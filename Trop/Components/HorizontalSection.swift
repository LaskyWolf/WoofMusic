//
//  HorizontalSection.swift
//  Trop
//
//  Created by 686udjie on 2/07/2026.
//

import SwiftUI

/// Titled horizontal-scroll section shared by the Home and Explore tabs:
/// a `NavigationTitleView` header over horizontally scrolling content with
/// standard edge padding and the shared section gap below.
struct HorizontalSection<Content: View>: View {
    let title: String
    /// Snaps to the children of the content's `scrollTargetLayout()`. The
    /// children bring their own side insets, so the edge padding is dropped.
    var snapsToItems = false
    /// Off for cards whose glow reaches past the row, like Explore's new releases.
    var clipsContent = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.titleContentGap) {
            NavigationTitleView(title: title)
            let scroll = ScrollView(.horizontal, showsIndicators: false) {
                content()
                    .padding(.horizontal, snapsToItems ? 0 : DesignTokens.screenHPadding)
            }
            .scrollClipDisabled(!clipsContent)
            if snapsToItems {
                scroll.scrollTargetBehavior(.viewAligned)
            } else {
                scroll
            }
        }
        .padding(.bottom, DesignTokens.sectionGap)
    }
}
