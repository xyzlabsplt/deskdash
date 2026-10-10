import AppKit
import VirtualDisplay

/// deskdash: a glanceable, always-on dashboard for the Wokyis dock's 5" 1280x720 screen.
/// One borderless window covers that screen; nothing listens on a port.
@main
enum DeskDash {
    static func main() {
        let options: Options
        do {
            options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            fputs("deskdash: \(error)\n\n\(Options.usage)\n", stderr)
            exit(2)
        }

        switch options.command {
        case .help:
            print(Options.usage)
        case .ctl(let words):
            Control.send(words)
        case .windows:
            MainActor.assumeIsolated { WindowScan.report() }
        case .displays:
            MainActor.assumeIsolated {
                _ = NSApplication.shared
                DisplayManager.report()
                guard options.tryVirtual else { return }
                print("\nAdding a 1920x1080 virtual display for 3 s, without changing the main display:")
                var display = DDVirtualDisplay(name: "deskdash test", width: 1920, height: 1080, hiDPI: false)
                guard display != nil else { return print("could not add one: this macOS may have changed its private API") }
                RunLoop.main.run(until: Date().addingTimeInterval(3))
                DisplayManager.report()
                display = nil
                RunLoop.main.run(until: Date().addingTimeInterval(2))
                print("\nRemoved it:")
                DisplayManager.report()
            }
        case .music:
            let listener = MainActor.assumeIsolated {
                setvbuf(stdout, nil, _IOLBF, 0)  // a line at a time, even into a pipe
                let loaded = ConfigStore(path: options.configPath).load()
                let listener = NowPlayingService(dash: Dashboard(config: loaded.config ?? Config()))
                listener.report = { print($0) }
                listener.start()
                print("Listening for Music and Spotify on this Mac. Play, pause or skip a track; Control-C stops.")
                return listener
            }
            RunLoop.main.add(Timer(timeInterval: 86_400, repeats: true) { _ in }, forMode: .default)
            withExtendedLifetime(listener) { RunLoop.main.run() }
        case .config:
            MainActor.assumeIsolated {
                let store = ConfigStore(path: options.configPath)
                let loaded = store.load()
                if let error = loaded.error { fputs("\(error)\n", stderr) }
                if options.save, let config = loaded.config { store.save(config) }
                print(ConfigStore.customized(loaded.config ?? Config()).map { String(decoding: $0, as: UTF8.self) } ?? "{}")
            }
        case .tokens:
            MainActor.assumeIsolated {
                setvbuf(stdout, nil, _IOLBF, 0)  // a line at a time, even into a pipe
                let loaded = ConfigStore(path: options.configPath).load()
                if let error = loaded.error { fputs("\(error)\n", stderr) }
                let cfg = (loaded.config ?? Config()).tokens
                _ = Task {
                    if options.watch {
                        await TokensService.watch(cfg)
                    } else {
                        print(await TokensService.report(cfg))
                    }
                    exit(0)
                }
            }
            RunLoop.main.add(Timer(timeInterval: 86_400, repeats: true) { _ in }, forMode: .default)
            RunLoop.main.run()
        case .limits:
            MainActor.assumeIsolated {
                let loaded = ConfigStore(path: options.configPath).load()
                if let error = loaded.error { fputs("\(error)\n", stderr) }
                let cfg = (loaded.config ?? Config()).limits
                _ = Task {
                    print(await LimitsService.report(cfg))
                    exit(0)
                }
            }
            RunLoop.main.add(Timer(timeInterval: 86_400, repeats: true) { _ in }, forMode: .default)
            RunLoop.main.run()
        case .dyson(let words):
            MainActor.assumeIsolated {
                _ = Task { exit(await DysonSetup.main(words)) }
            }
            // Serve the main queue from the main thread's run loop. dispatchMain() would drain it on a worker
            // thread, where the MainActor-bound network callbacks trap.
            RunLoop.main.add(Timer(timeInterval: 86_400, repeats: true) { _ in }, forMode: .default)
            RunLoop.main.run()
        case .run, .snapshot:
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                let delegate = AppDelegate(options: options)
                AppDelegate.shared = delegate  // NSApplication.delegate is weak
                app.delegate = delegate
                app.setActivationPolicy(.accessory)  // no Dock icon, never takes the menu bar
                app.run()
            }
        }
    }
}

struct Options: Sendable {
    enum Command: Equatable, Sendable { case run, snapshot, ctl([String]), windows, displays, music, tokens, limits, dyson([String]), config, help }

    var command = Command.run
    var configPath: String?
    var windowed = false
    var demo = false
    var noAgents = false
    var save = false
    var watch = false
    var tryVirtual = false
    var outDir = "snapshots"
    var only: [String] = []

