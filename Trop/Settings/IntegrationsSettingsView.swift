//
//  IntegrationsSettingsView.swift
//  Trop
//

import SwiftUI

struct IntegrationsSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        List {
            Section {
                SettingsNavigationRow("Discord", icon: "gamecontroller") {
                    DiscordSettingsView()
                }
                SettingsNavigationRow("Last.fm", icon: "music.note") {
                    LastFMSettingsView()
                }
                SettingsNavigationRow("ListenBrainz", icon: "headphones") {
                    ListenBrainzSettingsView()
                }
            } footer: {
                Text("Connect external services to enhance your experience.")
            }

            Section {
                SettingsToggleRow("Skip Non-Music Parts", icon: "forward.end", isOn: $settings.skipNonMusic)
            } footer: {
                Text("Skips talking intros and skits in music videos, using SponsorBlock's community data.")
            }
        }
        .navigationTitle("Integrations")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
    }
}
