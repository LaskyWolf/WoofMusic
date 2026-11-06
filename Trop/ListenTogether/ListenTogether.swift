//
//  ListenTogether.swift
//  Trop
//
//  Listen Together: several people hear the same song at the same moment.
//  Each phone streams the music itself; a metroserver relays only what the
//  host does (song, play, pause, seek, queue). Rooms are compatible with
//  Metrolist's, on the same server.
//
//  - Host: every half second the player is compared with what the room was
//    last told, and the difference is sent.
//  - Guest: the room's messages drive the player, and the server's drift
//    reports pull it back when it runs ahead or behind.
//

import Foundation
import Observation

@MainActor
@Observable
final class ListenTogether {
    static let shared = ListenTogether()

    /// Metrolist's public server, so rooms can mix both apps.
    nonisolated static let defaultServerURL = "wss://metroserverx.meowery.eu/ws"

    enum Status: Equatable {
        case idle
        case connecting
        case waitingForApproval
        case inRoom
        /// The connection dropped; trying to get back into the same room.
        case reconnecting
    }

    private(set) var status: Status = .idle
    private(set) var roomCode: String?
    private(set) var myUserId: String?
    private(set) var hostId: String?
    private(set) var users: [LTUser] = []
    /// Host only: people waiting to be let in.
    private(set) var joinRequests: [LTUserEvent] = []
    /// Host only: songs guests asked for.
    private(set) var suggestions: [LTSuggestion] = []
    /// The last thing worth telling the user: an error, a refusal, a kick.
    var notice: String?

    var isInRoom: Bool { roomCode != nil }
    var isHost: Bool { isInRoom && hostId != nil && hostId == myUserId }
    /// While a guest, the room drives playback and AutoMix stays off.
    var isGuest: Bool { isInRoom && !isHost }

    // Connection
    @ObservationIgnored private var connection: ListenTogetherConnection?
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    /// What to ask once the server has answered the capabilities.
    @ObservationIgnored private var pendingRequest: Request?
    @ObservationIgnored private var sessionToken: String?
    @ObservationIgnored private var reconnectAttempts = 0
    @ObservationIgnored private var leaving = false

    /// Server clock minus this phone's clock, in ms, from the pings.
    @ObservationIgnored private var clockOffset: Int64 = 0
    @ObservationIgnored private var pingSequence: UInt64 = 0
    @ObservationIgnored private var lastPing = Date.distantPast

    // Host: what the room was last told.
    @ObservationIgnored private var hostSequence: UInt64 = 0
    @ObservationIgnored private var sentTrackId: String?
    @ObservationIgnored private var sentPlaying = false
    @ObservationIgnored private var sentQueueIds: [String] = []
    @ObservationIgnored private var lastPosition: (seconds: Double, at: Date)?

    // Guest: the track the room is on, until this phone has loaded it.
    @ObservationIgnored private var awaitingBuffer: (trackId: String, revision: UInt64)?
    @ObservationIgnored private var lastDriftFix = Date.distantPast
    /// Members' pictures by YouTube channel ID.
    private var pictures: [String: String] = [:]
    @ObservationIgnored private var pictureRequests: Set<String> = []
    @ObservationIgnored private var myChannelId: String?
    /// The room's song change, held back while this phone's own AutoMix fades
    /// into that song: loading or changing the queue would cut the mix.
    @ObservationIgnored private var pendingLoad: (track: LTTrack, queue: [LTTrack], revision: UInt64)?

    private enum Request {
        case create(username: String)
        case join(code: String, username: String)
        case reconnect(token: String)
    }

    private static let features = [
        "drift_report", "origin_tag", "server_restarting", "suggestion_ack",
        "replace_queue", "host_sequence", "track_revision"
    ]
    /// The most queue entries sent to the room; metroserver caps it too.
    private static let maxQueue = 100
    /// A position jump bigger than this, between two ticks, is a seek.
    private static let seekThreshold = 2.0
    /// Guests further than this from the room jump back into place.
    private static let maxDriftMs: Int64 = 400

    private init() {}

    // MARK: - Actions

    func createRoom() {
        Task {
            await loadChannelId()
            start(.create(username: tagged(username)))
        }
    }

    func joinRoom(code: String) {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else { return }
        Task {
            await loadChannelId()
            start(.join(code: code, username: tagged(username)))
        }
    }

