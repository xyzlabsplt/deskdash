import Foundation

/// Tokens one agent used, by kind. Cache reads are the conversation so far, read again on every turn: most of the
/// total, and the cheapest kind.
struct TokenCount: Codable, Equatable, Sendable {
    var input = 0  // new input, including what was written to the prompt cache
    var cached = 0  // input read back from the prompt cache
    var output = 0  // what the model wrote, reasoning included

    var total: Int { input + cached + output }

    static func + (a: TokenCount, b: TokenCount) -> TokenCount {
        TokenCount(input: a.input + b.input, cached: a.cached + b.cached, output: a.output + b.output)
    }

    static func - (a: TokenCount, b: TokenCount) -> TokenCount {
        TokenCount(input: a.input - b.input, cached: a.cached - b.cached, output: a.output - b.output)
    }

    static func += (a: inout TokenCount, b: TokenCount) { a = a + b }
    static func -= (a: inout TokenCount, b: TokenCount) { a = a - b }
}

/// The coding agents whose logs are read, by the name the history file and the config use.
enum TokenAgent: String, CaseIterable, Sendable {
    case claude, codex, gemini, muse

    /// As the tokens page names it.
    var label: String { rawValue.uppercased() }
}

/// One day's tokens, per agent. In the history file it is an object of agents, {"claude": {...}, "codex": {...}}, and
/// an agent this version does not know is kept as it is.
struct DayTokens: Codable, Equatable, Sendable {
    var agents: [String: TokenCount]

    init(agents: [String: TokenCount] = [:]) {
        self.agents = agents
    }

    subscript(_ agent: TokenAgent) -> TokenCount {
        get { agents[agent.rawValue] ?? TokenCount() }
        set { agents[agent.rawValue] = newValue }
    }

    var total: Int { agents.values.reduce(0) { $0 + $1.total } }
    var all: TokenCount { agents.values.reduce(TokenCount(), +) }

    static func + (a: DayTokens, b: DayTokens) -> DayTokens {
        DayTokens(agents: a.agents.merging(b.agents, uniquingKeysWith: +))
    }

    /// The larger count of each agent. Logs only ever grow until they are deleted, so the larger one is the more
    /// complete.
    static func fuller(_ a: DayTokens, _ b: DayTokens) -> DayTokens {
        DayTokens(agents: a.agents.merging(b.agents) { $0.total >= $1.total ? $0 : $1 })
    }

    init(from decoder: Decoder) throws {
        agents = try decoder.singleValueContainer().decode([String: TokenCount].self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(agents)
    }
}

// The history file outlives versions of deskdash: a field it does not have yet reads as zero.
extension TokenCount {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.get(.input, 0)
        cached = try c.get(.cached, 0)
        output = try c.get(.output, 0)
    }
}

/// Every day's tokens deskdash knows of, by `LocalDay` number.
struct TokenHistory: Equatable, Sendable {
    var days: [Int: DayTokens] = [:]

    func on(_ day: Int) -> DayTokens { days[day] ?? DayTokens() }

    func sum(_ range: ClosedRange<Int>) -> DayTokens {
        range.reduce(DayTokens()) { $0 + on($1) }
    }

    /// Every day on record: what the logs on this Mac hold, and the history file's days.
    var allTime: Int { days.values.reduce(0) { $0 + $1.total } }

    func used(in range: ClosedRange<Int>) -> Bool {
        days.contains { range.contains($0.key) && $0.value.total > 0 }
    }

    /// Days in a row with any use, up to today. A day without use yet does not end the streak until it is over.
    func streak(through today: Int) -> Int {
        var day = on(today).total > 0 ? today : today - 1
        var count = 0
        while on(day).total > 0 {
            count += 1
            day -= 1
        }
        return count
    }

    /// For `snapshot --demo`: a made-up year of use that grows toward today, heavy on weekdays, light or none at
    /// weekends, with Codex on about half the days and Gemini on a quarter, both today. The same day always gets the
    /// same numbers.
    static func demo(today: Int) -> TokenHistory {
        var days: [Int: DayTokens] = [:]
        for day in (today - 7 * 54)...today {
            var seed = UInt64(bitPattern: Int64(day)) &* 0x9E37_79B9_7F4A_7C15
            func random() -> Double {  // splitmix64, 0..<1
                seed &+= 0x9E37_79B9_7F4A_7C15
                var z = seed
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
            }
            let weekend = [0, 6].contains(LocalDay.weekday(day))
            guard day == today || random() >= (weekend ? 0.55 : 0.1) else { continue }
            let trend = 0.35 + 0.65 * Double(day - today + 7 * 54) / Double(7 * 54)
            let claude = 95e6 * trend * (weekend ? 0.3 : 1) * (0.2 + 1.6 * random())
            let codex = day == today || random() < 0.5 ? claude * 0.35 * random() : 0
            let gemini = day == today || random() < 0.25 ? claude * 0.2 * random() : 0
            func split(_ total: Double) -> TokenCount {
                TokenCount(input: Int(total * 0.035), cached: Int(total * 0.95), output: Int(total * 0.015))
            }
            var tokens = DayTokens()
            for (agent, total) in [(TokenAgent.claude, claude), (.codex, codex), (.gemini, gemini)] where total > 0 {
                tokens[agent] = split(total)
            }
            days[day] = tokens
        }
        return TokenHistory(days: days)
    }
}

