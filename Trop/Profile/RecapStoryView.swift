//
//  RecapStoryView.swift
//  Trop
//

import SwiftUI
import UIKit

extension View {
    /// Full-screen Woof Recap for `interval` while `isPresented` is true.
    func recapStory(isPresented: Binding<Bool>, interval: DateInterval) -> some View {
        fullScreenCover(isPresented: isPresented) {
            RecapStoryView(interval: interval)
                .presentationBackground(.clear)
        }
    }
}

/// Woof Recap: story-style slides that advance every few seconds. Tap the
/// right two thirds for the next slide, the left third for the previous one,
/// hold to pause, swipe down or ✕ to close.
struct RecapStoryView: View {
    let interval: DateInterval

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    @State private var stats: RecapStats?
    @State private var isLoading = true
    @State private var songCover: UIImage?
    @State private var artistImage: UIImage?
    @State private var colors = RecapStoryView.fallbackColors
    @State private var shareImage: UIImage?

    @State private var index = 0
    /// 0...1 through the current slide.
    @State private var progress: Double = 0
    @State private var isPaused = false
    @State private var pressStart: Date?
    @State private var dragY: CGFloat = 0

    static let slideSeconds: Double = 4
    static let fallbackColors = [Color(red: 0.24, green: 0.16, blue: 0.48), Color(red: 0.08, green: 0.32, blue: 0.3)]

    enum Slide: Hashable {
        case intro, minutes, artist, song, badges, summary
    }

