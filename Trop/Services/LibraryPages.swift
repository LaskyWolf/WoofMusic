//
//  LibraryPages.swift
//  Trop
//

import Foundation

/// Every page of a library list. YouTube Music sends 25 entries per page and
/// puts the next page's token in `musicShelfRenderer.continuations`. SwiftyTube
/// 0.0.9 looks for it one level higher, so its sync stops after the first page.
enum LibraryPages {
    /// A guard against a token that never ends.
    private static let maxPages = 40

    /// All followed artists, or `firstPage` when fetching the rest fails:
    /// a short list would un-follow the missing artists in the database.
    static func allArtists(firstPage: [ParsedArtist] = []) async -> [ParsedArtist] {
        var artists: [ParsedArtist] = []
        var seen: Set<String> = []
        var request: [String: Any] = ["browseId": "FEmusic_library_corpus_artists"]
        for _ in 0 ..< maxPages {
            guard let data = try? await SignedInnerTube.post("browse", request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return firstPage }
            let page = LibraryBrowseParser.parseArtists(from: json).filter { seen.insert($0.browseId).inserted }
            artists += page
            guard !page.isEmpty, let token = nextPageToken(in: json) else { break }
            request = ["continuation": token]
        }
        return artists.count >= firstPage.count ? artists : firstPage
    }

    static func nextPageToken(in json: Any) -> String? {
        (ActivityJSON.first("nextContinuationData", in: json) as? [String: Any])?["continuation"] as? String
            ?? (ActivityJSON.first("continuationCommand", in: json) as? [String: Any])?["token"] as? String
    }
}
