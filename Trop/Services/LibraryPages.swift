//
//  LibraryPages.swift
//  Trop
//

import Foundation

/// Every page of a library list. YouTube Music sends 25 entries per page and
/// puts the next page's token inside the shelf or grid. SwiftyTube 0.0.9 looks
/// for it one level higher, so its sync stops after the first page.
enum LibraryPages {
    /// A guard against a token that never ends.
    private static let maxPages = 40

    static func allArtists(firstPage: [ParsedArtist] = []) async -> [ParsedArtist] {
        await all("FEmusic_library_corpus_artists", firstPage: firstPage, parse: LibraryBrowseParser.parseArtists, id: \.browseId)
    }

    static func allAlbums(firstPage: [ParsedAlbum]) async -> [ParsedAlbum] {
        await all("FEmusic_liked_albums", firstPage: firstPage, parse: LibraryBrowseParser.parseAlbums, id: \.browseId)
    }

    static func allPlaylists(firstPage: [ParsedPlaylist]) async -> [ParsedPlaylist] {
        await all("FEmusic_liked_playlists", firstPage: firstPage, parse: LibraryBrowseParser.parsePlaylists, id: \.browseId)
    }

    /// The whole list, or `firstPage` when fetching the rest fails: a short list
    /// would remove the missing entries from the database.
    private static func all<T>(
        _ browseId: String,
        firstPage: [T],
        parse: ([String: Any]) -> [T],
        id: KeyPath<T, String>
    ) async -> [T] {
        var items: [T] = []
        var seen: Set<String> = []
        var request: [String: Any] = ["browseId": browseId]
        for _ in 0 ..< maxPages {
            guard let data = try? await SignedInnerTube.post("browse", request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return firstPage }
            let page = parse(json).filter { seen.insert($0[keyPath: id]).inserted }
            items += page
            guard !page.isEmpty, let token = nextPageToken(in: json) else { break }
            request = ["continuation": token]
        }
        return items.count >= firstPage.count ? items : firstPage
    }

    static func nextPageToken(in json: Any) -> String? {
        (ActivityJSON.first("nextContinuationData", in: json) as? [String: Any])?["continuation"] as? String
            ?? (ActivityJSON.first("continuationCommand", in: json) as? [String: Any])?["token"] as? String
    }
}
