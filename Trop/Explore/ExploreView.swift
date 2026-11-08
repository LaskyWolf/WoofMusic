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
    @Bindable private var router = AppRouter.shared

    @State private var pendingRoute: DetailRoute?
    /// Shared by this tab's covers and the pages they open, for the zoom transition.
    @Namespace private var coverZoom

    var body: some View {
        NavigationStack(path: $router.explorePath) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .tabHeader {
                    TabHeaderView(title: "Explore", path: $router.explorePath)
                    if viewModel.phase == .idle || viewModel.phase == .loading {
                        // The chips come with the page: placeholders keep their place.
                        ShimmerChips(count: 6, width: 84)
                    } else if !viewModel.moods.isEmpty {
                        if let family = viewModel.selectedFamily, let sub = chosenSubgenre {
                            pathChips(family: family, subgenre: sub)
                        } else {
                            FilterChipBar(
                                items: MoodFamily.entries(for: viewModel.moods),
                                id: \.id,
                                title: \.title,
                                isSelected: isSelected,
                                onTap: tap
                            )
                        }
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
                .detailRouteDestinations()
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

    // MARK: - Chips

    private func isSelected(_ entry: MoodFamily.Entry) -> Bool {
        switch entry.kind {
        case .group(let family, _): viewModel.selectedFamily == family
        case .mood(let mood): viewModel.selectedFamily == nil && viewModel.selectedMood?.id == mood.id
        }
    }

    private func tap(_ entry: MoodFamily.Entry) {
        if isSelected(entry) {
            viewModel.selectFamily(nil)
            return
        }
        switch entry.kind {
        case .group(let family, _): viewModel.selectFamily(family)
        case .mood(let mood): viewModel.selectGenre(mood)
        }
    }

    /// The chosen genre when it is one of the family's sub-genres, not the family itself.
    private var chosenSubgenre: MoodItem? {
        guard let family = viewModel.selectedFamily, let mood = viewModel.selectedMood,
              MoodFamily.subgenres(of: family, in: viewModel.moods).contains(where: { $0.id == mood.id }) else { return nil }
        return mood
    }

    /// "Pop › Brazilian Pop ✕": the family goes back to all of Pop, the ✕ too.
    private func pathChips(family: String, subgenre: MoodItem) -> some View {
        HStack(spacing: 8) {
            pathChip(family, fill: settings.accentColor) { viewModel.selectFamily(family) }
            pathChip(subgenre.title, fill: settings.accentColor.mix(with: .black, by: 0.3), leading: "chevron.right", trailing: "xmark") {
                viewModel.selectFamily(family)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.screenHPadding)
        .padding(.vertical, 8)
    }

    private func pathChip(_ title: String, fill: Color, leading: String? = nil, trailing: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let leading { Image(systemName: leading).font(.caption.weight(.bold)) }
                Text(title).lineLimit(1)
                if let trailing { Image(systemName: trailing).font(.caption.weight(.bold)) }
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(minHeight: DesignTokens.controlHeight)
            .background(Capsule().fill(fill))
            .foregroundStyle(.white)
        }
        .buttonStyle(ZoomPressStyle())
    }

    // MARK: - Sub-genre cards

    /// The family's sub-genres as cards; the chosen one steps out and the rest dim.
    @ViewBuilder
    private var subgenreCards: some View {
        if let family = viewModel.selectedFamily {
            let subs = MoodFamily.subgenres(of: family, in: viewModel.moods)
            let chosen = chosenSubgenre
            let icons = MoodFamily.uniqueIcons(for: subs)
            let shown = subs.filter { $0.id != chosen?.id }
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: DesignTokens.titleContentGap) {
                    NavigationTitleView(title: "\(family) sub-genres")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: DesignTokens.cardSpacing) {
                            ForEach(shown) { mood in
                                Button { viewModel.selectGenre(mood) } label: {
                                    MoodCard(
                                        title: mood.title,
                                        color: MoodCard.swatch(family: family, title: mood.title),
                                        symbol: icons[mood.id]
                                    )
                                    .opacity(chosen == nil ? 1 : 0.55)
                                }
                                .buttonStyle(ZoomPressStyle())
                            }
                        }
                        .padding(.horizontal, DesignTokens.screenHPadding)
                    }
                    .scrollClipDisabled()
                }
                .padding(.bottom, DesignTokens.sectionGap)
                .animation(.smooth(duration: 0.3), value: chosen?.id)
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
            if let mood = viewModel.selectedMood {
                moodContent(mood)
            } else {
                sectionsList
            }
        case .empty:
            RetryStateView(
                title: "Nothing to explore",
                systemImage: "flame",
                message: "YouTube Music sent nothing for this region.",
                retry: { await viewModel.refresh() }
            )
        case .failed:
            // Wrapped in a ScrollView so the "Pull to retry" gesture works.
            ScrollView {
                RetryStateView(
                    title: "Explore failed",
                    systemImage: "exclamationmark.triangle",
                    message: "Couldn't load Explore.",
                    retry: { await viewModel.refresh() }
                )
                .containerRelativeFrame([.horizontal, .vertical])
            }
            .refreshable { await viewModel.refresh() }
        }
    }

    private var sectionsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                subgenreCards
                ExploreSectionsList(
                    sections: viewModel.sections,
                    pendingRoute: $pendingRoute,
                    newReleases: viewModel.newReleases
                )
            }
            .scrollsToTopOnTabReselect(2)
        }
        .scrollIndicators(.automatic)
        .miniPlayerTracksScroll()
        .refreshable { await viewModel.refresh() }
    }

    /// The chosen mood's page in place of the feed: its new releases first,
    /// then its songs, then the rest.
    @ViewBuilder
    private func moodContent(_ mood: MoodItem) -> some View {
        if let sections = viewModel.moodSections {
            if sections.isEmpty {
                ContentUnavailableView(
                    "Nothing here",
                    systemImage: "square.grid.2x2",
                    description: Text("Nothing found for \(mood.title).")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        subgenreCards
                        ExploreSectionsList(sections: sections, pendingRoute: $pendingRoute)
                    }
                    .scrollsToTopOnTabReselect(2) { viewModel.selectFamily(nil) }
                }
                .scrollIndicators(.automatic)
                .miniPlayerTracksScroll()
                // Keyed by mood, so switching moods starts at the top.
                .id(mood.id)
            }
        } else {
            MoodDetailSkeletonView { subgenreCards }
        }
    }
}

