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
        // Explore is the Search tab's root page, so it pushes onto `searchPath`.
        NavigationStack(path: $router.searchPath) {
            VStack(spacing: 0) {
                TabHeaderView(
                    title: "Explore",
                    accountIsLoggedIn: accountState.isLoggedIn,
                    accountImageUrl: accountState.accountImageUrl,
                    onHistory: { router.searchPath.append(DetailRoute.history) },
                    onAccount: { router.searchPath.append(DetailRoute.settings) }
                )

                searchBar

                content
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .toolbar(.hidden, for: .navigationBar)
            .detailRouteDestinations()
            .navigationDestination(for: MoodItem.self) { mood in
                MoodDetailView(mood: mood)
            }
            .navigationDestination(for: SearchRoute.self) { _ in
                SearchView()
            }
            .onChange(of: pendingRoute) { _, route in
                if let route {
                    router.searchPath.append(route)
                    pendingRoute = nil
                }
            }
            .onAppear { viewModel.load() }
        }
    }

    /// Looks like the search page's field; tapping it opens that page with the
    /// keyboard up. Sits where Home and Library show their filter chips.
    private var searchBar: some View {
        Button {
            router.searchPath.append(SearchRoute())
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                Text(SearchRoute.placeholder)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color(.systemGray5).opacity(0.6)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DesignTokens.screenHPadding)
        .padding(.vertical, 8)
        .accessibilityLabel("Search")
        .accessibilityHint(SearchRoute.placeholder)
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
            ExploreSectionsList(sections: viewModel.sections, pendingRoute: $pendingRoute)
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
    @ObservedObject private var router = AppRouter.shared
    var sections: [ExploreSection]
    var pendingRoute: Binding<DetailRoute?>

    var body: some View {
        // Sections space themselves (HorizontalSection adds the section gap).
        LazyVStack(alignment: .leading, spacing: 0) {
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
            // Not HorizontalSection: its horizontal ScrollView would fight the carousel drag.
            VStack(alignment: .leading, spacing: DesignTokens.titleContentGap) {
                NavigationTitleView(title: "Moods")
                MoodCarousel(entries: entries)
            }
            .padding(.bottom, DesignTokens.sectionGap)
        }
    }

    // MARK: - Navigation & playback

    private func openItem(_ item: YTItem) {
        YTItemRouter.route(
            item,
            playSong: { PlaybackQueue.playSingleWithRadio($0, log: Log.explore) },
            appendRoute: { router.searchPath.append($0) }
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
private struct MoodCarousel: View {
    let entries: [MoodFamily.Entry]

    @ObservedObject private var router = AppRouter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Fractional index of the card at the centre. Unbounded: `offset(of:)` wraps it.
    @State private var position: Double = 0
    @State private var dragStart: Double?
    /// The family whose genres the dialog lists.
    @State private var openGroup: (family: String, members: [MoodItem])?

    /// Finger travel that moves the row by one card: the arc's slope at the centre.
    private static let dragStep: Double = 75
    /// About two neighbours per side; the third one peeks in while dragging.
    private static let visibleRange: Double = 2.6
    static let centreSize = CGSize(width: 160, height: 116)
    /// Room under the centre card for the side cards to drop into.
    static let arcDrop: CGFloat = 70
    static let height: CGFloat = 200

    /// Size, position and tilt of a card `distance` steps from the centre.
    /// Shared with the skeleton so the placeholder has the same shape.
    static func layout(_ distance: Double) -> (size: CGSize, x: CGFloat, y: CGFloat, angle: Angle) {
        let step = abs(distance)
        let size = CGSize(
            width: max(96, centreSize.width - 30 * CGFloat(step)),
            height: max(72, centreSize.height - 20 * CGFloat(step))
        )
        let x = CGFloat(sin(distance * 0.5) * 150)
        let y = CGFloat((1 - cos(distance * 0.5)) * 90)
        return (size, x, y, .degrees(distance * 9))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                let distance = offset(of: index)
                if abs(distance) <= Self.visibleRange {
                    let layout = Self.layout(distance)
                    moodCard(entry, size: layout.size, textOpacity: max(0, 1 - abs(distance)))
                        .brightness(-0.18 * abs(distance))
                        .rotationEffect(layout.angle, anchor: .bottom)
                        .offset(x: layout.x, y: layout.y)
                        .onTapGesture { tap(index) }
                        .zIndex(-abs(distance))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height - Self.arcDrop, alignment: .bottom)
        // Fixed on the centre slot, so the dialog points at the centre card.
        .overlay(alignment: .bottom) {
            Color.clear
                .frame(width: Self.centreSize.width, height: Self.centreSize.height)
                .allowsHitTesting(false)
                .confirmationDialog(
                    openGroup?.family ?? "",
                    isPresented: Binding(get: { openGroup != nil }, set: { if !$0 { openGroup = nil } }),
                    titleVisibility: .visible
                ) {
                    ForEach(openGroup?.members ?? []) { mood in
                        Button(mood.title) { router.searchPath.append(mood) }
                    }
                }
        }
        .padding(.bottom, Self.arcDrop)
        .contentShape(Rectangle())
        .gesture(HorizontalPan(onChange: dragChanged, onEnd: dragEnded))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title(of: centreEntry))
        .accessibilityValue("\(centreIndex + 1) of \(entries.count)")
        .accessibilityHint("Swipe up or down to change mood.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: settle(to: position.rounded() + 1)
            case .decrement: settle(to: position.rounded() - 1)
            @unknown default: break
            }
        }
        .accessibilityAction { open(centreEntry) }
        .accessibilityActions {
            // A family's genres, so VoiceOver reaches them without the dialog.
            if case .group(_, let members) = centreEntry.kind {
                ForEach(members) { mood in
                    Button(mood.title) { router.searchPath.append(mood) }
                }
            }
        }
    }

    // MARK: Cards

    private func moodCard(_ entry: MoodFamily.Entry, size: CGSize, textOpacity: Double) -> MoodCard {
        switch entry.kind {
        case .group(let family, let members):
            MoodCard(
                title: family,
                color: MoodCard.swatch(family: family, title: family),
                subtitle: "\(members.count) genres",
                trailingSymbol: "chevron.up.chevron.down",
                size: size,
                textOpacity: textOpacity
            )
        case .mood(let mood, let family):
            MoodCard(
                title: mood.title,
                color: MoodCard.swatch(family: family, title: mood.title),
                size: size,
                textOpacity: textOpacity
            )
        }
    }

    // MARK: Position

    /// Signed distance of a card from the centre, wrapped into (-n/2, n/2] so
    /// the row loops: past the last mood comes the first again.
    private func offset(of index: Int) -> Double {
        let count = Double(entries.count)
        var distance = (Double(index) - position).truncatingRemainder(dividingBy: count)
        if distance > count / 2 { distance -= count } else if distance <= -count / 2 { distance += count }
        return distance
    }

    private var centreIndex: Int {
        let count = entries.count
        return (Int(position.rounded()) % count + count) % count
    }

    private var centreEntry: MoodFamily.Entry { entries[centreIndex] }

    private func title(of entry: MoodFamily.Entry) -> String {
        switch entry.kind {
        case .group(let family, _): family
        case .mood(let mood, _): mood.title
        }
    }

    /// The only tap path: a side card comes to the centre, the centre card opens.
    private func tap(_ index: Int) {
        let distance = offset(of: index)
        if abs(distance) < 0.5 {
            open(entries[index])
        } else {
            settle(to: (position + distance).rounded())
        }
    }

    /// A genre opens its page; a family lists its genres in a dialog.
    private func open(_ entry: MoodFamily.Entry) {
        switch entry.kind {
        case .group(let family, let members): openGroup = (family, members)
        case .mood(let mood, _): router.searchPath.append(mood)
        }
    }

    private func settle(to target: Double) {
        if reduceMotion {
            position = target
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { position = target }
        }
    }

    private func dragChanged(_ translation: CGFloat) {
        if dragStart == nil { dragStart = position }
        guard let start = dragStart else { return }
        position = start - Double(translation) / Self.dragStep
    }

    /// A flick carries on up to four cards, then snaps to the nearest one.
    private func dragEnded(_ translation: CGFloat, _ velocity: CGFloat) {
        guard let start = dragStart else { return }
        dragStart = nil
        // About the distance a scroll view's deceleration would add.
        let projected = Double(translation + velocity * 0.25) / Self.dragStep
        settle(to: (start - min(max(projected, -4), 4)).rounded())
    }
}

/// A horizontal-only pan. It begins only when the finger moves more sideways
/// than up or down, so the page's vertical scroll keeps working, and it cancels
/// the touches under it (the card taps) once it begins.
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    var onChange: (CGFloat) -> Void
    /// Translation and velocity on the x axis, in points and points per second.
    var onEnd: (CGFloat, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            onChange(translation)
        case .ended:
            onEnd(translation, recognizer.velocity(in: recognizer.view).x)
        case .cancelled, .failed:
            onEnd(translation, 0)
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
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
    var size = CGSize(width: 172, height: 100)
    /// Title, subtitle and chevron; the carousel fades them on side cards.
    var textOpacity: Double = 1

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
            .opacity(textOpacity)

            if let trailingSymbol {
                Image(systemName: trailingSymbol)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .opacity(textOpacity)
            }
        }
        .frame(width: size.width, height: size.height)
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
        return Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
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
                AppRouter.shared.searchPath.append(route)
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

/// Loading placeholder mirroring the Explore tab: album cards, the Trending
/// song columns, then the moods carousel. The section builders mirror
/// `ExploreSectionsList`, so the mood page skeleton reuses them.
private struct ExploreSkeletonView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Self.cardsSection(titleWidth: 220)
                Self.songsSection(titleWidth: 120)
                // Moods: the arc, centre card on top of its neighbours.
                VStack(alignment: .leading, spacing: DesignTokens.titleContentGap) {
                    ShimmerSectionTitle(width: 80)
                    ZStack(alignment: .bottom) {
                        ForEach([-2.0, 2.0, -1.0, 1.0, 0.0], id: \.self) { distance in
                            let layout = MoodCarousel.layout(distance)
                            ShimmerBlock(width: layout.size.width, height: layout.size.height, radius: 14)
                                .rotationEffect(layout.angle, anchor: .bottom)
                                .offset(x: layout.x, y: layout.y)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: MoodCarousel.height - MoodCarousel.arcDrop, alignment: .bottom)
                    .padding(.bottom, MoodCarousel.arcDrop)
                }
                .padding(.bottom, DesignTokens.sectionGap)
            }
        }
        .scrollIndicators(.hidden)
        .allowsHitTesting(false)
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
    }
}
