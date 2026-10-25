//
//  DownloadsView.swift
//  Trop
//

import SwiftUI

struct DownloadsView: View {
    @Environment(SettingsStore.self) private var settings
    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var showMoreSheet = false

    private var tracks: [DownloadedTrackEntity] { downloadManager.tracks }
    private var songs: [SongItem] { tracks.map { SongItem(entity: $0) } }
    private var activeDownloads: [(videoId: String, progress: Double)] {
        downloadManager.activeDownloads
    }

    var body: some View {
        Group {
            if !downloadManager.isLoaded {
                LoadingStateView("Loading downloads…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty && activeDownloads.isEmpty {
                emptyView
            } else {
                contentView
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await downloadManager.reload() }
        .task {
            if !downloadManager.isLoaded {
                await downloadManager.reload()
            }
        }
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("No Downloads Yet", systemImage: "arrow.down.circle")
        } description: {
            Text("Save songs for offline listening from the player menu, or enable auto-download when you like a track.")
        } actions: {
            NavigationLink {
                DownloadSettingsView()
            } label: {
                Text("Download Settings")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(settings.accentColor)
        }
        .miniPlayerTracksScroll()
    }

    private var contentView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                header
                    .padding(.bottom, 8)

                if !activeDownloads.isEmpty {
                    activeDownloadsSection
                }

                if !songs.isEmpty {
                    songList
                }
            }
        }
        .scrollDisabled(!downloadManager.isLoaded)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .miniPlayerTracksScroll()
    }

    private var header: some View {
        PlaylistHeaderView(
            title: "Downloads",
            thumbnails: Array(tracks.prefix(4).compactMap(\.thumbnailUrl)),
            songCount: tracks.count,
            duration: tracks.reduce(0) { $0 + $1.duration },
            accentColor: settings.accentColor,
            onPlay: playAll,
            onShuffle: shufflePlay,
            onMore: { showMoreSheet = true }
        )
        .sheet(isPresented: $showMoreSheet) {
            DownloadsMoreSheet(songs: songs)
        }
    }

    private var activeDownloadsSection: some View {
        VStack(spacing: 0) {
            SectionLabel(title: "Downloading", systemImage: "arrow.down.circle")
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            ForEach(activeDownloads, id: \.videoId) { item in
                ActiveDownloadRow(videoId: item.videoId, progress: item.progress)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }
        }
        .padding(.bottom, 16)
    }

    private var songList: some View {
        VStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                SongRowView(
                    song: song,
                    artSize: 48,
                    artRadius: 8,
                    onTap: { playSong(song) },
                    onNavigate: { AppRouter.shared.open($0) }
                )

                if index < songs.count - 1 {
                    Divider()
                        .padding(.leading, 76)
                }
            }
        }
    }

    private func playAll() {
        let songs = songs
        guard !songs.isEmpty else { return }
        NowPlaying.shared.setQueue(songs, startIndex: 0)
        NowPlaying.shared.update(with: songs[0])
        Task { await playLocal(songs[0]) }
    }

    private func shufflePlay() {
        let songs = songs.shuffled()
        guard !songs.isEmpty else { return }
        NowPlaying.shared.setQueue(songs, startIndex: 0)
        NowPlaying.shared.update(with: songs[0])
        Task { await playLocal(songs[0]) }
    }

    private func playSong(_ song: SongItem) {
        let songs = songs
        if let index = songs.firstIndex(where: { $0.videoId == song.videoId }) {
            NowPlaying.shared.setQueue(songs, startIndex: index)
        } else {
            NowPlaying.shared.setQueue([song], startIndex: 0)
        }
        NowPlaying.shared.update(with: song)
        Task { await playLocal(song) }
    }

    private func playLocal(_ song: SongItem) async {
        guard let localURL = await downloadManager.localURL(for: song.videoId) else { return }
        let artists = song.artists
        let displayArtist = artists.map(\.name).joined(separator: ", ")
        await PlayerController.shared.play(
            url: localURL.absoluteString,
            title: song.title,
            artist: displayArtist,
            videoId: song.videoId,
            duration: TimeInterval(song.duration),
            artists: artists
        )
    }
}
