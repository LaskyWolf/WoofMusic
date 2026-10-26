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
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.titleContentGap) {
            NavigationTitleView(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                content()
                    .padding(.horizontal, DesignTokens.screenHPadding)
            }
        }
        .padding(.bottom, DesignTokens.sectionGap)
    }
}
