//
//  PlayerController.swift
//  Trop
//
//  Created by 686udjie on 28/06/2026.
//

import Foundation
import Libmpv
import MediaPlayer
import Combine
import AVFoundation
import UIKit

// MARK: - PlayerController

@MainActor
final class PlayerController {
    static let shared = PlayerController()

    nonisolated(unsafe) private var _mpv: OpaquePointer?
    /// Second mpv instance that plays the next song during a crossfade.
    /// Created on first use; swapped with `_mpv` halfway through the fade.
    nonisolated(unsafe) private var _spare: OpaquePointer?
    /// While true, the outgoing song's end finishes the crossfade instead of
    /// advancing the queue.
    nonisolated(unsafe) var isCrossfading = false
    /// True once the spare deck has opened its audio output. When such a
    /// deck goes idle, mpv deactivates the shared audio session.
    nonisolated(unsafe) private var spareHasAudio = false
    /// Serial queue for all mpv property read/write calls
    let mpvAccessQueue = DispatchQueue(label: "com.686udjie.PlayerController.mpvAccess")

    nonisolated(unsafe) private var eventLoopThread: Thread?

    nonisolated(unsafe) var isRunning = false
    nonisolated(unsafe) var currentVideoId: String?
    nonisolated(unsafe) var pendingVideoId: String?
    var currentLoudnessDb: Double?
    var pendingURL: String?
    nonisolated(unsafe) var desiredPlaying = false
    private var wasPlayingBeforeInterruption = false

    let playState = CurrentValueSubject<State, Never>(.stopped)
    var nowPlayingInfo = [String: Any]()
    /// mpv applies a seek asynchronously, so `time-pos` keeps the old value
    /// for a moment. Until it catches up, progress reports the seek target
    /// instead, so the timeline doesn't jump back and forth.
    private var pendingSeek: (target: TimeInterval, deadline: Date)?
    /// Where to continue once a finished song is loaded again: the user moved
    /// the timeline after it ended and then pressed play.
    private var resumeAfterLoad: (videoId: String, time: TimeInterval)?
    /// Bumped by every `play()`. A call that finds it changed after an await
    /// was overtaken by a newer one and must not load its song.
    private var playGeneration = 0
    /// Position, time and queue length of the last progress sent to the lock
    /// screen, which counts forward from there by itself while playing.
    private var lastProgressPush: (position: TimeInterval, at: Date, queueCount: Int)?

    var currentTime: TimeInterval {
        withMpv { mpv in
            var val = Double(0)
            mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &val)
            return val
        } ?? 0
    }

    var duration: TimeInterval {
        withMpv { mpv in
            var val = Double(0)
            mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &val)
            return val
        } ?? 0
    }

    enum State: Equatable { case stopped, playing, paused }

    private init() {
        assertAudioSession()
        setupRemoteCommands()
        observeInterruptions()
        observeAudioSessionReset()
        startMpv()
    }

    deinit {
        isRunning = false
        if let mpv = _mpv { mpv_wakeup(mpv) }
        if let spare = _spare { mpv_wakeup(spare) }
    }

    nonisolated func withMpv<T: Sendable>(_ body: @escaping @Sendable (OpaquePointer) -> T) -> T? {
        var result: T?
        mpvAccessQueue.sync {
            guard let handle = _mpv else { return }
            result = body(handle)
        }
        return result
    }
}

// MARK: - Playback

