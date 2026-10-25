//
//  LikeFlavor.swift
//  Trop
//

import Foundation

/// What the heart turns into for a moment when a song is liked.
///
/// YouTube Music does not tell the genre of a song, so it is guessed from the
/// words in the title, artist and album. Anything unrecognized gets a random
/// but stable happy emoji, so every like still has a punchline.
struct LikeFlavor: Equatable {
    let emoji: String

    static let heart = LikeFlavor(emoji: "💖")

    /// Checked in order: the first rule with a matching word wins.
    private static let rules: [(emoji: String, words: [String])] = [
        ("🤘", ["metal", "metallica", "slayer", "megadeth", "hardcore", "deathcore"]),
        ("🎸", ["rock", "guitar", "punk", "grunge", "nirvana", "acdc", "indie", "riff"]),
        ("🎷", ["jazz", "blues", "sax", "saxophone", "swing", "bebop"]),
        ("🎹", ["piano", "sonata", "nocturne", "chopin", "beethoven", "etude"]),
        ("🎻", ["symphony", "orchestra", "violin", "concerto", "mozart", "bach", "vivaldi", "classical"]),
        ("🎤", ["rap", "hiphop", "trap", "drill", "freestyle", "cypher", "mixtape"]),
        ("🪩", ["disco", "funk", "groove", "boogie"]),
        ("🎧", ["edm", "techno", "house", "trance", "dubstep", "remix", "club", "electro", "bass", "dj"]),
        ("🤠", ["country", "cowboy", "nashville", "whiskey", "truck", "honky"]),
        ("🌴", ["reggae", "reggaeton", "latin", "salsa", "bachata", "tropical", "caribbean"]),
        ("🎄", ["christmas", "xmas", "santa", "jingle", "navidad", "noel"]),
        ("🌙", ["lofi", "chill", "study", "sleep", "relax", "ambient", "calm", "lullaby", "night", "moon", "midnight"]),
        ("🏖️", ["summer", "beach", "sun", "sunshine", "surf", "holiday"]),
        ("💘", ["love", "heart", "amor", "romance", "kiss", "valentine"]),
        ("🎃", ["halloween", "spooky", "ghost", "witch", "zombie"]),
        ("🚀", ["space", "galaxy", "astronaut", "cosmic", "star", "stars"]),
        ("🐶", ["dog", "puppy", "woof"]),
        ("🔥", ["fire", "flame", "burn", "hot"])
    ]

    private static let fallbacks = ["🎶", "😎", "🕺", "🥳", "🎧", "✨", "🦄", "🍕"]

    static func guess(title: String, artists: [String], album: String?, videoId: String) -> LikeFlavor {
        let haystack = ([title] + artists + [album ?? ""]).joined(separator: " ").lowercased()
        let words = Set(haystack.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))

        if haystack.unicodeScalars.contains(where: isJapanese) { return LikeFlavor(emoji: "🌸") }
        for rule in rules where rule.words.contains(where: { words.contains($0) }) {
            return LikeFlavor(emoji: rule.emoji)
        }
        let seed = videoId.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 9973 }
        return LikeFlavor(emoji: fallbacks[seed % fallbacks.count])
    }

    private static func isJapanese(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
    }
}
