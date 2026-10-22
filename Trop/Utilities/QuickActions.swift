//
//  QuickActions.swift
//  Trop
//

import SwiftUI
import UIKit

/// Home Screen quick actions: the menu shown when you long-press the app icon.
/// Search, Shuffle Liked Songs and Downloads are static (Info.plist); Resume
/// is added at runtime with the current song's title.
@MainActor
enum QuickAction: String {
    case search, shuffleLiked, downloads, resume

    /// Action from a cold launch, run once ContentView is on screen.
    static var pending: UIApplicationShortcutItem?

    static func perform(_ item: UIApplicationShortcutItem) {
        guard let action = QuickAction(rawValue: item.type) else { return }
        let router = AppRouter.shared
        switch action {
        case .search:
            router.selectedTabIndex = 3
        case .downloads:
            router.selectedTabIndex = 1
            router.libraryPath = NavigationPath([DetailRoute.downloads])
        case .shuffleLiked:
            Task {
                let songs = (try? await DatabaseService.shared.fetchAllLikedSongs())?.toSongItems() ?? []
                guard !songs.isEmpty else { return }
                PlaybackQueue.playShuffled(songs, log: Log.nowPlaying, context: "quickAction.shuffleLiked")
                router.expandPlayer()
            }
        case .resume:
            PlayerController.shared.setPaused(false)
            router.expandPlayer()
        }
    }

    static func performPending() {
        guard let item = pending else { return }
        pending = nil
        perform(item)
    }

    /// Refreshes the Resume item; called when the app goes to the background.
    static func updateResumeItem() {
        let np = NowPlaying.shared
        guard np.queueSongs.indices.contains(np.queueIndex) else {
            UIApplication.shared.shortcutItems = []
            return
        }
        let song = np.queueSongs[np.queueIndex]
        UIApplication.shared.shortcutItems = [
            UIApplicationShortcutItem(
                type: QuickAction.resume.rawValue,
                localizedTitle: "Resume",
                localizedSubtitle: SongTitle.display(song.title),
                icon: UIApplicationShortcutIcon(systemImageName: "play.fill")
            )
        ]
    }
}

/// Receives quick actions. SwiftUI has no modifier for them, so the app
/// delegate hands each new window scene this delegate.
final class QuickActionAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let item = options.shortcutItem {
            MainActor.assumeIsolated { QuickAction.pending = item }
        }
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = QuickActionSceneDelegate.self
        return config
    }
}

final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        MainActor.assumeIsolated { QuickAction.perform(shortcutItem) }
        completionHandler(true)
    }
}