    private var slides: [Slide] {
        guard let stats, !stats.isEmpty else { return [] }
        var list: [Slide] = [.intro, .minutes]
        if !stats.topArtists.isEmpty { list.append(.artist) }
        if stats.topSong != nil { list.append(.song) }
        list += [.badges, .summary]
        return list
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background
                if let stats, !stats.isEmpty, slides.indices.contains(index) {
                    gestureLayer(width: geo.size.width)
                    slideView(slides[index], stats: stats)
                        .id(index)
                        .transition(.opacity)
                        .padding(.top, 96)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 30)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(false)
                        .accessibilityElement(children: .combine)
                        .accessibilityAction(named: "Next Slide") { next() }
                        .accessibilityAction(named: "Previous Slide") { previous() }
                    if slides[index] == .summary {
                        summaryButtons
                            .padding(.horizontal, 22)
                            .padding(.bottom, 30)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                } else if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    emptyState
                        .padding(.horizontal, 32)
                }
                chrome
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .animation(.easeInOut(duration: 0.35), value: index)
        }
        .offset(y: dragY)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .accessibilityAction(.escape) { dismiss() }
        .sensoryFeedback(.selection, trigger: index)
        .task { await load() }
        .task(id: "\(index)-\(stats != nil)-\(voiceOver)") { await runTimer() }
    }

    // MARK: - Chrome

    private var background: some View {
        let color = colors[index % colors.count]
        let centers: [UnitPoint] = [.init(x: 0.5, y: 0.3), .init(x: 0.3, y: 0.8), .init(x: 0.5, y: 0.35),
                                    .init(x: 0.5, y: 0.3), .init(x: 0.5, y: 0), .init(x: 0.5, y: 1)]
        return ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.09)
            RadialGradient(colors: [color.opacity(0.9), .clear],
                           center: centers[index % centers.count], startRadius: 0, endRadius: 520)
            // Keeps white text readable on light covers.
            Color.black.opacity(0.25)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: index)
        .animation(.easeInOut(duration: 0.6), value: colors)
    }

    private var chrome: some View {
        VStack(spacing: 10) {
            if !slides.isEmpty {
                HStack(spacing: 4) {
                    ForEach(slides.indices, id: \.self) { i in
                        let fill = i < index ? 1 : (i == index ? progress : 0)
                        Capsule()
                            .fill(.white.opacity(0.3))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(.white)
                                    .scaleEffect(x: fill, anchor: .leading)
                            }
                            .frame(height: 3)
                    }
                }
                .animation(.linear(duration: 0.05), value: progress)
                .accessibilityElement()
                .accessibilityLabel("Slide \(index + 1) of \(slides.count)")
            }
            HStack {
                Text("🐾 Woof Recap")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 36, height: 36)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// One gesture for tap, hold and swipe, so they never fight each other.
    private func gestureLayer(width: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if pressStart == nil { pressStart = value.time }
                        isPaused = true
                        dragY = max(0, value.translation.height)
                    }
                    .onEnded { value in
                        let held = value.time.timeIntervalSince(pressStart ?? value.time)
                        pressStart = nil
                        isPaused = false
                        if value.translation.height > 120 {
                            dismiss()
                            return
                        }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragY = 0 }
                        let moved = hypot(value.translation.width, value.translation.height)
                        guard moved < 12, held < 0.3 else { return }
                        if value.startLocation.x < width / 3 { previous() } else { next() }
                    }
            )
            .accessibilityHidden(true)
    }

    // MARK: - Timer

    /// Advances after `slideSeconds`, paused while held. VoiceOver users move with the slide actions.
    private func runTimer() async {
        guard !slides.isEmpty, !voiceOver else { return }
        let tick = 0.05
        while progress < 1 {
            try? await Task.sleep(for: .seconds(tick))
            if Task.isCancelled { return }
            if !isPaused { progress = min(1, progress + tick / Self.slideSeconds) }
        }
        if index < slides.count - 1 { next() }
    }

    private func next() {
        guard index < slides.count - 1 else { return }
        progress = 0
        index += 1
    }

    private func previous() {
        progress = 0
        if index > 0 { index -= 1 }
    }

    // MARK: - Slides

    @ViewBuilder
    private func slideView(_ slide: Slide, stats: RecapStats) -> some View {
        switch slide {
        case .intro: IntroSlide(month: RecapService.monthName(interval))
        case .minutes: MinutesSlide(stats: stats)
        case .artist: ArtistSlide(artists: stats.topArtists, image: artistImage)
        case .song: SongSlide(song: stats.topSong, cover: songCover, newBadge: stats.newBadges.first)
        case .badges: BadgesSlide(stats: stats, month: RecapService.monthName(interval))
        case .summary: SummarySlide(stats: stats)
        }
    }

    private var summaryButtons: some View {
        HStack(spacing: 8) {
            Button {
                progress = 0
                index = 0
            } label: {
                Label("Replay", systemImage: "arrow.counterclockwise")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            if let shareImage {
                let image = Image(uiImage: shareImage)
                ShareLink(item: image, preview: SharePreview("Woof Recap", image: image)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("🐾")
                .font(.system(size: 56))
                .accessibilityHidden(true)
            Text("Nothing to sniff yet")
                .font(.title2.weight(.bold))
            Text("Play some music and come back.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Data

    private func load() async {
        let computed = await RecapService.compute(for: interval)
        stats = computed
        isLoading = false
        guard let computed, !computed.isEmpty else { return }
        songCover = await Self.image(computed.topSong?.thumbnailUrl)
        artistImage = await Self.image(computed.topArtists.first?.thumbnailUrl)
        if let source = songCover ?? artistImage {
            let extracted = await Task.detached(priority: .utility) { source.extractDominantColors() }.value
            if !extracted.isEmpty { colors = extracted }
        }
        shareImage = renderShareCard(computed)
    }

    private static func image(_ url: String?) async -> UIImage? {
        guard let url = (ArtworkURLs.highRes(url) ?? url).flatMap({ URL(string: $0) }) else { return nil }
        return try? await ArtworkLoader.image(for: url)
    }

    /// ImageRenderer can't wait for async images, so the covers are already loaded UIImages.
    private func renderShareCard(_ stats: RecapStats) -> UIImage? {
        let renderer = ImageRenderer(content: RecapShareCard(
            stats: stats, month: RecapService.monthName(interval), cover: songCover, colors: colors
        ))
        // 360×640 pt at 3× is 1080×1920 px.
        renderer.scale = 1080 / RecapShareCard.size.width
        return renderer.uiImage
    }
}

// MARK: - Entrance animations

private enum Entrance {
    /// Fades in while sliding up.
    case rise
    /// Grows from small with a twist and an overshoot (covers).
    case zoom
    /// Springs out from nothing (badges, bars).
    case pop
}

/// Plain fades with Reduce Motion.
private struct EntranceModifier: ViewModifier {
    let style: Entrance
    let shown: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let still = shown || reduceMotion
        content
            .opacity(shown ? 1 : 0)
            .offset(y: style == .rise && !still ? 14 : 0)
            .scaleEffect(still ? 1 : (style == .zoom ? 0.3 : (style == .pop ? 0.01 : 1)))
            .rotationEffect(.degrees(style == .zoom && !still ? -10 : 0))
            .animation(animation, value: shown)
    }

    private var animation: Animation {
        if reduceMotion { return .easeInOut(duration: 0.3).delay(delay) }
        switch style {
        case .rise: return .easeOut(duration: 0.6).delay(delay)
        case .zoom: return .spring(response: 0.8, dampingFraction: 0.6).delay(delay)
        case .pop: return .spring(response: 0.5, dampingFraction: 0.5).delay(delay)
        }
    }
}

private extension View {
    func entrance(_ style: Entrance, _ shown: Bool, delay: Double = 0) -> some View {
        modifier(EntranceModifier(style: style, shown: shown, delay: delay))
    }
}

/// Flips `shown` once the slide is on screen, so its parts animate in.
private struct Appearing<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var shown = false

    var body: some View {
        content(shown)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { shown = true }
    }
}

private struct Kicker: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(RecapPalette.gold)
    }
}

private extension Text {
    func headline(size: CGFloat = 34) -> some View {
        font(.system(size: size, weight: .heavy))
            .tracking(-0.8)
    }
}

enum RecapPalette {
    static let gold = Color(red: 1, green: 0.81, blue: 0.29)
    static let teal = Color(red: 0.37, green: 0.7, blue: 0.66)
}

// MARK: - Slide views

private struct IntroSlide: View {
    let month: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Appearing { shown in
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    if !reduceMotion { twinkles }
                    Circle()
                        .fill(RadialGradient(colors: [Color(red: 1, green: 0.96, blue: 0.85), Color(red: 1, green: 0.83, blue: 0.43),
                                                      Color(red: 0.88, green: 0.64, blue: 0.23)],
                                             center: UnitPoint(x: 0.35, y: 0.35), startRadius: 0, endRadius: 70))
                        .frame(width: 120, height: 120)
                        .shadow(color: Color(red: 1, green: 0.83, blue: 0.43).opacity(0.5), radius: 30)
                        .overlay { Text("🐾").font(.system(size: 44)) }
                        .entrance(.zoom, shown, delay: 0.1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .accessibilityHidden(true)

                Kicker(text: "Woof Recap · \(month)")
                    .entrance(.rise, shown, delay: 0.5)
                Text("Your \(month)\nin Woof")
                    .headline()
                    .entrance(.rise, shown, delay: 0.8)
                Text("The pack has been busy. Let's sniff out what you played.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .entrance(.rise, shown, delay: 1.2)
            }
        }
    }

    private var twinkles: some View {
        let spots: [(CGFloat, CGFloat, Double)] = [(-120, -40, 0), (110, -60, 0.6), (80, 90, 1.1), (-100, 110, 0.3)]
        return ZStack {
            ForEach(spots.indices, id: \.self) { i in
                Circle()
                    .fill(.white)
                    .frame(width: 4, height: 4)
                    .phaseAnimator([0.2, 1]) { content, phase in
                        content.opacity(phase).scaleEffect(0.6 + phase * 0.7)
                    } animation: { _ in
                        .easeInOut(duration: 0.9).delay(spots[i].2)
                    }
                    .offset(x: spots[i].0, y: spots[i].1)
            }
        }
    }
}

private struct MinutesSlide: View {
    let stats: RecapStats
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var counted = 0

    var body: some View {
        Appearing { shown in
            VStack(alignment: .leading, spacing: 8) {
                Kicker(text: "Minutes listened")
                    .entrance(.rise, shown, delay: 0.2)
                Text(counted, format: .number)
                    .font(.system(size: 64, weight: .heavy).monospacedDigit())
                    .tracking(-2)
                    .contentTransition(.numericText(value: Double(counted)))
                    .padding(.top, 40)
                    .accessibilityLabel("\(stats.totalMinutes) minutes")
                Text("That's \(Self.wagging(stats.totalMinutes)) of tail-wagging.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .entrance(.rise, shown, delay: 1.4)
                if stats.weeklyMinutes.count > 1 {
                    weeks(shown)
                        .padding(.top, 24)
                    if let loudest = loudestWeek {
                        Text("Week \(loudest + 1) was your loudest: \(Self.duration(stats.weeklyMinutes[loudest])).")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .entrance(.rise, shown, delay: 2.8)
                    }
                }
            }
        }
        .task { await countUp() }
    }

    private var loudestWeek: Int? {
        stats.weeklyMinutes.indices.max { stats.weeklyMinutes[$0] < stats.weeklyMinutes[$1] }
    }

    private func weeks(_ shown: Bool) -> some View {
        let top = max(1, stats.weeklyMinutes.max() ?? 1)
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(stats.weeklyMinutes.indices, id: \.self) { i in
                UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 2, bottomTrailingRadius: 2, topTrailingRadius: 6)
                    .fill(i == loudestWeek ? RecapPalette.gold : RecapPalette.teal)
                    .frame(height: max(4, 90 * CGFloat(stats.weeklyMinutes[i]) / CGFloat(top)))
                    .entrance(.pop, shown, delay: 1.8 + Double(i) * 0.15)
            }
        }
        .frame(height: 90, alignment: .bottom)
        .accessibilityHidden(true)
    }

    /// Counts up over about 1.2 s, easing out. Shows the total at once with Reduce Motion.
    private func countUp() async {
        let target = stats.totalMinutes
        guard !reduceMotion else {
            counted = target
            return
        }
        try? await Task.sleep(for: .seconds(0.4))
        let steps = 24
        for step in 1...steps {
            try? await Task.sleep(for: .seconds(0.05))
            if Task.isCancelled { return }
            let t = Double(step) / Double(steps)
            let eased = 1 - (1 - t) * (1 - t) * (1 - t)
            withAnimation(.snappy(duration: 0.1)) { counted = Int(Double(target) * eased) }
        }
    }

    /// "3 days and 8 hours", "12 hours", "45 minutes".
    static func wagging(_ minutes: Int) -> String {
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        if days > 0 { return hours > 0 ? "\(days) days and \(hours) hours" : "\(days) days" }
        if hours > 0 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h" : "\(minutes) min"
    }
}

