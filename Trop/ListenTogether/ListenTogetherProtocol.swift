//
//  ListenTogetherProtocol.swift
//  Trop
//
//  The messages of metroserver, the Listen Together server Metrolist uses:
//  protobuf envelopes over a WebSocket. The schema is
//  github.com/MetrolistGroup/metroproto (listentogether.proto); field numbers
//  below match it. Only Foundation, so it builds and tests anywhere.
//

import Foundation

// MARK: - Protobuf wire format

/// Writes the protobuf fields these messages use. Default values are left
/// out, as protobuf itself does.
struct ProtoWriter {
    private(set) var data = Data()

    private mutating func varint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }

    private mutating func tag(_ field: Int, _ wireType: UInt64) {
        varint(UInt64(field) << 3 | wireType)
    }

    mutating func uint(_ field: Int, _ value: UInt64) {
        guard value != 0 else { return }
        tag(field, 0)
        varint(value)
    }

    mutating func int(_ field: Int, _ value: Int64) {
        uint(field, UInt64(bitPattern: value))
    }

    mutating func bool(_ field: Int, _ value: Bool) {
        uint(field, value ? 1 : 0)
    }

    mutating func float(_ field: Int, _ value: Float) {
        guard value != 0 else { return }
        tag(field, 5)
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        guard !value.isEmpty else { return }
        tag(field, 2)
        varint(UInt64(value.count))
        data.append(value)
    }

    mutating func string(_ field: Int, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    mutating func message(_ field: Int, _ value: some ProtoMessage) {
        tag(field, 2)
        let encoded = value.encoded()
        varint(UInt64(encoded.count))
        data.append(encoded)
    }
}

/// Reads protobuf fields; unknown fields are skipped, so newer servers
/// can add some.
struct ProtoReader {
    enum Value {
        case varint(UInt64)
        case fixed32(UInt32)
        case fixed64(UInt64)
        case bytes(Data)

        var uint: UInt64 {
            if case .varint(let v) = self { return v }
            return 0
        }
        var int: Int64 { Int64(bitPattern: uint) }
        var bool: Bool { uint != 0 }
        var float: Float {
            if case .fixed32(let v) = self { return Float(bitPattern: v) }
            return 0
        }
        var data: Data {
            if case .bytes(let d) = self { return d }
            return Data()
        }
        var string: String { String(decoding: data, as: UTF8.self) }
    }

    struct Malformed: Error {}

    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    private mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < bytes.count, shift < 64 else { throw Malformed() }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    private mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, index + count <= bytes.count else { throw Malformed() }
        defer { index += count }
        return Array(bytes[index..<index + count])
    }

    /// Calls `body` with each field number and value, in order.
    static func fields(of data: Data, _ body: (Int, Value) throws -> Void) throws {
        var reader = ProtoReader(data)
        while reader.index < reader.bytes.count {
            let key = try reader.varint()
            let field = Int(key >> 3)
            let value: Value
            switch key & 7 {
            case 0: value = .varint(try reader.varint())
            case 1: value = .fixed64(try reader.take(8).reversed().reduce(0) { $0 << 8 | UInt64($1) })
            case 2: value = .bytes(Data(try reader.take(Int(try reader.varint()))))
            case 5: value = .fixed32(try reader.take(4).reversed().reduce(0) { $0 << 8 | UInt32($1) })
            default: throw Malformed()
            }
            try body(field, value)
        }
    }
}

protocol ProtoMessage {
    init()
    func write(to writer: inout ProtoWriter)
    mutating func read(_ field: Int, _ value: ProtoReader.Value) throws
}

extension ProtoMessage {
    func encoded() -> Data {
        var writer = ProtoWriter()
        write(to: &writer)
        return writer.data
    }

    init(decoding data: Data) throws {
        self.init()
        try ProtoReader.fields(of: data) { try read($0, $1) }
    }

    // Most messages only travel one way: the other direction does nothing.
    func write(to writer: inout ProtoWriter) {}
    mutating func read(_ field: Int, _ value: ProtoReader.Value) throws {}
}

// MARK: - Envelope

