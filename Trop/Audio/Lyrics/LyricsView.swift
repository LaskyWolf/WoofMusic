//
//  LyricsView.swift
//  Trop
//
//  Created by 686udjie on 16/07/2026.
//

import SwiftUI
import Translation

struct LyricsView: View {
    /// Point size of a lyric line.
    static let lineFontSize: Double = 26
    private let np = NowPlaying.shared
    private let player = PlayerController.shared
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var showLyrics: Bool
    @AppStorage(LyricsState.karaokeEnabledKey) private var karaokeEnabled = false

    @State private var lines: [LyricLine] = []
    @State private var isLoading = true
    @State private var activeIndex: Int = 0
    @State private var instrumentalGaps: [InstrumentalGap] = []
    @State private var romanizedLines: [String?] = []
    /// On-device translations, per line, filled by the 文A button.
    @State private var aiTranslations: [UUID: String] = [:]
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var isTranslating = false
    @State private var translationFailed = false

    struct InstrumentalGap {
        let afterIndex: Int
        let start: TimeInterval
        let end: TimeInterval
    }

    // MARK: - Auto-scroll & Re-sync

    @State private var isAutoScrollEnabled = true
    @State private var userHasScrolled = false
    @State private var hasPositionedInitialLyrics = false
    @State private var scrollProxy: ScrollViewProxy?
    @State private var loadGeneration = 0

    /// Karaoke runs only on lyrics with word timing; then the panel's own
    /// chrome (title, provider caption) steps aside.
    private var isKaraoke: Bool { karaokeEnabled && LyricsState.shared.hasWordTiming }

