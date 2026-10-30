//
//  TropApp.swift
//  Trop
//
//  Created by 686udjie on 28/06/2026.
//

import Nuke
import SwiftUI
import WebKit

@main
struct TropApp: App {
    @UIApplicationDelegateAdaptor(QuickActionAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings = SettingsStore.shared
    /// The Woof Stats widget opens this month's recap.
    @State private var showsRecap = false

    init() {
        configureNuke()
        ensureDirectories()
        PlayerController.registerRemoteControlSupport()
        observePlaybackSettings()
        Task { await InnerTubeClient.tropShared.syncTropLocale() }
        Task { @MainActor in DiscordIntegration.shared.start() }
        Task { @MainActor in LastFMIntegration.shared.start() }
        Task { @MainActor in WidgetSync.shared.syncAll() }
        Self.removeSpotifyLeftovers()
    }

    /// Spotify Canvas was removed; wipe the sign-in it may have left behind.
    private static func removeSpotifyLeftovers() {
        let defaults = UserDefaults.standard
        let flag = "cleanup.spotifyRemoved"
        guard !defaults.bool(forKey: flag) else { return }
        try? SecureStore(service: "com.trop.spotify.canvas").delete(for: "spDc")
        for key in ["spotify.userId", "spotify.displayName", "spotify.avatarURL", "spotify.product",
                    "settings.canvasEnabled", "settings.canvasOverCellular"] {
            defaults.removeObject(forKey: key)
        }
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let spotify = records.filter { $0.displayName.contains("spotify") }
            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: spotify) {
                defaults.set(true, forKey: flag)
            }
        }
    }

    /// Re-applies mpv playback settings whenever the user changes the
    /// equalizer or the audio filters from any screen.
    private func observePlaybackSettings() {
        func register() {
            withObservationTracking {
                let settings = SettingsStore.shared
                _ = settings.equalizerEnabled
                _ = settings.equalizerGains
                _ = settings.audioNormalization
                _ = settings.gaplessPlayback
            } onChange: {
                Task { @MainActor in
                    PlayerController.shared.applyPlaybackSettings()
                    // onChange fires once; observe again for the next change.
                    register()
                }
            }
        }
        register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(settings.preferredColorScheme)
                .tint(settings.accentColor)
                .environment(settings)
                .environment(\.downloadManager, DownloadManager.shared)
                .recapStory(isPresented: $showsRecap, interval: RecapService.monthToDate())
                .onOpenURL(perform: openWidgetLink)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                QuickAction.updateResumeItem()
                WidgetSync.shared.syncAll()
            }
        }
    }

    /// Links from the widgets: woofmusic://player, home or recap.
    private func openWidgetLink(_ url: URL) {
        guard url.scheme == WidgetLink.scheme else { return }
        switch url.host() {
        case "player": AppRouter.shared.expandPlayer()
        case "home":
            AppRouter.shared.collapsePlayer()
            AppRouter.shared.selectedTabIndex = 0
        case "recap": showsRecap = true
        default: break
        }
    }

    private func configureNuke() {
        let dataCache = try? DataCache(name: "com.trop.nuke")
        dataCache?.sizeLimit = 2 * 1024 * 1024 * 1024

        var config = ImagePipeline.Configuration()
        config.dataCache = dataCache
        config.imageCache = ImageCache(costLimit: 100 * 1024 * 1024)

        ImagePipeline.shared = ImagePipeline(configuration: config)
    }

    private func ensureDirectories() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: docs.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: docs.appendingPathComponent("Player"), withIntermediateDirectories: true)
    }
}
