//
//  NowPlayingShared.swift
//  Compiled into both targets: the app (Trop) and the widget extension (WoofWidgets).
//

import AppIntents
import Foundation
import Security
import UIKit

/// A song as the widgets show it.
struct WidgetSong: Codable, Hashable, Identifiable {
    var videoId: String
    var title: String
    var artist: String
    /// Small JPEG cover.
    var artwork: Data?
    var isPinned = false
    /// The app's encoded song, so an intent can play it; the widget never reads it.
    var payload: Data?

    var id: String { videoId }
}

/// What the Turntable widget shows about the current song.
struct NowPlayingState: Codable, Hashable {
    var title: String
    var artist: String
    var isPlaying: Bool
    var isPodcast: Bool
    /// Dominant artwork color as 0xRRGGBB.
    var tint: UInt32?
    /// JPEG cover.
    var artwork: Data?
    var isLiked = false
    var isShuffleOn = false
    var isRepeatOn = false
    /// The next songs in the queue, for the large size.
    var upNext: [WidgetSong] = []
}

/// The Quick Picks widget: pinned songs first, then the picks.
struct QuickPicksSnapshot: Codable, Hashable {
    var songs: [WidgetSong]
    /// False when Quick Picks are off in Settings.
    var isEnabled = true
}

/// The Woof Stats widget: this month so far, from the same data as Woof Recap.
struct StatsSnapshot: Codable, Hashable {
    struct Artist: Codable, Hashable {
        var name: String
        var minutes: Int
        var artwork: Data?
    }

    struct Badge: Codable, Hashable {
        var emoji: String
        var name: String
        var isUnlocked: Bool
        /// Light and dark gem colours as 0xRRGGBB.
        var colors: [UInt32]
    }

    var monthName: String
    var minutes: Int
    var weeklyMinutes: [Int]
    var streakDays: Int
    var streakGoal: Int
    var topSong: WidgetSong?
    var topSongPlays: Int
    var topArtists: [Artist]
    var badges: [Badge]
    /// False when play history is off in Settings: nothing is counted.
    var isTracking = true
}

/// Widget kinds, for reloading one widget's timeline.
enum WidgetKind {
    static let nowPlaying = "NowPlaying"
    static let quickPicks = "QuickPicks"
    static let stats = "WoofStats"
}

/// Links the widgets open in the app.
enum WidgetLink {
    static let scheme = "woofmusic"
    static let player = URL(string: "woofmusic://player")
    static let home = URL(string: "woofmusic://home")
    static let recap = URL(string: "woofmusic://recap")
}

/// A "still here" note each side leaves for the other, so a widget can tell
/// "the app never wrote anything" from "the app's data can't reach me", and the
/// app's diagnostics can tell when a widget last read the store.
struct WidgetPing: Codable, Hashable {
    var date: Date
    var build: String
}

/// JSON files in the App Group container, written by the app and read by the
/// widgets. Signing tools that use a shared certificate usually drop the App
/// Group; then the files go to a Keychain group the team shares, or failing
/// that to named pasteboards, which need no entitlement at all.
enum WidgetStore {
    static let nowPlayingFile = "nowplaying.json"
    static let quickPicksFile = "quickpicks.json"
    static let statsFile = "stats.json"
    static let appPingFile = "app-ping.json"
    static let widgetPingFile = "widget-ping.json"

    enum Backend: String {
        case appGroup = "App Group"
        case keychain = "Keychain"
        case pasteboard = "Pasteboard"
    }

    /// The first place this signature allows; both sides pick the same one when signed alike.
    static var backend: Backend {
        if groupId != nil { return .appGroup }
        if SharedKeychain.group != nil { return .keychain }
        return .pasteboard
    }

    private static let extensionSuffix = ".WoofWidgets"

