//
// KeychainStorage.swift
// Trop
//
// Created by 686udjie on 29/06/2026.
//

import Foundation

// Wraps iOS Security framework for encrypted Codable persistence
actor KeychainStorage {
  static let sessionKey = "sessionState"
  static let profilesKey = "profiles"

  private let store = SecureStore(service: "com.trop.app")

  nonisolated func loadSessionState() async throws -> SessionState {
    try loadDataDecoded(for: KeychainStorage.sessionKey)
  }

  nonisolated func loadProfiles() -> [SavedProfile] {
    (try? loadDataDecoded(for: KeychainStorage.profilesKey)) ?? []
  }

  // Saves a Codable value to Keychain, replacing any existing entry for the key
  nonisolated func save<T: Codable>(_ value: T, for key: String) throws {
    try store.save(try JSONEncoder().encode(value), for: key)
  }

  private nonisolated func loadDataDecoded<T: Codable>(for key: String) throws -> T {
    try JSONDecoder().decode(T.self, from: try store.load(for: key))
  }

  // Removes all stored session data from Keychain
  nonisolated func clear() throws {
    try store.delete(for: KeychainStorage.sessionKey)
  }
}
