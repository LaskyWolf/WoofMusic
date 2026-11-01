//
//  GlyphMotion.swift
//  Trop
//

import SwiftUI

/// One moment of an icon's movement. Distances are in points, angles in degrees.
struct GlyphPose {
    var scaleX = 1.0
    var scaleY = 1.0
    var rotation = 0.0
    var x = 0.0
    var y = 0.0
    var opacity = 1.0

    fileprivate func mixed(with other: GlyphPose, by amount: Double) -> GlyphPose {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * amount }
        return GlyphPose(
            scaleX: mix(scaleX, other.scaleX),
            scaleY: mix(scaleY, other.scaleY),
            rotation: mix(rotation, other.rotation),
            x: mix(x, other.x),
            y: mix(y, other.y),
            opacity: mix(opacity, other.opacity)
        )
    }
}

/// How one icon moves, and what flies out of it. Everything is worked out from
/// the time since the tap, so nothing is left running afterwards.
struct GlyphScript {
    struct Key {
        let time: Double
        let pose: GlyphPose

        init(_ time: Double, sx: Double = 1, sy: Double = 1, r: Double = 0, x: Double = 0, y: Double = 0, o: Double = 1) {
            self.time = time
            pose = GlyphPose(scaleX: sx, scaleY: sy, rotation: r, x: x, y: y, opacity: o)
        }

        init(_ time: Double, s: Double, r: Double = 0, x: Double = 0, y: Double = 0, o: Double = 1) {
            self.init(time, sx: s, sy: s, r: r, x: x, y: y, o: o)
        }
    }

    struct Bit {
        var color: Color?
        /// 0 points right, and -90 points up.
        var angle = -90.0
        var reach = 24.0
        var delay = 0.0
        var life = 0.7
        var size = 5.0
    }

    struct Ring {
        var color: Color?
        var delay = 0.0
    }

    let keys: [Key]
    var rings: [Ring] = []
    var bits: [Bit] = []
    var ringSize: CGFloat = 28

    var duration: Double {
        let moves = keys.last?.time ?? 0
        let ringsEnd = rings.map { $0.delay + GlyphExtras.ringLife }.max() ?? 0
        let bitsEnd = bits.map { $0.delay + $0.life }.max() ?? 0
        return max(moves, ringsEnd, bitsEnd)
    }

    func pose(at time: Double) -> GlyphPose {
        guard let first = keys.first, let last = keys.last else { return GlyphPose() }
        if time <= first.time { return first.pose }
        if time >= last.time { return last.pose }
        for (start, end) in zip(keys, keys.dropFirst()) where time < end.time {
            let x = (time - start.time) / (end.time - start.time)
            return start.pose.mixed(with: end.pose, by: x * x * (3 - 2 * x))
        }
        return last.pose
    }

    /// Bits spread evenly across an arc, each going a slightly different distance.
    static func burst(
        _ count: Int,
        color: Color? = nil,
        around angle: Double = -90,
        spread: Double,
        reach: Double,
        delay: Double = 0,
        stagger: Double = 0,
        life: Double,
        size: Double
    ) -> [Bit] {
        (0..<count).map { index in
            let share = count > 1 ? Double(index) / Double(count - 1) - 0.5 : 0
            return Bit(
                color: color,
                angle: angle + share * spread,
                reach: reach * (0.8 + Double((index * 37) % 10) / 20),
                delay: delay + Double(index) * stagger,
                life: life,
                size: size
            )
        }
    }
}

// The icons' movements. Pressed often means short.
extension GlyphScript {
    /// Distances follow the icon's size: it is 17 pt in the mini player and 42 pt in the player.
    static func pauseStamp(size: Double) -> GlyphScript {
        GlyphScript(keys: [Key(0, s: 1.3, y: -0.24 * size), Key(0.14, sx: 1.12, sy: 0.82), Key(0.28, s: 1)])
    }

    static func playShoot(size: Double) -> GlyphScript {
        GlyphScript(
            keys: [Key(0, sx: 1.25, sy: 0.7, x: -0.2 * size), Key(0.16, sx: 0.92, sy: 1.1, x: 0.07 * size), Key(0.3, s: 1)],
            rings: [Ring()],
            ringSize: size * 1.05
        )
    }

