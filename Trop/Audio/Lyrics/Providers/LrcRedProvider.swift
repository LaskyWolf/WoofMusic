//
//  LrcRedProvider.swift
//  Trop
//
//  lrc.red (the search backend Binimum's lyrics API redirects to): a search
//  returns hits with an ISRC and a TTML URL, so one request finds the track and
//  a second one brings syllable- or word-timed lyrics.
//

import Foundation

struct LrcRedProvider: LyricsProvider {
    let id = "lrcred"
    let name = "lrc.red"

    private let searchURL = "https://lrc.red/api/v1"

    private struct Search: Decodable {
        struct Hit: Decodable {
            let isrc: String?
            let trackName: String?
            let artistName: String?
            let albumName: String?
            let duration: Int?
            let lyricsURL: String?
            let timingType: String?

            enum CodingKeys: String, CodingKey {
                case isrc, duration
                case trackName = "track_name"
                case artistName = "artist_name"
                case albumName = "album_name"
                case lyricsURL = "lyricsUrl"
                case timingType = "timing_type"
            }
        }

        let results: [Hit]
    }

    func fetch(query: LyricsQuery) async throws -> [LyricLine] {
        var components = URLComponents(string: searchURL)!
        var items = [
            URLQueryItem(name: "track", value: query.title),
            URLQueryItem(name: "artist", value: query.artist)
        ]
        if let album = query.album, !album.isEmpty {
            items.append(URLQueryItem(name: "album", value: album))
        }
        if query.durationSeconds > 0 {
            items.append(URLQueryItem(name: "duration", value: String(query.durationSeconds)))
        }
        components.queryItems = items

        guard let url = components.url else { throw LyricsError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12

        let search = try await LyricsHTTP.decoded(Search.self, request)
        guard let hit = bestHit(in: search.results, query: query),
              let lyricsURL = hit.lyricsURL.flatMap(URL.init(string:)) else {
            throw LyricsError.notFound
        }

        var lyricsRequest = URLRequest(url: lyricsURL)
        lyricsRequest.timeoutInterval = 12
        let data = try await LyricsHTTP.get(lyricsRequest)
        guard let body = String(data: data, encoding: .utf8), !body.isEmpty else { throw LyricsError.notFound }

        let lines = body.contains("<tt")
            ? LyricsTTML.parse(body)
            : LyricsParsing.parseStoredText(body)
        guard !lines.isEmpty else { throw LyricsError.notFound }
        return lines
    }

    /// Word timing first, then line timing, then whatever is closest in length.
    private func bestHit(in hits: [Search.Hit], query: LyricsQuery) -> Search.Hit? {
        let candidates = hits.filter { $0.lyricsURL != nil }
        guard !candidates.isEmpty else { return nil }

        func score(_ hit: Search.Hit) -> Double {
            var value = 0.0
            switch hit.timingType?.lowercased() {
            case "word": value += 4
            case "syllable": value += 3
            case "line": value += 2
            default: value += 0
            }
            if let duration = hit.duration, query.durationSeconds > 0 {
                let difference = abs(duration - query.durationSeconds)
                value += difference <= 2 ? 3 : difference <= 6 ? 1 : 0
            }
            if let artist = hit.artistName, !artist.isEmpty,
               artist.lowercased().contains(query.artist.lowercased()) {
                value += 1
            }
            return value
        }

        return candidates.max { score($0) < score($1) }
    }
}
