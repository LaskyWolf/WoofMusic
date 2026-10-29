//
//  PlayerComponents.swift
//  Trop
//
//  Created by 686udjie on 13/07/2026.
//

import SwiftUI
import AVKit

// MARK: - ProgressBar
struct ProgressBar: View {
    @Binding var progress: Float
    let accentColor: Color
    let isPlaying: Bool
    let onEditingChanged: (Bool) -> Void
    @GestureState private var isScrubbing = false
    @State private var didStartEditing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let trackInset: CGFloat = isScrubbing ? 0 : 9
            let trackWidth = max(0, width - trackInset * 2)
            let elapsedWidth = max(0, min(trackWidth, trackWidth * CGFloat(progress)))
            let trackHeight: CGFloat = isScrubbing ? 17 : 7

            ZStack(alignment: .leading) {
                // Remaining track (unwatched)
                Capsule()
                    .fill(.white.opacity(0.15))
                    .frame(height: trackHeight)

                // Elapsed track (watched, marked)
                Capsule()
                    .fill(.white.opacity(isScrubbing ? 1 : 0.8))
                    .frame(width: elapsedWidth, height: trackHeight)
            }
            .padding(.horizontal, trackInset)
            .animation(.easeInOut(duration: reduceMotion ? 0.12 : (isScrubbing ? 0.4 : 0.3)), value: isScrubbing)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isScrubbing) { _, active, _ in active = true }
                    .onChanged { value in
                        // Tell the parent once per drag, then just move the bar.
                        if !didStartEditing {
                            didStartEditing = true
                            onEditingChanged(true)
                        }
                        let percent = width > 0 ? max(0, min(1, value.location.x / width)) : 0
                        progress = Float(percent)
                    }
                    .onEnded { _ in
                        didStartEditing = false
                        onEditingChanged(false)
                    }
            )
            .onChange(of: isScrubbing) { _, scrubbing in
                // A cancelled drag (e.g. the sheet takes over the touch) never
                // calls onEnded; finish the edit here so the bar doesn't freeze.
                if !scrubbing, didStartEditing {
                    didStartEditing = false
                    onEditingChanged(false)
                }
            }
        }
        .frame(height: 32)
    }
}

/// Play/pause icon that turns into a spinner when a song takes longer than
/// `spinnerDelay` to load. Shorter loads keep the icon unchanged.
struct PlayPauseGlyph: View {
    let isPlaying: Bool
    let size: CGFloat
    var color: Color?

    static let spinnerDelay: Duration = .milliseconds(500)

    @State private var showsSpinner = false
    /// `isPlaying` from when the load started, so a quick skip doesn't flicker the icon.
    @State private var playingBeforeLoad: Bool?

    private var style: AnyShapeStyle {
        color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint)
    }

    /// Every caller shows the now-playing item, so a podcast episode swaps
    /// play/pause for a microphone: on while playing, crossed out while paused.
    private func symbol(playing: Bool) -> String {
        if NowPlaying.shared.musicVideoType == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" {
            return playing ? "mic.fill" : "mic.slash.fill"
        }
        return playing ? "pause.fill" : "play.fill"
    }

    var body: some View {
        let isLoading = NowPlaying.shared.isLoadingTrack
        ZStack {
            if showsSpinner {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.regular)
                    .scaleEffect(size / 20)
                    .tint(color)
                    .transition(.opacity)
            } else {
                // A moon replaces the button while the sleep timer animation plays.
                Image(systemName: SleepTimer.shared.isCelebrating ? "moon.fill" : symbol(playing: playingBeforeLoad ?? isPlaying))
                    .font(.system(size: size))
                    .foregroundStyle(style)
                    .contentTransition(.symbolEffect(.replace))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: showsSpinner)
        .task(id: isLoading) {
            guard isLoading else {
                showsSpinner = false
                playingBeforeLoad = nil
                return
            }
            playingBeforeLoad = isPlaying
            try? await Task.sleep(for: Self.spinnerDelay)
            if !Task.isCancelled { showsSpinner = true }
        }
    }
}

// MARK: - PlaybackControlsRow
struct PlayerPlayPauseButton: View {
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PlayPauseGlyph(isPlaying: isPlaying, size: 42, color: .white)
        }
        // Scoped here: on the whole row it also bent the skip glyph
        // animation whenever play state changed mid-skip.
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isPlaying)
        .frame(width: 80, height: 80)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