/// A calendar day in this Mac's time zone, as a count of days since 1 January 1970. Plain arithmetic, so a day's
/// weekday and month need no Calendar, and a day's key in the history file reads as its date.
enum LocalDay {
    static func of(_ date: Date, zone: TimeZone = .current) -> Int {
        floorDiv(Int(date.timeIntervalSince1970.rounded(.down)) + zone.secondsFromGMT(for: date), 86_400)
    }

    /// 0 is Sunday, 6 Saturday: Calendar's weekday minus one. 1 January 1970 was a Thursday.
    static func weekday(_ day: Int) -> Int { ((day + 4) % 7 + 7) % 7 }

    /// Year, month (1-12) and day of the month (Howard Hinnant's civil_from_days).
    static func civil(_ day: Int) -> (year: Int, month: Int, day: Int) {
        let z = day + 719_468
        let era = floorDiv(z, 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, doy - (153 * mp + 2) / 5 + 1)
    }

    /// The inverse of `civil` (days_from_civil).
    static func number(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = floorDiv(y, 400)
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        return era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468
    }

    /// "2026-09-23", the history file's key for a day.
    static func key(_ day: Int) -> String {
        let c = civil(day)
        return String(format: "%04d-%02d-%02d", c.year, c.month, c.day)
    }

    static func day(key: String) -> Int? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, (1...12).contains(p[1]), (1...31).contains(p[2]) else { return nil }
        return number(year: p[0], month: p[1], day: p[2])
    }

    /// Seconds since 1970 from an ISO 8601 timestamp as both agents write them, "2026-09-23T07:34:57.718Z"; an offset
    /// such as "+08:00" in place of the Z is understood too.
    static func seconds(iso text: String) -> Int? {
        var text = text
        return text.withUTF8 { b -> Int? in
            func digits(_ at: Int, _ count: Int) -> Int? {
                guard at + count <= b.count else { return nil }
                var v = 0
                for i in at..<at + count {
                    let d = Int(b[i]) &- 48
                    guard (0...9).contains(d) else { return nil }
                    v = v * 10 + d
                }
                return v
            }
            guard b.count >= 19, b[4] == UInt8(ascii: "-"), b[10] == UInt8(ascii: "T"),
                  let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
                  let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2)
            else { return nil }
            var i = 19
            if i < b.count, b[i] == UInt8(ascii: ".") {
                i += 1
                while i < b.count, (48...57).contains(b[i]) { i += 1 }
            }
            var offset = 0
            if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-"),
               let h = digits(i + 1, 2), let m = digits(i + 4, 2) {
                offset = (b[i] == UInt8(ascii: "+") ? 1 : -1) * (h * 3600 + m * 60)
            }
            return number(year: year, month: month, day: day) * 86_400 + hour * 3600 + minute * 60 + second - offset
        }
    }

    static func floorDiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : -((-a + b - 1) / b) }
}

