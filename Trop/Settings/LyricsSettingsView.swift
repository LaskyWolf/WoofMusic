//
//  LyricsSettingsView.swift
//  Trop
//
//  Created by 686udjie on 20/08/2026.
//

import SwiftUI

struct LyricsSettingsView: View {
    @Environment(\.settingsStore) private var settings

    var body: some View {
        List {
            Section {
                LabeledContent {
                    Menu {
                        ForEach(LyricsProviderRegistry.all, id: \.id) { provider in
                            Toggle(provider.name, isOn: isEnabled(provider.id))
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(sourcesSummary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    // Stay open so several sources can be switched in one go.
                    .menuActionDismissBehavior(.disabled)
                } label: {
                    Label("Sources", systemImage: "music.note")
                }

                NavigationLink {
                    LyricsProviderOrderView()
                } label: {
                    Label("Source Order", systemImage: "list.number")
                }
            } footer: {
                Text("Lyrics are searched in this order; turned-off sources are skipped.")
            }
        }
        .navigationTitle("Lyrics")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
    }

    private var sourcesSummary: String {
        let all = LyricsProviderRegistry.all
        let enabled = all.filter { !settings.disabledLyricsProviders.contains($0.id) }.count
        return enabled == all.count ? "All" : "\(enabled) of \(all.count)"
    }

    private func isEnabled(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !settings.disabledLyricsProviders.contains(id) },
            set: { enabled in
                if enabled {
                    settings.disabledLyricsProviders.remove(id)
                } else {
                    settings.disabledLyricsProviders.insert(id)
                }
            }
        )
    }
}
