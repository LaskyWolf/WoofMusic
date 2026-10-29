//
// ExploreView.swift
// Trop
//
// Created by 686udjie on 11/09/2026.
//

import SwiftUI

struct ExploreView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var viewModel = ExploreViewModel()
    @ObservedObject private var router = AppRouter.shared

    @State private var pendingRoute: DetailRoute?
    /// Shared by this tab's covers and the pages they open, for the zoom transition.
    @Namespace private var coverZoom

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
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        }
        .coverZoomNamespace(coverZoom)
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
            // Wrapped in a ScrollView so the "Pull to retry" gesture works.
            ScrollView {
                ContentUnavailableView(
                    "Explore failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Couldn't load Explore. Pull to retry.")
                )
                .containerRelativeFrame([.horizontal, .vertical])
            }
            .refreshable { await viewModel.refresh() }
        }
    }

    private var sectionsList: some View {
        ScrollView {
            ExploreSectionsList(
                sections: viewModel.sections,
                pendingRoute: $pendingRoute,
                newReleases: viewModel.newReleases
            )
            .scrollsToTopOnTabReselect(2)
        }
        .scrollIndicators(.automatic)
        .miniPlayerTracksScroll()
        .refreshable { await viewModel.refresh() }
    }
}

// MARK: - Shared section list

/// Renders Explore sections (song grids, card carousels, the moods carousel).
/// Shared by the Explore tab and mood category pages.
struct ExploreSectionsList: View {
    /// Only appended to, never read: observing it would redraw this view on every tab's navigation.
    private let router = AppRouter.shared
    var sections: [ExploreSection]
    var pendingRoute: Binding<DetailRoute?>
    /// The Explore tab's new releases shelf, drawn as `NewReleasesSection`.
    var newReleases: ExploreViewModel.NewReleases?

