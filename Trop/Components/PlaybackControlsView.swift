//
//  PlaybackControlsView.swift
//  Trop
//
//  Created by 686udjie on 2/07/2026.
//

import SwiftUI

/// Shuffle / play / more circular buttons shared by every detail header.
/// Canonicalizes on the PlaylistHeaderView styling (48/64pt, grouped
/// background, accent glow shadow).
struct PlaybackControlsView: View {
    var accent: Color = SettingsStore.shared.accentColor
    var showsShuffle: Bool = true
    var showsMore: Bool = false
    var onPlay: () -> Void
    var onShuffle: () -> Void = {}
    var onMore: () -> Void = {}
    /// A pull-down menu shown in place of the More button (which then
    /// ignores `onMore`).
    var moreMenu: AnyView?

    var body: some View {
        HStack(spacing: 20) {
            if showsShuffle {
                Button(action: onShuffle) {
                    Image(systemName: "shuffle")
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Shuffle")
            }

            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(accent))
                    .shadow(color: accent.opacity(0.4), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play all")

            if let moreMenu {
                moreMenu
            } else if showsMore {
                Button(action: onMore) {
                    MoreCircleGlyph()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }
}

/// The round "⋯" button face used next to Play and Shuffle.
struct MoreCircleGlyph: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(width: 48, height: 48)
            .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
            .contentShape(Circle())
            .accessibilityLabel("More options")
    }
}
