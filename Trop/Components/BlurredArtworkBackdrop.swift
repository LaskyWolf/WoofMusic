//
//  BlurredArtworkBackdrop.swift
//  Trop
//

import SwiftUI

/// A heavily blurred copy of the artwork that fades down into the page,
/// behind the centred headers of the artist, playlist and album pages.
struct BlurredArtworkBackdrop: View {
    let url: String?
    var height: CGFloat = 400
    /// Extra height above the header, so the blur reaches under the status
    /// bar and the navigation bar, and fills the pull-down overscroll.
    static let overflow: CGFloat = 300

    var body: some View {
        AsyncImageView(url: url, contentMode: .fill)
            .frame(height: height + Self.overflow)
            .frame(maxWidth: .infinity)
            .clipped()
            .blur(radius: 40, opaque: true)
            .opacity(0.7)
            // Solid at the top, gone at the bottom, so the songs sit on the plain page.
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.55), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            .padding(.top, -Self.overflow)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    /// The spacing and blurred cover shared by the detail page headers.
    /// In landscape the side header's page-wide blur replaces the header's own.
    func detailHeaderBackdrop(url: String?) -> some View {
        modifier(DetailHeaderBackdrop(url: url))
    }

    /// On a phone in landscape (compact height) the page's header stays in a
    /// left column while the list scrolls beside it, over one blurred cover
    /// that reaches every edge. The page then leaves the header out of its list.
    func detailSideHeader<Header: View>(url: String?, @ViewBuilder header: () -> Header) -> some View {
        modifier(DetailSideHeader(url: url, header: header()))
    }
}

private struct DetailHeaderBackdrop: ViewModifier {
    let url: String?
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(alignment: .top) {
                if verticalSizeClass != .compact {
                    BlurredArtworkBackdrop(url: url)
                        // Under the notch side too, with no black bars.
                        .ignoresSafeArea(edges: .horizontal)
                }
            }
    }
}

private struct DetailSideHeader<Header: View>: ViewModifier {
    let url: String?
    let header: Header
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    func body(content: Content) -> some View {
        if verticalSizeClass == .compact {
            content
                .safeAreaInset(edge: .leading, spacing: 0) {
                    ScrollView {
                        header
                            .controlSize(.large)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .containerRelativeFrame(.horizontal) { width, _ in width * 0.45 }
                }
                .background {
                    Color.clear
                        .overlay { AsyncImageView(url: url, contentMode: .fill) }
                        .clipped()
                        .blur(radius: 40, opaque: true)
                        .opacity(0.7)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        } else {
            content
        }
    }
}
