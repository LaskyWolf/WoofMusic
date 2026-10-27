//
//  PlaylistSongEdits.swift
//  Trop
//

import Foundation

/// Adds and removes songs on a playlist. `browse/edit_playlist` wants the bare
/// playlist id, but library rows store the browse id (VL…), and
/// `MutationService` forwards that id unchanged. Synced playlists therefore go
/// straight to `editPlaylist` with the prefix stripped; local playlists keep
/// using `MutationService`. Callers reload the playlist afterwards, which
/// rewrites the local song list.
enum PlaylistSongEdits {
    static func add(songId: String, to playlistId: String) async throws {
        guard try await isSynced(playlistId) else {
            try await SyncBridge.mutations.addToPlaylist(playlistId: playlistId, songId: songId)
            return
        }
        _ = try await InnerTubeClient.tropShared.editPlaylist(
            playlistId: bareId(playlistId),
            actions: PlaylistEditAction.dictionaries([.addVideo(videoId: songId)])
        )
    }

    static func remove(songId: String, setVideoId: String, from playlistId: String) async throws {
        guard try await isSynced(playlistId) else {
            try await SyncBridge.mutations.removeFromPlaylist(playlistId: playlistId, songId: songId, setVideoId: setVideoId)
            return
        }
        _ = try await InnerTubeClient.tropShared.editPlaylist(
            playlistId: bareId(playlistId),
            actions: PlaylistEditAction.dictionaries([.removeVideo(setVideoId: setVideoId)])
        )
        try await SyncBridge.store.deleteMapEntry(playlistId: playlistId, songId: songId)
    }

    static func bareId(_ playlistId: String) -> String {
        playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
    }

    /// Same rule as the detail page: only a saved row without a browse id is local.
    private static func isSynced(_ playlistId: String) async throws -> Bool {
        let saved = try await DatabaseService.shared.fetchOne(PlaylistEntity.self, key: playlistId)
        return saved == nil || saved?.browseId != nil
    }
}
