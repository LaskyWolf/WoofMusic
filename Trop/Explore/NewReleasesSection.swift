//
//  NewReleasesSection.swift
//  Trop
//

import SwiftUI

/// Explore's "New albums & singles" shelf: a rounded backdrop holding
/// portrait cards tinted with each album's own artwork colours.
struct NewReleasesSection: View {
    let section: ExploreSection
    /// Release kind per album browseId ("Single", "Album", "EP").
    let kinds: [String: String]
    var onOpen: (YTItem) -> Void

    static let backdropRadius: CGFloat = 22
    static let inset: CGFloat = 12
    static let cardSpacing: CGFloat = 10

    private var albums: [AlbumItem] {
        section.items.compactMap { item in
            if case .album(let album) = item { return album }
            return nil
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.backdropRadius, style: .continuous)
        VStack(alignment: .leading, spacing: Self.inset) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New albums and singles")
                    .font(.title3.bold())
                Text("Fresh this week")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Self.inset + 2)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Self.cardSpacing) {
                    ForEach(albums, id: \.browseId) { album in
                        NewReleaseCard(album: album, kind: kinds[album.browseId]) {
                            onOpen(.album(album))
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, Self.inset, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
        }
        .padding(.top, Self.inset + 2)
        .padding(.bottom, Self.inset)
        .background(shape.fill(Color(.secondarySystemBackground)))
        // Cards scrolling past the edge stay inside the rounded corners.
        .clipShape(shape)
        .padding(.horizontal, DesignTokens.screenHPadding)
        .padding(.bottom, DesignTokens.sectionGap)
    }
}

// MARK: - Playback

/// Which album the new releases cards started, so a card can tell the queue
/// still holds its album even when album tracks carry no `albumId`.
@MainActor
enum NewReleasePlayback {
    /// Not observed: cards re-render through the `NowPlaying` reads in `isCurrent`.
    static var started: (browseId: String, videoIds: Set<String>)?

    /// True while the current song belongs to the album `browseId`.
    static func isCurrent(_ browseId: String) -> Bool {
        let np = NowPlaying.shared
        guard let videoId = np.videoId else { return false }
        if let started, started.browseId == browseId, started.videoIds.contains(videoId) { return true }
        return np.queueSongs.indices.contains(np.queueIndex)
            && np.queueSongs[np.queueIndex].videoId == videoId
            && np.queueSongs[np.queueIndex].albumId == browseId
    }
}

/// Artwork colours per album browseId, kept for the session so scrolling back
/// doesn't flash the neutral background again.
@MainActor
private enum ReleaseColors {
    // ponytail: unbounded, fine for one shelf; add eviction if other shelves use it.
    static var cache: [String: [Color]] = [:]
}

// MARK: - Card

/// Portrait card: cover with a vinyl disc behind it, kind/year, title, artist,
/// then Play and Save. The disc slides out and spins while the album plays.
struct NewReleaseCard: View {
    let album: AlbumItem
    let kind: String?
    var onOpen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var colors: [Color]?
    /// Loads the album only when Play or Save needs its songs.
    @State private var model: AlbumDetailViewModel
    @State private var isStarting = false
    /// The disc is out while this album plays; it goes back in for a moment on
    /// every song change, like swapping records, and stays in once another album plays.
    @State private var discOut = false
    /// Turns on only once a start has taken longer than `PlayPauseGlyph.spinnerDelay`.
    @State private var showsSpinner = false

    static let size = CGSize(width: 150, height: 255)
    static let radius: CGFloat = 18
    static let inset: CGFloat = 12
    static let coverSize = DesignTokens.artMedium
    static let discSize = coverSize - 4
    /// How far the disc slides out from behind the cover while playing.
    static let discSlide: CGFloat = 20

    init(album: AlbumItem, kind: String?, onOpen: @escaping () -> Void) {
        self.album = album
        self.kind = kind
        self.onOpen = onOpen
        _colors = State(initialValue: ReleaseColors.cache[album.browseId])
        _model = State(initialValue: AlbumDetailViewModel(browseId: album.browseId))
    }

    private var np: NowPlaying { NowPlaying.shared }

