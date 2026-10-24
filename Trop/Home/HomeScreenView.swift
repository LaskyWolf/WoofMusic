//
//  HomeScreenView.swift
//  Trop
//
//  Created by 686udjie on 01/07/2026.
//

import SwiftUI

struct HomeScreenView: View {
    @Environment(SettingsStore.self) private var settings
    @ObservedObject private var router = AppRouter.shared
    @State private var viewModel = HomeViewModel()
    private let account = AccountState.shared

    @State private var pendingRoute: DetailRoute?
    @State private var speedDialEntries: [SpeedDialEntry] = []

    var body: some View {
        NavigationStack(path: $router.homePath) {
            VStack(spacing: 0) {
                TabHeaderView(
                    title: "Home",
                    accountIsLoggedIn: viewModel.isLoggedIn,
                    accountImageUrl: viewModel.accountImageUrl,
                    onHistory: { router.homePath.append(DetailRoute.history) },
                    onAccount: { router.homePath.append(DetailRoute.settings) }
                )

                Group {
                    if viewModel.isLoading {
                        VStack {
                            Spacer()
                            ShimmerLoadingView()
                            Spacer()
                        }
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
                    viewModel.handleLogin(
                        cookies: account.loginModel.cookies,
                        sapisid: account.loginModel.sapisid,
                        visitorData: account.loginModel.visitorData
                    )
                } else {
                    viewModel.handleLogout()
                }
            }
            .task {
                await viewModel.restoreSession()
                viewModel.loadHomeData()
                await reloadSpeedDial()
                // Trigger library sync in background
                Task {
                    await SyncBridge.checkAndSyncIfStale()
                }
            }
            .task(id: viewModel.homeSections.count) {
                let urls = viewModel.homeSections
                    .flatMap(\.items)
                    .compactMap(\.thumbnailUrl)
                    .compactMap(URL.init)
                await ImagePreloader.shared.preload(urls)
            }
        }
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
                    ShimmerLoadingView()
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
        .onChange(of: settings.showQuickPicks) { _, _ in
            viewModel.syncSettings()
            Task { await viewModel.refresh() }
        }
        .onChange(of: settings.topListsLength) { _, _ in
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
            HStack(alignment: .top, spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in ShimmerCard() }
            }
            .padding(.horizontal, DesignTokens.screenHPadding)
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    @ViewBuilder
    private func sectionView(for section: HomeSection) -> some View {
        switch section {
        case .quickPicks:
            quickPicksSection(section)
        case .keepListening:
            mixedSection(section)
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

    @ViewBuilder
    private func quickPicksSection(_ section: HomeSection) -> some View {
        let pinnedSongs = speedDialEntries.map { $0.toSongItem() }
        let pinnedIds = Set(speedDialEntries.map(\.videoId))
        let visibleItems = section.items.filter { item in
            if case .song(let s) = item { return !pinnedIds.contains(s.videoId) }
            return true
        }
        let quickSongs = visibleItems.compactMap { if case .song(let s) = $0 { return s } else { return nil } }
        let combinedQueue = pinnedSongs + quickSongs

        if combinedQueue.isEmpty {
            EmptyView()
        } else {
            // Pages of 2x2: pinned songs first, then the picks. The next page peeks in from the right.
            let cards = pinnedSongs.map { ($0, true) } + quickSongs.map { ($0, false) }
            let pages = stride(from: 0, to: cards.count, by: 4).map { Array(cards[$0..<min($0 + 4, cards.count)]) }
            VStack(alignment: .leading, spacing: 8) {
                NavigationTitleView(title: section.displayTitle)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(pages.indices, id: \.self) { page in
                            quickPicksPage(pages[page], queue: combinedQueue)
                                .containerRelativeFrame(.horizontal) { width, _ in width - DesignTokens.screenHPadding * 2 - 12 }
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, DesignTokens.screenHPadding, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }

    private func quickPicksPage(_ cards: [(SongItem, Bool)], queue: [SongItem]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                let (song, isPinned) = card
                QuickPickCard(song: song, isPinned: isPinned) {
                    handleSongTap(song, in: queue)
                }
                .contextMenu {
                    if isPinned {
                        Button(role: .destructive) {
                            Task {
                                try? await DatabaseService.shared.removeFromSpeedDial(videoId: song.videoId)
                                await reloadSpeedDial()
                            }
                        } label: {
                            Label("Unpin", systemImage: "pin.slash")
                        }
                        .tint(.red)
                    }
                }
            }
        }
    }

    private func songsSection(_ section: HomeSection) -> some View {
        let queue = section.items.compactMap { if case .song(let s) = $0 { return s } else { return nil } }
        return HorizontalSection(title: section.displayTitle, vSpacing: 8, contentVerticalPadding: 0) {
            LazyHGrid(rows: Array(repeating: GridItem(.fixed(60)), count: 4), spacing: 12) {
                ForEach(section.items.indices, id: \.self) { i in
                    let item = section.items[i]
                    if case .song(let s) = item {
                        YouTubeListItemView(item: item, onTap: { handleSongTap(s, in: queue) }, onNavigate: { pendingRoute = $0 })
                            .frame(width: 280)
                    } else {
                        YouTubeListItemView(item: item, onTap: { handleItemTap(item) }, onNavigate: { pendingRoute = $0 })
                            .frame(width: 280)
                    }
                }
            }
        }
    }

    private func mixedSection(_ section: HomeSection) -> some View {
        let queue = section.items.compactMap { if case .song(let s) = $0 { return s } else { return nil } }
        return HorizontalSection(title: section.displayTitle, vSpacing: 8, contentVerticalPadding: 0) {
            HStack(spacing: 12) {
                ForEach(section.items.indices, id: \.self) { i in
                    let item = section.items[i]
                    if case .song(let s) = item, !queue.isEmpty {
                        YouTubeGridItemView(item: item, onTap: { handleSongTap(s, in: queue) })
                    } else {
                        YouTubeGridItemView(item: item, onTap: { handleItemTap(item) })
                    }
                }
            }
        }.padding(.top, 8)
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
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                        .padding(.top, 24)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                }
                .overlay(alignment: .topTrailing) {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(settings.accentColor)
                            .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
