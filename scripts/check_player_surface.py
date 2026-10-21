"""Exercise the production player host in an iOS Simulator with offline content."""
from pathlib import Path
import json
import platform
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
    static func report(_ phase: String) {
        let url = URL.documentsDirectory.appending(path: "surface-check.json")
        let data = try! JSONSerialization.data(withJSONObject: ["phase": phase, "mounts": mounts])
        try! data.write(to: url, options: .atomic)
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
                    SurfaceProbe.report(mode + "-before")
                    try? await Task.sleep(for: .seconds(2))
                    AppRouter.shared.playerExpandToken += 1
                    try? await Task.sleep(for: .seconds(3))
                    SurfaceProbe.report(mode + "-expanded")
                    try? await Task.sleep(for: .seconds(2))
                    AppRouter.shared.activeRoute = "close"
                    try? await Task.sleep(for: .seconds(3))
                    SurfaceProbe.report(mode + "-after")
                    try? await Task.sleep(for: .seconds(2))
                    AppRouter.shared.activeRoute = nil
                }
                SurfaceProbe.report("complete")
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
        # Instrument only the test copy; the production view must stay mounted.
        host = host.replace(".onAppear {\n                                if isExpanded", ".onAppear {\n                                SurfaceProbe.mounts += 1\n                                if isExpanded")
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
        run("xcrun", "simctl", "launch", device, identifier)
        data = Path(run("xcrun", "simctl", "get_app_container", device, identifier, "data"))
        result_path = data / "Documents/surface-check.json"
        seen = set()
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if result_path.exists():
                result = json.loads(result_path.read_text())
                phase = result["phase"]
                assert result["mounts"] == 1, result
                if phase == "complete":
                    assert len(seen) == 6, seen
                    (output / "result.json").write_text(json.dumps(result))
                    print("PASS: one player surface across two open/close cycles in light and dark mode")
                    break
                if phase not in seen:
                    run("xcrun", "simctl", "io", device, "screenshot", output / (phase + ".png"))
                    seen.add(phase)
            time.sleep(0.25)
        else:
            raise SystemExit("Player surface simulator check timed out")
finally:
    run("xcrun", "simctl", "shutdown", device)
    run("xcrun", "simctl", "delete", device)
