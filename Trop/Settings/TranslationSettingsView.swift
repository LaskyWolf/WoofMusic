//
//  TranslationSettingsView.swift
//  Trop
//
//  The engine picker behind the 文A button: Apple's on-device model, or one of
//  the network services with the listener's own key.
//

import SwiftUI

struct TranslationSettingsView: View {
    @State private var engine: TranslationEngine = TranslationSettings.engine
    @State private var target: String = TranslationSettings.targetOption
    @State private var model: String = ""
    @State private var key: String = ""
    @State private var base: String = ""

    var body: some View {
        List {
            Section {
                Picker("Engine", selection: $engine) {
                    ForEach(TranslationEngine.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                Picker("Translate into", selection: $target) {
                    ForEach(TranslationSettings.targets) { item in
                        Text(item.name).tag(item.id)
                    }
                }
            } footer: {
                Text("Apple's engine runs on the phone: free, private, one language model download. The others send the lyric lines to the service you pick and are billed by it.")
            }

            if engine.needsKey {
                Section {
                    SecureField("API key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Model", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if engine == .custom || engine == .openAI || engine == .openRouter {
                        TextField("Base URL", text: $base)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                } header: {
                    Text(engine.title)
                } footer: {
                    Text("Key: \(engine.keyHint). Model ids change on the provider's side, so if it answers 404, type the current one. The key is stored in this app's preferences, not in the Keychain.")
                }

                Section {
                    Button {
                        model = engine.defaultModel
                        base = engine.defaultBaseURL ?? ""
                    } label: {
                        Label("Reset model and URL", systemImage: "arrow.counterclockwise")
                    }
                } footer: {
                    Text("Settings are per engine, so switching back and forth keeps each one's key.")
                }
            }
        }
        .navigationTitle("Translation")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
        .onAppear { load() }
        .onChange(of: engine) { _, newValue in
            TranslationSettings.engine = newValue
            load()
        }
        .onChange(of: target) { _, newValue in
            TranslationSettings.targetOption = newValue
        }
        .onChange(of: key) { _, newValue in
            TranslationSettings.setKey(newValue, for: engine)
        }
        .onChange(of: model) { _, newValue in
            TranslationSettings.setModel(newValue, for: engine)
        }
        .onChange(of: base) { _, newValue in
            TranslationSettings.setBaseURL(newValue, for: engine)
        }
    }

    private func load() {
        model = TranslationSettings.model(for: engine)
        key = TranslationSettings.key(for: engine) ?? ""
        base = TranslationSettings.baseURL(for: engine)
    }
}
