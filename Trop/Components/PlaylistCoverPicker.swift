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
    /// Loads the photo picked in `item`, shrunk, lets the user crop and flip it
    /// in a sheet, and puts the square result in `image`.
    fileprivate func loadsPickedCover(item: Binding<PhotosPickerItem?>, into image: Binding<UIImage?>) -> some View {
        modifier(LoadsPickedCover(item: item, image: image))
    }
}

private struct PendingCrop: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct LoadsPickedCover: ViewModifier {
    @Binding var item: PhotosPickerItem?
    @Binding var image: UIImage?
    @State private var pending: PendingCrop?

    func body(content: Content) -> some View {
        content
            .onChange(of: item) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let picked = await Task.detached(priority: .userInitiated, operation: {
                           downsampledCover(from: data)
                       }).value {
                        pending = PendingCrop(image: picked)
                    }
                    item = nil
                }
            }
            .sheet(item: $pending) { crop in
                CoverCropSheet(source: crop.image) { image = $0 }
            }
    }
}

/// Long side of the decoded photo. PlaylistCoverUploader keeps at most
/// 1024 px, and 2048 leaves the short side above that for common photo shapes.
private let coverDecodeMaxPixelSize = 2048

/// Decodes the photo already shrunk (not at full camera resolution). Runs off the main thread.
private func downsampledCover(from data: Data) -> UIImage? {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: coverDecodeMaxPixelSize
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }
    return UIImage(cgImage: cgImage)
}

// MARK: - Crop

/// Square crop for a playlist cover: drag and pinch the photo under a square
/// window, flip it left to right, rotate it a quarter turn.
private struct CoverCropSheet: View {
    let source: UIImage
    var onDone: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var shown: UIImage
    @State private var turns = 0
    @State private var mirrored = false
    @State private var zoom: CGFloat = 1
    @State private var zoomStart: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var offsetStart: CGSize = .zero
    @State private var side: CGFloat = 300

    private static let maxZoom: CGFloat = 5

    init(source: UIImage, onDone: @escaping (UIImage) -> Void) {
        self.source = source
        self.onDone = onDone
        _shown = State(initialValue: source)
    }

    /// Size of the photo when it just fills the window, times the zoom.
    private var displaySize: CGSize {
        let fill = side / max(1, min(shown.size.width, shown.size.height))
        return CGSize(width: shown.size.width * fill * zoom, height: shown.size.height * fill * zoom)
    }

    private func clamped(_ value: CGSize) -> CGSize {
        let maxX = max(0, (displaySize.width - side) / 2)
        let maxY = max(0, (displaySize.height - side) / 2)
        return CGSize(width: min(max(value.width, -maxX), maxX), height: min(max(value.height, -maxY), maxY))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 0)
                Image(uiImage: shown)
                    .resizable()
                    .frame(width: displaySize.width, height: displaySize.height)
                    .offset(offset)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.tileRadius, style: .continuous))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { offset = clamped(CGSize(width: offsetStart.width + $0.translation.width, height: offsetStart.height + $0.translation.height)) }
                            .onEnded { _ in offsetStart = offset }
                    )
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged {
                                zoom = min(max(zoomStart * $0.magnification, 1), Self.maxZoom)
                                offset = clamped(offset)
                            }
                            .onEnded { _ in
                                zoomStart = zoom
                                offsetStart = offset
                            }
                    )
                HStack(spacing: 32) {
                    Button { mirrored.toggle(); reload() } label: {
                        Label("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                    Button { turns += 1; reload() } label: {
                        Label("Rotate", systemImage: "rotate.right")
                    }
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { min($0.size.width - 32, 360) } action: { side = $0 }
            .navigationTitle("Crop Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let cropped = crop() { onDone(cropped) }
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled()
    }

    /// Redraws the photo for the new flip or turn and puts the window back in the middle.
    private func reload() {
        shown = Self.oriented(source, turns: turns, mirrored: mirrored)
        zoom = 1
        zoomStart = 1
        offset = .zero
        offsetStart = .zero
    }

    /// The photo turned `turns` quarter turns clockwise, then flipped left to right.
    private static func oriented(_ image: UIImage, turns: Int, mirrored: Bool) -> UIImage {
        let quarter = ((turns % 4) + 4) % 4
        let size = image.size
        let outSize = quarter % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: outSize, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: outSize.width / 2, y: outSize.height / 2)
            if mirrored { cg.scaleBy(x: -1, y: 1) }
            cg.rotate(by: CGFloat(quarter) * .pi / 2)
            image.draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        }
    }

    /// What's inside the square window, cut from the photo at full resolution.
    private func crop() -> UIImage? {
        guard let cg = shown.cgImage, displaySize.width > 0, displaySize.height > 0 else { return nil }
        let factor = CGFloat(cg.width) / displaySize.width
        let x = ((displaySize.width - side) / 2 - offset.width) * factor
        let y = ((displaySize.height - side) / 2 - offset.height) * factor
        let length = side * factor
        let bounds = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let rect = CGRect(x: x, y: y, width: length, height: length).intersection(bounds).integral
        guard !rect.isNull, let cropped = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }
}


