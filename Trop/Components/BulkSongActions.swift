//
//  BulkSongActions.swift
//  Trop
//

import SwiftUI

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
                    let np = NowPlaying.shared
                    np.queueSongs.append(contentsOf: songs)
                    np.persistQueueState()
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