// MARK: - Shared section list

/// Renders Explore sections (song grids, card carousels): the Explore feed
/// and a mood's feed.
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
                    // Moods are the tab's filter chips.
                    EmptyView()
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

    // MARK: - Navigation & playback

    private func openItem(_ item: YTItem) {
        YTItemRouter.route(
            item,
            playSong: { PlaybackQueue.playSingleWithRadio($0, log: Log.explore) },
            appendRoute: { router.explorePath.append($0) }
        )
    }
}

// MARK: - Explore tab skeleton

/// Loading placeholder mirroring the Explore tab: new releases, then the
/// Trending song columns. The section builders mirror
/// `ExploreSectionsList`, so the mood page skeleton reuses them.
private struct ExploreSkeletonView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                NewReleasesSkeleton()
                Self.songsSection(titleWidth: 120)
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

/// Loading placeholder mirroring a mood's feed, which renders through
/// `ExploreSectionsList`: new releases, song columns, then card carousels.
private struct MoodDetailSkeletonView<Header: View>: View {
    @ViewBuilder var header: Header

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                // The order of `ExploreViewModel.moodOrder`: new releases, songs, the rest.
                ExploreSkeletonView.cardsSection(titleWidth: 220)
                ExploreSkeletonView.songsSection(titleWidth: 80)
                ExploreSkeletonView.cardsSection(titleWidth: 200)
            }
        }
        .scrollIndicators(.hidden)
        .allowsHitTesting(false)
        .shimmerClock()
    }
}
