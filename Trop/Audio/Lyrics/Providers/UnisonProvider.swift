//
//  UnisonProvider.swift
//  Trop
//
//  Unison (https://docs.betterlyrics.org/unison) is community-submitted lyrics
//  keyed by video id — the one id WoofMusic already has — and answers in TTML,
//  LRC or plain text. No key, 600 reads a minute per address.
//

import Foundation

struct UnisonProvider: LyricsProvider {
    let id = "unison"
    let name = "Unison"

    private let baseURL = "https://unison.betterlyrics.org/lyrics"

    private struct Envelope: Decodable {
        struct Payload: Decodable {
            let lyrics: String
            let format: String
            let syncType: String?
        }

        let success: Bool
        let data: Payload?
    }

    func fetch(query: LyricsQuery) async throws -> [LyricLine] {
        var components = URLComponents(string: baseURL)!
        var items: [URLQueryItem] = []

        if let videoId = query.videoId, !videoId.isEmpty {
            items.append(URLQueryItem(name: "v", value: videoId))
        }
        items.append(URLQueryItem(name: "song", value: query.title))
        items.append(URLQueryItem(name: "artist", value: query.artist))
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

        let envelope = try await LyricsHTTP.decoded(Envelope.self, request)
        guard envelope.success, let payload = envelope.data, !payload.lyrics.isEmpty else {
            throw LyricsError.notFound
        }

        let lines: [LyricLine]
        switch payload.format.lowercased() {
        case "ttml":
            lines = LyricsTTML.parse(payload.lyrics)
        case "lrc":
            lines = LyricsParsing.parseStoredText(payload.lyrics)
        default:
            lines = LyricsText.plainLines(payload.lyrics)
        }
        guard !lines.isEmpty else { throw LyricsError.notFound }
        return lines
    }
}
