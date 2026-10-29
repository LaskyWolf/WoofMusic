//
//  ArtistDetailView.swift
//  Trop
//
//  Created by 686udjie on 03/07/2026.
//

import Nuke
import SwiftUI

// MARK: - View Model

@MainActor
@Observable
final class ArtistDetailViewModel {
    let browseId: String
    var artist: ArtistDetailInfo?
    var isLoading = true
    var error: Error?
    /// A cached page is on screen but older than `ArtistDetailCache.lifetime`.
    var isStale = false

    private let innerTube = InnerTubeClient.tropShared

    init(browseId: String) {
        self.browseId = browseId
        // A recent visit shows at once, without the loading skeleton.
        if let cached = ArtistDetailCache.entry(for: browseId) {
            artist = cached.info
            isLoading = false
            isStale = !cached.isFresh
        }
    }

    /// No page yet, or a cached one due for a refresh.
    var needsLoad: Bool { isLoading || isStale }

    /// Fetches artist browse page from InnerTube and parses the response.
    /// With a cached page on screen it refreshes silently and keeps it on failure.
    func load() async {
        if artist == nil { isLoading = true }
        error = nil

        do {
            let json = try await innerTube.browse(browseId: browseId)
            let parsed = Self.parseArtistDetail(from: json, browseId: browseId)
            Self.preloadHeroArtwork(for: parsed.thumbnailUrl)
            artist = parsed
            ArtistDetailCache.store(parsed)
        } catch {
            // Leaving the page cancels the load: keep the flags so the next appear retries.
            if error.isCancellation { return }
            if artist == nil { self.error = error }
        }
        isLoading = false
        isStale = false
    }
}

// MARK: - Parser

extension ArtistDetailViewModel {
    /// Parses InnerTube browse JSON into an ArtistDetailInfo.
    /// Handles both musicImmersiveHeaderRenderer and musicResponsiveHeaderRenderer for the header,
    /// then extracts top songs from musicShelfRenderer and albums, singles, videos,
    /// playlists and related artists from musicCarouselShelfRenderer shelves.
    static func parseArtistDetail(from json: [String: Any], browseId: String) -> ArtistDetailInfo {
        var name = "Unknown Artist"
        var thumbnailUrl: String?
        var subscriberCountText: String?
        var descriptionText: String?
        var isSubscribed = false
        var songs: [SongItem] = []
        var buckets = ArtistCarouselBuckets()

        // --- Header ---
        // Artist pages can use either an immersive header (large background image)
        // or a responsive header (smaller, more compact).
        if let header = json["header"] as? [String: Any] {
            if let immersive = header["musicImmersiveHeaderRenderer"] as? [String: Any] {
                name = InnerTubeJSON.runsText(immersive["title"] as? [String: Any]) ?? "Unknown Artist"
                thumbnailUrl = InnerTubeJSON.musicThumbnailURL(immersive)
                let subscription = extractSubscriptionDetails(from: immersive)
                isSubscribed = subscription.isSubscribed ?? false
                subscriberCountText = subscription.subscriberCountText
            } else if let responsive = header["musicResponsiveHeaderRenderer"] as? [String: Any] {
                name = InnerTubeJSON.runsText(responsive["title"] as? [String: Any]) ?? "Unknown Artist"
                thumbnailUrl = InnerTubeJSON.musicThumbnailURL(responsive)
                let subscription = extractSubscriptionDetails(from: responsive)
                isSubscribed = subscription.isSubscribed ?? false
                subscriberCountText = subscription.subscriberCountText
            }
        }

        if name == "Unknown Artist" || thumbnailUrl == nil,
           let microformat = json["microformat"] as? [String: Any],
           let mfRenderer = microformat["microformatDataRenderer"] as? [String: Any] {
            if name == "Unknown Artist", let mfTitle = mfRenderer["title"] as? String {
                name = mfTitle
            }
            if thumbnailUrl == nil, let thumb = mfRenderer["thumbnail"] as? [String: Any],
               let thumbnails = thumb["thumbnails"] as? [[String: Any]],
               let last = thumbnails.last,
               let url = last["url"] as? String {
                thumbnailUrl = url
            }
            if descriptionText == nil, let desc = mfRenderer["description"] as? String {
                descriptionText = desc
            }
        }

        // --- Sections ---
        if let sections = BrowseLens.browseSections(json) {

            for sectionDict in sections {
                // musicShelfRenderer typically contains a list of songs
                if let shelf = sectionDict["musicShelfRenderer"] as? [String: Any],
                   let items = shelf["contents"] as? [[String: Any]] {
                    for itemDict in items {
                        if let renderer = itemDict["musicResponsiveListItemRenderer"] as? [String: Any],
                           let song = SongItem.from(renderer) {
                            songs.append(song)
                        }
                    }
                }

                // musicCarouselShelfRenderer holds albums, singles, videos,
                // playlists and related artists — classified per shelf below.
                if let carousel = sectionDict["musicCarouselShelfRenderer"] as? [String: Any],
                   let items = carousel["contents"] as? [[String: Any]] {
                    let shelfTitle = extractCarouselTitle(carousel)
                    for itemDict in items {
                        guard let twoRow = itemDict["musicTwoRowItemRenderer"] as? [String: Any] else { continue }
                        classifyCarouselItem(twoRow, shelfTitle: shelfTitle, buckets: &buckets)
                    }
                }
            }
        }

        return ArtistDetailInfo(
            name: name,
            thumbnailUrl: thumbnailUrl,
            subscriberCountText: subscriberCountText,
            descriptionText: descriptionText,
            isSubscribed: isSubscribed,
            browseId: browseId,
            songs: songs,
            albums: buckets.albums,
            singles: buckets.singles,
            videos: buckets.videos,
            playlists: buckets.playlists,
            relatedArtists: buckets.relatedArtists
        )
    }

