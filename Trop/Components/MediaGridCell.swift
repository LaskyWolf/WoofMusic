//
//  MediaGridCell.swift
//  Trop
//
//  Created by 686udjie on 2/07/2026.
//

import SwiftUI

/// Small ">" circle in the bottom right corner of a cover: the card opens a page.
private struct OpensPageBadge: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.black.opacity(0.55), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                .padding(6)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Marks an album or playlist cover as a link to its page.
    @ViewBuilder
    func opensPageBadge(_ isOn: Bool = true) -> some View {
        if isOn { modifier(OpensPageBadge()) } else { self }
    }
}

/// Square artwork card with two-line title + optional subtitle, shared by the
/// artist albums carousel and search album carousel. `size` fixes the width
/// for carousels; nil sizes flexibly for grids.
struct MediaGridCell: View {
    var thumbnailUrl: String?
    var title: String
    var subtitle: String?
    var size: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.cardInnerSpacing) {
            AsyncImageView(url: thumbnailUrl)
                .aspectRatio(1, contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
                .opensPageBadge()

            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .lineLimit(2)
                .frame(width: size, alignment: .leading)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: size, alignment: .leading)
            }
        }
        .frame(width: size)
    }
}

/// Large centered artwork for detail headers (album/playlist/podcast),
/// replacing the copy-pasted 200pt framed/clipped/shadowed blocks.
struct HeroArtworkView: View {
    var url: String?
    var size: CGFloat = DesignTokens.heroArtwork

    var body: some View {
        AsyncImageView(url: url)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.tileRadius))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }
}
