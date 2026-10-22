import SwiftUI
import UIKit

/// Pull-down to close the full player, like Apple Music: the player follows
/// the finger and closes when released far or fast enough.
///
/// The zoom transition's own pull-down only starts when no other gesture
/// claims the touch first, so it often lost to the buttons, sliders and track
/// swipe. This recognizer goes first: every other gesture except taps and
/// long presses waits until it has decided the touch isn't a downward pull.
struct PlayerDismissGesture: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: (_ distance: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        recognizer.maximumNumberOfTouches = 1
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // Window coordinates: the player moves while dragged, the window doesn't.
        let distance = recognizer.translation(in: nil).y
        switch recognizer.state {
        case .began, .changed:
            onChanged(distance)
        case .ended:
            onEnded(distance, recognizer.velocity(in: nil).y)
        case .cancelled, .failed:
            onEnded(0, 0)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: nil)
            // Downward and more vertical than sideways.
            return velocity.y > 0 && velocity.y > abs(velocity.x)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            // Taps and long presses stay instant; everything else (the zoom
            // dismiss, sliders, track swipe) waits for this one to fail.
            !(other is UITapGestureRecognizer || other is UILongPressGestureRecognizer)
        }
    }
}
