//
//  PlaylistCoverPicker.swift
//  Trop
//

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
                   let picked = UIImage(data: data) {
                    image = picked.centerCroppedSquare()
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

/// Edit Playlist: cover and name, saved together with Done.
struct PlaylistEditSheet: View {
    let playlist: PlaylistDetailInfo
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var coverImage: UIImage?
    @State private var removesCover = false
    @State private var isSaving = false
    @State private var error: String?

    init(playlist: PlaylistDetailInfo, onSaved: @escaping () -> Void) {
        self.playlist = playlist
        self.onSaved = onSaved
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
