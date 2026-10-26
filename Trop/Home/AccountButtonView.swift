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
