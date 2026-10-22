//
//  PlaylistMoreSheet.swift
//  Trop
//
//  Created by 686udjie on 28/08/2026.
//

import PhotosUI
import SwiftUI

struct PlaylistMoreSheet: View {
    let playlist: PlaylistDetailInfo
    var onSync: (() -> Void)?
    /// Only playlists you own on YouTube Music can get a custom cover.
    var canChangeCover = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsStore) private var settings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showEditAlert = false
    @State private var editedName = ""
    @State private var showRemoveDownloads = false
    @State private var coverItem: PhotosPickerItem?
    @State private var isUploadingCover = false
    @State private var coverError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    MenuSongPreview(
                        title: playlist.title,
                        artist: playlist.authorName ?? "\(playlist.songs.count) songs",
                        thumbnailURL: playlist.thumbnailUrl ?? playlist.songs.first?.thumbnailUrl
                    )
                }

                Section {
                    shortcutRow
                }

                if canChangeCover {
                    Section {
                        PhotosPicker(selection: $coverItem, matching: .images) {
                            HStack {
                                actionLabel("Change Cover…", icon: "photo")
                                if isUploadingCover {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isUploadingCover)
                    } footer: {
                        Text("The cover is saved to your YouTube Music playlist.")
                    }
                }

                Section("Queue") {
                    Button {
                        addToQueue()
                        dismiss()
                    } label: {
                        actionLabel("Add to Queue", icon: "list.bullet")
                    }
                    .disabled(playlist.songs.isEmpty)
                }

                Section {
                    Button {
                        downloadAll()
                        dismiss()
                    } label: {
                        actionLabel("Download", icon: "arrow.down.circle")
                    }
                    .disabled(playlist.songs.isEmpty)

                    Button(role: .destructive) {
                        showRemoveDownloads = true
                    } label: {
                        Label("Remove Downloads", systemImage: "trash")
                    }
                    .disabled(playlist.songs.isEmpty)
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("Remove Downloads deletes this playlist’s offline copies. Your playlist stays in your library.")
                }
            }
            .listStyle(.insetGrouped)
            .tint(settings.accentColor)
            .navigationTitle("Playlist Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .appSheetChrome()
        .destructiveConfirm(
            "Remove Downloads?",
            isPresented: $showRemoveDownloads,
            message: Text("Remove offline copies of this playlist’s songs from your device?"),
            confirmTitle: "Remove Downloads"
        ) {
            deleteAllDownloads()
            dismiss()
        }
        .onChange(of: coverItem) { _, item in
            guard let item else { return }
            uploadCover(item)
        }
        .alert("Couldn't Change Cover", isPresented: .init(
            get: { coverError != nil },
            set: { if !$0 { coverError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(coverError ?? "")
        }
        .textPrompt(
            "Rename Playlist",
            isPresented: $showEditAlert,
            placeholder: "Playlist name",
            text: $editedName,
            okTitle: "Rename",
            onOK: renamePlaylist
        )
    }

    private var shortcutRow: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            MenuShortcutButton(title: "Edit", icon: "pencil") {
                editedName = playlist.title
                showEditAlert = true
            }
            .accessibilityLabel("Rename Playlist")
            if !dynamicTypeSize.isAccessibilitySize { Divider().frame(height: 32) }
            MenuShortcutButton(title: "Sync", icon: "arrow.triangle.2.circlepath") {
                onSync?()
                dismiss()
            }
            .disabled(onSync == nil)
            if !dynamicTypeSize.isAccessibilitySize { Divider().frame(height: 32) }
            MenuShortcutButton(title: "Share", icon: "square.and.arrow.up", action: share)
        }
    }

    private func actionLabel(_ title: String, icon: String) -> some View {
        Label {
            Text(title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: icon).foregroundStyle(settings.accentColor)
        }
    }

    // MARK: - Actions

    private func renamePlaylist() {
        let name = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != playlist.title else { return }
        Task {
            try? await SyncBridge.mutations.renamePlaylist(
                playlistId: playlist.playlistId,
                newName: name
            )
        }
    }

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
                dismiss()
            } catch {
                coverError = error.localizedDescription
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

    private func share() {
        guard let url = URL.playlistShareURL(id: playlist.playlistId) else { return }
        presentShareSheet(items: [url])
        dismiss()
    }

    private func deleteAllDownloads() {
        let dm = DownloadManager.shared
        for song in playlist.songs {
            Task { await dm.delete(videoId: song.videoId) }
        }
    }
}
