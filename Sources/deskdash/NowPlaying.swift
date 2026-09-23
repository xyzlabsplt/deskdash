import AppKit
import ImageIO

/// A track playing in Music or Spotify on this Mac, as the player's own notifications describe it.
struct NowPlaying: Equatable {
    enum Player: String, CaseIterable, Sendable {
        case music, spotify

        var name: String { self == .music ? "Music" : "Spotify" }
        var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
        var notification: Notification.Name {
            Notification.Name(self == .music ? "com.apple.Music.playerInfo" : "com.spotify.client.PlaybackStateChanged")
        }
    }

    let player: Player
    let id: String  // Spotify's track ID, Music's persistent ID, or else artist, title and album
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval?
    var playing: Bool
    /// Where the playhead was at `at`. Neither player reports it continuously, so while playing it advances with
    /// the clock.
    var position: TimeInterval
    var at: Date
    var artwork: NSImage?

    func elapsed(at now: Date) -> TimeInterval {
        let p = max(0, position + (playing ? now.timeIntervalSince(at) : 0))
        return duration.map { min(p, $0) } ?? p
    }

    /// 0...1, or nil for a stream with no length.
    func progress(at now: Date) -> Double? {
        guard let duration, duration > 0 else { return nil }
        return elapsed(at: now) / duration
    }

    /// Tracks from one album share a cover, so they share one lookup and one decoded image.
    var coverKey: String { album.isEmpty ? id : "\(artist)\n\(album)" }
}

extension NowPlaying {
    /// Reads Music's `com.apple.Music.playerInfo` or Spotify's `com.spotify.client.PlaybackStateChanged`. Both
    /// carry Name, Artist, Album and Player State (Playing, Paused, Stopped). Music adds Total Time (ms) and a
    /// PersistentID but no playhead, so a new track starts at 0 and a known one carries on from where it was.
    /// Spotify adds Duration (ms), Track ID and Playback Position (s). Nil once the player has stopped.
    init?(_ player: Player, info: [AnyHashable: Any], previous: NowPlaying?, now: Date = Date()) {
        func text(_ key: String) -> String {
            (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func number(_ key: String) -> Double? {
            (info[key] as? NSNumber)?.doubleValue ?? Double(text(key))
        }
        let state = text("Player State")
        let title = text("Name")
        if state == "Paused", title.isEmpty, var paused = previous {  // a bare pause notice
            paused.position = paused.elapsed(at: now)
            paused.at = now
            paused.playing = false
            self = paused
            return
        }
        guard state == "Playing" || state == "Paused", !title.isEmpty else { return nil }
        let artist = text("Artist"), album = text("Album")
        let key = player == .spotify ? text("Track ID") : (info["PersistentID"] as? NSNumber)?.stringValue ?? ""
        let id = key.isEmpty ? "\(artist)\n\(title)\n\(album)" : key
        let same = previous?.id == id ? previous : nil
        let length = number(player == .spotify ? "Duration" : "Total Time").flatMap { $0 > 0 ? $0 / 1000 : nil }
        self.init(player: player, id: id, title: title, artist: artist, album: album, duration: length,
                  playing: state == "Playing", position: number("Playback Position") ?? same?.elapsed(at: now) ?? 0,
                  at: now, artwork: same?.artwork)
    }

    /// For `snapshot --demo`: a track part-way through, as Spotify reports one, with a drawn cover.
    static func demo(now: Date) -> NowPlaying? {
        var track = NowPlaying(.spotify, info: ["Name": "Slow Current", "Artist": "The Quiet Engines",
                                                "Album": "Harbor Lines", "Player State": "Playing", "Duration": 243_000,
                                                "Playback Position": 97.0, "Track ID": "spotify:track:demo"],
                               previous: nil, now: now)
        track?.artwork = NSImage(size: NSSize(width: 520, height: 520), flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.08, green: 0.22, blue: 0.38, alpha: 1),
                                NSColor(red: 0.93, green: 0.45, blue: 0.32, alpha: 1)])?.draw(in: rect, angle: 90)
            NSColor(red: 1, green: 0.86, blue: 0.62, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 150, y: 170, width: 220, height: 220)).fill()
            NSColor(red: 0.06, green: 0.16, blue: 0.3, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 520, height: 200)).fill()
            NSColor(white: 1, alpha: 0.35).setFill()
            for (i, y) in stride(from: 176.0, to: 20, by: -34).enumerated() {
                NSBezierPath(roundedRect: NSRect(x: 120 + Double(i) * 18, y: y, width: 280 - Double(i) * 36, height: 7),
                             xRadius: 3.5, yRadius: 3.5).fill()
            }
            return true
        }
        return track
    }
}

/// Listens to what Music and Spotify play on this Mac. Both post a distributed notification on every play,
/// pause, skip and track change, so this needs no permission and no polling. (AppleScript would trigger
/// Automation prompts, and the MediaRemote framework is private and restricted.) Nothing is known until the first
/// notice after start. Covers are looked up once per album: see `CoverLookup`.
@MainActor
final class NowPlayingService: NSObject {
    private let dash: Dashboard
    private var tracks: [NowPlaying.Player: NowPlaying] = [:]
    private var changed = false
    private var heard: Set<NowPlaying.Player> = []
    private var covers: [String: NSImage?] = [:]  // by cover key; a stored nil means the lookup found none
    private var coverOrder: [String] = []
    private var looking: Set<String> = []
    /// `deskdash music` prints what arrives through this.
    var report: ((String) -> Void)?

    init(dash: Dashboard) {
        self.dash = dash
        super.init()
    }

