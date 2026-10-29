//
//  PodcastDetailView.swift
//  Trop
//
//  Created by 686udjie on 06/07/2026.
//

import SwiftUI

// MARK: - View Model

@MainActor
@Observable
final class PodcastDetailViewModel {
    let browseId: String
    var podcast: PodcastDetailInfo?
    var isLoading = true
    var error: Error?
    var isSubscribed = false

    private let innerTube = InnerTubeClient.tropShared

    init(browseId: String) {
        self.browseId = browseId
    }

    func load() async {
        isLoading = true
        error = nil

        do {
            let json = try await innerTube.browse(browseId: browseId)
            let parsed = Self.parsePodcastDetail(from: json, browseId: browseId)
            Log.podcastDetail.debug("title=\(parsed.title) author=\(parsed.author ?? "nil") episodes=\(parsed.episodes.count)")
            podcast = parsed
            isLoading = false
            await refreshSubscribedState()
            // Seed from the remote subscribed state when nothing is stored locally yet.
            if parsed.isSubscribed {
                let local: PodcastEntity? = try? await DatabaseService.shared.fetchOne(PodcastEntity.self, key: browseId)
                if local?.subscribedAt == nil {
                    isSubscribed = true
                }
            }

            let fresh = await EpisodePlaybackStore.shared.syncKnownEpisodes(
                parsed.episodes, podcastId: browseId, podcastName: parsed.title
            )
            if SettingsStore.shared.autoDownloadNewEpisodes, !fresh.isEmpty {
                for episode in fresh.prefix(10) {
                    await DownloadManager.shared.download(song: episode.toSongItem())
                }
            }
        } catch {
            self.error = error
            isLoading = false
        }
    }

    func refreshSubscribedState() async {
        let entity = try? await DatabaseService.shared.fetchOne(PodcastEntity.self, key: browseId)
        isSubscribed = entity?.subscribedAt != nil
    }

    func toggleSubscribe() async {
        guard let podcast else { return }
        let currentlySubscribed = isSubscribed
        isSubscribed = !currentlySubscribed
        do {
            if currentlySubscribed {
                try await SyncBridge.mutations.unsubscribePodcast(browseId: browseId)
            } else {
                try await SyncBridge.mutations.subscribePodcast(
                    browseId: browseId,
                    name: podcast.title,
                    thumbnailUrl: podcast.thumbnailUrl
                )
            }
        } catch {
            Log.podcastDetail.error("Toggle subscribe failed: \(error)")
        }
        await refreshSubscribedState()
    }
}

// MARK: - Parser

/// Header fields extracted from the podcast browse response.
private struct ParsedPodcastHeader {
    var title = "Unknown Podcast"
    var author: String?
    var descriptionText: String?
    var thumbnailUrl: String?
    var isSubscribed = false
}

/// Subtitle metadata for one episode row.
private struct ParsedEpisodeMeta {
    var publishDate: String?
    var viewsText: String?
    var duration = 0
}

extension PodcastDetailViewModel {
    static func parsePodcastDetail(from json: [String: Any], browseId: String) -> PodcastDetailInfo {
        let header = parsePodcastHeader(from: json)
        var episodes = collectPodcastEpisodes(from: json)

        // Episodes carry no artist runs; stamp the show name so queue rows,
        // the mini player and menus show it (matching the big player author).
        if !episodes.isEmpty {
            let showName = header.author ?? header.title
            episodes = episodes.map { episode in
                var stamped = episode
                if stamped.artists.isEmpty {
                    stamped.artists = [YTArtist(name: showName)]
                }
                return stamped
            }
        }

        return PodcastDetailInfo(
            title: header.title,
            author: header.author,
            descriptionText: header.descriptionText,
            thumbnailUrl: header.thumbnailUrl,
            browseId: browseId,
            isSubscribed: header.isSubscribed,
            episodes: episodes
        )
    }
}

// MARK: - Podcast header parsing

