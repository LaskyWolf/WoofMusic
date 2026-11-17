//
//  SpotifyCanvasSource.swift
//  Trop
//
//  Spotify's own Canvas, the way BitChord does it — there is no open endpoint,
//  so the clip is fetched the way Spotify's web player fetches it:
//
//    1. the listener pastes their `sp_dc` cookie once (Settings → Appearance);
//    2. an offscreen WKWebView opens open.spotify.com with that cookie and the
//       token the page takes from its own API is read off the request headers;
//    3. `pathfinder/v2/query` is asked for the track's canvas, with the
//       persisted-query hash read live from the player's own bundles.
//
//  Every step can fail on its own and every failure returns nil, which sends
//  CanvasService to the next source — Apple's motion artwork keeps working with
//  no account at all. Nothing here touches the screen: the web view is only
//  ever loaded in memory and thrown away after the token is read.
//

import Foundation
import WebKit

// MARK: - Settings

enum SpotifyCanvasSettings {
    static let cookieDefaultsKey = "settings.spotifySessionCookie"

    /// Accepts the whole cookie header (`sp_dc=AQ…; other=…`) as well as the
    /// bare value, because both are what people copy out of a browser.
    static var sessionCookie: String? {
        guard let raw = UserDefaults.standard.string(forKey: cookieDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let range = raw.range(of: "sp_dc=") {
            let rest = raw[range.upperBound...]
            let value = rest.split(separator: ";").first.map(String.init) ?? String(rest)
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return raw
    }

    static var isConfigured: Bool { sessionCookie != nil }

    static func setSessionCookie(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: cookieDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: cookieDefaultsKey)
        }
        Task { @MainActor in
            CanvasService.shared.forgetAll()
            await SpotifyTokenHarvester.shared.reset()
        }
    }
}

// MARK: - Token

/// Mints the web player's bearer token: a hidden WKWebView loads the real
/// player with the listener's cookie, and a script wrapped around `fetch` and
/// `XMLHttpRequest` reports the `Authorization` header the page itself sends.
/// The token is a real one — no signing, no TOTP, nothing Spotify can tell
/// apart from its own web app, which is why it lasts as long as a session does.
@MainActor
final class SpotifyTokenHarvester: NSObject {
    static let shared = SpotifyTokenHarvester()

    private var token: String?
    private var expiresAt: Date?
    private var running: Task<String?, Never>?
    private var pending: CheckedContinuation<String?, Never>?
    private var webView: WKWebView?
    private var controller: WKUserContentController?

    private let lifetime: TimeInterval = 40 * 60
    private let timeout: TimeInterval = 20

    func reset() {
        token = nil
        expiresAt = nil
    }

    func accessToken(forceRefresh: Bool = false) async -> String? {
        if !forceRefresh, let token, let expiresAt, Date() < expiresAt { return token }
        if let running { return await running.value }

        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.mint()
        }
        running = task
        let value = await task.value
        running = nil

