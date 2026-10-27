//
//  PlaylistReattach.swift
//  Trop
//

import Foundation

/// Turns sync back on for a playlist you stopped syncing, keeping the song
/// changes made on both sides since then (a three-way merge):
/// - base: the songs when sync was turned off, saved by `saveBase`;
/// - local: the songs on this iPhone now;
/// - remote: the songs on YouTube Music now.
/// Songs added or removed on this iPhone are sent to YouTube Music; changes
/// made there arrive with the next page load. Order isn't merged: the
/// playlist keeps YouTube Music's order, and new songs go at the end.
/// Songs are compared as sets, so a song listed twice counts once.
@MainActor
enum PlaylistReattach {
    private static func baseKey(_ playlistId: String) -> String { "detachedPlaylistBase.\(playlistId)" }

    static func saveBase(_ songIds: [String], playlistId: String) {
        UserDefaults.standard.set(songIds, forKey: baseKey(playlistId))
    }

    /// Sends the local changes to YouTube Music, then marks the playlist synced.
    /// If any change fails the playlist stays local with its songs, and a retry
    /// works out the plan again against the songs online.
    static func reattach(playlistId id: String) async throws {
        #if DEBUG
        selfCheck()
        #endif
        let (firstPage, rows) = try await SyncBridge.playlistDetail.fetchPlaylistRows(playlistId: id)
        let remote = PlaylistDetailViewModel.parsePlaylistDetail(firstPage: firstPage, rows: rows, playlistId: id)
            .songs.map(\.videoId)
        let setVideoIds = PlaylistDetailViewModel.setVideoIds(rows)
        let local = try await SyncBridge.store.likedPlaylistSongIdsOrdered(playlistId: id)
        let base = UserDefaults.standard.stringArray(forKey: baseKey(id)).map { Set($0) }
        let plan = mergePlan(base: base, local: local, remote: Set(remote))

        // The playlist is still local here, so MutationService would only touch
        // the database: edit the playlist online directly, as PlaylistSongEdits does.
        let bareId = PlaylistSongEdits.bareId(id)
        var failed = 0
        for songId in plan.addToRemote {
            do {
                _ = try await InnerTubeClient.tropShared.editPlaylist(
                    playlistId: bareId,
                    actions: PlaylistEditAction.dictionaries([.addVideo(videoId: songId)])
                )
            } catch {
                Log.playlistDetail.error("Reattach: adding \(songId) to \(id) failed: \(error)")
                failed += 1
            }
        }
        for songId in plan.removeFromRemote {
            guard let setVideoId = setVideoIds[songId] else { continue }
            do {
                _ = try await InnerTubeClient.tropShared.editPlaylist(
                    playlistId: bareId,
                    actions: PlaylistEditAction.dictionaries([.removeVideo(setVideoId: setVideoId)])
                )
            } catch {
                Log.playlistDetail.error("Reattach: removing \(songId) from \(id) failed: \(error)")
                failed += 1
            }
        }
        guard failed == 0 else { throw ReattachError(failed: failed) }

        try await SyncBridge.store.reattachPlaylist(id: id)
        UserDefaults.standard.removeObject(forKey: baseKey(id))
    }

    /// What to send to YouTube Music. Adds keep the local order. A song both
    /// sides added, or both removed, needs nothing; nor does anything changed
    /// only online. Running it again after a partial run sends only what's left.
    /// Without a base (sync turned off before this version) the songs online
    /// stand in for it and only additions go up: a removal can't be told apart
    /// from a song added online, so local removals are lost.
    static func mergePlan(base: Set<String>?, local: [String], remote: Set<String>)
        -> (addToRemote: [String], removeFromRemote: [String]) {
        var known = remote.union(base ?? [])
        let adds = local.filter { known.insert($0).inserted }
        guard let base else { return (adds, []) }
        let removes = base.subtracting(local).intersection(remote).sorted()
        return (adds, removes)
    }

    struct ReattachError: LocalizedError {
        let failed: Int
        var errorDescription: String? {
            "\(failed) song change\(failed == 1 ? "" : "s") couldn't reach YouTube Music. "
                + "The playlist stays on this iPhone; try again."
        }
    }

    #if DEBUG
    static func selfCheck() {
        func plan(_ base: Set<String>?, _ local: [String], _ remote: Set<String>) -> ([String], [String]) {
            let p = mergePlan(base: base, local: local, remote: remote)
            return (p.addToRemote, p.removeFromRemote)
        }
        // Local add goes up.
        assert(plan(["a", "b"], ["a", "b", "c"], ["a", "b"]) == (["c"], []))
        // Local remove goes up.
        assert(plan(["a", "b"], ["a"], ["a", "b"]) == ([], ["b"]))
        // Remote add stays, nothing to send.
        assert(plan(["a"], ["a"], ["a", "x"]) == ([], []))
        // Remote remove stays removed: not added back.
        assert(plan(["a", "b"], ["a", "b"], ["a"]) == ([], []))
        // Both sides added the same song: no duplicate add.
        assert(plan(["a"], ["a", "c"], ["a", "c"]) == ([], []))
        // Missing base: local adds go up, nothing is removed.
        assert(plan(nil, ["a", "c"], ["a", "b"]) == (["c"], []))
    }
    #endif
}
