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
    @ObservedObject private var router = AppRouter.shared

    /// The native search field's presentation: true while search is active,
    /// even with the keyboard down. The system sets it back on Cancel.
    @State private var isSearching = false
    /// Keyboard focus of the native field, so a tap on the results can lower
    /// the keyboard without leaving search.
    @FocusState private var fieldFocused: Bool
    /// Shared by this tab's covers and the pages they open, for the zoom transition.
    @Namespace private var coverZoom

    private let accountState = AccountState.shared

    /// Sorting only reorders results, so the menu shows only while there are some.
    private var showsSortMenu: Bool {
        searchModel.phase == .loading || searchModel.phase == .results
    }

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

                if showsSortMenu {
                    HStack {
                        Spacer()
                        sortMenu
                    }
                    .padding(.horizontal, DesignTokens.screenHPadding)
                }

                SearchResultsView(viewModel: searchModel, fieldFocused: $fieldFocused)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .toolbar(.hidden, for: .navigationBar)
            .detailRouteDestinations()
            .onChange(of: router.focusSearchField) { _, requested in
                if requested { consumeFocusRequest() }
            }
            .onAppear { consumeFocusRequest() }
        }
        .searchable(text: $searchModel.fieldText, isPresented: $isSearching, prompt: SearchViewModel.placeholder)
        .searchFocused($fieldFocused)
        .autocorrectionDisabled()
        .onSubmit(of: .search) { searchModel.submit() }
        .onChange(of: isSearching) { _, searching in
            // System Cancel: back to recent searches, like the old Cancel button.
            if !searching { searchModel.cancel() }
        }
        .coverZoomNamespace(coverZoom)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(SearchSort.allCases, id: \.self) { option in
                Button {
                    searchModel.sort = option
                } label: {
                    if searchModel.sort == option {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.body)
                .foregroundStyle(.primary)
                .frame(width: DesignTokens.controlHeight, height: DesignTokens.controlHeight)
                .background(Circle().fill(Color(.systemGray5).opacity(0.6)))
        }
        .accessibilityLabel("Sort results")
    }

    /// Home Screen "Search" quick action: open the field with the keyboard up.
    private func consumeFocusRequest() {
        guard router.focusSearchField else { return }
        router.focusSearchField = false
        Task {
            // The tab switch must land before search can activate.
            try? await Task.sleep(for: .milliseconds(150))
            // Presenting search focuses the field; if search is already
            // presented with the keyboard down, only the focus change raises it.
            isSearching = true
            fieldFocused = true
        }
    }
}
