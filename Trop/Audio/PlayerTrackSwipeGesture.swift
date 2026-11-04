import SwiftUI
import UIKit

/// Reject vertical motion before recognition so the player zoom can dismiss.
struct PlayerTrackSwipeGesture: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var onChanged: (CGFloat) -> Void
    /// The final sideways translation, projected forward by the release velocity.
    var onEnded: (_ predictedEnd: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = false
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // Window coordinates, like the dismiss gesture: the player moves, the window doesn't.
        let translation = recognizer.translation(in: nil).x
        switch recognizer.state {
        case .began, .changed:
            onChanged(translation)
        case .ended:
            // Where a scroll view with fast deceleration would coast to after this flick.
            let rate = UIScrollView.DecelerationRate.fast.rawValue
            let velocity = recognizer.velocity(in: nil).x
            onEnded(translation + velocity / 1000 * rate / (1 - rate))
        case .cancelled, .failed:
            onEnded(0)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            // Only a clearly sideways swipe changes track; anything steeper
            // than ~27° is left to the pull-down dismiss.
            return abs(velocity.x) > 2 * abs(velocity.y)
        }
    }
}

/// The paging shared by the mini and full player: the current cover sits
/// between its queue neighbours and the pages follow the finger.
@MainActor
enum TrackSwipe {
    enum Direction {
        case next
        case previous
    }

    /// The share of the page width a release has to cover to change song.
    static let commitFraction: CGFloat = 0.35
    static let springBack = Animation.spring(response: 0.3, dampingFraction: 0.85)

    /// Slides the pages one full width, then moves the queue. The queue moves
    /// only once the slide has fully landed (no bounce), so the page that
    /// becomes current is already where the old one was: no jump.
    static func commit(
        _ direction: Direction,
        pageWidth: CGFloat,
        offset: Binding<CGFloat>,
        isCommitting: Binding<Bool>
    ) {
        isCommitting.wrappedValue = true
        withAnimation(.spring(duration: 0.3, bounce: 0), completionCriteria: .logicallyComplete) {
            offset.wrappedValue = direction == .next ? -pageWidth : pageWidth
        } completion: {
            switch direction {
            case .next: NowPlaying.shared.playNext()
            case .previous: NowPlaying.shared.playPrevious()
            }
            withAnimation(nil) { offset.wrappedValue = 0 }
            isCommitting.wrappedValue = false
        }
    }
}
