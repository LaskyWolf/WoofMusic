import CoreGraphics
import Foundation

/// Shared by the presentation and its executable geometry checks.
struct PlayerTransitionGeometry {
    let expanded: CGRect
    let collapsed: CGRect

    func frame(expansion: CGFloat, dragOffset: CGFloat) -> CGRect {
        let sizeProgress = min(1, max(0, expansion))
        // The spring may overshoot the landing position, but the capsule must
        // retain its final dimensions once the collapse has finished.
        let positionProgress = min(1, expansion)
        return CGRect(
            x: collapsed.minX + (expanded.minX - collapsed.minX) * sizeProgress,
            y: collapsed.minY + (expanded.minY - collapsed.minY) * positionProgress + max(0, dragOffset),
            width: collapsed.width + (expanded.width - collapsed.width) * sizeProgress,
            height: collapsed.height + (expanded.height - collapsed.height) * sizeProgress
        )
    }

    func cornerRadius(expansion: CGFloat, dragOffset: CGFloat) -> CGFloat {
        let progress = min(1, max(0, expansion))
        let capsuleRadius = collapsed.height / 2
        let dragRounding = min(1, max(0, dragOffset) / capsuleRadius)
        return capsuleRadius * (1 - progress + dragRounding * progress)
    }

    /// Finish the visual handoff over the last capsule-height of size change.
    /// At rest the overlay is fully transparent, so removing it cannot switch materials.
    static func presentationOpacity(expansion: CGFloat, expandedHeight: CGFloat, collapsedHeight: CGFloat) -> CGFloat {
        let remainingHeight = max(0, expansion) * max(0, expandedHeight - collapsedHeight)
        let fraction = min(1, remainingHeight / max(1, collapsedHeight))
        return fraction * fraction * (3 - 2 * fraction)
    }

    static func shouldDismiss(distance: CGFloat, predictedDistance: CGFloat, height: CGFloat) -> Bool {
        guard height > 0, distance > 0 else { return false }
        let dismissDistanceFraction: CGFloat = 0.18
        let projectedDistanceFraction: CGFloat = 0.28
        return distance > height * dismissDistanceFraction
            || predictedDistance > height * projectedDistanceFraction
    }
}
