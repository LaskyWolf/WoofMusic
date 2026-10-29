//
//  RadioViews.swift
//  Trop
//
//  Created by 686udjie on 26/09/2026.
//

import SwiftUI

/// Style + size + explicit filter for song radio, applied client-side over
/// the single YTM `RDAMVM` mix.
struct RadioOptionsSheet: View {
    let song: SongItem
    @Environment(\.dismiss) private var dismiss
    @State private var options = RadioOptions.default
    @State private var isStarting = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Style", selection: $options.style) {
                        ForEach(RadioStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(options.style.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Sound")
                }

                Section {
                    Stepper(value: $options.limit, in: 5...50, step: 5) {
                        HStack {
                            Text("Tracks")
                            Spacer()
                            Text("\(options.limit)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Include explicit", isOn: $options.allowExplicit)
                } header: {
                    Text("Queue")
                }
            }
            .navigationTitle("Customize Radio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                // In the bar, like Done in Edit Playlist: at the medium height a
                // button under the form was cut off.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { start() }
                        .fontWeight(.semibold)
                        .disabled(isStarting)
                }
            }
        }
        .appSheetChrome()
        .onAppear { options = .saved }
    }

    private func start() {
        isStarting = true
        options.save()
        PlaybackQueue.startRadio(for: song, options: options)
        dismiss()
    }
}

/// "Similar" list built from the radio mix minus the seed.
struct SimilarSongsView: View {
    let song: SongItem
    var onNavigate: ((DetailRoute) -> Void)?
    var onPlaySong: ((SongItem, [SongItem]) -> Void)?

    @State private var songs: [SongItem] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Finding similar tracks…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if songs.isEmpty {
                ContentUnavailableView(
                    "No similar tracks",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("Try again later.")
                )
            } else {
                List {
                    ForEach(Array(songs.enumerated()), id: \.offset) { _, similar in
                        SongRowView(
                            song: similar,
                            artSize: DesignTokens.artSmall,
                            onTap: {
                                if let onPlaySong {
                                    onPlaySong(similar, songs)
                                } else {
                                    PlaybackQueue.play(similar, in: songs, log: Log.search, context: "SimilarTo tap")
                                }
                            },
                            onNavigate: onNavigate
                        )
                        // The row brings its own 16pt side padding, like the other sheets' rows.
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Similar")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        defer { isLoading = false }
        guard let radio = try? await PersonalizationService.shared.fetchRadio(
            videoId: song.videoId,
            options: RadioOptions(style: .similar, limit: 25, allowExplicit: true)
        ) else { return }
        songs = radio.songs.filter { $0.videoId != song.videoId }
    }
}
