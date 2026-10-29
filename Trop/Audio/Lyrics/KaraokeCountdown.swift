//
//  KaraokeCountdown.swift
//  Trop
//

import SwiftUI

/// The karaoke start and stop greeting over the lyrics. On start a mascot
/// pops up from the bottom edge, tilts its head and barks three times; each
/// bark lights one of three paw dots at the top left. On stop it yawns and
/// dives. Overlay only: it never touches or delays the lyrics underneath.
struct KaraokeCountdownOverlay: View {
    /// Bumped by the lyrics on each karaoke start or stop.
    let trigger: Int
    /// Karaoke after the change: on plays the countdown, off the goodbye.
    let isOn: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Picked once per start; the goodbye reuses it.
    @State private var isWolf = false
    /// 0 is hidden below the bottom edge, 1 is fully up.
    @State private var lift: CGFloat = 0
    /// Degrees; the wolf lifts its head to howl instead.
    @State private var tilt = 0.0
    @State private var headRaise: CGFloat = 0
    @State private var bubbleTexts = ["", "", ""]
    /// One per bubble slot, so a new bark does not cut the previous bubble short.
    @State private var bubbleTriggers = [0, 0, 0]
    @State private var barkTrigger = 0
    @State private var yawnTrigger = 0
    @State private var litDots = 0
    @State private var showsDots = false

    /// How far below its resting spot the hidden mascot sits.
    private static let hiddenDrop: CGFloat = 100
    /// Bubble spots above the mascot's head, one per bark.
    private static let bubbleOffsets: [CGSize] = [
        CGSize(width: -38, height: -78),
        CGSize(width: 34, height: -92),
        CGSize(width: 0, height: -112)
    ]

    var body: some View {
        ZStack {
            pawDots
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            ZStack(alignment: .bottom) {
                ForEach(0..<3, id: \.self) { slot in
                    KaraokeBarkBubble(text: bubbleTexts[slot], isBig: slot == 2, trigger: bubbleTriggers[slot])
                        .offset(Self.bubbleOffsets[slot])
                }
                mascot
            }
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .clipped()
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
            .font(.system(size: 56))
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
            .offset(y: (1 - lift) * Self.hiddenDrop - headRaise)
    }

    private var pawDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                let isLit = litDots > index
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(isLit ? 1 : 0.28))
                    .scaleEffect(isLit ? 1.3 : 1)
            }
        }
        .opacity(showsDots ? 1 : 0)
        // Level with the lyrics header, where the karaoke title is hidden.
        .padding(.leading, 24)
        .padding(.top, 24)
    }

    // MARK: - Scripts

    /// About 2 s for the dog, 2.2 s for the wolf.
    private func countdown() async throws {
        // ponytail: 1 in 4 starts brings the wolf.
        isWolf = Int.random(in: 0..<4) == 0
        bubbleTexts = isWolf ? ["a-", "woo", "AWOOO!"] : ["woof!", "woof!", "WOOF!"]
        litDots = 0
        tilt = 0
        headRaise = 0
        withAnimation(.easeOut(duration: 0.2)) { showsDots = true }
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
            withAnimation(.spring(duration: 0.3, bounce: 0.5)) { litDots = slot + 1 }
            try await Task.sleep(for: .seconds(0.3))
        }

        try await Task.sleep(for: .seconds(0.1))
        withAnimation(.easeIn(duration: 0.3)) {
            lift = 0
            tilt = 0
            headRaise = 0
        }
        try await Task.sleep(for: .seconds(0.3))
        withAnimation(.easeOut(duration: 0.25)) { showsDots = false }
    }

    /// About 0.75 s.
    private func goodbye() async throws {
        bubbleTexts[0] = Bool.random() ? "zzz" : "bye!"
        withAnimation(.easeOut(duration: 0.15)) { showsDots = false }
        withAnimation(.spring(duration: 0.22, bounce: 0.35)) {
            lift = 1
            tilt = 0
            headRaise = 0
        }
        try await Task.sleep(for: .seconds(0.2))
        yawnTrigger += 1
        bubbleTriggers[0] += 1
        try await Task.sleep(for: .seconds(0.35))
        withAnimation(.easeIn(duration: 0.2)) { lift = 0 }
    }
}

/// A white speech bubble that pops in, floats up and fades, each time its
/// trigger changes. Invisible at rest.
private struct KaraokeBarkBubble: View {
    let text: String
    let isBig: Bool
    let trigger: Int

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: isBig ? 18 : 13, weight: .heavy, design: .rounded))
            .foregroundStyle(.black)
            .padding(.horizontal, isBig ? 12 : 9)
            .padding(.vertical, isBig ? 6 : 4)
            .background(Capsule().fill(.white))
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
