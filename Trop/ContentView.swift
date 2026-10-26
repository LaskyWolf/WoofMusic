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

    @State private var safeBottom: CGFloat = 0
    @State private var isKeyboardVisible = false

    var body: some View {
        // The system tab bar is hidden on every tab; TabView stays so each tab keeps its state.
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house.fill", value: 0) {
                tabPage(HomeScreenView())
            }
            Tab("Library", systemImage: "music.note.square.stack", value: 1) {
                tabPage(LibraryView())
            }
            // Explore is tab 3: AppRouter and the quick actions use that index.
            Tab("Explore", systemImage: "magnifyingglass", value: 3) {
                tabPage(ExploreView())
            }
        }
        .overlay(alignment: .bottom) {
            tabBar
        }
        .background {
            backgroundLayer
        }
        .background {
            // Ignores the keyboard so the bar's position comes from the home indicator only.
            Color.clear
                .ignoresSafeArea(.keyboard)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.safeAreaInsets.bottom
                } action: { bottom in
                    safeBottom = bottom
                }
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
            // A new page starts at the top, so the bar starts expanded.
            scrollState.isInline = false
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
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .onChange(of: nowPlaying.isBarPresented) { _, presented in
            if !presented { collapsePlayer() }
        }
        .simultaneousGesture(backSwipeGesture)
    }

    private var tabBar: some View {
        AppTabBar(
            selection: $selectedTab,
            isMinimized: scrollState.isInline,
            isLeftHanded: settings.leftHandedTabBar,
            showsMiniPlayer: nowPlaying.isBarPresented,
            onRestore: { scrollState.isInline = false },
            onReselect: { _ in reselectTab() }
        ) {
            MiniPlayerBarView(onExpand: expandPlayer, isTransitioning: isExpanded)
                .matchedTransitionSource(id: "nowPlaying", in: playerTransition) { source in
                    source.clipShape(RoundedRectangle(cornerRadius: 24))
                }
        }
        .padding(.horizontal, AppTabBarMetrics.horizontalMargin)
        .padding(.bottom, AppTabBarMetrics.bottomGap(safeBottom: safeBottom))
        // Stays behind the keyboard like the system tab bar, and fades out while it is up.
        .ignoresSafeArea(edges: .bottom)
        .opacity(isKeyboardVisible ? 0 : 1)
        .allowsHitTesting(!isKeyboardVisible)
        .accessibilityHidden(isKeyboardVisible)
        .animation(.easeInOut(duration: 0.2), value: isKeyboardVisible)
    }

    /// Room each page leaves under its content so the last rows clear the bar.
    private var tabBarInset: CGFloat {
        guard !isKeyboardVisible else { return 0 }
        let barTop = AppTabBarMetrics.bottomGap(safeBottom: safeBottom)
            + AppTabBarMetrics.expandedHeight(showsMiniPlayer: nowPlaying.isBarPresented)
        return max(0, barTop - safeBottom)
    }

    private func tabPage(_ page: some View) -> some View {
        page
            .toolbar(.hidden, for: .tabBar)
            // A bar, not a plain inset, so scroll views get the soft edge effect under the tab bar.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: tabBarInset)
            }
    }

    /// Tapping the selected tab again pops its navigation stack to the root, like the system tab bar.
    private func reselectTab() {
        let router = AppRouter.shared
        while router.activePathDepth > 0 {
            router.popActiveRoute()
        }
        router.tabReselectToken += 1
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
