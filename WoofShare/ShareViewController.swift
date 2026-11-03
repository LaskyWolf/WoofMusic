//
//  ShareViewController.swift
//  WoofShare
//

import UIKit
import UniformTypeIdentifiers

/// Hands a shared link to Woof Music as woofmusic://open?url=<link>; the app decides what it points to.
final class ShareViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await handOver() }
    }

    private func handOver() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []
        var shared: URL?
        for provider in providers where shared == nil {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                shared = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                // Chat apps often share the link inside a sentence.
                shared = Self.firstLink(in: text)
            }
        }
        if let shared, let link = Self.appLink(for: shared) { open(link) }
        extensionContext?.completeRequest(returningItems: nil)
    }

    private static func firstLink(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return detector?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url
    }

    /// The whole link is encoded, so its own ? and & stay inside the url value.
    private static func appLink(for url: URL) -> URL? {
        guard let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "woofmusic://open?url=\(encoded)")
    }

    /// An extension can't reach UIApplication.shared, but the app object is still at the end of the responder chain.
    /// Its open method is off limits to extension code, so it's looked up by name at run time.
    // ponytail: not an official API. If iOS stops passing the link on, copy it and paste it in Woof Music's search instead.
    private func open(_ url: URL) {
        typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, let method = class_getInstanceMethod(type(of: current), selector) {
                let open = unsafeBitCast(method_getImplementation(method), to: Open.self)
                open(current, selector, url as NSURL, [:] as NSDictionary, nil)
                return
            }
            responder = current.next
        }
    }
}
