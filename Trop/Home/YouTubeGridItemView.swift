//
//  YouTubeGridItemView.swift
//  Trop
//
//  Created by 686udjie on 01/07/2026.
//

import SwiftUI

struct YouTubeGridItemView: View {
    var item: YTItem
    var onTap: () -> Void

    @State private var durations = DurationResolver()
    static let artworkSize: CGFloat = 160
    /// Fixed so captions of one or two lines keep a carousel's cards aligned.
    static let cardHeight: CGFloat = 220

    private var videoId: String? {
        switch item {
        case .song(let s): return s.videoId
        case .episode(let e): return e.videoId
        default: return nil
        }
    }

    private var opensPage: Bool {
        switch item {
        case .album, .playlist: return true
        default: return false
        }
    }

    private var isArtist: Bool {
        if case .artist = item { return true }
        return false
    }

    private var subtitleText: String {
        switch item {
        case .artist:
            return "Artist"
        case .song(let s):
            return s.subtitleLine(duration: durations.effectiveDuration(known: s.duration))
        case .episode(let e):
            return e.toSongItem().subtitleLine(duration: durations.effectiveDuration(known: e.duration))
        case .album(let a):
            let names = a.artists.map(\.name)
            return names.isEmpty ? "" : names.joined(separator: ", ")
        default:
            return ""
        }
    }

    private var songItem: SongItem? {
        switch item {
        case .song(let s): return s
        case .episode(let e): return e.toSongItem()
        default: return nil
        }
    }

    var body: some View {
        Group {
            if let song = songItem {
                // Long press opens the same menu as a song row's ⋯.
                SongActionsMenu(song: song, onNavigate: { AppRouter.shared.open($0) }, asContextMenu: true) {
                    card
                }
            } else {
                card
            }
        }
        .task {
            guard let vid = videoId else { return }
            let known: Int
            switch item {
            case .song(let s): known = s.duration
            case .episode(let e): known = e.duration
            default: known = 0
            }
            await durations.resolve(videoId: vid, knownDuration: known)
        }
        .onReceive(NotificationCenter.default.publisher(for: .durationDidUpdate)) { notification in
            durations.handleUpdate(notification, videoId: videoId)
        }
    }

    private var card: some View {
        Button(action: onTap) {
            VStack(alignment: isArtist ? .center : .leading, spacing: 4) {
                AsyncImageView(url: item.thumbnailUrl)
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: Self.artworkSize, height: Self.artworkSize)
                    // Artists are round, albums and playlists are rounded squares.
                    .clipShape(isArtist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8)))
                    .opensPageBadge(opensPage)

                Text(item.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(isArtist ? .center : .leading)

                let subtitle = subtitleText
                if case .artist(let artist) = item {
                    ArtistKindLabel(name: artist.name)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: Self.artworkSize, height: Self.cardHeight, alignment: .top)
        }
        .buttonStyle(ZoomPressStyle())
        .cardMenu(for: item)
    }
}

/// One song row in the YouTube Music style: 56pt artwork, a one-line title
/// over "Artist • 2:37", and a vertical ⋮ menu. Shared by Home, Explore and Search.
struct YouTubeListItemView: View {
    var item: YTItem
    var onTap: () -> Void
    var onNavigate: ((DetailRoute) -> Void)?

    @State private var durations = DurationResolver()

    static let artSize: CGFloat = 56
    static let artRadius: CGFloat = 5
    static let rowHeight: CGFloat = 64

    private var songItem: SongItem? {
        switch item {
        case .song(let s): return s
        case .episode(let e): return e.toSongItem()
        default: return nil
        }
    }

    var body: some View {
        if let song = songItem {
            // Long pressing anywhere on the row opens the same menu as ⋮.
            SongActionsMenu(song: song, onNavigate: { onNavigate?($0) }, asContextMenu: true) {
                row(subtitle: song.subtitleLine(duration: durations.effectiveDuration(known: song.duration))) {
                    SongActionsMenu(song: song, onNavigate: { onNavigate?($0) }) {
                        VerticalMoreGlyph()
                    }
                }
                .background(DownloadCellProgressView(song: song))
            }
            .task { await durations.resolve(videoId: song.videoId, knownDuration: song.duration) }
            .onReceive(NotificationCenter.default.publisher(for: .durationDidUpdate)) { notification in
                durations.handleUpdate(notification, videoId: song.videoId)
            }
        } else {
            row(subtitle: albumSubtitleText) {
                if let url = item.webUrl {
                    Button {
                        UIPasteboard.general.string = url
                    } label: {
                        VerticalMoreGlyph()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy link")
                }
            }
        }
    }

    private func row<Trailing: View>(subtitle: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: DesignTokens.rowSpacing) {
            AsyncImageView(url: item.thumbnailUrl)
                .frame(width: Self.artSize, height: Self.artSize)
                .clipShape(RoundedRectangle(cornerRadius: Self.artRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing()
        }
        .padding(.leading, DesignTokens.screenHPadding)
        // The 44pt glyph already leaves air on the right.
        .padding(.trailing, 4)
        .frame(minHeight: Self.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .rowPressFeedback()
    }

    private var albumSubtitleText: String {
        if case .album(let a) = item {
            return a.artists.map(\.name).joined(separator: ", ")
        }
        return ""
    }
}

/// Vertical ⋮ for list rows, in the text colour like YouTube Music.
private struct VerticalMoreGlyph: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .rotationEffect(.degrees(90))
            .font(.body.weight(.bold))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("More")
    }
}
