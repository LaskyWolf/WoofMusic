//
//  AppIntents.swift
//  Trop
//

import AppIntents
import SwiftUI

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

/// "Play some music in Woof Music": resumes the queue, else shuffles liked songs.
struct PlaySomethingIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Some Music"
    static var description = IntentDescription("Resumes your queue, or shuffles your liked songs.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if !NowPlaying.shared.queueSongs.isEmpty {
            PlayerController.shared.setPaused(false)
            return .result(dialog: "Resuming.")
        }
        let songs = (try? await DatabaseService.shared.fetchAllLikedSongs())?.toSongItems() ?? []
        guard !songs.isEmpty else {
            return .result(dialog: "You have no liked songs yet. Say \"Play a song in Woof Music\" to search for one.")
        }
        PlaybackQueue.playShuffled(songs, log: Log.nowPlaying, context: "intent.playSomething")
        return .result(dialog: "Shuffling your liked songs.")
    }
}

/// "Play a song in Woof Music": Siri asks what to play, then the app searches
/// YouTube Music and plays the first song, followed by its radio.
struct PlayMusicIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play a Song or Artist"
    static var description = IntentDescription("Searches for a song or artist and plays it.")

    // A free-text parameter can't be spoken inside the phrase, so Siri asks for it.
    @Parameter(title: "Song or Artist", requestValueDialog: "What do you want to play?")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .result(dialog: "I didn't catch what to play.") }

        await AuthService.shared.loadPersistedSession()
        let sections: [SearchSection]
        do {
            sections = SearchParser.parseSearchResults(from: try await SearchService.shared.search(query: text))
        } catch let error as URLError {
            // Usually offline.
            if error.code != .cancelled { Log.search.notice("Siri search failed: \(error)") }
            return .result(dialog: "I couldn't search Woof Music right now.")
        } catch {
            Log.search.error("Siri search failed: \(error)")
            return .result(dialog: "I couldn't search Woof Music right now.")
        }

        let song = sections.lazy.flatMap(\.items).compactMap { item -> SongItem? in
            if case .song(let song) = item { return song }
            return nil
        }.first
        guard let song else { return .result(dialog: "I couldn't find \(text) in Woof Music.") }

        PlaybackQueue.playSingleWithRadio(song, log: Log.nowPlaying)
        return .result(dialog: "Playing \(song.title).")
    }
}

/// "Search in Woof Music", or "Search Woof Music for …": opens the Search tab
/// with the results. The system search schema lets Siri and Spotlight pass
/// the words spoken after "for" as the search term.
@AppIntent(schema: .system.search)
struct SearchMusicIntent: ShowInAppSearchResultsIntent {
    static var searchScopes: [StringSearchScope] = [.general]
    var criteria: StringSearchCriteria

    @MainActor
    func perform() async throws -> some IntentResult {
        let router = AppRouter.shared
        router.collapsePlayer()
        router.selectedTabIndex = 3
        router.searchPath = NavigationPath()
        router.pendingSearchQuery = criteria.term
        return .result()
    }
}

// PlayPauseIntent and NextSongIntent live in Shared/NowPlayingShared.swift:
// the widget extension compiles them too.

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
            intent: PlaySomethingIntent(),
            phrases: [
                "Play some music in \(.applicationName)",
                "Play something in \(.applicationName)"
            ],
            shortTitle: "Play Some Music",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlayMusicIntent(),
            phrases: [
                "Play a song in \(.applicationName)",
                "Play an artist in \(.applicationName)",
                "Search and play in \(.applicationName)"
            ],
            shortTitle: "Play a Song or Artist",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: SearchMusicIntent(),
            phrases: [
                "Search in \(.applicationName)",
                "Search \(.applicationName)"
            ],
            shortTitle: "Search",
            systemImageName: "magnifyingglass"
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