extension PlayerController {
    @MainActor
    func play(
        url: String,
        title: String? = nil,
        artist: String? = nil,
        videoId: String? = nil,
        duration: TimeInterval? = nil,
        artists: [YTArtist] = [],
        loudnessDb: Double? = nil,
        thumbnailUrl: String? = nil
    ) async {
        playGeneration &+= 1
        let generation = playGeneration
        Crossfade.shared.reset()
        currentLoudnessDb = loudnessDb
        guard let url = URL(string: url) else {
            Log.player.error("Invalid playback URL")
            return
        }

        if let videoId, let title, videoId != NowPlaying.shared.videoId {
            NowPlaying.shared.update(title: title, artist: artist, videoId: videoId, artists: artists, thumbnailUrl: thumbnailUrl)
        }

        let prevVideoId = currentVideoId
        let isNewSong = prevVideoId != nil && videoId != prevVideoId

        if isNewSong {
            await PlaybackStateService.shared.stopTracking()
            guard generation == playGeneration else { return }
        }
        // With Persistent Play/Pause a paused player stays paused when the track changes.
        desiredPlaying = SettingsStore.shared.persistentPlayPause ? playState.value != .paused : true
        assertAudioSession()
        if let videoId {
            await PlaybackStateService.shared.startTracking(videoId: videoId)
            guard generation == playGeneration else { return }
        }

        let isReady = withMpv { _ in true } ?? false
        guard isReady else {
            Log.player.info("mpv not ready yet, parking URL for deferred load")
            pendingURL = url.absoluteString
            pendingVideoId = videoId
            return
        }

        applyPlaybackSettings()

        pendingVideoId = videoId
        Log.player.info(
            "TRANSITION play videoId=\(videoId ?? "nil") isNewSong=\(isNewSong)"
        )
        let absoluteString = url.absoluteString
        let loadArguments = ["loadfile", absoluteString, "replace"]
        let pauseValue = desiredPlaying ? "no" : "yes"
        let cmdResult = withMpv { mpv -> Int32 in
            mpv_set_property_string(mpv, "pause", pauseValue)
            // A cancelled crossfade can leave the deck faded or sped up.
            mpv_set_property_string(mpv, "volume", "100")
            mpv_set_property_string(mpv, "speed", "1")
            return loadArguments.withUnsafeCArg { mpv_command(mpv, $0) }
        } ?? -1
        if cmdResult != 0 {
            Log.player.error("mpv_command loadfile failed result=\(cmdResult)")
        }
        if desiredPlaying { playState.send(.playing) }
        NowPlaying.shared.isPlaying = desiredPlaying
        NowPlaying.shared.currentTime = 0
        NowPlaying.shared.duration = max(0, duration ?? 0)
        setNowPlayingMetadata()
    }

