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
    /// Built per request: its last sync date belongs to the active profile.
    static var incremental: IncrementalSyncService {
        IncrementalSyncService(client: InnerTubeClient.tropShared, librarySync: librarySync, defaults: ProfileStorage.defaults)
    }

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
        if running == task { running = nil }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    /// Stops the sync in progress, so it can't write its account's library into another profile.
    @MainActor
    static func cancelRunning() async {
        guard let running else { return }
        running.cancel()
        await running.value
        Self.running = nil
    }

    @MainActor
    static func checkAndSyncIfStale() async {
        // The cookies and the database change one after the other: a sync between them would mix accounts.
        guard !AccountState.shared.isChangingSession else { return }
        let options = Self.options
        let incremental = Self.incremental
        await share {
            await incremental.checkAndSyncIfStale(options: options) {
                await LikeStore.shared.refresh()
            }
        }
    }

    @MainActor
    static func forceFullSync() async {
        guard !AccountState.shared.isChangingSession else { return }
        let options = Self.options
        let incremental = Self.incremental
        await share {
            await incremental.forceFullSync(options: options) {
                await LikeStore.shared.refresh()
            }
        }
    }
}
