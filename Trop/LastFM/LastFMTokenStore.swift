//
//  LastFMTokenStore.swift
//  Trop
//
//  Created by 686udjie on 31/08/2026.
//

import Foundation

final class LastFMTokenStore: @unchecked Sendable {
    static let shared = LastFMTokenStore()

    private let store = SecureStore(service: "com.trop.lastfm.token")
    private let sessionKeyAccount = "sessionKey"
    private let usernameAccount = "username"
    private let subscriberAccount = "subscriber"

    private let queue = DispatchQueue(label: "com.trop.LastFMTokenStore", attributes: .concurrent)

    private var cachedSessionKey: String?
    private var cachedUsername: String?

    private init() {
        if let legacy = UserDefaults.standard.string(forKey: LastFMDefaults.sessionKeyKey), !legacy.isEmpty {
            cachedSessionKey = legacy
            do {
                try saveString(legacy, for: sessionKeyAccount)
                // Delete the plain copy only once the Keychain holds it.
                UserDefaults.standard.removeObject(forKey: LastFMDefaults.sessionKeyKey)
            } catch {
                Log.lastfm.error("Could not migrate Last.fm session to Keychain; will retry on next launch")
            }
        }
    }

    // Credentials are read only from memory or Keychain.
    func retrieveSessionKey() -> String? {
        queue.sync {
            if let cached = cachedSessionKey { return cached.isEmpty ? nil : cached }
            let val: String? = loadString(for: sessionKeyAccount)
            cachedSessionKey = val
            return val
        }
    }

    func retrieveUsername() -> String? {
        queue.sync {
            if let cached = cachedUsername { return cached.isEmpty ? nil : cached }
            if let fromDefaults = UserDefaults.standard.string(forKey: LastFMDefaults.usernameKey),
               !fromDefaults.isEmpty {
                cachedUsername = fromDefaults
                return fromDefaults
            }
            let val: String? = loadString(for: usernameAccount)
            cachedUsername = val
            return val
        }
    }

    func store(sessionKey: String, username: String) throws {
        try queue.sync(flags: .barrier) {
            try saveString(sessionKey, for: sessionKeyAccount)
            self.cachedSessionKey = sessionKey
            self.cachedUsername = username
            UserDefaults.standard.removeObject(forKey: LastFMDefaults.sessionKeyKey)
            UserDefaults.standard.set(username, forKey: LastFMDefaults.usernameKey)
        }
    }

    func clear() {
        queue.sync(flags: .barrier) {
            delete(for: sessionKeyAccount)
            delete(for: usernameAccount)
            delete(for: subscriberAccount)
            cachedSessionKey = nil
            cachedUsername = nil
            UserDefaults.standard.removeObject(forKey: LastFMDefaults.sessionKeyKey)
            UserDefaults.standard.removeObject(forKey: LastFMDefaults.usernameKey)
        }
    }

    // MARK: - Keychain primitives

    private func saveString(_ value: String, for key: String) throws {
        try store.save(Data(value.utf8), for: key)
    }

    private func loadString(for key: String) -> String? {
        guard let data = try? store.load(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func delete(for key: String) {
        try? store.delete(for: key)
    }
}
