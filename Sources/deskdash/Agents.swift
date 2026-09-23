import Foundation

/// One Claude Code or Codex session as the display shows it.
struct AgentSession: Identifiable, Equatable, Comparable, Sendable {
    enum Kind: String, Sendable { case claude, codex, other }

    enum State: Int, Comparable, Sendable {
        case waiting, working, done, idle  // display order: what needs you first

        static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .waiting: "NEEDS YOU"
            case .working: "WORKING"
            case .done: "DONE"
            case .idle: "IDLE"
            }
        }
    }

    let id: String
    let kind: Kind
    let name: String
    let project: String
    let state: State
    let since: Date  // when it entered `state`
    let detail: String?  // what it waits for ("permission prompt"), or the tool it is running

    /// Waiting: longest wait first. Everything else: most recent change first.
    static func < (a: AgentSession, b: AgentSession) -> Bool {
        if a.state != b.state { return a.state < b.state }
        return a.state == .waiting ? a.since < b.since : a.since > b.since
    }

    static func demo(now: Date) -> [AgentSession] {
        [
            AgentSession(id: "demo-1", kind: .claude, name: "Fix the flaky login test", project: "web-app",
                         state: .waiting, since: now - 95, detail: "permission prompt"),
            AgentSession(id: "demo-2", kind: .codex, name: "Move the API to v2", project: "api-server",
                         state: .working, since: now - 840, detail: "Bash"),
            AgentSession(id: "demo-3", kind: .claude, name: "Write the release notes", project: "docs",
                         state: .done, since: now - 240, detail: nil),
        ]
    }
}

/// Polls where agents record their state:
///  - Claude Code keeps ~/.claude/sessions/<pid>.json for every live session (desktop app, terminal, --bg),
///    with status busy | idle | waiting and what it is waiting for. Read-only; no hooks needed.
///  - hooks/agent-status.sh writes <stateDir>/<agent>-<session>.json from Codex's (or Claude's) lifecycle hooks.
@MainActor
final class AgentsService {
    private let dash: Dashboard
    private var task: Task<Void, Never>?
    private var previous: [String: AgentSession.State] = [:]
    private var baselined = false

    init(dash: Dashboard) {
        self.dash = dash
    }

