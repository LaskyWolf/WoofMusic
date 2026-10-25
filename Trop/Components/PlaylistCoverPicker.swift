//
//  PlaylistCoverPicker.swift
//  Trop
//

import ImageIO
import PhotosUI
import SwiftUI

/// Large cover preview with a photo picker, used by the New Playlist and
/// Edit Playlist sheets. `image` is the picked photo, cropped square; nil
/// keeps `currentUrl`. With `onRemove`, a Remove Cover button shows.
struct PlaylistCoverPicker: View {
    var currentUrl: String?
    @Binding var image: UIImage?
    var onRemove: (() -> Void)?
    @State private var item: PhotosPickerItem?

    private var title: String {
        image == nil && currentUrl == nil ? "Add Cover" : "Change Cover"
    }

    var body: some View {
        VStack(spacing: 12) {
            PhotosPicker(selection: $item, matching: .images) {
                cover
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)

            HStack(spacing: 24) {
                PhotosPicker(title, selection: $item, matching: .images)
                if let onRemove {
                    Button("Remove Cover", role: .destructive, action: onRemove)
                }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity)
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let picked = await Task.detached(priority: .userInitiated, operation: {
                       downsampledSquareCover(from: data)
                   }).value {
                    image = picked
                }
                item = nil
            }
        }
    }

    private var cover: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let currentUrl {
                AsyncImageView(url: currentUrl)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 160, height: 160)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.tileRadius))
    }
}

/// Long side of the decoded photo. PlaylistCoverUploader keeps at most
/// 1024 px, and 2048 leaves the short side above that for common photo shapes.
private let coverDecodeMaxPixelSize = 2048

/// Decodes the photo already shrunk (not at full camera resolution), then
/// crops it square. Runs off the main thread.
private func downsampledSquareCover(from data: Data) -> UIImage? {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: coverDecodeMaxPixelSize
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }
    return UIImage(cgImage: cgImage).centerCroppedSquare()
}

/// Edit Playlist: cover and name, saved together with Done.
struct PlaylistEditSheet: View {
    let playlist: PlaylistDetailInfo
    var onSaved: () -> Void
    /// Called after a local playlist moved to YouTube Music: its id no longer exists.
    var onUploaded: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var isLocal = false
    @State private var name: String
    @State private var coverImage: UIImage?
    @State private var removesCover = false
    @State private var isSaving = false
    @State private var error: String?

    init(playlist: PlaylistDetailInfo, onSaved: @escaping () -> Void, onUploaded: (() -> Void)? = nil) {
        self.playlist = playlist
        self.onSaved = onSaved
        self.onUploaded = onUploaded
        _name = State(initialValue: playlist.title)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Only covers kept on this iPhone can be removed: YouTube Music has no
    /// known way to remove a custom cover.
    private var hasLocalCover: Bool {
        playlist.thumbnailUrl.flatMap(LocalPlaylistCover.fileURL) != nil
    }

    private var canRemoveCover: Bool {
        coverImage != nil || (hasLocalCover && !removesCover)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PlaylistCoverPicker(
                        currentUrl: removesCover ? nil : playlist.thumbnailUrl,
                        image: $coverImage,
                        onRemove: canRemoveCover ? { coverImage = nil; removesCover = hasLocalCover } : nil
                    )
                }
                .listRowBackground(Color.clear)

                Section {
                    TextField("Playlist Name", text: $name)
                        .submitLabel(.done)
                }

                if isLocal {
                    Section {
                        Button("Sync with YouTube Music", systemImage: "icloud.and.arrow.up", action: upload)
                            .disabled(isSaving)
                    } footer: {
                        Text("Moves this playlist, its songs and cover into your YouTube Music account.")
                    }
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Done", action: save)
                            .disabled(trimmedName.isEmpty)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .task {
            if let stored = try? await SyncBridge.store.fetchPlaylist(id: playlist.playlistId) {
                isLocal = stored.browseId == nil
            }
        }
    }

    private func upload() {
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                try await PlaylistUpload.upload(localId: playlist.playlistId)
                onUploaded?()
                dismiss()
            } catch {
                Log.playlistCover.error("Playlist upload failed: \(error)")
                self.error = error.localizedDescription
            }
        }
    }

    private func save() {
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                if trimmedName != playlist.title {
                    try await SyncBridge.mutations.renamePlaylist(playlistId: playlist.playlistId, newName: trimmedName)
                }
                if let coverImage {
                    try await PlaylistCoverUploader.apply(coverImage, to: playlist.playlistId)
                } else if removesCover {
                    try await PlaylistCoverUploader.removeLocalCover(from: playlist.playlistId)
                }
                onSaved()
                dismiss()
            } catch {
                Log.playlistCover.error("Playlist edit failed: \(error)")
                self.error = error.localizedDescription
            }
        }
    }
}
