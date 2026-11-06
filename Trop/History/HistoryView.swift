//
//  HistoryView.swift
//  Trop
//
//  Created by 686udjie on 13/07/2026.
//

import SwiftUI

struct HistoryScreenView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var viewModel = HistoryViewModel()
    @State private var isSelecting = false
    @State private var selectedEvents: Set<Event> = []
    @State private var query = ""

    private var displayableSections: [(title: String, entries: [DatabaseService.HistoryEntry])] {
        // Without a search, skip building a song per entry just to match it.
        let isSearching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        return viewModel.groupedEntries.compactMap { section -> (title: String, entries: [DatabaseService.HistoryEntry])? in
            let entries = isSearching ? section.entries.filter { matches(SongItem(historyEntry: $0)) } : section.entries
            return entries.isEmpty ? nil : (section.title, entries)
        }
    }

    private var remoteSections: [(title: String, songs: [SongItem])] {
        viewModel.remoteSections.compactMap { section -> (title: String, songs: [SongItem])? in
            let songs = section.songs.filter(matches)
            return songs.isEmpty ? nil : (section.title, songs)
        }
    }

    /// The search field's words in the title or an artist's name.
    private func matches(_ song: SongItem) -> Bool {
        let words = query.split(separator: " ")
        guard !words.isEmpty else { return true }
        let text = ([song.title] + song.artists.map(\.name)).joined(separator: " ")
        return words.allSatisfy { text.localizedStandardContains($0) }
    }

    private var allEvents: [Event] {
        displayableSections.flatMap(\.entries).map(\.event)
    }

    private var allDisplayableSongs: [SongItem] {
        displayableSections.flatMap(\.entries).map(SongItem.init(historyEntry:))
    }

    var body: some View {
        VStack(spacing: 0) {
            sourcePicker

            Group {
                if viewModel.isLoading {
                    historySkeleton
                } else if viewModel.source == .local {
                    localHistoryContent
                } else {
                    remoteHistoryContent
                }
            }
            .frame(maxHeight: .infinity)
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your history")
        .toolbar {
            toolbarContent
        }
        .onChange(of: viewModel.source) { _, newSource in
            if isSelecting {
                isSelecting = false
                selectedEvents.removeAll()
            }
            if newSource == .remote {
                Task { await viewModel.loadRemote() }
            }
        }
        .task { await viewModel.load() }
    }

    /// Two wide pills, one per source.
    private var sourcePicker: some View {
        HStack(spacing: 10) {
            ForEach(HistorySource.allCases, id: \.self) { source in
                let isOn = viewModel.source == source
                Button { viewModel.source = source } label: {
                    Text(source.rawValue)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Capsule().fill(isOn ? settings.accentColor : Color(.systemGray5)))
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                }
                .buttonStyle(ZoomPressStyle())
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(.horizontal, DesignTokens.screenHPadding)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .sensoryFeedback(.selection, trigger: viewModel.source)
    }

    /// Day titles and song rows, like the loaded list.
    private var historySkeleton: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<2, id: \.self) { _ in
                    ShimmerSectionTitle(width: 110)
                    ForEach(0..<5, id: \.self) { _ in
                        ShimmerMediaRow(artSize: DesignTokens.artSmall)
                            .padding(.horizontal, DesignTokens.screenHPadding)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .allowsHitTesting(false)
        .shimmerClock()
    }

    private var selectedSongs: [SongItem] {
        displayableSections.flatMap(\.entries)
            .filter { selectedEvents.contains($0.event) }
            .map(SongItem.init(historyEntry:))
    }

    private func endSelection() {
        isSelecting = false
        selectedEvents.removeAll()
    }

    /// The playlist page's buttons: Select, then Select All, the songs' actions and Done.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if viewModel.source == .local && !displayableSections.isEmpty {
            ToolbarItemGroup(placement: .primaryAction) {
                if isSelecting {
                    let all = selectedEvents.count == allEvents.count
                    Button(all ? "Deselect All" : "Select All",
                           systemImage: all ? "checklist.unchecked" : "checklist.checked") {
                        selectedEvents = all ? [] : Set(allEvents)
                    }
                    BulkSongActionsMenu(songs: selectedSongs, onFinished: endSelection)
                    if !selectedEvents.isEmpty {
                        Button("Delete from History", systemImage: "trash", role: .destructive) {
                            Task {
                                await viewModel.deleteEvents(Array(selectedEvents))
                                endSelection()
                            }
                        }
                    }
                    Button("Done", action: endSelection)
                } else {
                    Button("Select", systemImage: "checkmark.circle") { isSelecting = true }
                }
            }
        }
    }

    // MARK: - Local

    private var localHistoryContent: some View {
        Group {
            if displayableSections.isEmpty, !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if displayableSections.isEmpty {
                ContentUnavailableView(
                    "No History",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Songs you play will appear here.")
                )
            } else {
                localList
            }
        }
    }

    private var localList: some View {
        List {
            // One section per day, so titles are unique.
            ForEach(displayableSections, id: \.title) { section in
                Section {
                    ForEach(section.entries, id: \.event) { entry in
                        localRow(entry)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    Text(section.title)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .textCase(nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .listStyle(.plain)
        .miniPlayerTracksScroll()
    }

    private func localRow(_ entry: DatabaseService.HistoryEntry) -> some View {
        let song = SongItem(historyEntry: entry)
        let isSelected = selectedEvents.contains(entry.event)
        return SongRowView(
            song: song,
            artSize: DesignTokens.artSmall, artRadius: DesignTokens.cardRadius,
            onTap: {
                if isSelecting {
                    if isSelected {
                        selectedEvents.remove(entry.event)
                    } else {
                        selectedEvents.insert(entry.event)
                    }
                } else {
                    // Built on tap only: computing it per row re-converts the whole history.
                    PlaybackQueue.play(song, in: allDisplayableSongs, log: Log.historyView, context: "History play")
                }
            },
            isSelecting: isSelecting,
            isSelected: isSelected,
            onSelect: {
                isSelecting = true
                selectedEvents = [entry.event]
            },
            showsMenuButton: false
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task { await viewModel.deleteEvents([entry.event]) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Remote

    private var remoteHistoryContent: some View {
        Group {
            if viewModel.isRemoteLoading {
                historySkeleton
            } else if let error = viewModel.remoteError {
                RetryStateView(
                    title: "Couldn't load history",
                    systemImage: "exclamationmark.circle",
                    message: error.localizedDescription,
                    retry: { await viewModel.loadRemote() }
                )
            } else if remoteSections.isEmpty, !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if remoteSections.isEmpty {
                ContentUnavailableView(
                    "No History",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Sign in to see your YouTube Music history.")
                )
            } else {
                remoteList
            }
        }
    }

    private var remoteList: some View {
        List {
            ForEach(remoteSections.indices, id: \.self) { sectionIndex in
                let section = remoteSections[sectionIndex]
                Section {
                    ForEach(section.songs, id: \.videoId) { song in
                        SongRowView(
                            song: song,
                            artSize: DesignTokens.artSmall, artRadius: DesignTokens.cardRadius,
                            onTap: {
                                PlaybackQueue.play(song, in: section.songs, log: Log.historyView, context: "History play")
                            },
                            showsMenuButton: false
                        )
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    Text(section.title)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .textCase(nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .listStyle(.plain)
        .miniPlayerTracksScroll()
    }

}

private extension SongItem {
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
