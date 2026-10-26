//
//  SongActionsMenu.swift
//  Trop
//
//  Created by 686udjie on 21/08/2026.
//

import GRDB
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
        case playlist, radio, details, similar, artists, sleepTimer
        var id: Self { self }
    }

    // LikeStore, DownloadManager, the pin DB read and the avatar fetch live in
    // the menu items below, so a row whose menu never opens observes nothing.
    @State private var pin = PinState()
    @State private var sheet: Sheet?
    @State private var confirmRemoveDownload = false
    @State private var isResolvingArtist = false

    var body: some View {
        host {
            // Compact icon row at the top, like Apple Music's song menu.
            ControlGroup {
                LikeMenuButton(song: song)
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
                    AddedByMenuItem(adder: adder)
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

            DownloadMenuButton(song: song)

            if showsSleepTimer {
                sleepTimerMenu
            }

            // The rarer actions share one item, so the menu fits the screen without scrolling.
            Menu("More", systemImage: "ellipsis.circle") {
                Button("Start Radio…", systemImage: "dot.radiowaves.left.and.right") { sheet = .radio }
                PinMenuButton(song: song, pin: pin)
                if let onSelect {
                    Button("Select", systemImage: "checkmark.circle", action: onSelect)
                }
            }

            RemoveMenuItems(song: song, onRemove: onRemove, confirmRemoveDownload: $confirmRemoveDownload)

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
        .confirmationDialog("Remove this download?", isPresented: $confirmRemoveDownload,
                            titleVisibility: .visible) {
            Button("Remove Download", role: .destructive) {
                Task { await DownloadManager.shared.delete(videoId: song.videoId) }
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
            case .artists:
                ArtistPickerSheet(artists: song.artists.filter { !$0.name.isEmpty }) { artist in
                    self.sheet = nil
                    openArtist(artist)
                }
            case .sleepTimer:
                SleepTimerSheet()
            }
        }
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
        return Button(
            timer.summary.map { "Sleep Timer · \($0)" } ?? "Sleep Timer…",
            systemImage: timer.isActive ? "moon.zzz.fill" : "moon.zzz"
        ) { sheet = .sleepTimer }
    }

    private func addToQueue() {
        let np = NowPlaying.shared
        np.queueSongs.append(song)
        np.persistQueueState()
    }

    private func navigate(_ route: DetailRoute) {
        let hadSheet = sheet != nil
        sheet = nil
        onCollapseRequest?()
        // Appends directly to the selected tab's NavigationPath — plain state
        // mutation, so it lands even while the player is tearing down.
        if let onNavigate {
            // A sheet presented by the caller can't appear while this one is still dismissing.
            if hadSheet {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    onNavigate(route)
                }
            } else {
                onNavigate(route)
            }
        } else {
            AppRouter.shared.open(route)
        }
    }

    private func handleViewArtist() {
        guard !isResolvingArtist else { return }
        let namedArtists = song.artists.filter { !$0.name.isEmpty }
        if namedArtists.count > 1 {
            sheet = .artists
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

// MARK: - Menu Items

// Built only with the menu's items, so their observers and tasks cost nothing
// for rows whose menu is never opened.

private struct LikeMenuButton: View {
    let song: SongItem
    @ObservedObject private var likeStore = LikeStore.shared

    var body: some View {
        let liked = likeStore.isLiked(videoId: song.videoId)
        Button(liked ? "Unlike" : "Like", systemImage: liked ? "heart.fill" : "heart") {
            Task { await likeStore.toggle(song: song) }
        }
    }
}

private struct AddedByMenuItem: View {
    let adder: PlaylistContributor
    @State private var avatar: UIImage?

    var body: some View {
        // A menu shows the picture at icon size and the second Text as a subtitle.
        Button {} label: {
            Text("Added by \(adder.name)")
            if adder.isOwner { Text("Playlist owner") }
            if let avatar {
                Image(uiImage: avatar).renderingMode(.original)
            } else if adder.isOwner {
                Image(uiImage: CollaboratorIcon.make(avatar: nil, crowned: true)).renderingMode(.original)
            } else {
                Image(systemName: "person.crop.circle.fill")
            }
        }
        .task(id: adder.avatarUrl) {
            guard let url = adder.avatarUrl.flatMap(URL.init) else {
                avatar = nil
                return
            }
            let isOwner = adder.isOwner
            avatar = (try? await ArtworkLoader.image(for: url)).map { CollaboratorIcon.make(avatar: $0, crowned: isOwner) }
        }
    }
}

/// The pin state is owned by the menu, so the label stays right between openings;
/// it is refreshed from the database each time the items are built.
private struct PinMenuButton: View {
    let song: SongItem
    let pin: PinState

    var body: some View {
        Button(pin.isPinned ? "Unpin from Quick Picks" : "Pin to Quick Picks",
               systemImage: pin.isPinned ? "pin.slash" : "pin") {
            Task { await pin.toggle(song: song) }
        }
        .task(id: song.videoId) { await pin.load(videoId: song.videoId) }
    }
}

private struct DownloadMenuButton: View {
    let song: SongItem
    @ObservedObject private var downloadManager = DownloadManager.shared

    var body: some View {
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
}

/// One compact entry for the destructive removals that apply to this song.
private struct RemoveMenuItems: View {
    let song: SongItem
    let onRemove: (() -> Void)?
    @Binding var confirmRemoveDownload: Bool
    @ObservedObject private var downloadManager = DownloadManager.shared

    var body: some View {
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
}


// MARK: - Go to Artist Picker

/// Lists a song's artists when it has several; tapping one opens that artist.
private struct ArtistPickerSheet: View {
    let artists: [YTArtist]
    let onPick: (YTArtist) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(artists, id: \.self) { artist in
                Button {
                    onPick(artist)
                } label: {
                    ArtistPickerRow(artist: artist)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            }
            .listStyle(.plain)
            .navigationTitle("Go to Artist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .appSheetChrome([.medium])
    }
}

/// Profile picture, name and kind of act. The picture comes from the library
/// when the artist is saved, otherwise from the artist page.
private struct ArtistPickerRow: View {
    let artist: YTArtist
    @State private var thumbnailUrl: String?

    private static let avatarSize = DesignTokens.artSmall

    var body: some View {
        HStack(spacing: DesignTokens.menuRowSpacing) {
            ZStack {
                Circle().fill(Color(.tertiarySystemFill))
                if let thumbnailUrl {
                    AsyncImageView(url: thumbnailUrl)
                } else {
                    Image(systemName: "person.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.avatarSize, height: Self.avatarSize)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(artist.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                ArtistKindLabel(name: artist.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .task(id: artist.id) {
            thumbnailUrl = await Self.thumbnailUrl(browseId: artist.id)
        }
    }

    private static func thumbnailUrl(browseId: String?) async -> String? {
        guard let browseId else { return nil }
        let pixels = Int(avatarSize * 3)
        if let saved = try? await DatabaseService.shared.fetchOne(ArtistEntity.self, key: browseId)?.thumbnailUrl {
            return ArtworkURLs.sized(saved, width: pixels, height: pixels)
        }
        guard let json = try? await InnerTubeClient.tropShared.browse(browseId: browseId) else { return nil }
        let page = ArtistDetailViewModel.parseArtistDetail(from: json, browseId: browseId)
        return ArtworkURLs.sized(page.thumbnailUrl, width: pixels, height: pixels)
    }
}

// MARK: - Sleep Timer Picker

/// A countdown wheel with Cancel and Start, like the Clock app's timer,
/// plus an End of Song option.
private struct SleepTimerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var duration: TimeInterval

    private static let lastMinutesKey = "sleepTimerLastMinutes"
    private static let defaultMinutes = 15

    init() {
        let saved = UserDefaults.standard.integer(forKey: Self.lastMinutesKey)
        let minutes = SleepTimer.shared.minutes ?? (saved > 0 ? saved : Self.defaultMinutes)
        _duration = State(initialValue: TimeInterval(minutes * 60))
    }

    var body: some View {
        let timer = SleepTimer.shared
        let minutes = Int(duration / 60)
        NavigationStack {
            VStack(spacing: 20) {
                if timer.isActive {
                    SleepTimerStatus(timer: timer)
                }

                CountdownPicker(duration: $duration)
                    .frame(maxWidth: .infinity)

                HStack {
                    ClockRoundButton(title: "Cancel", systemImage: "xmark", isAccent: false) {
                        timer.cancel()
                    }
                    .disabled(!timer.isActive)
                    Spacer()
                    ClockRoundButton(title: "Start", systemImage: "play.fill", isAccent: true) {
                        UserDefaults.standard.set(minutes, forKey: Self.lastMinutesKey)
                        timer.start(minutes: minutes)
                        dismiss()
                    }
                    .disabled(minutes < 1)
                }

                Button {
                    timer.stopAtSongEnd()
                    dismiss()
                } label: {
                    Label("End of Song", systemImage: "music.note")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityAddTraits(timer.stopsAtSongEnd ? .isSelected : [])
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .frame(maxHeight: .infinity, alignment: .top)
            .navigationTitle("Sleep Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Tall enough for the status line, the 216pt wheel, the buttons and
        // End of Song; large stays available for big Dynamic Type sizes.
        .appSheetChrome([.height(580), .large])
    }
}

/// One line saying the timer runs and when it pauses playback.
private struct SleepTimerStatus: View {
    let timer: SleepTimer

    var body: some View {
        Group {
            if let endsAt = timer.endsAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Label {
                        Text("\(Self.countdown(endsAt.timeIntervalSince(context.date))) left · pauses at \(endsAt.formatted(date: .omitted, time: .shortened))")
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "moon.zzz.fill")
                    }
                }
            } else {
                Label("Pauses when this song ends", systemImage: "moon.zzz.fill")
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.tint)
    }

    /// "12:34" or "1:05:00".
    private static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded(.up)), 0)
        let hours = total / 3600
        let minutes = total / 60 % 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// The Clock app's round timer button: a tinted disc inside a thin ring.
private struct ClockRoundButton: View {
    let title: String
    let systemImage: String
    let isAccent: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(isAccent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .frame(width: 72, height: 72)
                .background(disc)
                .padding(4)
                .overlay(disc.mask { Circle().strokeBorder(lineWidth: 2) })
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(title)
    }

    @ViewBuilder private var disc: some View {
        if isAccent {
            Circle().fill(.tint).opacity(0.22)
        } else {
            Circle().fill(Color(.tertiarySystemFill))
        }
    }
}

/// UIDatePicker in countdown mode: the Clock app's hours and min wheels.
/// It never goes below one minute.
private struct CountdownPicker: UIViewRepresentable {
    @Binding var duration: TimeInterval

    func makeUIView(context: Context) -> UIDatePicker {
        let picker = UIDatePicker()
        picker.datePickerMode = .countDownTimer
        picker.preferredDatePickerStyle = .wheels
        picker.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        // Set after the first layout pass: a countdown picker configured
        // before it is on screen skips its first value change.
        let initial = duration
        Task { @MainActor in picker.countDownDuration = initial }
        return picker
    }

    func updateUIView(_ picker: UIDatePicker, context: Context) {
        context.coordinator.duration = $duration
    }

    func makeCoordinator() -> Coordinator { Coordinator(duration: $duration) }

    final class Coordinator: NSObject {
        var duration: Binding<TimeInterval>

        init(duration: Binding<TimeInterval>) { self.duration = duration }

        @objc func changed(_ sender: UIDatePicker) {
            duration.wrappedValue = sender.countDownDuration
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
    @State private var songCounts: [String: Int] = [:]
    @State private var isLoading = true
    @State private var addedTo: Set<String> = []
    @State private var showNewPlaylistAlert = false
    @State private var newPlaylistTitle = ""
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    // Same rows and insets as the playlist list below.
                    VStack(spacing: 0) {
                        ForEach(0..<6, id: \.self) { _ in
                            ShimmerMediaRow()
                                .padding(.horizontal, 16)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else if playlists.isEmpty {
                    ContentUnavailableView(
                        "No Playlists",
                        systemImage: "music.note.list",
                        description: Text("Create one below to start collecting songs.")
                    )
                } else {
                    List(playlists, id: \.id) { playlist in
                        let isAdded = addedTo.contains(playlist.id)
                        Button {
                            addTo(playlist)
                        } label: {
                            HStack(spacing: 12) {
                                MediaListRow(
                                    url: playlist.thumbnailUrl,
                                    title: playlist.name,
                                    subtitle: (songCounts[playlist.id] ?? playlist.remoteSongCount).map { "\($0) songs" }
                                )
                                if isAdded {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .accessibilityAddTraits(isAdded ? .isSelected : [])
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    }
                    .listStyle(.plain)
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
        songCounts = (try? await Self.fetchSongCounts()) ?? [:]
        isLoading = false
    }

    /// Saved songs per playlist, counted like the Library list.
    private static func fetchSongCounts() async throws -> [String: Int] {
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
        return Dictionary(uniqueKeysWithValues: rows)
    }

    private func addTo(_ playlist: PlaylistEntity) {
        guard !addedTo.contains(playlist.id) else { return }
        Task {
            do {
                for song in songs {
                    try await PlaylistSongEdits.add(songId: song.videoId, to: playlist.id)
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
                try await PlaylistSongEdits.add(songId: song.videoId, to: playlistId)
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
