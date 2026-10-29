//
//  NowPlayingShared.swift
//  Compiled into both targets: the app (Trop) and the widget extension (WoofWidgets).
//

import AppIntents
import Foundation

/// A song as the widgets show it.
struct WidgetSong: Codable, Hashable, Identifiable {
    var videoId: String
    var title: String
    var artist: String
    /// Small JPEG cover.
    var artwork: Data?
    var isPinned = false
    /// The app's encoded song, so an intent can play it; the widget never reads it.
    var payload: Data?

    var id: String { videoId }
}

/// What the Turntable widget shows about the current song.
struct NowPlayingState: Codable, Hashable {
    var title: String
    var artist: String
    var isPlaying: Bool
    var isPodcast: Bool
    /// Dominant artwork color as 0xRRGGBB.
    var tint: UInt32?
    /// JPEG cover.
    var artwork: Data?
    var isLiked = false
    var isShuffleOn = false
    var isRepeatOn = false
    /// The next songs in the queue, for the large size.
    var upNext: [WidgetSong] = []
}

/// The Quick Picks widget: pinned songs first, then the picks.
struct QuickPicksSnapshot: Codable, Hashable {
    var songs: [WidgetSong]
    /// False when Quick Picks are off in Settings.
    var isEnabled = true
}

/// The Woof Stats widget: this month so far, from the same data as Woof Recap.
struct StatsSnapshot: Codable, Hashable {
    struct Artist: Codable, Hashable {
        var name: String
        var minutes: Int
        var artwork: Data?
    }

    struct Badge: Codable, Hashable {
        var emoji: String
        var name: String
        var isUnlocked: Bool
        /// Light and dark gem colours as 0xRRGGBB.
        var colors: [UInt32]
    }

    var monthName: String
    var minutes: Int
    var weeklyMinutes: [Int]
    var streakDays: Int
    var streakGoal: Int
    var topSong: WidgetSong?
    var topSongPlays: Int
    var topArtists: [Artist]
    var badges: [Badge]
    /// False when play history is off in Settings: nothing is counted.
    var isTracking = true
}

/// Widget kinds, for reloading one widget's timeline.
enum WidgetKind {
    static let nowPlaying = "NowPlaying"
    static let quickPicks = "QuickPicks"
    static let stats = "WoofStats"
}

/// Links the widgets open in the app.
enum WidgetLink {
    static let scheme = "woofmusic"
    static let player = URL(string: "woofmusic://player")
    static let home = URL(string: "woofmusic://home")
    static let recap = URL(string: "woofmusic://recap")
}

/// JSON files in the App Group container, written by the app and read by the
/// widgets. The container is nil when the signed app has no App Group
/// entitlement: then the app writes nothing and the widgets show their placeholder.
enum WidgetStore {
    static let nowPlayingFile = "nowplaying.json"
    static let quickPicksFile = "quickpicks.json"
    static let statsFile = "stats.json"

    private static let extensionSuffix = ".WoofWidgets"

    /// "group." + the app's bundle id, read at runtime so it follows a bundle id
    /// that a sideloading tool renamed.
    static func fileURL(_ name: String) -> URL? {
        guard var id = Bundle.main.bundleIdentifier else { return nil }
        if id.hasSuffix(extensionSuffix) { id.removeLast(extensionSuffix.count) }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group." + id)?
            .appendingPathComponent(name)
    }

    static func read<Value: Decodable>(_ type: Value.Type, from name: String) -> Value? {
        guard let url = fileURL(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Returns false when there is no App Group container to write to.
    @discardableResult
    static func write<Value: Encodable>(_ value: Value, to name: String) -> Bool {
        guard let url = fileURL(name), let data = try? JSONEncoder().encode(value) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

// The widget buttons use these intents, so both targets compile them. iOS
// runs an AudioPlaybackIntent's perform() in the app process (launching the
// app in the background when needed), so only the app's copy acts.

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

struct PreviousSongIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Previous Song"
    static var description = IntentDescription("Goes back to the previous song in the queue.")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        NowPlaying.shared.playPrevious()
        #endif
        return .result()
    }
}

struct ToggleLikeIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Like or Unlike"
    static var description = IntentDescription("Likes the song that's playing, or removes the like.")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        if let song = NowPlaying.shared.currentSong {
            await LikeStore.shared.toggle(song: song)
            WidgetSync.shared.refresh()
        }
        #endif
        return .result()
    }
}

struct ToggleShuffleIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Shuffle"
    static var description = IntentDescription("Turns shuffle on or off for the queue.")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let np = NowPlaying.shared
        np.isShuffleOn.toggle()
        if np.isShuffleOn { np.shuffleQueue() } else { np.disableShuffle() }
        WidgetSync.shared.refresh()
        #endif
        return .result()
    }
}

struct ToggleRepeatIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Repeat"
    static var description = IntentDescription("Turns repeat on or off.")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        NowPlaying.shared.isRepeatOn.toggle()
        WidgetSync.shared.refresh()
        #endif
        return .result()
    }
}

struct PlayQuickPickIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Quick Pick"
    static var description = IntentDescription("Plays one of your Quick Picks, with the others queued after it.")
    static var isDiscoverable = false

    @Parameter(title: "Song ID") var videoId: String

    init() {}

    init(videoId: String) {
        self.videoId = videoId
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let songs = WidgetSync.quickPickSongs()
        if let song = songs.first(where: { $0.videoId == videoId }) {
            PlaybackQueue.play(song, in: songs, log: Log.player, context: "Widget Quick Pick")
        }
        #endif
        return .result()
    }
}

struct ShuffleQuickPicksIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Shuffle Quick Picks"
    static var description = IntentDescription("Plays your Quick Picks in a random order.")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let songs = WidgetSync.quickPickSongs()
        if !songs.isEmpty {
            PlaybackQueue.playShuffled(songs, log: Log.player, context: "Widget Quick Picks shuffle")
        }
        #endif
        return .result()
    }
}
