//
//  AppUpdater.swift
//  Trop
//

import SwiftUI

/// Compares the installed version with the latest Woof Music release on GitHub.
/// Releases carry no IPA, so an update only links to the release page.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, page: URL)
        case failed
    }

    private(set) var status: Status = .idle
    private var lastCheck: Date?

    var hasUpdate: Bool {
        if case .available = status { return true }
        return false
    }

    static let installedVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/LaskyWolf/WoofMusic/releases/latest")!
    /// Opening the app often does not ask GitHub every time.
    private static let recheckInterval: TimeInterval = 6 * 60 * 60

    private struct Release: Decodable {
        let tag_name: String
        let html_url: URL
    }

    /// `force` skips the interval: the user pressed Check Now.
    func check(force: Bool = false) async {
        guard status != .checking else { return }
        if !force, let lastCheck, Date().timeIntervalSince(lastCheck) < Self.recheckInterval { return }
        status = .checking
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data) else {
            status = .failed
            return
        }
        lastCheck = Date()
        let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        status = Self.isNewer(latest, than: Self.installedVersion)
            ? .available(version: latest, page: release.html_url)
            : .upToDate
    }

    /// "1.10" is newer than "1.9", and "1.5" equals "1.5.0".
    nonisolated static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let parts = { (version: String) in version.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(installed)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// The Updates row in Settings: the installed version and what GitHub has.
struct AppUpdateRow: View {
    private let updater = AppUpdater.shared
    @Environment(SettingsStore.self) private var settings
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if case .available(let version, let page) = updater.status {
                Button { openURL(page) } label: {
                    row(detail: "Version \(version) is out") {
                        Image(systemName: "arrow.up.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(settings.accentColor)
                    }
                }
                .accessibilityHint("Opens the release on GitHub")
            } else {
                Button { Task { await updater.check(force: true) } } label: {
                    row(detail: detail) {
                        if updater.status == .checking {
                            ProgressView()
                        } else {
                            Text("Check Now")
                                .font(.subheadline)
                                .foregroundStyle(settings.accentColor)
                        }
                    }
                }
                .disabled(updater.status == .checking)
            }
        }
        .tint(.primary)
        .task { await updater.check() }
    }

    private var detail: String {
        switch updater.status {
        case .idle, .checking: return "Checking GitHub…"
        case .upToDate: return "Up to date"
        case .failed: return "Couldn't reach GitHub"
        case .available: return ""
        }
    }

    private func row<Trailing: View>(detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Woof Music \(AppUpdater.installedVersion)")
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(updater.hasUpdate ? AnyShapeStyle(settings.accentColor) : AnyShapeStyle(.secondary))
                }
            } icon: {
                Image(systemName: updater.hasUpdate ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(settings.accentColor)
            }
            Spacer()
            trailing()
        }
        .contentShape(Rectangle())
    }
}
