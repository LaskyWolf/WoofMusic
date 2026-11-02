//
//  Odesli.swift
//  Trop
//

import Foundation
import Observation

/// Converts Spotify and Apple Music links to YouTube Music with Odesli, the
/// service behind song.link. The API key lives in the Keychain.
@MainActor
@Observable
final class Odesli {
    static let shared = Odesli()

    @ObservationIgnored private let store = SecureStore(service: OdesliDefaults.keychainService)
    private var key: String?

    var isConnected: Bool { key != nil }

    private init() {
        reloadForActiveProfile()
    }

    /// Each profile adds its own key.
    func reloadForActiveProfile() {
        key = (try? store.load(for: ProfileStorage.scoped(OdesliDefaults.keyAccount)))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Checks `key` with Odesli, then saves it.
    func connect(key rawKey: String) async throws {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        try await OdesliService.validate(key: key)
        try store.save(Data(key.utf8), for: ProfileStorage.scoped(OdesliDefaults.keyAccount))
        self.key = key
    }

    func disconnect() {
        try? store.delete(for: ProfileStorage.scoped(OdesliDefaults.keyAccount))
        key = nil
    }

    /// Sends `link` to Odesli and returns the same music on YouTube.
    func convert(_ link: URL) async throws -> MusicLink {
        guard let key else { throw OdesliError.notConnected }
        let response = try await OdesliService.links(for: link, key: key)
        guard let converted = MusicLink(odesliResponse: response) else { throw OdesliError.notFound }
        return converted
    }
}
