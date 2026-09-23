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
}

/// One day's tokens, per agent.
struct DayTokens: Codable, Equatable, Sendable {
    var claude = TokenCount()
    var codex = TokenCount()

    var total: Int { claude.total + codex.total }
    var all: TokenCount { claude + codex }

    static func + (a: DayTokens, b: DayTokens) -> DayTokens {
        DayTokens(claude: a.claude + b.claude, codex: a.codex + b.codex)
    }

    /// The larger count of each agent. Transcripts only ever grow until they are deleted, so the larger one is the
    /// more complete.
    static func fuller(_ a: DayTokens, _ b: DayTokens) -> DayTokens {
        DayTokens(claude: a.claude.total >= b.claude.total ? a.claude : b.claude,
                  codex: a.codex.total >= b.codex.total ? a.codex : b.codex)
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

extension DayTokens {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claude = try c.get(.claude, TokenCount())
        codex = try c.get(.codex, TokenCount())
    }
}

/// Every day's tokens deskdash knows of, by `LocalDay` number.
struct TokenHistory: Equatable, Sendable {
    var days: [Int: DayTokens] = [:]

    func on(_ day: Int) -> DayTokens { days[day] ?? DayTokens() }

    func sum(_ range: ClosedRange<Int>) -> DayTokens {
        range.reduce(DayTokens()) { $0 + on($1) }
    }

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
    /// weekends, with Codex on about half the days and today. The same day always gets the same numbers.
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
            func split(_ total: Double) -> TokenCount {
                TokenCount(input: Int(total * 0.035), cached: Int(total * 0.95), output: Int(total * 0.015))
            }
            days[day] = DayTokens(claude: split(claude), codex: split(codex))
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
///    `<session>/subagents/`. Each assistant line carries the API's `usage`. A reply with several blocks is written as
///    several lines with the same message id and usage, and a resumed or forked session copies earlier lines into its
///    new file, so a message counts once, by id.
///  - Codex's rollouts, `<codex>/sessions/YYYY/MM/DD/rollout-*.jsonl` and `<codex>/archived_sessions/`. Each response
///    writes a `token_usage_record` with its id. Versions before those records wrote only `token_count` events,
///    whose session totals are counted by the difference from the one before.
/// Only lines that carry token counts are decoded, and only their counts and times are kept: never the conversation.
/// It keeps its place in each file, so after the first pass a scan reads only what was appended since the last.
///
/// Claude Code deletes transcripts after 30 days (its `cleanupPeriodDays`), and the heatmap reaches back further, so
/// each day's totals are also kept in the history file, `tokens.history`.
actor TokenScanner {
    private enum Agent { case claude, codex }

    private struct Transcript {
        let path: String
        let key: String  // Codex's rollouts move to archived_sessions/: they keep their place by file name
        let agent: Agent
        let size: Int
        let modified: Int  // seconds since 1970
    }

    private struct Place {
        var path: String
        var agent: Agent
        var modified: Int  // when the file was last seen written, seconds since 1970
        var offset = 0  // bytes read, up to the end of the last whole line
        var codexTotal: TokenCount?  // the session total in the last token_count event
        var codexRecords = false  // this rollout has token_usage_records, which count instead
    }

    private let claude: String?
    private let codex: String?
    private var file: URL?  // the history file; nil once it turns out to be one not to write over
    /// Days back that the heatmap and the stats reach. Older lines in a log not read yet are skipped.
    private let reach: Int
    private var places: [String: Place] = [:]
    private var walkedAt: Int?  // the last thorough pass
    private var listed: [String: Int] = [:]  // folders' modification times when last listed, in ns
    private var projects: [String] = []  // Claude Code's project folders
    private var seen = Set<Int>()  // Claude message ids and Codex response ids counted, hashed
    private var counted: [Int: DayTokens] = [:]  // what the logs on disk hold, by day
    private var history: [Int: DayTokens]?  // the history file, and what has been added to it since
    private var saved: [Int: DayTokens]?
    private var savedAt: Date?
    private var zoneBlock = Int.min  // the quarter-hour whose UTC offset is `zoneOffset`
    private var zoneOffset = 0
    private let decoder = JSONDecoder()

    init(_ cfg: Config.Tokens) {
        claude = cfg.claude.isEmpty ? nil : Paths.resolve(cfg.claude).path
        codex = cfg.codex.isEmpty ? nil : Paths.resolve(cfg.codex).path
        file = cfg.history.isEmpty ? nil : Paths.resolve(cfg.history)
        reach = max(cfg.span * 7, 31) + 7
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
            places = places.filter { present.contains($0.key) }  // deleted, or moved out of reach
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
        let horizon = now - reach * 86_400
        let recent = now - 86_400
        var out: [Transcript] = []
        var keys = Set<String>()
        if thorough { listed = [:] }
        func add(_ path: String, _ key: String, _ agent: Agent, _ entry: Entry? = nil) {
            guard keys.insert(key).inserted, let file = entry ?? Self.entry(at: path) else { return }
            if places[key] == nil, file.modified < horizon {
                // Last written before the heatmap reaches: nothing in it to count, but anything added to it later is.
                places[key] = Place(path: path, agent: agent, modified: file.modified, offset: file.size)
                return
            }
            out.append(Transcript(path: path, key: key, agent: agent, size: file.size, modified: file.modified))
        }
        /// The logs in a folder that changed: every one on a thorough pass, the new ones on a quick pass.
        func scan(_ dir: String, _ agent: Agent, where wanted: (String) -> Bool) -> [Entry] {
            guard let found = list(dir, always: thorough) else { return [] }
            for entry in found where !entry.isDirectory && wanted(entry.name) {
                let path = dir + "/" + entry.name
                let key = agent == .codex ? entry.name : path
                if thorough || places[key] == nil { add(path, key, agent, entry) }
            }
            return found
        }
        let jsonl = { (name: String) in name.hasSuffix(".jsonl") }
        if let claude {
            if let found = list(claude, always: thorough) {
                projects = found.filter(\.isDirectory).map { claude + "/" + $0.name }
            }
            for dir in projects {
                for entry in scan(dir, .claude, where: jsonl) where entry.isDirectory && thorough {
                    _ = scan(dir + "/" + entry.name + "/subagents", .claude, where: jsonl)  // a session's subagents
                }
            }
            if !thorough {
                for (key, place) in places where place.agent == .claude && place.modified >= recent {
                    add(place.path, key, .claude)
                    if !key.contains("/subagents/") {
                        _ = scan(String(key.dropLast(6)) + "/subagents", .claude, where: jsonl)
                    }
                }
            }
        }
        if let codex {
            let rollout = { (name: String) in name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") }
            if thorough {
                func walk(_ dir: String, depth: Int) {
                    for entry in scan(dir, .codex, where: rollout) where entry.isDirectory && depth > 0 {
                        walk(dir + "/" + entry.name, depth: depth - 1)
                    }
                }
                walk(codex + "/sessions", depth: 3)
                walk(codex + "/archived_sessions", depth: 0)
            } else {
                // A new rollout starts in the folder of its day; one already known is written where it is.
                let today = LocalDay.of(Date(timeIntervalSince1970: Double(now)))
                for day in [today - 1, today] {
                    let date = LocalDay.civil(day)
                    _ = scan(codex + String(format: "/sessions/%04d/%02d/%02d", date.year, date.month, date.day), .codex,
                             where: rollout)
                }
                for (key, place) in places where place.agent == .codex && place.modified >= recent {
                    add(place.path, key, .codex)
                }
            }
        }
        return (out, keys)
    }

    /// A folder's entries if it has changed since it was last listed (a file added, removed or renamed), or `always`.
    private func list(_ path: String, always: Bool) -> [Entry]? {
        var info = stat()
        guard stat(path, &info) == 0 else { return always ? [] : nil }
        let stamp = Int(info.st_mtimespec.tv_sec) &* 1_000_000_000 &+ info.st_mtimespec.tv_nsec
        guard always || listed[path] != stamp else { return nil }
        listed[path] = stamp
        return Self.entries(path)
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
            let usage: Usage?
        }
        struct Usage: Decodable {
            let input_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
            let output_tokens: Int?
        }
        let timestamp: String?
        let message: Message?
    }

    private func countClaude(_ line: Data) {
        guard let entry = try? decoder.decode(ClaudeLine.self, from: line), let usage = entry.message?.usage,
              let time = entry.timestamp.flatMap(LocalDay.seconds(iso:))
        else { return }
        if let id = entry.message?.id, !seen.insert(id.hashValue).inserted { return }
        add(TokenCount(input: (usage.input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0),
                       cached: usage.cache_read_input_tokens ?? 0, output: usage.output_tokens ?? 0),
            .claude, at: time)
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

    private func add(_ tokens: TokenCount, _ agent: Agent, at time: Int) {
        guard tokens.total > 0 else { return }
        // This Mac's UTC offset, looked up once per quarter-hour of the logs: offsets change on quarter-hours.
        let block = LocalDay.floorDiv(time, 900)
        if block != zoneBlock {
            zoneBlock = block
            zoneOffset = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: Double(block * 900)))
        }
        let day = LocalDay.floorDiv(time + zoneOffset, 86_400)
        switch agent {
        case .claude: counted[day, default: DayTokens()].claude = counted[day, default: DayTokens()].claude + tokens
        case .codex: counted[day, default: DayTokens()].codex = counted[day, default: DayTokens()].codex + tokens
        }
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
        var last: DayTokens?
        print("Counting today's tokens every 10 s, as the tokens page does while it shows. Control-C stops.")
        while !Task.isCancelled {
            let today = await scanner.refresh(save: false).on(LocalDay.of(Date()))
            if let before = last, today != before {
                print("\(Date().formatted(date: .omitted, time: .standard))  today \(today.total.formatted(number))"
                    + "  (+\((today.total - before.total).formatted(number)))  claude \(today.claude.total.formatted(number))"
                    + "  codex \(today.codex.total.formatted(number))")
            } else if last == nil {
                print("today \(today.total.formatted(number))  claude \(today.claude.total.formatted(number))"
                    + "  codex \(today.codex.total.formatted(number))")
            }
            last = today
            try? await Task.sleep(for: .seconds(10))
        }
    }