    static let usage = """
    Build with scripts/build.sh: it makes deskdash.app, which scripts/install-service.sh runs at login.
    usage:
      deskdash [--config FILE] [--windowed] [--demo]
          Run the dashboard full screen on the display named in config (the login service runs this).
          --windowed shows it in a normal window on the largest screen instead; --demo adds sample agents.
      deskdash snapshot [--config FILE] [--out DIR] [--demo] [--no-agents] [PAGE...]
          Render pages (clock, music, photos, climate, markets, agents, limits, tokens, alert) to PNG files at 1280x720 and exit. --demo draws
          sample sessions, purifier, weather, load, track and tokens instead of this Mac's own; --no-agents draws no
          sessions at all.
          The PAGE `settings` renders each Settings tab (settings-TAB.png, and settings-TAB-end.png for a tall tab
          scrolled down).
      deskdash ctl next | prev | pause | resume | reload | demo | page NAME | capture FILE
                 | hide [MINUTES] | show | quit | telegram [CHANNEL] | settings [TAB] | settings-close
                 | capture-settings FILE | chime waiting | done | limit
          Control the running dashboard. quit also stops the LaunchAgent that runs it, until the next login. chime
          plays that alert's sound once, even with sounds off, to hear it.
      deskdash config [--config FILE] [--save]
          Print the settings that differ from the defaults. --save rewrites the file the way Settings does.
      deskdash windows
          List each display and the other apps' windows on it: what makes the dashboard stay behind them.
      deskdash displays [--try-virtual]
          List the displays, which is main, and where each sits. --try-virtual adds a virtual display for 3 s, without
          changing the main display, to check that this macOS supports display.virtualMain.
      deskdash music [--config FILE]
          Print what Music and Spotify on this Mac announce, as they announce it, and each cover found.
      deskdash tokens [--config FILE] [--watch]
          Print the tokens Claude Code and Codex used on this Mac, each day, as the tokens page counts them. --watch
          prints today's count instead, each time it changes (checked every 10 s, as the page does while it shows);
          Control-C stops.
      deskdash limits [--config FILE]
          Print the 5-hour and weekly limits of Claude Code's and Codex's plans as the limits page reads them: how
          much is left, when each resets, and when it runs out at the pace so far.
      deskdash dyson setup | test [--host HOST]
          Connect the Dyson purifier in Terminal, as Settings → Purifier does (run it yourself: it asks for a
          password), or read its sensors once.
    """

    static func parse(_ args: [String]) throws -> Options {
        var o = Options()
        var rest = args[...]
        switch rest.first {
        case "snapshot":
            o.command = .snapshot
            rest = rest.dropFirst()
        case "ctl":
            let words = Array(rest.dropFirst())
            guard !words.isEmpty else { throw OptionError("ctl needs a command") }
            o.command = .ctl(words)
            return o
        case "windows":
            o.command = .windows
            return o
        case "displays":
            o.command = .displays
            o.tryVirtual = args.dropFirst().contains("--try-virtual")
            return o
        case "music":
            o.command = .music
            rest = rest.dropFirst()
        case "tokens":
            o.command = .tokens
            rest = rest.dropFirst()
        case "limits":
            o.command = .limits
            rest = rest.dropFirst()
        case "dyson":
            o.command = .dyson(Array(rest.dropFirst()))
            return o
        case "config":
            o.command = .config
            rest = rest.dropFirst()
        case "help", "-h", "--help":
            o.command = .help
            return o
        default:
            break
        }
        while let arg = rest.popFirst() {
            switch arg {
            case "--config":
                guard let v = rest.popFirst() else { throw OptionError("--config needs a file") }
                o.configPath = v
            case "--out":
                guard let v = rest.popFirst() else { throw OptionError("--out needs a directory") }
                o.outDir = v
            case "--windowed": o.windowed = true
            case "--demo": o.demo = true
            case "--no-agents" where o.command == .snapshot: o.noAgents = true
            case "--save" where o.command == .config: o.save = true
            case "--watch" where o.command == .tokens: o.watch = true
            default:
                guard o.command == .snapshot, !arg.hasPrefix("-") else { throw OptionError("unknown argument '\(arg)'") }
                o.only.append(arg)
            }
        }
        return o
    }
}

struct OptionError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// `deskdash ctl ...` talks to the running dashboard through a distributed notification: no socket, no port.
enum Control {
    static let notification = Notification.Name("local.deskdash.ctl")

    static func send(_ words: [String]) {
        var words = words
        // The dashboard runs in its own working directory, so hand it an absolute path.
        if ["capture", "capture-settings"].contains(words.first), words.count > 1 {
            words[1] = URL(fileURLWithPath: words[1]).standardizedFileURL.path
        }
        DistributedNotificationCenter.default().postNotificationName(
            notification, object: words.joined(separator: " "), userInfo: nil, deliverImmediately: true)
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(Date.now.ISO8601Format()) \(message)\n".utf8))
}
