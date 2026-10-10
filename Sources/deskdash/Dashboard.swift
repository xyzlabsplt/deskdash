import AppKit
import SwiftUI

enum Page: Hashable, Sendable {
    case clock
    case music
    case photos
    case climate
    case markets(Int)
    case agents
    case limits
    case tokens

    var name: String {
        switch self {
        case .clock: "clock"
        case .music: "music"
        case .photos: "photos"
        case .climate: "climate"
        case .markets: "markets"
        case .agents: "agents"
        case .limits: "limits"
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
        case .photos: "Photos"
        case .climate: "Climate"
        case .markets(let i): i == 0 ? "Markets" : "Markets \(i + 1)"
        case .agents: "Agents"
        case .limits: "Limits"
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
    /// Claude Code's and Codex's plan limits, as each last reported them.
    var limits: [AgentLimits] = []
    /// The picture the photos page shows next; nil without a photos folder.
    var photo: Photo?
    /// The Mac's sound is muted or all the way down while sounds are on: shown, since no chime would be heard.
    var soundSilent = false
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
    let chime = Chime()
    /// The alert card (`alerts.card`): drawn on the dashboard while it covers the dock screen, and otherwise floating
    /// over the windows on the dock screen (`callout`), until what it is for is over or someone clicks it away.
    private(set) var card: AlertCard?
    /// Whether the dashboard covers the dock screen, above everything there; set by AppDelegate's stacking.
    private(set) var covering = false
    @ObservationIgnored let callout = Callout()
    /// What the card is up for, so it leaves once that is over: nil for one that stays until dismissed.
    @ObservationIgnored private var cardFor: (kind: Chime.Kind, session: String?)?

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
            case "photos" where photo != nil: out.append(.photos)
            case "climate" where hasIndoor: out.append(.climate)
            case "markets": out += (0..<marketPageCount).map { Page.markets($0) }
            case "agents" where hasActiveAgents: out.append(.agents)
            case "limits" where hasLimits: out.append(.limits)
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
        if card != nil, !config.alerts.card || cardFor.map(stillOn) == false { dismissCard() }
        chime.tick(config.alerts, quiet: quietNow) { kind in
            switch kind {
            case .waiting: anyWaiting
            case .done, .limit: true  // until someone is back: a finished turn waits for you as well
            }
        }
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

    enum AgentAlert { case waiting, done, limit }

    func alert(_ kind: AgentAlert) {
        let cfg = config.agents
        switch kind {
        case .waiting:
            if cfg.jumpOnWaiting { show(.agents, hold: cfg.holdSeconds) }
            let s = visibleSessions.filter { $0.state == .waiting }.max { $0.since < $1.since }
            raise(.waiting, title: "\(s?.kind.title ?? "An agent") needs you",
                  body: s.map { [$0.name, $0.detail ?? "", $0.project].filter { !$0.isEmpty }.joined(separator: " · ") } ?? "",
                  session: s?.id)
        case .done:
            doneFlashUntil = Date().addingTimeInterval(6)
            if cfg.jumpOnDone && page != .agents { show(.agents, hold: min(10, cfg.holdSeconds)) }
            let s = visibleSessions.filter { $0.state == .done }.max { $0.since < $1.since }
            raise(.done, title: "\(s?.kind.title ?? "An agent") finished",
                  body: s.map { [$0.name, $0.project].filter { !$0.isEmpty }.joined(separator: " · ") } ?? "", session: s?.id)
        case .limit:
            if config.limits.jumpOnAlert && hasLimits { show(.limits, hold: cfg.holdSeconds) }
            let (title, body) = lowestLimit
            raise(.limit, title: title, body: body, session: nil)
        }
    }

    /// The sound, and the card unless one that outranks it is up.
    private func raise(_ kind: Chime.Kind, title: String, body: String, session: String?) {
        chime.ring(kind, config.alerts, quiet: quietNow, title: title, body: body)
        guard config.alerts.card else { return }
        if let current = card, current.kind > kind, cardFor.map(stillOn) ?? true { return }
        showCard(AlertCard(kind: kind, title: title, body: body), for: (kind, session))
    }

    struct AlertCard: Equatable {
        let kind: Chime.Kind
        let title: String
        let body: String
    }

    func showCard(_ next: AlertCard, for what: (kind: Chime.Kind, session: String?)?) {
        withAnimation(.easeInOut(duration: 0.3)) { card = next }
        cardFor = what
        placeCard()
    }

    /// A click on the dashboard, or the floating card's ×.
    func dismissCard() {
        withAnimation(.easeInOut(duration: 0.3)) { card = nil }
        cardFor = nil
        placeCard()
    }

    func setCovering(_ value: Bool) {
        guard value != covering else { return }
        covering = value
        placeCard()
    }

    /// On the dashboard while it covers the dock screen; floating at the dock screen's top right while windows are
    /// there and the dashboard stays behind them.
    private func placeCard() {
        let match = config.display.match.lowercased()
        if let card, !covering, !match.isEmpty,
           let screen = NSScreen.screens.first(where: { $0.localizedName.lowercased().contains(match) }) {
            callout.onClose = { [weak self] in self?.dismissCard() }
            callout.show(card.kind, title: card.title, body: card.body, on: screen)
        } else if callout.shown {
            callout.hide()
        }
    }

    /// Whether what a card is up for still holds: the session still waits; the finished one has not been picked up
    /// again (it stays DONE or goes IDLE); a limit is still low.
    private func stillOn(_ c: (kind: Chime.Kind, session: String?)) -> Bool {
        let session = c.session.flatMap { id in visibleSessions.first { $0.id == id } }
        switch c.kind {
        case .waiting: return c.session == nil ? anyWaiting : session?.state == .waiting
        case .done: return c.session == nil || session.map { $0.state == .done || $0.state == .idle } == true
        case .limit:
            let below = config.limits.alertBelow
            return visibleLimits.contains { [$0.session, $0.week].contains { $0.map { $0.left < below } == true } }
        }
    }

    /// `deskdash ctl chime KIND`: the sound once, and the card until it is closed, whatever the settings.
    func preview(_ kind: Chime.Kind) {
        let title = switch kind {
        case .waiting: "Claude Code needs you"
        case .done: "Codex finished"
        case .limit: "Claude 5-hour limit: 15% left"
        }
        chime.preview(kind, config.alerts, title: title, body: "A preview of deskdash's alert")
        showCard(AlertCard(kind: kind, title: title, body: "A preview of deskdash's alert"), for: nil)
    }

    /// The window with the least left, for the limit alert: "Claude 5-hour limit: 15% left".
    private var lowestLimit: (String, String) {
        var lowest: (AgentLimits, String, UsageWindow)?
        for l in visibleLimits {
            for (name, w) in [("5-hour", l.session), ("weekly", l.week)] {
                guard let w else { continue }
                if lowest == nil || w.left < lowest!.2.left { lowest = (l, name, w) }
            }
        }
        guard let (l, name, w) = lowest else { return ("A plan limit is running low", "") }
        let resets = w.resetsAt.map { "Resets in " + Fmt.duration($0.timeIntervalSince(now)) } ?? ""
        return ("\(l.kind.title) \(name) limit: \(Int(w.left.rounded()))% left", resets)
    }

    // MARK: limits

    var hasLimits: Bool { !limits.isEmpty }

    /// As of now: a window past its reset time shows as started over.
    var visibleLimits: [AgentLimits] { limits.map { $0.at(now) } }

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

    /// No sounds in the night window, when `alerts.quietAtNight` is on.
    var quietNow: Bool {
        config.alerts.quietAtNight && (DailyWindow(config.schedule.dim)?.contains(now) ?? false)
    }

    var keepAwakeNow: Bool {
        DailyWindow(config.schedule.keepAwake)?.contains(now) ?? false
    }
}
