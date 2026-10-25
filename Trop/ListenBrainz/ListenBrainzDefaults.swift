//
//  ListenBrainzDefaults.swift
//  Trop
//

import Foundation

enum ListenBrainzDefaults {
    static let apiBase = "https://api.listenbrainz.org/1/"
    static let keychainService = "com.woofmusic.listenbrainz"
    static let tokenAccount = "token"

    // UserDefaults key
    static let userNameKey = "listenBrainz.userName"

    // A song counts once half of it, or 4 minutes, has played: ListenBrainz's own rule.
    static let minSongDuration: TimeInterval = 30
    static let maxListenSeconds: TimeInterval = 240
    // A couple of seconds in, so the title and artist are final.
    static let nowPlayingDelaySeconds: TimeInterval = 2

    static let clientName = "Woof Music"
}
