//
// ExploreView.swift
// Trop
//
// Created by 686udjie on 11/09/2026.
//

import SwiftUI

struct ExploreView: View {
    @State private var viewModel = ExploreViewModel()
    @ObservedObject private var router = AppRouter.shared

    @State private var pendingRoute: DetailRoute?

    private let accountState = AccountState.shared

    var body: some View {
        NavigationStack(path: $router.explorePath) {
            VStack(spacing: 0) {
                TabHeaderView(
                    title: "Explore",
                    accountIsLoggedIn: accountState.isLoggedIn,
                    accountImageUrl: accountState.accountImageUrl,
                    onHistory: { router.explorePath.append(DetailRoute.history) },
                    onAccount: { router.explorePath.append(DetailRoute.settings) }
                )

                content
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .toolbar(.hidden, for: .navigationBar)
            .detailRouteDestinations()
            .navigationDestination(for: MoodItem.self) { mood in
                MoodDetailView(mood: mood)
            }
            .onChange(of: pendingRoute) { _, route in
                if let route {
                    router.explorePath.append(route)
                    pendingRoute = nil
                }
            }
            .onAppear { viewModel.load() }
            .task(id: viewModel.sections.count) {
                let urls = viewModel.sections
                    .flatMap(\.items)
                    .compactMap(\.thumbnailUrl)
                    .compactMap(URL.init)
                await ImagePreloader.shared.preload(urls)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle, .loading:
            ExploreSkeletonView()
        case .loaded:
            sectionsList
        case .empty:
            ContentUnavailableView(
                "Nothing to explore",
                systemImage: "flame",
                description: Text("Try again later.")
            )
        case .failed:
            ContentUnavailableView(
                "Explore failed",
                systemImage: "exclamationmark.triangle",
                description: Text("Couldn't load Explore. Pull to retry.")
            )
        }
    }

    private var sectionsList: some View {
        ScrollView {
            ExploreSectionsList(sections: viewModel.sections, pendingRoute: $pendingRoute)
                .padding(.bottom, 16)
        }
        .scrollIndicators(.automatic)
        .miniPlayerTracksScroll()
        .refreshable { await viewModel.refresh() }
    }
}

// MARK: - Shared section list

/// Renders Explore sections (song grids, card carousels, mood grids).
/// Shared by the Explore tab and mood category pages.
struct ExploreSectionsList: View {
    @ObservedObject private var router = AppRouter.shared
    var sections: [ExploreSection]
    var pendingRoute: Binding<DetailRoute?>

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(sections) { section in
                switch section.kind {
                case .rows:
                    songGrid(section)
                case .cards:
                    cardsCarousel(section)
                case .moods:
                    moodsGrid(section)
                }
            }
        }
        .onAppear {
            Log.explore.debug(
                "Render sections: " +
                sections.map { "\($0.title)(\($0.kind)):\($0.items.count)" }.joined(separator: ", ")
            )
        }
    }

    // MARK: - Rows

