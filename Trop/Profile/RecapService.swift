//
//  RecapService.swift
//  Trop
//

import Foundation
import GRDB

/// Listening stats for one period, read from the local `event` history.
/// Events only cover what this device played, and deleting history entries removes them.
struct RecapStats: Sendable {
    struct Song: Sendable, Hashable {
        let id: String
        let title: String
        let artist: String?
        let thumbnailUrl: String?
        let plays: Int
    }

    struct Artist: Sendable, Hashable {
        let name: String
        let minutes: Int
        let plays: Int
        /// The artist's picture when the artist table has it, else the cover of their most played song.
        let thumbnailUrl: String?
    }

    let interval: DateInterval
    let totalMinutes: Int
    let plays: Int
    /// Minutes per 7-day slice of the period, from its first day.
    let weeklyMinutes: [Int]
    let topSong: Song?
    /// Up to five, most listened first. Empty when no song has an artist name.
    let topArtists: [Artist]
    /// Every badge, as of the end of the period.
    let badges: [RecapBadge]
    /// Badges locked at the start of the period and unlocked at its end.
    let newBadges: [RecapBadge]

    var isEmpty: Bool { plays == 0 }
    var unlockedCount: Int { badges.filter(\.isUnlocked).count }
}

/// A badge computed from history, with no table of its own: it is unlocked
/// while the history meets its rule, so deleting history can lock it again.
struct RecapBadge: Sendable, Hashable, Identifiable {
    enum Kind: String, Sendable, CaseIterable {
        case nightOwl, earlyBird, loyalPup, streak, explorer, podcastSage, timeBender
    }

    let kind: Kind
    let isUnlocked: Bool
    /// 0...1 toward unlocking.
    let progress: Double
    /// "4/7 days".
    let progressText: String

    var id: Kind { kind }
}

extension RecapBadge.Kind {
    var name: String {
        switch self {
        case .nightOwl: "Night Owl"
        case .earlyBird: "Early Bird"
        case .loyalPup: "Loyal Pup"
        case .streak: "Streak Dragon"
        case .explorer: "Explorer"
        case .podcastSage: "Podcast Sage"
        case .timeBender: "Time Bender"
        }
    }

    var emoji: String {
        switch self {
        case .nightOwl: "🦉"
        case .earlyBird: "🌅"
        case .loyalPup: "🐶"
        case .streak: "🐉"
        case .explorer: "🧭"
        case .podcastSage: "📻"
        case .timeBender: "⏩"
        }
    }

    var summary: String {
        let t = RecapService.self
        return switch self {
        case .nightOwl: "\(Int(t.nightOwlShare * 100))% of your listening between midnight and 5 am"
        case .earlyBird: "\(Int(t.earlyBirdShare * 100))% of your listening between 5 and 9 am"
        case .loyalPup: "Played one song \(t.loyalPupPlays) times"
        case .streak: "Listened \(t.streakDays) days in a row"
        case .explorer: "Played songs by \(t.explorerArtists) different artists"
        case .podcastSage: "Listened to \(t.podcastSageHours) hours of episodes"
        case .timeBender: "Played a show at a speed other than 1×"
        }
    }
}

enum RecapService {
    // Badge rules. Shares need `ratioMinimumMinutes` of listening first, so a
    // single late-night song can't make a Night Owl.
    static let nightOwlShare = 0.4
    static let earlyBirdShare = 0.3
    static let ratioMinimumMinutes = 120
    static let loyalPupPlays = 50
    static let streakDays = 7
    static let explorerArtists = 50
    static let podcastSageHours = 10
    /// Length counted for a YouTube history song that came without one.
    static let unknownSongSeconds = 180

    /// Stats for `interval`; nil when the database can't be read.
    static func compute(for interval: DateInterval) async -> RecapStats? {
        let calendar = Calendar.current
        let remote = await remoteHistory(in: interval, calendar: calendar)
        do {
            return try await DatabaseService.shared.read { db in
                let plays = try fetchPlays(before: interval.end, calendar: calendar, db: db)
                return try stats(plays: plays, remote: remote, interval: interval, calendar: calendar, db: db)
            }
        } catch {
            Log.db.error("Recap failed: \(error)")
            return nil
        }
    }

