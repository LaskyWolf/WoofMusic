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
    private let artworkSize: CGFloat = 160

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
                    .frame(width: artworkSize, height: artworkSize)
                    // Artists are round, albums and playlists are rounded squares.
                    .clipShape(isArtist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8)))
                    .opensPageBadge(opensPage)

                Text(item.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(isArtist ? .center : .leading)

                if !subtitleText.isEmpty {
                    Text(subtitleText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: artworkSize, height: 220, alignment: .top)
        }
        .buttonStyle(ZoomPressStyle())
        .cardMenu(for: item)
    }
}

struct YouTubeListItemView: View {
    @Environment(SettingsStore.self) private var settings
    var item: YTItem
    var onTap: () -> Void
    var onNavigate: ((DetailRoute) -> Void)?

    private var songItem: SongItem? {
        switch item {
        case .song(let s): return s
        case .episode(let e): return e.toSongItem()
        default: return nil
        }
    }

    var body: some View {
        if let song = songItem {
            SongRowView(
                song: song,
                artSize: 48,
                onTap: onTap,
                onNavigate: onNavigate
            )
        } else {
            HStack(spacing: 12) {
                AsyncImageView(url: item.thumbnailUrl)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(albumSubtitleText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if let url = item.webUrl {
                    Button {
                        UIPasteboard.general.string = url
                    } label: {
                        Text("⋮")
                            .font(.body.weight(.black))
                            .foregroundStyle(settings.accentColor)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private var albumSubtitleText: String {
        if case .album(let a) = item {
            return a.artists.map(\.name).joined(separator: ", ")
        }
        return ""
    }
}
