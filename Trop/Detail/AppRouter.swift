//
// AppRouter.swift
// Trop
//
// Created by 686udjie on 21/08/2026.
//

import Combine
import SwiftUI

/// Owns each tab's NavigationPath so overlays (e.g. the Big Player menu) can
/// push detail pages onto the regular tab navigation. Appending to a path is
/// plain state mutation, so it works even while views are transitioning —
/// unlike pub/sub events, which tabs can miss during player teardown.
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    @Published var homePath = NavigationPath()
    @Published var libraryPath = NavigationPath()
    @Published var searchPath = NavigationPath()
    @Published var selectedTabIndex = 0

    /// Last route opened from an overlay; ContentView listens to collapse the player.
    @Published private(set) var activeRoute: DetailRoute?

    @Published private(set) var playerExpandToken = 0

    /// Route shown as a sheet over the Big Player, which stays open.
    /// Tab NavigationStacks sit under the player's full-screen cover, so a
    /// push from there would be invisible without collapsing the player.
    @Published var sheetRoute: DetailRoute?

    var activePathDepth: Int {
        switch selectedTabIndex {
        case 1: libraryPath.count
        case 3: searchPath.count
        default: homePath.count
        }
    }

    func popActiveRoute() {
        guard activePathDepth > 0 else { return }
        switch selectedTabIndex {
        case 1: libraryPath.removeLast()
        case 3: searchPath.removeLast()
        default: homePath.removeLast()
        }
    }

    func expandPlayer() {
        playerExpandToken += 1
    }

    func open(_ route: DetailRoute) {
        switch selectedTabIndex {
        case 1: libraryPath.append(route)
        case 3: searchPath.append(route)
        default: homePath.append(route)
        }
        activeRoute = route
    }

    /// Opens `route` in a sheet over the Big Player instead of pushing it.
    /// Doesn't touch `activeRoute`, so the player isn't collapsed.
    func presentSheet(_ route: DetailRoute) {
        sheetRoute = route
    }
}

/// Presents `AppRouter.sheetRoute`. Attach once, inside the Big Player.
private struct RouterSheetModifier: ViewModifier {
    @ObservedObject private var router = AppRouter.shared

    func body(content: Content) -> some View {
        // Registers destinations so links inside the sheet push within it.
        content.sheet(item: $router.sheetRoute) { route in
            NavigationStack {
                DetailRouteDestinationView(route: route)
                    .detailRouteDestinations()
            }
            .environment(\.isInRouterSheet, true)
        }
    }
}

extension EnvironmentValues {
    /// True for pages shown by `routerSheet()`, so custom top bars can clear
    /// the sheet's rounded corners.
    @Entry var isInRouterSheet = false
}

extension View {
    /// Shows routes opened with `AppRouter.presentSheet(_:)` as a sheet.
    func routerSheet() -> some View {
        modifier(RouterSheetModifier())
    }
}
