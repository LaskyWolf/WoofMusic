//
//  NowPlayingShared.swift
//  Compiled into both targets: the app (Trop) and the widget extension (WoofWidgets).
//

import AppIntents
import Foundation

/// What the Home Screen widget shows about the current song.
struct NowPlayingState: Codable, Hashable {
    var title: String
    var artist: String
    var isPlaying: Bool
    var isPodcast: Bool
    /// Dominant artwork color as 0xRRGGBB.
    var tint: UInt32?
    /// JPEG cover.
    var artwork: Data?
}

/// The last song for the Home Screen widget, a JSON file in the App Group container.
/// The container is nil when the signed app has no App Group entitlement: then the
/// app writes nothing and the widget shows its placeholder.
enum WidgetSnapshot {
    private static let extensionSuffix = ".WoofWidgets"

    /// "group." + the app's bundle id, read at runtime so it follows a bundle id
    /// that a sideloading tool renamed.
    static var fileURL: URL? {
        guard var id = Bundle.main.bundleIdentifier else { return nil }
        if id.hasSuffix(extensionSuffix) { id.removeLast(extensionSuffix.count) }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group." + id)?
            .appendingPathComponent("nowplaying.json")
    }

    static func read() -> NowPlayingState? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NowPlayingState.self, from: data)
    }

    /// Returns false when there is no App Group container to write to.
    @discardableResult
    static func write(_ state: NowPlayingState) -> Bool {
        guard let url = fileURL, let data = try? JSONEncoder().encode(state) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

// The widget buttons use these intents, so both targets
// compile them. iOS runs an AudioPlaybackIntent's perform() in the app process
// (launching the app in the background when needed), so only the app's copy acts.

struct PlayPauseIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play or Pause"
    static var description = IntentDescription("Pauses the song that's playing, or resumes the last one.")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        PlayerController.shared.setPaused(NowPlaying.shared.isPlaying)
        #endif
        return .result()
    }
}

struct NextSongIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Next Song"
    static var description = IntentDescription("Skips to the next song in the queue.")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        NowPlaying.shared.playNext()
        #endif
        return .result()
    }
}