    /// `deskdash tokens`: each day with any use, oldest first, then what the tokens page shows.
    static func report(_ cfg: Config.Tokens) async -> String {
        let history = await TokenScanner(cfg).refresh(save: false)
        let today = LocalDay.of(Date())
        let number = IntegerFormatStyle<Int>().locale(Locale(identifier: "en_US"))
        func column(_ n: Int, _ width: Int) -> String {
            let text = n.formatted(number)
            return String(repeating: " ", count: max(0, width - text.count)) + text
        }
        var lines = ["date                 claude           codex           total      new input          cached          output"]
        for day in history.days.keys.sorted() {
            let d = history.on(day)
            guard d.total > 0 else { continue }
            lines.append(LocalDay.key(day) + column(d.claude.total, 17) + column(d.codex.total, 16)
                + column(d.total, 16) + column(d.all.input, 15) + column(d.all.cached, 16) + column(d.all.output, 16))
        }
        let streak = history.streak(through: today)
        lines.append("")
        lines.append("today \(Fmt.tokens(history.on(today).total)) · 7 days \(Fmt.tokens(history.sum(today - 6...today).total))"
            + " · 30 days \(Fmt.tokens(history.sum(today - 29...today).total)) · streak \(streak) day\(streak == 1 ? "" : "s")")
        return lines.joined(separator: "\n")
    }
}
