//
// PlaybackStateService.swift
// Trop
//
// Created by 686udjie on 30/06/2026.
//

import Foundation
import GRDB

actor PlaybackStateService {
    nonisolated static let shared = PlaybackStateService()
    private let db = DatabaseService.shared
    private let innerTube = InnerTubeClient.tropShared

    private let historyDurationThreshold: TimeInterval = 30
    private var currentVideoId: String?
    /// Play time before the last resume; paused time never counts.
    private var playedBefore: TimeInterval = 0
    /// When playback last resumed; nil while paused or still loading.
    private var resumedAt: Date?
    private var isTracking = false
    private var hasRecordedPlayback = false
    private var periodicCheckTask: Task<Void, Never>?
    private var bankedPlayTimeMs: Int64 = 0
    /// Last song whose row is known to exist; banking runs every 5s.
    private var ensuredSongId: String?

    private init() {}

    private var elapsed: TimeInterval {
        playedBefore + (resumedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    /// Starts paused; `setPlaying(true)` begins counting once audio runs.
    func startTracking(videoId: String) {
        currentVideoId = videoId
        playedBefore = 0
        resumedAt = nil
        isTracking = true
        hasRecordedPlayback = false
        bankedPlayTimeMs = 0
        Log.playbackState.debug("Started tracking videoId=\(videoId)")

        periodicCheckTask?.cancel()
        periodicCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                await self.periodicCheck()
            }
        }
    }

    func setPlaying(_ playing: Bool) {
        guard isTracking else { return }
        if playing {
            if resumedAt == nil { resumedAt = Date() }
        } else if let resumedAt {
            playedBefore += Date().timeIntervalSince(resumedAt)
            self.resumedAt = nil
        }
    }

    private func periodicCheck() async {
        guard isTracking, let videoId = currentVideoId else { return }
        let elapsedMs = Int64(elapsed * 1000)
        // Bank every 5s chunk so skipped tracks still count toward Top 100.
        // Claim the chunk before awaiting so stopTracking can't count it twice.
        let delta = elapsedMs - bankedPlayTimeMs
        if delta >= 5_000 {
            bankedPlayTimeMs = elapsedMs
            await addPlayTime(videoId: videoId, deltaMs: delta)
        }
        guard currentVideoId == videoId else { return }
        if elapsedMs >= Int64(historyDurationThreshold * 1000), !hasRecordedPlayback {
            hasRecordedPlayback = true
            await recordPlayback(videoId: videoId, playTimeMs: elapsedMs)
        }
    }

    func stopTracking() async {
        periodicCheckTask?.cancel()
        periodicCheckTask = nil

        guard isTracking, let videoId = currentVideoId else {
            Log.playbackState.debug("stopTracking called but no active tracking")
            reset()
            return
        }
        // Copy state and reset before any await: the next song may start
        // tracking while this one is still being saved.
        let elapsed = self.elapsed
        let delta = Int64(elapsed * 1000) - bankedPlayTimeMs
        let needsHistory = elapsed >= historyDurationThreshold && !hasRecordedPlayback
        reset()
        Log.playbackState.debug("Stopped tracking videoId=\(videoId) totalElapsed=\(String(format: "%.1f", elapsed))s")

        // Bank the remainder (down to 1s) so short plays count.
        if delta >= 1_000 {
            await addPlayTime(videoId: videoId, deltaMs: delta)
        }
        if needsHistory {
            await recordPlayback(videoId: videoId, playTimeMs: Int64(elapsed * 1000))
        } else if elapsed < historyDurationThreshold {
            Log.playbackState.debug(
                "Elapsed \(String(format: "%.1f", elapsed))s below threshold \(self.historyDurationThreshold)s — skipping history recording"
            )
        }
    }

    private func addPlayTime(videoId: String, deltaMs: Int64) async {
        guard SettingsStore.shared.trackPlayHistory, !videoId.isEmpty else { return }
        await ensureSongEntity(videoId: videoId)
        do {
            try await db.incrementTotalPlayTime(songId: videoId, playTimeMs: deltaMs)
        } catch {
            Log.playbackState.error("Failed to bank play time: \(error)")
        }
    }

    /// Inserts the song row when missing (title/artwork from the queue),
    /// so banking and history never hit a missing row. No-op when present.
    private func ensureSongEntity(videoId: String) async {
        guard ensuredSongId != videoId else { return }
        let queueSong: SongItem? = await MainActor.run {
            NowPlaying.shared.queueSongs.first(where: { $0.videoId == videoId })
        }
        do {
            try await db.write { db in
                guard try SongEntity.fetchOne(db, key: videoId) == nil else { return }
                let entity = SongEntity(
                    id: videoId,
                    title: queueSong?.title ?? videoId,
                    artistName: queueSong.flatMap { $0.artists.first?.name ?? $0.artistNamesDisplay },
                    albumName: queueSong?.album,
                    duration: queueSong?.duration ?? 0,
                    thumbnailUrl: queueSong?.thumbnailUrl ?? ArtworkURLs.fallback(for: videoId),
                    liked: false,
                    totalPlayTime: 0,
                    inLibrary: nil,
                    libraryAddToken: "",
                    libraryRemoveToken: "",
                    isEpisode: false,
                    isUploaded: false,
                    isVideo: false,
                    createDate: Date(),
                    modifyDate: Date()
                )
                try entity.insert(db, onConflict: .ignore)
                Log.playbackState.debug("Ensured SongEntity for \(videoId)")
            }
            ensuredSongId = videoId
        } catch {
            Log.playbackState.error("Failed to ensure song entity: \(error)")
        }
    }

    private func recordPlayback(videoId: String, playTimeMs: Int64) async {
        guard SettingsStore.shared.trackPlayHistory else {
            Log.playbackState.debug("Play history tracking disabled — skipping recording")
            return
        }
        Log.playbackState.debug("Recording playback videoId=\(videoId) playTimeMs=\(playTimeMs)")
        await ensureSongEntity(videoId: videoId)
        do {
            try await db.write { db in
                var event = Event(id: nil, songId: videoId, timestamp: Date(), playTime: playTimeMs)
                event = try event.inserted(db, onConflict: .ignore)
                Log.playbackState.debug("Local event recorded id=\(event.id ?? 0)")
            }

            let now = Date()
            let calendar = Calendar.current
            try await db.incrementPlayCount(songId: videoId, year: calendar.component(.year, from: now), month: calendar.component(.month, from: now))
            Log.playbackState.debug("Play count incremented")

            let trackingUrl = await getCachedTrackingUrl(videoId: videoId)
            if let trackingUrl {
                Log.playbackState.debug("Sending playback to YTM for tracking")
                Task {
                    do {
                        try await InnerTubeClient.tropShared.registerPlayback(trackingUrl: trackingUrl)
                    } catch let error as URLError {
                        // Usually offline; the play is already counted locally.
                        if error.code != .cancelled { Log.playbackState.notice("YTM playback registration failed: \(error)") }
                    } catch {
                        Log.playbackState.error("YTM playback registration failed: \(error)")
                    }
                }
            } else {
                Log.playbackState.debug("No cached tracking URL for videoId=\(videoId) — skipping YTM registration")
            }
        } catch {
            Log.playbackState.error("Failed to record playback: \(error)")
        }
    }

    private func getCachedTrackingUrl(videoId: String) async -> String? {
        if let format = try? await db.fetchOne(FormatEntity.self, key: videoId),
           let url = format.playbackUrl {
            return url
        }
        return nil
    }

    private func reset() {
        currentVideoId = nil
        playedBefore = 0
        resumedAt = nil
        isTracking = false
        hasRecordedPlayback = false
        bankedPlayTimeMs = 0
    }
}
