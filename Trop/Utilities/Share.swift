//
//  Share.swift
//  Trop
//
//  Created by 686udjie on 2/07/2026.
//

import UIKit

/// The top-most screen, for presenting above whatever is showing: the root is
/// usually already presenting the full player, and UIKit silently refuses a
/// second presentation from the same controller.
@MainActor
func topViewController() -> UIViewController? {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
          let window = scene.windows.first(where: { $0.isKeyWindow }),
          var top = window.rootViewController else { return nil }
    while let next = top.presentedViewController, !next.isBeingDismissed {
        top = next
    }
    return top
}

/// Presents a `UIActivityViewController` above whatever is on screen.
/// Pass `afterDismiss` when the sheet must close first (presentation is then
/// deferred slightly so the dismiss animation wins the window).
@MainActor
func presentShareSheet(items: [Any], afterDismiss dismiss: (() -> Void)? = nil) {
    let present = {
        topViewController()?.present(
            UIActivityViewController(activityItems: items, applicationActivities: nil),
            animated: true
        )
    }
    if let dismiss {
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            present()
        }
    } else {
        present()
    }
}

extension URL {
    static func playlistShareURL(id: String) -> URL? {
        URL(string: "https://music.youtube.com/playlist?list=\(id)")
    }
}
