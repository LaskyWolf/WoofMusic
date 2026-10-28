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
                .foregroundStyle(.primary)
                .frame(width: 24, height: 24)
                .glassEffect(.regular, in: Circle())
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

/// Square artwork card with a two-line title and optional subtitle, shared by
/// the artist page carousels, Search's album carousel and Library's grid.
/// Large covers by default, like Home's carousel cards; a nil `size` fills
/// the width it is given (Library's grid columns).
struct MediaGridCell: View {
    var thumbnailUrl: String?
    var title: String
    var subtitle: String?
    var size: CGFloat? = DesignTokens.artLarge
    /// Shows the ">" badge: the card opens a page.
    var opensPage = true
    /// The route this card pushes; its page zooms out of the cover.
    var zoomRoute: DetailRoute? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.cardInnerSpacing) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .frame(width: size)
                .overlay { AsyncImageView(url: thumbnailUrl) }
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
                .coverZoomSource(zoomRoute)
                .opensPageBadge(opensPage)

            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .lineLimit(2)
                .frame(maxWidth: size ?? .infinity, alignment: .leading)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: size ?? .infinity, alignment: .leading)
            }
        }
        .frame(width: size)
    }
}

struct ArtistCircleCell: View {
    var thumbnailUrl: String?
    var name: String
    /// nil fills the width it is given, like `MediaGridCell`.
    var size: CGFloat? = DesignTokens.artLarge

    var body: some View {
        VStack(spacing: DesignTokens.cardInnerSpacing) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .frame(width: size)
                .overlay { AsyncImageView(url: thumbnailUrl) }
                .clipShape(Circle())
            Text(name)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            ArtistKindLabel(name: name)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(width: size)
    }
}
