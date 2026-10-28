//
//  ProfilePictureWebView.swift
//  Trop
//

import SwiftUI
import SwiftyTube
import WebKit

/// YouTube Studio, where the channel picture (the Settings avatar) is changed:
/// Customization → Profile → Picture. No API can change it. The default
/// website data store is the one the Google sign-in sheet filled, so Studio
/// opens already signed in.
struct ProfilePictureWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        // Same desktop agent as the sign-in sheet, so Studio serves its web editor.
        webView.customUserAgent = LoginWebviewHarvest.userAgent
        webView.allowsBackForwardNavigationGestures = true
        // The app has no channel id (account_menu returns name, handle and
        // picture only), so this opens the Studio dashboard, not the profile tab.
        if let url = URL(string: "https://studio.youtube.com/") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
