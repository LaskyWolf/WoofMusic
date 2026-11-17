//
//  PaxsenixProvider.swift
//  Trop
//
//  Paxsenix (api.paxsenix.org) proxies Apple Music's own lyrics: a search
//  returns catalogue ids, then one id brings word-by-word lyrics. It is the
//  only source here that needs an account key, so it stays silent until one is
//  pasted in Settings → Lyrics.
//
//  The host's answers are only loosely documented, so the response is read
//  structurally rather than by a fixed schema: a TTML document is parsed as
//  TTML, Apple's richsync shape (timestamp plus timed pieces) is rebuilt into
//  word timings, and anything else falls back to the LRC/plain text a string
//  field carries. A miss throws instead of inventing lines.
//

import Foundation

extension LyricsAPIKeys {
    static let paxsenixDefaultsKey = "settings.paxsenixAPIKey"

    static var paxsenix: String? {
        guard let key = UserDefaults.standard.string(forKey: paxsenixDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }
}

struct PaxsenixProvider: LyricsProvider {
    let id = "paxsenix"
    let name = "Paxsenix"

    private let baseURL = "https://api.paxsenix.org"

    func fetch(query: LyricsQuery) async throws -> [LyricLine] {
        guard let key = LyricsAPIKeys.paxsenix else { throw LyricsError.notFound }
        guard let songID = try await searchID(key: key, query: query) else { throw LyricsError.notFound }

        var components = URLComponents(string: baseURL + "/lyrics/applemusic")!
        components.queryItems = [URLQueryItem(name: "id", value: songID)]
        guard let url = components.url else { throw LyricsError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")

        let data = try await LyricsHTTP.get(request)
        guard let body = String(data: data, encoding: .utf8), !body.isEmpty else { throw LyricsError.notFound }

        let lines = Self.parse(body)
        guard !lines.isEmpty else { throw LyricsError.notFound }
        return lines
    }

    // MARK: - Search

    private func searchID(key: String, query: LyricsQuery) async throws -> String? {
        var components = URLComponents(string: baseURL + "/apple-music/search")!
        components.queryItems = [URLQueryItem(name: "q", value: "\(query.title) \(query.artist)")]
        guard let url = components.url else { throw LyricsError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")

        let data = try await LyricsHTTP.get(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }

        var candidates: [Candidate] = []
        Self.collectTracks(object, into: &candidates)
        guard !candidates.isEmpty else { return nil }

        let wantedTitle = Self.normalized(query.title)
        let wantedArtist = Self.normalized(query.artist)

        func score(_ candidate: Candidate) -> Double {
            var value = 0.0
            let title = Self.normalized(candidate.title)
            if title == wantedTitle {
                value += 5
            } else if title.contains(wantedTitle) || wantedTitle.contains(title) {
                value += 2
            }
            let artist = Self.normalized(candidate.artist)
            if !wantedArtist.isEmpty, artist.contains(wantedArtist) || wantedArtist.contains(artist) {
                value += 3
            }
            if title.contains("karaoke") || title.contains("tribute") || title.contains("instrumental") {
                value -= 4
            }
            return value
        }

        return candidates
            .map { ($0, score($0)) }
            .max { $0.1 < $1.1 }
            .flatMap { $0.1 > 0 ? $0.0.id : nil }
    }

    private struct Candidate {
        let id: String
        let title: String
        let artist: String
    }

    /// Apple-shaped payloads nest the id under `data[].id`, others put it at the
    /// top of each row, so every dictionary that carries an id and a name is
    /// taken as a candidate wherever it sits.
    private static func collectTracks(_ element: Any, into destination: inout [Candidate]) {
        if let array = element as? [Any] {
            for item in array { collectTracks(item, into: &destination) }
            return
        }
        guard let object = element as? [String: Any] else { return }

        let attributes = object["attributes"] as? [String: Any]
        let id = firstString(in: object, keys: ["id", "songId", "trackId", "catalogId"])
        let title = firstString(in: attributes ?? object, keys: ["name", "title", "trackName", "songName"])
        if let id, let title, !id.isEmpty, !title.isEmpty {
            let artist = firstString(in: attributes ?? object,
                                     keys: ["artistName", "artist", "artist_name", "subtitle"]) ?? ""
            destination.append(Candidate(id: id, title: title, artist: artist))
        }

        for value in object.values { collectTracks(value, into: &destination) }
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    // MARK: - Response

    static func parse(_ body: String) -> [LyricLine] {
        if body.contains("<tt") {
            let lines = LyricsTTML.parse(body)
            if !lines.isEmpty { return lines }
        }

        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return LyricsParsing.parseStoredText(body)
        }

        if let richsync = appleLines(in: object), !richsync.isEmpty { return richsync }
        if let text = firstLyricsString(in: object) {
            let lines = LyricsParsing.parseStoredText(text)
            if !lines.isEmpty { return lines }
        }
        return []
    }

    /// Apple's richsync shape: `content` of `{ timestamp, text: [{ text }] }`,
    /// timestamps in milliseconds.
    private static func appleLines(in element: Any) -> [LyricLine]? {
        guard let object = element as? [String: Any] else {
            if let array = element as? [Any] {
                for item in array {
                    if let found = appleLines(in: item) { return found }
                }
            }
            return nil
        }

        if let content = object["content"] as? [[String: Any]] {
            let lines: [LyricLine] = content.compactMap { entry in
                guard let timestamp = (entry["timestamp"] as? NSNumber)?.doubleValue else { return nil }
                let pieces = entry["text"] as? [[String: Any]] ?? []
                let words: [LyricWord] = pieces.compactMap { piece in
                    guard let text = piece["text"] as? String else { return nil }
                    return LyricWord(text: text, startTime: timestamp / 1000)
                }
                let joined = words.map(\.text).joined()
                guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                var line = LyricLine(text: joined, startTime: timestamp / 1000)
                line.words = words.isEmpty ? nil : words
                return line
            }
            if !lines.isEmpty { return lines }
        }

        for value in object.values {
            if let found = appleLines(in: value) { return found }
        }
        return nil
    }

    private static func firstLyricsString(in element: Any) -> String? {
        if let object = element as? [String: Any] {
            for key in ["lyrics", "lrc", "syncedLyrics", "plainLyrics", "lines", "line", "text", "content"] {
                if let value = object[key] as? String, value.count > 12, value.contains("\n") {
                    return value
                }
            }
            for value in object.values {
                if let found = firstLyricsString(in: value) { return found }
            }
            return nil
        }
        if let array = element as? [Any] {
            for item in array {
                if let found = firstLyricsString(in: item) { return found }
            }
        }
        return nil
    }

    private static func normalized(_ text: String) -> String {
        let lowered = text.lowercased()
        let allowed = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        return String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: .whitespaces)
    }
}