        if let value {
            token = value
            expiresAt = Date().addingTimeInterval(lifetime)
        }
        return value
    }

    private func mint() async -> String? {
        guard let cookie = SpotifyCanvasSettings.sessionCookie else { return nil }
        await apply(cookie: cookie)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let controller = WKUserContentController()
        controller.add(self, name: "token")
        controller.addUserScript(WKUserScript(source: Self.hookScript,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        configuration.userContentController = controller
        self.controller = controller

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 640),
                             configuration: configuration)
        view.customUserAgent = CanvasHTTP.userAgent
        webView = view

        let value: String? = await withCheckedContinuation { continuation in
            self.pending = continuation
            view.load(URLRequest(url: URL(string: "https://open.spotify.com/")!))
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                self.finish(nil)
            }
        }

        // No-op when the token already arrived: the continuation resumes once.
        finish(nil)
        controller.removeScriptMessageHandler(forName: "token")
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
        webView = nil
        self.controller = nil
        return value
    }

    private func finish(_ value: String?) {
        guard let pending else { return }
        self.pending = nil
        pending.resume(returning: value)
    }

    private func apply(cookie value: String) async {
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: "sp_dc",
            .value: value,
            .domain: ".spotify.com",
            .path: "/",
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(365 * 24 * 60 * 60)
        ]
        guard let cookie = HTTPCookie(properties: properties) else { return }
        await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
    }

    /// Runs before the player's own scripts: the page keeps using the wrapped
    /// `fetch`, so the header it adds is the one reported here.
    private static let hookScript = """
    (function () {
      var send = function (value) {
        try { window.webkit.messageHandlers.token.postMessage(value); } catch (e) {}
      };
      var bearer = function (value) {
        if (typeof value !== 'string') return null;
        var index = value.toLowerCase().indexOf('bearer ');
        return index === 0 ? value.slice(7) : null;
      };
      var header = function (headers, name) {
        if (!headers) return null;
        try {
          if (typeof headers.get === 'function') return headers.get(name);
          if (Array.isArray(headers)) {
            for (var i = 0; i < headers.length; i++) {
              if (String(headers[i][0]).toLowerCase() === name.toLowerCase()) return headers[i][1];
            }
            return null;
          }
          for (var key in headers) {
            if (String(key).toLowerCase() === name.toLowerCase()) return headers[key];
          }
        } catch (e) {}
        return null;
      };
      var inspect = function (headers) {
        var token = bearer(header(headers, 'authorization'));
        if (token && token.length > 40) send(token);
      };

      var originalFetch = window.fetch;
      if (originalFetch) {
        window.fetch = function (input, init) {
          try {
            inspect((init && init.headers) || (input && input.headers));
          } catch (e) {}
          return originalFetch.apply(this, arguments);
        };
      }

      var originalSetHeader = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
        try {
          if (String(name).toLowerCase() === 'authorization') {
            var token = bearer(String(value));
            if (token && token.length > 40) send(token);
          }
        } catch (e) {}
        return originalSetHeader.apply(this, arguments);
      };
    })();
    """
}

extension SpotifyTokenHarvester: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard message.name == "token", let value = message.body as? String,
              value.count > 40, !value.contains(" ") else { return }
        Task { @MainActor in self.finish(value) }
    }
}

// MARK: - Persisted-query hash

