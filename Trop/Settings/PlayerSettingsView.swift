//
//  PlayerSettingsView.swift
//  Trop
//
//  Created by 686udjie on 20/08/2026.
//

import SwiftUI

struct PlayerSettingsView: View {
    @Environment(\.settingsStore) private var settings

    var body: some View {
        @Bindable var settings = settings

        List {
            Section {
                SettingsNavigationRow("Equalizer", icon: "slider.vertical.3") {
                    EqualizerView()
                }
            } header: {
                Text("Equalizer")
            } footer: {
                Text("Adjust the sound with presets or a custom curve.")
            }

            Section {
                SettingsPickerRow("Audio Quality", icon: "waveform", selection: $settings.audioQuality)
                SettingsToggleRow("Audio Normalization", icon: "speaker.wave.2", isOn: $settings.audioNormalization)
                SettingsToggleRow("Gapless Playback", icon: "arrow.right.arrow.left", isOn: $settings.gaplessPlayback)
            } header: {
                Text("Audio")
            }

            Section {
                SettingsToggleRow("AutoMix", icon: "dial.medium", isOn: $settings.autoMixEnabled)
                SettingsToggleRow("Smart Crossfade", icon: "waveform.path", isOn: $settings.crossfadeEnabled)
                if settings.crossfadeEnabled {
                    LabeledContent {
                        Slider(value: $settings.crossfadeSeconds, in: 1...12, step: 1)
                            .frame(maxWidth: 180)
                    } label: {
                        Text("Fade \(Int(settings.crossfadeSeconds)) s")
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Transitions")
            } footer: {
                Text("AutoMix blends songs like a DJ: it matches their tempo, keeps the beats together and swaps the bass on the bar. Songs without a steady beat get a Smart Crossfade instead. Smart Crossfade fades into the next song where the current one winds down.
            }

            Section {
                SettingsToggleRow("Autoplay Similar", icon: "infinity", isOn: $settings.autoplaySimilar)
                SettingsToggleRow("Persist Queue", icon: "clock.arrow.circlepath", isOn: $settings.persistQueue)
            } header: {
                Text("Queue")
            } footer: {
                Text("Persist Queue restores your queue, shuffle, and repeat state when the app relaunches.")
            }

            Section {
                SettingsToggleRow("Swipe Artwork to Skip", icon: "hand.draw", isOn: $settings.artworkSwipeNavigation)
            } header: {
                Text("Gestures")
            } footer: {
                Text("Swipe left or right on the artwork in the full player to play the next or previous song.")
            }
        }
        .navigationTitle("Player")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
    }
}
