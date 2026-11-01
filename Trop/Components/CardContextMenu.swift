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

/// Play, Shuffle, Play Next, Add to Queue and Download for a card that holds songs.
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
                    NowPlaying.shared.appendToQueue(songs)
                }
            }
            Button("Download", systemImage: "arrow.down.to.line") {
                Task { DownloadManager.shared.download(songs: await loadSongs()) }
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
    /// A long press lifts only what the view draws, so text would float over the blur. This
    /// background matches what's behind the view, so it only shows once the view is lifted.
    /// The margin goes back after the menu, so the layout doesn't change. A nil background
    /// is for a view that fills its own shape.
    @ViewBuilder
    func liftedMenu<Items: View>(
        background: Color? = Color(.systemBackground),
        margin: CGFloat = 6,
        @ViewBuilder items: () -> Items
    ) -> some View {
        if let background {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            padding(margin)
                .background(background, in: shape)
                .contentShape(.contextMenuPreview, shape)
                .contextMenu(menuItems: items)
                .padding(-margin)
        } else {
            contextMenu(menuItems: items)
        }
    }

    /// Long press on an album card.
    func albumCardMenu(browseId: String, artists: [YTArtist] = [], background: Color? = Color(.systemBackground)) -> some View {
        liftedMenu(background: background) { AlbumCardMenu(browseId: browseId, artists: artists) }
    }

    /// Long press on a playlist card; `extra` adds items below the standard ones.
    func playlistCardMenu<Extra: View>(id: String, @ViewBuilder extra: () -> Extra) -> some View {
        liftedMenu {
            PlaylistCardMenu(id: id)
            extra()
        }
    }

    func playlistCardMenu(id: String, background: Color? = Color(.systemBackground)) -> some View {
        liftedMenu(background: background) { PlaylistCardMenu(id: id) }
    }

    /// Long press on an artist card.
    func artistCardMenu(browseId: String, background: Color? = Color(.systemBackground)) -> some View {
        liftedMenu(background: background) { ArtistCardMenu(browseId: browseId) }
    }

    /// Long press menu for a card built from a feed item (albums, playlists, artists).
    @ViewBuilder
    func cardMenu(for item: YTItem, background: Color? = Color(.systemBackground)) -> some View {
        switch item {
        case .album(let album): albumCardMenu(browseId: album.browseId, artists: album.artists, background: background)
        case .playlist(let playlist): playlistCardMenu(id: playlist.id, background: background)
        case .artist(let artist): artistCardMenu(browseId: artist.browseId, background: background)
        default: self
        }
    }
}