    /// Bumped on each karaoke start; the lines cascade in from below.
    @State private var cascadeTrigger = 0
    /// Karaoke started before the lines loaded: they cascade when they arrive.
    @State private var cascadePending = false
    /// The long-pressed line the share card composer opens with.
    @State private var shareCardLine: LyricLine?
    /// 0 → 1 on every entrance: the visible lines blur in and rise, staggered.
    @State private var entranceProgress: Double = 0
    /// Fades the whole list out and back in when the track changes.
    @State private var trackFade: Double = 1

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            lyricsBody
                .layoutPriority(1)
                .overlay(alignment: .bottom) { translationButtons }
        }
        .background { LyricsTimeTracker(onTimeChange: updateActiveLine) }
        .onAppear {
            if isKaraoke { karaokeDidChange() }
            runEntrance()
        }
        .onChange(of: np.videoId) { _, _ in
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.16)) { trackFade = 0 }
            Task {
                try? await Task.sleep(for: .milliseconds(170))
                runEntrance()
                withAnimation(.smooth(duration: 0.42)) { trackFade = 1 }
            }
        }
        .onChange(of: isKaraoke) { _, _ in karaokeDidChange() }
        .onChange(of: lines.isEmpty) { _, isEmpty in
            guard !isEmpty, cascadePending else { return }
            cascadePending = false
            cascadeTrigger += 1
        }
        .task(id: np.videoId) { await loadLyrics() }
        .translationTask(translationConfig) { session in
            await translateAll(with: session)
        }
        .onChange(of: lines.count) { _, _ in
            // A cached translation costs nothing, so show it without a tap.
            if aiTranslations.isEmpty,
               let cached = LyricsTranslation.cached(videoId: np.videoId ?? "", lines: lines) {
                aiTranslations = cached
            }
        }
        .onChange(of: LyricsOffset.effective(for: np.videoId)) { _, _ in updateActiveLine() }
        .onChange(of: settings.romanizeCurrentTrack) { _, _ in
            Task { await rebuildRomanization() }
        }
        .onChange(of: LyricsState.shared.refreshToken) { _, _ in
            Task { await loadLyrics() }
        }
        .sheet(item: $shareCardLine) { line in
            LyricShareComposer(videoId: np.videoId ?? "", lines: lines, initialLineID: line.id)
        }
    }

    /// Karaoke turned on (menu toggle, word-timed lyrics arriving, or the
    /// panel opening with it on) or off. Closing the panel removes this view,
    /// so closing from karaoke shows no goodbye.
    private func karaokeDidChange() {
        guard !reduceMotion else { return }
        LyricsState.shared.karaokeGreetingIsOn = isKaraoke
        LyricsState.shared.karaokeGreeting += 1
        if !isKaraoke {
            cascadePending = false
        } else if lines.isEmpty {
            cascadePending = true
        } else {
            cascadeTrigger += 1
        }
    }

    // MARK: - Translation

    /// Two round buttons, the way Apple Music puts them: a globe that shows or
    /// hides the translation, and 文A for translating the song on the phone.
    private var translationButtons: some View {
        HStack {
            Button {
                settings.showLyricsTranslation.toggle()
            } label: {
                Image(systemName: "globe")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show or hide the translation")

            Spacer()

            Button {
                startTranslation()
            } label: {
                Group {
                    if isTranslating {
                        ProgressView().tint(.white)
                    } else {
                        Text("文A").font(.system(size: 15, weight: .semibold))
                    }
                }
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Translate the lyrics")
        }
        .foregroundStyle(translationFailed ? Color.orange : Color.white)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private func startTranslation() {
        guard !lines.isEmpty else { return }
        settings.showLyricsTranslation = true
        if let cached = LyricsTranslation.cached(videoId: np.videoId ?? "", lines: lines) {
            aiTranslations = cached
            return
        }
        // Apple's engine is driven by the Translation framework, which needs a
        // configuration and a session; every other engine is one HTTP call.
        if TranslationSettings.engine == .apple {
            translationConfig = TranslationSession.Configuration(
                source: nil,
                target: LyricsTranslation.targetLanguage
            )
        } else {
            Task { await translateWithEngine() }
        }
    }

    /// Translates through the engine picked in Settings: OpenAI, OpenRouter,
    /// Gemini, Claude or an OpenAI-compatible host of the listener's own.
    @MainActor
    private func translateWithEngine() async {
        let videoId = np.videoId ?? ""
        let texts = lines.map { $0.text }
        guard texts.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }

        isTranslating = true
        translationFailed = false
        defer { isTranslating = false }

        do {
            let translated = try await AITranslator.translate(
                lines: texts,
                to: TranslationSettings.targetName
            )
            var map: [UUID: String] = [:]
            for (index, text) in translated.enumerated() where lines.indices.contains(index) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                map[lines[index].id] = trimmed
            }
            guard !map.isEmpty else {
                translationFailed = true
                return
            }
            aiTranslations = map
            LyricsTranslation.save(map, videoId: videoId, lines: lines)
        } catch {
            translationFailed = true
        }
    }

    @MainActor
    private func translateAll(with session: TranslationSession) async {
        let videoId = np.videoId ?? ""
        let pairs = lines.enumerated().compactMap { index, line -> (Int, String)? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return (index, text)
        }
        guard !pairs.isEmpty else { return }

        if let cached = LyricsTranslation.cached(videoId: videoId, lines: lines) {
            aiTranslations = cached
            return
        }

        isTranslating = true
        translationFailed = false
        defer { isTranslating = false }

        let requests = pairs.map {
            TranslationSession.Request(sourceText: $0.1, clientIdentifier: String($0.0))
        }

        do {
            let responses = try await session.translations(from: requests)
            var map: [UUID: String] = [:]
            for response in responses {
                guard let identifier = response.clientIdentifier,
                      let index = Int(identifier),
                      lines.indices.contains(index) else { continue }
                let text = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                map[lines[index].id] = text
            }
            aiTranslations = map
            LyricsTranslation.save(map, videoId: videoId, lines: lines)
        } catch {
            translationFailed = true
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            if !isKaraoke {
                Text("Lyrics")
                    .font(.title2.bold())
            }
            Spacer()
            LyricsOptionsMenu {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Lyrics options")
            }
            Button { showLyrics = false } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(IconPressStyle(disc: .white, motion: .deflate))
            .accessibilityLabel("Close lyrics")
        }
        .foregroundStyle(.white)
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.top, 8)
    }

    // MARK: - Lyrics Body

    private var lyricsBody: some View {
        Group {
            if isLoading {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lines.isEmpty {
                ContentUnavailableView("No Lyrics", systemImage: "text.alignleft",
                                       description: Text("Lyrics are unavailable for this song."))
                    .foregroundStyle(.white)
            } else {
                lyricsContentView
                    .opacity(trackFade)
            }
        }
    }

    // MARK: - Lyrics Content

    private var lyricsContentView: some View {
        let fontSize = Self.lineFontSize
        return ZStack(alignment: .bottom) {
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: settings.lyricsAlignment.textAlignment.horizontal, spacing: 12) {
                            Spacer().frame(height: 20)

                            if !isKaraoke, let provider = LyricsState.shared.providerName {
                                Text("Lyrics from \(provider)")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .frame(maxWidth: .infinity, alignment: settings.lyricsAlignment.textAlignment)
                                    .padding(.horizontal, 24)
                            }

                            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                                lyricsLineRow(index: index, line: line, fontSize: fontSize)
                                    .id(line.id)
                            }

                            Spacer().frame(height: geo.size.height * 0.38)
                        }
                        .padding(.vertical, 8)
                    }
                    .scrollIndicators(.hidden)
                    .mask {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom)
                                .frame(height: 44)
                            Color.white
                            LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: 64)
                        }
                    }
                    .onScrollPhaseChange { _, newPhase in
                        if newPhase == .tracking || newPhase == .interacting {
                            pauseAutoScroll()
                        }
                    }
                    .onAppear {
                        scrollProxy = proxy
                        positionInitialLyrics()
                    }
                    .onChange(of: activeIndex) { _, newIndex in
                        guard lines.indices.contains(newIndex) else { return }
                        if isAutoScrollEnabled && !userHasScrolled {
                            if hasPositionedInitialLyrics {
                                scrollToActive()
                            } else {
                                positionInitialLyrics()
                            }
                        }
                    }
                }
            }

            if userHasScrolled && !lines.isEmpty {
                resyncButton
            }
        }
    }

    // MARK: - Re-sync Button

    private var resyncButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                userHasScrolled = false
                isAutoScrollEnabled = true
            }
            scrollToActive()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                Text("Re-sync")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(.white.opacity(0.15)))
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .padding(.bottom, 16)
    }

    // MARK: - Scrolling

    private func pauseAutoScroll() {
        withAnimation(.easeInOut(duration: 0.3)) {
            isAutoScrollEnabled = false
            userHasScrolled = true
        }
    }

    private func resumeAutoScroll() {
        isAutoScrollEnabled = true
        userHasScrolled = false
        scrollToActive()
    }

    /// Centers the active line via the proxy only — writing the
    /// scrollPosition binding here would top-align the line and fight the
    /// center anchor.
    /// Jumps without animation to the current line the first time lyrics show.
    private func positionInitialLyrics() {
        guard lines.indices.contains(activeIndex) else { return }
        scrollProxy?.scrollTo(lines[activeIndex].id, anchor: .center)
        hasPositionedInitialLyrics = true
    }

    private func scrollToActive() {
        guard lines.indices.contains(activeIndex) else { return }
        let targetID = lines[activeIndex].id
        withAnimation(.easeInOut(duration: 0.4)) {
            scrollProxy?.scrollTo(targetID, anchor: .center)
        }
    }

    // MARK: - Distance-based Opacity & Scale (Metrolist-style)

    private func opacityForDistance(_ distance: Int) -> Double {
        switch distance {
        case 0: return 1
        case 1: return 0.55
        case 2: return 0.32
        default: return 0.2
        }
    }

    private func scaleForDistance(_ distance: Int) -> CGFloat {
        switch distance {
        case 0: return 1
        case 1: return 0.98
        default: return 0.96
        }
    }

    // MARK: - Entrance & track change

    /// Lines further than this from the active one never blur: they are off
    /// screen, and a blur layer per row is not free.
    private static let entranceRadius = 9

    /// Runs the blur-in: rows start out of focus and slightly low, then settle.
    private func runEntrance() {
        guard !reduceMotion else {
            entranceProgress = 1
            return
        }
        entranceProgress = 0
        withAnimation(.smooth(duration: 0.5)) { entranceProgress = 1 }
    }

    /// Staggered from the active line outwards, the way rows arrive on screen.
    private func entranceDelay(for index: Int) -> Double {
        Double(min(abs(index - activeIndex), Self.entranceRadius)) * 0.03
    }

    private func entranceBlur(for index: Int) -> CGFloat {
        guard abs(index - activeIndex) <= Self.entranceRadius else { return 0 }
        return CGFloat((1 - entranceProgress) * 9)
    }

    private func entranceRise(for index: Int) -> CGFloat {
        guard abs(index - activeIndex) <= Self.entranceRadius else { return 0 }
        return CGFloat((1 - entranceProgress) * 7)
    }

    // MARK: - Interval Indicator (instrumental gaps)

    /// A lyric line plus its interval ring, which only exists in the hierarchy
    /// while playback is actually inside the gap.
    private func lyricsLineRow(index: Int, line: LyricLine, fontSize: Double) -> some View {
        let gap = settings.showIntervalIndicator ? instrumentalGaps.last(where: { $0.afterIndex == index }) : nil
        let romanized = romanization(for: index)
        // From three lines above the current one down, about the visible window.
        let cascadeDelay = Double(min(max(index - activeIndex + 3, 0), 9)) * 0.08
        let wag = index.isMultiple(of: 2) ? 3.0 : -3.0

        return VStack(spacing: 0) {
            LyricsLineView(
                text: line.text,
                isActive: index == activeIndex,
                alignment: settings.lyricsAlignment,
                fontSize: fontSize,
                lineOpacity: index == activeIndex ? 1 : opacityForDistance(abs(index - activeIndex)),
                lineScale: index == activeIndex ? 1 : scaleForDistance(abs(index - activeIndex)),
                translatedText: settings.showLyricsTranslation ? (line.translation ?? aiTranslations[line.id]) : nil,
                romanizedText: romanized,
                karaokeWords: isKaraoke && index == activeIndex ? line.words : nil,
                lyricsOffset: LyricsOffset.effective(for: np.videoId),
                onTap: {
                    if let t = line.startTime {
                        player.seek(to: t)
                        resumeAutoScroll()
                    }
                }
            )
            .contextMenu {
                Button("Share Card", systemImage: "quote.bubble") { shareCardLine = line }
                Button("Copy Line", systemImage: "doc.on.doc") { UIPasteboard.general.string = line.text }
            } preview: {
                // The lyrics sit on the player's colours, so the lifted line brings its own background.
                Text(line.text)
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .padding()
                    .frame(width: 320, alignment: .leading)
                    .background(Color(.systemBackground))
            }

            if let gap {
                InstrumentalGapRing(
                    gap: gap,
                    offset: LyricsOffset.effective(for: np.videoId),
                    color: intervalIndicatorColor
                )
            }
        }
        // Karaoke start: the line rises from below with a little wag.
        .keyframeAnimator(initialValue: CascadeMotion(), trigger: cascadeTrigger) { content, motion in
            content
                .rotationEffect(.degrees(motion.angle))
                .offset(y: motion.drop)
                .opacity(motion.opacity)
        } keyframes: { _ in
            KeyframeTrack(\.drop) {
                MoveKeyframe(40.0)
                LinearKeyframe(40.0, duration: max(cascadeDelay, 0.01))
                SpringKeyframe(0.0, duration: 0.55, spring: .bouncy)
            }
            KeyframeTrack(\.angle) {
                MoveKeyframe(wag)
                LinearKeyframe(wag, duration: max(cascadeDelay, 0.01))
                CubicKeyframe(wag * -0.6, duration: 0.18)
                SpringKeyframe(0.0, duration: 0.4, spring: .bouncy)
            }
            KeyframeTrack(\.opacity) {
                MoveKeyframe(0.0)
                LinearKeyframe(0.0, duration: max(cascadeDelay, 0.01))
                LinearKeyframe(1.0, duration: 0.2)
            }
        }
        // Blur-in: the visible lines arrive out of focus and settle, staggered
        // from the active one outwards. Runs on first show and on a new track.
        .blur(radius: entranceBlur(for: index))
        .offset(y: entranceRise(for: index))
        .animation(.smooth(duration: 0.55).delay(entranceDelay(for: index)), value: entranceProgress)
    }

    /// Metrolist's expressiveAccent: white on dynamic (album art) backgrounds,
    /// the accent color on solid ones.
    private var intervalIndicatorColor: Color {
        switch settings.playerBackgroundStyle {
        case .solid: return settings.accentColor
        case .dynamic: return .white
        }
    }

    /// The romanized variant for a line, when the toggle is on and one exists.
    private func romanization(for index: Int) -> String? {
        guard settings.romanizeCurrentTrack,
              romanizedLines.indices.contains(index) else { return nil }
        return romanizedLines[index]
    }

    /// Blank / ♪-only timestamped lines declare instrumental spans.
    private static func isInstrumentalMarker(_ line: LyricLine) -> Bool {
        line.text.trimmingCharacters(in: CharacterSet(charactersIn: "♪*· "))
            .isEmpty
    }

    /// Mirrors Metrolist's updateMergedList: an interval ring is created only
    /// from positive evidence — a blank interlude marker whose timestamp says
    /// the words already ended. Nothing is estimated, so the ring never shows
    /// over actual singing.
    private func detectGaps(in all: [LyricLine]) -> [InstrumentalGap] {
        var displayIndices = [Int?](repeating: nil, count: all.count)
        var displayCount = 0
        for (i, line) in all.enumerated() where !Self.isInstrumentalMarker(line) {
            displayIndices[i] = displayCount
            displayCount += 1
        }

        var gaps: [InstrumentalGap] = []
        for (i, marker) in all.enumerated() {
            guard Self.isInstrumentalMarker(marker), let gapStart = marker.startTime else { continue }

            // Attach to the nearest preceding vocal line; intro markers have none.
            var afterIndex: Int?
            var j = i - 1
            while j >= 0, afterIndex == nil {
                afterIndex = displayIndices[j]
                j -= 1
            }
            guard let afterIndex else { continue }

            // The break ends when the next lyrics start.
            var nextStart: TimeInterval?
            var k = i + 1
            while k < all.count, nextStart == nil {
                nextStart = all[k].startTime
                k += 1
            }
            guard let gapEnd = nextStart, gapEnd - gapStart > 4 else { continue }

            gaps.append(InstrumentalGap(afterIndex: afterIndex, start: gapStart, end: gapEnd))
        }
        return gaps
    }

    // MARK: - Romanization

    /// Transliterates lines off the main actor when the toggle is on.
    private func rebuildRomanization() async {
        guard settings.romanizeCurrentTrack, !lines.isEmpty else {
            romanizedLines = []
            return
        }
        let generation = loadGeneration
        let texts = lines.map(\.text)
        let romanized = await Task.detached(priority: .userInitiated) {
            texts.map { LyricsRomanizer.romanize($0) }
        }.value
        // A newer song may have loaded while this ran.
        guard generation == loadGeneration else { return }
        romanizedLines = romanized
    }

    // MARK: - Data

    private func loadLyrics() async {
        // Song changes and refreshes can overlap; only the newest load
        // may write results or clear the loading state.
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        guard let videoId = np.videoId else {
            lines = []
            LyricsState.shared.hasWordTiming = false
            return
        }
        lines = []
        instrumentalGaps = []
        romanizedLines = []
        activeIndex = 0
        hasPositionedInitialLyrics = false
        isAutoScrollEnabled = true
        userHasScrolled = false
        LyricsState.shared.providerName = nil

        guard !Task.isCancelled else { return }
        do {
            let result = try await LyricsService.shared.fetchLyrics(videoId: videoId)
            guard generation == loadGeneration else { return }
            LyricsState.shared.hasWordTiming = result.contains { $0.words != nil }
            guard !result.isEmpty else { return }
            let withoutMarkers = result.filter { !Self.isInstrumentalMarker($0) }
            lines = withoutMarkers.isEmpty ? result : withoutMarkers
            instrumentalGaps = detectGaps(in: result)
            updateActiveLine()
            await rebuildRomanization()
        } catch {
            if generation == loadGeneration { LyricsState.shared.hasWordTiming = false }
        }
    }

    private func updateActiveLine() {
        guard !lines.isEmpty else { return }
        let t = playbackClock() + LyricsOffset.effective(for: np.videoId)
        var idx = 0
        for (i, line) in lines.enumerated() {
            guard let start = line.startTime else { continue }
            if start <= t {
                idx = i
            } else {
                break
            }
        }
        if idx != activeIndex {
            activeIndex = idx
        }
    }
}

