import Foundation

/// Settings from config.json (JSON5: comments and trailing commas allowed). Every key is optional;
/// anything missing falls back to the defaults below, which are also documented in config.example.json.
struct Config: Codable, Equatable, Sendable {
    /// The menus' and alerts' language: "" follows macOS, or "en" or "zh-Hant".
    var language = ""
    var display = Display()
    var pages = Pages()
    var clock = Clock()
    var weather = Weather()
    var markets = Markets()
    var agents = Agents()
    var limits = Limits()
    var tokens = Tokens()
    var dyson = Dyson()
    var telegram = Telegram()
    var stats = Stats()
    var music = Music()
    var photos = Photos()
    var schedule = Schedule()
    var alerts = Alerts()

    struct Display: Codable, Equatable, Sendable {
        /// Part of the screen's name as System Settings > Displays shows it. Only that screen is ever covered.
        var match = "Wokyis"
        /// When a monitor is connected and the dock screen is the main display, make the monitor main.
        var keepOffMain = false
        /// When the dock screen is the only display (the Mac used remotely, through Parsec or Screen Sharing), add a
        /// virtual display of `virtualWidth` x `virtualHeight` points as the main one, until a monitor is connected.
        /// Uses CoreGraphics' private virtual display API.
        var virtualMain = false
        var virtualWidth = 1920
        var virtualHeight = 1080
        var virtualHiDPI = false
        /// When the dock screen goes black (`schedule.idleMinutes`, `schedule.sleep`), also turn its panel off over
        /// DDC/CI, backlight and all, if it takes the command. Otherwise it is only drawn black.
        var powerOff = true
    }

    struct Pages: Codable, Equatable, Sendable {
        var order = ["clock", "music", "photos", "climate", "markets", "agents", "limits", "tokens"]  // all but clock and markets only when they have data
        var seconds = 12.0
        var durations: [String: Double] = ["clock": 15]
    }

    struct Clock: Codable, Equatable, Sendable {
        var use24h = true
        /// An IANA time zone like "Europe/London"; "" follows this Mac.
        var timeZone = ""
    }

    struct Weather: Codable, Equatable, Sendable {
        var enabled = true
        /// Chosen in Settings → Weather & Time, which searches by city. Until a place is chosen there is no weather.
        var place = ""
        var latitude: Double?
        var longitude: Double?
        /// The place's own time zone, so Settings can point the clock at it.
        var timeZone = ""
        var fahrenheit = false

        /// Where to fetch the weather for: nil while it is off, or until a place is chosen.
        var coordinates: (latitude: Double, longitude: Double)? {
            guard enabled, let latitude, let longitude else { return nil }
            return (latitude, longitude)
        }
    }

    struct Markets: Codable, Equatable, Sendable {
        /// Hyperliquid perp names, e.g. BTC, ETH, SOL, HYPE, kPEPE.
        var symbols = ["BTC", "ETH", "SOL"]
        var perPage = 3

        /// `perPage` as the markets page draws it: one to five rows fit.
        var pageSize: Int { min(5, max(1, perPage)) }
    }

    struct Agents: Codable, Equatable, Sendable {
        /// Read Claude Code's own session registry (~/.claude/sessions/<pid>.json). No hooks needed.
        var claude = true
        /// Where hooks/agent-status.sh writes one file per session (Codex, or Claude via hooks).
        var stateDir = "~/.local/state/deskdash/agents"
        /// A session that finished its turn shows as DONE this long, then IDLE.
        var doneMinutes = 15.0
        /// Idle sessions older than this are left off the display.
        var maxIdleHours = 12.0
        var jumpOnWaiting = true
        var jumpOnDone = true
        var holdSeconds = 20.0
    }

    struct Limits: Codable, Equatable, Sendable {
        /// Where hooks/claude-statusline.sh copies the plan's limits from Claude Code's status line
        /// (scripts/install-claude-statusline.sh sets it up). "" leaves Claude out.
        var claude = "~/.local/state/deskdash/limits/claude.json"
        /// Codex's home: the logs in its sessions/ carry the plan's limits after every reply. "" leaves Codex out.
        var codex = "~/.codex"
        /// Alert when either window has less than this percent left: once per window, until it resets.
        var alertBelow = 20.0
        /// ...and jump to the limits page.
        var jumpOnAlert = true
    }

