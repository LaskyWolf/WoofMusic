//
//  SongRowView.swift
//  Trop
//
// Created by 686udjie on 12/09/2026.
//

import Combine
import SwiftUI

/// Trailing ⋮ button shared by every song row.
/// Label for a row's "⋯" song menu.
struct MoreGlyph: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.body.weight(.semibold))
            // A pale accent like Amber nearly disappears on white.
            .foregroundStyle(colorScheme == .light ? settings.accentColor.darkened(toLuminance: 0.3) : settings.accentColor)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("More")
    }
}

/// Unified song row: artwork + title + artists • duration + overflow menu.
/// Replaces AlbumSongRow, PlaylistSongRow, PodcastEpisodeRow, DownloadedSongRow
/// and the song branch of YouTubeListItemView.
struct SongRowView: View {
    let song: SongItem
    var artSize: CGFloat = DesignTokens.thumbSmall
    var artRadius: CGFloat = DesignTokens.thumbRadius
    var onTap: () -> Void
    var onNavigate: ((DetailRoute) -> Void)?
    /// Multi-select: shows a checkmark instead of the ⋯ button; `onTap` toggles the song.
    var isSelecting = false
    var isSelected = false
    /// Starts multi-select from the song menu (⋯ or long press).
    var onSelect: (() -> Void)?
    var onRemove: (() -> Void)?
    /// Off on the Downloads page, where every row would show it.
    var showsDownloadBadge = true

    @State private var durations = DurationResolver()
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        if isSelecting {
            rowContent
        } else {
            // Long pressing anywhere on the row opens the same menu as ⋯.
            SongActionsMenu(song: song, onNavigate: { onNavigate?($0) }, onSelect: onSelect,
                            onRemove: onRemove, asContextMenu: true, menuMargin: 0) {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: DesignTokens.rowSpacing) {
            AsyncImageView(url: song.thumbnailUrl)
                .frame(width: artSize, height: artSize)
                .clipShape(RoundedRectangle(cornerRadius: artRadius, style: .continuous))
                .greyedOut(!song.isAvailable)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(song.subtitleLine(duration: durations.effectiveDuration(known: song.duration)))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .greyedOut(!song.isAvailable)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityValue(song.isAvailable ? "" : "Unavailable")
            .accessibilityAction { if isSelecting || song.isAvailable { onTap() } }

            Spacer()

            HStack(spacing: 2) {
                if showsDownloadBadge { DownloadedBadge(videoId: song.videoId) }
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? AnyShapeStyle(settings.accentColor) : AnyShapeStyle(.secondary))
                        .contentTransition(.symbolEffect(.replace))
                        .glyphMotion(isSelected ? .pop : .deflate, trigger: isSelected)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityHidden(true)
                } else {
                    SongActionsMenu(song: song, onNavigate: { onNavigate?($0) },
                                    onSelect: onSelect, onRemove: onRemove) {
                        MoreGlyph()
                    }
                }
            }
        }
        .padding(.horizontal, DesignTokens.screenHPadding)
        .padding(.vertical, DesignTokens.rowVPadding)
        .background(DownloadCellProgressView(song: song))
        .background(isSelected ? settings.accentColor.opacity(0.12) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting || song.isAvailable { onTap() }
        }
        .rowPressFeedback()
        .task(id: song.videoId) { await durations.resolve(videoId: song.videoId, knownDuration: song.duration) }
        .onReceive(NotificationCenter.default.publisher(for: .durationDidUpdate)) { notification in
            durations.handleUpdate(notification, videoId: song.videoId)
        }
    }
}

extension View {
    /// The look of a song YouTube Music can't play.
    func greyedOut(_ isGreyedOut: Bool) -> some View {
        saturation(isGreyedOut ? 0 : 1)
            .opacity(isGreyedOut ? 0.4 : 1)
    }
}

