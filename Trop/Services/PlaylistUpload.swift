//
//  PlaylistUpload.swift
//  Trop
//

import UIKit

/// Moves a playlist that only lives on this iPhone into the YouTube Music account.
enum PlaylistUpload {
    /// Creates the playlist online, adds its songs and cover, then removes the
    /// local copy. If anything fails the online copy is removed again and the
    /// local playlist stays as it was, so a retry can't leave two copies.
    static func upload(localId: String) async throws {
        guard let local = try await SyncBridge.store.fetchPlaylist(id: localId), local.browseId == nil else { return }
        let songIds = try await SyncBridge.store.likedPlaylistSongIdsOrdered(playlistId: localId)

        let remoteId = try await SyncBridge.mutations.createPlaylist(title: local.name)
        do {
            for songId in songIds {
                try await SyncBridge.mutations.addToPlaylist(playlistId: remoteId, songId: songId)
            }
        } catch {
            try? await PlaylistRemoval.remove(playlistId: remoteId, owned: true)
            throw error
        }

        // A failed cover upload isn't worth losing the sync for.
        if let thumb = local.thumbnailUrl,
           let file = LocalPlaylistCover.fileURL(for: thumb),
           let image = (try? Data(contentsOf: file)).flatMap(UIImage.init(data:)) {
            try? await PlaylistCoverUploader.apply(image, to: remoteId)
        }
        LocalPlaylistCover.delete(local.thumbnailUrl)
        try await SyncBridge.store.deletePlaylistRows(playlistId: localId)
    }
}