    /// One full cycle, in the direction of the arrows.
    static let repeatTurn = GlyphScript(keys: [Key(0, s: 0.85, r: 0), Key(0.3, s: 1.1, r: 330), Key(0.42, s: 1, r: 360)])
    /// Half a cycle, then a small knock: it stays on one song.
    static let repeatOneTurn = GlyphScript(keys: [Key(0, s: 0.85, r: 0), Key(0.2, s: 1, r: 180), Key(0.3, s: 1.2, r: 180), Key(0.44, s: 1, r: 360)])
    /// The lines drop and pile up, like songs joining the queue.
    static let stackIn = GlyphScript(keys: [Key(0, y: -10, o: 0.3), Key(0.16, sx: 1.08, sy: 0.88, y: 2), Key(0.3)])
    static let volumePulse = GlyphScript(keys: [Key(0, sx: 1, sy: 0.6), Key(0.14, sx: 1.1, sy: 1.2), Key(0.28, s: 0.95), Key(0.42, s: 1)])
    static let routeShift = GlyphScript(keys: [Key(0, s: 0.8, y: 5), Key(0.18, s: 1.14), Key(0.34, s: 1)], rings: [Ring()])
    static let arrowDrop = GlyphScript(keys: [Key(0, y: -12, o: 0), Key(0.18, sx: 1.1, sy: 0.84, y: 2), Key(0.34)])
    /// No burst: many songs in a list finish together.
    static let downloadDone = GlyphScript(keys: [Key(0, s: 0.2, o: 0), Key(0.16, s: 1.3), Key(0.3, s: 1)])
    static let pinStick = GlyphScript(keys: [Key(0, r: -25, y: -12, o: 0.3), Key(0.16, sx: 1.15, sy: 0.8, r: 0, y: 2), Key(0.32)])
    static let followArtist = GlyphScript(
        keys: [Key(0, s: 1), Key(0.14, s: 0.9), Key(0.34, s: 1.12, y: -3), Key(0.54, s: 1)],
        rings: [Ring()],
        bits: burst(6, spread: 300, reach: 32, delay: 0.1, life: 0.6, size: 4)
    )
    static let bookmarkDrop = GlyphScript(keys: [Key(0, sx: 0.9, sy: 1.15, y: -12), Key(0.2, sx: 1.08, sy: 0.9, y: 1), Key(0.34)])
    static let playAll = GlyphScript(keys: [Key(0, sx: 1.2, sy: 0.8, x: -5), Key(0.16, sx: 0.95, sy: 1.06, x: 2), Key(0.3, s: 1)])
    static let spinBack = GlyphScript(keys: [Key(0, s: 0.8, r: 0, x: 8), Key(0.25, s: 1.2, r: -300, x: -4), Key(0.42, s: 1, r: -360)])
    static let deflate = GlyphScript(keys: [Key(0, s: 1.1), Key(0.14, s: 0.82), Key(0.26, s: 1)])
    /// One turn: the page opens at once and would cover a longer one.
    static let clockBack = GlyphScript(keys: [Key(0, s: 0.92, r: 0), Key(0.35, s: 1, r: -360)])
    static let bubblePop = GlyphScript(
        keys: [Key(0, s: 0.78), Key(0.16, s: 1.14), Key(0.32, s: 1)],
        bits: burst(3, color: .white, spread: 44, reach: 26, delay: 0.1, stagger: 0.05, life: 0.45, size: 3.5)
    )
    static let glassesOn = GlyphScript(
        keys: [Key(0, r: -8, y: -12), Key(0.24, r: 3, y: 2), Key(0.44)],
        bits: burst(2, spread: 180, reach: 12, delay: 0.26, life: 0.3, size: 2.5)
    )
    static let glassesOff = GlyphScript(keys: [Key(0, y: 4), Key(0.28)])
    /// Ends a quarter turn round, which looks the same on a plus.
    static let plusTurn = GlyphScript(keys: [Key(0, s: 0.8, r: 0), Key(0.22, s: 1.2, r: 100), Key(0.4, s: 1, r: 90)])
    static let crossSwap = GlyphScript(keys: [Key(0, sx: 1, sy: -1), Key(0.24, s: 1.12), Key(0.42, s: 1)])
    static let pop = GlyphScript(keys: [Key(0, s: 0.8), Key(0.14, s: 1.16), Key(0.3, s: 1)])

