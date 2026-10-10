import SwiftUI

/// Sized for a 5" panel read from across a desk: 1 pt on the 1280x720 canvas is about 0.09 mm, so body text
/// starts at ~60 pt and the clock is ~300 pt. Everything is drawn on a fixed canvas and scaled to the window.
enum Theme {
    static let canvas = CGSize(width: 1280, height: 720)

    static let text = Color(white: 0.96)
    static let secondary = Color(white: 0.62)
    static let faint = Color(white: 0.2)
    static let up = Color(red: 0.19, green: 0.84, blue: 0.35)
    static let down = Color(red: 1.0, green: 0.3, blue: 0.26)
    static let waiting = Color(red: 1.0, green: 0.7, blue: 0.0)
    static let working = Color(red: 0.26, green: 0.62, blue: 1.0)
    static let idle = Color(white: 0.4)
    static let humidity = Color(red: 0.45, green: 0.76, blue: 1.0)
    static let telegram = Color(red: 0.16, green: 0.67, blue: 0.93)
    static let blinkLow = 0.3  // an alert's "off" half-second, dimmed rather than gone

    /// Green below `fair`, amber below `poor`, red above: meaning from across the room.
    static func quality(_ value: Double?, fair: Double, poor: Double) -> Color {
        guard let value else { return faint }
        return value < fair ? up : value < poor ? waiting : down
    }

    static func font(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func color(_ state: AgentSession.State) -> Color {
        switch state {
        case .waiting: waiting
        case .working: working
        case .done: up
        case .idle: idle
        }
    }

    /// The token heatmap's five shades of green, as GitHub's: none, then dim to full.
    static func heat(_ level: Int) -> Color {
        switch level {
        case ..<1: Color.white.opacity(0.08)
        case 1: up.opacity(0.28)
        case 2: up.opacity(0.48)
        case 3: up.opacity(0.72)
        default: up
        }
    }

    static func color(_ pressure: SystemStats.Pressure) -> Color {
        switch pressure {
        case .normal: up
        case .warning: waiting
        case .critical: down
        }
    }

    static func color(_ thermal: ProcessInfo.ThermalState) -> Color {
        switch thermal {
        case .nominal: up
        case .fair: waiting
        default: down  // serious (fans at full speed) or critical (the chip slowed down to cool)
        }
    }
}

struct RootView: View {
    let dash: Dashboard

    var body: some View {
        GeometryReader { geo in
            Stage(dash: dash)
                .frame(width: Theme.canvas.width, height: Theme.canvas.height)
                .scaleEffect(min(geo.size.width / Theme.canvas.width, geo.size.height / Theme.canvas.height))
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black)
    }
}

/// The 1280x720 canvas: the current page plus the overlays every page shares.
struct Stage: View {
    let dash: Dashboard