    func leave() {
        leaving = true
        if isInRoom { connection?.send(LTMessage.leaveRoom) }
        shutDown()
        resetRoom()
        status = .idle
    }

    func approve(_ request: LTUserEvent) {
        connection?.send(LTMessage.approveJoin, LTUserAction(userId: request.userId))
        joinRequests.removeAll { $0.userId == request.userId }
    }

    func reject(_ request: LTUserEvent) {
        connection?.send(LTMessage.rejectJoin, LTUserAction(userId: request.userId))
        joinRequests.removeAll { $0.userId == request.userId }
    }

    func approve(_ suggestion: LTSuggestion) {
        connection?.send(LTMessage.approveSuggestion, LTSuggestionAction(suggestionId: suggestion.suggestionId))
        suggestions.removeAll { $0.id == suggestion.id }
    }

    func reject(_ suggestion: LTSuggestion) {
        connection?.send(LTMessage.rejectSuggestion, LTSuggestionAction(suggestionId: suggestion.suggestionId))
        suggestions.removeAll { $0.id == suggestion.id }
    }

    func kick(_ user: LTUser) {
        connection?.send(LTMessage.kickUser, LTUserAction(userId: user.userId))
    }

    func makeHost(_ user: LTUser) {
        connection?.send(LTMessage.transferHost, LTUserAction(userId: user.userId))
    }

    /// Guests ask the host to play a song next.
    func suggest(_ song: SongItem) {
        connection?.send(LTMessage.suggestTrack, LTSuggestTrack(track: Self.track(for: song)))
    }

    // MARK: - Pictures

    // metroserver users have only a name (at most 50 bytes), so WoofMusic adds
    // its YouTube channel ID to it: "Name \u{2063}UC…". Other WoofMusic phones
    // show that channel's picture; Metrolist shows the name with the code.
    private static let channelTag = " \u{2063}"
    private static let maxNameBytes = 50

    /// The name to show, and the YouTube channel a WoofMusic member added to it.
    static func split(_ username: String) -> (name: String, channelId: String?) {
        guard let range = username.range(of: channelTag, options: .backwards) else { return (username, nil) }
        let id = String(username[range.upperBound...])
        guard id.count == 24, id.hasPrefix("UC") else { return (username, nil) }
        return (String(username[..<range.lowerBound]), id)
    }

    /// A member's picture: the account's own for this phone, else the
    /// YouTube channel's, fetched once. Nil for a name without a channel.
    func pictureURL(for user: LTUser) -> String? {
        if user.userId == myUserId { return AccountState.shared.accountImageUrl }
        return pictureURL(forName: user.username)
    }

    func pictureURL(forName username: String) -> String? {
        guard let id = Self.split(username).channelId else { return nil }
        if let url = pictures[id] { return url }
        if !pictureRequests.contains(id) {
            pictureRequests.insert(id)
            Task { pictures[id] = await Self.channelPicture(id) }
        }
        return nil
    }

    private func tagged(_ name: String) -> String {
        guard let channelId = myChannelId else { return name }
        let suffix = Self.channelTag + channelId
        var name = name
        while !name.isEmpty, name.utf8.count + suffix.utf8.count > Self.maxNameBytes { name.removeLast() }
        return name + suffix
    }

    /// This account's channel, from the "Your channel" link of the account menu.
    private func loadChannelId() async {
        guard myChannelId == nil, AccountState.shared.isLoggedIn,
              let menu = try? await InnerTubeClient.tropShared.accountMenu() else { return }
        myChannelId = Self.values(for: "browseId", in: menu)
            .compactMap { $0 as? String }
            .first { $0.count == 24 && $0.hasPrefix("UC") }
    }

    /// The channel page's avatar (`foregroundThumbnail`), else its header image.
    private static func channelPicture(_ channelId: String) async -> String? {
        guard let page = try? await InnerTubeClient.tropShared.browse(browseId: channelId),
              let header = page["header"] else { return nil }
        let image = values(for: "foregroundThumbnail", in: header).first ?? values(for: "thumbnail", in: header).first
        let thumbnails = image.flatMap { values(for: "thumbnails", in: $0).first } as? [[String: Any]]
        return InnerTubeJSON.lastThumbnailURL(thumbnails)
    }

