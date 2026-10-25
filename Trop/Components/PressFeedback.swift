//
//  PressFeedback.swift
//  Trop
//

import SwiftUI

/// How long the feedback stays after the finger lifts, so a quick tap still shows it.
private let pressLinger: Duration = .milliseconds(200)

/// Shrinks a card while it is pressed, also on a quick tap.
struct ZoomPressStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        ZoomPressLabel(configuration: configuration, scale: scale)
    }
}

private struct ZoomPressLabel: View {
    let configuration: ButtonStyleConfiguration
    let scale: CGFloat
    @State private var zoomed = false

    var body: some View {
        configuration.label
            .scaleEffect(zoomed ? scale : 1)
            .animation(.spring(duration: 0.2, bounce: 0.3), value: zoomed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    zoomed = true
                } else {
                    Task {
                        try? await Task.sleep(for: pressLinger)
                        if !configuration.isPressed { zoomed = false }
                    }
                }
            }
    }
}

extension View {
    /// Lights up the row's background with a brighter outline and shrinks it slightly while it is touched.
    func rowPressFeedback() -> some View { modifier(RowPressFeedback()) }
}

private struct RowPressFeedback: ViewModifier {
    @State private var isPressed = false
    @State private var isLit = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(isLit ? 0.14 : 0))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(isLit ? 0.5 : 0), lineWidth: 1.5)
                    )
                    .padding(.horizontal, 6)
            )
            .scaleEffect(isLit ? 0.97 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.3), value: isLit)
            // Never fires: it only reports the touch, and the tap still goes through.
            .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 16, pressing: { pressing in
                isPressed = pressing
                if pressing {
                    isLit = true
                } else {
                    Task {
                        try? await Task.sleep(for: pressLinger)
                        if !isPressed { isLit = false }
                    }
                }
            }, perform: {})
    }
}
