//
//  SleepEndedAnimation.swift
//  Trop
//

import Foundation
import SwiftUI

/// Plays over the full player around the end of the sleep timer.
///
/// Ten seconds before the end a faint tint and a small wavy glow slide in from
/// the screen edges. At the end the glow grows into a night sky around the cover
/// with stars and comets, and a title ("Good night", "Sleep well" or "Sweet dreams") fades in and dissolves,
/// for `SleepTimer.celebrationSeconds`.
/// The frame is a function of `SleepTimer.animationTime`, so it also looks right
/// when the player opens in the middle of the animation.
struct SleepEndedOverlay: View {
    /// The whole screen, measured from its top edge.
    let size: CGSize

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Start of the wave clock. The waves follow the wall clock, not the
    /// timeline, so they keep moving while the music is paused in the prelude.
    @State private var waveClockStart = Date()
    private let timer = SleepTimer.shared

    var body: some View {
        if timer.isActive || timer.isCelebrating {
            // The cheap outer clock only waits for the prelude to begin;
            // the per-frame clock runs while there is something to draw.
            TimelineView(.periodic(from: .now, by: 0.5)) { outer in
                if timer.animationTime(at: outer.date) != nil {
                    TimelineView(.animation) { frame in
                        if let time = timer.animationTime(at: frame.date) {
                            SleepAnimationFrame(
                                time: time,
                                waveTime: frame.date.timeIntervalSince(waveClockStart),
                                size: size,
                                showsParticles: !reduceMotion
                            )
                        }
                    }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct SleepAnimationFrame: View {
    let time: Double
    /// Seconds on the wall clock; drives the wave motion only.
    let waveTime: Double
    let size: CGSize
    let showsParticles: Bool

    private static let tintTop = Color(red: 40 / 255, green: 36 / 255, blue: 120 / 255)
    private static let tintBottom = Color(red: 24 / 255, green: 30 / 255, blue: 90 / 255)
    private static let glyphColor = Color(red: 226 / 255, green: 223 / 255, blue: 1)

    private func ramp(_ from: Double, _ to: Double) -> Double {
        min(max((time - from) / (to - from), 0), 1)
    }

    private func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    private func smoother(_ x: Double) -> Double { x * x * x * (x * (x * 6 - 15) + 10) }

    /// Pixels of the design were drawn on a 300 pt wide screen.
    private var scale: Double { size.width / 300 }

    var body: some View {
        let out = 1 - ease(ramp(12.5, 15))
        let outGlow = 1 - ease(ramp(12, 15))
        let enter = smoother(ramp(-10, -6))
        let fadeIn = smoother(ramp(-10, -7))
        let preTint = 0.4 * ease(ramp(-10, 0))
        let tint = (preTint + (1 - preTint) * ease(ramp(0, 3.2))) * out
        let preGlow = 0.15 * enter
        let mainGlow = ease(ramp(0, 4.8))
        let waveBoost = 1 + 2.8 * (1 - mainGlow) * enter
        let breath = showsParticles ? 1 + 0.18 * sin(waveTime * 2.4) * (1 - mainGlow) * smoother(ramp(-8, -5)) : 1
        let strength = (preGlow + (1 - preGlow) * mainGlow) * breath * outGlow
        let outset = 44 * scale * (1 - enter)
        let title = ease(ramp(3, 4.6)) * (1 - ease(ramp(12.3, 14.5)))
        let particleFade = out

        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Self.tintTop.opacity(0.4), Self.tintBottom.opacity(0.28)], startPoint: .top, endPoint: .bottom)
                .frame(width: size.width, height: size.height + 240)
                .opacity(tint)

            glow(strength: strength, waveBoost: waveBoost, outset: outset)
                .opacity(fadeIn)

            if showsParticles {
                ForEach(Self.sparkles) { sparkle in
                    sparkleView(sparkle, fade: particleFade)
                }
                ForEach(Self.comets) { comet in
                    cometView(comet)
                }
            }

            titleView(strength: title)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    // MARK: - Glow

    /// Drawn by the `sleepGlow` Metal shader, so no image is built on the CPU each frame.
    private func glow(strength: Double, waveBoost: Double, outset: Double) -> some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: size.width, height: size.height)
            .colorEffect(ShaderLibrary.sleepGlow(
                .float2(size),
                .float(waveTime),
                .float(strength),
                .float(waveBoost),
                .float(outset),
                .float(scale),
                .float(showsParticles ? 1 : 0)
            ))
            .mask {
                // The glow comes from the sides and the top: it fades out before the controls.
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.45),
                        .init(color: .clear, location: 0.85)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
    }

    // MARK: - Title

    private func titleView(strength: Double) -> some View {
        let fontSize = size.width * 0.17
        // Script swashes reach past the glyphs' advance width, and Text clips
        // ink outside its own box. En spaces on both ends widen that box.
        return Text("\u{2002}\(SleepTimer.shared.message)\u{2002}")
            .font(.custom("GreatVibes-Regular", size: fontSize))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(.white)
            // Blur and shadows draw only inside the box, so it gets room for
            // the swashes.
            .padding(.horizontal, fontSize * 0.25)
            .padding(.vertical, fontSize * 0.15)
            .shadow(color: Color(red: 0.04, green: 0.03, blue: 0.24).opacity(0.6), radius: 8, y: 2)
            .shadow(color: Color(red: 0.67, green: 0.63, blue: 1).opacity(0.5), radius: 12)
            .scaleEffect(0.94 + 0.06 * strength)
            .blur(radius: (1 - strength) * 12)
            .opacity(strength)
            .frame(width: size.width)
            .position(x: size.width / 2, y: size.height / 2)
    }

    // MARK: - Particles

    private func glyph(isStar: Bool, size: Double) -> some View {
        Group {
            if isStar {
                StarShape()
                    .fill(Self.glyphColor)
                    .overlay(StarShape().stroke(Self.glyphColor, style: StrokeStyle(lineWidth: size * 0.09, lineJoin: .round)))
            } else {
                SparkleShape().fill(Self.glyphColor)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Self.glyphColor.opacity(0.9), radius: 4)
    }

    @ViewBuilder
    private func sparkleView(_ sparkle: Sparkle, fade: Double) -> some View {
        let gate = ease(ramp(2, 4.2)) * (1 - ease(ramp(12, 14.5)))
        let progress = (time - sparkle.start) / sparkle.life
        if progress > 0, progress < 1, gate > 0, fade > 0 {
            let bell = sin(progress * .pi)
            glyph(isStar: sparkle.isStar, size: sparkle.size * scale)
                .scaleEffect(0.5 + 0.75 * bell)
                .rotationEffect(.degrees(sparkle.tilt * progress))
                .opacity(bell * fade * gate)
                .position(x: sparkle.x * size.width, y: sparkle.y * size.height)
        }
    }

    @ViewBuilder
    private func cometView(_ comet: Comet) -> some View {
        let progress = ramp(comet.start, comet.start + comet.duration) == 0 || time >= comet.start + comet.duration
            ? 0
            : (time - comet.start) / comet.duration
        if progress > 0, progress < 1 {
            let travel = pow(progress, 1.3)
            let arrival = 1 - ease(min(max((progress - 0.7) / 0.3, 0), 1))
            let coverHeight = size.height * 0.58
            let from = CGPoint(x: comet.from.x * size.width, y: comet.from.y * coverHeight)
            let to = CGPoint(x: comet.to.x * size.width, y: comet.to.y * coverHeight)
            let angle = atan2(to.y - from.y, to.x - from.x) * 180 / .pi
            let tail = 110 * scale
            ZStack {
                Capsule()
                    .fill(LinearGradient(
                        colors: [.clear, Self.glyphColor.opacity(0.35), Self.glyphColor.opacity(0.95)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: tail, height: 3)
                    .offset(x: -tail / 2)
                glyph(isStar: false, size: 16 * scale)
            }
            .rotationEffect(.degrees(angle))
            .scaleEffect(0.5 + 0.5 * arrival)
            .opacity(arrival)
            .position(x: from.x + (to.x - from.x) * travel, y: from.y + (to.y - from.y) * travel)
        }
    }

    private struct Sparkle: Identifiable {
        let id: Int
        let x: Double
        let y: Double
        let start: Double
        let life: Double
        let size: Double
        let tilt: Double
        let isStar: Bool
    }

    private struct Comet: Identifiable {
        let id: Int
        let start: Double
        let duration: Double
        let from: CGPoint
        let to: CGPoint
    }

    /// Positions are fractions of the screen; a fixed seed keeps every run the same.
    /// Most stars sit in the glow: 8 on each side, 5 along the top, 2 over the cover.
    private static let sparkles: [Sparkle] = {
        var random = SeededRandom(seed: 11)
        var result: [Sparkle] = []
        func add(x: ClosedRange<Double>, y: ClosedRange<Double>, size: ClosedRange<Double>) {
            result.append(Sparkle(
                id: result.count,
                x: random.next(in: x),
                y: random.next(in: y),
                start: random.next(in: 2...11.8),
                life: random.next(in: 1.5...2.8),
                size: random.next(in: size),
                tilt: random.next(in: -35...35),
                isStar: random.next(in: 0...1) > 0.55
            ))
        }
        for _ in 0..<8 { add(x: 0.04...0.22, y: 0.03...0.64, size: 13...24) }
        for _ in 0..<8 { add(x: 0.78...0.96, y: 0.03...0.64, size: 13...24) }
        for _ in 0..<5 { add(x: 0.2...0.8, y: 0.02...0.13, size: 12...20) }
        for _ in 0..<2 { add(x: 0.35...0.65, y: 0.2...0.4, size: 11...15) }
        return result
    }()

    /// Each comet starts outside the screen and ends inside the cover.
    /// `y` is a fraction of the cover height.
    private static let comets: [Comet] = [
        Comet(id: 0, start: 3.8, duration: 1.7, from: CGPoint(x: 1.25, y: -0.12), to: CGPoint(x: 0.62, y: 0.34)),
        Comet(id: 1, start: 7.2, duration: 1.7, from: CGPoint(x: 1.15, y: -0.2), to: CGPoint(x: 0.34, y: 0.5)),
        Comet(id: 2, start: 10.6, duration: 1.7, from: CGPoint(x: 1.3, y: 0.06), to: CGPoint(x: 0.55, y: 0.28))
    ]
}

// MARK: - Shapes

/// Four-point sparkle with concave sides.
private struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.midX + x * radius, y: rect.midY + y * radius)
        }
        var path = Path()
        path.move(to: point(0, -1))
        path.addCurve(to: point(1, 0), control1: point(0.1, -0.28), control2: point(0.28, -0.1))
        path.addCurve(to: point(0, 1), control1: point(0.28, 0.1), control2: point(0.1, 0.28))
        path.addCurve(to: point(-1, 0), control1: point(-0.1, 0.28), control2: point(-0.28, 0.1))
        path.addCurve(to: point(0, -1), control1: point(-0.28, -0.1), control2: point(-0.1, -0.28))
        path.closeSubpath()
        return path
    }
}

/// Five-point star; the stroke added by the caller rounds its tips.
private struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for i in 0..<10 {
            let r = i.isMultiple(of: 2) ? 1.0 : 0.45
            let angle = -Double.pi / 2 + Double(i) * Double.pi / 5
            let point = CGPoint(x: rect.midX + cos(angle) * r * radius, y: rect.midY + sin(angle) * r * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// Small deterministic generator (SplitMix64) so the star layout never changes.
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
