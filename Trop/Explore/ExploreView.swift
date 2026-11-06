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
                    if !viewModel.moods.isEmpty {
                        FilterChipBar(
                            items: viewModel.moods,
                            id: \.id,
                            title: \.title,
                            isSelected: { viewModel.selectedMood?.id == $0.id },
                            onTap: { mood in
                                viewModel.select(viewModel.selectedMood?.id == mood.id ? nil : mood)
                            }
                        )
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
                    ExploreSectionsList(sections: sections, pendingRoute: $pendingRoute)
                        .scrollsToTopOnTabReselect(2) { viewModel.select(nil) }
                }
                .scrollIndicators(.automatic)
                .miniPlayerTracksScroll()
                // Keyed by mood, so switching moods starts at the top.
                .id(mood.id)
            }
        } else {
            MoodDetailSkeletonView()
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