extension PodcastDetailViewModel {
    /// Reads title/author/description/artwork/subscribed state from the
    /// immersive header, responsive header and microformat fallbacks.
    private static func parsePodcastHeader(from json: [String: Any]) -> ParsedPodcastHeader {
        var header = ParsedPodcastHeader()

        let firstTabSection = BrowseLens.firstSectionItem(json)
            .flatMap { $0["itemSectionRenderer"] as? [String: Any] }
            .flatMap { ($0["contents"] as? [[String: Any]])?.first }
            ?? BrowseLens.firstSectionItem(json)

        // Podcast show pages render an immersive header at the top level
        // (title, show description, artwork) — this is where the full
        // show blurb lives.
        if let topHeader = json["header"] as? [String: Any],
           let immersive = topHeader["musicImmersiveHeaderRenderer"] as? [String: Any] {
            applyImmersiveHeader(immersive, to: &header)
        }

        let renderer: [String: Any]? =
            firstTabSection?["musicResponsiveHeaderRenderer"] as? [String: Any]
            ?? (json["header"] as? [String: Any]).flatMap {
                $0["musicDetailHeaderRenderer"] as? [String: Any]
                ?? $0["musicResponsiveHeaderRenderer"] as? [String: Any]
            }
        if let renderer {
            applyResponsiveHeader(renderer, to: &header)
        }

        // Last resort: microformat description (always present on browse pages).
        if header.descriptionText == nil || header.descriptionText?.isEmpty == true {
            let microformat = (json["microformat"] as? [String: Any])?["microformatDataRenderer"] as? [String: Any]
            header.descriptionText = microformat?["description"] as? String
        }
        return header
    }

    private static func applyImmersiveHeader(_ immersive: [String: Any], to header: inout ParsedPodcastHeader) {
        header.title = InnerTubeJSON.runsText(immersive["title"] as? [String: Any]) ?? header.title
        if header.thumbnailUrl == nil {
            header.thumbnailUrl = InnerTubeJSON.musicThumbnailURL(immersive)
        }
        if let descDict = immersive["description"] as? [String: Any] {
            let shelf = descDict["musicDescriptionShelfRenderer"] as? [String: Any]
            if let desc = ((shelf?["description"] as? [String: Any]).flatMap({ InnerTubeJSON.runsText($0) })
                ?? InnerTubeJSON.runsText(descDict)), !desc.isEmpty {
                header.descriptionText = desc
            }
        }
        if header.author == nil {
            header.author = InnerTubeJSON.runsTexts(immersive["subtitle"] as? [String: Any]).first
                ?? InnerTubeJSON.runsTexts(immersive["straplineTextOne"] as? [String: Any]).first
        }
    }

    private static func applyResponsiveHeader(_ renderer: [String: Any], to header: inout ParsedPodcastHeader) {
        header.title = InnerTubeJSON.runsText(renderer["title"] as? [String: Any]) ?? header.title
        header.thumbnailUrl = header.thumbnailUrl ?? InnerTubeJSON.musicThumbnailURL(renderer)

        // The show blurb is usually nested one level deeper:
        // description.musicDescriptionShelfRenderer.description.runs.
        // Never clobber the immersive-header description already found.
        if header.descriptionText == nil {
            let shelf = (renderer["description"] as? [String: Any])?["musicDescriptionShelfRenderer"] as? [String: Any]
            header.descriptionText = (shelf?["description"] as? [String: Any])
                .flatMap { InnerTubeJSON.runsText($0) }
                ?? (renderer["description"] as? [String: Any])
                .flatMap { InnerTubeJSON.runsText($0) }
                ?? (renderer["descriptionText"] as? [String: Any])
                .flatMap { InnerTubeJSON.runsText($0) }
                ?? renderer["description"] as? String
        }

        applyHeaderButtons(renderer, to: &header)
        applyHeaderSubtitle(renderer, to: &header)
    }

    /// Subscribed state from the header action buttons, when present.
    private static func applyHeaderButtons(_ renderer: [String: Any], to header: inout ParsedPodcastHeader) {
        guard let buttons = renderer["buttons"] as? [[String: Any]] else { return }
        for button in buttons {
            if let toggle = button["toggleButtonRenderer"] as? [String: Any],
               let toggled = toggle["isToggled"] as? Bool, toggled {
                header.isSubscribed = true
            }
            if let subscribe = button["subscribeButtonRenderer"] as? [String: Any],
               let subscribed = subscribe["subscribed"] as? Bool {
                header.isSubscribed = subscribed
            }
        }
    }

