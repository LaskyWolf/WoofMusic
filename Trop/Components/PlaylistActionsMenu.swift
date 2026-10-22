//
//  PlaylistActionsMenu.swift
//  Trop
//
//  Created by 686udjie on 28/08/2026.
//

import PhotosUI
import SwiftUI

/// The playlist header's "⋯" button: a native pull-down menu. Rename and
/// Change Cover open system dialogs after the menu closes.
struct PlaylistActionsMenu<MenuLabel: View>: View {
    let playlist: PlaylistDetailInfo
    var onSync: (() -> Void)?
    /// Only playlists you own can be renamed.
    var isOwned = false
    /// Custom covers also need the playlist to exist on YouTube Music.
    var canChangeCover = false
    @ViewBuilder var label: () -> MenuLabel

    @State private var showRename = false
    @State private var editedName = ""
    @State private var showRemoveDownloads = false
    @State private var showCoverPicker = false
    @State private var coverItem: PhotosPickerItem?
    @State private var isUploadingCover = false
    @State private var actionError: String?

    var body: some View {
        Menu {
            ControlGroup {
                Button("Rename", systemImage: "pencil") {
                    editedName = playlist.title
                    showRename = true
                }
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
                if canChangeCover {
                    Button(isUploadingCover ? "Uploading Cover…" : "Change Cover…", systemImage: "photo") {
                        showCoverPicker = true
                    }
                    .disabled(isUploadingCover)
                }
            }
            .disabled(playlist.songs.isEmpty && !canChangeCover)

            Section {
                Button("Download", systemImage: "arrow.down.circle", action: downloadAll)
                Button("Remove Downloads", systemImage: "trash", role: .destructive) {
                    showRemoveDownloads = true
                }
            }
            .disabled(playlist.songs.isEmpty)
        } label: {
            label()
        }
        .menuOrder(.fixed)
        .photosPicker(isPresented: $showCoverPicker, selection: $coverItem, matching: .images)
        .onChange(of: coverItem) { _, item in
            guard let item else { return }
            uploadCover(item)
        }
        .alert("Couldn't Update Playlist", isPresented: .init(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .destructiveConfirm(
            "Remove Downloads?",
            isPresented: $showRemoveDownloads,
            message: Text("Remove offline copies of this playlist’s songs from your device? The playlist stays in your library."),
            confirmTitle: "Remove Downloads",
            onConfirm: deleteAllDownloads
        )
        .textPrompt(
            "Rename Playlist",
            isPresented: $showRename,
            placeholder: "Playlist name",
            text: $editedName,
            okTitle: "Rename",
            onOK: renamePlaylist
        )
    }

    // MARK: - Actions

    private func uploadCover(_ item: PhotosPickerItem) {
        isUploadingCover = true
        Task {
            defer {
                isUploadingCover = false
                coverItem = nil
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    throw PlaylistCoverUploader.UploadError.unreadableImage
                }
                try await PlaylistCoverUploader.setCover(image, playlistId: playlist.playlistId)
                onSync?()
            } catch {
                Log.playlistCover.error("Cover upload failed: \(error)")
                actionError = error.localizedDescription
            }
        }
    }

    private func renamePlaylist() {
        let name = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != playlist.title else { return }
        Task {
            do {
                try await SyncBridge.mutations.renamePlaylist(
                    playlistId: playlist.playlistId,
                    newName: name
                )
                onSync?()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

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
