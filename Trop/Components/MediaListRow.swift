//
//  MediaListRow.swift
//  Trop
//

import SwiftUI

/// A playlist, album, artist or podcast as a list row: medium artwork on the
/// left, then a title, a subtitle and an optional detail line. Used by the
/// Library list layout, Search result rows and the Add to Playlist sheet.
struct MediaListRow: View {
    let url: String?
    let title: String
    var subtitle: String?
    /// Third line under the subtitle, such as "12 songs • 45:30".
    var detail: String?
    var isCircular = false

    var body: some View {
        HStack(spacing: DesignTokens.menuRowSpacing) {
            AsyncImageView(url: url)
                .frame(width: DesignTokens.artMedium, height: DesignTokens.artMedium)
                .clipShape(isCircular
                    ? AnyShape(Circle())
                    : AnyShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous)))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, DesignTokens.rowVPadding)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
