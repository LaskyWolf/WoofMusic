//
//  CommentsViewModel.swift
//  Trop
//

import Foundation

/// The replies of one comment, opened under it.
struct CommentReplies {
    var items: [CommentItem] = []
    var next: String?
    var isLoading = false
    var isOpen = false
}

@MainActor
@Observable
final class CommentsViewModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case disabled
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var items: [CommentItem] = []
    private(set) var totalCountText: String?
    private(set) var sort: CommentSort = .top
    private(set) var replies: [String: CommentReplies] = [:]
    private(set) var isPosting = false
    /// Set when a like or a post did not go through.
    var alert: String?
    /// Posting needs YouTube's own parameters, which come with the comments.
    private(set) var canPost = false

    private let service = CommentsService.shared
    private var videoId = ""
    private var nextToken: String?
    private var sortTokens: [CommentSort: String] = [:]
    private var createParams: String?

    func load(videoId: String) async {
        self.videoId = videoId
        phase = .loading
        items = []
        replies = [:]
        sort = .top
        do {
            apply(try await service.loadInitial(videoId: videoId))
        } catch CommentsError.disabled {
            phase = .disabled
        } catch {
            guard !error.isCancellation else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    func setSort(_ newSort: CommentSort) async {
        guard newSort != sort, let token = sortTokens[newSort] else { return }
        sort = newSort
        phase = .loading
        items = []
        replies = [:]
        do {
            apply(try await service.loadPage(continuation: token))
        } catch {
            guard !error.isCancellation else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    func loadMore(after item: CommentItem) async {
        guard item.id == items.last?.id, let token = nextToken else { return }
        nextToken = nil
        guard let page = try? await service.loadPage(continuation: token) else {
            nextToken = token
            return
        }
        items += page.items.filter { new in !items.contains { $0.id == new.id } }
        nextToken = page.nextPageToken
    }

    func toggleReplies(of item: CommentItem) async {
        var state = replies[item.id] ?? CommentReplies()
        state.isOpen.toggle()
        replies[item.id] = state
        if state.isOpen, state.items.isEmpty, let token = item.replyContinuation { await loadReplies(id: item.id, token: token) }
    }

    func loadMoreReplies(of item: CommentItem) async {
        guard let token = replies[item.id]?.next else { return }
        await loadReplies(id: item.id, token: token)
    }

    func toggleLike(_ item: CommentItem) async {
        let liking = item.voteState != .liked
        guard let action = liking ? item.likeAction : item.unlikeAction else {
            alert = "Sign in to like comments."
            return
        }
        change(item.id) { $0.setLiked(liking) }
        do {
            guard try await service.vote(action: action) else { throw CommentsError.rejected("YouTube didn't accept the like.") }
        } catch {
            change(item.id) { $0.setLiked(!liking) }
            alert = error.localizedDescription
        }
    }

    /// True when it was sent, so the composer keeps the text after a failure.
    func post(_ text: String) async -> Bool {
        guard let params = createParams else { return false }
        isPosting = true
        defer { isPosting = false }
        do {
            try await service.post(params: params, text: text)
            // A new comment is the newest, so it shows at the top of that order.
            if sortTokens[.newest] != nil, sort == .top { await setSort(.newest) } else { await reload() }
            return true
        } catch {
            alert = error.localizedDescription
            return false
        }
    }

    // MARK: - Private

    private func reload() async {
        let current = sort
        await load(videoId: videoId)
        await setSort(current)
    }

    private func apply(_ page: CommentsPage) {
        items = page.items
        nextToken = page.nextPageToken
        if !page.sortTokens.isEmpty { sortTokens = page.sortTokens }
        totalCountText = page.totalCountText ?? totalCountText
        if let params = page.createCommentParams { createParams = params }
        canPost = createParams != nil
        phase = .loaded
    }

    private func loadReplies(id: String, token: String) async {
        replies[id, default: CommentReplies()].isLoading = true
        defer { replies[id]?.isLoading = false }
        do {
            let page = try await service.loadReplies(continuation: token)
            replies[id]?.items += page.items
            replies[id]?.next = page.nextPageToken
        } catch {
            guard !error.isCancellation else { return }
            alert = error.localizedDescription
        }
    }

    /// A comment or a reply, wherever it is.
    private func change(_ id: String, _ edit: (inout CommentItem) -> Void) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            edit(&items[index])
            return
        }
        for key in replies.keys {
            if let index = replies[key]?.items.firstIndex(where: { $0.id == id }) {
                edit(&replies[key]!.items[index])
                return
            }
        }
    }
}

private extension CommentItem {
    /// The vote and a count that follows it. A count in "1.2K" form stays as it is.
    mutating func setLiked(_ liked: Bool) {
        voteState = liked ? .liked : .indifferent
        if let count = Int(likeCountText) { likeCountText = String(max(0, count + (liked ? 1 : -1))) }
        else if likeCountText.isEmpty, liked { likeCountText = "1" }
    }
}
