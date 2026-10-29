//
//  ShimmerLoadingView.swift
//  Trop
//
//  Created by 686udjie on 01/07/2026.
//

import SwiftUI

// MARK: - Shimmer fill

struct ShimmerFill: View {
    var radius: CGFloat = 8

    /// Set by `shimmerClock()` on a skeleton's root.
    @Environment(\.shimmerPhase) private var sharedPhase

    var body: some View {
        // A fill outside a clocked skeleton runs its own timeline.
        if let sharedPhase {
            fill(phase: sharedPhase)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                fill(phase: shimmerPhase(at: timeline.date))
            }
        }
    }

    private func fill(phase: CGFloat) -> some View {
        let sweep = phase * 2 - 1
        return Color(.systemGray5)
            .overlay(
                GeometryReader { geo in
                    let w = max(geo.size.width, 1)
                    let h = max(geo.size.height, 1)
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(0.5), location: 0.5),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: w * 1.5, height: h)
                    .offset(x: sweep * w)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private func shimmerPhase(at date: Date) -> CGFloat {
    let period: TimeInterval = 1.6
    return CGFloat(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period)
}

extension EnvironmentValues {
    /// 0...1 through the shimmer sweep, shared by every fill under `shimmerClock()`.
    @Entry var shimmerPhase: CGFloat?
}

extension View {
    /// Drives every `ShimmerFill` inside from one timeline, instead of one per block.
    func shimmerClock() -> some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            self.environment(\.shimmerPhase, shimmerPhase(at: timeline.date))
        }
    }
}

// MARK: - Placeholder primitive

struct ShimmerBlock: View {
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat = 8

    var body: some View {
        ShimmerFill(radius: radius)
            .frame(width: width, height: height)
    }
}

// MARK: - Shared skeleton primitives

/// Section title placeholder with standard section padding.
struct ShimmerSectionTitle: View {
    var width: CGFloat = 160

    var body: some View {
        ShimmerBlock(width: width, height: 22, radius: 6)
            .padding(.horizontal, DesignTokens.screenHPadding)
            .padding(.vertical, 8)
    }
}

/// Media card placeholder, sized like `YouTubeGridItemView`: square artwork,
/// a title and an optional subtitle line, in the card's fixed height.
struct ShimmerCard: View {
    var size: CGFloat = YouTubeGridItemView.artworkSize
    var titleWidth: CGFloat = 130
    var subtitleWidth: CGFloat = 90
    var showsSubtitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.cardInnerSpacing) {
            ShimmerBlock(width: size, height: size, radius: DesignTokens.cardRadius)
            ShimmerBlock(width: titleWidth, height: 14, radius: 4)
            if showsSubtitle {
                ShimmerBlock(width: subtitleWidth, height: 12, radius: 4)
            }
        }
        .frame(width: size, height: YouTubeGridItemView.cardHeight, alignment: .top)
    }
}

/// Song row placeholder, sized like `YouTubeListItemView`: 56pt artwork and
/// two text lines in a 64pt row, with room for the ⋮ button on the right.
struct ShimmerListItem: View {
    var titleWidth: CGFloat = 170
    var subtitleWidth: CGFloat = 110

