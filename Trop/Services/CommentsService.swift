//
//  CommentsService.swift
//  Trop
//

import Foundation

enum CommentsError: LocalizedError {
    case disabled
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .disabled: "Comments are off for this song"
        case .rejected(let message): message
        }
    }
}

/// Reads and writes a song's YouTube comments through InnerTube `/next` as the web client:
/// the music client (WEB_REMIX) does not return the comments section. The music host
/// answers first and www.youtube.com is the fallback, as for every comment call.
actor CommentsService {
    static let shared = CommentsService()

    private let music = InnerTubeClient.tropShared
    private let youtube = InnerTubeClient(config: .youtube)

    func loadInitial(videoId: String) async throws -> CommentsPage {
        guard let token = await initialToken(videoId: videoId) else { throw CommentsError.disabled }
        let page = try await loadPage(continuation: token)
        if page.items.isEmpty, page.createCommentParams == nil { throw CommentsError.disabled }
        return page
    }

    func loadPage(continuation: String) async throws -> CommentsPage {
        CommentsParser.parseCommentsPage(try await next(continuation: continuation))
    }

    func loadReplies(continuation: String) async throws -> CommentRepliesPage {
        CommentsParser.parseRepliesPage(try await next(continuation: continuation))
    }

    /// Replays a like or unlike token from the comment. True when YouTube accepted it.
    func vote(action: String) async throws -> Bool {
        let json = try await withFallback { try await $0.performCommentAction(action: action, client: .web) }
        let results = json["actionResults"] as? [[String: Any]]
        return results?.first?["status"] as? String == "STATUS_SUCCEEDED"
    }

    func post(params: String, text: String) async throws {
        let json = try await withFallback { try await $0.createComment(params: params, text: text, client: .web) }
        if let message = Self.failureMessage(json) { throw CommentsError.rejected(message) }
    }

    // MARK: - Private

    private func initialToken(videoId: String) async -> String? {
        for client in [music, youtube] {
            await sync(client)
            if let json = try? await client.next(videoId: videoId, client: .web),
               let token = CommentsParser.findInitialCommentsToken(in: json) {
                return token
            }
        }
        return nil
    }

    private func next(continuation: String) async throws -> [String: Any] {
        try await withFallback { try await $0.next(continuation: continuation, client: .web) }
    }

    private func withFallback(_ call: (InnerTubeClient) async throws -> [String: Any]) async throws -> [String: Any] {
        await sync(music)
        do {
            return try await call(music)
        } catch {
            // After a timeout the request may have arrived: retrying could post a comment twice.
            if (error as? URLError)?.code == .timedOut { throw error }
            await sync(youtube)
            return try await call(youtube)
        }
    }

    private func sync(_ client: InnerTubeClient) async {
        await client.loadState(from: CookieStore())
        await client.syncTropLocale()
    }

    /// The text of the error YouTube answers with a 200, such as a refused comment.
    private static func failureMessage(_ json: [String: Any]) -> String? {
        if let message = (json["error"] as? [String: Any])?["message"] as? String { return message }
        let action = (json["actions"] as? [[String: Any]])?.first?["showErrorAction"] as? [String: Any]
        let text = ((action?["errorMessage"] as? [String: Any])?["messageRenderer"] as? [String: Any])?["text"]
        return ActivityJSON.text(text)
    }
}