/// Offsets of a lyric line during the karaoke start cascade; at rest, none.
private struct CascadeMotion {
    /// Degrees.
    var angle = 0.0
    /// Points down from the line's spot.
    var drop = 0.0
    var opacity = 1.0
}

// MARK: - Playback Tracking

/// The lyrics clock, shared by the active line and the karaoke fill so both
/// switch together. `np.currentTime` only moves every 0.25 s, so while playing
/// the clock counts forward from the last progress update (read up to 80
/// times a second, too often to ask mpv). An estimate off by a second or more
/// means a seek or song change set `currentTime` directly; then that is used.
@MainActor
private func playbackClock() -> TimeInterval {
    let np = NowPlaying.shared
    guard np.isPlaying, let last = PlayerController.shared.lastProgress else { return np.currentTime }
    let live = last.position + Date().timeIntervalSince(last.at) * PlaybackSpeed.shared.rate
    return abs(live - np.currentTime) < 1 ? live : np.currentTime
}

/// Reads the clock so the lyrics list does not: the list redraws only when
/// the active line changes, not on every playback tick. While playing it
/// checks 20 times a second, so a line turns active when it starts instead
/// of up to 0.25 s later.
private struct LyricsTimeTracker: View {
    let onTimeChange: () -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: !NowPlaying.shared.isPlaying)) { context in
            Color.clear
                .onChange(of: context.date) { _, _ in onTimeChange() }
        }
        .onChange(of: NowPlaying.shared.currentTime) { _, _ in onTimeChange() }
    }
}