private struct ArtistSlide: View {
    let artists: [RecapStats.Artist]
    let image: UIImage?

    var body: some View {
        Appearing { shown in
            VStack(spacing: 8) {
                Kicker(text: "Top artist")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .entrance(.rise, shown, delay: 0.1)
                if let top = artists.first {
                    RecapCover(image: image, side: 180)
                        .clipShape(Circle())
                        .overlay { Circle().strokeBorder(.white.opacity(0.1), lineWidth: 6) }
                        .shadow(color: RecapPalette.gold.opacity(0.4), radius: 25)
                        .padding(.vertical, 10)
                        .entrance(.zoom, shown, delay: 0.3)
                        .accessibilityHidden(true)
                    Text(top.name)
                        .headline()
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .entrance(.rise, shown, delay: 1.2)
                    Text("\(top.minutes.formatted()) min · \(top.plays.formatted()) plays")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .entrance(.rise, shown, delay: 1.5)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(artists.dropFirst().enumerated()), id: \.offset) { i, artist in
                            Text("\(i + 2)   \(artist.name)")
                                .lineLimit(1)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                    .entrance(.rise, shown, delay: 2.2)
                }
            }
        }
    }
}

private struct SongSlide: View {
    let song: RecapStats.Song?
    let cover: UIImage?
    let newBadge: RecapBadge?
    @State private var unlocked = false