    private static func applyHeaderSubtitle(_ renderer: [String: Any], to header: inout ParsedPodcastHeader) {
        if header.author == nil,
           let strapline = renderer["straplineTextOne"] as? [String: Any],
           let runs = strapline["runs"] as? [[String: Any]],
           let text = runs.first?["text"] as? String {
            header.author = text
        }

        if header.author == nil || header.descriptionText == nil,
           let subtitle = renderer["subtitle"] as? [String: Any],
           let runs = subtitle["runs"] as? [[String: Any]] {
            for run in runs {
                guard let text = run["text"] as? String else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed == "•" { continue }
                if header.author == nil {
                    header.author = trimmed
                } else if header.descriptionText == nil, trimmed.count > 3 {
                    // Second distinct subtitle run is often the show blurb.
                    header.descriptionText = trimmed
                }
            }
        }

        if header.descriptionText == nil,
           let secondSubtitle = renderer["secondSubtitle"] as? [String: Any],
           let text = InnerTubeJSON.runsText(secondSubtitle),
           !text.isEmpty,
           !text.localizedCaseInsensitiveContains("episode") {
            header.descriptionText = text
        }
    }
}

// MARK: - Podcast episode parsing

extension PodcastDetailViewModel {
    /// Podcast episodes use musicMultiRowListItemRenderer inside
    /// secondaryContents.sectionListRenderer.contents[].musicShelfRenderer.contents
    /// or musicPlaylistShelfRenderer.contents.
    static func collectPodcastEpisodes(from json: [String: Any]) -> [EpisodeItem] {
        var episodes: [EpisodeItem] = []

        // Primary: twoColumnBrowseResultsRenderer.secondaryContents
        if let twoCol = (json["contents"] as? [String: Any])?["twoColumnBrowseResultsRenderer"] as? [String: Any],
           let secondary = twoCol["secondaryContents"] as? [String: Any],
           let sectionList = secondary["sectionListRenderer"] as? [String: Any],
           let sectionContents = sectionList["contents"] as? [[String: Any]] {
            for section in sectionContents {
                if let isr = section["itemSectionRenderer"] as? [String: Any],
                   let innerContents = isr["contents"] as? [[String: Any]] {
                    for inner in innerContents {
                        episodes += parseShelfContents(inner)
                    }
                } else {
                    episodes += parseShelfContents(section)
                }
            }
        }

        // Fallback: singleColumnBrowseResultsRenderer
        if episodes.isEmpty,
           let sections = BrowseLens.browseSections(json) {
            for section in sections {
                if let isr = section["itemSectionRenderer"] as? [String: Any],
                   let innerContents = isr["contents"] as? [[String: Any]] {
                    for inner in innerContents {
                        episodes += parseShelfContents(inner)
                    }
                } else {
                    episodes += parseShelfContents(section)
                }
            }
        }
        return episodes
    }

    private static func parseShelfContents(_ shelfDict: [String: Any]) -> [EpisodeItem] {
        if let shelf = shelfDict["musicShelfRenderer"] as? [String: Any],
           let contents = shelf["contents"] as? [[String: Any]] {
            return parseContentItems(contents)
        }
        if let shelf = shelfDict["musicPlaylistShelfRenderer"] as? [String: Any],
           let contents = shelf["contents"] as? [[String: Any]] {
            return parseContentItems(contents)
        }
        return []
    }

    private static func parseContentItems(_ contentItems: [[String: Any]]) -> [EpisodeItem] {
        var result: [EpisodeItem] = []
        for item in contentItems {
            if let multiRow = item["musicMultiRowListItemRenderer"] as? [String: Any],
               let episode = parseMultiRowEpisode(multiRow) {
                result.append(episode)
            } else if let responsive = item["musicResponsiveListItemRenderer"] as? [String: Any],
                      let episode = EpisodeItem.from(responsive) {
                result.append(episode)
            }
        }
        return result
    }

