//
//  OdesliService.swift
//  Trop
//

import Foundation

enum OdesliError: LocalizedError {
    case notConnected
    case invalidKey
    case rateLimited
    case notFound
    case unreachable

    var errorDescription: String? {
        switch self {
        case .notConnected: "To open Spotify and Apple Music links, add an Odesli API key in Settings > Integrations."
        case .invalidKey: "Odesli didn't accept this API key. Check it and try again."
        case .rateLimited: "Odesli is receiving too many requests from this key. Wait a minute and try again."
        case .notFound: "Odesli couldn't find this on YouTube Music."
        case .unreachable: "Couldn't reach Odesli. Check your connection and try again."
        }
    }
}

/// Network calls to the Odesli API.
enum OdesliService {
    /// Throws only when the key is refused or Odesli can't be reached: a rate
    /// limit or a missing test song says nothing against the key.
    static func validate(key: String) async throws {
        guard let link = URL(string: OdesliDefaults.validationLink) else { return }
        do {
            _ = try await links(for: link, key: key)
        } catch OdesliError.rateLimited, OdesliError.notFound {
            return
        }
    }

    /// Returns the JSON listing `link` on every platform.
    static func links(for link: URL, key: String) async throws -> Data {
        guard var components = URLComponents(string: OdesliDefaults.apiURL) else { throw OdesliError.unreachable }
        components.queryItems = [
            URLQueryItem(name: "url", value: link.absoluteString),
            URLQueryItem(name: "songIfSingle", value: "true"),
            URLQueryItem(name: "key", value: key)
        ]
        // URLComponents leaves "+" as is, and servers read it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url) else {
            throw OdesliError.unreachable
        }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return data
        case 401, 403: throw OdesliError.invalidKey
        case 429: throw OdesliError.rateLimited
        default: throw OdesliError.notFound
        }
    }
}
