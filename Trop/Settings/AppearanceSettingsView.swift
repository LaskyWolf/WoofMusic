//
//  AppearanceSettingsView.swift
//  Trop
//
//  Created by 686udjie on 20/08/2026.
//

import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var spotifyCookie = SpotifyCanvasSettings.sessionCookie ?? ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 6)

    var body: some View {
        @Bindable var settings = settings

        List {
            Section {
                SettingsPickerRow("Theme Mode", icon: "sun.max", selection: $settings.themeMode)
            } header: {
                Text("Theme")
            } footer: {
                Text("Choose how the app follows your device appearance.")
            }

            Section {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(AccentPreset.all) { preset in
                        Button {
                            applyAppIcon(for: preset)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(preset.color)
                                    .frame(width: 34, height: 34)
                                if settings.accentName == preset.name {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.name)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Accent Color")
            } footer: {
                Text("Applies to buttons, highlights, and selected items.")
            }

            Section {
                SettingsPickerRow("Player Style", icon: "play.rectangle", selection: $settings.playerStyle)
                SettingsPickerRow("Player Background", icon: "photo", selection: $settings.playerBackgroundStyle)
                NavigationLink {
                    CacheSettingsView()
                } label: {
                    LabeledContent("Cache", value: CacheManager.summary())
                }

                Toggle(isOn: $settings.showCanvas) {
                    Label("Canvas", systemImage: "play.rectangle.on.rectangle")
                }
            } header: {
                Text("Player")
            } footer: {
                Text("Immersive spreads the cover behind the controls. Card shows it as a square on one colour from the cover. Canvas plays the album's looping clip behind the player when the track has one.")
            }

            Section {
                SecureField("sp_dc cookie", text: $spotifyCookie)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: spotifyCookie) { _, newValue in
                        SpotifyCanvasSettings.setSessionCookie(newValue)
                    }
            } header: {
                Text("Spotify Canvas")
            } footer: {
                Text("Optional. Paste the sp_dc cookie from a signed-in open.spotify.com, and Canvas plays Spotify's own clip for the track; tracks without one fall back to Apple's motion artwork.")
            }

            Section {
                SettingsPickerRow("Library Layout", icon: "square.grid.2x2", selection: $settings.libraryLayout)
            } header: {
                Text("Library")
            }

            Section {
                SettingsPickerRow("Lyrics Alignment", icon: settings.lyricsAlignment.iconName, selection: $settings.lyricsAlignment)
            } header: {
                Text("Lyrics")
            }

            Section {
                Picker("Default Tab", selection: $settings.defaultTab) {
                    Text("Home").tag(0)
                    Text("Library").tag(1)
                    Text("Explore").tag(2)
                    Text("Search").tag(3)
                }
                Toggle(isOn: $settings.leftHandedTabBar) {
                    Label("Left-Handed Tab Bar", systemImage: "hand.point.left")
                }
            } header: {
                Text("General")
            } footer: {
                Text("Puts Search on the left, closer to your left thumb. Home, Library and Explore keep their order.")
            }
        }
        .id(settings.accentName)
        .tint(settings.accentColor)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
    }

    /// Applies the selected accent and selects its bundled alternate app icon.
    private func applyAppIcon(for preset: AccentPreset) {
        settings.accentName = preset.name

        guard UIApplication.shared.supportsAlternateIcons else { return }
        let target = preset.alternateIconName
        guard UIApplication.shared.alternateIconName != target else { return }

        UIApplication.shared.setAlternateIconName(target) { error in
            if let error {
                Log.settings.error("Failed to set alternate icon '\(target ?? "nil")': \(error)")
            }
        }
    }
}
