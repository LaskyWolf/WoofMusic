//
//  ListenBrainzSettingsView.swift
//  Trop
//

import SwiftUI

struct ListenBrainzSettingsView: View {
    private let listenBrainz = ListenBrainz.shared
    @State private var token = ""
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        List {
            if let userName = listenBrainz.userName {
                Section {
                    LabeledContent("Connected as", value: userName)
                    Button("Disconnect", role: .destructive) { listenBrainz.disconnect() }
                } footer: {
                    Text("Songs count once half of them, or 4 minutes, has played.")
                }
            } else {
                Section {
                    SecureField("User Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(connect)
                    Button(action: connect) {
                        HStack {
                            Text("Connect")
                            if isConnecting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        if let error {
                            Text(error).foregroundStyle(.red)
                        }
                        Text("ListenBrainz is a free, open alternative to Last.fm. Copy your user token from [listenbrainz.org/settings](https://listenbrainz.org/settings/).")
                    }
                }
            }
        }
        .navigationTitle("ListenBrainz")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
    }

    private func connect() {
        guard !isConnecting else { return }
        isConnecting = true
        error = nil
        Task {
            defer { isConnecting = false }
            do {
                try await listenBrainz.connect(token: token)
                token = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
