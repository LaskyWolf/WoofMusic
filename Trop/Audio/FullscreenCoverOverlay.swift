import SwiftUI
import UIKit

/// The current cover over the whole screen, opened by pinching the full
/// player's cover. It lifts off the player, grows to fill the screen and then
/// slowly breathes under a few drifting motes. A pinch in or a swipe down
/// shrinks it back onto the player's cover.
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

    private var glowColor: Color {
        (np.accentColor ?? Color(red: 0.6, green: 0.8, blue: 1)).mix(with: .white, by: 0.25)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            GeometryReader { proxy in
                let screen = proxy.frame(in: .global)
                let start = source.offsetBy(dx: -screen.minX, dy: -screen.minY)
                // Reduce Motion: no movement, the cover only fades in place over the screen.
                let rect = isExpanded || reduceMotion ? CGRect(origin: .zero, size: proxy.size) : start

                ZStack {
                    Color.black.opacity(isExpanded ? 1 : 0)

                    coverCard(size: rect.size)
                        .position(x: rect.midX, y: rect.midY)

                    RadialGradient(
                        colors: [.clear, .black.opacity(0.55)],
                        center: .center,
                        startRadius: min(proxy.size.width, proxy.size.height) * 0.35,
                        endRadius: max(proxy.size.width, proxy.size.height) * 0.75
                    )
                    .opacity(isExpanded ? 1 : 0)
                    .allowsHitTesting(false)

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

    private func coverCard(size: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: isExpanded ? 0 : sourceCornerRadius, style: .continuous)
        // Breathing between 1.04 and 1.07 keeps the screen edges covered while it rises 6 pt.
        let scale: CGFloat = isLifted ? 1.05 : isBreathing ? 1.07 : (hasLanded && !reduceMotion) ? 1.04 : 1
        let rise: CGFloat = isLifted ? -18 : isBreathing ? -6 : 0
        return ZStack {
            if let song = np.currentSong {
                cover(song)
                    .id(song.videoId)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: np.currentSong?.videoId)
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
        .background {
            shape
                .fill(glowColor)
                .blur(radius: 28)
                .opacity(isLifted ? 0.7 : 0)
        }
        .keyframeAnimator(initialValue: Double.zero, trigger: openTrigger) { content, angle in
            content.rotationEffect(.degrees(reduceMotion ? 0 : angle))
        } keyframes: { _ in
            CubicKeyframe(Double(-3), duration: 0.2)
            CubicKeyframe(Double(2), duration: 0.25)
            SpringKeyframe(Double.zero, duration: 0.75, spring: .smooth)
        }
        .scaleEffect(scale)
        .offset(y: rise)
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
        // Lift-off in place, then grow to the screen, then settle into the breathing loop.
        withAnimation(.easeOut(duration: 0.45), completionCriteria: .logicallyComplete) {
            isLifted = true
        } completion: {
            guard !isClosing else { return }
            withAnimation(.smooth(duration: 0.75), completionCriteria: .logicallyComplete) {
                isLifted = false
                isExpanded = true
            } completion: {
                guard !isClosing else { return }
                withAnimation(.easeInOut(duration: 0.8), completionCriteria: .logicallyComplete) {
                    hasLanded = true
                } completion: {
                    guard !isClosing else { return }
                    withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                        isBreathing = true
                    }
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

/// Small glowing dots drifting up from the bottom of the screen and fading
/// out, each on its own staggered loop. One Canvas redraws them all.
private struct FloatingMotes: View {
    private static let count = 7
    private static let tint = Color(red: 0.75, green: 0.88, blue: 1)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                var glow = context
                glow.addFilter(.blur(radius: 4))
                for index in 0..<Self.count {
                    let i = Double(index)
                    let period = 9 + i * 0.7
                    // Staggered: each mote is at a different point of its rise.
                    let progress = (time + i / Double(Self.count) * period)
                        .truncatingRemainder(dividingBy: period) / period
                    let column = 0.1 + (i * 0.37).truncatingRemainder(dividingBy: 0.8)
                    let x = size.width * CGFloat(column) + CGFloat(10 * sin(time * 0.6 + i))
                    let y = size.height * CGFloat(1.02 - progress * 0.55)
                    let opacity = sin(progress * .pi) * 0.8
                    let color = index.isMultiple(of: 2) ? Self.tint : .white

                    glow.fill(
                        Path(ellipseIn: CGRect(x: x - 6, y: y - 6, width: 12, height: 12)),
                        with: .color(color.opacity(opacity * 0.6))
                    )
                    context.fill(Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)), with: .color(color.opacity(opacity)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