    /// Every badge as of now, for the profile.
    static func lifetimeBadges() async -> [RecapBadge] {
        let calendar = Calendar.current
        do {
            return try await DatabaseService.shared.read { db in
                try badges(fetchPlays(before: .distantFuture, calendar: calendar, db: db), calendar: calendar)
            }
        } catch {
            Log.db.error("Badges failed: \(error)")
            return []
        }
    }

    /// Whether anything was played in `interval`, on this iPhone or in the
    /// account's YouTube Music history.
    static func hasHistory(in interval: DateInterval) async -> Bool {
        let found = try? await DatabaseService.shared.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM event WHERE timestamp >= ? AND timestamp < ?)",
                arguments: [interval.start, interval.end]
            ) ?? false
        }
        if found == true { return true }
        return await !remoteHistory(in: interval, calendar: .current).isEmpty
    }

    // MARK: - YouTube Music history

    /// A song from the account's YouTube Music history, dated by its shelf.
    struct RemotePlay: Sendable {
        let song: SongItem
        let date: Date
    }

    /// The account's YouTube Music history inside `interval`; empty when signed
    /// out or offline. It covers plays on other devices too.
    static func remoteHistory(in interval: DateInterval, calendar: Calendar, now: Date = Date()) async -> [RemotePlay] {
        guard let json = try? await InnerTubeClient.tropShared.browse(browseId: "FEmusic_history") else { return [] }
        return HistoryViewModel.parseRemoteHistory(from: json).flatMap { shelf -> [RemotePlay] in
            guard let date = shelfDate(shelf.title, now: now, calendar: calendar), interval.contains(date) else { return [] }
            return shelf.songs.map { RemotePlay(song: $0, date: date) }
        }
    }

    // ponytail: YouTube dates its history only by shelf ("Today", "Last week",
    // "September"), so each song gets one day inside its shelf's period and
    // counts as one play; a recap near a month's edge can be off by a few days.
    /// A day inside the period a history shelf covers. Requests use `hl=en`,
    /// so the titles are English. nil for a title it can't place.
    static func shelfDate(_ title: String, now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        func daysAgo(_ days: Int) -> Date? { calendar.date(byAdding: .day, value: -days, to: today) }
        switch title.lowercased() {
        case "today": return today
        case "yesterday": return daysAgo(1)
        case "this week": return daysAgo(2)
        case "last week": return daysAgo(7)
        case "this month": return daysAgo(14)
        case "last month": return calendar.date(byAdding: .month, value: -1, to: today)
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            for format in ["MMMM yyyy", "MMMM"] {
                formatter.dateFormat = format
                guard let parsed = formatter.date(from: title) else { continue }
                var parts = calendar.dateComponents([.year, .month], from: parsed)
                if format == "MMMM" {
                    // "September" alone is the most recent September.
                    let thisYear = calendar.component(.year, from: now)
                    parts.year = (parts.month ?? 0) > calendar.component(.month, from: now) ? thisYear - 1 : thisYear
                }
                parts.day = 15
                return calendar.date(from: parts)
            }
            return nil
        }
    }

    /// Days in a row with a play, ending today, or yesterday when today has none yet.
    static func currentStreak(now: Date = Date()) async -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let since = calendar.date(byAdding: .day, value: -400, to: today) else { return 0 }
        let dates = (try? await DatabaseService.shared.read { db in
            try Date.fetchAll(db, sql: "SELECT timestamp FROM event WHERE timestamp >= ?", arguments: [since])
        }) ?? []
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        var day = days.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
        var streak = 0
        while days.contains(day) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    // MARK: - Periods

    static func month(containing date: Date) -> DateInterval {
        Calendar.current.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 0)
    }

    static func lastMonth(from now: Date = Date()) -> DateInterval {
        let start = month(containing: now).start
        return month(containing: start.addingTimeInterval(-1))
    }

    static func monthToDate(_ now: Date = Date()) -> DateInterval {
        DateInterval(start: month(containing: now).start, end: now)
    }

    /// "October".
    static func monthName(_ interval: DateInterval) -> String {
        interval.start.formatted(.dateTime.month(.wide))
    }

    // MARK: - Aggregation

    private struct Play {
        let songId: String
        let date: Date
        let day: Date
        let hour: Int
        let ms: Int64
        let artist: String?
        let isEpisode: Bool
    }

    // ponytail: loads every event up to `end` to compute lifetime badges;
    // move the badge counts into SQL if histories reach hundreds of thousands of rows.
    private static func fetchPlays(before end: Date, calendar: Calendar, db: Database) throws -> [Play] {
        try Row.fetchAll(db, sql: """
            SELECT event.song_id, event.timestamp, event.play_time, song.artist_name,
                   (COALESCE(song.is_episode, 0) = 1 OR episode.id IS NOT NULL) AS is_ep
            FROM event
            LEFT JOIN song ON song.id = event.song_id
            LEFT JOIN episode ON episode.id = event.song_id
            WHERE event.timestamp < ?
            ORDER BY event.timestamp
            """, arguments: [end])
            .map { row in
                let date: Date = row["timestamp"]
                let artist: String? = row["artist_name"]
                return Play(
                    songId: row["song_id"],
                    date: date,
                    day: calendar.startOfDay(for: date),
                    hour: calendar.component(.hour, from: date),
                    ms: row["play_time"],
                    artist: artist.flatMap { $0.isEmpty ? nil : $0 },
                    isEpisode: row["is_ep"]
                )
            }
    }

    private static func stats(
        plays: [Play], remote: [RemotePlay], interval: DateInterval, calendar: Calendar, db: Database
    ) throws -> RecapStats {
        let local = plays.filter { $0.date >= interval.start }
        // A song this iPhone played in the period is already counted: YouTube
        // history lists the app's own plays too.
        let localIds = Set(local.map(\.songId))
        let remoteSongs = Dictionary(remote.map { ($0.song.videoId, $0.song) }, uniquingKeysWith: { first, _ in first })
        // Badges read local plays only (`plays`): a history song's hour is unknown.
        let remotePlays = remote.filter { !localIds.contains($0.song.videoId) }.map { entry in
            Play(
                songId: entry.song.videoId,
                date: entry.date,
                day: calendar.startOfDay(for: entry.date),
                hour: 12,
                ms: Int64(entry.song.duration > 0 ? entry.song.duration : Self.unknownSongSeconds) * 1000,
                artist: entry.song.artists.first?.name,
                isEpisode: entry.song.musicVideoType == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"
            )
        }
        let inPeriod = local + remotePlays
        let totalMs = inPeriod.reduce(Int64(0)) { $0 + $1.ms }

        let dayCount = max(1, calendar.dateComponents([.day], from: interval.start, to: interval.end).day ?? 1)
        // Whole weeks; the last one takes the month's leftover days.
        var weekly = Array(repeating: Int64(0), count: max(1, dayCount / 7))
        for play in inPeriod {
            let day = calendar.dateComponents([.day], from: interval.start, to: play.date).day ?? 0
            weekly[min(max(0, day / 7), weekly.count - 1)] += play.ms
        }

        let music = inPeriod.filter { !$0.isEpisode }
        let songPlays = Dictionary(grouping: music, by: \.songId).mapValues(\.count)
        let topSongId = songPlays.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key

        var artistMs: [String: Int64] = [:]
        var artistPlays: [String: Int] = [:]
        var artistSongPlays: [String: [String: Int]] = [:]
        for play in music {
            guard let artist = play.artist else { continue }
            artistMs[artist, default: 0] += play.ms
            artistPlays[artist, default: 0] += 1
            artistSongPlays[artist, default: [:]][play.songId, default: 0] += 1
        }
        let topArtistNames = artistMs.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .prefix(5).map(\.key)
        var artistTopSong: [String: String] = [:]
        for name in topArtistNames {
            artistTopSong[name] = artistSongPlays[name]?.max { $0.value < $1.value }?.key
        }

        let songIds = Set(Array(artistTopSong.values) + [topSongId].compactMap { $0 })
        let songs = try DatabaseService.fetchSongMapByIds(Array(songIds), db: db)
        let topSong = topSongId.flatMap { id in
            songs[id].map {
                RecapStats.Song(id: id, title: $0.title, artist: $0.artistName, thumbnailUrl: $0.thumbnailUrl, plays: songPlays[id] ?? 0)
            } ?? remoteSongs[id].map {
                RecapStats.Song(id: id, title: $0.title, artist: $0.artists.first?.name, thumbnailUrl: $0.thumbnailUrl, plays: songPlays[id] ?? 0)
            }
        }
        let topArtists = try topArtistNames.map { name in
            let picture = try String.fetchOne(
                db,
                sql: "SELECT thumbnail_url FROM artist WHERE name = ? AND thumbnail_url IS NOT NULL LIMIT 1",
                arguments: [name]
            )
            let songCover = artistTopSong[name].flatMap { songs[$0]?.thumbnailUrl ?? remoteSongs[$0]?.thumbnailUrl }
            return RecapStats.Artist(
                name: name,
                minutes: Int((artistMs[name] ?? 0) / 60_000),
                plays: artistPlays[name] ?? 0,
                thumbnailUrl: picture ?? songCover
            )
        }

        let before = badges(plays.filter { $0.date < interval.start }, calendar: calendar)
        let after = badges(plays, calendar: calendar)
        let lockedBefore = Set(before.filter { !$0.isUnlocked }.map(\.kind))

        return RecapStats(
            interval: interval,
            totalMinutes: Int(totalMs / 60_000),
            plays: inPeriod.count,
            weeklyMinutes: weekly.map { Int($0 / 60_000) },
            topSong: topSong,
            topArtists: topArtists,
            badges: after,
            newBadges: after.filter { $0.isUnlocked && lockedBefore.contains($0.kind) }
        )
    }

    private static func badges(_ plays: [Play], calendar: Calendar) -> [RecapBadge] {
        let totalMs = plays.reduce(Int64(0)) { $0 + $1.ms }
        let totalMinutes = Int(totalMs / 60_000)

        func share(_ hours: Range<Int>, needed: Double, label: String) -> RecapBadge.Values {
            let ms = plays.filter { hours.contains($0.hour) }.reduce(Int64(0)) { $0 + $1.ms }
            let ratio = totalMs > 0 ? Double(ms) / Double(totalMs) : 0
            let hasEnough = totalMinutes >= ratioMinimumMinutes
            let text = hasEnough
                ? "\(Int(ratio * 100))% \(label)"
                : "\(totalMinutes)/\(ratioMinimumMinutes) min listened"
            let progress = ratio / needed * min(1, Double(totalMinutes) / Double(ratioMinimumMinutes))
            return (hasEnough && ratio >= needed, progress, text)
        }

        func tally(_ value: Int, of goal: Int, _ unit: String) -> RecapBadge.Values {
            (value >= goal, Double(value) / Double(goal), "\(min(value, goal))/\(goal) \(unit)")
        }

        let bestSongPlays = Dictionary(grouping: plays.filter { !$0.isEpisode }, by: \.songId).values.map(\.count).max() ?? 0
        let artists = Set(plays.filter { !$0.isEpisode }.compactMap(\.artist)).count
        let episodeHours = Int(plays.filter(\.isEpisode).reduce(Int64(0)) { $0 + $1.ms } / 3_600_000)

        var longest = 0
        var run = 0
        var previous: Date?
        for day in Set(plays.map(\.day)).sorted() {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = day
        }

        let values: [(RecapBadge.Kind, RecapBadge.Values)] = [
            (.nightOwl, share(0..<5, needed: nightOwlShare, label: "after midnight")),
            (.earlyBird, share(5..<9, needed: earlyBirdShare, label: "before 9 am")),
            (.loyalPup, tally(bestSongPlays, of: loyalPupPlays, "plays")),
            (.streak, tally(longest, of: streakDays, "days")),
            (.explorer, tally(artists, of: explorerArtists, "artists")),
            (.podcastSage, tally(episodeHours, of: podcastSageHours, "h")),
            (.timeBender, timeBender())
        ]
        return values.map { kind, value in
            RecapBadge(kind: kind, isUnlocked: value.0, progress: min(1, max(0, value.1)), progressText: value.2)
        }
    }

    /// The speed picked per podcast show is the only speed the app stores, and
    /// it has no date: the badge is lifetime only and never counts as new in a recap.
    private static func timeBender() -> RecapBadge.Values {
        let rates = UserDefaults.standard.dictionary(forKey: PlaybackSpeed.showRatesKey) as? [String: Double] ?? [:]
        let bent = rates.values.contains { abs($0 - 1) > 0.001 }
        return (bent, bent ? 1 : 0, bent ? "Speed changed" : "Try a show at 1.5×")
    }
}

extension RecapBadge {
    /// unlocked, progress, progress text.
    typealias Values = (Bool, Double, String)
}
