//
//  SongRowView.swift
//  Trop
//
// Created by 686udjie on 12/09/2026.
//

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

    @State private var durations = DurationResolver()

    var body: some View {
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

            HStack(spacing: 2) {
                SongActionsMenu(song: song, onNavigate: { onNavigate?($0) }) {
                    MoreGlyph()
                }
            }
        }
        .padding(.horizontal, DesignTokens.screenHPadding)
        .padding(.vertical, DesignTokens.rowVPadding)
        .background(DownloadCellProgressView(song: song))
        .contentShape(Rectangle())
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
    @ObservedObject private var downloadManager = DownloadManager.shared

    var body: some View {
        let state = downloadManager.state(for: song.videoId)
        GeometryReader { geo in
            if case .downloading(let fraction) = state {
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
    }
}
