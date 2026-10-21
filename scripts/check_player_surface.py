"""Exercise the production player host in an iOS Simulator with offline content."""
from pathlib import Path
import json
import platform
import signal
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[1]
output = root / "build/player-surface-check"
output.mkdir(parents=True, exist_ok=True)


def run(*args):
    return subprocess.check_output(list(map(str, args)), text=True).strip()


fixture = r'''import SwiftUI
import Combine
import Observation

@MainActor enum SurfaceProbe {
    static var mounts = 0
    static func report(_ phase: String) async {
        let url = URL.documentsDirectory.appending(path: "surface-check.json")
        let data = try! JSONSerialization.data(withJSONObject: ["phase": phase, "mounts": mounts])
        try! data.write(to: url, options: .atomic)
        guard phase != "complete" else { return }
        let acknowledgment = URL.documentsDirectory.appending(path: "surface-check-ack.txt")
        for _ in 0..<300 {
            if (try? String(contentsOf: acknowledgment, encoding: .utf8)) == phase { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        fatalError("Screenshot collection did not acknowledge " + phase)
    }
}
@Observable @MainActor final class SettingsStore {
    static let shared = SettingsStore()
    enum Background { case solid, gradient }
    var defaultTab = 0
    var playerBackgroundStyle = Background.gradient
}
@Observable @MainActor final class NowPlaying {
    static let shared = NowPlaying()
    var isBarPresented = true
    var dominantColors: [Color] = [.purple, .black]
    var accentColor: Color? = .purple
}
@MainActor final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    @Published var activeRoute: String?
    @Published var playerExpandToken = 0
    var selectedTabIndex = 0
    var activePathDepth = 0
    func popActiveRoute() {}
}
struct HomeScreenView: View {
    var body: some View {
        NavigationStack {
            List(0..<30) { index in
                HStack {
                    RoundedRectangle(cornerRadius: 8).fill(index.isMultiple(of: 2) ? .purple : .blue).frame(width: 48, height: 48)
                    Text("Offline song \(index + 1)")
                }
            }.navigationTitle("Music")
        }
    }
}
typealias LibraryView = HomeScreenView
typealias ExploreView = HomeScreenView
typealias SearchView = HomeScreenView
struct MiniPlayerBarView: View {
    var onExpand: () -> Void
    var isTransitioning: Bool
    var body: some View {
        HStack {
            Image(systemName: "music.note").frame(width: 30, height: 30).background(.blue, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading) {
                Text("Surface continuity").font(.subheadline.bold())
                Text("Offline simulator check").font(.caption)
            }
            Spacer()
            Button("Play", systemImage: "play.fill", action: {}).labelStyle(.iconOnly).frame(width: 44, height: 44)
        }.padding(.horizontal, 16).frame(height: 48).contentShape(Rectangle()).onTapGesture(perform: onExpand)
    }
}
struct FullPlayerView: View {
    let onCollapse: () -> Void
    let artworkTopInset: CGFloat
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat, CGFloat, CGFloat) -> Void
    let onDragCancelled: () -> Void
    var body: some View {
        VStack(spacing: 32) {
            Capsule().fill(.secondary).frame(width: 40, height: 5)
            Image(systemName: "music.note").resizable().scaledToFit().padding(70).background(.blue, in: RoundedRectangle(cornerRadius: 20))
            Text("Surface continuity").font(.title.bold())
            Text("Offline simulator check")
            Button("Close", action: onCollapse)
            Spacer()
        }.padding(24)
    }
}
@main struct SurfaceCheckApp: App {
    var body: some Scene { WindowGroup { CheckRoot() } }
}
struct CheckRoot: View {
    @State private var dark = false
    var body: some View {
        ContentView()
            .environment(SettingsStore.shared)
            .preferredColorScheme(dark ? .dark : .light)
            .task {
                for mode in ["light", "dark"] {
                    dark = mode == "dark"
                    try? await Task.sleep(for: .seconds(3))
                    await SurfaceProbe.report(mode + "-before")
                    try? await Task.sleep(for: .seconds(2))
                    AppRouter.shared.playerExpandToken += 1
                    try? await Task.sleep(for: .seconds(3))
                    await SurfaceProbe.report(mode + "-expanded")
                    try? await Task.sleep(for: .seconds(2))
                    AppRouter.shared.activeRoute = "close"
                    try? await Task.sleep(for: .seconds(3))
                    await SurfaceProbe.report(mode + "-after")
                    try? await Task.sleep(for: .seconds(2))
                    AppRouter.shared.activeRoute = nil
                }
                await SurfaceProbe.report("complete")
            }
    }
}
'''

runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
runtime = next(r["identifier"] for r in sorted(runtimes, key=lambda r: tuple(map(int, r["version"].split("."))), reverse=True)
               if r["isAvailable"] and "iOS" in r["name"] and tuple(map(int, r["version"].split("."))) >= (26, 2))
types = json.loads(run("xcrun", "simctl", "list", "devicetypes", "--json"))["devicetypes"]
device_type = next(d["identifier"] for d in types if d["name"] == "iPhone 17 Pro")
identifier = "com.laskywolf.Music.surfacecheck"
device = run("xcrun", "simctl", "create", "Player Surface Check", device_type, runtime)
recording = None
recording_log = None
app_process = None
app_log = None
try:
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        app = work / "SurfaceCheck.app"
        app.mkdir()
        import plistlib
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": identifier, "CFBundleExecutable": "SurfaceCheck",
            "CFBundleName": "SurfaceCheck", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
            "MinimumOSVersion": "26.2", "UILaunchScreen": {},
        }))
        host = (root / "Trop/ContentView.swift").read_text().split("#Preview")[0]
        # The native accessory must survive both expanded presentations.
        native = "MiniPlayerBarView(onExpand: expandPlayer, isTransitioning: isExpanded)"
        assert host.count(native) == 1
        host = host.replace(native, native + ".onAppear { SurfaceProbe.mounts += 1 }")
        (work / "ContentView.swift").write_text(host)
        (work / "Fixture.swift").write_text(fixture)
        sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
        sources = [work / "Fixture.swift", work / "ContentView.swift"] + [
            root / "Trop/Audio" / name for name in ["PlayerPresentation.swift", "PlayerTransitionGeometry.swift", "MiniPlayerScrollState.swift"]
        ]
        run("xcrun", "--sdk", "iphonesimulator", "swiftc", "-parse-as-library", "-sdk", sdk,
            "-target", f"{platform.machine()}-apple-ios26.2-simulator", *sources, "-o", app / "SurfaceCheck")
        run("xcrun", "simctl", "boot", device)
        run("xcrun", "simctl", "bootstatus", device, "-b")
        run("xcrun", "simctl", "install", device, app)
        app_log = (output / "app-console.log").open("w")
        app_process = subprocess.Popen([
            "xcrun", "simctl", "launch", "--console", device, identifier,
        ], stdout=app_log, stderr=subprocess.STDOUT)
        data = Path(run("xcrun", "simctl", "get_app_container", device, identifier, "data"))
        result_path = data / "Documents/surface-check.json"
        seen = set()
        baseline_mounts = {}
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            if result_path.exists():
                result = json.loads(result_path.read_text())
                (output / "last-state.json").write_text(json.dumps(result))
                phase = result["phase"]
                assert result["mounts"] >= 1, result
                mode = phase.split("-")[0]
                if phase.endswith("-before"):
                    baseline_mounts[mode] = result["mounts"]
                elif phase.endswith("-after"):
                    assert result["mounts"] == baseline_mounts[mode], result
                if phase == "complete":
                    assert len(seen) == 6, seen
                    (output / "result.json").write_text(json.dumps(result))
                    print("PASS: native accessory remains mounted across two open/close cycles in light and dark mode")
                    break
                if phase not in seen:
                    print("Simulator phase:", phase, flush=True)
                    run("xcrun", "simctl", "io", device, "screenshot", output / (phase + ".png"))
                    seen.add(phase)
                    if recording is None:
                        recording_log = (output / "recording.log").open("w")
                        recording = subprocess.Popen([
                            "xcrun", "simctl", "io", device, "recordVideo", "--codec=h264", "--force",
                            str(output / "transition.mp4"),
                        ], stdout=recording_log, stderr=subprocess.STDOUT)
                        time.sleep(1)
                    (data / "Documents/surface-check-ack.txt").write_text(phase)
            time.sleep(0.25)
        else:
            raise SystemExit("Player surface simulator check timed out")
finally:
    if recording is not None:
        recording.send_signal(signal.SIGINT)
        try:
            recording.wait(timeout=30)
        except subprocess.TimeoutExpired:
            recording.kill()
            recording.wait()
        recording_log.close()
    if app_process is not None:
        if app_process.poll() is None:
            app_process.terminate()
        app_process.wait(timeout=15)
        app_log.close()
    run("xcrun", "simctl", "shutdown", device)
    run("xcrun", "simctl", "delete", device)
