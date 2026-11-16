//
//  YouTubeHistoryReport.swift
//  Trop
//

import Foundation

/// Tells YouTube Music about one play, so it reaches the account's history
/// that the History page and other devices read.
///
/// The reporting addresses come from a `player` request as the signed-in web
/// client: the ones inside a stream's own response belong to the client that
/// resolved it, and are not tied to the account.
actor YouTubeHistoryReport {
    private let videoId: String
    /// YouTube's name for one viewing: 16 random characters, the same on every report.
    private let session = String((0..<16).compactMap { _ in
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".randomElement()
    })
    private var watchtimeURL: String?
    /// Seconds of the play already reported.
    private var reported: Double = 0

    /// Seconds between watch-time reports while a song plays.
    private static let interval: Double = 30

    init(videoId: String) {
        self.videoId = videoId
    }

    /// Opens the play, then reports the first `seconds`. Silent when signed out or offline.
    func start(playedSeconds seconds: Double) async {
        var body: [String: Any] = ["videoId": videoId, "contentCheckOk": true, "racyCheckOk": true]
        // Without it YouTube may answer the web client that the video is unavailable.
        if let timestamp = await StreamResolveProviders.tropLive.signatureTimestamp?() {
            body["playbackContext"] = ["contentPlaybackContext": ["signatureTimestamp": timestamp, "html5Preference": "HTML5_PREF_WANTS"]]
        }
        guard let data = try? await SignedInnerTube.post("player", body),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracking = json["playbackTracking"] as? [String: Any] else {
            Log.playbackState.debug("No tracking addresses for \(videoId): not signed in, offline or refused")
            return
        }
        func address(_ key: String) -> String? { (tracking[key] as? [String: Any])?["baseUrl"] as? String }
        watchtimeURL = address("videostatsWatchtimeUrl")
        guard let playbackURL = address("videostatsPlaybackUrl") else { return }
        send(playbackURL, ["cmt": Self.text(0)])
        await watch(upTo: seconds, final: true)
    }

    /// Reports the stretch since the last report, once it is long enough or when the song ends.
    func watch(upTo seconds: Double, final: Bool = false) async {
        guard watchtimeURL != nil, seconds - reported >= (final ? 1 : Self.interval) else { return }
        let start = reported
        reported = seconds
        send(watchtimeURL, ["st": Self.text(start), "et": Self.text(seconds), "cmt": Self.text(seconds), "final": final ? "1" : "0"])
    }

    private func send(_ address: String?, _ values: [String: String]) {
        guard let address else { return }
        let all = values.merging(["cpn": session, "el": "detailpage"]) { first, _ in first }
        Task {
            do {
                try await SignedInnerTube.ping(address, all)
            } catch let error as URLError where error.code == .cancelled || error.code == .notConnectedToInternet {
                // The play is already in the local history.
            } catch {
                Log.playbackState.notice("YouTube history report failed: \(error)")
            }
        }
    }

    private static func text(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }
}
