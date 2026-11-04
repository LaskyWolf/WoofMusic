"""Check TrackAnalyzer and MixPlanner on synthetic tracks with known tempo,
downbeats and silence, and the AutoMix style choice.

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
precondition(MixPlanner.style(for: plain, echoPeriod: nil, room: 10, variety: 0) == .blend, "Style for a timed fade")
let styles = Set((0..<12).map { MixPlanner.style(for: mix, echoPeriod: period, room: 10, variety: $0) })
precondition(styles == [.sweep, .loop, .echo, .wash], "Styles rotated: \(styles)")
let noEcho = Set((0..<12).map { MixPlanner.style(for: mix, echoPeriod: period * 1.05, room: 10, variety: $0) })
precondition(!noEcho.contains(.echo), "Echo built for another tempo")
let noRoom = Set((0..<12).map { MixPlanner.style(for: mix, echoPeriod: period, room: 0.5, variety: $0) })
precondition(noRoom == [.sweep, .loop], "Tails without room after the mix: \(noRoom)")
var stretched = mix
stretched.speed = 1.06
precondition(MixPlanner.style(for: stretched, echoPeriod: nil, room: 10, variety: 0) == .wash, "Big tempo change without a wash")
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
print("PASS: tempo, beats, downbeats, silence edges, AutoMix and crossfade plans, AutoMix styles")
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "main.swift"
    path.write_text(source + "\n" + checks)
    subprocess.run([swift, str(path)], cwd=directory, check=True)