    /// Buckets for one artist page's carousel shelves.
    private struct ArtistCarouselBuckets {
        var albums: [AlbumItem] = []
        var singles: [AlbumItem] = []
        var videos: [SongItem] = []
        var playlists: [PlaylistItem] = []
        var relatedArtists: [ArtistItem] = []
    }

    /// Routes one carousel tile into albums, singles, videos, playlists or
    /// related artists based on its page type (and shelf/subtitle hints for
    /// singles & EPs, which share the album page type).
    private static func classifyCarouselItem(
        _ twoRow: [String: Any],
        shelfTitle: String,
        buckets: inout ArtistCarouselBuckets
    ) {
        let pageType = HomePageParser.extractPageType(twoRow)
        switch pageType {
        case "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_AUDIOBOOK":
            guard let albumItem = AlbumItem.from(twoRow) else { return }
            if isSingleOrEP(shelfTitle: shelfTitle, renderer: twoRow) {
                buckets.singles.append(albumItem)
            } else {
                buckets.albums.append(albumItem)
            }
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL":
            if let artistItem = ArtistItem.from(twoRow) {
                buckets.relatedArtists.append(artistItem)
            }
        case "MUSIC_PAGE_TYPE_PLAYLIST":
            if let playlistItem = PlaylistItem.from(twoRow) {
                buckets.playlists.append(playlistItem)
            }
        default:
            // Music videos expose a watch endpoint instead of a browse page.
            if pageType == "MUSIC_PAGE_TYPE_VIDEO" || HomePageParser.hasWatchEndpoint(twoRow),
               let video = SongItem.from(twoRow) {
                buckets.videos.append(video)
            }
        }
    }

    /// Singles & EPs share the album page type, so the shelf title
    /// ("Singles & EPs") or subtitle ("Single • 2024") decides.
    private static let singleOrEPWords: Set<String> = ["single", "singles", "ep", "eps"]

    private static func words(in text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
    }

    private static func isSingleOrEP(shelfTitle: String, renderer: [String: Any]) -> Bool {
        if words(in: shelfTitle).contains(where: singleOrEPWords.contains) {
            return true
        }
        let subtitleWords = InnerTubeJSON.runsTexts(renderer["subtitle"] as? [String: Any])
            .flatMap { words(in: $0) }
        return subtitleWords.contains(where: singleOrEPWords.contains)
    }

    /// Warms Nuke's cache before the artist screen appears, avoiding a second
    /// visible loading state for the immersive header artwork.
    private static func preloadHeroArtwork(for thumbnailUrl: String?) {
        guard let artworkURL = ArtworkURLs.sized(thumbnailUrl, width: 1200, height: 1200),
              let url = URL(string: artworkURL) else {
            return
        }

        ArtworkLoader.warm(url)
    }