    func seek(to time: TimeInterval) {
        Crossfade.shared.finishNow()
        pendingSeek = (time, Date().addingTimeInterval(1.5))
        NowPlaying.shared.currentTime = time
        withMpv { mpv in
            var val = time
            let result = mpv_set_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &val)
            if result < 0 { Log.player.error("seek failed: mpv error \(result)") }
        }
        // The progress timer is stopped while paused.
        updateNowPlayingProgress()
    }

    func setPaused(_ paused: Bool) {
        Crossfade.shared.finishNow()
        // After the queue ends mpv holds no file: unpausing it would play silence.
        if !paused, playState.value == .stopped, pendingVideoId == nil {
            let np = NowPlaying.shared
            if let videoId = np.videoId, np.duration > 0, np.currentTime < np.duration - 1 {
                resumeAfterLoad = (videoId, np.currentTime)
            }
            np.playCurrentSong(logContext: "resume")
            return
        }
        desiredPlaying = !paused
        let currentlyPaused = playState.value != .playing
        guard currentlyPaused != paused else {
            updateNowPlayingProgress()
            return
        }
        withMpv { mpv in
            var flag: Int32 = paused ? 1 : 0
            mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
        }
        playState.send(paused ? .paused : .playing)
        NowPlaying.shared.isPlaying = !paused
        Task { await PlaybackStateService.shared.setPlaying(!paused) }
        if !paused { assertAudioSession() }
        updateNowPlayingProgress()
    }

    func togglePlayPause() {
        setPaused(playState.value == .playing)
    }

    func applyPlaybackSettings() {
        let chain = filterChain(loudness: currentLoudnessDb)
        let gapless = SettingsStore.shared.gaplessPlayback
        withMpv { mpv in
            mpv_set_property_string(mpv, "gapless-audio", gapless ? "yes" : "no")
            let result = mpv_set_property_string(mpv, "af", chain.isEmpty ? "" : chain)
            if result < 0 { Log.player.error("Failed to set af chain '\(chain)': mpv error \(result)") }
        }
    }

    /// Label of the bass filter AutoMix turns down and up during a mix.
    static let bassFilterLabel = "automixbass"

    /// Equalizer and loudness-normalization filters for a song with
    /// `loudness`, after a bass filter that a mix changes live with
    /// `af-command` (flat unless `bassGain` is set).
    func filterChain(loudness: Double?, bassGain: Double? = nil) -> String {
        let settings = SettingsStore.shared
        let eqEnabled = settings.equalizerEnabled
        let eqGains = settings.equalizerGains
        let norm = settings.audioNormalization
        // Always present (flat at 0 dB) so turning AutoMix on or off never
        // rebuilds the filters of the playing song.
        let bass = bassGain ?? 0

        return {
            var filters = ["@\(Self.bassFilterLabel):bass=f=180:g=\(Self.fmt(bass))"]
            if eqEnabled {
                let entries = zip(equalizerFrequencies, eqGains)
                    .map { "entry(\(Self.fmt($0.0)),\(Self.fmt($0.1)))" }
                    .joined(separator: ";")
                if !entries.isEmpty {
                    filters.append("firequalizer=gain_entry=\"\(entries)\"")
                }
            }
            if norm, let loudness, loudness.isFinite {
                let gain = max(-12, min(12, -14 - loudness))
                filters.append("volume=\(Self.fmt(gain))dB")
            }
            return filters.joined(separator: ",")
        }()
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

// MARK: - mpv lifecycle & event loop

extension PlayerController {
    fileprivate func startMpv() {
        mpvAccessQueue.async { [weak self] in
            guard let self else { return }
            _ = setenv("MVK_CONFIG_LOG_LEVEL", "1", 1)
            guard let mpv = Self.createHandle() else { return }
            self._mpv = mpv
            Log.player.info("mpv handle published — event loop starting")

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyPlaybackSettings()
                if let url = self.pendingURL {
                    self.pendingURL = nil
                    Log.player.info("mpv ready: loading deferred stream")
                    let pauseValue = self.desiredPlaying ? "no" : "yes"
                    _ = self.withMpv { mpv in
                        mpv_set_property_string(mpv, "pause", pauseValue)
                        return ["loadfile", url, "replace"].withUnsafeCArg { mpv_command(mpv, $0) }
                    }
                }
            }

            self.eventLoopThread = self.startEventLoop(mpv)
        }
    }

    nonisolated private static func createHandle() -> OpaquePointer? {
        guard let mpv = mpv_create() else {
            Log.player.error("mpv_create failed")
            return nil
        }
        applyMpvStartupOptions(mpv)
        Log.player.info("mpv initializing...")
        let initResult = mpv_initialize(mpv)
        guard initResult >= 0 else {
            let errStr = String(cString: mpv_error_string(initResult))
            Log.player.error("mpv_initialize failed: \(initResult) (\(errStr))")
            mpv_destroy(mpv)
            return nil
        }
        Log.player.info("mpv initialized successfully")
        applyPostInitProperties(mpv)
        applyObservedProperties(mpv)
        return mpv
    }

    nonisolated private func startEventLoop(_ mpv: OpaquePointer) -> Thread {
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.isRunning = true
            self.eventLoop(mpv)
        }
        thread.name = "com.686udjie.PlayerController.eventLoop"
        thread.start()
        return thread
    }

    nonisolated private static func applyMpvStartupOptions(_ mpv: OpaquePointer) {
        mpv_set_option_string(mpv, "vo", "null")
        mpv_set_option_string(mpv, "vid", "no")
        mpv_set_option_string(mpv, "force-window", "no")
        mpv_set_option_string(mpv, "msg-level", "all=error")

        #if targetEnvironment(simulator)
        mpv_set_option_string(mpv, "hwdec", "no")
        mpv_set_option_string(mpv, "audio-exclusive", "no")
        #else
        mpv_set_option_string(mpv, "hwdec", "videotoolbox")
        mpv_set_option_string(mpv, "audio-exclusive", "yes")
        #endif

        mpv_set_option_string(mpv, "keep-open", "no")
        mpv_set_option_string(mpv, "cache", "yes")
        mpv_set_option_string(mpv, "cache-secs", "120")
        mpv_set_option_string(mpv, "demuxer-max-bytes", "200M")
        mpv_set_option_string(mpv, "gapless-audio", "yes")
    }

    nonisolated private static func applyPostInitProperties(_ mpv: OpaquePointer) {
        if let caPath = Bundle.main.path(forResource: "cacert", ofType: "pem") {
            mpv_set_property_string(mpv, "tls-ca-file", caPath)
            Log.player.info("mpv tls-ca-file set: \(caPath)")
        } else {
            Log.player.warning("mpv cacert.pem not found in main bundle")
        }
        let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15" +
            " (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        mpv_set_property_string(mpv, "user-agent", userAgent)
    }

    nonisolated private static func applyObservedProperties(_ mpv: OpaquePointer) {
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
    }

    nonisolated fileprivate func eventLoop(_ mpv: OpaquePointer) {
        while isRunning {
            // Blocks until an event; deinit calls mpv_wakeup to end the loop.
            guard let event = mpv_wait_event(mpv, -1) else { continue }
            // The crossfade deck reports to the crossfade only.
            guard mpv == _mpv else {
                handleDeckEvent(event)
                continue
            }
            switch event.pointee.event_id {
            case MPV_EVENT_NONE:
                break
            case MPV_EVENT_FILE_LOADED:
                handleFileLoaded(mpv)
            case MPV_EVENT_PROPERTY_CHANGE:
                handlePropertyChange(event)
            case MPV_EVENT_START_FILE:
                Log.player.debug("TRANSITION START_FILE")
            case MPV_EVENT_END_FILE:
                handleEndFile(event)
            default:
                break
            }
        }
        if _mpv == mpv { _mpv = nil }
        mpv_destroy(mpv)
    }

    nonisolated private func handleDeckEvent(_ event: UnsafeMutablePointer<mpv_event>) {
        switch event.pointee.event_id {
        case MPV_EVENT_FILE_LOADED:
            spareHasAudio = true
            Task { @MainActor in Crossfade.shared.deckLoaded() }
        case MPV_EVENT_IDLE:
            guard spareHasAudio else { return }
            spareHasAudio = false
            Task { @MainActor in self.restoreAudioOutput() }
        case MPV_EVENT_END_FILE:
            guard let data = event.pointee.data,
                  data.load(as: mpv_event_end_file.self).reason == MPV_END_FILE_REASON_ERROR else { return }
            Task { @MainActor in Crossfade.shared.deckFailed() }
        default:
            break
        }
    }

    nonisolated private func handleFileLoaded(_ mpv: OpaquePointer) {
        var pauseFlag = Int32(1)
        mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &pauseFlag)
        if pauseFlag != 0, desiredPlaying {
            var unpause = Int32(0)
            mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &unpause)
            mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &pauseFlag)
        }
        let actuallyPlaying = pauseFlag == 0
        let aoPtr = mpv_get_property_string(mpv, "current-ao")
        if let aoPtr { mpv_free(aoPtr) }
        let pendingVideoId = self.pendingVideoId
        Task { @MainActor [weak self] in
            guard let self else { return }
            Log.player.debug("TRANSITION FILE_LOADED videoId=\(pendingVideoId ?? "nil") playing=\(actuallyPlaying)")
            self.playState.send(actuallyPlaying ? .playing : .paused)
            NowPlaying.shared.isPlaying = actuallyPlaying
            NowPlaying.shared.isLoadingTrack = false
            Task { await PlaybackStateService.shared.setPlaying(actuallyPlaying) }
            self.currentVideoId = pendingVideoId
            self.pendingVideoId = nil
            if let resume = self.resumeAfterLoad {
                self.resumeAfterLoad = nil
                if resume.videoId == pendingVideoId { self.seek(to: resume.time) }
            }
            self.assertAudioSession()
            self.setNowPlayingMetadata()
            let checkId = pendingVideoId
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard self.currentVideoId == checkId else { return }
                self.updateNowPlayingArtwork()
                self.updateNowPlayingProgress()
            }
        }
    }

    nonisolated private func handlePropertyChange(_ event: UnsafeMutablePointer<mpv_event>) {
        guard let prop = event.pointee.data?.load(as: mpv_event_property.self),
              let namePtr = prop.name else { return }
        let name = String(cString: namePtr)

        if name == "duration", prop.format == MPV_FORMAT_DOUBLE {
            let newDur: Double = prop.data?.load(as: Double.self) ?? 0
            if newDur > 0 {
                Task { @MainActor in
                    NowPlaying.shared.duration = newDur
                    self.setNowPlayingMetadata()
                }
            }
        }
    }

    nonisolated private func handleEndFile(_ event: UnsafeMutablePointer<mpv_event>) {
        guard let data = event.pointee.data else { return }
        let endFile = data.load(as: mpv_event_end_file.self)
        let reason = endFile.reason
        let isEof = reason == MPV_END_FILE_REASON_EOF
        let isError = reason == MPV_END_FILE_REASON_ERROR
        // A stream that fails before FILE_LOADED only has a pending id.
        let stoppedVideoId = isError ? (self.pendingVideoId ?? self.currentVideoId) : self.currentVideoId
        Task { @MainActor [weak self] in
            guard let self else { return }
            let videoId = stoppedVideoId
            Log.player.debug(
                "TRANSITION END_FILE reason=\(reason.rawValue) isEof=\(isEof) isError=\(isError) stoppedVideoId=\(videoId ?? "nil")"
            )
            if isError || isEof { NowPlaying.shared.isLoadingTrack = false }
            if isError, videoId != nil {
                Task { await PlaybackStateService.shared.stopTracking() }
            }
            if isEof, self.isCrossfading {
                Crossfade.shared.outgoingEnded()
            } else if isEof {
                self.playState.send(.stopped)
                NowPlaying.shared.stopped(videoId: videoId, isEof: true)
            } else if isError {
                self.currentVideoId = nil
                self.playState.send(.stopped)
                NowPlaying.shared.stopped(videoId: videoId, isEof: false)
            } else {
                Log.player.debug("END_FILE non-EOF ignored for auto-advance")
            }
        }
    }
}

