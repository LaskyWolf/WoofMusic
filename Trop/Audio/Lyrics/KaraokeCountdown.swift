//
//  KaraokeCountdown.swift
//  Trop
//

import SwiftUI

/// The karaoke start and stop greeting, laid over the player's play button.
/// On start a mascot pops out of the button, tilts its head and barks three
/// times. On stop it pops out, yawns while 💤 float up, and ducks back in.
/// Overlay only: it never touches or delays the lyrics or the button.
struct KaraokeCountdownOverlay: View {
    /// Bumped by the lyrics on each karaoke start or stop.
    let trigger: Int
    /// Karaoke after the change: on plays the countdown, off the goodbye.
    let isOn: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Karaoke starts so far; every third one brings the wolf.
    @AppStorage("karaoke.greetingCount") private var greetingCount = 0

    /// Picked once per start; the goodbye reuses it.
    @State private var isWolf = false
    /// 0 is tucked inside the button, 1 is fully out above it.
    @State private var lift: CGFloat = 0
    /// Degrees; the wolf lifts its head to howl instead.
    @State private var tilt = 0.0
    @State private var headRaise: CGFloat = 0
    @State private var bubbleTexts = ["", "", ""]
    /// One per bubble slot, so a new bark does not cut the previous bubble short.
    @State private var bubbleTriggers = [0, 0, 0]
    @State private var barkTrigger = 0
    @State private var yawnTrigger = 0

    /// How far above the button's centre the mascot stands when out.
    private static let rise: CGFloat = 62
    /// Starts brought by the wolf: one in this many.
    private static let wolfEvery = 3
    /// Bubble spots around the mascot's head, one per bark.
    private static let bubbleOffsets: [CGSize] = [
        CGSize(width: -44, height: -40),
        CGSize(width: 42, height: -54),
        CGSize(width: 0, height: -76)
    ]

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { slot in
                KaraokeBarkBubble(text: bubbleTexts[slot], isBig: slot == 2, trigger: bubbleTriggers[slot])
                    .offset(x: Self.bubbleOffsets[slot].width, y: Self.bubbleOffsets[slot].height - Self.rise)
            }
            mascot
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .sensoryFeedback(.impact(weight: .light), trigger: barkTrigger)
        .task(id: trigger) {
            guard trigger > 0, !reduceMotion else { return }
            // Cancelled when the next start or stop replaces this run.
            if isOn {
                try? await countdown()
            } else {
                try? await goodbye()
            }
        }
    }

    private var mascot: some View {
        Text(verbatim: isWolf ? "🐺" : "🐶")
            .font(.system(size: 52))
            // A bark: a quick swell from the chin.
            .keyframeAnimator(initialValue: CGFloat(1), trigger: barkTrigger) { content, scale in
                content.scaleEffect(scale, anchor: .bottom)
            } keyframes: { _ in
                CubicKeyframe(CGFloat(1.18), duration: 0.08)
                SpringKeyframe(CGFloat(1), duration: 0.22, spring: .bouncy)
            }
            // A yawn: squashed wide, stretched tall, then back.
            .keyframeAnimator(initialValue: CGFloat(1), trigger: yawnTrigger) { content, squash in
                content.scaleEffect(x: 2 - squash, y: squash, anchor: .bottom)
            } keyframes: { _ in
                CubicKeyframe(CGFloat(0.8), duration: 0.12)
                CubicKeyframe(CGFloat(1.12), duration: 0.14)
                SpringKeyframe(CGFloat(1), duration: 0.12, spring: .bouncy)
            }
            .rotationEffect(.degrees(tilt), anchor: .bottom)
            // Tucked in, it is a small dot at the button's centre.
            .scaleEffect(0.2 + 0.8 * lift)
            .opacity(min(1, lift * 2.5))
            .offset(y: -lift * Self.rise - headRaise)
    }

    // MARK: - Scripts

    /// About 2 s for the dog, 2.2 s for the wolf.
    private func countdown() async throws {
        greetingCount += 1
        isWolf = greetingCount.isMultiple(of: Self.wolfEvery)
        bubbleTexts = isWolf ? ["a-", "woo", "AWOOO!"] : ["woof!", "woof!", "WOOF!"]
        tilt = 0
        headRaise = 0
        withAnimation(.spring(duration: 0.4, bounce: 0.45)) { lift = 1 }
        try await Task.sleep(for: .seconds(0.4))

        // The dog cocks its head; the wolf lifts it higher, for longer, and keeps it up to howl.
        withAnimation(.easeInOut(duration: isWolf ? 0.3 : 0.18)) {
            tilt = isWolf ? -18 : 14
            headRaise = isWolf ? 10 : 0
        }
        try await Task.sleep(for: .seconds(isWolf ? 0.5 : 0.3))
        if !isWolf {
            withAnimation(.easeInOut(duration: 0.12)) { tilt = 0 }
        }

        for slot in 0..<3 {
            bubbleTriggers[slot] += 1
            barkTrigger += 1
            try await Task.sleep(for: .seconds(0.3))
        }

        try await Task.sleep(for: .seconds(0.1))
        withAnimation(.easeIn(duration: 0.3)) {
            lift = 0
            tilt = 0
            headRaise = 0
        }
    }

    /// About 1.3 s: a yawn and three 💤 drifting up, a 🌙 first for the wolf.
    private func goodbye() async throws {
        bubbleTexts = [isWolf ? "🌙" : "💤", "💤", "💤"]
        withAnimation(.spring(duration: 0.3, bounce: 0.35)) {
            lift = 1
            tilt = 0
            headRaise = 0
        }
        try await Task.sleep(for: .seconds(0.25))
        yawnTrigger += 1
        for slot in 0..<3 {
            bubbleTriggers[slot] += 1
            try await Task.sleep(for: .seconds(0.22))
        }
        try await Task.sleep(for: .seconds(0.2))
        withAnimation(.easeIn(duration: 0.25)) { lift = 0 }
    }
}

/// A bark in a white speech bubble, or a bare emoji (💤, 🌙), that pops in,
/// floats up and fades each time its trigger changes. Invisible at rest.
private struct KaraokeBarkBubble: View {
    let text: String
    let isBig: Bool
    let trigger: Int

    /// Emoji float on their own; words get the bubble.
    private var isEmoji: Bool {
        text.unicodeScalars.contains { $0.properties.isEmojiPresentation }
    }

    var body: some View {
        Group {
            if isEmoji {
                Text(verbatim: text)
                    .font(.system(size: isBig ? 30 : 24))
            } else {
                Text(verbatim: text)
                    .font(.system(size: isBig ? 18 : 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, isBig ? 12 : 9)
                    .padding(.vertical, isBig ? 6 : 4)
                    .background(Capsule().fill(.white))
            }
        }
        .fixedSize()
        .keyframeAnimator(initialValue: BubbleMotion(), trigger: trigger) { content, motion in
            content
                .scaleEffect(motion.scale)
                .offset(y: motion.rise)
                .opacity(motion.opacity)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                MoveKeyframe(0.3)
                SpringKeyframe(1.0, duration: 0.25, spring: .bouncy)
            }
            KeyframeTrack(\.rise) {
                MoveKeyframe(0.0)
                LinearKeyframe(-34.0, duration: 0.6)
            }
            KeyframeTrack(\.opacity) {
                MoveKeyframe(1.0)
                LinearKeyframe(1.0, duration: 0.35)
                LinearKeyframe(0.0, duration: 0.25)
            }
        }
    }
}

private struct BubbleMotion {
    var scale = 1.0
    /// Points up (negative) from the bubble's spot.
    var rise = 0.0
    var opacity = 0.0
}
