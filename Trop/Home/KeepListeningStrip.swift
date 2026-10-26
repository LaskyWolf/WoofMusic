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
    @State private var isExpanded = false

    static let coverSize: CGFloat = 60
    static let coverRadius: CGFloat = 10
    static let cardPadding: CGFloat = 12
    static let cardRadius: CGFloat = 18
    /// Room for the tilted covers' corners inside the scroll view's clip.
    static let tiltRoom: CGFloat = 4
    static let stackedStep: CGFloat = 24
    private static let spreadStep: CGFloat = 66
    static let stackedTilt: Double = 5
    private static let stackedLimit = 8
    static let cardColor = Color(.secondarySystemBackground)

    var body: some View {
        card
            .padding(.horizontal, DesignTokens.screenHPadding)
            .padding(.bottom, DesignTokens.sectionGap)
            // Folds back once the card scrolls off screen or Home is left.
            .onScrollVisibilityChange(threshold: 0.1) { visible in
                if !visible { isExpanded = false }
            }
            .onDisappear { isExpanded = false }
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
        .contentShape(shape)
        .onTapGesture { if !isExpanded { toggle() } }
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
        return ZStack(alignment: .leading) {
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
            height: Self.coverSize,
            alignment: .leading
        )
        // Collapsed, the whole stack is one button (taps, long presses and
        // VoiceOver); expanded, each cover is its own.
        .overlay {
            if !isExpanded {
                Button(action: toggle) {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(items.count) items")
                .accessibilityHint("Expands the list")
            }
        }
    }

    @ViewBuilder
    private func cover(for item: YTItem) -> some View {
        let button = Button {
            onSelect(item)
        } label: {
            artwork(for: item)
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
        // Artists are round, everything else a rounded square; the border in
        // the card colour separates overlapping covers.
        if case .artist = item {
            image
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Self.cardColor, lineWidth: 2))
        } else {
            let shape = RoundedRectangle(cornerRadius: Self.coverRadius, style: .continuous)
            image
                .clipShape(shape)
                .overlay(shape.strokeBorder(Self.cardColor, lineWidth: 2))
        }
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
