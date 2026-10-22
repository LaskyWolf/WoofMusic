//
//  Crossfade.swift
//  Trop
//

import Foundation
import ffmpegkit

/// Transitions between songs on two mpv decks: near the end of a song the
/// next one starts on the spare deck and the two are mixed.
///
/// - Smart Crossfade: a timed equal-power fade placed by `MixPlanner.smart`.
/// - AutoMix: a beat-matched mix placed by `MixPlanner.autoMix`. The incoming
///   song plays at the outgoing tempo, its beats are kept on the outgoing
///   beats by small speed corrections, and the bass of the two songs is
///   swapped on the bar halfway through, the way a DJ mixes.
///
/// Flow, driven by `tick()` every 0.25 s:
/// idle → planning (analyse both songs) → planned → prepared (next song
/// loaded, paused, silent) → fading (the decks swap halfway).
@MainActor
final class Crossfade {
    static let shared = Crossfade()

    struct Plan {
        let fromId: String
        let toId: String
        let url: String
        let loudness: Double?
        let mix: MixPlanner.Mix
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
    private var outgoingFinished = false
    private var fadeTask: Task<Void, Never>?
    private var speedTask: Task<Void, Never>?
    /// Song whose transition failed, so the tick doesn't retry it every 0.25 s.
    private var failedFor: String?

    /// Seconds of audio analysed at the end of the outgoing song and the
    /// start of the incoming one.
    private static let tailSeconds = 60.0
    private static let headSeconds = 45.0
    /// How long before the end analysis starts, and before the transition
    /// the next song is loaded so it is buffered in time.
    private static let planLead = 80.0
    private static let prepareLead = 12.0
    /// Time to ease a changed tempo back to normal after the transition.
    private static let speedEaseSeconds = 8.0
    /// AutoMix beat lock: how fast a timing error is corrected (per second),
    /// the largest speed correction, and the bass cut on the quieter deck.
    private static let lockGain = 0.5
    private static let maxLockCorrection = 0.02
    static let bassCut = -24.0

    private var player: PlayerController { .shared }

    private var isEnabled: Bool {
        SettingsStore.shared.crossfadeEnabled || SettingsStore.shared.autoMixEnabled
    }

    // MARK: Driving

