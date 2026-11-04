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

    // MARK: AutoMix styles

    /// How an AutoMix lets the outgoing song go, on top of the bass swap.
    enum Style: String {
        /// Volume fades only: no effect filters.
        case blend
        /// The outgoing song thins out through a rising high-pass while the
        /// incoming song's low-pass opens.
        case sweep
        /// The outgoing song's last bar feeds an echo on the beat, which
        /// keeps repeating after the song is cut.
        case echo
        /// The outgoing song dissolves into a reverb-like tail.
        case wash
        /// The outgoing song repeats a bar near its end instead of playing on.
        case loop
    }

    /// Echo repeats, and how far off the outgoing beat the echo built for
    /// the song may be.
    static let echoRepeats = 4
    static let maxEchoDrift = 0.02
    /// Tempo change above which stretched beats smear and a wash hides them.
    static let washTempoChange = 0.04
    /// Seconds the reverb rings after the outgoing song is cut.
    static let washTail: Double = 1

    /// The style of a mix; `.blend` when it isn't beat-matched. `echoPeriod`
    /// is the beat the outgoing song's echo was built for, `room` the
    /// seconds the outgoing song plays on after the mix (a tail needs them),
    /// `variety` rotates between the styles that fit.
    static func style(for mix: Mix, echoPeriod: Double?, room: Double, variety: Int) -> Style {
        guard let period = mix.beatPeriod else { return .blend }
        let canWash = room >= washTail
        if abs(mix.speed - 1) > washTempoChange, canWash { return .wash }
        var styles: [Style] = [.sweep]
        if loopBar(for: mix) != nil { styles.append(.loop) }
        if let echoPeriod, abs(echoPeriod / period - 1) <= maxEchoDrift, room >= echoTail(period: period) {
            styles.append(.echo)
        }
        if canWash { styles.append(.wash) }
        return styles[abs(variety) % styles.count]
    }

    /// Seconds the echo rings after the outgoing song is cut.
    static func echoTail(period: Double) -> Double {
        Double(echoRepeats) * period
    }

    /// The bar the loop style repeats (outgoing seconds) and how many extra
    /// times. The repeats replace the mix's last bars, so the mix keeps its
    /// length. Nil for mixes shorter than 4 bars.
    static func loopBar(for mix: Mix) -> (bar: Range<Double>, repeats: Int)? {
        guard let beats = mix.beats, let period = mix.beatPeriod, beats >= 4 * TrackAnalyzer.beatsPerBar else { return nil }
        let repeats = beats >= 8 * TrackAnalyzer.beatsPerBar ? 2 : 1
        let bar = period * Double(TrackAnalyzer.beatsPerBar)
        let start = mix.fadeStart + mix.fadeLength - bar * Double(repeats + 1)
        return (start..<(start + bar), repeats)
    }

    /// `from` at 0 to `to` at 1, evenly in pitch, the way a filter knob sweeps.
    static func sweep(from: Double, to: Double, progress: Double) -> Double {
        from * pow(to / from, min(1, max(0, progress)))
    }

    /// The grid point (`gridStart + k * step`) nearest `time` in the given
    /// direction.
    static func snap(_ time: Double, gridStart: Double, step: Double, rounding: FloatingPointRoundingRule) -> Double {
        gridStart + ((time - gridStart) / step).rounded(rounding) * step
    }
}
