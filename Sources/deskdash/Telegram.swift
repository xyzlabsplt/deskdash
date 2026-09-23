import Foundation

/// A post from a public Telegram channel.
struct TelegramPost: Equatable, Sendable {
    let channel: String  // username, as in t.me/<channel>
    let id: Int
    let title: String  // the channel's display name
    let text: String
    let date: Date?
}

/// Watches public Telegram channels through their public web preview (t.me/s/<channel>): no account, bot, or
/// token. Every `pollSeconds` it asks only for posts newer than the last one seen (`?after=<id>`, about 5 KB
/// when there is nothing new) and hands new ones to the dashboard, which shows each for a few seconds. The first
/// check after start only notes the newest post, so a restart does not replay old ones.
@MainActor
final class TelegramService {
    private let dash: Dashboard
    private var config: Config.Telegram?
    private var task: Task<Void, Never>?
    private var lastSeen: [String: Int] = [:]
    private var failing: Set<String> = []

    init(dash: Dashboard) {
        self.dash = dash
    }

    func apply(_ cfg: Config.Telegram) {
        guard cfg != config else { return }
        config = cfg
        task?.cancel()
        lastSeen = [:]
        let channels = cfg.channels.compactMap(Self.username)
        guard !channels.isEmpty else { return }
        task = Task {
            while !Task.isCancelled {
                for channel in channels { await check(channel) }
                try? await Task.sleep(for: .seconds(max(10, cfg.pollSeconds)))
            }
        }
    }

    private func check(_ channel: String) async {
        let known = lastSeen[channel]
        guard let page = await Self.fetch(channel, after: known) else {
            if failing.insert(channel).inserted { log("telegram: could not read t.me/s/\(channel); will keep trying") }
            return
        }
        if failing.remove(channel) != nil { log("telegram: t.me/s/\(channel) readable again") }
        guard let known else {
            lastSeen[channel] = page.posts.map(\.id).max() ?? 0
            log("telegram: watching \(page.posts.first?.title ?? channel) (t.me/\(channel)), newest post #\(lastSeen[channel]!)")
            return
        }
        let fresh = page.posts.filter { $0.id > known }.sorted { $0.id < $1.id }
        guard let newest = fresh.last else { return }
        lastSeen[channel] = newest.id
        dash.notify(fresh)
    }

    /// The newest post, for `deskdash ctl telegram` and snapshots.
    static func latest(_ channel: String) async -> TelegramPost? {
        guard let name = username(channel) else { return nil }
        return await fetch(name, after: nil)?.posts.max { $0.id < $1.id }
    }

    /// Accepts telegram, @telegram, t.me/telegram, or https://t.me/s/telegram.
    static func username(_ raw: String) -> String? {
        let name = raw.split(separator: "/").last.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")) ?? ""
        return !name.isEmpty && name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) ? name : nil
    }

    // MARK: the preview page

    private static func fetch(_ channel: String, after: Int?) async -> (posts: [TelegramPost], title: String?)? {
        var url = URLComponents(string: "https://t.me/s/\(channel)")!
        if let after { url.queryItems = [URLQueryItem(name: "after", value: String(after))] }
        guard let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url.url!, timeoutInterval: 20)),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return parse(String(decoding: data, as: UTF8.self), channel: channel)
    }

    /// Each post is a `tgme_widget_message_wrap` block carrying data-post="<channel>/<id>", its text in
    /// `tgme_widget_message_text`, and its time in <time datetime>.
    static func parse(_ html: String, channel: String) -> (posts: [TelegramPost], title: String?) {
        let title = first(#"<meta property="og:title" content="([^"]*)""#, in: html).map(decodeEntities)
        var posts: [TelegramPost] = []
        for block in html.components(separatedBy: #"<div class="tgme_widget_message_wrap"#).dropFirst() {
            guard let post = first(#"data-post="[^"/]+/(\d+)""#, in: block), let id = Int(post) else { continue }
            let text = first(#"<div class="tgme_widget_message_text[^"]*"[^>]*>(.*?)</div>"#, in: block).map(plainText)
            let media = block.contains("tgme_widget_message_photo") ? "Photo"
                : block.contains("tgme_widget_message_video") ? "Video" : "New post"
            let date = first(#"<time datetime="([^"]+)""#, in: block).flatMap { try? Date($0, strategy: .iso8601) }
            posts.append(TelegramPost(channel: channel, id: id, title: title ?? channel,
                                      text: (text?.isEmpty == false ? text! : media), date: date))
        }
        return (posts, title)
    }

    private static func first(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func plainText(_ html: String) -> String {
        let breaks = html.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
        let stripped = breaks.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return decodeEntities(stripped).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        var out = text
        for (entity, char) in [("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        // Numeric entities (&#036; is how the preview writes "$"), then &amp; last so it cannot create new ones.
        if let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) {
            for match in regex.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                guard let whole = Range(match.range, in: out), let hex = Range(match.range(at: 1), in: out),
                      let digits = Range(match.range(at: 2), in: out),
                      let code = UInt32(out[digits], radix: out[hex].isEmpty ? 10 : 16),
                      let scalar = Unicode.Scalar(code)
                else { continue }
                out.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}
