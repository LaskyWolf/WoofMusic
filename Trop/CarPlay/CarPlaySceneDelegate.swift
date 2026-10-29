//
//  CarPlaySceneDelegate.swift
//  Trop
//

// ponytail: CarPlay lists the app only when it is signed with the
// com.apple.developer.carplay-audio entitlement. A build re-signed without it
// never receives this scene, so this code stays idle. Add the key to
// Trop.entitlements once Apple grants it.

import CarPlay
import UIKit

/// CarPlay audio UI: Listen Now, Library and Downloads tabs read from the local
/// database. Playback goes through `PlaybackQueue`; the Now Playing screen shows
/// what `PlayerController` already publishes to `MPNowPlayingInfoCenter`.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPTabBarTemplateDelegate {
    private var interfaceController: CPInterfaceController?
    private var listenNow: CPListTemplate?
    private var library: CPListTemplate?
    private var downloads: CPListTemplate?

    /// Items per list; CarPlay may allow fewer in some cars.
    private static var limit: Int { min(50, Int(CPListTemplate.maximumItemCount)) }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        let listenNow = Self.tab("Listen Now", systemImage: "play.circle", empty: "Nothing played yet")
        let library = Self.tab("Library", systemImage: "square.stack", empty: "No playlists")
        let downloads = Self.tab("Downloads", systemImage: "arrow.down.circle", empty: "No downloads")
        self.listenNow = listenNow
        self.library = library
        self.downloads = downloads

        let tabBar = CPTabBarTemplate(templates: [listenNow, library, downloads])
        tabBar.delegate = self
        interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)
        for list in [listenNow, library, downloads] { reload(list) }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
        listenNow = nil
        library = nil
        downloads = nil
    }

    /// Refreshes a tab each time it is opened, so new plays and downloads show up.
    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        reload(selectedTemplate)
    }

    // MARK: - Tabs

    private static func tab(_ title: String, systemImage: String, empty: String) -> CPListTemplate {
        let list = CPListTemplate(title: title, sections: [])
        list.tabTitle = title
        list.tabImage = UIImage(systemName: systemImage)
        list.emptyViewTitleVariants = [empty]
        return list
    }

    private func reload(_ template: CPTemplate) {
        Task {
            if template === listenNow {
                await loadListenNow()
            } else if template === library {
                await loadLibrary()
            } else if template === downloads {
                downloads?.updateSections([songSection(DownloadManager.shared.tracks.map { SongItem(entity: $0) })])
            }
        }
    }

    private func loadListenNow() async {
        let db = DatabaseService.shared
        let half = Self.limit / 2
        let recent = (try? await db.fetchRecentSongs(limit: half))?.toSongItems() ?? []
        let picks = (try? await db.fetchLikedSongs())?.toSongItems() ?? []
        let sections = [
            songSection(recent, header: "Recently Played", limit: half),
            songSection(picks, header: "Quick Picks", limit: half)
        ]
        listenNow?.updateSections(sections.filter { !$0.items.isEmpty })
    }

    private func loadLibrary() async {
        let playlists = (try? await DatabaseService.shared.fetchPlaylists(limit: Self.limit - 1)) ?? []
        let liked = collectionItem("Liked Songs", thumbnail: nil, playlistId: nil)
        liked.setImage(UIImage(systemName: "heart.fill"))
        let rows = playlists.map { collectionItem($0.name, thumbnail: $0.thumbnailUrl, playlistId: $0.id) }
        library?.updateSections([CPListSection(items: [liked] + rows)])
    }

    // MARK: - Items

    /// Rows for `songs`; tapping one plays the whole list from that song.
    private func songSection(_ songs: [SongItem], header: String? = nil, limit: Int? = nil) -> CPListSection {
        let items = songs.prefix(limit ?? Self.limit).enumerated().map { index, song in
            let item = CPListItem(
                text: song.title,
                detailText: song.artists.map(\.name).joined(separator: ", "),
                image: UIImage(systemName: "music.note")
            )
            loadArtwork(song.thumbnailUrl, into: item)
            item.handler = { [weak self] _, completion in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    PlaybackQueue.play(songs, startIndex: index, log: Log.player, context: "carPlay")
                    self.showNowPlaying()
                }
                completion()
            }
            return item
        }
        return CPListSection(items: items, header: header, sectionIndexTitle: nil)
    }

    /// A playlist row (`playlistId` nil = Liked Songs) that opens its songs.
    private func collectionItem(_ title: String, thumbnail: String?, playlistId: String?) -> CPListItem {
        let item = CPListItem(text: title, detailText: nil, image: UIImage(systemName: "music.note.list"))
        item.accessoryType = .disclosureIndicator
        loadArtwork(thumbnail, into: item)
        item.handler = { [weak self] _, completion in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.openPlaylist(title, playlistId: playlistId)
            }
            completion()
        }
        return item
    }

    /// Loads songs the same way the app's playlist page does (saved copy,
    /// then the network for remote playlists).
    private func openPlaylist(_ title: String, playlistId: String?) {
        let list = CPListTemplate(title: title, sections: [])
        list.emptyViewTitleVariants = ["Loading…"]
        interfaceController?.pushTemplate(list, animated: true, completion: nil)
        Task {
            let model: PlaylistDetailViewModel
            if let playlistId {
                model = PlaylistDetailViewModel(playlistId: playlistId)
            } else {
                model = PlaylistDetailViewModel(autoPlaylistRoute: .likedSongs)
            }
            await model.load()
            list.emptyViewTitleVariants = ["No songs"]
            list.updateSections([songSection(model.playlist?.songs ?? [])])
        }
    }

    private func showNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        guard let interfaceController,
              !interfaceController.templates.contains(where: { $0 === nowPlaying }) else { return }
        interfaceController.pushTemplate(nowPlaying, animated: true, completion: nil)
    }

    private func loadArtwork(_ raw: String?, into item: CPListItem) {
        let pixels = ArtworkURLs.rung(for: CPListItem.maximumImageSize.width * 3)
        guard let raw, let url = URL(string: ArtworkURLs.sized(raw, width: pixels, height: pixels) ?? raw) else { return }
        if let cached = ArtworkLoader.cachedImage(for: url) {
            item.setImage(cached)
            return
        }
        Task {
            if let image = try? await ArtworkLoader.image(for: url) { item.setImage(image) }
        }
    }
}
