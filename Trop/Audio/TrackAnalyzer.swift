//
//  TrackAnalyzer.swift
//  Trop
//

import Foundation

/// Finds where a stretch of audio is loud, its tempo, its beats and the first
/// beat of each bar (the downbeat). Used to plan crossfades and AutoMix.
/// Works on mono samples, so it has no dependencies and
/// `scripts/check_track_analyzer.py` can test it alone.
enum TrackAnalyzer {
    struct Result: Equatable {
        /// First and last moment the audio is above the quiet threshold, in seconds.
        var soundStart: Double
        var soundEnd: Double
        /// Beats per minute, nil when no steady beat was found.
        var bpm: Double?
        /// Time of the first beat, in seconds.
        var firstBeat: Double
        /// Time of the first downbeat (beat 1 of a 4/4 bar), in seconds.
        var downbeat: Double
        /// Loudness (RMS) of each bar from the downbeat on, relative to the
        /// loudest bar. Empty without a beat.
        var barEnergy: [Float] = []
        /// How much each bar sounds like a sung line (0...1), see `vocalPresence`.
        var barVocal: [Float] = []
        var key: Key?

        var beatPeriod: Double? { bpm.map { 60 / $0 } }
        var barLength: Double? { beatPeriod.map { $0 * Double(TrackAnalyzer.beatsPerBar) } }

        /// Seconds where bar `bar` starts; bars count from the downbeat.
        func barTime(_ bar: Int) -> Double {
            downbeat + Double(bar) * (barLength ?? 0)
        }

        /// Whether a sung line is heard in any bar overlapping `range` (seconds).
        func hasVocals(in range: Range<Double>) -> Bool {
            lastVocalEnd(in: range) != nil
        }

        /// Seconds where the last sung bar overlapping `range` ends, nil when none.
        func lastVocalEnd(in range: Range<Double>) -> Double? {
            guard let barLength else { return nil }
            // A hair of slack so a bar ending on the range's edge doesn't count.
            let slack = barLength * 0.01
            for bar in barVocal.indices.reversed() where barVocal[bar] >= TrackAnalyzer.vocalThreshold {
                let start = barTime(bar)
                if start + slack < range.upperBound, start + barLength - slack > range.lowerBound { return start + barLength }
            }
            return nil
        }
    }

    /// A musical key, estimated from how much each of the 12 notes sounds.
    struct Key: Equatable {
        /// 0 = C, 1 = C♯ ... 11 = B.
        var pitchClass: Int
        var isMinor: Bool

        private static let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

        /// Position on the Camelot wheel: 1...12 plus A (minor) or B (major).
        /// Neighbours on the wheel share most notes, so they mix well.
        var camelotNumber: Int {
            let major = isMinor ? (pitchClass + 3) % 12 : pitchClass
            return (major * 7 % 12 + 7) % 12 + 1
        }

        var camelot: String { "\(camelotNumber)\(isMinor ? "A" : "B")" }
        var name: String { "\(Self.names[pitchClass]) \(isMinor ? "minor" : "major")" }

        /// Same key, its relative major/minor, or one step around the wheel.
        func isCompatible(with other: Key) -> Bool {
            if camelotNumber == other.camelotNumber { return true }
            let steps = (camelotNumber - other.camelotNumber + 12) % 12
            return isMinor == other.isMinor && (steps == 1 || steps == 11)
        }
    }

    static let sampleRate = 11_025
    private static let hop = 256
    static let beatsPerBar = 4
    /// `barVocal` at or above this counts as a sung bar.
    static let vocalThreshold: Float = 0.3

    // MARK: Analysis

    static func analyze(_ samples: [Float], sampleRate: Int = sampleRate) -> Result? {
        let frameCount = samples.count / hop
        guard frameCount > 16 else { return nil }
        let frameSeconds = Double(hop) / Double(sampleRate)

        // Loudness per frame (RMS), for the whole signal and for the bass
        // only. A one-pole low-pass at ~150 Hz keeps the kick drum, which
        // usually marks beat 1 of the bar.
        // The 200 Hz–4 kHz band (voice) is the difference of two more
        // one-poles, for the vocal estimate.
        let lowPass = Float(2 * Double.pi * 150 / Double(sampleRate))
        let voiceLow = Float(2 * Double.pi * 200 / Double(sampleRate))
        let voiceHigh = Float(2 * Double.pi * 4000 / Double(sampleRate))
        var low: Float = 0, under: Float = 0, upto: Float = 0
        var rms = [Float](repeating: 0, count: frameCount)
        var lowRMS = [Float](repeating: 0, count: frameCount)
        var voiceRMS = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var sum: Float = 0, lowSum: Float = 0, voiceSum: Float = 0
            let start = frame * hop
            for i in start..<(start + hop) {
                sum += samples[i] * samples[i]
                low += lowPass * (samples[i] - low)
                lowSum += low * low
                under += voiceLow * (samples[i] - under)
                upto += voiceHigh * (samples[i] - upto)
                let voice = upto - under
                voiceSum += voice * voice
            }
            rms[frame] = (sum / Float(hop)).squareRoot()
            lowRMS[frame] = (lowSum / Float(hop)).squareRoot()
            voiceRMS[frame] = (voiceSum / Float(hop)).squareRoot()
        }

