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
    @State private var playerExpansion: CGFloat = 0
    @State private var playerDragOffset: CGFloat = 0
    @State private var miniPlayerFrames: [Int: CGRect] = [:]
    @State private var miniPlayerFrame: CGRect = .zero
    @State private var transitionSourceFrame: CGRect = .zero
    @State private var isClosingPlayer = false
    @State private var pendingPlayerExpansion = false
    @State private var scrollState = MiniPlayerScrollState()

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "music.note.house.fill", value: 0) {
                playerContent(tab: 0) { HomeScreenView() }
            }

            Tab("Library", systemImage: "music.note.square.stack", value: 1) {
                playerContent(tab: 1) { LibraryView() }
            }

            Tab("Explore", systemImage: "flame", value: 2) {
                playerContent(tab: 2) { ExploreView() }
            }

            Tab("Search", systemImage: "magnifyingglass", value: 3, role: .search) {
                playerContent(tab: 3) { SearchView() }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
            .background {
                backgroundLayer
            }
            .environment(scrollState)
            .accessibilityHidden(isExpanded)
            .overlay {
                GeometryReader { proxy in
                    if nowPlaying.isBarPresented, !miniPlayerFrame.isEmpty {
                        let insets = proxy.safeAreaInsets
                        let bounds = CGRect(x: 0, y: 0, width: proxy.size.width,
                                            height: proxy.size.height + insets.top + insets.bottom)
                        let origin = proxy.frame(in: .global).origin
                        let sourceFrame = isExpanded ? transitionSourceFrame : miniPlayerFrame
                        let source = sourceFrame.offsetBy(dx: -origin.x, dy: -origin.y + insets.top)
                        ZStack {
                            if isExpanded {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture {}
                                    .accessibilityHidden(true)
                            }
                            PlayerPresentation(
                                expansion: playerExpansion,
                                dragOffset: playerDragOffset,
                                geometry: PlayerTransitionGeometry(expanded: bounds, collapsed: source),
                                safeAreaInsets: insets,
                                isExpanded: isExpanded,
                                onExpand: expandPlayer,
                                onCollapse: { collapsePlayer() },
                                onDragChanged: { offset in
                                    guard !isClosingPlayer else { return }
                                    playerDragOffset = reduceMotion ? 0 : max(0, offset)
                                },
                                onDragEnded: { distance, predicted, velocity in
                                    if PlayerTransitionGeometry.shouldDismiss(
                                        distance: distance, predictedDistance: predicted, height: bounds.height
                                    ) {
                                        let remaining = max(1, source.minY - distance)
                                        collapsePlayer(velocity: min(4, max(0, velocity / remaining)))
                                    } else {
                                        cancelPlayerDrag()
                                    }
                                },
                                onDragCancelled: cancelPlayerDrag
                            )
                            .environment(scrollState)
                            .onAppear {
                                if isExpanded {
                                    withAnimation(playerSpring()) { playerExpansion = 1 }
                                }
                            }
                            .onChange(of: isExpanded) { _, expanded in
                                if expanded {
                                    withAnimation(playerSpring()) { playerExpansion = 1 }
                                }
                            }
                        }
                    }
                }
                .ignoresSafeArea(.keyboard)
            }
        .onAppear { AppRouter.shared.selectedTabIndex = selectedTab }
        .onChange(of: selectedTab) { _, newValue in
            AppRouter.shared.selectedTabIndex = newValue
            if let frame = miniPlayerFrames[newValue] { miniPlayerFrame = frame }
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

    /// Reserves space above the native tab bar without creating another glass background.
    private func playerContent<Content: View>(tab: Int, @ViewBuilder content: () -> Content) -> some View {
        content()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if nowPlaying.isBarPresented {
                    Color.clear
                        .frame(height: 48)
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .global)
                        } action: { frame in
                            guard !frame.isEmpty else { return }
                            miniPlayerFrames[tab] = frame
                            guard selectedTab == tab else { return }
                            miniPlayerFrame = frame
                            if pendingPlayerExpansion { expandPlayer() }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    private func playerSpring(velocity: CGFloat = 0) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15)
            : .interpolatingSpring(mass: 1, stiffness: 300, damping: 30, initialVelocity: Double(velocity))
    }

    private func expandPlayer() {
        guard !isExpanded else { return }
        guard !miniPlayerFrame.isEmpty else {
            pendingPlayerExpansion = true
            return
        }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        pendingPlayerExpansion = false
        transitionSourceFrame = miniPlayerFrame
        playerExpansion = 0
        playerDragOffset = 0
        isClosingPlayer = false
        isExpanded = true
    }

    private func collapsePlayer(velocity: CGFloat = 0) {
        pendingPlayerExpansion = false
        guard isExpanded, !isClosingPlayer else { return }
        transitionSourceFrame = miniPlayerFrame
        isClosingPlayer = true
        withAnimation(playerSpring(velocity: velocity), completionCriteria: .removed) {
            playerExpansion = 0
            playerDragOffset = 0
        } completion: {
            isExpanded = false
            isClosingPlayer = false
        }
    }

    private func cancelPlayerDrag() {
        guard !isClosingPlayer, playerDragOffset > 0 else { return }
        withAnimation(playerSpring()) { playerDragOffset = 0 }
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
