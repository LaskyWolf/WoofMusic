//
//  BetterLyricsProvider.swift
//  Trop
//
//  Better Lyrics (https://docs.betterlyrics.org) serves Apple's own TTML:
//  syllable-level timing, backing vocals and per-line translations. Without a
//  key it answers for tracks somebody already asked for and rejects the rest
//  with 401, so a key pasted in Settings → Lyrics unlocks the whole catalogue.
//

import Foundation

/// Optional keys. Stored through SettingsStore's defaults, read from wherever
/// a provider runs (they are not main-actor state).
enum LyricsAPIKeys {
    static let betterLyricsDefaultsKey = "settings.betterLyricsAPIKey"

    static var betterLyrics: String? {
        guard let key = UserDefaults.standard.string(forKey: betterLyricsDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }
}

struct BetterLyricsProvider: LyricsProvider {
    let id = "betterlyrics"
    let name = "Better Lyrics"

    private let baseURL = "https://api.betterlyrics.org/getLyrics"

    func fetch(query: LyricsQuery) async throws -> [LyricLine] {
        var components = URLComponents(string: baseURL)!
        var items = [
            URLQueryItem(name: "s", value: query.title),
            URLQueryItem(name: "a", value: query.artist)
        ]
        if let album = query.album, !album.isEmpty {
            items.append(URLQueryItem(name: "al", value: album))
        }
        if query.durationSeconds > 0 {
            items.append(URLQueryItem(name: "d", value: String(query.durationSeconds)))
        }
        if let videoId = query.videoId, !videoId.isEmpty {
            items.append(URLQueryItem(name: "v", value: videoId))
        }
        components.queryItems = items

        guard let url = components.url else { throw LyricsError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        if let key = LyricsAPIKeys.betterLyrics {
            request.setValue(key, forHTTPHeaderField: "X-API-Key")
        }

        // A miss, a 401 without a key and a 503 in cache-only mode all end as
        // .notFound: the chain then asks the next provider.
        let json = try await LyricsHTTP.getJSON(request)
        guard let ttml = json["ttml"] as? String, !ttml.isEmpty else { throw LyricsError.notFound }

        let lines = LyricsTTML.parse(ttml)
        guard !lines.isEmpty else { throw LyricsError.notFound }
        return lines
    }
}