    /// YouTube Music subscription payloads vary: the subscribed state is in `subscriptionButton`, 
    /// the count in `subscriptionButton2`, and older responses include a notification toggle.
    private static func extractSubscriptionDetails(
        from header: [String: Any]
    ) -> (isSubscribed: Bool?, subscriberCountText: String?) {
        var isSubscribed: Bool?
        var subscriberCountText: String?

        let buttons = ["subscriptionButton2", "subscriptionButton"]
            .compactMap { header[$0] as? [String: Any] }

        for button in buttons {
            if let subscribe = button["subscribeButtonRenderer"] as? [String: Any] {
                if isSubscribed == nil {
                    isSubscribed = subscribe["subscribed"] as? Bool
                }

                if subscriberCountText == nil {
                    for key in ["subscriberCountWithSubscribeText", "longSubscriberCountText", "shortSubscriberCountText"] {
                        if let count = InnerTubeJSON.runsText(subscribe[key] as? [String: Any]), !count.isEmpty {
                            subscriberCountText = count
                            break
                        }
                    }
                }
            }

            if let toggle = button["subscriptionNotificationToggleButtonRenderer"] as? [String: Any] {
                if isSubscribed == nil {
                    isSubscribed = toggle["subscribed"] as? Bool
                }
                if subscriberCountText == nil,
                   let count = InnerTubeJSON.runsText(toggle["subscribedText"] as? [String: Any]),
                   !count.isEmpty {
                    subscriberCountText = count
                }
            }
        }

        return (isSubscribed, subscriberCountText)
    }

    /// Extracts the title from a musicCarouselShelfBasicHeaderRenderer.
    private static func extractCarouselTitle(_ carousel: [String: Any]) -> String {
        guard let header = carousel["header"] as? [String: Any],
              let basicHeader = header["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any],
              let title = InnerTubeJSON.runsText(basicHeader["title"] as? [String: Any]) else {
            return "Unknown"
        }
        return title
    }
}

// MARK: - View

struct ArtistDetailView: View {
    let browseId: String
    @State private var viewModel: ArtistDetailViewModel

    @State private var linkCopied = false
    /// "Rapper", "DJ"… from MusicBrainz; nil shows "Artist".
    @State private var artistKind: String?
    @State private var linkResetTask: Task<Void, Never>?

    init(browseId: String) {
        self.browseId = browseId
        _viewModel = State(initialValue: ArtistDetailViewModel(browseId: browseId))
    }

    var body: some View {
        ScrollView {
            DetailStateContainer(
                isLoading: viewModel.isLoading,
                error: viewModel.error,
                data: viewModel.artist,
                noun: "artist",
                emptyIcon: "music.mic"
            ) { artist in
                artistContent(for: artist)
            }
        }
        .scrollDisabled(viewModel.isLoading || viewModel.error != nil || viewModel.artist == nil)
        .miniPlayerTracksScroll()
        // System bar, as on the playlist and album pages: its back button is the only one.
        .navigationTitle(viewModel.artist?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(
                    linkCopied ? "Artist link copied" : "Copy artist link",
                    systemImage: linkCopied ? "checkmark" : "link"
                ) { copyArtistLink() }
                .disabled(viewModel.artist == nil)
            }
        }
        .task {
            guard viewModel.needsLoad else { return }
            await viewModel.load()
        }
        .onDisappear { linkResetTask?.cancel() }
    }

