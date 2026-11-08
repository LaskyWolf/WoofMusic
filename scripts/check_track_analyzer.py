"""Check TrackAnalyzer and MixPlanner on synthetic tracks with known tempo,
downbeats and silence, phrases, vocals and keys, and the AutoMix style choice.

Usage: python3 scripts/check_track_analyzer.py (needs a Swift toolchain)
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
swift = shutil.which("swift")
if not swift:
    raise SystemExit("Swift is required to run the track analyzer checks")

source = "\n".join((root / "Trop/Audio" / name).read_text() for name in ["TrackAnalyzer.swift", "MixPlanner.swift"])
checks = r'''
let sr = TrackAnalyzer.sampleRate

/// `lead` s of silence, clicks at `bpm` for `length` s, then `tail` s of
/// silence. Every 4th click, starting with the first, is twice as loud.
func clickTrack(bpm: Double, lead: Double, length: Double, tail: Double) -> [Float] {
    var samples = [Float](repeating: 0, count: Int((lead + length + tail) * Double(sr)))
    var beat = lead
    var seed: UInt32 = 1
    var count = 0
    while beat < lead + length - 0.1 {
        let accent: Float = count % 4 == 0 ? 1 : 0.5
        count += 1
        let start = Int(beat * Double(sr))
        for i in 0..<Int(0.05 * Double(sr)) {
            seed = seed &* 1_103_515_245 &+ 12_345
            let noise = Float(Int32(bitPattern: seed >> 1) % 1000) / 1000
            samples[start + i] = accent * noise * exp(-Float(i) / 150)
        }
        beat += 60 / bpm
    }
    // A quiet pad under the clicks, like the rest of a real mix.
    for i in Int(lead * Double(sr))..<Int((lead + length) * Double(sr)) {
        samples[i] += 0.05 * sin(Float(i) * 0.3)
    }
    return samples
}

for bpm in [120.0, 128.0, 96.0] {
    guard let result = TrackAnalyzer.analyze(clickTrack(bpm: bpm, lead: 2, length: 20, tail: 3)) else {
        fatalError("\(bpm) BPM: no result")
    }
    precondition(abs(result.soundStart - 2) < 0.1, "\(bpm): soundStart \(result.soundStart)")
    precondition(abs(result.soundEnd - 22) < 0.2, "\(bpm): soundEnd \(result.soundEnd)")
    guard let found = result.bpm else { fatalError("\(bpm): no tempo") }
    precondition(abs(found - bpm) < 2, "\(bpm): found \(found)")
    let period = 60 / bpm
    let offset = (result.firstBeat - 2).truncatingRemainder(dividingBy: period)
    let phaseError = min(abs(offset), abs(period - abs(offset)))
    precondition(phaseError < 0.05, "\(bpm): beat phase off by \(phaseError)")
    let bar = 4 * period
    let barOffset = (result.downbeat - 2).truncatingRemainder(dividingBy: bar)
    let downbeatError = min(abs(barOffset), abs(bar - abs(barOffset)))
    precondition(downbeatError < 0.05, "\(bpm): downbeat off by \(downbeatError)")
}

let tone = (0..<(10 * sr)).map { Float(sin(Double($0) * 0.2)) * 0.5 }
precondition(TrackAnalyzer.analyze(tone)?.bpm == nil, "steady tone has no beat")
precondition(TrackAnalyzer.analyze([Float](repeating: 0, count: sr)) == nil, "silence has no result")
// MixPlanner: a 200 s song at 128 BPM whose last 60 s are analysed, going
// quiet at 196 s; the next song at 124 BPM starts after 1.5 s of silence.
let period = 60.0 / 128
let tail = TrackAnalyzer.Result(soundStart: 0, soundEnd: 56, bpm: 128, firstBeat: 0.2, downbeat: 0.2 + period)
let head = TrackAnalyzer.Result(soundStart: 1.5, soundEnd: 45, bpm: 124, firstBeat: 0.1, downbeat: 0.1)
guard let mix = MixPlanner.autoMix(duration: 200, tail: tail, tailStart: 140, head: head) else {
    fatalError("AutoMix: no mix for compatible songs")
}
precondition(mix.beats == 32, "AutoMix: \(String(describing: mix.beats)) beats")
precondition(mix.fadeStart + mix.fadeLength <= 196 + 1e-9, "AutoMix ends after the song goes quiet")
let barsFromDownbeat = (mix.fadeStart - (140 + tail.downbeat)) / (4 * period)
precondition(abs(barsFromDownbeat - barsFromDownbeat.rounded()) < 1e-9, "AutoMix starts off a downbeat")
precondition(196 - (mix.fadeStart + mix.fadeLength) < 4 * period, "AutoMix starts more than a bar early")
let inBar = 4 * 60.0 / 124
precondition(abs(mix.inStart - (0.1 + inBar)) < 1e-9, "AutoMix: incoming starts at \(mix.inStart)")
precondition(abs(mix.speed - 128.0 / 124) < 1e-9, "AutoMix: speed \(mix.speed)")

var far = head
far.bpm = 100
precondition(MixPlanner.autoMix(duration: 200, tail: tail, tailStart: 140, head: far) == nil, "AutoMix across 28% tempo gap")
var beatless = head
beatless.bpm = nil
precondition(MixPlanner.autoMix(duration: 200, tail: tail, tailStart: 140, head: beatless) == nil, "AutoMix without a beat")

let fade = MixPlanner.smart(duration: 200, fadeLength: 8, tail: tail, tailStart: 140, head: far)
precondition(fade.fadeStart + 8 <= 196 && fade.fadeStart > 196 - 8 - period, "Smart fade at \(fade.fadeStart)")
precondition(fade.speed == 1, "Smart fade nudged a 28% tempo gap")
let plain = MixPlanner.smart(duration: 200, fadeLength: 8, tail: nil, tailStart: 140, head: nil)
precondition(plain == MixPlanner.Mix(fadeStart: 192, fadeLength: 8, inStart: 0, speed: 1), "Plain fade \(plain)")
// AutoMix styles: the 32-beat mix above, 3% tempo change.
let flat = MixPlanner.Cues()
precondition(MixPlanner.style(for: plain, echoPeriod: nil, room: 10, cues: flat, variety: 0) == .blend, "Style for a timed fade")
let styles = Set((0..<12).map { MixPlanner.style(for: mix, echoPeriod: period, room: 10, cues: flat, variety: $0) })
precondition(styles == [.sweep, .loop, .echo, .wash], "Styles rotated: \(styles)")
let noEcho = Set((0..<12).map { MixPlanner.style(for: mix, echoPeriod: period * 1.05, room: 10, cues: flat, variety: $0) })
precondition(!noEcho.contains(.echo), "Echo built for another tempo")
let noRoom = Set((0..<12).map { MixPlanner.style(for: mix, echoPeriod: period, room: 0.5, cues: flat, variety: $0) })
precondition(noRoom == [.sweep, .loop], "Tails without room after the mix: \(noRoom)")
var stretched = mix
stretched.speed = 1.06
precondition(MixPlanner.style(for: stretched, echoPeriod: nil, room: 10, cues: flat, variety: 0) == .wash, "Big tempo change without a wash")
// Style from the music: a falling outgoing song, a loud one meeting a rising one, a long outro, clashing keys.
var falling = flat
falling.outFalling = true
precondition(MixPlanner.style(for: mix, echoPeriod: period, room: 10, cues: falling, variety: 0) == .echo, "Falling energy: echo first")
precondition(MixPlanner.style(for: mix, echoPeriod: period, room: 10, cues: falling, variety: 1) == .wash, "Falling energy: wash second")
precondition(MixPlanner.style(for: mix, echoPeriod: nil, room: 0.5, cues: falling, variety: 0) == .sweep, "Falling energy without tails")
var peak = flat
peak.outHigh = true
peak.inRising = true
precondition(MixPlanner.style(for: mix, echoPeriod: period, room: 10, cues: peak, variety: 3) == .sweep, "High into rising: sweep")
var outro = flat
outro.longOutro = true
precondition(MixPlanner.style(for: mix, echoPeriod: period, room: 10, cues: outro, variety: 3) == .loop, "Long outro: loop")
var clash = mix
clash.keysCompatible = false
precondition(MixPlanner.style(for: clash, echoPeriod: period, room: 10, cues: peak, variety: 0) == .wash, "Key clash: wash hides it")
var short = mix
short.beats = 8
short.fadeLength = 8 * period
precondition(MixPlanner.loopBar(for: short) == nil, "Loop in a 2-bar mix")
guard let loop = MixPlanner.loopBar(for: mix) else { fatalError("No loop bar in a 32-beat mix") }
precondition(loop.repeats == 2, "Loop repeats \(loop.repeats)")
let mixEnd = mix.fadeStart + mix.fadeLength
precondition(abs(loop.bar.upperBound + 2 * 4 * period - mixEnd) < 1e-9, "Loop repeats don't end with the mix")
precondition(abs(loop.bar.upperBound - loop.bar.lowerBound - 4 * period) < 1e-9, "Loop isn't one bar")
precondition(MixPlanner.sweep(from: 300, to: 16_000, progress: 0) == 300, "Sweep start")
precondition(abs(MixPlanner.sweep(from: 300, to: 16_000, progress: 1) - 16_000) < 1e-6, "Sweep end")
precondition(abs(MixPlanner.sweep(from: 100, to: 10_000, progress: 0.5) - 1_000) < 1e-6, "Sweep isn't even in pitch")
precondition(MixPlanner.sweep(from: 100, to: 10_000, progress: 2) == MixPlanner.sweep(from: 100, to: 10_000, progress: 1), "Sweep overshoots")
// Keys: Krumhansl-Schmuckler on chroma vectors, the Camelot wheel, and a real chord.
let cMajorChroma: [Float] = [1, 0, 0.5, 0, 1, 0.5, 0, 1, 0, 0.5, 0, 0.5]
precondition(TrackAnalyzer.key(from: cMajorChroma) == TrackAnalyzer.Key(pitchClass: 0, isMinor: false), "C major chroma")
let aMinorChroma: [Float] = [0.8, 0, 0.4, 0, 0.8, 0.4, 0, 0.4, 0, 1, 0, 0.3]
precondition(TrackAnalyzer.key(from: aMinorChroma) == TrackAnalyzer.Key(pitchClass: 9, isMinor: true), "A minor chroma")
precondition(TrackAnalyzer.key(from: [Float](repeating: 0, count: 12)) == nil, "Silence has no key")
let cMajor = TrackAnalyzer.Key(pitchClass: 0, isMinor: false)
let aMinor = TrackAnalyzer.Key(pitchClass: 9, isMinor: true)
let gMajor = TrackAnalyzer.Key(pitchClass: 7, isMinor: false)
let eMinor = TrackAnalyzer.Key(pitchClass: 4, isMinor: true)
let fSharpMajor = TrackAnalyzer.Key(pitchClass: 6, isMinor: false)
precondition(cMajor.camelot == "8B" && aMinor.camelot == "8A" && gMajor.camelot == "9B" && eMinor.camelot == "9A", "Camelot positions")
precondition(TrackAnalyzer.Key(pitchClass: 11, isMinor: false).camelot == "1B", "B major wraps to 1B")
precondition(cMajor.isCompatible(with: aMinor) && cMajor.isCompatible(with: gMajor) && aMinor.isCompatible(with: eMinor), "Neighbours mix")
precondition(!cMajor.isCompatible(with: fSharpMajor) && !cMajor.isCompatible(with: eMinor), "Far keys clash")
let chord = (0..<(2 * sr)).map { i -> Float in
    let t = Double(i) / Double(sr)
    return Float(sin(2 * .pi * 261.63 * t) + sin(2 * .pi * 329.63 * t) + sin(2 * .pi * 392 * t)) / 3
}
let chordChroma = TrackAnalyzer.chroma(chord, sampleRate: sr)
precondition(Set(chordChroma.indices.sorted { chordChroma[$0] > chordChroma[$1] }.prefix(3)) == [0, 4, 7], "C-E-G chroma \(chordChroma)")
precondition(TrackAnalyzer.key(from: chordChroma) == cMajor, "C major chord")
// Phrases: boundaries where 4 bars step in energy; the outro falls and stays low.
let dropCurve = [Float](repeating: 1, count: 24) + [Float](repeating: 0.4, count: 8)
precondition(TrackAnalyzer.phraseBoundaries(dropCurve) == [24], "Drop at bar 24: \(TrackAnalyzer.phraseBoundaries(dropCurve))")
precondition(TrackAnalyzer.outroBar(dropCurve) == 24 && TrackAnalyzer.firstRiseBar(dropCurve) == nil, "Outro at 24")
let riseCurve = [Float](repeating: 0.3, count: 8) + [Float](repeating: 1, count: 16)
precondition(TrackAnalyzer.firstRiseBar(riseCurve) == 8 && TrackAnalyzer.outroBar(riseCurve) == nil, "Rise at 8")
precondition(TrackAnalyzer.phraseBoundaries([Float](repeating: 0.8, count: 32)).isEmpty, "Flat song has no phrases")
let breakdown = [Float](repeating: 1, count: 16) + [Float](repeating: 0.5, count: 8) + [Float](repeating: 1, count: 8)
precondition(TrackAnalyzer.phraseBoundaries(breakdown) == [16, 24] && TrackAnalyzer.outroBar(breakdown) == nil, "Break isn't an outro")
// Vocals: a held pad doesn't count, a line that comes and goes does.
let pad = [Float](repeating: 0.5, count: 80)
precondition(TrackAnalyzer.vocalPresence(voice: pad, total: pad) == 0, "Steady pad isn't a vocal")
let line = (0..<80).map { Float($0 % 8 < 4 ? 0.5 : 0.05) }
precondition(TrackAnalyzer.vocalPresence(voice: line, total: line) >= TrackAnalyzer.vocalThreshold, "Moving line is a vocal")
precondition(TrackAnalyzer.vocalPresence(voice: line.map { $0 * 0.1 }, total: line) < TrackAnalyzer.vocalThreshold, "Quiet band isn't a vocal")
precondition(TrackAnalyzer.vocalPresence(voice: [], total: []) == 0, "Empty bar")
// Phrase-aware AutoMix: the mix starts at the outro, the incoming rise lands on its end.
let bar = 4 * period
var phrased = tail
phrased.barEnergy = [Float](repeating: 1, count: 16) + [Float](repeating: 0.5, count: 12)
var rising = head
rising.barEnergy = [Float](repeating: 0.3, count: 8) + [Float](repeating: 1, count: 12)
let outroTime = 140 + tail.barTime(16)
guard let phraseMix = MixPlanner.autoMix(duration: 200, tail: phrased, tailStart: 140, head: rising) else { fatalError("No phrase mix") }
precondition(phraseMix.beats == 32 && abs(phraseMix.fadeStart - outroTime) < 1e-9, "Mix starts at the outro: \(phraseMix)")
// Landing the rise on the mix end would start inside the 1.5 s of silence, so it lands on the halfway bar.
let riseTime = head.barTime(8)
precondition(abs(phraseMix.inStart - (riseTime - phraseMix.fadeLength * phraseMix.speed / 2)) < 1e-9, "Rise lands halfway: \(phraseMix.inStart)")
var noSilence = rising
noSilence.soundStart = 0
guard let fullMix = MixPlanner.autoMix(duration: 200, tail: phrased, tailStart: 140, head: noSilence) else { fatalError("No full mix") }
precondition(abs(fullMix.inStart - (riseTime - fullMix.fadeLength * fullMix.speed)) < 1e-9, "Rise lands on the mix end: \(fullMix.inStart)")
precondition(phraseMix.duckUntil == nil && phraseMix.keysCompatible == nil, "No vocals or keys known")
let phraseCues = MixPlanner.cues(for: phraseMix, tail: phrased, tailStart: 140, head: rising)
precondition(phraseCues == MixPlanner.Cues(outFalling: true, outHigh: false, inRising: true, longOutro: true), "Cues \(phraseCues)")
// Vocals: the start steps back off a sung bar; singing on both sides shortens and ducks.
var sung = phrased
sung.barVocal = [Float](repeating: 0, count: 28)
sung.barVocal[16] = 1
guard let shifted = MixPlanner.autoMix(duration: 200, tail: sung, tailStart: 140, head: rising) else { fatalError("No shifted mix") }
precondition(abs(shifted.fadeStart - (outroTime - bar)) < 1e-9 && shifted.duckUntil == nil, "Start moved off the vocal: \(shifted)")
sung.barVocal = [Float](repeating: 1, count: 28)
var singing = rising
singing.barVocal = [Float](repeating: 1, count: 20)
guard let ducked = MixPlanner.autoMix(duration: 200, tail: sung, tailStart: 140, head: singing) else { fatalError("No ducked mix") }
precondition(ducked.beats == 8 && abs((ducked.duckUntil ?? 0) - 0.75) < 1e-9, "Vocals on both sides: \(ducked)")
// Keys: a clash drops the longest mix.
var keyed = phrased
keyed.key = cMajor
var farKey = rising
farKey.key = fSharpMajor
guard let clashMix = MixPlanner.autoMix(duration: 200, tail: keyed, tailStart: 140, head: farKey) else { fatalError("No key clash mix") }
precondition(clashMix.beats == 16 && clashMix.keysCompatible == false, "Key clash shortens: \(clashMix)")
farKey.key = gMajor
precondition(MixPlanner.autoMix(duration: 200, tail: keyed, tailStart: 140, head: farKey)?.keysCompatible == true, "Neighbour keys")
print("PASS: tempo, beats, downbeats, silence edges, phrases, vocals, keys, AutoMix and crossfade plans, AutoMix styles")
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "main.swift"
    path.write_text(source + "\n" + checks)
    subprocess.run([swift, str(path)], cwd=directory, check=True)
