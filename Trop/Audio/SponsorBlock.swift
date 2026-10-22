//
//  SponsorBlock.swift
//  Trop
//

import CryptoKit
import Foundation

/// Skips the non-music parts of music videos (talking intros, skits, long
/// outros) using SponsorBlock, a community database of video segments. Only
/// the first four characters of a hash of the video id are sent, so the
/// server can't tell which song is playing.
@MainActor
final class SponsorBlock {
    static let shared = SponsorBlock()

    private struct Segment: Sendable {
        let start: Double
        let end: Double
    }

    private var videoId: String?
    private var segments: [Segment] = []
    /// Segments already skipped in this play; seeking back into one plays it.
    private var skipped: Set<Int> = []

    /// Called by NowPlaying's timer after it updates the position.
    func tick() {
        let np = NowPlaying.shared
        guard SettingsStore.shared.skipNonMusic, let id = np.videoId else { return }
        if id != videoId {
            videoId = id
            segments = []
            skipped = []
            Task { [weak self] in
                let found = await Self.fetchSegments(videoId: id)
                guard let self, self.videoId == id else { return }
                self.segments = found
                if !found.isEmpty { Log.sponsorBlock.info("Found \(found.count) non-music segments") }
            }
            return
        }
        guard np.isPlaying, !PlayerController.shared.isCrossfading else { return }
        let position = np.currentTime
        for (index, segment) in segments.enumerated() where !skipped.contains(index) {
            // Within the last second the jump isn't worth it.
            guard position >= segment.start, position < segment.end - 1 else { continue }
            skipped.insert(index)
            Log.sponsorBlock.info("Skipping non-music part \(Int(segment.start))s–\(Int(segment.end))s")
            PlayerController.shared.seek(to: segment.end)
            return
        }
    }

    private struct VideoSegments: Decodable {
        struct Raw: Decodable {
            let category: String
            let actionType: String?
            let segment: [Double]
        }
        let videoID: String
        let segments: [Raw]
    }

    /// Non-music segments of `videoId`; empty when there are none, the
    /// server is unreachable, or the reply can't be read.
    private nonisolated static func fetchSegments(videoId: String) async -> [Segment] {
        let hash = SHA256.hash(data: Data(videoId.utf8)).map { String(format: "%02x", $0) }.joined()
        var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(hash.prefix(4))")
        components?.queryItems = [URLQueryItem(name: "categories", value: "[\"music_offtopic\"]")]
        guard let url = components?.url,
              let reply = try? await URLSession.shared.data(from: url),
              (reply.1 as? HTTPURLResponse)?.statusCode == 200,
              let videos = try? JSONDecoder().decode([VideoSegments].self, from: reply.0),
              let video = videos.first(where: { $0.videoID == videoId }) else { return [] }
        return video.segments
            .filter { $0.category == "music_offtopic" && ($0.actionType ?? "skip") == "skip" && $0.segment.count == 2 }
            .map { Segment(start: $0.segment[0], end: $0.segment[1]) }
            .sorted { $0.start < $1.start }
    }
}