    var body: some View {
        ZStack {
            Color.black
            PageView(dash: dash, page: dash.page)
                .id(dash.page)
                .transition(.opacity)
            if dash.trackFlash, let track = dash.track {  // a new track, over the page for a few seconds
                ZStack {
                    Color.black
                    NowPlayingPage(track: track, now: dash.now)
                }
                .id(track.id)
                .transition(.opacity)
            }
            if dash.page != .agents {
                AgentStrip(sessions: dash.visibleSessions.filter { $0.state != .idle }, blinkOn: dash.blinkOn)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            AttentionFrame(waiting: dash.anyWaiting, done: dash.doneFlash, blinkOn: dash.blinkOn)
            if dash.soundSilent {  // sounds are on, but the Mac is muted: no chime would be heard
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(Theme.waiting)
                    .padding(.top, 36)
                    .padding(.trailing, 44)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if let card = dash.card {
                AlertBanner(card: card)
                    .transition(.opacity)
            }
            if let post = dash.telegramPost {
                TelegramCard(post: post, use24h: dash.config.clock.use24h, zone: Fmt.zone(dash.config.clock.timeZone))
                    .id(post.id)
                    .transition(.opacity)
            }
            if let error = dash.configError {
                Text(error)
                    .font(Theme.font(26, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Theme.down.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                    .padding(22)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            if dash.brightness < 1 {
                Color.black.opacity(1 - dash.brightness).allowsHitTesting(false)
            }
        }
        .clipped()
    }
}

struct PageView: View {
    let dash: Dashboard
    let page: Page

    var body: some View {
        switch page {
        case .clock: ClockPage(dash: dash)
        case .music:
            if let track = dash.track { NowPlayingPage(track: track, now: dash.now) }
        case .photos: PhotoPage(dash: dash)
        case .climate: ClimatePage(dash: dash)
        case .markets(let i): MarketsPage(dash: dash, symbols: dash.symbols(onPage: i))
        case .agents: AgentsPage(sessions: dash.visibleSessions, now: dash.now, blinkOn: dash.blinkOn)
        case .limits: LimitsPage(dash: dash)
        case .tokens: TokensPage(dash: dash)
        }
    }
}

// MARK: clock

/// The time, the date with the indoor temperature and humidity, and along the bottom what is playing and the
/// Mac's load. The time and date sit centered in whatever room those two rows leave; with neither row, the time
/// grows back to 360 pt.
struct ClockPage: View {
    let dash: Dashboard

    var body: some View {
        let now = dash.now
        let use24h = dash.config.clock.use24h
        let zone = Fmt.zone(dash.config.clock.timeZone)
        let track = dash.config.music.onClock ? dash.track : nil
        let stats = dash.config.stats.enabled ? dash.stats : nil
        let size: CGFloat = track == nil && stats == nil ? 360 : 300
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: size / 25) {
                Text(Fmt.time(now, use24h: use24h, zone: zone))
                    .font(Theme.font(size, .bold))
                    .monospacedDigit()
                    .tracking(-size / 60)
                if !use24h {
                    Text(Fmt.meridiem(now, zone: zone))
                        .font(Theme.font(size * 76 / 360, .semibold))
                        .foregroundStyle(Theme.secondary)
                }
            }
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.top, -size / 9)
            .padding(.bottom, -size / 12)

            HStack(alignment: .center, spacing: 0) {
                Text(Fmt.date(now, zone: zone))
                    .foregroundStyle(Theme.text)
                if zone != .current {
                    Text("  " + Fmt.city(zone)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 40)
                if dash.hasIndoor, let indoor = dash.indoor {
                    IndoorBadge(reading: indoor, fahrenheit: dash.config.weather.fahrenheit)
                } else if dash.weather != nil || dash.config.weather.coordinates != nil {
                    WeatherBadge(reading: dash.weather)  // "– –" until the first reading, none without a place
                }
            }
            .font(Theme.font(80, .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 64)

            Spacer(minLength: 0)
            if let track {
                NowPlayingLine(track: track, now: now)
                    .padding(.horizontal, 64)
                    .padding(.bottom, stats == nil ? 0 : 26)
            }
            if let stats {
                StatsRow(stats: stats, fahrenheit: dash.config.weather.fahrenheit)
                    .padding(.horizontal, 64)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, track == nil && stats == nil ? 24 : 70)  // clear of the agent bars along the bottom edge
    }
}

/// The Mac's load along the bottom of the clock page, in the Climate page's segment bars laid on their side.
/// CPU turns amber at 70% and red at 90%, the SSD at 80% and 90%. Memory takes its color from macOS's memory
/// pressure rather than from how full it is, since macOS keeps memory full on purpose, and the temperature from
/// macOS's thermal pressure rather than from degrees, since Apple silicon runs its cores past 90 °C on purpose. Its
/// bar is a segment per 10 °C. Every column has a fixed width, so changing numbers never shift the row.
struct StatsRow: View {
    let stats: SystemStats
    let fahrenheit: Bool

    var body: some View {
        let cpu = stats.cpu.map { ($0 * 100).rounded() / 100 }  // the color follows the number shown
        let disk = stats.diskUsed.map { ($0 * 100).rounded() / 100 }
        HStack(alignment: .center, spacing: 0) {
            StatMeter(label: "CPU", value: cpu.map(Fmt.wholePercent), unit: "%", fraction: cpu,
                      color: Theme.quality(cpu, fair: 0.7, poor: 0.9))
            Spacer(minLength: 20)
            if let celsius = stats.temperature {
                StatMeter(label: "TEMP", value: Fmt.degrees(celsius, fahrenheit: fahrenheit), unit: "°",
                          fraction: celsius / 100, color: Theme.color(stats.thermal))
                Spacer(minLength: 20)
            }
            StatMeter(label: "RAM", value: Fmt.gigabytes(stats.memoryUsed), unit: "GB", fraction: stats.memory,
                      color: Theme.color(stats.pressure))
            Spacer(minLength: 20)
            StatMeter(label: "SSD", value: disk.map(Fmt.wholePercent), unit: "%", fraction: disk,
                      color: Theme.quality(disk, fair: 0.8, poor: 0.9))
            Spacer(minLength: 20)
            NetworkRates(download: stats.download, upload: stats.upload)
        }
    }
}

/// One meter in the stats row: its name, the value in its state color, and ten segments filled from the left.
struct StatMeter: View {
    let label: String
    let value: String?
    let unit: String
    let fraction: Double?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(label)
                    .font(Theme.font(28, .heavy))
                    .tracking(2)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize()
                Spacer(minLength: 8)
                Text(value ?? "–")
                    .font(Theme.font(46, .bold))
                    .monospacedDigit()
                    .foregroundStyle(value == nil ? Theme.faint : color)
                if value != nil {
                    Text(unit)
                        .font(Theme.font(30, .bold))
                        .foregroundStyle(color)
                        .padding(.leading, unit == "GB" ? 6 : 2)  // a word keeps a space, a sign hugs the number
                        .baselineOffset(unit == "°" ? 11 : 0)  // up to the digits' tops, where a degree sign sits
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)  // a rare wide value, such as 128 GB, shrinks a little rather than truncating
            SegmentBar(lit: lit, color: color, horizontal: true, segment: CGSize(width: 16, height: 26), spacing: 5,
                       corner: 4)
        }
        .frame(width: 205)
    }

    /// In proportion; anything above zero lights at least one segment.
    private var lit: Int {
        guard let f = fraction, f > 0 else { return 0 }
        return min(10, max(1, Int((f * 10).rounded())))
    }
}

/// Download over upload, in neutral text: traffic is information, not a warning.
struct NetworkRates: View {
    let download: Double?
    let upload: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            rate("arrow.down", download)
            rate("arrow.up", upload)
        }
        .frame(width: 230, alignment: .leading)
    }

    private func rate(_ symbol: String, _ value: Double?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(Theme.font(30, .heavy))
                .foregroundStyle(Theme.secondary)
            Text(value.map(Fmt.rate) ?? "–")
                .font(Theme.font(40, .semibold))
                .monospacedDigit()
                .foregroundStyle(value == nil ? Theme.faint : Theme.text)
        }
    }
}

// MARK: now playing

/// While music plays, one line on the clock page: the cover, "Title — Artist", and a thin progress bar.
struct NowPlayingLine: View {
    let track: NowPlaying
    let now: Date

