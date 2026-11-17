//
//  CacheManager.swift
//  Trop
//
//  One place that owns how much disk the app may use: Nuke's artwork cache,
//  the HTTP cache, lyric translations and the clips imported from Photos.
//  The limit is the listener's choice; every cache is measured against it.
//

import Foundation
import Nuke

enum CacheManager {
    static let limitKey = "settings.cacheLimitMB"
    static let defaultLimitMB = 2048
    static let choices = [256, 512, 1024, 2048, 4096, 8192]

    static var limitMB: Int {
        let stored = UserDefaults.standard.object(forKey: limitKey) as? Int
        return max(128, stored ?? defaultLimitMB)
    }

    static var limitBytes: Int64 { Int64(limitMB) * 1024 * 1024 }

    /// Pushes the limit into both caches. Nuke owns cover art, URLCache owns
    /// every other HTTP response, and both shrink when the listener picks a
    /// smaller number.
    static func applyLimits() {
        let bytes = Int(min(limitBytes, Int64(Int.max)))
        if let dataCache = ImagePipeline.shared.configuration.dataCache as? DataCache {
            dataCache.sizeLimit = bytes
        }
        URLCache.shared = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: bytes,
            diskPath: "trop.http"
        )
    }

    // MARK: - Measurement

    static func usedBytes() -> Int64 {
        directorySize(cachesDirectory) + directorySize(canvasDirectory)
    }

    static func canvasBytes() -> Int64 {
        directorySize(canvasDirectory)
    }

    static func formatted(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(bytes, 0))
    }

    static func summary() -> String {
        "\(formatted(usedBytes())) of \(formatted(limitBytes))"
    }

    // MARK: - Cleaning

    static func clearArtwork() {
        ImagePipeline.shared.configuration.dataCache?.removeAll()
        URLCache.shared.removeAllCachedResponses()
        trimCachesToLimit()
    }

    /// Deletes every imported clip and forgets the picks that pointed at them.
    static func clearCanvases() {
        let url = canvasDirectory
        if let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
        UserDefaults.standard.removeObject(forKey: "canvas.picks.v2")
        // CanvasService is main-actor bound; cleaning can be called from a
        // background trim, so the forget hops to the main actor.
        Task { @MainActor in CanvasService.shared.forgetAll() }
    }

    /// Drops whole caches when the listener lowers the limit below what is on disk.
    static func trimCachesToLimit() {
        guard usedBytes() > limitBytes else { return }
        if canvasBytes() > limitBytes / 4 {
            clearCanvases()
        }
        if usedBytes() > limitBytes {
            ImagePipeline.shared.configuration.dataCache?.removeAll()
            URLCache.shared.removeAllCachedResponses()
        }
    }

    // MARK: - Paths

    private static var cachesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    private static var canvasDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Canvases", isDirectory: true)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
