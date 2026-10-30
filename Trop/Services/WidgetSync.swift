//
//  WidgetSync.swift
//  Trop
//

import SwiftUI
import UIKit
import WidgetKit

/// Writes what the Home Screen widgets show into the App Group folder and
/// reloads them. The Lock Screen and the Dynamic Island use the system's Now
/// Playing controls, fed by PlayerController's `MPNowPlayingInfoCenter` info,
/// so the app runs no Live Activity of its own.
@MainActor
final class WidgetSync {
    static let shared = WidgetSync()

    private var lastNowPlaying: NowPlayingState?
    private var lastQuickPicks: QuickPicksSnapshot?
    private var pending: Task<Void, Never>?
    private var pendingQuickPicks: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    /// Cover encoded for `NowPlaying.thumbnailVersion`.
    private var cover: (version: Int, data: Data?)?
    /// Small covers by thumbnail URL, for up next, Quick Picks and stats.
    // ponytail: unbounded; a session's queue and picks are a few dozen covers.
    private var smallCovers: [String: Data] = [:]

    /// Side of the small covers, in pixels.
    private static let smallSide: CGFloat = 120

    private init() {}

    // MARK: - Everything

    /// Rewrites the widgets' data and reloads them all, even when nothing
    /// changed: the pushes below reload only on a change, so a reload WidgetKit
    /// dropped would otherwise never be retried. Called at launch, when the app
    /// goes to the background and from Diagnostics.
    func syncAll() {
        guard backgroundTask == .invalid else { return }
        WidgetStore.write(WidgetPing(date: .now, build: WidgetStore.build), to: WidgetStore.appPingFile)
        // Without this the app can be suspended before the data is written.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "WidgetSync") { [weak self] in
            self?.endBackgroundTask()
        }
        Task {
            await pushNowPlaying()
            await pushStats()
            WidgetCenter.shared.reloadAllTimelines()
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Now Playing (Turntable)

    /// PlayerController calls this whenever it publishes the lock-screen info;
    /// calls within half a second are merged, and unchanged states are not written.
    func refresh() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await pushNowPlaying()
        }
    }

    /// For the widget's own buttons: the system reloads a widget as soon as its
    /// intent returns, so the new state has to be written by then.
    func refreshNow() async {
        pending?.cancel()
        await pushNowPlaying()
    }

    private func pushNowPlaying() async {
        let np = NowPlaying.shared
        guard let videoId = np.videoId, !np.title.isEmpty else { return }
        var upNext: [WidgetSong] = []
        for song in np.upcomingSongs(prefixLimit: 3).prefix(3) {
            upNext.append(await widgetSong(song))
        }
        guard !Task.isCancelled else { return }
        let state = NowPlayingState(
            title: String(SongTitle.display(np.title).prefix(120)),
            artist: String(np.displayArtist.prefix(120)),
            isPlaying: np.isPlaying,
            isPodcast: np.musicVideoType == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE",
            tint: Self.rgb(np.accentColor ?? SettingsStore.shared.accentColor),
            artwork: encodedCover(np),
            isLiked: LikeStore.shared.isLiked(videoId: videoId),
            isShuffleOn: np.isShuffleOn,
            isRepeatOn: np.isRepeatOn,
            upNext: upNext
        )
        if state != lastNowPlaying, WidgetStore.write(state, to: WidgetStore.nowPlayingFile) {
            let songChanged = lastNowPlaying.map { $0.title != state.title } ?? false
            lastNowPlaying = state
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nowPlaying)
            // The song that just ended counts in this month's numbers.
            if songChanged {
                Task {
                    await pushStats()
                    WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.stats)
                }
            }
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

    // MARK: - Quick Picks

    /// Home calls this with the cards it shows: pinned songs first, then the picks.
    /// A newer call cancels the older one, so a stale list never lands last.
    func updateQuickPicks(_ cards: [(song: SongItem, isPinned: Bool)], isEnabled: Bool) {
        pendingQuickPicks?.cancel()
        pendingQuickPicks = Task {
            var songs: [WidgetSong] = []
            for card in cards.prefix(6) {
                var song = await widgetSong(card.song)
                song.isPinned = card.isPinned
                song.payload = try? JSONEncoder().encode(card.song)
                songs.append(song)
            }
            guard !Task.isCancelled else { return }
            let snapshot = QuickPicksSnapshot(songs: songs, isEnabled: isEnabled)
            if snapshot != lastQuickPicks, WidgetStore.write(snapshot, to: WidgetStore.quickPicksFile) {
                lastQuickPicks = snapshot
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.quickPicks)
            }
        }
    }

    /// The songs behind the Quick Picks widget, for its play and shuffle intents.
    static func quickPickSongs() -> [SongItem] {
        let snapshot = WidgetStore.read(QuickPicksSnapshot.self, from: WidgetStore.quickPicksFile)
        return snapshot?.songs.compactMap { song in
            song.payload.flatMap { try? JSONDecoder().decode(SongItem.self, from: $0) }
        } ?? []
    }

    // MARK: - Woof Stats

    /// Recomputes this month's numbers.
    private func pushStats() async {
        let settings = SettingsStore.shared
        let interval = RecapService.monthToDate()
        guard let stats = await RecapService.compute(for: interval) else { return }
        let streak = await RecapService.currentStreak()

        var topSong: WidgetSong?
        if let song = stats.topSong {
            topSong = WidgetSong(videoId: song.id, title: song.title, artist: song.artist ?? "",
                                 artwork: await smallCover(song.thumbnailUrl))
        }
        var artists: [StatsSnapshot.Artist] = []
        for artist in stats.topArtists.prefix(3) {
            artists.append(StatsSnapshot.Artist(name: artist.name, minutes: artist.minutes,
                                                artwork: await smallCover(artist.thumbnailUrl)))
        }
        // Unlocked first: the widget has room for 7 of the 23.
        let badges = (stats.badges.filter(\.isUnlocked) + stats.badges.filter { !$0.isUnlocked }).map { badge in
            let pair = badge.kind.hexPair
            return StatsSnapshot.Badge(emoji: badge.kind.emoji, name: badge.kind.name,
                                       isUnlocked: badge.isUnlocked, colors: [pair.0, pair.1])
        }
        let snapshot = StatsSnapshot(
            monthName: RecapService.monthName(interval),
            minutes: stats.totalMinutes,
            weeklyMinutes: stats.weeklyMinutes,
            streakDays: streak,
            streakGoal: RecapService.streakDays,
            topSong: topSong,
            topSongPlays: stats.topSong?.plays ?? 0,
            topArtists: artists,
            badges: badges,
            isTracking: settings.trackPlayHistory
        )
        WidgetStore.write(snapshot, to: WidgetStore.statsFile)
    }

    // MARK: - Covers

    private func widgetSong(_ song: SongItem) async -> WidgetSong {
        WidgetSong(
            videoId: song.videoId,
            title: SongTitle.display(song.title),
            artist: song.artistNamesDisplay,
            artwork: await smallCover(song.thumbnailUrl)
        )
    }

    private func smallCover(_ address: String?) async -> Data? {
        guard let address else { return nil }
        if let cached = smallCovers[address] { return cached }
        guard let url = URL(string: address), let image = try? await ArtworkLoader.image(for: url),
              let data = Self.jpeg(image, side: Self.smallSide, maxBytes: 20_000) else { return nil }
        smallCovers[address] = data
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
