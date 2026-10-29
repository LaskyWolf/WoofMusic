//
//  LyricShareCard.swift
//  Trop
//

import SwiftUI

/// Lyric share card composer for the current song: pick up to four lines,
/// preview the Sticker card, share it as a 1080×1920 image.
struct LyricShareComposer: View {
    static let maxLines = 4

    private let videoId: String
    private let title: String
    private let artist: String
    private let cover: UIImage?
    private let colors: [Color]
    private let songLink: String?

    @State private var lines: [LyricLine]
    @State private var isLoading: Bool
    @State private var selected: Set<LyricLine.ID>
    @State private var rendered: UIImage?
    @State private var showsPreview = false
    /// Bumped when a tap would pick a fifth line: haptic plus a shake of the counter.
    @State private var shakeTrigger = 0

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `lines` empty: the lines come from the lyrics cache and the line
    /// playing now is ticked.
    init(videoId: String, lines: [LyricLine] = [], initialLineID: LyricLine.ID? = nil) {
        // Snapshot of the song, so a track change while the sheet is open
        // doesn't swap the cover under the picked lines.
        let np = NowPlaying.shared
        self.videoId = videoId
        title = np.title
        artist = np.displayArtist
        cover = np.thumbnailVideoId == videoId ? np.thumbnailUIImage : nil
        colors = np.dominantColors
        songLink = np.currentSong.flatMap { $0.videoId == videoId ? $0.webUrl : nil }
        _lines = State(initialValue: lines)
        _isLoading = State(initialValue: lines.isEmpty)
        var initial: Set<LyricLine.ID> = []
        if let initialLineID { initial.insert(initialLineID) }
        _selected = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            pickStep
                .navigationTitle("Share Card")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .principal) {
                        counter
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Next") {
                            rendered = renderCard()
                            showsPreview = rendered != nil
                        }
                        .disabled(selected.isEmpty)
                    }
                }
                .navigationDestination(isPresented: $showsPreview) {
                    previewStep
                }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: shakeTrigger)
        .appSheetChrome([.large])
        .task { await loadLinesIfNeeded() }
    }

    // MARK: - Step 1: pick lines

    @ViewBuilder
    private var pickStep: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if lines.isEmpty {
            ContentUnavailableView("No Lyrics", systemImage: "text.alignleft",
                                   description: Text("Lyrics are unavailable for this song."))
        } else {
            ScrollViewReader { proxy in
                List(lines) { line in
                    let isOn = selected.contains(line.id)
                    Button { toggle(line) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                .accessibilityHidden(true)
                            Text(line.text)
                                .font(.body.weight(isOn ? .semibold : .regular))
                                .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(line.text)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .id(line.id)
                }
                .listStyle(.plain)
                .onAppear {
                    if let first = lines.first(where: { selected.contains($0.id) }) {
                        proxy.scrollTo(first.id, anchor: .center)
                    }
                }
            }
        }
    }

    private var counter: some View {
        Text("\(selected.count)/\(Self.maxLines)")
            .font(.headline.monospacedDigit())
            .keyframeAnimator(initialValue: ShakeMotion(), trigger: shakeTrigger) { content, motion in
                content.offset(x: reduceMotion ? 0 : motion.x)
            } keyframes: { _ in
                KeyframeTrack(\.x) {
                    LinearKeyframe(-8.0, duration: 0.05)
                    LinearKeyframe(8.0, duration: 0.08)
                    LinearKeyframe(-5.0, duration: 0.07)
                    LinearKeyframe(3.0, duration: 0.06)
                    SpringKeyframe(0.0, duration: 0.2)
                }
            }
            .accessibilityLabel("\(selected.count) of \(Self.maxLines) lines selected")
    }

    private func toggle(_ line: LyricLine) {
        if selected.contains(line.id) {
            selected.remove(line.id)
            return
        }
        guard selected.count < Self.maxLines else {
            shakeTrigger += 1
            UIAccessibility.post(notification: .announcement, argument: "Up to \(Self.maxLines) lines")
            return
        }
        selected.insert(line.id)
    }

    // MARK: - Step 2: preview and share

    @ViewBuilder
    private var previewStep: some View {
        VStack(spacing: 20) {
            if let rendered {
                let image = Image(uiImage: rendered)
                image
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
                    .frame(maxHeight: .infinity)
                    .accessibilityLabel("Share card: \(pickedTexts.joined(separator: ", ")), \(title) by \(artist)")

                // ShareLink needs one item type, so the song link rides along as the message.
                ShareLink(
                    item: image,
                    message: songLink.map { Text(verbatim: $0) },
                    preview: SharePreview(title, image: image)
                ) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Picked lines in lyric order, not tap order, so the card reads like the song.
    private var pickedTexts: [String] {
        lines.filter { selected.contains($0.id) }.map(\.text)
    }

    /// ImageRenderer can't wait for async images; the cover is already a loaded UIImage.
    private func renderCard() -> UIImage? {
        let renderer = ImageRenderer(content: LyricStickerCard(
            lines: pickedTexts, title: title, artist: artist, cover: cover, colors: colors
        ))
        // 360×640 pt at 3× is 1080×1920 px.
        renderer.scale = 1080 / LyricStickerCard.size.width
        return renderer.uiImage
    }

    // MARK: - Data

    /// From the menu: lines from the lyrics cache (no new lookup when the
    /// song's lyrics are already loaded), with the line playing now ticked.
    private func loadLinesIfNeeded() async {
        guard isLoading else { return }
        defer { isLoading = false }
        guard let fetched = try? await LyricsService.shared.fetchLyrics(videoId: videoId) else { return }
        let shown = fetched.filter {
            !$0.text.trimmingCharacters(in: CharacterSet(charactersIn: "♪*· ")).isEmpty
        }
        lines = shown
        guard selected.isEmpty else { return }
        let t = NowPlaying.shared.currentTime + SettingsStore.shared.lyricsOffsetSeconds
        if let current = shown.last(where: { ($0.startTime ?? .infinity) <= t }) {
            selected.insert(current.id)
        }
    }
}

private struct ShakeMotion {
    /// Points right of rest.
    var x = 0.0
}

// MARK: - Sticker card

/// The 9:16 card: cover colours as background, the cover as a taped
/// polaroid with title and artist written on it, lines as paper labels.
/// Paper stays light with dark ink on any cover, so text contrast never
/// depends on the artwork.
struct LyricStickerCard: View {
    let lines: [String]
    let title: String
    let artist: String
    let cover: UIImage?
    let colors: [Color]

    static let size = CGSize(width: 360, height: 640)
    private static let paper = Color(red: 1, green: 0.98, blue: 0.94)
    private static let ink = Color(red: 0.11, green: 0.08, blue: 0.13)
    private static let coverSide: CGFloat = 184

    var body: some View {
        VStack(spacing: 0) {
            polaroid
                .padding(.top, 52)
            Spacer(minLength: 20)
            labels
                .layoutPriority(1)
            Spacer(minLength: 20)
            footer
                .padding(.bottom, 30)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(background)
        .clipped()
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: colors.count > 1 ? colors : colors + colors,
                           startPoint: .top, endPoint: .bottom)
            // Darker toward the bottom, so the paper labels stand out on light covers too.
            LinearGradient(colors: [.clear, .black.opacity(0.25)], startPoint: .top, endPoint: .bottom)
        }
    }

    private var polaroid: some View {
        VStack(spacing: 10) {
            coverImage
                .frame(width: Self.coverSide, height: Self.coverSide)
                .clipped()
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text(artist)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .opacity(0.65)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(Self.ink)
            .frame(width: Self.coverSide)
        }
        .padding([.horizontal, .top], 11)
        .padding(.bottom, 14)
        .background(Color.white)
        .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
        .overlay(alignment: .top) {
            // Translucent tape holding the photo on.
            Rectangle()
                .fill(Color.white.opacity(0.55))
                .frame(width: 92, height: 26)
                .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                .rotationEffect(.degrees(3))
                .offset(y: -13)
        }
        .rotationEffect(.degrees(-5))
    }

    @ViewBuilder
    private var coverImage: some View {
        if let cover {
            Image(uiImage: cover)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: colors.count > 1 ? colors : colors + colors,
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private var labels: some View {
        // ponytail: fixed sizes for 1–2 vs 3–4 lines; very long lines shrink via minimumScaleFactor.
        let fontSize: CGFloat = lines.count <= 2 ? 21 : 17
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                let isEven = index.isMultiple(of: 2)
                Text(line)
                    .font(.system(size: fontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(Self.ink)
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Self.paper, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 0, y: 2)
                    .rotationEffect(.degrees(isEven ? -1.5 : 1.5))
                    .padding(.leading, isEven ? 0 : 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
    }

    private var footer: some View {
        Text("🐾 Woof Music")
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(Self.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Self.paper.opacity(0.9), in: Capsule())
    }
}

// MARK: - Song share

/// The song menu's Share: the Sticker card without lines, shared as an image
/// with the song link as its message, or the link on its own.
struct SongShareSheet: View {
    let song: SongItem

    @Environment(\.dismiss) private var dismiss
    @State private var rendered: UIImage?
    @State private var didFail = false

    private var link: URL? { URL(string: song.webUrl) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let rendered {
                    let image = Image(uiImage: rendered)
                    image
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
                        .frame(maxHeight: .infinity)
                        .accessibilityLabel("Share card: \(song.title) by \(song.artistNamesDisplay)")
                        .padding(.bottom, 8)

                    ShareLink(
                        item: image,
                        message: link.map { Text(verbatim: $0.absoluteString) },
                        preview: SharePreview(song.title, image: image)
                    ) {
                        Label("Share Card", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else if didFail {
                    ContentUnavailableView("Card unavailable", systemImage: "photo", description: Text("The cover couldn't be loaded."))
                } else {
                    ProgressView()
                        .frame(maxHeight: .infinity)
                }

                if let link {
                    ShareLink(item: link) {
                        Label("Share Link Only", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .navigationTitle("Share Song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task { await render() }
    }

    /// ImageRenderer can't wait for async images, so the cover is loaded first.
    private func render() async {
        let address = song.thumbnailUrl.map { ArtworkURLs.highRes($0) ?? $0 }
        guard let url = address.flatMap(URL.init(string:)),
              let cover = try? await ArtworkLoader.image(for: url) else {
            didFail = true
            return
        }
        let colors = await Task.detached(priority: .userInitiated) { cover.extractDominantColors() }.value
        let renderer = ImageRenderer(content: LyricStickerCard(
            lines: [], title: SongTitle.display(song.title), artist: song.artistNamesDisplay, cover: cover, colors: colors
        ))
        renderer.scale = 1080 / LyricStickerCard.size.width
        rendered = renderer.uiImage
        didFail = rendered == nil
    }
}
