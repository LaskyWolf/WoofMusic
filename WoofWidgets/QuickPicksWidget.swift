//
//  QuickPicksWidget.swift
//  WoofWidgets
//

import SwiftUI
import WidgetKit

/// Home's Quick Picks as cover tiles: tapping one plays it with the others queued after it.
struct QuickPicksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.quickPicks, provider: SnapshotProvider<QuickPicksSnapshot>(file: WidgetStore.quickPicksFile)) { entry in
            QuickPicksView(snapshot: entry.value)
                .widgetURL(WidgetLink.home)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color(hex: 0x1B2430), Color(hex: 0x0E1218)],
                                   startPoint: .top, endPoint: .bottom)
                }
        }
        .configurationDisplayName("Quick Picks")
        .description("Your Quick Picks from Home, one tap to play.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct QuickPicksView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: QuickPicksSnapshot?

    var body: some View {
        if let snapshot, !snapshot.isEnabled {
            WidgetPlaceholder(symbol: "sparkles", text: "Turn on Quick Picks in Settings to fill this widget")
        } else if let songs = snapshot?.songs, !songs.isEmpty {
            switch family {
            case .systemSmall: small(songs)
            case .systemLarge: large(songs)
            default: medium(songs)
            }
        } else {
            WidgetPlaceholder(symbol: "sparkles", text: "Open Home in Woof Music to load your Quick Picks")
        }
    }

    private var header: some View {
        Text("Quick Picks")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
    }

    private var shuffle: some View {
        Button(intent: ShuffleQuickPicksIntent()) {
            Label("Shuffle", systemImage: "shuffle")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(.white))
        }
        .buttonStyle(.plain)
    }

    /// Three covers and a shuffle tile in a 2×2 grid.
    private func small(_ songs: [WidgetSong]) -> some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                tile(songs, 0, showsTitle: false)
                tile(songs, 1, showsTitle: false)
            }
            GridRow {
                tile(songs, 2, showsTitle: false)
                Button(intent: ShuffleQuickPicksIntent()) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Shuffle Quick Picks")
            }
        }
    }

    private func medium(_ songs: [WidgetSong]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                header
                Spacer(minLength: 0)
                shuffle
            }
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { tile(songs, $0, showsTitle: true) }
            }
        }
    }

    private func large(_ songs: [WidgetSong]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                header
                Spacer(minLength: 0)
                Text("Woof Music")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow { ForEach(0..<3, id: \.self) { tile(songs, $0, showsTitle: true) } }
                GridRow { ForEach(3..<6, id: \.self) { tile(songs, $0, showsTitle: true) } }
            }
            Button(intent: ShuffleQuickPicksIntent()) {
                Label("Shuffle Quick Picks", systemImage: "shuffle")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(.plain)
        }
    }

    /// One cover. An index past the end leaves an empty slot, so the grid keeps its shape.
    @ViewBuilder
    private func tile(_ songs: [WidgetSong], _ index: Int, showsTitle: Bool) -> some View {
        if songs.indices.contains(index) {
            let song = songs[index]
            Button(intent: PlayQuickPickIntent(videoId: song.videoId)) {
                CoverImage(data: song.artwork)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(alignment: .bottomLeading) {
                        if showsTitle {
                            Text(song.title)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .shadow(color: .black.opacity(0.8), radius: 2)
                                .padding(5)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if song.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(Circle().fill(.black.opacity(0.45)))
                                .padding(4)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(song.title) by \(song.artist)")
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.06))
                .aspectRatio(1, contentMode: .fit)
        }
    }
}
