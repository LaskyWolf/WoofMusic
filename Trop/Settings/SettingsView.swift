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
    @State private var isEditingPicture = false
    /// Picture fetched after Studio closes. AccountState keeps its own fetch
    /// private, so only this screen shows the new picture until next launch.

    var body: some View {
        List {
            Section {
                accountRow
                if account.isLoggedIn {
                    Button {
                        isEditingPicture = true
                    } label: {
                        Label("Change Profile Picture", systemImage: "camera")
                    }
                    .tint(settings.accentColor)
                }
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
            } header: {
                Text("Integrations")
            }
        }
        .listSectionSpacing(.compact)
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
        .loginSheet()
        .sheet(isPresented: $isEditingPicture, onDismiss: { Task { await account.fetchAccountInfo() } }) {
            NavigationStack {
                ProfilePictureWebView()
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("YouTube Studio")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isEditingPicture = false }
                        }
                    }
            }
        }
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

    private var accountRow: some View {
        HStack(spacing: 14) {
            if account.isLoggedIn {
                Button {
                    isEditingPicture = true
                } label: {
                    avatar.overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 20, height: 20)
                            .glassEffect(.regular, in: Circle())
                            .offset(x: 4, y: 4)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change Profile Picture")
            } else {
                avatar
            }

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
