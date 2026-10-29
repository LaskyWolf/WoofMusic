//
//  LyricShareCard.swift
//  Trop
//

import SwiftUI

/// Lyric share card composer for the current song: pick up to four lines,
/// then style and share the card in `ShareCardStudio`.
struct LyricShareComposer: View {
    static let maxLines = 4

    private let videoId: String
    private let title: String
    private let artist: String
    private let cover: UIImage?
    private let colors: [Color]

    @State private var lines: [LyricLine]
    @State private var isLoading: Bool
    @State private var selected: Set<LyricLine.ID>
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
                        Button("Next") { showsPreview = true }
                        .disabled(selected.isEmpty)
                    }
                }
                .navigationDestination(isPresented: $showsPreview) {
                    ShareCardStudio(content: cardContent)
                        .navigationTitle("Style")
                        .navigationBarTitleDisplayMode(.inline)
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

    // MARK: - Step 2: style and share

    private var cardContent: ShareCardContent {
        let picked = lines.filter { selected.contains($0.id) }
        return ShareCardContent(
            lines: picked.map(\.text), title: title, artist: artist, cover: cover, colors: colors,
            startTime: picked.first?.startTime, videoId: videoId
        )
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

// MARK: - Song share

/// The song menu's Share: the share card studio without lines.
struct SongShareSheet: View {
    let song: SongItem

    @Environment(\.dismiss) private var dismiss
    @State private var content: ShareCardContent?

    var body: some View {
        NavigationStack {
            Group {
                if let content {
                    ShareCardStudio(content: content)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Share Song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .appSheetChrome([.large])
        .task { await load() }
    }

    /// ImageRenderer can't wait for async images, so the cover is loaded first.
    /// Without it the card shows a note on the cover's colours.
    private func load() async {
        let address = song.thumbnailUrl.map { ArtworkURLs.highRes($0) ?? $0 }
        var loaded: UIImage?
        if let url = address.flatMap(URL.init(string:)) {
            loaded = try? await ArtworkLoader.image(for: url)
        }
        let cover = loaded
        let colors = await Task.detached(priority: .userInitiated) { cover?.extractDominantColors() ?? [] }.value
        content = ShareCardContent(
            lines: [], title: SongTitle.display(song.title), artist: song.artistNamesDisplay,
            cover: cover, colors: colors, startTime: nil, videoId: song.videoId
        )
    }
}
