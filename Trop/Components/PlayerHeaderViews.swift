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

/// Every value the like animation changes over its 1.9 seconds.
private struct LikeFrame {
    var heartScale = 1.0
    var heartOpacity = 1.0
    var emojiScale = 0.0
    var emojiRotation = 0.0
    var emojiLift = 0.0
    var emojiOpacity = 0.0
    var burst = 0.0
}

/// White heart toggle for player surfaces (FullPlayer, Queue).
/// Liking squashes the heart, pops it into an emoji that fits the song,
/// wobbles it, throws a few mini ones around and bounces the heart back.
struct PlayerLikeButton: View {
    var isLiked: Bool
    var flavor: LikeFlavor = .heart
    var activeColor: Color = .red
    var inactiveColor: Color = .white
    var fontSize: CGFloat = 17
    let onToggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var likeCount = 0

    var body: some View {
        Button {
            if !isLiked, !reduceMotion { likeCount += 1 }
            onToggle()
        } label: {
            Color.clear
                .frame(width: 36, height: 36)
                .keyframeAnimator(initialValue: LikeFrame(), trigger: likeCount) { _, frame in
                    animatedContent(frame)
                } keyframes: { _ in
                    KeyframeTrack(\.heartScale) {
                        LinearKeyframe(0.55, duration: 0.1)
                        LinearKeyframe(0, duration: 0.06)
                        LinearKeyframe(0, duration: 1.14)
                        SpringKeyframe(1, duration: 0.6, spring: .bouncy(duration: 0.6, extraBounce: 0.3))
                    }
                    KeyframeTrack(\.heartOpacity) {
                        LinearKeyframe(1, duration: 0.1)
                        LinearKeyframe(0, duration: 0.06)
                        LinearKeyframe(0, duration: 1.14)
                        LinearKeyframe(1, duration: 0.05)
                        LinearKeyframe(1, duration: 0.55)
                    }
                    KeyframeTrack(\.emojiScale) {
                        LinearKeyframe(0, duration: 0.1)
                        SpringKeyframe(1.9, duration: 0.6, spring: .bouncy(duration: 0.6, extraBounce: 0.35))
                        LinearKeyframe(1.9, duration: 0.6)
                        LinearKeyframe(0, duration: 0.2)
                        LinearKeyframe(0, duration: 0.4)
                    }
                    KeyframeTrack(\.emojiOpacity) {
                        LinearKeyframe(0, duration: 0.1)
                        LinearKeyframe(1, duration: 0.03)
                        LinearKeyframe(1, duration: 1.17)
                        LinearKeyframe(0, duration: 0.2)
                        LinearKeyframe(0, duration: 0.4)
                    }
                    KeyframeTrack(\.emojiRotation) {
                        LinearKeyframe(0, duration: 0.1)
                        CubicKeyframe(-16, duration: 0.12)
                        CubicKeyframe(14, duration: 0.2)
                        CubicKeyframe(-10, duration: 0.2)
                        CubicKeyframe(8, duration: 0.2)
                        CubicKeyframe(-4, duration: 0.2)
                        CubicKeyframe(0, duration: 0.2)
                        LinearKeyframe(0, duration: 0.68)
                    }
                    KeyframeTrack(\.emojiLift) {
                        LinearKeyframe(0, duration: 0.1)
                        CubicKeyframe(-8, duration: 0.2)
                        CubicKeyframe(0, duration: 0.2)
                        CubicKeyframe(-5, duration: 0.2)
                        CubicKeyframe(0, duration: 0.2)
                        LinearKeyframe(0, duration: 1.0)
                    }
                    KeyframeTrack(\.burst) {
                        LinearKeyframe(0, duration: 0.15)
                        LinearKeyframe(1, duration: 0.95)
                        LinearKeyframe(1, duration: 0.8)
                    }
                }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: likeCount)
        .accessibilityLabel(isLiked ? "Unlike" : "Like")
    }

    private func animatedContent(_ frame: LikeFrame) -> some View {
        ZStack {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.system(size: fontSize, weight: .regular))
                .foregroundStyle(isLiked ? activeColor : inactiveColor)
                .scaleEffect(frame.heartScale)
                .opacity(frame.heartOpacity)

            Text(flavor.emoji)
                .font(.system(size: fontSize * 1.4))
                .scaleEffect(frame.emojiScale)
                .rotationEffect(.degrees(frame.emojiRotation))
                .offset(y: frame.emojiLift)
                .opacity(frame.emojiOpacity)

            ForEach(0..<7, id: \.self) { index in
                burstParticle(index, progress: frame.burst)
            }
        }
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
    }

    private func burstParticle(_ index: Int, progress: Double) -> some View {
        let angle = (-90 + Double(index - 3) * 26) * .pi / 180
        let distance = 46 + Double((index * 37) % 18)
        let size = 0.8 + Double((index * 13) % 5) / 10
        let reach = distance * (1 - pow(1 - progress, 2))
        let visible = progress > 0 && progress < 1
        return Text(flavor.emoji)
            .font(.system(size: 13))
            .scaleEffect(size * (1 - 0.3 * progress))
            .rotationEffect(.degrees(progress * 40 * (angle > -Double.pi / 2 ? 1 : -1)))
            .offset(x: cos(angle) * reach, y: sin(angle) * reach - progress * 10)
            .opacity(visible ? sin(progress * .pi) : 0)
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
