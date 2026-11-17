//
//  HistoryViewModel.swift
//  Trop
//
//  Created by 686udjie on 13/07/2026.
//

import Foundation
import GRDB

/// One song in the merged history: a play from this app (it has an `event`,
/// so it can be deleted) or one only YouTube Music knows about.
struct HistoryRow: Identifiable {
    let song: SongItem
    var event: Event?
    var id: String { event.map { "e\($0.id ?? 0)" } ?? "r\(song.videoId)" }
}

struct HistoryDay: Identifiable {
    let title: String
    var rows: [HistoryRow]
    var id: String { title }
}

@MainActor
@Observable
final class HistoryViewModel {
    private(set) var days: [HistoryDay] = []
    var isLoading = true

    private let db = DatabaseService.shared
    private var local: [DatabaseService.HistoryEntry] = []
    /// Plays read from the database; scrolling to the end raises it by `pageSize`.
    private var localLimit = HistoryViewModel.pageSize
    private static let pageSize = 100
    /// The last read filled the limit, so older plays may be waiting.
    private(set) var hasMoreLocal = false
    private var remote: [(title: String, songs: [SongItem])] = []

    func load() async {
        isLoading = true
        await loadLocal()
        isLoading = false
        await loadRemote()
    }

    func loadLocal() async {
        do {
            local = try await db.fetchHistory(limit: localLimit)
            hasMoreLocal = local.count == localLimit
            rebuild()
        } catch {
            if error.isCancellation { return }
            Log.historyView.error("Failed to load local history: \(error)")
        }
    }

    /// The next `pageSize` older plays, asked for when the list's end comes on screen.
    func loadMoreLocal() async {
        guard hasMoreLocal else { return }
        hasMoreLocal = false
        localLimit += Self.pageSize
        await loadLocal()
    }

    /// YouTube Music's history joins the list when it arrives; signed out or offline, the list stays local.
    func loadRemote() async {
        do {
            let json = try await InnerTubeClient.tropShared.browse(browseId: "FEmusic_history")
            var sections = Self.parseRemoteHistory(from: json)
            for index in sections.indices {
                sections[index].songs = await Shorts.removing(from: sections[index].songs)
            }
            remote = sections.filter { !$0.songs.isEmpty }
            rebuild()
        } catch {
            if error.isCancellation { return }
            Log.historyView.notice("Failed to load remote history: \(error)")
        }
    }

    func deleteEvents(_ events: [Event]) async {
        let ids = events.compactMap(\.id)
        try? await db.write { db in _ = try Event.deleteAll(db, keys: ids) }
        await loadLocal()
    }

    // MARK: - Merge

    /// Plays from this app by day, then what YouTube Music lists for that day and
    /// this app does not (plays on other devices). A play from here that already
    /// reached YouTube Music shows once.
    private func rebuild() {
        let calendar = Calendar.current
        var byDay: [Date: [HistoryRow]] = [:]
        for entry in local.sorted(by: { $0.event.timestamp > $1.event.timestamp }) {
            let day = calendar.startOfDay(for: entry.event.timestamp)
            byDay[day, default: []].append(HistoryRow(song: SongItem(historyEntry: entry), event: entry.event))
        }
        // Shelves covering a period ("Last week") have no single day: they keep their
        // title and sit where that period starts, holding only songs not listed elsewhere.
        var periods: [(date: Date, day: HistoryDay)] = []
        var everywhere = Set(local.map(\.event.songId))
        for section in remote {
            if let day = Self.day(forTitle: section.title) {
                var known = Set(byDay[day, default: []].map(\.song.videoId))
                let extra = section.songs.filter { known.insert($0.videoId).inserted }.map { HistoryRow(song: $0, event: nil) }
                byDay[day, default: []].append(contentsOf: extra)
                everywhere.formUnion(extra.map(\.song.videoId))
                continue
            }
            let rows = section.songs.filter { everywhere.insert($0.videoId).inserted }.map { HistoryRow(song: $0, event: nil) }
            guard !rows.isEmpty else { continue }
            let date = RecapService.shelfDate(section.title, now: Date(), calendar: calendar) ?? .distantPast
            periods.append((date, HistoryDay(title: section.title, rows: rows)))
        }
        let dated = byDay.keys.map { (date: $0, day: HistoryDay(title: Self.title(for: $0), rows: byDay[$0] ?? [])) }
        // Stable order for equal dates: a day before the period that starts on it.
        days = (dated + periods).enumerated()
            .sorted { $0.element.date != $1.element.date ? $0.element.date > $1.element.date : $0.offset < $1.offset }
            .map(\.element.day)
    }

