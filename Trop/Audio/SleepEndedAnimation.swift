//
//  SleepEndedAnimation.swift
//  Trop
//

import SwiftUI

/// Plays over the full player for 15 seconds when the sleep timer ends:
/// a blue hue, a purple vignette closing in around the cover with sparkles and
/// comets, and a "Sleep timer ended" title that fades in and dissolves.
/// The frame is a function of the time since `SleepTimer.endedAt`, so it also
/// looks right when the player opens in the middle of the animation.
struct SleepEndedOverlay: View {
    /// Height of the artwork area, measured from the top of the screen.
    let coverHeight: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let timer = SleepTimer.shared

    var body: some View {
        if timer.isCelebrating, let start = timer.endedAt {
            TimelineView(.animation) { context in
                SleepEndedFrame(
                    time: context.date.timeIntervalSince(start),
                    coverHeight: coverHeight,
                    showsParticles: !reduceMotion
                )
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct SleepEndedFrame: View {
    let time: Double
    let coverHeight: CGFloat
    let showsParticles: Bool

    private static let blue = Color(red: 0.1, green: 0.28, blue: 0.95)
    private static let purple = Color(red: 0.42, green: 0.12, blue: 0.82)
    private static let magenta = Color(red: 0.9, green: 0.15, blue: 0.7)

    private func ramp(_ from: Double, _ to: Double) -> Double {
        min(max((time - from) / (to - from), 0), 1)
    }

    private func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    /// 0 outside the animation, 1 at full strength, back to 0 as it ends.
    private func envelope(rise: ClosedRange<Double>, fall: ClosedRange<Double>) -> Double {
        ease(ramp(rise.lowerBound, rise.upperBound)) * (1 - ease(ramp(fall.lowerBound, fall.upperBound)))
    }

    var body: some View {
        GeometryReader { geo in
            let hue = envelope(rise: 0...1.8, fall: 12.5...15)
            let vignette = envelope(rise: 0.6...3.5, fall: 12...15)
            let title = envelope(rise: 2.2...3.6, fall: 12.3...14.5)
            let fade = 1 - ease(ramp(12.5, 15))
            let width = geo.size.width
            let regionHeight = max(coverHeight, 1)

            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [Self.blue.opacity(0.5), Self.blue.opacity(0.28)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .opacity(hue)

                vignetteLayer(width: width, height: regionHeight, strength: vignette)

                if showsParticles {
                    ForEach(Self.sparkles.indices, id: \.self) { index in
                        sparkle(Self.sparkles[index], width: width, height: regionHeight, fade: fade)
                    }
                    ForEach(Self.comets.indices, id: \.self) { index in
                        comet(Self.comets[index], width: width, height: regionHeight)
                    }
                }

                titleLayer(strength: title)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
    }

    // MARK: - Layers

    /// Purple and magenta close in from outside the cover toward its center.
    private func vignetteLayer(width: CGFloat, height: CGFloat, strength: Double) -> some View {
        let radius = hypot(width, height) / 2
        let pulse = showsParticles ? 0.03 * sin(time * 2) : 0
        let inner = radius * (1.15 - 0.7 * strength + pulse)
        return Rectangle()
            .fill(
                RadialGradient(
                    colors: [.clear, Self.purple.opacity(0.6), Self.magenta.opacity(0.9)],
                    center: .center,
                    startRadius: max(inner, 0),
                    endRadius: max(inner + radius * 0.6, 1)
                )
            )
            .frame(width: width, height: height)
            .opacity(strength > 0 ? 1 : 0)
    }

    private func titleLayer(strength: Double) -> some View {
        VStack(spacing: 0) {
            Text("Sleep timer")
            Text("ended")
        }
        .font(.system(size: 46, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        .opacity(strength)
        .scaleEffect(0.92 + 0.08 * strength)
        .blur(radius: (1 - strength) * 14)
    }

    private func sparkle(_ sparkle: Sparkle, width: CGFloat, height: CGFloat, fade: Double) -> some View {
        let progress = (time - sparkle.start) / sparkle.life
        let bell = progress > 0 && progress < 1 ? sin(progress * .pi) : 0
        return Text(sparkle.glyph)
            .font(.system(size: sparkle.size))
            .scaleEffect(0.5 + 0.7 * bell)
            .rotationEffect(.degrees(sparkle.tilt * progress))
            .opacity(bell * fade)
            .position(x: width * sparkle.x, y: height * sparkle.y)
    }

    private func comet(_ comet: Comet, width: CGFloat, height: CGFloat) -> some View {
        let progress = min(max((time - comet.start) / comet.duration, 0), 1)
        let visible = progress > 0 && progress < 1
        // Speeds up toward the cover, then fades out as it reaches it.
        let travel = pow(progress, 1.3)
        let x = comet.from.x + (comet.to.x - comet.from.x) * travel
        let y = comet.from.y + (comet.to.y - comet.from.y) * travel
        let arrival = 1 - ease(min(max((progress - 0.7) / 0.3, 0), 1))
        return Text("☄️")
            .font(.system(size: 34))
            .scaleEffect(0.4 + 0.6 * arrival)
            .opacity(visible ? arrival : 0)
            .position(x: width * x, y: height * y)
    }

    // MARK: - Fixed particle layout

    private struct Sparkle {
        let x: Double
        let y: Double
        let start: Double
        let life: Double
        let size: Double
        let tilt: Double
        let glyph: String
    }

    private struct Comet {
        let start: Double
        let duration: Double
        let from: CGPoint
        let to: CGPoint
    }

    /// Positions are fractions of the cover area; a fixed seed keeps every run the same.
    private static let sparkles: [Sparkle] = {
        var random = SeededRandom(seed: 7)
        let glyphs = ["✨", "🌟", "⭐️", "💫"]
        return (0..<16).map { _ in
            Sparkle(
                x: random.next(in: 0.05...0.95),
                y: random.next(in: 0.08...0.95),
                start: random.next(in: 1.2...11.5),
                life: random.next(in: 1.4...2.6),
                size: random.next(in: 11...22),
                tilt: random.next(in: -40...40),
                glyph: glyphs[Int(random.next(in: 0...3.99))]
            )
        }
    }()

    /// Each comet starts outside the screen and ends inside the cover.
    private static let comets: [Comet] = [
        Comet(start: 3.4, duration: 1.7, from: CGPoint(x: 1.25, y: -0.15), to: CGPoint(x: 0.62, y: 0.35)),
        Comet(start: 7.2, duration: 1.7, from: CGPoint(x: 1.15, y: -0.25), to: CGPoint(x: 0.35, y: 0.5)),
        Comet(start: 10.6, duration: 1.7, from: CGPoint(x: 1.3, y: 0.05), to: CGPoint(x: 0.55, y: 0.28))
    ]
}

/// Small deterministic generator (SplitMix64) so the sparkle layout never changes.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        let unit = Double(value >> 11) / Double(1 << 53)
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }
}
