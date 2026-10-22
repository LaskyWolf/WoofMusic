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
    @State private var isLoading = true
    @State private var selectedFilter: LibraryFilter?
    @State private var showCreateDialog = false
    @State private var playlistToDelete: PlaylistEntity?
    @State private var playlistSongCounts: [String: Int] = [:]

    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var downloadManager = DownloadManager.shared

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let accountState = AccountState.shared

    private var gridColumns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: count)
    }
    private var autoPlaylists: [AutoPlaylistInfo] {
        [
            AutoPlaylistInfo(id: "liked", title: "Liked Songs", icon: "heart.fill", subtitle: "\(likedSongCount) songs", route: .likedSongs),
            AutoPlaylistInfo(id: "top100", title: "My Top 100", icon: "trophy.fill", subtitle: "Most played", route: .topSongs(limit: 100)),
            AutoPlaylistInfo(id: "downloads", title: "Downloads", icon: "arrow.down.circle.fill",
                             subtitle: downloadsSubtitle, route: nil, detailRoute: .downloads)
        ]
    }

    private var downloadsSubtitle: String {
        downloadManager.persistedDownloadCount == 0
            ? "Offline"
            : "\(downloadManager.persistedDownloadCount) songs"
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
                await loadContent()
                Task {
                    await SyncBridge.checkAndSyncIfStale()
                    await loadContent()
                }
            }
            .onAppear {
                // Coming back from a playlist that was deleted there.
                guard !isLoading else { return }
                Task { await loadContent() }
            }
            .task(id: isLoading) {
                guard !isLoading else { return }
                let urls = (playlists.map(\.thumbnailUrl) + albums.map(\.thumbnailUrl) + artists.map(\.thumbnailUrl) + podcasts.map(\.thumbnailUrl))
                    .compactMap { $0 }
                    .compactMap(URL.init)
                await ImagePreloader.shared.preload(urls)
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
                shortcutRow
                filterBar

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
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        playlistToDelete = playlist
                    } label: {
                        Label(playlist.isEditable ? "Delete" : "Remove from Library", systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: - Shortcuts

    /// Liked Songs, My Top 100 and Downloads, always above the filters.
    private var shortcutRow: some View {
        HStack(spacing: 10) {
            ForEach(autoPlaylists) { info in
                NavigationLink(value: info.detailRoute ?? info.route.map(DetailRoute.autoPlaylist)) {
                    shortcutTile(info: info)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DesignTokens.screenHPadding)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private func shortcutTile(info: AutoPlaylistInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: info.icon)
                .font(.title3)
            Spacer(minLength: 12)
            Text(info.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if let subtitle = info.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .opacity(0.8)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background(autoPlaylistGradient(), in: .rect(cornerRadius: 14, style: .continuous))
        .contentShape(.rect(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Artists

    private var artistsSection: some View {
        librarySection(title: "Artists", count: artists.count) {
            ForEach(artists, id: \.id) { artist in
                NavigationLink(value: DetailRoute.artist(browseId: artist.id)) {
                    artistCell(
                        url: artist.thumbnailUrl,
                        name: artist.name
                    )
                }
                .buttonStyle(.plain)
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
                        subtitle: album.songCount > 0 ? "\(album.songCount) songs" : nil
                    )
                }
                .buttonStyle(.plain)
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
                        subtitle: nil
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Components

    private func librarySection<Content: View>(
        title: String,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.sectionSpacing) {
            sectionTitle(title, count: count)

            LazyVGrid(columns: gridColumns, spacing: 16) {
                content()
            }
            .padding(.horizontal, DesignTokens.screenHPadding)
        }
        .padding(.bottom, 24)
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
        .padding(.horizontal, DesignTokens.screenHPadding)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func autoPlaylistGradient() -> LinearGradient {
        let accent = settings.accentColor
        return LinearGradient(
            colors: [accent.opacity(0.55), accent],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func itemCell(url: String?, title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImageView(url: url)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(title).lineLimit(1).font(.callout)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func artistCell(url: String?, name: String) -> some View {
        VStack(spacing: 8) {
            AsyncImageView(url: url)
                .frame(width: 120, height: 120)
                .clipShape(Circle())
            Text(name).lineLimit(1).font(.callout)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Loading Skeleton

    private var librarySkeleton: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ShimmerChips(count: 4, width: 88)

                ForEach(0..<2, id: \.self) { _ in
                    ShimmerSectionTitle(width: 130)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

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
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Data Loading

    /// YouTube Music's built-in "Episodes for Later" list ("SE", or "VLSE" as a
    /// browse id). Trop has no use for it, so the library hides it.
    private static let hiddenPlaylistIds: Set<String> = ["SE", "VLSE"]

    private func loadContent() async {
        do {
            async let artistsFetch = DatabaseService.shared.fetchAll(
                ArtistEntity.self,
                sql: "SELECT * FROM artist WHERE bookmarked_at IS NOT NULL ORDER BY name LIMIT 50"
            )
            async let playlistsFetch = DatabaseService.shared.fetchAll(
                PlaylistEntity.self,
                sql: "SELECT * FROM playlist WHERE bookmarked_at IS NOT NULL ORDER BY name LIMIT 50"
            )
            async let albumsFetch = DatabaseService.shared.fetchAllAlbums()
            async let podcastsFetch = DatabaseService.shared.fetchAllPodcasts()
            async let countFetch = DatabaseService.shared.fetchAllLikedSongCount()
            artists = try await artistsFetch
            playlists = try await playlistsFetch.filter { !Self.hiddenPlaylistIds.contains($0.id) }
            albums = try await albumsFetch
            podcasts = try await podcastsFetch.filter { !Self.hiddenPlaylistIds.contains($0.id) }
            likedSongCount = try await countFetch

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

// MARK: - AutoPlaylist Info

struct AutoPlaylistInfo: Identifiable {
    let id: String
    let title: String
    let icon: String
    let subtitle: String?
    let route: AutoPlaylistRoute?
    var detailRoute: DetailRoute?
}