    static func parseMultiRowEpisode(_ renderer: [String: Any]) -> EpisodeItem? {
        guard let onTap = renderer["onTap"] as? [String: Any],
              let watch = onTap["watchEndpoint"] as? [String: Any],
              let videoId = watch["videoId"] as? String else { return nil }

        let title = InnerTubeJSON.runsText(renderer["title"] as? [String: Any]) ?? "Unknown"
        let thumbnailUrl = multiRowThumbnailUrl(renderer)
        var duration = progressRendererDuration(renderer)
        let meta = episodeSubtitleMeta(renderer, fallbackDuration: duration == 0)
        if duration == 0 { duration = meta.duration }

        // Per-episode description snippet (shown under the title like YTM).
        let episodeDescription = (renderer["description"] as? [String: Any])
            .flatMap { InnerTubeJSON.runsText($0) }
            ?? renderer["description"] as? String

        return EpisodeItem(
            videoId: videoId,
            title: title,
            artists: [],
            duration: duration,
            thumbnailUrl: thumbnailUrl,
            publishDate: meta.publishDate,
            descriptionText: episodeDescription,
            viewsText: meta.viewsText
        )
    }

    private static func multiRowThumbnailUrl(_ renderer: [String: Any]) -> String? {
        guard let thumbRenderer = renderer["thumbnail"] as? [String: Any],
              let musicThumb = thumbRenderer["musicThumbnailRenderer"] as? [String: Any],
              let thumb = musicThumb["thumbnail"] as? [String: Any],
              let thumbnails = thumb["thumbnails"] as? [[String: Any]],
              let last = thumbnails.last,
              let url = last["url"] as? String else { return nil }
        return url
    }

    /// Most reliable duration source: the playback progress renderer.
    private static func progressRendererDuration(_ renderer: [String: Any]) -> Int {
        guard let progress = renderer["playbackProgress"] as? [String: Any],
              let progressRenderer = progress["musicPlaybackProgressRenderer"] as? [String: Any],
              let durationText = InnerTubeJSON.runsText(progressRenderer["durationText"] as? [String: Any]),
              !durationText.isEmpty else { return 0 }
        return DurationFormat.parseClock(durationText)
            ?? DurationFormat.parseSpoken(durationText)
            ?? 0
    }

    /// Subtitle format: "17k views • 4 hr ago • 1 hr 23 mins".
    private static func episodeSubtitleMeta(
        _ renderer: [String: Any],
        fallbackDuration: Bool
    ) -> ParsedEpisodeMeta {
        var meta = ParsedEpisodeMeta()
        guard let subtitle = renderer["subtitle"] as? [String: Any],
              let runs = subtitle["runs"] as? [[String: Any]] else {
            return meta
        }
        let texts = runs.compactMap { $0["text"] as? String }
        let separated = texts.filter { $0.trimmingCharacters(in: .whitespaces) != "•" }
        for text in separated {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let lower = trimmed.lowercased()
            if lower.contains("ago") {
                // Relative date ("4 hr ago") — never a duration.
                if meta.publishDate == nil { meta.publishDate = trimmed }
            } else if trimmed.contains(":") {
                if fallbackDuration, meta.duration == 0 { meta.duration = DurationFormat.parseClock(trimmed) ?? 0 }
            } else if fallbackDuration, meta.duration == 0, let spoken = DurationFormat.parseSpoken(trimmed) {
                meta.duration = spoken
            } else if lower.contains("view") || lower.contains("listening") || lower.contains("download") {
                meta.viewsText = trimmed
            } else if meta.publishDate == nil {
                meta.publishDate = trimmed
            }
        }
        return meta
    }
}

// MARK: - View

struct PodcastDetailView: View {
    let browseId: String
    @State private var viewModel: PodcastDetailViewModel
    @State private var showMoreSheet = false

    init(browseId: String) {
        self.browseId = browseId
        _viewModel = State(initialValue: PodcastDetailViewModel(browseId: browseId))
    }

    var body: some View {
        ScrollView {
            DetailStateContainer(
                isLoading: viewModel.isLoading,
                error: viewModel.error,
                data: viewModel.podcast,
                noun: "podcast",
                emptyIcon: "antenna.radiowaves.left.and.right"
            ) { podcast in
                podcastContent(for: podcast)
            }
        }
        .scrollDisabled(viewModel.isLoading || viewModel.error != nil || viewModel.podcast == nil)
        .miniPlayerTracksScroll()
        .navigationTitle(viewModel.podcast?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel.isLoading else { return }
            await viewModel.load()
        }
        .sheet(isPresented: $showMoreSheet) {
            if let podcast = viewModel.podcast {
                PodcastMoreSheet(
                    podcast: podcast,
                    isSubscribed: viewModel.isSubscribed,
                    onToggleSubscribe: { Task { await viewModel.toggleSubscribe() } },
                    onPlayAll: { playAll(podcast) }
                )
            }
        }
    }

