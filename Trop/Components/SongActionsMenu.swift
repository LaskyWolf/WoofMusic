//
//  SongActionsMenu.swift
//  Trop
//
//  Created by 686udjie on 21/08/2026.
//

import SwiftUI

/// The "⋯" song menu: a native pull-down menu, like Apple Music.
/// Items that need more input open one sheet after the menu closes.
struct SongActionsMenu<MenuLabel: View>: View {
    let song: SongItem
    var showsQueueActions = true
    /// The full player's menu also offers the sleep timer.
    var showsSleepTimer = false
    /// Collapses the full player so a pushed page is visible underneath.
    var onCollapseRequest: (() -> Void)?
    var onNavigate: ((DetailRoute) -> Void)?
    /// Shows a Select item that starts multi-select in the hosting list.
    var onSelect: (() -> Void)?
    /// Shows a destructive Remove from Playlist item (editable playlists only).
    var onRemove: (() -> Void)?
    /// Attaches the menu to the label's long press instead of making it a tap target.
    var asContextMenu = false
    @ViewBuilder var label: () -> MenuLabel

    private enum Sheet: Identifiable {
        case playlist, radio, details, similar
        var id: Self { self }
    }

    @ObservedObject private var likeStore = LikeStore.shared
    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var pin = PinState()
    @State private var sheet: Sheet?
    @State private var showArtistPicker = false
    @State private var confirmRemoveDownload = false
    @State private var isResolvingArtist = false
    @State private var adderAvatar: UIImage?

