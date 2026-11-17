//
//  CanvasService.swift
//  Trop
//
//  The short looping video behind a song — what Spotify calls Canvas.
//  Two sources sit behind `CanvasSource`: Spotify's own clips, which need the
//  listener's session cookie (see SpotifyCanvasSource), and Apple Music's motion
//  artwork, which needs no account and covers every track Spotify has no clip
//  for. The service walks them in order and stops at the first clip.
//

import Foundation

enum CanvasError: Error {
    case unavailable
}

// MARK: - Source

protocol CanvasSource: Sendable {
    var name: String { get }
    func canvasURL(title: String, artist: String, album: String?) async throws -> URL?
}

/// Apple Music's animated artwork: two HLS clips per album (square and 3:4).
struct AppleMotionCanvas: CanvasSource {
    let name = "Apple Music"
    /// Apple's catalogue is reachable from one storefront; art is the same.
    var storefront = "us"

    func canvasURL(title: String, artist: String, album: String?) async throws -> URL? {
        guard !title.isEmpty, !artist.isEmpty else { return nil }

        var components = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(title) \(artist)"),
            URLQueryItem(name: "types", value: "albums"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "extend", value: "editorialVideo")
        ]
        guard let url = components.url else { throw CanvasError.unavailable }

        for attempt in 0..<2 {
            let token = try await AppleWebToken.shared.token(forceRefresh: attempt > 0)
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
            request.setValue(CanvasHTTP.userAgent, forHTTPHeaderField: "User-Agent")

            guard let data = try? await CanvasHTTP.data(request),
                  let search = try? JSONDecoder().decode(Search.self, from: data) else { continue }

            let albums = search.results.albums?.data ?? []
            guard let best = bestAlbum(in: albums, title: title, artist: artist, album: album),
                  let motion = best.attributes.editorialVideo?.bestURL else {
                return nil
            }
            return URL(string: motion)
        }
        throw CanvasError.unavailable
    }

    /// The album that actually holds the track: same album name when we know it,
    /// the artist matching, and never a tribute/karaoke release.
    private func bestAlbum(in albums: [Search.Album], title: String, artist: String, album: String?) -> Search.Album? {
        let wantedAlbum = normalized(album)
        let wantedArtist = normalized(artist)

        func score(_ album: Search.Album) -> Double {
            var value = 0.0
            let name = normalized(album.attributes.name)
            let owner = normalized(album.attributes.artistName)
            if !wantedAlbum.isEmpty, name == wantedAlbum { value += 3 }
            if owner == wantedArtist { value += 4 }
            if owner.contains(wantedArtist) || wantedArtist.contains(owner) { value += 2 }
            if album.attributes.editorialVideo == nil { value -= 6 }
            if name.contains("karaoke") || name.contains("tribute") || name.contains("instrumental") { value -= 4 }
            if name.contains("single") || name == normalized(title) { value -= 1 }
            return value
        }

        return albums
            .filter { $0.attributes.editorialVideo != nil }
            .max { score($0) < score($1) }
    }

    private func normalized(_ text: String?) -> String {
        guard let text else { return "" }
        let lowered = text.lowercased()
        let allowed = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        return String(String.UnicodeScalarView(allowed))
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Response

    private struct Search: Decodable {
        struct Results: Decodable {
            let albums: Listing?
        }

        struct Listing: Decodable {
            let data: [Album]
        }

        struct Album: Decodable {
            let id: String
            let attributes: Attributes
        }

        struct Attributes: Decodable {
            let name: String
            let artistName: String
            let editorialVideo: EditorialVideo?
        }

        struct EditorialVideo: Decodable {
            let motionTallVideo3x4: Clip?
            let motionDetailTall: Clip?
            let motionSquareVideo1x1: Clip?
            let motionDetailSquare: Clip?

            /// Portrait first: the player is a phone screen.
            var bestURL: String? {
                for clip in [motionTallVideo3x4, motionDetailTall, motionSquareVideo1x1, motionDetailSquare] {
                    if let video = clip?.video, !video.isEmpty { return video }
                }
                return nil
            }
        }

        struct Clip: Decodable {
            let video: String?
        }

        let results: Results
    }
}

