//
//  RadioDialTile.swift
//  Trop
//

import GRDB
import SwiftUI

/// Podcast card for Home's horizontal shelves, styled like a radio dial: the
/// artwork-coloured card and glow of Explore's new releases, an ON AIR light
/// while this show plays, and a tuning scale whose needle marks the listening progress.
struct RadioDialTile: View {
    let podcast: PodcastItem
    var onOpen: () -> Void

    @State private var colors: [Color]?
    /// The playing episode, once the database confirms it belongs to this show.
    @State private var onAirVideoId: String?
    /// Progress of the show's most recently listened episode.
    @State private var savedProgress: Double = 0
    @State private var isStarting = false
    /// Turns on only once a start has taken longer than `PlayPauseGlyph.spinnerDelay`.
    @State private var showsSpinner = false

    static let size = CGSize(width: 170, height: 258)
    static let radius: CGFloat = 18
    static let inset: CGFloat = 12
    static let artSize: CGFloat = 120
    static let podcastEpisodeType = "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"

    init(podcast: PodcastItem, onOpen: @escaping () -> Void) {
        self.podcast = podcast
        self.onOpen = onOpen
        _colors = State(initialValue: ReleaseColors.cache[podcast.browseId])
    }

    private var np: NowPlaying { NowPlaying.shared }

    /// An episode of this show is the current item, playing or paused.
    private var isCurrent: Bool {
        np.videoId != nil && np.videoId == onAirVideoId && np.musicVideoType == Self.podcastEpisodeType
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        let current = isCurrent

        Button(action: onOpen) {
            card(isCurrent: current)
                .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
                .background(NewReleaseCard.backdrop(colors))
                .clipShape(shape)
                .shadow(color: NewReleaseCard.glowColor(colors).opacity(0.5), radius: 8, y: 5)
                .contentShape(shape)
                .contentShape(.contextMenuPreview, shape)
        }
        .buttonStyle(ZoomPressStyle())
        .cardMenu(for: .podcast(podcast))
        // On top of the card rather than inside its button, so its taps never open the page.
        .overlay(alignment: .bottomTrailing) {
            playButton(isCurrent: current)
                .padding(Self.inset)
        }
        // The fixed card height holds the text up to this size.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .task(id: podcast.browseId) { await loadColors() }
        .task(id: np.musicVideoType == Self.podcastEpisodeType ? np.videoId : nil) { await resolveOnAir() }
        // The playing tile follows the player live; the others show the saved position.
        .task(id: current) {
            if !current { await loadSavedProgress() }
        }
    }

    // MARK: Parts

    private func card(isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if isCurrent && np.isPlaying { OnAirBadge() }
            }
            .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
            .padding(.bottom, 6)

