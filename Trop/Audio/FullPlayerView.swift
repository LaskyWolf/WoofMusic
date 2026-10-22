//
//  FullPlayerView.swift
//  Trop
//
//  Created by 686udjie on 18/07/2026.
//

import SwiftUI

struct FullPlayerView: View {
    let onCollapse: () -> Void
    let artworkTopInset: CGFloat

    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let player = PlayerController.shared
    @Bindable private var np = NowPlaying.shared
    @State private var editingProgress: Float = 0
    @State private var isEditingSlider = false

    @ObservedObject private var likeStore = LikeStore.shared
    private var isLiked: Bool {
        guard let song = np.queueSongs.indices.contains(np.queueIndex) ? np.queueSongs[np.queueIndex] : nil else { return false }
        return likeStore.isLiked(videoId: song.videoId)
    }
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var pendingRoute: DetailRoute?
    @State private var isOpeningArtist = false
    @State private var artistUnavailable = false
    @State private var artworkEntryOffset: CGFloat = 0
    @State private var titleChangeTrigger = 0
    @State private var titleChangeDirection: CGFloat = 1
    @State private var lastTitleQueueIndex = NowPlaying.shared.queueIndex
    private let titleLineHeight: CGFloat = 30
    @State private var currentLyrics: [LyricLine] = []
    private var playerBackgroundColors: [Color] { np.dominantColors }

    private var activeLyricText: String? {
        let synchronizedLines = currentLyrics.filter {
            $0.startTime != nil &&
                !$0.text.trimmingCharacters(in: CharacterSet(charactersIn: "♪*· ")).isEmpty
        }
        guard let firstLine = synchronizedLines.first else { return nil }

        let lyricTime = np.currentTime + settings.lyricsOffsetSeconds
        return synchronizedLines.last { line in
            guard let startTime = line.startTime else { return false }
            return startTime <= lyricTime
        }?.text ?? firstLine.text
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if settings.playerBackgroundStyle == .solid {
                    Color.black
                        .ignoresSafeArea()
                } else {
                    LinearGradient(
                        colors: [
                            playerBackgroundColors.first ?? Color(red: 0.15, green: 0.15, blue: 0.2),
                            playerBackgroundColors.last ?? Color(red: 0.05, green: 0.05, blue: 0.08)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.8), value: playerBackgroundColors)

                    Circle()
                        .fill(playerBackgroundColors.first ?? .blue)
                        .frame(width: 400, height: 400)
                        .blur(radius: 120)
                        .opacity(0.45)
                        .offset(y: -150)
                        .ignoresSafeArea()
                }

                artwork
                    .frame(maxWidth: .infinity)
                    .frame(height: (geometry.size.height + artworkTopInset) * 0.58)
                    .compositingGroup()
                    .clipped()
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0),
                                .init(color: .white, location: 0.62),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .offset(y: -artworkTopInset)
                    .frame(maxHeight: .infinity, alignment: .top)