// MARK: - Apple's web token

/// Apple's web player token, scraped from its own bundle the way the web clients
/// do it: no account, good for a while, refreshed when the API rejects it.
actor AppleWebToken {
    static let shared = AppleWebToken()

    private var token: String?
    private var issuedAt: Date?
    /// Apple's token lives for hours; refreshing early keeps a long session safe.
    private let lifetime: TimeInterval = 45 * 60

    func token(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let token, let issuedAt, Date().timeIntervalSince(issuedAt) < lifetime {
            return token
        }
        let fresh = try await scrape()
        token = fresh
        issuedAt = Date()
        return fresh
    }

    private func scrape() async throws -> String {
        let page = try await CanvasHTTP.data(URLRequest(url: URL(string: "https://music.apple.com/us/new")!))
        guard let html = String(data: page, encoding: .utf8),
              let script = html.range(of: #"/assets/index~[^"]+\.js"#, options: .regularExpression),
              let scriptURL = URL(string: "https://music.apple.com" + html[script]) else {
            throw CanvasError.unavailable
        }

        let bundle = try await CanvasHTTP.data(URLRequest(url: scriptURL))
        guard let source = String(data: bundle, encoding: .utf8),
              let match = source.range(of: #"eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
                                       options: .regularExpression) else {
            throw CanvasError.unavailable
        }
        return String(source[match])
    }
}

// MARK: - Service

/// Caches what it found, remembers what it did not, and never runs two lookups
/// for the same track at once.
@MainActor
final class CanvasService {
    static let shared = CanvasService()

    /// Spotify's own clips when a session cookie is set, Apple's motion
    /// artwork for everything else — the second source needs no account.
    private var sources: [CanvasSource] {
        SpotifyCanvasSettings.isConfigured
            ? [SpotifyCanvas(), AppleMotionCanvas()]
            : [AppleMotionCanvas()]
    }
    private var hits: [String: URL] = [:]
    /// Tracks without motion artwork: skip them for this session.
    private var misses: Set<String> = []
    private var running: [String: Task<URL?, Never>] = [:]

    func canvas(videoId: String, title: String, artist: String, album: String?) async -> URL? {
        // A clip the listener picked by hand wins over both sources: it is the
        // only way to give a track a clip when neither service has one.
        if !videoId.isEmpty, let picked = CanvasStore.url(for: videoId) { return picked }
        guard !videoId.isEmpty, !title.isEmpty, !artist.isEmpty else { return nil }
        if let hit = hits[videoId] { return hit }
        if misses.contains(videoId) { return nil }
        if let running = running[videoId] { return await running.value }

        let task = Task<URL?, Never> { [sources] in
            for source in sources {
                guard let url = (try? await source.canvasURL(title: title, artist: artist, album: album)) ?? nil else { continue }
                return url
            }
            return nil
        }
        running[videoId] = task
        let found = await task.value
        running[videoId] = nil

        if let found {
            if hits.count > 200 { hits.removeAll() }
            hits[videoId] = found
        } else {
            misses.insert(videoId)
        }
        return found
    }

    /// Drops every cached answer: after the Spotify cookie changes, tracks that
    /// read as "nothing found" deserve a second look.
    func forgetAll() {
        hits.removeAll()
        misses.removeAll()
    }

    /// Drops a track from the "nothing found" list, e.g. after a track was added.
    func forget(videoId: String) {
        misses.remove(videoId)
        hits[videoId] = nil
    }
}

// MARK: - HTTP

enum CanvasHTTP {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static func data(_ request: URLRequest) async throws -> Data {
        var request = request
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CanvasError.unavailable
        }
        return data
    }
}