    func tick() {
        let np = NowPlaying.shared
        if failedFor != nil, failedFor != np.videoId { failedFor = nil }
        guard phase != .fading else { return }
        guard isEnabled, np.hasNext, !np.isRepeatOn,
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
            guard let plan, position >= plan.mix.fadeStart - Self.prepareLead else { return }
            phase = .prepared
            Task { await loadIncoming(plan) }
        case .prepared:
            guard let plan, incomingReady, position >= plan.mix.fadeStart - 0.4 else { return }
            phase = .fading
            // The tick is coarse; sleep the rest so the start lands on the beat.
            let wait = max(0, plan.mix.fadeStart - player.currentTime)
            fadeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self else { return }
                if let beats = plan.mix.beats, let period = plan.mix.beatPeriod {
                    await self.runBeatMix(plan, beats: beats, period: period)
                } else {
                    await self.runFade(plan)
                }
            }
        case .planning, .fading:
            break
        }
    }

    /// Cancels any planned or running transition. Called when a new song is
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
        if phase == .fading, let active {
            player.deck(active, set: "volume", "100")
            setBass(active, gain: 0)
        }
        player.isCrossfading = false
        clear()
    }

    /// Ends a running transition at once (pause or seek during it).
    func finishNow() {
        guard phase == .fading else { return }
        fadeTask?.cancel()
        guard outgoing != nil else {
            // The transition was scheduled but hadn't started; keep the song going.
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

    /// The outgoing song ran out before the transition ended.
    func outgoingEnded() {
        guard phase == .fading else { return }
        outgoingFinished = true
        if !promoted { promote() }
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

        let settings = SettingsStore.shared
        let tailStart = max(0, duration - Self.tailSeconds)
        let autoMix = settings.autoMixEnabled
            ? MixPlanner.autoMix(duration: duration, tail: outInfo, tailStart: tailStart, head: inInfo)
            : nil
        let mix = autoMix ?? MixPlanner.smart(
            duration: duration,
            fadeLength: settings.crossfadeSeconds,
            tail: outInfo,
            tailStart: tailStart,
            head: inInfo
        )
        Log.player.info(
            "Transition plan: \(mix.isBeatMatched ? "AutoMix \(mix.beats ?? 0) beats" : "crossfade") " +
            "at \(mix.fadeStart)s for \(mix.fadeLength)s, next from \(mix.inStart)s, speed \(mix.speed), " +
            "bpm \(outInfo?.bpm ?? 0) → \(inInfo?.bpm ?? 0)"
        )
        plan = Plan(fromId: current, toId: next, url: source.url, loudness: source.loudness, mix: mix)
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
        let bass: Double? = plan.mix.isBeatMatched ? Self.bassCut : nil
        player.deck(deck, set: "pause", "yes")
        player.deck(deck, set: "volume", "0")
        player.deck(deck, set: "speed", Self.fmt(plan.mix.speed))
        player.deck(deck, set: "af", player.filterChain(loudness: plan.loudness, bassGain: bass))
        player.deck(deck, set: "start", Self.fmt(plan.mix.inStart))
        player.deck(deck, command: ["loadfile", plan.url, "replace"])
    }

    /// Smart Crossfade: an equal-power fade timed by the clock.
    private func runFade(_ plan: Plan) async {
        guard begin() else { return }
        let start = Date()
        while !Task.isCancelled {
            let t = min(1, Date().timeIntervalSince(start) / plan.mix.fadeLength)
            setVolumes(outgoing: cos(t * .pi / 2), incoming: sin(t * .pi / 2))
            // Halfway the next song becomes the one on screen and lock screen.
            if !promoted, t >= 0.5 { promote() }
            if t >= 1 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !Task.isCancelled else { return }
        complete()
    }

    /// AutoMix: progress is counted in outgoing beats, read from the music
    /// itself, so every step lands on the beat.
    /// - First half: the incoming song fades in with its bass cut.
    /// - Halfway (a bar line): the bass swaps from the outgoing song to the
    ///   incoming one, and the incoming song becomes the current song.
    /// - Second half: the outgoing song fades out.
    private func runBeatMix(_ plan: Plan, beats: Int, period: Double) async {
        guard begin(), let incoming, let outgoing else { return }
        let mix = plan.mix
        let start = Date()
        var bassSwapped = false
        var lastSpeed = mix.speed
        var lastLockUpdate = Date.distantPast

        while !Task.isCancelled {
            let wallBeats = Date().timeIntervalSince(start) / period
            let positions = outgoingFinished ? nil : player.positions(outgoing, incoming)
            // Once the outgoing song has ended, its position stops; count by the clock.
            let elapsedBeats = positions.map { ($0.outgoing - mix.fadeStart) / period } ?? wallBeats
            let t = min(1, max(0, elapsedBeats / Double(beats)))

            setVolumes(
                outgoing: t < 0.5 ? 1 : cos((t - 0.5) * 2 * .pi / 2),
                incoming: t < 0.5 ? sin(t * 2 * .pi / 2) : 1
            )
            if !bassSwapped, t >= 0.5 {
                bassSwapped = true
                setBass(incoming, gain: 0)
                setBass(outgoing, gain: Self.bassCut)
            }
            if !promoted, t >= 0.5 { promote() }

            // Beat lock: where the incoming song should be if its beats sit
            // on the outgoing beats, and a small speed change to get there.
            if let positions, Date().timeIntervalSince(lastLockUpdate) >= 0.25 {
                lastLockUpdate = Date()
                let expected = mix.inStart + (positions.outgoing - mix.fadeStart) * mix.speed
                let error = (positions.incoming - expected) / mix.speed
                let correction = max(-Self.maxLockCorrection, min(Self.maxLockCorrection, -Self.lockGain * error))
                let speed = mix.speed * (1 + correction)
                if abs(speed - lastSpeed) > 0.0005 {
                    player.deck(incoming, set: "speed", Self.fmt(speed))
                    lastSpeed = speed
                }
            }

            // Safety net if positions stop moving for another reason.
            if t >= 1 || Date().timeIntervalSince(start) > mix.fadeLength / mix.speed + 5 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !Task.isCancelled else { return }
        complete(speed: lastSpeed)
    }

    /// Starts the incoming deck. False (and reset) when a deck is missing.
    private func begin() -> Bool {
        guard let incoming, let active = player.activeDeck else {
            reset()
            return false
        }
        outgoing = active
        promoted = false
        outgoingFinished = false
        player.isCrossfading = true
        player.deck(incoming, set: "pause", "no")
        return true
    }

    private func promote() {
        guard let plan else { return }
        promoted = true
        player.promoteSpare(videoId: plan.toId, loudness: plan.loudness)
        NowPlaying.shared.advanceForCrossfade(to: plan.toId)
        player.setNowPlayingMetadata()
    }

    private func complete(speed: Double? = nil) {
        if let outgoing {
            player.deck(outgoing, command: ["stop"])
            player.deck(outgoing, set: "volume", "100")
            player.deck(outgoing, set: "speed", "1")
        }
        if let incoming {
            player.deck(incoming, set: "volume", "100")
            setBass(incoming, gain: 0)
        }
        player.isCrossfading = false
        let finalSpeed = speed ?? plan?.mix.speed ?? 1
        let active = incoming
        clear()
        if finalSpeed != 1, let active { easeSpeed(active, from: finalSpeed) }
    }

    private func clear() {
        phase = .idle
        plan = nil
        incoming = nil
        outgoing = nil
        incomingReady = false
        promoted = false
        outgoingFinished = false
        fadeTask = nil
    }

    private func setVolumes(outgoing outGain: Double, incoming inGain: Double) {
        if let outgoing { player.deck(outgoing, set: "volume", Self.mpvVolume(outGain)) }
        if let incoming { player.deck(incoming, set: "volume", Self.mpvVolume(inGain)) }
    }

    /// Changes the bass filter in place (no audio gap). Only decks that
    /// were loaded with AutoMix on have it; on others mpv ignores the command.
    private func setBass(_ deck: MpvDeck, gain: Double) {
        player.deck(deck, command: ["af-command", PlayerController.bassFilterLabel, "g", Self.fmt(gain)])
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
