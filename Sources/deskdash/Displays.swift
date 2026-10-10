import AppKit
import VirtualDisplay

/// Keeps the dock screen from being the main display, where macOS opens windows and dialogs and the dashboard has to
/// stay behind them.
///  - `display.keepOffMain`: when a monitor is connected and the dock screen is main, the monitor becomes main, as
///    dragging the menu bar in System Settings → Displays does. Public API.
///  - `display.virtualMain`: when the dock screen has been the only display for 10 s, as when the Mac is used through
///    Parsec or Screen Sharing with no monitor, a virtual display is added and made main, so the remote session has a
///    full-size desktop and the dock screen keeps the dashboard. Connecting a monitor removes it at once. It goes
///    away with deskdash, too. Private API (`DDVirtualDisplay`), off by default.
@MainActor
final class DisplayManager {
    private var cfg = Config.Display()
    private var virtual: DDVirtualDisplay?
    private var aloneSince: Date?
    private var note = ""

    func apply(_ cfg: Config.Display) {
        let resized = cfg.virtualWidth != self.cfg.virtualWidth || cfg.virtualHeight != self.cfg.virtualHeight
            || cfg.virtualHiDPI != self.cfg.virtualHiDPI
        self.cfg = cfg
        if resized, virtual != nil { remove("its size changed") }
        check()
    }

    /// On every screen change, and every 5 s.
    func check() {
        let displays = Self.active()
        let virtualID = virtual?.displayID
        let match = cfg.match.lowercased()
        let dock = match.isEmpty ? nil
            : NSScreen.screens.first { $0.localizedName.lowercased().contains(match) }?.displayID
        let monitors = displays.filter { $0 != dock && $0 != virtualID }

        if cfg.virtualMain, dock != nil, monitors.isEmpty {
            if virtual == nil {
                let since = aloneSince ?? Date()
                aloneSince = since
                if Date().timeIntervalSince(since) >= 10 { add() }
            }
        } else {
            aloneSince = nil
            if virtual != nil { remove(cfg.virtualMain ? "a monitor is connected" : "display.virtualMain is off") }
        }

        guard let dock, CGMainDisplayID() == dock, cfg.keepOffMain || virtual != nil else { return }
        let candidates = monitors + [virtual?.displayID].compactMap { $0 }
        guard let target = candidates.max(by: { Self.area($0) < Self.area($1) }) else { return }
        makeMain(target, among: displays)
    }

    private func add() {
        let (w, h) = (max(640, cfg.virtualWidth), max(480, cfg.virtualHeight))
        guard let display = DDVirtualDisplay(name: "deskdash virtual display", width: UInt(w), height: UInt(h),
                                             hiDPI: cfg.virtualHiDPI) else {
            return say("could not add a virtual display (this macOS may have changed its private API)")
        }
        virtual = display
        say("the dock screen is the only display: added a virtual \(w)x\(h)\(cfg.virtualHiDPI ? " HiDPI" : "") display")
        // It comes online a moment later; the screen change it causes runs check() again, which makes it main.
    }

    private func remove(_ reason: String) {
        virtual = nil  // the display goes when the object does
        say("removed the virtual display: \(reason)")
    }

    /// Moves `target` to the origin, which makes it the main display, and every other display with it, so the
    /// arrangement stays as it was. Saved permanently, as System Settings does, so macOS keeps it for this set of
    /// displays.
    private func makeMain(_ target: CGDirectDisplayID, among displays: [CGDirectDisplayID]) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        let origin = CGDisplayBounds(target).origin
        for id in displays where CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay {
            let b = CGDisplayBounds(id)
            CGConfigureDisplayOrigin(config, id, Int32(b.origin.x - origin.x), Int32(b.origin.y - origin.y))
        }
        let result = CGCompleteDisplayConfiguration(config, .permanently)
        say(result == .success ? "made \(Self.name(target)) the main display, so the dock screen can show the dashboard"
            : "could not make \(Self.name(target)) the main display (error \(result.rawValue))")
    }

    private func say(_ text: String) {
        guard text != note else { return }
        note = text
        log(text)
    }

    /// `deskdash displays`: each active display, where it sits, and which is main.
    static func report() {
        for id in active() {
            let b = CGDisplayBounds(id)
            let mirror = CGDisplayMirrorsDisplay(id)
            print("\(name(id)) (id \(id)): \(Int(b.width))x\(Int(b.height)) at \(Int(b.origin.x)),\(Int(b.origin.y))"
                + (id == CGMainDisplayID() ? ", main" : "") + (mirror != kCGNullDirectDisplay ? ", mirrors \(mirror)" : ""))
        }
    }

    private static func active() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private static func area(_ id: CGDirectDisplayID) -> CGFloat {
        let b = CGDisplayBounds(id)
        return b.width * b.height
    }

    private static func name(_ id: CGDirectDisplayID) -> String {
        NSScreen.screens.first { $0.displayID == id }?.localizedName ?? "display \(id)"
    }
}
