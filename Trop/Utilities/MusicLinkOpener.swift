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
    /// Plays the song or opens the page. Spotify and Apple Music links go
    /// through Odesli first.
    static func open(_ url: URL?) async -> MusicLinkProblem? {
        let router = AppRouter.shared
        let link: MusicLink
        if let url, let parsed = MusicLink(link: url) {
            link = parsed
        } else if let url, MusicLink.isConvertible(url) {
            do {
                link = try await Odesli.shared.convert(url)
            } catch {
                return MusicLinkProblem(message: error.localizedDescription)
            }
        } else {
            return MusicLinkProblem(message: "Woof Music opens YouTube, YouTube Music, Spotify and Apple Music links to music.")
        }
        switch link {
        case .song(let videoId): return await play(videoId)
        case .playlist(let id): router.open(.playlist(playlistId: id))
        case .album(let browseId): router.open(.album(browseId: browseId))
        case .artist(let browseId): router.open(.artist(browseId: browseId))
        case .podcast(let browseId): router.open(.podcast(browseId: browseId))
        }
        return nil
    }

    /// For woofmusic:// links, where nothing else can show the problem.
    static func openShowingProblem(_ url: URL?) {
        Task {
            guard let problem = await open(url) else { return }
            let alert = UIAlertController(title: "Couldn't open this link", message: problem.message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            topViewController()?.present(alert, animated: true)
        }
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
