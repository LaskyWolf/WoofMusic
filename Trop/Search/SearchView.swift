//
//  SearchView.swift
//  Trop
//
//  Created by 686udjie on 03/07/2026.
//

import SwiftUI

/// The Search tab's root page: the system search field (in the tab bar,
/// because ContentView gives this tab the search role), then recent
/// searches or results underneath.
struct SearchView: View {
    @State private var searchModel = SearchViewModel()
    @Bindable private var router = AppRouter.shared

    /// The native search field's presentation: true while search is active,
    /// even with the keyboard down. The system sets it back on Cancel.
    @State private var isSearching = false
    /// Keyboard focus of the native field, so a tap on the results can lower
    /// the keyboard without leaving search.
    @FocusState private var fieldFocused: Bool
    /// Shared by this tab's covers and the pages they open, for the zoom transition.
    @Namespace private var coverZoom

    private let accountState = AccountState.shared

    var body: some View {
        NavigationStack(path: $router.searchPath) {
            VStack(spacing: 0) {
                TabHeaderView(
                    title: "Search",
                    accountIsLoggedIn: accountState.isLoggedIn,
                    accountImageUrl: accountState.accountImageUrl,
                    onHistory: { router.searchPath.append(DetailRoute.history) },
                    onAccount: { router.searchPath.append(DetailRoute.settings) }
                )

                SearchResultsView(viewModel: searchModel, fieldFocused: $fieldFocused)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .toolbar(.hidden, for: .navigationBar)
            .detailRouteDestinations()
            .onChange(of: router.focusSearchField) { _, requested in
                if requested { consumeFocusRequest() }
            }
            .onChange(of: router.pendingSearchQuery) { _, query in
                if query != nil { consumeSearchRequest() }
            }
            .onAppear {
                consumeFocusRequest()
                consumeSearchRequest()
            }
        }
        .searchable(text: $searchModel.fieldText, isPresented: $isSearching, prompt: SearchViewModel.placeholder)
        .searchFocused($fieldFocused)
        .autocorrectionDisabled()
        .onSubmit(of: .search) { searchModel.submit() }
        .onChange(of: isSearching) { _, searching in
            // System Cancel (which also leaves the tab, see ContentView): drop
            // the query and results, so the next visit opens on recent searches.
            if !searching { searchModel.cancel() }
        }
        .coverZoomNamespace(coverZoom)
    }

    /// The full player's cover takes about 0.4 s to close.
    private static let activationDelay: Duration = .milliseconds(450)

    /// Home Screen "Search" quick action: open the field with the keyboard up.
    private func consumeFocusRequest() {
        guard router.focusSearchField else { return }
        router.focusSearchField = false
        Task {
            // The tab switch, and the full player closing over it, must land
            // before search can activate and raise the keyboard.
            try? await Task.sleep(for: Self.activationDelay)
            // Presenting search focuses the field; if search is already
            // presented with the keyboard down, only the focus change raises it.
            isSearching = true
            fieldFocused = true
        }
    }

    /// Siri's search: show the results with the keyboard down.
    private func consumeSearchRequest() {
        guard let query = router.pendingSearchQuery else { return }
        router.pendingSearchQuery = nil
        Task {
            // The tab switch, and the full player closing over it, must land
            // before search can activate and raise the keyboard.
            try? await Task.sleep(for: Self.activationDelay)
            isSearching = true
            searchModel.submit(query)
        }
    }
}
