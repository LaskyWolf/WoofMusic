//
//  TabHeaderView.swift
//  Trop
//
//  Created by 686udjie on 18/08/2026.
//

import SwiftUI

/// Shared large-title header with history and account buttons, used by the
/// four tabs. `path` is the tab's navigation stack.
struct TabHeaderView: View {
    @Environment(SettingsStore.self) private var settings
    private let account = AccountState.shared
    let title: String
    @Binding var path: NavigationPath
    /// Shows a "+" button when set (Library: new playlist).
    var onAdd: (() -> Void)?
    /// Shows the Incognito button when set (Search).
    var incognito: Binding<Bool>?

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.largeTitle)
                .fontWeight(.bold)
            Spacer()
            // 36 pt icons with 12 pt between them, so they don't crowd. Each takes taps on 44 pt.
            HStack(spacing: 12) {
                if let onAdd {
                    Button(action: onAdd) {
                        Image(systemName: "plus")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .tapArea(outset: 4)
                    }
                    .buttonStyle(IconPressStyle(motion: .plusTurn))
                    .accessibilityLabel("New Playlist")
                }

                if let incognito {
                    Button { incognito.wrappedValue.toggle() } label: {
                        Image(systemName: "eyeglasses")
                            .font(.title3)
                            .glyphMotion(incognito.wrappedValue ? .glassesOn : .glassesOff, trigger: incognito.wrappedValue)
                            .foregroundStyle(incognito.wrappedValue ? AnyShapeStyle(settings.accentColor) : AnyShapeStyle(.secondary))
                            .frame(width: 36, height: 36)
                            .tapArea(outset: 4)
                    }
                    .buttonStyle(IconPressStyle())
                    .accessibilityLabel(incognito.wrappedValue ? "Turn Off Incognito" : "Turn On Incognito")
                    .sensoryFeedback(.selection, trigger: incognito.wrappedValue)
                }

                Button { path.append(DetailRoute.history) } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .tapArea(outset: 4)
                }
                .buttonStyle(IconPressStyle(motion: .clockBack))
                .accessibilityLabel("History")

                AccountButtonView(
                    isLoggedIn: account.isLoggedIn,
                    accountImageUrl: account.accountImageUrl,
                    onTap: { path.append(DetailRoute.settings) }
                )
                .accessibilityLabel("Account")
            }
        }
        .padding(.horizontal, DesignTokens.screenHPadding)
        .padding(.vertical, 8)
    }
}
