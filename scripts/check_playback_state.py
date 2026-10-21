"""Check metadata and load-state publication using the production Swift statements."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Trop/Audio/NowPlaying.swift").read_text()
update = source[source.index("    func update(title:"):source.index("    /// Convenience pushing")]
controller = (root / "Trop/Audio/PlayerController/PlayerController.swift").read_text()
play = controller[controller.index("    func play("):controller.index("    func seek(")]
publication = next(line.strip() for line in play.splitlines() if "NowPlaying.shared.isPlaying =" in line)
harness = r'''import Foundation
struct YTArtist {}
enum CanvasPrefetch {
    static func request(videoId: String, title: String, artist: String, album: String?) {}
}
func cleanArtist(_ value: String) -> String { value }
final class NowPlaying {
    static let shared = NowPlaying()
    var isPlaying = false
    var title = ""
    var artists: [YTArtist] = []
    var artist = ""
    var albumTitle = ""
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var videoId: String?
    var hasVideo = false
    var isVideoMode = false
    var isVideoReady = false
    func startTimer() {}
    func loadThumbnail(videoId: String, thumbnailUrl: String?) {}
    func preloadNextTrack() {}
'''
checks = r'''
}
enum State: Equatable { case playing, paused, stopped }
struct Subject { var value = State.paused }
final class Controller {
    var playState = Subject()
    func publishLoadState() {
        PUBLICATION
    }
}
let player = Controller()
let np = NowPlaying.shared
for state in [State.paused, .playing, .stopped] {
    player.playState.value = state
    np.isPlaying = state == .playing
    let before = np.isPlaying
    np.update(title: "Next song", artist: "Artist", videoId: "next")
    assert(np.isPlaying == before, "Metadata must not change playback state")
    player.publishLoadState()
    assert(np.isPlaying == (state != .paused), "A paused track change must remain paused")
}
player.playState.value = .paused
player.publishLoadState()
assert(!np.isPlaying, "A pause during loading must remain visible")
print("PASS: metadata preserves playback state; track loads preserve pause and play intent")
'''
swift = shutil.which("swift")
if not swift:
    raise SystemExit("Swift is required to run the playback-state checks")
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "main.swift"
    path.write_text(harness + update + checks.replace("PUBLICATION", publication))
    subprocess.run([swift, str(path)], cwd=directory, check=True)