        // "Quiet" = 26 dB below the loudest frame.
        let threshold = (rms.max() ?? 0) * 0.05
        guard threshold > 0,
              let first = rms.firstIndex(where: { $0 > threshold }),
              let last = rms.lastIndex(where: { $0 > threshold }) else { return nil }

        let onset = onsets(rms)
        var result = Result(
            soundStart: Double(first) * frameSeconds,
            soundEnd: Double(last + 1) * frameSeconds,
            bpm: nil,
            firstBeat: 0,
            downbeat: 0
        )
        // The kick (the low band) marks the beat more cleanly in some songs,
        // the full mix in others: keep the tempo whose peak stands out more.
        let lowOnset = onsets(lowRMS)
        guard let grid = [beatGrid(onset: onset, frameSeconds: frameSeconds),
                          beatGrid(onset: lowOnset, frameSeconds: frameSeconds)]
            .compactMap({ $0 }).max(by: { $0.prominence < $1.prominence }) else { return result }
        result.bpm = 60 / (grid.period * frameSeconds)
        result.firstBeat = grid.phase * frameSeconds

        // Downbeat: the beat of the bar where the bass hits hardest.
        var accents = [Float](repeating: 0, count: beatsPerBar)
        var position = grid.phase
        var beat = 0
        while Int(position) < lowOnset.count {
            accents[beat % beatsPerBar] += lowOnset[Int(position)]
            position += grid.period
            beat += 1
        }
        let strongest = accents.indices.max { accents[$0] < accents[$1] } ?? 0
        result.downbeat = (grid.phase + Double(strongest) * grid.period) * frameSeconds

