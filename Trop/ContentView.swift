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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nowPlaying = NowPlaying.shared
    @State private var selectedTab = SettingsStore.shared.defaultTab
    @State private var isExpanded = false
    @State private var playerDismissalBounce = 0
    @State private var scrollState = MiniPlayerScrollState()
    @Namespace private var playerTransition

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "music.note.house.fill", value: 0) {
                HomeScreenView()
            }

            Tab("Library", systemImage: "music.note.square.stack", value: 1) {
                LibraryView()
            }

            Tab("Explore", systemImage: "flame", value: 2) {
                ExploreView()
            }

            Tab("Search", systemImage: "magnifyingglass", value: 3, role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
            .tabViewBottomAccessory(isEnabled: nowPlaying.isBarPresented) {
                MiniPlayerBarView(onExpand: {
                    // Dismiss the keyboard before expanding the player so the reveal is visible on the first tap.
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                    isExpanded = true
                })
                .matchedTransitionSource(id: "nowPlaying", in: playerTransition) { source in
                    source.clipShape(RoundedRectangle(cornerRadius: 24))
                }
                .phaseAnimator([CGFloat(1), 1.035, 1], trigger: playerDismissalBounce) { content, scale in
                    content.scaleEffect(x: 1, y: reduceMotion ? 1 : scale)
                } animation: { _ in
                    .spring(duration: 0.2, bounce: 0.1)
                }
            }
            .background {
                backgroundLayer
            }
            .fullScreenCover(isPresented: $isExpanded, onDismiss: {
                if !reduceMotion { playerDismissalBounce += 1 }
            }) {
                FullPlayerView(onCollapse: { isExpanded = false })
                    .navigationTransition(.zoom(sourceID: "nowPlaying", in: playerTransition))
                    .environment(scrollState)
            }
            .environment(scrollState)
        .onAppear { AppRouter.shared.selectedTabIndex = selectedTab }
        .onChange(of: selectedTab) { _, newValue in
            AppRouter.shared.selectedTabIndex = newValue
        }
        .onReceive(AppRouter.shared.$activeRoute) { route in
            // A detail page was opened from an overlay: collapse the player so
            // the pushed page is visible underneath.
            if route != nil {
                isExpanded = false
            }
        }
        .onReceive(AppRouter.shared.$playerExpandToken.dropFirst()) { _ in
            isExpanded = true
        }
        .simultaneousGesture(backSwipeGesture)
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