/// Edit Playlist: a header like the playlist page's (large cover, a title you
/// tap to rename, cover buttons) and the sync switch, saved together with Done.
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
            VStack(spacing: 0) {
                headerCard
                    .fixedSize(horizontal: false, vertical: true)
                Form {
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
                .scrollContentBackground(.hidden)
            }
            .background(alignment: .top) { backdrop }
            .background(Color(.systemGroupedBackground))
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
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSaving)
        .loadsPickedCover(item: $pickerItem, into: $coverImage)
        .task {
            if let stored = try? await SyncBridge.store.fetchPlaylist(id: playlist.playlistId) {
                wasSynced = stored.browseId != nil
                syncs = stored.browseId != nil
            }
        }
    }

    // MARK: Header card

    private var headerCard: some View {
        HStack(alignment: .top, spacing: 14) {
            cover
            VStack(alignment: .leading, spacing: 3) {
                Text("Name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                title
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        HeaderRoundIcon(systemImage: "photo")
                    }
                    .accessibilityLabel(coverImage == nil && currentUrl == nil ? "Add Cover" : "Change Cover")
                    if canRemoveCover {
                        Button {
                            coverImage = nil
                            removesCover = hasLocalCover
                        } label: {
                            HeaderRoundIcon(systemImage: "trash")
                        }
                        .accessibilityLabel("Remove Cover")
                    }
                }
                .buttonStyle(ZoomPressStyle(scale: 0.92))
            }
            .frame(maxWidth: .infinity, minHeight: DesignTokens.artLarge, alignment: .leading)
        }
        .padding(.horizontal, DesignTokens.screenHPadding)
        .padding(.vertical, 16)
    }

    /// The name as text with a pencil right after it; a tap turns the text into a
    /// field. A long name is cut short so the pencil always stays visible.
    private var title: some View {
        HStack(spacing: 6) {
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
                    .lineLimit(1)
            }
            Image(systemName: "pencil")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .layoutPriority(1)
                .accessibilityHidden(true)
            if !isEditingName { Spacer(minLength: 0) }
        }
        .font(.title3.weight(.bold))
        .contentShape(Rectangle())
        .onTapGesture { isEditingName = true }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Renames the playlist")
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
        .frame(width: DesignTokens.artLarge, height: DesignTokens.artLarge)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.tileRadius, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
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

    private func syncFooter(wasSynced: Bool) -> String {
        guard syncs else {
            return "Kept only on this iPhone. Turning sync off doesn't delete the playlist from YouTube Music; it only stops syncing."
        }
        if wasSynced { return "Changes to this playlist also go to your YouTube Music account." }
        return madeOnThisPhone
            ? "Moves this playlist, its songs and cover into your YouTube Music account."
            : "Reconnects to the playlist on YouTube Music and keeps the songs added or removed on either side. Song order follows YouTube Music."
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
                    // The songs now, so turning sync back on can tell which side changed what.
                    PlaylistReattach.saveBase(saved, playlistId: id)
                } else if reattaches {
                    try await PlaylistReattach.reattach(playlistId: id)
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