    var body: some View {
        // Sections space themselves (HorizontalSection adds the section gap).
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(sections) { section in
                switch section.kind {
                case .rows:
                    songGrid(section)
                case .cards:
                    if let newReleases, section.id == newReleases.sectionId {
                        NewReleasesSection(section: section, kinds: newReleases.kinds, onOpen: openItem)
                    } else {
                        cardsCarousel(section)
                    }
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

    /// Song rows in a 4-row grid scrolling horizontally, one column per swipe.
    /// A column is the screen width minus `songColumnPeek`, so the next one shows.
    /// Not HorizontalSection: paging needs content margins instead of padding,
    /// or the snapped column would lose its edge inset.
    private func songGrid(_ section: ExploreSection) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.titleContentGap) {
            NavigationTitleView(title: section.title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: Self.songRows, spacing: DesignTokens.cardSpacing) {
                    ForEach(section.items, id: \.id) { item in
                        YouTubeListItemView(item: item, onTap: {
                            openItem(item)
                        }, onNavigate: { pendingRoute.wrappedValue = $0 })
                        .containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in
                            width - Self.songColumnPeek
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
        .padding(.bottom, DesignTokens.sectionGap)
    }

    /// Four 64 pt song rows per column.
    static let songRows = Array(repeating: GridItem(.fixed(64), spacing: 8), count: 4)
    /// How much of the next column peeks in from the trailing edge.
    static let songColumnPeek: CGFloat = 40

    // MARK: - Cards carousel

    private func cardsCarousel(_ section: ExploreSection) -> some View {
        HorizontalSection(title: section.title) {
            LazyHStack(alignment: .top, spacing: DesignTokens.cardSpacing) {
                ForEach(section.items, id: \.id) { item in
                    YouTubeGridItemView(item: item, onTap: {
                        openItem(item)
                    })
                }
            }
        }
    }

    // MARK: - Moods grid

    @ViewBuilder
    private func moodsGrid(_ section: ExploreSection) -> some View {
        let entries = MoodFamily.entries(for: section.moods)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.titleContentGap) {
                NavigationTitleView(title: "Moods")
                MoodRow(entries: entries)
            }
            .padding(.bottom, DesignTokens.sectionGap)
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

    /// Families with two or more genres become one group card that opens a
    /// dialog with its genres. Everything else keeps its place.
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

/// One looping row of mood cards stacked on an arc: the centre card is the
/// biggest and on top; its neighbours shrink, dim, drop and tilt outwards like a
/// fanned hand. Swipe or tap a side card to bring it to the centre; tap the
/// centre card to open it.
///
/// Every card is the same plain view whatever its distance, so a gesture in
/// flight never loses its view. A UIKit pan drives the drag: it starts only on
/// a horizontal swipe (vertical ones scroll the page) and cancels the tap under
/// the finger once it starts.
/// One row of mood cards that loops: scrolling past the last mood brings the
/// first one back. A family opens the native pop-up menu with its genres.
private struct MoodRow: View {
    let entries: [MoodFamily.Entry]

    /// Only appended to, never read: observing it would redraw this view on every tab's navigation.
    private let router = AppRouter.shared
    /// Set once the row has jumped to the middle copy, so coming back to the
    /// row keeps the user's place.
    @State private var centered = false

    /// The entries are repeated this many times and the row starts in the
    /// middle, so it never reaches an end in practice.
    // ponytail: repeated copies fake the loop; a recentering scroll view if anyone scrolls 20+ laps.
    private static let copies = 40

    init(entries: [MoodFamily.Entry]) {
        self.entries = entries
    }

    var body: some View {
        // A one-time scrollTo instead of `.scrollPosition(id:)`: that binding is
        // written every time a card passes the middle of the row, and the row
        // dropped a frame at each write.
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: DesignTokens.cardSpacing) {
                    ForEach(0..<entries.count * Self.copies, id: \.self) { index in
                        card(entries[index % entries.count])
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, DesignTokens.screenHPadding, for: .scrollContent)
            // The cards' glow reaches below the row.
            .scrollClipDisabled()
            .scrollTargetBehavior(.viewAligned)
            .onAppear {
                guard !centered else { return }
                centered = true
                proxy.scrollTo(entries.count * Self.copies / 2, anchor: .leading)
            }
        }
    }

    @ViewBuilder
    private func card(_ entry: MoodFamily.Entry) -> some View {
        switch entry.kind {
        case .group(let family, let members):
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
            .buttonStyle(ZoomPressStyle())
        case .mood(let mood, let family):
            Button { router.explorePath.append(mood) } label: {
                MoodCard(title: mood.title, color: MoodCard.swatch(family: family, title: mood.title))
            }
            .buttonStyle(ZoomPressStyle())
        }
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
    var size = Self.defaultSize
    static let defaultSize = CGSize(width: 172, height: 100)

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
            Image(systemName: Self.symbol(for: title))
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
    fileprivate static func symbol(for title: String) -> String {
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

// MARK: - Mood detail

/// Full mood/genre category page: songs grid, playlists, videos, albums.
private struct MoodDetailView: View {
    let mood: MoodItem

    @State private var sections: [ExploreSection]?
    @State private var pendingRoute: DetailRoute?

    init(mood: MoodItem) {
        self.mood = mood
        _sections = State(initialValue: MoodDetailCache.sections(for: mood))
    }

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
        .task { await refreshIfNeeded() }
    }

    /// Loads the page only when it is not cached yet or the cached copy is old.
    /// A refresh replaces what is on screen only when the content really changed.
    private func refreshIfNeeded() async {
        guard !MoodDetailCache.isFresh(mood) else { return }
        let loaded = await ExploreViewModel.loadMoodDetail(mood)
        // A failed request returns nothing: keep the cached page.
        if loaded.isEmpty {
            if sections == nil { sections = [] }
            return
        }
        MoodDetailCache.store(loaded, for: mood)
        MoodGenreIndex.record(loaded, mood: mood.title)
        if sections.map(Self.signature) != Self.signature(loaded) { sections = loaded }
    }

    private static func signature(_ sections: [ExploreSection]) -> String {
        sections.map { section in
            section.title + "|" + section.items.map(\.id).joined(separator: ",") + "|\(section.moods.count)"
        }.joined(separator: ";")
    }
}

// MARK: - Explore tab skeleton

/// Loading placeholder mirroring the Explore tab: new releases, the Trending
/// song columns, then the moods row. The section builders mirror
/// `ExploreSectionsList`, so the mood page skeleton reuses them.
private struct ExploreSkeletonView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                NewReleasesSkeleton()
                Self.songsSection(titleWidth: 120)
                // Moods: one row of cards, the next one peeking in.
                VStack(alignment: .leading, spacing: DesignTokens.titleContentGap) {
                    ShimmerSectionTitle(width: 80)
                    HStack(spacing: DesignTokens.cardSpacing) {
                        ForEach(0..<3, id: \.self) { _ in
                            ShimmerBlock(width: MoodCard.defaultSize.width, height: MoodCard.defaultSize.height, radius: 14)
                        }
                    }
                    .padding(.leading, DesignTokens.screenHPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                }
                .padding(.bottom, DesignTokens.sectionGap)
            }
        }
        .scrollIndicators(.hidden)
        .allowsHitTesting(false)
        .shimmerClock()
    }

    /// Card carousel: square cover, title and subtitle, like the real cards.
    static func cardsSection(titleWidth: CGFloat) -> some View {
        section(titleWidth: titleWidth) {
            HStack(alignment: .top, spacing: DesignTokens.cardSpacing) {
                ForEach(0..<5, id: \.self) { _ in
                    ShimmerCard()
                }
            }
        }
    }

    /// Song columns like `songGrid`: four rows each, the next column peeking in.
    static func songsSection(titleWidth: CGFloat) -> some View {
        section(titleWidth: titleWidth) {
            LazyHGrid(rows: ExploreSectionsList.songRows, spacing: DesignTokens.cardSpacing) {
                ForEach(0..<8, id: \.self) { _ in
                    ShimmerListItem()
                        .containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in
                            width - ExploreSectionsList.songColumnPeek
                        }
                }
            }
            // The rows carry their own 16 pt inset, like the real song grid.
            .padding(.leading, -DesignTokens.screenHPadding)
        }
    }

    /// A title over a sideways row with the same content margins as `songGrid`.
    private static func section<Content: View>(
        titleWidth: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.titleContentGap) {
            ShimmerSectionTitle(width: titleWidth)
            ScrollView(.horizontal, showsIndicators: false) {
                content()
            }
            .contentMargins(.horizontal, DesignTokens.screenHPadding, for: .scrollContent)
        }
        .padding(.bottom, DesignTokens.sectionGap)
    }
}

// MARK: - Mood detail skeleton

/// Loading placeholder mirroring the mood page, which renders through
/// `ExploreSectionsList`: song columns, then card carousels.
private struct MoodDetailSkeletonView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ExploreSkeletonView.songsSection(titleWidth: 80)
                ExploreSkeletonView.cardsSection(titleWidth: 200)
                ExploreSkeletonView.cardsSection(titleWidth: 220)
            }
        }
        .scrollIndicators(.hidden)
        .allowsHitTesting(false)
        .shimmerClock()
    }
}
