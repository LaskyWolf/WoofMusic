//
//  Haptics.swift
//  Trop
//

import UIKit

/// The app's taps: a light impact for a control that acts, a selection tick for
/// a choice, success and error for the end of something that ran out of sight.
/// For a handful of places use SwiftUI's `sensoryFeedback`; this is for code that
/// is not tied to a view update, such as a finished download.
@MainActor
enum Haptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