    /// Song rows in a 4-row grid scrolling horizontally.
    private func songGrid(_ section: ExploreSection) -> some View {
        HorizontalSection(title: section.title) {
            LazyHGrid(
                rows: [
                    GridItem(.flexible(), spacing: 0),
                    GridItem(.flexible(), spacing: 0),
                    GridItem(.flexible(), spacing: 0),
                    GridItem(.flexible(), spacing: 0)
                ],
                spacing: 12
            ) {
                ForEach(section.items, id: \.id) { item in
                    YouTubeListItemView(item: item, onTap: {
                        openItem(item)
                    }, onNavigate: { pendingRoute.wrappedValue = $0 })
                    .frame(width: 320, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Cards carousel

    private func cardsCarousel(_ section: ExploreSection) -> some View {
        HorizontalSection(title: section.title) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(section.items, id: \.id) { item in
                    YouTubeGridItemView(item: item, onTap: {
                        openItem(item)
                    })
                }
            }
        }
    }

    // MARK: - Moods grid

    private func moodsGrid(_ section: ExploreSection) -> some View {
        let entries = MoodFamily.entries(for: section.moods)
        return HorizontalSection(title: "Moods") {
            // Two-row grid scrolling horizontally: all 50+ moods reachable
            // without a dominating vertical wall.
            LazyHGrid(
                rows: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                ForEach(entries) { entry in
                    switch entry.kind {
                    case .group(let family, let members):
                        // Native pop-up: pick the sub-genre without leaving the page.
                        Menu {
                            let icons = MoodFamily.uniqueIcons(for: members)
                            ForEach(members) { mood in
                                Button { router.explorePath.append(mood) } label: {
                                    Label(mood.title, systemImage: icons[mood.id] ?? "music.note")
                                }
                            }
                        } label: {
                            MoodCard(
                                title: family,
                                color: MoodCard.swatch(family: family, title: family),
                                subtitle: "\(members.count) genres",
                                trailingSymbol: "chevron.up.chevron.down"
                            )
                        }
                        .buttonStyle(.plain)
                    case .mood(let mood, let family):
                        NavigationLink(value: mood) {
                            MoodCard(title: mood.title, color: MoodCard.swatch(family: family, title: mood.title))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Navigation & playback

    private func openItem(_ item: YTItem) {
        YTItemRouter.route(
            item,
            playSong: { PlaybackQueue.playSingleWithRadio($0, log: Log.explore) },
            appendRoute: { router.explorePath.append($0) }
        )
    }
}

// MARK: - Mood card

/// Genres that share a family (Hip-Hop, Brazilian Hip-Hop...) share a color, and
/// the family collapses into one card that opens to show its genres.
private enum MoodFamily {
    struct Entry: Identifiable {
        enum Kind {
            case group(family: String, members: [MoodItem])
            case mood(MoodItem, family: String?)
        }
        let id: String
        let kind: Kind
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

    /// An icon per sub-genre from its title. Two genres never share one: the
    /// second falls back to the next free icon of the family's set.
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

    /// Families with two or more genres become one group card that opens a
    /// pop-up with its genres. Everything else keeps its place.
    static func entries(for moods: [MoodItem]) -> [Entry] {
        var members: [String: [MoodItem]] = [:]
        for mood in moods { if let f = family(of: mood.title) { members[f, default: []].append(mood) } }
        var seen = Set<String>()
        var result: [Entry] = []
        for mood in moods {
            guard let f = family(of: mood.title), let group = members[f], group.count > 1 else {
                result.append(Entry(id: "mood-\(mood.id)", kind: .mood(mood, family: nil)))
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
private struct MoodCard: View {
    let title: String
    let color: Color
    var subtitle: String?
    var trailingSymbol: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [color.mix(with: .white, by: 0.3), color],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Light from above, so the card reads as a raised surface.
            LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .center)

            // Larger than the card and tilted left, so the card edge crops it.
            Image(systemName: Self.symbol(for: title))
                .font(.system(size: 84, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
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
            // Dark text: white is unreadable on pastel colors.
            .foregroundStyle(.black.opacity(0.75))
            // Keeps the text inside the card and off the cropped icon.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
            .padding(.trailing, 36)
            .padding(.bottom, 12)

            if let trailingSymbol {
                Image(systemName: trailingSymbol)
                    .font(.title3)
                    .foregroundStyle(.black.opacity(0.55))
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(width: 172, height: 100)
        .clipShape(shape)
        .shadow(color: color.opacity(0.4), radius: 6, y: 4)
    }

    /// An SF Symbol for the category, matched on words in its title. The
    /// more specific words come first ("K-Pop" before "Pop").
    fileprivate static func symbol(for title: String) -> String {
        let title = title.lowercased()
        let symbols: [(words: [String], symbol: String)] = [
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
        return symbols.first { entry in entry.words.contains { title.contains($0) } }?.symbol ?? "music.note"
    }

    /// Pastel Pantone colors (name, code, sRGB value as published by Pantone),
    /// ordered so that neighboring families differ in hue.
    private static let pantone: [(name: String, code: String, rgb: Int)] = [
        ("Rose Quartz", "13-1520", 0xF7CAC9),
        ("Aqua Sky", "14-4811", 0x7BC4C4),
        ("Mimosa", "14-0848", 0xEFC050),
        ("Serenity", "15-3919", 0x92A8D1),
        ("Greenery", "15-0343", 0x88B04B),
        ("Radiant Orchid", "18-3224", 0xB163A3),
        ("Peach Fuzz", "13-1023", 0xFFBE98),
        ("Cerulean", "15-4020", 0x9BB7D4),
        ("Illuminating", "13-0647", 0xF5DF4D),
        ("Turquoise", "15-5519", 0x45B5AA),
        ("Living Coral", "16-1546", 0xFF6F61)
    ]

    /// A family's genres share its color. The sum of the letters is stable
    /// between launches; `hashValue` is not.
    static func swatch(family: String?, title: String) -> Color {
        let key = family ?? MoodFamily.family(of: title)
        // Each family gets its own color; other genres are spread by their title.
        let index = key.flatMap { MoodFamily.names.firstIndex(of: $0) }
            ?? title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) &* 31 }
        let rgb = pantone[(index % pantone.count + pantone.count) % pantone.count].rgb
        return Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

// MARK: - Mood detail

/// Full mood/genre category page: songs grid, playlists, videos, albums.
private struct MoodDetailView: View {
    let mood: MoodItem

    @State private var sections: [ExploreSection]?
    @State private var pendingRoute: DetailRoute?

    var body: some View {
        Group {
            if let sections {
                if sections.isEmpty {
                    ContentUnavailableView(
                        "Nothing here",
                        systemImage: "square.grid.2x2",
                        description: Text("Nothing found for \(mood.title).")
                    )
                } else {
                    ScrollView {
                        ExploreSectionsList(sections: sections, pendingRoute: $pendingRoute)
                            .padding(.bottom, 16)
                    }
                    .scrollIndicators(.automatic)
                    .miniPlayerTracksScroll()
                }
            } else {
                MoodDetailSkeletonView()
            }
        }
        .navigationTitle(mood.title)
        .navigationBarTitleDisplayMode(.large)
        .onChange(of: pendingRoute) { _, route in
            if let route {
                AppRouter.shared.explorePath.append(route)
                pendingRoute = nil
            }
        }
        .task {
            sections = await ExploreViewModel.loadMoodDetail(mood)
        }
    }
}

// MARK: - Explore tab skeleton

/// Loading placeholder mirroring the Explore tab: album cards (title only),
/// the 2-row moods grid, then a vertical Trending song list — the same
/// shimmer animation as Home, composed for this layout.
private struct ExploreSkeletonView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                VStack(alignment: .leading, spacing: 0) {
                    ShimmerSectionTitle(width: 220)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(0..<5, id: \.self) { _ in
                                ShimmerCard(showsSubtitle: false)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    ShimmerSectionTitle(width: 160)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHGrid(
                            rows: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                            spacing: 10
                        ) {
                            ForEach(0..<10, id: \.self) { _ in
                                ShimmerBlock(width: 150, height: 64, radius: 12)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    ShimmerSectionTitle(width: 120)
                    VStack(spacing: 0) {
                        ForEach(0..<6, id: \.self) { _ in
                            ShimmerRow()
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Mood detail skeleton

/// Loading placeholder mirroring the mood page layout: a vertical song
/// list followed by large playlist cards.
private struct MoodDetailSkeletonView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                VStack(alignment: .leading, spacing: 0) {
                    ShimmerSectionTitle(width: 80)
                    VStack(spacing: 0) {
                        ForEach(0..<5, id: \.self) { _ in
                            HStack(spacing: 12) {
                                ShimmerRow(titleWidth: 190, subtitleWidth: 130)
                                ShimmerBlock(width: 90, height: 20, radius: 4)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                        }
                    }
                }
                skeletonCardsSection(titleWidth: 200)
                skeletonCardsSection(titleWidth: 220)
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
    }

    private func skeletonCardsSection(titleWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ShimmerSectionTitle(width: titleWidth)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(0..<4, id: \.self) { _ in
                        ShimmerCard(showsSubtitle: false)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
    }
}
