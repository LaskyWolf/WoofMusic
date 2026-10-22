//
//  PlaylistCoverPicker.swift
//  Trop
//

import PhotosUI
import SwiftUI

/// Large cover preview with a photo picker, used by the New Playlist and
/// Edit Playlist sheets. `image` is the picked photo, cropped square; nil
/// keeps `currentUrl`.
struct PlaylistCoverPicker: View {
    var currentUrl: String?
    @Binding var image: UIImage?
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

            PhotosPicker(title, selection: $item, matching: .images)
                .font(.subheadline.weight(.semibold))
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
    @State private var isSaving = false
    @State private var error: String?

    init(playlist: PlaylistDetailInfo, onSaved: @escaping () -> Void) {
        self.playlist = playlist
        self.onSaved = onSaved
        _name = State(initialValue: playlist.title)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PlaylistCoverPicker(currentUrl: playlist.thumbnailUrl, image: $coverImage)
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