    var body: some View {
        HStack(spacing: 24) {
            Artwork(image: track.artwork, size: 72, corner: 12)
            VStack(alignment: .leading, spacing: 12) {
                Group {
                    if track.artist.isEmpty {
                        Text(track.title)
                    } else {
                        Text("\(Text(track.title))\(Text("  —  \(track.artist)").foregroundStyle(Theme.secondary))")
                    }
                }
                .font(Theme.font(44, .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                if let progress = track.progress(at: now) {
                    ProgressBar(fraction: progress).frame(height: 8)
                }
            }
        }
    }
}

/// While music plays: the cover large on the left; title, artist, album and the playhead on the right. Also the
/// few seconds' takeover on a new track, when `music.takeover` is on.
struct NowPlayingPage: View {
    let track: NowPlaying
    let now: Date

    var body: some View {
        HStack(alignment: .center, spacing: 56) {
            Artwork(image: track.artwork, size: 520, corner: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text(track.player.name.uppercased())
                    .font(Theme.font(28, .heavy))
                    .tracking(2)
                    .foregroundStyle(Theme.idle)
                    .padding(.bottom, 12)
                Text(track.title)
                    .font(Theme.font(80, .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.55)
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(Theme.font(56, .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.top, 8)
                }
                if !track.album.isEmpty {
                    Text(track.album)
                        .font(Theme.font(40, .semibold))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.top, 8)
                }
                Spacer(minLength: 20)
                if let progress = track.progress(at: now), let length = track.duration {
                    ProgressBar(fraction: progress).frame(height: 12)
                    HStack {
                        Text(Fmt.playtime(track.elapsed(at: now)))
                        Spacer()
                        Text(Fmt.playtime(length))
                    }
                    .font(Theme.font(38, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondary)
                    .padding(.top, 14)
                }
            }
            .frame(height: 520)
        }
        .padding(.horizontal, 64)
        .padding(.bottom, 60)  // clear of the agent bars along the bottom edge
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// A track's cover, or a quiet note until it arrives (or when there is none).
struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        ZStack {
            Color.white.opacity(0.08)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// The part played in near-white on a faint track. It moves once a second, with the clock.
struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Color.white.opacity(0.14))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Theme.text.opacity(0.9))
                        .frame(width: max(geo.size.height, geo.size.width * min(1, max(0, fraction))))
                }
        }
    }
}

struct WeatherBadge: View {
    let reading: WeatherReading?

    var body: some View {
        if let r = reading {
            HStack(spacing: 14) {
                Image(systemName: r.symbol)
                    .symbolRenderingMode(.multicolor)
                Text("\(Int(r.temperature.rounded()))°")
                    .foregroundStyle(Theme.text)
                    .padding(.trailing, 22)
                Image(systemName: "drop.fill")
                    .foregroundStyle(Theme.humidity)
                Text("\(Int(r.humidity.rounded()))%")
                    .foregroundStyle(Theme.text)
            }
            .monospacedDigit()
        } else {
            Text("– –").foregroundStyle(Theme.faint)
        }
    }
}

/// The purifier's temperature and humidity, in the clock page's weather spot, with the same icons as the
/// climate page.
struct IndoorBadge: View {
    let reading: IndoorReading
    let fahrenheit: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "thermometer.medium")
                .foregroundStyle(Theme.secondary)
            Text(reading.temperature.map { Fmt.temperature($0, fahrenheit: fahrenheit, decimals: 0) } ?? "–")
                .padding(.trailing, 26)
            Image(systemName: "drop.fill")
                .foregroundStyle(Theme.humidity)
            Text(reading.humidity.map { "\(Int($0.rounded()))%" } ?? "–")
        }
        .foregroundStyle(Theme.text)
        .monospacedDigit()
    }
}

// MARK: climate

/// Indoor air from the Dyson purifier, laid out like Dyson's own display. Temperature and humidity sit
/// beside their icons; each pollutant gets a 10-segment level bar filled in its state color; the outdoor weather
/// goes in the corner.
struct ClimatePage: View {
    let dash: Dashboard

    var body: some View {
        let r = dash.indoor
        let fahrenheit = dash.config.weather.fahrenheit
        VStack(spacing: 24) {
            HStack(alignment: .center, spacing: 0) {
                IconStat(symbol: "thermometer.medium", tint: Theme.secondary,
                         value: r?.temperature.map { Fmt.temperature($0, fahrenheit: fahrenheit, decimals: 1) })
                Spacer(minLength: 30)
                IconStat(symbol: "drop.fill", tint: Theme.humidity, value: r?.humidity.map { "\(Int($0.rounded()))%" })
                Spacer(minLength: 30)
                if let w = dash.weather {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("OUTSIDE").font(Theme.font(26, .heavy)).tracking(2)
                        HStack(spacing: 10) {
                            Image(systemName: w.symbol).symbolRenderingMode(.multicolor)
                            Text("\(Int(w.temperature.rounded()))°  \(Int(w.humidity.rounded()))%").monospacedDigit()
                        }
                        .font(Theme.font(48, .semibold))
                    }
                    .foregroundStyle(Theme.secondary)
                }
            }
            if r?.sensorsOff == true {
                Text("Sensors are off: turn on Continuous Monitoring in the Dyson app")
                    .font(Theme.font(38, .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxHeight: .infinity)
            } else {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(AirMeter.all(r)) { meter in
                        MeterView(meter: meter).frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 54, style: .continuous).fill(Color.white.opacity(0.07)))
            }
        }
        .padding(.horizontal, 48)
        .padding(.top, 30)
        .padding(.bottom, 62)  // clear of the agent bars along the bottom edge
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// An icon beside its number, the way Dyson's display shows temperature and humidity.
struct IconStat: View {
    let symbol: String
    let tint: Color
    let value: String?

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(Theme.font(90, .regular))
                .foregroundStyle(tint)
            Text(value ?? "–")
                .font(Theme.font(124, .semibold))
                .foregroundStyle(value == nil ? Theme.faint : Theme.text)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
}

/// One pollutant: its reading and where that sits on its scale.
struct AirMeter: Identifiable {
    let label: String
    let value: Double?
    let text: String?
    let floor: Double, fair: Double, poor: Double, top: Double
    var id: String { label }

    var color: Color { Theme.quality(value, fair: fair, poor: poor) }