/// The arrow that marks a song, playlist or album saved on this iPhone.
struct DownloadedGlyph: View {
    /// White, for artwork and coloured cards where the accent colour may not show.
    var onArtwork = false
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Image(systemName: "arrow.down.to.line")
            .font(.caption.weight(.bold))
            .foregroundStyle(onArtwork ? Color.white : settings.accentColor)
            .accessibilityLabel("Downloaded")
    }
}

/// `DownloadedGlyph` for one song, once that song is saved.
struct DownloadedBadge: View {
    let videoId: String
    var onArtwork = false
    /// Only this song's answer, like `DownloadCellProgressView`.
    @State private var isDownloaded: Bool
    /// The song `isDownloaded` belongs to: a list can reuse this view for another song.
    @State private var shownVideoId: String
    @State private var finishedDownloads = 0

    init(videoId: String, onArtwork: Bool = false) {
        self.videoId = videoId
        self.onArtwork = onArtwork
        _shownVideoId = State(initialValue: videoId)
        _isDownloaded = State(initialValue: DownloadManager.shared.downloadedIds.contains(videoId))
    }

    var body: some View {
        // The ZStack stays when empty: it keeps the subscription, at no width.
        ZStack {
            if isDownloaded { DownloadedGlyph(onArtwork: onArtwork) }
        }
        .glyphMotion(.downloadDone, trigger: finishedDownloads)
        .onReceive(DownloadManager.shared.$downloadedIds.map { [videoId] in $0.contains(videoId) }.removeDuplicates()) { downloaded in
            if shownVideoId == videoId, downloaded, !isDownloaded { finishedDownloads += 1 }
            shownVideoId = videoId
            isDownloaded = downloaded
        }
    }
}

/// The arrow for any feed item that can be saved: a song, episode, album or playlist.
struct ItemDownloadedBadge: View {
    let item: YTItem

    var body: some View {
        switch item {
        case .song(let song):
            DownloadedBadge(videoId: song.videoId)
        case .episode(let episode):
            DownloadedBadge(videoId: episode.videoId)
        default:
            if DownloadedCollections.shared.isComplete(YTItemRouter.detailRoute(for: item)) {
                DownloadedGlyph()
            }
        }
    }
}

/// "Downloaded" or "3 of 12 downloaded", under a playlist or album title.
struct DownloadedSongsLabel: View {
    let songs: [SongItem]
    @Environment(SettingsStore.self) private var settings
    @State private var downloadedIds: Set<String> = []

    private var available: [SongItem] { songs.filter(\.isAvailable) }
    private var count: Int { available.filter { downloadedIds.contains($0.videoId) }.count }

    var body: some View {
        ZStack {
            if count > 0 {
                Label {
                    Text(count == available.count ? "Downloaded" : "\(count) of \(available.count) downloaded")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "arrow.down.to.line")
                        .foregroundStyle(settings.accentColor)
                }
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.top, 4)
            }
        }
        .onReceive(DownloadManager.shared.$downloadedIds) { downloadedIds = $0 }
    }
}

/// Covers the whole row while its song downloads: a tinted fill that grows
/// with the progress and a solid bar along the bottom edge.
struct DownloadCellProgressView: View {
    let song: SongItem
    @Environment(SettingsStore.self) private var settings
    /// Only this song's entry: observing the whole manager would redraw every
    /// visible row at each progress step of any download.
    @State private var state: DownloadManager.DownloadState?

    var body: some View {
        GeometryReader { geo in
            if case .downloading(let fraction)? = state {
                let width = geo.size.width * CGFloat(min(max(fraction, 0), 1))
                ZStack(alignment: .bottomLeading) {
                    settings.accentColor.opacity(0.18)
                        .frame(width: width)
                    settings.accentColor
                        .frame(width: width, height: 3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .transition(.opacity)
                .accessibilityElement()
                .accessibilityLabel("Downloading, \(Int(fraction * 100)) percent")
            }
        }
        .animation(.easeInOut(duration: 0.3), value: state)
        .onReceive(DownloadManager.shared.$downloads.map { [videoId = song.videoId] in $0[videoId] }.removeDuplicates()) {
            state = $0
        }
    }
}