    /// Every value stored under `key` anywhere in a JSON tree, outermost first.
    private static func values(for key: String, in json: Any) -> [Any] {
        if let dict = json as? [String: Any] {
            return (dict[key].map { [$0] } ?? []) + dict.values.flatMap { values(for: key, in: $0) }
        }
        if let array = json as? [Any] { return array.flatMap { values(for: key, in: $0) } }
        return []
    }

    // MARK: - Connection

    private var username: String {
        let name = SettingsStore.shared.listenTogetherUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let account = AccountState.shared.accountName
        return account == "Guest" ? "WoofMusic listener" : account
    }

    private func start(_ request: Request) {
        leaving = false
        notice = nil
        shutDown()
        if case .reconnect = request {
            status = .reconnecting
        } else {
            resetRoom()
            status = .connecting
        }
        let text = SettingsStore.shared.listenTogetherServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text.isEmpty ? Self.defaultServerURL : text),
              url.scheme == "ws" || url.scheme == "wss" else {
            notice = "The server address must start with wss:// or ws://."
            status = .idle
            return
        }
        pendingRequest = request
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let connection = ListenTogetherConnection(url: url, userAgent: "WoofMusic/\(version) (iOS)")
        self.connection = connection
        connection.send(LTMessage.clientCapabilities, LTClientCapabilities(clientVersion: "WoofMusic \(version)", features: Self.features))
        listenTask = Task { [weak self] in
            for await event in connection.events {
                guard let self, self.connection === connection else { return }
                self.handle(event)
            }
        }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func shutDown() {
        listenTask?.cancel()
        tickTask?.cancel()
        reconnectTask?.cancel()
        connection?.close()
        connection = nil
    }

    private func resetRoom() {
        roomCode = nil
        myUserId = nil
        hostId = nil
        users = []
        joinRequests = []
        suggestions = []
        sessionToken = nil
        reconnectAttempts = 0
        sentTrackId = nil
        sentQueueIds = []
        lastPosition = nil
        awaitingBuffer = nil
        pendingLoad = nil
    }

    private func handle(_ event: ListenTogetherConnection.Event) {
        switch event {
        case .opened:
            break
        case .message(let type, let payload):
            do {
                try handleMessage(type, payload)
            } catch {
                Log.player.warning("Listen Together: unreadable \(type): \(error)")
            }
        case .closed(let reason):
            Log.player.info("Listen Together: connection closed: \(reason)")
            connection = nil
            tickTask?.cancel()
            if leaving { return }
            if let token = sessionToken, isInRoom {
                scheduleReconnect(token: token)
            } else {
                notice = status == .connecting ? "Couldn't reach the Listen Together server." : "Disconnected from the room."
                resetRoom()
                status = .idle
            }
        }
    }

