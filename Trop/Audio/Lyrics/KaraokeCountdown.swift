//
//  KaraokeCountdown.swift
//  Trop
//

import SwiftUI

/// The karaoke start and stop greeting, in the player's play button's place.
/// On start the button shrinks away and a mascot pops up where it was, tilts
/// its head and barks three times. On stop it yawns while one 💤 drifts up
/// slowly, then the button comes back. It never delays the lyrics.
struct KaraokeCountdownOverlay: View {
    /// Bumped by the lyrics on each karaoke start or stop.
    let trigger: Int
    /// Karaoke after the change: on plays the countdown, off the goodbye.
    let isOn: Bool
    /// True while the mascot stands in for the play button.
    @Binding var replacesPlayButton: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Karaoke starts so far; every third one brings the wolf.
    @AppStorage("karaoke.greetingCount") private var greetingCount = 0

    /// Picked once per start; the goodbye reuses it.
    @State private var isWolf = false
    /// 0 is a dot at the button's centre, 1 is full size in its place.
    @State private var lift: CGFloat = 0
    /// Degrees; the wolf lifts its head to howl instead.
    @State private var tilt = 0.0
    @State private var headRaise: CGFloat = 0
    @State private var bubbleTexts = ["", "", ""]
    /// One per bubble slot, so a new bark does not cut the previous bubble short.
    @State private var bubbleTriggers = [0, 0, 0]
    @State private var barkTrigger = 0
    @State private var yawnTrigger = 0
    @State private var run: Task<Void, Never>?

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
                KaraokeBarkBubble(text: bubbleTexts[slot], isBig: slot == 2, isSlow: !isOn, trigger: bubbleTriggers[slot])
                    .offset(x: Self.bubbleOffsets[slot].width, y: Self.bubbleOffsets[slot].height)
            }
            mascot
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .sensoryFeedback(.impact(weight: .light), trigger: barkTrigger)
        // onChange, not task(id:): opening the player must not replay the last greeting.
        .onChange(of: trigger) { _, _ in
            run?.cancel()
            guard !reduceMotion else { return }
            run = Task {
                withAnimation(.spring(duration: 0.3, bounce: 0.3)) { replacesPlayButton = true }
                if isOn {
                    try? await countdown()
                } else {
                    try? await goodbye()
                }
                // A newer greeting took over and keeps the button hidden.
                guard !Task.isCancelled else { return }
                withAnimation(.spring(duration: 0.35, bounce: 0.3)) { replacesPlayButton = false }
            }
        }
        .onDisappear {
            run?.cancel()
            replacesPlayButton = false
        }
    }

    private var mascot: some View {
        Text(verbatim: isWolf ? "🐺" : "🐶")
            .font(.system(size: 50))
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
            .scaleEffect(0.2 + 0.8 * lift)
            .opacity(min(1, lift * 2.5))
            .offset(y: -headRaise)
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

    /// About 3 s: a slow yawn, one 💤 (🌙 for the wolf) drifting up, and a nod off.
    private func goodbye() async throws {
        bubbleTexts = ["", "", isWolf ? "🌙" : "💤"]
        withAnimation(.easeOut(duration: 0.5)) {
            lift = 1
            tilt = 0
            headRaise = 0
        }
        try await Task.sleep(for: .seconds(0.5))
        yawnTrigger += 1
        try await Task.sleep(for: .seconds(0.3))
        bubbleTriggers[2] += 1
        // The head droops while the 💤 floats away.
        withAnimation(.easeInOut(duration: 1.2)) { tilt = 12 }
        try await Task.sleep(for: .seconds(1.6))
        withAnimation(.easeIn(duration: 0.6)) {
            lift = 0
            tilt = 0
        }
        try await Task.sleep(for: .seconds(0.6))
    }
}

/// A bark in a white speech bubble, or a bare emoji (💤, 🌙), that pops in,
/// floats up and fades each time its trigger changes. Invisible at rest.
private struct KaraokeBarkBubble: View {
    let text: String
    let isBig: Bool
    /// Drifts up slowly, for the goodbye.
    var isSlow = false
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
                CubicKeyframe(isSlow ? -60.0 : -34.0, duration: isSlow ? 1.8 : 0.6)
            }
            KeyframeTrack(\.opacity) {
                MoveKeyframe(1.0)
                LinearKeyframe(1.0, duration: isSlow ? 1.0 : 0.35)
                LinearKeyframe(0.0, duration: isSlow ? 0.8 : 0.25)
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
