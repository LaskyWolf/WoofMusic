//
//  MediaGridCell.swift
//  Trop
//
//  Created by 686udjie on 2/07/2026.
//

import SwiftUI

/// Card title followed by a small ">" that says the card opens a page.
struct TitleWithChevron: View {
    let title: String
    var font: Font = .caption
    var lineLimit = 2

    var body: some View {
        HStack(alignment: .top, spacing: 3) {
            Text(title)
                .font(font)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .lineLimit(lineLimit)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.top, 3)
                .accessibilityHidden(true)
        }
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

            TitleWithChevron(title: title)
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
