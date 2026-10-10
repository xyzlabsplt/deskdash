import AppKit
import AudioToolbox
import CoreAudio

/// The alert sounds: one when a session needs you, one when a session finishes, one when a limit runs low. Each rings
/// again until someone uses the Mac's keyboard or mouse, or what it rang for is over, so a chime missed from across the
/// room is not the only one: first after `alerts.repeatSeconds`, then half as long again each time, up to
/// `alerts.repeatMaxSeconds` (30 s, 45 s, 68 s, 101 s, 152 s, then every 3 min), so it keeps on without nagging.
/// With `alerts.notify` each ring is a notification on the main screen instead, saying what it is for, and macOS
/// silences it as it does any app's in a Focus (Sleep among them) or while the Mac is muted. Notification Center
/// stacks the repeats of a long wait into one group.
@MainActor
final class Chime {
    enum Kind: Int, Comparable {
        case done, limit, waiting  // a session waiting on you outranks the others

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    private(set) var ringing: Kind?
    private var since = Date.distantPast
    private var playedAt = Date.distantPast
    private var gap: TimeInterval = 0
    private var sound: NSSound?
    private var message = (title: "", body: "")

    func ring(_ kind: Kind, _ cfg: Config.Alerts, quiet: Bool, title: String, body: String) {
        guard cfg.sound, !quiet else { return }
        if let ringing, ringing > kind { return }
        ringing = kind
        since = Date()
        gap = cfg.repeatSeconds
        message = (title, body)
        play(kind, cfg)
    }

    /// On the 1 s tick. `wanted` says whether what it rings for is still on (a session still waits, one still
    /// shows DONE).
    func tick(_ cfg: Config.Alerts, quiet: Bool, wanted: (Kind) -> Bool) {
        guard let kind = ringing else { return }
        let now = Date()
        // Any input since it began means someone is back at the Mac.
        guard cfg.sound, !quiet, wanted(kind), Self.idleSeconds >= now.timeIntervalSince(since) - 0.5 else {
            ringing = nil
            return
        }
        guard gap > 0, now.timeIntervalSince(playedAt) >= gap else { return }
        play(kind, cfg)
        gap = min(gap * 1.5, max(cfg.repeatSeconds, cfg.repeatMaxSeconds))
    }

    /// `deskdash ctl chime KIND`: one ring, whatever `alerts.sound` says, to hear what it sounds like.
    func preview(_ kind: Kind, _ cfg: Config.Alerts, title: String, body: String) {
        message = (title, body)
        play(kind, cfg, force: true)
    }

    private func play(_ kind: Kind, _ cfg: Config.Alerts, force: Bool = false) {
        let name = switch kind {
        case .waiting: cfg.waiting
        case .done: cfg.done
        case .limit: cfg.limit
        }
        playedAt = Date()
        if cfg.notify { return Notifier.post(title: message.title, body: message.body, sound: name) }
        guard !name.isEmpty, let next = NSSound(named: NSSound.Name(name)) else {
            if !name.isEmpty || force { log("sound: no system sound named '\(name)'") }
            return
        }
        sound?.stop()
        next.volume = Float(min(1, max(0, cfg.volume)))
        next.play()
        sound = next
    }

    /// Seconds since the last key press, click, or mouse move by anyone at this Mac.
    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}

/// A notification on the main screen, for `alerts.notify`, through osascript's `display notification`, which macOS
/// files under Script Editor. deskdash.app is ad-hoc signed, and macOS keeps Notification Center from an app without a
/// developer signature ("Notifications are not allowed for this application"). `display notification` is a Standard
/// Addition, not a scripted app, so unlike AppleScript aimed at Music it needs no Automation permission. Like any app's
/// notification it stays quiet in a Focus (Sleep among them) and while the Mac is muted.
enum Notifier {
    static func post(title: String, body: String, sound: String) {
        var script = "display notification \(quote(body)) with title \(quote(title))"
        if !sound.isEmpty { script += " sound name \(quote(sound))" }
        let osascript = Process()
        osascript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osascript.arguments = ["-e", script]
        do { try osascript.run() } catch { log("notification: \(error.localizedDescription)") }
    }

    private static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

enum SystemAudio {
    /// True when the default output device is muted or turned all the way down: a chime would go unheard.
    static var isSilent: Bool {
        var device = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown
        else { return false }

        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                             mElement: kAudioObjectPropertyElementMain)
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &address),
           AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr, muted != 0 {
            return true
        }

        address.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        var volume: Float32 = 1
        size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectHasProperty(device, &address),
           AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr, volume < 0.01 {
            return true
        }
        return false
    }
}
