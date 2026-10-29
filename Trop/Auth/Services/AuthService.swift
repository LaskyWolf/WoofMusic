//
// AuthService.swift
// Trop
//
// Created by 686udjie on 29/06/2026.
//

import Foundation
import WebKit

// Acts as the session and auth entry point for the rest of the app
actor AuthService {
    static let shared = AuthService()

    private let innerTube = InnerTubeClient.tropShared
    private let cookieStore = CookieStore()

// Imports a raw cookie string (e.g. from browser export) and persists it
  func importSession(from cookieString: String, dataSyncId: String? = nil) async throws {
    let auth = try SessionImporter.importSession(from: cookieString, dataSyncId: dataSyncId)
    await cookieStore.save(
        cookies: auth.cookies,
        sapisid: auth.sapisid,
        visitorData: auth.visitorData,
        dataSyncId: auth.dataSyncId
    )

    await innerTube.loadState(from: cookieStore)
  }

    // Re-hydrates InnerTube from whatever is currently saved in the CookieStore
    func loadPersistedSession() async {
        await innerTube.loadState(from: cookieStore)
    }

// Wipes cookies and SAPISID from both CookieStore and the running InnerTube instance
  func logout() async {
    await cookieStore.clear()
    await innerTube.loadState(from: cookieStore)
    await Self.clearGoogleWebsiteData()
  }

    @MainActor
    private static func clearGoogleWebsiteData() async {
        let store = WKWebsiteDataStore.default()
        let roots = ["google.com", "youtube.com"]
        for cookie in await store.httpCookieStore.allCookies() {
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if roots.contains(where: { domain == $0 || domain.hasSuffix("." + $0) }) {
                await store.httpCookieStore.deleteCookie(cookie)
            }
        }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types).filter { record in
            let domain = record.displayName.lowercased()
            return roots.contains { domain == $0 || domain.hasSuffix("." + $0) }
        }
        await store.removeData(ofTypes: types, for: records)
    }
}