                VStack(spacing: 0) {
                    playerHandle

                    VStack(spacing: 0) {
                        Spacer(minLength: 0)

                        titleAndActionsRow
                            .padding(.horizontal, 32)
                            .padding(.top, 20)
                            .padding(.bottom, 16)

                        lyricPreview
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(playerSwipe())
                    .overlay {
                        playerPanel
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                    }

                    progressSlider
                        .padding(.top, 4)
                        .padding(.bottom, 16)

                    Color.clear.frame(height: 8)

                    PlaybackControlsRow(
                        isPlaying: np.isPlaying,
                        hasPrevious: np.hasPrevious,
                        hasNext: np.hasNext,
                        onPrevious: { np.playPrevious() },
                        onPlayPause: { player.togglePlayPause() },
                        onNext: { np.playNext() }
                    )
                    .padding(.bottom, 8)

                    PlayerVolumeSlider()

                    Color.clear.frame(height: 4)

                    SecondaryActionsRow(
                        showQueue: $showQueue,
                        isRepeatOn: $np.isRepeatOn,
                        showLyrics: $showLyrics
                    )

                    Color.clear.frame(height: 8)
                }
            }
            .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.25), value: showQueue)
            .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.25), value: showLyrics)
            .onChange(of: np.videoId) { oldValue, newValue in
                if oldValue != nil, newValue != nil {
                    titleChangeDirection = np.queueIndex < lastTitleQueueIndex ? -1 : 1
                    titleChangeTrigger &+= 1
                }
                lastTitleQueueIndex = np.queueIndex
                showLyrics = false
                preloadLyrics()
            }
            .onChange(of: np.queueSongs.count) { _, _ in
                np.preloadNeighborArtwork()
                preloadLyrics()
            }
            .onChange(of: np.queueIndex) { _, _ in
                np.preloadNeighborArtwork()
            }
            .onChange(of: showQueue) { _, newValue in
                if newValue {
                    showLyrics = false
                    np.preloadNeighborArtwork()
                }
            }
            .onChange(of: showLyrics) { _, newValue in
                if newValue { showQueue = false }
            }
            .task { np.preloadNeighborArtwork() }
            .task(id: np.videoId) { await loadCurrentLyrics() }
            .alert("Artist unavailable", isPresented: $artistUnavailable) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The artist page could not be found. Try again when connected.")
            }
            .interactiveDismissDisabled(showQueue || showLyrics)
            .background(
                Color.clear
                    .detailRouteSheet(item: $pendingRoute)
            )
        }
    }

    private func closePanelOrPlayer() {
        if showQueue {
            showQueue = false
        } else if showLyrics {
            showLyrics = false
        } else {
            onCollapse()
        }
    }

    private var playerHandle: some View {
        Button(action: closePanelOrPlayer) {
            Capsule()
                .fill(.white.opacity(0.3))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showQueue ? "Close queue" : showLyrics ? "Close lyrics" : "Collapse player")
    }

    @ViewBuilder
    private var playerPanel: some View {
        if showQueue || showLyrics {
            Group {
                if showLyrics {
                    LyricsView(showLyrics: $showLyrics)
                } else {
                    QueueView(
                        showQueue: $showQueue,
                        isShuffleOn: $np.isShuffleOn,
                        isRepeatOn: $np.isRepeatOn
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
            .environment(\.colorScheme, .dark)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.95).combined(with: .opacity))
            .accessibilityAction(.escape) { closePanelOrPlayer() }
        }
    }

    private var lyricPreview: some View {
        Group {
            if let activeLyricText {
                Text(activeLyricText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .multilineTextAlignment(settings.lyricsAlignment.multilineTextAlignment)
                    .frame(maxWidth: .infinity, alignment: settings.lyricsAlignment.textAlignment)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 8)
                    .accessibilityLabel("Current lyric: \(activeLyricText)")
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 33, alignment: .bottom)
        .allowsHitTesting(false)
    }

    // MARK: - Gestures

    private func playerSwipe() -> PlayerTrackSwipeGesture {
        PlayerTrackSwipeGesture(
            isEnabled: !showQueue && !showLyrics && settings.artworkSwipeNavigation
        ) { distance in
            if distance < -60, np.hasNext {
                np.playNext()
                slideInArtwork(fromLeft: false)
            } else if distance > 60, np.hasPrevious {
                np.playPrevious()
                slideInArtwork(fromLeft: true)
            }
        }
    }

    private func slideInArtwork(fromLeft: Bool) {
        artworkEntryOffset = fromLeft ? -600 : 600
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            artworkEntryOffset = 0
        }
    }

    // MARK: - Player Content

    private func preloadLyrics() {
        guard let id = np.videoId else { return }
        let upcoming = np.upcomingSongs(prefixLimit: 3).map(\.videoId)
        Task { await LyricsService.shared.preload(videoId: id, upcoming: upcoming) }
    }

    private func loadCurrentLyrics() async {
        guard let videoId = np.videoId else {
            currentLyrics = []
            return
        }
        currentLyrics = []
        guard let lines = try? await LyricsService.shared.fetchLyrics(videoId: videoId),
              !Task.isCancelled,
              np.videoId == videoId else { return }
        currentLyrics = lines
    }

    private var titleAndActionsRow: some View {
        HStack(alignment: .top) {
            PlayerTitleBlock(
                title: np.title,
                artist: np.displayArtist,
                spacing: 1,
                titleFont: .title2.weight(.bold),
                onArtistTap: { openCurrentArtist() }
            )
            .disabled(isOpeningArtist)
            .keyframeAnimator(initialValue: CGFloat.zero, trigger: titleChangeTrigger) { content, offset in
                content.offset(x: reduceMotion ? 0 : offset * titleChangeDirection)
            } keyframes: { _ in
                MoveKeyframe(CGFloat(18))
                SpringKeyframe(CGFloat.zero, duration: 0.45, spring: .bouncy)
            }

            Spacer()

            HStack(spacing: 12) {
                PlayerLikeButton(isLiked: isLiked) {
                    guard let song = np.queueSongs.indices.contains(np.queueIndex) ? np.queueSongs[np.queueIndex] : nil else { return }
                    Task { await likeStore.toggle(song: song) }
                }

                if np.queueSongs.indices.contains(np.queueIndex) {
                    PlayerSongMenu(song: np.queueSongs[np.queueIndex], onCollapse: { onCollapse() })
                        .equatable()
                }
            }
            .alignmentGuide(.top) { dimensions in
                dimensions.height / 2 - titleLineHeight / 2
            }
        }
    }

    private func openCurrentArtist() {
        guard !isOpeningArtist else { return }
        let artist = np.artists.first(where: { !$0.name.isEmpty }) ?? YTArtist(name: np.artist, id: nil)
        guard !artist.name.isEmpty else {
            artistUnavailable = true
            return
        }
        isOpeningArtist = true
        Task { @MainActor in
            defer { isOpeningArtist = false }
            var browseId = artist.id
            if browseId == nil {
                if let json = try? await SearchService.shared.search(query: artist.name) {
                    browseId = SearchParser.parseSearchResults(from: json)
                        .flatMap(\.items)
                        .compactMap { item -> ArtistItem? in
                            if case .artist(let result) = item { return result }
                            return nil
                        }
                        .first(where: { $0.name.caseInsensitiveCompare(artist.name) == .orderedSame })?
                        .browseId
                }
            }
            guard let browseId else {
                artistUnavailable = true
                return
            }
            onCollapse()
            AppRouter.shared.open(.artist(browseId: browseId))
        }
    }

    private var artwork: some View {
        artworkImage
            .offset(x: artworkEntryOffset)
    }

    /// Song artwork (or placeholder), filling its container.
    private var artworkImage: some View {
        ZStack {
            if let uiImage = np.thumbnailUIImage {
                GeometryReader { geo in
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note")
                        .font(.system(size: 64))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
    }

    private var progressSlider: some View {
        VStack(spacing: 6) {
            ProgressBar(
                progress: Binding(
                    get: { isEditingSlider ? editingProgress : np.progress },
                    set: { editingProgress = $0 }
                ),
                accentColor: np.dominantColors.first ?? .white,
                isPlaying: np.isPlaying,
                onEditingChanged: { editing in
                    if !editing {
                        player.seek(to: TimeInterval(editingProgress) * np.duration)
                    }
                    isEditingSlider = editing
                }
            )

            HStack {
                Text(DurationFormat.playbackTime(isEditingSlider
                    ? TimeInterval(editingProgress) * np.duration
                    : np.currentTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()

                Text(DurationFormat.playbackTime(np.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 32)
    }

}

/// The full player's "⋯" menu. The player redraws several times a second for
/// the progress bar; `.equatable()` skips those redraws here, because a menu
/// rebuilt while open flickers.
private struct PlayerSongMenu: View, Equatable {
    let song: SongItem
    let onCollapse: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.song.videoId == rhs.song.videoId
    }

    var body: some View {
        SongActionsMenu(song: song, showsQueueActions: false, onCollapseRequest: onCollapse) {
            PlayerOptionsGlyph()
        }
    }
}
