//
//  ProfileView.swift
//  Trop
//

import SwiftUI

/// The account page pushed from Settings: picture, name, sign in or out,
/// Woof Recap and the badge shelf. Recap and badges come from this device's
/// history, so they work signed out too.
struct ProfileView: View {
    @Environment(SettingsStore.self) private var settings
    private let account = AccountState.shared

    @State private var isEditingPicture = false
    @State private var confirmsSignOut = false
    @State private var badges: [RecapBadge] = []
    @State private var lastMonthHasHistory = false
    @State private var recapInterval = RecapService.monthToDate()
    @State private var showsRecap = false
    @State private var selectedBadge: RecapBadge?

    var body: some View {
        List {
            Section {
                header
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }

            Section {
                if account.isLoggedIn {
                    Button("Sign Out", role: .destructive) { confirmsSignOut = true }
                } else {
                    Button {
                        account.isLoginSheetPresented = true
                    } label: {
                        Label("Sign In to YouTube Music", systemImage: "person.crop.circle.badge.plus")
                    }
                    .tint(settings.accentColor)
                }
            } footer: {
                if !account.isLoggedIn {
                    Text("Sign in to sync your library.")
                }
            }

            Section {
                recapRow("This Month's Recap", icon: "sparkles", interval: RecapService.monthToDate())
                if lastMonthHasHistory {
                    let last = RecapService.lastMonth()
                    recapRow("\(RecapService.monthName(last)) Recap", icon: "calendar", interval: last)
                }
            } header: {
                Text("Woof Recap")
            }

            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 16) {
                    ForEach(badges) { badge in
                        Button { selectedBadge = badge } label: {
                            BadgeTile(badge: badge)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
            } header: {
                Text("Badges")
            } footer: {
                Text("Badges come from what this iPhone played.")
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
        .loginSheet()
        .confirmationDialog("Sign out of YouTube Music?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { account.signOut() }
        }
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
        .sheet(item: $selectedBadge) { badge in
            BadgeDetailView(badge: badge)
                .appSheetChrome([.medium])
        }
        .recapStory(isPresented: $showsRecap, interval: recapInterval)
        .task(id: showsRecap) {
            // Also runs when the recap closes, so badges match what it showed.
            badges = await RecapService.lifetimeBadges()
            lastMonthHasHistory = await RecapService.hasHistory(in: RecapService.lastMonth())
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            if account.isLoggedIn {
                Button {
                    isEditingPicture = true
                } label: {
                    avatar.overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 32)
                            .glassEffect(.regular, in: Circle())
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change Profile Picture")
            } else {
                avatar
            }
            Text(account.isLoggedIn ? account.accountName : "Not Signed In")
                .font(.title2.weight(.bold))
                .lineLimit(1)
            Text(account.isLoggedIn ? "YouTube Music" : "Recap and badges use this iPhone's history")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
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
        .frame(width: 96, height: 96)
        .clipShape(Circle())
    }

    private func recapRow(_ title: String, icon: String, interval: DateInterval) -> some View {
        Button {
            recapInterval = interval
            showsRecap = true
        } label: {
            HStack {
                Label {
                    Text(title).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: icon)
                }
                Spacer()
                Image(systemName: "play.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(settings.accentColor)
    }
}

// MARK: - Badges

/// A badge's hexagon gem: its colours when unlocked, grey and faded when locked.
struct BadgeGem: View {
    let kind: RecapBadge.Kind
    var isUnlocked = true
    var size: CGFloat = 52

    var body: some View {
        Text(kind.emoji)
            .font(.system(size: size * 0.46))
            .frame(width: size, height: size * 1.12)
            .background(LinearGradient(colors: kind.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(BadgeHexagon())
            .grayscale(isUnlocked ? 0 : 1)
            .opacity(isUnlocked ? 1 : 0.35)
            .accessibilityHidden(true)
    }
}

/// Gem, name with a lock when locked, and the rule or the progress toward it.
struct BadgeTile: View {
    let badge: RecapBadge
    var isNew = false

    var body: some View {
        VStack(spacing: 5) {
            BadgeGem(kind: badge.kind, isUnlocked: badge.isUnlocked)
                .overlay(alignment: .topTrailing) {
                    if isNew {
                        Text("NEW")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(RecapPalette.gold, in: Capsule())
                            .offset(x: 10, y: -2)
                    }
                }
            HStack(spacing: 3) {
                Text(badge.kind.name)
                if !badge.isUnlocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                }
            }
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            Text(badge.isUnlocked ? badge.kind.summary : badge.progressText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let state = badge.isUnlocked ? "unlocked" : "locked, " + badge.progressText
        return badge.kind.name + ", " + state + (isNew ? ", new" : "")
    }
}

private struct BadgeDetailView: View {
    let badge: RecapBadge

    var body: some View {
        VStack(spacing: 12) {
            BadgeGem(kind: badge.kind, isUnlocked: badge.isUnlocked, size: 96)
            Text(badge.kind.name)
                .font(.title2.weight(.bold))
            Text(badge.kind.summary)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if badge.isUnlocked {
                Label("Unlocked", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(RecapPalette.teal)
            } else {
                ProgressView(value: badge.progress) {
                    Text(badge.progressText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .tint(RecapPalette.gold)
                .padding(.horizontal, 40)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Pointy-top hexagon filling its frame.
struct BadgeHexagon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.25))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.75))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.75))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.25))
        path.closeSubpath()
        return path
    }
}

extension RecapBadge.Kind {
    /// Light to dark gem gradient.
    var colors: [Color] {
        let pair: (UInt32, UInt32) = switch self {
        case .nightOwl: (0xB98CFF, 0x4B2A8A)
        case .earlyBird: (0xFFE08A, 0xE07B39)
        case .loyalPup: (0xFFD36E, 0xD9822B)
        case .streak: (0xFF8A8A, 0xA8324A)
        case .explorer: (0x7FE0D2, 0x2A7A70)
        case .podcastSage: (0xFFA98A, 0xB8463A)
        case .timeBender: (0x9FD0FF, 0x2B5FA8)
        }
        return [Self.color(pair.0), Self.color(pair.1)]
    }

    private static func color(_ hex: UInt32) -> Color {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        return Color(red: red, green: green, blue: blue)
    }
}
