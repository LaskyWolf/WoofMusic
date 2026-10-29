//
//  RadioBloom.swift
//  Trop
//

import SwiftUI

/// A radio started from "Start Radio…": what the full player's bloom shows.
struct RadioBloomEvent: Equatable {
    /// Covers that burst out of the seed cover.
    static let orbCount = 5

    var id = 0
    /// True until the radio's songs arrive or the request fails.
    var isLoading = false
    /// Thumbnails of the first songs after the current one; empty on failure.
    var covers: [String?] = []
    var addedCount = 0
}

/// The Radio Bloom, laid over the whole full player. While the radio loads,
/// teal rings ripple out of the cover and the play button turns over into an
/// antenna. When the songs arrive, their covers burst out around the cover and
/// fly into the queue button, which shows how many were added.
/// The Immersive player's cover fills the top of the screen, so there the
/// rings are round signal waves broadcast from the middle of the artwork.
/// Overlay only: it never touches the cover, the queue or playback.
struct RadioBloomOverlay: View {
    let event: RadioBloomEvent
    /// Global frames, read when the bloom starts.
    let cover: () -> CGRect
    let playButton: () -> CGRect
    let queueButton: () -> CGRect
    let coverCornerRadius: CGFloat
    let isImmersive: Bool
    /// True while the antenna stands in for the play button.
    @Binding var replacesPlayButton: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var origin: CGPoint = .zero
    @State private var ringsStart: Date?
    @State private var orbCovers: [String?] = []
    /// 0 hidden in the cover, 1 around it, 2 in the queue button.
    @State private var orbStage = 0
    @State private var badge: String?
    @State private var run: Task<Void, Never>?

