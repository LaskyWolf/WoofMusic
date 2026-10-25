//
//  SleepEndedAnimation.swift
//  Trop
//

import CoreGraphics
import Foundation
import SwiftUI

/// Plays over the full player around the end of the sleep timer.
///
/// Ten seconds before the end a faint tint and a small wavy glow slide in from
/// the screen edges. At the end the glow grows into a night sky around the cover
/// with stars and comets, and a "Sleep timer" title fades in and dissolves,
/// for `SleepTimer.celebrationSeconds`.
/// The frame is a function of `SleepTimer.animationTime`, so it also looks right
/// when the player opens in the middle of the animation.
struct SleepEndedOverlay: View {
    /// The whole screen, measured from its top edge.
    let size: CGSize

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let timer = SleepTimer.shared

    var body: some View {
        if timer.isActive || timer.isCelebrating {
            // The cheap outer clock only waits for the prelude to begin;
            // the per-frame clock runs while there is something to draw.
            TimelineView(.periodic(from: .now, by: 0.5)) { outer in
                if timer.animationTime(at: outer.date) != nil {
                    TimelineView(.animation) { frame in
                        if let time = timer.animationTime(at: frame.date) {
                            SleepAnimationFrame(time: time, size: size, showsParticles: !reduceMotion)
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
        let breath = showsParticles ? 1 + 0.18 * sin(time * 2.4) * (1 - mainGlow) * smoother(ramp(-8, -5)) : 1
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

    @ViewBuilder
    private func glow(strength: Double, waveBoost: Double, outset: Double) -> some View {
        let pad = GlowImage.padding * scale
        if let image = GlowImage.make(
            time: time,
            size: size,
            scale: scale,
            strength: strength,
            waveBoost: waveBoost,
            outset: outset,
            waves: showsParticles
        ) {
            let fullHeight = size.height + 2 * pad
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width + 2 * pad, height: fullHeight)
                .blur(radius: 8 * scale)
                .mask {
                    // The glow comes from the sides and the top: it fades out before the controls.
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: (0.6 * size.height + pad) / fullHeight),
                            .init(color: .clear, location: (0.92 * size.height + pad) / fullHeight)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .offset(x: -pad, y: -pad)
        }
    }

    // MARK: - Title

    private func titleView(strength: Double) -> some View {
        Text("Sleep timer")
            .font(.custom("GreatVibes-Regular", size: size.width * 0.2))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(.white)
            .shadow(color: Color(red: 0.04, green: 0.03, blue: 0.24).opacity(0.6), radius: 8, y: 2)
            .shadow(color: Color(red: 0.67, green: 0.63, blue: 1).opacity(0.5), radius: 12)
            .scaleEffect(0.94 + 0.06 * strength)
            .blur(radius: (1 - strength) * 12)
            .opacity(strength)
            .padding(.horizontal, 16)
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

// MARK: - Glow image

/// The glow as a small bitmap: three wavy layers (indigo, violet, a touch of teal)
/// hugging the left, top and right edges. The three edges are joined by a smooth
/// minimum, so the glow follows the rounded top corners. The bitmap is scaled up
/// and blurred by the view.
private enum GlowImage {
    static let padding = 24.0

    private struct Layer {
        let color: (Double, Double, Double)
        let alpha: Double
        let depth: Double
        let amplitude: Double
        let frequency: Double
        let speed: Double
        let phase: Double
    }

    private static let layers = [
        Layer(color: (48, 32, 165), alpha: 0.95, depth: 185, amplitude: 34, frequency: 0.012, speed: 0.7, phase: 0),
        Layer(color: (112, 86, 250), alpha: 0.6, depth: 132, amplitude: 38, frequency: 0.016, speed: -0.9, phase: 1.7),
        Layer(color: (86, 196, 220), alpha: 0.3, depth: 88, amplitude: 26, frequency: 0.02, speed: 1.1, phase: 3.1)
    ]

    /// Softness of the joins between the edges, per point.
    private static let softness = 0.016

    static func make(
        time: Double,
        size: CGSize,
        scale: Double,
        strength: Double,
        waveBoost: Double,
        outset: Double,
        waves: Bool
    ) -> CGImage? {
        guard strength > 0.001 else { return nil }
        let pad = padding * scale
        let cell = 5 * scale
        let width = Double(size.width)
        let height = Double(size.height)
        let cols = Int(((width + 2 * pad) / cell).rounded(.up))
        let rows = Int(((height + 2 * pad) / cell).rounded(.up))
        guard cols > 0, rows > 0 else { return nil }

        let k = softness / scale
        let skipMargin = log(3.0) / k
        let waveOn = waves ? 1.0 : 0.0
        var acc = [Float](repeating: 0, count: cols * rows * 4)
        var left = [Double](repeating: 0, count: rows)
        var right = [Double](repeating: 0, count: rows)
        var top = [Double](repeating: 0, count: cols)

        for (index, layer) in layers.enumerated() {
            let edge = min(1, strength * (1 + Double(index) * 0.04))
            let depth = layer.depth * scale
            let fade = depth * edge + 1
            let freq = layer.frequency / scale
            let amp = layer.amplitude * scale * edge * waveBoost * waveOn

            func boundary(_ u: Double, _ offset: Double) -> Double {
                edge * depth - outset
                    + amp * sin(u * freq + time * layer.speed + layer.phase + offset)
                    + amp * 0.12 * sin(u * freq * 1.7 - time * layer.speed * 0.6 + layer.phase + offset)
            }

            for row in 0..<rows {
                let y = Double(row) * cell - pad
                left[row] = boundary(y, 0)
                right[row] = boundary(y, 1.9)
            }
            for col in 0..<cols {
                top[col] = boundary(Double(col) * cell - pad, 3.8) * 0.85
            }

            for row in 0..<rows {
                let y = Double(row) * cell - pad
                for col in 0..<cols {
                    let x = Double(col) * cell - pad
                    let v1 = x - left[row]
                    let v2 = (width - x) - right[row]
                    let v3 = (y - top[col]) / 0.85
                    if min(v1, min(v2, v3)) > skipMargin { continue }
                    let distance = -log(exp(-k * v1) + exp(-k * v2) + exp(-k * v3)) / k
                    var u = -distance / fade
                    if u <= 0 { continue }
                    if u > 1 { u = 1 }
                    let a = Float(u * u * (3 - 2 * u) * layer.alpha)
                    let i = (row * cols + col) * 4
                    let keep = 1 - a
                    acc[i] = acc[i] * keep + Float(layer.color.0) * a
                    acc[i + 1] = acc[i + 1] * keep + Float(layer.color.1) * a
                    acc[i + 2] = acc[i + 2] * keep + Float(layer.color.2) * a
                    acc[i + 3] = acc[i + 3] * keep + a
                }
            }
        }

        var pixels = [UInt8](repeating: 0, count: cols * rows * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = UInt8(min(max(acc[i], 0), 255))
            pixels[i + 1] = UInt8(min(max(acc[i + 1], 0), 255))
            pixels[i + 2] = UInt8(min(max(acc[i + 2], 0), 255))
            pixels[i + 3] = UInt8(min(max(acc[i + 3] * 255, 0), 255))
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: cols,
            height: rows,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: cols * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
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
