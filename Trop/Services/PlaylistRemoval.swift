//
//  PlaylistRemoval.swift
//  Trop
//

import Foundation

/// Takes a playlist out of the library. A synced playlist is deleted on
/// YouTube Music when you own it and un-saved when someone else does, then
/// forgotten locally. A local playlist is only forgotten locally.
enum PlaylistRemoval {
    enum RemovalError: LocalizedError {
        case notSignedIn

        var errorDescription: String? { "Sign in to remove a synced playlist." }
    }

    static func remove(playlistId: String, owned: Bool) async throws {
        let saved = try? await DatabaseService.shared.fetchOne(PlaylistEntity.self, key: playlistId)
        if saved?.browseId != nil {
            // The library keeps the browse id (VL…); the endpoints want the bare playlist id.
            let bareId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
            let delete = (endpoint: "playlist/delete", body: ["playlistId": bareId] as [String: Any])
            let unsave = (endpoint: "like/removelike", body: ["target": ["playlistId": bareId]] as [String: Any])
            // The ownership flag can be stale, so a rejected call falls back to the other one.
            try await send(owned ? [delete, unsave] : [unsave, delete])
        }
        try await SyncBridge.store.deletePlaylistRows(playlistId: playlistId)
    }

    private static func send(_ calls: [(endpoint: String, body: [String: Any])]) async throws {
        var firstRejection: Error?
        for call in calls {
            do {
                try await post(call.endpoint, call.body)
                return
            } catch InnerTubeError.httpError(let code, let data) where (400 ..< 500).contains(code) {
                firstRejection = firstRejection ?? InnerTubeError.httpError(statusCode: code, data: data)
            }
        }
        throw firstRejection ?? InnerTubeError.invalidResponse
    }

    private static func post(_ endpoint: String, _ payload: [String: Any]) async throws {
        let client = InnerTubeClient.tropShared
        let config = await client.config
        let auth = await client.currentAuth()
        guard let sapisid = auth.sapisid, !auth.cookies.isEmpty else { throw RemovalError.notSignedIn }

        let web = config.defaultClient
        var clientContext: [String: Any] = [
            "clientName": web.clientName,
            "clientVersion": web.clientVersion,
            "gl": config.defaultLocale.gl,
            "hl": config.defaultLocale.hl
        ]
        if let visitorData = auth.visitorData { clientContext["visitorData"] = visitorData }
        var user: [String: Any] = ["lockedSafetyMode": false]
        if let dataSyncId = auth.dataSyncId { user["onBehalfOfUser"] = dataSyncId }

        var body = payload
        body["context"] = ["client": clientContext, "user": user]

        let origin = config.service.origin
        var request = URLRequest(url: config.service.baseURL.appendingPathComponent(endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Goog-Api-Format-Version")
        request.setValue("\(web.clientId)", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(web.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(origin, forHTTPHeaderField: "X-Origin")
        request.setValue(origin + "/", forHTTPHeaderField: "Referer")
        request.setValue(web.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(config.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue(auth.cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        request.setValue(SAPISIDAuth.authorizationHeader(sapisid: sapisid, origin: origin), forHTTPHeaderField: "Authorization")
        if let visitorData = auth.visitorData {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw InnerTubeError.invalidResponse }
        guard (200 ... 299).contains(http.statusCode) else {
            throw InnerTubeError.httpError(statusCode: http.statusCode, data: data)
        }
    }
}
