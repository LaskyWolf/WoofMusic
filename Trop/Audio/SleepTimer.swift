//
//  SleepTimer.swift
//  Trop
//

import Foundation
import Observation

/// Pauses playback after a countdown or when the current song ends.
@MainActor
@Observable
final class SleepTimer {
    static let shared = SleepTimer()

    /// When the countdown pauses playback; nil unless a countdown is running.
    private(set) var endsAt: Date?
    /// Pause when the current song ends instead of after a countdown.
    private(set) var stopsAtSongEnd = false
    /// The preset the running countdown was started with, for the picker's checkmark.
    private(set) var minutes: Int?
    /// True for `celebrationSeconds` after the timer ends, while the player plays its animation.
    private(set) var isCelebrating = false
    /// When the animation started; it draws itself from the time passed since then.
    private(set) var endedAt: Date?

    /// Shown in turn by the animation, one per time the timer ends.
    static let messages = ["Good night", "Sleep well", "Sweet dreams"]
    private static let messageIndexKey = "sleepTimerMessageIndex"
    /// The title of the current animation.
    private(set) var message = SleepTimer.messages[0]

    static let celebrationSeconds = 15.0
    /// How long before the end the player starts announcing it.
    static let preludeSeconds = 10.0

    var isActive: Bool { endsAt != nil || stopsAtSongEnd }

    /// Where the animation is on its timeline: negative during the prelude
    /// (minus the seconds left), positive after the timer ended, nil when idle.
    func animationTime(at date: Date) -> Double? {
        if isCelebrating, let endedAt { return date.timeIntervalSince(endedAt) }
        guard let remaining = secondsUntilEnd(at: date), remaining <= Self.preludeSeconds else { return nil }
        return -max(remaining, 0)
    }

    /// When the song is expected to end. The song position arrives four times a
    /// second with some jitter: following each sample makes the animation clock
    /// jump back and forth, so the end date only moves when the song really jumped.
    @ObservationIgnored private var predictedSongEnd: Date?
    private static let songJumpTolerance = 0.75

    private func secondsUntilEnd(at date: Date) -> Double? {
        if let endsAt { return endsAt.timeIntervalSince(date) }
        guard stopsAtSongEnd else { return nil }
        let np = NowPlaying.shared
        guard np.duration > 0 else { return nil }
        let reported = np.duration - np.currentTime
        guard np.isPlaying else {
            predictedSongEnd = nil
            return reported
        }
        if let end = predictedSongEnd, abs(end.timeIntervalSince(date) - reported) < Self.songJumpTolerance {
            return end.timeIntervalSince(date)
        }
        predictedSongEnd = date.addingTimeInterval(reported)
        return reported
    }

    /// "until 23:10" or "end of song", for the menu label.
    var summary: String? {
        if stopsAtSongEnd { return "end of song" }
        guard let endsAt else { return nil }
        return "until " + endsAt.formatted(date: .omitted, time: .shortened)
    }

    private var countdown: Task<Void, Never>?

    func start(minutes: Int) {
        cancel()
        isCelebrating = false
        let deadline = Date().addingTimeInterval(Double(minutes) * 60)
        endsAt = deadline
        self.minutes = minutes
        countdown = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60), clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.fire(deadline: deadline)
        }
    }

    func stopAtSongEnd() {
        cancel()
        isCelebrating = false
        stopsAtSongEnd = true
    }

    func cancel() {
        countdown?.cancel()
        countdown = nil
        endsAt = nil
        minutes = nil
        stopsAtSongEnd = false
    }

    /// The song ended with "End of Song" selected: clear the timer and play the animation.
    func finishAtSongEnd() {
        cancel()
        celebrate()
    }

    private func celebrate() {
        let defaults = UserDefaults.standard
        let index = defaults.integer(forKey: Self.messageIndexKey) % Self.messages.count
        message = Self.messages[index]
        defaults.set(index + 1, forKey: Self.messageIndexKey)
        let start = Date()
        endedAt = start
        isCelebrating = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.celebrationSeconds))
            guard let self, self.endedAt == start else { return }
            self.isCelebrating = false
        }
    }

    private func fire(deadline: Date) {
        // iOS freezes the app while nothing plays. Waking up long after the
        // deadline means the user came back on their own: don't pause them.
        let isLate = Date().timeIntervalSince(deadline) > 30
        cancel()
        guard !isLate else { return }
        PlayerController.shared.setPaused(true)
        celebrate()
    }
}
