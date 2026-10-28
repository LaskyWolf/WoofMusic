//
//  LyricsOptionsMenu.swift
//  Trop
//
//  Created by 686udjie on 24/08/2026.
//

import SwiftUI

/// The lyrics panel's "⋯" menu: a native pull-down menu. Edit, search and
/// offset open their own sheet after the menu closes.
struct LyricsOptionsMenu<MenuLabel: View>: View {
    @ViewBuilder var label: () -> MenuLabel

    @Environment(\.settingsStore) private var settings
    @AppStorage(LyricsState.karaokeEnabledKey) private var karaokeEnabled = false
    private let np = NowPlaying.shared

    private enum Sheet: Identifiable {
        case edit, search, offset
        var id: Self { self }
    }

    @State private var sheet: Sheet?

    var body: some View {
        @Bindable var settings = settings

        Menu {
            Section {
                Button("Edit Lyrics…", systemImage: "square.and.pencil") { sheet = .edit }
                Button("Search Lyrics…", systemImage: "magnifyingglass") { sheet = .search }
                Button("Refetch Lyrics", systemImage: "arrow.clockwise", action: refetchLyrics)
                Button("Copy Lyrics", systemImage: "doc.on.doc", action: copyLyrics)
            }
            .disabled(np.videoId == nil)

            Section {
                Button { sheet = .offset } label: {
                    Label("Lyric Offset…", systemImage: "forward")
                    Text(offsetDescription)
                }
                Toggle(isOn: $settings.showIntervalIndicator) {
                    Label("Show Interval Indicator", systemImage: "text.quote")
                }
                Toggle(isOn: $settings.romanizeCurrentTrack) {
                    Label("Romanize Current Track", systemImage: "globe")
                }
                Toggle(isOn: $karaokeEnabled) {
                    Label("Karaoke", systemImage: "music.mic")
                    if !LyricsState.shared.hasWordTiming {
                        Text("Needs word-timed lyrics")
                    }
                }
                .disabled(!LyricsState.shared.hasWordTiming)
            }
        } label: {
            label()
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .offset:
                LyricsOffsetSheet()
            case .edit:
                EditLyricsSheet(videoId: np.videoId ?? "", songTitle: np.title)
            case .search:
                SearchLyricsSheet(
                    videoId: np.videoId ?? "",
                    defaultTitle: np.title,
                    defaultArtist: np.displayArtist,
                    duration: np.duration
                )
            }
        }
    }

    /// "Off", or a signed value like "+1.5s".
    private var offsetDescription: String {
        let v = settings.lyricsOffsetSeconds
        guard v != 0 else { return "Off" }
        var s = String(format: "%.2f", abs(v))
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return "\(v < 0 ? "-" : "+")\(s)s"
    }

    private func refetchLyrics() {
        guard let videoId = np.videoId else { return }
        Task { await LyricsService.shared.refetch(videoId: videoId) }
    }

    private func copyLyrics() {
        guard let videoId = np.videoId else { return }
        Task {
            if let text = await LyricsService.shared.plainTextForCopy(videoId: videoId) {
                UIPasteboard.general.string = text
            }
        }
    }
}

