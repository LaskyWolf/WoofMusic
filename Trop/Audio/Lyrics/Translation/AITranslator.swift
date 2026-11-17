//
//  AITranslator.swift
//  Trop
//
//  Network translation for lyrics. One prompt shape for every engine: a JSON
//  array of lines in, a JSON object with the same number of lines out. Apple's
//  on-device engine is not handled here — the view drives it through
//  TranslationSession — so this is the "the rest" of the picker.
//

import Foundation

enum AITranslationError: Error, LocalizedError {
    case missingKey
    case badResponse(Int, String)
    case unparsable

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No API key for the chosen translator."
        case .badResponse(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmed.count > 180 ? String(trimmed.prefix(180)) + "…" : trimmed
            return "HTTP \(code): \(detail)"
        case .unparsable:
            return "The translator's answer could not be read."
        }
    }
}

enum AITranslator {
    /// Lines per request: enough for the model to keep the song's context,
    /// small enough that the answer never gets truncated or merged.
    private static let batchSize = 40

    /// Returns one translation per input line, in the same order. Empty input
    /// lines stay empty, so the caller can map by index without bookkeeping.
    static func translate(lines: [String], to language: String) async throws -> [String] {
        let engine = TranslationSettings.engine
        guard engine != .apple else { return lines }

        var result = [String](repeating: "", count: lines.count)
        let wanted = lines.enumerated().filter {
            !$0.element.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !wanted.isEmpty else { return result }

        var cursor = 0
        while cursor < wanted.count {
            let slice = Array(wanted[cursor..<min(cursor + batchSize, wanted.count)])
            let texts = slice.map { $0.element }
            let translated = try await request(engine: engine, texts: texts, language: language)
            for (offset, item) in slice.enumerated() where translated.indices.contains(offset) {
                result[item.offset] = translated[offset]
            }
            cursor += batchSize
        }
        return result
    }

    // MARK: - Engines

    private static func request(
        engine: TranslationEngine,
        texts: [String],
        language: String
    ) async throws -> [String] {
        switch engine {
        case .openAI, .openRouter, .custom:
            return try await chat(engine: engine, texts: texts, language: language)
        case .google:
            return try await google(texts: texts, language: language)
        case .anthropic:
            return try await anthropic(texts: texts, language: language)
        case .apple:
            return texts
        }
    }

    private static func chat(
        engine: TranslationEngine,
        texts: [String],
        language: String
    ) async throws -> [String] {
        guard let key = TranslationSettings.key(for: engine) else { throw AITranslationError.missingKey }
        let root = TranslationSettings.baseURL(for: engine)
        guard !root.isEmpty else { throw AITranslationError.missingKey }
        let path = root.hasSuffix("/") ? root + "chat/completions" : root + "/chat/completions"
        guard let url = URL(string: path) else { throw AITranslationError.unparsable }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if engine == .openRouter {
            request.setValue("Music+ for iOS", forHTTPHeaderField: "X-Title")
            request.setValue("https://github.com/dmitrylol/WoofMusicPlus", forHTTPHeaderField: "HTTP-Referer")
        }

        let body: [String: Any] = [
            "model": TranslationSettings.model(for: engine),
            "temperature": 0,
            "messages": [
                ["role": "system", "content": instructions(language: language)],
                ["role": "user", "content": payload(texts)]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AITranslationError.unparsable
        }
        return try parse(content, expected: texts.count)
    }

    private static func google(texts: [String], language: String) async throws -> [String] {
        guard let key = TranslationSettings.key(for: .google) else { throw AITranslationError.missingKey }
        let model = TranslationSettings.model(for: .google)
        let path = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(key)"
        guard let url = URL(string: path) else { throw AITranslationError.unparsable }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": instructions(language: language)]]],
            "contents": [
                ["role": "user", "parts": [["text": payload(texts)]]]
            ],
            "generationConfig": [
                "temperature": 0,
                "responseMimeType": "application/json"
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw AITranslationError.unparsable
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        return try parse(text, expected: texts.count)
    }

    private static func anthropic(texts: [String], language: String) async throws -> [String] {
        guard let key = TranslationSettings.key(for: .anthropic) else { throw AITranslationError.missingKey }
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw AITranslationError.unparsable
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": TranslationSettings.model(for: .anthropic),
            "max_tokens": 8192,
            "temperature": 0,
            "system": instructions(language: language),
            "messages": [
                ["role": "user", "content": payload(texts)]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = json["content"] as? [[String: Any]] else {
            throw AITranslationError.unparsable
        }
        let text = blocks.compactMap { $0["text"] as? String }.joined()
        return try parse(text, expected: texts.count)
    }

    // MARK: - Plumbing

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AITranslationError.unparsable }
        guard (200..<300).contains(http.statusCode) else {
            throw AITranslationError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private static func instructions(language: String) -> String {
        """
        You translate song lyrics. The user sends a JSON array of lyric lines. \
        Translate every line into \(language). Keep the order and the number of \
        items exactly, keep slang, names and the song's tone, never merge or \
        split lines, never explain anything. Answer with one JSON object and \
        nothing else, in this shape: {"lines": ["first line", "second line"]}
        """
    }

    private static func payload(_ texts: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: texts) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Reads the JSON object back, and falls back to one translation per row
    /// for a model that ignored the shape but kept the count.
    private static func parse(_ raw: String, expected: Int) throws -> [String] {
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}"),
           start < end,
           let data = String(cleaned[start...end]).data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let array = json["lines"] as? [String],
           array.count == expected {
            return array
        }

        let rows = cleaned
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if rows.count == expected { return rows }

        throw AITranslationError.unparsable
    }
}
