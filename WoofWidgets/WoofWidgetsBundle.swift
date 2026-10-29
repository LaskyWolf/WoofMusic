//
//  WoofWidgetsBundle.swift
//  WoofWidgets
//

import SwiftUI
import WidgetKit

@main
struct WoofWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        NowPlayingLiveActivity()
    }
}

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    /// nil until the app has written a song (or when there is no App Group).
    let state: NowPlayingState?
}

/// The app reloads the timeline when the song or the play state changes.
struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, state: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(NowPlayingEntry(date: .now, state: WidgetSnapshot.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        completion(Timeline(entries: [NowPlayingEntry(date: .now, state: WidgetSnapshot.read())], policy: .never))
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowPlaying", provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(state: entry.state)
                .containerBackground(for: .widget) {
                    LinearGradient(
                        colors: [(entry.state?.tintColor ?? .gray).opacity(0.6), .black],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
        }
        .configurationDisplayName("Now Playing")
        .description("The song playing in Woof Music.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

private struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let state: NowPlayingState?

    var body: some View {
        if let state {
            switch family {
            case .accessoryRectangular:
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(state.title).font(.headline).lineLimit(1)
                        Text(state.artist).font(.caption).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    PlaybackButtons(state: state, showsNext: false)
                }
            case .systemMedium:
                HStack(spacing: 14) {
                    ArtworkView(state: state, size: 120, cornerRadius: 14)
                    VStack(alignment: .leading, spacing: 10) {
                        SongTitles(state: state, lineLimit: 2)
                        Spacer(minLength: 0)
                        PlaybackButtons(state: state)
                    }
                    Spacer(minLength: 0)
                }
            default:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        ArtworkView(state: state, size: 64, cornerRadius: 12)
                        Spacer(minLength: 0)
                        PlaybackButtons(state: state, showsNext: false)
                    }
                    Spacer(minLength: 0)
                    SongTitles(state: state, lineLimit: 2)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "music.note")
                    .font(.title2)
                if family != .accessoryRectangular { Spacer(minLength: 0) }
                Text("Open Woof Music to start listening")
                    .font(family == .accessoryRectangular ? .caption : .subheadline)
                    .lineLimit(3)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