    @ViewBuilder
    private func podcastContent(for podcast: PodcastDetailInfo) -> some View {
        LazyVStack(spacing: 0) {
            header(for: podcast)
                .padding(.bottom, 8)

            CurrentEpisodeCard(episodes: podcast.episodes) { playEpisode($0, in: podcast) }

            if podcast.episodes.isEmpty {
                VStack(spacing: 8) {
                    Spacer().frame(height: 40)
                    Text("No episodes found")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                // Episodes come newest first.
                episodeRow("Latest", podcast.episodes.prefix(Self.latestCount), in: podcast)
                if podcast.episodes.count > Self.latestCount {
                    episodeRow("Earlier", podcast.episodes.dropFirst(Self.latestCount), in: podcast)
                }
            }
        }
    }

    @ViewBuilder
    private func header(for podcast: PodcastDetailInfo) -> some View {
        VStack(spacing: 10) {
            DetailHeaderCard(meta: kindLine(for: podcast), title: podcast.title) {
                AsyncImageView(url: podcast.thumbnailUrl)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous))
            } secondary: {
                if let author = podcast.author, !author.isEmpty {
                    authorChip(author)
                        .padding(.top, 4)
                }
            } buttons: {
                Button(action: { showMoreSheet = true }, label: {
                    HeaderRoundIcon(systemImage: "ellipsis")
                })
                .accessibilityLabel("More options")

                Button(action: {
                    Task { await viewModel.toggleSubscribe() }
                }, label: {
                    HeaderRoundIcon(
                        systemImage: viewModel.isSubscribed ? "bookmark.fill" : "bookmark",
                        tint: viewModel.isSubscribed ? .accentColor : .primary
                    )
                })
                .accessibilityLabel(viewModel.isSubscribed ? "Unsubscribe from podcast" : "Subscribe to podcast")

                if !podcast.episodes.isEmpty {
                    Button(action: { playOrResume(podcast) }, label: {
                        HeaderRoundIcon(systemImage: "play.fill", primary: .accentColor)
                    })
                    .accessibilityLabel("Play")
                }
            }

            if let desc = podcast.descriptionText, !desc.isEmpty {
                ExpandableDescriptionText(text: desc, collapsedLimit: 110)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DesignTokens.screenHPadding + 4)
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        // Same backdrop as the playlist and album headers.
        .background(alignment: .top) {
            BlurredArtworkBackdrop(url: podcast.thumbnailUrl)
        }
    }

    private func kindLine(for podcast: PodcastDetailInfo) -> String {
        let count = podcast.episodes.count
        guard count > 0 else { return "Podcast" }
        return "Podcast · \(count) episode\(count == 1 ? "" : "s")"
    }

