//
//  CoverSearch.swift
//  Trop
//
//  Cover art search across two free catalogues that need no key: the iTunes
//  Search API and Deezer. Both answer with a square cover we can ask for at full
//  size, which is what the picker grid shows. Nothing here throws: a source that
//  fails or times out just contributes no rows.
//

import Foundation
import UIKit

struct CoverCandidate: Identifiable, Hashable {
    let id: String
    let url: URL
    let title: String
    let artist: String
    let source: String
}

enum CoverSearch {
    /// Result cap per source; the grid shows them in the order they arrived.
    private static let limit = 40

    static func search(title: String, artist: String, album: String?) async -> [CoverCandidate] {
        let titlePart = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artistPart = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !titlePart.isEmpty else { return [] }

        var queries: [String] = []
        if !artistPart.isEmpty { queries.append("\(artistPart) \(titlePart)") }
        queries.append(titlePart)
        if let album, !album.isEmpty, album != titlePart {
            queries.append(albumPart(album, artist: artistPart))
        }

        var found: [CoverCandidate] = []
        await withTaskGroup(of: [CoverCandidate].self) { group in
            for query in queries.prefix(2) {
                group.addTask { await itunes(query: query, limit: limit) }
                group.addTask { await deezer(query: query, limit: limit) }
            }
            for await batch in group {
                found.append(contentsOf: batch)
            }
        }
        // Same artwork often comes from both catalogues at different sizes;
        // the path before the size suffix is the identity.
        var seen = Set<String>()
        var unique: [CoverCandidate] = []
        for item in found where !seen.contains(item.id) {
            seen.insert(item.id)
            unique.append(item)
        }
        // Rows whose album and artist match what is playing go first.
        return unique.sorted { lhs, rhs in
            score(lhs, title: titlePart, artist: artistPart) > score(rhs, title: titlePart, artist: artistPart)
        }
    }

    private static func albumPart(_ album: String, artist: String) -> String {
        artist.isEmpty ? album : "\(artist) \(album)"
    }

    private static func score(_ item: CoverCandidate, title: String, artist: String) -> Int {
        var value = 0
        let t = item.title.lowercased()
        let a = item.artist.lowercased()
        if !title.isEmpty, t.contains(title.lowercased()) { value += 2 }
        if !artist.isEmpty, a.contains(artist.lowercased()) { value += 3 }
        if t.contains("karaoke") || t.contains("tribute") || t.contains("cover version") { value -= 4 }
        return value
    }

    // MARK: - iTunes

    private static func itunes(query: String, limit: Int) async -> [CoverCandidate] {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            .init(name: "term", value: query),
            .init(name: "entity", value: "album"),
            .init(name: "limit", value: "\(limit)")
        ]
        guard let url = components?.url,
              let data = await fetch(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["results"] as? [[String: Any]]
        else { return [] }

        return rows.compactMap { row in
            guard let art = row["artworkUrl100"] as? String else { return nil }
            // The size lives in the file name: 100x100bb.jpg → 3000x3000bb.jpg.
            let full = art
                .replacingOccurrences(of: "100x100bb", with: "3000x3000bb")
                .replacingOccurrences(of: "100x100-75", with: "3000x3000-75")
            guard let url = URL(string: full) else { return nil }
            let name = row["collectionName"] as? String ?? row["trackName"] as? String ?? ""
            let artist = row["artistName"] as? String ?? ""
            return CoverCandidate(
                id: url.absoluteString, url: url,
                title: name, artist: artist, source: "Apple"
            )
        }
    }

    // MARK: - Deezer

    private static func deezer(query: String, limit: Int) async -> [CoverCandidate] {
        var components = URLComponents(string: "https://api.deezer.com/search/album")
        components?.queryItems = [
            .init(name: "q", value: query),
            .init(name: "limit", value: "\(limit)")
        ]
        guard let url = components?.url,
              let data = await fetch(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]]
        else { return [] }

        return rows.compactMap { row in
            guard let art = row["cover_xl"] as? String, let url = URL(string: art) else { return nil }
            let name = row["title"] as? String ?? ""
            let artist = (row["artist"] as? [String: Any])?["name"] as? String ?? ""
            return CoverCandidate(
                id: url.absoluteString, url: url,
                title: name, artist: artist, source: "Deezer"
            )
        }
    }

    // MARK: - Helpers

    private static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("WoofMusic/1.1 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    /// Full-size image for a picked row.
    static func download(_ candidate: CoverCandidate) async -> UIImage? {
        guard let data = await fetch(candidate.url) else { return nil }
        return UIImage(data: data)
    }
}
