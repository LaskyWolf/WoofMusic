//
//  HomeScreenView.swift
//  Trop
//
//  Created by 686udjie on 01/07/2026.
//

import SwiftUI

struct HomeScreenView: View {
    @Environment(SettingsStore.self) private var settings
    @Bindable private var router = AppRouter.shared
    @State private var viewModel = HomeViewModel()
    /// Shared by this tab's covers and the pages they open, for the zoom transition.
    @Namespace private var coverZoom
    private let account = AccountState.shared

    @State private var pendingRoute: DetailRoute?
    @State private var speedDialEntries: [SpeedDialEntry] = []
    @State private var quickPicksPage: Int? = 0

    var body: some View {
        NavigationStack(path: $router.homePath) {
            VStack(spacing: 0) {
                TabHeaderView(
                    title: "Home",
                    accountIsLoggedIn: account.isLoggedIn,
                    accountImageUrl: account.accountImageUrl,
                    onHistory: { router.homePath.append(DetailRoute.history) },
                    onAccount: { router.homePath.append(DetailRoute.settings) }
                )

                Group {
                    if viewModel.isLoading {
                        ShimmerLoadingView()
                            .frame(maxHeight: .infinity, alignment: .top)
                            .transition(.opacity)
                    } else if let error = viewModel.error {
                        errorView(error)
                    } else {
                        homescreenContent
                            .transition(.opacity)
                    }
                }
                .animation(.smooth(duration: 0.35), value: viewModel.isLoading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .toolbar(.hidden, for: .navigationBar)
            .detailRouteDestinations()
            .onChange(of: pendingRoute) { _, route in
                if let route {
                    router.homePath.append(route)
                    pendingRoute = nil
                }
            }
            .onChange(of: account.isLoggedIn) { _, loggedIn in
                if loggedIn {
                    guard !viewModel.isLoggedIn else { return }
                    viewModel.handleLogin(sapisid: account.loginModel.sapisid)
                } else {
                    viewModel.handleLogout()
                }
            }
            .task {
                // .task re-runs on every return to Home; the session only needs restoring once.
                if !viewModel.isLoggedIn {
                    await viewModel.restoreSession()
                }
                viewModel.loadHomeData()
                await reloadSpeedDial()
                // Trigger library sync in background
                Task {
                    await SyncBridge.checkAndSyncIfStale()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .speedDialDidChange)) { _ in
                Task { await reloadSpeedDial() }
            }
            // The Quick Picks widget shows the same cards. Out here so it follows
            // them while their section or this tab is off screen.
            .onChange(of: quickPicksCards.map { $0.song.videoId }, initial: true) {
                let cards = quickPicksCards
                if !cards.isEmpty { WidgetSync.shared.updateQuickPicks(cards, isEnabled: true) }
            }
        }
        .coverZoomNamespace(coverZoom)
    }

    private var homescreenContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let chips = viewModel.homePage?.chips, !chips.isEmpty {
                    ChipsRowView(
                        chips: chips,
                        selectedChip: viewModel.selectedChip,
                        onChipTap: { viewModel.toggleChip($0) }
                    )
                }

                if viewModel.isChipLoading {
                    // YouTube localises chip titles; "Podcast" matches English and Italian.
                    ShimmerLoadingView(
                        isChipFeed: true,
                        isPodcastFeed: viewModel.selectedChip?.title.localizedCaseInsensitiveContains("podcast") == true
                    )
                } else {
                    // Keyed by section id, so a new section fades in instead of popping in.
                    ForEach(viewModel.homeSections) { section in
                        sectionView(for: section)
                            .transition(.opacity.combined(with: .offset(y: 24)))
                            .onAppear { loadMoreWhenNearEnd(section) }
                    }
                }

                if viewModel.isLoadingMore {
                    loadingMorePlaceholder
                        .transition(.opacity)
                }

                GeometryReader { _ in
                    Color.clear
                        .onAppear {
                            let total = viewModel.homeSections.count
                            if total > 0 {
                                viewModel.loadMoreIfNeeded(
                                    currentIndex: total - 1,
                                    total: total
                                )
                            }
                        }
                }
                .frame(height: 1)
            }
            .animation(.smooth(duration: 0.4), value: viewModel.homeSections.map(\.id))
            .animation(.smooth(duration: 0.3), value: viewModel.isLoadingMore)
            .scrollsToTopOnTabReselect(0) {
                if viewModel.selectedChip != nil { viewModel.toggleChip(nil) }
            }
        }
        .scrollIndicators(.automatic)
        .miniPlayerTracksScroll()
        .refreshable {
            await viewModel.refresh()
            await reloadSpeedDial()
            await SyncBridge.checkAndSyncIfStale()
        }
        .onChange(of: settings.hideExplicit) { _, _ in
            viewModel.syncSettings()
        }
        .onChange(of: settings.showQuickPicks) { _, isOn in
            if !isOn { WidgetSync.shared.updateQuickPicks([], isEnabled: false) }
            viewModel.syncSettings()
            Task { await viewModel.refresh() }
        }
        .onChange(of: settings.quickPicksSize) { _, _ in
            Task { await viewModel.refresh() }
        }
        .onChange(of: settings.contentCountry) { _, _ in
            Task { await viewModel.refresh() }
        }
    }

    /// Starts the next page when one of the last sections shows up, so it is
    /// usually there before the user reaches the bottom.
    private func loadMoreWhenNearEnd(_ section: HomeSection) {
        let sections = viewModel.homeSections
        guard let index = sections.firstIndex(where: { $0.id == section.id }) else { return }
        viewModel.loadMoreIfNeeded(currentIndex: index, total: sections.count)
    }

    /// Same shape as a card section, shown while the next page loads.
    private var loadingMorePlaceholder: some View {
        VStack(alignment: .leading, spacing: 0) {
            ShimmerSectionTitle(width: 180)
            HStack(alignment: .top, spacing: DesignTokens.cardSpacing) {
                ForEach(0..<3, id: \.self) { _ in ShimmerCard() }
            }
            .padding(.horizontal, DesignTokens.screenHPadding)
            .padding(.top, DesignTokens.titleContentGap)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .padding(.bottom, DesignTokens.sectionGap)
    }

    @ViewBuilder
    private func sectionView(for section: HomeSection) -> some View {
        switch section {
        case .quickPicks:
            quickPicksSection(section)
        case .keepListening:
            keepListeningSection(section)
        case .forgottenFavorites:
            songsSection(section)
        case .homePageSection(let sectionData, _):
            if sectionData.isSongsOnly {
                songsSection(section)
            } else {
                mixedSection(section)
            }
        default:
            mixedSection(section)
        }
    }

    /// Pinned songs, then the section's songs that aren't pinned.
    private func quickPicksSongs(_ section: HomeSection) -> (pinned: [SongItem], picks: [SongItem]) {
        let pinnedIds = Set(speedDialEntries.map(\.videoId))
        let picks: [SongItem] = section.items.compactMap { item in
            if case .song(let s) = item, !pinnedIds.contains(s.videoId) { return s }
            return nil
        }
        return (speedDialEntries.map { $0.toSongItem() }, picks)
    }

    private var quickPicksCards: [(song: SongItem, isPinned: Bool)] {
        let section = viewModel.homeSections.first { if case .quickPicks = $0 { true } else { false } }
        guard let section else { return [] }
        let songs = quickPicksSongs(section)
        let cards = songs.pinned.map { (song: $0, isPinned: true) } + songs.picks.map { (song: $0, isPinned: false) }
        return Array(cards.prefix(settings.quickPicksSize.count))
    }

    @ViewBuilder
    private func quickPicksSection(_ section: HomeSection) -> some View {
        let songs = quickPicksSongs(section)
        let pinnedSongs = songs.pinned
        let quickSongs = songs.picks
        let combinedQueue = pinnedSongs + quickSongs

        if combinedQueue.isEmpty {
            EmptyView()
        } else {
            // Pages of 3x2 or 3x3 (a setting): pinned songs first, then the picks.
            let size = settings.quickPicksSize
            let cards = Array((pinnedSongs.map { ($0, true) } + quickSongs.map { ($0, false) }).prefix(size.count))
            let pages = stride(from: 0, to: cards.count, by: size.perPage).map { Array(cards[$0..<min($0 + size.perPage, cards.count)]) }
            VStack(alignment: .leading, spacing: DesignTokens.titleContentGap) {
                NavigationTitleView(title: section.displayTitle)
                ScrollView(.horizontal, showsIndicators: false) {
                    // Spacing equals the side margin, so the next page stays off screen.
                    LazyHStack(alignment: .top, spacing: DesignTokens.screenHPadding) {
                        ForEach(pages.indices, id: \.self) { page in
                            quickPicksPage(pages[page], queue: combinedQueue, columns: size.columns)
                                .containerRelativeFrame(.horizontal)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, DesignTokens.screenHPadding, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $quickPicksPage)

                if pages.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(pages.indices, id: \.self) { page in
                            Circle()
                                .fill(page == (quickPicksPage ?? 0) ? Color.primary : Color.secondary.opacity(0.35))
                                .frame(width: 6, height: 6)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
                    .animation(.smooth(duration: 0.2), value: quickPicksPage)
                    .accessibilityHidden(true)
                }
            }
            .padding(.bottom, DesignTokens.sectionGap)
        }
    }


    private func quickPicksPage(_ cards: [(SongItem, Bool)], queue: [SongItem], columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                let (song, isPinned) = card
                // Long press: the song menu, which also pins and unpins.
                SongActionsMenu(song: song, onNavigate: { AppRouter.shared.open($0) }, asContextMenu: true) {
                    QuickPickCard(song: song, isPinned: isPinned) {
                        handleSongTap(song, in: queue)
                    }
                }
            }
        }
    }

    private func songsSection(_ section: HomeSection) -> some View {
        let queue = section.items.compactMap { if case .song(let s) = $0 { return s } else { return nil } }
        // Columns a bit narrower than the screen, so the next column's artwork
        // peeks at the right edge; scrolling snaps one column at a time.
        return HorizontalSection(title: section.displayTitle, snapsToItems: true) {
            LazyHGrid(rows: Array(repeating: GridItem(.fixed(YouTubeListItemView.rowHeight), spacing: 8), count: 4), spacing: 0) {
                ForEach(section.items.indices, id: \.self) { i in
                    let item = section.items[i]
                    Group {
                        if case .song(let s) = item {
                            YouTubeListItemView(item: item, onTap: { handleSongTap(s, in: queue) }, onNavigate: { pendingRoute = $0 })
                        } else {
                            YouTubeListItemView(item: item, onTap: { handleItemTap(item) }, onNavigate: { pendingRoute = $0 })
                        }
                    }
                    .containerRelativeFrame(.horizontal) { width, _ in width - Self.songColumnPeek }
                }
            }
            .scrollTargetLayout()
        }
    }

    /// How much of the next song column shows at the right edge.
    static let songColumnPeek: CGFloat = 40

    private func mixedSection(_ section: HomeSection) -> some View {
        let queue = section.items.compactMap { if case .song(let s) = $0 { return s } else { return nil } }
        let hasPodcasts = section.items.contains { if case .podcast = $0 { return true } else { return false } }
        let hasPlaylists = section.items.contains { if case .playlist = $0 { return true } else { return false } }
        // Podcast tiles glow below the row, so it must not clip them.
        return HorizontalSection(title: section.displayTitle, clipsContent: !hasPodcasts) {
            // Top-aligned, so captions line up when titles wrap to two lines.
            LazyHStack(alignment: .top, spacing: DesignTokens.cardSpacing) {
                ForEach(section.items.indices, id: \.self) { i in
                    let item = section.items[i]
                    if case .song(let s) = item, !queue.isEmpty {
                        YouTubeGridItemView(item: item, onTap: { handleSongTap(s, in: queue) }, reservesPlaylistLift: hasPlaylists)
                    } else if case .podcast(let podcast) = item {
                        RadioDialTile(podcast: podcast) { handleItemTap(item) }
                    } else {
                        YouTubeGridItemView(item: item, onTap: { handleItemTap(item) }, reservesPlaylistLift: hasPlaylists)
                    }
                }
            }
        }
    }

    /// Same taps as `mixedSection`: songs play within the section's songs, the rest route.
    private func keepListeningSection(_ section: HomeSection) -> some View {
        let queue = section.items.compactMap { if case .song(let s) = $0 { return s } else { return nil } }
        // In a month's first week, last month's recap card takes this place.
        return RecapHomeCard {
            KeepListeningStrip(title: section.displayTitle, items: section.items) { item in
                if case .song(let s) = item, !queue.isEmpty {
                    handleSongTap(s, in: queue)
                } else {
                    handleItemTap(item)
                }
            }
        }
        // Same gap under the chips as Library's shortcut tiles.
        .padding(.top, 8)
    }

    // MARK: - Quick Picks (pinned)

    private func reloadSpeedDial() async {
        speedDialEntries = (try? await DatabaseService.shared.fetchSpeedDial()) ?? []
    }

    private func handleSongTap(_ song: SongItem, in queue: [SongItem]) {
        Log.homeScreenView.debug("Tapped song in queue: \(song.title) queueCount=\(queue.count)")
        PlaybackQueue.play(song, in: queue, log: Log.homeScreenView, context: "Tapped song")
    }

    private func handleItemTap(_ item: YTItem) {
        Log.homeScreenView.debug("Tapped item: \(item.title) type=\(typeName(item))")
        YTItemRouter.route(
            item,
            playSong: { PlaybackQueue.playSingleWithRadio($0, log: Log.homeScreenView) },
            appendRoute: { router.homePath.append($0) }
        )
    }

    private func typeName(_ item: YTItem) -> String {
        switch item {
        case .song: return "song"
        case .album: return "album"
        case .artist: return "artist"
        case .playlist: return "playlist"
        case .podcast: return "podcast"
        case .episode: return "episode"
        }
    }

    private func errorView(_ error: Error) -> some View {
        ContentUnavailableView(
            "Couldn't load your homescreen",
            systemImage: "wifi.slash",
            description: Text(error.localizedDescription)
        )
    }
}

#Preview {
    HomeScreenView()
}

/// Square cover with the title over a dark fade at the bottom.
private struct QuickPickCard: View {
    @Environment(SettingsStore.self) private var settings
    let song: SongItem
    let isPinned: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { AsyncImageView(url: song.thumbnailUrl).scaledToFill() }
                .overlay(alignment: .bottom) {
                    Text(song.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                        .padding(.top, 28)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                }
                .overlay(alignment: .topTrailing) {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(settings.accentColor)
                            .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(ZoomPressStyle())
    }
}
