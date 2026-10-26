//
//  LibraryView.swift
//  Trop
//
//  Created by 686udjie on 05/07/2026.
//

import SwiftUI
import GRDB

struct LibraryView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var artists: [ArtistEntity] = []
    @State private var playlists: [PlaylistEntity] = []
    @State private var albums: [AlbumEntity] = []
    @State private var podcasts: [PodcastEntity] = []
    @State private var likedSongCount = 0
    /// First artworks of Liked Songs and My Top 100, keyed by shortcut id.
    @State private var shortcutCovers: [String: [String]] = [:]
    @State private var isLoading = true
    @State private var selectedFilter: LibraryFilter?
    @State private var showCreateDialog = false
    @State private var playlistToDelete: PlaylistEntity?
    @State private var playlistSongCounts: [String: Int] = [:]
    @State private var didStartSync = false

    @ObservedObject private var router = AppRouter.shared

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let accountState = AccountState.shared

    private var gridColumns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: count)
    }
    private var isList: Bool { settings.libraryLayout == .list }
    /// Full-width rows shrink less on press than grid cards.
    private var pressScale: CGFloat { isList ? 0.98 : 0.94 }

    private var autoPlaylists: [AutoPlaylistInfo] {
        [
            AutoPlaylistInfo(id: "liked", title: "Liked Songs", icon: "heart.fill", tint: .pink,
                             covers: shortcutCovers["liked"] ?? [],
                             subtitle: "\(likedSongCount) songs", route: .likedSongs),
            AutoPlaylistInfo(id: "top100", title: "My Top 100", icon: "trophy.fill", tint: .orange,
                             covers: shortcutCovers["top100"] ?? [],
                             subtitle: "Most played", route: .topSongs(limit: 100)),
            // Covers and subtitle come from DownloadManager views, so only they redraw on download changes.
            AutoPlaylistInfo(id: "downloads", title: "Downloads", icon: "arrow.down.circle.fill", tint: .blue,
                             subtitle: nil, route: nil, detailRoute: .downloads)
        ]
    }

    enum LibraryFilter: String, CaseIterable {
        case playlists = "Playlists"
        case albums = "Albums"
        case artists = "Artists"
        case podcasts = "Podcasts"
    }

    var body: some View {
        NavigationStack(path: $router.libraryPath) {
            VStack(spacing: 0) {
                TabHeaderView(
                    title: "Library",
                    accountIsLoggedIn: accountState.isLoggedIn,
                    accountImageUrl: accountState.accountImageUrl,
                    onHistory: { router.libraryPath.append(DetailRoute.history) },
                    onAccount: { router.libraryPath.append(DetailRoute.settings) },
                    onAdd: { showCreateDialog = true }
                )

                Group {
                    if isLoading {
                        librarySkeleton
                    } else {
                        feedContent
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .toolbar(.hidden, for: .navigationBar)
            .detailRouteDestinations()
            .sheet(isPresented: $showCreateDialog) {
                NewPlaylistSheet(onCreated: { await loadContent() })
            }
            .task {
                // Runs on every appear, so coming back from a playlist deleted there reloads too.
                await loadContent()
                guard !didStartSync else { return }
                didStartSync = true
                Task {
                    await SyncBridge.checkAndSyncIfStale()
                    await loadContent()
                }
            }
            .refreshable {
                await SyncBridge.forceFullSync()
                await loadContent()
            }
            .destructiveConfirm(
                playlistToDelete?.isEditable == false ? "Remove from Library" : "Delete Playlist",
                isPresented: .init(
                    get: { playlistToDelete != nil },
                    set: { if !$0 { playlistToDelete = nil } }
                ),
                message: Text(playlistToDelete?.isEditable == false
                    ? "Remove \"\(playlistToDelete?.name ?? "")\" from your library?"
                    : "Are you sure you want to delete \"\(playlistToDelete?.name ?? "")\"?"),
                confirmTitle: playlistToDelete?.isEditable == false ? "Remove" : "Delete"
            ) {
                if let p = playlistToDelete {
                    Task { await deletePlaylist(p) }
                }
            }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        FilterChipBar(
            items: LibraryFilter.allCases,
            id: \.self,
            title: \.rawValue,
            isSelected: { selectedFilter == $0 },
            onTap: { filter in
                selectedFilter = selectedFilter == filter ? nil : filter
            }
        )
    }

    // MARK: - Feed Content

    @ViewBuilder
    private var feedContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                filterBar
                shortcutRow

                switch selectedFilter {
                case .playlists:
                    playlistsSection
                case .albums:
                    if !albums.isEmpty { albumsSection }
                case .artists:
                    if !artists.isEmpty { artistsSection }
                case .podcasts:
                    if !podcasts.isEmpty { podcastsSection }
                case nil:
                    playlistsSection
                    if !albums.isEmpty { albumsSection }
                    if !artists.isEmpty { artistsSection }
                    if !podcasts.isEmpty { podcastsSection }
                }
            }
        }
        .scrollIndicators(.automatic)
        .miniPlayerTracksScroll()
    }

    // MARK: - Playlists (Auto + User)

    private var playlistsSection: some View {
        librarySection(title: "Playlists", count: playlists.count) {
            ForEach(playlists, id: \.id) { playlist in
                NavigationLink(value: DetailRoute.playlist(playlistId: playlist.id)) {
                    itemCell(
                        url: playlist.thumbnailUrl,
                        title: playlist.name,
                        subtitle: playlistSongCounts[playlist.id].map { "\($0) songs" }
                    )
                }
                .buttonStyle(ZoomPressStyle(scale: pressScale))
                .playlistCardMenu(id: playlist.id) {
                    Section {
                        Button(role: .destructive) {
                            playlistToDelete = playlist
                        } label: {
                            Label(playlist.isEditable ? "Delete" : "Remove from Library", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
            }
        }
    }

    // MARK: - Shortcuts

    /// Liked Songs, My Top 100 and Downloads, right under the filters.
    private var shortcutRow: some View {
        HStack(spacing: 10) {
            ForEach(autoPlaylists) { info in
                NavigationLink(value: info.detailRoute ?? info.route.map(DetailRoute.autoPlaylist)) {
                    shortcutTile(info: info)
                }
                .buttonStyle(ZoomPressStyle())
            }
        }
        .padding(.horizontal, DesignTokens.screenHPadding)
        // The chip bar already pads 8pt below; this doubles the gap to the tiles.
        .padding(.top, 8)
        .padding(.bottom, DesignTokens.sectionGap)
    }

    /// A dark card with the list's first artworks fanned at the top, over a big
    /// tinted symbol cropped by the corner like Explore's mood cards.
    private func shortcutTile(info: AutoPlaylistInfo) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            Group {
                if info.id == "downloads" {
                    DownloadsCovers()
                } else {
                    ShortcutCovers(urls: info.covers)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(info.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Group {
                    if info.id == "downloads" {
                        DownloadsSubtitle()
                    } else if let subtitle = info.subtitle {
                        Text(subtitle)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .frame(height: 116)
        .background {
            ZStack {
                Color(.secondarySystemBackground)
                // Larger than the corner and tilted left, so the card edge crops it.
                Image(systemName: info.icon)
                    .font(.system(size: 66, weight: .semibold))
                    .foregroundStyle(info.tint.opacity(0.4))
                    .rotationEffect(.degrees(-18))
                    // MoodCard's placement (x 24, y 12 at 84 pt), scaled to 66 pt.
                    .offset(x: 19, y: 9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
            .clipShape(shape)
            .accessibilityHidden(true)
        }
        .contentShape(shape)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Artists

    private var artistsSection: some View {
        librarySection(title: "Artists", count: artists.count) {
            ForEach(artists, id: \.id) { artist in
                NavigationLink(value: DetailRoute.artist(browseId: artist.id)) {
                    if isList {
                        listRow(
                            url: artist.thumbnailUrl,
                            title: artist.name,
                            subtitle: artist.isPodcastChannel ? "Podcast Channel" : "Artist",
                            isCircular: true
                        )
                    } else {
                        artistCell(
                            url: artist.thumbnailUrl,
                            name: artist.name
                        )
                    }
                }
                .buttonStyle(ZoomPressStyle(scale: pressScale))
                .artistCardMenu(browseId: artist.id)
            }
        }
    }

    // MARK: - Albums

    private var albumsSection: some View {
        librarySection(title: "Albums", count: albums.count) {
            ForEach(albums, id: \.id) { album in
                NavigationLink(value: DetailRoute.album(browseId: album.id)) {
                    itemCell(
                        url: album.thumbnailUrl,
                        title: album.title,
                        subtitle: isList
                            ? albumDetails(album)
                            : (album.songCount > 0 ? "\(album.songCount) songs" : nil)
                    )
                }
                .buttonStyle(ZoomPressStyle(scale: pressScale))
                .albumCardMenu(browseId: album.id)
            }
        }
    }

    // MARK: - Podcasts

    private var podcastsSection: some View {
        librarySection(title: "Podcasts", count: podcasts.count) {
            ForEach(podcasts, id: \.id) { podcast in
                NavigationLink(value: DetailRoute.podcast(browseId: podcast.id)) {
                    itemCell(
                        url: podcast.thumbnailUrl,
                        title: podcast.name,
                        // The library stores no author, so the row names the kind.
                        subtitle: isList ? "Podcast" : nil,
                        opensPage: false
                    )
                }
                .buttonStyle(ZoomPressStyle(scale: pressScale))
            }
        }
    }

    // MARK: - Components

    private func librarySection<Content: View>(
        title: String,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.titleContentGap) {
            sectionTitle(title, count: count)

            if isList {
                LazyVStack(spacing: 0) {
                    content()
                }
            } else {
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    content()
                }
                .padding(.horizontal, DesignTokens.screenHPadding)
            }
        }
        .padding(.bottom, DesignTokens.sectionGap)
    }

    private func sectionTitle(_ title: String, count: Int? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3)
                .fontWeight(.bold)
            Spacer()
            if let count {
                Text("\(count)")
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
        }
        // Same box as `NavigationTitleView` on Home and Explore.
        .padding(.horizontal, DesignTokens.screenHPadding)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func itemCell(url: String?, title: String, subtitle: String?, opensPage: Bool = true) -> some View {
        if isList {
            listRow(url: url, title: title, subtitle: subtitle, isCircular: false)
        } else {
            gridCell(url: url, title: title, subtitle: subtitle, opensPage: opensPage)
        }
    }

    private func gridCell(url: String?, title: String, subtitle: String?, opensPage: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImageView(url: url)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .opensPageBadge(opensPage)
            Text(title).lineLimit(1).font(.callout)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func listRow(url: String?, title: String, subtitle: String?, isCircular: Bool) -> some View {
        MediaListRow(url: url, title: title, subtitle: subtitle, isCircular: isCircular)
            .padding(.horizontal, DesignTokens.screenHPadding)
    }

    /// "12 songs • 45:30" from what the library stores (it keeps no artist or year).
    private func albumDetails(_ album: AlbumEntity) -> String {
        var parts: [String] = []
        if album.songCount > 0 { parts.append("\(album.songCount) songs") }
        if album.duration > 0 { parts.append(album.duration.formattedDuration) }
        return parts.isEmpty ? "Album" : parts.joined(separator: " • ")
    }

    private func artistCell(url: String?, name: String) -> some View {
        VStack(spacing: 8) {
            AsyncImageView(url: url)
                .frame(width: 120, height: 120)
                .clipShape(Circle())
            VStack(spacing: 2) {
                Text(name).lineLimit(1).font(.callout)
                ArtistKindLabel(name: name).font(.caption).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Loading Skeleton

    /// Same order as `feedContent`: chips, the three shortcut tiles, then
    /// sections in the layout chosen in Settings (grid or list).
    private var librarySkeleton: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ShimmerChips(count: LibraryFilter.allCases.count, width: 88)

                HStack(spacing: 10) {
                    ForEach(0..<autoPlaylists.count, id: \.self) { _ in shortcutTileSkeleton }
                }
                .padding(.horizontal, DesignTokens.screenHPadding)
                .padding(.top, 8)
                .padding(.bottom, DesignTokens.sectionGap)

                ForEach(0..<2, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: DesignTokens.titleContentGap) {
                        ShimmerSectionTitle(width: 130)
                        if isList {
                            VStack(spacing: 0) {
                                ForEach(0..<6, id: \.self) { _ in
                                    ShimmerMediaRow()
                                        .padding(.horizontal, DesignTokens.screenHPadding)
                                }
                            }
                        } else {
                            LazyVGrid(columns: gridColumns, spacing: 16) {
                                ForEach(0..<6, id: \.self) { _ in
                                    VStack(alignment: .leading, spacing: 6) {
                                        ShimmerFill(radius: 12)
                                            .aspectRatio(1, contentMode: .fit)
                                        ShimmerBlock(width: 110, height: 15, radius: 4)
                                        ShimmerBlock(width: 70, height: 12, radius: 4)
                                    }
                                }
                            }
                            .padding(.horizontal, DesignTokens.screenHPadding)
                        }
                    }
                    .padding(.bottom, DesignTokens.sectionGap)
                }
            }
        }
        .scrollIndicators(.hidden)
        .allowsHitTesting(false)
    }

    /// `shortcutTile` without content: the dark 116pt card, two fanned covers
    /// at the top and the title lines at the bottom. The symbol is left out.
    private var shortcutTileSkeleton: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                ShimmerBlock(width: 42, height: 42, radius: 7)
                    .rotationEffect(.degrees(-8))
                    .offset(x: 2, y: 6)
                ShimmerBlock(width: 42, height: 42, radius: 7)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color(.secondarySystemBackground), lineWidth: 2))
                    .rotationEffect(.degrees(6))
                    .offset(x: 24, y: 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 4) {
                ShimmerBlock(width: 70, height: 13, radius: 4)
                ShimmerBlock(width: 50, height: 10, radius: 4)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .frame(height: 116)
        .background(Color(.secondarySystemBackground), in: shape)
    }

    // MARK: - Data Loading

    /// YouTube Music's built-in "Episodes for Later" list ("SE", or "VLSE" as a
    /// browse id). Trop has no use for it, so the library hides it.
    private static let hiddenPlaylistIds: Set<String> = ["SE", "VLSE"]

    private func loadContent() async {
        do {
            async let artistsFetch = DatabaseService.shared.fetchAll(
                ArtistEntity.self,
                sql: "SELECT * FROM artist WHERE bookmarked_at IS NOT NULL ORDER BY name"
            )
            async let playlistsFetch = DatabaseService.shared.fetchAll(
                PlaylistEntity.self,
                sql: "SELECT * FROM playlist WHERE bookmarked_at IS NOT NULL ORDER BY name"
            )
            async let albumsFetch = DatabaseService.shared.fetchAllAlbums()
            async let podcastsFetch = DatabaseService.shared.fetchAllPodcasts()
            async let countFetch = DatabaseService.shared.fetchAllLikedSongCount()
            // Same order as the Liked Songs and My Top 100 pages open with.
            async let coversFetch = DatabaseService.shared.read { db in
                try [
                    "liked": String.fetchAll(
                        db,
                        sql: "SELECT thumbnail_url FROM song WHERE liked = 1 AND thumbnail_url <> '' "
                            + "ORDER BY create_date DESC LIMIT 2"
                    ),
                    "top100": String.fetchAll(
                        db,
                        sql: "SELECT thumbnail_url FROM song WHERE total_play_time > 0 AND thumbnail_url <> '' "
                            + "ORDER BY total_play_time DESC LIMIT 2"
                    )
                ]
            }
            artists = try await artistsFetch
            playlists = try await playlistsFetch.filter { !Self.hiddenPlaylistIds.contains($0.id) }
            albums = try await albumsFetch
            podcasts = try await podcastsFetch.filter { !Self.hiddenPlaylistIds.contains($0.id) }
            likedSongCount = try await countFetch
            shortcutCovers = try await coversFetch

            let rows: [(String, Int)] = try await DatabaseService.shared.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT playlist_id, COUNT(*) as cnt "
                        + "FROM playlist_song_map "
                        + "WHERE EXISTS (SELECT 1 FROM song WHERE id = song_id) "
                        + "GROUP BY playlist_id"
                )
                .map { ($0["playlist_id"] as String, $0["cnt"] as Int) }
            }
            playlistSongCounts = Dictionary(uniqueKeysWithValues: rows)

            isLoading = false
        } catch {
            Log.libraryView.error("Failed to load: \(error)")
            isLoading = false
        }
    }

    private func deletePlaylist(_ playlist: PlaylistEntity) async {
        do {
            try await PlaylistRemoval.remove(playlistId: playlist.id, owned: playlist.isEditable)
            await loadContent()
        } catch {
            Log.libraryView.error("Failed to delete playlist: \(error)")
        }
    }
}

// MARK: - New Playlist Sheet

/// System-style form for creating a playlist, local or synced.
struct NewPlaylistSheet: View {
    let onCreated: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var syncWithYouTube = false
    @State private var coverImage: UIImage?
    @State private var isCreating = false
    @State private var error: Error?
    /// Set once the playlist exists, so a failed cover upload retries only
    /// the cover instead of creating a second playlist.
    @State private var createdId: String?
    @FocusState private var isFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PlaylistCoverPicker(image: $coverImage, onRemove: coverImage == nil ? nil : { coverImage = nil })
                }
                .listRowBackground(Color.clear)

                Section {
                    TextField("Playlist Name", text: $name)
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit(create)
                }

                Section {
                    Toggle("Sync with YouTube Music", isOn: $syncWithYouTube)
                        .disabled(createdId != nil)
                } footer: {
                    Text("Synced playlists live in your YouTube Music account. This can't be changed later.")
                }

                if let error {
                    Section {
                        Label(error.localizedDescription, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView()
                    } else {
                        Button(createdId == nil ? "Create" : "Retry", action: create)
                            .disabled(trimmedName.isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isCreating)
        .onAppear { isFocused = true }
    }

    private func create() {
        guard !trimmedName.isEmpty, !isCreating else { return }
        isCreating = true
        Task {
            defer { isCreating = false }
            do {
                let id: String
                if let createdId {
                    id = createdId
                } else {
                    id = try await createPlaylist()
                    createdId = id
                }
                if let coverImage {
                    try await PlaylistCoverUploader.apply(coverImage, to: id)
                }
                await onCreated()
                dismiss()
            } catch {
                self.error = error
            }
        }
    }

    /// Creates the playlist and returns its id.
    private func createPlaylist() async throws -> String {
        if syncWithYouTube {
            return try await SyncBridge.mutations.createPlaylist(title: trimmedName)
        } else {
            let entity = PlaylistEntity(
                id: UUID().uuidString,
                browseId: nil,
                name: trimmedName,
                thumbnailUrl: nil,
                isEditable: true,
                bookmarkedAt: Date(),
                remoteSongCount: 0
            )
            try await DatabaseService.shared.insert(entity)
            return entity.id
        }
    }
}

// MARK: - Downloads Subtitle

/// Observes DownloadManager on its own, so download progress doesn't redraw the whole Library.
private struct DownloadsSubtitle: View {
    @ObservedObject private var downloadManager = DownloadManager.shared

    var body: some View {
        Text(downloadManager.persistedDownloadCount == 0
             ? "Offline"
             : "\(downloadManager.persistedDownloadCount) songs")
    }
}

// MARK: - Shortcut Covers

/// Up to two artworks fanned like a small stack; nothing when the list is empty,
/// so the tile's big symbol stands alone.
private struct ShortcutCovers: View {
    let urls: [String]

    var body: some View {
        if !urls.isEmpty {
            let isStack = urls.count > 1
            ZStack(alignment: .topLeading) {
                if isStack {
                    cover(urls[1])
                        .rotationEffect(.degrees(-8))
                        .offset(x: 2, y: 6)
                }
                cover(urls[0])
                    .rotationEffect(.degrees(isStack ? 6 : 0))
                    .offset(x: isStack ? 24 : 2, y: 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func cover(_ url: String) -> some View {
        AsyncImageView(url: url)
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
    }
}

/// Observes DownloadManager on its own, like DownloadsSubtitle, and shows the newest downloads.
private struct DownloadsCovers: View {
    // Not private: a private stored property would make the memberwise init private.
    @ObservedObject var downloadManager = DownloadManager.shared

    var body: some View {
        ShortcutCovers(
            urls: Array(downloadManager.tracks.lazy.compactMap(\.thumbnailUrl).filter { !$0.isEmpty }.prefix(2))
        )
    }
}

// MARK: - AutoPlaylist Info

struct AutoPlaylistInfo: Identifiable {
    let id: String
    let title: String
    let icon: String
    let tint: Color
    var covers: [String] = []
    let subtitle: String?
    let route: AutoPlaylistRoute?
    var detailRoute: DetailRoute?
}
