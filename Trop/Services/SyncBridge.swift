//
//  SyncBridge.swift
//  Trop
//
//  Created by 686udjie on 09/10/2026.
//

import Foundation

enum SyncBridge {
    static let store = TropLibraryStore()
    static let librarySync = LibrarySyncService(client: InnerTubeClient.tropShared, store: store)
    static let playlistDetail = PlaylistDetailService(client: InnerTubeClient.tropShared, store: store)
    static let mutations = MutationService(client: InnerTubeClient.tropShared, store: store)
    static let incremental = IncrementalSyncService(client: InnerTubeClient.tropShared, librarySync: librarySync)

    static var options: LibrarySyncOptions {
        let settings = SettingsStore.shared
        return LibrarySyncOptions(
            syncArtists: settings.syncArtists,
            syncPlaylists: settings.syncPlaylists,
            syncAlbums: settings.syncAlbums,
            syncPodcasts: settings.syncPodcasts,
            syncSongs: settings.syncSongs
        )
    }

    /// The sync running now. Sign-in, Home and Library all ask for one at launch;
    /// they share it instead of each downloading the whole library.
    @MainActor private static var running: Task<Void, Never>?

    @MainActor
    private static func share(_ sync: @escaping @Sendable () async -> Void) async {
        if let running { return await running.value }
        let task = Task { await sync() }
        running = task
        await task.value
        running = nil
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    @MainActor
    static func checkAndSyncIfStale() async {
        let options = Self.options
        await share {
            await incremental.checkAndSyncIfStale(options: options) {
                await LikeStore.shared.refresh()
            }
        }
    }

    @MainActor
    static func forceFullSync() async {
        let options = Self.options
        await share {
            await incremental.forceFullSync(options: options) {
                await LikeStore.shared.refresh()
            }
        }
    }
}
