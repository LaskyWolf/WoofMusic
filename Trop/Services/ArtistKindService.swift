//
//  ArtistKindService.swift
//  Trop
//

import Foundation
import SwiftUI

/// Describes what kind of act an artist is ("Band", "Solo Artist", "Orchestra"…).
/// YouTube Music only says "Artist", so the type comes from MusicBrainz.
/// Each name is looked up once; hits and misses are cached in UserDefaults.
actor ArtistKindService {
    static let shared = ArtistKindService()

    private static let defaultsKey = "artistKindCache"
    private static let userAgent = "WoofMusic/1.3 ( https://github.com/LaskyWolf/WoofMusic )"
    /// MusicBrainz allows 1 request per second; a small margin keeps us under it.
    private static let requestInterval: TimeInterval = 1.1
    private static let minimumScore = 90

    /// Lowercased name → label. An empty label records a miss.
    private var cache: [String: String]
    private var inFlight: [String: Task<String?, Never>] = [:]
    private var nextRequestDate = Date.distantPast

    init() {
        cache = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    /// The artist's kind, or nil when MusicBrainz has no confident match.
    func kind(for name: String) async -> String? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if let cached = cache[key] { return cached.isEmpty ? nil : cached }
        if let task = inFlight[key] { return await task.value }

        let task = Task { await self.lookUp(name: name, key: key) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private func lookUp(name: String, key: String) async -> String? {
        // The slot is reserved before suspending, so concurrent lookups
        // queue up one interval apart even though the actor is reentrant.
        let now = Date()
        let slot = max(now, nextRequestDate)
        nextRequestDate = slot.addingTimeInterval(Self.requestInterval)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }

        guard let artists = await search(name: name) else {
            // Network or server error: don't cache, retry next time.
            return nil
        }
        let match = artists.first {
            ($0.score ?? 0) >= Self.minimumScore
                && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
        let label = match.flatMap(Self.label(for:)) ?? ""
        cache[key] = label
        UserDefaults.standard.set(cache, forKey: Self.defaultsKey)
        return label.isEmpty ? nil : label
    }

    private func search(name: String) async -> [MBArtist]? {
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/artist/")
        components?.queryItems = [
            URLQueryItem(name: "query", value: "artist:\"\(escaped)\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(MBSearchResponse.self, from: data) else {
            return nil
        }
        return decoded.artists
    }

    private static func label(for artist: MBArtist) -> String? {
        let hints = ([artist.disambiguation ?? ""] + (artist.tags ?? []).map(\.name))
            .joined(separator: " ")
            .lowercased()
        let hintWords = Set(hints.components(separatedBy: CharacterSet.alphanumerics.inverted))
        switch artist.type {
        case "Person":
            return hintWords.contains("dj") ? "DJ" : "Solo Artist"
        case "Group":
            let groupHints = ["group", "idol", "k-pop", "kpop"]
            return groupHints.contains { hints.contains($0) } ? "Group" : "Band"
        case "Orchestra": return "Orchestra"
        case "Choir": return "Choir"
        case "Character": return "Character"
        default: return nil
        }
    }

    private struct MBSearchResponse: Decodable {
        let artists: [MBArtist]
    }

    private struct MBArtist: Decodable {
        let name: String
        let type: String?
        let score: Int?
        let disambiguation: String?
        let tags: [MBTag]?
    }

    private struct MBTag: Decodable {
        let name: String
    }
}

/// Subtitle under an artist name: shows `fallback` until the artist's kind
/// resolves, and keeps it when MusicBrainz has no confident match.
struct ArtistKindLabel: View {
    let name: String
    var fallback: String = "Artist"

    @State private var kind: String?

    var body: some View {
        Text(kind ?? fallback)
            .task(id: name) {
                kind = nil
                kind = await ArtistKindService.shared.kind(for: name)
            }
    }
}
