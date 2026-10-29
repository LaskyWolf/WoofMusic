//
//  WidgetSync.swift
//  Trop
//

import SwiftUI
import UIKit
import WidgetKit

/// Mirrors the current song to the Home Screen widget. The Lock Screen and the
/// Dynamic Island use the system's Now Playing controls, fed by PlayerController's
/// `MPNowPlayingInfoCenter` info, so the app runs no Live Activity of its own.
/// PlayerController calls `refresh()` whenever it publishes that info; calls
/// within half a second are merged, and unchanged states are not written.
@MainActor
final class WidgetSync {
    static let shared = WidgetSync()

    private var lastWidgetState: NowPlayingState?
    private var pending: Task<Void, Never>?
    /// Cover encoded for `NowPlaying.thumbnailVersion`.
    private var cover: (version: Int, data: Data?)?

    private init() {}

    func refresh() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            push()
        }
    }

    private func push() {
        let np = NowPlaying.shared
        guard np.videoId != nil, !np.title.isEmpty else { return }
        let state = NowPlayingState(
            title: String(SongTitle.display(np.title).prefix(120)),
            artist: String(np.displayArtist.prefix(120)),
            isPlaying: np.isPlaying,
            isPodcast: np.musicVideoType == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE",
            tint: Self.rgb(np.accentColor ?? SettingsStore.shared.accentColor),
            artwork: encodedCover(np)
        )
        if state != lastWidgetState, WidgetSnapshot.write(state) {
            lastWidgetState = state
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// A 300 px cover for the widget.
    private func encodedCover(_ np: NowPlaying) -> Data? {
        guard let image = np.thumbnailUIImage, np.thumbnailVideoId == np.videoId else { return nil }
        if let cover, cover.version == np.thumbnailVersion { return cover.data }
        let data = Self.jpeg(image, side: 300, maxBytes: 80_000)
        cover = (np.thumbnailVersion, data)
        return data
    }

    private static func jpeg(_ image: UIImage, side: CGFloat, maxBytes: Int) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: side, height: side)
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        for quality in [0.7, 0.5, 0.3] as [CGFloat] {
            if let data = scaled.jpegData(compressionQuality: quality), data.count <= maxBytes { return data }
        }
        return nil
    }

    private static func rgb(_ color: Color) -> UInt32 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        _ = UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> UInt32 { UInt32(max(0, min(1, value)) * 255) }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }
}
