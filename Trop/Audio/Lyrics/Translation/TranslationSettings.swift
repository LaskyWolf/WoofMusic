//
//  TranslationSettings.swift
//  Trop
//
//  Which engine translates lyrics and how it is called. Apple's on-device
//  translation stays the default because it costs nothing and needs no key;
//  the network engines are opt-in and each keeps its own key and model id.
//

import Foundation

enum TranslationEngine: String, CaseIterable, Identifiable {
    case apple
    case openAI
    case openRouter
    case google
    case anthropic
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple (on device)"
        case .openAI: return "OpenAI"
        case .openRouter: return "OpenRouter"
        case .google: return "Google Gemini"
        case .anthropic: return "Anthropic Claude"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    var needsKey: Bool { self != .apple }

    /// Endpoint root for the engines that speak the OpenAI chat API.
    var defaultBaseURL: String? {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .custom: return ""
        default: return nil
        }
    }

    /// A starting point only. Model ids change on the provider's side, so the
    /// field is editable and a 404 is fixed by typing the current one.
    var defaultModel: String {
        switch self {
        case .apple: return ""
        case .openAI: return "gpt-6.1"
        case .openRouter: return "openai/gpt-6.1"
        case .google: return "gemini-4-carbon"
        case .anthropic: return "claude-sonnet-5-5"
        case .custom: return ""
        }
    }

    var keyHint: String {
        switch self {
        case .apple: return ""
        case .openAI: return "platform.openai.com → API keys"
        case .openRouter: return "openrouter.ai/keys"
        case .google: return "aistudio.google.com → API key"
        case .anthropic: return "console.anthropic.com → API keys"
        case .custom: return "Any service that speaks the OpenAI chat API"
        }
    }
}

struct TranslationTarget: Identifiable, Hashable {
    let id: String
    let name: String
}

enum TranslationSettings {
    private static let engineKey = "settings.translationEngine"
    private static let targetKey = "settings.translationTarget"

    /// A short list is enough: a listener translates into the language they
    /// read, and a wrong guess is one tap away from being fixed.
    static let targets: [TranslationTarget] = [
        TranslationTarget(id: "auto", name: "Match the phone"),
        TranslationTarget(id: "ru", name: "Russian"),
        TranslationTarget(id: "en", name: "English"),
        TranslationTarget(id: "uk", name: "Ukrainian"),
        TranslationTarget(id: "kk", name: "Kazakh"),
        TranslationTarget(id: "es", name: "Spanish"),
        TranslationTarget(id: "de", name: "German"),
        TranslationTarget(id: "fr", name: "French"),
        TranslationTarget(id: "it", name: "Italian"),
        TranslationTarget(id: "pt", name: "Portuguese"),
        TranslationTarget(id: "tr", name: "Turkish"),
        TranslationTarget(id: "ko", name: "Korean"),
        TranslationTarget(id: "ja", name: "Japanese"),
        TranslationTarget(id: "zh", name: "Chinese")
    ]

    static var engine: TranslationEngine {
        get { TranslationEngine(rawValue: UserDefaults.standard.string(forKey: engineKey) ?? "") ?? .apple }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: engineKey) }
    }

    static var targetOption: String {
        get { UserDefaults.standard.string(forKey: targetKey) ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: targetKey) }
    }

    /// BCP-47 identifier the translation runs into.
    static var targetIdentifier: String {
        targetOption == "auto" ? (Locale.preferredLanguages.first ?? "en") : targetOption
    }

    /// The same language as a name a model understands in a prompt.
    static var targetName: String {
        let identifier = targetIdentifier
        return Locale(identifier: "en").localizedString(forIdentifier: identifier) ?? identifier
    }

    static func model(for engine: TranslationEngine) -> String {
        let stored = UserDefaults.standard.string(forKey: "settings.translationModel.\(engine.rawValue)")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return engine.defaultModel }
        return stored
    }

    static func setModel(_ model: String, for engine: TranslationEngine) {
        UserDefaults.standard.set(
            model.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: "settings.translationModel.\(engine.rawValue)"
        )
    }

    static func key(for engine: TranslationEngine) -> String? {
        guard let value = UserDefaults.standard.string(forKey: "settings.translationKey.\(engine.rawValue)")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func setKey(_ key: String, for engine: TranslationEngine) {
        UserDefaults.standard.set(
            key.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: "settings.translationKey.\(engine.rawValue)"
        )
    }

    static func baseURL(for engine: TranslationEngine) -> String {
        let stored = UserDefaults.standard.string(forKey: "settings.translationBase.\(engine.rawValue)")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty { return stored }
        return engine.defaultBaseURL ?? ""
    }

    static func setBaseURL(_ value: String, for engine: TranslationEngine) {
        UserDefaults.standard.set(
            value.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: "settings.translationBase.\(engine.rawValue)"
        )
    }
}