/// Every WebSocket frame: the message type and its encoded payload.
struct LTEnvelope: ProtoMessage {
    var type = ""
    var payload = Data()
    /// The server gzips payloads only for clients that ask for it; this one doesn't.
    var compressed = false
    var requestId: UInt64 = 0

    func write(to w: inout ProtoWriter) {
        w.string(1, type)
        w.bytes(2, payload)
        w.bool(3, compressed)
        w.uint(4, requestId)
    }

    mutating func read(_ field: Int, _ v: ProtoReader.Value) throws {
        switch field {
        case 1: type = v.string
        case 2: payload = v.data
        case 3: compressed = v.bool
        case 4: requestId = v.uint
        default: break
        }
    }
}

// MARK: - Shared

struct LTTrack: ProtoMessage, Hashable {
    var id = ""
    var title = ""
    var artist = ""
    var album = ""
    /// Milliseconds.
    var duration: Int64 = 0
    var thumbnail = ""
    var suggestedBy = ""

    func write(to w: inout ProtoWriter) {
        w.string(1, id)
        w.string(2, title)
        w.string(3, artist)
        w.string(4, album)
        w.int(5, duration)
        w.string(6, thumbnail)
        w.string(7, suggestedBy)
    }

    mutating func read(_ field: Int, _ v: ProtoReader.Value) throws {
        switch field {
        case 1: id = v.string
        case 2: title = v.string
        case 3: artist = v.string
        case 4: album = v.string
        case 5: duration = v.int
        case 6: thumbnail = v.string
        case 7: suggestedBy = v.string
        default: break
        }
    }
}

struct LTUser: ProtoMessage, Hashable, Identifiable {
    var userId = ""
    var username = ""
    var isHost = false
    var isConnected = false

    var id: String { userId }

    mutating func read(_ field: Int, _ v: ProtoReader.Value) throws {
        switch field {
        case 1: userId = v.string
        case 2: username = v.string
        case 3: isHost = v.bool
        case 4: isConnected = v.bool
        default: break
        }
    }
}

struct LTRoomState: ProtoMessage {
    var roomCode = ""
    var hostId = ""
    var users: [LTUser] = []
    var currentTrack: LTTrack?
    var isPlaying = false
    /// Milliseconds into the track at `lastUpdate` (server clock, ms).
    var position: Int64 = 0
    var lastUpdate: Int64 = 0
    var queue: [LTTrack] = []
    var revision: UInt64 = 0
    var queueTitle = ""

    mutating func read(_ field: Int, _ v: ProtoReader.Value) throws {
        switch field {
        case 1: roomCode = v.string
        case 2: hostId = v.string
        case 3: users.append(try LTUser(decoding: v.data))
        case 4: currentTrack = try LTTrack(decoding: v.data)
        case 5: isPlaying = v.bool
        case 6: position = v.int
        case 7: lastUpdate = v.int
        case 9: queue.append(try LTTrack(decoding: v.data))
        case 10: revision = v.uint
        case 11: queueTitle = v.string
        default: break
        }
    }
}

// MARK: - Client to server

/// leave_room and request_sync carry nothing.
struct LTEmpty: ProtoMessage {}

struct LTClientCapabilities: ProtoMessage {
    var clientVersion = ""
    var features: [String] = []

    func write(to w: inout ProtoWriter) {
        w.bool(1, true) // supports_protobuf
        w.bool(2, false) // supports_compression
        w.string(3, clientVersion)
        for feature in features { w.string(4, feature) }
    }
}

struct LTCreateRoom: ProtoMessage {
    var username = ""
    func write(to w: inout ProtoWriter) { w.string(1, username) }
}

struct LTJoinRoom: ProtoMessage {
    var roomCode = ""
    var username = ""
    func write(to w: inout ProtoWriter) {
        w.string(1, roomCode)
        w.string(2, username)
    }
}

/// A user ID with an optional reason: approve_join, reject_join, kick_user and
/// transfer_host all have this shape.
struct LTUserAction: ProtoMessage {
    var userId = ""
    var reason = ""
    func write(to w: inout ProtoWriter) {
        w.string(1, userId)
        w.string(2, reason)
    }
}

