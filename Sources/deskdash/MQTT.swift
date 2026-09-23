import Foundation
import Network

/// A minimal MQTT 3.1 client, the dialect Dyson devices speak: connect with a username and password,
/// subscribe, publish at QoS 0, keep alive. Enough to read a purifier's sensors; nothing more.
@MainActor
final class MQTTClient {
    enum Event {
        case connected
        case refused(UInt8)  // CONNACK return code: 4 bad username or password, 5 not authorized
        case message(topic: String, payload: Data)
        case closed(String)
    }

    private let connection: NWConnection
    private let username: String
    private let password: String
    private let clientID = "deskdash-" + String(UInt32.random(in: 0...UInt32.max), radix: 36)  // MQTT 3.1: <= 23 chars
    private let onEvent: (Event) -> Void
    private var buffer: [UInt8] = []
    private var keepalive: Task<Void, Never>?
    private var lastReceived = Date()
    private var nextPacketID: UInt16 = 0
    private var finished = false
    private(set) var isConnected = false
    /// How far the connection got, for error messages: where did it stall?
    private(set) var progress = "looking up the device"

    /// DESKDASH_DEBUG=1 logs connection states and packet types (never the login's contents).
    private static let debug = ProcessInfo.processInfo.environment["DESKDASH_DEBUG"] != nil
    private func trace(_ message: @autoclosure () -> String) {
        if Self.debug { log("mqtt: \(message())") }
    }

    init(endpoint: NWEndpoint, username: String, password: String, onEvent: @escaping (Event) -> Void) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 10
        connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
        self.username = username
        self.password = password
        self.onEvent = onEvent
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state) }
        }
        connection.start(queue: .main)
        // Without a deadline a connection can sit in "preparing" for good: an unresolvable Bonjour name, or a
        // Local Network denial lifted a moment later (right after a rebuild, before macOS updates its record).
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !self.finished, !self.isConnected else { return }
            self.finish("no answer within 20 s (\(self.progress))")
        }
    }

    func stop() {
        if isConnected { send([0xE0, 0x00]) }  // DISCONNECT
        finish("stopped")
    }

    func subscribe(_ topic: String) {
        trace("subscribe \(topic)")
        nextPacketID &+= 1
        send(Self.packet(0x82, [UInt8(nextPacketID >> 8), UInt8(nextPacketID & 0xFF)] + Self.string(topic) + [0]))
    }

    func publish(_ topic: String, _ payload: Data) {
        trace("publish \(topic) \(String(decoding: payload.prefix(120), as: UTF8.self))")
        send(Self.packet(0x30, Self.string(topic) + Array(payload)))
    }

    // MARK: connection

    private func handle(_ state: NWConnection.State) {
        trace("state \(state)")
        switch state {
        case .preparing:
            progress = "connecting"
        case .ready:
            progress = "connected, login sent, no reply to the login"
            send(Self.packet(0x10, Self.string("MQIsdp") + [3, 0xC2, 0, 60]  // MQTT 3.1; user+password, clean session; 60 s
                             + Self.string(clientID) + Self.string(username) + Self.string(password)))
            receive()
        case .waiting(let error): finish("cannot reach it (\(error))")
        case .failed(let error): finish("connection failed (\(error))")
        case .cancelled: finish("closed")
        default: break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return }
                if let data, !data.isEmpty {
                    self.lastReceived = Date()
                    self.buffer += data
                    self.parsePackets()
                }
                if let error { return self.finish("receive failed (\(error))") }
                if isComplete { return self.finish("closed by the device") }
                self.receive()
            }
        }
    }

    private func send(_ bytes: [UInt8]) { send(Data(bytes)) }

    private func send(_ data: Data) {
        guard !finished else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func finish(_ reason: String) {
        guard !finished else { return }
        finished = true
        isConnected = false
        keepalive?.cancel()
        connection.cancel()
        onEvent(.closed(reason))
    }

    /// Pings every 30 s; 90 s without a byte from the device means the connection is dead.
    private func startKeepalive() {
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                if Date().timeIntervalSince(self.lastReceived) > 90 { return self.finish("the device went quiet") }
                self.send([0xC0, 0x00])  // PINGREQ
            }
        }
    }

    // MARK: packets

    private func parsePackets() {
        while buffer.count >= 2 {
            var length = 0, multiplier = 1, index = 1, complete = false
            while index < buffer.count, index <= 4 {
                let byte = Int(buffer[index])
                length += (byte & 0x7F) * multiplier
                multiplier *= 128
                index += 1
                if byte & 0x80 == 0 {
                    complete = true
                    break
                }
            }
            guard complete else {
                if index > 4 { finish("malformed packet") }
                return
            }
            guard buffer.count >= index + length else { return }
            let header = buffer[0]
            let body = Array(buffer[index..<(index + length)])
            buffer.removeFirst(index + length)
            handlePacket(type: header >> 4, flags: header & 0x0F, body: body)
        }
    }

    private func handlePacket(type: UInt8, flags: UInt8, body: [UInt8]) {
        trace("received packet type \(type), \(body.count) bytes")
        switch type {
        case 2:  // CONNACK
            let code = body.count >= 2 ? body[1] : 0xFF
            guard code == 0 else {
                onEvent(.refused(code))
                return finish("refused (code \(code))")
            }
            isConnected = true
            progress = "logged in"
            startKeepalive()
            onEvent(.connected)
        case 3:  // PUBLISH
            guard body.count >= 2 else { return }
            let topicLength = Int(body[0]) << 8 | Int(body[1])
            guard body.count >= 2 + topicLength else { return }
            let topic = String(decoding: body[2..<(2 + topicLength)], as: UTF8.self)
            var offset = 2 + topicLength
            let qos = (flags >> 1) & 0x03
            if qos > 0 {
                guard body.count >= offset + 2 else { return }
                send([qos == 1 ? 0x40 : 0x50, 0x02, body[offset], body[offset + 1]])  // PUBACK or PUBREC
                offset += 2
            }
            onEvent(.message(topic: topic, payload: Data(body[offset...])))
        case 6:  // PUBREL, for a QoS 2 delivery
            if body.count >= 2 { send([0x70, 0x02, body[0], body[1]]) }  // PUBCOMP
        default:
            break  // SUBACK, PINGRESP
        }
    }

    private static func string(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        return [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)] + bytes
    }

    private static func packet(_ header: UInt8, _ body: [UInt8]) -> Data {
        var out: [UInt8] = [header]
        var length = body.count
        repeat {
            var byte = UInt8(length % 128)
            length /= 128
            if length > 0 { byte |= 0x80 }
            out.append(byte)
        } while length > 0
        return Data(out + body)
    }
}
