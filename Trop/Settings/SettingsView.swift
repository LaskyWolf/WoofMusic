//
//  SettingsView.swift
//  Trop
//
//  Created by 686udjie on 16/07/2026.
//

import SwiftUI

struct SettingsView: View {
    private let account = AccountState.shared
    @State private var showsDiagnostics = false

    var body: some View {
        List {
            Section {
                accountRow
            }

            Section {
                SettingsNavigationRow("Appearance", icon: "paintpalette") {
                    AppearanceSettingsView()
                }
            } header: {
                Text("Appearance")
            }

            Section {
                SettingsNavigationRow("Player", icon: "play.circle") {
                    PlayerSettingsView()
                }
                SettingsNavigationRow("Downloads", icon: "arrow.down.circle") {
                    DownloadSettingsView()
                }
            } header: {
                Text("Playback & Offline")
            }

            Section {
                SettingsNavigationRow("Content", icon: "globe") {
                    ContentSettingsView()
                }
            } header: {
                Text("Content")
            }

            Section {
                SettingsNavigationRow("Integrations", icon: "puzzlepiece.extension") {
                    IntegrationsSettingsView()
                }
                // Hidden: a long press opens Diagnostics.
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.8).onEnded { _ in showsDiagnostics = true })
                .sensoryFeedback(.impact(weight: .medium), trigger: showsDiagnostics) { _, isShown in isShown }
            } header: {
                Text("Integrations")
            }
        }
        .listSectionSpacing(.compact)
        .scrollBounceBehavior(.basedOnSize)
        .navigationDestination(isPresented: $showsDiagnostics) { DiagnosticsView() }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
    }

    private var avatar: some View {
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
    }

    /// Opens the profile: sign in or out, the picture, Woof Recap and badges.
    private var accountRow: some View {
        NavigationLink {
            ProfileView()
        } label: {
            HStack(spacing: 14) {
                avatar

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.isLoggedIn ? account.accountName : "Not Signed In")
                        .font(.headline)
                        .lineLimit(1)
                    Text(account.isLoggedIn ? "YouTube Music" : "Sign in to sync your library")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
