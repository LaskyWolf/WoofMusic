//
//  SearchView.swift
//  Trop
//
//  Created by 686udjie on 03/07/2026.
//

import SwiftUI

/// The Search tab's root page: its own search field where Home and Library
/// show their filter chips, then recent searches or results underneath.
struct SearchView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchModel = SearchViewModel()
    @ObservedObject private var router = AppRouter.shared

    @FocusState private var fieldFocused: Bool
    /// Shared by this tab's covers and the pages they open, for the zoom transition.
    @Namespace private var coverZoom

    private let accountState = AccountState.shared

    /// Cancel and the sort menu show while typing or while a search is on screen.
    private var isActive: Bool { fieldFocused || !searchModel.fieldText.isEmpty }

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

                searchBar

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
        .coverZoomNamespace(coverZoom)
    }

    private var searchAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.4)
    }

    /// A field the height of the filter chips; Cancel and the sort menu slide
    /// in on the trailing side while it is active.
    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(SearchViewModel.placeholder, text: $searchModel.fieldText)
                    .focused($fieldFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit {
                        fieldFocused = false
                        searchModel.submit()
                    }
                if !searchModel.fieldText.isEmpty {
                    Button {
                        searchModel.fieldText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: DesignTokens.controlHeight)
            .background(Capsule().fill(Color(.systemGray5).opacity(0.6)))

            if isActive {
                Group {
                    sortMenu
                    Button("Cancel", action: cancelSearch)
                        .foregroundStyle(settings.accentColor)
                }
                .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, DesignTokens.screenHPadding)
        .padding(.vertical, 8)
        .animation(searchAnimation, value: isActive)
    }

    private func cancelSearch() {
        fieldFocused = false
        searchModel.cancel()
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

    /// Home Screen "Search" quick action: focus the field.
    private func consumeFocusRequest() {
        guard router.focusSearchField else { return }
        router.focusSearchField = false
        Task {
            // The tab switch must land before the field can take focus.
            try? await Task.sleep(for: .milliseconds(150))
            fieldFocused = true
        }
    }
}
