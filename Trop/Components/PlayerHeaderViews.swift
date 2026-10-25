//
//  PlayerHeaderViews.swift
//  Trop
//
//  Created by 686udjie on 2/07/2026.
//

import SwiftUI

/// Title + artist marquee block shared by the FullPlayer, Queue and Lyrics
/// header rows.
struct PlayerTitleBlock: View {
    var title: String
    var artist: String
    var spacing: CGFloat = 2
    var titleFont: Font = .body.weight(.semibold)
    var onArtistTap: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            // Short title instead of a scrolling one; lists show the full title.
            Text(SongTitle.display(title))
                .font(titleFont)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityLabel(title)
                .allowsHitTesting(false)

            if !artist.isEmpty {
                if let onArtistTap {
                    Button(action: onArtistTap) {
                        artistLabel
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View artist: \(artist)")
                } else {
                    artistLabel
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var artistLabel: some View {
        Text(artist)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// How a like is celebrated. Songs with a known genre always get `emoji`;
/// the others get a random one of the four hearts once in a while, or `tap`.
private enum LikeStyle {
    case tap, emoji, spin, heartbeat, jelly, floatingHearts

    var duration: Double {
        switch self {
        case .tap: 0.45
        case .emoji: 1.9
        case .spin: 1.2
        case .heartbeat: 1.3
        case .jelly: 1.1
        case .floatingHearts: 1.8
        }
    }

    /// Chance that a song of unknown genre gets one of the longer animations.
    private static let unknownGenreChance = 3

    static func pick(for flavor: LikeFlavor) -> LikeStyle {
        if flavor.isKnown { return .emoji }
        guard Int.random(in: 0..<unknownGenreChance) == 0 else { return .tap }
        return [.spin, .heartbeat, .jelly, .floatingHearts].randomElement() ?? .tap
    }
}

private struct LikeRun: Equatable {
    let start: Date
    let style: LikeStyle
    /// The emoji the heart turns into (known genres only).
    let emoji: String
}

/// White heart toggle for player surfaces (FullPlayer, Queue).
/// Liking squashes the heart and plays a bouncy animation: an emoji that fits
/// the song's genre, or a heart trick when the genre is unknown.
struct PlayerLikeButton: View {
    var isLiked: Bool
    var flavor: LikeFlavor = .unknown
    var activeColor: Color = .red
    var inactiveColor: Color = .white
    var fontSize: CGFloat = 17
    let onToggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var run: LikeRun?
    @State private var hapticCount = 0

    var body: some View {
        Button {
            if !isLiked, !reduceMotion { startRun() }
            onToggle()
        } label: {
            ZStack {
                if let run {
                    TimelineView(.animation) { context in
                        animatedContent(run, time: context.date.timeIntervalSince(run.start))
                    }
                } else {
                    heart(scale: 1)
                }
            }
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: hapticCount)
        .accessibilityLabel(isLiked ? "Unlike" : "Like")
        .task(id: run?.start) {
            guard let current = run else { return }
            try? await Task.sleep(for: .seconds(current.style.duration))
            if run == current { run = nil }
        }
    }

    private func startRun() {
        let style = LikeStyle.pick(for: flavor)
        run = LikeRun(start: Date(), style: style, emoji: flavor.emojis.randomElement() ?? "")
        if style != .tap { hapticCount += 1 }
    }

    // MARK: - Animation maths

    private func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    private func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }

    /// Springs past 1 and settles, like a bouncy spring.
    private func elastic(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        return 1 - pow(2, -9 * x) * cos(x * .pi * 3.2)
    }

    private func heart(scale: Double, scaleX: Double = 1, scaleY: Double = 1, rotation: Double = 0, lift: Double = 0, flip: Double = 0, opacity: Double = 1) -> some View {
        Image(systemName: isLiked ? "heart.fill" : "heart")
            .font(.system(size: fontSize, weight: .regular))
            .foregroundStyle(isLiked ? activeColor : inactiveColor)
            .rotation3DEffect(.degrees(flip), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .scaleEffect(x: scale * scaleX, y: scale * scaleY)
            .rotationEffect(.degrees(rotation))
            .offset(y: lift)
            .opacity(opacity)
    }

    @ViewBuilder
    private func animatedContent(_ run: LikeRun, time t: Double) -> some View {
        switch run.style {
        case .tap:
            heart(scale: t < 0.08 ? 1 - 0.2 * ease(t / 0.08) : 0.8 + 0.2 * elastic((t - 0.08) / 0.37))
        case .emoji:
            emojiContent(run.emoji, time: t)
        case .spin:
            let progress = clamp(t / 0.9)
            let scale = t < 0.12 ? 1 - 0.35 * ease(t / 0.12) : 0.65 + 0.35 * elastic(clamp((t - 0.12) / 0.9)) + 0.45 * sin(progress * .pi)
            heart(scale: scale, flip: 720 * (1 - pow(1 - progress, 3)))
        case .heartbeat:
            heartbeatContent(time: t)
        case .jelly:
            let wobble = sin(t * 22) * exp(-t * 4.2)
            heart(
                scale: 1,
                scaleX: 1 + 0.38 * wobble,
                scaleY: 1 - 0.38 * wobble,
                rotation: 14 * sin(t * 17) * exp(-t * 5),
                lift: -8 * abs(sin(t * 9)) * exp(-t * 4)
            )
        case .floatingHearts:
            floatingHeartsContent(time: t)
        }
    }

    private func emojiContent(_ emoji: String, time t: Double) -> some View {
        var heartScale = 1.0
        if t < 0.1 {
            heartScale = 1 - 0.45 * ease(t / 0.1)
        } else if t < 0.16 {
            heartScale = 0.55 * (1 - ease((t - 0.1) / 0.06))
        } else if t < 1.3 {
            heartScale = 0
        } else {
            heartScale = elastic((t - 1.3) / 0.55)
        }
        let heartOpacity = (t >= 0.16 && t < 1.3) ? 0.0 : 1.0

        var emojiScale = 0.0, emojiRotation = 0.0, emojiLift = 0.0, emojiOpacity = 0.0
        if t >= 0.1, t < 1.5 {
            let u = t - 0.1
            emojiScale = 1.9 * elastic(u / 0.6) * (1 + 0.05 * sin(u * 9))
            emojiRotation = 16 * sin(u * 14) * exp(-u * 1.8)
            emojiLift = -7 * abs(sin(u * 6.5)) * exp(-u * 1.6)
            emojiOpacity = 1
            if t > 1.3 {
                let fade = ease(clamp((t - 1.3) / 0.2))
                emojiScale *= 1 - fade
                emojiOpacity = 1 - fade
            }
        }
        let burst = clamp((t - 0.15) / 0.95)

        return ZStack {
            heart(scale: heartScale, opacity: heartOpacity)
            Text(emoji)
                .font(.system(size: fontSize * 1.4))
                .scaleEffect(emojiScale)
                .rotationEffect(.degrees(emojiRotation))
                .offset(y: emojiLift)
                .opacity(emojiOpacity)
            ForEach(0..<7, id: \.self) { index in
                burstParticle(index, progress: burst)
            }
        }
    }

    private func burstParticle(_ index: Int, progress: Double) -> some View {
        let angle = (-90 + Double(index - 3) * 26) * .pi / 180
        let distance = 46 + Double((index * 37) % 18)
        let size = 0.8 + Double((index * 13) % 5) / 10
        let reach = distance * (1 - pow(1 - progress, 2))
        let visible = progress > 0 && progress < 1
        let emojis = flavor.emojis
        return Text(emojis.isEmpty ? "" : emojis[index % emojis.count])
            .font(.system(size: 13))
            .scaleEffect(size * (1 - 0.3 * progress))
            .rotationEffect(.degrees(progress * 40 * (angle > -Double.pi / 2 ? 1 : -1)))
            .offset(x: cos(angle) * reach, y: sin(angle) * reach - progress * 10)
            .opacity(visible ? sin(progress * .pi) : 0)
    }

    private func heartbeatContent(time t: Double) -> some View {
        let scale: Double
        if t < 0.15 {
            scale = 1 + 0.45 * ease(t / 0.15)
        } else if t < 0.3 {
            scale = 1.45 - 0.35 * ease((t - 0.15) / 0.15)
        } else if t < 0.45 {
            scale = 1.1 + 0.45 * ease((t - 0.3) / 0.15)
        } else {
            scale = 1.55 - 0.55 * elastic(clamp((t - 0.45) / 0.6))
        }
        return ZStack {
            ForEach([0.0, 0.3], id: \.self) { delay in
                let u = clamp((t - delay) / 0.7)
                Circle()
                    .stroke(activeColor, lineWidth: 2)
                    .frame(width: fontSize * 1.7, height: fontSize * 1.7)
                    .scaleEffect(0.9 + u * 2.4)
                    .opacity(u > 0 && u < 1 ? 0.6 * (1 - u) : 0)
            }
            heart(scale: scale)
        }
    }

    private func floatingHeartsContent(time t: Double) -> some View {
        let bounce = 1 + 0.5 * sin(clamp(t / 0.5) * .pi) * exp(-t * 1.2)
        let scale = t < 0.5 ? bounce : 1 + 0.12 * sin((t - 0.5) * 10) * exp(-(t - 0.5) * 4)
        let tints: [Color] = [.red, Color(red: 1, green: 0.42, blue: 0.5), Color(red: 1, green: 0.6, blue: 0.66)]
        return ZStack {
            ForEach(0..<6, id: \.self) { index in
                let drift = (index.isMultiple(of: 2) ? -1.0 : 1.0) * Double(4 + index * 3)
                let rise = Double(46 + index * 7)
                let sway = Double(5 + (index % 3) * 2)
                let size = 0.6 + Double(index % 3) * 0.2
                let u = clamp((t - 0.1 - Double(index) * 0.1) / 1.1)
                Image(systemName: "heart.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(tints[index % tints.count])
                    .scaleEffect(size * (0.7 + 0.5 * u))
                    .offset(x: drift + sin(u * 6 + drift) * sway, y: -ease(u) * rise)
                    .opacity(u > 0 && u < 1 ? sin(u * .pi) * 0.95 : 0)
            }
            heart(scale: scale)
        }
    }
}

/// White ⋮ button for player surfaces. The options sheet stays owned by the caller.
/// Label for the full player's "⋯" song menu.
struct PlayerOptionsGlyph: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Song options")
    }
}
