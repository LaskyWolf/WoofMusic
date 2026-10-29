//
//  ArtistKindService.swift
//  Trop
//

import Foundation
import SwiftUI

/// Describes what kind of act an artist is ("Band", "Singer", "Rapper"…).
/// YouTube Music only says "Artist", so the type comes from MusicBrainz.
/// Each name is looked up once; hits and misses are cached in UserDefaults.
actor ArtistKindService {
    static let shared = ArtistKindService()

    /// Bump the version when the labels change, so old entries are looked up again.
    private static let defaultsKey = "artistKindCache.v2"
    private static let legacyDefaultsKey = "artistKindCache"
    private static let userAgent = "WoofMusic/1.3 ( https://github.com/LaskyWolf/WoofMusic )"
    /// MusicBrainz allows 1 request per second; a small margin keeps us under it.
    private static let requestInterval: TimeInterval = 1.1
    /// MusicBrainz answers 503 to roughly one request in six even at that pace.
    private static let maxAttempts = 3
    private static let minimumScore = 90
    /// Keeps the UserDefaults entry small; it is rewritten on every new name.
    private static let maxCachedNames = 500

    /// Lowercased name → label. An empty label records a miss.
    private var cache: [String: String]
    private var nextRequestDate = Date.distantPast

    init() {
        cache = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        UserDefaults.standard.removeObject(forKey: Self.legacyDefaultsKey)
    }

    /// The artist's kind, or nil when MusicBrainz has no confident match.
    /// The lookup runs in the caller's task: when a row scrolls away and its
    /// task is cancelled, the lookup leaves the queue instead of delaying the
    /// rows still on screen.
    func kind(for name: String) async -> String? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        for _ in 0..<Self.maxAttempts {
            if let cached = cache[key] { return cached.isEmpty ? nil : cached }
            guard await waitForTurn() else { return nil }
            // Another caller may have looked the same name up while this one waited.
            if let cached = cache[key] { return cached.isEmpty ? nil : cached }
            guard let artists = await search(name: name) else {
                // Rate limited, offline or cancelled: don't cache, try again.
                continue
            }
            let match = artists.first {
                ($0.score ?? 0) >= Self.minimumScore
                    && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }
            let label = match.flatMap(Self.label(for:)) ?? ""
            cache[key] = label
            // ponytail: evicts arbitrary names, not the oldest; an evicted name is just looked up again.
            while cache.count > Self.maxCachedNames, let evicted = cache.keys.first(where: { $0 != key }) {
                cache.removeValue(forKey: evicted)
            }
            UserDefaults.standard.set(cache, forKey: Self.defaultsKey)
            return label.isEmpty ? nil : label
        }
        return nil
    }

    /// Waits until a request may go out under the rate limit. Returns false when
    /// the caller is cancelled while waiting. Checking and claiming the slot
    /// happen without a suspension in between, so the actor keeps them atomic.
    private func waitForTurn() async -> Bool {
        while !Task.isCancelled {
            let wait = nextRequestDate.timeIntervalSinceNow
            if wait <= 0 {
                nextRequestDate = Date().addingTimeInterval(Self.requestInterval)
                return true
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            } catch {
                return false
            }
        }
        return false
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
        let disambiguation = (artist.disambiguation ?? "").lowercased()
        let tags = (artist.tags ?? []).map(\.name).joined(separator: " ").lowercased()
        switch artist.type {
        case "Person":
            // The disambiguation ("Italian rapper", "Scottish DJ and producer")
            // is curated; tags are crowd-sourced, so they only break the tie.
            return role(in: disambiguation) ?? role(in: tags) ?? "Solo Artist"
        case "Group":
            let groupHints = ["group", "idol", "k-pop", "kpop"]
            let hints = disambiguation + " " + tags
            return groupHints.contains { hints.contains($0) } ? "Group" : "Band"
        case "Orchestra": return "Orchestra"
        case "Choir": return "Choir"
        case "Character": return "Character"
        default: return nil
        }
    }

    /// A solo artist's role from free text, or nil when it names none.
    private static func role(in text: String) -> String? {
        let words = Set(text.components(separatedBy: CharacterSet.alphanumerics.inverted))
        let isDJ = words.contains("dj")
        let isProducer = words.contains("producer")
        if isDJ { return isProducer ? "DJ/Producer" : "DJ" }
        if words.contains("rapper") || words.contains("rap") { return "Rapper" }
        if words.contains("singer") || words.contains("vocalist") { return "Singer" }
        if isProducer { return "Producer" }
        if words.contains("composer") { return "Composer" }
        return nil
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
