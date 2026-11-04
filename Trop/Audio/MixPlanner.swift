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
        /// Mix progress (0...1) until which the incoming song is held down
        /// because both songs sing over each other. Nil when neither does.
        var duckUntil: Double?
        /// Whether the two keys mix well; nil when a key is unknown.
        var keysCompatible: Bool?

        var isBeatMatched: Bool { beats != nil }
    }

    /// Largest tempo change a crossfade applies quietly, and the largest an
    /// AutoMix applies (about what a DJ pitch fader allows).
    static let maxTempoNudge = 0.06
    static let maxTempoMatch = 0.08
    static let maxIntroSkip = 10.0
    /// Intro an AutoMix may skip to land the incoming song's first strong
    /// phrase on the end of the mix.
    static let maxPhraseSkip = 30.0
    /// AutoMix lengths to try, longest first. Multiples of 8 so the bass
    /// swap halfway lands on a bar line.
    static let mixBeats = [32, 16, 8]
    /// Bars the mix start may move earlier to begin where nobody sings.
    static let maxVocalShift = 4
    /// Incoming level (linear) while both songs sing.
    static let duckLevel = 0.5

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
    /// It starts where the outgoing song's outro begins when one is heard,
    /// avoids starting over a sung bar, and lands the incoming song's first
    /// strong phrase on the end of the mix. Clashing keys or vocals on both
    /// sides shorten the mix. Nil when either song has no steady beat or the
    /// tempos are too far apart; the caller then uses `smart`.
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
        let outro = TrackAnalyzer.outroBar(tail.barEnergy).map { tailStart + tail.barTime($0) }

        let inBar = 60 / inBPM * Double(TrackAnalyzer.beatsPerBar)
        let firstBar = snap(head.soundStart, gridStart: head.downbeat, step: inBar, rounding: .up)
        let defaultIn = firstBar > maxIntroSkip ? head.downbeat : firstBar
        let rise = TrackAnalyzer.firstRiseBar(head.barEnergy).map { head.barTime($0) }

        var keysCompatible: Bool?
        if let outKey = tail.key, let inKey = head.key { keysCompatible = outKey.isCompatible(with: inKey) }
        let options = keysCompatible == false ? Array(mixBeats.dropFirst()) : mixBeats

        for beats in options {
            let length = Double(beats) * period
            var start: Double
            if let outro, outro >= earliest, outro + length <= outEnd {
                start = outro
            } else {
                let latestStart = outEnd - length
                guard latestStart >= earliest else { continue }
                start = snap(latestStart, gridStart: firstDownbeat, step: bar, rounding: .down)
                guard start >= earliest else { continue }
            }
            // Step back up to a few bars to start where the outgoing song doesn't sing.
            if tail.hasVocals(in: (start - tailStart)..<(start - tailStart + bar)) {
                for shift in 1...maxVocalShift {
                    let candidate = start - Double(shift) * bar
                    guard candidate >= earliest else { break }
                    if !tail.hasVocals(in: (candidate - tailStart)..<(candidate - tailStart + bar)) {
                        start = candidate
                        break
                    }
                }
            }
            // The incoming song's first strong phrase lands on the end of the
            // mix, or on its halfway bar when its intro is too short. Never
            // inside the leading silence.
            var inStart = defaultIn
            if let rise {
                let aligned = [rise - length * speed, rise - length * speed / 2]
                if let fit = aligned.first(where: { $0 >= firstBar - 1e-6 && $0 <= maxPhraseSkip }) { inStart = fit }
            }
            inStart = max(0, inStart)

            // Both singing over each other: a shorter mix, or the last resort
            // of holding the incoming song down until the outgoing line ends.
            var duckUntil: Double?
            let outVocals = tail.lastVocalEnd(in: (start - tailStart)..<(start - tailStart + length))
            if let outVocals, head.hasVocals(in: inStart..<(inStart + length * speed)) {
                if beats != options.last { continue }
                // Released over 2 beats, so it is back up before the mix ends.
                duckUntil = min(1 - 2 / Double(beats), (outVocals + tailStart - start) / length)
            }
            return Mix(
                fadeStart: start, fadeLength: length, inStart: inStart, speed: speed, beats: beats,
                beatPeriod: period, duckUntil: duckUntil, keysCompatible: keysCompatible
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

    /// What the music does around the mix, read from the bar energies.
    struct Cues: Equatable {
        /// The outgoing song gets quieter through the mix.
        var outFalling = false
        /// The outgoing song stays near its loudest through the mix.
        var outHigh = false
        /// The incoming song gets louder from where it comes in to the mix end.
        var inRising = false
        /// The outgoing song's outro lasts 8 bars or more.
        var longOutro = false
    }

    /// The cues for `mix` between `tail` and `head`.
    static func cues(for mix: Mix, tail: TrackAnalyzer.Result, tailStart: Double, head: TrackAnalyzer.Result) -> Cues {
        guard let bar = tail.barLength, let inBar = head.barLength, bar > 0, inBar > 0 else { return Cues() }
        func mean(_ energy: [Float], _ from: Int, _ count: Int) -> Float? {
            let range = max(0, from)..<min(energy.count, max(0, from) + count)
            return range.isEmpty ? nil : energy[range].reduce(0, +) / Float(range.count)
        }
        var cues = Cues()
        let bars = max(1, Int((mix.fadeLength / bar).rounded()))
        let startBar = Int(((mix.fadeStart - tailStart - tail.downbeat) / bar).rounded())
        if let before = mean(tail.barEnergy, startBar - 4, 4), let during = mean(tail.barEnergy, startBar, bars) {
            cues.outFalling = during < before * 0.7
            cues.outHigh = during >= 0.75
        }
        let inBars = max(1, Int((mix.fadeLength * mix.speed / inBar).rounded()))
        let inBar0 = Int(((mix.inStart - head.downbeat) / inBar).rounded())
        if let entry = mean(head.barEnergy, inBar0, 4), let after = mean(head.barEnergy, inBar0 + inBars, 4) {
            cues.inRising = after > entry * 1.3
        }
        if let outro = TrackAnalyzer.outroBar(tail.barEnergy) {
            cues.longOutro = tail.soundEnd - tail.barTime(outro) >= 8 * bar
        }
        return cues
    }

    /// The style of a mix; `.blend` when it isn't beat-matched. `echoPeriod`
    /// is the beat the outgoing song's echo was built for, `room` the
    /// seconds the outgoing song plays on after the mix (a tail needs them).
    /// The music picks: a falling outgoing song gets an echo or a wash, a
    /// loud one meeting a rising one a sweep, a long outro over a steady
    /// beat a loop, clashing keys the tails that hide them. `variety`
    /// rotates between the styles left.
    static func style(for mix: Mix, echoPeriod: Double?, room: Double, cues: Cues, variety: Int) -> Style {
        guard let period = mix.beatPeriod else { return .blend }
        let canWash = room >= washTail
        if abs(mix.speed - 1) > washTempoChange, canWash { return .wash }
        var fits: [Style] = [.sweep]
        if loopBar(for: mix) != nil { fits.append(.loop) }
        if let echoPeriod, abs(echoPeriod / period - 1) <= maxEchoDrift, room >= echoTail(period: period) {
            fits.append(.echo)
        }
        if canWash { fits.append(.wash) }

        var preferred: [Style] = []
        if mix.keysCompatible == false {
            preferred = [.wash, .echo]
        } else if cues.outFalling {
            preferred = [.echo, .wash]
        } else if cues.outHigh, cues.inRising {
            preferred = [.sweep]
        } else if cues.longOutro {
            preferred = [.loop]
        }
        let styles = preferred.filter(fits.contains)
        let choice = styles.isEmpty ? fits : styles
        return choice[abs(variety) % choice.count]
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
