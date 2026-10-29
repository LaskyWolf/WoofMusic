//
//  PlaybackQueue.swift
//  Trop
//
// Created by 686udjie on 12/09/2026.
//

import Foundation

/// Shared queue setup + resolve-and-play flows used by every tap-to-play site.
/// Each entry sets the queue on `NowPlaying` and resolves the stream via
/// `PlaybackManager`, logging failures instead of going silent.
@MainActor
enum PlaybackQueue {
    /// Plays `songs[startIndex]` (clamped). Used by detail play-all / play-song.
    static func play(_ songs: [SongItem], startIndex: Int = 0, log: AppLogger, context: String) {
        guard !songs.isEmpty else { return }
        let index = min(max(startIndex, 0), songs.count - 1)
        let first = songs[index]
        NowPlaying.shared.setQueue(songs, startIndex: index)
        loggedTask(log, "\(context) failed") {
            try await PlaybackManager.shared.resolveAndPlay(videoId: first.videoId)
        }
    }

    /// Shuffled variant of `play(_:startIndex:)`.
    static func playShuffled(_ songs: [SongItem], log: AppLogger, context: String) {
        guard !songs.isEmpty else { return }
        play(songs.shuffled(), log: log, context: context)
    }

    /// Plays `song`, reusing `songs` as the queue when it contains it.
    static func play(_ song: SongItem, in songs: [SongItem], log: AppLogger, context: String) {
        if let index = songs.firstIndex(where: { $0.videoId == song.videoId }) {
            play(songs, startIndex: index, log: log, context: context)
        } else {
            play([song], log: log, context: context)
        }
    }

    /// Starts a radio queue for `song`: plays it first unless already current,
    /// then replaces the queue with the fetched radio. Used by the song and
    /// player "Start Radio" menu actions.
    static func startRadio(for song: SongItem, options: RadioOptions = .default) {
        let isCurrentSong = NowPlaying.shared.videoId == song.videoId
        if !isCurrentSong {
            NowPlaying.shared.setQueue([song], startIndex: 0)
            Task { try? await PlaybackManager.shared.resolveAndPlay(videoId: song.videoId) }
        }
        let np = NowPlaying.shared
        let bloomId = np.radioBloom.id + 1
        np.radioBloom = RadioBloomEvent(id: bloomId, isLoading: true)
        Task {
            defer { if np.radioBloom.id == bloomId { np.radioBloom.isLoading = false } }
            guard let radio = try? await PersonalizationService.shared.fetchRadio(videoId: song.videoId, options: options),
                  radio.songs.count > 1 else { return }
            guard np.videoId == song.videoId else { return }
            np.replaceWithRadio(
                preservingArtists(radio.songs, over: np.queueSongs),
                currentIndex: radio.currentIndex
            )
            let upcoming = np.queueSongs.dropFirst(np.queueIndex + 1)
            np.radioBloom.covers = upcoming.prefix(RadioBloomEvent.orbCount).map(\.thumbnailUrl)
            np.radioBloom.addedCount = upcoming.count
        }
    }

    /// Plays a single song, then continues with its radio queue when available.
    /// Used by Home/Search/Explore tap-to-play.
    static func playSingleWithRadio(_ song: SongItem, log: AppLogger) {
        NowPlaying.shared.setQueue([song], startIndex: 0)
        Task { @MainActor in
            do {
                try await PlaybackManager.shared.resolveAndPlay(videoId: song.videoId)
            } catch {
                log.error("Playback failed: \(error)")
                return
            }
            guard let radio = try? await PersonalizationService.shared.fetchRadio(videoId: song.videoId),
                  radio.songs.count > 1,
                  NowPlaying.shared.videoId == song.videoId else { return }
            NowPlaying.shared.replaceWithRadio(
                preservingArtists(radio.songs, over: NowPlaying.shared.queueSongs),
                currentIndex: radio.currentIndex
            )
        }
    }

    private static func preservingArtists(_ songs: [SongItem], over current: [SongItem]) -> [SongItem] {
        guard !current.isEmpty else { return songs }
        let existingById = Dictionary(current.map { ($0.videoId, $0) }, uniquingKeysWith: { first, _ in first })
        return songs.map { song in
            guard let old = existingById[song.videoId], old.artists.count > song.artists.count else { return song }
            var merged = song
            merged.artists = old.artists
            return merged
        }
    }
}
