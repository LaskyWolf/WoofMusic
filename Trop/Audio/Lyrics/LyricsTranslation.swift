//
//  LyricsTranslation.swift
//  Trop
//
//  On-device translation for lyrics, through Apple's Translation framework:
//  no key, no network cost after the language model downloads once. The
//  result is cached per track and per target language, so reopening a song
//  shows the translation without translating it again.
//

import Foundation

enum LyricsTranslation {
    /// Translates into the phone's own language, which is what a listener
    /// wants for a foreign song.
    static var targetIdentifier: String {
        TranslationSettings.targetIdentifier
    }

    static var targetLanguage: Locale.Language {
        Locale.Language(identifier: targetIdentifier)
    }

    // MARK: - Cache

    static func cached(videoId: String, lines: [LyricLine]) -> [UUID: String]? {
        guard !videoId.isEmpty,
              let stored = UserDefaults.standard.dictionary(forKey: key(videoId)) as? [String: String],
              !stored.isEmpty else { return nil }

        var map: [UUID: String] = [:]
        for line in lines {
            if let text = stored[normalize(line.text)] { map[line.id] = text }
        }
        return map.isEmpty ? nil : map
    }

    static func save(_ map: [UUID: String], videoId: String, lines: [LyricLine]) {
        guard !videoId.isEmpty else { return }
        var stored: [String: String] = [:]
        for line in lines {
            guard let text = map[line.id] else { continue }
            stored[normalize(line.text)] = text
        }
        guard !stored.isEmpty else { return }
        UserDefaults.standard.set(stored, forKey: key(videoId))
    }

    static func clear(videoId: String) {
        UserDefaults.standard.removeObject(forKey: key(videoId))
    }

    private static func key(_ videoId: String) -> String {
        "LyricsAI.\(TranslationSettings.engine.rawValue).\(targetIdentifier).\(videoId)"
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
