//
//  PlaylistActionsMenu.swift
//  Trop
//
//  Created by 686udjie on 28/08/2026.
//

import SwiftUI

/// The playlist header's "⋯" button: a native pull-down menu. Edit opens
/// the Edit Playlist sheet (cover and name) after the menu closes.
struct PlaylistActionsMenu<MenuLabel: View>: View {
    let playlist: PlaylistDetailInfo
    var onSync: (() -> Void)?
    /// Only playlists you own can be edited.
    var isOwned = false
    /// Shown as "Delete Playlist" for owned playlists and "Remove from Library" for saved ones.
    var onDelete: (() -> Void)?
    @ViewBuilder var label: () -> MenuLabel

    @State private var showEdit = false
    @State private var showRemoveDownloads = false
    @State private var showDelete = false

    var body: some View {
        Menu {
            ControlGroup {
                Button("Edit", systemImage: "pencil") { showEdit = true }
                    .disabled(!isOwned)
                Button("Sync", systemImage: "arrow.triangle.2.circlepath") { onSync?() }
                    .disabled(onSync == nil)
                if let url = URL.playlistShareURL(id: playlist.playlistId) {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .controlGroupStyle(.compactMenu)

            Section {
                Button("Add to Queue", systemImage: "text.append", action: addToQueue)
                Button("Download", systemImage: "arrow.down.circle", action: downloadAll)
                Button("Remove Downloads", systemImage: "trash", role: .destructive) {
                    showRemoveDownloads = true
                }
                .tint(.red)
            }
            .disabled(playlist.songs.isEmpty)

            if onDelete != nil {
                Section {
                    Button(isOwned ? "Delete Playlist" : "Remove from Library", systemImage: "trash", role: .destructive) {
                        showDelete = true
                    }
                    .tint(.red)
                }
            }
        } label: {
            label()
        }
        .menuOrder(.fixed)
        .sheet(isPresented: $showEdit) {
            PlaylistEditSheet(playlist: playlist) { onSync?() }
        }
        .destructiveConfirm(
            "Remove Downloads?",
            isPresented: $showRemoveDownloads,
            message: Text("Remove offline copies of this playlist’s songs from your device? The playlist stays in your library."),
            confirmTitle: "Remove Downloads",
            onConfirm: deleteAllDownloads
        )
        .destructiveConfirm(
            isOwned ? "Delete Playlist?" : "Remove from Library?",
            isPresented: $showDelete,
            message: Text(isOwned
                ? "Delete \"\(playlist.title)\"? This can't be undone."
                : "Remove \"\(playlist.title)\" from your library? The playlist itself stays on YouTube Music."),
            confirmTitle: isOwned ? "Delete" : "Remove",
            onConfirm: { onDelete?() }
        )
    }

    // MARK: - Actions

    private func addToQueue() {
        let np = NowPlaying.shared
        np.queueSongs.append(contentsOf: playlist.songs)
        np.persistQueueState()
    }

    private func downloadAll() {
        for song in playlist.songs {
            Task { await DownloadManager.shared.download(song: song) }
        }
    }

    private func deleteAllDownloads() {
        let dm = DownloadManager.shared
        for song in playlist.songs {
            Task { await dm.delete(videoId: song.videoId) }
        }
    }
}
