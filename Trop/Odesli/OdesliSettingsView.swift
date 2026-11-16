//
//  OdesliSettingsView.swift
//  Trop
//

import SwiftUI

struct OdesliSettingsView: View {
    private let odesli = Odesli.shared
    @State private var key = ""
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        List {
            if odesli.isConnected {
                Section {
                    LabeledContent("Status", value: "Connected")
                    Button("Disconnect", role: .destructive) { odesli.disconnect() }
                } footer: {
                    Text("Each Spotify or Apple Music link you open in Woof Music is sent to Odesli.")
                }
            } else {
                Section {
                    SecureField("API Key", text: $key)
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
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        if let error {
                            Text(error).foregroundStyle(.red)
                        }
                        Text("Odesli finds Spotify and Apple Music links on YouTube Music, so they open in Woof Music. Ask for a key at [developers@song.link](mailto:developers@song.link).")
                    }
                }
            }
        }
        .navigationTitle("Odesli")
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
                try await odesli.connect(key: key)
                key = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
