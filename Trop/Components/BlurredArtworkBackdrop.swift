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

    var body: some View {
        AsyncImageView(url: url, contentMode: .fill)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipped()
            .blur(radius: 40, opaque: true)
            .opacity(0.7)
            // Solid at the top, gone at the bottom, so the songs sit on the plain page.
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.25), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            // Reaches under the status bar and the top bar.
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
