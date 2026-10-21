import SwiftUI

/// An opaque artwork card shrinks and fades over the native accessory.
/// The accessory owns the only glass background throughout the transition.
struct PlayerPresentation: View, Animatable {
    var expansion: CGFloat
    var dragOffset: CGFloat
    let geometry: PlayerTransitionGeometry
    let safeAreaInsets: EdgeInsets
    let onCollapse: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat, CGFloat, CGFloat) -> Void
    let onDragCancelled: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(SettingsStore.self) private var settings
    private let np = NowPlaying.shared

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(expansion, dragOffset) }
        set {
            expansion = newValue.first
            dragOffset = newValue.second
        }
    }

    var body: some View {
        let progress = min(1, max(0, expansion))
        let frame = reduceMotion ? geometry.expanded : geometry.frame(expansion: expansion, dragOffset: dragOffset)
        let radius = reduceMotion ? 0 : geometry.cornerRadius(expansion: expansion, dragOffset: dragOffset)

        ZStack(alignment: .top) {
            LinearGradient(
                colors: settings.playerBackgroundStyle == .solid ? [.black, .black] : np.dominantColors,
                startPoint: .top,
                endPoint: .bottom
            )
            // Crop the lower background instead of compressing bright colors into the capsule.
            .frame(width: geometry.expanded.width, height: geometry.expanded.height)
            .frame(width: frame.width, height: frame.height, alignment: .bottom)

            FullPlayerView(
                onCollapse: onCollapse,
                artworkTopInset: safeAreaInsets.top,
                onDragChanged: onDragChanged,
                onDragEnded: onDragEnded,
                onDragCancelled: onDragCancelled
            )
            .frame(width: geometry.expanded.width,
                   height: geometry.expanded.height - safeAreaInsets.top - safeAreaInsets.bottom)
            .padding(.top, safeAreaInsets.top)
            .padding(.bottom, safeAreaInsets.bottom)
            .frame(width: geometry.expanded.width, height: geometry.expanded.height)
            .scaleEffect(reduceMotion ? 1 : max(0.01, progress), anchor: .top)
            .opacity(reduceMotion ? 1 : min(1, progress * 2.5))
            .allowsHitTesting(progress >= 0.999)
            .accessibilityHidden(progress < 0.999)
        }
        .frame(width: frame.width, height: frame.height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .opacity(reduceMotion ? progress : PlayerTransitionGeometry.presentationOpacity(
            expansion: expansion, expandedHeight: geometry.expanded.height, collapsedHeight: geometry.collapsed.height
        ))
        .position(x: frame.midX, y: frame.midY - safeAreaInsets.top)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onCollapse)
        .transaction { $0.animation = nil }
    }
}