// MARK: - Crossfade decks

/// An mpv instance handed to `Crossfade`; mpv handles are thread-safe.
struct MpvDeck: @unchecked Sendable, Equatable {
    let handle: OpaquePointer
}

extension PlayerController {
    /// File path or stream URL of the playing song.
    var activePath: String? {
        withMpv { mpv -> String? in
            guard let path = mpv_get_property_string(mpv, "path") else { return nil }
            defer { mpv_free(path) }
            return String(cString: path)
        } ?? nil
    }

    var activeDeck: MpvDeck? {
        mpvAccessQueue.sync { _mpv.map(MpvDeck.init) }
    }

    /// The second instance, created and started on first use.
    func spareDeck() async -> MpvDeck? {
        await withCheckedContinuation { continuation in
            mpvAccessQueue.async { [self] in
                if _spare == nil, let mpv = Self.createHandle() {
                    _spare = mpv
                    _ = startEventLoop(mpv)
                }
                continuation.resume(returning: _spare.map(MpvDeck.init))
            }
        }
    }

    nonisolated func deck(_ deck: MpvDeck, set name: String, _ value: String) {
        mpvAccessQueue.async { _ = mpv_set_property_string(deck.handle, name, value) }
    }

    /// Playback positions of two decks read together, so they can be
    /// compared. `audio-pts` accounts for the audio output delay.
    nonisolated func positions(_ outgoing: MpvDeck, _ incoming: MpvDeck) -> (outgoing: Double, incoming: Double)? {
        mpvAccessQueue.sync {
            func position(_ deck: MpvDeck) -> Double? {
                var value = Double(0)
                if mpv_get_property(deck.handle, "audio-pts", MPV_FORMAT_DOUBLE, &value) >= 0 { return value }
                if mpv_get_property(deck.handle, "time-pos", MPV_FORMAT_DOUBLE, &value) >= 0 { return value }
                return nil
            }
            guard let out = position(outgoing), let inc = position(incoming) else { return nil }
            return (out, inc)
        }
    }

