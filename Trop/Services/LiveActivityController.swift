//
//  LiveActivityController.swift
//  Trop
//

import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

/// Mirrors the current song to the Live Activity (Lock Screen and Dynamic Island)
/// and to the Home Screen widget. PlayerController calls `refresh()` whenever it
/// publishes the lock-screen info: track change, play/pause, seek, artwork.
/// Calls within half a second are merged, and unchanged states are not sent.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var activity: Activity<NowPlayingAttributes>?
    private var lastPushed: NowPlayingState?
    private var lastWidgetState: NowPlayingState?
    private var pending: Task<Void, Never>?
    /// Covers encoded for `NowPlaying.thumbnailVersion`.
    private var covers: (version: Int, small: Data?, large: Data?)?

    private init() {
        // An activity left over from an earlier run is updated, or ended when nothing plays.
        activity = Activity<NowPlayingAttributes>.activities.first
        // ActivityKit starts activities only in the foreground: playback started
        // by Siri or a widget gets its activity once the app is opened.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in LiveActivityController.shared.refresh() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            // The process exits right after this returns, so wait for the end call.
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                for activity in Activity<NowPlayingAttributes>.activities {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
                done.signal()
            }
            _ = done.wait(timeout: .now() + 2)
        }
    }

    func refresh() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await push()
        }
    }

    private func push() async {
        let np = NowPlaying.shared
        guard np.videoId != nil, !np.title.isEmpty else { return await end() }
        var state = makeState(np)
        let cover = encodedCovers(np)

        // The widget shows no progress, so seeks and drift don't reload it.
        var widgetState = state
        widgetState.artwork = cover.large
        widgetState.elapsed = 0
        widgetState.duration = 0
        widgetState.startedAt = .distantPast
        if widgetState != lastWidgetState, WidgetSnapshot.write(widgetState) {
            lastWidgetState = widgetState
            WidgetCenter.shared.reloadAllTimelines()
        }

        // The queue ran out: the last song sits paused at its end.
        if !np.isPlaying, !np.hasNext, np.duration > 0, np.currentTime >= np.duration - 1 {
            return await end()
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        state.artwork = cover.small

        if let current = activity, current.activityState != .ended, current.activityState != .dismissed {
            if let lastPushed, lastPushed.isClose(to: state) { return }
            await current.update(ActivityContent(state: state, staleDate: nil))
        } else {
            activity = nil
            guard np.isPlaying, UIApplication.shared.applicationState == .active else { return }
            do {
                activity = try Activity.request(
                    attributes: NowPlayingAttributes(),
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: nil
                )
            } catch {
                Log.player.error("LIVE_ACTIVITY start failed: \(error)")
                return
            }
        }
        lastPushed = state
    }

    private func end() async {
        guard let current = activity else { return }
        activity = nil
        lastPushed = nil
        await current.end(nil, dismissalPolicy: .immediate)
    }

    private func makeState(_ np: NowPlaying) -> NowPlayingState {
        let elapsed = max(0, np.currentTime)
        return NowPlayingState(
            title: String(SongTitle.display(np.title).prefix(120)),
            artist: String(np.displayArtist.prefix(120)),
            isPlaying: np.isPlaying,
            isPodcast: np.musicVideoType == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE",
            elapsed: elapsed,
            duration: max(0, np.duration),
            startedAt: Date().addingTimeInterval(-elapsed),
            tint: Self.rgb(np.accentColor ?? SettingsStore.shared.accentColor),
            artwork: nil
        )
    }

    /// A 64 px cover for the Live Activity (at most 1.8 KB, about 2.4 KB once
    /// base64-encoded in the payload) and a 300 px one for the widget.
    private func encodedCovers(_ np: NowPlaying) -> (small: Data?, large: Data?) {
        guard let image = np.thumbnailUIImage, np.thumbnailVideoId == np.videoId else { return (nil, nil) }
        if let covers, covers.version == np.thumbnailVersion { return (covers.small, covers.large) }
        let small = Self.jpeg(image, side: 64, maxBytes: 1800) ?? Self.jpeg(image, side: 40, maxBytes: 1800)
        let large = Self.jpeg(image, side: 300, maxBytes: 80_000)
        covers = (np.thumbnailVersion, small, large)
        return (small, large)
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

private extension NowPlayingState {
    /// Same song and look, and a progress bar that differs by under a second.
    func isClose(to other: NowPlayingState) -> Bool {
        guard title == other.title, artist == other.artist, isPlaying == other.isPlaying,
              isPodcast == other.isPodcast, tint == other.tint, artwork == other.artwork,
              abs(duration - other.duration) < 1 else { return false }
        return isPlaying ? abs(startedAt.timeIntervalSince(other.startedAt)) < 1 : abs(elapsed - other.elapsed) < 1
    }
}
