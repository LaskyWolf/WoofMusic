//
//  MoodCard.swift
//  Trop
//
//  The colored tile of a sub-genre in Explore, and the families that group
//  genres (Pop, Hip-Hop...) so a family's genres share a color.
//

import SwiftUI

/// Genres that share a family (Hip-Hop, Brazilian Hip-Hop...) share a color.
/// A family with two or more genres becomes one chip in Explore; its genres
/// show as cards under the chips.
enum MoodFamily {
    struct Entry: Identifiable {
        enum Kind {
            case group(family: String, members: [MoodItem])
            case mood(MoodItem)
        }
        let id: String
        let kind: Kind

        var title: String {
            switch kind {
            case .group(let family, _): family
            case .mood(let mood): mood.title
            }
        }
    }

    private static let families: [(name: String, words: [String])] = [
        ("Hip-Hop", ["hip-hop", "hip hop", "rap", "trap"]),
        ("Metal", ["metal"]),
        ("Rock", ["rock", "punk", "grunge"]),
        ("R&B & Soul", ["r&b", "soul"]),
        ("Dance & Electronic", ["dance", "electronic", "edm", "house", "techno"]),
        ("Latin", ["latin", "reggaeton", "salsa", "bachata"]),
        ("Reggae", ["reggae", "dancehall"]),
        ("Jazz & Blues", ["jazz", "blues"]),
        ("Classical", ["classical"]),
        ("Country & Folk", ["country", "folk", "bluegrass"]),
        ("Pop", ["pop"])
    ]

    static var names: [String] { families.map(\.name) }

    static func family(of title: String) -> String? {
        let title = title.lowercased()
        return families.first { $0.words.contains { title.contains($0) } }?.name
    }

    /// The genre that is the family itself ("Pop" in Pop), when YouTube lists one.
    static func base(of family: String, in members: [MoodItem]) -> MoodItem? {
        members.first { $0.title.lowercased() == family.lowercased() }
    }

    /// The family's genres other than the family itself.
    static func subgenres(of family: String, in moods: [MoodItem]) -> [MoodItem] {
        let members = moods.filter { Self.family(of: $0.title) == family }
        let base = base(of: family, in: members)
        return members.filter { $0.id != base?.id }
    }

    /// An icon per sub-genre from its title. Two genres never share one: the
    /// second falls back to the next free icon.
    static func uniqueIcons(for members: [MoodItem]) -> [UUID: String] {
        let spare = ["music.note", "music.note.list", "headphones", "speaker.wave.2.fill", "star.fill", "heart.fill", "bolt.fill", "sparkles", "globe", "flame.fill"]
        var used = Set<String>()
        var icons: [UUID: String] = [:]
        for mood in members {
            var icon = MoodCard.symbol(for: mood.title)
            if used.contains(icon) { icon = spare.first { !used.contains($0) } ?? icon }
            used.insert(icon)
            icons[mood.id] = icon
        }
        return icons
    }

    /// Families with two or more genres become one chip. Everything else keeps its place.
    static func entries(for moods: [MoodItem]) -> [Entry] {
        var members: [String: [MoodItem]] = [:]
        for mood in moods { if let f = family(of: mood.title) { members[f, default: []].append(mood) } }
        var seen = Set<String>()
        var result: [Entry] = []
        for mood in moods {
            guard let f = family(of: mood.title), let group = members[f], group.count > 1 else {
                result.append(Entry(id: "mood-\(mood.id)", kind: .mood(mood)))
                continue
            }
            if seen.insert(f).inserted {
                result.append(Entry(id: "group-\(f)", kind: .group(family: f, members: group)))
            }
        }
        return result
    }
}

/// A colored mood tile, like Apple Music's category cards. The color is a
/// Pantone color, picked from the family (or the title) so a category keeps its
/// color between launches. YouTube Music's own colors are muddy, so unused.
struct MoodCard: View {
    let title: String
    let color: Color
    var subtitle: String?
    var trailingSymbol: String?
    /// An SF Symbol; the title's own symbol when nil.
    var symbol: String?
    var size = Self.defaultSize
    static let defaultSize = CGSize(width: 150, height: 88)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [color, color.mix(with: .black, by: 0.3)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Light from above, so the card reads as a raised surface.
            LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .center)

