//
//  ContentView.swift
//  Trop
//
//  Created by 686udjie on 28/06/2026.
//

import SwiftUI

struct ContentView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var nowPlaying = NowPlaying.shared
    private let router = AppRouter.shared
    @State private var isExpanded = false
    @Namespace private var playerTransition
    @State private var scrollState = MiniPlayerScrollState()

    var body: some View {
        TabView(selection: tabSelection) {
            // Right-to-left puts the first tab on the right, so the left-handed layout
            // declares them in reverse: on screen they stay Home, Library, Explore.
            if settings.leftHandedTabBar {
                exploreTab
                libraryTab
                homeTab
            } else {
                homeTab
                libraryTab
                exploreTab
            }

            // The system search tab puts SearchView's native field in the tab bar.
            Tab("Search", systemImage: "magnifyingglass", value: 3, role: .search) {
                SearchView().environment(\.layoutDirection, .leftToRight)
            }
        }
        // Right-to-left moves Search to the left; every page inside is set back to left-to-right.
        .environment(\.layoutDirection, settings.leftHandedTabBar ? .rightToLeft : .leftToRight)
        .tabBarMinimizeBehavior(.onScrollDown)
        // Selecting the Search tab activates search (keyboard up); Cancel
        // deactivates it and goes back to the previously selected tab.
        .tabViewSearchActivation(.searchTabSelection)
            .tabViewBottomAccessory(isEnabled: nowPlaying.isBarPresented) {
                MiniPlayerBarView(onExpand: expandPlayer, isTransitioning: isExpanded)
                    .environment(\.layoutDirection, .leftToRight)
                    .matchedTransitionSource(id: "nowPlaying", in: playerTransition) { source in
                        source.clipShape(RoundedRectangle(cornerRadius: 24))
                    }
            }
            .background {
                backgroundLayer
            }
            .environment(scrollState)
            .accessibilityHidden(isExpanded)
            .fullScreenCover(isPresented: $isExpanded) {
                GeometryReader { proxy in
                    FullPlayerView(
                        onCollapse: collapsePlayer,
                        artworkTopInset: proxy.safeAreaInsets.top
                    )
                }
                .navigationTransition(.zoom(sourceID: "nowPlaying", in: playerTransition))
                .presentationBackground(.clear)
                .environment(scrollState)
                .accessibilityAction(.escape, collapsePlayer)
            }
        .onAppear { QuickAction.performPending() }
        .onChange(of: router.playerCollapseToken) { collapsePlayer() }
        .onChange(of: router.playerExpandToken) { expandPlayer() }
        .onChange(of: nowPlaying.isBarPresented) { _, presented in
            if !presented { collapsePlayer() }
        }
        .simultaneousGesture(backSwipeGesture)
    }

    private var homeTab: some TabContent<Int> {
        Tab("Home", systemImage: "house.fill", value: 0) {
            HomeScreenView().environment(\.layoutDirection, .leftToRight)
        }
    }

    private var libraryTab: some TabContent<Int> {
        Tab("Library", systemImage: "music.note.square.stack", value: 1) {
            LibraryView().environment(\.layoutDirection, .leftToRight)
        }
    }

    private var exploreTab: some TabContent<Int> {
        Tab("Explore", systemImage: "flame", value: 2) {
            ExploreView().environment(\.layoutDirection, .leftToRight)
        }
    }

    /// The router's tab, plus a tap on the tab that is already selected reaches it.
    private var tabSelection: Binding<Int> {
        // Read here, in the body, so a tab switch from a quick action or a
        // widget link redraws the TabView.
        let selected = router.selectedTabIndex
        return Binding(
            get: { selected },
            set: { tab in
                if tab == router.selectedTabIndex { router.reselectTab(tab) }
                router.selectedTabIndex = tab
            }
        )
    }

    private func expandPlayer() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        isExpanded = true
    }

    private func collapsePlayer() {
        isExpanded = false
    }

    private var backSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                let isHorizontal = abs(value.translation.width) > abs(value.translation.height)
                guard !isExpanded,
                      value.startLocation.x <= 28,
                      isHorizontal,
                      value.translation.width > 80 else { return }

                let router = AppRouter.shared
                let depth = router.activePathDepth
                guard depth > 0 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard !isExpanded, router.activePathDepth == depth else { return }
                    router.popActiveRoute()
                }
            }
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        if settings.playerBackgroundStyle == .solid {
            Color.black.ignoresSafeArea()
        } else if let accent = nowPlaying.accentColor {
            accent
                .opacity(0.06)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.8), value: nowPlaying.accentColor)
        }
    }
}

#Preview {
    ContentView()
}
