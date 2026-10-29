//
//  LyricsManager.swift
//  Trop
//
//  Created by 686udjie on 16/07/2026.
//

import Foundation

@Observable
@MainActor
final class LyricsSettings {
    static let shared = LyricsSettings()

    private let orderKey = "lyricsProviderOrder"

    /// Ordered provider ids. Defaults to a sensible fallback chain.
    var providerOrder: [String] = LyricsProviderRegistry.defaultOrder

    private init() {
        if let data = UserDefaults.standard.data(forKey: orderKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data),
           !decoded.isEmpty {
            providerOrder = decoded + LyricsProviderRegistry.defaultOrder.filter { !decoded.contains($0) }
        }
    }

    func saveProviderOrder(_ order: [String]) {
        providerOrder = order
        let data = (try? JSONEncoder().encode(order)) ?? Data()
        UserDefaults.standard.set(data, forKey: orderKey)
    }
}

/// Registry of all available providers.
enum LyricsProviderRegistry {
    static let all: [LyricsProvider] = [
        LRCLIBProvider(),
        MusixmatchProvider(),
        NeteaseProvider(),
        KugouProvider(),
        GeniusProvider()
    ]

    static let defaultOrder: [String] = [
        "musixmatch",
        "lrclib",
        "netease",
        "kugou",
        "genius"
    ]

    static func provider(for id: String) -> LyricsProvider? {
        all.first { $0.id == id }
    }
}

actor LyricsManager {
    static let shared = LyricsManager()

    private init() {}

    struct LyricSearchResult: Identifiable {
        let id = UUID()
        let lines: [LyricLine]
        let providerName: String
        let sortOrder: Int

        var previewText: String {
            lines.prefix(2).map(\.text).joined(separator: "\n")
        }

        var isSynced: Bool {
            lines.contains { $0.startTime != nil }
        }
    }

    func fetchLyrics(query: LyricsQuery) async throws -> [LyricLine] {
        let (lines, _) = try await fetchLyricsReturningProvider(query: query)
        return lines
    }

    /// Queries every enabled provider concurrently and returns all matches.
    func searchAll(query: LyricsQuery) async -> [LyricSearchResult] {
        let order = await LyricsSettings.shared.providerOrder
        let disabled = SettingsStore.shared.disabledLyricsProviders
        let providers = order
            .compactMap { LyricsProviderRegistry.provider(for: $0) }
            .filter { !disabled.contains($0.id) }
            .enumerated().map { ($1, $0) }

        return await withTaskGroup(of: (Int, LyricSearchResult)?.self) { group in
            for (provider, index) in providers {
                group.addTask {
                    guard let fetched = try? await provider.fetch(query: query) else { return nil }
                    let lines = LyricsParsing.droppingCredits(fetched)
                    guard !lines.isEmpty else { return nil }
                    return (index, LyricSearchResult(lines: lines, providerName: provider.name, sortOrder: index))
                }
            }
            var results: [(Int, LyricSearchResult)] = []
            for await item in group {
                if let item { results.append(item) }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private struct ProviderHit: Sendable {
        let order: Int
        let lines: [LyricLine]
        let providerName: String

        /// Lower wins. Line-timed lyrics beat plain text from any provider:
        /// the player's lyric line and the synced view need timestamps.
        var rank: Int { lines.contains { $0.startTime != nil } ? order : order + Self.plainTextPenalty }
        static let plainTextPenalty = 1_000
    }

    func fetchLyricsReturningProvider(query: LyricsQuery) async throws -> ([LyricLine], providerName: String?) {
        guard let best = await race(query: query, excluding: nil, wordTimedOnly: false) else {
            throw LyricsError.notFound
        }
        return (best.lines, best.providerName)
    }

    /// The highest-priority result with word timing, for karaoke when the
    /// chosen lyrics are line-only. `excluding` is the provider that gave them.
    func fetchWordTimed(query: LyricsQuery, excluding providerName: String?) async -> ([LyricLine], providerName: String)? {
        guard let best = await race(query: query, excluding: providerName, wordTimedOnly: true) else { return nil }
        return (best.lines, best.providerName)
    }

    /// Asks the enabled providers concurrently and returns the highest-priority
    /// hit; with `wordTimedOnly`, results without word timing do not count.
    private func race(query: LyricsQuery, excluding: String?, wordTimedOnly: Bool) async -> ProviderHit? {
        let order = await LyricsSettings.shared.providerOrder
        let disabled = SettingsStore.shared.disabledLyricsProviders
        let candidates: [(index: Int, provider: LyricsProvider)] = order.enumerated().compactMap { index, id in
            guard !disabled.contains(id), let provider = LyricsProviderRegistry.provider(for: id),
                  provider.name != excluding else { return nil }
            return (index, provider)
        }
        guard !candidates.isEmpty else { return nil }

        // Returns as soon as no higher-priority provider is still pending,
        // instead of waiting for every provider (each up to 10 s).
        return await withTaskGroup(of: (Int, ProviderHit?).self, returning: ProviderHit?.self) { group in
            for (index, provider) in candidates {
                group.addTask {
                    do {
                        let lines = try await LyricsParsing.droppingCredits(Self.withTimeout(seconds: 10) {
                            try await provider.fetch(query: query)
                        })
                        guard !lines.isEmpty, !wordTimedOnly || lines.contains(where: { $0.words != nil }) else {
                            return (index, nil)
                        }
                        return (index, ProviderHit(order: index, lines: lines, providerName: provider.name))
                    } catch {
                        return (index, nil)
                    }
                }
            }
            var pending = Set(candidates.map(\.index))
            var winner: ProviderHit?
            while let item = await group.next() {
                let (index, hit) = item
                pending.remove(index)
                if let hit, hit.rank < (winner?.rank ?? .max) { winner = hit }
                // A pending provider's best possible rank is its order.
                if let found = winner, !pending.contains(where: { $0 < found.rank }) {
                    group.cancelAll()
                    break
                }
            }
            return winner
        }
    }

    private static func withTimeout<T: Sendable>(seconds: Double, work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw LyricsError.notFound
            }
            guard let first = try await group.next() else {
                group.cancelAll()
                throw LyricsError.notFound
            }
            group.cancelAll()
            return first
        }
    }
}
