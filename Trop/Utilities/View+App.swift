//
//  View+App.swift
//  Trop
//
//  Created by 686udjie on 13/09/2026.
//

import SwiftUI

extension View {
    /// Keeps the mini player's inline layout in sync with this scroll container:
    /// collapsing when scrolled down and restoring when back at the top.
    func miniPlayerTracksScroll() -> some View {
        modifier(MiniPlayerInlineOnScrollModifier())
    }

    /// Registers standard DetailRoute navigation. Playlist and album pages zoom
    /// out of their cover when one was marked with `coverZoomSource`.
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
    /// playlists and albums zoom; other routes leave the view unchanged.
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
        case .playlist, .album: true
        default: false
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
