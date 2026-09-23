import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, weather, markets, telegram, agents, purifier
}

/// The Settings window's state. It is an @Observable class, not @State: in this SDK @State is a SwiftUI macro,
/// and the Command Line Tools ship no SwiftUI macro plugin (the Observation macros are in the toolchain).
/// Every change to `draft` goes through `update`, which hands it to `commit` to apply and save.
@MainActor @Observable
final class SettingsModel {
    private(set) var draft: Config
    var tab: SettingsTab
    var query = ""
    var places: [Place] = []
    var weatherStatus = ""
    var newSymbol = ""
    var marketsStatus = ""
    var newChannel = ""
    var telegramStatus = ""
    var titles: [String: String] = [:]
    var host: String
    let purifier: PurifierSetup

    @ObservationIgnored let dash: Dashboard
    @ObservationIgnored let screens: [String]
    @ObservationIgnored private let commit: (Config) -> Void
    @ObservationIgnored let previewTelegram: (String) -> Void
    @ObservationIgnored private var dragging = false
    @ObservationIgnored private var previewEnd: Task<Void, Never>?

    /// `purifierChanged` runs after a purifier is connected or forgotten, so the dashboard reconnects at once.
    init(config: Config, tab: SettingsTab, dash: Dashboard, screens: [String], commit: @escaping (Config) -> Void,
         previewTelegram: @escaping (String) -> Void, purifierChanged: @escaping () -> Void) {
        draft = config
        self.tab = tab
        self.dash = dash
        self.screens = screens
        self.commit = commit
        self.previewTelegram = previewTelegram
        host = config.dyson.host
        purifier = PurifierSetup(config: config.dyson, changed: purifierChanged)
    }

    func update(_ change: (inout Config) -> Void) {
        var next = draft
        change(&next)
        guard next != draft else { return }
        draft = next
        commit(next)
    }

    /// A binding to one setting.
    func setting<T>(_ path: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(get: { self.draft[keyPath: path] }, set: { value in self.update { $0[keyPath: path] = value } })
    }

    /// A binding to the window's own state (search text and so on).
    func field<T>(_ path: ReferenceWritableKeyPath<SettingsModel, T>) -> Binding<T> {
        Binding(get: { self[keyPath: path] }, set: { self[keyPath: path] = $0 })
    }

    /// The dock screen shows a brightness slider's level while it moves, whatever the time of day, and the
    /// schedule's again 1.5 s after the last change. A drag (`dragging`) holds the preview until it is let go.
    func previewBrightness(_ level: Double, dragging: Bool? = nil) {
        if let dragging { self.dragging = dragging }
        previewEnd?.cancel()
        if dash.brightnessPreview != level { dash.brightnessPreview = level }
        guard !self.dragging else { return }
        previewEnd = Task { [dash] in
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { dash.brightnessPreview = nil }
        }
    }
}

/// The Settings window, from the menu bar icon or the dashboard's right-click menu. Every change applies at once
/// and is saved to config.json (only what differs from the defaults), which stays hand-editable.
struct SettingsView: View {
    let model: SettingsModel

    var body: some View {
        TabView(selection: model.field(\.tab)) {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            WeatherSettings(model: model)
                .tabItem { Label("Weather & Time", systemImage: "cloud.sun") }
                .tag(SettingsTab.weather)
            MarketsSettings(model: model)
                .tabItem { Label("Markets", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(SettingsTab.markets)
            TelegramSettings(model: model)
                .tabItem { Label("Telegram", systemImage: "paperplane") }
                .tag(SettingsTab.telegram)
            AgentsSettings(model: model)
                .tabItem { Label("Agents", systemImage: "sparkles") }
                .tag(SettingsTab.agents)
            PurifierSettings(model: model)
                .tabItem { Label("Purifier", systemImage: "wind") }
                .tag(SettingsTab.purifier)
        }
        .padding(16)
        .frame(width: 640, height: 560)
    }
}

/// The Settings window is a non-activating panel, so it comes to the front with the keyboard whether or not deskdash
/// becomes the active app. Since macOS 14 `NSApp.activate()` is only a request, which the system may refuse an
/// accessory app (`ctl settings`, typed in Terminal, has no click in deskdash behind it at all), and a plain window of
/// an inactive app opens behind the active app's windows, without the keyboard. A `.nonactivatingPanel` can be the key
/// window while another app stays active. It sits at the normal level, so other windows still cover it like any window.
final class SettingsPanel: NSPanel {
    /// deskdash has no main menu, which is where the standard editing shortcuts live, so they are handled here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let action: Selector? = switch (event.modifierFlags.intersection([.command, .shift, .option, .control]),
                                        event.charactersIgnoringModifiers?.lowercased() ?? "") {
        case (.command, "x"): #selector(NSText.cut(_:))
        case (.command, "c"): #selector(NSText.copy(_:))
        case (.command, "v"): #selector(NSText.paste(_:))
        case (.command, "a"): #selector(NSText.selectAll(_:))
        case (.command, "z"): Selector(("undo:"))
        case ([.command, .shift], "z"): Selector(("redo:"))
        case (.command, "w"): #selector(NSWindow.performClose(_:))
        default: nil
        }
        return action.map { NSApp.sendAction($0, to: nil, from: self) } ?? false
    }
}