/// Type-a-number offset editor laid out like Metrolist's ShowOffsetDialog:
/// big forward icon, bold title, centered value field with unit suffix and
/// reset button, then a −/+ stepper slider. Changes apply live.
struct LyricsOffsetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsStore) private var settings

    /// Typed values may exceed the slider range, like Metrolist's ±9999ms.
    private let typeLimit: Double = 10
    private let sliderRange: ClosedRange<Double> = -3...3

    @State private var textFieldValue = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "forward")
                    .font(.system(size: 40))
                    .foregroundStyle(settings.accentColor)

                Text("Lyric Offset")
                    .font(.title2.bold())

                HStack(spacing: 8) {
                    TextField("0", text: $textFieldValue)
                        .font(.system(size: 34, weight: .bold))
                        .multilineTextAlignment(.center)
                        .keyboardType(.numbersAndPunctuation)
                        .frame(width: 150)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("s")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)

                    if settings.lyricsOffsetSeconds != 0 {
                        Button {
                            settings.lyricsOffsetSeconds = 0
                            textFieldValue = "0"
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .foregroundStyle(settings.accentColor)
                                .frame(width: 36, height: 36)
                        }
                        .accessibilityLabel("Reset offset")
                    }
                }

                HStack(spacing: 4) {
                    Button {
                        bump(-0.05)
                    } label: {
                        Image(systemName: "minus")
                            .font(.body.weight(.semibold))
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Slider(
                        value: Binding(
                            get: { min(sliderRange.upperBound, max(sliderRange.lowerBound, settings.lyricsOffsetSeconds)) },
                            set: { newValue in
                                apply(newValue)
                            }
                        ),
                        in: sliderRange,
                        step: 0.1
                    )
                    .tint(settings.accentColor)

                    Button {
                        bump(0.05)
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    Text("-3s")
                    Spacer()
                    Text("+3s")
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 48)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .appSheetChrome([.medium])
        .onAppear {
            textFieldValue = trimmedDecimalString(settings.lyricsOffsetSeconds)
        }
        .onChange(of: textFieldValue) { _, newValue in
            handleTextInput(newValue)
        }
    }

    // MARK: - Input Handling

    private func handleTextInput(_ raw: String) {
        let cleaned = sanitize(raw)
        if cleaned != raw {
            textFieldValue = cleaned
            return
        }
        guard cleaned.isEmpty == false, cleaned != "-", cleaned != "." else {
            settings.lyricsOffsetSeconds = 0
            return
        }
        if let value = Double(cleaned) {
            settings.lyricsOffsetSeconds = min(typeLimit, max(-typeLimit, value))
        }
    }

    /// Digits only, optional leading "-", single decimal point.
    private func sanitize(_ raw: String) -> String {
        var result = ""
        var seenDot = false
        for (index, char) in raw.enumerated() {
            if char.isNumber {
                result.append(char)
            } else if char == ".", !seenDot {
                seenDot = true
                result.append(char)
            } else if char == "-", index == 0 {
                result.append(char)
            }
            if result.count >= 7 { break }
        }
        return result
    }

    private func apply(_ value: Double) {
        settings.lyricsOffsetSeconds = value
        textFieldValue = trimmedDecimalString(value)
    }

    private func bump(_ delta: Double) {
        let current = settings.lyricsOffsetSeconds
        let target = min(sliderRange.upperBound, max(sliderRange.lowerBound, current + delta))
        apply((target * 100).rounded() / 100)
    }

    private func trimmedDecimalString(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

// MARK: - Edit Lyrics

/// Multiline editor pre-filled with the active lyrics, like Metrolist's
/// TextFieldDialog. Saving stores the text as the song's manual lyrics.
struct EditLyricsSheet: View {
    let videoId: String
    let songTitle: String

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.system(size: 14))
                .padding(.horizontal, 8)
                .navigationTitle(songTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            Task {
                                await LyricsService.shared.saveCustom(videoId: videoId, rawText: text, providerName: nil)
                            }
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .appSheetChrome([.large])
        .task {
            text = await LyricsService.shared.editableText(videoId: videoId)
        }
    }
}

// MARK: - Search Lyrics

/// Query editor + provider results list, mirroring Metrolist's search dialog
/// and ListDialog (2-line previews, provider caption, sync badge).
struct SearchLyricsSheet: View {
    let videoId: String
    let defaultTitle: String
    let defaultArtist: String
    let duration: TimeInterval

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var titleField = ""
    @State private var results: [LyricsManager.LyricSearchResult] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var expandedResultID: LyricsManager.LyricSearchResult.ID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Song title — e.g. Adele - Hello", text: $titleField)

                    HStack(spacing: 16) {
                        Button("Cancel") { dismiss() }
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Search Online") { searchOnline() }
                        Button("Search") { search() }
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderless)
                }

                if isSearching {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 24)
                    }
                } else if hasSearched && !results.isEmpty {
                    Section("Results") {
                        ForEach(results) { result in
                            resultRow(result)
                        }
                    }
                } else if hasSearched {
                    Section {
                        Text("Lyrics not found")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
        }
        .appSheetChrome([.large])
        .onAppear {
            titleField = defaultTitle
        }
    }

    private func resultRow(_ result: LyricsManager.LyricSearchResult) -> some View {
        let isExpanded = expandedResultID == result.id
        return Button {
            select(result)
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(result.previewText)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(isExpanded ? nil : 2)
                    HStack(spacing: 4) {
                        Text(result.providerName)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        if result.isSynced {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Button {
                    expandedResultID = isExpanded ? nil : result.id
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
        }
    }

    private func search() {
        // The title usually carries the artist ("Adele - Hello"); split it off
        // when present, otherwise fall back to the track's own artist.
        let raw = titleField.trimmingCharacters(in: .whitespacesAndNewlines)
        var queryTitle = raw
        var queryArtist = defaultArtist
        if let range = raw.range(of: " - ") {
            let left = String(raw[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let right = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !left.isEmpty, !right.isEmpty {
                queryArtist = left
                queryTitle = right
            }
        }
        guard !queryTitle.isEmpty else { return }

        isSearching = true
        hasSearched = false
        results = []
        Task {
            let query = LyricsQuery(
                title: queryTitle,
                artist: queryArtist,
                album: nil,
                duration: duration
            )
            results = await LyricsManager.shared.searchAll(query: query)
            isSearching = false
            hasSearched = true
        }
    }

    /// Opens a web search for the query, like Metrolist's ACTION_WEB_SEARCH.
    private func searchOnline() {
        let text = "\(titleField) lyrics".trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        if let url = components?.url {
            openURL(url)
        }
    }

    private func select(_ result: LyricsManager.LyricSearchResult) {
        let raw = LyricsParsing.serializeLines(result.lines)
        Task {
            await LyricsService.shared.saveCustom(videoId: videoId, rawText: raw, providerName: result.providerName)
        }
        dismiss()
    }
}
