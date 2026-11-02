//
//  MusicLink.swift
//  Trop
//

import Foundation

private struct OdesliResponse: Decodable {
    struct Platform: Decodable {
        let url: String
    }

    let linksByPlatform: [String: Platform]
}

/// A YouTube or YouTube Music link, read from its text alone, with no network call.
enum MusicLink: Equatable {
    case song(videoId: String)
    case playlist(id: String)
    case album(browseId: String)
    case artist(browseId: String)
    case podcast(browseId: String)

    /// The link inside woofmusic://open?url=<encoded link>.
    static func wrappedLink(in openURL: URL) -> URL? {
        URLComponents(url: openURL, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "url" }?.value
            .flatMap(URL.init(string:))
    }

    /// True for Spotify and Apple Music links. Only these may go to Odesli, so
    /// other links the user shares stay on the iPhone.
    static func isConvertible(_ link: URL) -> Bool {
        guard let parts = URLComponents(url: link, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased()) else { return false }
        return ["open.spotify.com", "music.apple.com", "geo.music.apple.com"].contains(parts.host?.lowercased())
    }

    /// The YouTube link in an Odesli reply, preferring YouTube Music.
    init?(odesliResponse: Data) {
        guard let links = try? JSONDecoder().decode(OdesliResponse.self, from: odesliResponse).linksByPlatform else { return nil }
        for platform in ["youtubeMusic", "youtube"] {
            if let url = links[platform].flatMap({ URL(string: $0.url) }), let link = MusicLink(link: url) {
                self = link
                return
            }
        }
        return nil
    }

    init?(link: URL) {
        guard let parts = URLComponents(url: link, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased()),
              let host = parts.host?.lowercased() else { return nil }
        let path = parts.path.split(separator: "/").map(String.init)
        let query = { (name: String) in parts.queryItems?.first { $0.name == name }?.value }

        if host == "youtu.be" {
            guard path.count == 1 else { return nil }
            self.init(videoId: path[0])
        } else if ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"].contains(host) {
            switch path.first {
            case "watch" where query("v") != nil: self.init(videoId: query("v") ?? "")
            case "watch", "playlist": self.init(playlistId: query("list") ?? "")
            // The app's own artist share links use /channel.
            case "browse", "channel":
                guard path.count == 2 else { return nil }
                self.init(browseId: path[1])
            default: return nil
            }
        } else {
            return nil
        }
    }

    private init?(videoId: String) {
        guard videoId.count == 11, Self.isId(videoId) else { return nil }
        self = .song(videoId: videoId)
    }

    private init?(playlistId: String) {
        guard Self.isId(playlistId) else { return nil }
        self = .playlist(id: playlistId)
    }

    private init?(browseId: String) {
        guard Self.isId(browseId) else { return nil }
        if browseId.hasPrefix("MPREb_") {
            self = .album(browseId: browseId)
        } else if browseId.hasPrefix("UC") || browseId.hasPrefix("MPCH") {
            self = .artist(browseId: browseId)
        } else if browseId.hasPrefix("VL") {
            self = .playlist(id: browseId)
        } else if browseId.hasPrefix("MPSP") {
            self = .podcast(browseId: browseId)
        } else {
            return nil
        }
    }

    private static func isId(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}