    var body: some View {
        Appearing { shown in
            VStack(spacing: 8) {
                Kicker(text: "Top song")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .entrance(.rise, shown, delay: 0.1)
                if let song {
                    RecapCover(image: cover, side: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 15, y: 12)
                        .padding(.vertical, 4)
                        .entrance(.zoom, shown, delay: 0.2)
                        .accessibilityHidden(true)
                    Text(song.title)
                        .headline(size: 28)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .entrance(.rise, shown, delay: 0.8)
                    Text([song.artist, "played \(song.plays) \(song.plays == 1 ? "time" : "times")"]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .entrance(.rise, shown, delay: 1)
                }
                Spacer(minLength: 0)
                if let newBadge {
                    UnlockedCard(badge: newBadge)
                        .entrance(.pop, shown, delay: 1.8)
                        .sensoryFeedback(.success, trigger: unlocked)
                        .task {
                            try? await Task.sleep(for: .seconds(1.8))
                            unlocked = true
                        }
                }
            }
        }
    }
}

/// "Badge unlocked" card; the gem bounces once after it pops in.
private struct UnlockedCard: View {
    let badge: RecapBadge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = 0

    private struct Bounce {
        var scale: Double = 1
    }

    var body: some View {
        HStack(spacing: 12) {
            BadgeGem(kind: badge.kind)
                .keyframeAnimator(initialValue: Bounce(), trigger: bounce) { content, motion in
                    content.scaleEffect(reduceMotion ? 1 : motion.scale)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        SpringKeyframe(1.3, duration: 0.25)
                        SpringKeyframe(1, duration: 0.4)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text("Badge unlocked: \(badge.kind.name)")
                    .font(.headline)
                Text(badge.kind.summary)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(RecapPalette.gold.opacity(0.5)) }
        .shadow(color: RecapPalette.gold.opacity(0.25), radius: 20)
        .task {
            try? await Task.sleep(for: .seconds(2.2))
            bounce += 1
        }
    }
}

private struct BadgesSlide: View {
    let stats: RecapStats
    let month: String

