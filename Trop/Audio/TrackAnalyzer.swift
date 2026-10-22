//
//  TrackAnalyzer.swift
//  Trop
//

import Foundation

/// Finds where a stretch of audio is loud, and its tempo and beat positions.
/// Used to pick crossfade points. Works on mono samples, so it has no
/// dependencies and `scripts/check_track_analyzer.py` can test it alone.
enum TrackAnalyzer {
    struct Result: Equatable {
        /// First and last moment the audio is above the quiet threshold, in seconds.
        var soundStart: Double
        var soundEnd: Double
        /// Beats per minute, nil when no steady beat was found.
        var bpm: Double?
        /// Time of the first beat, in seconds.
        var firstBeat: Double

        var beatPeriod: Double? { bpm.map { 60 / $0 } }
    }

    static let sampleRate = 11_025
    private static let hop = 256

    // MARK: Analysis

    static func analyze(_ samples: [Float], sampleRate: Int = sampleRate) -> Result? {
        let frameCount = samples.count / hop
        guard frameCount > 16 else { return nil }

        // Loudness per frame (RMS).
        var rms = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            let start = frame * hop
            for i in start..<(start + hop) { sum += samples[i] * samples[i] }
            rms[frame] = (sum / Float(hop)).squareRoot()
        }
        let frameSeconds = Double(hop) / Double(sampleRate)

        // "Quiet" = 26 dB below the loudest frame.
        let threshold = (rms.max() ?? 0) * 0.05
        guard threshold > 0,
              let first = rms.firstIndex(where: { $0 > threshold }),
              let last = rms.lastIndex(where: { $0 > threshold }) else { return nil }

        // Onset strength: how much louder each frame is than the one before.
        // Drum hits make sharp jumps; the beat is the rhythm of those jumps.
        var onset = [Float](repeating: 0, count: frameCount)
        for frame in 1..<frameCount {
            let rise = log(rms[frame] + 1e-6) - log(rms[frame - 1] + 1e-6)
            onset[frame] = max(0, rise)
        }

        let (bpm, firstBeat) = tempo(onset: onset, frameSeconds: frameSeconds)
        return Result(
            soundStart: Double(first) * frameSeconds,
            soundEnd: Double(last + 1) * frameSeconds,
            bpm: bpm,
            firstBeat: firstBeat
        )
    }

    /// Autocorrelation of the onset curve: the lag where the curve best
    /// matches a shifted copy of itself is the beat period.
    private static func tempo(onset: [Float], frameSeconds: Double) -> (Double?, Double) {
        let minBPM = 70.0, maxBPM = 180.0
        let minLag = max(1, Int((60 / maxBPM / frameSeconds).rounded(.down)))
        let maxLag = Int((60 / minBPM / frameSeconds).rounded(.up))
        // Without clear hits (a 10% jump in loudness) there is no beat to find.
        guard onset.count > maxLag * 4, (onset.max() ?? 0) > 0.1 else { return (nil, 0) }

        var scores: [Float] = []
        for lag in minLag...maxLag {
            var sum: Float = 0
            for i in lag..<onset.count { sum += onset[i] * onset[i - lag] }
            scores.append(sum / Float(onset.count - lag))
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return (nil, 0) }
        let mean = scores.reduce(0, +) / Float(scores.count)
        // A flat curve means no steady beat (ambient, speech).
        guard mean > 0, scores[best] > mean * 1.3 else { return (nil, 0) }

        // Refine the lag between frames with a parabola through the peak.
        var lag = Double(best + minLag)
        if best > 0, best < scores.count - 1 {
            let a = Double(scores[best - 1]), b = Double(scores[best]), c = Double(scores[best + 1])
            let denom = a - 2 * b + c
            if denom != 0 { lag += 0.5 * (a - c) / denom }
        }
        var bpm = 60 / (lag * frameSeconds)
        // Fold into the range DJs count in, so 70 and 140 compare as equal.
        while bpm < 85 { bpm *= 2 }
        while bpm > 170 { bpm /= 2 }

        // Beat grid: the period and offset whose beats land on the most
        // onsets. Fine-tuning the period too matters: a tempo off by 0.5 BPM
        // drifts 70 ms over 40 beats.
        let basePeriod = 60 / bpm / frameSeconds
        var grid = (score: Float(-1), period: basePeriod, phase: 0.0)
        for step in -20...20 {
            let period = basePeriod * (1 + Double(step) * 0.001)
            var phase = 0.0
            while phase < period {
                var sum: Float = 0
                var position = phase
                while Int(position) < onset.count {
                    sum += onset[Int(position)]
                    position += period
                }
                if sum > grid.score { grid = (sum, period, phase) }
                phase += 0.5
            }
        }
        return (60 / (grid.period * frameSeconds), grid.phase * frameSeconds)
    }
}
