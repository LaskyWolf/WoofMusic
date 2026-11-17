//
//  LyricsTTML.swift
//  Trop
//
//  Apple-style TTML — the format Better Lyrics, lrc.red and Unison answer with.
//  Every <p> is a line, every <span> inside it a syllable, a span marked
//  ttm:role="x-bg" holds backing vocals, and a second <p> per line carries the
//  translation (same itunes:key, or the same begin time).
//

import Foundation

enum LyricsTTML {
    /// Parses a TTML document into timed lines. Never throws: a broken document
    /// gives back whatever was read before the error.
    static func parse(_ xml: String) -> [LyricLine] {
        guard let data = xml.data(using: .utf8), !data.isEmpty else { return [] }
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldProcessNamespaces = true
        _ = parser.parse()
        return reader.result()
    }

    /// "12.5", "12.5s", "0:12.500" and "1:02:03.400" → seconds.
    static func seconds(_ raw: String?) -> TimeInterval? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasSuffix("s") { text.removeLast() }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var value: TimeInterval = 0
        for part in parts {
            guard let number = Double(part.replacingOccurrences(of: ",", with: ".")), number.isFinite else { return nil }
            value = value * 60 + number
        }
        return value >= 0 ? value : nil
    }
}

// MARK: - Reading

private final class Reader: NSObject, XMLParserDelegate {
    /// A <p> being read, or a finished one.
    private struct Line {
        var key: String?
        var begin: TimeInterval?
        var end: TimeInterval?
        var isTranslation = false
        var words: [LyricWord] = []
        /// Text that sits outside any timed span: the spaces between syllables.
        var loose = ""

        var text: String {
            words.isEmpty
                ? loose.trimmingCharacters(in: .whitespacesAndNewlines)
                : words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var finished: [Line] = []
    private var line: Line?
    /// One entry per open <span>: the word index it writes into, when it is timed.
    private var spans: [Int?] = []
    private var translationDepth = 0

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "p":
            flush()
            var opened = Line()
            opened.begin = LyricsTTML.seconds(attributeDict["begin"])
            opened.end = LyricsTTML.seconds(attributeDict["end"])
            opened.key = attributeDict["key"] ?? attributeDict["id"]
            let role = attributeDict["role"] ?? ""
            opened.isTranslation = translationDepth > 0 || role.contains("translation")
            line = opened
            spans = []
        case "div":
            if (attributeDict["role"] ?? "").contains("translation") { translationDepth += 1 }
        case "span":
            guard var current = line else { return }
            if let begin = LyricsTTML.seconds(attributeDict["begin"]) {
                current.words.append(LyricWord(text: "", startTime: begin,
                                               endTime: LyricsTTML.seconds(attributeDict["end"])))
                line = current
                spans.append(current.words.count - 1)
            } else {
                // An untimed wrapper (backing vocals hang their timed spans under it).
                spans.append(nil)
            }
        case "br":
            append(" ")
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch elementName {
        case "p":
            flush()
        case "div":
            if translationDepth > 0 { translationDepth -= 1 }
        case "span":
            if !spans.isEmpty { spans.removeLast() }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        append(String(decoding: CDATABlock, as: UTF8.self))
    }

    // MARK: Pieces

    private func append(_ text: String) {
        guard !text.isEmpty, var current = line else { return }
        if let index = spans.last ?? nil, current.words.indices.contains(index) {
            current.words[index].text += text
        } else if !current.words.isEmpty {
            // A space between two syllables belongs to the syllable before it,
            // so the line keeps its spacing without extra runs.
            current.words[current.words.count - 1].text += text
        } else {
            current.loose += text
        }
        line = current
    }

    private func flush() {
        guard var current = line else { return }
        line = nil
        spans = []
        current.words.removeAll { $0.text.isEmpty }
        if !current.words.isEmpty {
            current.words[0].text = String(current.words[0].text.drop(while: \.isWhitespace))
            let last = current.words.count - 1
            while let character = current.words[last].text.last, character.isWhitespace {
                current.words[last].text.removeLast()
            }
        }
        guard !current.text.isEmpty else { return }
        finished.append(current)
    }

    // MARK: Result

    func result() -> [LyricLine] {
        flush()
        let originals = finished.filter { !$0.isTranslation }
        let translations = finished.filter { $0.isTranslation }

        var byKey: [String: String] = [:]
        var byBegin: [TimeInterval: String] = [:]
        for translation in translations where !translation.text.isEmpty {
            if let key = translation.key { byKey[key] = translation.text }
            if let begin = translation.begin { byBegin[begin] = translation.text }
        }
        // Some documents list translations in line order without keys or times.
        let positional = translations.count == originals.count ? translations : []

        return originals.enumerated().compactMap { offset, original -> LyricLine? in
            let text = original.text
            guard !text.isEmpty else { return nil }
            var translation = original.key.flatMap { byKey[$0] } ?? original.begin.flatMap { byBegin[$0] }
            if translation == nil, positional.indices.contains(offset) {
                let candidate = positional[offset].text
                translation = candidate.isEmpty ? nil : candidate
            }
            return LyricLine(
                text: text,
                startTime: original.begin,
                words: original.words.isEmpty ? nil : original.words,
                translation: translation == text ? nil : translation
            )
        }
    }
}