    /// Segments 1-3 are the good band, 4-6 fair, 7-10 poor, and a value fills its band in proportion, so a
    /// bar's height and its color always agree. Any reading above the floor lights at least one segment.
    var segments: Int {
        guard let v = value, v > floor else { return 0 }
        func fill(_ from: Double, _ to: Double, _ base: Int, _ count: Int) -> Int {
            base + min(count, max(1, Int(((v - from) / (to - from) * Double(count)).rounded(.up))))
        }
        if v < fair { return fill(floor, fair, 0, 3) }
        if v < poor { return fill(fair, poor, 3, 3) }
        return fill(poor, top, 6, 4)
    }

    /// Bands: CO₂ under 800 ppm is fresh and over 1200 stuffy (outdoor air is about 420). PM2.5 uses the
    /// US EPA's 12 and 35 µg/m³, PM10 50 and 100. VOC and NO₂ use Dyson's 0-10 index (4 fair, 7 poor).
    /// Formaldehyde uses WHO's 0.1 mg/m³.
    static func all(_ r: IndoorReading?) -> [AirMeter] {
        var meters = [
            AirMeter(label: "CO₂", value: r?.co2, text: r?.co2.map { "\(Int($0))" },
                     floor: 400, fair: 800, poor: 1200, top: 2000),
            AirMeter(label: "PM2.5", value: r?.pm25, text: r?.pm25.map { "\(Int($0))" },
                     floor: 0, fair: 12, poor: 35, top: 75),
            AirMeter(label: "PM10", value: r?.pm10, text: r?.pm10.map { "\(Int($0))" },
                     floor: 0, fair: 50, poor: 100, top: 200),
            AirMeter(label: "VOC", value: r?.voc, text: r?.voc.map { String(format: "%.1f", $0) },
                     floor: 0, fair: 4, poor: 7, top: 10),
            AirMeter(label: "NO₂", value: r?.no2, text: r?.no2.map { String(format: "%.1f", $0) },
                     floor: 0, fair: 4, poor: 7, top: 10),
        ]
        if let hcho = r?.hcho {
            meters.append(AirMeter(label: "HCHO", value: hcho, text: String(format: "%.2f", hcho),
                                   floor: 0, fair: 0.05, poor: 0.1, top: 0.2))
        }
        return meters
    }
}

/// The value in its state color, a 10-segment bar filled from the bottom, and the pollutant's name.
struct MeterView: View {
    let meter: AirMeter

    var body: some View {
        VStack(spacing: 14) {
            Text(meter.text ?? "–")
                .font(Theme.font(56, .bold))
                .monospacedDigit()
                .foregroundStyle(meter.text == nil ? Theme.faint : meter.color)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            SegmentBar(lit: meter.segments, color: meter.color)
            Text(meter.label)
                .font(Theme.font(32, .heavy))
                .foregroundStyle(Theme.secondary)
        }
    }
}

/// Ten level segments, the lit ones in the state color and the rest outlined: upright and filled from the bottom
/// on the Climate page, on their side and filled from the left in the clock page's stats row.
struct SegmentBar: View {
    let lit: Int
    let color: Color
    var horizontal = false
    var segment = CGSize(width: 74, height: 19)
    var spacing: CGFloat = 7
    var corner: CGFloat = 5

    var body: some View {
        if horizontal {
            HStack(spacing: spacing) { ForEach(0..<10, id: \.self) { cell($0) } }
        } else {
            VStack(spacing: spacing) { ForEach((0..<10).reversed(), id: \.self) { cell($0) } }
        }
    }

    private func cell(_ index: Int) -> some View {
        let on = index < lit
        return RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(on ? color : Color.white.opacity(0.08))
            .overlay {
                if !on {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 2)
                }
            }
            .frame(width: segment.width, height: segment.height)
    }
}

// MARK: telegram

/// A new channel post, over the whole screen for a few seconds: the channel, the time, and the text as large
/// as it fits, inside a Telegram-blue frame that says where it came from even when the text is too far to read.
struct TelegramCard: View {
    let post: TelegramPost
    let use24h: Bool
    let zone: TimeZone

    var body: some View {
        ZStack {
            Color.black
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 18) {
                    Image(systemName: "paperplane.fill")
                        .foregroundStyle(Theme.telegram)
                    Text(post.title)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 20)
                    if let date = post.date {
                        Text(Fmt.time(date, use24h: use24h, zone: zone))
                            .foregroundStyle(Theme.secondary)
                            .monospacedDigit()
                    }
                }
                .font(Theme.font(46, .bold))
                // Starts large and shrinks to fit: a one-line alert fills the card, a long post still fits.
                Text(post.text)
                    .font(Theme.font(104, .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(6)
                    .minimumScaleFactor(0.4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 64)
            .padding(.vertical, 54)
            Rectangle()
                .strokeBorder(Theme.telegram, lineWidth: 18)
        }
    }
}

// MARK: markets

/// One to five tickers (`markets.perPage`) share the canvas above the agent bars; each row sizes itself to its share.
struct MarketsPage: View {
    let dash: Dashboard
    let symbols: [String]

