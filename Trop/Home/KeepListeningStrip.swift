//
//  KeepListeningStrip.swift
//  Trop
//

import SwiftUI

/// Keep Listening as one compact bar: covers fanned in a stack, spread out on tap.
struct KeepListeningStrip: View {
    let title: String
    let items: [YTItem]
    let onSelect: (YTItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    private static let coverSize: CGFloat = 40
    private static let barPadding: CGFloat = 6
    private static let stackedStep: CGFloat = 16
    private static let spreadStep: CGFloat = 46
    private static let stackedLimit = 8
    private static let barColor = Color(.secondarySystemBackground)

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.titleContentGap) {
            NavigationTitleView(title: title)
            bar
                .padding(.horizontal, DesignTokens.screenHPadding)
        }
        .padding(.bottom, DesignTokens.sectionGap)
        // Folds back once the strip scrolls off screen or Home is left.
        .onScrollVisibilityChange(threshold: 0.1) { visible in
            if !visible { isExpanded = false }
        }
        .onDisappear { isExpanded = false }
    }

    private var bar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                stack
                    .padding(Self.barPadding)
            }
            .scrollDisabled(!isExpanded)

            if isExpanded {
                Button(action: toggle) {
                    Image(systemName: "chevron.left")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: Self.coverSize + Self.barPadding * 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse Keep listening")
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.barColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if !isExpanded { toggle() } }
    }

    private var stack: some View {
        let step = isExpanded ? Self.spreadStep : Self.stackedStep
        let shownCount = isExpanded ? items.count : min(items.count, Self.stackedLimit)
        return ZStack(alignment: .leading) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let isShown = index < shownCount
                cover(for: item)
                    // Rotate before offsetting, so each cover turns around its own centre.
                    .rotationEffect(.degrees(isExpanded ? 0 : (index.isMultiple(of: 2) ? -4 : 4)))
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
        // the bar colour separates overlapping covers.
        if case .artist = item {
            image
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Self.barColor, lineWidth: 2))
        } else {
            let shape = RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous)
            image
                .clipShape(shape)
                .overlay(shape.strokeBorder(Self.barColor, lineWidth: 2))
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
