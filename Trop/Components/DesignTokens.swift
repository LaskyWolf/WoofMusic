//
//  DesignTokens.swift
//  Trop
//
//  Created by 686udjie on 13/09/2026.
//

import SwiftUI

/// Centralized layout constants. New shared components read from here
/// instead of re-typing literals; legacy screens adopt them opportunistically.
enum DesignTokens {
    // MARK: - Spacing

    static let rowSpacing: CGFloat = 12
    static let cardInnerSpacing: CGFloat = 4
    static let menuRowSpacing: CGFloat = 14

    // Page rhythm on the tab pages. Section titles (`NavigationTitleView`) carry
    // 8 pt of padding above and below the text, so the visible gaps are
    // 24 pt between sections and 12 pt from a title to its content.

    /// Space after a section's content, before the next section title.
    static let sectionGap: CGFloat = 16
    /// Space between a section title and its content.
    static let titleContentGap: CGFloat = 4
    /// Space between cards in a carousel.
    static let cardSpacing: CGFloat = 12

    // MARK: - Padding

    static let screenHPadding: CGFloat = 16
    static let rowVPadding: CGFloat = 6

    // MARK: - Corner radii

    static let thumbRadius: CGFloat = 4
    static let cardRadius: CGFloat = 8
    static let tileRadius: CGFloat = 12
    static let sheetRadius: CGFloat = 16

    // MARK: - Sizes

    static let thumbSmall: CGFloat = 40

    // Cover art for artists, albums and playlists comes in three sizes.
    // Song rows and page headers keep their own sizes.

    /// Small covers: Keep Listening's stack and inline avatars beside a name
    /// (Go to Artist rows, Search's top artist).
    static let artSmall: CGFloat = 60
    /// Medium covers: list rows (Library list layout, Add to Playlist,
    /// Search result rows). The width of a Quick Picks card on a 393 pt
    /// phone: three columns, 8 pt apart, inside the 16 pt page margins.
    static let artMedium: CGFloat = 115
    /// Large covers: carousel cards (Home, Explore, Search, artist pages)
    /// and Library's grid layout.
    static let artLarge: CGFloat = 160
    static let heroArtwork: CGFloat = artLarge
    /// Height of the row under each tab title: Explore's search bar and the
    /// Home, Library and Search filter chips, so the pages line up. A minimum,
    /// so large Dynamic Type sizes can still grow it.
    static let controlHeight: CGFloat = 40
}