    nonisolated func deck(_ deck: MpvDeck, command args: [String]) {
        mpvAccessQueue.async { _ = args.withUnsafeCArg { mpv_command(deck.handle, $0) } }
    }

    /// Makes the spare deck the playing one. The old deck keeps fading out
    /// as the new spare until `Crossfade` pauses it.
    func promoteSpare(videoId: String, loudness: Double?) {
        mpvAccessQueue.sync { swap(&_mpv, &_spare) }
        spareHasAudio = true
        currentVideoId = videoId
        pendingVideoId = nil
        currentLoudnessDb = loudness
        let generation = playGeneration
        Task {
            await PlaybackStateService.shared.stopTracking()
            // A song started meanwhile tracks itself.
            guard generation == playGeneration else { return }
            await PlaybackStateService.shared.startTracking(videoId: videoId)
        }
    }
}

// MARK: - Audio session / interruption handling

extension PlayerController {
    /// An idle spare deck closed its audio output, and mpv's iOS output
    /// deactivates the audio session when it closes, which stops the playing
    /// deck's output too. Reactivate the session and restart that output.
    func restoreAudioOutput() {
        Log.player.notice("Spare deck went idle; restoring audio output")
        assertAudioSession()
        guard desiredPlaying else { return }
        withMpv { mpv in
            mpv_set_property_string(mpv, "pause", "yes")
            mpv_set_property_string(mpv, "pause", "no")
        }
    }

