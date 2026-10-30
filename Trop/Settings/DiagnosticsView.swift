//
//  DiagnosticsView.swift
//  Trop
//

import SwiftUI

/// Hidden page, opened by long-pressing Settings › Integrations: build,
/// signing, widget storage, account and recent log errors, with a button that
/// copies everything for a bug report.
struct DiagnosticsView: View {
    @State private var sections: [DiagnosticsSection] = []
    @State private var accountCheck: String?
    @State private var isCheckingAccount = false
    @State private var copied = false
    @State private var problems: [String] = []

    var body: some View {
        List {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.rows, id: \.label) { row in
                        LabeledContent(row.label) {
                            Text(row.value)
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            Section("Actions") {
                Button("Reload Widgets", systemImage: "arrow.clockwise") {
                    WidgetSync.shared.syncAll()
                    Task {
                        // The widgets answer with their own ping once they have reloaded.
                        try? await Task.sleep(for: .seconds(2))
                        sections = DiagnosticsSection.all()
                    }
                }
                Button {
                    Task { await checkAccount() }
                } label: {
                    LabeledContent {
                        if isCheckingAccount { ProgressView() } else if let accountCheck { Text(accountCheck) }
                    } label: {
                        Label("Check Account", systemImage: "person.badge.shield.checkmark")
                    }
                }
                .disabled(isCheckingAccount)
                if let log = FileLog.shared.fileURL, FileManager.default.fileExists(atPath: log.path) {
                    ShareLink(item: log) {
                        Label("Share Log File", systemImage: "doc.text")
                    }
                }
                Button(copied ? "Copied" : "Copy Report", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = report
                    copied = true
                }
            }

            Section {
                if problems.isEmpty {
                    Text("No warnings or errors in the log.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(problems.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    Button("Clear Problems", systemImage: "trash", role: .destructive) {
                        DiagnosticsSection.clearProblems()
                        problems = []
                    }
                }
            } header: {
                Text("Recent Problems")
            } footer: {
                Text("The last warnings and errors from the log file, newest last. Clearing hides them here; the log file keeps them.")
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            sections = DiagnosticsSection.all()
            problems = DiagnosticsSection.recentProblems()
        }
    }

    private var report: String {
        var lines = sections.flatMap { section in
            ["## \(section.title)"] + section.rows.map { "\($0.label): \($0.value)" }
        }
        if let accountCheck { lines.append("Account check: \(accountCheck)") }
        lines.append("## Recent Problems")
        lines += problems
        return lines.joined(separator: "\n")
    }

    private func checkAccount() async {
        isCheckingAccount = true
        defer { isCheckingAccount = false }
        do {
            let info = try await InnerTubeClient.tropShared.accountInfo()
            accountCheck = info.name.isEmpty || info.name == "Guest" ? "Guest menu (session not recognised)" : "OK, \(info.name)"
        } catch {
            accountCheck = "Failed: \(error.localizedDescription)"
        }
    }
}

struct DiagnosticsSection: Identifiable {
    struct Row {
        let label: String
        let value: String
    }

    let title: String
    let rows: [Row]
    var id: String { title }

    @MainActor
    static func all() -> [DiagnosticsSection] {
        [app(), signing(), widgets(), account()]
    }

    // MARK: - Sections

    private static func app() -> DiagnosticsSection {
        let info = Bundle.main.infoDictionary
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return DiagnosticsSection(title: "App", rows: [
            Row(label: "Version", value: info?["CFBundleShortVersionString"] as? String ?? "?"),
            Row(label: "Build", value: info?["CFBundleVersion"] as? String ?? "?"),
            Row(label: "Bundle ID", value: Bundle.main.bundleIdentifier ?? "?"),
            Row(label: "Widgets Bundle ID", value: widgetBundleId ?? "Missing from the app"),
            Row(label: "iOS", value: UIDevice.current.systemVersion),
            Row(label: "Device", value: model),
            Row(label: "Language", value: Locale.current.identifier)
        ])
    }

    /// What the signing tool's provisioning profile allows, read from the app.
    private static func signing() -> DiagnosticsSection {
        guard let profile = ProvisioningProfile.contents else {
            return DiagnosticsSection(title: "Signing", rows: [Row(label: "Profile", value: "None (ad-hoc or unsigned)")])
        }
        let entitlements = ProvisioningProfile.entitlements
        func list(_ key: String) -> String {
            let values = entitlements[key] as? [String] ?? []
            return values.isEmpty ? "None" : values.joined(separator: ", ")
        }
        let devices = profile["ProvisionsAllDevices"] as? Bool == true
            ? "All devices"
            : "\((profile["ProvisionedDevices"] as? [String])?.count ?? 0) devices"
        return DiagnosticsSection(title: "Signing", rows: [
            Row(label: "Profile", value: profile["Name"] as? String ?? "?"),
            Row(label: "Team", value: "\(profile["TeamName"] as? String ?? "?") (\((profile["TeamIdentifier"] as? [String])?.first ?? "?"))"),
            Row(label: "Expires", value: (profile["ExpirationDate"] as? Date)?.formatted(date: .abbreviated, time: .omitted) ?? "?"),
            Row(label: "Devices", value: devices),
            Row(label: "App Groups", value: list("com.apple.security.application-groups")),
            Row(label: "Keychain Groups", value: list("keychain-access-groups"))
        ])
    }

    private static func widgets() -> DiagnosticsSection {
        let keychain = SharedKeychain.probe
        let keychainStatus = keychain.status == errSecSuccess
            ? "OK"
            : "\(keychain.status) \(SecCopyErrorMessageString(keychain.status, nil) as String? ?? "")"
        func ping(_ file: String) -> String {
            guard let ping = WidgetStore.read(WidgetPing.self, from: file) else { return "Never" }
            return "\(ping.date.formatted(.relative(presentation: .named))), build \(ping.build)"
        }
        func snapshot<Value: Decodable>(_ type: Value.Type, _ file: String) -> String {
            WidgetStore.read(type, from: file) == nil ? "Missing" : "Written"
        }
        return DiagnosticsSection(title: "Widgets", rows: [
            Row(label: "Storage", value: WidgetStore.backend.rawValue),
            Row(label: "App Group Container", value: WidgetStore.groupId ?? "Missing"),
            Row(label: "Keychain Team", value: SharedKeychain.teamId ?? "Unknown"),
            Row(label: "Keychain Group", value: keychainStatus),
            Row(label: "Pasteboard", value: pasteboardRoundTrip() ? "OK" : "Failed"),
            Row(label: "App Ping", value: ping(WidgetStore.appPingFile)),
            Row(label: "Widget Ping", value: ping(WidgetStore.widgetPingFile)),
            Row(label: "Now Playing", value: snapshot(NowPlayingState.self, WidgetStore.nowPlayingFile)),
            Row(label: "Quick Picks", value: snapshot(QuickPicksSnapshot.self, WidgetStore.quickPicksFile)),
            Row(label: "Woof Stats", value: snapshot(StatsSnapshot.self, WidgetStore.statsFile))
        ])
    }

    @MainActor
    private static func account() -> DiagnosticsSection {
        let account = AccountState.shared
        return DiagnosticsSection(title: "Account", rows: [
            Row(label: "Signed In", value: account.isLoggedIn ? "Yes" : "No"),
            Row(label: "Name", value: account.isLoggedIn ? account.accountName : "–"),
            Row(label: "Play History", value: SettingsStore.shared.trackPlayHistory ? "Tracked" : "Off")
        ])
    }

    // MARK: - Helpers

    private static var widgetBundleId: String? {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return nil }
        return Bundle(url: plugins.appendingPathComponent("WoofWidgets.appex"))?.bundleIdentifier
    }

    private static func pasteboardRoundTrip() -> Bool {
        let token = Data(UUID().uuidString.utf8)
        return SharedPasteboard.write(token, for: "diagnostics") && SharedPasteboard.read("diagnostics") == token
    }

    /// Logged by "Clear Problems": the list starts after the last one, so the
    /// log file itself stays whole for "Share Log File".
    private static let clearedMarker = "Recent Problems cleared"

    static func clearProblems() {
        Log.settings.notice(clearedMarker)
    }

    /// The last 30 warning, error and fault lines of the log file, after the last clear.
    static func recentProblems() -> [String] {
        guard let url = FileLog.shared.fileURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n")
        let start = lines.lastIndex { $0.hasSuffix(clearedMarker) }.map { $0 + 1 } ?? lines.startIndex
        let problems = lines[start...].filter {
            $0.contains("[ERROR]") || $0.contains("[WARNING]") || $0.contains("[FAULT]")
        }
        return problems.suffix(30).map(String.init)
    }
}
