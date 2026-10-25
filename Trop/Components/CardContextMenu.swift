//
//  CardContextMenu.swift
//  Trop
//

import SwiftUI

/// Songs of an album or playlist, fetched only when a menu action needs them.
@MainActor
private enum CardSongs {
    static func album(_ browseId: String) async -> [SongItem] {
        let model = AlbumDetailViewModel(browseId: browseId)
        await model.load()
        return model.album?.songs ?? []
    }

    static func playlist(_ id: String) async -> [SongItem] {
        let model = PlaylistDetailViewModel(playlistId: id)
        await model.load()
        return model.playlist?.songs ?? []
    }
}

/// Play, Shuffle, Play Next and Add to Queue for a card that holds songs.
private struct SongCollectionItems: View {
    let loadSongs: () async -> [SongItem]

    var body: some View {
        Section {
            Button("Play", systemImage: "play.fill") {
                Task {
                    let songs = await loadSongs()
                    PlaybackQueue.play(songs, log: Log.playlistDetail, context: "card play")
                }
            }
            Button("Shuffle", systemImage: "shuffle") {
                Task {
                    let songs = await loadSongs()
                    PlaybackQueue.playShuffled(songs, log: Log.playlistDetail, context: "card shuffle")
                }
            }
        }
        Section {
            Button("Play Next", systemImage: "text.insert") {
                Task { await loadSongs().forEach(NowPlaying.shared.enqueueNext) }
            }
            Button("Add to Queue", systemImage: "text.append") {
                Task {
                    let songs = await loadSongs()
                    let np = NowPlaying.shared
                    np.queueSongs.append(contentsOf: songs)
                    np.persistQueueState()
                }
            }
        }
    }
}

private struct AlbumCardMenu: View {
    let browseId: String
    let artists: [YTArtist]

    var body: some View {
        Button("Open Album", systemImage: "square.stack") {
            AppRouter.shared.open(.album(browseId: browseId))
        }
        SongCollectionItems { await CardSongs.album(browseId) }
        let linked = artists.filter { $0.id != nil && !$0.name.isEmpty }
        if !linked.isEmpty {
            Section {
                ForEach(linked, id: \.self) { artist in
                    Button("Go to \(artist.name)", systemImage: "music.mic") {
                        if let id = artist.id { AppRouter.shared.open(.artist(browseId: id)) }
                    }
                }
            }
        }
        if let url = URL(string: "https://music.youtube.com/browse/\(browseId)") {
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }
}

private struct PlaylistCardMenu: View {
    let id: String

    var body: some View {
        Button("Open Playlist", systemImage: "music.note.list") {
            AppRouter.shared.open(.playlist(playlistId: id))
        }
        SongCollectionItems { await CardSongs.playlist(id) }
        if let url = URL.playlistShareURL(id: id) {
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }
}

private struct ArtistCardMenu: View {
    let browseId: String

    var body: some View {
        Button("Open Artist", systemImage: "music.mic") {
            AppRouter.shared.open(.artist(browseId: browseId))
        }
        if let url = URL(string: "https://music.youtube.com/channel/\(browseId)") {
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }
}

extension View {
    /// Long press on an album card.
    func albumCardMenu(browseId: String, artists: [YTArtist] = []) -> some View {
        contextMenu { AlbumCardMenu(browseId: browseId, artists: artists) }
    }

    /// Long press on a playlist card; `extra` adds items below the standard ones.
    func playlistCardMenu<Extra: View>(id: String, @ViewBuilder extra: () -> Extra) -> some View {
        contextMenu {
            PlaylistCardMenu(id: id)
            extra()
        }
    }

    func playlistCardMenu(id: String) -> some View {
        contextMenu { PlaylistCardMenu(id: id) }
    }

    /// Long press on an artist card.
    func artistCardMenu(browseId: String) -> some View {
        contextMenu { ArtistCardMenu(browseId: browseId) }
    }

    /// Long press menu for a card built from a feed item (albums, playlists, artists).
    @ViewBuilder
    func cardMenu(for item: YTItem) -> some View {
        switch item {
        case .album(let album): albumCardMenu(browseId: album.browseId, artists: album.artists)
        case .playlist(let playlist): playlistCardMenu(id: playlist.id)
        case .artist(let artist): artistCardMenu(browseId: artist.browseId)
        default: self
        }
    }
}
