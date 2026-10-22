//
//  SettingsView.swift
//  Trop
//
//  Created by 686udjie on 16/07/2026.
//

import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    private let account = AccountState.shared

    var body: some View {
        List {
            Section {
                accountRow
            }

            // Grouped like iOS Settings: no headers, so the page fits
            // one screen without scrolling.
            Section {
                SettingsNavigationRow("Appearance", icon: "paintpalette") {
                    AppearanceSettingsView()
                }
                SettingsNavigationRow("Player", icon: "play.circle") {
                    PlayerSettingsView()
                }
                SettingsNavigationRow("Downloads", icon: "arrow.down.circle") {
                    DownloadSettingsView()
                }
            }

            Section {
                SettingsNavigationRow("Content", icon: "globe") {
                    ContentSettingsView()
                }
                SettingsNavigationRow("Integrations", icon: "puzzlepiece.extension") {
                    IntegrationsSettingsView()
                }
            }
        }
        .listSectionSpacing(.compact)
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
        .loginSheet()
    }

    private var accountRow: some View {
        HStack(spacing: 14) {
            Group {
                if account.isLoggedIn {
                    AsyncImageView(url: account.accountImageUrl)
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(account.isLoggedIn ? account.accountName : "Not Signed In")
                    .font(.headline)
                    .lineLimit(1)
                Text(account.isLoggedIn ? "YouTube Music" : "Sign in to sync your library")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if account.isLoggedIn {
                Button("Sign Out", role: .destructive) { account.signOut() }
                    .buttonStyle(.bordered)
            } else {
                Button("Sign In") { account.isLoginSheetPresented = true }
                    .buttonStyle(.borderedProminent)
                    .tint(settings.accentColor)
            }
        }
        .padding(.vertical, 4)
    }
}
