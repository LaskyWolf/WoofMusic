//
//  PlaylistRemoval.swift
//  Trop
//

import Foundation

/// Takes a playlist out of the library. A synced playlist is deleted on
/// YouTube Music when you own it and un-saved when someone else does, then
/// forgotten locally. A local playlist is only forgotten locally.
enum PlaylistRemoval {
    enum RemovalError: LocalizedError {
        case notSignedIn

        var errorDescription: String? { "Sign in to remove a synced playlist." }
    }

    static func remove(playlistId: String, owned: Bool) async throws {
        let saved = try? await DatabaseService.shared.fetchOne(PlaylistEntity.self, key: playlistId)
        if saved?.browseId != nil {
            // The library keeps the browse id (VL…); the endpoints want the bare playlist id.
            let bareId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
            let delete = (endpoint: "playlist/delete", body: ["playlistId": bareId] as [String: Any])
            let unsave = (endpoint: "like/removelike", body: ["target": ["playlistId": bareId]] as [String: Any])
            // The ownership flag can be stale, so a rejected call falls back to the other one.
            try await send(owned ? [delete, unsave] : [unsave, delete])
        }
        try await SyncBridge.store.deletePlaylistRows(playlistId: playlistId)
    }

    private static func send(_ calls: [(endpoint: String, body: [String: Any])]) async throws {
        var firstRejection: Error?
        for call in calls {
            do {
                try await post(call.endpoint, call.body)
                return
            } catch InnerTubeError.httpError(let code, let data) where (400 ..< 500).contains(code) {
                firstRejection = firstRejection ?? InnerTubeError.httpError(statusCode: code, data: data)
            }
        }
        throw firstRejection ?? InnerTubeError.invalidResponse
    }

    private static func post(_ endpoint: String, _ payload: [String: Any]) async throws {
        do {
            _ = try await SignedInnerTube.post(endpoint, payload)
        } catch SignedInnerTube.Failure.notSignedIn {
            throw RemovalError.notSignedIn
        }
    }
}
