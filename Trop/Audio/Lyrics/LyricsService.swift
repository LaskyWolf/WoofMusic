//
//  LyricsService.swift
//  Trop
//
//  Created by 686udjie on 16/07/2026.
//

import Foundation

struct LyricLine: Identifiable, Equatable, Sendable {
    let id = UUID()
    let text: String
    let startTime: TimeInterval?
    /// Word-level timing for karaoke; nil when the source has only line timing.
    var words: [LyricWord]? = nil

    static let placeholder = LyricLine(text: "♪", startTime: nil)
}

/// One timed piece of a line (a word or a syllable), in song seconds.
struct LyricWord: Equatable, Sendable {
    var text: String
    let startTime: TimeInterval
    /// Nil when the source gives no end (a last Enhanced LRC word without a closing tag).
    var endTime: TimeInterval?
}

@MainActor
@Observable
final class LyricsState {
    static let shared = LyricsState()

    /// Songs with confirmed lyrics. Populated by preload/fetch.
    var availableVideoIds: Set<String> = []
    var providerName: String?
    var refreshToken: Int = 0
    /// The lyrics on screen have word-level timing, so karaoke can run.
    var hasWordTiming = false
    /// Bumped on each karaoke start or stop; the player's play button greets it.
    var karaokeGreeting = 0
    /// Karaoke after the last change: on plays the countdown, off the goodbye.
    var karaokeGreetingIsOn = false

    /// UserDefaults key of the karaoke toggle in the lyrics menu.
    nonisolated static let karaokeEnabledKey = "settings.lyricsKaraoke"

    private init() {}
}

