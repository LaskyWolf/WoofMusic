//
//  HistoryViewModel.swift
//  Trop
//
//  Created by 686udjie on 13/07/2026.
//

import Foundation

enum HistorySource: String, CaseIterable, Sendable {
    case local = "On This iPhone"
    case remote = "YouTube Music"
}

@MainActor
@Observable
final class HistoryViewModel {
    var groupedEntries: [(title: String, entries: [DatabaseService.HistoryEntry])] = []
    var remoteSections: [(title: String, songs: [SongItem])] = []
    var source: HistorySource = .local
    var isLoading = true
    var isRemoteLoading = false
    var remoteError: Error?

    private let db = DatabaseService.shared

    func load() async {
        isLoading = true
        await loadLocal()
        isLoading = false
    }

    func loadLocal() async {
        do {
            let raw = try await db.fetchHistory(limit: 100)
            groupedEntries = Self.groupByDate(raw)
        } catch {
            if error.isCancellation { return }
            Log.historyView.error("Failed to load local history: \(error)")
        }
    }

    func loadRemote() async {
        guard source == .remote else { return }
        isRemoteLoading = true
        remoteError = nil
        do {
            let json = try await InnerTubeClient.tropShared.browse(browseId: "FEmusic_history")
            let sections = Self.parseRemoteHistory(from: json)
            remoteSections = sections
        } catch {
            if error is URLError, !error.isCancellation {
                Log.historyView.notice("Failed to load remote history: \(error)")
                remoteError = error
            } else if !error.isCancellation {
                Log.historyView.error("Failed to load remote history: \(error)")
                remoteError = error
            }
        }
        isRemoteLoading = false
    }

    // MARK: - Local group by date

    private static func groupByDate(_ entries: [DatabaseService.HistoryEntry]) -> [(String, [DatabaseService.HistoryEntry])] {
        guard !entries.isEmpty else { return [] }

        let calendar = Calendar.current
        let grouped = Dictionary(grouping: entries) { entry in
            calendar.startOfDay(for: entry.event.timestamp)
        }

        return grouped.keys
            .sorted(by: >)
            .compactMap { day -> (String, [DatabaseService.HistoryEntry])? in
                guard let dayEntries = grouped[day], !dayEntries.isEmpty else { return nil }
                let sorted = dayEntries.sorted { $0.event.timestamp > $1.event.timestamp }
                return (title(for: day), sorted)
            }
    }

    private static func title(for day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    func deleteEvents(_ events: [Event]) async {
        for event in events {
            _ = try? await db.delete(event)
        }
        await loadLocal()
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
