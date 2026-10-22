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
        }
        // A paused player stays paused when the track changes.
        desiredPlaying = playState.value != .paused
        assertAudioSession()
        if let videoId { await PlaybackStateService.shared.startTracking(videoId: videoId) }

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
        pendingSeek = (time, Date().addingTimeInterval(1.5))
        NowPlaying.shared.currentTime = time
        withMpv { mpv in
            var val = time
            let result = mpv_set_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &val)
            if result < 0 { Log.player.error("seek failed: mpv error \(result)") }
        }
    }

    func setPaused(_ paused: Bool) {
        // After the queue ends mpv holds no file: unpausing it would play silence.
        if !paused, playState.value == .stopped, pendingVideoId == nil {
            NowPlaying.shared.playCurrentSong(logContext: "resume")
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
        let settings = SettingsStore.shared
        let loudness = currentLoudnessDb
        let eqEnabled = settings.equalizerEnabled
        let eqGains = settings.equalizerGains
        let gapless = settings.gaplessPlayback
        let norm = settings.audioNormalization

        let chain: String = {
            var filters: [String] = []
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

        withMpv { mpv in
            mpv_set_property_string(mpv, "gapless-audio", gapless ? "yes" : "no")
            let result = mpv_set_property_string(mpv, "af", chain.isEmpty ? "" : chain)
            if result < 0 { Log.player.error("Failed to set af chain '\(chain)': mpv error \(result)") }
        }
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
            guard let mpv = mpv_create() else {
                Log.player.error("mpv_create failed")
                return
            }

            _ = setenv("MVK_CONFIG_LOG_LEVEL", "1", 1)

            Self.applyMpvStartupOptions(mpv)

            Log.player.info("mpv initializing...")
            let initResult = mpv_initialize(mpv)
            guard initResult >= 0 else {
                let errStr = String(cString: mpv_error_string(initResult))
                Log.player.error("mpv_initialize failed: \(initResult) (\(errStr))")
                mpv_destroy(mpv)
                return
            }
            Log.player.info("mpv initialized successfully")

            Self.applyPostInitProperties(mpv)
            Self.applyObservedProperties(mpv)

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

            let thread = Thread { [weak self] in
                guard let self else { return }
                self.isRunning = true
                self.eventLoop(mpv)
            }
            self.eventLoopThread = thread
            thread.name = "com.686udjie.PlayerController.eventLoop"
            thread.start()
        }
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
            guard let event = mpv_wait_event(mpv, 0.2) else { continue }
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
        _mpv = nil
        mpv_destroy(mpv)
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
            Task { await PlaybackStateService.shared.setPlaying(actuallyPlaying) }
            self.currentVideoId = pendingVideoId
            self.pendingVideoId = nil
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
            if isError, videoId != nil {
                Task { await PlaybackStateService.shared.stopTracking() }
            }
            if isEof {
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

// MARK: - Audio session / interruption handling

extension PlayerController {
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

    func updateNowPlayingProgress() {
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
        np.duration = props.dur
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = props.pos
        np.currentTime = props.pos
        info[MPNowPlayingInfoPropertyPlaybackRate] = np.isPlaying ? 1 : 0
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = np.queueIndex
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = np.queueSongs.count
        nowPlayingInfo = info
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
            Task { @MainActor [weak self] in
                self?.seek(to: position)
                self?.updateNowPlayingProgress()
            }
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