/// approve_suggestion and reject_suggestion.
struct LTSuggestionAction: ProtoMessage {
    var suggestionId = ""
    var reason = ""
    func write(to w: inout ProtoWriter) {
        w.string(1, suggestionId)
        w.string(2, reason)
    }
}

struct LTSuggestTrack: ProtoMessage {
    var track = LTTrack()
    func write(to w: inout ProtoWriter) { w.message(1, track) }
}

struct LTReconnect: ProtoMessage {
    var sessionToken = ""
    func write(to w: inout ProtoWriter) { w.string(1, sessionToken) }
}

struct LTBufferReady: ProtoMessage {
    var trackId = ""
    var trackRevision: UInt64 = 0
    func write(to w: inout ProtoWriter) {
        w.string(1, trackId)
        w.uint(2, trackRevision)
    }
}

struct LTPing: ProtoMessage {
    var clientTime: Int64 = 0
    var sequence: UInt64 = 0
    /// Drift report: where this listener is in `trackId`, sampled at
    /// `capturedAt` on the server's clock.
    var trackId: String?
    var position: Int64 = 0
    var capturedAt: Int64 = 0

    func write(to w: inout ProtoWriter) {
        w.int(1, clientTime)
        w.uint(2, sequence)
        if let trackId {
            w.bool(3, true)
            w.string(4, trackId)
            w.int(5, position)
            w.int(6, capturedAt)
        }
    }
}

// MARK: - Both ways

/// playback_action (host to server) and sync_playback (server to everyone).
struct LTPlayback: ProtoMessage {
    enum Action: String {
        case play, pause, seek
        case changeTrack = "change_track"
        case queueAdd = "queue_add"
        case queueRemove = "queue_remove"
        case queueClear = "queue_clear"
        case syncQueue = "sync_queue"
    }

    var action = ""
    var trackId = ""
    /// Milliseconds.
    var position: Int64 = 0
    var track: LTTrack?
    var insertNext = false
    var queue: [LTTrack] = []
    var queueTitle = ""
    /// Server clock (ms) when the server sent it.
    var serverTime: Int64 = 0
    var revision: UInt64 = 0
    /// Server clock (ms) when the host read `position`.
    var capturedAt: Int64 = 0
    var replaceQueue = false
    var originUserId = ""
    var hostSequence: UInt64 = 0

    init() {}

    init(_ action: Action) {
        self.action = action.rawValue
    }

    func write(to w: inout ProtoWriter) {
        w.string(1, action)
        w.string(2, trackId)
        w.int(3, position)
        if let track { w.message(4, track) }
        w.bool(5, insertNext)
        for item in queue { w.message(6, item) }
        w.string(7, queueTitle)
        w.uint(10, revision)
        w.int(11, capturedAt)
        w.bool(12, replaceQueue)
        w.uint(14, hostSequence)
    }

    mutating func read(_ field: Int, _ v: ProtoReader.Value) throws {
        switch field {
        case 1: action = v.string
        case 2: trackId = v.string
        case 3: position = v.int
        case 4: track = try LTTrack(decoding: v.data)
        case 5: insertNext = v.bool
        case 6: queue.append(try LTTrack(decoding: v.data))
        case 7: queueTitle = v.string
        case 9: serverTime = v.int
        case 10: revision = v.uint
        case 11: capturedAt = v.int
        case 12: replaceQueue = v.bool
        case 13: originUserId = v.string
        case 14: hostSequence = v.uint
        default: break
        }
    }
}

// MARK: - Server to client

struct LTServerCapabilities: ProtoMessage {
    var serverVersion = ""
    var features: [String] = []
    var canHost = false

    mutating func read(_ field: Int, _ v: ProtoReader.Value) throws {
        switch field {
        case 3: serverVersion = v.string
        case 4: features.append(v.string)
        case 5: canHost = v.bool
        default: break
        }
    }
}

/// room_created, join_approved and reconnected: where this client now is.
struct LTJoined: ProtoMessage {
    var roomCode = ""
    var userId = ""
    var sessionToken = ""
    var state: LTRoomState?
    var isHost = false