    func start() {
        task = Task {
            while !Task.isCancelled {
                scan()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func scan(alerts: Bool = true) {
        let cfg = dash.config.agents
        let now = Date()
        var found: [AgentSession] = []
        if cfg.claude { found += Self.claudeSessions(cfg, now: now) }
        found += Self.hookSessions(cfg, now: now)
        found.sort()

        var becameWaiting = false
        var finished = false
        if baselined {
            for s in found {
                let before = previous[s.id]
                if s.state == .waiting && before != .waiting { becameWaiting = true }
                if before == .working && (s.state == .done || s.state == .idle) { finished = true }
            }
        }
        previous = Dictionary(found.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        baselined = true

        if found != dash.sessions { dash.sessions = found }
        guard alerts else { return }
        if becameWaiting {
            dash.alert(.waiting)
        } else if finished {
            dash.alert(.done)
        }
    }

    // MARK: Claude Code's session registry

    private struct ClaudeRecord: Decodable {
        let pid: Int32
        let sessionId: String?
        let cwd: String?
        let name: String?
        let status: String?
        let waitingFor: String?
        let startedAt: Double?
        let updatedAt: Double?
        let statusUpdatedAt: Double?
    }

    private static func claudeSessions(_ cfg: Config.Agents, now: Date) -> [AgentSession] {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [AgentSession] = []
        // Only <pid>.json. The <pid>.<hash>.key files beside them hold messaging tokens: never open those.
        for file in names where file.hasSuffix(".json") {
            let stem = file.dropLast(5)
            guard !stem.isEmpty, stem.allSatisfy(\.isASCII), stem.allSatisfy(\.isNumber),
                  let data = try? Data(contentsOf: dir.appendingPathComponent(file)),
                  let r = try? JSONDecoder().decode(ClaudeRecord.self, from: data)
            else { continue }
            let started = r.startedAt.map(Date.init(ms:))
            guard Proc.isAlive(r.pid, startedBy: started) else { continue }
            let since = Date(ms: r.statusUpdatedAt ?? r.updatedAt ?? r.startedAt ?? now.ms)
            let project = projectName(r.cwd)
            guard let state = state(r.status, since: since, started: started, now: now, cfg: cfg) else { continue }
            out.append(AgentSession(
                id: "claude-\(r.sessionId ?? String(r.pid))", kind: .claude,
                name: nonEmpty(r.name) ?? project, project: project, state: state, since: since,
                detail: state == .waiting ? nonEmpty(r.waitingFor) : nil))
        }
        return out
    }

    // MARK: files written by hooks/agent-status.sh

    private struct HookRecord: Decodable {
        let agent: String?
        let sessionId: String?
        let pid: Int32?
        let cwd: String?
        let name: String?
        let status: String?
        let waitingFor: String?
        let detail: String?
        let startedAt: Double?
        let updatedAt: Double?
        let statusUpdatedAt: Double?
    }

    private static func hookSessions(_ cfg: Config.Agents, now: Date) -> [AgentSession] {
        let dir = URL(fileURLWithPath: (cfg.stateDir as NSString).expandingTildeInPath)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [AgentSession] = []
        for file in names where file.hasSuffix(".json") {
            let url = dir.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url),
                  let r = try? JSONDecoder().decode(HookRecord.self, from: data)
            else { continue }
            let updated = Date(ms: r.updatedAt ?? 0)
            // Sessions that ended without a SessionEnd hook (crash, kill): drop their files.
            let alive = if let pid = r.pid, pid > 0 {
                Proc.isAlive(pid, startedBy: r.startedAt.map(Date.init(ms:)))
            } else {
                now.timeIntervalSince(updated) < cfg.maxIdleHours * 3600
            }
            guard alive else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let since = Date(ms: r.statusUpdatedAt ?? r.updatedAt ?? now.ms)
            let started = r.startedAt.map(Date.init(ms:))
            let project = projectName(r.cwd)
            guard let state = state(r.status, since: since, started: started, now: now, cfg: cfg) else { continue }
            let kind = AgentSession.Kind(rawValue: r.agent ?? "") ?? .other
            out.append(AgentSession(
                id: "\(kind.rawValue)-\(r.sessionId ?? file)", kind: kind,
                name: nonEmpty(r.name) ?? project, project: project, state: state, since: since,
                detail: state == .waiting ? nonEmpty(r.waitingFor) : state == .working ? nonEmpty(r.detail) : nil))
        }
        return out
    }

    // MARK: helpers

    /// Maps a recorded status to what the display shows; nil hides a long-idle session.
    private static func state(_ status: String?, since: Date, started: Date?, now: Date,
                              cfg: Config.Agents) -> AgentSession.State? {
        switch status {
        case "waiting": return .waiting
        case "busy": return .working
        default:
            let age = now.timeIntervalSince(since)
            // DONE only if the session did something after it started: a freshly opened one is just idle.
            let didWork = started.map { since.timeIntervalSince($0) > 10 } ?? true
            if age < cfg.doneMinutes * 60 && didWork { return .done }
            return age < cfg.maxIdleHours * 3600 ? .idle : nil
        }
    }

    private static func projectName(_ cwd: String?) -> String {
        guard let cwd = nonEmpty(cwd) else { return "" }
        if cwd.contains("/scratch-workspaces/") { return "scratch" }
        if cwd == NSHomeDirectory() { return "~" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

enum Proc {
    /// True when `pid` is running and started no later than `startedBy` (plus slack). The second check
    /// rejects a recycled pid that now belongs to a newer process.
    static func isAlive(_ pid: Int32, startedBy: Date?) -> Bool {
        guard pid > 0 else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        guard let startedBy else { return true }
        let tv = info.kp_proc.p_un.__p_starttime
        let processStart = Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
        return processStart <= startedBy.addingTimeInterval(5)
    }
}

extension Date {
    init(ms: Double) { self.init(timeIntervalSince1970: ms / 1000) }
    var ms: Double { timeIntervalSince1970 * 1000 }
}