    var body: some View {
        let rows = CGFloat(max(1, symbols.count))
        let height = (Theme.canvas.height - 92 - 2 * (rows - 1)) / rows  // 208 pt for three rows
        VStack(spacing: 0) {
            ForEach(Array(symbols.enumerated()), id: \.element) { index, symbol in
                if index > 0 {
                    Rectangle().fill(Theme.faint).frame(height: 2).padding(.horizontal, 48)
                }
                TickerRow(symbol: symbol, quote: dash.quotes[symbol], spark: dash.sparks[symbol] ?? [],
                          stale: !dash.marketsConnected || dash.quotes[symbol].map { dash.now.timeIntervalSince($0.updated) > 60 } ?? true,
                          height: height)
                    .frame(height: height)
            }
        }
        .padding(.top, 30)
        .padding(.bottom, 62)  // clear of the agent bars along the bottom edge
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Symbol, price, and 24 h change over the 24 h sparkline. The sizes below are for three rows a page. Four or five
/// rows shrink them by the square root of the row height, so five rows still show 93 pt prices. One or two rows are
/// too tall for a single line to use: the symbol and change go on top, over a price up to 280 pt.
struct TickerRow: View {
    let symbol: String
    let quote: Quote?
    let spark: [Double]
    let stale: Bool
    let height: CGFloat

    var body: some View {
        let change = quote?.change ?? 0
        let color = change >= 0 ? Theme.up : Theme.down
        let price = quote.map { Fmt.price($0.price) } ?? "–"
        let percent = quote.map { Fmt.percent($0.change) } ?? ""
        ZStack {
            Sparkline(values: spark + (quote.map { [$0.price] } ?? []), color: color)
                .padding(.vertical, height * 0.14)
                .padding(.horizontal, 48)
            Group {
                if height > 260 {
                    let top = min(100, height * 0.23)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(symbol)
                                .font(Theme.font(top, .heavy))
                                .foregroundStyle(Theme.text)
                            Spacer(minLength: 40)
                            Text(percent)
                                .font(Theme.font(top, .bold))
                                .foregroundStyle(color)
                        }
                        Text(price)
                            .font(Theme.font(min(280, height * 0.58), .bold))
                            .foregroundStyle(Theme.text)
                    }
                } else {
                    let s = min(1, (height / 208).squareRoot())
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(symbol)
                            .font(Theme.font(78 * s, .heavy))
                            .foregroundStyle(Theme.text)
                            .frame(width: 290 * s, alignment: .leading)
                        Text(price)
                            .font(Theme.font(120 * s, .bold))
                            .foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(percent)
                            .font(Theme.font(62 * s, .bold))
                            .foregroundStyle(color)
                            .frame(width: 290 * s, alignment: .trailing)
                    }
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 60)
            .opacity(stale ? 0.4 : 1)
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1, let lo = values.min(), let hi = values.max() else { return }
            let span = max(hi - lo, abs(hi) * 1e-6, 1e-12)
            func point(_ i: Int) -> CGPoint {
                CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                        y: size.height * (1 - CGFloat((values[i] - lo) / span)))
            }
            var line = Path()
            line.move(to: point(0))
            for i in 1..<values.count { line.addLine(to: point(i)) }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.22), color.opacity(0)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(color.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: agents

struct AgentsPage: View {
    let sessions: [AgentSession]
    let now: Date
    let blinkOn: Bool

    var body: some View {
        let shown = Array(sessions.prefix(4))
        VStack(alignment: .leading, spacing: 20) {
            ForEach(shown) { AgentRow(session: $0, now: now, blinkOn: blinkOn) }
            if sessions.count > shown.count {
                Text("+\(sessions.count - shown.count) more")
                    .font(Theme.font(38, .semibold))
                    .foregroundStyle(Theme.secondary)
                    .padding(.leading, 44)
            }
        }
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct AgentRow: View {
    let session: AgentSession
    let now: Date
    let blinkOn: Bool

    var body: some View {
        let color = Theme.color(session.state)
        // Most useful first, since the line truncates: what it waits for beats which project it is.
        let waiting = session.state == .waiting
        let facts = [Fmt.duration(now.timeIntervalSince(session.since)),
                     waiting ? session.detail : nil, session.project, waiting ? nil : session.detail]
            .compactMap { $0 }.filter { !$0.isEmpty && $0 != session.name }
        HStack(spacing: 28) {
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(waiting && !blinkOn ? Theme.blinkLow : 1))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.name)
                    .font(Theme.font(60, .bold))
                    .foregroundStyle(session.state == .idle ? Theme.secondary : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 0) {
                    Text(session.state.label).foregroundStyle(color).fontWeight(.heavy)
                    Text("  " + facts.joined(separator: " · ")).foregroundStyle(Theme.secondary)
                }
                .font(Theme.font(40, .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Text(session.kind == .other ? "" : session.kind.rawValue.uppercased())
                .font(Theme.font(28, .heavy))
                .foregroundStyle(Theme.faint)
                .tracking(2)
        }
        .frame(height: 128)
    }
}

/// Small bars along the bottom of every other page: one per active session, colored by state.
/// They sit clear of the 26 px attention frame.
struct AgentStrip: View {
    let sessions: [AgentSession]
    let blinkOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            ForEach(sessions.prefix(12)) { s in
                Capsule()
                    .fill(Theme.color(s.state).opacity(s.state == .waiting && !blinkOn ? Theme.blinkLow : 1))
                    .frame(width: 72, height: 12)
            }
        }
        .padding(.bottom, 36)
    }
}

/// An amber frame that blinks while any session needs you; a green one for a few seconds when one finishes.
/// 26 px is about 2 mm on the 5" panel, enough to catch from the chair in peripheral vision. Blinking steps
/// once a second with the clock instead of animating: a smooth pulse cost 2-5% of a core, in the app or in
/// the window server, for as long as it ran.
struct AttentionFrame: View {
    let waiting: Bool
    let done: Bool
    let blinkOn: Bool

    var body: some View {
        let strength = blinkOn ? 1 : Theme.blinkLow
        if waiting {
            Rectangle().strokeBorder(Theme.waiting.opacity(strength), lineWidth: 26)
        } else if done {
            Rectangle().strokeBorder(Theme.up.opacity(strength), lineWidth: 18)
        }
    }
}

// MARK: photos

/// A picture from `photos.folder`: whole, over a blurred copy of itself, or cropped to fill (`photos.fill`), with the
/// time and date in the corner, clear of the agent bars.
struct PhotoPage: View {
    let dash: Dashboard

    private static let month: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM yyyy"
        return f
    }()

    var body: some View {
        let size = Theme.canvas
        ZStack(alignment: .bottomLeading) {
            if let photo = dash.photo {
                if let backdrop = photo.backdrop {
                    Image(decorative: backdrop, scale: 1).resizable().scaledToFill()
                        .frame(width: size.width, height: size.height).clipped()
                    Image(decorative: photo.image, scale: 1).resizable().interpolation(.high).scaledToFit()
                        .frame(width: size.width, height: size.height)
                } else {
                    Image(decorative: photo.image, scale: 1).resizable().interpolation(.high).scaledToFill()
                        .frame(width: size.width, height: size.height).clipped()
                }
                if dash.config.photos.clock {
                    let zone = Fmt.zone(dash.config.clock.timeZone)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Fmt.time(dash.now, use24h: dash.config.clock.use24h, zone: zone))
                            .font(Theme.font(120, .bold))
                            .monospacedDigit()
                        Text(Fmt.date(dash.now, zone: zone)
                             + (photo.taken.map { "   " + Self.month.string(from: $0) } ?? ""))
                            .font(Theme.font(44, .semibold))
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.75), radius: 14)
                    .padding(.leading, 56)
                    .padding(.bottom, 70)  // clear of the agent bars along the bottom edge
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: alert card

/// The alert card on the dock screen (`alerts.card`): what needs you, large enough to read from the chair, over the page
/// until it is over or someone clicks the dashboard.
struct AlertBanner: View {
    let card: Dashboard.AlertCard

    var body: some View {
        let color: Color = switch card.kind {
        case .waiting: Theme.waiting
        case .done: Theme.up
        case .limit: Theme.down
        }
        ZStack {
            Color.black.opacity(0.6)
            HStack(alignment: .top, spacing: 30) {
                RoundedRectangle(cornerRadius: 8).fill(color).frame(width: 16)
                VStack(alignment: .leading, spacing: 10) {
                    Text(card.title)
                        .font(Theme.font(68, .bold))
                        .foregroundStyle(Theme.text)
                        .minimumScaleFactor(0.6)
                    if !card.body.isEmpty {
                        Text(card.body)
                            .font(Theme.font(42, .semibold))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                    }
                    TokenCaption(text: L10n.t("CLICK TO DISMISS"))
                        .padding(.top, 8)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(40)
            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 30))
            .overlay(RoundedRectangle(cornerRadius: 30).strokeBorder(color, lineWidth: 5))
            .padding(.horizontal, 60)
            .padding(.bottom, 40)
        }
    }
}

// MARK: limits

/// Each agent's plan limits side by side: what is left of the 5-hour window large, the week under it. Each bar has a
/// white tick where an even pace would leave it, so a bar reaching past its tick has room to spare. Amber means it
/// runs out before it resets at the pace so far, or is nearly gone; red, almost nothing is left.
struct LimitsPage: View {
    let dash: Dashboard

    var body: some View {
        HStack(alignment: .top, spacing: 72) {
            let shown = dash.visibleLimits.prefix(2)
            ForEach(shown) {
                LimitsColumn(limits: $0, now: dash.now, use24h: dash.config.clock.use24h, solo: shown.count == 1)
            }
        }
        .padding(.horizontal, 56)
        .padding(.top, 34)
        .padding(.bottom, 74)  // clear of the agent bars along the bottom edge
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LimitsColumn: View {
    let limits: AgentLimits
    let now: Date
    let use24h: Bool
    var solo = false  // the only column: the figures grow into the room

    var body: some View {
        let age = now.timeIntervalSince(limits.updated)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                TokenCaption(text: limits.kind.rawValue.uppercased() + (limits.plan.map { "  " + $0.uppercased() } ?? ""))
                Spacer(minLength: 16)
                if age > 1800 {  // an old report: the agent has not been used since
                    TokenCaption(text: Fmt.duration(age).uppercased() + " AGO")
                }
            }
            // The first window large, the second under it. A plan with one window (Codex Pro has only the week)
            // shows that one large, in the middle of the column.
            let windows = [("LEFT  5H", limits.session), ("LEFT  WEEK", limits.week)].compactMap { c, w in w.map { (c, $0) } }
            let first: CGFloat = solo ? 200 : 150
            if windows.count == 1 { Spacer(minLength: 0) }
            ForEach(Array(windows.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Spacer(minLength: 18)
                    Rectangle().fill(Theme.faint).frame(height: 2)
                    Spacer(minLength: 6)
                }
                LimitFigure(window: item.1, now: now, caption: item.0, size: index == 0 ? first : 110)
                    .padding(.top, index == 0 ? -first / 9 : 0)
                    .padding(.bottom, index == 0 ? -4 : 0)
                LimitBar(window: item.1, now: now)
                    .frame(height: 22)
                    .padding(.top, index == 0 ? 0 : 4)
                LimitNote(window: item.1, now: now, use24h: use24h)
                    .padding(.top, 14)
            }
            if windows.count == 1 { Spacer(minLength: 40) }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@MainActor
enum LimitStyle {
    /// Green with room to spare, amber when it runs out before the reset or is under 20% left, red under 10%.
    static func color(_ w: UsageWindow, _ now: Date) -> Color {
        if w.left < 10 { return Theme.down }
        if w.left < 20 || w.runsOut(now) != nil { return Theme.waiting }
        return Theme.up
    }

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE"
        return f
    }()

    /// "1h 42m" within a day, otherwise the weekday and time: "FRI 14:00".
    static func when(_ date: Date, now: Date, use24h: Bool) -> String {
        let wait = date.timeIntervalSince(now)
        if wait < 86400 { return "IN " + Fmt.duration(wait).uppercased() }
        let time = Fmt.time(date, use24h: use24h) + (use24h ? "" : " " + Fmt.meridiem(date))
        return weekday.string(from: date).uppercased() + " " + time
    }
}

/// What is left as a large percentage, white while there is room and in the alert color when not.
struct LimitFigure: View {
    let window: UsageWindow
    let now: Date
    let caption: String
    let size: CGFloat

    var body: some View {
        let color = LimitStyle.color(window, now)
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text("\(Int(window.left.rounded()))%")
                .font(Theme.font(size, .bold))
                .monospacedDigit()
                .foregroundStyle(color == Theme.up ? Theme.text : color)
            TokenCaption(text: caption)
        }
    }
}

/// What is left, as a bar in the alert colors, with a tick where an even pace would leave it.
struct LimitBar: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                if window.left > 0 {
                    Capsule()
                        .fill(LimitStyle.color(window, now))
                        .frame(width: max(geo.size.height, width * window.left / 100))
                }
                if let elapsed = window.elapsed(now) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.text)
                        .frame(width: 6, height: geo.size.height + 18)
                        .offset(x: min(width - 6, max(0, width * (1 - elapsed) - 3)))
                }
            }
        }
    }
}