    private static func title(for day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    /// The day of one of YouTube's section titles ("Today", "Monday", "November 12"), which the
    /// app asks for in English. Nil for a title in another form.
    static func day(forTitle title: String, now: Date = Date()) -> Date? {
        let cal = Calendar.current
        let text = title.trimmingCharacters(in: .whitespaces)
        let today = cal.startOfDay(for: now)
        if text.caseInsensitiveCompare("Today") == .orderedSame { return today }
        if text.caseInsensitiveCompare("Yesterday") == .orderedSame { return cal.date(byAdding: .day, value: -1, to: today) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEEE"
        for offset in 2...7 {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            if formatter.string(from: day).caseInsensitiveCompare(text) == .orderedSame { return day }
        }
        for template in ["MMMMd", "MMMd"] {
            formatter.setLocalizedDateFormatFromTemplate(template)
            guard let parsed = formatter.date(from: text) else { continue }
            var parts = cal.dateComponents([.month, .day], from: parsed)
            parts.year = cal.component(.year, from: now)
            guard let day = cal.date(from: parts) else { continue }
            // No year in the title means the last 12 months.
            return day > today ? cal.date(byAdding: .year, value: -1, to: day) : day
        }
        for template in ["MMMMdy", "MMMdy"] {
            formatter.setLocalizedDateFormatFromTemplate(template)
            if let day = formatter.date(from: text) { return cal.startOfDay(for: day) }
        }
        return nil
    }

    // MARK: - Remote history parse

    /// Also read by the Woof Recap, so it is not tied to the main actor.
    nonisolated static func parseRemoteHistory(from json: [String: Any]) -> [(title: String, songs: [SongItem])] {
        guard let contents = json["contents"] as? [String: Any] else {
            Log.historyView.debug("No 'contents' in response, keys: \(json.keys.sorted())")
            return []
        }
        guard contents["singleColumnBrowseResultsRenderer"] is [String: Any],
              let shelfList = BrowseLens.browseSections(json) else {
            Log.historyView.debug("Couldn't navigate to sectionListRenderer.contents")
            return []
        }

        var sections: [(title: String, songs: [SongItem])] = []

        for shelfDict in shelfList {
            guard let shelf = shelfDict["musicShelfRenderer"] as? [String: Any] else {
                Log.historyView.debug("Skipping non-musicShelfRenderer: \(shelfDict.keys.sorted())")
                continue
            }

            let title = extractShelfTitle(shelf) ?? "Unknown"
            guard let items = shelf["contents"] as? [[String: Any]] else { continue }

            var songs: [SongItem] = []
            for itemDict in items {
                guard let renderer = itemDict["musicResponsiveListItemRenderer"] as? [String: Any] else { continue }
                if let song = SongItem.from(renderer) {
                    songs.append(song)
                }
            }

            if !songs.isEmpty {
                sections.append((title, songs))
            }
        }

        return sections
    }

    private nonisolated static func extractShelfTitle(_ shelf: [String: Any]) -> String? {
        guard let titleDict = shelf["title"] as? [String: Any],
              let runs = titleDict["runs"] as? [[String: Any]],
              let first = runs.first,
              let text = first["text"] as? String else {
            return nil
        }
        return text
    }
}

extension SongItem {
    /// The saved song, or a placeholder named after its id when the song row is gone.
    init(historyEntry entry: DatabaseService.HistoryEntry) {
        if let entity = entry.song {
            self.init(entity: entity)
        } else {
            self.init(
                videoId: entry.event.songId,
                title: entry.event.songId,
                artists: [],
                album: nil,
                albumId: nil,
                duration: 0,
                thumbnailUrl: ArtworkURLs.fallback(for: entry.event.songId),
                isExplicit: false,
                playlistId: nil
            )
        }
    }
}
