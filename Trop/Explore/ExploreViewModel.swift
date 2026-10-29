//
// ExploreViewModel.swift
// Trop
//
// Created by 686udjie on 11/09/2026.
//

import Foundation
import SwiftUI

/// Drives the Explore tab (`FEmusic_explore`): new releases, charts,
/// moods & genres.
@MainActor
@Observable
final class ExploreViewModel {

    enum Phase {
        case idle
        case loading
        case loaded
        case empty
        case failed
    }

    private(set) var phase: Phase = .idle
    private(set) var sections: [ExploreSection] = []
    private(set) var error: Error?
    /// The "New albums & singles" shelf, which Explore draws as its own
    /// section. Nil when Explore didn't send it.
    private(set) var newReleases: NewReleases?

    struct NewReleases {
        var sectionId: UUID
        /// Release kind per album browseId ("Single", "Album", "EP").
        var kinds: [String: String]
    }

    private var hasLoaded = false

    // MARK: - Loading

    func load() {
        // A tab switch mid-fetch appears again: don't start a second browse request.
        guard !hasLoaded, phase != .loading else { return }
        Task { await fetch() }
    }

    func refresh() async {
        await fetch()
    }

    private func fetch() async {
        // Pull-to-refresh keeps the current page on screen; the skeleton is for the first load.
        if sections.isEmpty { phase = .loading }
        error = nil
        let region = SettingsStore.shared.contentCountry
        Log.explore.debug("Explore fetch start browseId=\(HomePageParser.exploreBrowseId)")
        do {
            let json = try await InnerTubeClient.tropShared.browse(
                browseId: HomePageParser.exploreBrowseId,
                formData: ["selectedValues": [region]]
            )
            Log.explore.debug("Explore fetch ok topKeys=\((json.keys.sorted()))")
            sections = HomePageParser.parseExploreSections(from: json)
            newReleases = Self.applyNewReleaseDetails(from: json, to: &sections)
            await applyRegionalTrending(region: region)
            moveMoodsUnderTrending()
            let moodCount = sections.reduce(0) { $0 + $1.moods.count }
            Log.explore.debug(
                "Explore loaded: " +
                sections.map { "\($0.title)(\($0.kind)):\($0.items.count)" }.joined(separator: ", ") +
                " moods=\(moodCount)"
            )
            phase = sections.isEmpty ? .empty : .loaded
            hasLoaded = phase == .loaded
        } catch {
            if error.isCancellation {
                // Back to idle so the next appear can start the load again.
                if phase == .loading { phase = .idle }
                return
            }
            if error is URLError {
                Log.explore.notice("Explore fetch failed: \(error)")
            } else {
                Log.explore.error("Explore fetch failed: \(error)")
            }
            self.error = error
            phase = .failed
        }
    }

    /// Swaps the Trending shelf for the region's chart tracks. The explore
    /// carousel follows the IP/account region, which the region setting
    /// cannot move — but per-country charts can, via the country selector.
    /// Falls back to explore's own items on any failure.
    private func applyRegionalTrending(region: String) async {
        guard let index = sections.firstIndex(where: { $0.title.lowercased().contains("trending") }) else {
            Log.explore.debug("Explore: no trending shelf for regional swap")
            return
        }
        guard let playlistId = try? await RegionalCharts.trendingPlaylistId(country: region, using: InnerTubeClient.tropShared),
              let (_, rows) = try? await SyncBridge.playlistDetail.fetchPlaylistRows(playlistId: playlistId) else { return }
        let songs = rows.compactMap { item -> SongItem? in
            guard let renderer = item["musicResponsiveListItemRenderer"] as? [String: Any] else { return nil }
            return SongItem.from(renderer)
        }
        guard !songs.isEmpty else { return }
        sections[index].items = songs.map(YTItem.song)
        sections[index].kind = .rows
    }

    /// Puts the Moods section right under Trending. Without a Trending
    /// section the order stays as Explore sent it.
    private func moveMoodsUnderTrending() {
        guard let moodsIndex = sections.firstIndex(where: { $0.kind == .moods }),
              sections.contains(where: { $0.title.lowercased().contains("trending") }) else { return }
        let moods = sections.remove(at: moodsIndex)
        guard let trending = sections.firstIndex(where: { $0.title.lowercased().contains("trending") }) else { return }
        sections.insert(moods, at: trending + 1)
    }

    // MARK: - New releases

