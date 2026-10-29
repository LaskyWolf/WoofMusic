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

    @ObservedObject private var likeStore = LikeStore.shared
    private var isLiked: Bool {
        guard let song = np.queueSongs.indices.contains(np.queueIndex) ? np.queueSongs[np.queueIndex] : nil else { return false }
        return likeStore.isLiked(videoId: song.videoId)
    }
    private var currentLikeFlavor: LikeFlavor {
        guard np.queueSongs.indices.contains(np.queueIndex) else { return .unknown }
        let song = np.queueSongs[np.queueIndex]
        return LikeFlavor.guess(videoId: song.videoId, title: song.title, artists: song.artists.map(\.name), album: song.album)
    }
    @State private var showLyrics = false
    @AppStorage(LyricsState.karaokeEnabledKey) private var karaokeEnabled = false
    /// Karaoke lyrics drop their glass panel; the artwork and title step aside
    /// so only the lyrics sit over the player background.
    private var showsKaraoke: Bool { showLyrics && karaokeEnabled && LyricsState.shared.hasWordTiming }
    @State private var showQueue = false
    @State private var isOpeningArtist = false
    @State private var artistUnavailable = false
    /// How far the cover pages are dragged sideways by the track swipe.
    @State private var artworkDragOffset: CGFloat = 0
    @State private var isCommittingSwipe = false
    private static let sleepOverlayBleed: CGFloat = 8
    @State private var titleChangeTrigger = 0
    @State private var titleChangeDirection: CGFloat = 1
    @State private var lastTitleQueueIndex = NowPlaying.shared.queueIndex
    /// Timed, non-empty lines of the current song, for the lyric preview.
    @State private var syncedLyrics: [LyricLine] = []
    /// How far the player is pulled down by the dismiss gesture.
    @State private var pullDistance: CGFloat = 0
    /// The hidden full-screen cover, opened by pinching the cover out.
    @State private var showsFullscreenCover = false
    /// Where the current cover sits on screen, for the full-screen cover to
    /// grow from. A plain box, not state: the swipe and pull move the cover
    /// every frame and must not redraw the player.
    @State private var coverFrame = CoverFrameBox()
    private var playerBackgroundColors: [Color] { np.dominantColors }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if settings.playerBackgroundStyle == .solid {
                    Color.black
                        .ignoresSafeArea()
                } else if settings.playerStyle == .card {
                    // The cover's colour, brighter at the top and dark enough for
                    // white text from the middle down, where the controls sit.
                    let base = playerBackgroundColors.first ?? .black
                    LinearGradient(
                        stops: [
                            .init(color: base.mix(with: .black, by: 0.15), location: 0),
                            .init(color: base.mix(with: .black, by: 0.6), location: 0.55)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                        .animation(.easeInOut(duration: 0.8), value: playerBackgroundColors)
                } else {
                    LinearGradient(
                        colors: [
                            playerBackgroundColors.first ?? Color(red: 0.15, green: 0.15, blue: 0.2),
                            playerBackgroundColors.last ?? Color(red: 0.05, green: 0.05, blue: 0.08)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    // An overlay, not a ZStack sibling: on a screen narrower than
                    // 400 points the glow's fixed width would widen the player,
                    // shift it right and show the previous cover at the left edge.
                    .overlay {
                        Circle()
                            .fill(playerBackgroundColors.first ?? .blue)
                            .frame(width: 400, height: 400)
                            .blur(radius: 120)
                            .opacity(0.45)
                            .offset(y: -150)
                    }
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.8), value: playerBackgroundColors)
                }

                if settings.playerStyle == .immersive {
                    let artworkHeight = (geometry.size.height + artworkTopInset) * 0.58
                    // Clipped to the screen width, so a neighbour shows only the
                    // part dragged in from the edge.
                    artworkPager(pageSize: CGSize(width: geometry.size.width, height: artworkHeight))
                        .frame(maxWidth: .infinity)
                        .frame(height: artworkHeight)
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
                        .opacity(showsKaraoke ? 0 : 1)
                }

                VStack(spacing: 0) {
                    playerHandle

                    VStack(spacing: 0) {
                        artworkArea(pageWidth: geometry.size.width)

                        titleAndActionsRow
                            .padding(.horizontal, 32)
                            .padding(.top, 20)
                            .padding(.bottom, 16)
                            .opacity(showsKaraoke ? 0 : 1)

                        // Hidden under an open panel: the glass is see-through.
                        PlayerLyricPreview(lines: syncedLyrics)
                            .opacity(showQueue || showLyrics ? 0 : 1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // No bottom padding: the panel covers the lyric line and the
                    // progress bar's touch area leaves the gap above its track.
                    .overlay {
                        playerPanel
                            .padding(.horizontal, 20)
                    }

                    // No top padding: the bar's touch area already leaves a gap
                    // above the track, and the lyric line belongs with it.
                    PlayerProgressSection()
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
            // An overlay, so its taller-than-screen size does not push the player down.
            // Sized and offset like the artwork, not with ignoresSafeArea: the safe
            // area shrinks while the player is pulled down and would slide the
            // animation away from the player.
            // A few points wider than the player on each side, so no edge of the
            // screen is left without the animation.
            .overlay(alignment: .top) {
                let sleepOverlaySize = CGSize(
                    width: geometry.size.width + 2 * Self.sleepOverlayBleed,
                    height: geometry.size.height + artworkTopInset
                )
                SleepEndedOverlay(size: sleepOverlaySize)
                    .frame(width: sleepOverlaySize.width, height: sleepOverlaySize.height)
                    .offset(y: -artworkTopInset)
            }
            .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.25), value: showQueue)
            .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.25), value: showLyrics)
            .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.25), value: showsKaraoke)
            .offset(y: pullDistance)
            .gesture(pullToDismiss(height: geometry.size.height))
            // Outside the pull offset; it is torn down with the player.
            .overlay {
                if showsFullscreenCover {
                    FullscreenCoverOverlay(
                        source: coverFrame.rect,
                        sourceCornerRadius: settings.playerStyle == .card ? Self.cardCoverRadius : 0,
                        fadesBottom: settings.playerStyle == .immersive,
                        onClosed: { showsFullscreenCover = false },
                        cover: { cover(for: $0) }
                    )
                }
            }
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
                artworkDragOffset = 0
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
            .interactiveDismissDisabled(showQueue || showLyrics || showsFullscreenCover)
            .background(
                // Artist and album links from the player open over it, as a sheet.
                Color.clear
                    .routerSheet()
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
            .glassEffect(showsKaraoke ? .identity : .regular, in: RoundedRectangle(cornerRadius: 24))
            .environment(\.colorScheme, .dark)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.95).combined(with: .opacity))
            .accessibilityAction(.escape) { closePanelOrPlayer() }
        }
    }

    // MARK: - Gestures

    private func pullToDismiss(height: CGFloat) -> PlayerDismissGesture {
        PlayerDismissGesture(isEnabled: !showQueue && !showLyrics && !showsFullscreenCover) { distance in
            pullDistance = max(0, distance)
        } onEnded: { distance, velocity in
            // Far enough (a fifth of the screen) or a quick flick closes it.
            if distance > height * 0.2 || (distance > 20 && velocity > 800) {
                onCollapse()
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { pullDistance = 0 }
            }
        }
    }

    /// The cover follows the finger, like the mini player's pages, and the
    /// neighbour's cover slides in from the edge.
    private func playerSwipe(pageWidth: CGFloat) -> PlayerTrackSwipeGesture {
        PlayerTrackSwipeGesture(
            isEnabled: !showQueue && !showLyrics && settings.artworkSwipeNavigation
        ) { translation in
            guard !isCommittingSwipe else { return }
            // No song on that side: the cover stretches a little and springs back.
            let hasNeighbour = translation < 0 ? np.hasNext : np.hasPrevious
            artworkDragOffset = hasNeighbour ? translation : translation / 4
        } onEnded: { predictedEnd in
            guard !isCommittingSwipe else { return }
            // Held past the threshold, or flicked hard enough to coast past it.
            if predictedEnd <= -pageWidth * TrackSwipe.commitFraction, np.hasNext {
                TrackSwipe.commit(.next, pageWidth: pageWidth, offset: $artworkDragOffset, isCommitting: $isCommittingSwipe)
            } else if predictedEnd >= pageWidth * TrackSwipe.commitFraction, np.hasPrevious {
                TrackSwipe.commit(.previous, pageWidth: pageWidth, offset: $artworkDragOffset, isCommitting: $isCommittingSwipe)
            } else {
                withAnimation(TrackSwipe.springBack) { artworkDragOffset = 0 }
            }
        }
    }

    /// Two fingers spreading on the cover open it full screen. Simultaneous,
    /// so the one-finger track swipe and pull-down are untouched.
    private var fullscreenCoverPinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard value.magnification > 1.25, !showsFullscreenCover, !showQueue, !showLyrics else { return }
                showsFullscreenCover = true
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
            syncedLyrics = []
            return
        }
        syncedLyrics = []
        guard let lines = try? await LyricsService.shared.fetchLyrics(videoId: videoId),
              !Task.isCancelled,
              np.videoId == videoId else { return }
        syncedLyrics = lines.filter {
            $0.startTime != nil &&
                !$0.text.trimmingCharacters(in: CharacterSet(charactersIn: "♪*· ")).isEmpty
        }
    }

    private var titleAndActionsRow: some View {
        HStack(alignment: .center) {
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
                PlayerLikeButton(isLiked: isLiked, flavor: currentLikeFlavor) {
                    guard let song = np.queueSongs.indices.contains(np.queueIndex) ? np.queueSongs[np.queueIndex] : nil else { return }
                    Task { await likeStore.toggle(song: song) }
                }

                if np.queueSongs.indices.contains(np.queueIndex) {
                    PlayerSongMenu(song: np.queueSongs[np.queueIndex], onCollapse: { onCollapse() })
                        .equatable()
                }
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
            AppRouter.shared.presentSheet(.artist(browseId: browseId))
        }
    }

    /// The space above the title, where the track swipe starts. The Card
    /// style's cover sits here; the Immersive cover is behind it.
    private func artworkArea(pageWidth: CGFloat) -> some View {
        Group {
            if settings.playerStyle == .card {
                GeometryReader { area in
                    artworkPager(pageSize: area.size)
                }
                .padding(.vertical, 12)
                .opacity(showsKaraoke ? 0 : 1)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(playerSwipe(pageWidth: pageWidth))
        .simultaneousGesture(fullscreenCoverPinch)
    }

    /// The current cover with the previous and next ones a page to each side,
    /// moved together by the track swipe.
    private func artworkPager(pageSize: CGSize) -> some View {
        ZStack {
            if let previous = np.previousSong {
                artworkPage(for: previous, size: pageSize)
                    .offset(x: -pageSize.width)
            }
            if let current = np.currentSong {
                artworkPage(for: current, size: pageSize)
                    // The full-screen copy lifts off from here; Reduce Motion fades it in over this one.
                    .opacity(showsFullscreenCover && !reduceMotion ? 0 : 1)
            }
            if let next = np.nextSong {
                artworkPage(for: next, size: pageSize)
                    .offset(x: pageSize.width)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { page in
            if settings.playerStyle == .card {
                let side = Self.cardCoverSide(in: page.size)
                coverFrame.rect = CGRect(x: page.midX - side / 2, y: page.midY - side / 2, width: side, height: side)
            } else {
                coverFrame.rect = page
            }
        }
        .offset(x: artworkDragOffset)
    }

    private static let cardCoverRadius: CGFloat = 16

    /// The Card cover is a square inset from the page's sides.
    private static func cardCoverSide(in size: CGSize) -> CGFloat {
        max(0, min(size.width - 64, size.height))
    }

    @ViewBuilder
    private func artworkPage(for song: SongItem, size: CGSize) -> some View {
        if settings.playerStyle == .card {
            let side = Self.cardCoverSide(in: size)
            cover(for: song)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: Self.cardCoverRadius, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                .frame(width: size.width, height: size.height)
        } else {
            cover(for: song)
                .frame(width: size.width, height: size.height)
                .clipped()
        }
    }

    /// The player's own artwork once it belongs to this song; until then,
    /// and for the neighbours, the cached cover the mini player shows.
    @ViewBuilder
    private func cover(for song: SongItem) -> some View {
        if song.videoId == np.thumbnailVideoId, let uiImage = np.thumbnailUIImage {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else {
            MiniArtworkView(song: song, placeholderIconSize: 64)
                .id(song.videoId)
        }
    }
}

private final class CoverFrameBox {
    var rect: CGRect = .zero
}

/// The current lyric line under the title. Its own view so only this line,
/// not the whole player, redraws as `currentTime` ticks.
private struct PlayerLyricPreview: View {
    let lines: [LyricLine]

    @Environment(SettingsStore.self) private var settings
    private let np = NowPlaying.shared

    private var activeLyricText: String? {
        guard let firstLine = lines.first else { return nil }
        let lyricTime = np.currentTime + settings.lyricsOffsetSeconds
        return lines.last { line in
            guard let startTime = line.startTime else { return false }
            return startTime <= lyricTime
        }?.text ?? firstLine.text
    }

    var body: some View {
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
                    .padding(.bottom, 2)
                    .accessibilityLabel("Current lyric: \(activeLyricText)")
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 33, alignment: .bottom)
        .allowsHitTesting(false)
    }
}

/// Progress bar and time labels. Its own view so only this part, not the
/// whole player, redraws as `currentTime` ticks.
private struct PlayerProgressSection: View {
    private let player = PlayerController.shared
    private let np = NowPlaying.shared
    @State private var editingProgress: Float = 0
    @State private var isEditingSlider = false

    var body: some View {
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

/// The full player's "⋯" menu. `.equatable()` skips the player's redraws
/// here, because a menu rebuilt while open flickers.
private struct PlayerSongMenu: View, Equatable {
    let song: SongItem
    let onCollapse: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.song.videoId == rhs.song.videoId
    }

    var body: some View {
        SongActionsMenu(song: song, showsQueueActions: false, showsSleepTimer: true, onNavigate: { AppRouter.shared.presentSheet($0) }) {
            PlayerOptionsGlyph()
        }
    }
}
