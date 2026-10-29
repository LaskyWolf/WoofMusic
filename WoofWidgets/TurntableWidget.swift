//
//  TurntableWidget.swift
//  WoofWidgets
//

import AppIntents
import SwiftUI
import WidgetKit

/// The song playing now as a record: tonearm down while playing, lifted when paused.
struct TurntableWidget: Widget {
    var body: some WidgetConfiguration {
        // Keeps the old Now Playing kind, so widgets already on the Home Screen become the Turntable.
        StaticConfiguration(kind: WidgetKind.nowPlaying, provider: SnapshotProvider<NowPlayingState>(file: WidgetStore.nowPlayingFile)) { entry in
            TurntableView(state: entry.value)
                .widgetURL(WidgetLink.player)
                .containerBackground(for: .widget) {
                    LinearGradient(
                        colors: [(entry.value?.tintColor ?? .purple).mix(with: .black, by: 0.35), .black],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
        }
        .configurationDisplayName("Turntable")
        .description("The song playing in Woof Music, with its controls.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

private struct TurntableView: View {
    @Environment(\.widgetFamily) private var family
    let state: NowPlayingState?

    var body: some View {
        if let state {
            switch family {
            case .systemSmall: small(state)
            case .systemLarge: large(state)
            case .accessoryRectangular: lockScreen(state)
            default: medium(state)
            }
        } else {
            WidgetPlaceholder(symbol: "music.note", text: "Open Woof Music to start listening")
        }
    }

    private func titles(_ state: NowPlayingState, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(state.title)
                .font(.system(size: size, weight: .bold))
                .lineLimit(1)
            Text(state.artist)
                .font(.system(size: size * 0.82))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
    }

    private func status(_ state: NowPlayingState) -> some View {
        Text(state.isPlaying ? "● Now playing" : "Paused")
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(state.isPlaying ? Color(hex: 0xFFD36E) : .white.opacity(0.55))
    }

    private func playPause(_ state: NowPlayingState, size: CGFloat = 34) -> some View {
        IntentCircleButton(intent: PlayPauseIntent(), symbol: state.playPauseSymbol,
                           label: state.isPlaying ? "Pause" : "Play", size: size, isProminent: true)
    }

    private func small(_ state: NowPlayingState) -> some View {
        ZStack(alignment: .topTrailing) {
            Turntable(state: state, size: 92)
                .offset(x: 26, y: -24)
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                titles(state, size: 14)
                HStack {
                    status(state)
                    Spacer(minLength: 0)
                    playPause(state)
                }
                .padding(.top, 6)
            }
        }
    }

    private func medium(_ state: NowPlayingState) -> some View {
        HStack(spacing: 14) {
            Turntable(state: state, size: 124)
            VStack(alignment: .leading, spacing: 4) {
                titles(state, size: 15)
                status(state)
                HStack(spacing: 8) {
                    IntentCircleButton(intent: PreviousSongIntent(), symbol: "backward.fill", label: "Previous Song")
                    playPause(state)
                    IntentCircleButton(intent: NextSongIntent(), symbol: "forward.fill", label: "Next Song")
                    IntentCircleButton(intent: ToggleLikeIntent(), symbol: state.isLiked ? "heart.fill" : "heart",
                                       label: state.isLiked ? "Unlike" : "Like")
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
    }

    private func large(_ state: NowPlayingState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Turntable(state: state, size: 140)
                VStack(alignment: .leading, spacing: 4) {
                    titles(state, size: 16)
                    status(state)
                    HStack(spacing: 8) {
                        IntentCircleButton(intent: PreviousSongIntent(), symbol: "backward.fill", label: "Previous Song")
                        playPause(state)
                        IntentCircleButton(intent: NextSongIntent(), symbol: "forward.fill", label: "Next Song")
                    }
                    .padding(.top, 8)
                    HStack(spacing: 8) {
                        IntentCircleButton(intent: ToggleLikeIntent(), symbol: state.isLiked ? "heart.fill" : "heart",
                                           label: state.isLiked ? "Unlike" : "Like", isOn: state.isLiked)
                        IntentCircleButton(intent: ToggleShuffleIntent(), symbol: "shuffle", label: "Shuffle", isOn: state.isShuffleOn)
                        IntentCircleButton(intent: ToggleRepeatIntent(), symbol: "repeat", label: "Repeat", isOn: state.isRepeatOn)
                    }
                }
                Spacer(minLength: 0)
            }
            if !state.upNext.isEmpty {
                Text("Up Next")
                    .font(.system(size: 11, weight: .bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.6))
                VStack(spacing: 8) {
                    ForEach(state.upNext) { song in
                        HStack(spacing: 10) {
                            CoverImage(data: song.artwork)
                                .frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(song.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(song.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                            }
                            .foregroundStyle(.white)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func lockScreen(_ state: NowPlayingState) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(state.title).font(.headline).lineLimit(1)
                Text(state.artist).font(.caption).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(intent: PlayPauseIntent()) {
                Image(systemName: state.playPauseSymbol)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
        }
    }
}

/// A record with the cover as its label and a tonearm. Widgets can't spin,
/// so each song turns the record to its own angle.
private struct Turntable: View {
    let state: NowPlayingState
    let size: CGFloat

    /// Stable per title: the same song always sits at the same angle.
    private var angle: Double {
        Double(state.title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % 360)
    }

    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.07))
            ForEach(0..<6, id: \.self) { ring in
                Circle()
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
                    .padding(size * (0.06 + CGFloat(ring) * 0.04))
            }
            CoverImage(data: state.artwork)
                .frame(width: size * 0.38, height: size * 0.38)
                .clipShape(Circle())
                .rotationEffect(.degrees(angle))
            Circle()
                .fill(AngularGradient(colors: [.clear, .white.opacity(0.14), .clear, .clear, .white.opacity(0.1), .clear], center: .center))
            Circle()
                .fill(Color.black)
                .frame(width: size * 0.05, height: size * 0.05)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.5), radius: 8, y: 6)
        .overlay(alignment: .topTrailing) { tonearm }
        .accessibilityHidden(true)
    }

    /// Pivots at the top right; swings onto the record while playing.
    private var tonearm: some View {
        ZStack(alignment: .top) {
            Capsule()
                .fill(Color(white: 0.82))
                .frame(width: size * 0.04, height: size * 0.55)
            Circle()
                .fill(Color(white: 0.7))
                .frame(width: size * 0.1, height: size * 0.1)
                .offset(y: -size * 0.03)
        }
        .rotationEffect(.degrees(state.isPlaying ? 28 : 6), anchor: .top)
        .offset(x: -size * 0.02, y: -size * 0.02)
    }
}
