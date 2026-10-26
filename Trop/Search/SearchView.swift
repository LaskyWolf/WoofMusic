//
//  SearchView.swift
//  Trop
//
//  Created by 686udjie on 03/07/2026.
//

import SwiftUI

/// The Search tab's root page: the native search field, the sort menu, and
/// recent searches or results underneath.
struct SearchView: View {
    @State private var searchModel = SearchViewModel()
    @ObservedObject private var router = AppRouter.shared

    /// The native search field's presentation: true while search is active,
    /// even with the keyboard down. The system sets it back on Cancel.
    @State private var isSearching = false
    @FocusState private var fieldFocused: Bool

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

                HStack {
                    Spacer()
                    sortMenu
                }
                .padding(.horizontal, DesignTokens.screenHPadding)

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
        // The system search tab puts this field in the tab bar.
        .searchable(text: $searchModel.fieldText, isPresented: $isSearching, prompt: SearchViewModel.placeholder)
        .searchFocused($fieldFocused)
        .autocorrectionDisabled()
        .onSubmit(of: .search) { searchModel.submit() }
        .onChange(of: isSearching) { _, searching in
            if !searching { searchModel.cancel() }
        }
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

    /// Home Screen "Search" quick action: open the search field.
    private func consumeFocusRequest() {
        guard router.focusSearchField else { return }
        router.focusSearchField = false
        Task {
            // The tab switch must land before the field can take focus.
            try? await Task.sleep(for: .milliseconds(150))
            isSearching = true
        }
    }
}
