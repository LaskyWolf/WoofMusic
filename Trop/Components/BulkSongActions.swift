//
//  BulkSongActions.swift
//  Trop
//

import Observation
import SwiftUI

/// Multi-select state shared by the playlist and album pages.
@MainActor
@Observable
final class SongSelection {
    var isActive = false
    var selected: Set<String> = []
    /// Row frames in the "songList" space, read only while dragging down the checkbox column.
    @ObservationIgnored var rowFrames: [Int: CGRect] = [:]
    /// While dragging: true selects the rows passed, false deselects them.
    @ObservationIgnored private var dragSelects: Bool?

    func begin(with song: SongItem? = nil) {
        selected = song.map { [$0.videoId] } ?? []
        isActive = true
    }

    func end() {
        isActive = false
        selected = []
    }

    func toggle(_ song: SongItem) {
        if selected.contains(song.videoId) {
            selected.remove(song.videoId)
        } else {
            selected.insert(song.videoId)
        }
    }

    func picked(from songs: [SongItem]) -> [SongItem] {
        songs.filter { selected.contains($0.videoId) }
    }

    func allSelected(in songs: [SongItem]) -> Bool {
        !songs.isEmpty && selected.count == Set(songs.map(\.videoId)).count
    }

    func toggleAll(in songs: [SongItem]) {
        selected = allSelected(in: songs) ? [] : Set(songs.map(\.videoId))
    }

    func drag(atY y: CGFloat, in songs: [SongItem]) {
        guard let index = rowFrames.first(where: { $0.value.minY <= y && y < $0.value.maxY })?.key,
              songs.indices.contains(index) else { return }
        let id = songs[index].videoId
        let selects = dragSelects ?? !selected.contains(id)
        dragSelects = selects
        if selects { selected.insert(id) } else { selected.remove(id) }
    }

    func endDrag() { dragSelects = nil }
}

extension View {
    /// Song list container: names the coordinate space and, while selecting,
    /// lets a drag down the right edge select or deselect every row it crosses.
    func songSelectionColumn(_ selection: SongSelection, songs: [SongItem]) -> some View {
        coordinateSpace(name: "songList")
            .overlay(alignment: .trailing) {
                if selection.isActive {
                    Color.clear
                        .frame(width: 56)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("songList"))
                                .onChanged { selection.drag(atY: $0.location.y, in: songs) }
                                .onEnded { _ in selection.endDrag() }
                        )
                }
            }
    }

    /// Records a row's frame for the drag selection.
    func trackRowFrame(_ selection: SongSelection, index: Int) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named("songList")) } action: {
            selection.rowFrames[index] = $0
        }
    }
}

/// Toolbar shown while selecting: Select All, the actions menu and Done.
struct SongSelectionToolbar: ToolbarContent {
    let selection: SongSelection
    let songs: [SongItem]
    /// Nil when the list is not an editable playlist.
    var onRemove: (([SongItem]) -> Void)?

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            let all = selection.allSelected(in: songs)
            Button(all ? "Deselect All" : "Select All",
                   systemImage: all ? "checklist.unchecked" : "checklist.checked") {
                selection.toggleAll(in: songs)
            }
            BulkSongActionsMenu(
                songs: selection.picked(from: songs),
                onRemove: onRemove.map { remove -> (() -> Void) in { remove(selection.picked(from: songs)) } },
                onFinished: selection.end
            )
            Button("Done", action: selection.end)
        }
    }
}

/// Actions for the songs picked in a list's multi-select mode.
struct BulkSongActionsMenu: View {
    let songs: [SongItem]
    /// Nil when the list is not an editable playlist.
    var onRemove: (() -> Void)?
    var onFinished: () -> Void

    @ObservedObject private var likeStore = LikeStore.shared
    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var showPlaylistSheet = false
    @State private var confirmRemoveDownloads = false
    @State private var confirmRemove = false

    private var allLiked: Bool {
        songs.allSatisfy { likeStore.isLiked(videoId: $0.videoId) }
    }

    private var downloaded: [SongItem] {
        songs.filter { downloadManager.state(for: $0.videoId) == .completed }
    }

    private var toDownload: [SongItem] {
        songs.filter {
            switch downloadManager.state(for: $0.videoId) {
            case .notStarted, .failed: true
            case .completed, .downloading: false
            }
        }
    }

    var body: some View {
        Menu {
            Section {
                Button("Play", systemImage: "play.fill") {
                    PlaybackQueue.play(songs, log: Log.playlistDetail, context: "bulk play")
                    finish()
                }
                Button("Shuffle", systemImage: "shuffle") {
                    PlaybackQueue.playShuffled(songs, log: Log.playlistDetail, context: "bulk shuffle")
                    finish()
                }
            }

            Section {
                Button("Play Next", systemImage: "text.insert") {
                    songs.forEach(NowPlaying.shared.enqueueNext)
                    finish()
                }
                Button("Add to Queue", systemImage: "text.append") {
                    NowPlaying.shared.appendToQueue(songs)
                    finish()
                }
            }

            Section {
                Button(allLiked ? "Unlike" : "Like", systemImage: allLiked ? "heart.slash" : "heart") {
                    let target = !allLiked
                    let changing = songs.filter { likeStore.isLiked(videoId: $0.videoId) != target }
                    Task { for song in changing { await likeStore.toggle(song: song) } }
                    finish()
                }
                Button("Add to Playlist…", systemImage: "text.badge.plus") { showPlaylistSheet = true }
            }

            if !toDownload.isEmpty {
                Section {
                    Button("Download", systemImage: "arrow.down.circle") {
                        let pending = toDownload
                        Task { for song in pending { await downloadManager.download(song: song) } }
                        finish()
                    }
                }
            }

            if onRemove != nil || !downloaded.isEmpty {
                Section {
                    Menu("Remove from…", systemImage: "minus.circle") {
                        if onRemove != nil {
                            Button("from Playlist", systemImage: "music.note.list", role: .destructive) {
                                confirmRemove = true
                            }
                            .tint(.red)
                        }
                        if !downloaded.isEmpty {
                            Button("from Downloads", systemImage: "arrow.down.circle", role: .destructive) {
                                confirmRemoveDownloads = true
                            }
                            .tint(.red)
                        }
                    }
                    .tint(.red)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("Actions for \(songs.count) selected")
        }
        .disabled(songs.isEmpty)
        .sheet(isPresented: $showPlaylistSheet, onDismiss: finish) {
            AddSongToPlaylistSheet(songs: songs)
        }
        .confirmationDialog("Remove \(downloaded.count) downloads?", isPresented: $confirmRemoveDownloads,
                            titleVisibility: .visible) {
            Button("Remove Downloads", role: .destructive) {
                let ids = downloaded.map(\.videoId)
                Task { for id in ids { await downloadManager.delete(videoId: id) } }
                finish()
            }
        }
        .confirmationDialog("Remove \(songs.count) songs from this playlist?", isPresented: $confirmRemove,
                            titleVisibility: .visible) {
            Button("Remove from Playlist", role: .destructive) {
                onRemove?()
                finish()
            }
        }
    }

    private func finish() { onFinished() }
}