    /// The show's author in a glass capsule, styled like the playlist people chip.
    /// Podcasts carry no author picture, so the initial stands in for the avatar.
    private func authorChip(_ author: String) -> some View {
        HStack(spacing: 6) {
            Text(author.prefix(1).uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
                .accessibilityHidden(true)
            Text(author)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: Capsule())
    }

    /// Episodes in the "Latest" row; the rest go to "Earlier".
    static let latestCount = 6

    /// A horizontal row of episode tiles. The tiles' glow reaches below the row, so it doesn't clip.
    private func episodeRow(_ title: String, _ episodes: ArraySlice<EpisodeItem>, in podcast: PodcastDetailInfo) -> some View {
        HorizontalSection(title: title, clipsContent: false) {
            LazyHStack(alignment: .top, spacing: DesignTokens.cardSpacing) {
                ForEach(episodes, id: \.videoId) { episode in
                    EpisodeDialTile(episode: episode) { playEpisode(episode, in: podcast) }
                }
            }
        }
    }

    // MARK: - Actions

    private func playAll(_ podcast: PodcastDetailInfo) {
        PlaybackQueue.play(podcast.episodes.map { $0.toSongItem() }, log: Log.podcastDetail, context: "playAll")
    }

    /// Resumes the most recently listened unfinished episode, else plays the show from the top.
    private func playOrResume(_ podcast: PodcastDetailInfo) {
        Task {
            if let resume = await CurrentEpisodeCard.latestInProgress(in: podcast.episodes) {
                playEpisode(resume.episode, in: podcast)
            } else {
                playAll(podcast)
            }
        }
    }

    private func playEpisode(_ episode: EpisodeItem, in podcast: PodcastDetailInfo) {
        let songs = podcast.episodes.map { $0.toSongItem() }
        let song = episode.toSongItem()
        Task {
            let saved = await EpisodePlaybackStore.shared.position(for: episode.videoId)
            let resumeAt: TimeInterval? = if let saved, saved.position > 10, !saved.isFinished {
                saved.position
            } else {
                nil
            }
            PlaybackQueue.play(song, in: songs, log: Log.podcastDetail, context: "playEpisode")
            guard let resumeAt else { return }
            // Wait until this episode's file is actually loaded before seeking.
            // A fixed delay races slow stream resolves (BotGuard etc.): the seek
            // lands on the old file (or nothing) and the fresh load starts at 0.
            for _ in 0..<75 {
                try? await Task.sleep(for: .milliseconds(200))
                if PlayerController.shared.currentVideoId == episode.videoId { break }
            }
            guard PlayerController.shared.currentVideoId == episode.videoId else { return }
            PlayerController.shared.seek(to: resumeAt)
        }
    }
}

// MARK: - Podcast More Sheet

/// Overflow menu matching PlaylistMoreSheet, with Subscribe as the
/// first row (mirrors podcast.subscribed_at).
struct PodcastMoreSheet: View {
    let podcast: PodcastDetailInfo
    let isSubscribed: Bool
    var onToggleSubscribe: (() -> Void)?
    var onPlayAll: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetChrome {
            MenuCard {
                MenuRow(
                    icon: isSubscribed ? "checkmark.circle.fill" : "plus.circle",
                    title: isSubscribed ? "Subscribed" : "Subscribe",
                    subtitle: isSubscribed ? "Unsubscribe from this podcast" : "Get new episodes in your library"
                ) {
                    onToggleSubscribe?()
                    dismiss()
                }
                Divider()
                MenuRow(
                    icon: "play.fill",
                    title: "Play All",
                    subtitle: "Play episodes from the top"
                ) {
                    onPlayAll?()
                    dismiss()
                }
                Divider()
                MenuRow(
                    icon: "list.bullet",
                    title: "Add to Queue",
                    subtitle: "Add to the end of the queue"
                ) {
                    addToQueue()
                    dismiss()
                }
                Divider()
                MenuRow(
                    icon: "square.and.arrow.down",
                    title: "Download",
                    subtitle: "Download episodes for offline playback"
                ) {
                    downloadAll()
                    dismiss()
                }
                Divider()
                MenuRow(
                    icon: "square.and.arrow.up",
                    title: "Share",
                    subtitle: "Share this podcast with others"
                ) {
                    share()
                    dismiss()
                }
            }
        }
    }

    private func addToQueue() {
        NowPlaying.shared.appendToQueue(podcast.episodes.map { $0.toSongItem() })
    }

    private func downloadAll() {
        for episode in podcast.episodes {
            Task { await DownloadManager.shared.download(song: episode.toSongItem()) }
        }
    }

    private func share() {
        guard let url = URL(string: "https://music.youtube.com/browse/\(podcast.browseId)") else { return }
        presentShareSheet(items: [url])
        dismiss()
    }
}

// MARK: - Current episode card

/// Wide dial card over the episode rows: the episode the player holds when it
/// is from this show, else the most recently listened unfinished one.
/// Hidden when neither exists.
private struct CurrentEpisodeCard: View {
    let episodes: [EpisodeItem]
    var onPlay: (EpisodeItem) -> Void

    @State private var resume: (episode: EpisodeItem, saved: EpisodePosition)?
    @State private var colors: [Color]?

    static let artSize: CGFloat = 70