    struct Tokens: Codable, Equatable, Sendable {
        /// Weeks of days in the heatmap, this one included.
        var weeks = 26
        /// Where each agent keeps its logs: Claude Code's transcripts (a folder per project), Codex's home (its sessions/
        /// and archived_sessions/), Gemini CLI's (its tmp/<project>/chats/), and Muse Code's data folder (its
        /// sessions/). Only the token counts in them are read. "" leaves one out.
        var claude = "~/.claude/projects"
        var codex = "~/.codex"
        var gemini = "~/.gemini"
        var muse = "~/.local/share/muse"
        /// deskdash's own record of each day's totals: Claude Code deletes its transcripts after 30 days, and the page
        /// counts all time. "" keeps none.
        var history = "~/.local/state/deskdash/tokens.json"

        /// `weeks` as the heatmap draws it: 4 to 53.
        var span: Int { min(53, max(4, weeks)) }
    }

    struct Dyson: Codable, Equatable, Sendable {
        var enabled = true
        /// Written by Settings → Purifier or `deskdash dyson setup` (gitignored). Relative paths are inside the
        /// deskdash checkout.
        var credentials = "secrets/dyson.json"
        /// The purifier's IP or hostname; empty finds it by name on the local network (Bonjour).
        var host = ""
    }

    struct Telegram: Codable, Equatable, Sendable {
        /// Public channels to watch, by username (t.me/<name>), e.g. ["telegram"]. Empty watches nothing.
        var channels: [String] = []
        /// How long a new post stays on screen.
        var seconds = 5.0
        var pollSeconds = 20.0
    }

    struct Stats: Codable, Equatable, Sendable {
        /// CPU, temperature, memory, SSD and network meters along the bottom of the clock page.
        var enabled = true
    }

    struct Music: Codable, Equatable, Sendable {
        /// While Music or Spotify plays on this Mac, a line on the clock page. The Now Playing page is "music" in
        /// `pages.order`.
        var onClock = true
        /// Covers from Spotify's oEmbed and Apple's iTunes Search (public, no key), looked up once per album.
        var artwork = true
        /// Each new track takes the screen for `takeoverSeconds`, the way a Telegram post does.
        var takeover = false
        var takeoverSeconds = 5.0
    }

    struct Photos: Codable, Equatable, Sendable {
        /// A folder of pictures (JPEG, HEIC, PNG and the like), its subfolders included, for the photos page. "" has none.
        var folder = ""
        /// An album in the Photos app, by the name it shows there (Favorites, a shared album, one of yours). When set, it
        /// takes the folder's place. `deskdash ctl albums` logs the names.
        var album = ""
        var shuffle = true
        /// Crop each picture to fill the screen. false shows it whole, over a blurred copy of itself.
        var fill = false
        /// The time and date in the corner.
        var clock = true
    }

    struct Schedule: Codable, Equatable, Sendable {
        /// "HH:MM-HH:MM": hold the displays awake in this window. "" never does.
        var keepAwake = "08:00-23:00"
        /// "HH:MM-HH:MM": draw the dashboard at `dimBrightness` in this window, and at `dayBrightness` the rest of
        /// the day. "" never dims.
        var dim = "23:00-08:00"
        var dimBrightness = 0.35
        var dayBrightness = 1.0
        /// Turn the dock screen black after this many minutes without keyboard or mouse input; any input, or an alert,
        /// brings it back. 0 never does.
        var idleMinutes = 0.0
        /// "HH:MM-HH:MM": sleep hours, when the dock screen stays black whatever happens, and the displays may sleep.
        /// "" has none.
        var sleep = ""
    }

    struct Alerts: Codable, Equatable, Sendable {
        /// A sound when a session needs you, when one finishes, and when a limit runs low.
        var sound = false
        /// ...and a card at the top right of the main screen that says what for, until it is over or closed.
        var card = false
        /// macOS's alert sounds by name (/System/Library/Sounds: Glass, Hero, Funk, Ping, ...); "" stays quiet.
        var waiting = "Glass"
        var done = "Hero"
        var limit = "Funk"
        var volume = 1.0
        /// Ring through Notification Center: a notification on the main screen says what it is for, and macOS keeps it
        /// quiet in a Focus (Sleep among them), as it does any app's. false plays the sound directly, Focus or not;
        /// `volume` applies only then.
        var notify = true
        /// Play it again until someone uses the Mac's keyboard or mouse, or what it rang for is over: first after
        /// `repeatSeconds`, each wait half as long again as the last, up to `repeatMaxSeconds`. 0 plays it once.
        var repeatSeconds = 30.0
        var repeatMaxSeconds = 180.0
        /// No sound in the night window (`schedule.dim`).
        var quietAtNight = true
    }
}