/// The interval ring under a line, present only while playback is inside the
/// gap. Reads `currentTime` itself so only this view follows playback.
private struct InstrumentalGapRing: View {
    let gap: LyricsView.InstrumentalGap
    let offset: Double
    let color: Color

    var body: some View {
        let now = NowPlaying.shared.currentTime + offset
        // The ring disappears slightly before vocals resume, like Metrolist's -650ms.
        let isVisible = now >= gap.start && now <= gap.end - 0.65

        VStack(spacing: 0) {
            if isVisible {
                IntervalIndicatorView(
                    start: gap.start,
                    end: gap.end - 0.65,
                    now: now,
                    color: color
                )
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isVisible)
    }
}

// MARK: - Interval Indicator Ring

/// Circular progress ring shown during instrumental gaps — SwiftUI take on
/// Metrolist's wavy ring: colored stroke over a 20% track.
///
/// Instead of stepping with playback-position updates (which arrive in coarse
/// chunks), the sweep is one continuous linear animation timed to finish
/// exactly when the gap ends; playback seeks re-anchor it.
private struct IntervalIndicatorView: View {
    let start: TimeInterval
    let end: TimeInterval
    let now: TimeInterval
    let color: Color

    @State private var displayedProgress: Double
    @State private var anchorNow: TimeInterval

