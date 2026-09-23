// Posts the notification Music or Spotify sends on each play, pause and track change, so now playing can be
// tried without any music. The running dashboard, and `deskdash music`, take it for the real player.
//
//   swift scripts/fake-track.swift spotify                    a real Spotify track 30 s in, so its cover resolves
//   swift scripts/fake-track.swift music                      the same song from Music: iTunes Search finds its cover
//   swift scripts/fake-track.swift spotify "Title" "Artist" "Album" 245    made up: no cover, the placeholder shows
//   swift scripts/fake-track.swift music paused               also: playing (the default), stopped
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
guard let player = args.first, ["music", "spotify"].contains(player) else {
    print("usage: swift scripts/fake-track.swift music|spotify [playing|paused|stopped] [TITLE ARTIST ALBUM SECONDS]")
    exit(2)
}
args.removeFirst()
let state = ["playing", "paused", "stopped"].contains(args.first ?? "") ? args.removeFirst().capitalized : "Playing"
let custom = !args.isEmpty
let title = custom ? args[0] : "Never Gonna Give You Up"
let artist = args.count > 1 ? args[1] : "Rick Astley"
let album = args.count > 2 ? args[2] : "Whenever You Need Somebody"
let seconds = args.count > 3 ? Double(args[3]) ?? 213 : 213

/// A stable made-up ID per title, so pausing and resuming a track is recognized as the same track.
var hash: UInt64 = 0xcbf2_9ce4_8422_2325
for byte in (title + artist).utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }

var info: [String: Any] = ["Player State": state]
if state != "Stopped" {
    info["Name"] = title
    info["Artist"] = artist
    info["Album"] = album
}
let name: String
if player == "spotify" {
    name = "com.spotify.client.PlaybackStateChanged"
    info["Duration"] = Int(seconds * 1000)
    info["Playback Position"] = 30.0
    info["Track ID"] = custom ? "spotify:track:fake\(String(hash, radix: 36))" : "spotify:track:4cOdK2wGLETKBW3PvgPWqT"
} else {
    name = "com.apple.Music.playerInfo"
    info["Total Time"] = Int(seconds * 1000)
    info["PersistentID"] = Int64(bitPattern: hash)
}
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name(name), object: player == "spotify" ? "com.spotify.client" : "com.apple.Music.player",
    userInfo: info, deliverImmediately: true)
print("posted \(name): \(state) \(state == "Stopped" ? "" : "“\(title)” by \(artist)")")
