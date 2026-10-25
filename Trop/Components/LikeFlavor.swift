//
//  LikeFlavor.swift
//  Trop
//

import Foundation

/// The emoji a liked song's heart can turn into, picked from the song's genre.
///
/// YouTube Music does not tell the genre of a song. It is taken from the
/// Explore mood page the song was seen on (see `MoodGenreIndex`), or else
/// guessed from the words in the title, artist and album. Each genre has
/// three emoji; one is picked at random and the three are thrown around
/// together. A song with no recognized genre has no emoji.
struct LikeFlavor: Equatable {
    let emojis: [String]

    var isKnown: Bool { !emojis.isEmpty }

    static let unknown = LikeFlavor(emojis: [])

    /// Checked in order: the first rule with a matching word wins.
    private static let rules: [(emojis: [String], words: [String])] = [
        (["🤘", "🔥", "💀"], ["metal", "metallica", "slayer", "megadeth", "hardcore", "deathcore"]),
        (["🎸", "🤟", "⚡️"], ["rock", "guitar", "punk", "grunge", "nirvana", "acdc", "indie", "riff"]),
        (["🎷", "🎺", "🎩"], ["jazz", "blues", "sax", "saxophone", "swing", "bebop"]),
        (["🎹", "🎼", "🕯️"], ["piano", "sonata", "nocturne", "chopin", "beethoven", "etude"]),
        (["🎻", "🎼", "🎭"], ["symphony", "orchestra", "violin", "concerto", "mozart", "bach", "vivaldi", "classical"]),
        (["🎤", "🧢", "🏆"], ["rap", "hip", "hop", "hiphop", "trap", "drill", "freestyle", "cypher", "mixtape"]),
        (["🪩", "🕺", "💃"], ["disco", "funk", "groove", "boogie"]),
        (["🎧", "🔊", "🎛️"], ["edm", "dance", "electronic", "techno", "house", "trance", "dubstep", "remix", "club", "electro", "bass", "dj"]),
        (["🤠", "🐎", "🌾"], ["country", "folk", "bluegrass", "cowboy", "nashville", "whiskey", "truck", "honky"]),
        (["🌴", "🍹", "🥁"], ["reggae", "reggaeton", "latin", "salsa", "bachata", "tropical", "caribbean"]),
        (["🎄", "🎅", "⛄️"], ["christmas", "xmas", "santa", "jingle", "navidad", "noel"]),
        (["🌙", "☕️", "📚"], ["lofi", "chill", "study", "sleep", "relax", "ambient", "calm", "lullaby", "night", "moon", "midnight"]),
        (["🏖️", "🌞", "🍦"], ["summer", "beach", "sun", "sunshine", "surf", "holiday"]),
        (["💘", "💌", "🌹"], ["love", "heart", "amor", "romance", "kiss", "valentine"]),
        (["🎃", "👻", "🦇"], ["halloween", "spooky", "ghost", "witch", "zombie"]),
        (["🚀", "👽", "🪐"], ["space", "galaxy", "astronaut", "cosmic", "star", "stars"]),
        (["🐶", "🦴", "🐾"], ["dog", "puppy", "woof"]),
        (["🔥", "💥", "☄️"], ["fire", "flame", "burn", "hot"]),
        // Explore mood names.
        (["💪", "🏋️", "🔥"], ["workout", "gym", "running", "training"]),
        (["🥳", "🎉", "🪩"], ["party", "parties"]),
        (["😢", "🌧️", "💔"], ["sad", "heartbreak", "melancholy"]),
        (["🎯", "🧠", "📚"], ["focus", "concentration"]),
        (["⚡️", "🚀", "💥"], ["energy", "energizing"]),
        (["🚗", "🎧", "🛣️"], ["commute", "drive", "driving", "road"]),
        (["😊", "🌈", "☀️"], ["feel", "happy", "good"]),
        (["🎮", "👾", "🕹️"], ["gaming", "game"]),
        (["🎀", "🍭", "✨"], ["pop"]),
        (["🕶️", "🎶", "💜"], ["soul"])
    ]

    private static let japanese = ["🌸", "🍙", "⛩️"]

    /// The mood page the song came from wins; the song's own words come second.
    static func guess(videoId: String, title: String, artists: [String], album: String?) -> LikeFlavor {
        if let mood = MoodGenreIndex.mood(for: videoId), let flavor = match(mood) { return flavor }
        return match(([title] + artists + [album ?? ""]).joined(separator: " ")) ?? .unknown
    }

    private static func match(_ text: String) -> LikeFlavor? {
        let text = text.lowercased()
        if text.unicodeScalars.contains(where: isJapanese) { return LikeFlavor(emojis: japanese) }
        let words = Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return rules.first { rule in rule.words.contains { words.contains($0) } }.map { LikeFlavor(emojis: $0.emojis) }
    }

    private static func isJapanese(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
    }
}

/// Remembers which Explore mood page each song was listed on, so a liked song
/// gets the mood's genre. Kept on the device only, newest entries win.
enum MoodGenreIndex {
    private static let key = "moodGenreIndex"
    private static let maxEntries = 3000
    private static var cache: [String: String]?

    private static var entries: [String: String] {
        if let cache { return cache }
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        cache = stored
        return stored
    }

    static func mood(for videoId: String) -> String? { entries[videoId] }

    static func record(_ sections: [ExploreSection], mood: String) {
        var all = entries
        if all.count > maxEntries { all.removeAll() }
        for section in sections {
            for case .song(let song) in section.items { all[song.videoId] = mood }
        }
        cache = all
        UserDefaults.standard.set(all, forKey: key)
    }
}
