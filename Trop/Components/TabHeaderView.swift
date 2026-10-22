//
//  TabHeaderView.swift
//  Trop
//
//  Created by 686udjie on 18/08/2026.
//

import SwiftUI

/// Shared large-title header with history and account buttons,
/// used by the Home and Library tabs.
struct TabHeaderView: View {
    let title: String
    var accountIsLoggedIn: Bool = false
    var accountImageUrl: String?
    var onHistory: () -> Void
    var onAccount: () -> Void
    /// Shows a "+" button when set (Library: new playlist).
    var onAdd: (() -> Void)?

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.largeTitle)
                .fontWeight(.bold)
            Spacer()
            // 36 pt tap targets with 12 pt between them, so the icons don't crowd.
            HStack(spacing: 12) {
                if let onAdd {
                    Button(action: onAdd) {
                        Image(systemName: "plus")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New Playlist")
                }

                Button(action: onHistory) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("History")

                AccountButtonView(
                    isLoggedIn: accountIsLoggedIn,
                    accountImageUrl: accountImageUrl,
                    onTap: onAccount
                )
                .accessibilityLabel("Account")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
