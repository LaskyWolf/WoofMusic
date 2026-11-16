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

        var request = URLRequest(url: config.service.baseURL.appendingPathComponent(endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Goog-Api-Format-Version")
        sign(&request, config: config, auth: auth, sapisid: sapisid)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw InnerTubeError.invalidResponse }
        guard (200 ... 299).contains(http.statusCode) else {
            throw InnerTubeError.httpError(statusCode: http.statusCode, data: data)
        }
        return data
    }

    /// Opens one of the addresses YouTube gives for reporting playback, as the signed-in user.
    /// They carry the sign-in, so they only go to YouTube itself and never follow a redirect.
    static func ping(_ address: String, _ values: [String: String]) async throws {
        let client = InnerTubeClient.tropShared
        let config = await client.config
        let auth = await client.currentAuth()
        guard let sapisid = auth.sapisid, !auth.cookies.isEmpty else { throw Failure.notSignedIn }
        guard var components = URLComponents(string: address), components.scheme == "https",
              let host = components.host, host == "youtube.com" || host.hasSuffix(".youtube.com") else {
            throw URLError(.badURL)
        }
        let added = values.merging(["ver": "2", "c": config.defaultClient.clientName]) { first, _ in first }
        components.queryItems = (components.queryItems ?? []).filter { added[$0.name] == nil }
            + added.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        sign(&request, config: config, auth: auth, sapisid: sapisid)
        _ = try await URLSession.shared.data(for: request, delegate: NoRedirects())
    }

    private static func sign(_ request: inout URLRequest, config: SwiftyTubeConfig, auth: AuthState, sapisid: String) {
        let web = config.defaultClient
        let origin = config.service.origin
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
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }
}