            // Larger than the card and tilted left, so the card edge crops it.
            Image(systemName: symbol ?? Self.symbol(for: title))
                .font(.system(size: 84, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
                .rotationEffect(.degrees(-18))
                .offset(x: 24, y: 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.leading)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2.weight(.semibold))
                        .opacity(0.85)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            // Keeps the text inside the card and off the cropped icon.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
            .padding(.trailing, 36)
            .padding(.bottom, 12)

            if let trailingSymbol {
                Image(systemName: trailingSymbol)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .shadow(color: color.opacity(0.4), radius: 6, y: 4)
        // One bitmap per card, glow included: scrolling moves it instead of
        // recompositing the gradients, symbol, clip and two shadows each frame.
        // The padding keeps the glow inside the bitmap; the negative padding
        // and the content shape keep the card's size and tap area.
        .padding(Self.glowInset)
        .drawingGroup()
        .padding(-Self.glowInset)
        .contentShape(shape)
    }

    /// Room around the card for the glow (radius 6, 4 pt down).
    private static let glowInset: CGFloat = 16

    /// An SF Symbol for the category, matched on words in its title. The
    /// more specific words come first ("K-Pop" before "Pop").
    static func symbol(for title: String) -> String {
        let title = title.lowercased()
        return symbols.first { entry in entry.words.contains { title.contains($0) } }?.symbol ?? "music.note"
    }

    /// Built once: a local array would be rebuilt for every card render and
    /// for every genre of a family's menu.
    private static let symbols: [(words: [String], symbol: String)] = [
        // Styles and places inside a family come first, so sub-genres differ.
        (["brazil", "brasil", "samba", "bossa", "sertanejo", "funk"], "sun.max.fill"),
        (["latin", "reggaeton", "salsa", "bachata", "tango"], "figure.dance"),
        (["korean"], "sparkles"),
        (["japanese", "j-rock", "anime"], "moon.stars.fill"),
        (["old school", "oldies", "classic", "retro", "90s", "80s", "70s", "60s"], "clock.arrow.circlepath"),
        (["trap", "drill", "grime"], "bolt.fill"),
        (["gangsta", "hardcore", "punk", "grunge"], "flame.fill"),
        (["underground", "lo-fi", "lofi", "bedroom"], "headphones"),
        (["conscious", "boom bap", "spoken"], "text.book.closed.fill"),
        (["house", "techno", "trance", "club"], "waveform"),
        (["singer", "songwriter", "unplugged"], "guitars"),
        (["opera", "orchestra", "baroque", "symphon"], "pianokeys"),
        (["swing", "bebop", "smooth"], "music.quarternote.3"),
        (["dancehall", "ska", "dub"], "beach.umbrella.fill"),
        (["western", "bluegrass", "honky"], "sun.horizon.fill"),
        (["african", "afro"], "globe.africa.fill"),
        (["arab", "middle east"], "globe.europe.africa.fill"),
        (["indian", "bollywood"], "globe.asia.australia.fill"),
        (["k-pop", "j-pop", "mandopop", "cantopop"], "sparkles"),
        (["hip-hop", "hip hop", "rap"], "music.mic"),
        (["r&b", "soul"], "music.mic.circle.fill"),
        (["dance", "electronic", "edm"], "waveform"),
        (["metal"], "flame.fill"),
        (["rock"], "guitars.fill"),
        (["folk", "acoustic"], "guitars"),
        (["classical", "piano"], "pianokeys"),
        (["jazz", "blues"], "music.quarternote.3"),
        (["country"], "sun.horizon.fill"),
        (["latin"], "figure.dance"),
        (["reggae", "caribbean"], "beach.umbrella.fill"),
        (["indie", "alternative"], "headphones"),
        (["soundtrack", "musical", "film"], "film.fill"),
        (["christian", "gospel"], "hands.sparkles.fill"),
        (["family", "kids", "children"], "figure.2.and.child.holdinghands"),
        (["holiday", "christmas"], "gift.fill"),
        (["decade", "0s", "throwback"], "clock.arrow.circlepath"),
        (["chill", "relax"], "leaf.fill"),
        (["commut", "travel", "drive"], "car.fill"),
        (["energy", "boost"], "bolt.fill"),
        (["feel good", "happy"], "sun.max.fill"),
        (["focus", "study"], "scope"),
        (["gaming"], "gamecontroller.fill"),
        (["party"], "party.popper.fill"),
        (["romance", "love"], "heart.fill"),
        (["sad"], "cloud.rain.fill"),
        (["sleep"], "moon.zzz.fill"),
        (["workout", "fitness", "running"], "figure.run"),
        (["african", "arabic", "indian", "bollywood", "korean", "japanese", "world"], "globe"),
        (["pop"], "star.fill")
    ]

    /// Pantone colors (name, code, sRGB value as published by Pantone).
    private static let pantone: [(name: String, code: String, rgb: Int)] = [
        ("Classic Blue", "19-4052", 0x0F4C81),
        ("Living Coral", "16-1546", 0xFF6F61),
        ("Ultra Violet", "18-3838", 0x5F4B8B),
        ("Radiant Orchid", "18-3224", 0xB163A3),
        ("Marsala", "18-1438", 0x955251),
        ("Emerald", "17-5641", 0x009473),
        ("Tangerine Tango", "17-1463", 0xDD4124),
        ("Honeysuckle", "18-2120", 0xD94F70),
        ("Blue Iris", "18-3943", 0x5A5B9F),
        ("Viva Magenta", "18-1750", 0xBE3455),
        ("Very Peri", "17-3938", 0x6667AB),
        ("Greenery", "15-0343", 0x88B04B),
        ("Turquoise", "15-5519", 0x45B5AA)
    ]

    /// A family's genres share its color. The sum of the letters is stable
    /// between launches; `hashValue` is not.
    static func swatch(family: String?, title: String) -> Color {
        let key = family ?? MoodFamily.family(of: title)
        // Each family gets its own color; other genres are spread by their title.
        let index = key.flatMap { MoodFamily.names.firstIndex(of: $0) }
            ?? title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) &* 31 }
        let rgb = pantone[(index % pantone.count + pantone.count) % pantone.count].rgb
        return Color(hex: UInt32(rgb))
    }
}
