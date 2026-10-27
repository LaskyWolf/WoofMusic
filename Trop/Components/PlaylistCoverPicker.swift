//
//  PlaylistCoverPicker.swift
//  Trop
//

import ImageIO
import PhotosUI
import SwiftUI

/// Large cover preview with a photo picker, used by the New Playlist sheet. `image` is the picked photo, cropped square; nil
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
        .loadsPickedCover(item: $item, into: $image)
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

extension View {
    /// Loads the photo picked in `item`, shrunk and cropped square, into `image`.
    fileprivate func loadsPickedCover(item: Binding<PhotosPickerItem?>, into image: Binding<UIImage?>) -> some View {
        onChange(of: item.wrappedValue) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let picked = await Task.detached(priority: .userInitiated, operation: {
                       downsampledSquareCover(from: data)
                   }).value {
                    image.wrappedValue = picked
                }
                item.wrappedValue = nil
            }
        }
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


/// Edit Playlist: a header card like the playlist page's (cover, a title you
/// tap to rename, a cover button) and the sync switch, saved together with Done.
struct PlaylistEditSheet: View {
    let playlist: PlaylistDetailInfo
    var onSaved: () -> Void
    /// Called after a local playlist moved to YouTube Music: its id no longer exists.
    var onUploaded: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    /// Whether the playlist synced when the sheet opened; nil until read.
    @State private var wasSynced: Bool?
    @State private var syncs = true
    @State private var name: String
    @State private var isEditingName = false
    @FocusState private var nameFocused: Bool
    @State private var coverImage: UIImage?
    @State private var pickerItem: PhotosPickerItem?
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

    /// Playlists made on this iPhone have a UUID id. A playlist you stopped
    /// syncing keeps its YouTube id, so turning sync back on reconnects it
    /// instead of creating a second copy online.
    private var madeOnThisPhone: Bool { UUID(uuidString: playlist.playlistId) != nil }