    /// Finds the new releases shelf (header browseId `FEmusic_new_releases_albums`)
    /// and fills its albums' artists, year and kind from the card subtitle
    /// ("Single • Artist", "Album • Artist • 2026"), which the shared
    /// two-row parser leaves out.
    private static func applyNewReleaseDetails(
        from json: [String: Any],
        to sections: inout [ExploreSection]
    ) -> NewReleases? {
        guard let raw = BrowseLens.browseSections(json)?
            .compactMap({ $0["musicCarouselShelfRenderer"] as? [String: Any] })
            .first(where: { headerBrowseId($0) == "FEmusic_new_releases_albums" }),
              let header = (raw["header"] as? [String: Any])?["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any],
              let title = InnerTubeJSON.runsText(header["title"] as? [String: Any]),
              let index = sections.firstIndex(where: { $0.kind == .cards && $0.title == title }) else {
            return nil
        }

        var kinds: [String: String] = [:]
        var details: [String: (artists: [YTArtist], year: Int?)] = [:]
        for content in raw["contents"] as? [[String: Any]] ?? [] {
            guard let twoRow = content["musicTwoRowItemRenderer"] as? [String: Any],
                  let browseId = ((twoRow["navigationEndpoint"] as? [String: Any])?["browseEndpoint"]
                      as? [String: Any])?["browseId"] as? String,
                  var runs = (twoRow["subtitle"] as? [String: Any])?["runs"] as? [[String: Any]],
                  !runs.isEmpty else { continue }
            // A first run without a link is the kind, not an artist.
            if runs[0]["navigationEndpoint"] == nil, let kind = runs[0]["text"] as? String {
                kinds[browseId] = kind.trimmingCharacters(in: .whitespaces)
                runs.removeFirst()
            }
            let year = (runs.last?["text"] as? String).flatMap { text -> Int? in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                return trimmed.count == 4 ? Int(trimmed) : nil
            }
            let artists = ArtistCredits.parse(runs: runs).map { YTArtist(name: $0.name, id: $0.browseId) }
            details[browseId] = (artists, year)
        }

        sections[index].items = sections[index].items.map { item in
            guard case .album(var album) = item, let detail = details[album.browseId] else { return item }
            if album.artists.isEmpty { album.artists = detail.artists }
            if album.year == nil { album.year = detail.year }
            return .album(album)
        }
        return NewReleases(sectionId: sections[index].id, kinds: kinds)
    }

    /// The shelf header's browseId: the title link, else the "More" button.
    private static func headerBrowseId(_ carousel: [String: Any]) -> String? {
        guard let header = (carousel["header"] as? [String: Any])?["musicCarouselShelfBasicHeaderRenderer"]
            as? [String: Any] else { return nil }
        let titleRun = ((header["title"] as? [String: Any])?["runs"] as? [[String: Any]])?.first
        let button = (header["moreContentButton"] as? [String: Any])?["buttonRenderer"] as? [String: Any]
        let endpoint = titleRun?["navigationEndpoint"] as? [String: Any]
            ?? button?["navigationEndpoint"] as? [String: Any]
        return (endpoint?["browseEndpoint"] as? [String: Any])?["browseId"] as? String
    }

    // MARK: - Moods

    /// Full category page (songs, playlists, videos, albums shelves).
    static func loadMoodDetail(_ mood: MoodItem) async -> [ExploreSection] {
        Log.explore.debug("Explore mood '\(mood.title)' fetch params=\(mood.params ?? "none")")
        do {
            let json = try await InnerTubeClient.tropShared.browse(
                browseId: HomePageParser.moodsCategoryBrowseId,
                params: mood.params
            )
            let sections = HomePageParser.parseExploreSections(from: json)
            Log.explore.debug(
                "Explore mood '\(mood.title)': " +
                sections.map { "\($0.title)(\($0.kind)):\($0.items.count)" }.joined(separator: ", ")
            )
            return sections
        } catch {
            if error.isCancellation { return [] }
            if error is URLError {
                Log.explore.notice("Explore mood '\(mood.title)' failed: \(error)")
            } else {
                Log.explore.error("Explore mood '\(mood.title)' failed: \(error)")
            }
            return []
        }
    }

}

/// Mood pages kept in memory, so reopening one shows it at once instead of reloading.
@MainActor
enum MoodDetailCache {
    private static var entries: [String: (sections: [ExploreSection], date: Date)] = [:]
    /// A cached page older than this is refreshed quietly in the background.
    private static let maxAge: TimeInterval = 30 * 60

    private static func key(_ mood: MoodItem) -> String { mood.params ?? mood.title }

    static func sections(for mood: MoodItem) -> [ExploreSection]? {
        entries[key(mood)]?.sections
    }

    static func isFresh(_ mood: MoodItem) -> Bool {
        guard let date = entries[key(mood)]?.date else { return false }
        return Date().timeIntervalSince(date) < maxAge
    }

    static func store(_ sections: [ExploreSection], for mood: MoodItem) {
        entries[key(mood)] = (sections, Date())
    }
}
