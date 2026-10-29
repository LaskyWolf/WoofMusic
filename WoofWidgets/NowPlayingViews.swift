//
//  NowPlayingViews.swift
//  WoofWidgets
//

import AppIntents
import SwiftUI
import UIKit

extension NowPlayingState {
    /// Dominant artwork color, or the app's accent when there is none.
    var tintColor: Color {
        guard let tint else { return .red }
        return Color(
            red: Double((tint >> 16) & 0xFF) / 255,
            green: Double((tint >> 8) & 0xFF) / 255,
            blue: Double(tint & 0xFF) / 255
        )
    }

    /// Same glyphs as the app: an episode swaps play/pause for a microphone.
    var playPauseSymbol: String {
        if isPodcast { return isPlaying ? "mic.fill" : "mic.slash.fill" }
        return isPlaying ? "pause.fill" : "play.fill"
    }

    /// What the compact Dynamic Island shows next to the cover.
    var stateSymbol: String {
        if isPodcast { return isPlaying ? "mic.fill" : "mic.slash.fill" }
        return isPlaying ? "waveform" : "pause.fill"
    }
}

struct ArtworkView: View {
    let state: NowPlayingState?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let data = state?.artwork, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: state?.isPodcast == true ? "mic.fill" : "music.note")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.15))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct SongTitles: View {
    let state: NowPlayingState
    var lineLimit = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(lineLimit)
            Text(state.artist)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
    }
}

struct PlaybackButtons: View {
    let state: NowPlayingState
    var showsNext = true

    var body: some View {
        HStack(spacing: 18) {
            Button(intent: PlayPauseIntent()) {
                Image(systemName: state.playPauseSymbol)
            }
            .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
            if showsNext {
                Button(intent: NextSongIntent()) {
                    Image(systemName: "forward.fill")
                }
                .accessibilityLabel("Next Song")
            }
        }
        .buttonStyle(.plain)
        .font(.title2)
        .foregroundStyle(.white)
    }
}

/// A bar that the system animates on its own while playing; static when paused.
struct SongProgress: View {
    let state: NowPlayingState

    var body: some View {
        if state.duration > 0 {
            HStack(spacing: 8) {
                Group {
                    if state.isPlaying {
                        ProgressView(timerInterval: state.startedAt...state.endsAt, countsDown: false) {
                            EmptyView()
                        } currentValueLabel: {
                            EmptyView()
                        }
                    } else {
                        ProgressView(value: min(state.elapsed, state.duration), total: state.duration)
                    }
                }
                .progressViewStyle(.linear)
                .tint(state.tintColor)

                Text(
                    timerInterval: state.startedAt...state.endsAt,
                    pauseTime: state.isPlaying ? nil : state.startedAt.addingTimeInterval(state.elapsed),
                    countsDown: true
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.trailing)
                .frame(width: 52, alignment: .trailing)
            }
        }
    }
}
