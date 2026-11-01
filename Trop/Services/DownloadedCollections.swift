//
//  DownloadedCollections.swift
//  Trop
//

import Combine
import Foundation
import GRDB
import Observation

/// Which playlists and albums have their songs saved on this iPhone.
@MainActor
@Observable
final class DownloadedCollections {
    static let shared = DownloadedCollections()

    /// Bare playlist ids and album browse ids with every song saved.
    private var complete: Set<String> = []
    /// The same ids, with at least one song saved.
    private var withDownloads: Set<String> = []
    @ObservationIgnored private var subscription: AnyCancellable?

    private init() {
        let downloads = DownloadManager.shared.$downloadedIds.map { _ in () }
        let library = NotificationCenter.default.publisher(for: .libraryDidChange).map { _ in () }
        // Debounced: a big download changes this at every song. Also runs once at the start.
        subscription = downloads.merge(with: library)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.refresh() }
            }
    }

    /// Whether the album or playlist a route opens has every song saved.
    func isComplete(_ route: DetailRoute?) -> Bool {
        switch route {
        case .album(let browseId): complete.contains(browseId)
        case .playlist(let playlistId): complete.contains(PlaylistSongEdits.bareId(playlistId))
        default: false
        }
    }

    func hasDownloads(playlistId: String) -> Bool {
        withDownloads.contains(PlaylistSongEdits.bareId(playlistId))
    }

    /// Remembers an album's available songs: nothing else in the database links them to it.
    func saveSongs(_ songIds: [String], ofAlbum browseId: String) async {
        try? await DatabaseService.shared.write { db in
            try db.execute(sql: "DELETE FROM album_song WHERE album_id = ?", arguments: [browseId])
            for songId in songIds {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO album_song (album_id, song_id) VALUES (?, ?)",
                    arguments: [browseId, songId]
                )
            }
        }
        await refresh()
    }

    func refresh() async {
        // Search opens a playlist by its bare id, the library by its VL id.
        let rows: [(id: String, isComplete: Bool, total: Int)]? = try? await DatabaseService.shared.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT m.playlist_id AS id, COUNT(d.id) = COUNT(*) AS is_complete, COUNT(*) AS total
                    FROM playlist_song_map m
                    JOIN song s ON s.id = m.song_id
                    LEFT JOIN downloaded_track d ON d.id = m.song_id
                    WHERE s.is_unavailable = 0
                    GROUP BY m.playlist_id HAVING COUNT(d.id) > 0
                    UNION ALL
                    SELECT a.album_id, COUNT(d.id) = COUNT(*), COUNT(*)
                    FROM album_song a
                    LEFT JOIN downloaded_track d ON d.id = a.song_id
                    GROUP BY a.album_id HAVING COUNT(d.id) > 0
                    """
            )
            .map { (PlaylistSongEdits.bareId($0["id"] as String), $0["is_complete"] as Bool, $0["total"] as Int) }
        }
        guard let rows else { return }
        let newWithDownloads = Set(rows.map(\.id))
        if withDownloads != newWithDownloads { withDownloads = newWithDownloads }
        // A playlist can have two snapshots, under its bare and VL ids. An old one mustn't win.
        let newest = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { $0.total >= $1.total ? $0 : $1 })
        let newComplete = Set(newest.values.filter(\.isComplete).map(\.id))
        if complete != newComplete { complete = newComplete }
    }
}
