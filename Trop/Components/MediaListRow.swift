//
//  MediaListRow.swift
//  Trop
//

import SwiftUI

/// A playlist, album, artist or podcast as a list row: artwork on the left,
/// title over a details line. Used by the Library list layout and the
/// Add to Playlist sheet.
struct MediaListRow: View {
    let url: String?
    let title: String
    var subtitle: String?
    var isCircular = false

    var body: some View {
        HStack(spacing: DesignTokens.menuRowSpacing) {
            AsyncImageView(url: url)
                .frame(width: DesignTokens.thumbLarge, height: DesignTokens.thumbLarge)
                .clipShape(isCircular
                    ? AnyShape(Circle())
                    : AnyShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous)))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
