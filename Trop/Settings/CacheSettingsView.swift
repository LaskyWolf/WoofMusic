//
//  CacheSettingsView.swift
//  Trop
//
//  How much disk the app may use, and what is already on it.
//

import SwiftUI

struct CacheSettingsView: View {
    @Environment(\.settingsStore) private var settings
    @State private var used: Int64 = 0
    @State private var canvasUsed: Int64 = 0

    var body: some View {
        @Bindable var settings = settings

        List {
            Section {
                Picker("Limit", selection: $settings.cacheLimitMB) {
                    ForEach(CacheManager.choices, id: \.self) { mb in
                        Text(mb >= 1024 ? "\(mb / 1024) GB" : "\(mb) MB").tag(mb)
                    }
                }
            } header: {
                Text("Disk Limit")
            } footer: {
                Text("Covers, clips and translated lyrics share this budget. Lowering it deletes the oldest clips first.")
            }

            Section {
                LabeledContent("Used", value: CacheManager.formatted(used))
                LabeledContent("Of limit", value: CacheManager.formatted(CacheManager.limitBytes))
                LabeledContent("Imported clips", value: CacheManager.formatted(canvasUsed))
            } header: {
                Text("On Disk")
            }

            Section {
                Button("Clear Artwork Cache") {
                    CacheManager.clearArtwork()
                    refresh()
                }
                Button("Delete Imported Clips", role: .destructive) {
                    CacheManager.clearCanvases()
                    refresh()
                }
            } footer: {
                Text("Downloaded songs and liked music are not touched.")
            }
        }
        .navigationTitle("Cache")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
        .onChange(of: settings.cacheLimitMB) { _, _ in refresh() }
    }

    private func refresh() {
        used = CacheManager.usedBytes()
        canvasUsed = CacheManager.canvasBytes()
    }
}
