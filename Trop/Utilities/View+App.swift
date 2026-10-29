//
//  View+App.swift
//  Trop
//
//  Created by 686udjie on 13/09/2026.
//

import Combine
import SwiftUI

extension View {
    /// Keeps the mini player's inline layout in sync with this scroll container:
    /// collapsing when scrolled down and restoring when back at the top.
    func miniPlayerTracksScroll() -> some View {
        modifier(MiniPlayerInlineOnScrollModifier())
    }

    /// Tapping `tab` again at its root page runs `clearFilter` and scrolls
    /// back to the top. Apply to the root view inside the tab's main ScrollView.
    func scrollsToTopOnTabReselect(_ tab: Int, clearFilter: @escaping () -> Void = {}) -> some View {
        modifier(TabReselectModifier(tab: tab, clearFilter: clearFilter))
    }

    /// Registers standard DetailRoute navigation. Playlist, album and Library
    /// shortcut pages zoom out of their cover when one was marked with `coverZoomSource`.
    func detailRouteDestinations() -> some View {
        self.navigationDestination(for: DetailRoute.self) { route in
            DetailRouteDestinationView(route: route)
                .modifier(CoverZoomDestination(route: route))
        }
    }

    /// Set on a tab's NavigationStack: its covers and the pages it pushes share
    /// this namespace for the zoom transition.
    func coverZoomNamespace(_ namespace: Namespace.ID) -> some View {
        environment(\.coverZoomNamespace, namespace)
    }

    /// Marks this cover as the place `route`'s page zooms out of. Only
    /// playlists, albums and the Library shortcuts zoom; other routes leave the view unchanged.
    func coverZoomSource(_ route: DetailRoute?) -> some View {
        modifier(CoverZoomSource(route: route))
    }

    /// Presents a DetailRoute destination in a NavigationStack
    func detailRouteSheet(item: Binding<DetailRoute?>) -> some View {
        self.sheet(item: item) { route in
            NavigationStack {
                DetailRouteDestinationView(route: route)
            }
        }
    }

    /// Standard sheet presentation: detents plus a visible drag indicator.
    func appSheetChrome(_ detents: Set<PresentationDetent> = [.medium, .large]) -> some View {
        presentationDetents(detents)
            .presentationDragIndicator(.visible)
    }
}

extension EnvironmentValues {
    @Entry var coverZoomNamespace: Namespace.ID?
}

extension DetailRoute {
    /// Pages that open with the native zoom from their cover.
    var zoomsFromCover: Bool {
        switch self {
        case .playlist, .album, .autoPlaylist, .downloads: true
        default: false
        }
    }
}

private struct TabReselectModifier: ViewModifier {
    let tab: Int
    let clearFilter: () -> Void

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .id("tabTop")
                .onReceive(AppRouter.shared.tabReselected.filter { $0 == tab }) { _ in
                    clearFilter()
                    withAnimation(.smooth) { proxy.scrollTo("tabTop", anchor: .top) }
                }
        }
    }
}

private struct CoverZoomSource: ViewModifier {
    let route: DetailRoute?
    @Environment(\.coverZoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace, let route, route.zoomsFromCover {
            content.matchedTransitionSource(id: route, in: namespace)
        } else {
            content
        }
    }
}

private struct CoverZoomDestination: ViewModifier {
    let route: DetailRoute
    @Environment(\.coverZoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace, route.zoomsFromCover {
            content.navigationTransition(.zoom(sourceID: route, in: namespace))
        } else {
            content
        }
    }
}
