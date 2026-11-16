//
//  ActivityView.swift
//  Trop
//

import SwiftUI

/// One entry of YouTube Music's Activity inbox: a new release, a new song, a post.
struct ActivityItem: Identifiable {
    let id: String
    let message: String
    let time: String?
    let thumbnail: String?
    /// The page it opens: an album, artist, playlist or podcast.
    let route: DetailRoute?
    /// A song it plays when it has no page.
    let videoId: String?
    /// YouTube's request that marks the entry as read when it is opened.
    let clickRequest: String?
    var isRead: Bool

    init(renderer: [String: Any], seen: Set<String>) {
        id = renderer["notificationId"] as? String ?? UUID().uuidString
        message = ActivityJSON.text(renderer["shortMessage"]) ?? ""
        time = ActivityJSON.text(renderer["sentTimeText"])
        thumbnail = ActivityJSON.lastThumbnail(renderer["videoThumbnail"]) ?? ActivityJSON.lastThumbnail(renderer["thumbnail"])
        let endpoint = renderer["navigationEndpoint"]
        videoId = ActivityJSON.first("videoId", in: endpoint) as? String
        route = (ActivityJSON.first("browseId", in: endpoint) as? String).flatMap(Self.route(forBrowseId:))
        clickRequest = ActivityJSON.first("serializedInteractionsRequest", in: renderer["recordClickEndpoint"]) as? String
        isRead = renderer["read"] as? Bool ?? false || seen.contains(id)
    }

    /// YouTube Music's ids say what they are: MPREb albums, UC artists, MPSP podcasts, VL playlists.
    private static func route(forBrowseId id: String) -> DetailRoute? {
        if id.hasPrefix("MPREb") { return .album(browseId: id) }
        if id.hasPrefix("UC") { return .artist(browseId: id) }
        if id.hasPrefix("MPSP") { return .podcast(browseId: id) }
        if id.hasPrefix("VL") { return .playlist(playlistId: String(id.dropFirst(2))) }
        return nil
    }
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

/// The Activity inbox and its unseen count, shared by the bell and the page.
@MainActor
@Observable
final class ActivityStore {
    static let shared = ActivityStore()

    private(set) var unseen = 0

    private static let seenKey = "activity.seen"
    private static let seenLimit = 500

    static var seenIds: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
    }

    static func markSeen(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let saved = UserDefaults.standard.stringArray(forKey: seenKey) ?? []
        let updated = saved.filter { !ids.contains($0) } + ids
        UserDefaults.standard.set(Array(updated.suffix(seenLimit)), forKey: seenKey)
    }

    func refreshUnseen() async {
        guard AccountState.shared.isLoggedIn,
              let data = try? await SignedInnerTube.post("notification/get_unseen_count", [:]),
              let json = try? JSONSerialization.jsonObject(with: data) else { return }
        let count = ActivityJSON.first("unseenCount", in: json)
        unseen = count as? Int ?? Int(count as? String ?? "") ?? 0
    }

    func clearUnseen() { unseen = 0 }

    /// The inbox, grouped under YouTube's own section titles.
    static func fetchInbox() async throws -> [ActivitySection] {
        let data = try await SignedInnerTube.post(
            "notification/get_notification_menu",
            ["notificationsMenuRequestType": "NOTIFICATIONS_MENU_REQUEST_TYPE_INBOX"]
        )
        let json = try JSONSerialization.jsonObject(with: data)
        let seen = seenIds
        var sections: [ActivitySection] = []
        func add(_ item: ActivityItem, to title: String) {
            if let index = sections.firstIndex(where: { $0.title == title }) {
                sections[index].items.append(item)
            } else {
                sections.append(ActivitySection(title: title, items: [item]))
            }
        }
        for section in ActivityJSON.nodes("multiPageMenuNotificationSectionRenderer", in: json) {
            let title = ActivityJSON.text(section["notificationSectionTitle"]) ?? ActivityJSON.text(section["title"]) ?? "Activity"
            for renderer in ActivityJSON.nodes("notificationRenderer", in: section["items"]) {
                add(ActivityItem(renderer: renderer, seen: seen), to: title)
            }
        }
        if sections.isEmpty {
            for renderer in ActivityJSON.nodes("notificationRenderer", in: json) {
                add(ActivityItem(renderer: renderer, seen: seen), to: "Activity")
            }
        }
        // An empty inbox still has its sections; no sections at all means the answer has another shape.
        if sections.isEmpty, ActivityJSON.first("multiPageMenuNotificationSectionRenderer", in: json) == nil {
            let keys = ((json as? [String: Any])?.keys.sorted().joined(separator: ", ")) ?? "none"
            throw NSError(domain: "Activity", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "YouTube Music answered without an inbox (\(data.count) bytes, fields: \(keys))."
            ])
        }
        return sections
    }
}

struct ActivityView: View {
    @State private var sections: [ActivitySection] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var seenOnPage: Set<String> = []

    var body: some View {
        List {
            ForEach(sections) { section in
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
            if sections.isEmpty {
                if isLoading {
                    ProgressView()
                } else if let errorText {
                    RetryStateView(
                        title: "Couldn't load activity",
                        systemImage: "exclamationmark.circle",
                        message: errorText,
                        retry: { await load() }
                    )
                } else {
                    ContentUnavailableView(
                        "No Activity",
                        systemImage: "bell",
                        description: Text("New releases from artists you follow will appear here.")
                    )
                }
            }
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            ActivityStore.shared.clearUnseen()
            await ActivityNotifier.askForPermissionOnce()
            await load()
        }
        .refreshable { await load() }
        .onDisappear {
            ActivityStore.markSeen(seenOnPage)
            markRead(seenOnPage)
            seenOnPage = []
        }
    }

    private func load() async {
        defer { isLoading = false }
        do {
            sections = try await ActivityStore.fetchInbox()
            errorText = nil
        } catch {
            // Leaving the page cancels the request, which says nothing about the inbox.
            guard !error.isCancellation else { return }
            errorText = error.localizedDescription
        }
    }

    /// By id, because a refresh can replace the list while a row still holds its place.
    private func markRead(_ ids: Set<String>) {
        for section in sections.indices {
            for row in sections[section].items.indices where ids.contains(sections[section].items[row].id) {
                sections[section].items[row].isRead = true
            }
        }
    }

    private func open(_ item: ActivityItem) {
        markRead([item.id])
        ActivityStore.markSeen([item.id])
        if let request = item.clickRequest {
            Task { _ = try? await SignedInnerTube.post("notification/record_interactions", ["serializedRecordNotificationInteractionsRequests": [request]]) }
        }
        if let route = item.route {
            AppRouter.shared.open(route)
        } else if let videoId = item.videoId {
            let song = SongItem(
                videoId: videoId, title: item.message, artists: [], album: nil, albumId: nil, duration: 0,
                thumbnailUrl: item.thumbnail ?? ArtworkURLs.fallback(for: videoId), isExplicit: false, playlistId: nil
            )
            PlaybackQueue.play([song], log: Log.homeScreenView, context: "Activity \(item.message)")
        }
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
