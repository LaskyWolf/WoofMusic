//
//  ReleaseFeed.swift
//  Trop
//

import Foundation

/// New releases from the artists the user follows. YouTube Music's own bell
/// feed is not served to this client, so the list is read from each artist's
/// page: its albums and singles, newest first, tagged only with a year.
enum ReleaseFeed {
    /// Artists checked per refresh, and releases kept per artist.
    private static let artistLimit = 30
    private static let perArtist = 2
    private static let parallelism = 5

    static func items(seen: Set<String>) async -> [ActivityItem] {
        guard let data = try? await SignedInnerTube.post("browse", ["browseId": "FEmusic_library_corpus_artists"]),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let artistIds = Array(browseIds(in: json, prefix: "UC").prefix(artistLimit))
        let year = String(Calendar.current.component(.year, from: Date()))

        var all: [ActivityItem] = []
        // A few artists at a time, so the phone doesn't open 30 connections at once.
        for chunk in stride(from: 0, to: artistIds.count, by: parallelism).map({ Array(artistIds[$0 ..< min($0 + parallelism, artistIds.count)]) }) {
            let results = await withTaskGroup(of: (Int, [ActivityItem]).self) { group in
                for (index, id) in chunk.enumerated() {
                    group.addTask { (index, await releases(ofArtist: id, year: year, seen: seen)) }
                }
                var collected: [(Int, [ActivityItem])] = []
                for await result in group { collected.append(result) }
                return collected
            }
            all += results.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        return all
    }

    private static func releases(ofArtist id: String, year: String, seen: Set<String>) async -> [ActivityItem] {
        guard let data = try? await SignedInnerTube.post("browse", ["browseId": id]),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let header = ActivityJSON.nodes("musicImmersiveHeaderRenderer", in: json).first ?? ActivityJSON.nodes("musicVisualHeaderRenderer", in: json).first
        let artist = ActivityJSON.text(header?["title"])
        var items: [ActivityItem] = []
        for shelf in ActivityJSON.nodes("musicCarouselShelfRenderer", in: json) {
            for row in ActivityJSON.nodes("musicTwoRowItemRenderer", in: shelf["contents"]) {
                guard let album = ActivityJSON.first("browseId", in: row["navigationEndpoint"]) as? String,
                      album.hasPrefix("MPREb"),
                      let subtitle = ActivityJSON.text(row["subtitle"]), subtitle.contains(year),
                      let title = ActivityJSON.text(row["title"]) else { continue }
                let itemId = "release-\(album)"
                items.append(ActivityItem(
                    id: itemId,
                    message: artist.map { "\($0): \(title)" } ?? title,
                    time: subtitle,
                    thumbnail: ActivityJSON.lastThumbnail(ActivityJSON.first("thumbnails", in: row["thumbnailRenderer"]).map { ["thumbnails": $0] }),
                    route: .album(browseId: album),
                    isRead: seen.contains(itemId)
                ))
                if items.count == perArtist { return items }
            }
        }
        return items
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
