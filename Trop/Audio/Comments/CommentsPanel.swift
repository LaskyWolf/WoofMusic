//
//  CommentsPanel.swift
//  Trop
//

import SwiftUI

/// The player's comments page, in the place of the artwork like the queue and the lyrics:
/// each comment as WoofTube shows it, with likes, replies and a box to write one.
struct CommentsPanel: View {
    @Binding var showComments: Bool
    private let np = NowPlaying.shared

    @State private var model = CommentsViewModel()
    @State private var draft = ""
    @FocusState private var isComposing: Bool
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .foregroundStyle(.white)
        .safeAreaInset(edge: .bottom) { composer }
        .task(id: np.videoId) {
            guard let videoId = np.videoId else { return }
            await model.load(videoId: videoId)
        }
        .alert("That Didn't Work", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Comments")
                    .font(.title2.bold())
                if let count = model.totalCountText {
                    Text(count)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer()
            if model.phase == .loaded {
                Menu {
                    Picker("Sort by", selection: Binding(get: { model.sort }, set: { sort in Task { await model.setSort(sort) } })) {
                        ForEach(CommentSort.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Sort comments, \(model.sort.title)")
            }
            Button { showComments = false } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(IconPressStyle(disc: .white, motion: .deflate))
            .accessibilityLabel("Close comments")
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .disabled:
            message("Comments Are Off", symbol: "bubble.left.and.exclamationmark.bubble.right",
                    detail: "YouTube has no comments for this song.")
        case .failed(let text):
            VStack(spacing: 12) {
                message("Couldn't Load", symbol: "exclamationmark.triangle", detail: text)
                Button("Try Again") {
                    guard let videoId = np.videoId else { return }
                    Task { await model.load(videoId: videoId) }
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .frame(maxHeight: .infinity)
        case .loaded where model.items.isEmpty:
            message("No Comments Yet", symbol: "bubble.left", detail: model.canPost ? "Be the first to write one." : nil)
        case .loaded:
            list
        }
    }

    private func message(_ title: String, symbol: String, detail: String?) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let detail { Text(detail) }
        }
        .foregroundStyle(.white.opacity(0.8))
        .frame(maxHeight: .infinity)
    }

    private var list: some View {
        List {
            ForEach(model.items) { item in
                CommentRow(item: item, model: model)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                    .task { await model.loadMore(after: item) }
                if let replies = model.replies[item.id], replies.isOpen {
                    ForEach(replies.items) { reply in
                        CommentRow(item: reply, model: model)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 64, bottom: 6, trailing: 20))
                    }
                    if replies.isLoading {
                        ProgressView().tint(.white)
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else if replies.next != nil {
                        Button("Show More Replies") { Task { await model.loadMoreReplies(of: item) } }
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(settings.accentColor)
                            .frame(minHeight: 44)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 64, bottom: 0, trailing: 20))
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .environment(\.colorScheme, .dark)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Composer

    @ViewBuilder
    private var composer: some View {
        if model.canPost, AccountState.shared.isLoggedIn {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Add a comment", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($isComposing)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
                Button("Send", systemImage: "arrow.up") { Task { await send() } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isPosting)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if await model.post(text) {
            draft = ""
            isComposing = false
            Haptics.success()
        }
    }
}

// MARK: - Row

private struct CommentRow: View {
    let item: CommentItem
    var model: CommentsViewModel
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImageView(url: item.author.avatarURL)
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                if item.isPinned {
                    Label(item.pinnedText ?? "Pinned", systemImage: "pin.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Text(byline)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Text(words(of: item))
                    .font(.subheadline)
                    .tint(settings.accentColor)
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == "woof-seek", let seconds = Double(url.host() ?? "") else { return .systemAction }
                        PlayerController.shared.seek(to: seconds)
                        return .handled
                    })
                actions
            }
        }
    }

    private var byline: String {
        let name = item.author.isCreator || item.author.isArtist ? item.author.name + " ✓" : item.author.name
        return [name, item.publishedTime].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 16) {
            Button {
                Haptics.impact()
                Task { await model.toggleLike(item) }
            } label: {
                Label {
                    Text(item.likeCountText)
                } icon: {
                    Image(systemName: item.voteState == .liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .glyphMotion(item.voteState == .liked ? .pop : .deflate, trigger: item.voteState == .liked)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .foregroundStyle(item.voteState == .liked ? settings.accentColor : .white.opacity(0.7))
            .accessibilityLabel("Like")
            .accessibilityValue(item.likeCountText)
            .accessibilityAddTraits(item.voteState == .liked ? .isSelected : [])

            if item.replyContinuation != nil {
                Button {
                    Task { await model.toggleReplies(of: item) }
                } label: {
                    HStack(spacing: 4) {
                        Text(item.replyCountText.isEmpty ? "Replies" : item.replyCountText)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                            .rotationEffect(.degrees(model.replies[item.id]?.isOpen == true ? 180 : 0))
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .foregroundStyle(settings.accentColor)
            }

            if item.isHearted {
                Image(systemName: "heart.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Liked by the artist")
            }
        }
        .font(.footnote.weight(.medium))
        .buttonStyle(ZoomPressStyle())
    }

    /// The comment's words, with links and timestamps that can be tapped.
    private func words(of item: CommentItem) -> AttributedString {
        var result = AttributedString()
        for run in item.runs {
            switch run {
            case .text(let text):
                result += AttributedString(text)
            case .link(let text, let url):
                var part = AttributedString(text)
                part.link = url
                result += part
            case .timestamp(let text, let seconds, _):
                var part = AttributedString(text)
                part.link = URL(string: "woof-seek://\(seconds)")
                result += part
            }
        }
        return result
    }
}
