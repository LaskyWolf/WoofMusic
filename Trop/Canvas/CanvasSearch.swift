//
//  CanvasSearch.swift
//  Trop
//
//  Catalogue search for the manual picker: every album Apple has motion
//  artwork for, with a still and a playable clip. Same host and token as the
//  automatic source, but it returns the whole list instead of the best guess.
//

import Foundation

struct CanvasCandidate: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let video: URL
    let preview: URL?
}

enum CanvasSearch {
    static func albums(matching query: String, storefront: String = "us") async -> [CanvasCandidate] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count > 1 else { return [] }

        var components = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "types", value: "albums"),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "extend", value: "editorialVideo")
        ]
        guard let url = components.url else { return [] }

        for attempt in 0..<2 {
            guard let token = try? await AppleWebToken.shared.token(forceRefresh: attempt > 0) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
            request.setValue(CanvasHTTP.userAgent, forHTTPHeaderField: "User-Agent")

            guard let data = try? await CanvasHTTP.data(request),
                  let response = try? JSONDecoder().decode(Response.self, from: data) else { continue }

            return (response.results.albums?.data ?? []).compactMap { album in
                guard let clip = album.attributes.editorialVideo?.best,
                      let video = URL(string: clip) else { return nil }
                return CanvasCandidate(
                    id: album.id,
                    title: album.attributes.name,
                    artist: album.attributes.artistName,
                    video: video,
                    preview: still(album.attributes.editorialVideo)
                )
            }
        }
        return []
    }

    /// The catalogue ships stills as `{w}x{h}bb.jpg` templates.
    private static func still(_ motion: EditorialVideo?) -> URL? {
        guard let template = motion?.previewTemplate else { return nil }
        let sized = template.replacingOccurrences(of: "{w}", with: "300")
            .replacingOccurrences(of: "{h}", with: "300")
        return URL(string: sized)
    }

    // MARK: - Response

    private struct Response: Decodable {
        let results: Results
        struct Results: Decodable { let albums: Listing? }
        struct Listing: Decodable { let data: [Album] }
        struct Album: Decodable {
            let id: String
            let attributes: Attributes
        }
        struct Attributes: Decodable {
            let name: String
            let artistName: String
            let editorialVideo: EditorialVideo?
        }
    }
}

/// Apple's motion artwork block: one video and one still per aspect.
struct EditorialVideo: Decodable {
    struct Variant: Decodable {
        let video: String?
        let previewFrame: Frame?
    }
    struct Frame: Decodable { let url: String? }

    let motionDetailTall: Variant?
    let motionDetailSquare: Variant?
    let motionTall: Variant?
    let motionSquare: Variant?

    var best: String? {
        motionDetailTall?.video
            ?? motionDetailSquare?.video
            ?? motionTall?.video
            ?? motionSquare?.video
    }

    var previewTemplate: String? {
        motionDetailSquare?.previewFrame?.url
            ?? motionDetailTall?.previewFrame?.url
            ?? motionSquare?.previewFrame?.url
            ?? motionTall?.previewFrame?.url
    }
}