    private func copyArtistLink() {
        guard let artist = viewModel.artist,
              let url = URL(string: "https://music.youtube.com/channel/\(artist.browseId)") else { return }
        UIPasteboard.general.string = url.absoluteString
        linkCopied = true
        linkResetTask?.cancel()
        linkResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            linkCopied = false
        }
    }

    @ViewBuilder
    private func artistContent(for artist: ArtistDetailInfo) -> some View {
        LazyVStack(spacing: 0) {
            header(for: artist)

            if !artist.songs.isEmpty {
                songsSection(songs: artist.songs)
            }

            if !artist.albums.isEmpty {
                albumsSection(albums: artist.albums)
            }

            if !artist.singles.isEmpty {
                singlesSection(singles: artist.singles)
            }

            if !artist.playlists.isEmpty {
                playlistsSection(playlists: artist.playlists)
            }

            if !artist.relatedArtists.isEmpty {
                relatedArtistsSection(artists: artist.relatedArtists)
            }

            // A profile's description is only "Profile • @handle": the handle alone, centred.
            if !artist.hasMusic, let handle = artist.handle {
                Text(handle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else if let description = artist.descriptionText, !description.isEmpty {
                aboutSection(description: description)
            }

            if artist.songs.isEmpty && artist.albums.isEmpty && artist.singles.isEmpty
                && artist.playlists.isEmpty && artist.relatedArtists.isEmpty {
                VStack(spacing: 8) {
                    Spacer().frame(height: 40)
                    Text(artist.hasMusic ? "No content found" : "Nothing public on this profile yet")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    /// Header card over the blurred avatar: round avatar, subscribers, name,
    /// then Subscribe, Shuffle and Play. Same card as the playlist and album headers.
    private func header(for artist: ArtistDetailInfo) -> some View {
        DetailHeaderCard(meta: kindLabel(for: artist), title: artist.name) {
            AsyncImageView(url: ArtworkURLs.sized(artist.thumbnailUrl, width: 1200, height: 1200))
                .clipShape(Circle())
        } secondary: {
            if let count = artist.subscriberCountText, !count.isEmpty {
                Text(subscriberLabel(for: count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } buttons: {
            Button(action: { toggleSubscribe(artist) }, label: {
                HeaderRoundIcon(
                    systemImage: artist.isSubscribed ? "person.fill.checkmark" : "person.badge.plus",
                    tint: artist.isSubscribed ? SettingsStore.shared.accentColor : .primary
                )
            })
            .accessibilityLabel(artist.isSubscribed ? "Unsubscribe" : "Subscribe")

            // A profile with no songs has nothing to play.
            if !artist.songs.isEmpty {
                Button(action: { shufflePlay(artist) }, label: {
                    HeaderRoundIcon(systemImage: "shuffle")
                })
                .accessibilityLabel("Shuffle artist")

                Button(action: { playAll(artist) }, label: {
                    HeaderRoundIcon(systemImage: "play.fill", primary: SettingsStore.shared.accentColor)
                })
                .accessibilityLabel("Play songs")
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            BlurredArtworkBackdrop(url: ArtworkURLs.sized(artist.thumbnailUrl, width: 1200, height: 1200))
        }
        .task(id: artist.name) {
            // A listener's name could match an unrelated MusicBrainz artist.
            guard artist.hasMusic else { return }
            artistKind = await ArtistKindService.shared.kind(for: artist.name)
        }
    }

    /// "Artist" (or its MusicBrainz kind) for a channel with music; a channel
    /// without any is a person's profile: "Creator" with videos, else "User".
    private func kindLabel(for artist: ArtistDetailInfo) -> String {
        if artist.hasMusic { return artistKind ?? "Artist" }
        return artist.videos.isEmpty ? "User" : "Creator"
    }

    private func subscriberLabel(for count: String) -> String {
        count.localizedCaseInsensitiveContains("subscriber") ? count : "\(count) subscribers"
    }

    @ViewBuilder
    private func aboutSection(description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(.title3)
                .fontWeight(.bold)
                .padding(.horizontal, 16)

            Text(description)
                .font(.body)
                .foregroundColor(.primary)
                .lineLimit(5)
                .padding(.horizontal, 16)
        }
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private func songsSection(songs: [SongItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Songs")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ForEach(Array(songs.enumerated()), id: \.offset) { _, song in
                SongRowView(
                    song: song,
                    artSize: DesignTokens.artSmall, artRadius: DesignTokens.cardRadius,
                    onTap: { playSong(song) },
                    onNavigate: { AppRouter.shared.open($0) }
                )
            }
        }
    }

    @ViewBuilder
    private func albumsSection(albums: [AlbumItem]) -> some View {
        carouselSection(title: "Albums") {
            ForEach(albums.indices, id: \.self) { i in
                let album = albums[i]
                let route = DetailRoute.album(browseId: album.browseId)
                NavigationLink(value: route) {
                    MediaGridCell(
                        thumbnailUrl: album.thumbnailUrl,
                        title: album.title,
                        subtitle: album.artists.map(\.name).joined(separator: ", "),
                        zoomRoute: route
                    )
                }
                .buttonStyle(ZoomPressStyle())
                .albumCardMenu(browseId: album.browseId, artists: album.artists)
            }
        }
    }

    @ViewBuilder
    private func singlesSection(singles: [AlbumItem]) -> some View {
        carouselSection(title: "Singles & EPs") {
            ForEach(singles.indices, id: \.self) { i in
                let single = singles[i]
                let route = DetailRoute.album(browseId: single.browseId)
                NavigationLink(value: route) {
                    MediaGridCell(
                        thumbnailUrl: single.thumbnailUrl,
                        title: single.title,
                        subtitle: single.artists.map(\.name).joined(separator: ", "),
                        zoomRoute: route
                    )
                }
                .buttonStyle(ZoomPressStyle())
                .albumCardMenu(browseId: single.browseId, artists: single.artists)
            }
        }
    }

    @ViewBuilder
    private func playlistsSection(playlists: [PlaylistItem]) -> some View {
        carouselSection(title: "Playlists") {
            ForEach(playlists.indices, id: \.self) { i in
                let playlist = playlists[i]
                let route = DetailRoute.playlist(playlistId: playlist.id)
                NavigationLink(value: route) {
                    MediaGridCell(
                        thumbnailUrl: playlist.thumbnailUrl,
                        title: playlist.title,
                        subtitle: playlistSubtitle(playlist.author),
                        isPlaylist: true,
                        zoomRoute: route
                    )
                }
                .buttonStyle(ZoomPressStyle())
                .playlistCardMenu(id: playlist.id)
            }
        }
    }

    @ViewBuilder
    private func relatedArtistsSection(artists: [ArtistItem]) -> some View {
        carouselSection(title: "Fans Also Like", spacing: 16) {
            ForEach(artists.indices, id: \.self) { i in
                let related = artists[i]
                NavigationLink(value: DetailRoute.artist(browseId: related.browseId)) {
                    ArtistCircleCell(thumbnailUrl: related.thumbnailUrl, name: related.name)
                }
                .buttonStyle(ZoomPressStyle())
                .artistCardMenu(browseId: related.browseId)
            }
        }
    }

    /// Shared shell for the artist page's horizontal carousels.
    @ViewBuilder
    private func carouselSection<Content: View>(
        title: String,
        spacing: CGFloat = 12,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal, 16)
                .padding(.top, 24)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: spacing) {
                    content()
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Actions

    private func shufflePlay(_ artist: ArtistDetailInfo) {
        PlaybackQueue.playShuffled(artist.songs, log: Log.artistDetail, context: "Shuffle playback")
    }

    private func playAll(_ artist: ArtistDetailInfo) {
        PlaybackQueue.play(artist.songs, log: Log.artistDetail, context: "Playback")
    }

    private func playSong(_ song: SongItem) {
        guard let artist = viewModel.artist else { return }
        PlaybackQueue.play(song, in: artist.songs, log: Log.artistDetail, context: "Playback")
    }

    /// The tile subtitle's first run is the generic "Playlist" type label —
    /// redundant under the Playlists header, so only show a real author.
    private func playlistSubtitle(_ author: String?) -> String? {
        guard let author, !author.isEmpty,
              author.localizedCaseInsensitiveCompare("playlist") != .orderedSame else { return nil }
        return author
    }

    private func toggleSubscribe(_ artist: ArtistDetailInfo) {
        loggedTask(Log.artistDetail, "Subscribe failed") {
            let channelId = artist.browseId
            let entity = ArtistEntity(
                id: artist.browseId,
                name: artist.name,
                thumbnailUrl: artist.thumbnailUrl,
                bookmarkedAt: artist.isSubscribed ? nil : Date(),
                isPodcastChannel: false,
                channelId: channelId
            )
            try await DatabaseService.shared.insertOrReplace(entity)

            if artist.isSubscribed {
                try await SyncBridge.mutations.unsubscribeArtist(channelId: channelId, artistId: artist.browseId)
            } else {
                try await SyncBridge.mutations.subscribeArtist(channelId: channelId, artistId: artist.browseId)
            }

            await MainActor.run {
                if let current = viewModel.artist {
                    let updated = ArtistDetailInfo(
                        name: current.name,
                        thumbnailUrl: current.thumbnailUrl,
                        subscriberCountText: current.subscriberCountText,
                        descriptionText: current.descriptionText,
                        isSubscribed: !current.isSubscribed,
                        browseId: current.browseId,
                        songs: current.songs,
                        albums: current.albums,
                        singles: current.singles,
                        videos: current.videos,
                        playlists: current.playlists,
                        relatedArtists: current.relatedArtists
                    )
                    viewModel.artist = updated
                    ArtistDetailCache.update(updated)
                }
            }
        }
    }
}
