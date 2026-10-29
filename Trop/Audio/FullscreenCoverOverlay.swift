import SwiftUI
import UIKit

/// The current cover over the whole screen, opened by pinching the full
/// player's cover. The whole square cover levitates off the player with a shake
/// and a soft glow, springs to the middle of the screen and lands tilted by a
/// small random angle with a wobble, over a blurred copy of itself and a soft
/// breathing halo. A pinch in or a swipe down flies it back onto the player's cover.
struct FullscreenCoverOverlay<Cover: View>: View {
    /// The player's cover on screen, in global coordinates.
    let source: CGRect
    let sourceCornerRadius: CGFloat
    /// The Immersive cover fades out at the bottom; the copy matches it until it grows.
    let fadesBottom: Bool
    /// Called once the closing animation has landed on the player's cover.
    let onClosed: () -> Void
    /// The player's own cover for a song, so both show the same image.
    let cover: (SongItem) -> Cover

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let player = PlayerController.shared
    private let np = NowPlaying.shared

    @State private var isLifted = false
    @State private var isExpanded = false
    @State private var hasLanded = false
    @State private var isBreathing = false
    @State private var isClosing = false
    @State private var openTrigger = 0
    @State private var idleTimerWasDisabled = false
    /// Picked once per opening: 4° to 12° either way, never upright and never
    /// enough to make the cover look upside down.
    @State private var landingAngle = Double.random(in: 4...12) * (Bool.random() ? 1 : -1)

    private static var cornerRadius: CGFloat { 12 }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            GeometryReader { proxy in
                let screen = proxy.frame(in: .global)
                let start = source.offsetBy(dx: -screen.minX, dy: -screen.minY)
                // Reduce Motion: no movement, the cover only fades in place over the screen.
                let rect = isExpanded || reduceMotion ? Self.landingFrame(in: proxy.size) : start
                let angle = Angle.degrees(isExpanded && !reduceMotion ? landingAngle : 0)

                ZStack {
                    backdrop
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .opacity(isExpanded ? 1 : isLifted ? 0.35 : 0)

                    ZStack {
                        halo(size: rect.size)
                        coverCard(size: rect.size)
                    }
                    // 0–0.5 s: levitates in place, shaking and glowing, with a puff of motes.
                    // 0.5 s on: during the flight it lands past the angle, swings back a
                    // little and settles, while the lift and the glow fade out.
                    .keyframeAnimator(initialValue: OpeningMotion(), trigger: openTrigger) { content, motion in
                        levitating(content, reduceMotion ? OpeningMotion() : motion, size: rect.size)
                    } keyframes: { _ in
                        KeyframeTrack(\.angle) {
                            CubicKeyframe(-3.0, duration: 0.15)
                            CubicKeyframe(2.0, duration: 0.13)
                            CubicKeyframe(0.0, duration: 0.22)
                            CubicKeyframe(landingAngle * 0.5, duration: 0.22)
                            CubicKeyframe(landingAngle * -0.25, duration: 0.18)
                            SpringKeyframe(0.0, duration: 0.35, spring: .smooth)
                        }
                        KeyframeTrack(\.lift) {
                            CubicKeyframe(-16.0, duration: 0.15)
                            CubicKeyframe(-8.0, duration: 0.13)
                            CubicKeyframe(-12.0, duration: 0.22)
                            CubicKeyframe(0.0, duration: 0.4)
                        }
                        KeyframeTrack(\.scale) {
                            CubicKeyframe(1.04, duration: 0.15)
                            LinearKeyframe(1.04, duration: 0.35)
                            CubicKeyframe(1.0, duration: 0.4)
                        }
                        KeyframeTrack(\.glow) {
                            CubicKeyframe(0.7, duration: 0.15)
                            CubicKeyframe(0.6, duration: 0.13)
                            LinearKeyframe(0.6, duration: 0.22)
                            CubicKeyframe(0.0, duration: 0.4)
                        }
                        KeyframeTrack(\.glowHue) {
                            LinearKeyframe(0.0, duration: 0.15)
                            LinearKeyframe(1.0, duration: 0.13)
                        }
                        KeyframeTrack(\.burst) {
                            LinearKeyframe(1.0, duration: 0.6)
                        }
                    }
                    .rotationEffect(angle)
                    .position(x: rect.midX, y: rect.midY)

                    if hasLanded, !reduceMotion {
                        FloatingMotes()
                            .transition(.opacity)
                    }
                }
            }
            .ignoresSafeArea()

