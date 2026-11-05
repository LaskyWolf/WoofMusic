//
//  ListenTogetherConnection.swift
//  Trop
//
//  One WebSocket to a metroserver: sends envelopes, delivers the ones that
//  arrive. Knows nothing about rooms; `ListenTogether` does.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ListenTogetherConnection: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum Event {
        case opened
        case message(type: String, payload: Data)
        /// The socket is gone: closed by either side or failed.
        case closed(reason: String)
    }

    /// Delivered in order. Ends after `.closed`.
    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var isClosed = false

    init(url: URL, userAgent: String) {
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
        super.init()
        var request = URLRequest(url: url)
        // metroserver's operators can set rules per client; this names the app.
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        task.resume()
        receive()
    }

    func send(_ type: String, _ payload: some ProtoMessage, requestId: UInt64 = 0) {
        let envelope = LTEnvelope(type: type, payload: payload.encoded(), requestId: requestId)
        task?.send(.data(envelope.encoded())) { [weak self] error in
            if let error { self?.finish("send failed: \(error.localizedDescription)") }
        }
    }

    /// A message with no payload, like leave_room or request_sync.
    func send(_ type: String) {
        send(type, LTEmpty())
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
        finish("closed by the app")
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                let data: Data
                switch message {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: data = Data()
                }
                if let envelope = try? LTEnvelope(decoding: data), !envelope.compressed {
                    continuation.yield(.message(type: envelope.type, payload: envelope.payload))
                }
                receive()
            case .failure(let error):
                finish(error.localizedDescription)
            }
        }
    }

    private func finish(_ reason: String) {
        lock.lock()
        let wasClosed = isClosed
        isClosed = true
        lock.unlock()
        guard !wasClosed else { return }
        continuation.yield(.closed(reason: reason))
        continuation.finish()
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        continuation.yield(.opened)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        finish("server closed the connection (\(closeCode.rawValue))")
    }
}

/// Message type names, as metroserver spells them.
enum LTMessage {
    static let clientCapabilities = "client_capabilities"
    static let serverCapabilities = "server_capabilities"
    static let createRoom = "create_room"
    static let joinRoom = "join_room"
    static let leaveRoom = "leave_room"
    static let approveJoin = "approve_join"
    static let rejectJoin = "reject_join"
    static let playbackAction = "playback_action"
    static let bufferReady = "buffer_ready"
    static let kickUser = "kick_user"
    static let transferHost = "transfer_host"
    static let ping = "ping"
    static let requestSync = "request_sync"
    static let reconnect = "reconnect"
    static let suggestTrack = "suggest_track"
    static let approveSuggestion = "approve_suggestion"
    static let rejectSuggestion = "reject_suggestion"

    static let roomCreated = "room_created"
    static let joinRequest = "join_request"
    static let joinApproved = "join_approved"
    static let joinRejected = "join_rejected"
    static let userJoined = "user_joined"
    static let userLeft = "user_left"
    static let syncPlayback = "sync_playback"
    static let bufferWait = "buffer_wait"
    static let bufferComplete = "buffer_complete"
    static let error = "error"
    static let pong = "pong"
    static let hostChanged = "host_changed"
    static let kicked = "kicked"
    static let syncState = "sync_state"
    static let reconnected = "reconnected"
    static let userReconnected = "user_reconnected"
    static let userDisconnected = "user_disconnected"
    static let suggestionReceived = "suggestion_received"
    static let suggestionApproved = "suggestion_approved"
    static let suggestionRejected = "suggestion_rejected"
    static let suggestionSubmitted = "suggestion_submitted"
    static let serverRestarting = "server_restarting"
}
