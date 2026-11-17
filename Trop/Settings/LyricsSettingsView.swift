//
//  LyricsSettingsView.swift
//  Trop
//
//  Created by 686udjie on 20/08/2026.
//

import SwiftUI

struct LyricsSettingsView: View {
    @Environment(\.settingsStore) private var settings
    @State private var betterLyricsKey = LyricsAPIKeys.betterLyrics ?? ""
    @State private var paxsenixKey = LyricsAPIKeys.paxsenix ?? ""

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

            Section {
                Toggle(isOn: Binding(
                    get: { settings.showLyricsTranslation },
                    set: { settings.showLyricsTranslation = $0 }
                )) {
                    Label("Translations", systemImage: "character.bubble")
                }

                NavigationLink {
                    TranslationSettingsView()
                } label: {
                    Label("Translation Engine", systemImage: "character.bubble.fill")
                }
            } footer: {
                Text("Shows the translated line under the original. The engine is either Apple's on-device model or a service you key in.")
            }

            Section {
                SecureField("API key", text: $betterLyricsKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: betterLyricsKey) { _, newValue in
                        UserDefaults.standard.set(
                            newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                            forKey: LyricsAPIKeys.betterLyricsDefaultsKey
                        )
                    }
            } header: {
                Text("Better Lyrics Key")
            } footer: {
                Text("Optional. Without a key Better Lyrics only returns tracks somebody already requested; a free key is on docs.betterlyrics.org.")
            }

            Section {
                SecureField("API key", text: $paxsenixKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: paxsenixKey) { _, newValue in
                        UserDefaults.standard.set(
                            newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                            forKey: LyricsAPIKeys.paxsenixDefaultsKey
                        )
                    }
            } header: {
                Text("Paxsenix Key")
            } footer: {
                Text("Optional. Paxsenix proxies Apple Music's own word-timed lyrics and needs an account key from api.paxsenix.org; without one the source stays off.")
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