    /// Tries again with a growing pause, up to about 15 minutes: how long the
    /// server keeps a place in the room.
    private func scheduleReconnect(token: String, after seconds: Double? = nil) {
        status = .reconnecting
        reconnectAttempts += 1
        guard reconnectAttempts <= 30 else {
            notice = "Lost the connection to the room."
            resetRoom()
            status = .idle
            return
        }
        let delay = seconds ?? min(30, pow(2, Double(reconnectAttempts - 1)))
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.status == .reconnecting else { return }
            self.start(.reconnect(token: token))
        }
    }

    // MARK: - Messages

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func handleMessage(_ type: String, _ payload: Data) throws {
        switch type {
        case LTMessage.serverCapabilities:
            switch pendingRequest {
            case .create(let name): connection?.send(LTMessage.createRoom, LTCreateRoom(username: name))
            case .join(let code, let name):
                connection?.send(LTMessage.joinRoom, LTJoinRoom(roomCode: code, username: name))
                status = .waitingForApproval
            case .reconnect(let token): connection?.send(LTMessage.reconnect, LTReconnect(sessionToken: token))
            case nil: break
            }
            pendingRequest = nil

        case LTMessage.roomCreated:
            enter(try LTJoined.decode(.created, payload))
        case LTMessage.joinApproved:
            enter(try LTJoined.decode(.approved, payload))
        case LTMessage.reconnected:
            enter(try LTJoined.decode(.reconnected, payload))
        case LTMessage.joinRejected:
            let reason = try LTNotice(decoding: payload).code
            notice = reason.isEmpty ? "The host didn't let you in." : "The host didn't let you in: \(reason)"
            leaveQuietly()
        case LTMessage.kicked:
            let reason = try LTNotice(decoding: payload).code
            notice = reason.isEmpty ? "The host removed you from the room." : "Removed from the room: \(reason)"
            leaveQuietly()

        case LTMessage.joinRequest:
            let request = try LTUserEvent(decoding: payload)
            joinRequests.removeAll { $0.userId == request.userId }
            joinRequests.append(request)
        case LTMessage.userJoined:
            let user = try LTUserEvent(decoding: payload)
            users.removeAll { $0.userId == user.userId }
            users.append(LTUser(userId: user.userId, username: user.username, isHost: false, isConnected: true))
            joinRequests.removeAll { $0.userId == user.userId }
        case LTMessage.userLeft:
            let user = try LTUserEvent(decoding: payload)
            users.removeAll { $0.userId == user.userId }
        case LTMessage.userDisconnected, LTMessage.userReconnected:
            let user = try LTUserEvent(decoding: payload)
            if let index = users.firstIndex(where: { $0.userId == user.userId }) {
                users[index].isConnected = type == LTMessage.userReconnected
            }
        case LTMessage.hostChanged:
            setHost(try LTUserEvent(decoding: payload).userId)

        case LTMessage.syncPlayback:
            let playback = try LTPlayback(decoding: payload)
            isHost ? hostReceived(playback) : guestApply(playback)
        case LTMessage.syncState:
            let state = try LTSyncState(decoding: payload)
            if isGuest {
                guestLoad(state.currentTrack, queue: state.queue, revision: 0)
            }

        case LTMessage.suggestionReceived:
            suggestions.append(try LTSuggestion.decode(.received, payload))
        case LTMessage.suggestionApproved:
            let track = try LTSuggestion.decode(.approved, payload).track
            if !isHost { notice = "The host added \(track.title)." }
        case LTMessage.suggestionRejected:
            if !isHost { notice = "The host passed on your suggestion." }
        case LTMessage.suggestionSubmitted:
            notice = "Suggestion sent to the host."

        case LTMessage.pong:
            handlePong(try LTPong(decoding: payload))
        case LTMessage.serverRestarting:
            let eta = Double(try LTServerRestarting(decoding: payload).etaMs) / 1000
            if let token = sessionToken {
                leavingForRestart(token: token, after: max(1, eta) + Double.random(in: 0...2))
            }
        case LTMessage.error:
            let error = try LTNotice(decoding: payload)
            Log.player.warning("Listen Together error \(error.code): \(error.message)")
            // Races the next message repairs on its own.
            if ["stale_action", "stale_track", "sync_rate_limited"].contains(error.code) { return }
            if status == .reconnecting {
                notice = "The room has closed."
                leaveQuietly()
                return
            }
            notice = error.message.isEmpty ? error.code : error.message
            if status == .waitingForApproval || status == .connecting { leaveQuietly() }
        default:
            break
        }
    }

    private func enter(_ joined: LTJoined) {
        roomCode = joined.roomCode
        myUserId = joined.userId
        if !joined.sessionToken.isEmpty { sessionToken = joined.sessionToken }
        reconnectAttempts = 0
        status = .inRoom
        if let state = joined.state {
            users = state.users
            setHost(state.hostId)
            if isGuest {
                guestLoad(state.currentTrack, queue: state.queue, revision: 0)
            }
        } else {
            // A new room: just this phone, as its host.
            users = [LTUser(userId: joined.userId, username: username, isHost: true, isConnected: true)]
            setHost(joined.userId)
        }
    }

    private func setHost(_ id: String) {
        let wasHost = isHost
        hostId = id
        for index in users.indices { users[index].isHost = users[index].userId == id }
        guard isHost, !wasHost else { return }
        // Just became host: the room is already on this song, so only what
        // changes from here on is sent. A new room hears the song from scratch.
        let np = NowPlaying.shared
        let roomHasSong = users.count > 1
        sentTrackId = roomHasSong ? np.videoId : nil
        sentPlaying = roomHasSong && np.isPlaying
        sentQueueIds = roomHasSong ? np.upcomingSongs(prefixLimit: Self.maxQueue).map(\.videoId) : []
        lastPosition = nil
        awaitingBuffer = nil
    }

    /// Ends the room locally, without telling the server (it already knows).
    private func leaveQuietly() {
        leaving = true
        shutDown()
        resetRoom()
        status = .idle
    }

    private func leavingForRestart(token: String, after seconds: Double) {
        leaving = true
        shutDown()
        leaving = false
        scheduleReconnect(token: token, after: seconds)
    }

    // MARK: - Clock

    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private var serverNowMs: Int64 { nowMs + clockOffset }

    private func sendPing() {
        lastPing = Date()
        pingSequence += 1
        var ping = LTPing()
        ping.clientTime = nowMs
        ping.sequence = pingSequence
        // A guest playing a loaded song reports where it is, for the drift check.
        let np = NowPlaying.shared
        if isGuest, awaitingBuffer == nil, pendingLoad == nil, np.isPlaying, !np.isLoadingTrack, let id = np.videoId {
            ping.trackId = id
            ping.position = Int64(np.currentTime * 1000)
            ping.capturedAt = serverNowMs
        }
        connection?.send(LTMessage.ping, ping)
    }

    private func handlePong(_ pong: LTPong) {
        // Assumes the trip there and back take as long: the usual NTP guess.
        let received = nowMs
        clockOffset = ((pong.serverReceiveTime - pong.clientTime) + (pong.serverSendTime - received)) / 2
        guard isGuest, pong.driftValid, abs(pong.driftMs) > Self.maxDriftMs,
              Date().timeIntervalSince(lastDriftFix) > 4 else { return }
        let np = NowPlaying.shared
        guard np.isPlaying, !np.isLoadingTrack, !PlayerController.shared.isCrossfading else { return }
        lastDriftFix = Date()
        PlayerController.shared.seek(to: max(0, np.currentTime - Double(pong.driftMs) / 1000))
    }

    // MARK: - Tick

    private func tick() {
        guard connection != nil else { return }
        if Date().timeIntervalSince(lastPing) >= 5 { sendPing() }
        guard status == .inRoom else { return }
        if isHost {
            hostTick()
        } else {
            guestTick()
        }
    }

    // MARK: - Host

    private func hostTick() {
        let np = NowPlaying.shared
        guard let videoId = np.videoId, let song = np.currentSong, song.videoId == videoId else { return }
        let upcoming = np.upcomingSongs(prefixLimit: Self.maxQueue)
        let queueIds = upcoming.map(\.videoId)

        if videoId != sentTrackId {
            var change = action(.changeTrack)
            change.track = Self.track(for: song, duration: np.duration)
            change.queue = upcoming.map { Self.track(for: $0) }
            change.replaceQueue = true
            connection?.send(LTMessage.playbackAction, change)
            sentTrackId = videoId
            // change_track leaves the room paused at 0; play follows once loaded.
            sentPlaying = false
            sentQueueIds = queueIds
            lastPosition = nil
            return
        }
        if queueIds != sentQueueIds {
            var sync = action(.syncQueue)
            sync.queue = upcoming.map { Self.track(for: $0) }
            connection?.send(LTMessage.playbackAction, sync)
            sentQueueIds = queueIds
        }
        guard !np.isLoadingTrack else { return }

        let position = np.currentTime
        if np.isPlaying != sentPlaying {
            sendTransport(np.isPlaying ? .play : .pause, trackId: videoId, position: position)
            sentPlaying = np.isPlaying
        } else if let last = lastPosition {
            let expected = last.seconds + (np.isPlaying ? Date().timeIntervalSince(last.at) : 0)
            if abs(position - expected) > Self.seekThreshold {
                sendTransport(.seek, trackId: videoId, position: position)
            }
        }
        lastPosition = (position, Date())
    }

    private func action(_ kind: LTPlayback.Action) -> LTPlayback {
        hostSequence += 1
        var playback = LTPlayback(kind)
        playback.hostSequence = hostSequence
        return playback
    }

    private func sendTransport(_ kind: LTPlayback.Action, trackId: String, position: Double) {
        var playback = action(kind)
        playback.trackId = trackId
        playback.position = Int64(max(0, position) * 1000)
        playback.capturedAt = serverNowMs
        connection?.send(LTMessage.playbackAction, playback)
    }

    /// The host's own actions come back too; only a suggestion the host
    /// approved needs doing here: it plays next.
    private func hostReceived(_ playback: LTPlayback) {
        guard playback.action == LTPlayback.Action.queueAdd.rawValue,
              playback.originUserId != myUserId, let track = playback.track else { return }
        NowPlaying.shared.enqueueNext(Self.song(for: track))
    }

    // MARK: - Guest

    private func guestApply(_ playback: LTPlayback) {
        let np = NowPlaying.shared
        let player = PlayerController.shared
        // Where the host is now: the position plus the time since the server sent it.
        let elapsed = Double(max(0, serverNowMs - playback.serverTime)) / 1000
        let position = Double(playback.position) / 1000
        switch LTPlayback.Action(rawValue: playback.action) {
        case .changeTrack:
            guestLoad(playback.track, queue: playback.queue, revision: playback.revision)
        case .play:
            guard awaitingBuffer == nil, pendingLoad == nil, playback.trackId == np.videoId else { return }
            let target = position + elapsed
            if abs(np.currentTime - target) > 0.5 { player.seek(to: target) }
            player.setPaused(false)
        case .pause:
            guard awaitingBuffer == nil, pendingLoad == nil, playback.trackId == np.videoId else { return }
            player.setPaused(true)
            player.seek(to: position)
        case .seek:
            guard awaitingBuffer == nil, pendingLoad == nil, playback.trackId == np.videoId else { return }
            player.seek(to: np.isPlaying ? position + elapsed : position)
        case .queueAdd, .queueRemove, .queueClear, .syncQueue:
            guestSetQueue(playback.queue)
        case nil:
            break
        }
    }

    /// Puts the room's song on this phone, paused: once it has loaded,
    /// `buffer_ready` asks the server where the room is, and it answers with
    /// a seek and a play.
    private func guestLoad(_ track: LTTrack?, queue: [LTTrack], revision: UInt64) {
        guard let track, !track.id.isEmpty else {
            guestSetQueue(queue)
            return
        }
        if Crossfade.shared.mixingInto == track.id {
            // This phone is already mixing into the room's song: `guestTick`
            // loads it once the mix ends, which finds it already playing.
            pendingLoad = (track, queue, revision)
            return
        }
        pendingLoad = nil
        let np = NowPlaying.shared
        let songs = [Self.song(for: track)] + queue.map(Self.song(for:))
        awaitingBuffer = (track.id, revision)
        if np.videoId == track.id {
            // Already here, e.g. this phone reached the song on its own.
            np.setQueue(songs, startIndex: 0)
            return
        }
        np.setQueue(songs, startIndex: 0)
        np.playCurrentSong(logContext: "Listen Together")
        // Paused once the load starts (pausing before it is undone by the
        // load), so the song doesn't play from 0 before the room's position.
        Task {
            for _ in 0..<80 {
                if np.isLoadingTrack {
                    PlayerController.shared.setPaused(true)
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    private func guestSetQueue(_ queue: [LTTrack]) {
        if pendingLoad != nil {
            pendingLoad?.queue = queue
            return
        }
        let np = NowPlaying.shared
        guard let current = np.currentSong else { return }
        np.setQueue([current] + queue.map(Self.song(for:)), startIndex: 0)
    }

    private func guestTick() {
        let np = NowPlaying.shared
        if let pending = pendingLoad, Crossfade.shared.mixingInto != pending.track.id {
            guestLoad(pending.track, queue: pending.queue, revision: pending.revision)
        }
        guard let waiting = awaitingBuffer, np.videoId == waiting.trackId, !np.isLoadingTrack, np.duration > 0 else { return }
        awaitingBuffer = nil
        connection?.send(LTMessage.bufferReady, LTBufferReady(trackId: waiting.trackId, trackRevision: waiting.revision))
    }

    // MARK: - Tracks

    static func track(for song: SongItem, duration: Double = 0) -> LTTrack {
        var track = LTTrack()
        track.id = song.videoId
        track.title = song.title
        track.artist = song.artists.map(\.name).filter { !$0.isEmpty }.joined(separator: ", ")
        track.album = song.album ?? ""
        track.duration = Int64((duration > 0 ? duration : Double(song.duration)) * 1000)
        track.thumbnail = song.thumbnailUrl ?? ""
        return track
    }

    static func song(for track: LTTrack) -> SongItem {
        SongItem(
            videoId: track.id,
            title: track.title,
            artists: track.artist.isEmpty ? [] : [YTArtist(name: track.artist, id: nil)],
            album: track.album.isEmpty ? nil : track.album,
            duration: Int(track.duration / 1000),
            thumbnailUrl: track.thumbnail.isEmpty ? nil : track.thumbnail,
            isExplicit: false
        )
    }
}
