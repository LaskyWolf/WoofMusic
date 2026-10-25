//
//  LikeFlavor.swift
//  Trop
//

import Foundation

/// The emoji a liked song's heart can turn into, picked from the song's genre.
///
/// YouTube Music does not tell the genre of a song, so it is guessed from the
/// words in the title, artist and album. Each genre has three emoji; one is
/// picked at random for every like and the three are thrown around together.
/// A song with no recognized genre has no emoji: it gets a heart animation.
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
        (["🎤", "🧢", "🏆"], ["rap", "hiphop", "trap", "drill", "freestyle", "cypher", "mixtape"]),
        (["🪩", "🕺", "💃"], ["disco", "funk", "groove", "boogie"]),
        (["🎧", "🔊", "🎛️"], ["edm", "techno", "house", "trance", "dubstep", "remix", "club", "electro", "bass", "dj"]),
        (["🤠", "🐎", "🌾"], ["country", "cowboy", "nashville", "whiskey", "truck", "honky"]),
        (["🌴", "🍹", "🥁"], ["reggae", "reggaeton", "latin", "salsa", "bachata", "tropical", "caribbean"]),
        (["🎄", "🎅", "⛄️"], ["christmas", "xmas", "santa", "jingle", "navidad", "noel"]),
        (["🌙", "☕️", "📚"], ["lofi", "chill", "study", "sleep", "relax", "ambient", "calm", "lullaby", "night", "moon", "midnight"]),
        (["🏖️", "🌞", "🍦"], ["summer", "beach", "sun", "sunshine", "surf", "holiday"]),
        (["💘", "💌", "🌹"], ["love", "heart", "amor", "romance", "kiss", "valentine"]),
        (["🎃", "👻", "🦇"], ["halloween", "spooky", "ghost", "witch", "zombie"]),
        (["🚀", "👽", "🪐"], ["space", "galaxy", "astronaut", "cosmic", "star", "stars"]),
        (["🐶", "🦴", "🐾"], ["dog", "puppy", "woof"]),
        (["🔥", "💥", "☄️"], ["fire", "flame", "burn", "hot"])
    ]

    private static let japanese = ["🌸", "🍙", "⛩️"]

    static func guess(title: String, artists: [String], album: String?) -> LikeFlavor {
        let haystack = ([title] + artists + [album ?? ""]).joined(separator: " ").lowercased()
        if haystack.unicodeScalars.contains(where: isJapanese) { return LikeFlavor(emojis: japanese) }
        let words = Set(haystack.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        for rule in rules where rule.words.contains(where: { words.contains($0) }) {
            return LikeFlavor(emojis: rule.emojis)
        }
        return .unknown
    }

    private static func isJapanese(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
    }
}
