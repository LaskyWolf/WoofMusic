//
//  QueueView.swift
//  Trop
//
//  Created by 686udjie on 16/07/2026.
//

import SwiftUI

struct QueueView: View {
    private let np = NowPlaying.shared

    @Binding var showQueue: Bool
    @Binding var isShuffleOn: Bool
    @Binding var isRepeatOn: Bool

    var body: some View {
        queueContent
            .simultaneousGesture(backSwipeGesture)
    }

    private var backSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onEnded { value in
                let isHorizontal = abs(value.translation.width) > abs(value.translation.height)
                guard value.startLocation.x <= 28,
                      isHorizontal,
                      value.translation.width > 80 else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    showQueue = false
                }
            }
    }

    // MARK: - Queue Content

    private var queueContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Up Next")
                    .font(.title2.bold())
                Spacer()
                Button { showQueue = false } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close queue")
            }
            .foregroundStyle(.white)
            .padding(.leading, 20)
            .padding(.trailing, 8)
            .padding(.top, 8)
            playbackPillsRow

            ScrollViewReader { proxy in
                List {
                    if np.queueSongs.isEmpty {
                        emptyQueueRow
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(Array(np.queueSongs.enumerated()), id: \.element.videoId) { index, song in
                            queueRow(song: song, index: index)
                        }
                        .onMove(perform: np.moveQueueSongs)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.colorScheme, .dark)
                .scrollIndicators(.hidden)
                .layoutPriority(1)
                .onAppear {
                    if np.queueSongs.indices.contains(np.queueIndex) {
                        proxy.scrollTo(np.queueSongs[np.queueIndex].videoId, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Queue Sub-Views

    private var playbackPillsRow: some View {
        HStack(spacing: 8) {
            pillButton(isOn: $isShuffleOn, icon: "shuffle") {
                if isShuffleOn {
                    np.shuffleQueue()
                } else {
                    np.disableShuffle()
                }
            }
            pillButton(isOn: $isRepeatOn, icon: "repeat")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func pillButton(isOn: Binding<Bool>, icon: String, action: (() -> Void)? = nil) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            action?()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    Capsule()
                        .fill(isOn.wrappedValue ? .white.opacity(0.15) : .white.opacity(0.07))
                )
        }
        .accessibilityLabel(icon == "shuffle" ? "Shuffle" : "Repeat")
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
    }

    private var emptyQueueRow: some View {
        HStack {
            Spacer()
            Text("Queue is empty")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
        }
        .padding(.vertical, 24)
    }

    // MARK: - Actions

    private func queueRow(song: SongItem, index: Int) -> some View {
        let isCurrent = index == np.queueIndex

        return Button {
            playSong(at: index)
        } label: {
            QueueSongRow(
                song: song,
                isCurrent: isCurrent,
                isPlayed: index < np.queueIndex
            )
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowBackground(
            Group {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.08))
                        .padding(.horizontal, 12)
                }
            }
        )
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                withAnimation(.spring(response: 0.3)) {
                    removeSong(at: index)
                }
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func playSong(at index: Int) {
        guard np.queueSongs.indices.contains(index) else { return }
        np.lastManualSkipTime = Date()
        np.moveQueueIndex(to: index)
        np.playCurrentSong(logContext: "resolveAndPlay", manageResolvingFlag: false)
    }

    private func removeSong(at index: Int) {
        guard np.queueSongs.indices.contains(index) else { return }
        let wasCurrent = index == np.queueIndex
        let removedVideoId = np.queueSongs[index].videoId
        np.removeQueueSong(at: index)
        if wasCurrent {
            if np.queueSongs.isEmpty {
                np.queueIndex = 0
                np.isPlaying = false
                np.persistQueueState()
                Task { @MainActor in PlayerController.shared.setPaused(true) }
                return
            }
            let nextIndex = min(index, np.queueSongs.count - 1)
            np.queueIndex = nextIndex
            let song = np.queueSongs[nextIndex]
            np.update(with: song)
            loggedTask(Log.nowPlaying, "removeSong auto-play failed") {
                try await PlaybackManager.shared.resolveAndPlay(videoId: song.videoId)
            }
        } else {
            np.repairQueueIndex()
        }
        np.persistQueueState()
        if !wasCurrent && removedVideoId == np.videoId {
            np.repairQueueIndex()
        }
    }
}

// MARK: - Queue Song Row

struct QueueSongRow: View {
    let song: SongItem
    var isCurrent = false
    var isPlayed = false

    var body: some View {
        HStack(spacing: 12) {
            AsyncImageView(url: song.thumbnailUrl)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .opacity(isPlayed ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(
                    text: song.title,
                    font: .body.weight(isCurrent ? .semibold : .medium),
                    frameHeight: 24,
                    textColor: titleColor
                )

                let artistStr = song.artists.map(\.name).joined(separator: ", ")
                if !artistStr.isEmpty {
                    Text(artistStr)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(isPlayed ? 0.35 : 0.6))
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.leading, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.25), value: isCurrent)
    }

    private var titleColor: Color {
        isPlayed && !isCurrent ? Color.white.opacity(0.45) : .white
    }
}
