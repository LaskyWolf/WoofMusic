//
//  MiniPlayerBarView.swift
//  Trop
//
//  Created by 686udjie on 18/07/2026.
//

import SwiftUI
import Nuke

/// The mini player bar, hosted as the TabView's native bottom accessory.
/// Swiping left/right pages through the queue with the artwork and text sliding
/// together, exactly tracking the drag state. When the tab bar minimizes on
/// scroll the bar collapses into a compact inline form that merges with the
/// tab bar, matching the Apple Music behavior; otherwise it renders as the
/// 48pt floating glass capsule with a bottom progress line.
struct MiniPlayerBarView: View {
    let onExpand: () -> Void
    var isTransitioning = false

    @Environment(MiniPlayerScrollState.self) private var scrollState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let player = PlayerController.shared
    @Bindable private var np = NowPlaying.shared

    @State private var dragOffset: CGFloat = 0
    @State private var dragAxis: DragAxis?
    @State private var isCommitting = false

    private enum DragAxis {
        case horizontal
        case vertical
    }

    private var isInline: Bool {
        scrollState.isInline
    }

    private var barHeight: CGFloat {
        48
    }

    private var artworkSize: CGFloat {
        30
    }

    private var isDarkMode: Bool {
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
           let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
            return window.traitCollection.userInterfaceStyle == .dark
        }
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first {
            return window.traitCollection.userInterfaceStyle == .dark
        }
        return colorScheme == .dark
    }

    private var titleColor: Color {
        isDarkMode ? .white : .black
    }

    private var artistColor: Color {
        isDarkMode ? Color.white.opacity(0.85) : Color.black.opacity(0.80)
    }

    var body: some View {
        HStack(spacing: 0) {
            pagingArea
            playPauseButton
                .padding(.trailing, 8)
        }
        .frame(height: barHeight)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { MiniPlayerProgressLine() }
        .clipShape(Capsule())
        .onChange(of: np.videoId) { _, _ in
            dragOffset = 0
            preloadLyrics()
        }
        .onChange(of: np.queueSongs.count) { _, _ in
            dragOffset = 0
            np.preloadNeighborArtwork()
        }
        .onChange(of: np.queueIndex) { _, _ in
            dragOffset = 0
            np.preloadNeighborArtwork()
        }
        .task { np.preloadNeighborArtwork() }
    }

    private func preloadLyrics() {
        guard let id = np.videoId else { return }
        let upcoming = np.upcomingSongs(prefixLimit: 3).map(\.videoId)
        Task { await LyricsService.shared.preload(videoId: id, upcoming: upcoming) }
    }

    // MARK: - Paging area

    private var pagingArea: some View {
        GeometryReader { geo in
            let pageWidth = geo.size.width
            ZStack(alignment: .center) {
                if let prev = np.previousSong {
                    page(for: prev, width: pageWidth)
                        .offset(x: -pageWidth)
                }
                if let current = np.currentSong {
                    page(for: current, width: pageWidth)
                }
                if let next = np.nextSong {
                    page(for: next, width: pageWidth)
                        .offset(x: pageWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .offset(x: dragOffset)
            .clipped()
            .contentShape(Rectangle())
            .gesture(dragGesture(pageWidth: pageWidth))
            .onTapGesture { onExpand() }
        }
        .frame(height: barHeight)
    }

    private func page(for song: SongItem, width: CGFloat) -> some View {
        HStack(spacing: 8) {
            barArtwork(for: song)

            VStack(alignment: .leading, spacing: 0) {
                if isInline || reduceMotion {
                    Text(song.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(titleColor)
                } else {
                    MarqueeText(
                        text: song.title,
                        font: .system(size: 13, weight: .semibold),
                        frameHeight: 16,
                        textColor: titleColor,
                        // Neighbor pages sit off screen; only the current title scrolls.
                        isPaused: isTransitioning || song.videoId != np.currentSong?.videoId
                    )
                }

                Text(artistLine(for: song))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(artistColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(width: width, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
    }

    private func barArtwork(for song: SongItem) -> some View {
        // Every page, the current one too, shows the same cached cover, so the
        // cover doesn't change when a swipe makes a neighbour current.
        MiniArtworkView(song: song)
            .id(song.videoId)
        .frame(width: artworkSize, height: artworkSize)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var playPauseButton: some View {
        Button(action: { player.togglePlayPause() }, label: {
            PlayPauseGlyph(isPlaying: np.isPlaying, size: 17)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        })
        .accessibilityLabel(np.isPlaying ? "Pause" : "Play")
    }

    // MARK: - Data

    /// Artist line for a queued song, falling back to the resolved author
    /// (what the big player shows via `displayArtist`) when the queued item
    /// carries no artist runs — e.g. videos or cache-repaired songs.
    private func artistLine(for song: SongItem) -> String {
        let own = artistDisplayString(from: song.artists)
        if !own.isEmpty { return own }
        if song.videoId == np.videoId { return np.displayArtist }
        return own
    }

    // MARK: - Gesture

    private func dragGesture(pageWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                guard !isCommitting else { return }
                if dragAxis == nil {
                    dragAxis = abs(value.translation.width) > abs(value.translation.height)
                        ? .horizontal
                        : .vertical
                }
                guard dragAxis == .horizontal else { return }

                let minOffset = np.hasNext ? -pageWidth : 0
                let maxOffset = np.hasPrevious ? pageWidth : 0
                dragOffset = min(max(value.translation.width, minOffset), maxOffset)
            }
            .onEnded { value in
                guard !isCommitting else { return }
                defer { dragAxis = nil }

                switch dragAxis {
                case .horizontal:
                    if dragOffset <= -pageWidth * TrackSwipe.commitFraction, np.hasNext {
                        TrackSwipe.commit(.next, pageWidth: pageWidth, offset: $dragOffset, isCommitting: $isCommitting)
                    } else if dragOffset >= pageWidth * TrackSwipe.commitFraction, np.hasPrevious {
                        TrackSwipe.commit(.previous, pageWidth: pageWidth, offset: $dragOffset, isCommitting: $isCommitting)
                    } else {
                        withAnimation(TrackSwipe.springBack) {
                            dragOffset = 0
                        }
                    }
                case .vertical:
                    if value.translation.height < -40 {
                        onExpand()
                    }
                case nil:
                    break
                }
            }
    }
}

/// The bottom progress line. Its own view so only the line, not the whole bar,
/// redraws as playback advances.
private struct MiniPlayerProgressLine: View {
    private let np = NowPlaying.shared

    var body: some View {
        GeometryReader { geo in
            let progressWidth = max(0, min(geo.size.width, geo.size.width * CGFloat(np.progress)))
            Rectangle()
                .fill(.tint)
                .frame(width: progressWidth, height: 2)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}

// MARK: - Per-song artwork (memory-cache fast path)

/// The cover NowPlaying loads first for a song: its own artwork at player
/// resolution, else the ytimg default.
@MainActor
private func miniArtworkURL(for song: SongItem) -> URL? {
    URL(string: ArtworkURLs.highRes(song.thumbnailUrl) ?? NowPlaying.artworkURL(for: song.videoId))
}

/// A queued song's cover. The full player's swipe pages use it too, so both
/// players show the same cached cover for a neighbour.
@MainActor
struct MiniArtworkView: View {
    let song: SongItem
    let placeholderIconSize: CGFloat

    @State private var uiImage: UIImage?

    init(song: SongItem, placeholderIconSize: CGFloat = 20) {
        self.song = song
        self.placeholderIconSize = placeholderIconSize
        // Seeded here, not on appear, so a cached cover is there on the first frame.
        // The player's own image covers songs whose cover isn't cached under this URL
        // (downloads with embedded art), but only once it belongs to this song.
        let np = NowPlaying.shared
        _uiImage = State(initialValue: cachedArtwork(for: song)
            ?? (np.thumbnailVideoId == song.videoId ? np.thumbnailUIImage : nil))
    }

    var body: some View {
        ZStack {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.12)
                Image(systemName: "music.note")
                    .font(.system(size: placeholderIconSize))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard uiImage == nil, let url = miniArtworkURL(for: song) else { return }
        do {
            let image = try await ArtworkLoader.image(for: url)
            uiImage = image.centerCroppedSquare()
        } catch {
            Log.nowPlaying.error("Mini artwork load failed: \(error)")
        }
    }
}

@MainActor
private func cachedArtwork(for song: SongItem) -> UIImage? {
    guard let url = miniArtworkURL(for: song) else { return nil }
    return ArtworkLoader.cachedImage(for: url)?.centerCroppedSquare()
}
