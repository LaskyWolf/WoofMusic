//
//  Shorts.swift
//  Trop
//

import Foundation

/// Tells YouTube Shorts apart from other videos. YouTube Music's history lists
/// Shorts watched on YouTube as plain user videos (UGC), with nothing marking
/// them; youtube.com/shorts/<id> answers 200 for a Short and redirects otherwise.
enum Shorts {
    /// `songs` without Shorts. Only user videos are checked; a failed check keeps the song.
    static func removing(from songs: [SongItem]) async -> [SongItem] {
        let candidates = Set(songs.filter { $0.musicVideoType == "MUSIC_VIDEO_TYPE_UGC" }.map(\.videoId))
        guard !candidates.isEmpty else { return songs }
        let shorts = await withTaskGroup(of: String?.self) { group in
            for id in candidates { group.addTask { await isShort(id) ? id : nil } }
            var found: Set<String> = []
            for await id in group { if let id { found.insert(id) } }
            return found
        }
        return songs.filter { !shorts.contains($0.videoId) }
    }

    private static let cache = Cache()

    private actor Cache {
        var answers: [String: Bool] = [:]
        func set(_ id: String, _ value: Bool) { answers[id] = value }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    private static func isShort(_ videoId: String) async -> Bool {
        if let known = await cache.answers[videoId] { return known }
        guard let url = URL(string: "https://www.youtube.com/shorts/\(videoId)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        // Without the consent cookie, EU visitors are redirected to the consent page for every video.
        request.setValue("SOCS=CAI", forHTTPHeaderField: "Cookie")
        // A phone or app user agent is sent to m.youtube.com first, Short or not.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return false }
        let short = status == 200
        await cache.set(videoId, short)
        return short
    }
}
