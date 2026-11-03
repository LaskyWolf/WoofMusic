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

    var availableVersion: String? {
        if case .available(let version, _) = status { return version }
        return nil
    }

    var hasUpdate: Bool { availableVersion != nil }

    static let installedVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    static let installedBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
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

/// The App section of the profile: the installed version and what GitHub has.
struct AppUpdateSection: View {
    private let updater = AppUpdater.shared
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Section {
            LabeledContent("Version", value: "\(AppUpdater.installedVersion) (\(AppUpdater.installedBuild))")
            if case .available(let version, let page) = updater.status {
                Link(destination: page) {
                    Label("Woof Music \(version) Is Available", systemImage: "arrow.down.app")
                }
            } else {
                Button { Task { await updater.check(force: true) } } label: {
                    HStack {
                        Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                        Spacer(minLength: 8)
                        switch updater.status {
                        case .checking: ProgressView()
                        case .upToDate: statusText("Up to Date")
                        case .failed: statusText("GitHub can't be reached right now.")
                        case .idle, .available: EmptyView()
                        }
                    }
                }
                .disabled(updater.status == .checking)
            }
        } header: {
            Text("App")
        } footer: {
            Text("Compares this version with the newest release on GitHub.")
        }
        .tint(settings.accentColor)
        .task { await updater.check() }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
