//
//  DetailRoute.swift
//  Trop
//
//  Created by 686udjie on 03/07/2026.
//

import Foundation
import SwiftUI

/// Route destinations for detail view navigation.
/// Used with NavigationStack + NavigationPath to push detail screens.
enum DetailRoute: Hashable, Identifiable {
    var id: String {
        switch self {
        case .album(let browseId): return "album_\(browseId)"
        case .artist(let browseId): return "artist_\(browseId)"
        case .playlist(let playlistId): return "playlist_\(playlistId)"
        case .podcast(let browseId): return "podcast_\(browseId)"
        case .autoPlaylist(let route): return "autoPlaylist_\(String(describing: route))"
        case .history: return "history"
        case .settings: return "settings"
        case .downloads: return "downloads"
        }
    }

    case album(browseId: String)
    case artist(browseId: String)
    case playlist(playlistId: String)
    case podcast(browseId: String)
    case autoPlaylist(AutoPlaylistRoute)
    case history
    case settings
    case downloads
}

/// Shared view resolving a `DetailRoute` to its target destination view.
struct DetailRouteDestinationView: View {
    let route: DetailRoute

    var body: some View {
        switch route {
        case .album(let browseId):
            AlbumDetailView(browseId: browseId)
        case .artist(let browseId):
            ArtistDetailView(browseId: browseId)
        case .playlist(let playlistId):
            PlaylistDetailView(playlistId: playlistId)
        case .podcast(let browseId):
            PodcastDetailView(browseId: browseId)
        case .autoPlaylist(let autoRoute):
            PlaylistDetailView(autoPlaylistRoute: autoRoute)
        case .history:
            HistoryScreenView()
        case .settings:
            SettingsView()
        case .downloads:
            DownloadsView()
        }
    }
}

enum AutoPlaylistRoute: Hashable {
    case likedSongs
    case topSongs(limit: Int)
}

/// Dispatches a tapped `YTItem` to playback or a pushed detail route.
/// Collapses the per-tab `handleItemTap`/`openItem` switches (Home/Search/Explore).
enum YTItemRouter {
    static func route(
        _ item: YTItem,
        playSong: (SongItem) -> Void,
        appendRoute: (DetailRoute) -> Void
    ) {
        switch item {
        case .song(let s):
            playSong(s)
        case .episode(let e):
            playSong(e.toSongItem())
        default:
            if let route = detailRoute(for: item) { appendRoute(route) }
        }
    }

    /// The page `item` opens, or nil for songs and episodes, which play.
    /// Cards also use it as their cover's zoom source, so both always match.
    static func detailRoute(for item: YTItem) -> DetailRoute? {
        switch item {
        case .song, .episode: nil
        case .album(let a): .album(browseId: a.browseId)
        case .artist(let a): .artist(browseId: a.browseId)
        case .playlist(let p): .playlist(playlistId: p.id)
        case .podcast(let p): .podcast(browseId: p.browseId)
        }
    }
}

enum TopPeriod: String, CaseIterable, Hashable, Identifiable {
    case allTime = "All Time"
    case year = "Past Year"
    case month = "Past Month"
    case day = "Past 24 Hours"

    var id: String { rawValue }
    var displayName: String { rawValue }

    var dateFrom: Date {
        let now = Date()
        switch self {
        case .allTime: return Date.distantPast
        case .year: return Calendar.current.date(byAdding: .year, value: -1, to: now) ?? now
        case .month: return Calendar.current.date(byAdding: .month, value: -1, to: now) ?? now
        case .day: return Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
        }
    }
}
