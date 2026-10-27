//
//  SearchResultsView.swift
//  Trop
//
//  Created by 686udjie on 03/07/2026.
//

import SwiftUI

/// Recent searches and results, shown under the Search tab's field.
/// SearchView owns the field and the view model; detail destinations
/// come from SearchView's NavigationStack.
struct SearchResultsView: View {
    @Environment(SettingsStore.self) private var settings
    let viewModel: SearchViewModel
    var fieldFocused: FocusState<Bool>.Binding
    /// Only appended to, never read: observing it would redraw the results on every tab's navigation.
    private let router = AppRouter.shared

    @State private var pendingRoute: DetailRoute?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { fieldFocused.wrappedValue = false })
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: pendingRoute) { _, route in
                if let route {
                    router.searchPath.append(route)
                    pendingRoute = nil
                }
            }
            .onAppear { viewModel.loadSearchHistory() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle:
            if viewModel.searchHistory.isEmpty {
                noRecentSearchesView
            } else {
                searchHistoryView
            }
        case .loading:
            loadingView
        case .results:
            searchResultsList
        case .noResults:
            noResultsView
        case .failed:
            errorView(viewModel.error)
        }
    }

    /// Same shape as `searchResultsList`: filter chips, a section title, song rows.
    private var loadingView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ShimmerChips(count: 5)
                ShimmerSectionTitle(width: 90)
                    .padding(.bottom, DesignTokens.titleContentGap)
                ForEach(0..<8, id: \.self) { _ in
                    ShimmerListItem()
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(true)
    }

    // MARK: - Submission

    private func submit(_ text: String) {
        fieldFocused.wrappedValue = false
        viewModel.submit(text)
    }

    private var searchHistoryView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Recently searched")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    Button("Clear") {
                        viewModel.clearSearchHistory()
                    }
                    .font(.subheadline)
                    .foregroundColor(settings.accentColor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                ForEach(viewModel.searchHistory, id: \.query) { entry in
                    Button {
                        submit(entry.query)
                    } label: {
                        HStack {
                            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                                .foregroundColor(settings.accentColor)
                            Text(entry.query)
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            viewModel.deleteSearchHistoryEntry(entry)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
            }
        }
        .scrollIndicators(.automatic)
        .miniPlayerTracksScroll()
    }

    private var searchResultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !viewModel.availableFilters.isEmpty {
                    filterChips
                }

                if let hero = viewModel.heroArtist {
                    artistHeroCard(hero, songs: viewModel.heroSongs)
                        .padding(.horizontal, DesignTokens.screenHPadding)
                        .padding(.top, 8)
                        .padding(.bottom, DesignTokens.sectionGap)
                }

                ForEach(viewModel.filteredResults) { section in
                    sectionHeader(section.title)

                    switch section.title {
                    case "Artists":
                        artistCarousel(items: section.items)
                    case "Albums":
                        albumCarousel(items: section.items)
                    default:
                        ForEach(section.items, id: \.id) { item in
                            resultRow(item)
                        }
                    }

                    // Section gap as its own row, so the item rows above stay lazy.
                    Color.clear.frame(height: DesignTokens.sectionGap)
                }
            }
        }
        .scrollIndicators(.automatic)
        .miniPlayerTracksScroll()
    }

    /// Section title with chevron — taps drill into (or clear) the filter.
    private func sectionHeader(_ title: String) -> some View {
        Button {
            if viewModel.selectedSectionFilter == title {
                viewModel.selectedSectionFilter = nil
            } else {
                viewModel.selectedSectionFilter = title
                viewModel.isShowingLibrary = false
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Same box as `NavigationTitleView`, so the rhythm matches Home and Explore.
        .padding(.horizontal, DesignTokens.screenHPadding)
        .padding(.vertical, 8)
        .padding(.bottom, DesignTokens.titleContentGap)
    }

    /// Artist-first hero: big circular artwork + name, then top songs.
    private func artistHeroCard(_ artist: ArtistItem, songs: [SongItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                router.searchPath.append(DetailRoute.artist(browseId: artist.browseId))
            } label: {
                HStack(spacing: 12) {
                    AsyncImageView(url: artist.thumbnailUrl)
                        .frame(width: DesignTokens.artSmall, height: DesignTokens.artSmall)
                        .clipShape(Circle())
                    Text(artist.name)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text("•••")
                        .font(.body.weight(.black))
                        .foregroundStyle(settings.accentColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ForEach(songs, id: \.videoId) { song in
                let item = YTItem.song(song)
                YouTubeListItemView(item: item, onTap: {
                    handleItemTap(item)
                }, onNavigate: { pendingRoute = $0 })
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemGray6))
        )
    }

    /// Songs and episodes keep the 56 pt song row; albums, artists, playlists
    /// and podcasts get the medium cover row used by Library's list layout.
    @ViewBuilder
    private func resultRow(_ item: YTItem) -> some View {
        switch item {
        case .song, .episode:
            YouTubeListItemView(item: item, onTap: {
                handleItemTap(item)
            }, onNavigate: { pendingRoute = $0 })
        case .album(let album):
            mediaRow(item, subtitle: album.artists.map(\.name).joined(separator: ", "), detail: album.year.map { String($0) })
        case .artist(let artist):
            mediaRow(item, subtitle: "Artist", artistKindOf: artist.name, isCircular: true)
        case .playlist(let playlist):
            mediaRow(item, subtitle: playlist.author, detail: playlist.songCount.map { "\($0) songs" })
        case .podcast(let podcast):
            mediaRow(item, subtitle: podcast.author ?? "Podcast")
        }
    }

    private func mediaRow(
        _ item: YTItem, subtitle: String?, artistKindOf: String? = nil, detail: String? = nil, isCircular: Bool = false
    ) -> some View {
        Button {
            handleItemTap(item)
        } label: {
            MediaListRow(
                url: item.thumbnailUrl, title: item.title, subtitle: subtitle, artistKindOf: artistKindOf,
                detail: detail, isCircular: isCircular,
                zoomRoute: YTItemRouter.detailRoute(for: item)
            )
                .padding(.horizontal, DesignTokens.screenHPadding)
        }
        .buttonStyle(ZoomPressStyle(scale: 0.98))
        .cardMenu(for: item)
    }

    private func artistCarousel(items: [YTItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(items, id: \.id) { item in
                    if case .artist(let artist) = item {
                        Button {
                            router.searchPath.append(DetailRoute.artist(browseId: artist.browseId))
                        } label: {
                            ArtistCircleCell(thumbnailUrl: artist.thumbnailUrl, name: artist.name)
                        }
                        .buttonStyle(ZoomPressStyle())
                        .artistCardMenu(browseId: artist.browseId)
                    }
                }
            }
            .padding(.horizontal, DesignTokens.screenHPadding)
        }
    }

    private func albumCarousel(items: [YTItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: DesignTokens.cardSpacing) {
                ForEach(items, id: \.id) { item in
                    if case .album(let album) = item {
                        let route = DetailRoute.album(browseId: album.browseId)
                        Button {
                            router.searchPath.append(route)
                        } label: {
                            MediaGridCell(
                                thumbnailUrl: album.thumbnailUrl,
                                title: album.title,
                                subtitle: album.artists.map(\.name).joined(separator: ", "),
                                zoomRoute: route
                            )
                        }
                        .buttonStyle(ZoomPressStyle())
                        .albumCardMenu(browseId: album.browseId, artists: album.artists)
                    }
                }
            }
            .padding(.horizontal, DesignTokens.screenHPadding)
        }
    }

    private var filterChips: some View {
        FilterChipBar(
            items: ["All Results"] + viewModel.availableFilters,
            id: \.self,
            title: { $0 },
            isSelected: { filter in
                if filter == "All Results" {
                    return viewModel.selectedSectionFilter == nil && !viewModel.isShowingLibrary
                }
                return filter == "Library"
                    ? viewModel.isShowingLibrary
                    : viewModel.selectedSectionFilter == filter
            },
            onTap: { filter in
                if filter == "All Results" {
                    viewModel.selectedSectionFilter = nil
                    viewModel.isShowingLibrary = false
                } else if filter == "Library" {
                    let willShow = !viewModel.isShowingLibrary
                    viewModel.isShowingLibrary = willShow
                    viewModel.selectedSectionFilter = nil
                } else {
                    viewModel.selectedSectionFilter = filter
                    viewModel.isShowingLibrary = false
                }
            }
        )
    }

    private var noResultsView: some View {
        ContentUnavailableView(
            "No Results",
            systemImage: "magnifyingglass",
            description: Text("No results found for \"\(viewModel.submittedQuery)\"")
        )
    }

    private var noRecentSearchesView: some View {
        ContentUnavailableView(
            "No Recent Searches",
            systemImage: "magnifyingglass",
            description: Text("Your recent searches will appear here.")
        )
    }

    private func errorView(_ error: Error?) -> some View {
        ContentUnavailableView(
            "Search failed",
            systemImage: "exclamationmark.triangle",
            description: Text(error?.localizedDescription ?? "Something went wrong.")
        )
    }

    private func handleItemTap(_ item: YTItem) {
        YTItemRouter.route(
            item,
            playSong: { PlaybackQueue.playSingleWithRadio($0, log: Log.searchView) },
            appendRoute: { router.searchPath.append($0) }
        )
    }
}