// Decoding with per-key defaults: a partial config.json only overrides what it names.
extension Config {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        language = try c.get(.language, d.language)
        display = try c.get(.display, d.display)
        pages = try c.get(.pages, d.pages)
        clock = try c.get(.clock, d.clock)
        weather = try c.get(.weather, d.weather)
        markets = try c.get(.markets, d.markets)
        agents = try c.get(.agents, d.agents)
        limits = try c.get(.limits, d.limits)
        tokens = try c.get(.tokens, d.tokens)
        dyson = try c.get(.dyson, d.dyson)
        telegram = try c.get(.telegram, d.telegram)
        stats = try c.get(.stats, d.stats)
        music = try c.get(.music, d.music)
        photos = try c.get(.photos, d.photos)
        schedule = try c.get(.schedule, d.schedule)
        alerts = try c.get(.alerts, d.alerts)
    }
}

extension Config.Display {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        match = try c.get(.match, d.match)
        keepOffMain = try c.get(.keepOffMain, d.keepOffMain)
        virtualMain = try c.get(.virtualMain, d.virtualMain)
        virtualWidth = try c.get(.virtualWidth, d.virtualWidth)
        virtualHeight = try c.get(.virtualHeight, d.virtualHeight)
        virtualHiDPI = try c.get(.virtualHiDPI, d.virtualHiDPI)
        powerOff = try c.get(.powerOff, d.powerOff)
    }
}

extension Config.Pages {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        order = try c.get(.order, d.order)
        seconds = try c.get(.seconds, d.seconds)
        durations = try c.get(.durations, d.durations)
    }
}

extension Config.Clock {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        use24h = try c.get(.use24h, d.use24h)
        timeZone = try c.get(.timeZone, d.timeZone)
    }
}

extension Config.Weather {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = try c.get(.enabled, d.enabled)
        place = try c.get(.place, d.place)
        latitude = try c.get(.latitude, d.latitude)
        longitude = try c.get(.longitude, d.longitude)
        timeZone = try c.get(.timeZone, d.timeZone)
        fahrenheit = try c.get(.fahrenheit, d.fahrenheit)
    }
}

extension Config.Markets {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        symbols = try c.get(.symbols, d.symbols)
        perPage = try c.get(.perPage, d.perPage)
    }
}

extension Config.Agents {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        claude = try c.get(.claude, d.claude)
        stateDir = try c.get(.stateDir, d.stateDir)
        doneMinutes = try c.get(.doneMinutes, d.doneMinutes)
        maxIdleHours = try c.get(.maxIdleHours, d.maxIdleHours)
        jumpOnWaiting = try c.get(.jumpOnWaiting, d.jumpOnWaiting)
        jumpOnDone = try c.get(.jumpOnDone, d.jumpOnDone)
        holdSeconds = try c.get(.holdSeconds, d.holdSeconds)
    }
}

extension Config.Limits {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        claude = try c.get(.claude, d.claude)
        codex = try c.get(.codex, d.codex)
        alertBelow = try c.get(.alertBelow, d.alertBelow)
        jumpOnAlert = try c.get(.jumpOnAlert, d.jumpOnAlert)
    }
}

extension Config.Tokens {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        weeks = try c.get(.weeks, d.weeks)
        claude = try c.get(.claude, d.claude)
        codex = try c.get(.codex, d.codex)
        gemini = try c.get(.gemini, d.gemini)
        muse = try c.get(.muse, d.muse)
        history = try c.get(.history, d.history)
    }
}

extension Config.Dyson {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = try c.get(.enabled, d.enabled)
        credentials = try c.get(.credentials, d.credentials)
        host = try c.get(.host, d.host)
    }
}

extension Config.Telegram {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        channels = try c.get(.channels, d.channels)
        seconds = try c.get(.seconds, d.seconds)
        pollSeconds = try c.get(.pollSeconds, d.pollSeconds)
    }
}

extension Config.Stats {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.get(.enabled, Self().enabled)
    }
}

extension Config.Music {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        onClock = try c.get(.onClock, d.onClock)
        artwork = try c.get(.artwork, d.artwork)
        takeover = try c.get(.takeover, d.takeover)
        takeoverSeconds = try c.get(.takeoverSeconds, d.takeoverSeconds)
    }
}

extension Config.Photos {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        folder = try c.get(.folder, d.folder)
        album = try c.get(.album, d.album)
        shuffle = try c.get(.shuffle, d.shuffle)
        fill = try c.get(.fill, d.fill)
        clock = try c.get(.clock, d.clock)
    }
}

