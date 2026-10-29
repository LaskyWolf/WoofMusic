//
//  LyricsProvider.swift
//  Trop
//
//  Created by 686udjie on 16/07/2026.
//

import Foundation

/// A normalized query used to look up lyrics across providers
struct LyricsQuery: Sendable {
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval

    var durationSeconds: Int { Int(duration) }
}

/// Common interface implemented by every lyrics source.
protocol LyricsProvider: Sendable {
    var id: String { get }
    var name: String { get }
    func fetch(query: LyricsQuery) async throws -> [LyricLine]
}

enum LyricsParsing {
    /// One or more leading [..] tags. Compiled once: parsing runs per line.
    private static let leadingTagsRegex = try? NSRegularExpression(pattern: #"^(?:\[(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?\])+"#)
    private static let tagRegex = try? NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?\]"#)
    /// Enhanced LRC word tag: `<mm:ss.xx>`.
    private static let wordTagRegex = try? NSRegularExpression(pattern: #"<(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?>"#)
    /// Netease klyric / yrc and Kugou KRC line start `[startMs,durationMs]`.
    private static let klyricLineRegex = try? NSRegularExpression(pattern: #"^\[(\d+),\d+\]"#)
    /// Netease klyric word tag `(x,durationMs)`.
    private static let klyricWordRegex = try? NSRegularExpression(pattern: #"\(\d+,(\d+)\)"#)
    /// Netease yrc word tag `(startMs,durationMs,0)` or Kugou KRC `<offsetMs,durationMs,0>`.
    private static let timedWordRegex = try? NSRegularExpression(pattern: #"[(<](\d+),(\d+),-?\d+[)>]"#)

    /// Seconds from a tag match whose groups 1–3 are minutes, seconds and an
    /// optional 2 or 3 digit fraction.
    private static func tagSeconds(_ match: NSTextCheckingResult, in ns: NSString) -> TimeInterval {
        let mins = Int(ns.substring(with: match.range(at: 1))) ?? 0
        let secs = Int(ns.substring(with: match.range(at: 2))) ?? 0
        let fracRange = match.range(at: 3)
        let frac = fracRange.location != NSNotFound ? Double("0.\(ns.substring(with: fracRange))") ?? 0 : 0
        return TimeInterval(mins * 60 + secs) + frac
    }

    /// Parses an `[mm:ss.xx]` or `[mm:ss]` timestamp at the start of a line
    static func parseLrcTimestamp(_ line: String) -> (time: TimeInterval, text: String)? {
        guard let regex = leadingTagsRegex,
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        else { return nil }

        // The last matched tag holds the time we care about
        guard let tagRegex = Self.tagRegex else { return nil }
        let tagMatches = tagRegex.matches(in: line, range: NSRange(line.startIndex..., in: line))
        guard let last = tagMatches.last else { return nil }
        let time = tagSeconds(last, in: line as NSString)

        let end = match.range.location + match.range.length
        let text = String(line[line.index(line.startIndex, offsetBy: end)...])
            .trimmingCharacters(in: .whitespaces)
        return (time, text)
    }

    /// Split a raw LRC string into lines. Blank timestamped lines are kept —
    /// they mark instrumental spans (like Metrolist's isBlank entries).
    static func parseLrc(_ raw: String) -> [LyricLine] {
        raw.split(whereSeparator: \.isNewline).map(String.init).compactMap { line -> LyricLine? in
            guard let (time, text) = parseLrcTimestamp(line) else { return nil }
            guard let (plain, words) = parseWordTags(text) else { return LyricLine(text: text, startTime: time) }
            return LyricLine(text: plain, startTime: time, words: words)
        }
    }

    /// Enhanced LRC word tags: `<00:12.00>Never <00:12.50>gonna<00:13.25>`.
    /// Each tag starts the text after it and the next tag ends it. Returns
    /// nil when the text has no tags; `words` is nil when no piece has text.
    static func parseWordTags(_ text: String) -> (text: String, words: [LyricWord]?)? {
        guard let regex = wordTagRegex else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let first = matches.first else { return nil }
        var words: [LyricWord] = []
        for (i, match) in matches.enumerated() {
            let next = i + 1 < matches.count ? matches[i + 1] : nil
            let from = match.range.location + match.range.length
            let to = next?.range.location ?? ns.length
            appendPiece(
                ns.substring(with: NSRange(location: from, length: to - from)),
                start: tagSeconds(match, in: ns),
                end: next.map { tagSeconds($0, in: ns) },
                to: &words
            )
        }
        // Text before the first tag has no time of its own: it joins the first word.
        if !words.isEmpty { words[0].text = ns.substring(to: first.range.location) + words[0].text }
        guard let timed = trimmedWords(words) else {
            let stripped = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            return (stripped.trimmingCharacters(in: .whitespaces), nil)
        }
        return (timed.map(\.text).joined(), timed)
    }

    /// Netease `klyric`: `[startMs,durationMs](0,508)Don't(0,1) (0,151)want`.
    /// The second number of each `(x,ms)` tag is the following word's
    /// duration; words follow each other from the line start, as in
    /// spicetify lyrics-plus ProviderNetease.js (`getKaraoke`).
    static func parseKlyric(_ raw: String) -> [LyricLine] {
        guard let lineRegex = klyricLineRegex, let wordRegex = klyricWordRegex else { return [] }
        return raw.split(whereSeparator: \.isNewline).compactMap { sub -> LyricLine? in
            let line = sub.trimmingCharacters(in: .whitespaces)
            let ns = line as NSString
            guard let head = lineRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let startMs = Double(ns.substring(with: head.range(at: 1))) else { return nil }
            let body = ns.substring(from: head.range.location + head.range.length) as NSString
            let tags = wordRegex.matches(in: body as String, range: NSRange(location: 0, length: body.length))
            var words: [LyricWord] = []
            var cursor = startMs / 1000
            for (i, tag) in tags.enumerated() {
                let from = tag.range.location + tag.range.length
                let to = i + 1 < tags.count ? tags[i + 1].range.location : body.length
                let duration = (Double(body.substring(with: tag.range(at: 1))) ?? 0) / 1000
                appendPiece(body.substring(with: NSRange(location: from, length: to - from)),
                            start: cursor, end: cursor + duration, to: &words)
                cursor += duration
            }
            guard let timed = trimmedWords(words) else { return nil }
            return LyricLine(text: timed.map(\.text).joined(), startTime: startMs / 1000, words: timed)
        }
    }

    /// Netease `yrc`: `[lineMs,durMs](startMs,durMs,0)word`, word starts in song
    /// time. Kugou KRC: `[lineMs,durMs]<offsetMs,durMs,0>word`, word starts
    /// from the line start (LDDC core/parser/yrc.py and krc.py).
    static func parseWordTimedLines(_ raw: String, offsetsFromLineStart: Bool) -> [LyricLine] {
        guard let lineRegex = klyricLineRegex, let wordRegex = timedWordRegex else { return [] }
        return raw.split(whereSeparator: \.isNewline).compactMap { sub -> LyricLine? in
            let line = sub.trimmingCharacters(in: .whitespaces)
            let ns = line as NSString
            guard let head = lineRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let lineMs = Double(ns.substring(with: head.range(at: 1))) else { return nil }
            let body = ns.substring(from: head.range.location + head.range.length) as NSString
            let tags = wordRegex.matches(in: body as String, range: NSRange(location: 0, length: body.length))
            let baseMs = offsetsFromLineStart ? lineMs : 0
            var words: [LyricWord] = []
            for (i, tag) in tags.enumerated() {
                let from = tag.range.location + tag.range.length
                let to = i + 1 < tags.count ? tags[i + 1].range.location : body.length
                let start = (baseMs + (Double(body.substring(with: tag.range(at: 1))) ?? 0)) / 1000
                let duration = (Double(body.substring(with: tag.range(at: 2))) ?? 0) / 1000
                appendPiece(body.substring(with: NSRange(location: from, length: to - from)),
                            start: start, end: start + duration, to: &words)
            }
            guard let timed = trimmedWords(words) else { return nil }
            return LyricLine(text: timed.map(\.text).joined(), startTime: lineMs / 1000, words: timed)
        }
    }

    /// Kugou KRC file: `krc1` + zlib data XORed with a fixed key
    /// (LyricsKit KugouKrcDecrypter.swift, LDDC core/decryptor).
    static func decodeKrc(_ data: Data) -> String? {
        let key: [UInt8] = [64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105]
        guard data.count > 10, data.starts(with: Array("krc1".utf8)) else { return nil }
        let zlibBytes = data.dropFirst(4).enumerated().map { i, byte in byte ^ key[i % key.count] }
        // NSData's `.zlib` is raw DEFLATE: drop the 2-byte zlib header and the 4-byte checksum.
        let deflate = Data(zlibBytes.dropFirst(2).dropLast(4)) as NSData
        guard let inflated = try? deflate.decompressed(using: .zlib) else { return nil }
        return String(data: inflated as Data, encoding: .utf8)
    }

    /// Musixmatch `richsync_body`: a JSON array of lines `{ts, te, l: [{c, o}]}`
    /// in seconds. Each word starts `o` seconds after its line's `ts` and ends
    /// where the next word starts; the last ends at `te` (spicetify
    /// lyrics-plus ProviderMusixmatch.js, `getKaraoke`).
    /// Words are split on spaces, so text without spaces (Japanese, Chinese)
    /// arrives as one piece per line: when most lines are a single piece the
    /// word timing is dropped and the lines stay line-synced, so a provider
    /// with real per-character timing (Kugou KRC) wins the karaoke lookup.
    static func parseRichsync(_ body: String) -> [LyricLine] {
        guard let data = body.data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        let lines = rows.compactMap { row -> LyricLine? in
            guard let ts = row["ts"] as? Double,
                  let te = row["te"] as? Double,
                  let parts = row["l"] as? [[String: Any]] else { return nil }
            var words: [LyricWord] = []
            for (i, part) in parts.enumerated() {
                guard let piece = part["c"] as? String, let offset = part["o"] as? Double else { continue }
                let nextOffset: Double? = i + 1 < parts.count ? parts[i + 1]["o"] as? Double : nil
                appendPiece(piece, start: ts + offset, end: nextOffset.map { ts + $0 } ?? te, to: &words)
            }
            guard let timed = trimmedWords(words) else { return nil }
            return LyricLine(text: timed.map(\.text).joined(), startTime: ts, words: timed)
        }
        let singlePiece = lines.filter { $0.words?.count == 1 }.count
        guard singlePiece * 2 > lines.count else { return lines }
        return lines.map { LyricLine(text: $0.text, startTime: $0.startTime) }
    }

    /// Adds a timed piece; whitespace-only (or empty) pieces join the previous word.
    private static func appendPiece(_ piece: String, start: TimeInterval, end: TimeInterval?, to words: inout [LyricWord]) {
        guard !piece.trimmingCharacters(in: .whitespaces).isEmpty else {
            if !words.isEmpty { words[words.count - 1].text += piece }
            return
        }
        words.append(LyricWord(text: piece, startTime: start, endTime: end))
    }

    /// Drops the line's outer spaces from its first and last word; nil when empty.
    private static func trimmedWords(_ words: [LyricWord]) -> [LyricWord]? {
        guard !words.isEmpty else { return nil }
        var words = words
        while words[0].text.first?.isWhitespace == true { words[0].text.removeFirst() }
        while words[words.count - 1].text.last?.isWhitespace == true { words[words.count - 1].text.removeLast() }
        return words
    }

    /// Parses stored lyrics text — LRC if timestamped, otherwise plain lines.
    static func parseStoredText(_ raw: String) -> [LyricLine] {
        let lrc = parseLrc(raw)
        if !lrc.isEmpty { return lrc }
        return raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { LyricLine(text: $0, startTime: nil) }
    }

    /// Serializes lines back to LRC/plain text for storage and editing.
    static func serializeLines(_ lines: [LyricLine]) -> String {
        let synced = lines.contains { $0.startTime != nil }
        return lines.map { line -> String in
            guard synced, let t = line.startTime else { return line.text }
            guard let words = line.words else { return "[\(stamp(t))]" + line.text }
            // Word timing is stored as Enhanced LRC; an end tag is written only
            // where a word does not end exactly when the next one starts.
            var body = ""
            for (i, word) in words.enumerated() {
                body += "<\(stamp(word.startTime))>\(word.text)"
                let nextStart = i + 1 < words.count ? stamp(words[i + 1].startTime) : nil
                if let end = word.endTime.map(stamp), end != nextStart { body += "<\(end)>" }
            }
            return "[\(stamp(t))]" + body
        }
        .joined(separator: "\n")
    }

    /// `mm:ss.xx`, rounded to the nearest centisecond.
    private static func stamp(_ t: TimeInterval) -> String {
        let centis = Int((t * 100).rounded())
        return String(format: "%02d:%02d.%02d", centis / 6000, centis / 100 % 60, centis % 100)
    }

    /// Drops the credit lines some sources put before the lyrics ("作词：Eve",
    /// "编曲：Eve/Numa", "Lyrics by: X"), plus a leading "Title - Artist" line
    /// when credits follow it. Only the opening lines are checked, so a sung
    /// line with a colon later in the song stays.
    static func droppingCredits(_ lines: [LyricLine]) -> [LyricLine] {
        var count = 0
        var sawCredit = false
        for (index, line) in lines.enumerated() {
            if isCreditLine(line.text) {
                sawCredit = true
            } else if !(index == 0 && line.text.contains(" - ")) {
                break
            }
            count = index + 1
        }
        return sawCredit ? Array(lines.dropFirst(count)) : lines
    }

    private static let creditKeywords = [
        "词", "詞", "曲", "编", "編", "制作", "製作", "混音", "母带", "录音", "錄音", "和声", "和聲",
        "监制", "監製", "出品", "发行", "發行", "吉他", "贝斯", "鼓", "弦乐", "企划", "统筹",
        "lyric", "compos", "written", "writer", "produc", "arrang", "mix", "master", "vocal"
    ]

    /// "Key: value" with a short key naming a credit role.
    private static func isCreditLine(_ text: String) -> Bool {
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let key = text[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty, key.count <= 14 else { return false }
        return key == "op" || key == "sp" || creditKeywords.contains { key.contains($0) }
    }

    /// Plain text without timestamps — what "Copy" puts on the clipboard.
    static func plainText(_ lines: [LyricLine]) -> String {
        lines.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    #if DEBUG
    static func selfCheck() {
        func near(_ a: TimeInterval?, _ b: TimeInterval) -> Bool { abs((a ?? .nan) - b) < 0.0005 }

        // Enhanced LRC: tags become words; the trailing tag ends the last word.
        let enhanced = parseLrc("[00:12.00]<00:12.00>Never <00:12.50>gonna<00:13.25>")
        assert(enhanced.count == 1 && enhanced[0].text == "Never gonna" && enhanced[0].startTime == 12)
        assert(enhanced[0].words == [
            LyricWord(text: "Never ", startTime: 12, endTime: 12.5),
            LyricWord(text: "gonna", startTime: 12.5, endTime: 13.25)
        ])
        // Word timing survives storage (edit, search selection, refetch).
        assert(parseStoredText(serializeLines(enhanced)).first?.words == enhanced[0].words)

        // Plain LRC line: no words, so karaoke stays unavailable.
        let plain = parseLrc("[01:02.50]Give you up")
        assert(plain.count == 1 && plain[0].text == "Give you up" && plain[0].startTime == 62.5 && plain[0].words == nil)

        // Netease klyric: durations add up from the line start; metadata lines are skipped.
        let klyric = parseKlyric("[ar:Someone]\n[1000,700](0,500)Don't(0,1) (0,199)want")
        assert(klyric.count == 1 && klyric[0].text == "Don't want" && klyric[0].startTime == 1)
        assert(klyric[0].words?.map(\.text) == ["Don't ", "want"])
        assert(near(klyric[0].words?[1].startTime, 1.501) && near(klyric[0].words?[1].endTime, 1.7))

        // Musixmatch richsync: offsets from `ts`, the last word ends at `te`.
        let rich = parseRichsync(#"[{"ts":5.0,"te":6.0,"l":[{"c":"Hi","o":0},{"c":" ","o":0.3},{"c":"there","o":0.4}]}]"#)
        assert(rich.count == 1 && rich[0].text == "Hi there" && rich[0].words?.count == 2)
        assert(near(rich[0].words?[0].endTime, 5.3))
        assert(near(rich[0].words?[1].startTime, 5.4) && near(rich[0].words?[1].endTime, 6))
        // Richsync of text without spaces: one piece per line is line timing, not karaoke.
        let richJa = parseRichsync(#"[{"ts":1,"te":2,"l":[{"c":"あなたは","o":0}]},{"ts":3,"te":4,"l":[{"c":"形だけ","o":0},{"c":" ","o":0.3},{"c":"今日","o":0.4}]},{"ts":5,"te":6,"l":[{"c":"言うけど","o":0}]}]"#)
        assert(richJa.map(\.text) == ["あなたは", "形だけ 今日", "言うけど"] && richJa[1].startTime == 3)
        assert(richJa.allSatisfy { $0.words == nil })

        // Netease yrc (music.163.com /api/song/lyric?yv=-1): word starts are song time.
        let yrc = parseWordTimedLines(#"{"t":0,"c":[{"tx":"Lyrics"}]}"# + "\n[27360,1290](27360,240,0)I've (27600,90,0)been (27690,360,0)tryna",
                                      offsetsFromLineStart: false)
        assert(yrc.count == 1 && yrc[0].text == "I've been tryna" && near(yrc[0].startTime, 27.36))
        assert(yrc[0].words?.map(\.text) == ["I've ", "been ", "tryna"])
        assert(near(yrc[0].words?[1].startTime, 27.6) && near(yrc[0].words?[2].endTime, 28.05))

        // Kugou KRC (lyrics.kugou.com/download?fmt=krc): decode, then offsets from the line start.
        let krcFile = Data(base64Encoded: "a3JjMTjb6lmXhgaLev/l2Ib/pOalzVdC74agdmUDAaV7475Ydne2Ru7BIPdQB71h46ZihXJVqiVLXjiKHUMdoIOnYoUKdVP85zL4oEDp") ?? Data()
        let krcText = decodeKrc(krcFile) ?? ""
        assert(krcText.hasPrefix("[ti:Anti-Hero]\n[5499,1500]<0,307,0>I "))
        let krc = parseWordTimedLines(krcText, offsetsFromLineStart: true)
        assert(krc.count == 1 && krc[0].text == "I have this" && near(krc[0].startTime, 5.499))
        assert(near(krc[0].words?[1].startTime, 5.806) && near(krc[0].words?[2].endTime, 6.999))
        assert(decodeKrc(Data("not krc".utf8)) == nil)

        // Credits before the lyrics go, with the title line; a sung line with a colon stays.
        let credited = ["AIYOU - Eve", "词：Eve", "编曲：Eve/Numa", "Lyrics by: Someone", "あなたは", "Note: still sung"]
            .map { LyricLine(text: $0, startTime: nil) }
        assert(droppingCredits(credited).map(\.text) == ["あなたは", "Note: still sung"])
        let titleOnly = ["Night - Day", "First line"].map { LyricLine(text: $0, startTime: nil) }
        assert(droppingCredits(titleOnly).count == 2)
    }
    #endif
}
