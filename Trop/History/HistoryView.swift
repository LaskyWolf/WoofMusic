//
//  HistoryView.swift
//  Trop
//
//  Created by 686udjie on 13/07/2026.
//

import SwiftUI

struct HistoryScreenView: View {
    @State private var viewModel = HistoryViewModel()
    @State private var isSelecting = false
    @State private var selectedEvents: Set<Event> = []
    @State private var query = ""

    private var displayableDays: [HistoryDay] {
        viewModel.days.compactMap { day -> HistoryDay? in
            let rows = day.rows.filter { matches($0.song) }
            return rows.isEmpty ? nil : HistoryDay(title: day.title, rows: rows)
        }
    }

    /// The search field's words in the title or an artist's name.
    private func matches(_ song: SongItem) -> Bool {
        let words = query.split(separator: " ")
        guard !words.isEmpty else { return true }
        let text = ([song.title] + song.artists.map(\.name)).joined(separator: " ")
        return words.allSatisfy { text.localizedStandardContains($0) }
    }

    /// Only plays from this app can be selected and deleted.
    private var allEvents: [Event] {
        displayableDays.flatMap(\.rows).compactMap(\.event)
    }

    private var allDisplayableSongs: [SongItem] {
        displayableDays.flatMap(\.rows).map(\.song)
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                historySkeleton
            } else if displayableDays.isEmpty, !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if displayableDays.isEmpty {
                ContentUnavailableView(
                    "No History",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Songs you play will appear here.")
                )
            } else {
                list
            }
        }
        .frame(maxHeight: .infinity)
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your history")
        .toolbar {
            toolbarContent
        }
        .task { await viewModel.load() }
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
        displayableDays.flatMap(\.rows)
            .filter { $0.event.map(selectedEvents.contains) ?? false }
            .map(\.song)
    }

    private func endSelection() {
        isSelecting = false
        selectedEvents.removeAll()
    }

    /// The playlist page's buttons: Select, then Select All, the songs' actions and Done.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !allEvents.isEmpty {
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

    // MARK: - List

    private var list: some View {
        List {
            // One section per day, so titles are unique.
            ForEach(displayableDays) { day in
                Section {
                    ForEach(day.rows) { row in
                        rowView(row)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    Text(day.title)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .textCase(nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // Older plays load when this comes on screen. YouTube Music's own history
            // has no next page: it sends one shelf of about 40 songs.
            if viewModel.hasMoreLocal {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .task { await viewModel.loadMoreLocal() }
            }
        }
        .listStyle(.plain)
        .miniPlayerTracksScroll()
    }

    @ViewBuilder
    private func rowView(_ row: HistoryRow) -> some View {
        if let event = row.event {
            localRow(row.song, event: event)
        } else {
            // From YouTube Music only: it plays, but there is no local play to select or delete.
            SongRowView(
                song: row.song,
                artSize: DesignTokens.artSmall, artRadius: DesignTokens.cardRadius,
                onTap: { if !isSelecting { play(row.song) } },
                showsMenuButton: false
            )
        }
    }

    private func localRow(_ song: SongItem, event: Event) -> some View {
        let isSelected = selectedEvents.contains(event)
        return SongRowView(
            song: song,
            artSize: DesignTokens.artSmall, artRadius: DesignTokens.cardRadius,
            onTap: {
                if isSelecting {
                    if isSelected {
                        selectedEvents.remove(event)
                    } else {
                        selectedEvents.insert(event)
                    }
                } else {
                    play(song)
                }
            },
            isSelecting: isSelecting,
            isSelected: isSelected,
            onSelect: {
                isSelecting = true
                selectedEvents = [event]
            },
            showsMenuButton: false
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task { await viewModel.deleteEvents([event]) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Built on tap only: computing it per row re-converts the whole history.
    private func play(_ song: SongItem) {
        PlaybackQueue.play(song, in: allDisplayableSongs, log: Log.historyView, context: "History play")
    }
}
