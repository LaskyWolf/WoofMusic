//
//  Log.swift
//  Trop
//
//  Created by 686udjie on 20/07/2026.
//

import Foundation
import OSLog

/// Appends log lines to Documents/log.txt (exposed as Trop/log.txt in the
/// Files app) so issues that only show up on-device can be diagnosed without
/// attaching to Xcode. Users can share this file when reporting bugs. The
/// file rotates itself once it exceeds ~1 MB.
final class FileLog {
    static let shared = FileLog()

    private let queue = DispatchQueue(label: "com.686udjie.Trop.FileLog")
    private let maxBytes = 1_000_000

    var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("log.txt")
    }

    private init() {
        // Older versions wrote authentication values into this file.
        let cleanupKey = "privacy.authLogCleanup.v1"
        guard !UserDefaults.standard.bool(forKey: cleanupKey), let url = fileURL else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                return
            }
        }
        UserDefaults.standard.set(true, forKey: cleanupKey)
    }

    /// Kept open between lines instead of reopened for each one. Only touched on `queue`.
    private var handle: FileHandle?
    /// Size of the file behind `handle`, so rotation needs no file stat per line.
    private var size = 0

    func append(_ category: String, _ level: String, _ message: String) {
        queue.async { [weak self] in
            guard let self, let url = self.fileURL else { return }
            let stamp = Self.formatter.string(from: Date())
            let line = "\(stamp) [\(level)][\(category)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            if self.handle == nil {
                self.handle = try? FileHandle(forWritingTo: url)
                self.size = Int((try? self.handle?.seekToEnd()) ?? 0)
            }
            if let handle = self.handle, self.size <= self.maxBytes {
                do {
                    try handle.write(contentsOf: data)
                    self.size += data.count
                    return
                } catch {
                    // Falls through to a fresh file below.
                }
            }
            // No file yet, past ~1 MB (rotate: keep it simple, start a fresh
            // file) or a failed write. The next line reopens the new file.
            try? self.handle?.close()
            self.handle = nil
            try? data.write(to: url, options: .atomic)
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

struct AppLogger {
    let logger: Logger
    var category: String = ""
    /// mpv streams every internal log line through here — far too chatty to
    /// mirror onto disk.
    var writesToDisk: Bool = true
    var redact: Bool = true

    private func emit(_ level: String, _ message: String) {
        guard writesToDisk else { return }
        FileLog.shared.append(category, level, message)
    }

    func debug(_ message: String) {
        emit("DEBUG", message)
        if redact {
            logger.debug("\(message, privacy: .private)")
        } else {
            logger.debug("\(message)")
        }
    }

    func info(_ message: String) {
        emit("INFO", message)
        if redact {
            logger.info("\(message, privacy: .private)")
        } else {
            logger.info("\(message)")
        }
    }

    func notice(_ message: String) {
        emit("NOTICE", message)
        if redact {
            logger.notice("\(message, privacy: .private)")
        } else {
            logger.notice("\(message)")
        }
    }

    func warning(_ message: String) {
        emit("WARNING", message)
        if redact {
            logger.warning("\(message, privacy: .private)")
        } else {
            logger.warning("\(message)")
        }
    }

    func error(_ message: String) {
        emit("ERROR", message)
        if redact {
            logger.error("\(message, privacy: .private)")
        } else {
            logger.error("\(message)")
        }
    }

    func fault(_ message: String) {
        emit("FAULT", message)
        if redact {
            logger.fault("\(message, privacy: .private)")
        } else {
            logger.fault("\(message)")
        }
    }
}

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.686udjie.Trop"

    static let player = AppLogger(logger: Logger(subsystem: subsystem, category: "Player"), category: "player", redact: false)
    static let mpv = AppLogger(logger: Logger(subsystem: subsystem, category: "mpv"), category: "mpv", writesToDisk: false, redact: false)
    static let nowPlaying = AppLogger(logger: Logger(subsystem: subsystem, category: "NowPlaying"), category: "nowPlaying")
    static let login = AppLogger(logger: Logger(subsystem: subsystem, category: "Login"), category: "login")
    static let loginViewModel = AppLogger(logger: Logger(subsystem: subsystem, category: "LoginViewModel"), category: "loginViewModel")
    static let db = AppLogger(logger: Logger(subsystem: subsystem, category: "DB"), category: "db")
    static let playlistDetail = AppLogger(logger: Logger(subsystem: subsystem, category: "PlaylistDetail"), category: "playlistDetail")
    static let parser = AppLogger(logger: Logger(subsystem: subsystem, category: "Parser"), category: "parser")
    static let albumDetail = AppLogger(logger: Logger(subsystem: subsystem, category: "AlbumDetail"), category: "albumDetail")
    static let albumDetailViewModel = AppLogger(
        logger: Logger(subsystem: subsystem, category: "AlbumDetailViewModel"), category: "albumDetailViewModel")
    static let artistDetail = AppLogger(logger: Logger(subsystem: subsystem, category: "ArtistDetail"), category: "artistDetail")
    static let podcastDetail = AppLogger(logger: Logger(subsystem: subsystem, category: "PodcastDetail"), category: "podcastDetail")
    static let historyView = AppLogger(logger: Logger(subsystem: subsystem, category: "HistoryView"), category: "historyView")
    static let homeScreenView = AppLogger(logger: Logger(subsystem: subsystem, category: "HomeScreenView"), category: "homeScreenView")
    static let homeViewModel = AppLogger(logger: Logger(subsystem: subsystem, category: "HomeViewModel"), category: "homeViewModel")
    static let explore = AppLogger(logger: Logger(subsystem: subsystem, category: "Explore"), category: "explore")
    static let libraryView = AppLogger(logger: Logger(subsystem: subsystem, category: "LibraryView"), category: "libraryView")
    static let playlistCover = AppLogger(logger: Logger(subsystem: subsystem, category: "PlaylistCover"), category: "playlistCover")
    static let innerTube = AppLogger(logger: Logger(subsystem: subsystem, category: "InnerTube"), category: "innerTube")
    static let playbackState = AppLogger(logger: Logger(subsystem: subsystem, category: "PlaybackState"), category: "playbackState")
    static let registerPlayback = AppLogger(logger: Logger(subsystem: subsystem, category: "RegisterPlayback"), category: "registerPlayback")
    static let search = AppLogger(logger: Logger(subsystem: subsystem, category: "Search"), category: "search")
    static let searchView = AppLogger(logger: Logger(subsystem: subsystem, category: "SearchView"), category: "searchView")
    static let downloadManager = AppLogger(logger: Logger(subsystem: subsystem, category: "DownloadManager"), category: "downloadManager")
    static let sync = AppLogger(logger: Logger(subsystem: subsystem, category: "Sync"), category: "sync")
    static let addSong = AppLogger(logger: Logger(subsystem: subsystem, category: "AddSong"), category: "addSong")
    static let settings = AppLogger(logger: Logger(subsystem: subsystem, category: "Settings"), category: "settings")
    static let discord = AppLogger(logger: Logger(subsystem: subsystem, category: "DiscordSvc"), category: "discord")
    static let lastfm = AppLogger(logger: Logger(subsystem: subsystem, category: "LastFM"), category: "lastfm")
    static let listenBrainz = AppLogger(logger: Logger(subsystem: subsystem, category: "ListenBrainz"), category: "listenBrainz")
    static let sponsorBlock = AppLogger(logger: Logger(subsystem: subsystem, category: "SponsorBlock"), category: "sponsorBlock")
}