struct PlaybackControlsRow: View {
    let isPlaying: Bool
    let hasPrevious: Bool
    let hasNext: Bool

    let onPrevious: () -> Void
    let onPlayPause: () -> Void
    let onNext: () -> Void
    /// The karaoke mascot or the radio antenna stands in its place.
    var hidesPlayPause = false
    @State private var previousAnimation = 0
    @State private var nextAnimation = 0

    var body: some View {
        // A centered group with fixed gaps, not spread over the whole width.
        HStack(spacing: 24) {
            Button {
                previousAnimation &+= 1
                onPrevious()
            } label: {
                AnimatedSkipLabel(backwards: true, trigger: previousAnimation)
                    .foregroundStyle(.white)
            }
            .buttonStyle(PlayerSkipButtonStyle())
            .disabled(!hasPrevious)
            .opacity(hasPrevious ? 1 : 0.3)
            .accessibilityLabel("Previous")

            PlayerPlayPauseButton(isPlaying: isPlaying, action: onPlayPause)
                .scaleEffect(hidesPlayPause ? 0.3 : 1)
                .opacity(hidesPlayPause ? 0 : 1)
                .allowsHitTesting(!hidesPlayPause)

            Button {
                nextAnimation &+= 1
                onNext()
            } label: {
                AnimatedSkipLabel(backwards: false, trigger: nextAnimation)
                    .foregroundStyle(.white)
            }
            .buttonStyle(PlayerSkipButtonStyle())
            .disabled(!hasNext)
            .opacity(hasNext ? 1 : 0.3)
            .accessibilityLabel("Next")
        }
    }
}

private struct PlayerSkipButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 68, height: 68)
            .background(.white.opacity(configuration.isPressed ? 0.12 : 0), in: Circle())
            .contentShape(Circle())
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.85)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - SecondaryActionsRow
struct SecondaryActionsRow: View {
    @Binding var showQueue: Bool
    @Binding var isRepeatOn: Bool
    var showLyrics: Binding<Bool>? = nil

    var body: some View {
        HStack(spacing: 0) {
            if let showLyrics {
                Button {
                    showLyrics.wrappedValue.toggle()
                } label: {
                    Image(systemName: "quote.bubble")
                        .font(.title3)
                        .foregroundStyle(showLyrics.wrappedValue ? .white : .white.opacity(0.7))
                        .frame(width: 44, height: 44)
                        .background(showLyrics.wrappedValue ? Circle().fill(.white.opacity(0.15)) : Circle().fill(.clear))
                }
                .accessibilityLabel(showLyrics.wrappedValue ? "Close lyrics" : "Open lyrics")
                .frame(maxWidth: .infinity)
            }

            PlayerAirPlayControl()
                .frame(maxWidth: .infinity)

            // Queue + Repeat stacked like Apple Music
            ZStack(alignment: .topTrailing) {
                Button {
                    showQueue.toggle()
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                        .foregroundStyle(showQueue ? .white : .white.opacity(0.7))
                        .padding(10)
                        .background(showQueue ? Circle().fill(.white.opacity(0.15)) : Circle().fill(.clear))
                }
                .accessibilityLabel("Queue")

                if !showQueue {
                    Button {
                        isRepeatOn.toggle()
                    } label: {
                        Image(systemName: isRepeatOn ? "repeat.1" : "repeat")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(isRepeatOn ? .white : .white.opacity(0.7))
                            .padding(4)
                    }
                    .offset(x: 2, y: -2)
                    .accessibilityLabel(isRepeatOn ? "Repeat one" : "Repeat all")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 16)
    }
}

struct PlayerAirPlayControl: View {
    var body: some View {
        Button {} label: {
            Image(systemName: "airplayaudio")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))
                .padding(10)
        }
        .overlay(AirPlayButton())
        .accessibilityLabel("AirPlay")
    }
}

// MARK: - AirPlayButton
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: UIViewRepresentableContext<Self>) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = UIColor.clear
        picker.activeTintColor = UIColor.clear
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: UIViewRepresentableContext<Self>) {}
}
