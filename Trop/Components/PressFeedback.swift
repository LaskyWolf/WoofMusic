//
//  PressFeedback.swift
//  Trop
//

import SwiftUI

/// Zooms a card in while it is pressed.
struct ZoomPressStyle: ButtonStyle {
    var scale: CGFloat = 1.06

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(duration: 0.25, bounce: 0.35), value: configuration.isPressed)
    }
}

extension View {
    /// Lights up the row's background and zooms it slightly while it is touched.
    func rowPressFeedback() -> some View { modifier(RowPressFeedback()) }
}

private struct RowPressFeedback: ViewModifier {
    @State private var isPressed = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(isPressed ? 0.14 : 0))
                    .padding(.horizontal, 6)
            )
            .scaleEffect(isPressed ? 1.03 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: isPressed)
            // Never fires: it only reports the touch, and the tap still goes through.
            .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 16, pressing: { isPressed = $0 }, perform: {})
    }
}
