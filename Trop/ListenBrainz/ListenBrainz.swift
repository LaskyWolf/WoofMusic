//
//  ListenBrainz.swift
//  Trop
//

import Foundation
import Observation

/// Sends the songs you play to ListenBrainz, the open alternative to Last.fm.
/// A song counts once half of it, or 4 minutes, has played: ListenBrainz's
/// own rule. The user token lives in the Keychain.
@MainActor
@Observable
final class ListenBrainz {
    static let shared = ListenBrainz()

    enum ConnectError: LocalizedError {
        case invalidToken
        case unreachable

        var errorDescription: String? {
            switch self {
            case .invalidToken: "ListenBrainz didn't accept this token. Copy it again from your ListenBrainz settings."
            case .unreachable: "Couldn't reach ListenBrainz. Check your connection and try again."
            }
        }
    }

    private static let api = "https://api.listenbrainz.org/1/"
    private static let userNameKey = "listenBrainz.userName"
    @ObservationIgnored private let store = SecureStore(service: "com.woofmusic.listenbrainz")
    @ObservationIgnored private var token: String?
    private(set) var userName: String?

    // Playback of the current song.
    @ObservationIgnored private var videoId: String?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var listened: TimeInterval = 0
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var sentNowPlaying = false
    @ObservationIgnored private var submitted = false

    var isConnected: Bool { userName != nil }

    private init() {
        if let data = try? store.load(for: "token") {
            token = String(data: data, encoding: .utf8)
            userName = UserDefaults.standard.string(forKey: Self.userNameKey)
        }
    }

    /// Checks `token` with ListenBrainz, then saves it.
    func connect(token rawToken: String) async throws {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: URL(string: Self.api + "validate-token")!)
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        guard let reply = try? await URLSession.shared.data(for: request) else { throw ConnectError.unreachable }
        let json = try? JSONSerialization.jsonObject(with: reply.0) as? [String: Any]
        guard json?["valid"] as? Bool == true, let name = json?["user_name"] as? String else {
            throw ConnectError.invalidToken
        }
        try store.save(Data(token.utf8), for: "token")
        UserDefaults.standard.set(name, forKey: Self.userNameKey)
        self.token = token
        userName = name
    }

    func disconnect() {
        try? store.delete(for: "token")
        UserDefaults.standard.removeObject(forKey: Self.userNameKey)
        token = nil
        userName = nil
    }

    /// Called by NowPlaying's timer: counts the time the song actually plays.
    func tick() {
        guard let token else { return }
        let np = NowPlaying.shared
        guard let id = np.videoId else { return }
        let now = Date()
        if id != videoId {
            videoId = id
            startedAt = now
            listened = 0
            lastTick = nil
            sentNowPlaying = false
            submitted = false
        }
        if np.isPlaying, let lastTick {
            // Capped so a stalled timer can't count time that didn't play.
            listened += min(now.timeIntervalSince(lastTick), 1)
        }
        lastTick = np.isPlaying ? now : nil

        // A couple of seconds in, so the title and artist are final.
        if !sentNowPlaying, listened >= 2 {
            sentNowPlaying = true
            send(type: "playing_now", listenedAt: nil, token: token)
        }
        let duration = np.duration
        if !submitted, duration >= 30, listened >= min(duration / 2, 240) {
            submitted = true
            send(type: "single", listenedAt: startedAt, token: token)
        }
    }

    // ponytail: a listen that fails to send is dropped, not queued; add an
    // offline queue if listens go missing on bad connections.
    private func send(type: String, listenedAt: Date?, token: String) {
        let np = NowPlaying.shared
        guard !np.title.isEmpty, !np.displayArtist.isEmpty, let videoId = np.videoId else { return }
        var metadata: [String: Any] = [
            "artist_name": np.displayArtist,
            "track_name": np.title,
            "additional_info": [
                "media_player": "Woof Music",
                "submission_client": "Woof Music",
                "music_service": "music.youtube.com",
                "origin_url": "https://music.youtube.com/watch?v=\(videoId)",
                "duration_ms": Int(np.duration * 1000)
            ]
        ]
        if !np.albumTitle.isEmpty { metadata["release_name"] = np.albumTitle }
        var listen: [String: Any] = ["track_metadata": metadata]
        if let listenedAt { listen["listened_at"] = Int(listenedAt.timeIntervalSince1970) }

        var request = URLRequest(url: URL(string: Self.api + "submit-listens")!)
        request.httpMethod = "POST"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["listen_type": type, "payload": [listen]])
        Task {
            let status = (try? await URLSession.shared.data(for: request))
                .flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
            if status != 200 { Log.listenBrainz.error("Submitting \(type) failed with status \(status ?? -1)") }
        }
    }
}
