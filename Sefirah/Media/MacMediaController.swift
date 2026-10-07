import AppKit
import Foundation
import ImageIO
import IOKit.hidsystem
import SefirahCore
import UniformTypeIdentifiers

/// Publishes the active Spotify or Music track as one Mac media session.
///
/// When neither app is playing, the session remains available with system media-key
/// controls for another compatible macOS player.
@MainActor
enum MacMediaController {
    private enum Player: Sendable {
        case spotify
        case music
    }

    private struct PlaybackSnapshot: Sendable {
        var info: PlaybackInfo
        let player: Player
        let artworkURL: URL?
    }

    nonisolated private static let source = "sefirah.macos.media"
    private static var activePlayer: Player?
    private static var artworkCache: [String: String] = [:]
    private static var lastTrackIdentifier: String?

    static func playbackInfos() async -> [PlaybackInfo] {
        guard var snapshot = await Task.detached(priority: .utility, operation: {
            playbackMetadata()
        }).value else {
            activePlayer = nil
            lastTrackIdentifier = nil
            return [fallbackPlaybackInfo()]
        }

        activePlayer = snapshot.player
        let trackIdentifier = [
            snapshot.info.appName ?? "",
            snapshot.info.trackTitle ?? "",
            snapshot.info.artist ?? "",
            snapshot.artworkURL?.absoluteString ?? "",
        ].joined(separator: "\u{1F}")
        if let lastTrackIdentifier, lastTrackIdentifier != trackIdentifier {
            snapshot.info.infoType = .playbackUpdate
        }
        lastTrackIdentifier = trackIdentifier

        if let artworkURL = snapshot.artworkURL {
            let key = artworkURL.absoluteString
            if let artwork = artworkCache[key] {
                snapshot.info.thumbnail = artwork
            } else if let artwork = await downloadArtwork(from: artworkURL) {
                artworkCache[key] = artwork
                snapshot.info.thumbnail = artwork
            }
        }
        return [snapshot.info]
    }

    static func handle(_ action: MediaAction) async {
        guard action.source == source else { return }

        switch activePlayer {
        case .spotify:
            await runAppleScript(spotifyCommand(for: action))
        case .music:
            await runAppleScript(musicCommand(for: action))
        case nil:
            postMediaKey(for: action.actionType)
        }
    }

    static func handles(_ action: MediaAction) -> Bool {
        action.source == source
    }

    private static func fallbackPlaybackInfo() -> PlaybackInfo {
        PlaybackInfo(
            infoType: .playbackInfo,
            source: source,
            trackTitle: "Mac media",
            artist: Host.current().localizedName,
            isPlaying: false,
            appName: "Sefirah",
            volume: 0,
            canPlay: true,
            canPause: true,
            canGoNext: true,
            canGoPrevious: true,
            canSeek: false
        )
    }

    nonisolated private static func playbackMetadata() -> PlaybackSnapshot? {
        if isRunning(bundleIdentifier: "com.spotify.client"),
           let snapshot = playerInfo(
               script: """
               tell application "Spotify"
                   if player state is not stopped then
                       return (name of current track) & "␟" & (artist of current track) & "␟" & (player state as text) & "␟" & (player position as text) & "␟" & (duration of current track as text) & "␟" & (artwork url of current track)
                   end if
               end tell
               return ""
               """,
               player: .spotify,
               appName: "Spotify",
               durationMultiplier: 1
           )
        {
            return snapshot
        }

        if isRunning(bundleIdentifier: "com.apple.Music") {
            return playerInfo(
                script: """
                tell application "Music"
                    if player state is not stopped then
                        return (name of current track) & "␟" & (artist of current track) & "␟" & (player state as text) & "␟" & (player position as text) & "␟" & (duration of current track as text)
                    end if
                end tell
                return ""
                """,
                player: .music,
                appName: "Music",
                durationMultiplier: 1_000
            )
        }

        return nil
    }

    nonisolated private static func isRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    nonisolated private static func playerInfo(
        script: String,
        player: Player,
        appName: String,
        durationMultiplier: Double
    ) -> PlaybackSnapshot? {
        guard let value = runAppleScriptBlocking(script) else { return nil }
        let fields = value.components(separatedBy: "␟")
        guard fields.count >= 5 else { return nil }

        let artworkURL = fields.count > 5 ? URL(string: fields[5]) : nil
        let info = PlaybackInfo(
            infoType: .playbackInfo,
            source: source,
            trackTitle: fields[0],
            artist: fields[1],
            isPlaying: fields[2].localizedCaseInsensitiveContains("playing"),
            playbackRate: fields[2].localizedCaseInsensitiveContains("playing") ? 1 : 0,
            position: Double(fields[3]).map { $0 * 1_000 },
            maxSeekTime: Double(fields[4]).map { $0 * durationMultiplier },
            minSeekTime: 0,
            appName: appName,
            volume: 0,
            canPlay: true,
            canPause: true,
            canGoNext: true,
            canGoPrevious: true,
            canSeek: true
        )
        return PlaybackSnapshot(info: info, player: player, artworkURL: artworkURL)
    }

    private static func spotifyCommand(for action: MediaAction) -> String? {
        switch action.actionType {
        case .play:
            "tell application \"Spotify\" to play"
        case .pause, .stop:
            "tell application \"Spotify\" to pause"
        case .next:
            "tell application \"Spotify\" to next track"
        case .previous:
            "tell application \"Spotify\" to previous track"
        case .seek:
            seekCommand(for: "Spotify", position: action.value)
        default:
            nil
        }
    }

    private static func musicCommand(for action: MediaAction) -> String? {
        switch action.actionType {
        case .play:
            "tell application \"Music\" to play"
        case .pause, .stop:
            "tell application \"Music\" to pause"
        case .next:
            "tell application \"Music\" to next track"
        case .previous:
            "tell application \"Music\" to previous track"
        case .seek:
            seekCommand(for: "Music", position: action.value)
        default:
            nil
        }
    }

    private static func seekCommand(for application: String, position: Double?) -> String? {
        guard let position, position.isFinite else { return nil }
        let seconds = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), max(0, position / 1_000))
        return "tell application \"\(application)\" to set player position to \(seconds)"
    }

    private static func runAppleScript(_ source: String?) async {
        guard let source else { return }
        _ = await Task.detached(priority: .userInitiated) {
            runAppleScriptBlocking(source)
        }.value
    }

    nonisolated private static func runAppleScriptBlocking(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result?.stringValue : nil
    }

    nonisolated private static func downloadArtwork(from url: URL) async -> String? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              data.count <= 1_500_000
        else {
            return nil
        }
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  imageSource,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 160,
                  ] as CFDictionary
              )
        else {
            return nil
        }

        let thumbnail = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            thumbnail,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (thumbnail as Data).base64EncodedString()
    }

    private static func postMediaKey(for action: MediaActionType) {
        switch action {
        case .play, .pause, .stop:
            postMediaKey(NX_KEYTYPE_PLAY)
        case .next:
            postMediaKey(NX_KEYTYPE_NEXT)
        case .previous:
            postMediaKey(NX_KEYTYPE_PREVIOUS)
        default:
            break
        }
    }

    private static func postMediaKey(_ keyCode: Int32) {
        postMediaKey(keyCode, state: 0xA)
        postMediaKey(keyCode, state: 0xB)
    }

    private static func postMediaKey(_ keyCode: Int32, state: Int) {
        let data1 = Int(keyCode) << 16 | state << 8
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xA00),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else {
            return
        }

        event.cgEvent?.post(tap: .cghidEventTap)
    }
}
