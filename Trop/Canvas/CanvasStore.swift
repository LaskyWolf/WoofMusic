//
//  CanvasStore.swift
//  Trop
//
//  Clips the listener picked by hand, per track. Two kinds: a URL found in the
//  catalogue (or pasted) and a video imported from Photos and copied into the
//  app's Documents. A pick beats both automatic sources, which is the only way
//  to give a track a clip when Spotify and Apple Music both have none.
//

import Foundation

enum CanvasStore {
    /// One track's choice. `localFile` is a file name inside `directory`.
    struct Pick: Codable {
        var remote: URL?
        var localFile: String?
    }

    private static let defaultsKey = "canvas.picks.v2"

    // MARK: - Lookup

    /// The clip to play for a track: the imported file when it still exists,
    /// otherwise the picked URL, otherwise nothing (the automatic sources run).
    static func url(for videoId: String) -> URL? {
        guard !videoId.isEmpty, let pick = picks()[videoId] else { return nil }
        if let file = pick.localFile {
            let url = directory.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return pick.remote
    }

    static func hasPick(for videoId: String) -> Bool {
        url(for: videoId) != nil
    }

    // MARK: - Writing

    static func setRemote(_ url: URL, for videoId: String) {
        guard !videoId.isEmpty else { return }
        var map = picks()
        var pick = map[videoId] ?? Pick()
        if let old = pick.localFile { try? FileManager.default.removeItem(at: directory.appendingPathComponent(old)) }
        pick.localFile = nil
        pick.remote = url
        map[videoId] = pick
        save(map)
    }

    /// Copies the video into Documents so the pick survives the temp file the
    /// picker hands over, and so a deleted Photos original cannot break it.
    @discardableResult
    static func importVideo(from source: URL, for videoId: String) throws -> URL {
        var map = picks()
        var pick = map[videoId] ?? Pick()
        if let old = pick.localFile { try? FileManager.default.removeItem(at: directory.appendingPathComponent(old)) }

        let file = "\(videoId)-\(Int(Date().timeIntervalSince1970)).mov"
        let destination = directory.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)

        pick.localFile = file
        pick.remote = nil
        map[videoId] = pick
        save(map)
        return destination
    }

    static func clear(for videoId: String) {
        var map = picks()
        if let pick = map.removeValue(forKey: videoId), let file = pick.localFile {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
        save(map)
    }

    // MARK: - Storage

    private static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Canvases", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    private static func picks() -> [String: Pick] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let map = try? JSONDecoder().decode([String: Pick].self, from: data) else { return [:] }
        return map
    }

    private static func save(_ map: [String: Pick]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
