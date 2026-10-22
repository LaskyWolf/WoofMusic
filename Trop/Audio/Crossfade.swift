//
//  Crossfade.swift
//  Trop
//

import Foundation
import ffmpegkit

/// Smart Crossfade: near the end of a song, plays the next one on a second
/// mpv deck and fades between them. The fade ends where the outgoing song
/// goes quiet, starts on one of its beats, skips the incoming song's silent
/// intro, and nudges the incoming tempo to match when the two are within 6%.
///
/// Flow, driven by `tick()` every 0.25 s:
/// idle → planning (analyse both songs) → planned → prepared (next song
/// loaded, paused, silent) → fading (volumes cross; the decks swap halfway).
@MainActor
final class Crossfade {
    static let shared = Crossfade()

    struct Plan {
        let fromId: String
        let toId: String
        let url: String
        let loudness: Double?
        /// Outgoing position where the fade starts, in seconds.
        let fadeStart: Double
        let fadeLength: Double
        /// Incoming position the fade starts from.
        let inStart: Double
        /// Incoming playback speed during the fade (1 = unchanged).
        let speed: Double
    }

    private enum Phase { case idle, planning, planned, prepared, fading }

    private var phase = Phase.idle
    private var plan: Plan?
    /// Identifies the current planning run; a reset makes older runs stale.
    private var planToken = UUID()
    private var incoming: MpvDeck?
    private var outgoing: MpvDeck?
    private var incomingReady = false
    private var promoted = false
    private var fadeTask: Task<Void, Never>?
    private var speedTask: Task<Void, Never>?
    /// Song whose crossfade failed, so the tick doesn't retry it every 0.25 s.
    private var failedFor: String?

    /// Seconds of audio analysed at the end of the outgoing song and the
    /// start of the incoming one.
    private static let tailSeconds = 40.0
    private static let headSeconds = 30.0
    /// How long before the end analysis starts, and before the fade the next
    /// song is loaded so it is buffered in time.
    private static let planLead = 60.0
    private static let prepareLead = 10.0
    private static let maxTempoNudge = 0.06
    private static let maxIntroSkip = 10.0
    /// Time to ease a nudged tempo back to normal after the fade.
    private static let speedEaseSeconds = 8.0

    private var player: PlayerController { .shared }

    // MARK: Driving

