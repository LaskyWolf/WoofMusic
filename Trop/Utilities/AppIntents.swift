//
//  AppIntents.swift
//  Trop
//

import AppIntents

// Siri and Shortcuts actions. Phrases must contain the app's name; the
// Info.plist adds "Woof Music" and "Woof" as alternative names so they don't
// collide with Apple Music.

struct ShuffleLikedSongsIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Shuffle Liked Songs"
    static var description = IntentDescription("Plays your liked songs in random order.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let songs = (try? await DatabaseService.shared.fetchAllLikedSongs())?.toSongItems() ?? []
        guard !songs.isEmpty else { return .result(dialog: "You have no liked songs yet.") }
        PlaybackQueue.playShuffled(songs, log: Log.nowPlaying, context: "intent.shuffleLiked")
        AppRouter.shared.expandPlayer()
        return .result(dialog: "Shuffling your liked songs.")
    }
}

struct PlayPauseIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play or Pause"
    static var description = IntentDescription("Pauses the song that's playing, or resumes the last one.")

    @MainActor
    func perform() async throws -> some IntentResult {
        PlayerController.shared.setPaused(NowPlaying.shared.isPlaying)
        return .result()
    }
}

struct NextSongIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Next Song"
    static var description = IntentDescription("Skips to the next song in the queue.")

    @MainActor
    func perform() async throws -> some IntentResult {
        NowPlaying.shared.playNext()
        return .result()
    }
}

struct WoofMusicShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShuffleLikedSongsIntent(),
            phrases: [
                "Shuffle my liked songs in \(.applicationName)",
                "Play my liked songs in \(.applicationName)"
            ],
            shortTitle: "Shuffle Liked Songs",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: PlayPauseIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Resume \(.applicationName)"
            ],
            shortTitle: "Play or Pause",
            systemImageName: "playpause.fill"
        )
        AppShortcut(
            intent: NextSongIntent(),
            phrases: [
                "Next song in \(.applicationName)",
                "Skip this song in \(.applicationName)"
            ],
            shortTitle: "Next Song",
            systemImageName: "forward.fill"
        )
    }
}
