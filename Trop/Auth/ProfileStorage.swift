//
//  ProfileStorage.swift
//  Trop
//

import Foundation

/// Where each profile keeps its database, downloads and last sync date.
/// The first profile keeps the app's original paths, so its data never moves.
enum ProfileStorage {
    /// The original paths. Other profiles use a UUID.
    static let original = ""

    private static let activeKey = "profile.activeStorage"
    private static let ownersKey = "profile.storageOwners"

    static var active: String {
        UserDefaults.standard.string(forKey: activeKey) ?? original
    }

    static func activate(_ storage: String) {
        UserDefaults.standard.set(storage, forKey: activeKey)
    }

    /// The account's storage. It stays reserved after a sign-out, so signing
    /// back in finds the same library and downloads.
    static func claim(for accountId: String) -> String {
        selfCheck()
        var owners = UserDefaults.standard.dictionary(forKey: ownersKey) as? [String: String] ?? [:]
        let storage = storage(for: accountId, owners: owners, active: active, newStorage: UUID().uuidString)
        owners[accountId] = storage
        UserDefaults.standard.set(owners, forKey: ownersKey)
        return storage
    }

    /// A new account takes the active storage if no account owns it: that is
    /// the data of the app before its first sign-in.
    private static func storage(for accountId: String, owners: [String: String], active: String, newStorage: String) -> String {
        if let owned = owners[accountId] { return owned }
        return owners.values.contains(active) ? newStorage : active
    }

    static var databaseURL: URL {
        get throws {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            guard active != original else { return base.appendingPathComponent("trop.sqlite") }
            let folder = base.appendingPathComponent("Profiles/\(active)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder.appendingPathComponent("trop.sqlite")
        }
    }

    static var downloadsDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        guard active != original else { return base.appendingPathComponent("Downloads", isDirectory: true) }
        return base.appendingPathComponent("Profiles/\(active)/Downloads", isDirectory: true)
    }

    /// Holds what a profile keeps outside its database: last sync date, search
    /// history, episode positions and the names of its linked services.
    static var defaults: UserDefaults {
        guard active != original else { return .standard }
        return UserDefaults(suiteName: "profile.\(active)") ?? .standard
    }

    /// A Keychain account name of the active profile. The first profile keeps
    /// the plain name, so what it already saved stays its own.
    static func scoped(_ account: String) -> String {
        active == original ? account : "\(active).\(account)"
    }

    static func isClaimed(_ accountId: String) -> Bool {
        (UserDefaults.standard.dictionary(forKey: ownersKey) as? [String: String])?[accountId] != nil
    }

    /// Deletes a signed-out account's storage. Only for an account with no
    /// identity to sign back in with, which could never find it again.
    static func discard(accountId: String) {
        var owners = UserDefaults.standard.dictionary(forKey: ownersKey) as? [String: String] ?? [:]
        guard let storage = owners[accountId], storage != active, storage != original else { return }
        owners[accountId] = nil
        UserDefaults.standard.set(owners, forKey: ownersKey)
        let folders: [FileManager.SearchPathDirectory] = [.applicationSupportDirectory, .documentDirectory]
        for folder in folders {
            guard let base = FileManager.default.urls(for: folder, in: .userDomainMask).first else { continue }
            try? FileManager.default.removeItem(at: base.appendingPathComponent("Profiles/\(storage)", isDirectory: true))
        }
        UserDefaults.standard.removePersistentDomain(forName: "profile.\(storage)")
    }

    private static func selfCheck() {
        assert(storage(for: "a", owners: [:], active: original, newStorage: "new") == original)
        assert(storage(for: "b", owners: ["a": original], active: original, newStorage: "new") == "new")
        assert(storage(for: "a", owners: ["a": original, "b": "new"], active: "new", newStorage: "other") == original)
    }
}
