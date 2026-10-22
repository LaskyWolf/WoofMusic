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
        HorizontalSection(title: section.title) {
            // Two-row grid scrolling horizontally: all 50+ moods reachable
            // without a dominating vertical wall.
            LazyHGrid(
                rows: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                ForEach(section.moods) { mood in
                    NavigationLink(value: mood) {
                        MoodCard(mood: mood)
                    }
                    .buttonStyle(.plain)
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

/// A colored Moods & Genres tile, like Apple Music's category cards. The
/// color comes from YouTube Music when it sends one, otherwise from the title,
/// so a category keeps its color between launches.
private struct MoodCard: View {
    let mood: MoodItem

    var body: some View {
        let hue = Self.hue(for: mood)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.7, brightness: 0.62),
                    Color(hue: (hue + 0.06).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.42)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Light from above, so the card reads as a raised surface.
            LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .center)

            // Larger than the card and tilted left, so the card edge crops it.
            Image(systemName: Self.symbol(for: mood.title))
                .font(.system(size: 84, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
                .rotationEffect(.degrees(-18))
                .offset(x: 24, y: 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .accessibilityHidden(true)

            Text(mood.title)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(12)
        }
        .frame(width: 172, height: 100)
        .clipShape(shape)
        .shadow(color: Color(hue: hue, saturation: 0.8, brightness: 0.3).opacity(0.35), radius: 6, y: 4)
    }

    /// An SF Symbol for the category, matched on words in its title. The
    /// more specific words come first ("K-Pop" before "Pop").
    private static func symbol(for title: String) -> String {
        let title = title.lowercased()
        let symbols: [(words: [String], symbol: String)] = [
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

    /// Only the hue is kept: saturation and brightness are fixed so white
    /// text stays readable on every card.
    private static func hue(for mood: MoodItem) -> Double {
        if let rgb = mood.color {
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
            UIColor(
                red: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1
            ).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            if saturation > 0.15 { return Double(hue) }
        }
        // `hashValue` changes every launch; a sum of the letters doesn't.
        let sum = mood.title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) &* 31 }
        return Double((sum % 360 + 360) % 360) / 360
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
