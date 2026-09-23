import SwiftUI

enum Page: Hashable, Sendable {
    case clock
    case music
    case climate
    case markets(Int)
    case agents
    case tokens

    var name: String {
        switch self {
        case .clock: "clock"
        case .music: "music"
        case .climate: "climate"
        case .markets: "markets"
        case .agents: "agents"
        case .tokens: "tokens"
        }
    }

    var fileName: String {
        if case .markets(let i) = self { return "markets-\(i + 1)" }
        return name
    }

    var title: String {
        switch self {
        case .clock: "Clock"
        case .music: "Now Playing"
        case .climate: "Climate"
        case .markets(let i): i == 0 ? "Markets" : "Markets \(i + 1)"
        case .agents: "Agents"
        case .tokens: "Tokens"
        }
    }
}

/// Everything the screen shows. Services write into it on the main actor; SwiftUI observes it.
@MainActor @Observable
final class Dashboard {
    var config: Config
    var configError: String?
    var now = Date()
    var weather: WeatherReading?
    var indoor: IndoorReading?
    var quotes: [String: Quote] = [:]
    var sparks: [String: [Double]] = [:]
    var marketsConnected = false
    var stats: SystemStats?
    /// What Music or Spotify is playing on this Mac; nil while nothing plays.
    private(set) var track: NowPlaying?
    var sessions: [AgentSession] = []
    /// Claude Code's and Codex's tokens by day; nil while the tokens page is off.
    var tokens: TokenHistory?
    /// The token heatmap's top row, as Calendar's weekday (1 is Sunday); nil follows this Mac's calendar.
    var weekStart: Int?
    var demo = false
    var paused = false
    private(set) var page = Page.clock
    private(set) var doneFlashUntil: Date?
    /// A Telegram post on screen right now, over whatever page is showing.
    private(set) var telegramPost: TelegramPost?
    /// A new track's takeover of the screen, when `music.takeover` is on.
    private(set) var trackFlashUntil: Date?

    @ObservationIgnored private var pageShownAt = Date()
    @ObservationIgnored private var holdUntil: Date?
    @ObservationIgnored private var telegramQueue: [TelegramPost] = []
    @ObservationIgnored private var telegramUntil: Date?
    @ObservationIgnored private var announcedTrack: String?

    init(config: Config) {
        self.config = config
    }

    // MARK: pages

    var pages: [Page] {
        var out: [Page] = []
        for name in config.pages.order {
            switch name {
            case "clock": out.append(.clock)
            case "music" where track != nil: out.append(.music)
            case "climate" where hasIndoor: out.append(.climate)
            case "markets": out += (0..<marketPageCount).map { Page.markets($0) }
            case "agents" where hasActiveAgents: out.append(.agents)
            case "tokens" where hasTokens: out.append(.tokens)
            default: break
            }
        }
        return out.isEmpty ? [.clock] : out
    }

    var marketPageCount: Int {
        let per = config.markets.pageSize
        return (config.markets.symbols.count + per - 1) / per
    }

    func symbols(onPage i: Int) -> [String] {
        let per = config.markets.pageSize
        return Array(config.markets.symbols.dropFirst(i * per).prefix(per))
    }

    func duration(of page: Page) -> TimeInterval {
        max(3, config.pages.durations[page.name] ?? config.pages.seconds)
    }

    /// Called once a second.
    func tick() {
        now = Date()
        if let until = doneFlashUntil, now >= until { doneFlashUntil = nil }
        if let until = telegramUntil, now >= until { showNextTelegram() }
        if let until = trackFlashUntil, now >= until { withAnimation(.easeInOut(duration: 0.3)) { trackFlashUntil = nil } }
        let list = pages
        guard list.contains(page) else { return show(list[0]) }
        guard !paused else { return }
        if let hold = holdUntil, now < hold { return }
        holdUntil = nil
        if now.timeIntervalSince(pageShownAt) >= duration(of: page) { advance(1) }
    }

    func advance(_ step: Int) {
        let list = pages
        let i = list.firstIndex(of: page) ?? 0
        show(list[((i + step) % list.count + list.count) % list.count])
    }

