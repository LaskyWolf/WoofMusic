//
//  AccountButtonView.swift
//  Trop
//
//  Created by 686udjie on 01/07/2026.
//

import SwiftUI

/// Avatar framed in a glass circle, the size of the header's other buttons.
struct AccountButtonView: View {
    var isLoggedIn: Bool
    var accountImageUrl: String?
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            avatar
                .frame(width: 28, height: 28)
                .clipShape(Circle())
                .frame(width: 36, height: 36)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(Circle())
                .overlay(alignment: .topTrailing) {
                    if updater.hasUpdate {
                        // Red like an iOS badge; the ring keeps it apart from the glass.
                        Circle()
                            .fill(.red)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.spring(duration: 0.35, bounce: 0.4), value: updater.hasUpdate)
        }
        .buttonStyle(.plain)
        .accessibilityValue(updater.hasUpdate ? "Update available" : "")
        .task { await updater.check() }
    }

    private var updater: AppUpdater { .shared }

    @ViewBuilder
    private var avatar: some View {
        if isLoggedIn {
            AsyncImageView(url: accountImageUrl)
        } else {
            Circle()
                .fill(Color(.systemGray4))
                .overlay(
                    Text("T")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                )
        }
    }
}

/// The account picture, or a placeholder when signed out.
struct AccountAvatar: View {
    let size: CGFloat
    private let account = AccountState.shared

    var body: some View {
        Group {
            if account.isLoggedIn {
                AsyncImageView(url: account.accountImageUrl)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