    func assertAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playback || session.mode != .default {
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            }
            try session.setActive(true)
        } catch {
            Log.player.error("Failed to assert audio session: \(error)")
        }
    }

    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            Log.player.info("AUDIO_INTERRUPTION began")
            wasPlayingBeforeInterruption = desiredPlaying || playState.value == .playing
            if playState.value == .playing {
                Task { @MainActor in
                    self.setPaused(true)
                    self.desiredPlaying = self.wasPlayingBeforeInterruption
                }
            }
        case .ended:
            Log.player.info("AUDIO_INTERRUPTION ended")
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            let shouldResume = options.contains(.shouldResume) || wasPlayingBeforeInterruption
            Task { @MainActor in
                guard shouldResume else { return }
                self.assertAudioSession()
                if self.playState.value != .playing {
                    self.setPaused(false)
                }
                self.wasPlayingBeforeInterruption = false
            }
        @unknown default:
            break
        }
    }

    private func observeAudioSessionReset() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
    }

    @objc private func handleAudioSessionReset() {
        Log.player.notice("AUDIO_SESSION reset")
        Task { @MainActor in
            self.assertAudioSession()
            self.setNowPlayingMetadata()
            if self.desiredPlaying, self.playState.value != .playing {
                self.setPaused(false)
            }
        }
    }

    @objc nonisolated private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        Log.player.info("ROUTE_CHANGE reason=\(reason.rawValue)")
        // iOS posts route changes off the main thread; read playState on main.
        guard reason == .oldDeviceUnavailable else { return }
        Task { @MainActor in
            if self.playState.value == .playing { self.togglePlayPause() }
        }
    }
}

// MARK: - Now Playing info / lock-screen

extension PlayerController {
    func setNowPlayingMetadata() {
        assertAudioSession()
        let np = NowPlaying.shared
        nowPlayingInfo.removeAll()

        let liveDur = withMpv { mpv in
            var val = Double(0)
            mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &val)
            return val
        } ?? 0
        let duration = liveDur > 0 ? liveDur : np.duration
        if duration > 0 { np.duration = duration }

