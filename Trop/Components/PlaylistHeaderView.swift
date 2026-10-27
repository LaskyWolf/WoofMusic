//
//  PlaylistHeaderView.swift
//  Trop
//
//  Created by 686udjie on 28/08/2026.
//

import SwiftUI

struct PlaylistHeaderView: View {
    let title: String
    let subtitle: String?
    let thumbnailUrl: String?
    let thumbnails: [String]
    let songCount: Int
    let duration: Int
    let accentColor: Color
    let onPlay: () -> Void
    let onShuffle: () -> Void
    let onMore: (() -> Void)?

    init(
        title: String,
        subtitle: String? = nil,
        thumbnailUrl: String? = nil,
        thumbnails: [String] = [],
        songCount: Int,
        duration: Int,
        accentColor: Color = .accentColor,
        onPlay: @escaping () -> Void,
        onShuffle: @escaping () -> Void,
        onMore: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.thumbnailUrl = thumbnailUrl
        self.thumbnails = thumbnails
        self.songCount = songCount
        self.duration = duration
        self.accentColor = accentColor
        self.onPlay = onPlay
        self.onShuffle = onShuffle
        self.onMore = onMore
    }

    var body: some View {
        DetailHeaderCard(
            meta: songCount > 0 ? metadataLine : "",
            title: title
        ) {
            artwork
        } secondary: {
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } buttons: {
            if songCount > 0 {
                if let onMore {
                    Button(action: onMore) { HeaderRoundIcon(systemImage: "ellipsis") }
                        .accessibilityLabel("More options")
                }
                Button(action: onShuffle) { HeaderRoundIcon(systemImage: "shuffle") }
                    .accessibilityLabel("Shuffle")
                Button(action: onPlay) { HeaderRoundIcon(systemImage: "play.fill", primary: accentColor) }
                    .accessibilityLabel("Play all")
            }
        }
        .padding(.vertical, 20)
        // Same backdrop as the playlist, album and artist headers.
        .background(alignment: .top) {
            BlurredArtworkBackdrop(url: thumbnailUrl ?? thumbnails.first)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if thumbnails.count >= 4 {
            ArtworkMosaicView(urls: thumbnails, size: DesignTokens.artLarge)
        } else if let url = thumbnailUrl ?? thumbnails.first {
            AsyncImageView(url: url)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous))
        } else {
            artPlaceholder
        }
    }

    private var artPlaceholder: some View {
        RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        accentColor.opacity(0.9),
                        accentColor.opacity(0.55),
                        Color.teal.opacity(0.65)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .symbolRenderingMode(.hierarchical)
            }
    }

    private var metadataLine: String {
        var parts: [String] = []
        parts.append("\(songCount) \(songCount == 1 ? "song" : "songs")")
        if duration > 0 {
            parts.append(duration.formattedDuration)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Header card

/// Header shared by the artist, playlist, album and Downloads pages: a
/// large cover on the left over the blurred artwork; kind line, title,
/// secondary line and round buttons on the right.
struct DetailHeaderCard<Cover: View, Secondary: View, Buttons: View>: View {
    let meta: String
    let title: String
    @ViewBuilder var cover: () -> Cover
    @ViewBuilder var secondary: () -> Secondary
    @ViewBuilder var buttons: () -> Buttons

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            cover()
                .frame(width: DesignTokens.artLarge, height: DesignTokens.artLarge)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 3) {
                if !meta.isEmpty {
                    Text(meta)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(title)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                secondary()
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    buttons()
                }
                .buttonStyle(ZoomPressStyle(scale: 0.92))
            }
            .frame(maxWidth: .infinity, minHeight: DesignTokens.artLarge, alignment: .leading)
        }
        .padding(.horizontal, DesignTokens.screenHPadding)
        .accessibilityElement(children: .contain)
    }
}

/// Round icon face for the header card buttons (same shape as the New
/// Releases card buttons). `primary` fills it with that colour and a white glyph.
struct HeaderRoundIcon: View {
    let systemImage: String
    var primary: Color?
    var tint: Color = .primary

    /// The filled play button is larger than the other buttons beside it.
    private var size: CGFloat { primary == nil ? 38 : 50 }

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: primary == nil ? 15 : 19, weight: .bold))
            .contentTransition(.symbolEffect(.replace))
            .foregroundStyle(primary == nil ? tint : .white)
            .frame(width: size, height: size)
            .background(Circle().fill(primary ?? Color.primary.opacity(0.1)))
            .contentShape(Circle())
    }
}
