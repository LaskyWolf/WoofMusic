//
//  PlayerHeaderViews.swift
//  Trop
//
//  Created by 686udjie on 2/07/2026.
//

import SwiftUI

/// Title + artist marquee block shared by the FullPlayer, Queue and Lyrics
/// header rows.
struct PlayerTitleBlock: View {
    var title: String
    var artist: String
    var spacing: CGFloat = 2
    var titleFont: Font = .body.weight(.semibold)
    var onArtistTap: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            // Short title instead of a scrolling one; lists show the full title.
            Text(SongTitle.display(title))
                .font(titleFont)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityLabel(title)
                .allowsHitTesting(false)

            if !artist.isEmpty {
                if let onArtistTap {
                    Button(action: onArtistTap) {
                        artistLabel
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View artist: \(artist)")
                } else {
                    artistLabel
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var artistLabel: some View {
        Text(artist)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// White heart toggle for player surfaces (FullPlayer, Queue).
struct PlayerLikeButton: View {
    var isLiked: Bool
    var activeColor: Color = .red
    var inactiveColor: Color = .white
    var fontSize: CGFloat = 17
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.system(size: fontSize, weight: .regular))
                .foregroundStyle(isLiked ? activeColor : inactiveColor)
                .frame(width: 36, height: 36)
        }
    }
}

/// White ⋮ button for player surfaces. The options sheet stays owned by the caller.
/// Label for the full player's "⋯" song menu.
struct PlayerOptionsGlyph: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Song options")
    }
}
