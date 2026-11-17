//
//  CanvasPickerView.swift
//  Trop
//
//  The manual clip picker behind the "⋯ → Canvas…" item: search the catalogue
//  for a still and a clip, or import a video from Photos. Either choice is
//  stored per track and wins over both automatic sources.
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct CanvasPickerView: View {
    let videoId: String
    let title: String
    let artist: String
    let album: String?

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var candidates: [CanvasCandidate] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var hasPick = false

    var body: some View {
        NavigationStack {
            List {
                if hasPick {
                    Section {
                        Label("This track uses your clip", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Remove Clip", role: .destructive) {
                            CanvasStore.clear(for: videoId)
                            CanvasService.shared.forget(videoId: videoId)
                            hasPick = false
                        }
                    } header: {
                        Text("Current")
                    }
                }

                Section {
                    PhotosPicker(selection: $pickedItem, matching: .videos) {
                        HStack {
                            Label("Choose from Photos…", systemImage: "photo.on.rectangle")
                            Spacer()
                            if isImporting { ProgressView() }
                        }
                    }
                } header: {
                    Text("Your Video")
                } footer: {
                    Text("The video is copied into the app, so it keeps playing after the original is deleted.")
                }

                Section {
                    TextField("Song or album", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }

                    Button {
                        Task { await search() }
                    } label: {
                        HStack {
                            Text("Search Catalogue")
                            Spacer()
                            if isSearching { ProgressView() }
                        }
                    }
                    .disabled(query.trimmingCharacters(in: .whitespaces).count < 2 || isSearching)
                } header: {
                    Text("Search")
                } footer: {
                    Text("Apple Music's motion artwork for “\(title)”.")
                }

                if !candidates.isEmpty {
                    Section("Results") {
                        ForEach(candidates) { candidate in
                            Button {
                                CanvasStore.setRemote(candidate.video, for: videoId)
                                CanvasService.shared.forget(videoId: videoId)
                                hasPick = true
                                dismiss()
                            } label: {
                                candidateRow(candidate)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else if hasSearched, !isSearching {
                    Section {
                        Text("Nothing with motion artwork for that query.")
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Canvas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { hasPick = CanvasStore.hasPick(for: videoId) }
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                Task { await importVideo(item) }
            }
        }
        .appSheetChrome()
    }

    private func candidateRow(_ candidate: CanvasCandidate) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: candidate.preview) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title).font(.body).lineLimit(1)
                Text(candidate.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func search() async {
        isSearching = true
        errorMessage = nil
        defer {
            isSearching = false
            hasSearched = true
        }
        candidates = await CanvasSearch.albums(matching: query)
    }

    private func importVideo(_ item: PhotosPickerItem) async {
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }

        do {
            guard let video = try await item.loadTransferable(type: PickableVideo.self) else {
                errorMessage = "That video could not be read."
                return
            }
            try CanvasStore.importVideo(from: video.url, for: videoId)
            try? FileManager.default.removeItem(at: video.url)
            CanvasService.shared.forget(videoId: videoId)
            hasPick = true
            dismiss()
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}

/// A Photos video, copied out of the picker's sandbox before it disappears.
struct PickableVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("canvas-\(UUID().uuidString).mov")
            if FileManager.default.fileExists(atPath: copy.path) {
                try FileManager.default.removeItem(at: copy)
            }
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickableVideo(url: copy)
        }
    }
}