            Button {
                player.togglePlayPause()
            } label: {
                PlayPauseGlyph(isPlaying: np.isPlaying, size: 22, color: .white)
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: Circle())
            .accessibilityLabel(np.isPlaying ? "Pause" : "Play")
            .padding(24)
            .opacity(hasLanded ? 1 : 0)
            .scaleEffect(hasLanded ? 1 : 0.6)
            .allowsHitTesting(hasLanded)
        }
        .opacity(reduceMotion && !isExpanded ? 0 : 1)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.height > 80 || value.predictedEndTranslation.height > 240 {
                        close()
                    }
                }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    if value.magnification < 0.8 { close() }
                }
        )
        .sensoryFeedback(.impact(weight: .light), trigger: openTrigger)
        .accessibilityAction(.escape) { close() }
        .onAppear(perform: open)
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
        }
    }

    /// A large square, centred and slightly above the middle of the screen.
    private static func landingFrame(in size: CGSize) -> CGRect {
        let side = max(0, min(size.width - 48, size.height * 0.5))
        return CGRect(
            x: (size.width - side) / 2,
            y: size.height * 0.46 - side / 2,
            width: side,
            height: side
        )
    }

    /// The current cover, crossfading when the song changes.
    private var artwork: some View {
        ZStack {
            if let song = np.currentSong {
                cover(song)
                    .id(song.videoId)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: np.currentSong?.videoId)
    }

    /// The cover blurred over the whole screen, dark enough for the white button.
    private var backdrop: some View {
        ZStack {
            Color.black
            artwork
                .blur(radius: 60, opaque: true)
                .saturation(1.3)
            Color.black.opacity(0.3)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The cover again, a little larger and heavily blurred, glowing behind the card.
    private func halo(size: CGSize) -> some View {
        artwork
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .scaleEffect(1.1 * (isBreathing ? 1.08 : 1))
            .blur(radius: 40)
            .opacity(isExpanded ? (isBreathing ? 0.85 : 0.55) : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The opening keyframes on the cover: a glow behind it shifting from light
    /// blue to lavender, the puff of motes, the shake, the growth and the lift.
    private func levitating(_ content: some View, _ motion: OpeningMotion, size: CGSize) -> some View {
        let tint = Color(
            red: (160 + 40 * motion.glowHue) / 255,
            green: (200 - 40 * motion.glowHue) / 255,
            blue: 1
        )
        return content
            .background {
                if motion.glow > 0 {
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .fill(tint)
                        .padding(-10)
                        .blur(radius: 24)
                        .opacity(motion.glow)
                }
            }
            .overlay(alignment: .bottom) {
                // Taller than the cover, so the motes rise off its top edge.
                if motion.burst > 0, motion.burst < 1 {
                    MoteBurst(progress: motion.burst)
                        .frame(width: size.width, height: size.height * 1.5)
                }
            }
            .rotationEffect(.degrees(motion.angle))
            .scaleEffect(CGFloat(motion.scale))
            .offset(y: CGFloat(motion.lift))
    }

    private func coverCard(size: CGSize) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: isExpanded || reduceMotion ? Self.cornerRadius : sourceCornerRadius,
            style: .continuous
        )
        return artwork
            .frame(width: size.width, height: size.height)
            .mask {
                // Same fade as the Immersive cover, filled in as the cover grows.
                ZStack {
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0),
                            .init(color: .white, location: 0.62),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    Color.white.opacity(fadesBottom && !isExpanded ? 0 : 1)
                }
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(isExpanded || isLifted ? 0.4 : 0), radius: 30, y: 16)
            .scaleEffect(isBreathing ? 1.025 : 1)
    }

    private func open() {
        idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        openTrigger += 1

        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.25), completionCriteria: .logicallyComplete) {
                isExpanded = true
            } completion: {
                withAnimation(.easeOut(duration: 0.25)) { hasLanded = true }
            }
            return
        }
        // Levitate in place while the backdrop starts fading in (the keyframes add
        // the shake and the glow), spring to the middle with an overshoot while
        // tilting, then settle into the breathing loop.
        withAnimation(.easeInOut(duration: 0.5), completionCriteria: .logicallyComplete) {
            isLifted = true
        } completion: {
            guard !isClosing else { return }
            withAnimation(.spring(duration: 0.5, bounce: 0.4), completionCriteria: .logicallyComplete) {
                isLifted = false
                isExpanded = true
            } completion: {
                guard !isClosing else { return }
                withAnimation(.easeOut(duration: 0.3)) { hasLanded = true }
                // 3.5 s each way: one full breath every 7 s.
                withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) {
                    isBreathing = true
                }
            }
        }
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        withAnimation(
            reduceMotion ? .easeInOut(duration: 0.25) : .smooth(duration: 0.4),
            completionCriteria: .logicallyComplete
        ) {
            isLifted = false
            isExpanded = false
            hasLanded = false
            isBreathing = false
        } completion: {
            onClosed()
        }
    }
}