    /// Most recently updated saved position past 10 s and not finished: the
    /// same threshold `playEpisode` uses to resume.
    static func latestInProgress(in episodes: [EpisodeItem]) async -> (episode: EpisodeItem, saved: EpisodePosition)? {
        var latest: (episode: EpisodeItem, saved: EpisodePosition)?
        for episode in episodes {
            guard let saved = await EpisodePlaybackStore.shared.position(for: episode.videoId),
                  saved.position > 10, !saved.isFinished,
                  saved.updatedAt > (latest?.saved.updatedAt ?? .distantPast) else { continue }
            latest = (episode: episode, saved: saved)
        }
        return latest
    }

    var body: some View {
        let np = NowPlaying.shared
        // The player's item, playing or paused, when it is one of this show's episodes.
        let current = episodes.first { $0.videoId == np.videoId }
        let shown = current ?? resume?.episode

        // A VStack rather than a Group: an empty Group never runs its task.
        VStack(spacing: 0) {
            if let shown {
                card(shown, isCurrent: current != nil, saved: current == nil ? resume?.saved : nil)
            }
        }
        // Pausing or changing episode saves a position: reload it then.
        .task(id: "\(episodes.count)|\(np.videoId ?? "")|\(np.isPlaying)") {
            resume = await Self.latestInProgress(in: episodes)
        }
        .task(id: shown?.videoId) {
            guard let shown else { return }
            let loaded = await ReleaseColors.load(key: shown.videoId, url: shown.thumbnailUrl)
            withAnimation(.easeInOut(duration: 0.4)) { colors = loaded }
        }
    }

