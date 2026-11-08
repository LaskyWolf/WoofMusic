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
                    .buttonStyle(IconPressStyle(motion: .crossSwap))
                    .accessibilityLabel("Shuffle")
                Button(action: onPlay) { HeaderRoundIcon(systemImage: "play.fill", primary: accentColor) }
                    .buttonStyle(IconPressStyle(motion: .playAll))
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
                Image(systemName: "arrow.down.to.line")
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
    /// Large in the landscape side column: the buttons get their own row under
    /// the cover, bigger and spread across the column.
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        if controlSize == .large {
            VStack(spacing: 20) {
                HStack(alignment: .center, spacing: 14) {
                    coverView
                    VStack(alignment: .leading, spacing: 3) { titleLines }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 20) { buttons() }
                    .buttonStyle(ZoomPressStyle(scale: 0.92))
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, DesignTokens.screenHPadding)
            .accessibilityElement(children: .contain)
        } else {
            compactBody
        }
    }

    private var coverView: some View {
        cover()
            .frame(width: DesignTokens.artLarge, height: DesignTokens.artLarge)
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    @ViewBuilder
    private var titleLines: some View {
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
    }

    private var compactBody: some View {
        HStack(alignment: .top, spacing: 14) {
            coverView

            VStack(alignment: .leading, spacing: 3) {
                titleLines
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

/// `DetailHeaderCard` already shows the title, so the bar repeats it only once
/// the cover has scrolled away. A pinned title, like a selection count, always shows.
private struct DetailBarTitle: ViewModifier {
    let title: String
    let pinnedTitle: String?
    @State private var isHeaderScrolledAway = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > DesignTokens.artLarge
            } action: { _, isScrolledAway in
                isHeaderScrolledAway = isScrolledAway
            }
            .navigationTitle(pinnedTitle ?? (isHeaderScrolledAway ? title : ""))
    }
}

extension View {
    /// Goes on the ScrollView of a page that starts with `DetailHeaderCard`.
    func detailBarTitle(_ title: String, pinnedTitle: String? = nil) -> some View {
        modifier(DetailBarTitle(title: title, pinnedTitle: pinnedTitle))
    }
}

/// Round icon face for the header card buttons (same shape as the New
/// Releases card buttons). `primary` fills it with that colour and a white glyph.
struct HeaderRoundIcon: View {
    let systemImage: String
    var primary: Color?
    var tint: Color = .primary
    var motion: GlyphScript?
    var trigger: AnyHashable = 0

    /// Bigger in the landscape side column (`controlSize` large).
    @Environment(\.controlSize) private var controlSize

    private var scale: CGFloat { controlSize == .large ? 1.3 : 1 }
    /// The filled play button is larger than the other buttons beside it.
    private var size: CGFloat { (primary == nil ? 38 : 50) * scale }

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: (primary == nil ? 15 : 19) * scale, weight: .bold))
            .contentTransition(.symbolEffect(.replace))
            .glyphMotion(motion, trigger: trigger)
            .foregroundStyle(primary == nil ? tint : .white)
            .frame(width: size, height: size)
            .background(Circle().fill(primary ?? Color.primary.opacity(0.1)))
            .contentShape(Circle())
    }
}

/// The shuffle and play buttons of a detail page header.
struct HeaderPlayButtons: View {
    var shuffleLabel = "Shuffle"
    var playLabel = "Play all"
    let onShuffle: () -> Void
    let onPlay: () -> Void

    var body: some View {
        Button(action: onShuffle, label: {
            HeaderRoundIcon(systemImage: "shuffle")
        })
        .buttonStyle(IconPressStyle(motion: .crossSwap))
        .accessibilityLabel(shuffleLabel)

        Button(action: onPlay, label: {
            HeaderRoundIcon(systemImage: "play.fill", primary: SettingsStore.shared.accentColor)
        })
        .buttonStyle(IconPressStyle(motion: .playAll))
        .accessibilityLabel(playLabel)
    }
}