            AsyncImageView(url: podcast.thumbnailUrl)
                .frame(width: Self.artSize, height: Self.artSize)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .coverZoomSource(YTItemRouter.detailRoute(for: .podcast(podcast)))
                .shadow(color: .black.opacity(0.35), radius: 6, x: 2, y: 4)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)

            Text(podcast.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(podcast.author ?? "Podcast")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                TuningScale(progress: isCurrent ? nil : savedProgress)
                // Room for the play button, which sits on top of the card.
                Color.clear
                    .frame(width: NewReleaseCard.buttonSize, height: NewReleaseCard.buttonSize)
            }
        }
        .padding(Self.inset)
    }

    private func playButton(isCurrent: Bool) -> some View {
        Button(action: playTapped) {
            if isCurrent {
                // The player's own glyph: a mic while playing, crossed out while paused.
                PlayPauseGlyph(isPlaying: np.isPlaying, size: 16, color: .white)
                    .frame(width: NewReleaseCard.buttonSize, height: NewReleaseCard.buttonSize)
                    .background(Circle().fill(Color.accentColor))
                    .contentShape(Circle())
            } else {
                NewReleaseCard.roundIcon("play.fill", fill: .accentColor, foreground: .white, isBusy: showsSpinner)
            }
        }
        .buttonStyle(ZoomPressStyle(scale: 0.92))
        .disabled(isStarting)
        .task(id: isStarting) {
            guard isStarting else { showsSpinner = false; return }
            try? await Task.sleep(for: PlayPauseGlyph.spinnerDelay)
            if !Task.isCancelled { showsSpinner = true }
        }
        .accessibilityLabel(isCurrent && np.isPlaying ? "Pause" : "Play")
    }

    // MARK: Actions

    /// This show playing → pause/resume; otherwise play its episodes, like the podcast page's Play.
    private func playTapped() {
        if isCurrent {
            PlayerController.shared.togglePlayPause()
            return
        }
        Task {
            isStarting = true
            defer { isStarting = false }
            // Loading the show also stores its episodes with the show id, which `resolveOnAir` reads.
            let model = PodcastDetailViewModel(browseId: podcast.browseId)
            await model.load()
            guard let episodes = model.podcast?.episodes, !episodes.isEmpty else { return }
            PlaybackQueue.play(episodes.map { $0.toSongItem() }, log: Log.homeScreenView, context: "Playing podcast \(podcast.title)")
        }
    }

    /// The player knows only the episode's video id; the episode table maps it
    /// to its show. Episodes are stored when their show's page (or this tile's Play) loads it.
    private func resolveOnAir() async {
        guard np.musicVideoType == Self.podcastEpisodeType, let videoId = np.videoId else {
            onAirVideoId = nil
            return
        }
        let episode: EpisodeEntity? = (try? await DatabaseService.shared.fetchOne(EpisodeEntity.self, key: videoId)) ?? nil
        onAirVideoId = episode?.podcastId == podcast.browseId ? videoId : nil
    }

    /// Position of the show's most recently listened episode, 0 when none is saved.
    private func loadSavedProgress() async {
        let episodes = (try? await DatabaseService.shared.fetchAll(
            EpisodeEntity.self,
            sql: "SELECT * FROM episode WHERE podcast_id = ?",
            arguments: [podcast.browseId]
        )) ?? []
        var latest: EpisodePosition?
        for episode in episodes {
            guard let saved = await EpisodePlaybackStore.shared.position(for: episode.id),
                  saved.updatedAt > (latest?.updatedAt ?? .distantPast) else { continue }
            latest = saved
        }
        savedProgress = latest?.progress ?? 0
    }

    private func loadColors() async {
        guard colors == nil,
              let url = podcast.thumbnailUrl.flatMap({ URL(string: $0) }),
              let image = try? await ArtworkLoader.image(for: url) else { return }
        let extracted = await Task.detached(priority: .utility) { image.extractDominantColors() }.value
        ReleaseColors.cache[podcast.browseId] = extracted
        withAnimation(.easeInOut(duration: 0.4)) { colors = extracted }
    }
}

// MARK: - ON AIR

/// Red capsule that blinks slowly, held still with Reduce Motion.
/// Also marks the playing episode on the podcast page.
struct OnAirBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        Text("ON AIR")
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.8)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.red))
            .opacity(dimmed ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                // 0.8 s each way: one blink every 1.6 s.
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dimmed = true }
            }
    }
}

// MARK: - Tuning scale

/// A tick every 7 pt with a glowing needle at `progress`. `nil` follows the
/// playing episode live; only the playing tile reads the player's position.
/// Also used by the podcast page, whose plain background needs `tickColor`.
struct TuningScale: View {
    let progress: Double?
    var tickColor: Color = .white.opacity(0.4)

    static let tickSpacing: CGFloat = 7
    /// #FFCF4A
    static let needleColor = Color(red: 1, green: 0.81, blue: 0.29)

    var body: some View {
        let value = CGFloat(min(1, max(0, progress ?? Double(NowPlaying.shared.progress))))
        Canvas { context, size in
            var ticks = Path()
            for i in 0...Int(size.width / Self.tickSpacing) {
                // Every fifth tick is full height, like the numbered marks on a dial.
                let height = i % 5 == 0 ? size.height : size.height * 0.5
                ticks.addRect(CGRect(x: CGFloat(i) * Self.tickSpacing, y: size.height - height, width: 1, height: height))
            }
            context.fill(ticks, with: .color(tickColor))
        }
        .overlay(alignment: .leading) {
            GeometryReader { geo in
                Capsule()
                    .fill(Self.needleColor)
                    .frame(width: 2)
                    .shadow(color: Self.needleColor.opacity(0.9), radius: 3)
                    .offset(x: (geo.size.width - 2) * value)
            }
        }
        .frame(height: 22)
        .accessibilityHidden(true)
    }
}
