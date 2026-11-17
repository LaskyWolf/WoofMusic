//
//  CustomArtworkStore.swift
//  Trop
//
//  Covers picked by the listener. A custom cover is a JPEG in Documents, keyed
//  by video id; the "use the video still" switch is a set of ids in
//  UserDefaults. Both are read on the artwork path, so the store stays free of
//  actors and touches only files and defaults.
//

import Foundation
import UIKit

enum CustomArtworkStore {
    /// Posted after a cover is set or removed so the player can reload it.
    static let didChange = Notification.Name("artwork.didChange")

    private static let picksKey = "artwork.picks.v2"
    private static let videoStillKey = "artwork.videoStill.v2"

    /// Documents/Artwork, created on first use.
    static var folder: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Artwork", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func picks() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: picksKey) as? [String: String] ?? [:]
    }

    private static func stills() -> [String] {
        UserDefaults.standard.stringArray(forKey: videoStillKey) ?? []
    }

    /// The saved file for this track, if one was picked.
    static func fileURL(for videoId: String) -> URL? {
        guard let name = picks()[videoId] else { return nil }
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func image(for videoId: String) -> UIImage? {
        guard let url = fileURL(for: videoId) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    static func hasCustomCover(_ videoId: String) -> Bool { fileURL(for: videoId) != nil }

    static func save(_ image: UIImage, for videoId: String) {
        guard let data = image.jpegData(compressionQuality: 0.92) else { return }
        let name = "\(videoId)-\(Int(Date().timeIntervalSince1970)).jpg"
        let url = folder.appendingPathComponent(name)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        var table = picks()
        if let old = table[videoId], old != name {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old))
        }
        table[videoId] = name
        UserDefaults.standard.set(table, forKey: picksKey)
        // A picked cover outranks the video still, so the flag goes away.
        setPrefersVideoStill(false, for: videoId)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func remove(for videoId: String) {
        var table = picks()
        if let old = table.removeValue(forKey: videoId) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old))
        }
        UserDefaults.standard.set(table, forKey: picksKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    // MARK: - Video still

    /// True when this track should show the music video's frame instead of its
    /// album cover.
    static func prefersVideoStill(_ videoId: String) -> Bool {
        stills().contains(videoId)
    }

    static func setPrefersVideoStill(_ on: Bool, for videoId: String) {
        var ids = stills()
        ids.removeAll { $0 == videoId }
        if on { ids.append(videoId) }
        UserDefaults.standard.set(ids, forKey: videoStillKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// The still a video thumbnail would give us, at the best size ytimg offers.
    static func videoStillURL(for videoId: String) -> URL? {
        URL(string: "https://i.ytimg.com/vi/\(videoId)/maxresdefault.jpg")
    }

    // MARK: - Cache housekeeping

    static func totalBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return files.reduce(Int64(0)) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + Int64(size)
        }
    }

    static func removeAll() {
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: url)
        }
        UserDefaults.standard.removeObject(forKey: picksKey)
        UserDefaults.standard.removeObject(forKey: videoStillKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