        let livePos = withMpv { mpv in
            var val = Double(0)
            mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &val)
            return val
        } ?? 0
        let elapsed = livePos > 0 ? livePos : np.currentTime

        nowPlayingInfo[MPMediaItemPropertyTitle] = np.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = np.artist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = np.albumTitle
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = np.isPlaying ? 1 : 0
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1
        if duration > 0 { nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration }
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackQueueIndex] = np.queueIndex
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackQueueCount] = np.queueSongs.count
        if let image = np.thumbnailUIImage {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        MPNowPlayingInfoCenter.default().playbackState = np.isPlaying ? .playing : .paused
        lastProgressPush = (elapsed, Date(), np.queueSongs.count)
        Log.player.info(
            "NOW_PLAYING_PUBLISH title='\(np.title)' artist='\(np.artist)' " +
            "duration=\(duration) rate=\(nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] ?? 0) " +
            "artwork=\(np.thumbnailUIImage != nil) keys=\(nowPlayingInfo.keys.count)"
        )
    }

    func updateNowPlayingArtwork() {
        let np = NowPlaying.shared
        if let image = np.thumbnailUIImage {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    /// `onlyIfDrifted`: the 0.25 s progress timer passes true, so the lock
    /// screen is only updated when its own clock is off by a second or more
    /// (seek, stall, song change) or the queue length changed.
    func updateNowPlayingProgress(onlyIfDrifted: Bool = false) {
        let props: (dur: Double, pos: Double)? = withMpv { mpv in
            var dur = Double(0)
            mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &dur)
            var pos = Double(0)
            mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &pos)
            return (dur, pos)
        }
        guard var props, props.dur > 0 else { return }
        let np = NowPlaying.shared

        if let seek = pendingSeek {
            if abs(props.pos - seek.target) > 1, Date() < seek.deadline {
                props.pos = seek.target
            } else {
                pendingSeek = nil
            }
        }

        var info = nowPlayingInfo
        info[MPMediaItemPropertyPlaybackDuration] = props.dur
        // Observation notifies on every write, even of an equal value.
        if np.duration != props.dur { np.duration = props.dur }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = props.pos
        np.currentTime = props.pos
        info[MPNowPlayingInfoPropertyPlaybackRate] = np.isPlaying ? 1 : 0
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = np.queueIndex
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = np.queueSongs.count
        nowPlayingInfo = info
        let now = Date()
        if onlyIfDrifted, np.isPlaying, let last = lastProgressPush, last.queueCount == np.queueSongs.count,
           abs(props.pos - last.position - now.timeIntervalSince(last.at)) < 1 {
            return
        }
        lastProgressPush = (props.pos, now, np.queueSongs.count)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = np.isPlaying ? .playing : .paused
    }
}

// MARK: - Remote commands

extension PlayerController {
    nonisolated static func registerRemoteControlSupport() {
        MainActor.assumeIsolated {
            UIApplication.shared.beginReceivingRemoteControlEvents()
            Log.player.info("REMOTE_COMMANDS launch-time beginReceivingRemoteControlEvents")
        }
    }

    fileprivate func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Log.player.info("REMOTE_COMMAND play fired")
            Task { @MainActor [weak self] in self?.setPaused(false) }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Log.player.info("REMOTE_COMMAND pause fired")
            Task { @MainActor [weak self] in self?.setPaused(true) }
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Log.player.info("REMOTE_COMMAND togglePlayPause fired")
            Task { @MainActor [weak self] in self?.togglePlayPause() }
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { _ in
            Log.player.info("REMOTE_COMMAND next fired")
            Task { @MainActor in NowPlaying.shared.playNext() }
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { _ in
            Log.player.info("REMOTE_COMMAND previous fired")
            Task { @MainActor in NowPlaying.shared.playPrevious() }
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Log.player.info("REMOTE_COMMAND seek fired to=\(position)")
            Task { @MainActor [weak self] in self?.seek(to: position) }
            return .success
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Keep the audio session alive while the screen is locked so
                // auto-advance can keep playing without user interaction.
                if self.desiredPlaying {
                    self.assertAudioSession()
                }
                self.setNowPlayingMetadata()
                self.updateNowPlayingProgress()
            }
            for delaySeconds in [0.6, 3] as [Double] {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                    guard let self, UIApplication.shared.applicationState != .active else { return }
                    self.setNowPlayingMetadata()
                    self.updateNowPlayingProgress()
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.assertAudioSession()
                self.updateNowPlayingProgress()
            }
        }
    }
}

extension Array where Element == String {
    func withUnsafeCArg<T>(_ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> T) -> T {
        let cstrings = map { strdup($0) }
        defer { cstrings.forEach { free($0) } }
        var ptrs = cstrings.map { UnsafePointer($0) } + [nil]
        return ptrs.withUnsafeMutableBufferPointer { buf in
            body(buf.baseAddress)
        }
    }
}
