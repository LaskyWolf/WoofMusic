//
//  AppTabBar.swift
//  Trop
//

import SwiftUI

/// Sizes shared by the tab bar and the pages that leave room for it.
enum AppTabBarMetrics {
    static let item = CGSize(width: 66, height: 54)
    static let pillPadding: CGFloat = 4
    static let pillHeight = item.height + pillPadding * 2
    /// Diameter of a minimized pill; matches the mini player's height so the row lines up.
    static let circle: CGFloat = 48
    static let miniPlayerHeight: CGFloat = 48
    static let spacing: CGFloat = 8
    static let horizontalMargin: CGFloat = 20

    /// Distance from the screen's bottom edge to the bar. On Face ID iPhones the bar
    /// sits partly inside the home indicator area, like the system tab bar.
    // ponytail: eyeballed against the iOS 26 tab bar, tune on device if it looks off.
    static func bottomGap(safeBottom: CGFloat) -> CGFloat {
        safeBottom > 0 ? max(safeBottom - 14, spacing) : 12
    }

    /// Full height of the expanded bar, mini player row included.
    static func expandedHeight(showsMiniPlayer: Bool) -> CGFloat {
        pillHeight + (showsMiniPlayer ? miniPlayerHeight + spacing : 0)
    }
}

/// The app's tab bar: a Home/Library pill and an Explore pill in Liquid Glass, with
/// the mini player above them. When `isMinimized` (the page scrolled down) each pill
/// shrinks to a circle and the mini player drops into the row between them, like
/// iOS 26 Music. Left-handed mode mirrors the whole bar.
struct AppTabBar<MiniPlayer: View>: View {
    @Binding var selection: Int
    var isMinimized: Bool
    var isLeftHanded: Bool
    var showsMiniPlayer: Bool
    /// Called when the minimized Home/Library circle is tapped.
    var onRestore: () -> Void
    /// Called when the already selected tab is tapped again.
    var onReselect: (Int) -> Void
    @ViewBuilder var miniPlayer: MiniPlayer

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Home or Library, whichever was shown last: the minimized circle shows it.
    @State private var lastPrimaryTab = 0

    private typealias Metrics = AppTabBarMetrics

    private struct Item: Identifiable {
        let id: Int
        let title: String
        let icon: String
    }

    private static var home: Item { Item(id: 0, title: "Home", icon: "house.fill") }
    private static var library: Item { Item(id: 1, title: "Library", icon: "music.note.square.stack") }
    private static var explore: Item { Item(id: 3, title: "Explore", icon: "magnifyingglass") }

    var body: some View {
        GlassEffectContainer(spacing: Metrics.spacing) {
            ZStack(alignment: .bottom) {
                HStack(spacing: 0) {
                    if isLeftHanded {
                        explorePill
                        Spacer(minLength: Metrics.spacing)
                        primaryPill
                    } else {
                        primaryPill
                        Spacer(minLength: Metrics.spacing)
                        explorePill
                    }
                }

                if showsMiniPlayer {
                    // One instance that moves, so the player's zoom source never changes.
                    // With Reduce Motion the id flips instead, so the move becomes a crossfade.
                    miniPlayer
                        .frame(height: Metrics.miniPlayerHeight)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .padding(.horizontal, isMinimized ? Metrics.circle + Metrics.spacing : 0)
                        .padding(.bottom, isMinimized ? 0 : Metrics.pillHeight + Metrics.spacing)
                        .id(reduceMotion ? isMinimized : false)
                        .transition(.opacity)
                }
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.82), value: isMinimized)
        .animation(.smooth(duration: 0.3), value: showsMiniPlayer)
        .animation(.smooth(duration: 0.25), value: selection)
        .sensoryFeedback(.selection, trigger: selection)
        .onChange(of: selection, initial: true) { _, tab in
            if tab != Self.explore.id { lastPrimaryTab = tab }
        }
    }

    // MARK: - Pills

    private var primaryPill: some View {
        let items = isLeftHanded ? [Self.library, Self.home] : [Self.home, Self.library]
        return HStack(spacing: 0) {
            if isMinimized {
                let item = lastPrimaryTab == Self.library.id ? Self.library : Self.home
                circleButton(item, isSelected: selection != Self.explore.id, hint: "Shows all tabs", action: onRestore)
            } else {
                ForEach(items) { tabButton($0) }
            }
        }
        .padding(isMinimized ? 0 : Metrics.pillPadding)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var explorePill: some View {
        Group {
            if isMinimized {
                circleButton(Self.explore, isSelected: selection == Self.explore.id, hint: nil) {
                    select(Self.explore.id)
                }
            } else {
                tabButton(Self.explore)
            }
        }
        .padding(isMinimized ? 0 : Metrics.pillPadding)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    // MARK: - Buttons

    private func tabButton(_ item: Item) -> some View {
        let isSelected = selection == item.id
        return Button { select(item.id) } label: {
            VStack(spacing: 2) {
                Image(systemName: item.icon)
                    .font(.system(size: 19, weight: .medium))
                    .frame(height: 26)
                Text(item.title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(itemStyle(isSelected))
            .frame(width: Metrics.item.width, height: Metrics.item.height)
            .background {
                if isSelected {
                    Capsule().fill(.primary.opacity(0.1))
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer()
    }

    private func circleButton(_ item: Item, isSelected: Bool, hint: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: item.icon)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(itemStyle(isSelected))
                .frame(width: Metrics.circle, height: Metrics.circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityHint(hint ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer()
    }

    private func itemStyle(_ isSelected: Bool) -> AnyShapeStyle {
        isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary)
    }

    private func select(_ tab: Int) {
        if selection == tab {
            onReselect(tab)
        } else {
            selection = tab
        }
    }
}