    init(start: TimeInterval, end: TimeInterval, now: TimeInterval, color: Color) {
        self.start = start
        self.end = end
        self.now = now
        self.color = color
        _displayedProgress = State(initialValue: Self.fraction(at: now, start: start, end: end))
        _anchorNow = State(initialValue: now)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: 3.5)
            Circle()
                .trim(from: 0, to: CGFloat(max(0.02, min(1, displayedProgress))))
                .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 36, height: 36)
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 4)
        .onAppear { animateToCompletion() }
        .onChange(of: now) { _, newNow in
            // Position ticks are small; anything larger is a seek — re-anchor
            // the sweep so it still completes exactly on time.
            if abs(newNow - anchorNow) > 0.75 {
                anchorNow = newNow
                displayedProgress = Self.fraction(at: newNow, start: start, end: end)
                animateToCompletion(at: newNow)
            } else {
                anchorNow = newNow
            }
        }
    }

    private static func fraction(at t: TimeInterval, start: TimeInterval, end: TimeInterval) -> Double {
        guard end > start else { return 1 }
        return min(1, max(0, (t - start) / (end - start)))
    }

    private func animateToCompletion(at reference: TimeInterval? = nil) {
        let remaining = max(0.15, end - (reference ?? now))
        displayedProgress = min(displayedProgress, 0.999)
        withAnimation(.linear(duration: remaining).delay(0)) {
            displayedProgress = 1
        }
    }
}