    var body: some View {
        Appearing { shown in
            VStack(alignment: .leading, spacing: 8) {
                Kicker(text: "Your badge shelf")
                    .entrance(.rise, shown, delay: 0.1)
                Text("\(stats.unlockedCount) of \(stats.badges.count) unlocked")
                    .headline(size: 26)
                    .entrance(.rise, shown, delay: 0.3)
                if !stats.newBadges.isEmpty {
                    Text("\(stats.newBadges.count) new in \(month)")
                        .font(.subheadline)
                        .foregroundStyle(RecapPalette.gold)
                        .entrance(.rise, shown, delay: 0.4)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 14) {
                    ForEach(Array(stats.badges.enumerated()), id: \.element.id) { i, badge in
                        BadgeTile(badge: badge, isNew: stats.newBadges.contains(badge))
                            .entrance(.pop, shown, delay: 0.6 + Double(i) * 0.15)
                    }
                }
                .padding(.top, 12)
            }
        }
    }
}

private struct SummarySlide: View {
    let stats: RecapStats

    var body: some View {
        Appearing { shown in
            VStack(alignment: .leading, spacing: 8) {
                Kicker(text: "That's a wrap")
                    .entrance(.rise, shown, delay: 0.1)
                Text("Show off\nyour pack")
                    .headline()
                    .entrance(.rise, shown, delay: 0.3)
                VStack(spacing: 0) {
                    row("Minutes", stats.totalMinutes.formatted())
                    if let artist = stats.topArtists.first { row("Top artist", artist.name) }
                    if let song = stats.topSong { row("Top song", song.title) }
                    HStack {
                        Text("Badges")
                        Spacer()
                        HStack(spacing: 4) {
                            ForEach(stats.badges.filter(\.isUnlocked).prefix(4)) { badge in
                                BadgeGem(kind: badge.kind, size: 26)
                            }
                            if stats.unlockedCount == 0 {
                                Text("None yet").font(.subheadline.weight(.semibold))
                            } else if stats.unlockedCount > 4 {
                                Text("+\(stats.unlockedCount - 4)").font(.subheadline.weight(.semibold))
                            }
                        }
                    }
                    .font(.subheadline)
                    .padding(.vertical, 6)
                }
                .padding(16)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.16)) }
                .padding(.top, 16)
                .entrance(.rise, shown, delay: 0.6)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .font(.subheadline)
        .padding(.vertical, 6)
    }
}

/// A loaded cover, or a gradient with a note while it loads or when there is none.
private struct RecapCover: View {
    let image: UIImage?
    let side: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: RecapStoryView.fallbackColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: side * 0.3, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
            }
        }
        .frame(width: side, height: side)
        .clipped()
    }
}

// MARK: - Share card

/// The 9:16 recap image: minutes, top song and artist, unlocked badges.
struct RecapShareCard: View {
    let stats: RecapStats
    let month: String
    let cover: UIImage?
    let colors: [Color]

    static let size = CGSize(width: 360, height: 640)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("🐾 Woof Recap · \(month)")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(RecapPalette.gold)
            Text(stats.totalMinutes.formatted())
                .font(.system(size: 72, weight: .heavy))
                .tracking(-2)
                .padding(.top, 28)
            Text("minutes listened")
                .font(.system(size: 17, weight: .semibold))
                .opacity(0.75)

            Spacer(minLength: 24)

            if let song = stats.topSong {
                HStack(spacing: 14) {
                    RecapCover(image: cover, side: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TOP SONG")
                            .font(.system(size: 11, weight: .heavy))
                            .tracking(1.2)
                            .foregroundStyle(RecapPalette.gold)
                        Text(song.title)
                            .font(.system(size: 20, weight: .bold))
                            .lineLimit(2)
                        Text("\(song.plays) plays")
                            .font(.system(size: 14, weight: .semibold))
                            .opacity(0.75)
                    }
                }
            }
            if let artist = stats.topArtists.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TOP ARTIST")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(1.2)
                        .foregroundStyle(RecapPalette.gold)
                    Text(artist.name)
                        .font(.system(size: 24, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .padding(.top, 22)
            }

            Spacer(minLength: 24)

            if stats.unlockedCount > 0 {
                HStack(spacing: 6) {
                    ForEach(stats.badges.filter(\.isUnlocked)) { badge in
                        BadgeGem(kind: badge.kind, size: 38)
                    }
                }
            }
            Text("Woof Music")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .tracking(1.2)
                .textCase(.uppercase)
                .opacity(0.7)
                .padding(.top, 18)
        }
        .foregroundStyle(.white)
        .padding(32)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background {
            ZStack {
                Color(red: 0.05, green: 0.06, blue: 0.09)
                LinearGradient(colors: colors.map { $0.opacity(0.85) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}
