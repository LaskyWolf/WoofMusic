//
//  KeepListeningStrip.swift
//  Trop
//

import SwiftUI

/// Keep Listening as one card: the title on top, covers fanned in a stack
/// below it, spread out on tap.
struct KeepListeningStrip: View {
    let title: String
    let items: [YTItem]
    let onSelect: (YTItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Stays as the user left it, across tab switches and Home reloads.
    @SceneStorage("keepListeningExpanded") private var isExpanded = false

    static let coverSize: CGFloat = DesignTokens.artSmall
    static let coverRadius: CGFloat = 10
    static let cardPadding: CGFloat = 12
    static let cardRadius: CGFloat = 18
    /// Room for the tilted covers' corners inside the scroll view's clip.
    static let tiltRoom: CGFloat = 4
    static let stackedStep: CGFloat = 24
    private static let spreadStep: CGFloat = 66
    static let stackedTilt: Double = 5
    /// How far each layered edge peeks out above a playlist cover.
    static let playlistEdgeStep: CGFloat = 3
    /// Room above every cover for a playlist's two layered edges.
    static let playlistLift: CGFloat = playlistEdgeStep * 2
    private static let stackedLimit = 8
    static let cardColor = Color(.secondarySystemBackground)

    var body: some View {
        card
            .padding(.horizontal, DesignTokens.screenHPadding)
            .padding(.bottom, DesignTokens.sectionGap)
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 8 - Self.tiltRoom) {
            header
                .padding(.horizontal, Self.cardPadding)

            // Edge to edge inside the card, so spread covers scroll under its rounded edge.
            ScrollView(.horizontal, showsIndicators: false) {
                stack
                    .padding(.horizontal, Self.cardPadding)
                    .padding(.vertical, Self.tiltRoom)
            }
            .scrollDisabled(!isExpanded)
        }
        .padding(.top, Self.cardPadding)
        .padding(.bottom, Self.cardPadding - Self.tiltRoom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.cardColor, in: shape)
        .clipShape(shape)
        // Collapsed, the whole card is one button (taps, long presses and
        // VoiceOver). It stays in the tree and only stops taking touches
        // when expanded, so no removal animation leaves it over the covers.
        .overlay {
            Button(action: toggle) {
                Color.clear.contentShape(shape)
            }
            .buttonStyle(.plain)
            .allowsHitTesting(!isExpanded)
            .accessibilityHidden(isExpanded)
            .accessibilityLabel("\(title), \(items.count) items")
            .accessibilityHint("Expands the list")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            if isExpanded {
                Button(action: toggle) {
                    Image(systemName: "chevron.left")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Full 44pt target without making the header taller.
                .padding(.vertical, -12)
                .padding(.trailing, -14)
                .accessibilityLabel("Collapse \(title)")
                .transition(.opacity)
            } else {
                Text("Tap to spread")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
    }

    private var stack: some View {
        let step = isExpanded ? Self.spreadStep : Self.stackedStep
        let shownCount = isExpanded ? items.count : min(items.count, Self.stackedLimit)
        return ZStack(alignment: .bottomLeading) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let isShown = index < shownCount
                cover(for: item)
                    // Rotate before offsetting, so each cover turns around its own centre.
                    .rotationEffect(.degrees(isExpanded ? 0 : (index.isMultiple(of: 2) ? -Self.stackedTilt : Self.stackedTilt)))
                    // Hidden extras wait under the last stacked cover.
                    .offset(x: CGFloat(min(index, shownCount - 1)) * step)
                    .opacity(isShown ? 1 : 0)
                    .zIndex(Double(items.count - index))
                    .allowsHitTesting(isShown)
                    .accessibilityHidden(!isShown || !isExpanded)
            }
        }
        .frame(
            width: CGFloat(max(shownCount - 1, 0)) * step + Self.coverSize,
            height: Self.coverSize + Self.playlistLift,
            alignment: .bottomLeading
        )
    }

    @ViewBuilder
    private func cover(for item: YTItem) -> some View {
        let button = Button {
            onSelect(item)
        } label: {
            artwork(for: item)
                .coverZoomSource(YTItemRouter.detailRoute(for: item))
        }
        .buttonStyle(ZoomPressStyle())
        .accessibilityLabel("\(item.title), \(Self.kindName(item))")

        // Long press: the same menus the Home cards use.
        switch item {
        case .song(let song):
            SongActionsMenu(song: song, onNavigate: { AppRouter.shared.open($0) }, asContextMenu: true) { button }
        case .episode(let episode):
            SongActionsMenu(song: episode.toSongItem(), onNavigate: { AppRouter.shared.open($0) }, asContextMenu: true) { button }
        default:
            button.cardMenu(for: item)
        }
    }

    @ViewBuilder
    private func artwork(for item: YTItem) -> some View {
        let image = AsyncImageView(url: item.thumbnailUrl)
            .frame(width: Self.coverSize, height: Self.coverSize)
        let shape = RoundedRectangle(cornerRadius: Self.coverRadius, style: .continuous)
        // Artists are round, playlists a rounded square with two layered
        // edges peeking out on top, everything else a plain rounded square.
        // The border in the card colour separates overlapping covers.
        switch item {
        case .artist:
            image
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Self.cardColor, lineWidth: 2))
        case .playlist:
            ZStack(alignment: .bottom) {
                Self.playlistEdge(inset: 12, color: Color(.systemGray4))
                    .offset(y: -2 * Self.playlistEdgeStep)
                Self.playlistEdge(inset: 6, color: Color(.systemGray2))
                    .offset(y: -Self.playlistEdgeStep)
                image
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Self.cardColor, lineWidth: 2))
            }
            .frame(height: Self.coverSize + Self.playlistLift, alignment: .bottom)
        default:
            image
                .clipShape(shape)
                .overlay(shape.strokeBorder(Self.cardColor, lineWidth: 2))
        }
    }

    /// A card behind a playlist cover, `inset` narrower on each side.
    private static func playlistEdge(inset: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: coverRadius - 2, style: .continuous)
            .fill(color)
            .frame(width: coverSize - inset * 2, height: coverSize)
    }

    private func toggle() {
        let animation: Animation? = reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.25)
        withAnimation(animation) {
            isExpanded.toggle()
        }
    }

    private static func kindName(_ item: YTItem) -> String {
        switch item {
        case .song: return "Song"
        case .album: return "Album"
        case .artist: return "Artist"
        case .playlist: return "Playlist"
        case .podcast: return "Podcast"
        case .episode: return "Episode"
        }
    }
}
