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
///   swapped on the bar halfway through, the way a DJ mixes. On top of that
///   each mix lets the outgoing song go in a `MixPlanner.Style`: a filter
///   sweep, an echo, a reverb wash or a loop, all set live on named filters
///   (`af-command`) so the filter chain is never rebuilt mid-song.
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
        let style: MixPlanner.Style
        /// The incoming song's beat, which its echo filter is built for.
        let echoDelay: Double?
    }

    private enum Phase { case idle, planning, planned, prepared, fading }

    private var phase = Phase.idle
    private var plan: Plan?
    /// Identifies the current planning run; a reset makes older runs stale.
    private var planToken = UUID()
    /// The planning run, cancelled by a reset so its decodes stop too.
    private var planTask: Task<Void, Never>?
    private var incoming: MpvDeck?
    private var outgoing: MpvDeck?
    private var incomingReady = false
    private var promoted = false
    private var outgoingFinished = false
    private var fadeTask: Task<Void, Never>?
    private var speedTask: Task<Void, Never>?
    /// Song whose transition failed, so the tick doesn't retry it every 0.25 s.
    private var failedFor: String?
    /// Transition settings read when the playing song started, so changing
    /// them takes effect from the next song.
    // swiftlint:disable:next large_tuple
    private var songSettings: (songId: String, autoMix: Bool, crossfade: Bool, seconds: Double)?
    /// AutoMixes planned so far, to rotate between styles.
    private var mixCount = 0
    /// Effect values sent during this mix, so unchanged ones aren't resent every 50 ms.
    private var sentEffects: [String: String] = [:]

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
    /// Filter sweep range: the incoming low-pass opens over the first half,
    /// the outgoing high-pass rises over the second.
    private static let lowPassSweep: (from: Double, to: Double) = (300, 16_000)
    private static let highPassSweep: (from: Double, to: Double) = (20, 1_500)

    private var player: PlayerController { .shared }

    private var isEnabled: Bool {
        songSettings.map { $0.autoMix || $0.crossfade } ?? false
    }

    // MARK: Driving

    func tick() {
        let np = NowPlaying.shared
        if failedFor != nil, failedFor != np.videoId { failedFor = nil }
        if let id = np.videoId, songSettings?.songId != id {
            let settings = SettingsStore.shared
            songSettings = (id, settings.autoMixEnabled, settings.crossfadeEnabled, settings.crossfadeSeconds)
        }
        if phase == .fading {
            // Play Next or a reorder changed what follows: the mix can still be called off.
            if !promoted, let plan, np.nextSong?.videoId != plan.toId { reset() }
            return
        }
        guard isEnabled, np.hasNext, !np.isRepeatOn, !SleepTimer.shared.stopsAtSongEnd,
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
            planTask = Task { await makePlan(from: current, to: next, duration: duration, token: token) }
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
        planTask?.cancel()
        planTask = nil
        planToken = UUID()
        let active = player.activeDeck
        for deck in [incoming, outgoing].compactMap({ $0 }) where deck != active {
            player.deck(deck, set: "pause", "yes")
            player.deck(deck, set: "volume", "100")
            player.deck(deck, set: "speed", "1")
            clearEffects(deck)
        }
        if phase == .fading, let active {
            player.deck(active, set: "volume", "100")
            clearEffects(active)
        }
        player.isCrossfading = false
        clear()
    }

    /// Stops easing the speed back to 1× after a mix: the user picked a speed.
    func stopSpeedEase() {
        speedTask?.cancel()
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

    /// The decks have swapped: an ended song is the incoming one, shorter than the mix.
    var hasPromoted: Bool { promoted }

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

        let tailStart = max(0, duration - Self.tailSeconds)
        let autoMix = songSettings?.autoMix == true
            ? MixPlanner.autoMix(duration: duration, tail: outInfo, tailStart: tailStart, head: inInfo)
            : nil
        let mix = autoMix ?? MixPlanner.smart(
            duration: duration,
            fadeLength: songSettings?.seconds ?? 6,
            tail: outInfo,
            tailStart: tailStart,
            head: inInfo
        )
        var style = MixPlanner.Style.blend
        if mix.isBeatMatched, player.hasEffectFilters {
            mixCount += 1
            let room = duration - mix.fadeStart - mix.fadeLength
            var cues = MixPlanner.Cues()
            if let outInfo, let inInfo { cues = MixPlanner.cues(for: mix, tail: outInfo, tailStart: tailStart, head: inInfo) }
            style = MixPlanner.style(for: mix, echoPeriod: player.currentEchoDelay, room: room, cues: cues, variety: mixCount)
        }
        let keys = "\(outInfo?.key?.camelot ?? "?") → \(inInfo?.key?.camelot ?? "?")"
        let keyMatch = mix.keysCompatible.map { $0 ? "compatible" : "clash" } ?? "unknown"
        Log.player.info(
            "Transition plan: \(mix.isBeatMatched ? "AutoMix \(mix.beats ?? 0) beats, style \(style.rawValue)," : "crossfade") " +
            "at \(mix.fadeStart)s for \(mix.fadeLength)s, next from \(mix.inStart)s, speed \(mix.speed), " +
            "bpm \(outInfo?.bpm ?? 0) → \(inInfo?.bpm ?? 0), key \(keys) (\(keyMatch)), " +
            "duck until \(mix.duckUntil.map { "\($0)" } ?? "none")"
        )
        plan = Plan(
            fromId: current, toId: next, url: source.url, loudness: source.loudness,
            mix: mix, style: style, echoDelay: inInfo?.beatPeriod
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
        let bass: Double? = plan.mix.isBeatMatched ? Self.bassCut : nil
        player.deck(deck, set: "pause", "yes")
        player.deck(deck, set: "volume", "0")
        player.deck(deck, set: "speed", PlayerController.fmt(plan.mix.speed))
        // Keep the audio output open between files: closing it deactivates
        // the audio session (see `complete`).
        player.deck(deck, set: "gapless-audio", "yes")
        player.deck(deck, set: "af", player.filterChain(loudness: plan.loudness, bassGain: bass, echoDelay: plan.echoDelay))
        player.deck(deck, set: "start", PlayerController.fmt(plan.mix.inStart))
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
    /// The style's effects run alongside (`applyStyle`); echo and wash then
    /// let their tail ring before the outgoing deck stops.
    private func runBeatMix(_ plan: Plan, beats: Int, period: Double) async {
        let mix = plan.mix
        if plan.style == .sweep, let incoming {
            effect(incoming, PlayerController.lowPassLabel, "lowpass", "f", lowPassStart)
            effect(incoming, PlayerController.lowPassLabel, "lowpass", "m", 1)
        }
        guard begin(), let incoming, let outgoing else { return }
        let loop = plan.style == .loop ? MixPlanner.loopBar(for: mix) : nil
        if let loop {
            player.deck(outgoing, set: "ab-loop-a", PlayerController.fmt(loop.bar.lowerBound))
            player.deck(outgoing, set: "ab-loop-b", PlayerController.fmt(loop.bar.upperBound))
            player.deck(outgoing, set: "ab-loop-count", "\(loop.repeats)")
        }
        let start = Date()
        var bassSwapped = false
        var lastSpeed = mix.speed
        var lastLockUpdate = Date.distantPast
        // Seconds the loop has jumped the outgoing song back, added to its
        // position so the mix keeps counting forward.
        var loopOffset: Double = 0
        var lastOutgoing: Double?

        while !Task.isCancelled {
            let wallBeats = Date().timeIntervalSince(start) / period
            let positions = outgoingFinished ? nil : player.positions(outgoing, incoming)
            if let loop, let position = positions?.outgoing {
                let length = loop.bar.upperBound - loop.bar.lowerBound
                if let lastOutgoing, position < lastOutgoing - length / 2 {
                    loopOffset += length
                }
                lastOutgoing = position
            }
            let outPosition = positions.map { $0.outgoing + loopOffset }
            // Once the outgoing song has ended, its position stops; count by the clock.
            let elapsedBeats = outPosition.map { ($0 - mix.fadeStart) / period } ?? wallBeats
            let t = min(1, max(0, elapsedBeats / Double(beats)))

            applyStyle(plan.style, t: t, beats: beats)
            if !bassSwapped, t >= 0.5 {
                bassSwapped = true
                setBass(incoming, gain: 0)
                setBass(outgoing, gain: Self.bassCut)
            }
            if !promoted, t >= 0.5 { promote() }

            // Beat lock: where the incoming song should be if its beats sit
            // on the outgoing beats, and a small speed change to get there.
            if let positions, let outPosition, Date().timeIntervalSince(lastLockUpdate) >= 0.25 {
                lastLockUpdate = Date()
                let expected = mix.inStart + (outPosition - mix.fadeStart) * mix.speed
                let error = (positions.incoming - expected) / mix.speed
                let correction = max(-Self.maxLockCorrection, min(Self.maxLockCorrection, -Self.lockGain * error))
                let speed = mix.speed * (1 + correction)
                if abs(speed - lastSpeed) > 0.0005 {
                    player.deck(incoming, set: "speed", PlayerController.fmt(speed))
                    lastSpeed = speed
                }
            }

            // Safety net if positions stop moving for another reason.
            if t >= 1 || Date().timeIntervalSince(start) > mix.fadeLength / mix.speed + 5 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !Task.isCancelled else { return }
        if let tail = tailSeconds(plan.style, period: period), !outgoingFinished {
            // The song is cut and its sends closed: only the echo or reverb is left.
            effect(outgoing, PlayerController.effectsLabel, "volume@dry", "volume", 0)
            effect(outgoing, PlayerController.effectsLabel, "volume@echosend", "volume", 0)
            effect(outgoing, PlayerController.effectsLabel, "volume@verbsend", "volume", 0)
            try? await Task.sleep(for: .seconds(tail))
            guard !Task.isCancelled else { return }
        }
        complete(speed: lastSpeed)
    }

    /// Volumes and effect levels at mix progress `t` (0...1). The outgoing
    /// song fades out over the second half: by its deck volume, or for echo
    /// and wash by its dry path only, so their tail outlives it.
    private func applyStyle(_ style: MixPlanner.Style, t: Double, beats: Int) {
        guard let incoming, let outgoing else { return }
        let outGain = t < 0.5 ? 1 : cos((t - 0.5) * .pi)
        let inGain = (t < 0.5 ? sin(t * .pi) : 1) * duck(t)
        let strength = effectStrength
        let fx = PlayerController.effectsLabel
        switch style {
        case .echo:
            setVolumes(outgoing: 1, incoming: inGain)
            effect(outgoing, fx, "volume@dry", "volume", outGain)
            // The last bar feeds the echo.
            let lastBar = 1 - Double(TrackAnalyzer.beatsPerBar) / Double(beats)
            effect(outgoing, fx, "volume@echosend", "volume", t >= lastBar ? strength : 0)
        case .wash:
            setVolumes(outgoing: 1, incoming: inGain)
            effect(outgoing, fx, "volume@dry", "volume", outGain)
            effect(outgoing, fx, "volume@verbsend", "volume", t < 0.5 ? 0 : min(1, (t - 0.5) * 2) * strength)
        case .sweep:
            setVolumes(outgoing: outGain, incoming: inGain)
            if t < 0.5 {
                let cutoff = MixPlanner.sweep(from: lowPassStart, to: Self.lowPassSweep.to, progress: t * 2)
                effect(incoming, PlayerController.lowPassLabel, "lowpass", "f", cutoff)
            } else {
                let cutoff = MixPlanner.sweep(from: Self.highPassSweep.from, to: highPassEnd, progress: (t - 0.5) * 2)
                effect(incoming, PlayerController.lowPassLabel, "lowpass", "m", 0)
                effect(outgoing, PlayerController.highPassLabel, "highpass", "f", cutoff)
                effect(outgoing, PlayerController.highPassLabel, "highpass", "m", 1)
            }
        case .blend, .loop:
            setVolumes(outgoing: outGain, incoming: inGain)
        }
    }

    /// Transition Effects setting (0...1), read live so it can be tuned by
    /// ear during a mix. It scales the echo and reverb sends and how far the
    /// sweep filters travel.
    private var effectStrength: Double {
        min(1, max(0, SettingsStore.shared.transitionEffects))
    }

    /// Where the incoming low-pass starts: at full strength 300 Hz, at zero
    /// strength already open.
    private var lowPassStart: Double {
        MixPlanner.sweep(from: Self.lowPassSweep.to, to: Self.lowPassSweep.from, progress: effectStrength)
    }

    /// Where the outgoing high-pass ends up.
    private var highPassEnd: Double {
        MixPlanner.sweep(from: Self.highPassSweep.from, to: Self.highPassSweep.to, progress: effectStrength)
    }

    /// Incoming level factor at progress `t`: held at `duckLevel` while the
    /// outgoing song still sings over it, then released over 2 beats.
    private func duck(_ t: Double) -> Double {
        guard let plan, let until = plan.mix.duckUntil, let beats = plan.mix.beats else { return 1 }
        let release = min(1, max(0, (t - until) * Double(beats) / 2))
        return MixPlanner.duckLevel + (1 - MixPlanner.duckLevel) * release
    }

    /// How long a style's tail rings after the mix, nil when it has none.
    private func tailSeconds(_ style: MixPlanner.Style, period: Double) -> Double? {
        switch style {
        case .echo: MixPlanner.echoTail(period: period)
        case .wash: MixPlanner.washTail
        case .blend, .sweep, .loop: nil
        }
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
        player.promoteSpare(videoId: plan.toId, loudness: plan.loudness, echoDelay: plan.echoDelay)
        NowPlaying.shared.advanceForCrossfade(to: plan.toId)
        player.setNowPlayingMetadata()
    }

    private func complete(speed: Double? = nil) {
        if let outgoing {
            // Pause, never stop: a stopped mpv goes idle and switches off the
            // app's audio session, which silences the deck still playing.
            player.deck(outgoing, set: "pause", "yes")
            player.deck(outgoing, set: "volume", "100")
            player.deck(outgoing, set: "speed", "1")
            clearEffects(outgoing)
        }
        if let incoming {
            player.deck(incoming, set: "volume", "100")
            clearEffects(incoming)
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
        sentEffects = [:]
    }

    private func setVolumes(outgoing outGain: Double, incoming inGain: Double) {
        if let outgoing { player.deck(outgoing, set: "volume", Self.mpvVolume(outGain)) }
        if let incoming { player.deck(incoming, set: "volume", Self.mpvVolume(inGain)) }
    }

    /// Changes the bass filter in place (no audio gap). Only decks that
    /// were loaded with AutoMix on have it; on others mpv ignores the command.
    private func setBass(_ deck: MpvDeck, gain: Double) {
        afCommand(deck, PlayerController.bassFilterLabel, "bass", "g", PlayerController.fmt(gain))
    }

    /// Sets one effect parameter in place, skipping a value already sent this mix.
    private func effect(_ deck: MpvDeck, _ label: String, _ target: String, _ name: String, _ value: Double) {
        let text = PlayerController.fmt(value)
        let key = "\(deck.handle) \(label) \(target) \(name)"
        guard sentEffects[key] != text else { return }
        sentEffects[key] = text
        afCommand(deck, label, target, name, text)
    }

    /// `target` names the filter inside the label's lavfi graph: with mpv's
    /// default ("all") the command fails on the graph's other filters.
    private func afCommand(_ deck: MpvDeck, _ label: String, _ target: String, _ name: String, _ value: String) {
        player.deck(deck, command: ["af-command", label, name, value, target])
    }

    /// Puts a deck's AutoMix filters back to rest and drops its loop.
    private func clearEffects(_ deck: MpvDeck) {
        setBass(deck, gain: 0)
        afCommand(deck, PlayerController.highPassLabel, "highpass", "m", "0")
        afCommand(deck, PlayerController.lowPassLabel, "lowpass", "m", "0")
        afCommand(deck, PlayerController.effectsLabel, "volume@dry", "volume", "1")
        afCommand(deck, PlayerController.effectsLabel, "volume@echosend", "volume", "0")
        afCommand(deck, PlayerController.effectsLabel, "volume@verbsend", "volume", "0")
        player.deck(deck, set: "ab-loop-a", "no")
        player.deck(deck, set: "ab-loop-b", "no")
        player.deck(deck, set: "ab-loop-count", "inf")
    }

    private func easeSpeed(_ deck: MpvDeck, from speed: Double) {
        speedTask = Task { [weak self] in
            let start = Date()
            while !Task.isCancelled {
                let t = min(1, Date().timeIntervalSince(start) / Self.speedEaseSeconds)
                self?.player.deck(deck, set: "speed", PlayerController.fmt(speed + (1 - speed) * t))
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

        // A reset cancels the plan; the session is stopped instead of decoding on.
        let running = RunningSession()
        let succeeded = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let started = FFmpegKit.execute(withArgumentsAsync: args) { session in
                    continuation.resume(returning: ReturnCode.isSuccess(session?.getReturnCode()))
                }
                running.start(started)
            }
        } onCancel: {
            running.cancel()
        }
        guard succeeded, let data = try? Data(contentsOf: output), !data.isEmpty else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// mpv's volume is cubic (amplitude = (volume / 100)³), so a linear gain
    /// needs a cube root to fade smoothly.
    private nonisolated static func mpvVolume(_ gain: Double) -> String {
        PlayerController.fmt(100 * cbrt(max(0, gain)))
    }
}

/// The FFmpeg session of a decode, shared with its cancellation handler,
/// which can run before the session exists.
private final class RunningSession: @unchecked Sendable {
    private let lock = NSLock()
    private var session: FFmpegSession?
    private var isCancelled = false

    func start(_ session: FFmpegSession?) {
        lock.lock()
        self.session = session
        let cancelled = isCancelled
        lock.unlock()
        if cancelled { session?.cancel() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let session = session
        lock.unlock()
        session?.cancel()
    }
}
