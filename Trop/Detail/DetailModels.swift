//
//  DetailModels.swift
//  Trop
//
//  Created by 686udjie on 03/07/2026.
//

import Foundation

/// Parsed detail data for an album page.
struct AlbumDetailInfo {
    var title: String
    var artists: [YTArtist]
    var year: Int?
    var songCount: Int
    var duration: Int
    var thumbnailUrl: String?
    var playlistId: String?
    var browseId: String
    var songs: [SongItem]
}

/// Parsed detail data for an artist page.
struct ArtistDetailInfo {
    var name: String
    var thumbnailUrl: String?
    var subscriberCountText: String?
    var descriptionText: String?
    var isSubscribed: Bool
    var browseId: String
    var songs: [SongItem]
    var albums: [AlbumItem]
    var singles: [AlbumItem] = []
    var videos: [SongItem] = []
    var playlists: [PlaylistItem] = []
    var relatedArtists: [ArtistItem] = []
}

/// Parsed detail data for a playlist page.
struct PlaylistDetailInfo {
    var title: String
    var authorName: String?
    var authorBrowseId: String?
    var authorAvatarUrl: String?
    var descriptionText: String?
    var songCount: Int
    var duration: Int
    var thumbnailUrl: String?
    var playlistId: String
    var songs: [SongItem]
    /// Avatars of the people on a shared playlist, owner first. Empty otherwise.
    var collaboratorAvatarUrls: [String] = []
    /// Token for the request that lists them by name.
    var collaboratorsPanelParams: String?
    /// The signed-in account owns this playlist (YouTube sends an editable header).
    var isEditable = false
    /// The header facepile opens the "PAplaylist_collaborate" panel: a shared
    /// playlist whose collaborators can add and remove songs without owning it.
    var isCollaborative = false
}

/// Parsed detail data for a podcast page.
struct PodcastDetailInfo {
    var title: String
    var author: String?
    var descriptionText: String?
    var thumbnailUrl: String?
    var browseId: String
    var isSubscribed: Bool
    var episodes: [EpisodeItem]
}

/// Header fields of a shared playlist from its last network load. Lets the
/// edit buttons and collaborator avatars show on reopen before the refresh.
struct PlaylistHeaderSnapshot: Codable, Equatable {
    var isCollaborative: Bool
    var collaboratorAvatarUrls: [String]
    var collaboratorsPanelParams: String?
    var descriptionText: String?
}

/// Snapshots by playlist id, kept in memory and in UserDefaults.
/// Only shared playlists are stored: ownership already lives in the playlist table.
@MainActor
enum PlaylistHeaderCache {
    private static let key = "playlistHeaderCache"
    private static var entries: [String: PlaylistHeaderSnapshot] = {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: PlaylistHeaderSnapshot].self, from: data)) ?? [:]
    }()

    static func snapshot(for playlistId: String) -> PlaylistHeaderSnapshot? {
        entries[playlistId]
    }

    static func store(_ info: PlaylistDetailInfo, for playlistId: String) {
        let isShared = info.isCollaborative || !info.collaboratorAvatarUrls.isEmpty
        let snapshot = isShared ? PlaylistHeaderSnapshot(
            isCollaborative: info.isCollaborative,
            collaboratorAvatarUrls: info.collaboratorAvatarUrls,
            collaboratorsPanelParams: info.collaboratorsPanelParams,
            descriptionText: info.descriptionText
        ) : nil
        guard entries[playlistId] != snapshot else { return }
        entries[playlistId] = snapshot
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

extension PlaylistDetailInfo {
    mutating func apply(_ snapshot: PlaylistHeaderSnapshot) {
        isCollaborative = snapshot.isCollaborative
        collaboratorAvatarUrls = snapshot.collaboratorAvatarUrls
        collaboratorsPanelParams = snapshot.collaboratorsPanelParams
        descriptionText = descriptionText ?? snapshot.descriptionText
    }
}

/// Artist pages from recent loads, so reopening one shows it at once.
/// Kept in memory only; entries older than `lifetime` still show but get refreshed.
@MainActor
enum ArtistDetailCache {
    static let lifetime: TimeInterval = 10 * 60
    // ponytail: unbounded, one entry per artist opened this session; add an LRU cap if memory grows.
    private static var entries: [String: (info: ArtistDetailInfo, loadedAt: Date)] = [:]

    static func entry(for browseId: String) -> (info: ArtistDetailInfo, isFresh: Bool)? {
        guard let entry = entries[browseId] else { return nil }
        return (entry.info, Date().timeIntervalSince(entry.loadedAt) < lifetime)
    }

    static func store(_ info: ArtistDetailInfo) {
        entries[info.browseId] = (info, Date())
    }

    /// Keeps the cached copy in step with a local change without resetting its age.
    static func update(_ info: ArtistDetailInfo) {
        guard let loadedAt = entries[info.browseId]?.loadedAt else { return }
        entries[info.browseId] = (info, loadedAt)
    }
}
