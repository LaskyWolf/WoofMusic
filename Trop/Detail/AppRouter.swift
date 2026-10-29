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
@Observable
final class AppRouter {
    static let shared = AppRouter()

    var homePath = NavigationPath()
    var libraryPath = NavigationPath()
    var explorePath = NavigationPath()
    var searchPath = NavigationPath()
    /// The tab bar's selection, starting on the tab picked in Settings.
    var selectedTabIndex = SettingsStore.shared.defaultTab
    /// Set by the "Search" quick action; SearchView opens its field and clears it.
    var focusSearchField = false
    /// Set by Siri's search; SearchView submits it and clears it.
    var pendingSearchQuery: String?

    /// Bumped on every `open(_:)`; ContentView collapses the player so the
    /// pushed page is visible. A counter, so opening the same route twice still fires.
    private(set) var routeOpenToken = 0

    private(set) var playerExpandToken = 0

    /// Route shown as a sheet over the Big Player, which stays open.
    /// Tab NavigationStacks sit under the player's full-screen cover, so a
    /// push from there would be invisible without collapsing the player.
    var sheetRoute: DetailRoute?

    var activePathDepth: Int {
        switch selectedTabIndex {
        case 1: libraryPath.count
        case 2: explorePath.count
        case 3: searchPath.count
        default: homePath.count
        }
    }

    func popActiveRoute() {
        guard activePathDepth > 0 else { return }
        switch selectedTabIndex {
        case 1: libraryPath.removeLast()
        case 2: explorePath.removeLast()
        case 3: searchPath.removeLast()
        default: homePath.removeLast()
        }
    }

    /// Sends a tab's index when it is tapped again at its root page.
    let tabReselected = PassthroughSubject<Int, Never>()

    /// Tapping the selected tab again first pops its pushed pages; at the
    /// root it asks the tab's feed to clear its filter and scroll to the top.
    func reselectTab(_ tab: Int) {
        guard tab == selectedTabIndex else { return }
        guard activePathDepth > 0 else {
            tabReselected.send(tab)
            return
        }
        switch tab {
        case 1: libraryPath = NavigationPath()
        case 2: explorePath = NavigationPath()
        case 3: searchPath = NavigationPath()
        default: homePath = NavigationPath()
        }
    }

    func expandPlayer() {
        playerExpandToken += 1
    }

    func open(_ route: DetailRoute) {
        switch selectedTabIndex {
        case 1: libraryPath.append(route)
        case 2: explorePath.append(route)
        case 3: searchPath.append(route)
        default: homePath.append(route)
        }
        routeOpenToken += 1
    }

    /// Opens `route` in a sheet over the Big Player instead of pushing it.
    /// Doesn't bump `routeOpenToken`, so the player isn't collapsed.
    func presentSheet(_ route: DetailRoute) {
        sheetRoute = route
    }
}

/// Presents `AppRouter.sheetRoute`. Attach once, inside the Big Player.
private struct RouterSheetModifier: ViewModifier {
    @Bindable private var router = AppRouter.shared

    func body(content: Content) -> some View {
        // Registers destinations so links inside the sheet push within it.
        content.sheet(item: $router.sheetRoute) { route in
            NavigationStack {
                DetailRouteDestinationView(route: route)
                    .detailRouteDestinations()
            }
        }
    }
}

extension View {
    /// Shows routes opened with `AppRouter.presentSheet(_:)` as a sheet.
    func routerSheet() -> some View {
        modifier(RouterSheetModifier())
    }
}
