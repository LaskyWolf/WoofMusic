//
//  MixPlanner.swift
//  Trop
//

import Foundation

/// Decides where a transition between two songs starts and how it runs,
/// from the analysis of the outgoing song's end and the incoming song's
/// start. Pure math, tested by `scripts/check_track_analyzer.py`.
enum MixPlanner {
    struct Mix: Equatable {
        /// Outgoing position where the transition starts, in seconds.
        var fadeStart: Double
        var fadeLength: Double
        /// Incoming position the transition starts from.
        var inStart: Double
        /// Incoming playback speed during the transition (1 = unchanged).
        var speed: Double
        /// Beat-matched mix (AutoMix): its length in beats and the outgoing
        /// beat length in seconds. Nil for a timed crossfade.
        var beats: Int?
        var beatPeriod: Double?

        var isBeatMatched: Bool { beats != nil }
    }

    /// Largest tempo change a crossfade applies quietly, and the largest an
    /// AutoMix applies (about what a DJ pitch fader allows).
    static let maxTempoNudge = 0.06
    static let maxTempoMatch = 0.08
    static let maxIntroSkip = 10.0
    /// AutoMix lengths to try, longest first. Multiples of 8 so the bass
    /// swap halfway lands on a bar line.
    static let mixBeats = [32, 16, 8]

    /// Smart Crossfade: a timed equal-power fade that ends where the outgoing
    /// song goes quiet and starts on one of its beats. Without analysis it
    /// falls back to a plain fade that ends with the song.
    static func smart(
        duration: Double,
        fadeLength: Double,
        tail: TrackAnalyzer.Result?,
        tailStart: Double,
        head: TrackAnalyzer.Result?
    ) -> Mix {
        let outEnd = min(duration, tail.map { tailStart + $0.soundEnd } ?? duration)
        let earliest = duration * 0.5
        var fadeStart = max(earliest, outEnd - fadeLength)
        if let tail, let period = tail.beatPeriod {
            let beat = snap(fadeStart, gridStart: tailStart + tail.firstBeat, step: period, rounding: .down)
            if beat >= earliest { fadeStart = beat }
        }

        var inStart = 0.0
        if let head {
            inStart = head.soundStart
            if let period = head.beatPeriod {
                inStart = snap(head.soundStart, gridStart: head.firstBeat, step: period, rounding: .up)
            }
            if inStart > maxIntroSkip { inStart = 0 }
        }

        var speed = 1.0
        if let outBPM = tail?.bpm, let inBPM = head?.bpm, abs(outBPM / inBPM - 1) <= maxTempoNudge {
            speed = outBPM / inBPM
        }
        return Mix(fadeStart: fadeStart, fadeLength: fadeLength, inStart: max(0, inStart), speed: speed)
    }

    /// AutoMix: a beat-matched transition of 8 to 32 beats that starts on an
    /// outgoing downbeat, brings the incoming song in on its own downbeat at
    /// the outgoing tempo, and ends before the outgoing song goes quiet.
    /// Nil when either song has no steady beat or the tempos are too far
    /// apart; the caller then uses `smart`.
    static func autoMix(
        duration: Double,
        tail: TrackAnalyzer.Result?,
        tailStart: Double,
        head: TrackAnalyzer.Result?
    ) -> Mix? {
        guard let tail, let head, let outBPM = tail.bpm, let inBPM = head.bpm else { return nil }
        let speed = outBPM / inBPM
        guard abs(speed - 1) <= maxTempoMatch else { return nil }

        let period = 60 / outBPM
        let bar = period * Double(TrackAnalyzer.beatsPerBar)
        let outEnd = min(duration, tailStart + tail.soundEnd)
        let firstDownbeat = tailStart + tail.downbeat
        let earliest = max(firstDownbeat, duration * 0.5)

        let inBar = 60 / inBPM * Double(TrackAnalyzer.beatsPerBar)
        var inStart = snap(head.soundStart, gridStart: head.downbeat, step: inBar, rounding: .up)
        if inStart > maxIntroSkip { inStart = head.downbeat }

        for beats in mixBeats {
            let length = Double(beats) * period
            let latestStart = outEnd - length
            guard latestStart >= earliest else { continue }
            let start = snap(latestStart, gridStart: firstDownbeat, step: bar, rounding: .down)
            guard start >= earliest else { continue }
            return Mix(
                fadeStart: start, fadeLength: length, inStart: max(0, inStart),
                speed: speed, beats: beats, beatPeriod: period
            )
        }
        return nil
    }

    /// The grid point (`gridStart + k * step`) nearest `time` in the given
    /// direction.
    static func snap(_ time: Double, gridStart: Double, step: Double, rounding: FloatingPointRoundingRule) -> Double {
        gridStart + ((time - gridStart) / step).rounded(rounding) * step
    }
}
