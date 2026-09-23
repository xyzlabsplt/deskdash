import AppKit
import IOKit.pwr_mgt
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    static var shared: AppDelegate?

    private let options: Options
    private let store: ConfigStore
    private let dash: Dashboard
    private let markets: MarketsService
    private let weather: WeatherService
    private let agents: AgentsService
    private let dyson: DysonService
    private let telegram: TelegramService
    private let stats: SystemStatsService
    private let music: NowPlayingService
    private var window: NSWindow?
    private var displayAssertion: IOPMAssertionID = 0
    private var hiddenUntil: Date?
    private var stackingNote = ""
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var saveTask: Task<Void, Never>?

    /// Just above the desktop picture and icons, below every app window.
    private static let behindWindows = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    init(options: Options) {
        self.options = options
        store = ConfigStore(path: options.configPath)
        let loaded = store.load()
        dash = Dashboard(config: loaded.config ?? Config())
        dash.configError = loaded.error
        dash.demo = options.demo
        markets = MarketsService(dash: dash)
        weather = WeatherService(dash: dash)
        agents = AgentsService(dash: dash)
        dyson = DysonService(dash: dash)
        telegram = TelegramService(dash: dash)
        stats = SystemStatsService(dash: dash)
        music = NowPlayingService(dash: dash)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if options.command == .snapshot {
            Task {
                await snapshot()
                exit(0)
            }
            return
        }
        if let error = dash.configError { log(error) }
        // The bundle ID is what macOS's Local Network permission follows; a bare binary has none.
        log("deskdash started as \(Bundle.main.bundleIdentifier ?? "a bare binary, not deskdash.app") (config: \(store.path)"
            + (launchdJob.map { ", launchd job \($0))" } ?? ")"))
        applyConfig()
        agents.start()
        music.start()
        if !options.windowed { installStatusItem() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(control(_:)), name: Control.notification, object: nil,
            suspensionBehavior: .deliverImmediately)
        Task { await runClock() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { options.windowed }

    /// Ticks on each whole second: flips the clock, publishes prices, the playing track and (every 2 s) the Mac's
    /// load, rotates pages, keeps the window out of the way of other windows, reloads config.
    private func runClock() async {
        var n = 0
        while !Task.isCancelled {
            let fraction = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1)
            try? await Task.sleep(for: .seconds(1 - fraction + 0.01))
            markets.flush()
            music.flush()
            if n % 2 == 0 { stats.sample() }
            dash.tick()
            if let until = hiddenUntil, Date() >= until { placeWindow() }
            updateStacking()
            n += 1
            if n % 2 == 0, store.changed { reloadConfig() }
            if n % 30 == 0 { updateDisplayAssertion() }
        }
    }

    private func reloadConfig() {
        let loaded = store.load()
        if dash.configError != loaded.error {
            dash.configError = loaded.error
            if let error = loaded.error { log(error) }
        }
        guard let config = loaded.config, config != dash.config else { return }
        dash.config = config
        applyConfig()
        log("config reloaded")
    }

    private func applyConfig() {
        markets.apply(symbols: dash.config.markets.symbols)
        weather.apply(dash.config.weather)
        dyson.apply(dash.config.dyson)
        telegram.apply(dash.config.telegram)
        stats.apply(dash.config.stats)
        placeWindow()
        updateDisplayAssertion()
    }

    // MARK: window

    @objc private func screensChanged() { placeWindow() }

    /// Covers the screen whose name contains `display.match`, and only that one. If it is unplugged the
    /// window hides rather than landing on another display, and comes back when it reappears.
    private func placeWindow() {
        if options.windowed { return showWindowed() }
        if let until = hiddenUntil {
            guard Date() >= until else {
                window?.orderOut(nil)
                return
            }
            hiddenUntil = nil
        }
        let match = dash.config.display.match.lowercased()
        guard !match.isEmpty, let screen = NSScreen.screens.first(where: { $0.localizedName.lowercased().contains(match) }) else {
            if window?.isVisible == true { log("no display matching '\(dash.config.display.match)'; hiding") }
            window?.orderOut(nil)
            return
        }
        let panel = window ?? makePanel()
        window = panel
        if panel.frame != screen.frame {
            if panel.isVisible { log("\(screen.localizedName) moved to \(screen.frame); following it") }
            panel.setFrame(screen.frame, display: true)
        }
        updateStacking(on: screen)  // before ordering in, so it never covers a window even for a moment
        if !panel.isVisible { log("showing on \(screen.localizedName), \(Int(screen.frame.width))x\(Int(screen.frame.height))") }
        panel.orderFrontRegardless()
    }

    /// The panel covers its screen, menu bar included, only while nothing else is there. If another app's
    /// window is on that screen, or that screen is the main display (where macOS opens new windows and
    /// dialogs), the panel drops behind every window like a desktop picture. A window that lands on the dock
    /// screen, for whatever reason, then stays visible and can be dragged off. Checked every second.
    private func updateStacking(on target: NSScreen? = nil) {
        guard !options.windowed, let panel = window, let screen = target ?? panel.screen,
              let id = screen.displayID else { return }
        let isMain = id == CGMainDisplayID()
        let others = isMain ? [] : WindowScan.otherAppWindows(on: id, excluding: panel.windowNumber)
        let level: NSWindow.Level = isMain || !others.isEmpty ? Self.behindWindows : .statusBar
        if panel.level != level { panel.level = level }
        let note = isMain ? "\(screen.localizedName) is the main display: staying behind windows"
            : others.isEmpty ? "\(screen.localizedName) is clear: covering it"
            : "windows on \(screen.localizedName) (\(Set(others).sorted().joined(separator: ", "))): staying behind them"
        if note != stackingNote {
            stackingNote = note
            log(note)
        }
    }

    private func makePanel() -> NSWindow {
        let panel = DashboardPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.level = Self.behindWindows  // updateStacking raises it once the screen is known to be clear
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.contentView = makeContentView()
        return panel
    }

    private func showWindowed() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: Theme.canvas),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "deskdash"
            w.contentAspectRatio = Theme.canvas
            w.isReleasedWhenClosed = false
            w.contentView = makeContentView()
            // The largest screen, so the dock display stays free.
            if let big = NSScreen.screens.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                w.setFrameOrigin(NSPoint(x: big.visibleFrame.midX - Theme.canvas.width / 2,
                                         y: big.visibleFrame.midY - Theme.canvas.height / 2))
            }
            window = w
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeContentView() -> NSView {
        let view = DashboardHostingView(rootView: RootView(dash: dash))
        view.onClick = { [weak self] in self?.dash.advance(1) }
        view.contextMenu = { [weak self] in self?.menu(full: false) }
        return view
    }

    // MARK: menus: the menu bar icon, and a right-click on the dashboard (the way out that needs no terminal)

    /// A gauge in the menu bar of the main display; its menu is rebuilt each time it opens.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "deskdash")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "deskdash"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in menuItems(full: true) { menu.addItem(item) }
    }

    private func menu(full: Bool) -> NSMenu {
        let menu = NSMenu()
        for item in menuItems(full: full) { menu.addItem(item) }
        return menu
    }

    private func menuItems(full: Bool) -> [NSMenuItem] {
        func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            return item
        }
        var items: [NSMenuItem] = []
        if full {
            let header = NSMenuItem(title: "deskdash: \(dash.page.title) on \(dash.config.display.match)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            let pages = NSMenuItem(title: "Show Page", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for page in dash.pages {
                let entry = item(page.title, #selector(menuShowPage(_:)))
                entry.representedObject = page.fileName
                entry.state = page == dash.page ? .on : .off
                submenu.addItem(entry)
            }
            pages.submenu = submenu
            items += [header, .separator(), pages]
        }
        items += [item("Next Page", #selector(menuNext)), item("Previous Page", #selector(menuPrevious))]
        if full {
            let pause = item("Pause Rotation", #selector(menuTogglePause))
            pause.state = dash.paused ? .on : .off
            items.append(pause)
        }
        items.append(.separator())
        items.append(hiddenUntil == nil ? item("Hide for 10 Minutes", #selector(menuHide))
                                        : item("Show Dashboard", #selector(menuShow)))
        items.append(item("Settings…", #selector(menuSettings), key: ","))
        items.append(.separator())
        items.append(item(launchdJob == nil ? "Quit deskdash" : "Quit deskdash (until next login)", #selector(menuQuit)))
        return items
    }

    @objc private func menuNext() { dash.advance(1) }
    @objc private func menuPrevious() { dash.advance(-1) }
    @objc private func menuTogglePause() { dash.paused.toggle() }
    @objc private func menuHide() { hide(minutes: 10) }
    @objc private func menuSettings() { openSettings() }
    @objc private func menuQuit() { quit() }

    @objc private func menuShow() {
        hiddenUntil = nil
        placeWindow()
    }

    @objc private func menuShowPage(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let page = dash.pages.first(where: { $0.fileName == name })
        else { return }
        dash.show(page, hold: 60)
    }

    // MARK: Settings window

    /// Opens on the main display, never the dock screen, in front of every window and with the keyboard, whether or
    /// not macOS lets deskdash become the active app (see SettingsPanel). `fresh` rebuilds it from the current
    /// settings even when it is already open.
    private func openSettings(tab: SettingsTab = .general, fresh: Bool = false) {
        let window = settingsWindow ?? {
            let w = SettingsPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
            w.title = "deskdash Settings"
            w.isReleasedWhenClosed = false
            w.hidesOnDeactivate = false  // a panel hides whenever its app deactivates, by default
            w.collectionBehavior = .moveToActiveSpace  // reopening it brings it to this Space
            w.delegate = self
            settingsWindow = w
            return w
        }()
        if fresh || !window.isVisible {
            let model = SettingsModel(config: dash.config, tab: tab, dash: dash, screens: NSScreen.screens.map(\.localizedName),
                                      commit: { [weak self] in self?.commitSettings($0) },
                                      previewTelegram: { [weak self] in self?.previewTelegram($0) },
                                      purifierChanged: { [weak self] in self?.dyson.reload() })
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            if let main = NSScreen.screens.first(where: { $0.displayID == CGMainDisplayID() }) {
                let area = main.visibleFrame
                window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
            }
        }
        NSApp.activate()  // only a request; nothing below depends on it
        window.orderFrontRegardless()  // orderFront would leave an inactive app's window behind the active app's
        window.makeKey()
    }

    /// Closing Settings hands the keyboard back to the app you were in; deskdash has no other window to keep. If
    /// deskdash never became active, that app still is, and gets the keyboard back from the panel by itself. A
    /// brightness preview ends with the window.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        dash.brightnessPreview = nil
        NSApp.deactivate()
    }

    /// Applies a change from Settings at once; writes config.json once the edits pause.
    private func commitSettings(_ config: Config) {
        guard config != dash.config else { return }
        dash.config = config
        applyConfig()
        saveTask?.cancel()
        saveTask = Task { [store] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            store.save(config)
            log("settings saved")
        }
    }

    /// Shows a channel's newest post on the dock screen now.
    private func previewTelegram(_ channel: String) {
        Task {
            guard let post = await TelegramService.latest(channel) else { return log("telegram: nothing to preview for \(channel)") }
            dash.notify([post])
        }
    }

    private func hide(minutes: Double) {
        hiddenUntil = Date().addingTimeInterval(max(0.1, minutes) * 60)
        window?.orderOut(nil)
        log("hidden for \(minutes) min")
    }

    /// The label of the LaunchAgent that runs deskdash, if one does: scripts/install-service.sh's local.deskdash, or any
    /// other. launchd starts such a job itself and puts its label in XPC_SERVICE_NAME. An app opened from Finder is
    /// started by launchd too, but as "application.<bundle ID>…", and one started from a shell has the shell as parent.
    private var launchdJob: String? {
        guard getppid() == 1, let label = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"],
              !label.isEmpty, label != "0", !label.hasPrefix("application.")
        else { return nil }
        return label
    }

    /// Under a LaunchAgent a plain exit is restarted by KeepAlive, so unload the job first. It loads again at the next
    /// login, or when scripts/install-service.sh runs.
    private func quit() {
        if let label = launchdJob {
            log("quit from the dashboard: unloading \(label) until the next login")
            let launchctl = Process()
            launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            launchctl.arguments = ["bootout", "gui/\(getuid())/\(label)"]
            try? launchctl.run()
            launchctl.waitUntilExit()  // launchd normally terminates us before this returns
        }
        NSApp.terminate(nil)
    }

    // MARK: display sleep

    /// During `schedule.keepAwake` the displays stay on (macOS cannot keep only one display awake).
    private func updateDisplayAssertion() {
        let want = !options.windowed && dash.keepAwakeNow
        if want, displayAssertion == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "deskdash keeps the desk display on" as CFString, &id)
            if result == kIOReturnSuccess {
                displayAssertion = id
                log("holding displays awake (schedule \(dash.config.schedule.keepAwake))")
            }
        } else if !want, displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
            log("released display-awake hold")
        }
    }

    // MARK: control

    @objc private func control(_ note: Notification) {
        guard let text = note.object as? String else { return }
        let words = text.split(separator: " ", maxSplits: 1).map(String.init)
        let argument = words.count > 1 ? words[1] : nil
        switch words.first {
        case "next": dash.advance(1)
        case "prev": dash.advance(-1)
        case "pause": dash.paused = true
        case "resume": dash.paused = false
        case "reload": reloadConfig()
        case "demo":
            dash.demo.toggle()
            if dash.demo { dash.alert(.waiting) }
        case "page":
            if let target = dash.pages.first(where: { $0.name == argument || $0.fileName == argument }) {
                dash.show(target, hold: 60)
            }
        case "capture":
            if let path = argument { capture(window, to: path) }
        case "telegram":  // preview: show the newest post of a watched channel (or the one named)
            guard let channel = argument ?? dash.config.telegram.channels.first else { return log("ctl: no Telegram channel") }
            previewTelegram(channel)
        case "settings": openSettings(tab: argument.flatMap(SettingsTab.init(rawValue:)) ?? .general, fresh: true)
        case "settings-close": settingsWindow?.close()
        case "capture-settings":
            if let path = argument { capture(settingsWindow, to: path) }
        case "hide": hide(minutes: argument.flatMap(Double.init) ?? 10)
        case "show":
            hiddenUntil = nil
            placeWindow()
        case "quit": quit()
        default:
            log("ctl: unknown command '\(text)'")
        }
    }

    /// Writes what one of deskdash's windows shows to a PNG. No screen-recording permission involved.
    private func capture(_ window: NSWindow?, to path: String) {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            log("captured \(path)")
        } catch {
            log("capture failed: \(error.localizedDescription)")
        }
    }

    /// `deskdash snapshot settings`: each Settings tab, drawn in a window that is never put on screen, and a tab too
    /// tall for the window once more scrolled to its end (`-end`). The Purifier tab is drawn once more on its Dyson
    /// account route (`settings-purifier-account`). The window server composites the glass tab bar's labels, so they
    /// come out blank here; the file name says which tab.
    private func snapshotSettings(to out: URL) async {
        let model = SettingsModel(config: dash.config, tab: .general, dash: dash, screens: NSScreen.screens.map(\.localizedName),
                                  commit: { _ in }, previewTelegram: { _ in }, purifierChanged: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: SettingsView(model: model).background(Color(nsColor: .windowBackgroundColor)))
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, !scroll.isHiddenOrHasHiddenAncestor { return scroll }
            return view.subviews.lazy.compactMap(scrollView).first
        }
        func draw(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(300))  // SwiftUI lays out the new tab over the next few turns
            capture(window, to: out.appendingPathComponent("settings-\(name).png").path)
            guard let scroll = window.contentView.flatMap(scrollView), let page = scroll.documentView,
                  page.frame.height > scroll.contentSize.height + 1 else { return }
            page.scroll(NSPoint(x: 0, y: page.isFlipped ? page.frame.height - scroll.contentSize.height : 0))
            try? await Task.sleep(for: .milliseconds(300))
            capture(window, to: out.appendingPathComponent("settings-\(name)-end.png").path)
        }
        for tab in SettingsTab.allCases {
            model.tab = tab
            await draw(tab.rawValue)
        }
        model.purifier.changing = true
        model.purifier.method = .account
        await draw("purifier-account")
    }

    // MARK: snapshot

    /// `deskdash snapshot`: fetch everything once, render each page at 1280x720, write PNGs, exit. With --demo, sample
    /// data stands in for everything of this Mac's own: its sessions, purifier, place's weather, load and track.
    private func snapshot() async {
        let out = URL(fileURLWithPath: options.outDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let symbols = dash.config.markets.symbols
        await markets.fetchOnce(symbols)
        await markets.refreshSparks(symbols)
        dash.demo = options.demo && !options.noAgents  // the sample sessions
        if options.demo {
            dash.weather = .demo
            dash.indoor = IndoorReading(sensorData: ["tact": "2976", "hact": "58", "p25r": "4", "p10r": "6",
                                                     "va10": "12", "noxl": "4", "co2r": "712", "hchr": "9"])
            dash.stats = .demo
            var track = NowPlaying.demo(now: Date())
            if !dash.config.music.artwork { track?.artwork = nil }
            dash.play(track, announce: false)
        } else {
            await weather.refresh(dash.config.weather)
            if !options.noAgents { agents.scan(alerts: false) }
            if let device = DysonCredentials.load(from: Paths.resolve(dash.config.dyson.credentials)),
               case .reading(let reading) = await DysonSetup.probe(device, host: dash.config.dyson.host, timeout: 15) {
                dash.indoor = reading
            }
            await stats.prime()
        }
        dash.tick()
        dash.stillFrame = true
        if options.only.contains("telegram"), let channel = dash.config.telegram.channels.first,
           let post = await TelegramService.latest(channel) {
            dash.notify([post])
            render(Stage(dash: dash), to: out.appendingPathComponent("telegram.png"))
            dash.clearTelegram()
        }
        for page in dash.pages where options.only.isEmpty || options.only.contains(page.name) {
            dash.show(page, animated: false)
            render(Stage(dash: dash), to: out.appendingPathComponent("\(page.fileName).png"))
        }
        if options.only.contains("settings") { await snapshotSettings(to: out) }
    }

    /// Draws a 1280x720 frame to a PNG, exactly as the dock screen shows it. Always in sRGB: the renderer picks
    /// Display P3 for some frames (one with a cover in it), and viewers that ignore the tag then show it tinted.
    private func render(_ stage: Stage, to file: URL) {
        let renderer = ImageRenderer(content: stage.frame(width: Theme.canvas.width, height: Theme.canvas.height))
        renderer.scale = 1
        guard let image = renderer.cgImage, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return log("snapshot: could not render \(file.lastPathComponent)") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flat = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: flat).representation(using: .png, properties: [:])
        else { return log("snapshot: could not render \(file.lastPathComponent)") }
        do {
            try png.write(to: file)
            print(file.path)
        } catch {
            log("snapshot: \(error.localizedDescription)")
        }
    }
}

final class DashboardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Click the dashboard for the next page, right-click for a menu (hide, quit), without taking focus.
final class DashboardHostingView: NSHostingView<RootView> {
    var onClick: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
