//
//  ReleaseFeed.swift
//  Trop
//

import Foundation

/// New releases from the artists the user follows. YouTube Music's own bell
/// feed is not served to this client, so the list is read from each artist's
/// page: its albums and singles, tagged only with a year. Deezer's public API
/// supplies the exact day, matched by artist name and title; a release Deezer
/// can't date stays out, since a year can't tell January from last week.
enum ReleaseFeed {
    /// Artists checked per refresh, and releases kept per artist.
    private static let artistLimit = 30
    private static let perArtist = 2
    private static let parallelism = 5
    /// Releases older than this leave the list.
    private static let windowDays = 60

    private struct Release {
        let item: ActivityItem
        let date: Date
    }

    static func items(seen: Set<String>) async -> [ActivityItem] {
        guard let data = try? await SignedInnerTube.post("browse", ["browseId": "FEmusic_library_corpus_artists"]),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let artistIds = Array(browseIds(in: json, prefix: "UC").prefix(artistLimit))

        var all: [Release] = []
        // A few artists at a time, so the phone doesn't open 30 connections at once.
        for start in stride(from: 0, to: artistIds.count, by: parallelism) {
            let chunk = Array(artistIds[start ..< min(start + parallelism, artistIds.count)])
            let results = await withTaskGroup(of: (Int, [Release]).self) { group in
                for (index, id) in chunk.enumerated() {
                    group.addTask { (index, await releases(ofArtist: id, seen: seen)) }
                }
                var collected: [(Int, [Release])] = []
                for await result in group { collected.append(result) }
                return collected
            }
            all += results.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        return all.sorted { $0.date > $1.date }.map(\.item)
    }

    private static func releases(ofArtist id: String, seen: Set<String>) async -> [Release] {
        guard let data = try? await SignedInnerTube.post("browse", ["browseId": id]),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let header = ActivityJSON.nodes("musicImmersiveHeaderRenderer", in: json).first ?? ActivityJSON.nodes("musicVisualHeaderRenderer", in: json).first
        let artist = ActivityJSON.text(header?["title"])
        let thisYear = Calendar.current.component(.year, from: Date())
        // Last year too: a December release is still new in January.
        let years = [String(thisYear), String(thisYear - 1)]
        var dates: [String: Date] = [:]
        if let artist { dates = await DeezerDates.releaseDates(artist: artist) }
        let oldest = Calendar.current.date(byAdding: .day, value: -windowDays, to: Date()) ?? .distantPast

        var found: [Release] = []
        // An album and a single often share a title: list it once.
        var titles: Set<String> = []
        for shelf in ActivityJSON.nodes("musicCarouselShelfRenderer", in: json) {
            for row in ActivityJSON.nodes("musicTwoRowItemRenderer", in: shelf["contents"]) {
                guard let album = ActivityJSON.first("browseId", in: row["navigationEndpoint"]) as? String,
                      album.hasPrefix("MPREb"),
                      let subtitle = ActivityJSON.text(row["subtitle"]),
                      years.contains(where: { subtitle.contains($0) }),
                      let title = ActivityJSON.text(row["title"]) else { continue }
                guard let date = dates[DeezerDates.key(title)], date >= oldest,
                      titles.insert(DeezerDates.key(title)).inserted else { continue }
                let itemId = "release-\(album)"
                found.append(Release(
                    item: ActivityItem(
                        id: itemId,
                        message: artist.map { "\($0): \(title)" } ?? title,
                        time: date.formatted(.relative(presentation: .named)),
                        thumbnail: ActivityJSON.lastThumbnail(ActivityJSON.first("thumbnails", in: row["thumbnailRenderer"]).map { ["thumbnails": $0] }),
                        route: .album(browseId: album),
                        isRead: seen.contains(itemId)
                    ),
                    date: date
                ))
                if found.count == perArtist { return found }
            }
        }
        return found
    }

    /// Distinct ids with `prefix`, in the order the page lists them.
    private static func browseIds(in node: Any, prefix: String) -> [String] {
        var ids: [String] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let id = (dict["browseEndpoint"] as? [String: Any])?["browseId"] as? String,
                   id.hasPrefix(prefix), !ids.contains(id) { ids.append(id) }
                dict.values.forEach(walk)
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        walk(node)
        return ids
    }
}

/// Release days from Deezer's public API, which needs no key. Only the artist's
/// name leaves the iPhone. Any failure (no exact name match, rate limit, offline)
/// gives no dates, and the release keeps YouTube's year.
enum DeezerDates {
    private struct Search: Decodable {
        struct Artist: Decodable {
            let id: Int
            let name: String
            let fans: Int?
            enum CodingKeys: String, CodingKey { case id, name, fans = "nb_fan" }
        }
        let data: [Artist]?
    }

    private struct Albums: Decodable {
        struct Album: Decodable {
            let title: String
            let releaseDate: String?
            enum CodingKeys: String, CodingKey { case title, releaseDate = "release_date" }
        }
        let data: [Album]?
    }

    /// Title key → release day.
    static func releaseDates(artist: String) async -> [String: Date] {
        guard var search = URLComponents(string: "https://api.deezer.com/search/artist") else { return [:] }
        search.queryItems = [URLQueryItem(name: "q", value: artist), URLQueryItem(name: "limit", value: "5")]
        guard let searchURL = search.url,
              let found: Search = await fetch(searchURL),
              // Only the same name, compared by `key` because YouTube pads some names with
              // invisible characters. Several artists can share it: the most followed is
              // almost always the right one.
              let match = found.data?.filter({ key($0.name) == key(artist) }).max(by: { ($0.fans ?? 0) < ($1.fans ?? 0) }),
              let albumsURL = URL(string: "https://api.deezer.com/artist/\(match.id)/albums?limit=100"),
              let albums: Albums = await fetch(albumsURL) else { return [:] }

        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        var dates: [String: Date] = [:]
        for album in albums.data ?? [] {
            guard let text = album.releaseDate, let date = day.date(from: text) else { continue }
            dates[key(album.title)] = dates[key(album.title)].map { min($0, date) } ?? date
        }
        return dates
    }

    /// Lowercased letters and digits only: "From Zero (Deluxe)" and "from zero deluxe" match.
    static func key(_ title: String) -> String {
        String(title.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func fetch<T: Decodable>(_ url: URL) async -> T? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