    func show(_ target: Page, hold: TimeInterval? = nil, animated: Bool = true) {
        if animated {
            withAnimation(.easeInOut(duration: 0.7)) { page = target }
        } else {
            page = target
        }
        pageShownAt = Date()
        holdUntil = hold.map { Date().addingTimeInterval($0) }
    }

    /// A purifier reading from the last 10 minutes; older than that, the clock falls back to the outdoor weather.
    var hasIndoor: Bool { indoor.map { now.timeIntervalSince($0.updated) < 600 } ?? false }

    // MARK: agents

    var visibleSessions: [AgentSession] {
        demo ? (AgentSession.demo(now: now) + sessions).sorted() : sessions
    }

    var hasActiveAgents: Bool { visibleSessions.contains { $0.state != .idle } }
    var anyWaiting: Bool { visibleSessions.contains { $0.state == .waiting } }
    var doneFlash: Bool { doneFlashUntil != nil }

    /// Alerts blink on the whole-second tick: bright on even seconds, dim on odd ones. Snapshots pin it on.
    var stillFrame = false
    var blinkOn: Bool { stillFrame || Int(now.timeIntervalSince1970) % 2 == 0 }

    enum AgentAlert { case waiting, done }

    func alert(_ kind: AgentAlert) {
        let cfg = config.agents
        switch kind {
        case .waiting:
            if cfg.jumpOnWaiting { show(.agents, hold: cfg.holdSeconds) }
        case .done:
            doneFlashUntil = Date().addingTimeInterval(6)
            if cfg.jumpOnDone && page != .agents { show(.agents, hold: min(10, cfg.holdSeconds)) }
        }
    }

    // MARK: tokens

    /// Any use in the heatmap's weeks.
    var hasTokens: Bool {
        let today = LocalDay.of(now)
        return tokens?.used(in: (today - config.tokens.span * 7)...today) ?? false
    }

    // MARK: telegram

    /// New posts each take the screen for `telegram.seconds`, in order. A burst keeps only the newest four, so a
    /// liquidation cascade cannot hold the screen for minutes.
    func notify(_ posts: [TelegramPost]) {
        telegramQueue += posts
        if telegramQueue.count > 4 { telegramQueue.removeFirst(telegramQueue.count - 4) }
        if telegramPost == nil { showNextTelegram() }
    }

    func clearTelegram() {
        telegramQueue.removeAll()
        showNextTelegram()
    }

    private func showNextTelegram() {
        let next = telegramQueue.isEmpty ? nil : telegramQueue.removeFirst()
        withAnimation(.easeInOut(duration: 0.3)) { telegramPost = next }
        telegramUntil = next.map { _ in Date().addingTimeInterval(max(1, config.telegram.seconds)) }
    }

    // MARK: music

    var trackFlash: Bool { trackFlashUntil != nil && track != nil }

    /// From NowPlayingService, on the tick. A new track takes the screen for `music.takeoverSeconds` if
    /// `music.takeover` is on; pausing and resuming the same track does not count as new. Snapshots don't announce.
    func play(_ next: NowPlaying?, announce: Bool = true) {
        if next != track { track = next }
        guard let next else {
            trackFlashUntil = nil
            return
        }
        guard next.id != announcedTrack else { return }
        announcedTrack = next.id
        if announce, config.music.takeover, page != .music {
            withAnimation(.easeInOut(duration: 0.3)) {
                trackFlashUntil = Date().addingTimeInterval(max(1, config.music.takeoverSeconds))
            }
        }
    }

    // MARK: schedule

    /// A level from a Settings brightness slider, shown instead of the schedule's while the slider moves.
    var brightnessPreview: Double?

    /// `dimBrightness` inside the night window (`schedule.dim`), `dayBrightness` outside it.
    var brightness: Double {
        let night = DailyWindow(config.schedule.dim)?.contains(now) ?? false
        let level = brightnessPreview ?? (night ? config.schedule.dimBrightness : config.schedule.dayBrightness)
        return min(1, max(0.05, level))
    }

    var keepAwakeNow: Bool {
        DailyWindow(config.schedule.keepAwake)?.contains(now) ?? false
    }
}