    var body: some View {
        HStack(spacing: DesignTokens.rowSpacing) {
            ShimmerBlock(
                width: YouTubeListItemView.artSize,
                height: YouTubeListItemView.artSize,
                radius: YouTubeListItemView.artRadius
            )
            VStack(alignment: .leading, spacing: 6) {
                ShimmerBlock(width: titleWidth, height: 14, radius: 4)
                ShimmerBlock(width: subtitleWidth, height: 12, radius: 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, DesignTokens.screenHPadding)
        // The 44pt ⋮ button plus its 4pt edge in the real row.
        .padding(.trailing, 48)
        .frame(height: YouTubeListItemView.rowHeight)
    }
}

/// Library row placeholder, sized like `MediaListRow`: artwork (medium by
/// default, round for artists), a title, a subtitle and a detail line.
struct ShimmerMediaRow: View {
    var isCircular = false
    var artSize = DesignTokens.artMedium
    var titleWidth: CGFloat = 160
    var subtitleWidth: CGFloat = 100
    var detailWidth: CGFloat = 70

    var body: some View {
        HStack(spacing: DesignTokens.menuRowSpacing) {
            ShimmerBlock(
                width: artSize,
                height: artSize,
                radius: isCircular ? artSize / 2 : DesignTokens.cardRadius
            )
            VStack(alignment: .leading, spacing: 8) {
                ShimmerBlock(width: titleWidth, height: 16, radius: 4)
                ShimmerBlock(width: subtitleWidth, height: 13, radius: 4)
                ShimmerBlock(width: detailWidth, height: 11, radius: 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DesignTokens.rowVPadding)
    }
}

/// Filter chip placeholders in a horizontal scroll row, sized like `FilterChipBar`.
struct ShimmerChips: View {
    var count = 6
    var width: CGFloat = 80

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0..<count, id: \.self) { _ in
                    ShimmerBlock(width: width, height: DesignTokens.controlHeight, radius: DesignTokens.controlHeight / 2)
                }
            }
            .padding(.horizontal, DesignTokens.screenHPadding)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - ShimmerLoadingView

/// Home's loading placeholder, in the order `HomeViewModel` sorts sections:
/// Keep Listening, Quick Picks, then card carousels and song columns.
struct ShimmerLoadingView: View {
    private enum Section: Hashable { case keepListening, quickPicks, squares, list, dials }

    /// A mood chip's feed: the real chips are already on screen above, and
    /// the feed has none of the local sections (Keep Listening, Quick Picks).
    var isChipFeed = false
    /// The Podcasts chip's feed: shelves of `RadioDialTile` shows.
    var isPodcastFeed = false

    private var sections: [Section] {
        if isPodcastFeed { return [.dials, .dials, .dials] }
        let local: [Section] = isChipFeed
            ? []
            : [.keepListening] + (SettingsStore.shared.showQuickPicks ? [.quickPicks] : [])
        return local + [.squares, .list, .squares]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !isChipFeed { ShimmerChips() }
                ForEach(sections.indices, id: \.self) { index in
                    switch sections[index] {
                    case .keepListening: keepListeningCard
                    case .quickPicks: quickPicksSection
                    case .squares: squaresSection
                    case .list: listSection
                    case .dials: dialsSection
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .allowsHitTesting(false)
        .shimmerClock()
    }

    /// Same box as `HorizontalSection`: title, content, then the section gap.
    private func section<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.titleContentGap) {
            ShimmerSectionTitle()
            content()
        }
        .padding(.bottom, DesignTokens.sectionGap)
    }

    /// `KeepListeningStrip` folded: one rounded card, the title inside at the
    /// top left, overlapping tilted covers below it.
    private var keepListeningCard: some View {
        typealias Strip = KeepListeningStrip
        let shape = RoundedRectangle(cornerRadius: Strip.cardRadius, style: .continuous)
        let coverShape = RoundedRectangle(cornerRadius: Strip.coverRadius, style: .continuous)
        let count = 6
        return VStack(alignment: .leading, spacing: 8 - Strip.tiltRoom) {
            ShimmerBlock(width: 140, height: 22, radius: 6)
                .padding(.horizontal, Strip.cardPadding)

            ZStack(alignment: .bottomLeading) {
                ForEach(0..<count, id: \.self) { index in
                    ShimmerFill(radius: Strip.coverRadius)
                        .frame(width: Strip.coverSize, height: Strip.coverSize)
                        // The card-coloured border keeps overlapping covers apart.
                        .overlay(coverShape.strokeBorder(Strip.cardColor, lineWidth: 2))
                        .rotationEffect(.degrees(index.isMultiple(of: 2) ? -Strip.stackedTilt : Strip.stackedTilt))
                        .offset(x: CGFloat(index) * Strip.stackedStep)
                        .zIndex(Double(count - index))
                }
            }
            // Same height as the real stack, which keeps room for playlist edges.
            .frame(height: Strip.coverSize + Strip.playlistLift, alignment: .bottomLeading)
            .padding(.horizontal, Strip.cardPadding)
            .padding(.vertical, Strip.tiltRoom)
        }
        .padding(.top, Strip.cardPadding)
        .padding(.bottom, Strip.cardPadding - Strip.tiltRoom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Strip.cardColor, in: shape)
        .clipShape(shape)
        .padding(.horizontal, DesignTokens.screenHPadding)
        .padding(.top, 8)
        .padding(.bottom, DesignTokens.sectionGap)
    }

    /// Square cards in the layout chosen in Settings: 3x3 or 3x2.
    private var quickPicksSection: some View {
        let size = SettingsStore.shared.quickPicksSize
        return section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: size.columns), spacing: 8) {
                ForEach(0..<size.perPage, id: \.self) { _ in
                    ShimmerFill(radius: 8).aspectRatio(1, contentMode: .fit)
                }
            }
            .padding(.horizontal, DesignTokens.screenHPadding)

            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
        }
    }

    private var squaresSection: some View {
        section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: DesignTokens.cardSpacing) {
                    ForEach(0..<5, id: \.self) { _ in ShimmerCard() }
                }
                .padding(.horizontal, DesignTokens.screenHPadding)
            }
        }
    }

    private var dialsSection: some View {
        section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: DesignTokens.cardSpacing) {
                    ForEach(0..<3, id: \.self) { _ in dialTile }
                }
                .padding(.horizontal, DesignTokens.screenHPadding)
            }
        }
    }

    /// `RadioDialTile`'s card: the empty ON AIR row, centred artwork, title and
    /// author lines, then the tuning scale beside the play button.
    private var dialTile: some View {
        typealias Tile = RadioDialTile
        let button = NewReleaseCard.buttonSize
        return VStack(alignment: .leading, spacing: 0) {
            ShimmerBlock(width: Tile.artSize, height: Tile.artSize, radius: 10)
                .frame(maxWidth: .infinity)
                // The ON AIR row: 16pt tall plus its 6pt gap.
                .padding(.top, 22)
                .padding(.bottom, 8)
            ShimmerBlock(width: 110, height: 14, radius: 4)
            ShimmerBlock(width: 80, height: 12, radius: 4)
                .padding(.top, 6)

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                // Thin bar at the foot of the 22pt tuning scale.
                ShimmerFill(radius: 2)
                    .frame(height: 4)
                    .frame(height: 22, alignment: .bottom)
                ShimmerBlock(width: button, height: button, radius: button / 2)
            }
        }
        .padding(Tile.inset)
        .frame(width: Tile.size.width, height: Tile.size.height, alignment: .top)
        .background(
            KeepListeningStrip.cardColor,
            in: RoundedRectangle(cornerRadius: Tile.radius, style: .continuous)
        )
    }

    /// Song columns like `songsSection`: four 64pt rows each, a column as wide
    /// as the page minus `songColumnPeek`, so the next one peeks in.
    private var listSection: some View {
        section {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(
                    rows: Array(repeating: GridItem(.fixed(YouTubeListItemView.rowHeight), spacing: 8), count: 4),
                    spacing: 0
                ) {
                    ForEach(0..<8, id: \.self) { _ in
                        ShimmerListItem()
                            .containerRelativeFrame(.horizontal) { width, _ in
                                width - HomeScreenView.songColumnPeek
                            }
                    }
                }
            }
        }
    }
}
