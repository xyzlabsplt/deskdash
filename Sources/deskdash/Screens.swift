import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// What else is on a display, so the dashboard never hides a window. Reading window bounds and owners needs no
/// screen-recording permission (window titles would, and are not read).
enum WindowScan {
    /// Owners of windows overlapping `display` by at least 40x40 pt, other than the dashboard panel itself and the alert
    /// card floating over it (deskdash's own Settings window counts). Layers 0..<20 hold ordinary, floating, modal and utility
    /// windows. The Dock (20), menu bar (24) and system overlays sit higher, and the desktop picture and icons
    /// are excluded.
    static func otherAppWindows(on display: CGDirectDisplayID, excluding own: Set<Int> = []) -> [String] {
        let bounds = CGDisplayBounds(display)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { w in
            guard let layer = w[kCGWindowLayer as String] as? Int, (0..<20).contains(layer),
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  !own.contains(w[kCGWindowNumber as String] as? Int ?? -1),
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dict as CFDictionary)
            else { return nil }
            let overlap = frame.intersection(bounds)
            guard !overlap.isNull, overlap.width >= 40, overlap.height >= 40 else { return nil }
            return w[kCGWindowOwnerName as String] as? String ?? "pid \(pid)"
        }
    }

    /// `deskdash windows`: each display, whether it is the main one, and whose windows are on it.
    static func report() {
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let main = id == CGMainDisplayID()
            let owners = Array(Set(otherAppWindows(on: id))).sorted()
            print("\(screen.localizedName)\(main ? " (main display)" : ""): "
                + (owners.isEmpty ? "no windows" : owners.joined(separator: ", ")))
        }
    }
}
