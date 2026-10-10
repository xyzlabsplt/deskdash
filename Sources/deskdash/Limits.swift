import Foundation

/// One of a plan's usage windows (the 5-hour session, or the week) as the agent last reported it.
struct UsageWindow: Equatable, Sendable {
    let used: Double  // percent, 0 to 100
    let resetsAt: Date?
    let length: TimeInterval

    var left: Double { max(0, min(100, 100 - used)) }

    /// Past its reset time the window has started over. Until the agent reports again, nothing of it is used.
    func at(_ now: Date) -> UsageWindow {
        guard let resetsAt, now >= resetsAt, length > 0 else { return self }
        let periods = (now.timeIntervalSince(resetsAt) / length).rounded(.down) + 1
        return UsageWindow(used: 0, resetsAt: resetsAt + periods * length, length: length)
    }

    /// The share of the window gone by, 0 to 1: what an even pace would have used by now.
    func elapsed(_ now: Date) -> Double? {
        guard let resetsAt, length > 0 else { return nil }
        return min(1, max(0, 1 - resetsAt.timeIntervalSince(now) / length))
    }

    /// When it runs out at the pace so far, if that comes before the reset.
    func runsOut(_ now: Date) -> Date? {
        guard let resetsAt, let elapsed = elapsed(now), elapsed > 0.02, used > 0 else { return nil }
        let perSecond = used / (elapsed * length)
        let out = now + (100 - used) / perSecond
        return out < resetsAt ? out : nil
    }
}

/// An agent's plan limits: its 5-hour session window and its weekly one.
struct AgentLimits: Identifiable, Equatable, Sendable {
    let kind: AgentSession.Kind
    let plan: String?
    let session: UsageWindow?
    let week: UsageWindow?
    let updated: Date  // when the agent reported them

    var id: String { kind.rawValue }

    func at(_ now: Date) -> AgentLimits {
        AgentLimits(kind: kind, plan: plan, session: session?.at(now), week: week?.at(now), updated: updated)
    }

    static func demo(now: Date) -> [AgentLimits] {
        [
            AgentLimits(kind: .claude, plan: "max",
                        session: UsageWindow(used: 38, resetsAt: now + 6120, length: 5 * 3600),
                        week: UsageWindow(used: 69, resetsAt: now + 3.3 * 86400, length: 7 * 86400), updated: now - 40),
            AgentLimits(kind: .codex, plan: "plus",
                        session: UsageWindow(used: 12, resetsAt: now + 11100, length: 5 * 3600),
                        week: UsageWindow(used: 30, resetsAt: now + 3.9 * 86400, length: 7 * 86400), updated: now - 900),
        ]
    }
}