    func start() {
        // deliverImmediately: deskdash is never the active app, and a background app's notices otherwise wait.
        for player in NowPlaying.Player.allCases {
            DistributedNotificationCenter.default().addObserver(
                self, selector: player == .music ? #selector(musicNotice(_:)) : #selector(spotifyNotice(_:)),
                name: player.notification, object: nil, suspensionBehavior: .deliverImmediately)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appQuit(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    @objc private func musicNotice(_ note: Notification) { receive(.music, note.userInfo ?? [:]) }
    @objc private func spotifyNotice(_ note: Notification) { receive(.spotify, note.userInfo ?? [:]) }

    /// A player that quits (or crashes) may not say it stopped first.
    @objc private func appQuit(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard let player = NowPlaying.Player.allCases.first(where: { $0.bundleID == app?.bundleIdentifier }),
              tracks.removeValue(forKey: player) != nil
        else { return }
        changed = true
        report?("\(player.name): quit")
    }

    func receive(_ player: NowPlaying.Player, _ info: [AnyHashable: Any]) {
        if heard.insert(player).inserted { log("music: hearing from \(player.name)") }
        var track = NowPlaying(player, info: info, previous: tracks[player])
        if let key = track?.coverKey, track?.artwork == nil, case .some(.some(let cover)) = covers[key] { track?.artwork = cover }
        tracks[player] = track
        changed = true
        report?(Self.describe(player, track))
        if let track { lookUpCover(track) }
    }

    /// Publishes on the clock tick, so a burst of notices (skipping through a playlist) redraws once.
    func flush() {
        let now = Date()
        // Long past its end with no word from the player (a lost notice): stop counting it as playing.
        for (player, track) in tracks where track.playing {
            if let length = track.duration, track.position + now.timeIntervalSince(track.at) > length + 120 {
                tracks[player]?.playing = false
                changed = true
            }
        }
        guard changed else { return }
        changed = false
        dash.play(tracks.values.filter(\.playing).max { $0.at < $1.at })
    }

    /// The last few covers stay decoded (about 1 MB each), for an album's next track or a replay.
    private func lookUpCover(_ track: NowPlaying) {
        let key = track.coverKey
        guard dash.config.music.artwork, track.artwork == nil, covers[key] == nil, looking.insert(key).inserted
        else { return }
        let lookup = CoverLookup(player: track.player, id: track.id, title: track.title, artist: track.artist)
        Task {
            let cover = await lookup.fetch().flatMap(Self.image)
            looking.remove(key)
            covers[key] = .some(cover)
            coverOrder.append(key)
            if coverOrder.count > 6 { covers[coverOrder.removeFirst()] = nil }
            report?(cover.map { "  cover: \(Int($0.size.width))x\(Int($0.size.height)) px" } ?? "  cover: none found")
            for (player, t) in tracks where t.coverKey == key && t.artwork == nil {
                tracks[player]?.artwork = cover
                changed = true
            }
        }
    }

    /// Decoded once, at most 520 px across: the size the Now Playing page draws it.
    private static func image(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 520,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    static func describe(_ player: NowPlaying.Player, _ track: NowPlaying?) -> String {
        guard let t = track else { return "\(player.name): stopped" }
        let length = t.duration.map { " of \(Fmt.playtime($0))" } ?? ""
        return "\(player.name): \(t.playing ? "playing" : "paused") “\(t.title)” by \(t.artist.isEmpty ? "?" : t.artist)"
            + (t.album.isEmpty ? "" : ", from \(t.album)") + ", at \(Fmt.playtime(t.elapsed(at: Date())))\(length)"
    }
}

/// Finds a track's cover. Spotify's oEmbed gives it by track ID, at 300 px; the same image ID with Spotify's
/// 640 px size code is sharper, when it exists. Apple's iTunes Search finds a Music track by artist and title and
/// gives 100 px, which it also serves at 600. Both are public and need no key, and a cover is about 100 KB.
struct CoverLookup: Sendable {
    let player: NowPlaying.Player
    let id: String
    let title: String
    let artist: String

    func fetch() async -> Data? {
        for url in await candidates() {
            if let data = await Self.get(url) { return data }
        }
        return nil
    }

    private func candidates() async -> [URL] {
        switch player {
        case .spotify:
            // spotify:track:<id> or spotify:episode:<id>. Local files and ads have no page.
            let parts = id.split(separator: ":").map(String.init)
            guard parts.count == 3, ["track", "episode"].contains(parts[1]) else { return [] }
            struct OEmbed: Decodable { let thumbnail_url: String? }
            var url = URLComponents(string: "https://open.spotify.com/oembed")!
            url.queryItems = [URLQueryItem(name: "url", value: "https://open.spotify.com/\(parts[1])/\(parts[2])")]
            guard let data = await Self.get(url.url!),
                  let thumb = (try? JSONDecoder().decode(OEmbed.self, from: data))?.thumbnail_url
            else { return [] }
            let large = thumb.replacingOccurrences(of: "ab67616d00001e02", with: "ab67616d0000b273")
            return (large == thumb ? [thumb] : [large, thumb]).compactMap(URL.init(string:))
        case .music:
            struct Search: Decodable {
                struct Song: Decodable { let artworkUrl100: String? }
                let results: [Song]
            }
            var url = URLComponents(string: "https://itunes.apple.com/search")!
            url.queryItems = [URLQueryItem(name: "term", value: "\(artist) \(title)"),
                              URLQueryItem(name: "entity", value: "song"), URLQueryItem(name: "limit", value: "1")]
            guard let data = await Self.get(url.url!),
                  let art = (try? JSONDecoder().decode(Search.self, from: data))?.results.first?.artworkUrl100
            else { return [] }
            return [art.replacingOccurrences(of: "100x100", with: "600x600"), art].compactMap(URL.init(string:))
        }
    }

    private static func get(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15)),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }
}