    private static let teal = Color(red: 0.37, green: 0.70, blue: 0.66)
    /// Orb spots around the cover's centre, as fractions of its side.
    private static let orbSpots: [(x: CGFloat, y: CGFloat, tilt: Double)] = [
        (-0.49, -0.37, -12), (0, -0.53, 6), (0.49, -0.37, 12), (-0.54, 0.15, -8), (0.54, 0.15, 8)
    ]
    /// Shortest ripple, so a radio that loads at once still blooms.
    private static let minimumRipple: Duration = .seconds(0.9)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let ringsStart { rings(since: ringsStart) }
            ForEach(Array(orbCovers.enumerated()), id: \.offset) { index, url in orb(url, index: index) }
            if replacesPlayButton { antenna }
            if let badge { badgeView(badge) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin = $0 }
        .allowsHitTesting(false)
        .onChange(of: event.id) { _, _ in
            run?.cancel()
            run = Task { await bloom() }
        }
        .onDisappear {
            run?.cancel()
            replacesPlayButton = false
        }
    }

    /// A global rect in this overlay's space.
    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -origin.x, dy: -origin.y)
    }

    // MARK: - Pieces

    /// Where the bloom grows from: the Card cover, or a square in the middle
    /// of the Immersive artwork (above its faded bottom).
    private var seed: CGRect {
        let rect = local(cover())
        guard isImmersive else { return rect }
        let side = min(rect.width * 0.62, rect.height * 0.7)
        return CGRect(x: rect.midX - side / 2, y: rect.minY + rect.height * 0.42 - side / 2, width: side, height: side)
    }

    /// Three rings a third of a period apart, each growing out of the seed and
    /// fading: the cover's shape on Card, wider circles on Immersive.
    private func rings(since start: Date) -> some View {
        let rect = seed
        let radius = isImmersive ? rect.width / 2 : coverCornerRadius
        let growth: CGFloat = isImmersive ? 1.3 : 0.5
        return TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(start)
            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    let time = elapsed - Double(ring) * 0.3
                    let progress = time < 0 ? 0 : time.truncatingRemainder(dividingBy: 1.2) / 1.2
                    RoundedRectangle(cornerRadius: isImmersive ? radius : radius + 20 * progress, style: .continuous)
                        .strokeBorder(Self.teal, lineWidth: isImmersive ? 3 : 2)
                        .scaleEffect(1 + growth * progress)
                        .opacity(time < 0 ? 0 : 0.85 * (1 - progress))
                }
            }
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
        }
        .transition(.opacity)
    }

    private func orb(_ url: String?, index: Int) -> some View {
        let rect = seed
        let side = min(rect.width, rect.height)
        let spot = Self.orbSpots[index % Self.orbSpots.count]
        let target = local(queueButton())
        let size: CGFloat = 52
        let position: CGPoint = switch orbStage {
        case 0: CGPoint(x: rect.midX, y: rect.midY)
        case 1: CGPoint(x: rect.midX + spot.x * side, y: rect.midY + spot.y * side)
        default: CGPoint(x: target.midX, y: target.midY)
        }
        return AsyncImageView(url: url)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 8, y: 6)
            .rotationEffect(.degrees(orbStage == 1 ? spot.tilt : 0))
            .scaleEffect(orbStage == 1 ? 1 : orbStage == 0 ? 0.3 : 0.25)
            .opacity(orbStage == 0 ? 0 : 1)
            .position(position)
    }

    /// The radio glyph alone, no button behind it, its waves pulsing.
    private var antenna: some View {
        let rect = local(playButton())
        return Image(systemName: "antenna.radiowaves.left.and.right")
            .font(.system(size: 38, weight: .semibold))
            .foregroundStyle(Self.teal)
            .symbolEffect(.variableColor.iterative.reversing, isActive: !reduceMotion)
            .position(x: rect.midX, y: rect.midY)
            // Turns over with the play button, like a coin: in place, never shrinking away.
            .transition(.modifier(active: CoinFlip(angle: 90), identity: CoinFlip(angle: 0)))
    }

    private func badgeView(_ text: String) -> some View {
        let rect = local(queueButton())
        return Text(text)
            .font(.system(size: 11, weight: .heavy).monospacedDigit())
            .foregroundStyle(Color(red: 0.02, green: 0.13, blue: 0.11))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Self.teal))
            // On the icon's top-right corner, like an app badge.
            .position(x: rect.midX + 13, y: rect.midY - 13)
            .transition(.asymmetric(
                insertion: .scale(scale: 0.4).combined(with: .opacity),
                removal: .modifier(active: Dissolve(isGone: true), identity: Dissolve(isGone: false))
            ))
    }

    // MARK: - Script

    private func bloom() async {
        let np = NowPlaying.shared
        let id = event.id
        orbCovers = []
        orbStage = 0
        badge = nil
        withAnimation(.spring(duration: 0.35, bounce: 0.3)) { replacesPlayButton = true }
        if !reduceMotion { withAnimation(.easeOut(duration: 0.2)) { ringsStart = .now } }
        defer {
            // A newer bloom owns the antenna; it resets it itself.
            if np.radioBloom.id == id {
                withAnimation(.easeInOut(duration: 0.3)) {
                    replacesPlayButton = false
                    ringsStart = nil
                }
            }
        }

        // Ripples while the radio loads, at least briefly, for 20 s at most.
        let started = ContinuousClock.now
        while np.radioBloom.id == id, np.radioBloom.isLoading || ContinuousClock.now - started < Self.minimumRipple {
            guard ContinuousClock.now - started < .seconds(20) else { return }
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
        }
        let result = np.radioBloom
        guard result.id == id, result.addedCount > 0 else { return }

        if reduceMotion {
            try? await showBadge(result.addedCount)
            return
        }
        withAnimation(.easeOut(duration: 0.3)) { ringsStart = nil }
        orbCovers = result.covers
        // Out of the cover, around its edges, then down into the queue button.
        try? await Task.sleep(for: .milliseconds(30))
        withAnimation(.spring(duration: 0.45, bounce: 0.35)) { orbStage = 1 }
        do {
            try await Task.sleep(for: .seconds(0.8))
            withAnimation(.easeIn(duration: 0.45)) { orbStage = 2 }
            try await Task.sleep(for: .seconds(0.42))
            orbCovers = []
            try await showBadge(result.addedCount)
        } catch {
            orbCovers = []
            badge = nil
        }
    }

    private func showBadge(_ count: Int) async throws {
        withAnimation(.spring(duration: 0.35, bounce: 0.5)) { badge = "+\(count)" }
        defer { withAnimation(.easeOut(duration: 0.6)) { badge = nil } }
        try await Task.sleep(for: .seconds(1.6))
    }
}

/// Turned edge-on at 90°, so the view is invisible halfway through.
struct CoinFlip: ViewModifier {
    let angle: Double

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .opacity(abs(angle) < 89 ? 1 : 0)
    }
}

/// Fades out through a blur, without moving or shrinking.
private struct Dissolve: ViewModifier {
    let isGone: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: isGone ? 6 : 0)
            .opacity(isGone ? 0 : 1)
    }
}