// MARK: - Lyrics Line View

private struct LyricsLineView: View {
    let text: String
    let isActive: Bool
    let alignment: LyricsAlignment
    let fontSize: Double
    var lineOpacity: Double = 1
    var lineScale: CGFloat = 1
    /// Translation rendered under the main line, when the source has one.
    var translatedText: String?
    /// Romanized variant rendered under the main line, Metrolist-style.
    var romanizedText: String?
    /// Set only on the active line in karaoke mode.
    var karaokeWords: [LyricWord]?
    var lyricsOffset: Double = 0
    let onTap: () -> Void

    var body: some View {
        let textToDisplay = text.isEmpty ? "\u{266A}" : text

        Button(action: onTap) {
            VStack(alignment: alignment.textAlignment.horizontal, spacing: 4) {
                Group {
                    if let karaokeWords {
                        KaraokeLineText(words: karaokeWords, offset: lyricsOffset)
                    } else {
                        Text(textToDisplay)
                    }
                }
                .font(.system(size: fontSize, weight: .bold))
                .foregroundStyle(.white)
                .lineSpacing(3)
                .multilineTextAlignment(alignment.multilineTextAlignment)

                if let translatedText, !translatedText.isEmpty {
                    Text(translatedText)
                        .font(.system(size: max(12, fontSize * 0.6), weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .multilineTextAlignment(alignment.multilineTextAlignment)
                        // A language switch swaps the text, so it crossfades
                        // instead of blinking in place; showing or hiding the
                        // translation drops it in from just above.
                        .id(translatedText)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }

                if let romanizedText, !romanizedText.isEmpty {
                    Text(romanizedText)
                        .font(.system(size: max(12, fontSize * 0.55), weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .multilineTextAlignment(alignment.multilineTextAlignment)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment.textAlignment)
            .padding(.horizontal, 24)
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.3), value: translatedText)
        }
        .buttonStyle(.plain)
        .opacity(lineOpacity)
        .scaleEffect(lineScale, anchor: alignment.textAlignment == .leading ? .leading : alignment.textAlignment == .trailing ? .trailing : .center)
        .shadow(color: .white.opacity(isActive ? 0.16 : 0), radius: 10)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: isActive)
    }
}

// MARK: - Karaoke

/// The active line in karaoke mode: sung words lit, the current word filling
/// left to right, upcoming words dimmed. Only this view follows the clock
/// frame by frame; the lyrics list redraws only when the active line changes.
private struct KaraokeLineText: View {
    let words: [LyricWord]
    let offset: Double

    /// The line as one Text with letter timing already attached. Built once per
    /// line, not per frame: the renderer below runs sixty times a second.
    private let rendered: Text

    private let np = NowPlaying.shared

    init(words: [LyricWord], offset: Double) {
        self.words = words
        self.offset = offset
        // Word timing sliced into letters, so the fill runs letter by letter
        // instead of jumping from one word to the next.
        self.rendered = Self.text(for: LyricsSyllables.letters(words))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !np.isPlaying)) { _ in
            rendered.textRenderer(KaraokeRenderer(time: playbackClock() + offset))
        }
    }