    var body: some View {
        host {
            // Compact icon row at the top, like Apple Music's song menu.
            ControlGroup {
                let liked = likeStore.isLiked(videoId: song.videoId)
                Button(liked ? "Unlike" : "Like", systemImage: liked ? "heart.fill" : "heart") {
                    Task { await likeStore.toggle(song: song) }
                }
                Button("Add to Playlist", systemImage: "text.badge.plus") { sheet = .playlist }
                if let url = URL(string: song.webUrl) {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .controlGroupStyle(.compactMenu)

            if let adder = song.addedBy {
                Section {
                    // A menu shows the picture at icon size and the second Text as a subtitle.
                    Button {} label: {
                        Text("Added by \(adder.name)")
                        if adder.isOwner { Text("Playlist owner") }
                        if let avatar = adderAvatar {
                            Image(uiImage: avatar).renderingMode(.original)
                        } else if adder.isOwner {
                            Image(uiImage: CollaboratorIcon.make(avatar: nil, crowned: true)).renderingMode(.original)
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                        }
                    }
                }
            }

            if showsQueueActions {
                Section {
                    Button("Play Next", systemImage: "text.insert") {
                        NowPlaying.shared.enqueueNext(song)
                    }
                    Button("Add to Queue", systemImage: "text.append", action: addToQueue)
                }
            }

            Section {
                Button("Start Radio…", systemImage: "dot.radiowaves.left.and.right") { sheet = .radio }
                downloadButton
                Button(pin.isPinned ? "Unpin from Quick Picks" : "Pin to Quick Picks",
                       systemImage: pin.isPinned ? "pin.slash" : "pin") {
                    Task { await pin.toggle(song: song) }
                }
            }

            if showsSleepTimer {
                sleepTimerMenu
            }

            if let onSelect {
                Button("Select", systemImage: "checkmark.circle", action: onSelect)
            }

            removeMenu

            Menu("Go To", systemImage: "arrow.forward.circle") {
                if !song.artists.filter({ !$0.name.isEmpty }).isEmpty {
                    Button("Artist", systemImage: "music.mic", action: handleViewArtist)
                        .disabled(isResolvingArtist)
                }
                if let albumId = song.firstAlbumBrowseId {
                    Button("Album", systemImage: "square.stack") {
                        navigate(.album(browseId: albumId))
                    }
                }
                Button("Similar Songs…", systemImage: "sparkles") { sheet = .similar }
                Button("Song Details…", systemImage: "info.circle") { sheet = .details }
            }
        }
        .task(id: song.addedBy?.avatarUrl) {
            guard let url = song.addedBy?.avatarUrl.flatMap(URL.init) else { return }
            let isOwner = song.addedBy?.isOwner ?? false
            adderAvatar = (try? await ArtworkLoader.image(for: url)).map { CollaboratorIcon.make(avatar: $0, crowned: isOwner) }
        }
        .confirmationDialog("Go to Artist", isPresented: $showArtistPicker, titleVisibility: .visible) {
            ForEach(song.artists.filter { !$0.name.isEmpty }, id: \.self) { artist in
                Button(artist.name) { openArtist(artist) }
            }
        }
        .confirmationDialog("Remove this download?", isPresented: $confirmRemoveDownload,
                            titleVisibility: .visible) {
            Button("Remove Download", role: .destructive) {
                Task { await downloadManager.delete(videoId: song.videoId) }
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .playlist:
                AddSongToPlaylistSheet(song: song)
            case .radio:
                RadioOptionsSheet(song: song)
            case .details:
                NavigationStack {
                    SongDetailsView(song: song)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { self.sheet = nil }
                            }
                        }
                }
                .appSheetChrome()
            case .similar:
                NavigationStack {
                    SimilarSongsView(
                        song: song,
                        onNavigate: { navigate($0) },
                        onPlaySong: { similar, songs in
                            self.sheet = nil
                            PlaybackQueue.play(similar, in: songs, log: Log.search, context: "SimilarTo tap")
                            AppRouter.shared.expandPlayer()
                        }
                    )
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { self.sheet = nil }
                        }
                    }
                }
                .appSheetChrome()
            }
        }
        .task { await pin.load(videoId: song.videoId) }
    }

    /// The same items as a tap menu on the ⋯ button or as a long-press menu on a whole row.
    @ViewBuilder
    private func host<Items: View>(@ViewBuilder _ items: () -> Items) -> some View {
        if asContextMenu {
            label().contextMenu { items() }
        } else {
            Menu { items() } label: { label() }
                .menuOrder(.fixed)
        }
    }

    private var sleepTimerMenu: some View {
        let timer = SleepTimer.shared
        return Menu {
            Button("End of Song", systemImage: "music.note") { timer.stopAtSongEnd() }
            ForEach(SleepTimer.presetMinutes, id: \.self) { minutes in
                Button(minutes == 60 ? "1 Hour" : "\(minutes) Minutes", systemImage: "timer") {
                    timer.start(minutes: minutes)
                }
            }
            if timer.isActive {
                Section {
                    Button("Turn Off", systemImage: "moon.zzz") { timer.cancel() }
                }
            }
        } label: {
            Label(
                timer.summary.map { "Sleep Timer · \($0)" } ?? "Sleep Timer",
                systemImage: timer.isActive ? "moon.zzz.fill" : "moon.zzz"
            )
        }
    }

    /// One compact entry for the destructive removals that apply to this song.
    @ViewBuilder
    private var removeMenu: some View {
        let hasDownload = downloadManager.state(for: song.videoId) == .completed
        if onRemove != nil || hasDownload {
            Section {
                Menu("Remove from…", systemImage: "minus.circle") {
                    if let onRemove {
                        Button("from Playlist", systemImage: "music.note.list", role: .destructive, action: onRemove)
                            .tint(.red)
                    }
                    if hasDownload {
                        Button("from Downloads", systemImage: "arrow.down.circle", role: .destructive) {
                            confirmRemoveDownload = true
                        }
                        .tint(.red)
                    }
                }
                .tint(.red)
            }
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        switch downloadManager.state(for: song.videoId) {
        case .completed:
            EmptyView()
        case .downloading:
            Button("Downloading…", systemImage: "arrow.down.circle") {}
                .disabled(true)
        case .notStarted, .failed:
            Button("Download", systemImage: "arrow.down.circle") {
                Task { await downloadManager.download(song: song) }
            }
        }
    }

    private func addToQueue() {
        let np = NowPlaying.shared
        np.queueSongs.append(song)
        np.persistQueueState()
    }

    private func navigate(_ route: DetailRoute) {
        sheet = nil
        onCollapseRequest?()
        // Appends directly to the selected tab's NavigationPath — plain state
        // mutation, so it lands even while the player is tearing down.
        if let onNavigate {
            onNavigate(route)
        } else {
            AppRouter.shared.open(route)
        }
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
                let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let artists = SearchParser.parseSearchResults(from: json)
                    .flatMap(\.items)
                    .compactMap { item -> ArtistItem? in
                        if case .artist(let artist) = item { return artist }
                        return nil
                    }
                // Prefer the exact name; otherwise trust search ranking.
                let exact = artists.first {
                    $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        .caseInsensitiveCompare(wanted) == .orderedSame
                }
                browseId = (exact ?? artists.first)?.browseId
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
    let songs: [SongItem]

    init(song: SongItem) { songs = [song] }
    init(songs: [SongItem]) { self.songs = songs }
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
                message: Text(songs.count == 1
                    ? "Adds “\(songs[0].title)” once created."
                    : "Adds \(songs.count) songs once created.")
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
                for song in songs {
                    try await SyncBridge.mutations.addToPlaylist(playlistId: playlist.id, songId: song.videoId)
                }
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
            for song in songs {
                try await SyncBridge.mutations.addToPlaylist(playlistId: playlistId, songId: song.videoId)
            }
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
        List {
            trackSection
            streamSection
            statsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadMetadata() }
    }

    // MARK: Sections

    private var trackSection: some View {
        Section("Track") {
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
        Section("Stream") {
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
        Section("Stats") {
            row("Views", viewCountText ?? "Loading…")
        }
    }

    // MARK: Building Blocks

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