/// The `canvas` operation's hash, read from the web player's own bundles the
/// way BitChord does, with its January 2026 value as the fallback so a read
/// failure costs one round trip instead of the feature.
actor SpotifyCanvasHashes {
    static let shared = SpotifyCanvasHashes()

    /// Verified against BitChord's `KNOWN_CANVAS_HASH` before it was copied here.
    private static let known = "575138ab27cd5c1b3e54da54d0a7cc8d85485402de26340c2145f0f6bb5e7a9f"

    private var cached: (hash: String, at: Date)?
    private var missedAt: Date?

    func canvasHash() async -> String {
        if let cached, Date().timeIntervalSince(cached.at) < 3600 { return cached.hash }
        if let missedAt, Date().timeIntervalSince(missedAt) < 600 { return Self.known }
        if let live = await lookUp() {
            cached = (live, Date())
            return live
        }
        missedAt = Date()
        return Self.known
    }

    private func lookUp() async -> String? {
        guard let html = await Self.fetch("https://open.spotify.com/"),
              let scripts = Self.scripts(in: html) else { return nil }
        for script in scripts.prefix(8) {
            guard let body = await Self.fetch(script) else { continue }
            if let hash = Self.hash(in: body) { return hash }
        }
        return nil
    }

    private static let declaration = try? NSRegularExpression(
        pattern: #"["'](\w+)["']\s*,\s*["']query["']\s*,\s*["']([0-9a-f]{64})["']"#
    )
    private static let scriptPattern = try? NSRegularExpression(
        pattern: #"https://open\.spotifycdn\.com/cdn/build/web-player/[A-Za-z0-9._~-]+\.js"#
    )

    static func hash(in script: String, operation: String = "canvas") -> String? {
        guard let declaration else { return nil }
        let range = NSRange(script.startIndex..., in: script)
        for match in declaration.matches(in: script, range: range) {
            guard match.numberOfRanges > 2,
                  let nameRange = Range(match.range(at: 1), in: script),
                  let hashRange = Range(match.range(at: 2), in: script),
                  String(script[nameRange]) == operation else { continue }
            return String(script[hashRange])
        }
        return nil
    }

    static func scripts(in html: String) -> [String]? {
        guard let scriptPattern else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        let found = scriptPattern.matches(in: html, range: range).compactMap { match -> String? in
            guard let matchRange = Range(match.range, in: html) else { return nil }
            return String(html[matchRange])
        }
        return found.isEmpty ? nil : Array(Set(found))
    }

    private static func fetch(_ url: String) async -> String? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(CanvasHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        guard let data = try? await CanvasHTTP.data(request) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Source

struct SpotifyCanvas: CanvasSource {
    let name = "Spotify"

    func canvasURL(title: String, artist: String, album: String?) async throws -> URL? {
        guard SpotifyCanvasSettings.isConfigured else { return nil }
        guard let token = await SpotifyTokenHarvester.shared.accessToken() else { return nil }
        guard let track = try await search(title: title, artist: artist, token: token) else { return nil }

        if let url = try await canvasURL(trackURI: track.uri, token: token) { return url }

        // A token that was revoked reads as "no canvas": mint a fresh one and
        // ask once more before giving up on Spotify for this track.
        guard let fresh = await SpotifyTokenHarvester.shared.accessToken(forceRefresh: true),
              fresh != token else { return nil }
        return try await canvasURL(trackURI: track.uri, token: fresh)
    }

    // MARK: Search

    private struct Track {
        let uri: String
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval
    }

    private struct Search: Decodable {
        struct Tracks: Decodable { let items: [Item] }
        let tracks: Tracks?
    }

    private struct Item: Decodable {
        struct Artist: Decodable { let name: String }
        struct Album: Decodable { let name: String }

        let uri: String
        let name: String
        let artists: [Artist]
        let album: Album?
        let duration: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case uri, name, artists, album
            case duration = "duration_ms"
        }
    }

    private func search(title: String, artist: String, token: String) async throws -> Track? {
        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "\(title) \(artist)"),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: "10")
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let data = try? await CanvasHTTP.data(request),
              let payload = try? JSONDecoder().decode(Search.self, from: data) else { return nil }
        let items = payload.tracks?.items ?? []
        guard !items.isEmpty else { return nil }

        let wantedTitle = Self.normalized(title)
        let wantedArtist = Self.normalized(artist)

        func score(_ item: Item) -> Double {
            var value = 0.0
            let name = Self.normalized(item.name)
            if name == wantedTitle { value += 5 }
            else if name.contains(wantedTitle) || wantedTitle.contains(name) { value += 2 }
            let owners = item.artists.map { Self.normalized($0.name) }
            if owners.contains(where: { $0.contains(wantedArtist) || wantedArtist.contains($0) }) { value += 3 }
            if name.contains("karaoke") || name.contains("tribute") || name.contains("instrumental") {
                value -= 4
            }
            return value
        }

        guard let best = items.max(by: { score($0) < score($1) }), score(best) > 0 else { return nil }
        return Track(
            uri: best.uri,
            title: best.name,
            artist: best.artists.first?.name ?? "",
            album: best.album?.name ?? "",
            duration: (best.duration ?? 0) / 1000
        )
    }

    // MARK: Pathfinder

    private func canvasURL(trackURI: String, token: String) async throws -> URL? {
        guard let endpoint = URL(string: "https://api-partner.spotify.com/pathfinder/v2/query") else {
            return nil
        }
        let hash = await SpotifyCanvasHashes.shared.canvasHash()
        let body: [String: Any] = [
            "variables": ["trackUri": trackURI],
            "operationName": "canvas",
            "extensions": ["persistedQuery": ["version": 1, "sha256Hash": hash]]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("WebPlayer", forHTTPHeaderField: "app-platform")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://open.spotify.com", forHTTPHeaderField: "Origin")
        request.setValue("https://open.spotify.com/", forHTTPHeaderField: "Referer")
        request.setValue(CanvasHTTP.userAgent, forHTTPHeaderField: "User-Agent")

        guard let data = try? await CanvasHTTP.data(request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let union = payload["trackUnion"] as? [String: Any],
              let canvas = union["canvas"] as? [String: Any],
              let value = canvas["url"] as? String,
              value.contains(".mp4"),
              let url = URL(string: value) else { return nil }
        return url
    }

    private static func normalized(_ text: String) -> String {
        let lowered = text.lowercased()
        let allowed = lowered.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
        }
        return String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: .whitespaces)
    }
}