    private var currentUrl: String? { removesCover ? nil : playlist.thumbnailUrl }

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
                    headerCard
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                if let wasSynced {
                    Section {
                        Toggle("Sync with YouTube Music", isOn: $syncs)
                    } footer: {
                        Text(syncFooter(wasSynced: wasSynced))
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
                wasSynced = stored.browseId != nil
                syncs = stored.browseId != nil
            }
        }
    }

    // MARK: Header card

    private var headerCard: some View {
        HStack(spacing: 16) {
            cover
            VStack(alignment: .leading, spacing: 12) {
                title
                    .font(.title2.weight(.bold))
                HStack(spacing: 12) {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        roundIcon("photo")
                    }
                    .accessibilityLabel(coverImage == nil && currentUrl == nil ? "Add Cover" : "Change Cover")
                    if canRemoveCover {
                        Button {
                            coverImage = nil
                            removesCover = hasLocalCover
                        } label: {
                            roundIcon("trash")
                        }
                        .accessibilityLabel("Remove Cover")
                    }
                }
                // A custom style keeps each button tappable on its own inside the Form row.
                .buttonStyle(ZoomPressStyle(scale: 0.92))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        // Same blurred backdrop as the playlist page header, cut to the card.
        .background(alignment: .top) { backdrop }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.sheetRadius, style: .continuous))
        .loadsPickedCover(item: $pickerItem, into: $coverImage)
    }

    /// The name as text; a tap turns it into a field in the same place.
    @ViewBuilder
    private var title: some View {
        if isEditingName {
            TextField("Playlist Name", text: $name)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit { isEditingName = false }
                // The field only exists after the tap, so focus it once it's on screen.
                .onAppear { nameFocused = true }
                .onChange(of: nameFocused) { _, focused in
                    if !focused { isEditingName = false }
                }
        } else {
            Text(trimmedName.isEmpty ? "Playlist Name" : name)
                .foregroundStyle(trimmedName.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(3)
                .contentShape(Rectangle())
                .onTapGesture { isEditingName = true }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Renames the playlist")
        }
    }

    private var cover: some View {
        Group {
            if let coverImage {
                Image(uiImage: coverImage)
                    .resizable()
                    .scaledToFill()
            } else if let currentUrl {
                AsyncImageView(url: currentUrl)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note.list")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: DesignTokens.artMedium, height: DesignTokens.artMedium)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.tileRadius, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
    }

    /// A picked photo has no URL yet, so it gets the same blur by hand.
    @ViewBuilder
    private var backdrop: some View {
        if let coverImage {
            Image(uiImage: coverImage)
                .resizable()
                .scaledToFill()
                .blur(radius: 40, opaque: true)
                .opacity(0.7)
                .accessibilityHidden(true)
        } else if currentUrl != nil {
            BlurredArtworkBackdrop(url: currentUrl)
        }
    }

    /// Same round button as the New Releases cards, on glass so it reads over any cover.
    private func roundIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.primary)
            .frame(width: NewReleaseCard.buttonSize, height: NewReleaseCard.buttonSize)
            .background(Circle().fill(.ultraThinMaterial))
            .contentShape(Circle())
    }

    private func syncFooter(wasSynced: Bool) -> String {
        guard syncs else {
            return "Kept only on this iPhone. Turning sync off doesn't delete the playlist from YouTube Music; it only stops syncing."
        }
        if wasSynced { return "Changes to this playlist also go to your YouTube Music account." }
        return madeOnThisPhone
            ? "Moves this playlist, its songs and cover into your YouTube Music account."
            : "Reconnects to the playlist on YouTube Music. Its songs there replace changes made on this iPhone."
    }

    // MARK: Save

    private enum EditError: LocalizedError {
        case songsNotSaved

        var errorDescription: String? { "The songs are still being saved on this iPhone. Try again in a moment." }
    }

    private func save() {
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                let id = playlist.playlistId
                let turnsOff = wasSynced == true && !syncs
                let turnsOn = wasSynced == false && syncs
                let reattaches = turnsOn && !madeOnThisPhone
                // Sync changes first, so the name and cover go where the playlist now lives.
                if turnsOff {
                    // The page saves the songs just after showing them; detaching
                    // before that would leave the local copy without them.
                    let saved = try await SyncBridge.store.likedPlaylistSongIdsOrdered(playlistId: id)
                    guard Set(playlist.songs.map(\.videoId)).isSubset(of: Set(saved)) else { throw EditError.songsNotSaved }
                    try await SyncBridge.store.detachPlaylist(id: id)
                } else if reattaches {
                    try await SyncBridge.store.reattachPlaylist(id: id)
                }

                if trimmedName != playlist.title {
                    try await SyncBridge.mutations.renamePlaylist(playlistId: id, newName: trimmedName)
                }
                if let coverImage {
                    try await PlaylistCoverUploader.apply(coverImage, to: id)
                } else if removesCover {
                    try await PlaylistCoverUploader.removeLocalCover(from: id)
                } else if reattaches, let thumb = playlist.thumbnailUrl,
                          let file = LocalPlaylistCover.fileURL(for: thumb),
                          let image = (try? Data(contentsOf: file)).flatMap(UIImage.init(data:)) {
                    // A cover set while it was local goes up with it; a failed upload isn't worth losing the sync for.
                    do {
                        try await PlaylistCoverUploader.setCover(image, playlistId: id)
                        LocalPlaylistCover.delete(thumb)
                    } catch {
                        Log.playlistCover.error("Cover upload after reconnecting failed: \(error)")
                    }
                }

                if turnsOn && madeOnThisPhone {
                    try await PlaylistUpload.upload(localId: id)
                    onUploaded?()
                } else {
                    onSaved()
                }
                dismiss()
            } catch {
                Log.playlistCover.error("Playlist edit failed: \(error)")
                self.error = error.localizedDescription
            }
        }
    }
}
