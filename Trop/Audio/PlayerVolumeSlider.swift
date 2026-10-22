//
//  PlayerVolumeSlider.swift
//  Trop
//

import AVFoundation
import MediaPlayer
import SwiftUI

/// The system volume as a player-styled bar, like Apple Music's. It follows
/// the hardware buttons and Control Center, and dragging it sets the device
/// volume.
struct PlayerVolumeSlider: View {
    @State private var volume = AVAudioSession.sharedInstance().outputVolume
    @State private var isDragging = false
    @State private var systemVolume = SystemVolume()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.caption)
            ProgressBar(
                progress: Binding(
                    get: { volume },
                    set: { volume = $0; systemVolume.set($0) }
                ),
                accentColor: .white,
                isPlaying: false,
                onEditingChanged: { isDragging = $0 }
            )
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption)
        }
        .foregroundStyle(.white.opacity(0.6))
        .padding(.horizontal, 32)
        // iOS only applies volume changes (and hides its own volume HUD)
        // while an MPVolumeView is on screen; this one is invisible.
        .background(SystemVolumeHost(systemVolume: systemVolume))
        .onReceive(AVAudioSession.sharedInstance().publisher(for: \.outputVolume)) { newValue in
            if !isDragging { volume = newValue }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(volume * 100))%")
        .accessibilityAdjustableAction { direction in
            let step: Float = direction == .increment ? 0.0625 : -0.0625
            volume = min(1, max(0, volume + step))
            systemVolume.set(volume)
        }
    }
}

/// Holds the hidden MPVolumeView whose internal slider is the only public
/// way to change the device volume.
@MainActor
final class SystemVolume {
    let view = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 1, height: 1))

    func set(_ value: Float) {
        guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.value = value
    }
}

private struct SystemVolumeHost: UIViewRepresentable {
    let systemVolume: SystemVolume

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.isUserInteractionEnabled = false
        systemVolume.view.alpha = 0.01
        container.addSubview(systemVolume.view)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
