"""Run the production queue insertion and persistence methods without iOS UI."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
swift = shutil.which("swift")
if not swift:
    raise SystemExit("Swift is required to run the Play Next checks")
source = (root / "Trop/Audio/NowPlaying.swift").read_text()
methods = source[source.index("    private func restoreQueueIfNeeded()"):source.index("    /// Ensures `queueIndex`")]
keys = source[source.index("    private static let queueKey"):source.index("    private init()")]
harness = r'''import Foundation
struct SongItem: Codable, Equatable {
    let videoId: String
    init(_ id: String) { videoId = id }
}
final class SettingsStore {
    static let shared = SettingsStore()
    var persistQueue = true
}
final class QueueCheck {
    var queueSongs: [SongItem] = [] {
        didSet { queueNeedsSave = true }
    }
    private var queueNeedsSave = true
    var queueIndex = 0
    var playNextEnd: Int?
    var originalQueue: [SongItem]?
    var isShuffleOn = false
    var isRepeatOn = false
    init() { restoreQueueIfNeeded() }
'''
checks = r'''
}
let defaults = UserDefaults.standard
let q = QueueCheck()
func expect(_ ids: [String]) { assert(q.queueSongs.map(\.videoId) == ids) }
q.setQueue([SongItem("past"), SongItem("current"), SongItem("regular")], startIndex: 1)
q.enqueueNext(SongItem("first"))
q.enqueueNext(SongItem("second"))
q.enqueueNext(SongItem("third"))
expect(["past", "current", "first", "second", "third", "regular"])
q.queueIndex += 1
q.enqueueNext(SongItem("fourth"))
expect(["past", "current", "first", "second", "third", "fourth", "regular"])
q.removeQueueSong(at: 3)
q.enqueueNext(SongItem("fifth"))
expect(["past", "current", "first", "third", "fourth", "fifth", "regular"])
q.removeQueueSong(at: 0)
q.queueIndex -= 1
q.enqueueNext(SongItem("sixth"))
expect(["current", "first", "third", "fourth", "fifth", "sixth", "regular"])
let restored = QueueCheck()
restored.enqueueNext(SongItem("seventh"))
assert(restored.queueSongs.map(\.videoId) == ["current", "first", "third", "fourth", "fifth", "sixth", "seventh", "regular"])
q.replaceWithRadio([SongItem("first"), SongItem("radio")], currentIndex: 0)
q.enqueueNext(SongItem("last"))
expect(["first", "third", "fourth", "fifth", "sixth", "last", "radio"])
q.setQueue([SongItem("new"), SongItem("normal")], startIndex: 0)
q.enqueueNext(SongItem("new"))
q.enqueueNext(SongItem("new"))
expect(["new", "new", "new", "normal"])
assert(q.queueIndex == 0)
q.queueIndex = 2
q.enqueueNext(SongItem("after-consumed"))
expect(["new", "new", "new", "after-consumed", "normal"])
q.setQueue([SongItem("a"), SongItem("b"), SongItem("c"), SongItem("d")], startIndex: 3)
q.enqueueNext(SongItem("x"))
q.moveQueueIndex(to: 0)
q.enqueueNext(SongItem("y"))
expect(["a", "y", "b", "c", "d", "x"])
q.moveQueueIndex(to: 1)
q.enqueueNext(SongItem("z"))
expect(["a", "y", "z", "b", "c", "d", "x"])
q.setQueue([], startIndex: 0)
assert(QueueCheck().queueSongs.isEmpty)
q.enqueueNext(SongItem("empty-first"))
q.enqueueNext(SongItem("empty-second"))
expect(["empty-first", "empty-second"])
print("PASS: FIFO, advancement, removal, persistence, radio completion, jumps, reset, duplicates and empty queue")
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "main.swift"
    path.write_text(harness + keys + methods + checks)
    subprocess.run([swift, str(path)], cwd=directory, check=True)