extension Config.Schedule {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        keepAwake = try c.get(.keepAwake, d.keepAwake)
        dim = try c.get(.dim, d.dim)
        dimBrightness = try c.get(.dimBrightness, d.dimBrightness)
        dayBrightness = try c.get(.dayBrightness, d.dayBrightness)
        idleMinutes = try c.get(.idleMinutes, d.idleMinutes)
        sleep = try c.get(.sleep, d.sleep)
    }
}

extension Config.Alerts {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        sound = try c.get(.sound, d.sound)
        card = try c.get(.card, d.card)
        waiting = try c.get(.waiting, d.waiting)
        done = try c.get(.done, d.done)
        limit = try c.get(.limit, d.limit)
        volume = try c.get(.volume, d.volume)
        notify = try c.get(.notify, d.notify)
        repeatSeconds = try c.get(.repeatSeconds, d.repeatSeconds)
        repeatMaxSeconds = try c.get(.repeatMaxSeconds, d.repeatMaxSeconds)
        quietAtNight = try c.get(.quietAtNight, d.quietAtNight)
    }
}

extension KeyedDecodingContainer {
    func get<T: Decodable>(_ key: Key, _ fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

/// A daily "HH:MM-HH:MM" window; wraps past midnight when the end is earlier than the start.
struct DailyWindow: Equatable, Sendable {
    let start: Int  // minutes after midnight
    let end: Int

    init?(_ text: String) {
        let parts = text.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let s = Self.minutes(parts[0]), let e = Self.minutes(parts[1]) else { return nil }
        start = s
        end = e
    }

    func contains(_ date: Date) -> Bool {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return start <= end ? (m >= start && m < end) : (m >= start || m < end)
    }

    private static func minutes(_ hhmm: String) -> Int? {
        let p = hhmm.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0...24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
}

/// Loads config.json and notices when it changes on disk, so edits apply without a restart.
@MainActor
final class ConfigStore {
    let path: String
    private var stamp: Date?

    init(path explicit: String?) {
        path = explicit.map { ($0 as NSString).expandingTildeInPath }
            ?? Paths.root.appendingPathComponent("config.json").path
    }

    /// Returns the config, or nil plus a readable error when the file exists but does not parse.
    func load() -> (config: Config?, error: String?) {
        stamp = Self.modified(path)
        guard FileManager.default.fileExists(atPath: path) else { return (Config(), nil) }
        do {
            let decoder = JSONDecoder()
            decoder.allowsJSON5 = true
            return (try decoder.decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: path))), nil)
        } catch let DecodingError.typeMismatch(_, ctx), let DecodingError.valueNotFound(_, ctx) {
            return (nil, "config.json \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)")
        } catch let DecodingError.dataCorrupted(ctx) {
            let detail = (ctx.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
            return (nil, "config.json: \(detail ?? ctx.debugDescription)")
        } catch {
            return (nil, "config.json: \(error.localizedDescription)")
        }
    }

    var changed: Bool { Self.modified(path) != stamp }

    /// The settings that differ from the defaults, as JSON: what `save` writes and `deskdash config` prints.
    /// Only whole fields are compared, so a list or map is always written complete.
    static func customized(_ config: Config) -> Data? {
        let encoder = JSONEncoder()
        guard let current = (try? JSONSerialization.jsonObject(with: encoder.encode(config))) as? [String: Any],
              let defaults = (try? JSONSerialization.jsonObject(with: encoder.encode(Config()))) as? [String: Any]
        else { return nil }
        var changed: [String: Any] = [:]
        for (section, value) in current {
            guard let fields = value as? [String: Any], let base = defaults[section] as? [String: Any] else { continue }
            let differing = fields.filter { !($0.value as AnyObject).isEqual(base[$0.key]) }
            if !differing.isEmpty { changed[section] = differing }
        }
        return try? JSONSerialization.data(withJSONObject: changed, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Writes config.json from the Settings window. Comments in a hand-edited file are not kept.
    func save(_ config: Config) {
        guard let body = Self.customized(config) else { return }
        let text = "// deskdash settings that differ from the defaults, written by the Settings window.\n"
            + "// Hand edits are fine too; config.example.json documents every key.\n"
            + String(decoding: body, as: UTF8.self) + "\n"
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            stamp = Self.modified(path)
        } catch {
            log("could not save \(path): \(error.localizedDescription)")
        }
    }

    private static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
