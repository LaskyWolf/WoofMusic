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

    /// Minutes offered in the player menu.
    static let presetMinutes = [5, 15, 30, 45, 60]

    /// When the countdown pauses playback; nil unless a countdown is running.
    private(set) var endsAt: Date?
    /// Pause when the current song ends instead of after a countdown.
    private(set) var stopsAtSongEnd = false
    /// True for `celebrationSeconds` after the timer ends, while the player plays its animation.
    private(set) var isCelebrating = false
    /// When the animation started; it draws itself from the time passed since then.
    private(set) var endedAt: Date?

    static let celebrationSeconds = 15.0

    var isActive: Bool { endsAt != nil || stopsAtSongEnd }

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
        stopsAtSongEnd = false
    }

    /// The song ended with "End of Song" selected: clear the timer and play the animation.
    func finishAtSongEnd() {
        cancel()
        celebrate()
    }

    private func celebrate() {
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
