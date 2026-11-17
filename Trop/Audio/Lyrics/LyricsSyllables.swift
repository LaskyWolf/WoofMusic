//
//  LyricsSyllables.swift
//  Trop
//
//  Letter-level timing for the karaoke line. A source that times whole words
//  (Enhanced LRC, and TTML for line-timed tracks) hands the renderer one long
//  slice per word; splitting it by letter — each letter carrying its share of
//  the word's duration, vowels longer than consonants — makes the highlight run
//  letter by letter, the way Apple Music lights syllables.
//

import Foundation

enum LyricsSyllables {
    /// Splits every timed word into letters with their own start and end.
    /// Words from scripts that need shaping (Arabic, Hebrew's neighbours, Indic,
    /// Thai, Khmer…) stay whole: cutting them apart would break the glyphs.
    static func letters(_ words: [LyricWord]) -> [LyricWord] {
        var out: [LyricWord] = []
        out.reserveCapacity(words.count * 4)

        for (index, word) in words.enumerated() {
            let start = word.startTime
            let end = resolvedEnd(word, next: index + 1 < words.count ? words[index + 1].startTime : nil)
            let characters = Array(word.text)
            let duration = end - start

            guard duration >= 0.12, characters.count > 1, splittable(word.text) else {
                out.append(LyricWord(text: word.text, startTime: start, endTime: end))
                continue
            }

            let weights = characters.map(weight)
            let total = weights.reduce(0, +)
            guard total > 0 else {
                out.append(LyricWord(text: word.text, startTime: start, endTime: end))
                continue
            }

            var cursor = start
            for (offset, character) in characters.enumerated() {
                let isLast = offset == characters.count - 1
                let next = isLast ? max(end, cursor) : cursor + duration * (weights[offset] / total)
                out.append(LyricWord(text: String(character), startTime: cursor, endTime: next))
                cursor = next
            }
        }
        return out
    }

    /// A last word with no end tag fills over a fixed 0.6 s, like the line view does.
    private static func resolvedEnd(_ word: LyricWord, next: TimeInterval?) -> TimeInterval {
        if let end = word.endTime, end > word.startTime { return end }
        if let next, next > word.startTime { return next }
        return word.startTime + 0.6
    }

    /// Vowels hold the note, consonants pass, spaces barely register.
    private static func weight(_ character: Character) -> Double {
        if character.isWhitespace { return 0.55 }
        if character.isPunctuation || character.isSymbol { return 0.7 }
        if vowels.contains(String(character).lowercased()) { return 1.8 }
        return 1.0
    }

    private static let vowels: Set<String> = Set("aeiouyàâäáãåéèêëíìîïóòôöõúùûüýÿæøœаеёиоуыэюяіїєў".map { String($0) })

    /// False for scripts whose letters change shape when they are separated.
    private static func splittable(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x05FF,   // Hebrew: keep words together for right-to-left runs
                 0x0600...0x0FFF,   // Arabic, Syriac, Thaana, N'Ko, Indic, Thai, Lao, Tibetan
                 0x1000...0x109F,   // Myanmar
                 0x1780...0x17FF,   // Khmer
                 0x1A20...0x1AAF,   // Tai Tham
                 0xA980...0xAA5F:   // Javanese, Cham…
                return false
            default:
                continue
            }
        }
        return true
    }
}
