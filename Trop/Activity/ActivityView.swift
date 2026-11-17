//
//  ActivityView.swift
//  Trop
//

import SwiftUI

/// One entry of Notifications: a new release from a followed artist.
struct ActivityItem: Identifiable {
    let id: String
    let message: String
    let time: String?
    let thumbnail: String?
    /// The page it opens: an album, artist, playlist or podcast.
    let route: DetailRoute?
    var isRead: Bool
}

struct ActivitySection: Identifiable {
    let title: String
    var items: [ActivityItem]
    var id: String { title }
}

/// Reading what YouTube answers, which nests the same few shapes at different depths.
enum ActivityJSON {
    static func text(_ node: Any?) -> String? {
        guard let dict = node as? [String: Any] else { return nil }
        if let simple = dict["simpleText"] as? String { return simple }
        let runs = dict["runs"] as? [[String: Any]]
        return runs.map { $0.compactMap { $0["text"] as? String }.joined() }
    }

    static func lastThumbnail(_ node: Any?) -> String? {
        let thumbnails = (node as? [String: Any])?["thumbnails"] as? [[String: Any]]
        return thumbnails?.last?["url"] as? String
    }

    /// The first value stored under `key`, at any depth.
    static func first(_ key: String, in node: Any?) -> Any? {
        if let dict = node as? [String: Any] {
            if let value = dict[key] { return value }
            for value in dict.values { if let found = first(key, in: value) { return found } }
        } else if let array = node as? [Any] {
            for value in array { if let found = first(key, in: value) { return found } }
        }
        return nil
    }

    /// Every object stored under `key`, at any depth.
    static func nodes(_ key: String, in node: Any?) -> [[String: Any]] {
        if let dict = node as? [String: Any] {
            if let match = dict[key] as? [String: Any] { return [match] }
            return dict.values.flatMap { nodes(key, in: $0) }
        }
        if let array = node as? [Any] { return array.flatMap { nodes(key, in: $0) } }
        return []
    }
}

/// The notifications, loaded when the app opens and kept for the page and the bell.
@MainActor
@Observable
final class ActivityStore {
    static let shared = ActivityStore()

    /// Nil until the first load ends.
    private(set) var sections: [ActivitySection]?
    private var loading: Task<Void, Never>?
    private var loadedAt: Date?
    /// App launches and returns to the app within this reuse the last load; pull to refresh doesn't.
    private static let freshFor: TimeInterval = 60 * 60

    var unseen: Int {
        sections?.reduce(0) { $0 + $1.items.count(where: { !$0.isRead }) } ?? 0
    }

    private static let seenKey = "activity.seen"
    private static let seenLimit = 500

    static var seenIds: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
    }

    /// Fetches the releases again. A call during a load waits for that load.
    func refresh() async {
        if let loading { return await loading.value }
        let task = Task {
            let items = await ReleaseFeed.items(seen: Self.seenIds)
            // A cancelled load is partial: keep what is shown.
            guard !Task.isCancelled else { return }
            guard let items else {
                // Failed (offline, signed out): keep what is shown, and the next check tries again.
                if sections == nil { sections = [] }
                return
            }
            sections = items.isEmpty ? [] : [ActivitySection(title: "New releases", items: items)]
            loadedAt = Date()
        }
        loading = task
        await task.value
        loading = nil
    }

    /// `refresh`, unless the last load is under an hour old.
    func refreshIfStale() async {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < Self.freshFor { return }
        await refresh()
    }

    /// Stops a running load, for a background task iOS is ending.
    func cancelLoading() { loading?.cancel() }

    /// Forgets the list, for an account switch.
    func reset() {
        loading?.cancel()
        loading = nil
        sections = nil
        loadedAt = nil
    }

    /// Saves the ids as seen and updates the rows, which clears them from the badge.
    func markSeen(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let saved = UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? []
        let updated = saved.filter { !ids.contains($0) } + ids
        UserDefaults.standard.set(Array(updated.suffix(Self.seenLimit)), forKey: Self.seenKey)
        guard var sections else { return }
        for section in sections.indices {
            for row in sections[section].items.indices where ids.contains(sections[section].items[row].id) {
                sections[section].items[row].isRead = true
            }
        }
        self.sections = sections
    }
}

struct ActivityView: View {
    private let store = ActivityStore.shared
    @State private var seenOnPage: Set<String> = []

    var body: some View {
        List {
            ForEach(store.sections ?? []) { section in
                Section {
                    ForEach(section.items) { item in
                        ActivityRow(item: item) { open(item) }
                            .onAppear { if !item.isRead { seenOnPage.insert(item.id) } }
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    Text(section.title)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .textCase(nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .listStyle(.plain)
        .miniPlayerTracksScroll()
        .overlay {
            if store.sections == nil {
                ProgressView()
            } else if store.sections?.isEmpty == true {
                ContentUnavailableView(
                    "No Notifications",
                    systemImage: "bell",
                    description: Text("New releases from artists you follow will appear here.")
                )
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await ActivityNotifier.askForPermissionOnce()
            // Loaded when the app opened; only a load still missing starts here.
            if store.sections == nil { await store.refresh() }
        }
        .refreshable { await store.refresh() }
        .onDisappear {
            store.markSeen(seenOnPage)
            seenOnPage = []
        }
    }

    private func open(_ item: ActivityItem) {
        store.markSeen([item.id])
        if let route = item.route { AppRouter.shared.open(route) }
    }
}

private struct ActivityRow: View {
    let item: ActivityItem
    let onOpen: () -> Void
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: DesignTokens.rowSpacing) {
                AsyncImageView(url: item.thumbnail)
                    .frame(width: DesignTokens.artSmall, height: DesignTokens.artSmall)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.message)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let time = item.time {
                        Text(time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !item.isRead {
                    Circle()
                        .fill(settings.accentColor)
                        .frame(width: 10, height: 10)
                        .accessibilityLabel("New")
                }
            }
            .padding(.horizontal, DesignTokens.screenHPadding)
            .padding(.vertical, DesignTokens.rowVPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(ZoomPressStyle(scale: 0.98))
    }
}
