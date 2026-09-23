import Foundation

struct Quote: Equatable, Sendable {
    var price: Double
    var prevDay: Double
    var funding: Double?
    var updated: Date

    var change: Double { prevDay > 0 ? price / prevDay - 1 : 0 }
}

/// Live prices from Hyperliquid, no API key: one WebSocket subscription per coin (`activeAssetCtx`, about one
/// ~300-byte message a second each), plus a 24h sparkline from 15-minute candles refreshed every 10 minutes.
@MainActor
final class MarketsService {
    private static let wsURL = URL(string: "wss://api.hyperliquid.xyz/ws")!
    private static let infoURL = URL(string: "https://api.hyperliquid.xyz/info")!

    private let dash: Dashboard
    private var symbols: [String] = []
    private var streamTask: Task<Void, Never>?
    private var sparkTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var pending: [String: Quote] = [:]
    private var lastMessage = Date.distantPast

    init(dash: Dashboard) {
        self.dash = dash
    }

    func apply(symbols new: [String]) {
        guard new != symbols else { return }
        symbols = new
        streamTask?.cancel()
        sparkTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        guard !new.isEmpty else { return }
        streamTask = Task { await stream(new) }
        sparkTask = Task {
            while !Task.isCancelled {
                await refreshSparks(new)
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    /// Publishes the latest prices; called once a second so the screen redraws at most that often.
    func flush() {
        guard !pending.isEmpty else { return }
        dash.quotes.merge(pending) { _, new in new }
        pending.removeAll()
    }

    // MARK: WebSocket

    private func stream(_ symbols: [String]) async {
        var backoff = 2.0
        while !Task.isCancelled {
            let ws = URLSession.shared.webSocketTask(with: Self.wsURL)
            socket = ws
            ws.resume()
            lastMessage = Date()
            // Keepalive, and a watchdog: silence for 45 s means a dead connection, so drop it and reconnect.
            let keepalive = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    if Date().timeIntervalSince(lastMessage) > 45 {
                        ws.cancel(with: .goingAway, reason: nil)
                        return
                    }
                    try? await ws.send(.string(#"{"method":"ping"}"#))
                }
            }
            do {
                for coin in symbols {
                    try await ws.send(.string(Self.json(["method": "subscribe",
                                                         "subscription": ["type": "activeAssetCtx", "coin": coin]])))
                }
                while !Task.isCancelled {
                    switch try await ws.receive() {
                    case .string(let text): handle(Data(text.utf8))
                    case .data(let data): handle(data)
                    @unknown default: break
                    }
                    backoff = 2
                }
            } catch {
                if !Task.isCancelled { log("markets: stream dropped (\(error.localizedDescription)); retrying in \(Int(backoff))s") }
            }
            keepalive.cancel()
            ws.cancel(with: .goingAway, reason: nil)
            dash.marketsConnected = false
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 60)
        }
    }

    private struct Envelope: Decodable { let channel: String }

    private struct CtxMessage: Decodable {
        struct Payload: Decodable {
            let coin: String
            let ctx: Ctx
        }
        let data: Payload
    }

    struct Ctx: Decodable {
        let markPx: String?
        let midPx: String?
        let prevDayPx: String?
        let funding: String?

        var quote: Quote? {
            guard let price = midPx.flatMap(Double.init) ?? markPx.flatMap(Double.init),
                  let prev = prevDayPx.flatMap(Double.init)
            else { return nil }
            return Quote(price: price, prevDay: prev, funding: funding.flatMap(Double.init), updated: Date())
        }
    }

    private func handle(_ data: Data) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return }
        lastMessage = Date()
        guard envelope.channel == "activeAssetCtx",
              let message = try? JSONDecoder().decode(CtxMessage.self, from: data),
              let quote = message.data.ctx.quote
        else { return }
        pending[message.data.coin] = quote
        if !dash.marketsConnected { dash.marketsConnected = true }
    }

    // MARK: REST

    /// One-shot read of every perp's context (for `deskdash snapshot`, which cannot wait for the stream).
    func fetchOnce(_ symbols: [String]) async {
        struct Universe: Decodable {
            struct Asset: Decodable { let name: String }
            let universe: [Asset]
        }
        struct MetaAndCtxs: Decodable {
            let names: [String]
            let ctxs: [Ctx]
            init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                names = try c.decode(Universe.self).universe.map(\.name)
                ctxs = try c.decode([Ctx].self)
            }
        }
        do {
            let data = try await Self.post(["type": "metaAndAssetCtxs"])
            let m = try JSONDecoder().decode(MetaAndCtxs.self, from: data)
            for (name, ctx) in zip(m.names, m.ctxs) where symbols.contains(name) {
                dash.quotes[name] = ctx.quote
            }
            dash.marketsConnected = true
        } catch {
            log("markets: snapshot fetch failed: \(error.localizedDescription)")
        }
    }

    /// Every perp Hyperliquid lists, for checking a symbol typed into Settings (names are case-sensitive: kPEPE).
    static func listedSymbols() async -> [String]? {
        struct Meta: Decodable {
            struct Asset: Decodable { let name: String }
            let universe: [Asset]
        }
        guard let data = try? await post(["type": "meta"]),
              let meta = try? JSONDecoder().decode(Meta.self, from: data)
        else { return nil }
        return meta.universe.map(\.name)
    }

    func refreshSparks(_ symbols: [String]) async {
        struct Candle: Decodable { let c: String }
        let end = Date()
        let start = end.addingTimeInterval(-24 * 3600)
        for coin in symbols {
            guard !Task.isCancelled else { return }
            do {
                let data = try await Self.post(["type": "candleSnapshot",
                                                "req": ["coin": coin, "interval": "15m",
                                                        "startTime": Int(start.ms), "endTime": Int(end.ms)]])
                dash.sparks[coin] = try JSONDecoder().decode([Candle].self, from: data).compactMap { Double($0.c) }
            } catch {
                log("markets: candles for \(coin) failed: \(error.localizedDescription)")
            }
        }
    }

    private static func post(_ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: infoURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
