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
