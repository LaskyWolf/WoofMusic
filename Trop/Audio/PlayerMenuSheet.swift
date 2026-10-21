//
//  PlayerMenuSheet.swift
//  Trop
//
//  Created by 686udjie on 21/08/2026.
//

import SwiftUI

/// Song actions presented with the same grouped list as Settings.
struct PlayerMenuSheet: View {
    let song: SongItem
    /// Collapses the Big Player so the pushed page is visible underneath.
    var onCollapseRequest: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsStore) private var settings

    // Loaded state
    @State private var pin = PinState()
    @State private var showPlaylistPicker = false
    @State private var showArtistPicker = false
    @State private var showRadioOptions = false
    @State private var isResolvingArtist = false
    @Environment(\.downloadManager) private var downloadManager

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: startRadio) {
                        actionLabel("Start Radio", icon: "dot.radiowaves.left.and.right")
                    }
                    Button { showPlaylistPicker = true } label: {
                        actionLabel("Add to Playlist", icon: "music.note.list")
                    }
                    Button {
                        UIPasteboard.general.string = song.webUrl
                        dismiss()
                    } label: {
                        actionLabel("Copy Link", icon: "link")
                    }
                }

                Section("Library") {
                    viewArtistRow
                    if let albumId = song.firstAlbumBrowseId {
                        Button { navigate(.album(browseId: albumId)) } label: {
                            actionLabel("View Album", icon: "record.circle")
                        }
                    }
                    pinRow
                    downloadRow
                }

                Section("More") {
                    SettingsNavigationRow("Details", icon: "info.circle") {
                        SongDetailsView(song: song)
                    }
                    SettingsNavigationRow("Similar to this song", icon: "dot.radiowaves.left.and.right") {
                        SimilarSongsView(
                            song: song,
                            onNavigate: { navigate($0) },
                            onPlaySong: { similar, songs in
                                dismiss()
                                PlaybackQueue.play(similar, in: songs, log: Log.search, context: "SimilarTo tap")
                                AppRouter.shared.expandPlayer()
                            }
                        )
                    }
                    Button { showRadioOptions = true } label: {
                        actionLabel("Customize Radio", icon: "slider.horizontal.3")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .tint(settings.accentColor)
            .navigationTitle("Song Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .appSheetChrome()
        .confirmationDialog("View Artist", isPresented: $showArtistPicker, titleVisibility: .visible) {
            ForEach(song.artists.filter { !$0.name.isEmpty }, id: \.self) { artist in
                Button(artist.name) {
                    openArtist(artist)
                }
            }
        }
        .sheet(isPresented: $showPlaylistPicker) {
            AddSongToPlaylistSheet(song: song)
        }
        .sheet(isPresented: $showRadioOptions) {
            RadioOptionsSheet(song: song)
        }
        .task { await pin.load(videoId: song.videoId) }
    }

    private func actionLabel(_ title: String, icon: String) -> some View {
        Label {
            Text(title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: icon).foregroundStyle(settings.accentColor)
        }
    }

    // MARK: - Download Row

    private var downloadRow: some View {
        let state = downloadManager.state(for: song.videoId)
        return Group {
            switch state {
            case .completed:
                Button(role: .destructive) {
                    Task { await downloadManager.delete(videoId: song.videoId) }
                } label: {
                    Label("Remove Download", systemImage: "trash")
                }
            case .downloading:
                Label("Downloading…", systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
            case .notStarted, .failed:
                Button {
                    Task { await downloadManager.download(song: song) }
                } label: {
                    actionLabel("Download", icon: "arrow.down.circle")
                }
            }
        }
    }

    // MARK: - Library Rows

    private var viewArtistRow: some View {
        Button(action: handleViewArtist) {
            HStack {
                actionLabel("View Artist", icon: "music.mic")
                Spacer()
                if isResolvingArtist { ProgressView() }
            }
        }
        .disabled(song.artists.isEmpty || isResolvingArtist)
    }

    private var pinRow: some View {
        Button {
            Task { await pin.toggle(song: song) }
        } label: {
            actionLabel(pin.isPinned ? "Unpin from Quick Picks" : "Pin to Quick Picks",
                        icon: pin.isPinned ? "pin.fill" : "pin")
        }
    }

    // MARK: - State

    private func startRadio() {
        PlaybackQueue.startRadio(for: song)
        dismiss()
    }

    private func navigate(_ route: DetailRoute) {
        dismiss()
        onCollapseRequest?()
        // Appends directly to the selected tab's NavigationPath — plain state
        // mutation, so it lands even while the player is tearing down.
        AppRouter.shared.open(route)
    }

    private func handleViewArtist() {
        guard !isResolvingArtist else { return }
        let namedArtists = song.artists.filter { !$0.name.isEmpty }
        if namedArtists.count > 1 {
            showArtistPicker = true
            return
        }
        guard let artist = namedArtists.first else { return }
        openArtist(artist)
    }

    private func openArtist(_ artist: YTArtist) {
        if let id = artist.id {
            navigate(.artist(browseId: id))
            return
        }
        resolveArtistByName(artist.name)
    }

    private func resolveArtistByName(_ name: String) {
        guard !name.isEmpty else { return }
        isResolvingArtist = true
        Task {
            defer { isResolvingArtist = false }
            var browseId: String?
            do {
                let json = try await SearchService.shared.search(query: name)
                browseId = SearchParser.parseSearchResults(from: json)
                    .flatMap(\.items)
                    .compactMap { item -> String? in
                        if case .artist(let artist) = item { return artist.browseId }
                        return nil
                    }
                    .first
            } catch {
                browseId = nil
            }
            if let browseId {
                navigate(.artist(browseId: browseId))
            }
        }
    }
}

// MARK: - Add to Playlist Picker

/// Lets the user pick which playlist to add `song` to, or create a new one.
struct AddSongToPlaylistSheet: View {
    let song: SongItem
    @Environment(\.dismiss) private var dismiss

    @State private var playlists: [PlaylistEntity] = []
    @State private var isLoading = true
    @State private var addedTo: Set<String> = []
    @State private var showNewPlaylistAlert = false
    @State private var newPlaylistTitle = ""
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if playlists.isEmpty {
                    ContentUnavailableView(
                        "No Playlists",
                        systemImage: "music.note.list",
                        description: Text("Create one below to start collecting songs.")
                    )
                } else {
                    List(playlists, id: \.id) { playlist in
                        Button {
                            addTo(playlist)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name)
                                        .foregroundStyle(.primary)
                                    if let count = playlist.remoteSongCount {
                                        Text("\(count) songs")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if addedTo.contains(playlist.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newPlaylistTitle = ""
                        showNewPlaylistAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New playlist")
                }
            }
            .textPrompt(
                "New Playlist",
                isPresented: $showNewPlaylistAlert,
                placeholder: "Playlist name",
                text: $newPlaylistTitle,
                okTitle: "Create",
                message: Text("Adds “\(song.title)” once created.")
            ) {
                Task { await createAndAdd() }
            }
            .task { await loadPlaylists() }
        }
        .appSheetChrome()
    }

    private func loadPlaylists() async {
        playlists = (try? await DatabaseService.shared.fetchPlaylists(limit: 100)) ?? []
        isLoading = false
    }

    private func addTo(_ playlist: PlaylistEntity) {
        guard !addedTo.contains(playlist.id) else { return }
        Task {
            do {
                try await SyncBridge.mutations.addToPlaylist(playlistId: playlist.id, songId: song.videoId)
                addedTo.insert(playlist.id)
            } catch {
                addedTo.remove(playlist.id)
            }
        }
    }

    private func createAndAdd() async {
        let title = newPlaylistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !isCreating else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            let playlistId = try await SyncBridge.mutations.createPlaylist(title: title)
            try await SyncBridge.mutations.addToPlaylist(playlistId: playlistId, songId: song.videoId)
            await loadPlaylists()
            addedTo.insert(playlistId)
        } catch {
            // Leave the sheet open so the user can retry.
        }
    }
}

// MARK: - Details (Nerdy Metadata)

struct SongDetailsView: View {
    let song: SongItem

    @State private var stream: PlaybackResult?
    @State private var formatEntity: FormatEntity?
    @State private var viewCountText: String?
    @State private var resolvedDuration: Int = 0

    private var effectiveDuration: Int {
        song.duration > 0 ? song.duration : resolvedDuration
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                trackSection
                streamSection
                statsSection
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadMetadata() }
    }

    // MARK: Sections

    private var trackSection: some View {
        section("Track") {
            row("Title", song.title)
            row("Artists", song.artistNamesDisplay)
            if let album = song.album {
                row("Album", album)
            }
            row("Duration", effectiveDuration.formattedDuration)
            row("Video ID", song.videoId, monospaced: true)
        }
    }

    @ViewBuilder
    private var streamSection: some View {
        section("Stream") {
            if let s = stream {
                row("Client", s.clientName)
                row("ITAG", "\(s.itag)", monospaced: true)
                row("Bitrate", "\(s.bitrate / 1000) kbps")
                row("Audio quality", s.audioQuality.replacingOccurrences(of: "AUDIO_QUALITY_", with: ""))
                if let loudness = s.loudnessDb {
                    row("Loudness", String(format: "%.1f dB", loudness))
                }
                row("Expires in", "\(s.expiresInSeconds)s")
            } else if let f = formatEntity {
                row("Source", "Cached format")
                row("ITAG", "\(f.itag)", monospaced: true)
                row("Bitrate", "\(f.bitrate / 1000) kbps")
                if f.contentLength > 0 {
                    row("Size", ByteCountFormatter.string(fromByteCount: f.contentLength, countStyle: .file))
                }
            } else {
                row("Status", "Not resolved yet")
            }
        }
    }

    private var statsSection: some View {
        section("Stats") {
            row("Views", viewCountText ?? "Loading…")
        }
    }

    // MARK: Building Blocks

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value.isEmpty ? "—" : value)
                .font(monospaced ? .footnote.monospaced() : .callout)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    // MARK: Helpers

    private func loadMetadata() async {
        if song.duration <= 0 {
            if let duration = await InnerTubeClient.tropShared.resolveDuration(videoId: song.videoId) {
                resolvedDuration = duration
            }
        }
        stream = await StreamCache.shared.get(videoId: song.videoId)
        formatEntity = try? await DatabaseService.shared.fetchOne(FormatEntity.self, key: song.videoId)
        if let response: PlayerResponse = try? await InnerTubeClient.tropShared.playerResponse(videoId: song.videoId),
           let raw = response.videoDetails?.viewCount,
           let count = Int(raw) {
            viewCountText = count.formattedViews()
        } else {
            viewCountText = "Unavailable"
        }
    }
}