    func tick() {
        let np = NowPlaying.shared
        if failedFor != nil, failedFor != np.videoId { failedFor = nil }
        guard phase != .fading else { return }
        guard SettingsStore.shared.crossfadeEnabled, np.hasNext, !np.isRepeatOn,
              let current = np.videoId, np.duration > 30, np.duration < 600 else {
            if phase != .idle { reset() }
            return
        }
        let next = np.queueSongs[np.queueIndex + 1].videoId
        if let plan, plan.fromId != current || plan.toId != next {
            reset()
        }
        guard np.isPlaying else { return }
        let position = np.currentTime

        switch phase {
        case .idle:
            guard np.duration - position < Self.planLead, failedFor != current else { return }
            phase = .planning
            let token = planToken
            let duration = np.duration
            Task { await makePlan(from: current, to: next, duration: duration, token: token) }
        case .planned:
            guard let plan, position >= plan.fadeStart - Self.prepareLead else { return }
            phase = .prepared
            Task { await loadIncoming(plan) }
        case .prepared:
            guard let plan, incomingReady, position >= plan.fadeStart - 0.4 else { return }
            phase = .fading
            // The tick is coarse; sleep the rest so the fade lands on the beat.
            let wait = max(0, plan.fadeStart - player.currentTime)
            fadeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                await self?.runFade(plan)
            }
        case .planning, .fading:
            break
        }
    }

    /// Cancels any planned or running crossfade. Called when a new song is
    /// loaded the normal way.
    func reset() {
        fadeTask?.cancel()
        speedTask?.cancel()
        planToken = UUID()
        let active = player.activeDeck
        for deck in [incoming, outgoing].compactMap({ $0 }) where deck != active {
            player.deck(deck, command: ["stop"])
            player.deck(deck, set: "volume", "100")
            player.deck(deck, set: "speed", "1")
        }
        if phase == .fading, let active { player.deck(active, set: "volume", "100") }
        player.isCrossfading = false
        clear()
    }

    /// Ends a running fade at once (pause or seek during the fade).
    func finishNow() {
        guard phase == .fading else { return }
        fadeTask?.cancel()
        guard outgoing != nil else {
            // The fade was scheduled but hadn't started; keep the song going.
            reset()
            return
        }
        if !promoted { promote() }
        complete()
    }

    // MARK: Deck events

    func deckLoaded() {
        guard phase == .prepared, let incoming else { return }
        player.deck(incoming, set: "start", "none")
        incomingReady = true
    }

    func deckFailed() {
        guard phase == .prepared || (phase == .fading && !promoted) else { return }
        Log.player.notice("Crossfade: next song failed to load, falling back to a normal transition")
        failedFor = plan?.fromId
        reset()
    }

    /// The outgoing song ran out before the fade reached its midpoint.
    func outgoingEnded() {
        guard phase == .fading, !promoted else { return }
        promote()
    }

    // MARK: Steps

    private func makePlan(from current: String, to next: String, duration: Double, token: UUID) async {
        guard let source = await Self.source(for: next), let outURL = player.activePath else {
            if token == planToken { failedFor = current; phase = .idle }
            return
        }
        async let tail = Self.analyze(url: outURL, seconds: Self.tailSeconds, fromEnd: true)
        async let head = Self.analyze(url: source.url, seconds: Self.headSeconds, fromEnd: false)
        let (outInfo, inInfo) = await (tail, head)
        guard token == planToken else { return }

        let points = Self.points(
            duration: duration,
            fadeLength: SettingsStore.shared.crossfadeSeconds,
            tail: outInfo,
            tailStart: max(0, duration - Self.tailSeconds),
            head: inInfo
        )
        Log.player.info(
            "Crossfade plan: fade at \(points.fadeStart)s, next from \(points.inStart)s, speed \(points.speed), " +
            "bpm \(outInfo?.bpm ?? 0) → \(inInfo?.bpm ?? 0)"
        )
        plan = Plan(
            fromId: current, toId: next, url: source.url, loudness: source.loudness,
            fadeStart: points.fadeStart, fadeLength: SettingsStore.shared.crossfadeSeconds,
            inStart: points.inStart, speed: points.speed
        )
        phase = .planned
    }

    private func loadIncoming(_ plan: Plan) async {
        guard let deck = await player.spareDeck() else {
            failedFor = plan.fromId
            reset()
            return
        }
        guard phase == .prepared, self.plan?.toId == plan.toId else { return }
        incoming = deck
        incomingReady = false
        player.deck(deck, set: "pause", "yes")
        player.deck(deck, set: "volume", "0")
        player.deck(deck, set: "speed", Self.fmt(plan.speed))
        player.deck(deck, set: "af", player.filterChain(loudness: plan.loudness))
        player.deck(deck, set: "start", Self.fmt(plan.inStart))
        player.deck(deck, command: ["loadfile", plan.url, "replace"])
    }

    private func runFade(_ plan: Plan) async {
        guard let incoming, let active = player.activeDeck else {
            reset()
            return
        }
        outgoing = active
        promoted = false
        player.isCrossfading = true
        player.deck(incoming, set: "pause", "no")

        let start = Date()
        while !Task.isCancelled {
            let t = min(1, Date().timeIntervalSince(start) / plan.fadeLength)
            setGains(t)
            // Halfway the next song becomes the one on screen and lock screen.
            if !promoted, t >= 0.5 { promote() }
            if t >= 1 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !Task.isCancelled else { return }
        complete()
    }

    private func promote() {
        guard let plan else { return }
        promoted = true
        player.promoteSpare(videoId: plan.toId, loudness: plan.loudness)
        NowPlaying.shared.advanceForCrossfade(to: plan.toId)
        player.setNowPlayingMetadata()
    }

    private func complete() {
        if let outgoing {
            player.deck(outgoing, command: ["stop"])
            player.deck(outgoing, set: "volume", "100")
            player.deck(outgoing, set: "speed", "1")
        }
        if let incoming { player.deck(incoming, set: "volume", "100") }
        player.isCrossfading = false
        let speed = plan?.speed ?? 1
        let active = incoming
        clear()
        if speed != 1, let active { easeSpeed(active, from: speed) }
    }

    private func clear() {
        phase = .idle
        plan = nil
        incoming = nil
        outgoing = nil
        incomingReady = false
        promoted = false
        fadeTask = nil
    }

    /// Equal-power curve: the sum of both songs stays about as loud as one.
    private func setGains(_ t: Double) {
        if let outgoing { player.deck(outgoing, set: "volume", Self.mpvVolume(cos(t * .pi / 2))) }
        if let incoming { player.deck(incoming, set: "volume", Self.mpvVolume(sin(t * .pi / 2))) }
    }

    private func easeSpeed(_ deck: MpvDeck, from speed: Double) {
        speedTask = Task { [weak self] in
            let start = Date()
            while !Task.isCancelled {
                let t = min(1, Date().timeIntervalSince(start) / Self.speedEaseSeconds)
                self?.player.deck(deck, set: "speed", Self.fmt(speed + (1 - speed) * t))
                if t >= 1 { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    // MARK: Planning math

    /// Picks the fade start, the incoming start and the tempo nudge from the
    /// two analyses. Without analysis it falls back to a plain fade that
    /// ends with the song.
    nonisolated static func points(
        duration: Double,
        fadeLength: Double,
        tail: TrackAnalyzer.Result?,
        tailStart: Double,
        head: TrackAnalyzer.Result?
    ) -> (fadeStart: Double, inStart: Double, speed: Double) {
        // End the fade where the outgoing song goes quiet.
        let outEnd = min(duration, tail.map { tailStart + $0.soundEnd } ?? duration)
        let earliest = duration * 0.5
        var fadeStart = max(earliest, outEnd - fadeLength)
        // Start on the last beat before that point.
        if let tail, let period = tail.beatPeriod {
            let gridStart = tailStart + tail.firstBeat
            let beat = gridStart + ((fadeStart - gridStart) / period).rounded(.down) * period
            if beat >= earliest { fadeStart = beat }
        }

        // Skip the incoming song's silent intro, starting on its first beat.
        var inStart = 0.0
        if let head {
            inStart = head.soundStart
            if let period = head.beatPeriod {
                inStart = head.firstBeat + ((head.soundStart - head.firstBeat) / period).rounded(.up) * period
            }
            if inStart > maxIntroSkip { inStart = 0 }
        }

        // Play the incoming song at the outgoing tempo when they are close.
        var speed = 1.0
        if let outBPM = tail?.bpm, let inBPM = head?.bpm {
            let ratio = outBPM / inBPM
            if abs(ratio - 1) <= maxTempoNudge { speed = ratio }
        }
        return (fadeStart, max(0, inStart), speed)
    }

    // MARK: Sources

    /// Where the next song plays from: its download, or its stream URL.
    private nonisolated static func source(for videoId: String) async -> (url: String, loudness: Double?)? {
        if let local = await DownloadManager.shared.localURL(for: videoId) {
            return (local.path, nil)
        }
        guard let result = try? await PlaybackManager.shared.resolve(videoId: videoId) else { return nil }
        return (result.streamUrl, result.loudnessDb)
    }

    private nonisolated static func analyze(url: String, seconds: Double, fromEnd: Bool) async -> TrackAnalyzer.Result? {
        guard let samples = await decode(url: url, seconds: seconds, fromEnd: fromEnd) else { return nil }
        return TrackAnalyzer.analyze(samples)
    }

    /// Decodes `seconds` of audio at the start or end of `url` to mono floats.
    private nonisolated static func decode(url: String, seconds: Double, fromEnd: Bool) async -> [Float]? {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("crossfade-\(UUID().uuidString).raw")
        defer { try? FileManager.default.removeItem(at: output) }

        var args = ["-y", "-v", "error", "-rw_timeout", "15000000"]
        if url.hasPrefix("http") {
            if let caPath = Bundle.main.path(forResource: "cacert", ofType: "pem") {
                args += ["-cafile", caPath]
            }
            args += ["-headers", "User-Agent: Mozilla/5.0\r\n"]
        }
        if fromEnd { args += ["-sseof", "-\(Int(seconds))"] }
        args += ["-i", url, "-t", "\(Int(seconds))", "-vn", "-ac", "1",
                 "-ar", "\(TrackAnalyzer.sampleRate)", "-f", "f32le", output.path]

        let succeeded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            FFmpegKit.execute(withArgumentsAsync: args) { session in
                continuation.resume(returning: ReturnCode.isSuccess(session?.getReturnCode()))
            }
        }
        guard succeeded, let data = try? Data(contentsOf: output), !data.isEmpty else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private nonisolated static func fmt(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    /// mpv's volume is cubic (amplitude = (volume / 100)³), so a linear gain
    /// needs a cube root to fade smoothly.
    private nonisolated static func mpvVolume(_ gain: Double) -> String {
        fmt(100 * cbrt(max(0, gain)))
    }
}
