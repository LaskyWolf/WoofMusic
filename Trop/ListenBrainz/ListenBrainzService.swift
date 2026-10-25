//
//  ListenBrainzService.swift
//  Trop
//

import Foundation

enum ListenBrainzError: LocalizedError {
    case invalidToken
    case unreachable

    var errorDescription: String? {
        switch self {
        case .invalidToken: "ListenBrainz didn't accept this token. Copy it again from your ListenBrainz settings."
        case .unreachable: "Couldn't reach ListenBrainz. Check your connection and try again."
        }
    }
}

private struct ValidateResponse: Decodable {
    let valid: Bool
    let userName: String?
}

struct ListenBrainzListen: Encodable {
    struct TrackMetadata: Encodable {
        struct AdditionalInfo: Encodable {
            let mediaPlayer: String
            let submissionClient: String
            let musicService: String
            let originUrl: String
            let durationMs: Int
        }

        let artistName: String
        let trackName: String
        let releaseName: String?
        let additionalInfo: AdditionalInfo
    }

    let listenedAt: Int?
    let trackMetadata: TrackMetadata
}

/// Network calls to the ListenBrainz API.
enum ListenBrainzService {
    enum ListenType: String {
        case playingNow = "playing_now"
        case single
    }

    private struct SubmitBody: Encodable {
        let listenType: String
        let payload: [ListenBrainzListen]
    }

    /// Returns the user name the token belongs to.
    static func validate(token: String) async throws -> String {
        var request = URLRequest(url: apiURL("validate-token"))
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else {
            throw ListenBrainzError.unreachable
        }
        let reply = try? decoder.decode(ValidateResponse.self, from: data)
        guard reply?.valid == true, let name = reply?.userName else { throw ListenBrainzError.invalidToken }
        return name
    }

    /// Returns the HTTP status code, nil when the server was not reached.
    static func submit(_ listen: ListenBrainzListen, type: ListenType, token: String) async -> Int? {
        var request = URLRequest(url: apiURL("submit-listens"))
        request.httpMethod = "POST"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? encoder.encode(SubmitBody(listenType: type.rawValue, payload: [listen]))
        let reply = try? await URLSession.shared.data(for: request)
        return (reply?.1 as? HTTPURLResponse)?.statusCode
    }

    private static func apiURL(_ path: String) -> URL {
        URL(string: ListenBrainzDefaults.apiBase + path)!
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
}
