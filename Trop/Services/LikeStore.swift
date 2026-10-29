//
//  LikeStore.swift
//  Trop
//
//  Created by 686udjie on 28/08/2026.
//

import Combine
import Foundation
import GRDB

@MainActor
class LikeStore: ObservableObject {
    static let shared = LikeStore()

    @Published private(set) var liked: [String: Bool] = [:]

    private init() {
        Task { await refresh() }
    }

    func isLiked(videoId: String) -> Bool {
        liked[videoId] ?? false
    }

    func refresh() async {
        let ids = (try? await DatabaseService.shared.fetchLikedSongIds()) ?? []
        liked = Dictionary(ids.map { ($0, true) }, uniquingKeysWith: { first, _ in first })
    }

    func toggle(song: SongItem) async {
        let videoId = song.videoId
        let target = !isLiked(videoId: videoId)

        var updated = liked
        updated[videoId] = target
        liked = updated

        do {
            if target {
                try await SyncBridge.mutations.likeSong(videoId: videoId)
                // The download must not hold up the like (the widget heart waits on toggle).
                if SettingsStore.shared.autoDownloadOnLike {
                    Task { await DownloadManager.shared.download(song: song) }
                }
            } else {
                try await SyncBridge.mutations.unlikeSong(videoId: videoId)
            }
            let artist = song.artists.map(\.name).joined(separator: ", ")
            let track = song.title
            if !artist.isEmpty, !track.isEmpty {
                Task { await LastFMIntegration.shared.handleLove(artist: artist, track: track, love: target) }
            }
        } catch {
            var reverted = liked
            reverted[videoId] = !target
            liked = reverted
        }
    }
}
