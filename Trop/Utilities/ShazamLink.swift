//
//  ShazamLink.swift
//  Trop
//
//  A Shazam link names a song only by an ID. Its public page says the title
//  and artist, which a YouTube Music search turns into a song to play.
//

import Foundation

enum ShazamLink {
    struct Track: Equatable {
        let title: String
        let artist: String
    }

    /// Whether a link's host is Shazam's (shz.am is the short link the app shares).
    static func isShazam(host: String, path: [String]) -> Bool {
        switch host {
        case "shz.am": !path.isEmpty
        case "shazam.com", "www.shazam.com": ["track", "song"].contains(path.first ?? "")
        default: false
        }
    }

    /// The song a Shazam link points to, read from the page behind it.
    static func track(at url: URL) async -> Track? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        // A phone browser's identity: the page names the song in its meta tags for it.
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8) else { return nil }
        return track(inPage: html)
    }

    /// "Listen to <title> by <artist>. See lyrics…" in og:description; the title
    /// "<title> - <artist>: Song Lyrics…" is the fallback. The last " by " and
    /// " - " split them, because titles contain those and artists rarely do.
    static func track(inPage html: String) -> Track? {
        if let match = meta("og:description", in: html)?.firstMatch(of: #/Listen to (.+) by (.+?)\. See lyrics/#) {
            return Track(title: String(match.1), artist: String(match.2))
        }
        if let match = meta("og:title", in: html)?.firstMatch(of: #/(.+) - (.+?): Song Lyrics/#) {
            return Track(title: String(match.1), artist: String(match.2))
        }
        return nil
    }

    private static func meta(_ property: String, in html: String) -> String? {
        guard let regex = try? Regex(#"<meta property="\#(property)" content="([^"]*)""#),
              let match = html.firstMatch(of: regex),
              let value = match.output[1].substring else { return nil }
        return String(value)
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func selfCheck() {
        let page = #"<meta property="og:description" content="Listen to Stand by Me by Ben E. King. See lyrics and music videos, find tour dates."/>"#
        assert(track(inPage: page) == Track(title: "Stand by Me", artist: "Ben E. King"))
        let titleOnly = #"<meta property="og:title" content="Rock &amp; Roll - AC/DC: Song Lyrics, Music Videos &amp; Concerts"/>"#
        assert(track(inPage: titleOnly) == Track(title: "Rock & Roll", artist: "AC/DC"))
        assert(track(inPage: "<html></html>") == nil)
        assert(isShazam(host: "www.shazam.com", path: ["track", "52331483", "dtmf"]))
        assert(!isShazam(host: "www.shazam.com", path: ["charts"]))
    }
}
