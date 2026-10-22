//
//  Share.swift
//  Trop
//
//  Created by 686udjie on 2/07/2026.
//

import UIKit

/// Presents a `UIActivityViewController` above whatever is on screen. Consolidates
/// the window lookup used by every share button.
/// Pass `afterDismiss` when the sheet must close first (presentation is then
/// deferred slightly so the dismiss animation wins the window).
@MainActor
func presentShareSheet(items: [Any], afterDismiss dismiss: (() -> Void)? = nil) {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
          let window = scene.windows.first(where: { $0.isKeyWindow }),
          let root = window.rootViewController else { return }
    let present = {
        // Present from the top-most screen: the root is usually already
        // presenting the full player, and UIKit silently refuses a second
        // presentation from the same controller.
        var top = root
        while let next = top.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        top.present(
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
