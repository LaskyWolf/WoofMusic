//
//  MusicLinkOpener.swift
//  Trop
//

import UIKit

/// Why a link didn't open, in words for the user.
struct MusicLinkProblem: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}

@MainActor
enum MusicLinkOpener {
    /// Plays the song or opens the page. Nil link means it wasn't recognised.
    static func open(_ link: MusicLink?) async -> MusicLinkProblem? {
        let router = AppRouter.shared
        switch link {
        case .song(let videoId): return await play(videoId)
        case .playlist(let id): router.open(.playlist(playlistId: id))
        case .album(let browseId): router.open(.album(browseId: browseId))
        case .artist(let browseId): router.open(.artist(browseId: browseId))
        case .podcast(let browseId): router.open(.podcast(browseId: browseId))
        case .shazam(let url): return await playShazam(url)
        case nil:
            return MusicLinkProblem(message: "Woof Music opens YouTube and YouTube Music links to songs, playlists, albums, artists and podcasts, and Shazam links to songs.")
        }
        return nil
    }

    /// For woofmusic:// links, where nothing else can show the problem.
    static func openShowingProblem(_ link: MusicLink?) {
        Task {
            guard let problem = await open(link) else { return }
            let alert = UIAlertController(title: "Couldn't open this link", message: problem.message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            topViewController()?.present(alert, animated: true)
        }
    }

    /// Finds the Shazam song on YouTube Music: the first song result with its title, else the first song.
    private static func playShazam(_ url: URL) async -> MusicLinkProblem? {
        guard let track = await ShazamLink.track(at: url) else {
            return MusicLinkProblem(message: "This Shazam link couldn't be read. Check your connection, or search for the song by name.")
        }
        await AuthService.shared.loadPersistedSession()
        guard let raw = try? await InnerTubeClient.tropShared.search(query: "\(track.title) \(track.artist)", params: nil, client: .webRemix) else {
            return MusicLinkProblem(message: "Couldn't search for \"\(track.title)\". Check your connection.")
        }
        let songs = SearchParser.parseSearchResults(from: raw).flatMap(\.items).compactMap { item -> SongItem? in
            if case .song(let song) = item, song.isAvailable { return song }
            return nil
        }
        guard let song = songs.first(where: { $0.title.localizedCaseInsensitiveContains(track.title) }) ?? songs.first else {
            return MusicLinkProblem(message: "\"\(track.title)\" by \(track.artist) wasn't found on YouTube Music.")
        }
        PlaybackQueue.playSingleWithRadio(song, log: Log.nowPlaying)
        AppRouter.shared.expandPlayer()
        return nil
    }

    /// The radio response carries the song's title and artwork, which a bare ID doesn't have.
    private static func play(_ videoId: String) async -> MusicLinkProblem? {
        await AuthService.shared.loadPersistedSession()
        guard let radio = try? await PersonalizationService.shared.fetchRadio(videoId: videoId),
              radio.songs[radio.currentIndex].videoId == videoId,
              radio.songs[radio.currentIndex].isAvailable else {
            return MusicLinkProblem(message: "This song couldn't be loaded. It may be unavailable, or you may be offline.")
        }
        PlaybackQueue.play(radio.songs, startIndex: radio.currentIndex, log: Log.nowPlaying, context: "musicLink")
        AppRouter.shared.expandPlayer()
        return nil
    }
}