    /// One text, so lines wrap normally; each word carries its timing.
    private static func text(for words: [LyricWord]) -> Text {
        words.enumerated().reduce(Text(verbatim: "")) { line, item in
            let (index, word) = item
            // ponytail: a last word with no end tag fills over a fixed 0.5 s.
            let timing = KaraokeWordTiming(index: index, start: word.startTime,
                                           end: word.endTime ?? word.startTime + 0.5)
            return Text("\(line)\(Text(verbatim: word.text).customAttribute(timing))")
        }
    }
}

private struct KaraokeWordTiming: TextAttribute {
    /// The word's position in the line, so two words with equal times stay apart.
    let index: Int
    let start: TimeInterval
    let end: TimeInterval
}

/// Draws each word dimmed, then its sung part at full strength, clipped from
/// the left. Only drawing changes per frame; the text layout is reused.
/// A word can span several runs — a line wrap, or kanji and kana drawn with
/// different fonts — so its sung width crosses those runs in order instead
/// of filling each run at once.
/// ponytail: fills left to right, so right-to-left scripts fill backwards.
private struct KaraokeRenderer: TextRenderer {
    var time: TimeInterval

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var wordWidth: [Int: CGFloat] = [:]
        for line in layout {
            for run in line {
                if let timing = run[KaraokeWordTiming.self] {
                    wordWidth[timing.index, default: 0] += run.typographicBounds.rect.width
                }
            }
        }
        var drawnWidth: [Int: CGFloat] = [:]
        for line in layout {
            for run in line {
                guard let timing = run[KaraokeWordTiming.self] else {
                    context.draw(run)
                    continue
                }
                let progress = min(1, max(0, (time - timing.start) / max(timing.end - timing.start, 0.01)))
                let rect = run.typographicBounds.rect
                let before = drawnWidth[timing.index, default: 0]
                drawnWidth[timing.index] = before + rect.width
                let sungWidth = progress * wordWidth[timing.index, default: rect.width] - before
                if progress >= 1 || sungWidth >= rect.width {
                    context.draw(run)
                    continue
                }
                var upcoming = context
                upcoming.opacity = 0.26
                upcoming.draw(run)
                guard sungWidth > 0 else { continue }
                var sung = context
                // Tall clip so only the horizontal edge cuts glyphs.
                sung.clip(to: Path(CGRect(x: rect.minX, y: rect.minY - rect.height,
                                          width: sungWidth, height: rect.height * 3)))
                // The light trail: a blurred copy of the same clipped run blooms
                // out of the sung edge, so the fill reads as singing rather than
                // as a stencil sliding under the glyphs.
                var glow = sung
                glow.addFilter(.blur(radius: 5))
                glow.opacity = 0.45
                glow.draw(run)
                sung.draw(run)
            }
        }
    }
}