/// When it runs out at this pace, in the alert color, or else when it resets.
struct LimitNote: View {
    let window: UsageWindow
    let now: Date
    let use24h: Bool

    var body: some View {
        Group {
            if let out = window.runsOut(now) {
                Text("RUNS OUT " + LimitStyle.when(out, now: now, use24h: use24h))
                    .foregroundStyle(LimitStyle.color(window, now))
            } else if let resets = window.resetsAt {
                Text("RESETS " + LimitStyle.when(resets, now: now, use24h: use24h))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .font(Theme.font(40, .semibold))
        .minimumScaleFactor(0.7)
    }
}

// MARK: tokens

/// The tokens the coding agents used on this Mac: today's count large, with the agents' shares under it; the last 7 and
/// 30 days, all time, and the streak of days with any use beside it; and underneath, the last `tokens.weeks` weeks as a
/// GitHub-style heatmap, a column per week, brighter green for busier days.
struct TokensPage: View {
    let dash: Dashboard

    var body: some View {
        let history = dash.tokens ?? TokenHistory()
        let today = LocalDay.of(dash.now)
        let weeks = dash.config.tokens.span
        let day = history.on(today)
        let window = history.sum((today - weeks * 7)...today)
        // The agents used in these weeks, most used first: three fit.
        let agents = TokenAgent.allCases.filter { window[$0].total > 0 }.sorted { window[$0].total > window[$1].total }
        let streak = history.streak(through: today)
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    TokenCaption(text: "TODAY")
                    Text(Fmt.tokens(day.total))
                        .font(Theme.font(150, .bold))
                        .monospacedDigit()
                        .foregroundStyle(day.total > 0 ? Theme.text : Theme.faint)
                        .padding(.top, -14)
                        .padding(.bottom, -6)
                    TokenShares(day: day, agents: Array(agents.prefix(3)))
                }
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 0) {
                    TokenStat(label: "7 DAYS", count: history.sum((today - 6)...today).total, size: 56)
                    TokenStat(label: "30 DAYS", count: history.sum((today - 29)...today).total, size: 56)
                    TokenStat(label: "ALL TIME", count: history.allTime, size: 56)
                    TokenStat(label: "STREAK", value: streak == 1 ? "1 day" : "\(streak) days", size: 56)
                }
                .fixedSize()
            }
            .lineLimit(1)
            TokenHeatmap(history: history, today: today, weeks: weeks,
                         firstWeekday: dash.weekStart ?? Calendar.current.firstWeekday)
                .padding(.top, 16)
        }
        .padding(.horizontal, 56)
        .padding(.top, 30)
        .padding(.bottom, 62)  // clear of the agent bars along the bottom edge
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A caption in the other pages' style ("OUTSIDE", "CPU").
struct TokenCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.font(28, .heavy))
            .tracking(2)
            .foregroundStyle(Theme.secondary)
    }
}

