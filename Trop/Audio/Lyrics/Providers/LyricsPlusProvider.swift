//
//  LyricsPlusProvider.swift
//  Trop
//
//  LyricsPlus — the Go provider behind YouLy+ (ibratabian17/LyricsPlus). It
//  races Apple, Spotify and QQ upstream and answers with whichever hit has the
//  best timing, handed back as Apple TTML through `/v1/ttml/get`, so syllable
//  timings come out of one request. No key and no account.
//

import Foundation

struct LyricsPlusProvider: LyricsProvider {
    let id = "lyricsplus"
    let name = "LyricsPlus"

    private let baseURL = "https://lyricsplus.prjktla.my.id/v1/ttml/get"

    /// The endpoint takes `duration` in seconds with an optional millisecond
    /// fraction, and matching gets noticeably better when it is sent.
    func fetch(query: LyricsQuery) async throws -> [LyricLine] {
        var components = URLComponents(string: baseURL)!
        var items = [
            URLQueryItem(name: "title", value: query.title),
            URLQueryItem(name: "artist", value: query.artist)
        ]
        if let album = query.album, !album.isEmpty {
            items.append(URLQueryItem(name: "album", value: album))
        }
        if query.duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(format: "%.3f", query.duration)))
        }
        components.queryItems = items

        guard let url = components.url else { throw LyricsError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await LyricsHTTP.get(request)
        guard let payload = try? JSONDecoder().decode(Response.self, from: data),
              !payload.ttml.isEmpty else { throw LyricsError.notFound }

        let lines = LyricsTTML.parse(payload.ttml)
        guard !lines.isEmpty else { throw LyricsError.notFound }
        return lines
    }

    private struct Response: Decodable {
        let ttml: String
    }
}
