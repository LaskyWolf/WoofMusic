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

    @ObservationIgnored private let store = SecureStore(service: ListenBrainzDefaults.keychainService)
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
        if let data = try? store.load(for: ListenBrainzDefaults.tokenAccount) {
            token = String(data: data, encoding: .utf8)
            userName = UserDefaults.standard.string(forKey: ListenBrainzDefaults.userNameKey)
        }
    }

    /// Checks `token` with ListenBrainz, then saves it.
    func connect(token rawToken: String) async throws {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = try await ListenBrainzService.validate(token: token)
        try store.save(Data(token.utf8), for: ListenBrainzDefaults.tokenAccount)
        UserDefaults.standard.set(name, forKey: ListenBrainzDefaults.userNameKey)
        self.token = token
        userName = name
    }

    func disconnect() {
        try? store.delete(for: ListenBrainzDefaults.tokenAccount)
        UserDefaults.standard.removeObject(forKey: ListenBrainzDefaults.userNameKey)
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

        if !sentNowPlaying, listened >= ListenBrainzDefaults.nowPlayingDelaySeconds {
            sentNowPlaying = true
            send(type: .playingNow, listenedAt: nil, token: token)
        }
        let duration = np.duration
        if !submitted, duration >= ListenBrainzDefaults.minSongDuration,
           listened >= min(duration / 2, ListenBrainzDefaults.maxListenSeconds) {
            submitted = true
            send(type: .single, listenedAt: startedAt, token: token)
        }
    }

    // ponytail: a listen that fails to send is dropped, not queued; add an
    // offline queue if listens go missing on bad connections.
    private func send(type: ListenBrainzService.ListenType, listenedAt: Date?, token: String) {
        let np = NowPlaying.shared
        guard !np.title.isEmpty, !np.displayArtist.isEmpty, let videoId = np.videoId else { return }
        let listen = ListenBrainzListen(
            listenedAt: listenedAt.map { Int($0.timeIntervalSince1970) },
            trackMetadata: .init(
                artistName: np.displayArtist,
                trackName: np.title,
                releaseName: np.albumTitle.isEmpty ? nil : np.albumTitle,
                additionalInfo: .init(
                    mediaPlayer: ListenBrainzDefaults.clientName,
                    submissionClient: ListenBrainzDefaults.clientName,
                    musicService: "music.youtube.com",
                    originUrl: "https://music.youtube.com/watch?v=\(videoId)",
                    durationMs: Int(np.duration * 1000)
                )
            )
        )
        Task {
            let status = await ListenBrainzService.submit(listen, type: type, token: token)
            if status != 200 { Log.listenBrainz.error("Submitting \(type.rawValue) failed with status \(status ?? -1)") }
        }
    }
}
