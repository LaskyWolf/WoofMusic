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
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isScrubbing) { _, active, _ in active = true }
                    .onChanged { value in
                        onEditingChanged(true)
                        let loc = value.location.x
                        let percent = width > 0 ? max(0, min(1, loc / width)) : 0
                        progress = Float(percent)
                    }
                    .onEnded { _ in
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 32)
        .animation(.easeInOut(duration: reduceMotion ? 0.12 : (isScrubbing ? 0.4 : 0.3)), value: isScrubbing)
    }
}

// MARK: - PlaybackControlsRow
struct PlayerPlayPauseButton: View {
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 42))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        }
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
    @State private var previousAnimation = 0
    @State private var nextAnimation = 0

    var body: some View {
        HStack(spacing: 0) {
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
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Previous")

            PlayerPlayPauseButton(isPlaying: isPlaying, action: onPlayPause)
            .frame(maxWidth: .infinity)

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
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Next")
        }
        .padding(.horizontal, 24)
    }
}

private struct PlayerSkipButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.9)
            .frame(width: 68, height: 68)
            .background(.white.opacity(configuration.isPressed ? 0.12 : 0), in: Circle())
            .contentShape(Circle())
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.85)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct PlayerTransportAirPlayFooter: View {
    let isPlaying: Bool
    let hasPrevious: Bool
    let hasNext: Bool
    let onPrevious: () -> Void
    let onPlayPause: () -> Void
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PlaybackControlsRow(
                isPlaying: isPlaying,
                hasPrevious: hasPrevious,
                hasNext: hasNext,
                onPrevious: onPrevious,
                onPlayPause: onPlayPause,
                onNext: onNext
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isPlaying)

            HStack {
                Spacer()
                PlayerAirPlayControl()
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 16)
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