    private func card(_ episode: EpisodeItem, isCurrent: Bool, saved: EpisodePosition?) -> some View {
        DialCard(colors: colors, progress: isCurrent ? nil : (saved?.progress ?? 0)) {
            HStack(alignment: .top, spacing: 12) {
                AsyncImageView(url: episode.thumbnailUrl)
                    .frame(width: Self.artSize, height: Self.artSize)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 6, x: 2, y: 4)

                VStack(alignment: .leading, spacing: 6) {
                    EpisodeStatusTag(isCurrent: isCurrent, saved: saved)
                    Text(episode.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)

            if let desc = episode.descriptionText, !desc.isEmpty {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .padding(.bottom, 4)
            }
            Text(episode.dateAndLength)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
        .overlay(alignment: .bottomTrailing) {
            DialPlayButton(isCurrent: isCurrent) { play(episode, isCurrent: isCurrent) }
                .padding(RadioDialTile.inset)
        }
        .padding(.horizontal, DesignTokens.screenHPadding)
        .padding(.bottom, DesignTokens.sectionGap)
    }

    private func play(_ episode: EpisodeItem, isCurrent: Bool) {
        if isCurrent {
            PlayerController.shared.togglePlayPause()
        } else {
            onPlay(episode)
        }
    }
}

// MARK: - Episode tile

/// One episode in a "Latest" / "Earlier" row, in the look of Home's `RadioDialTile`.
/// Tap plays or resumes it (pause/resume while it is the current one);
/// long press opens the song menu (queue, download, share…).
private struct EpisodeDialTile: View {
    let episode: EpisodeItem
    var onPlay: () -> Void

    @State private var colors: [Color]?
    /// Saved listening position; reloaded when the episode stops being current.
    @State private var saved: EpisodePosition?

    static let size = CGSize(width: 160, height: 286)
    static let artSize: CGFloat = 118

    init(episode: EpisodeItem, onPlay: @escaping () -> Void) {
        self.episode = episode
        self.onPlay = onPlay
        _colors = State(initialValue: ReleaseColors.cache[episode.videoId])
    }

    var body: some View {
        // This episode is the player's current item, playing or paused.
        let isCurrent = NowPlaying.shared.videoId == episode.videoId

        SongActionsMenu(song: episode.toSongItem(), onNavigate: { AppRouter.shared.open($0) }, asContextMenu: true) {
            Button { play(isCurrent: isCurrent) } label: {
                DialCard(colors: colors, size: Self.size, progress: isCurrent ? nil : (saved?.progress ?? 0)) {
                    content(isCurrent: isCurrent)
                }
            }
            .buttonStyle(ZoomPressStyle())
        }
        // On top of the card rather than inside its button, like `RadioDialTile`.
        .overlay(alignment: .bottomTrailing) {
            DialPlayButton(isCurrent: isCurrent) { play(isCurrent: isCurrent) }
                .padding(RadioDialTile.inset)
        }
        // The fixed card height holds the text up to this size.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .task(id: episode.videoId) {
            guard colors == nil,
                  let extracted = await ReleaseColors.load(key: episode.videoId, url: episode.thumbnailUrl) else { return }
            withAnimation(.easeInOut(duration: 0.4)) { colors = extracted }
        }
        // Reloads when the episode stops being current, so the needle keeps the position it reached.
        .task(id: isCurrent ? nil : episode.videoId) {
            guard !isCurrent else { return }
            saved = await EpisodePlaybackStore.shared.position(for: episode.videoId)
        }
    }

    @ViewBuilder
    private func content(isCurrent: Bool) -> some View {
        HStack(spacing: 4) {
            EpisodeStatusTag(isCurrent: isCurrent, saved: saved)
            Spacer(minLength: 0)
            if episode.duration > 0 {
                Text(episode.duration.formattedDuration)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
        .padding(.bottom, 6)

        AsyncImageView(url: episode.thumbnailUrl)
            .frame(width: Self.artSize, height: Self.artSize)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 6, x: 2, y: 4)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)

        Text(episode.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(2, reservesSpace: true)
        if let date = episode.publishDate, !date.isEmpty {
            Text(date)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
    }

    private func play(isCurrent: Bool) {
        if isCurrent {
            PlayerController.shared.togglePlayPause()
        } else {
            onPlay()
        }
    }
}

// MARK: - Status tag

/// ON AIR while the episode plays, minutes left while paused or in progress,
/// PLAYED once finished (per `EpisodePosition.isFinished`), else nothing.
private struct EpisodeStatusTag: View {
    let isCurrent: Bool
    let saved: EpisodePosition?

    var body: some View {
        let np = NowPlaying.shared
        if isCurrent && np.isPlaying {
            OnAirBadge()
        } else if isCurrent, np.duration > 0 {
            // Paused: the player's live position, newer than the saved one.
            EpisodeTag(text: Self.minutesLeft(np.duration - np.currentTime))
        } else if let saved, saved.isFinished {
            EpisodeTag(text: "PLAYED")
        } else if let saved, saved.position > 10 {
            EpisodeTag(text: Self.minutesLeft(saved.remaining))
        }
    }

    static func minutesLeft(_ seconds: Double) -> String {
        "\(max(1, Int((seconds / 60).rounded()))) MIN LEFT"
    }
}

/// Small white capsule label for the coloured dial cards, sized like `OnAirBadge`.
private struct EpisodeTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.8)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.2)))
            .lineLimit(1)
    }
}

private extension EpisodeItem {
    /// "4 hr ago · 1 hr 23 mins", leaving out whichever is missing.
    var dateAndLength: String {
        [publishDate ?? "", duration.wordsDuration].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Inline expandable description ("… More" right after the text)

/// Shows a truncated prefix with an inline tappable More suffix, expanding
/// to the full text with a Less suffix. The toggle sits immediately after
/// the text instead of on a separate row below it.
private struct ExpandableDescriptionText: View {
    let text: String
    var collapsedLimit: Int = 140

    @State private var expanded = false

    private var isTruncated: Bool { text.count > collapsedLimit }

    var body: some View {
        Text(styledText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .onTapGesture {
                if isTruncated { expanded.toggle() }
            }
            .accessibilityLabel(isTruncated ? (expanded ? "Show less" : "Show more") : "Description")
    }

    private var styledText: AttributedString {
        var str = AttributedString(displayText)
        guard isTruncated else { return str }
        var toggle = AttributedString(toggleLabel)
        toggle.foregroundColor = .accentColor
        toggle.font = .caption.weight(.semibold)
        str.append(toggle)
        return str
    }

    private var displayText: String {
        guard !expanded, isTruncated else { return text }
        return String(text.prefix(collapsedLimit)) + "… "
    }

    private var toggleLabel: String {
        guard isTruncated else { return "" }
        return expanded ? " Less" : "More"
    }
}
