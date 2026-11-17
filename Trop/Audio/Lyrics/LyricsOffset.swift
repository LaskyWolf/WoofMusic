//
//  LyricsOffset.swift
//  Trop
//
//  Per-track lyric offset. Shifting a badly timed track no longer moves every
//  other song: the value belongs to the video id. A track that was never
//  adjusted falls back to the global default in Settings, which stays 0 unless
//  the listener changed it. Reads happen on the render path, so nothing here
//  touches an actor or the settings object.
//

import Foundation

enum LyricsOffset {
    /// Posted after a track's offset changes so open lyrics re-sync.
    static let didChange = Notification.Name("lyrics.offset.didChange")

    private static let key = "lyrics.offsets.v2"
    /// Same key SettingsStore writes its default under.
    private static let defaultKey = "settings.lyricsOffsetSeconds"

    private static func table() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    /// The value typed for this track, if any.
    static func stored(for videoId: String?) -> Double? {
        guard let videoId else { return nil }
        return table()[videoId]
    }

    /// The offset actually applied: this track's own value, else the global one.
    static func effective(for videoId: String?) -> Double {
        if let own = stored(for: videoId) { return own }
        return UserDefaults.standard.double(forKey: defaultKey)
    }

    static func isAdjusted(_ videoId: String?) -> Bool {
        stored(for: videoId) != nil
    }

    /// Zero clears the entry, so the track goes back to following the default.
    static func set(_ value: Double, for videoId: String?) {
        guard let videoId else { return }
        var table = table()
        if abs(value) < 0.005 {
            table.removeValue(forKey: videoId)
        } else {
            table[videoId] = value
        }
        UserDefaults.standard.set(table, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