/// Each agent's tokens today, as one line of captions and numbers that shrinks to fit the room beside the stats.
struct TokenShares: View {
    let day: DayTokens
    let agents: [TokenAgent]

    var body: some View {
        agents.enumerated().reduce(Text("")) { line, item in
            let (index, agent) = item
            let count = day[agent].total
            return line + Text(index == 0 ? "" : "   ").font(Theme.font(46, .bold))
                + Text(agent.label + "  ").font(Theme.font(28, .heavy)).tracking(2).foregroundStyle(Theme.secondary)
                + Text(Fmt.tokens(count)).font(Theme.font(46, .bold)).foregroundStyle(count > 0 ? Theme.text : Theme.faint)
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// A caption beside its number, faint while it is zero.
struct TokenStat: View {
    let label: String
    let value: String
    let size: CGFloat
    var zero = false

    init(label: String, value: String, size: CGFloat) {
        self.label = label
        self.value = value
        self.size = size
    }

    init(label: String, count: Int, size: CGFloat) {
        self.init(label: label, value: Fmt.tokens(count), size: size)
        zero = count == 0
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            TokenCaption(text: label)
            Text(value)
                .font(Theme.font(size, .bold))
                .monospacedDigit()
                .foregroundStyle(zero ? Theme.faint : Theme.text)
        }
    }
}

/// A column per week, oldest on the left, each starting on the calendar's first weekday, and a month's name over the
/// column where it begins. Days after today are left out, and today is outlined. The shades are GitHub's five: none,
/// then the quarters of the days with any use, by rank, so one huge day does not leave every other in the dimmest.
/// It fills the width, or else the height, centered; either way flush with the bottom.
struct TokenHeatmap: View {
    let history: TokenHistory
    let today: Int
    let weeks: Int
    let firstWeekday: Int  // Calendar's: 1 is Sunday

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    var body: some View {
        Canvas { ctx, size in
            let first = today - (LocalDay.weekday(today) - (firstWeekday - 1) + 7) % 7 - (weeks - 1) * 7
            let ranked = (first...today).map { history.on($0).total }.filter { $0 > 0 }.sorted()
            func level(_ total: Int) -> Int {
                guard total > 0, !ranked.isEmpty else { return 0 }
                var (lo, hi) = (0, ranked.count)  // how many days used at most this much
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if ranked[mid] <= total { lo = mid + 1 } else { hi = mid }
                }
                return min(4, max(1, Int((4 * Double(lo) / Double(ranked.count)).rounded(.up))))
            }

            let labels: CGFloat = 42  // the month names' row
            let gap: CGFloat = 0.18  // of a column's pitch
            let pitch = min(size.width / (CGFloat(weeks) - gap), (size.height - labels) / (7 - gap))
            let cell = pitch * (1 - gap)
            let left = (size.width - pitch * (CGFloat(weeks) - gap)) / 2
            let top = size.height - pitch * (7 - gap)

            var starts = (0..<weeks).filter { $0 == 0 || LocalDay.civil(first + $0 * 7).month != LocalDay.civil(first + $0 * 7 - 7).month }
            if starts.count > 1, starts[1] < 3 { starts.removeFirst() }  // no room for the first column's month
            for week in starts {
                let name = Self.months[LocalDay.civil(first + week * 7).month - 1]
                ctx.draw(Text(name).font(Theme.font(26, .semibold)).foregroundStyle(Theme.secondary),
                         at: CGPoint(x: left + CGFloat(week) * pitch, y: top - 10), anchor: .bottomLeading)
            }
            for week in 0..<weeks {
                for row in 0..<7 {
                    let day = first + week * 7 + row
                    guard day <= today else { break }
                    let rect = CGRect(x: left + CGFloat(week) * pitch, y: top + CGFloat(row) * pitch, width: cell, height: cell)
                    let shape = RoundedRectangle(cornerRadius: cell * 0.2, style: .continuous).path(in: rect)
                    ctx.fill(shape, with: .color(Theme.heat(level(history.on(day).total))))
                    if day == today {
                        ctx.stroke(shape.strokedPath(StrokeStyle(lineWidth: 3)), with: .color(Theme.text))
                    }
                }
            }
        }
    }
}

// MARK: formatting

@MainActor
enum Fmt {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE d MMM"
        return f
    }()