    static func selfCheck() {
        let all: [GlyphScript] = [
            .pauseStamp(size: 42), .playShoot(size: 17), .repeatTurn, .repeatOneTurn, .stackIn, .volumePulse, .routeShift,
            .arrowDrop, .downloadDone, .pinStick, .followArtist, .bookmarkDrop, .playAll, .spinBack, .deflate, .clockBack,
            .bubblePop, .glassesOn, .glassesOff, .crossSwap, .pop
        ]
        // Every movement has to land where the icon rests, or it jumps at the end.
        for script in all {
            let end = script.pose(at: script.duration)
            assert(end.scaleX == 1 && end.scaleY == 1 && end.x == 0 && end.y == 0 && end.opacity == 1)
            assert(end.rotation.truncatingRemainder(dividingBy: 360) == 0)
        }
        let halfway = GlyphScript(keys: [.init(0, s: 0), .init(1, s: 2)]).pose(at: 0.5)
        assert(halfway.scaleX == 1)
    }
}

private struct GlyphRun: Equatable {
    let start: Date
    let script: GlyphScript

    static func == (a: GlyphRun, b: GlyphRun) -> Bool { a.start == b.start }
}

private struct GlyphRunner<Trigger: Equatable>: ViewModifier {
    let script: GlyphScript?
    let trigger: Trigger
    let playsOnAppear: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var run: GlyphRun?

    func body(content: Content) -> some View {
        // Paused unless it's moving, so a resting icon costs nothing.
        TimelineView(.animation(minimumInterval: nil, paused: run == nil)) { context in
            let time = run.map { context.date.timeIntervalSince($0.start) } ?? 0
            let pose = run?.script.pose(at: time) ?? GlyphPose()
            content
                .scaleEffect(x: pose.scaleX, y: pose.scaleY)
                .rotationEffect(.degrees(pose.rotation))
                .offset(x: pose.x, y: pose.y)
                .opacity(pose.opacity)
                .overlay {
                    if let run {
                        GlyphExtras(script: run.script, time: time)
                    }
                }
        }
        .onChange(of: trigger) { start() }
        .onAppear { if playsOnAppear { start() } }
        .task(id: run?.start) {
            guard let current = run else { return }
            try? await Task.sleep(for: .seconds(current.script.duration))
            if !Task.isCancelled, run == current { run = nil }
        }
    }

    private func start() {
        guard !reduceMotion, let script else { return }
        run = GlyphRun(start: Date(), script: script)
    }
}

private struct GlyphExtras: View {
    static let ringLife = 0.6

    let script: GlyphScript
    let time: Double

    var body: some View {
        ZStack {
            ForEach(Array(script.rings.enumerated()), id: \.offset) { _, ring in
                let progress = min(max((time - ring.delay) / Self.ringLife, 0), 1)
                Circle()
                    .stroke(style(ring.color), lineWidth: 1.5)
                    .frame(width: script.ringSize, height: script.ringSize)
                    .scaleEffect(0.6 + progress * 1.3)
                    .opacity(progress > 0 && progress < 1 ? 0.8 * (1 - progress) : 0)
            }
            ForEach(Array(script.bits.enumerated()), id: \.offset) { _, bit in
                let progress = min(max((time - bit.delay) / bit.life, 0), 1)
                let reach = bit.reach * (1 - pow(1 - progress, 2))
                let radians = bit.angle * .pi / 180
                Circle()
                    .fill(style(bit.color))
                    .frame(width: bit.size, height: bit.size)
                    .scaleEffect(0.5 + progress * 0.6)
                    .offset(x: cos(radians) * reach, y: sin(radians) * reach)
                    .opacity(progress > 0 && progress < 1 ? sin(progress * .pi) : 0)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Without a colour it follows the foreground set outside `glyphMotion`.
    private func style(_ color: Color?) -> AnyShapeStyle {
        color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.foreground)
    }
}

/// Bounces a menu's icon when it is tapped. The system draws menus, so the tap is seen from outside.
private struct MenuTapBounce: ViewModifier {
    @State private var taps = 0

    func body(content: Content) -> some View {
        content
            .symbolEffect(.bounce.byLayer, value: taps)
            .simultaneousGesture(TapGesture().onEnded { taps += 1 })
    }
}

extension View {
    /// Plays a movement each time `trigger` changes. Without a script it does nothing, and Reduce Motion skips it.
    func glyphMotion<Trigger: Equatable>(_ script: GlyphScript?, trigger: Trigger, playsOnAppear: Bool = false) -> some View {
        modifier(GlyphRunner(script: script, trigger: trigger, playsOnAppear: playsOnAppear))
    }

    func bouncesOnTap() -> some View { modifier(MenuTapBounce()) }
}

/// Melts an icon into its next shape, such as play into pause.
struct MorphingGlyph: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
            .animation(.snappy, value: systemName)
    }
}