    /// The App Group in use: "group." + the app's bundle id (read at runtime, so it
    /// follows a renamed bundle id), else the first of the provisioning profile's
    /// own groups, which some signing services hand out in place of the app's.
    /// Each candidate is tried with a write, so a container the signature doesn't cover is skipped.
    static let groupId: String? = {
        var candidates: [String] = []
        if var id = Bundle.main.bundleIdentifier {
            if id.hasSuffix(extensionSuffix) { id.removeLast(extensionSuffix.count) }
            candidates.append("group." + id)
        }
        // Sorted, so the app and the widgets settle on the same one.
        candidates += ProvisioningProfile.appGroups.sorted()
        return candidates.first { group in
            guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return false }
            return (try? Data().write(to: url.appendingPathComponent(".probe"))) != nil
        }
    }()

    static func fileURL(_ name: String) -> URL? {
        guard let groupId else { return nil }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupId)?
            .appendingPathComponent(name)
    }

    static func read<Value: Decodable>(_ type: Value.Type, from name: String) -> Value? {
        let data: Data? = switch backend {
        case .appGroup: fileURL(name).flatMap { try? Data(contentsOf: $0) }
        case .keychain: SharedKeychain.read(name)
        case .pasteboard: SharedPasteboard.read(name)
        }
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Returns false when the write failed.
    @discardableResult
    static func write<Value: Encodable>(_ value: Value, to name: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        switch backend {
        case .appGroup:
            guard let url = fileURL(name) else { return false }
            return (try? data.write(to: url, options: .atomic)) != nil
        case .keychain:
            return SharedKeychain.write(data, for: name)
        case .pasteboard:
            return SharedPasteboard.write(data, for: name)
        }
    }

    /// The running build, for the pings.
    static var build: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        return "\(version) (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}

/// The plist inside the app's embedded.mobileprovision (a signed CMS wrapper
/// around it): what the signing tool's profile allows.
enum ProvisioningProfile {
    static let contents: [String: Any]? = {
        // A widget reads the copy in the app around it: PlugIns/<widget>.appex sits two levels down.
        let appURL = Bundle.main.bundleURL.pathExtension == "appex"
            ? Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            : Bundle.main.bundleURL
        guard let data = try? Data(contentsOf: appURL.appendingPathComponent("embedded.mobileprovision")),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        return try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
    }()

    static var entitlements: [String: Any] {
        contents?["Entitlements"] as? [String: Any] ?? [:]
    }

    static var appGroups: [String] {
        entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }
}

/// Named pasteboards are shared by the apps and extensions of one team and
/// need no entitlement, so they survive any re-signing. Not documented as a
/// way to feed widgets: the last resort.
enum SharedPasteboard {
    private static let type = "public.data"

    static func read(_ name: String) -> Data? {
        pasteboard(name)?.data(forPasteboardType: type)
    }

    static func write(_ data: Data, for name: String) -> Bool {
        guard let board = pasteboard(name) else { return false }
        board.setData(data, forPasteboardType: type)
        return true
    }

    private static func pasteboard(_ name: String) -> UIPasteboard? {
        UIPasteboard(name: UIPasteboard.Name("com.laskywolf.woofmusic.widgets." + name), create: true)
    }
}

/// Generic-password items in "TEAMID.woofmusic.widgets". The usual profile of a
/// shared certificate grants the Keychain groups "TEAMID.*" to the app and its
/// extensions, so both reach this group without an App Group.
enum SharedKeychain {
    private static let service = "WoofWidgets"

    /// The team id from the default Keychain group, or nil.
    static let teamId: String? = findTeamId()

    /// The shared group and the probe write's status. Writing a probe is the
    /// only way to learn whether the entitlements allow the group.
    static let probe: (group: String?, status: OSStatus) = {
        guard let teamId else { return (nil, errSecMissingEntitlement) }
        let group = teamId + ".woofmusic.widgets"
        let status = upsert(Data(), account: "probe", group: group)
        return (status == errSecSuccess ? group : nil, status)
    }()

    /// Nil when the entitlements don't cover the group (an App Group build, or a profile without "TEAMID.*").
    static var group: String? { probe.group }

    static func read(_ account: String) -> Data? {
        guard let group else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func write(_ data: Data, for account: String) -> Bool {
        guard let group else { return false }
        return upsert(data, account: account, group: group) == errSecSuccess
    }

    private static func upsert(_ data: Data, account: String, group: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var item = query
        item[kSecValueData as String] = data
        // Widgets refresh while the phone is locked.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil)
    }

    /// The team id, read off the access group of an item saved in the default group ("TEAMID.<bundle id>").
    private static func findTeamId() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "team-probe",
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data()
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(item as CFDictionary, &result)
        }
        guard status == errSecSuccess,
              let attributes = result as? [String: Any],
              let accessGroup = attributes[kSecAttrAccessGroup as String] as? String,
              let team = accessGroup.split(separator: ".").first else { return nil }
        return String(team)
    }
}

// The widget buttons use these intents, so both targets compile them. iOS
// runs an AudioPlaybackIntent's perform() in the app process (launching the
// app in the background when needed), so only the app's copy acts.

struct PlayPauseIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play or Pause"
    static var description = IntentDescription("Pauses the song that's playing, or resumes the last one.")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        PlayerController.shared.setPaused(NowPlaying.shared.isPlaying)
        #endif
        return .result()
    }
}

struct NextSongIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Next Song"
    static var description = IntentDescription("Skips to the next song in the queue.")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        NowPlaying.shared.playNext()
        #endif
        return .result()
    }
}

struct PreviousSongIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Previous Song"
    static var description = IntentDescription("Goes back to the previous song in the queue.")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        NowPlaying.shared.playPrevious()
        #endif
        return .result()
    }
}

struct ToggleLikeIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Like or Unlike"
    static var description = IntentDescription("Likes the song that's playing, or removes the like.")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        if let song = NowPlaying.shared.currentSong {
            await LikeStore.shared.toggle(song: song)
            WidgetSync.shared.refresh()
        }
        #endif
        return .result()
    }
}

struct ToggleShuffleIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Shuffle"
    static var description = IntentDescription("Turns shuffle on or off for the queue.")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let np = NowPlaying.shared
        np.isShuffleOn.toggle()
        if np.isShuffleOn { np.shuffleQueue() } else { np.disableShuffle() }
        WidgetSync.shared.refresh()
        #endif
        return .result()
    }
}

struct ToggleRepeatIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Repeat"
    static var description = IntentDescription("Turns repeat on or off.")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        NowPlaying.shared.isRepeatOn.toggle()
        WidgetSync.shared.refresh()
        #endif
        return .result()
    }
}

struct PlayQuickPickIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Quick Pick"
    static var description = IntentDescription("Plays one of your Quick Picks, with the others queued after it.")
    static var isDiscoverable = false

    @Parameter(title: "Song ID") var videoId: String

    init() {}

    init(videoId: String) {
        self.videoId = videoId
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let songs = WidgetSync.quickPickSongs()
        if let song = songs.first(where: { $0.videoId == videoId }) {
            PlaybackQueue.play(song, in: songs, log: Log.player, context: "Widget Quick Pick")
        }
        #endif
        return .result()
    }
}

struct ShuffleQuickPicksIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Shuffle Quick Picks"
    static var description = IntentDescription("Plays your Quick Picks in a random order.")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let songs = WidgetSync.quickPickSongs()
        if !songs.isEmpty {
            PlaybackQueue.playShuffled(songs, log: Log.player, context: "Widget Quick Picks shuffle")
        }
        #endif
        return .result()
    }
}
