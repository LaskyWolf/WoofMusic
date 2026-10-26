//
//  ContentView.swift
//  Trop
//
//  Created by 686udjie on 28/06/2026.
//

import Combine
import SwiftUI

struct ContentView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var nowPlaying = NowPlaying.shared
    @State private var selectedTab = SettingsStore.shared.defaultTab
    @State private var isExpanded = false
    @Namespace private var playerTransition
    @State private var scrollState = MiniPlayerScrollState()

    var body: some View {
        TabView(selection: $selectedTab) {
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
        .onAppear {
            AppRouter.shared.selectedTabIndex = selectedTab
            QuickAction.performPending()
        }
        .onReceive(AppRouter.shared.$selectedTabIndex.dropFirst()) { index in
            // Quick actions switch tabs through the router.
            if selectedTab != index { selectedTab = index }
        }
        .onChange(of: selectedTab) { _, newValue in
            AppRouter.shared.selectedTabIndex = newValue
        }
        .onReceive(AppRouter.shared.$activeRoute) { route in
            // A detail page was opened from an overlay: collapse the player so
            // the pushed page is visible underneath.
            if route != nil {
                collapsePlayer()
            }
        }
        .onReceive(AppRouter.shared.$playerExpandToken.dropFirst()) { _ in
            expandPlayer()
        }
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
