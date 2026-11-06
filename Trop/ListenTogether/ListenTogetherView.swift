//
//  ListenTogetherView.swift
//  Trop
//
//  Start or join a Listen Together room, and run it: who is in, who wants
//  in, what guests suggest.
//

import SwiftUI

struct ListenTogetherView: View {
    @Environment(SettingsStore.self) private var settings
    private let room = ListenTogether.shared
    @State private var code = ""

    var body: some View {
        List {
            if let notice = room.notice {
                Section {
                    Label(notice, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }

            switch room.status {
            case .idle:
                startSections(settings: settings)
            case .connecting, .waitingForApproval:
                waitingSection
            case .inRoom, .reconnecting:
                roomSections
            }
        }
        .navigationTitle("Listen Together")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.default, value: room.status)
        .animation(.default, value: room.users)
        .animation(.default, value: room.joinRequests)
    }

    // MARK: - Not in a room

    @ViewBuilder
    private func startSections(settings: SettingsStore) -> some View {
        @Bindable var settings = settings

        Section {
            TextField("Your name", text: $settings.listenTogetherUsername, prompt: Text(AccountState.shared.accountName))
                .textContentType(.nickname)
        } header: {
            Text("Name")
        } footer: {
            Text("Everyone in the room sees it.")
        }

        Section {
            Button("Start a Room", systemImage: "person.2.wave.2") { room.createRoom() }
        } footer: {
            Text("You control the music. Share the room code; you let each person in.")
        }

        Section {
            TextField("Room code", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .onSubmit(join)
            Button("Join Room", systemImage: "arrow.right.circle", action: join)
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Join")
        } footer: {
            Text("The host's music plays on your phone, in step with theirs.")
        }

        Section {
            TextField("Server", text: $settings.listenTogetherServerURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote.monospaced())
            if settings.listenTogetherServerURL != ListenTogether.defaultServerURL {
                Button("Use Metrolist's Server") {
                    settings.listenTogetherServerURL = ListenTogether.defaultServerURL
                }
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Rooms are shared with Metrolist on the same server, so Android friends can join too.")
        }
    }

    private func join() {
        room.joinRoom(code: code)
    }

    private var waitingSection: some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text(room.status == .connecting ? "Connecting…" : "Waiting for the host to let you in…")
                    .foregroundStyle(.secondary)
            }
            Button("Cancel", role: .cancel) { room.leave() }
        }
    }

    // MARK: - In a room

    @ViewBuilder
    private var roomSections: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(room.isHost ? "You're the host" : "Listening along")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(room.roomCode ?? "")
                    .font(.largeTitle.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                if room.status == .reconnecting {
                    Label("Reconnecting…", systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)
            if let code = room.roomCode {
                ShareLink(item: "Listen with me on WoofMusic or Metrolist. Room code: \(code)") {
                    Label("Share Room Code", systemImage: "square.and.arrow.up")
                }
            }
        } footer: {
            if room.isGuest {
                Text("The host controls the music. Suggest songs from any song's menu.")
            }
        }

        if room.isHost, !room.joinRequests.isEmpty {
            Section("Wants to Join") {
                ForEach(room.joinRequests) { request in
                    HStack {
                        Label {
                            Text(ListenTogether.split(request.username).name)
                        } icon: {
                            MemberPicture(name: ListenTogether.split(request.username).name, url: room.pictureURL(forName: request.username))
                        }
                        Spacer()
                        Button("Decline", systemImage: "xmark") { room.reject(request) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.bordered)
                            .tint(.red)
                        Button("Let In", systemImage: "checkmark") { room.approve(request) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }

        if room.isHost, !room.suggestions.isEmpty {
            Section("Suggestions") {
                ForEach(room.suggestions) { suggestion in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.track.title)
                                .lineLimit(1)
                            Text("\(suggestion.track.artist) · from \(ListenTogether.split(suggestion.fromUsername).name)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Skip", systemImage: "xmark") { room.reject(suggestion) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.bordered)
                        Button("Play Next", systemImage: "text.insert") { room.approve(suggestion) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }

        Section("In the Room") {
            ForEach(room.users) { user in
                HStack {
                    let name = ListenTogether.split(user.username).name
                    Label {
                        Text(user.userId == room.myUserId ? "\(name) (you)" : name)
                    } icon: {
                        MemberPicture(name: name, url: room.pictureURL(for: user))
                            .overlay(alignment: .bottomTrailing) {
                                if user.isHost {
                                    Image(systemName: "crown.fill")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.yellow)
                                        .padding(3)
                                        .background(Color(.secondarySystemGroupedBackground), in: .circle)
                                        .offset(x: 5, y: 4)
                                        .accessibilityLabel("Host")
                                }
                            }
                    }
                    Spacer()
                    if !user.isConnected {
                        Text("Away")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    if room.isHost, user.userId != room.myUserId {
                        Button("Make Host", systemImage: "crown") { room.makeHost(user) }
                        Button("Remove", systemImage: "person.fill.xmark", role: .destructive) { room.kick(user) }
                    }
                }
            }
        }

        Section {
            Button("Leave Room", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                room.leave()
            }
        }
    }
}

/// A member's YouTube picture, or their initial on a colour of their own.
private struct MemberPicture: View {
    let name: String
    let url: String?

    var body: some View {
        Group {
            if let url {
                AsyncImageView(url: url)
            } else {
                Circle()
                    .fill(color.gradient)
                    .overlay {
                        Text(String(name.split(separator: " ").first?.first ?? "?").uppercased())
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(.circle)
    }

    private static let colors: [Color] = [.orange, .pink, .purple, .indigo, .teal, .green, .brown]

    /// The same colour for a name on every launch (`hashValue` changes per launch).
    private var color: Color {
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Self.colors[sum % Self.colors.count]
    }
}