/// Reads the limits where each agent leaves them:
///  - Claude Code hands its status line command the plan's rate limits, and hooks/claude-statusline.sh copies them
///    to `limits.claude`: { updatedAt, rate_limits: { five_hour, seven_day: { used_percentage, resets_at } } }.
///  - Codex logs a token_count event after every reply, with rate_limits: { primary, secondary: { used_percent,
///    window_minutes, resets_at } } and the plan_type. Only the newest log's tail is read, and only those events.
actor LimitsReader {
    private let cfg: Config.Limits
    private var codexCache: (file: URL, modified: Date, size: Int, limits: AgentLimits?)?

    init(_ cfg: Config.Limits) {
        self.cfg = cfg
    }

    func read() -> [AgentLimits] {
        [claude(), codex()].compactMap { $0 }
    }

    // MARK: Claude Code

    private func claude() -> AgentLimits? {
        guard !cfg.claude.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: (cfg.claude as NSString).expandingTildeInPath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any]
        else { return nil }
        func window(_ key: String, _ length: TimeInterval) -> UsageWindow? {
            guard let w = limits[key] as? [String: Any], let used = Self.number(w["used_percentage"]) else { return nil }
            return UsageWindow(used: used, resetsAt: Self.date(w["resets_at"]), length: length)
        }
        let session = window("five_hour", 5 * 3600)
        let week = window("seven_day", 7 * 86400)
        guard session != nil || week != nil else { return nil }
        let updated = Self.number(root["updatedAt"]).map(Date.init(ms:)) ?? Date()
        return AgentLimits(kind: .claude, plan: nil, session: session, week: week, updated: updated)
    }

    // MARK: Codex

    private func codex() -> AgentLimits? {
        guard !cfg.codex.isEmpty else { return nil }
        let sessions = URL(fileURLWithPath: (cfg.codex as NSString).expandingTildeInPath).appendingPathComponent("sessions")
        // Codex files its logs by day: sessions/YYYY/MM/DD/rollout-*.jsonl. A week back covers the weekly window.
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        var logs: [(url: URL, modified: Date, size: Int)] = []
        for back in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: now) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                let url = dir.appendingPathComponent(name)
                guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let modified = a[.modificationDate] as? Date else { continue }
                logs.append((url, modified, (a[.size] as? Int) ?? 0))
            }
        }
        // The newest log with a snapshot in it: a session that just started has none yet.
        for log in logs.sorted(by: { $0.modified > $1.modified }).prefix(6) {
            if let cache = codexCache, cache.file == log.url, cache.modified == log.modified, cache.size == log.size {
                if let limits = cache.limits { return limits }
                continue
            }
            let limits = Self.lastSnapshot(in: log.url, modified: log.modified)
            codexCache = (log.url, log.modified, log.size, limits)
            if let limits { return limits }
        }
        return nil
    }

    private static let marker = Data(#""rate_limits""#.utf8)

    /// The last token_count event in the log's final 512 KB that carries the plan's limits.
    private static func lastSnapshot(in file: URL, modified: Date) -> AgentLimits? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > 512 * 1024 ? end - 512 * 1024 : 0
        try? handle.seek(toOffset: start)
        guard let tail = try? handle.readToEnd() else { return nil }
        var fallback: AgentLimits?
        for line in tail.split(separator: UInt8(ascii: "\n")).reversed() where line.range(of: marker) != nil {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = event["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let limits = payload["rate_limits"] as? [String: Any],
                  let parsed = codexLimits(limits, updated: date(event["timestamp"]) ?? modified)
            else { continue }
            // Codex may log other quotas beside its own (limit_id "codex"); prefer its own.
            let id = limits["limit_id"] as? String
            if id == nil || id == "codex" { return parsed }
            if fallback == nil { fallback = parsed }
        }
        return fallback
    }

    private static func codexLimits(_ limits: [String: Any], updated: Date) -> AgentLimits? {
        var session: UsageWindow?
        var week: UsageWindow?
        for (key, isPrimary) in [("primary", true), ("secondary", false)] {
            guard let w = limits[key] as? [String: Any], let used = number(w["used_percent"]) else { continue }
            let minutes = number(w["window_minutes"])
            let length = minutes.map { $0 * 60 } ?? (isPrimary ? 5 * 3600 : 7 * 86400)
            let window = UsageWindow(used: used, resetsAt: date(w["resets_at"]), length: length)
            // Which is which by length: the primary is the short one on today's plans, but that is not promised.
            if length <= 86400 { session = window } else { week = window }
        }
        guard session != nil || week != nil else { return nil }
        return AgentLimits(kind: .codex, plan: limits["plan_type"] as? String, session: session, week: week, updated: updated)
    }

    // MARK: values

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    /// Epoch seconds or milliseconds, or an ISO 8601 string with or without fractional seconds.
    private static func date(_ value: Any?) -> Date? {
        if let n = number(value), !(value is String) {
            return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        }
        guard let s = value as? String else { return nil }
        if let n = Double(s) { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }
}

/// Reads the limits every 5 s, off the main thread, and raises an alert when a window first drops below
/// `limits.alertBelow` percent left. A window alerts once, and again only after it has been back above.
@MainActor
final class LimitsService {
    private let dash: Dashboard
    private var current: Config.Limits?
    private var reader: LimitsReader?
    private var reading = false
    private var readAt = Date.distantPast
    private var low: Set<String> = []
    private var baselined = false

    init(dash: Dashboard) {
        self.dash = dash
    }

    func apply(_ cfg: Config.Limits, enabled: Bool) {
        let wanted = enabled ? cfg : nil
        guard wanted != current else { return }
        current = wanted
        reader = wanted.map(LimitsReader.init)
        readAt = .distantPast
        baselined = false
        if wanted == nil { dash.limits = [] }
    }

    func tick() {
        guard let reader, !reading, Date().timeIntervalSince(readAt) >= 5 else { return }
        reading = true
        readAt = Date()
        Task(priority: .utility) {
            let found = await reader.read()
            reading = false
            guard self.reader === reader else { return }  // the settings changed while it read
            if found != dash.limits { dash.limits = found }
            check(found)
        }
    }

    /// For `deskdash snapshot`: one read, no alerts.
    func readOnce(_ cfg: Config.Limits) async {
        dash.limits = await LimitsReader(cfg).read()
    }

    private func check(_ found: [AgentLimits]) {
        guard let threshold = current?.alertBelow, threshold > 0 else { return }
        let now = Date()
        var lowNow: Set<String> = []
        for limits in found.map({ $0.at(now) }) {
            if let w = limits.session, w.left < threshold { lowNow.insert("\(limits.id)-session") }
            if let w = limits.week, w.left < threshold { lowNow.insert("\(limits.id)-week") }
        }
        let fresh = lowNow.subtracting(low)
        low = lowNow
        defer { baselined = true }
        if baselined, !fresh.isEmpty { dash.alert(.limit) }
    }

    /// `deskdash limits`: what the limits page would show, one line per agent and window.
    static func report(_ cfg: Config.Limits) async -> String {
        let now = Date()
        let found = await LimitsReader(cfg).read().map { $0.at(now) }
        guard !found.isEmpty else {
            return "No limits found. Claude: run scripts/install-claude-statusline.sh, then send Claude Code a message"
                + " (Pro or Max plan). Codex: send it a message; its logs carry the limits."
        }
        var lines: [String] = []
        for limits in found {
            lines.append("\(limits.kind.rawValue)\(limits.plan.map { " (\($0))" } ?? "")  reported "
                + Fmt.duration(now.timeIntervalSince(limits.updated)) + " ago")
            for (name, w) in [("5 hours", limits.session), ("week", limits.week)] {
                guard let w else { continue }
                var line = "  \(name): \(Int(w.left.rounded()))% left"
                if let resets = w.resetsAt { line += ", resets in " + Fmt.duration(resets.timeIntervalSince(now)) }
                if let out = w.runsOut(now) { line += ", runs out in " + Fmt.duration(out.timeIntervalSince(now)) + " at this pace" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }
}
