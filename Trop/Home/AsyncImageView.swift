//
//  AsyncImageView.swift
//  Trop
//
//  Created by 686udjie on 01/07/2026.
//

import Nuke
import SwiftUI

struct AsyncImageView: View {
    let url: String?
    var contentMode: ContentMode = .fill
    @Environment(\.displayScale) private var displayScale
    @State private var loadedImage: UIImage?

    var body: some View {
        GeometryReader { geometry in
            let request = imageRequest(targetSize: geometry.size)
            Group {
                // A memory-cache hit shows at once, so scrolling back doesn't flash the placeholder.
                if let image = request.flatMap({ Self.cachedImage(for: $0) }) ?? loadedImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
                        .clipped()
                } else {
                    placeholderView
                }
            }
            .task(id: url) {
                await loadImage(request)
            }
        }
    }

    private static func cachedImage(for request: ImageRequest) -> UIImage? {
        ImagePipeline.shared.cache.cachedImage(for: request, caches: .memory)?.image
    }

    private func imageRequest(targetSize: CGSize) -> ImageRequest? {
        guard let urlString = url else { return nil }
        let scale = displayScale
        // Zero-size layout passes would otherwise make degenerate cache requests.
        let fallbackPixels: CGFloat = 120 * scale
        let displaySize = targetSize.width > 0 && targetSize.height > 0
            ? CGSize(width: targetSize.width * scale, height: targetSize.height * scale)
            : CGSize(width: fallbackPixels, height: fallbackPixels)
        let imageURL: URL
        if let file = LocalPlaylistCover.fileURL(for: urlString) {
            // Each saved cover gets a new file name, so caching by URL never goes stale.
            imageURL = file
        } else {
            // Request the ladder rung covering this surface (BitChord-style),
            // so rows, cards and headers each share one cache entry.
            let rung = ArtworkURLs.rung(for: max(displaySize.width, displaySize.height))
            guard let remote = URL(string: normalizeThumbnailURL(urlString, pixels: rung)) else { return nil }
            imageURL = remote
        }
        guard contentMode == .fill else { return ImageRequest(url: imageURL) }
        return ImageRequest(
            url: imageURL,
            processors: [.resize(size: displaySize, unit: .pixels, contentMode: .aspectFill)]
        )
    }

    private func loadImage(_ request: ImageRequest?) async {
        guard let request else {
            loadedImage = nil
            return
        }
        if let cached = Self.cachedImage(for: request) {
            loadedImage = cached
            return
        }
        do {
            let image = try await ImagePipeline.shared.image(for: request)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                loadedImage = image
            }
        } catch {
            guard !Task.isCancelled else { return }
            loadedImage = nil
        }
    }

    private var placeholderView: some View {
        Image(systemName: "music.note")
            .resizable()
            .scaledToFit()
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGray6))
    }
}

// Compiled once: `normalizeThumbnailURL` runs on every image render.
private let thumbnailCropSuffixRegex = try? NSRegularExpression(pattern: "(?<=[sh]\\d+)-c")
private let thumbnailSizeRegex = try? NSRegularExpression(pattern: "w(\\d+)-h(\\d+)")

private func normalizeThumbnailURL(_ urlString: String, pixels: Int) -> String {
    var url = urlString

    if let regex = thumbnailCropSuffixRegex {
        url = regex.stringByReplacingMatches(in: url, range: NSRange(url.startIndex..., in: url), withTemplate: "")
    }

    if url.contains("googleusercontent.com") || url.contains("ggpht.com") {
        if let match = thumbnailSizeRegex,
           let result = match.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
           let wRange = Range(result.range(at: 1), in: url),
           let hRange = Range(result.range(at: 2), in: url),
           let w = Int(url[wRange]),
           let h = Int(url[hRange]) {
            let size = "w\(pixels)-h\(pixels)"
            if size != "w\(w)-h\(h)" {
                url = url.replacingOccurrences(of: "w\(w)-h\(h)", with: size)
            }
        } else if let base = url.split(separator: "=").first {
            // Bare CDN URL with no size params: pin an explicit size instead
            // of trusting the server default.
            url = String(base) + "=w\(pixels)-h\(pixels)"
        }
    }

    return url
}
