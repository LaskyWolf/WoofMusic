//
//  MixesRow.swift
//  Trop
//

import SwiftUI

/// A queue built from what you play and like. It starts with these songs and
/// goes on with songs like the first one, so it does not run dry.
struct Mix: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color
    let songs: [SongItem]
}

enum MixBuilder {
    /// Fewest songs a mix needs to be worth showing.
    static let minimumSongs = 5
    private static let day: TimeInterval = 86_400

    /// Flow from your favorites, On Repeat and Rewind from your history, and a
    /// mix for each of your two most played artists. Mixes without enough songs are left out.
    static func build() async -> [Mix] {
        let db = DatabaseService.shared
        let now = Date()
        let top = (try? await db.fetchTopSongs(limit: 60)) ?? []
        let liked = (try? await db.fetchLikedSongs()) ?? []
        let monthAgo = now.addingTimeInterval(-30 * day)
        let yearAgo = now.addingTimeInterval(-365 * day)
        let recent = (try? await db.fetchTopSongs(limit: 30, from: monthAgo, to: now)) ?? []
        let earlier = (try? await db.fetchTopSongs(limit: 30, from: yearAgo, to: monthAgo)) ?? []

        var seen = Set<String>()
        let favorites = (top + liked).filter { seen.insert($0.id).inserted && isMusic($0) }

        var mixes: [Mix] = []
        func add(_ id: String, _ title: String, _ subtitle: String, _ symbol: String, _ color: Color, _ songs: [SongEntity], shuffled: Bool) {
            let usable = songs.filter(isMusic)
            guard usable.count >= minimumSongs else { return }
            mixes.append(Mix(
                id: id, title: title, subtitle: subtitle, symbol: symbol, color: color,
                songs: (shuffled ? usable.shuffled() : usable).prefix(30).toSongItems()
            ))
        }

        let indigo = Color(red: 0.36, green: 0.35, blue: 0.84)
        let red = Color(red: 0.89, green: 0.35, blue: 0.29)
        let teal = Color(red: 0.16, green: 0.55, blue: 0.55)
        add("flow", "Flow", "Your favorites, endlessly", "waveform", indigo, favorites, shuffled: true)
        add("on-repeat", "On Repeat", "Last 30 days", "repeat", red, recent, shuffled: false)
        add("rewind", "Rewind", "From earlier", "backward.end.fill", teal, earlier, shuffled: false)

        let artistColors = [Color(red: 0.85, green: 0.55, blue: 0.15), Color(red: 0.55, green: 0.32, blue: 0.7)]
        for (index, artist) in topArtists(in: top).enumerated() {
            let songs = favorites.filter { $0.artistName == artist }
            add("artist-\(artist)", "\(artist) Mix", "Songs you play", "person.wave.2.fill", artistColors[index % artistColors.count], songs, shuffled: true)
        }
        return mixes
    }

    private static func isMusic(_ song: SongEntity) -> Bool {
        !song.title.isEmpty && !song.isEpisode && !song.isUnavailable
    }

    /// The two artists with the most songs among your most played.
    private static func topArtists(in top: [SongEntity]) -> [String] {
        let counts = Dictionary(grouping: top.filter(isMusic).compactMap(\.artistName).filter { !$0.isEmpty }, by: { $0 })
            .mapValues(\.count)
        return counts.filter { $0.value >= minimumSongs }
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(2).map(\.key)
    }

    /// Plays the mix, then adds songs like its first one that are not in it yet.
    @MainActor
    static func play(_ mix: Mix) {
        PlaybackQueue.play(mix.songs, log: Log.homeScreenView, context: "Mix \(mix.title)")
        guard let seed = mix.songs.first(where: \.isAvailable) else { return }
        Task {
            guard let radio = try? await PersonalizationService.shared.fetchRadio(videoId: seed.videoId) else { return }
            let np = NowPlaying.shared
            // The queue was replaced while the radio loaded: leave it alone.
            guard np.queueSongs.contains(where: { $0.videoId == seed.videoId }) else { return }
            let known = Set(np.queueSongs.map(\.videoId))
            np.appendToQueue(radio.songs.filter { !known.contains($0.videoId) })
        }
    }
}

/// Home's row of mixes, shown under Keep Listening once there is enough to build one.
struct MixesRow: View {
    @State private var mixes: [Mix] = []

    var body: some View {
        Group {
            if !mixes.isEmpty {
                HorizontalSection(title: "Your Mixes", clipsContent: false) {
                    LazyHStack(spacing: DesignTokens.cardSpacing) {
                        ForEach(mixes) { mix in
                            Button { Haptics.impact(); MixBuilder.play(mix) } label: {
                                MoodCard(
                                    title: mix.title,
                                    color: mix.color,
                                    subtitle: mix.subtitle,
                                    trailingSymbol: "play.fill",
                                    symbol: mix.symbol,
                                    size: CGSize(width: 168, height: 104)
                                )
                            }
                            .buttonStyle(ZoomPressStyle())
                            .accessibilityLabel("\(mix.title), \(mix.subtitle)")
                            .accessibilityHint("Plays the mix")
                        }
                    }
                }
            }
        }
        .task { mixes = await MixBuilder.build() }
    }
}
