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
        }
        .buttonStyle(.plain)
    }

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