// MARK: General

private struct GeneralSettings: View {
    let model: SettingsModel
    private struct PageOption: Identifiable {
        let id: String
        let title: String
    }
    private static let pages = [PageOption(id: "clock", title: "Clock"),
                                PageOption(id: "music", title: "Now Playing (while Music or Spotify plays)"),
                                PageOption(id: "climate", title: "Climate (from the purifier)"),
                                PageOption(id: "markets", title: "Markets"), PageOption(id: "agents", title: "Agents")]

    var body: some View {
        let draft = model.draft
        Form {
            Section("Dock screen") {
                Picker("Show the dashboard on", selection: model.setting(\.display.match)) {
                    ForEach(screenChoices, id: \.self) { Text($0).tag($0) }
                }
            }
            Section("Pages") {
                ForEach(Self.pages) { page in
                    Toggle(page.title, isOn: pageShown(page.id))
                }
                StepSlider(title: "Each page stays", value: model.setting(\.pages.seconds), steps: StepSlider.pageSeconds)
                StepSlider(title: "The clock stays", value: clockSeconds, steps: StepSlider.pageSeconds)
            }
            Section("Clock") {
                Toggle("24-hour clock", isOn: model.setting(\.clock.use24h))
                Toggle("CPU, memory, SSD and network along the bottom", isOn: model.setting(\.stats.enabled))
                Toggle("What's playing in Music or Spotify", isOn: model.setting(\.music.onClock))
                LabeledContent("Time zone") {
                    HStack {
                        Text(draft.clock.timeZone.isEmpty ? "This Mac's (\(TimeZone.current.identifier))" : draft.clock.timeZone)
                        if !draft.clock.timeZone.isEmpty {
                            Button("Use this Mac's") { model.update { $0.clock.timeZone = "" } }
                        }
                    }
                }
                Text("To show another place's time, choose the place under Weather & Time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Now playing") {
                Toggle("Show each new track full screen", isOn: model.setting(\.music.takeover))
                if draft.music.takeover {
                    StepSlider(title: "Shows for", value: model.setting(\.music.takeoverSeconds),
                               steps: [2, 3, 4, 5, 6, 8, 10, 12, 15])
                }
                Toggle("Look up covers (Spotify, Apple's iTunes Search)", isOn: model.setting(\.music.artwork))
                Text("Music and Spotify on this Mac announce each track themselves; nothing needs a permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Schedule") {
                Toggle("Keep the displays awake", isOn: windowOn(\.keepAwake, fallback: "08:00-23:00"))
                if !draft.schedule.keepAwake.isEmpty {
                    WindowPicker(text: model.setting(\.schedule.keepAwake))
                }
            }
            Section("Brightness") {
                brightness(draft.schedule.dim.isEmpty ? "All day" : "Daytime", \.dayBrightness)
                Toggle("Dim the dashboard at night", isOn: windowOn(\.dim, fallback: "23:00-08:00"))
                if !draft.schedule.dim.isEmpty {
                    WindowPicker(text: model.setting(\.schedule.dim))
                    brightness("At night", \.dimBrightness)
                }
                Text("While you drag a slider, the dock screen shows that level.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Previews on the dock screen as it moves, even the night level in the daytime (see `previewBrightness`).
    private func brightness(_ title: String, _ path: WritableKeyPath<Config.Schedule, Double>) -> some View {
        let level = Binding(get: { model.draft.schedule[keyPath: path] },
                            set: { value in
                                model.update { $0.schedule[keyPath: path] = value }
                                model.previewBrightness(value)
                            })
        return StepSlider(title: title, value: level, steps: (2...20).map { Double($0) / 20 },
                          format: { "\(Int(($0 * 100).rounded()))%" },
                          onEditingChanged: { model.previewBrightness(level.wrappedValue, dragging: $0) })
    }

    private var screenChoices: [String] {
        let match = model.draft.display.match
        return model.screens.contains(match) ? model.screens : [match] + model.screens
    }

    /// Pages keep their usual order; a toggle only adds or removes one.
    private func pageShown(_ name: String) -> Binding<Bool> {
        Binding(
            get: { model.draft.pages.order.contains(name) },
            set: { on in
                model.update { config in
                    let kept = Set(config.pages.order.filter { $0 != name } + (on ? [name] : []))
                    config.pages.order = Self.pages.map(\.id).filter(kept.contains)
                }
            })
    }

    private var clockSeconds: Binding<Double> {
        Binding(get: { model.draft.pages.durations["clock"] ?? model.draft.pages.seconds },
                set: { value in model.update { $0.pages.durations["clock"] = value } })
    }

    private func windowOn(_ path: WritableKeyPath<Config.Schedule, String>, fallback: String) -> Binding<Bool> {
        Binding(get: { !model.draft.schedule[keyPath: path].isEmpty },
                set: { on in model.update { $0.schedule[keyPath: path] = on ? fallback : "" } })
    }
}

/// Edits a daily "HH:MM-HH:MM" window as two time pickers.
private struct WindowPicker: View {
    @Binding var text: String

    var body: some View {
        HStack {
            DatePicker("From", selection: part(0), displayedComponents: .hourAndMinute)
            DatePicker("to", selection: part(1), displayedComponents: .hourAndMinute)
        }
    }

    private func part(_ index: Int) -> Binding<Date> {
        Binding(
            get: {
                let parts = text.split(separator: "-").map(String.init)
                return Self.date(parts.count == 2 ? parts[index] : "00:00")
            },
            set: { date in
                var parts = text.split(separator: "-").map(String.init)
                if parts.count != 2 { parts = ["00:00", "00:00"] }
                parts[index] = Self.text(date)
                text = parts.joined(separator: "-")
            })
    }

    private static func date(_ hhmm: String) -> Date {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: min(p.first ?? 0, 23), minute: p.count > 1 ? p[1] : 0,
                                     second: 0, of: Date()) ?? Date()
    }

    private static func text(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

// MARK: Weather & Time

private struct WeatherSettings: View {
    let model: SettingsModel

    var body: some View {
        let draft = model.draft
        Form {
            Section("Location") {
                if let latitude = draft.weather.latitude, let longitude = draft.weather.longitude {
                    LabeledContent("Showing", value: draft.weather.place.isEmpty ? "A place without a name" : draft.weather.place)
                    LabeledContent("Coordinates", value: String(format: "%.3f, %.3f", latitude, longitude))
                } else {
                    LabeledContent("Showing", value: "No place yet: find your city below")
                }
                InputRow(title: "Find a city", prompt: "City name, like Lisbon", text: model.field(\.query),
                         action: "Search", run: search)
                if !model.weatherStatus.isEmpty {
                    Text(model.weatherStatus).foregroundStyle(.secondary)
                }
                ForEach(model.places) { place in
                    Button { choose(place) } label: {
                        HStack {
                            Text(place.title)
                            Spacer()
                            Text(place.timezone ?? "").foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle("The clock shows this place's time", isOn: clockFollows)
                    .disabled(draft.weather.timeZone.isEmpty)
            }
            Section("Weather") {
                Toggle("Show outdoor weather", isOn: model.setting(\.weather.enabled))
                Toggle("Fahrenheit", isOn: model.setting(\.weather.fahrenheit))
            }
        }
        .formStyle(.grouped)
    }

    private var clockFollows: Binding<Bool> {
        Binding(get: { !model.draft.weather.timeZone.isEmpty && model.draft.clock.timeZone == model.draft.weather.timeZone },
                set: { on in model.update { $0.clock.timeZone = on ? $0.weather.timeZone : "" } })
    }

    private func search() {
        let name = model.query.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.weatherStatus = "Searching…"
        Task {
            let found = await Place.search(name)
            model.places = found ?? []
            model.weatherStatus = found == nil ? "Could not reach Open-Meteo's place search."
                : model.places.isEmpty ? "No place called “\(name)”." : ""
        }
    }

    private func choose(_ place: Place) {
        let following = clockFollows.wrappedValue
        model.update { config in
            config.weather.place = place.title
            config.weather.latitude = place.latitude
            config.weather.longitude = place.longitude
            config.weather.timeZone = place.timezone ?? ""
            if following { config.clock.timeZone = config.weather.timeZone }
        }
        model.places = []
        model.query = ""
        model.weatherStatus = "Now showing \(place.title)."
    }
}

/// A search result from Open-Meteo's geocoding API (free, no key).
struct Place: Identifiable, Decodable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double
    let admin1: String?
    let country: String?
    let timezone: String?

    /// "Tokyo, Japan", not "Tokyo, Tokyo, Japan".
    var title: String {
        var parts: [String] = []
        for part in [name, admin1, country].compactMap({ $0 }) where !part.isEmpty && !parts.contains(part) {
            parts.append(part)
        }
        return parts.joined(separator: ", ")
    }

    static func search(_ name: String) async -> [Place]? {
        struct Response: Decodable { let results: [Place]? }
        var url = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        url.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "count", value: "8"),
                          URLQueryItem(name: "language", value: "en"), URLQueryItem(name: "format", value: "json")]
        guard let (data, _) = try? await URLSession.shared.data(from: url.url!),
              let response = try? JSONDecoder().decode(Response.self, from: data)
        else { return nil }
        return response.results ?? []
    }
}

// MARK: Markets

private struct MarketsSettings: View {
    let model: SettingsModel

    var body: some View {
        let symbols = model.draft.markets.symbols
        Form {
            Section("Hyperliquid perps, in order") {
                ForEach(symbols, id: \.self) { symbol in
                    HStack {
                        Text(symbol).font(.body.monospaced())
                        Spacer()
                        Button { move(symbol, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(symbol == symbols.first)
                        Button { move(symbol, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(symbol == symbols.last)
                        Button { model.update { $0.markets.symbols.removeAll { $0 == symbol } } } label: {
                            Image(systemName: "minus.circle")
                        }
                    }
                    .buttonStyle(.borderless)
                }
                InputRow(title: "Add a symbol", prompt: "Its Hyperliquid name, like SOL", text: model.field(\.newSymbol),
                         action: "Add", run: add)
                if !model.marketsStatus.isEmpty {
                    Text(model.marketsStatus).foregroundStyle(.secondary)
                }
            }
            Section {
                StepSlider(title: "Tickers per page", value: perPage, steps: [1, 2, 3, 4, 5], format: { "\(Int($0))" })
                Text("Up to five fit on the dock screen, sized to fill it. More symbols make more pages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var perPage: Binding<Double> {
        Binding(get: { Double(model.draft.markets.pageSize) },
                set: { count in model.update { $0.markets.perPage = Int(count) } })
    }

    private func move(_ symbol: String, by step: Int) {
        model.update { config in
            guard let i = config.markets.symbols.firstIndex(of: symbol),
                  config.markets.symbols.indices.contains(i + step)
            else { return }
            config.markets.symbols.swapAt(i, i + step)
        }
    }

    /// Checked against Hyperliquid's list, and stored with its exact spelling (kPEPE, not KPEPE).
    private func add() {
        let typed = model.newSymbol.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        model.marketsStatus = "Checking \(typed) on Hyperliquid…"
        Task {
            guard let listed = await MarketsService.listedSymbols() else {
                model.marketsStatus = "Could not reach Hyperliquid."
                return
            }
            guard let name = listed.first(where: { $0.caseInsensitiveCompare(typed) == .orderedSame }) else {
                model.marketsStatus = "Hyperliquid has no perp called \(typed)."
                return
            }
            model.update { if !$0.markets.symbols.contains(name) { $0.markets.symbols.append(name) } }
            model.newSymbol = ""
            model.marketsStatus = "Added \(name)."
        }
    }
}

// MARK: Telegram

private struct TelegramSettings: View {
    let model: SettingsModel

    var body: some View {
        let draft = model.draft
        Form {
            Section("Public channels") {
                ForEach(draft.telegram.channels, id: \.self) { channel in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.titles[channel] ?? channel)
                            Text("t.me/\(channel)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Preview") { model.previewTelegram(channel) }
                        Button { model.update { $0.telegram.channels.removeAll { $0 == channel } } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                InputRow(title: "Add a channel", prompt: "t.me link or @name", text: model.field(\.newChannel),
                         action: "Add", run: add)
                if !model.telegramStatus.isEmpty {
                    Text(model.telegramStatus).foregroundStyle(.secondary)
                }
            }
            Section("New posts") {
                StepSlider(title: "Each one shows for", value: model.setting(\.telegram.seconds),
                           steps: [2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 30, 45, 60])
                StepSlider(title: "Check for them every", value: model.setting(\.telegram.pollSeconds),
                           steps: [10, 15, 20, 30, 45, 60, 90, 120, 180, 300, 600])
            }
            Text("Public channels only: deskdash reads Telegram's public preview page, without an account. "
                + "Preview shows a channel's newest post on the dock screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .task {
            for channel in model.draft.telegram.channels where model.titles[channel] == nil {
                model.titles[channel] = await TelegramService.latest(channel)?.title
            }
        }
    }

    /// Checked by reading the channel's public preview, which also gives its display name.
    private func add() {
        guard let name = TelegramService.username(model.newChannel.trimmingCharacters(in: .whitespaces)) else {
            model.telegramStatus = "That is not a channel link or name."
            return
        }
        guard !model.draft.telegram.channels.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            model.telegramStatus = "Already watching t.me/\(name)."
            return
        }
        model.telegramStatus = "Checking t.me/\(name)…"
        Task {
            guard let post = await TelegramService.latest(name) else {
                model.telegramStatus = "t.me/\(name) has no public preview. Only public channels work."
                return
            }
            model.titles[name] = post.title
            model.update { $0.telegram.channels.append(name) }
            model.newChannel = ""
            model.telegramStatus = "Added \(post.title)."
        }
    }
}

// MARK: Agents

private struct AgentsSettings: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section("Sessions") {
                Toggle("Show Claude Code sessions", isOn: model.setting(\.agents.claude))
                StepSlider(title: "A finished session shows DONE for", value: model.setting(\.agents.doneMinutes),
                           steps: [1, 2, 3, 5, 10, 15, 20, 30, 45, 60, 90, 120], format: { "\(Int($0)) min" })
                StepSlider(title: "Hide idle sessions after", value: model.setting(\.agents.maxIdleHours),
                           steps: [1, 2, 3, 4, 6, 8, 12, 18, 24, 36, 48, 72], format: { "\(Int($0)) h" })
            }
            Section("Alerts") {
                Toggle("Jump to the agents page when a session needs you", isOn: model.setting(\.agents.jumpOnWaiting))
                Toggle("…and briefly when one finishes", isOn: model.setting(\.agents.jumpOnDone))
                StepSlider(title: "Hold the agents page for", value: model.setting(\.agents.holdSeconds),
                           steps: [5, 10, 15, 20, 30, 45, 60, 90, 120])
            }
            Section("Codex") {
                Text("Codex sessions appear once deskdash's hook is installed. Run this in Terminal:")
                    .foregroundStyle(.secondary)
                CommandRow(command: Self.installHook)
                Text("Then type /hooks in Codex to trust it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// The script's full path, quoted for the shell if it needs it.
    private static let installHook: String = {
        let path = Paths.root.appendingPathComponent("scripts/install-codex-hooks.sh").path
        let plain = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+@%".contains($0) }
        return plain ? path : "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }()
}

// MARK: Purifier

/// Connecting the purifier from Settings: the steps of `deskdash dyson setup`, with the secrets typed into the window
/// instead of a terminal. A password is cleared as soon as it has been used, and never saved or logged; only the
/// purifier's local credential is saved, in the credentials file (secrets/dyson.json).
@MainActor @Observable
final class PurifierSetup {
    enum Method: Hashable { case sticker, account }

    var method = Method.sticker
    /// The purifier in the credentials file.
    var saved: DysonCredentials?
    /// Showing the steps to connect a purifier while one is already saved.
    var changing = false
    var confirmForget = false
    /// Purifiers that answered on this network, and the one picked by serial: "" types the sticker's Wi-Fi name.
    var found: [DysonCredentials] = []
    var target = ""
    var ssid = ""
    var stickerPassword = ""
    var country = DysonSetup.defaultCountry
    var email = ""
    /// Set once Dyson has emailed a code, which `code` and `accountPassword` then answer.
    var challenge: String?
    var code = ""
    var accountPassword = ""
    /// The account's devices, when none of them answered on this network to pick it by.
    var choices: [DysonCredentials] = []
    var chosen = ""
    var busy = false
    var message = ""
    var failed = false

    @ObservationIgnored private let changed: () -> Void
    @ObservationIgnored private var searched = false

    init(config: Config.Dyson, changed: @escaping () -> Void) {
        self.changed = changed
        saved = DysonCredentials.load(from: Paths.resolve(config.credentials))
    }

    /// When the tab opens: one look for purifiers on this network (Bonjour, 4 s).
    func search() async {
        guard !searched else { return }
        searched = true
        found = await DysonSetup.discover()
        if target.isEmpty, ssid.isEmpty { target = found.first?.serial ?? "" }
    }

    /// Who the sticker's password is for: the purifier picked from the network, or the one its Wi-Fi name names.
    var stickerDevice: DysonCredentials? {
        found.first { $0.serial == target } ?? DysonSetup.device(ssid: ssid)
    }

    func connectWithSticker(_ cfg: Config.Dyson) {
        guard !busy, !stickerPassword.isEmpty else { return }
        guard var device = stickerDevice else {
            return report("That is not a Dyson Wi-Fi name. It looks like DYSON-XXX-XX-XXXXXXXX-664.", failed: true)
        }
        device.credential = DysonSetup.credential(stickerPassword: stickerPassword)
        stickerPassword = ""
        Task { await finish(device, cfg) }
    }

    func requestCode() {
        let email = email.trimmingCharacters(in: .whitespaces)
        let country = country.trimmingCharacters(in: .whitespaces).uppercased()
        guard !busy else { return }
        guard DysonSetup.isEmail(email) else {
            return report("Type the whole email address you sign in to the Dyson app with.", failed: true)
        }
        busy = true
        report("Asking Dyson to email a code…")
        Task {
            do {
                challenge = try await DysonSetup.requestCode(email: email,
                                                             country: country.isEmpty ? DysonSetup.defaultCountry : country)
                code = ""
                report("Dyson has emailed a one-time code to \(email).")
            } catch {
                report("\(error)", failed: true)
            }
            busy = false
        }
    }

    func signIn(_ cfg: Config.Dyson) {
        guard !busy, let challenge, !code.isEmpty, !accountPassword.isEmpty else { return }
        let password = accountPassword
        accountPassword = ""
        busy = true
        report("Signing in to Dyson…")
        Task {
            do {
                let token = try await DysonSetup.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password,
                                                        challenge: challenge, code: code.trimmingCharacters(in: .whitespaces))
                let devices = try await DysonSetup.accountDevices(token: token)
                self.challenge = nil
                code = ""
                busy = false
                if let device = DysonSetup.match(devices, found: found) ?? (devices.count == 1 ? devices[0] : nil) {
                    await finish(device, cfg)
                } else {
                    choices = devices
                    chosen = devices[0].serial
                    report("None of the account's \(devices.count) devices answered on this network. Choose the purifier.")
                }
            } catch {
                busy = false
                report("\(error)", failed: true)
            }
        }
    }

    func connectChosen(_ cfg: Config.Dyson) {
        guard !busy, let device = choices.first(where: { $0.serial == chosen }) else { return }
        choices = []
        Task { await finish(device, cfg) }
    }

    func startOver() {
        challenge = nil
        code = ""
        accountPassword = ""
        choices = []
        report("")
    }

    func forget(_ cfg: Config.Dyson) {
        confirmForget = false
        let file = Paths.resolve(cfg.credentials)
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                return report("Could not delete \(file.path): \(error.localizedDescription)", failed: true)
            }
        }
        saved = nil
        changing = false
        report("Forgot the purifier. Its password is deleted from this Mac.")
        changed()
    }

    /// Proves the password by reading the sensors once, then saves it, as `deskdash dyson setup` does.
    private func finish(_ device: DysonCredentials, _ cfg: Config.Dyson) async {
        busy = true
        report("Trying the password with \(device.name). This can take up to 30 s…")
        let result = await DysonSetup.testAndSave(device, host: cfg.host, to: Paths.resolve(cfg.credentials))
        busy = false
        report(result.message, failed: !result.saved)
        guard result.saved else { return }
        saved = device
        changing = false
        changed()
    }

    private func report(_ text: String, failed: Bool = false) {
        message = text
        self.failed = failed
    }
}

private struct PurifierSettings: View {
    let model: SettingsModel

    var body: some View {
        let setup = model.purifier
        Form {
            Section("Dyson purifier") {
                Toggle("Read the purifier's sensors", isOn: model.setting(\.dyson.enabled))
                LabeledContent("Status", value: status)
                LabeledContent("Purifier") {
                    if let device = setup.saved {
                        HStack(spacing: 8) {
                            Text("\(device.name) · \(device.serial)")
                            if setup.confirmForget {
                                Button("Cancel") { setup.confirmForget = false }
                                Button("Forget", role: .destructive) { setup.forget(model.draft.dyson) }
                            } else {
                                if !setup.changing {
                                    Button("Change…") { setup.changing = true }
                                }
                                Button("Forget…") { setup.confirmForget = true }
                            }
                        }
                    } else {
                        Text("None yet")
                    }
                }
                if setup.confirmForget {
                    Text("Forgetting deletes the purifier's password from this Mac. Connecting it again takes the sticker "
                        + "or your Dyson account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if setup.saved == nil || setup.changing {
                Section(setup.saved == nil ? "Connect the purifier" : "Connect another purifier") {
                    Picker("Its password from", selection: model.field(\.purifier.method)) {
                        Text("The Wi-Fi sticker").tag(PurifierSetup.Method.sticker)
                        Text("Your Dyson account").tag(PurifierSetup.Method.account)
                    }
                    .pickerStyle(.segmented)
                    if setup.method == .sticker {
                        sticker(setup)
                    } else {
                        account(setup)
                    }
                }
            }
            if !setup.message.isEmpty {
                Section {
                    Text(setup.message)
                        .foregroundStyle(setup.failed ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                }
            }
            Section("Network") {
                InputRow(title: "Address", prompt: "Found automatically", text: model.field(\.host),
                         action: "Apply", ready: model.host.trimmingCharacters(in: .whitespaces) != model.draft.dyson.host,
                         run: applyHost)
                Text("Leave the address blank unless the purifier cannot be found: then type its IP address or host[:port].")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await setup.search() }
    }

    /// The password printed on the purifier's Wi-Fi sticker, for the purifier found on the network or named by the
    /// sticker's Wi-Fi name.
    @ViewBuilder private func sticker(_ setup: PurifierSetup) -> some View {
        if !setup.found.isEmpty {
            Picker("Purifier", selection: model.field(\.purifier.target)) {
                ForEach(setup.found, id: \.serial) { Text("\($0.name) · \($0.serial)").tag($0.serial) }
                Text("Another: type its Wi-Fi name").tag("")
            }
        }
        if setup.found.isEmpty || setup.target.isEmpty {
            InputRow(title: "Wi-Fi name", prompt: "DYSON-XXX-XX-XXXXXXXX-664", text: model.field(\.purifier.ssid))
        }
        InputRow(title: "Wi-Fi password", prompt: "As printed on the sticker", text: model.field(\.purifier.stickerPassword),
                 secure: true, action: "Connect",
                 ready: !setup.busy && !setup.stickerPassword.isEmpty && (!setup.target.isEmpty || !setup.ssid.isEmpty),
                 run: { setup.connectWithSticker(model.draft.dyson) })
        Text("The sticker is on the purifier, and on the back of its manual. No Dyson account involved.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// A one-time code by email, then the account password, which reads the purifier's password off the account.
    @ViewBuilder private func account(_ setup: PurifierSetup) -> some View {
        if !setup.choices.isEmpty {
            Picker("Purifier", selection: model.field(\.purifier.chosen)) {
                ForEach(setup.choices, id: \.serial) { Text("\($0.name) · \($0.serial)").tag($0.serial) }
            }
            HStack {
                Spacer()
                Button("Start Over", action: setup.startOver)
                Button("Connect") { setup.connectChosen(model.draft.dyson) }
                    .buttonStyle(.borderedProminent)
                    .disabled(setup.busy)
            }
        } else if setup.challenge == nil {
            InputRow(title: "Country", prompt: "Two letters, like US", text: model.field(\.purifier.country))
            InputRow(title: "Email", prompt: "you@example.com", text: model.field(\.purifier.email),
                     action: "Send Code", ready: !setup.busy && DysonSetup.isEmail(setup.email), run: setup.requestCode)
            Text("The email you sign in to the Dyson app with. Dyson emails it a one-time code; your account password is "
                + "then used once, to sign in, and never saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            InputRow(title: "Code", prompt: "From Dyson's email", text: model.field(\.purifier.code))
            InputRow(title: "Password", prompt: "Your Dyson account's", text: model.field(\.purifier.accountPassword),
                     secure: true, action: "Sign In",
                     ready: !setup.busy && !setup.code.isEmpty && !setup.accountPassword.isEmpty,
                     run: { setup.signIn(model.draft.dyson) })
            HStack {
                Text("Used once, to sign in, and never saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Start Over", action: setup.startOver)
                    .disabled(setup.busy)
            }
        }
    }

    private func applyHost() {
        let host = model.host.trimmingCharacters(in: .whitespaces)
        model.update { $0.dyson.host = host }
    }

    private var status: String {
        guard model.draft.dyson.enabled else { return "Off" }
        guard model.purifier.saved != nil else { return "Not connected yet" }
        guard let reading = model.dash.indoor else { return "No readings yet" }
        let age = Int(model.dash.now.timeIntervalSince(reading.updated))
        return age < 120 ? "Reporting (last reading \(age) s ago)" : "Last reading \(age / 60) min ago"
    }
}

// MARK: controls

/// A number chosen from a few sensible values: a slider that snaps to them, with the value beside it. A hand-edited
/// value between steps shows as it is and sits at the nearest step until the slider moves.
private struct StepSlider: View {
    let title: String
    @Binding var value: Double
    let steps: [Double]
    var format: (Double) -> String = StepSlider.duration
    var onEditingChanged: (Bool) -> Void = { _ in }

    static let pageSeconds: [Double] = [5, 6, 8, 10, 12, 15, 20, 25, 30, 45, 60, 90, 120]

    /// "45 s", "90 s", "3 min".
    nonisolated static func duration(_ seconds: Double) -> String {
        seconds >= 120 && seconds.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(seconds / 60)) min" : "\(Int(seconds)) s"
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Slider(value: position, in: 0...Double(steps.count - 1), step: 1, onEditingChanged: onEditingChanged)
                    .frame(width: 200)
                    .accessibilityLabel(title)
                    .accessibilityValue(format(value))  // the slider itself only knows the step's index
                Text(format(value))
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)
            }
        }
    }

    private var position: Binding<Double> {
        Binding(get: { Double(steps.indices.min { abs(steps[$0] - value) < abs(steps[$1] - value) } ?? 0) },
                set: { value = steps[min(steps.count - 1, max(0, Int($0.rounded())))] })
    }
}

/// A text input that reads as one. In a grouped form a plain TextField is borderless and looks like a label; this is
/// a bordered field with a prompt, and its action, if it has one, as the prominent button beside it, which Return also
/// presses. The button waits for something to be typed, or for `ready`. A `secure` field hides what is typed.
private struct InputRow: View {
    let title: String
    let prompt: String
    @Binding var text: String
    var secure = false
    var action: String?
    var ready: Bool?
    var run: () -> Void = {}

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Group {
                    if secure {
                        SecureField(title, text: $text, prompt: Text(prompt))
                    } else {
                        TextField(title, text: $text, prompt: Text(prompt))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)  // a grouped form right-aligns it otherwise
                .labelsHidden()
                .onSubmit(run)
                if let action {
                    Button(action, action: run)
                        .buttonStyle(.borderedProminent)
                        .disabled(!(ready ?? !text.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
        }
    }
}

/// A command for Terminal, with a button that copies it.
private struct CommandRow: View {
    let command: String

    var body: some View {
        HStack {
            Text(command)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
    }
}
