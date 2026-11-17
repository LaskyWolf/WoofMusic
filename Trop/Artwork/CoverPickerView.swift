//
//  CoverPickerView.swift
//  Trop
//
//  Cover art picker for one track: a search across Apple's and Deezer's
//  catalogues, a grid of full-size covers, and two fallbacks that need no
//  network at all — the video's own still, or the cover the app already has.
//

import SwiftUI

struct CoverPickerView: View {
    let videoId: String
    let title: String
    let artist: String
    let album: String?

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var results: [CoverCandidate] = []
    @State private var isSearching = false
    @State private var failed = false
    @State private var saving: String?
    @State private var usesVideoStill = false
    @State private var hasCustom = false
    @State private var didLoad = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    searchField

                    if isSearching, results.isEmpty {
                        ProgressView().padding(.top, 40)
                    } else if failed, results.isEmpty {
                        emptyState(
                            "No covers found",
                            detail: "Check the spelling or try just the album name."
                        )
                    } else if results.isEmpty, didLoad {
                        emptyState("Nothing here yet", detail: "Search for a cover above.")
                    } else {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(results) { candidate in
                                Button {
                                    pick(candidate)
                                } label: {
                                    coverCell(candidate)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    fallbackSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .navigationTitle("Cover Art")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .appSheetChrome()
        }
        .onAppear {
            query = [artist, album ?? title].filter { !$0.isEmpty }.joined(separator: " ")
            hasCustom = CustomArtworkStore.hasCustomCover(videoId)
            usesVideoStill = CustomArtworkStore.prefersVideoStill(videoId)
            Task { await runSearch() }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Artist or album", text: $query)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { Task { await runSearch() } }
            if isSearching {
                ProgressView().scaleEffect(0.8)
            } else if !query.isEmpty {
                Button {
                    query = ""
                    Task { await runSearch() }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func coverCell(_ candidate: CoverCandidate) -> some View {
        ZStack(alignment: .bottomTrailing) {
            AsyncImage(url: candidate.url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                default:
                    Rectangle().fill(.quaternary)
                }
            }
            .aspectRatio(1, contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if saving == candidate.id {
                ProgressView()
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(6)
            } else {
                Text(candidate.source)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(6)
            }
        }
    }

    private var fallbackSection: some View {
        VStack(spacing: 0) {
            Toggle(isOn: Binding(
                get: { usesVideoStill },
                set: { newValue in
                    usesVideoStill = newValue
                    CustomArtworkStore.setPrefersVideoStill(newValue, for: videoId)
                    NowPlaying.shared.reloadArtwork()
                }
            )) {
                Label("Use the video still", systemImage: "film")
            }
            .padding(.vertical, 10)

            Divider()

            if hasCustom {
                Button(role: .destructive) {
                    CustomArtworkStore.remove(for: videoId)
                    hasCustom = false
                    NowPlaying.shared.reloadArtwork()
                } label: {
                    Label("Remove custom cover", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 10)
                Divider()
            }

            Button {
                CustomArtworkStore.remove(for: videoId)
                hasCustom = false
                usesVideoStill = false
                CustomArtworkStore.setPrefersVideoStill(false, for: videoId)
                NowPlaying.shared.reloadArtwork()
                dismiss()
            } label: {
                Label("Back to the original cover", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
        }
        .font(.subheadline)
    }

    private func emptyState(_ text: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Text(text).font(.headline)
            Text(detail).font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 32)
    }

    private func runSearch() async {
        isSearching = true
        failed = false
        let found = await CoverSearch.search(title: title, artist: artist, album: album)
        results = found
        isSearching = false
        didLoad = true
        failed = found.isEmpty
    }

    private func pick(_ candidate: CoverCandidate) {
        saving = candidate.id
        Task {
            if let image = await CoverSearch.download(candidate) {
                CustomArtworkStore.save(image, for: videoId)
                hasCustom = true
                usesVideoStill = false
                NowPlaying.shared.reloadArtwork()
                saving = nil
                dismiss()
            } else {
                saving = nil
                failed = true
            }
        }
    }
}