        // Per bar: loudness and vocal presence, on the bar grid.
        let barFrames = grid.period * Double(beatsPerBar)
        var barStart = grid.phase + Double(strongest) * grid.period
        var energy: [Float] = []
        while Int(barStart + barFrames) <= frameCount {
            let frames = Int(barStart)..<Int(barStart + barFrames)
            let mean = frames.reduce(Float(0)) { $0 + rms[$1] * rms[$1] } / Float(frames.count)
            energy.append(mean.squareRoot())
            result.barVocal.append(vocalPresence(voice: Array(voiceRMS[frames]), total: Array(rms[frames])))
            barStart += barFrames
        }
        let loudest = energy.max() ?? 0
        result.barEnergy = loudest > 0 ? energy.map { $0 / loudest } : energy
        result.key = key(from: chroma(samples, sampleRate: sampleRate))
        return result
    }

    // MARK: Phrases

    /// Bars that start a new phrase: where the next 4 bars are clearly
    /// louder or quieter than the 4 before (a drop, a break, a chorus).
    static func phraseBoundaries(_ energy: [Float]) -> [Int] {
        let span = 4
        guard energy.count >= 2 * span else { return [] }
        var boundaries: [Int] = []
        for bar in span...(energy.count - span) {
            let before = energy[(bar - span)..<bar].reduce(0, +) / Float(span)
            let after = energy[bar..<(bar + span)].reduce(0, +) / Float(span)
            guard before > 0, after > 0 else { continue }
            let change = after / before
            guard change > 1.4 || change < 0.7 else { continue }
            // One boundary per change: keep the bar with the sharpest step.
            if let last = boundaries.last, bar - last < span {
                let lastBefore = energy[(last - span)..<last].reduce(0, +) / Float(span)
                let lastAfter = energy[last..<(last + span)].reduce(0, +) / Float(span)
                if abs(log(change)) <= abs(log(lastAfter / lastBefore)) { continue }
                boundaries.removeLast()
            }
            boundaries.append(bar)
        }
        return boundaries
    }

    /// The bar where the song's energy falls and stays low: the start of
    /// its outro. Nil when the song keeps going until it stops.
    static func outroBar(_ energy: [Float]) -> Int? {
        for bar in phraseBoundaries(energy).reversed() {
            let before = energy[(bar - 4)..<bar].reduce(0, +) / 4
            guard energy[bar] < before, energy[bar...].allSatisfy({ $0 < before * 0.85 }) else { continue }
            return bar
        }
        return nil
    }

    /// The first bar where the song's energy rises sharply: its first
    /// strong phrase, after the intro. Nil when it starts at full energy.
    static func firstRiseBar(_ energy: [Float]) -> Int? {
        phraseBoundaries(energy).first { bar in
            energy[bar] > energy[(bar - 4)..<bar].reduce(0, +) / 4
        }
    }

    // MARK: Vocals

    /// How much a bar sounds like singing (0...1): the share of its loudness
    /// in the voice band, scaled down when that share barely moves. Sung
    /// lines come and go within a bar; pads and drones hold still.
    // ponytail: snares and hi-hats live in the same band and fluctuate too,
    // so loud drum breaks count as vocals; a learned model would tell them apart.
    static func vocalPresence(voice: [Float], total: [Float]) -> Float {
        let count = Float(voice.count)
        guard count > 0 else { return 0 }
        let energy = total.reduce(0) { $0 + $1 * $1 }
        guard energy > 0 else { return 0 }
        let share = voice.reduce(0) { $0 + $1 * $1 } / energy
        let mean = voice.reduce(0, +) / count
        guard mean > 0 else { return 0 }
        let variance = voice.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / count
        let movement = variance.squareRoot() / mean
        return min(1, share * min(1, movement / 0.25))
    }

    // MARK: Key

    /// Krumhansl-Schmuckler key profiles: how much each scale degree is
    /// heard in major and minor music, from the tonic up.
    private static let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.6, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// How much each of the 12 notes sounds over the whole signal, from C3
    /// to B5. One Goertzel filter per note and second: an FFT's cost without
    /// an FFT library.
    static func chroma(_ samples: [Float], sampleRate: Int) -> [Float] {
        var chroma = [Float](repeating: 0, count: 12)
        let block = sampleRate
        guard samples.count >= block else { return chroma }
        for tone in 0..<36 {
            let frequency = 130.8128 * pow(2, Double(tone) / 12)
            let coefficient = Float(2 * cos(2 * Double.pi * frequency / Double(sampleRate)))
            var start = 0
            while start + block <= samples.count {
                var s1: Float = 0, s2: Float = 0
                for i in start..<(start + block) {
                    let s = samples[i] + coefficient * s1 - s2
                    s2 = s1
                    s1 = s
                }
                let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
                chroma[tone % 12] += max(0, power).squareRoot()
                start += block
            }
        }
        return chroma
    }

    /// The key whose profile best matches the chroma (Pearson correlation
    /// over the 24 keys). Nil for silence.
    static func key(from chroma: [Float]) -> Key? {
        guard chroma.count == 12, chroma.contains(where: { $0 > 0 }) else { return nil }
        var best: (score: Float, key: Key)?
        for (isMinor, profile) in [(false, majorProfile), (true, minorProfile)] {
            for tonic in 0..<12 {
                let rotated = (0..<12).map { profile[($0 - tonic + 12) % 12] }
                let score = correlation(chroma, rotated)
                if best.map({ score > $0.score }) ?? true {
                    best = (score, Key(pitchClass: tonic, isMinor: isMinor))
                }
            }
        }
        return best?.key
    }

    private static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let count = Float(a.count)
        let meanA = a.reduce(0, +) / count, meanB = b.reduce(0, +) / count
        var cross: Float = 0, varA: Float = 0, varB: Float = 0
        for i in a.indices {
            cross += (a[i] - meanA) * (b[i] - meanB)
            varA += (a[i] - meanA) * (a[i] - meanA)
            varB += (b[i] - meanB) * (b[i] - meanB)
        }
        let denom = (varA * varB).squareRoot()
        return denom > 0 ? cross / denom : 0
    }

    /// Onset strength: how much louder each frame is than the one before.
    /// Drum hits make sharp jumps; the beat is the rhythm of those jumps.
    private static func onsets(_ levels: [Float]) -> [Float] {
        var onset = [Float](repeating: 0, count: levels.count)
        for frame in 1..<levels.count {
            onset[frame] = max(0, log(levels[frame] + 1e-6) - log(levels[frame - 1] + 1e-6))
        }
        return onset
    }

    /// Beat period and offset in frames, and how far the tempo peak stands
    /// above the average lag. Nil when there is no steady beat.
    private static func beatGrid(onset: [Float], frameSeconds: Double) -> (period: Double, phase: Double, prominence: Float)? {
        let minBPM = 70.0, maxBPM = 180.0
        let minLag = max(1, Int((60 / maxBPM / frameSeconds).rounded(.down)))
        let maxLag = Int((60 / minBPM / frameSeconds).rounded(.up))
        // Without clear hits (a 10% jump in loudness) there is no beat to find.
        guard onset.count > maxLag * 4, (onset.max() ?? 0) > 0.1 else { return nil }

        // Autocorrelation: the lag where the onset curve best matches a
        // shifted copy of itself is the beat period.
        var scores: [Float] = []
        for lag in minLag...maxLag {
            var sum: Float = 0
            for i in lag..<onset.count { sum += onset[i] * onset[i - lag] }
            scores.append(sum / Float(onset.count - lag))
        }
        guard let peak = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return nil }
        let mean = scores.reduce(0, +) / Float(scores.count)
        // A flat curve means no steady beat (ambient, speech).
        guard mean > 0, scores[peak] > mean * 1.3 else { return nil }
        let prominence = scores[peak] / mean

        // Refine the lag between frames with a parabola through the peak.
        var lag = Double(peak + minLag)
        if peak > 0, peak < scores.count - 1 {
            let a = Double(scores[peak - 1]), b = Double(scores[peak]), c = Double(scores[peak + 1])
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
        return (grid.period, grid.phase, prominence)
    }
}