    /// The clock's zone: an IANA identifier from config, or this Mac's.
    static func zone(_ identifier: String) -> TimeZone {
        identifier.isEmpty ? .current : TimeZone(identifier: identifier) ?? .current
    }

    /// "Europe/London" → "London", for the clock page when it shows another zone.
    static func city(_ zone: TimeZone) -> String {
        (zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier).replacingOccurrences(of: "_", with: " ")
    }

    private static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar.current
        calendar.timeZone = zone
        return calendar
    }

    static func time(_ date: Date, use24h: Bool, zone: TimeZone = .current) -> String {
        let c = calendar(zone).dateComponents([.hour, .minute], from: date)
        let (h, m) = (c.hour ?? 0, c.minute ?? 0)
        if use24h { return String(format: "%02d:%02d", h, m) }
        return String(format: "%d:%02d", h % 12 == 0 ? 12 : h % 12, m)
    }

    static func meridiem(_ date: Date, zone: TimeZone = .current) -> String {
        calendar(zone).component(.hour, from: date) < 12 ? "AM" : "PM"
    }

    static func date(_ date: Date, zone: TimeZone = .current) -> String {
        dateFormatter.timeZone = zone
        return dateFormatter.string(from: date)
    }

    static func temperature(_ celsius: Double, fahrenheit: Bool, decimals: Int) -> String {
        degrees(celsius, fahrenheit: fahrenheit, decimals: decimals) + "°"
    }

    /// The number alone, for a meter that draws its ° smaller.
    static func degrees(_ celsius: Double, fahrenheit: Bool, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f", fahrenheit ? celsius * 9 / 5 + 32 : celsius)
    }

    /// About five significant digits: 86,276 · 2,743.9 · 118.19 · 97.01 · 0.2165
    static func price(_ p: Double) -> String {
        let a = abs(p)
        let decimals = a >= 10_000 ? 0 : a >= 1_000 ? 1 : a >= 10 ? 2 : a >= 1 ? 3 : a >= 0.01 ? 4 : 6
        return p.formatted(.number.precision(.fractionLength(decimals)).locale(Locale(identifier: "en_US")))
    }

    static func percent(_ x: Double) -> String {
        let v = x * 100
        return (v < 0 ? "\u{2212}" : "+") + String(format: "%.2f%%", abs(v))
    }

    /// 0.37 → "37", for a meter that draws its % smaller.
    static func wholePercent(_ x: Double) -> String {
        "\(Int((x * 100).rounded()))"
    }

    /// Memory in GB the way Activity Monitor counts it (2^30 bytes), without the unit: "13"
    static func gigabytes(_ bytes: Double) -> String {
        "\(Int((bytes / 1_073_741_824).rounded()))"
    }

    /// Network speed in bytes a second: 812 B/s · 340 KB/s · 1.2 MB/s · 48 MB/s
    static func rate(_ bytesPerSecond: Double) -> String {
        let v = max(0, bytesPerSecond)
        switch v {
        case ..<999.5: return "\(Int(v.rounded())) B/s"
        case ..<999_500: return "\(Int((v / 1e3).rounded())) KB/s"
        case ..<9_950_000: return String(format: "%.1f MB/s", v / 1e6)
        case ..<999_500_000: return "\(Int((v / 1e6).rounded())) MB/s"
        default: return String(format: "%.1f GB/s", v / 1e9)
        }
    }

    /// A token count to three figures: 950 · 8.41K · 297K · 4.83M · 236M · 1.24B
    static func tokens(_ count: Int) -> String {
        var value = Double(max(0, count))
        guard value >= 999.5 else { return "\(Int(value.rounded()))" }
        let units = ["K", "M", "B", "T"]
        var unit = -1
        repeat {
            value /= 1000
            unit += 1
        } while value >= 999.5 && unit < units.count - 1
        return String(format: "%.\(value < 9.995 ? 2 : value < 99.95 ? 1 : 0)f", value) + units[unit]
    }

    /// A playhead or a track's length: 3:07, or 1:02:45 past an hour.
    static func playtime(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        switch s {
        case ..<60: return "\(s)s"
        case ..<3600: return "\(s / 60)m"
        case ..<86400:
            let (h, m) = (s / 3600, s % 3600 / 60)
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        default: return "\(s / 86400)d"
        }
    }
}