/// Reads token counts out of the agents' own logs on this Mac:
///  - Claude Code's transcripts, `<projects>/<project>/<session>.jsonl`, and its subagents' beside them in
///    `<session>/subagents/`, a workflow's agents one level further down (`workflows/wf_<id>/`). Each assistant line
///    carries the API's `usage`. A reply with several blocks is written as several lines, each with the reply's usage
///    so far (older versions wrote it growing), and a resumed or forked session copies earlier lines into its new file,
///    so a reply counts once, by its message and request ids, at the largest of its lines. `<synthetic>` replies, which
///    Claude Code writes itself, are left out, and so are the `journal.jsonl` files of workflows.
///  - Codex's rollouts, `<codex>/sessions/YYYY/MM/DD/rollout-*.jsonl` and `<codex>/archived_sessions/`. Each response
///    writes a `token_usage_record` with its id. Versions before those records wrote only `token_count` events,
///    whose session totals are counted by the difference from the one before.
///  - Gemini CLI's sessions, `<gemini>/tmp/<project>/chats/*.json`: one JSON file per session, written over as the
///    session grows, so it is read whole when it changes and replaces what it counted before. Each reply in it carries
///    its `tokens`.
///  - Muse Code's sessions, `<muse>/sessions/YYYY/MM/DD/<session>/session.jsonl`, each subagent's in its own
///    `subagent/<id>/session.jsonl` below. Each `model_completed` event carries one model call's usage.
/// Only what carries token counts is decoded, and only the counts and times are kept: never the conversation. It keeps
/// its place in each log, so after the first pass a scan reads only what was appended since the last.
///
/// Claude Code deletes transcripts after 30 days (its `cleanupPeriodDays`), and the page counts all time, so each day's
/// totals are also kept in the history file, `tokens.history`.
actor TokenScanner {
    private typealias Agent = TokenAgent

    private struct Transcript {
        let path: String
        let key: String  // Codex's rollouts move to archived_sessions/: they keep their place by file name
        let agent: Agent
        let size: Int
        let modified: Int  // seconds since 1970
    }

    /// A Claude reply's usage: the largest of its lines so far.
    private struct Reply {
        let time: Int  // its first line's, seconds since 1970
        var input: Int, cacheWrite: Int, cacheRead: Int, output: Int
    }

    private struct Place {
        var path: String
        var agent: Agent
        var modified: Int  // when the file was last seen written, seconds since 1970
        var offset = 0  // bytes read, up to the end of the last whole line; a Gemini session's size when last read
        var codexTotal: TokenCount?  // the session total in the last token_count event
        var codexRecords = false  // this rollout has token_usage_records, which count instead
    }

    private let claude: String?
    private let codex: String?
    private let gemini: String?
    private let muse: String?
    private var file: URL?  // the history file; nil once it turns out to be one not to write over
    private var places: [String: Place] = [:]
    private var walkedAt: Int?  // the last thorough pass
    private var listed: [String: (stamp: Int, folders: [String])] = [:]  // each folder when last listed: its time, in ns
    private var seen = Set<Int>()  // counted already: Claude replies, Codex responses and Muse calls, by id, hashed
    private var recent: [Int: Reply] = [:]  // the last day's Claude replies, whose later lines may say more
    private var sessions: [String: [Int: TokenCount]] = [:]  // each Gemini session's count by day, as last read
    private var counted: [Int: DayTokens] = [:]  // what the logs on disk hold, by day
    private var history: [Int: DayTokens]?  // the history file, and what has been added to it since
    private var saved: [Int: DayTokens]?
    private var savedAt: Date?
    private var zoneBlock = Int.min  // the quarter-hour whose UTC offset is `zoneOffset`
    private var zoneOffset = 0
    private let decoder = JSONDecoder()

    init(_ cfg: Config.Tokens) {
        func folder(_ path: String) -> String? { path.isEmpty ? nil : Paths.resolve(path).path }
        claude = folder(cfg.claude)
        codex = folder(cfg.codex)
        gemini = folder(cfg.gemini)
        muse = folder(cfg.muse)
        file = cfg.history.isEmpty ? nil : Paths.resolve(cfg.history)
    }

    /// Reads what the logs gained since the last call and returns every day known, from the logs and the history file.
    /// `save` writes the history file when it has changed, at most every 10 minutes (and when a day ends): the logs
    /// keep the latest days anyway.
    func refresh(now: Date = Date(), save: Bool) -> TokenHistory {
        let first = history == nil
        if first {
            if let path = file, let days = Self.load(path, setAside: save) {
                history = days
            } else {
                history = [:]
                if save { file = nil }
            }
            saved = history
        }
        let started = Date()
        let clock = Int(now.timeIntervalSince1970)
        let thorough = walkedAt.map { clock - $0 >= 300 } ?? true
        let (transcripts, present) = find(now: clock, thorough: thorough)
        var bytes = 0
        for transcript in transcripts { bytes += read(transcript) }
        if thorough {
            walkedAt = clock
            places = places.filter { present.contains($0.key) }  // deleted
            recent = recent.filter { $0.value.time >= clock - 86_400 }
        }

        var merged = history ?? [:]
        for (day, tokens) in counted { merged[day] = merged[day].map { DayTokens.fuller($0, tokens) } ?? tokens }
        history = merged
        if first {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            log("tokens: read \(transcripts.count == 1 ? "1 log" : "\(transcripts.count) logs"), \(bytes / 1_000_000) MB, "
                + "in \(ms) ms; \(merged.count == 1 ? "1 day" : "\(merged.count) days") on record")
        }
        if save, let file, merged != saved,
           savedAt.map({ now.timeIntervalSince($0) >= 600 || LocalDay.of($0) != LocalDay.of(now) }) ?? true {
            Self.store(merged, to: file)
            saved = merged
            savedAt = now
        }
        return TokenHistory(days: merged)
    }

    // MARK: finding the logs

    /// The logs to read, and every log seen. A thorough pass, every 5 minutes, lists every folder and looks at every
    /// file. In between, a quick pass looks only where something is likely to have changed: in the folders that gained a
    /// file (a new session), and at the logs written in the last day, with their sessions' subagent folders. A session
    /// resumed after longer waits for the next thorough pass.
    private func find(now: Int, thorough: Bool) -> ([Transcript], Set<String>) {
        let recent = now - 86_400
        var out: [Transcript] = []
        var keys = Set<String>()
        if thorough { listed = [:] }
        func add(_ path: String, _ key: String, _ agent: Agent, _ entry: Entry? = nil) {
            guard keys.insert(key).inserted, let file = entry ?? Self.entry(at: path) else { return }
            out.append(Transcript(path: path, key: key, agent: agent, size: file.size, modified: file.modified))
        }
        /// The logs in a folder that changed, every one on a thorough pass and the new ones on a quick pass, and
        /// its subfolders.
        func scan(_ dir: String, _ agent: Agent, where wanted: (String) -> Bool) -> [String] {
            let (files, folders) = list(dir, always: thorough)
            for entry in files ?? [] where wanted(entry.name) {
                let path = dir + "/" + entry.name
                let key = agent == .codex ? entry.name : path
                if thorough || places[key] == nil { add(path, key, agent, entry) }
            }
            return folders
        }
        /// A folder and those below it, `depth` levels down: a quick pass lists only the folders that changed, but
        /// looks into each of them.
        func walk(_ dir: String, _ agent: Agent, depth: Int, where wanted: (String) -> Bool) {
            for folder in scan(dir, agent, where: wanted) where depth > 0 {
                walk(dir + "/" + folder, agent, depth: depth - 1, where: wanted)
            }
        }
        /// On a quick pass: the logs written in the last day. Returns their keys.
        func hot(_ agent: Agent) -> [String] {
            var found: [String] = []
            for (key, place) in places where place.agent == agent && place.modified >= recent {
                add(place.path, key, agent)
                found.append(key)
            }
            return found
        }
        // The day folders (YYYY/MM/DD) where a new Codex or Muse session starts: yesterday's to tomorrow's, whichever
        // zone the agent dates them in.
        let today = LocalDay.of(Date(timeIntervalSince1970: Double(now)))
        let days = (today - 1...today + 1).map { day in
            let date = LocalDay.civil(day)
            return String(format: "%04d/%02d/%02d", date.year, date.month, date.day)
        }
        if let claude {
            let jsonl = { (name: String) in name.hasSuffix(".jsonl") && name != "journal.jsonl" }  // a journal holds no counts
            for project in list(claude, always: thorough).folders {
                let dir = claude + "/" + project
                for session in scan(dir, .claude, where: jsonl) where thorough {
                    walk(dir + "/" + session + "/subagents", .claude, depth: 3, where: jsonl)
                }
            }
            if !thorough {
                for key in hot(.claude) where !key.contains("/subagents/") {
                    walk(String(key.dropLast(6)) + "/subagents", .claude, depth: 3, where: jsonl)  // a live session's
                }
            }
        }
        if let codex {
            let rollout = { (name: String) in name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") }
            if thorough {
                walk(codex + "/sessions", .codex, depth: 3, where: rollout)
                walk(codex + "/archived_sessions", .codex, depth: 0, where: rollout)
            } else {
                for day in days { walk(codex + "/sessions/" + day, .codex, depth: 0, where: rollout) }
                _ = hot(.codex)
            }
        }
        if let gemini {
            for project in list(gemini + "/tmp", always: thorough).folders {
                _ = scan(gemini + "/tmp/" + project + "/chats", .gemini, where: { $0.hasSuffix(".json") })
            }
            if !thorough { _ = hot(.gemini) }
        }
        if let muse {
            let session = { (name: String) in name == "session.jsonl" }
            if thorough {
                walk(muse + "/sessions", .muse, depth: 8, where: session)
            } else {
                for day in days { walk(muse + "/sessions/" + day, .muse, depth: 5, where: session) }
                for key in hot(.muse) {
                    walk(String(key.dropLast("session.jsonl".count)) + "subagent", .muse, depth: 4, where: session)
                }
            }
        }
        return (out, keys)
    }

    /// A folder's files if it has changed since it was last listed (a file added, removed or renamed), or `always`, and
    /// its subfolders either way: from the last listing when it has not changed.
    private func list(_ path: String, always: Bool) -> (files: [Entry]?, folders: [String]) {
        var info = stat()
        guard stat(path, &info) == 0 else {
            listed[path] = nil
            return (always ? [] : nil, [])
        }
        let stamp = Int(info.st_mtimespec.tv_sec) &* 1_000_000_000 &+ info.st_mtimespec.tv_nsec
        if !always, let known = listed[path], known.stamp == stamp { return (nil, known.folders) }
        let entries = Self.entries(path)
        let folders = entries.filter(\.isDirectory).map(\.name)
        listed[path] = (stamp, folders)
        return (entries.filter { !$0.isDirectory }, folders)
    }

    private struct Entry {
        let name: String
        let isDirectory: Bool
        var size = 0
        var modified = 0  // seconds since 1970
    }

    /// A folder's subfolders and files, with each file's size and modification time: readdir and fstatat, a fraction of
    /// the cost of FileManager's listing, which makes a URL and its resource values for every entry.
    private static func entries(_ path: String) -> [Entry] {
        guard let dir = opendir(path) else { return [] }
        defer { closedir(dir) }
        var out: [Entry] = []
        while let item = readdir(dir) {
            let name = withUnsafeBytes(of: item.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(item.pointee.d_namlen)), as: UTF8.self)
            }
            guard !name.hasPrefix(".") else { continue }
            let type = item.pointee.d_type
            var info = stat()
            if type == DT_DIR {
                out.append(Entry(name: name, isDirectory: true))
            } else if type == DT_REG || type == DT_UNKNOWN, fstatat(dirfd(dir), name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                out.append(Entry(name: name, isDirectory: info.st_mode & S_IFMT == S_IFDIR, size: Int(info.st_size),
                                 modified: Int(info.st_mtimespec.tv_sec)))
            }
        }
        return out
    }

    private static func entry(at path: String) -> Entry? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Entry(name: "", isDirectory: false, size: Int(info.st_size), modified: Int(info.st_mtimespec.tv_sec))
    }

    // MARK: reading them

    /// Reads a log from where the last scan stopped, a few MB at a time; returns the bytes read.
    private func read(_ transcript: Transcript) -> Int {
        if transcript.agent == .gemini { return readSession(transcript) }
        var place = places[transcript.key] ?? Place(path: transcript.path, agent: transcript.agent, modified: 0)
        if transcript.size < place.offset {  // rewritten: read it again; what was counted stays counted
            place = Place(path: transcript.path, agent: transcript.agent, modified: 0)
        }
        place.path = transcript.path
        place.modified = transcript.modified
        guard transcript.size > place.offset, let handle = FileHandle(forReadingAtPath: transcript.path) else {
            places[transcript.key] = place
            return 0
        }
        defer { try? handle.close() }
        let start = place.offset
        do { try handle.seek(toOffset: UInt64(place.offset)) } catch { return 0 }
        let chunk = 4 << 20
        var pending = Data()
        while let data = try? handle.read(upToCount: chunk), !data.isEmpty {
            pending.append(data)
            let used = lines(in: pending, transcript.agent, &place)
            place.offset += used
            pending = Data(pending.dropFirst(used))  // a line longer than a chunk waits for the rest of itself
            if data.count < chunk { break }
        }
        places[transcript.key] = place
        return place.offset - start
    }

    private static let assistant = Array(#""type":"assistant""#.utf8)
    private static let usage = Array(#""usage""#.utf8)
    private static let record = Array(#""type":"token_usage_record""#.utf8)
    private static let tokenCount = Array(#""type":"token_count""#.utf8)
    private static let modelCompleted = Array(#""model_completed""#.utf8)

    /// Counts the whole lines in `data`; returns the bytes they take, through the last newline.
    private func lines(in data: Data, _ agent: Agent, _ place: inout Place) -> Int {
        var wanted: [Range<Int>] = []
        var used = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            func has(_ needle: [UInt8], _ at: Int, _ count: Int) -> Bool {
                needle.withUnsafeBytes { memmem(base + at, count, $0.baseAddress, needle.count) != nil }
            }
            var start = 0
            while start < raw.count, let newline = memchr(base + start, 0x0A, raw.count - start) {
                let end = UnsafeRawPointer(newline) - base
                let length = end - start
                let keep = switch agent {
                case .claude: has(Self.assistant, start, length) && has(Self.usage, start, length)
                case .codex: has(Self.record, start, length) || has(Self.tokenCount, start, length)
                case .muse: has(Self.modelCompleted, start, length)
                case .gemini: false  // read whole, by readSession
                }
                if keep { wanted.append(start..<end) }
                start = end + 1
            }
            used = start
        }
        let base = data.startIndex
        var totals: [(TokenCount, Int)] = []  // Codex token_count differences, counted if the rollout has no records
        for range in wanted {
            let line = data[(base + range.lowerBound)..<(base + range.upperBound)]
            switch agent {
            case .claude: countClaude(line)
            case .codex: countCodex(line, &place, &totals)
            case .muse: countMuse(line)
            case .gemini: break
            }
        }
        if !place.codexRecords {
            for (tokens, time) in totals { add(tokens, .codex, at: time) }
        }
        return used
    }

    private struct ClaudeLine: Decodable {
        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
        }
        struct Usage: Decodable {
            let input_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
            let output_tokens: Int?
        }
        let timestamp: String?
        let requestId: String?
        let message: Message?
    }

    private func countClaude(_ line: Data) {
        guard let entry = try? decoder.decode(ClaudeLine.self, from: line), let message = entry.message,
              let usage = message.usage, message.model != "<synthetic>",
              let time = entry.timestamp.flatMap(LocalDay.seconds(iso:))
        else { return }
        let counts = Reply(time: time, input: max(0, usage.input_tokens ?? 0), cacheWrite: max(0, usage.cache_creation_input_tokens ?? 0),
                         cacheRead: max(0, usage.cache_read_input_tokens ?? 0), output: max(0, usage.output_tokens ?? 0))
        guard let id = message.id else {
            return add(TokenCount(input: counts.input + counts.cacheWrite, cached: counts.cacheRead, output: counts.output), .claude,
                       at: time)
        }
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(entry.requestId)
        let key = hasher.finalize()
        if seen.insert(key).inserted {
            recent[key] = counts
            add(TokenCount(input: counts.input + counts.cacheWrite, cached: counts.cacheRead, output: counts.output), .claude,
                at: time)
        } else if var known = recent[key] {
            // A later line of the same reply: count whatever it adds, on the reply's own day.
            let grown = TokenCount(input: max(0, counts.input - known.input) + max(0, counts.cacheWrite - known.cacheWrite),
                                   cached: max(0, counts.cacheRead - known.cacheRead), output: max(0, counts.output - known.output))
            guard grown.total > 0 else { return }
            known.input = max(known.input, counts.input)
            known.cacheWrite = max(known.cacheWrite, counts.cacheWrite)
            known.cacheRead = max(known.cacheRead, counts.cacheRead)
            known.output = max(known.output, counts.output)
            recent[key] = known
            add(grown, .claude, at: known.time)
        }
    }

    private struct CodexLine: Decodable {
        struct Payload: Decodable {
            let type: String?
            let response_id: String?
            let usage: Usage?  // token_usage_record: this response's tokens
            let info: Info?  // token_count: the session's tokens so far
        }
        struct Info: Decodable {
            let total_token_usage: Usage?
        }
        /// OpenAI counts cached input as part of the input, and reasoning as part of the output.
        struct Usage: Decodable {
            let input_tokens: Int?
            let cached_input_tokens: Int?
            let output_tokens: Int?

            var tokens: TokenCount {
                let cached = cached_input_tokens ?? 0
                return TokenCount(input: max(0, (input_tokens ?? 0) - cached), cached: cached, output: output_tokens ?? 0)
            }
        }
        let timestamp: String?
        let type: String?
        let payload: Payload?
    }

    private func countCodex(_ line: Data, _ place: inout Place, _ totals: inout [(TokenCount, Int)]) {
        guard let entry = try? decoder.decode(CodexLine.self, from: line), let payload = entry.payload,
              let time = entry.timestamp.flatMap(LocalDay.seconds(iso:))
        else { return }
        if entry.type == "token_usage_record" {
            place.codexRecords = true
            guard let usage = payload.usage else { return }
            if let id = payload.response_id, !seen.insert(id.hashValue).inserted { return }
            add(usage.tokens, .codex, at: time)
        } else if payload.type == "token_count", let total = payload.info?.total_token_usage?.tokens {
            let before = place.codexTotal
            place.codexTotal = total
            guard let before else { return totals.append((total, time)) }
            let step = TokenCount(input: total.input - before.input, cached: total.cached - before.cached,
                                  output: total.output - before.output)
            if step.input < 0 || step.cached < 0 || step.output < 0 {
                totals.append((total, time))  // the total started over
            } else if step.total > 0 {
                totals.append((step, time))  // the same total again is a repeat, not a response
            }
        }
    }

    /// Gemini CLI writes a session's file over as it grows: when its size or time changes, it is read whole, and what
    /// it counts replaces what it counted before. A reply's `tokens` may count the cached input inside the input: when
    /// the total adds up that way, the cached part is taken out of the input.
    private func readSession(_ transcript: Transcript) -> Int {
        if let known = places[transcript.key], known.offset == transcript.size, known.modified == transcript.modified {
            return 0
        }
        guard let data = FileManager.default.contents(atPath: transcript.path),
              let session = try? decoder.decode(GeminiSession.self, from: data)
        else { return 0 }  // being written: the next scan tries again
        places[transcript.key] = Place(path: transcript.path, agent: .gemini, modified: transcript.modified,
                                       offset: transcript.size)
        var replies: [String: GeminiSession.Message] = [:]  // by id: a later copy replaces an earlier one
        var unnamed: [GeminiSession.Message] = []
        for message in session.messages ?? [] where message.tokens != nil && !(message.model ?? "").isEmpty {
            if let id = message.id { replies[id] = message } else { unnamed.append(message) }
        }
        var byDay: [Int: TokenCount] = [:]
        for message in Array(replies.values) + unnamed {
            guard let tokens = message.tokens?.count, tokens.total > 0,
                  let time = (message.timestamp ?? session.startTime).flatMap(LocalDay.seconds(iso:))
            else { continue }
            byDay[day(of: time), default: TokenCount()] += tokens
        }
        for (day, tokens) in sessions[transcript.key] ?? [:] { counted[day, default: DayTokens()][.gemini] -= tokens }
        for (day, tokens) in byDay { counted[day, default: DayTokens()][.gemini] += tokens }
        sessions[transcript.key] = byDay
        return data.count
    }

    private struct GeminiSession: Decodable {
        struct Message: Decodable {
            let id: String?
            let timestamp: String?
            let model: String?
            let tokens: Tokens?
        }
        /// `thoughts` (reasoning) and `tool` (tool-use prompts) are counted apart from `input` and `output`.
        struct Tokens: Decodable {
            let input: Int?
            let output: Int?
            let cached: Int?
            let thoughts: Int?
            let tool: Int?
            let total: Int?

            var count: TokenCount {
                var input = max(0, self.input ?? 0)
                let cached = max(0, self.cached ?? 0), output = max(0, self.output ?? 0)
                let thoughts = max(0, self.thoughts ?? 0), tool = max(0, self.tool ?? 0)
                if cached > 0, total == input + output + thoughts + tool { input = max(0, input - cached) }
                return TokenCount(input: input + tool, cached: cached, output: output + thoughts)
            }
        }
        let startTime: String?
        let messages: [Message]?
    }

    private struct MuseLine: Decodable {
        struct Stream: Decodable {
            let id: String?
        }
        struct Payload: Decodable {
            let event: Event?
        }
        struct Event: Decodable {
            let kind: String?
            let model: String?
            let usage: Usage?
        }
        /// Muse counts cached input inside the input, and reasoning inside the output.
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
            let cached_tokens: Int?
            let cache_read_tokens: Int?
            let cache_write_tokens: Int?
        }
        let stream: Stream?
        let sequence: Int?
        let recorded_at: Int?  // microseconds since 1970
        let payload_type: String?
        let payload: Payload?
    }

    /// One `model_completed` event: one model call. A parent session's `workflow_child_lifecycle` totals repeat its
    /// subagents' calls, which their own logs count, so they are left out.
    private func countMuse(_ line: Data) {
        guard let entry = try? decoder.decode(MuseLine.self, from: line), entry.payload_type == "runtime.session",
              let event = entry.payload?.event, event.kind == "model_completed", let usage = event.usage,
              let recorded = entry.recorded_at
        else { return }
        let time = recorded >= 1_000_000_000_000_000 ? recorded / 1_000_000  // microseconds
            : recorded >= 1_000_000_000_000 ? recorded / 1000  // milliseconds
            : recorded
        guard time >= 1_000_000_000 else { return }
        let input = max(0, usage.input_tokens ?? 0), output = max(0, usage.output_tokens ?? 0)
        let cached = min(max(0, usage.cache_read_tokens ?? usage.cached_tokens ?? 0), input)
        let tokens = TokenCount(input: input - cached + max(0, usage.cache_write_tokens ?? 0), cached: cached, output: output)
        if let session = entry.stream?.id, let sequence = entry.sequence {  // an event written twice counts once
            var hasher = Hasher()
            hasher.combine("muse")
            hasher.combine(session)
            hasher.combine(sequence)
            guard seen.insert(hasher.finalize()).inserted else { return }
        }
        add(tokens, .muse, at: time)
    }

    private func add(_ tokens: TokenCount, _ agent: Agent, at time: Int) {
        guard tokens.total > 0 else { return }
        counted[day(of: time), default: DayTokens()][agent] += tokens
    }

    /// The local day of a time in the logs. This Mac's UTC offset is looked up once per quarter-hour of them: offsets
    /// change on quarter-hours.
    private func day(of time: Int) -> Int {
        let block = LocalDay.floorDiv(time, 900)
        if block != zoneBlock {
            zoneBlock = block
            zoneOffset = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: Double(block * 900)))
        }
        return LocalDay.floorDiv(time + zoneOffset, 86_400)
    }

    // MARK: the history file

    private struct HistoryFile: Codable {
        var days: [String: DayTokens]
    }

    /// The days in the history file. One that is there but cannot be read is never written over: with `setAside`, it is
    /// renamed to `<name>.unreadable` and a new history starts; nil if even that failed.
    private static func load(_ file: URL, setAside: Bool) -> [Int: DayTokens]? {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(HistoryFile.self, from: data) {
            var days: [Int: DayTokens] = [:]
            for (key, tokens) in decoded.days {
                if let day = LocalDay.day(key: key) { days[day] = tokens }
            }
            return days
        }
        guard setAside else {
            log("tokens: could not read \(file.path); going by the logs alone")
            return [:]
        }
        let aside = file.appendingPathExtension("unreadable")
        try? FileManager.default.removeItem(at: aside)
        do {
            try FileManager.default.moveItem(at: file, to: aside)
            log("tokens: could not read \(file.path); kept it as \(aside.lastPathComponent) and started a new history")
        } catch {
            log("tokens: could not read \(file.path), nor set it aside, so no history is kept: \(error.localizedDescription)")
            return nil
        }
        return [:]
    }

    private static func store(_ days: [Int: DayTokens], to file: URL) {
        let body = HistoryFile(days: Dictionary(uniqueKeysWithValues: days.map { (LocalDay.key($0.key), $0.value) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(body).write(to: file, options: .atomic)
        } catch {
            log("tokens: could not save \(file.path): \(error.localizedDescription)")
        }
    }
}

/// Counts the tokens Claude Code and Codex use on this Mac (TokenScanner), while the tokens page is on.
@MainActor
final class TokensService {
    private let dash: Dashboard
    private var current: Config.Tokens?
    private var scanner: TokenScanner?
    private var scanning = false
    private var scannedAt = Date.distantPast
    private var showing = false

    init(dash: Dashboard) {
        self.dash = dash
    }

    func apply(_ cfg: Config.Tokens, enabled: Bool) {
        let wanted = enabled ? cfg : nil
        guard wanted != current else { return }
        current = wanted
        scanner = wanted.map(TokenScanner.init)
        scannedAt = .distantPast  // the next tick reads it all
        if wanted == nil { dash.tokens = nil }
    }

    /// On the clock tick: a scan as the tokens page comes up and every 10 s while it shows, so its count keeps up with
    /// the agents; otherwise every 5 min, which keeps the rotation and the history file current.
    func tick() {
        let onPage = dash.page == .tokens
        defer { showing = onPage }
        guard let scanner, !scanning else { return }
        let age = Date().timeIntervalSince(scannedAt)
        guard age >= (onPage ? 10 : 300) || (onPage && !showing) else { return }
        scanning = true
        scannedAt = Date()
        Task(priority: .utility) {
            let history = await scanner.refresh(save: true)
            scanning = false
            guard self.scanner === scanner else { return }  // the settings changed while it ran
            if history != dash.tokens { dash.tokens = history }
        }
    }

    /// For `deskdash snapshot`: one scan, without touching the history file.
    func scanOnce(_ cfg: Config.Tokens) async {
        dash.tokens = await TokenScanner(cfg).refresh(save: false)
    }

    /// `deskdash tokens --watch`: today's count, a line each time it changes, as the page would show it.
    static func watch(_ cfg: Config.Tokens) async {
        let scanner = TokenScanner(cfg)
        let number = IntegerFormatStyle<Int>().locale(Locale(identifier: "en_US"))
        func agents(_ day: DayTokens) -> String {
            TokenAgent.allCases.filter { day[$0].total > 0 }.map { "  \($0.rawValue) \(day[$0].total.formatted(number))" }.joined()
        }
        var last: DayTokens?
        print("Counting today's tokens every 10 s, as the tokens page does while it shows. Control-C stops.")
        while !Task.isCancelled {
            let today = await scanner.refresh(save: false).on(LocalDay.of(Date()))
            if let before = last, today != before {
                print("\(Date().formatted(date: .omitted, time: .standard))  today \(today.total.formatted(number))"
                    + "  (+\((today.total - before.total).formatted(number)))" + agents(today))
            } else if last == nil {
                print("today \(today.total.formatted(number))" + agents(today))
            }
            last = today
            try? await Task.sleep(for: .seconds(10))
        }
    }

    /// `deskdash tokens`: each day with any use, oldest first, with a column for each agent that has any, then what the
    /// tokens page shows.
    static func report(_ cfg: Config.Tokens) async -> String {
        let history = await TokenScanner(cfg).refresh(save: false)
        let today = LocalDay.of(Date())
        let number = IntegerFormatStyle<Int>().locale(Locale(identifier: "en_US"))
        func column(_ text: String, _ width: Int = 16) -> String {
            String(repeating: " ", count: max(0, width - text.count)) + text
        }
        let agents = TokenAgent.allCases.filter { agent in history.days.values.contains { $0[agent].total > 0 } }
        var lines = ["date      " + agents.map { column($0.rawValue) }.joined() + column("total") + column("new input")
            + column("cached") + column("output")]
        for day in history.days.keys.sorted() {
            let d = history.on(day)
            guard d.total > 0 else { continue }
            lines.append(LocalDay.key(day) + agents.map { column(d[$0].total.formatted(number)) }.joined()
                + [d.total, d.all.input, d.all.cached, d.all.output].map { column($0.formatted(number)) }.joined())
        }
        let streak = history.streak(through: today)
        lines.append("")
        lines.append("today \(Fmt.tokens(history.on(today).total)) · 7 days \(Fmt.tokens(history.sum(today - 6...today).total))"
            + " · 30 days \(Fmt.tokens(history.sum(today - 29...today).total)) · all time \(Fmt.tokens(history.allTime))"
            + " · streak \(streak) day\(streak == 1 ? "" : "s")")
        return lines.joined(separator: "\n")
    }
}