actor LyricsService {
    static let shared = LyricsService()

    private var cache: [String: [LyricLine]] = [:]
    private var customs: [String: (lines: [LyricLine], providerName: String)] = [:]
    /// Nil result: no query could be built for the song (not cached as not found).
    private var inFlight: [String: Task<FetchResult?, Error>] = [:]
    /// Songs no provider had lyrics for, so reopening or preloading them skips
    /// the providers for a while. Entries expire because lyrics can be
    /// published later.
    private var notFoundUntil: [String: Date] = [:]
    private static let notFoundTTL: TimeInterval = 10 * 60

    private init() {}

    private static func customKey(_ videoId: String) -> String { "lyrics.custom.\(videoId)" }
    private static func customProviderKey(_ videoId: String) -> String { "lyrics.customProvider.\(videoId)" }

    private struct FetchResult: Sendable {
        let lines: [LyricLine]
        let providerName: String?
        let query: LyricsQuery
    }

    func fetchLyrics(videoId: String) async throws -> [LyricLine] {
        #if DEBUG
        LyricsParsing.selfCheck()
        #endif
        if let custom = customEntry(for: videoId) {
            await updateAvailability(videoId: videoId, available: true, providerName: custom.providerName)
            return custom.lines
        }
        if let cached = cache[videoId] {
            await updateAvailability(videoId: videoId, available: !cached.isEmpty)
            return cached
        }
        if let until = notFoundUntil[videoId], until > Date() {
            await updateAvailability(videoId: videoId, available: false)
            throw LyricsError.notFound
        }
        if let flight = inFlight[videoId] {
            guard let result = try await flight.value else { throw LyricsError.notFound }
            return result.lines
        }
        // Stored before the first await, so callers arriving meanwhile share it.
        let flight = Task<FetchResult?, Error> {
            guard let query = await resolveQuery(videoId: videoId) else { return nil }
            let (lines, providerName) = try await LyricsManager.shared.fetchLyricsReturningProvider(query: query)
            return FetchResult(lines: lines, providerName: providerName, query: query)
        }
        inFlight[videoId] = flight
        let fetched: FetchResult?
        do {
            fetched = try await flight.value
        } catch {
            inFlight.removeValue(forKey: videoId)
            // `.notFound` means the providers answered; network errors are retried.
            if case LyricsError.notFound = error {
                notFoundUntil[videoId] = Date().addingTimeInterval(Self.notFoundTTL)
            }
            if !error.isCancellation {
                await updateAvailability(videoId: videoId, available: false)
            }
            throw error
        }
        inFlight.removeValue(forKey: videoId)
        guard let result = fetched else {
            await updateAvailability(videoId: videoId, available: false)
            throw LyricsError.notFound
        }
        // Only cache successful lookups — empty results should be retried later
        // since lyrics can be matched/published after playback starts.
        if !result.lines.isEmpty {
            cache[videoId] = result.lines
            upgradeToWordTiming(videoId: videoId, query: result.query, shown: result.lines, excluding: result.providerName)
        }
        await updateAvailability(videoId: videoId, available: !result.lines.isEmpty, providerName: result.providerName)
        return result.lines
    }

    // MARK: - Manual Manipulations (edit / refetch / search selection / copy)

    /// Raw text of the active lyrics for the editor.
    func editableText(videoId: String) -> String {
        if let custom = customEntry(for: videoId) {
            return LyricsParsing.serializeLines(custom.lines)
        }
        if let cached = cache[videoId] {
            return LyricsParsing.serializeLines(cached)
        }
        return ""
    }

    /// Plain text without timestamps for the clipboard.
    func plainTextForCopy(videoId: String) -> String? {
        if let custom = customEntry(for: videoId) {
            return LyricsParsing.plainText(custom.lines)
        }
        if let cached = cache[videoId] {
            return LyricsParsing.plainText(cached)
        }
        return nil
    }

    /// Stores edited or search-selected lyrics and signals the view to reload.
    func saveCustom(videoId: String, rawText: String, providerName: String?) {
        let lines = LyricsParsing.parseStoredText(rawText)
        guard !lines.isEmpty else { return }
        // Edits keep the existing provider; fresh selections pass their own.
        let provider = providerName
            ?? customs[videoId]?.providerName
            ?? UserDefaults.standard.string(forKey: Self.customProviderKey(videoId))
            ?? "Manual"
        customs[videoId] = (lines, provider)
        UserDefaults.standard.set(rawText, forKey: Self.customKey(videoId))
        UserDefaults.standard.set(provider, forKey: Self.customProviderKey(videoId))
        cache.removeValue(forKey: videoId)
        Task {
            await MainActor.run {
                LyricsState.shared.availableVideoIds.insert(videoId)
                LyricsState.shared.providerName = provider
                LyricsState.shared.refreshToken += 1
            }
        }
    }

    /// Re-fetches from providers; replaces any manual override with the fresh
    /// result (explicit user intent), like Metrolist's refetchLyrics.
    func refetch(videoId: String) async {
        cache.removeValue(forKey: videoId)
        notFoundUntil.removeValue(forKey: videoId)
        func signalReload() {
            Task { await MainActor.run { LyricsState.shared.refreshToken += 1 } }
        }
        guard let query = await resolveQuery(videoId: videoId),
              let (foundLines, foundProvider) = try? await LyricsManager.shared.fetchLyricsReturningProvider(query: query),
              !foundLines.isEmpty else {
            await updateAvailability(videoId: videoId, available: false)
            signalReload()
            return
        }
        var fetchedLines = foundLines
        var fetchedProvider = foundProvider
        // The result is stored as the song's own copy, which later fetches
        // never replace, so word timing for karaoke is looked up now.
        if Self.wantsWordTiming(fetchedLines),
           let wordTimed = await LyricsManager.shared.fetchWordTimed(query: query, excluding: fetchedProvider) {
            fetchedLines = wordTimed.0
            fetchedProvider = wordTimed.providerName
        }
        cache[videoId] = fetchedLines
        let raw = LyricsParsing.serializeLines(fetchedLines)
        let provider = fetchedProvider ?? "Manual"
        customs[videoId] = (fetchedLines, provider)
        UserDefaults.standard.set(raw, forKey: Self.customKey(videoId))
        UserDefaults.standard.set(provider, forKey: Self.customProviderKey(videoId))
        await updateAvailability(videoId: videoId, available: true, providerName: provider)
        signalReload()
    }

    /// Karaoke was turned on: looks for word timing for the provider lyrics
    /// on screen. A song's own copy (edited or picked) is left alone.
    func requestWordTiming(videoId: String) async {
        guard customEntry(for: videoId) == nil, let shown = cache[videoId],
              let query = await resolveQuery(videoId: videoId) else { return }
        upgradeToWordTiming(videoId: videoId, query: query, shown: shown, excluding: nil)
    }

    private static func wantsWordTiming(_ lines: [LyricLine]) -> Bool {
        UserDefaults.standard.bool(forKey: LyricsState.karaokeEnabledKey) && !lines.contains { $0.words != nil }
    }

    /// When karaoke is on and the shown lyrics are line-only, asks the other
    /// providers for a word-timed copy in the background and swaps it in, so
    /// the line-synced lyrics appear without waiting for it.
    private func upgradeToWordTiming(videoId: String, query: LyricsQuery, shown: [LyricLine], excluding providerName: String?) {
        guard Self.wantsWordTiming(shown) else { return }
        let shownId = shown.first?.id
        Task {
            guard let wordTimed = await LyricsManager.shared.fetchWordTimed(query: query, excluding: providerName),
                  // Other lyrics may have been picked or refetched meanwhile.
                  customs[videoId] == nil, cache[videoId]?.first?.id == shownId else { return }
            cache[videoId] = wordTimed.0
            await updateAvailability(videoId: videoId, available: true, providerName: wordTimed.providerName)
            await MainActor.run {
                if NowPlaying.shared.videoId == videoId { LyricsState.shared.refreshToken += 1 }
            }
        }
    }

    private func customEntry(for videoId: String) -> (lines: [LyricLine], providerName: String)? {
        if let entry = customs[videoId] { return entry }
        guard let raw = UserDefaults.standard.string(forKey: Self.customKey(videoId)) else { return nil }
        let lines = LyricsParsing.parseStoredText(raw)
        guard !lines.isEmpty else { return nil }
        let provider = UserDefaults.standard.string(forKey: Self.customProviderKey(videoId)) ?? "Manual"
        let entry = (lines, provider)
        customs[videoId] = entry
        return entry
    }

    func preload(videoId: String, upcoming: [String] = []) async {
        _ = try? await fetchLyrics(videoId: videoId)
        for id in upcoming where cache[id] == nil && customEntry(for: id) == nil {
            _ = try? await fetchLyrics(videoId: id)
        }
    }

    private func updateAvailability(videoId: String, available: Bool, providerName: String? = nil) async {
        await MainActor.run {
            if available {
                LyricsState.shared.availableVideoIds.insert(videoId)
                if NowPlaying.shared.videoId == videoId { LyricsState.shared.providerName = providerName }
            } else {
                LyricsState.shared.availableVideoIds.remove(videoId)
            }
        }
    }

    private func resolveQuery(videoId: String) async -> LyricsQuery? {
        let info = await MainActor.run {
            let np = NowPlaying.shared
            return (
                title: np.title,
                artist: np.displayArtist,
                album: np.albumTitle.isEmpty ? nil : np.albumTitle,
                duration: np.duration,
                currentId: np.videoId,
                queue: np.queueSongs
            )
        }

        let (npTitle, npArtist, npAlbum, npDuration, currentId, queue) = info

        let title: String
        let artist: String
        let album: String?
        let duration: TimeInterval

        if currentId == videoId, !npTitle.isEmpty, !npArtist.isEmpty {
            title = npTitle
            artist = npArtist
            album = npAlbum
            duration = npDuration
        } else if let song = queue.first(where: { $0.videoId == videoId }) {
            title = song.title
            artist = song.artists.map(\.name).joined(separator: ", ")
            album = song.album?.isEmpty == false ? song.album : nil
            let dur = song.duration > 0 ? song.duration : (DurationCache.get(videoId) ?? 0)
            duration = TimeInterval(dur)
        } else {
            return nil
        }

        guard !title.isEmpty, !artist.isEmpty else { return nil }
        let cleaned = cleanQuery(title: title, artist: artist, album: album)
        return LyricsQuery(
            title: cleaned.title,
            artist: cleaned.artist,
            album: cleaned.album,
            duration: duration > 0 ? duration : 0
        )
    }

    private struct CleanedQuery {
        let title: String
        let artist: String
        let album: String?
    }

    private func cleanQuery(title: String, artist: String, album: String?) -> CleanedQuery {
        let (extractedTitle, extractedArtist) = Self.extractArtistTitle(from: title, channelArtist: artist)
        let cleanedTitle = Self.cleanTitle(extractedTitle)
        let cleanedArtist = Self.cleanArtist(extractedArtist ?? artist)
        let cleanedAlbum = album.map { Self.cleanAlbum($0) }
        return CleanedQuery(title: cleanedTitle, artist: cleanedArtist, album: cleanedAlbum)
    }

    private static func extractArtistTitle(from rawTitle: String, channelArtist: String) -> (title: String, artist: String?) {
        guard isChannelLike(channelArtist) else { return (rawTitle, nil) }
        let separators = [" - ", " – ", " — "]
        for sep in separators {
            if let range = rawTitle.range(of: sep) {
                let left = String(rawTitle[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let right = String(rawTitle[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !left.isEmpty, !right.isEmpty else { break }
                // left = real artist, right = real title
                return (right, left)
            }
        }
        return (rawTitle, nil)
    }

    private static func isChannelLike(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard !lower.isEmpty else { return false }
        let channelWords = ["music", "channel", "official", "records", "record",
                           "tv", "studio", "entertainment", "4k", "中文", "古风",
                           "chinese", "ort", "ehp", "vip", "lyrics", "mv",
                           "topic", "vevo", "remix", "dj", "radio"]
        return channelWords.contains(where: { lower.contains($0) })
    }

    private static func cleanTitle(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: #"【[^】]*】"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"「[^」]*」"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"『[^』]*』"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        for marker in ["|", "♪", "mv", "lyrics", "歌词", "動態", "动态", "official", "官方"] {
            if let r = s.range(of: marker, options: .caseInsensitive) {
                s = String(s[..<r.lowerBound])
                break
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanArtist(_ raw: String) -> String {
        let parts = raw
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { part -> String in
                var p = part
                if let range = p.range(of: " - ") {
                    p = String(p[..<range.lowerBound])
                }
                p = p.replacingOccurrences(of: " - Topic", with: "")
                p = p.replacingOccurrences(of: "-Topic", with: "")
                p = p.replacingOccurrences(of: "Topic", with: "")
                return p.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        return parts.joined(separator: ", ")
    }

    private static func cleanAlbum(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