    /// The three messages number the same fields differently.
    enum Kind { case created, approved, reconnected }

    static func decode(_ kind: Kind, _ data: Data) throws -> LTJoined {
        var joined = LTJoined()
        try ProtoReader.fields(of: data) { field, v in
            switch (kind, field) {
            case (_, 1): joined.roomCode = v.string
            case (_, 2): joined.userId = v.string
            case (.created, 3), (.approved, 3): joined.sessionToken = v.string
            case (.approved, 4), (.reconnected, 3): joined.state = try LTRoomState(decoding: v.data)
            case (.reconnected, 4): joined.isHost = v.bool
            default: break
            }
        }
        if kind == .created { joined.isHost = true }
        return joined
    }
}

/// join_request, user_joined, user_left, user_reconnected, user_disconnected,
/// host_changed: a user ID and name.
struct LTUserEvent: ProtoMessage, Hashable, Identifiable {
    var userId = ""
    var username = ""

    var id: String { userId }

    mutating func read(_ field: Int, _ v: ProtoReader.Value) throws {
        switch field {
        case 1: userId = v.string
        case 2: username = v.string
        default: break
        }
    }
}

/// error (code, message), join_rejected and kicked (a reason in field 1).
struct LTNotice: ProtoMessage {
    var code = ""
    var message = ""

    mutating func read(_ field: Int, _ v: ProtoReader.Value) throws {
        switch field {
        case 1: code = v.string
        case 2: message = v.string
        default: break
        }
    }
}

struct LTSyncState: ProtoMessage {
    var currentTrack: LTTrack?
    var isPlaying = false
    var position: Int64 = 0
    var lastUpdate: Int64 = 0
    var queue: [LTTrack] = []
    var revision: UInt64 = 0
    var queueTitle = ""

    mutating func read(_ field: Int, _ v: ProtoReader.Value) throws {
        switch field {
        case 1: currentTrack = try LTTrack(decoding: v.data)
        case 2: isPlaying = v.bool
        case 3: position = v.int
        case 4: lastUpdate = v.int
        case 5: queue.append(try LTTrack(decoding: v.data))
        case 7: revision = v.uint
        case 8: queueTitle = v.string
        default: break
        }
    }
}

struct LTPong: ProtoMessage {
    var clientTime: Int64 = 0
    var serverReceiveTime: Int64 = 0
    var serverSendTime: Int64 = 0
    var sequence: UInt64 = 0
    var driftValid = false
    /// This listener's position minus the room's (positive = ahead).
    var driftMs: Int64 = 0

    mutating func read(_ field: Int, _ v: ProtoReader.Value) throws {
        switch field {
        case 1: clientTime = v.int
        case 2: serverReceiveTime = v.int
        case 3: serverSendTime = v.int
        case 4: sequence = v.uint
        case 5: driftValid = v.bool
        case 6: driftMs = v.int
        default: break
        }
    }
}

/// suggestion_received, suggestion_approved, suggestion_rejected and suggestion_submitted.
struct LTSuggestion: ProtoMessage, Identifiable {
    var suggestionId = ""
    var fromUserId = ""
    var fromUsername = ""
    var track = LTTrack()
    var reason = ""

    var id: String { suggestionId }

    enum Kind { case received, approved, rejected, submitted }

    static func decode(_ kind: Kind, _ data: Data) throws -> LTSuggestion {
        var s = LTSuggestion()
        try ProtoReader.fields(of: data) { field, v in
            switch (kind, field) {
            case (_, 1): s.suggestionId = v.string
            case (.received, 2): s.fromUserId = v.string
            case (.received, 3): s.fromUsername = v.string
            case (.received, 4): s.track = try LTTrack(decoding: v.data)
            case (.approved, 2), (.submitted, 2): s.track = try LTTrack(decoding: v.data)
            case (.rejected, 2): s.reason = v.string
            default: break
            }
        }
        return s
    }
}

struct LTServerRestarting: ProtoMessage {
    var etaMs: Int64 = 0

    mutating func read(_ field: Int, _ v: ProtoReader.Value) throws {
        if field == 1 { etaMs = v.int }
    }
}
