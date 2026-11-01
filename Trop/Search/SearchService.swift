//
// SearchService.swift
// Trop
//
// Created by 686udjie on 30/06/2026.
//

import Foundation
import GRDB

actor SearchService {
    nonisolated static let shared = SearchService()
    private let innerTube = InnerTubeClient.tropShared
    private let db = DatabaseService.shared
    private var searchTask: Task<[String: Any], Error>?
    private var searchGeneration = 0

    func search(query: String, params: String? = nil, client: YouTubeClient = .webRemix) async throws -> [String: Any] {
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let task = Task { () -> [String: Any] in
            try await innerTube.search(query: query, params: params, client: client)
        }
        searchTask = task
        let result = try await task.value
        guard generation == searchGeneration else { throw CancellationError() }
        return result
    }

    /// YouTube Music's autocomplete. Needs no account, and works for guests the
    /// same way. SwiftyTube keeps its request builder internal.
    func suggestions(query: String, country: String) async throws -> [String] {
        let config = await innerTube.config
        let web = config.defaultClient
        let origin = config.service.origin
        var request = URLRequest(url: config.service.baseURL.appendingPathComponent("music/get_search_suggestions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(origin, forHTTPHeaderField: "X-Origin")
        request.setValue(origin + "/", forHTTPHeaderField: "Referer")
        request.setValue(web.userAgent, forHTTPHeaderField: "User-Agent")
        let clientContext: [String: Any] = [
            "clientName": web.clientName,
            "clientVersion": web.clientVersion,
            "gl": country.isEmpty ? "US" : country,
            "hl": config.defaultLocale.hl
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: ["context": ["client": clientContext], "input": query])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return Self.parseSuggestions(data)
    }

    /// Takes the text suggestions. The answer's other section lists songs and
    /// artists, which have no `searchEndpoint`.
    nonisolated static func parseSuggestions(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["contents"] as? [[String: Any]] else { return [] }
        return sections.flatMap { section -> [String] in
            let shelf = section["searchSuggestionsSectionRenderer"] as? [String: Any]
            let items = shelf?["contents"] as? [[String: Any]] ?? []
            return items.compactMap { item in
                let suggestion = (item["searchSuggestionRenderer"] ?? item["historySuggestionRenderer"]) as? [String: Any]
                let endpoint = suggestion?["navigationEndpoint"] as? [String: Any]
                return (endpoint?["searchEndpoint"] as? [String: Any])?["query"] as? String
            }
        }
    }

    struct LocalSearchResults {
        var songs: [SongEntity] = []
        var artists: [ArtistEntity] = []
        var albums: [AlbumEntity] = []
        var playlists: [PlaylistEntity] = []
    }

    func localSearch(query: String) async throws -> LocalSearchResults {
        let pattern = "%\(query)%"
        async let songs = db.fetchAll(
            SongEntity.self,
            sql: "SELECT * FROM song WHERE title LIKE ? OR artist_name LIKE ? ORDER BY total_play_time DESC LIMIT 50",
            arguments: [pattern, pattern]
        )
        async let artists = db.fetchAll(ArtistEntity.self, sql: "SELECT * FROM artist WHERE name LIKE ? LIMIT 20", arguments: [pattern])
        async let albums = db.fetchAll(AlbumEntity.self, sql: "SELECT * FROM album WHERE title LIKE ? LIMIT 20", arguments: [pattern])
        async let playlists = db.fetchAll(PlaylistEntity.self, sql: "SELECT * FROM playlist WHERE name LIKE ? LIMIT 20", arguments: [pattern])
        let results = try await LocalSearchResults(
            songs: songs, artists: artists, albums: albums,
            playlists: playlists.filter { !PlaylistEntity.hiddenIds.contains($0.id) }
        )
        return results
    }
}