    private var artistLine: String {
        album.artists.map(\.name).joined(separator: ", ")
    }

    /// "Single", "Album · 2026".
    private var meta: String? {
        let parts = [kind, album.year.map { String($0) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        let isCurrent = NewReleasePlayback.isCurrent(album.browseId)
        let isPlaying = isCurrent && np.isPlaying

        VStack(alignment: .leading, spacing: 0) {
            info(isCurrent: isCurrent, spinning: isPlaying && !reduceMotion)
            Spacer(minLength: 8)
            buttons(isPlaying: isPlaying)
        }
        .padding(Self.inset)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(background)
        .clipShape(shape)
        .contentShape(shape)
        .contentShape(.contextMenuPreview, shape)
        // The buttons take their own taps; anywhere else opens the album.
        .onTapGesture(perform: onOpen)
        .cardMenu(for: .album(album))
        // The fixed card height holds the text up to this size.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .contain)
        .task(id: album.browseId) {
            await model.refreshSavedState()
            await loadColors()
        }
        .onAppear { discOut = isCurrent }
        .onChange(of: isCurrent) { _, current in discOut = current }
        .task(id: np.videoId) {
            guard discOut else { return }
            discOut = false
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            discOut = NewReleasePlayback.isCurrent(album.browseId)
        }
    }

    // MARK: Parts

    private func info(isCurrent: Bool, spinning: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ZStack {
                VinylDisc(size: Self.discSize, label: colors?.first ?? Color(white: 0.45), spinning: spinning)
                    .offset(x: discOut ? Self.discSlide : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.72), value: discOut)
                AsyncImageView(url: album.thumbnailUrl)
                    .frame(width: Self.coverSize, height: Self.coverSize)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    // Explore opens it through YTItemRouter, so the same route.
                    .coverZoomSource(YTItemRouter.detailRoute(for: .album(album)))
                    .shadow(color: .black.opacity(0.35), radius: 6, x: 2, y: 4)
            }
            .frame(width: Self.coverSize, height: Self.coverSize)
            .padding(.bottom, 8)

            if let meta {
                Text(meta)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            Text(album.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if !artistLine.isEmpty {
                Text(artistLine)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([album.title, artistLine, kind ?? "Album"].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
    }

    /// Icon-only round buttons on the trailing side: Save, then Play.
    private func buttons(isPlaying: Bool) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            Button {
                Task { await toggleSave() }
            } label: {
                roundIcon(model.isSaved ? "bookmark.fill" : "bookmark",
                          fill: .white.opacity(0.18), foreground: .white, isBusy: false)
            }
            .accessibilityLabel(model.isSaved ? "Remove from Library" : "Save to Library")

            Button(action: playTapped) {
                roundIcon(isPlaying ? "pause.fill" : "play.fill",
                          fill: .white, foreground: .black, isBusy: showsSpinner)
            }
            .disabled(isStarting)
            .task(id: isStarting) {
                guard isStarting else { showsSpinner = false; return }
                try? await Task.sleep(for: PlayPauseGlyph.spinnerDelay)
                if !Task.isCancelled { showsSpinner = true }
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
        }
        .buttonStyle(ZoomPressStyle(scale: 0.92))
    }

    static let buttonSize: CGFloat = 38

    private func roundIcon(_ systemImage: String, fill: Color, foreground: Color, isBusy: Bool) -> some View {
        ZStack {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(foreground)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .foregroundStyle(foreground)
        .frame(width: Self.buttonSize, height: Self.buttonSize)
        .background(Circle().fill(fill))
        .contentShape(Circle())
    }

    /// Neutral grey until the artwork colours are ready, then the album's
    /// gradient fades in. The bottom shade keeps white text legible on light art.
    private var background: some View {
        ZStack {
            Color(white: 0.22)
            if let colors, let first = colors.first, let last = colors.last {
                LinearGradient(
                    colors: [first.mix(with: .black, by: 0.1), last.mix(with: .black, by: 0.45)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .transition(.opacity)
            }
            LinearGradient(
                stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.4), location: 1)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: Actions

    /// This album playing → pause/resume; otherwise start the album.
    private func playTapped() {
        if NewReleasePlayback.isCurrent(album.browseId) {
            PlayerController.shared.togglePlayPause()
            return
        }
        Task {
            isStarting = true
            defer { isStarting = false }
            if model.album == nil { await model.load() }
            guard let songs = model.album?.songs, !songs.isEmpty else { return }
            NewReleasePlayback.started = (album.browseId, Set(songs.map(\.videoId)))
            PlaybackQueue.play(songs, log: Log.explore, context: "Playing new release \(album.title)")
        }
    }

    /// Same save as the album page's "Save to Library", which needs the album loaded.
    private func toggleSave() async {
        if model.album == nil { await model.load() }
        await model.toggleSave()
    }

    private func loadColors() async {
        guard colors == nil,
              let url = album.thumbnailUrl.flatMap({ URL(string: $0) }),
              let image = try? await ArtworkLoader.image(for: url) else { return }
        let extracted = await Task.detached(priority: .utility) { image.extractDominantColors() }.value
        ReleaseColors.cache[album.browseId] = extracted
        withAnimation(.easeInOut(duration: 0.4)) { colors = extracted }
    }
}

// MARK: - Vinyl

/// Black record with fine grooves and a label in the album colour. Spins at
/// 33⅓ rpm while `spinning`; the sheen stays still, like light on a real record.
private struct VinylDisc: View {
    let size: CGFloat
    let label: Color
    let spinning: Bool

    var body: some View {
        TimelineView(.animation(paused: !spinning)) { context in
            record
                .rotationEffect(.degrees(Self.angle(at: context.date)))
        }
        .overlay {
            Circle()
                .fill(AngularGradient(
                    colors: [.clear, .white.opacity(0.1), .clear, .clear, .white.opacity(0.06), .clear],
                    center: .center
                ))
                .allowsHitTesting(false)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.35), radius: 4, x: 1, y: 3)
        .accessibilityHidden(true)
    }

    private var record: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [Color(white: 0.14), Color(white: 0.04)],
                    center: .center,
                    startRadius: size * 0.18,
                    endRadius: size / 2
                ))
            ForEach(1..<7, id: \.self) { ring in
                Circle()
                    .stroke(.white.opacity(0.07), lineWidth: 0.5)
                    .frame(width: size * (0.42 + CGFloat(ring) * 0.09))
            }
            Circle()
                .fill(label)
                .frame(width: size * 0.36)
            // Off-centre mark, so the spin shows on the round grooves.
            Capsule()
                .fill(.white.opacity(0.55))
                .frame(width: size * 0.09, height: 2)
                .offset(x: size * 0.09)
            Circle()
                .fill(.black)
                .frame(width: 4, height: 4)
        }
        .frame(width: size, height: size)
    }

    /// 33⅓ rpm = 200° per second.
    private static func angle(at date: Date) -> Double {
        (date.timeIntervalSinceReferenceDate * 200).truncatingRemainder(dividingBy: 360)
    }
}

// MARK: - Skeleton

/// Loading placeholder for `NewReleasesSection`: the backdrop, title lines
/// and two portrait cards.
struct NewReleasesSkeleton: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NewReleasesSection.backdropRadius, style: .continuous)
        VStack(alignment: .leading, spacing: NewReleasesSection.inset) {
            VStack(alignment: .leading, spacing: 6) {
                ShimmerBlock(width: 200, height: 20, radius: 6)
                ShimmerBlock(width: 100, height: 12, radius: 4)
            }
            .padding(.horizontal, NewReleasesSection.inset + 2)
            HStack(spacing: NewReleasesSection.cardSpacing) {
                ForEach(0..<2, id: \.self) { _ in
                    ShimmerBlock(
                        width: NewReleaseCard.size.width,
                        height: NewReleaseCard.size.height,
                        radius: NewReleaseCard.radius
                    )
                }
            }
            .padding(.horizontal, NewReleasesSection.inset)
        }
        .padding(.top, NewReleasesSection.inset + 2)
        .padding(.bottom, NewReleasesSection.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Color(.secondarySystemBackground)))
        .clipShape(shape)
        .padding(.horizontal, DesignTokens.screenHPadding)
        .padding(.bottom, DesignTokens.sectionGap)
    }
}
