"""Check TrackAnalyzer on synthetic click tracks with known tempo and silence.

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

source = (root / "Trop/Audio/TrackAnalyzer.swift").read_text()
checks = r'''
let sr = TrackAnalyzer.sampleRate

/// `lead` s of silence, clicks at `bpm` for `length` s, then `tail` s of silence.
func clickTrack(bpm: Double, lead: Double, length: Double, tail: Double) -> [Float] {
    var samples = [Float](repeating: 0, count: Int((lead + length + tail) * Double(sr)))
    var beat = lead
    var seed: UInt32 = 1
    while beat < lead + length - 0.1 {
        let start = Int(beat * Double(sr))
        for i in 0..<Int(0.05 * Double(sr)) {
            seed = seed &* 1_103_515_245 &+ 12_345
            let noise = Float(Int32(bitPattern: seed >> 1) % 1000) / 1000
            samples[start + i] = noise * exp(-Float(i) / 150)
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
}

let tone = (0..<(10 * sr)).map { Float(sin(Double($0) * 0.2)) * 0.5 }
precondition(TrackAnalyzer.analyze(tone)?.bpm == nil, "steady tone has no beat")
precondition(TrackAnalyzer.analyze([Float](repeating: 0, count: sr)) == nil, "silence has no result")
print("PASS: tempo, beat phase and silence edges on synthetic tracks")
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "main.swift"
    path.write_text(source + "\n" + checks)
    subprocess.run([swift, str(path)], cwd=directory, check=True)
