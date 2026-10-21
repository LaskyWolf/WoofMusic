"""Execute the production transition geometry with Swift, without the app runtime."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
swift = shutil.which("swift")
if not swift:
    raise SystemExit("Swift is required to run the player transition checks")
source = (root / "Trop/Audio/PlayerTransitionGeometry.swift").read_text()
checks = r''' 
for size in [CGSize(width: 393, height: 852), CGSize(width: 320, height: 568),
             CGSize(width: 430, height: 932), CGSize(width: 852, height: 393),
             CGSize(width: 1024, height: 1366)] {
    let expanded = CGRect(origin: .zero, size: size)
    let collapsed = CGRect(x: 16, y: size.height - 140, width: size.width - 32, height: 48)
    let geometry = PlayerTransitionGeometry(expanded: expanded, collapsed: collapsed)
    assert(geometry.frame(expansion: 0, dragOffset: 0) == collapsed)
    assert(geometry.frame(expansion: 1, dragOffset: 0) == expanded)
    let dragged = geometry.frame(expansion: 1, dragOffset: 80)
    assert(dragged.origin == CGPoint(x: 0, y: 80) && dragged.size == size)
    assert(geometry.cornerRadius(expansion: 1, dragOffset: 0) == 0)
    assert(geometry.cornerRadius(expansion: 0, dragOffset: 0) == collapsed.height / 2)
    for step in -10...110 {
        let progress = CGFloat(step) / 100
        let frame = geometry.frame(expansion: progress, dragOffset: 0)
        assert(frame.width >= collapsed.width && frame.width <= expanded.width)
        assert(frame.height >= collapsed.height && frame.height <= expanded.height)
        assert(geometry.cornerRadius(expansion: progress, dragOffset: 0) <= frame.height / 2)
    }
    let rebound = geometry.frame(expansion: -0.02, dragOffset: 0)
    assert(rebound.size == collapsed.size && rebound.minY > collapsed.minY)
}
assert(!PlayerTransitionGeometry.shouldDismiss(distance: 20, predictedDistance: 30, height: 852))
assert(PlayerTransitionGeometry.shouldDismiss(distance: 180, predictedDistance: 180, height: 852))
assert(PlayerTransitionGeometry.shouldDismiss(distance: 30, predictedDistance: 400, height: 852))
assert(!PlayerTransitionGeometry.shouldDismiss(distance: -30, predictedDistance: -400, height: 852))
assert(!PlayerTransitionGeometry.shouldDismiss(distance: 0, predictedDistance: 400, height: 852))
assert(!PlayerTransitionGeometry.shouldDismiss(distance: 100, predictedDistance: 400, height: 0))
for height in [568.0, 852.0, 1366.0] {
    let capsule = 48.0
    let handoff = capsule / (height - capsule)
    assert(PlayerTransitionGeometry.presentationOpacity(expansion: 0, expandedHeight: height, collapsedHeight: capsule) == 0)
    assert(PlayerTransitionGeometry.presentationOpacity(expansion: -0.02, expandedHeight: height, collapsedHeight: capsule) == 0)
    assert(PlayerTransitionGeometry.presentationOpacity(expansion: 1, expandedHeight: height, collapsedHeight: capsule) == 1)
    assert(abs(PlayerTransitionGeometry.presentationOpacity(expansion: handoff / 2, expandedHeight: height, collapsedHeight: capsule) - 0.5) < 0.000001)
    var previous = 0.0
    for step in 0...100 {
        let opacity = PlayerTransitionGeometry.presentationOpacity(expansion: handoff * Double(step) / 100, expandedHeight: height, collapsedHeight: capsule)
        assert(opacity >= previous && opacity <= 1)
        assert(abs(opacity - previous) < 0.016)
        previous = opacity
    }
}
assert(PlayerTransitionGeometry.presentationOpacity(expansion: 1, expandedHeight: 0, collapsedHeight: 0) == 0)
print("PASS: geometry, drag thresholds and continuous glass handoff with invisible overlay at rest")
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "main.swift"
    path.write_text(source + checks)
    subprocess.run([swift, str(path)], check=True)
