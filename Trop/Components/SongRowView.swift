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

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.body.weight(.semibold))
            .foregroundStyle(settings.accentColor)
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

    @State private var durations = DurationResolver()
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        if isSelecting {
            rowContent
        } else {
            // Long pressing anywhere on the row opens the same menu as ⋯.
            SongActionsMenu(song: song, onNavigate: { onNavigate?($0) }, onSelect: onSelect,
                            onRemove: onRemove, asContextMenu: true) {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: DesignTokens.rowSpacing) {
            AsyncImageView(url: song.thumbnailUrl)
                .frame(width: artSize, height: artSize)
                .clipShape(RoundedRectangle(cornerRadius: artRadius, style: .continuous))

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

            Spacer()

            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(settings.accentColor) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityHidden(true)
            } else {
                HStack(spacing: 2) {
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onTapGesture(perform: onTap)
        .rowPressFeedback()
        .task { await durations.resolve(videoId: song.videoId, knownDuration: song.duration) }
        .onReceive(NotificationCenter.default.publisher(for: .durationDidUpdate)) { notification in
            durations.handleUpdate(notification, videoId: song.videoId)
        }
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
