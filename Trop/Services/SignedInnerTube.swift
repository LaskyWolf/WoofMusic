//
//  SignedInnerTube.swift
//  Trop
//

import Foundation

/// POSTs to a YouTube Music endpoint as the signed-in user. SwiftyTube keeps
/// its request builder internal, so endpoints it doesn't wrap go through here.
enum SignedInnerTube {
    enum Failure: Error { case notSignedIn }

    @discardableResult
    static func post(_ endpoint: String, _ payload: [String: Any]) async throws -> Data {
        let client = InnerTubeClient.tropShared
        let config = await client.config
        let auth = await client.currentAuth()
        guard let sapisid = auth.sapisid, !auth.cookies.isEmpty else { throw Failure.notSignedIn }

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
        return data
    }
}