/// The values the opening keyframes animate, all at rest by default.
private struct OpeningMotion {
    /// Degrees, added to the landing tilt.
    var angle = 0.0
    /// Points up (negative) from the cover's frame.
    var lift = 0.0
    var scale = 1.0
    /// Opacity of the glow behind the cover.
    var glow = 0.0
    /// 0 is light blue, 1 is lavender.
    var glowHue = 0.0
    /// Runs 0 to 1 once; the motes show only in between.
    var burst = 0.0
}

/// A one-shot puff of tiny glowing dots rising off the cover, drawn at `progress`.
private struct MoteBurst: View {
    let progress: Double

    var body: some View {
        Canvas { context, size in
            var glow = context
            glow.addFilter(.blur(radius: 4))
            for index in 0..<5 {
                let i = Double(index)
                // Staggered starts, each mote rising for 60% of the burst.
                let local = min(max((progress - i * 0.08) / 0.6, 0), 1)
                let opacity = sin(local * .pi) * 0.9
                guard opacity > 0.01 else { continue }
                let x = size.width * CGFloat(0.12 + i * 0.19)
                let y = size.height * CGFloat(0.9 - local * 0.7)
                let color = index.isMultiple(of: 2) ? FloatingMotes.tint : .white

                glow.fill(
                    Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10)),
                    with: .color(color.opacity(opacity * 0.6))
                )
                context.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)), with: .color(color.opacity(opacity)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A few tiny glowing dots drifting slowly up from the bottom of the screen
/// and fading out, each on its own staggered loop. One Canvas redraws them all.
private struct FloatingMotes: View {
    private static let count = 4
    static let tint = Color(red: 0.75, green: 0.88, blue: 1)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                var glow = context
                glow.addFilter(.blur(radius: 4))
                for index in 0..<Self.count {
                    let i = Double(index)
                    let period = 14 + i * 1.5
                    // Staggered: each mote is at a different point of its rise.
                    let progress = (time + i / Double(Self.count) * period)
                        .truncatingRemainder(dividingBy: period) / period
                    let column = 0.15 + i * 0.23
                    let x = size.width * CGFloat(column) + CGFloat(10 * sin(time * 0.4 + i))
                    let y = size.height * CGFloat(1.02 - progress * 0.55)
                    let opacity = sin(progress * .pi) * 0.8
                    let color = index.isMultiple(of: 2) ? Self.tint : .white

                    glow.fill(
                        Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10)),
                        with: .color(color.opacity(opacity * 0.6))
                    )
                    context.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)), with: .color(color.opacity(opacity)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
