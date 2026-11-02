//
//  AccountState.swift
//  Trop
//
//  Created by 686udjie on 2/07/2026.
//

import SwiftUI
import Combine
import SwiftyTube

/// A Google sign-in kept on this iPhone, to switch back to.
struct SavedProfile: Codable, Identifiable {
    let id: String
    var name: String
    var thumbnailUrl: String?
    var session: SessionState
}

/// The signed-in YouTube Music account, shared by every tab header and the
/// Settings account row, so signing in or out anywhere updates them all.
@MainActor
@Observable
final class AccountState {
    static let shared = AccountState()

    private(set) var isLoggedIn = false
    private(set) var accountName = "Guest"
    private(set) var accountImageUrl: String?
    var isLoginSheetPresented = false
    let loginModel = LoginViewModel()
    private(set) var profiles: [SavedProfile] = []
    private(set) var currentProfileId: String? {
        didSet { UserDefaults.standard.set(currentProfileId, forKey: Self.currentProfileKey) }
    }
    /// The profile being opened, for its row's spinner.
    private(set) var switchingProfileId: String?
    /// Changes when another profile takes over; every tab starts over with it.
    private(set) var generation = 0

    /// True while the cookies and the database of the previous session and the next one are mixed.
    private(set) var isChangingSession = false

    /// Another account's session can't be saved over this one until this one is saved.
    var canAddAccount: Bool {
        profiles.contains { $0.id == currentProfileId }
    }

    private static let currentProfileKey = "profile.currentAccount"

    @ObservationIgnored private var loginObserver: AnyCancellable?
    @ObservationIgnored private let cookieStore = CookieStore()
    @ObservationIgnored private let keychain = KeychainStorage()
    @ObservationIgnored private var hasAttemptedTokenRefresh = false
    @ObservationIgnored private var isFetchingAccountInfo = false
    /// Changes as soon as the session starts changing, while `generation` changes
    /// last. Work started for the old session checks it before saving anything.
    @ObservationIgnored private var sessionEpoch = 0

    private init() {
        profiles = keychain.loadProfiles()
        currentProfileId = UserDefaults.standard.string(forKey: Self.currentProfileKey)
        // LoginViewModel is an ObservableObject; mirror its flag into this
        // @Observable class so SwiftUI views refresh when it changes.
        loginObserver = loginModel.$isLoggedIn
            .removeDuplicates()
            .sink { [weak self] loggedIn in
                Task { @MainActor in self?.handleLoginChange(loggedIn) }
            }
        loginModel.restoreSessionIfPresent()
    }

    private func handleLoginChange(_ loggedIn: Bool) {
        isLoggedIn = loggedIn
        if loggedIn {
            startAccountWork()
        } else {
            accountName = "Guest"
            accountImageUrl = nil
        }
    }

    private func startAccountWork() {
        isLoginSheetPresented = false
        hasAttemptedTokenRefresh = false
        Task { await fetchAccountInfo() }
        // Here and not in a tab, so the library syncs whichever tab opens first.
        Task { await SyncBridge.checkAndSyncIfStale() }
    }

    /// Google can answer `account_menu` with a guest-shaped menu while the
    /// session still works (stale rotating tokens). Retry, then renew once.
    func fetchAccountInfo() async {
        guard isLoggedIn, !isFetchingAccountInfo else { return }
        isFetchingAccountInfo = true
        defer { isFetchingAccountInfo = false }
        let startedEpoch = sessionEpoch
        for attempt in 1...3 {
            let info: AccountInfo
            do {
                info = try await InnerTubeClient.tropShared.accountInfo()
            } catch {
                if error.isCancellation { return }
                if error is URLError {
                    Log.loginViewModel.notice("fetchAccountInfo: attempt \(attempt) failed: \(error)")
                } else {
                    Log.loginViewModel.error("fetchAccountInfo: attempt \(attempt) failed: \(error)")
                }
                return
            }
            // The answer belongs to the profile that asked.
            guard startedEpoch == sessionEpoch else { return }
            guard !info.name.isEmpty, info.name != "Guest" else {
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                Log.loginViewModel.notice("fetchAccountInfo: giving up — menu stayed guest-shaped")
                if !hasAttemptedTokenRefresh {
                    hasAttemptedTokenRefresh = true
                    // Release the guard so the fetch after the renewal can run.
                    isFetchingAccountInfo = false
                    await refreshRotatedSession()
                }
                return
            }
            accountName = info.name
            if let url = info.thumbnailUrl {
                accountImageUrl = url
            }
            await rememberCurrentProfile(info, epoch: startedEpoch)
            if info.thumbnailUrl != nil { return }
            if accountImageUrl != nil || attempt == 3 { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// Renews the rotating session tokens through a hidden webview (Google
    /// sign-in round trip) and stores the reissued cookies in the Keychain.
    private func refreshRotatedSession() async {
        let epoch = sessionEpoch
        let base = await cookieStore.cookies()
        let dataSyncId = await cookieStore.dataSyncId()
        guard let sapisid = await cookieStore.sapisid() else { return }
        let refreshed = await SessionTokenRefresher.shared.refreshRotatedTokens(baseCookies: base)
        // These tokens belong to the account that asked for them.
        guard !refreshed.isEmpty, epoch == sessionEpoch else { return }
        await cookieStore.save(
            cookies: refreshed,
            sapisid: sapisid,
            visitorData: refreshed["visitor_data"],
            dataSyncId: dataSyncId
        )
        await InnerTubeClient.tropShared.loadState(from: cookieStore)
        // Sync and Home ran with the old tokens and got a guest's answers.
        NotificationCenter.default.post(name: .sessionDidRenew, object: nil)
        Task { await SyncBridge.checkAndSyncIfStale() }
        await fetchAccountInfo()
    }

    /// Removes this account from the list and moves to another saved one if
    /// there is one. Its library and downloads stay, for when it signs back in.
    func signOut() {
        let others = profiles.filter { $0.id != currentProfileId }
        // Another profile can't open during a download; the Sign Out button is off then too.
        guard switchingProfileId == nil, others.isEmpty || !DownloadManager.shared.hasActiveDownloads else { return }
        sessionEpoch += 1
        SavedHome.clear()
        let leaving = currentProfileId
        profiles = others
        saveProfiles()
        currentProfileId = nil
        if let next = others.first {
            Task {
                await switchTo(next)
                // A login with no identity got a random id, so it could never sign back in to this data.
                if let leaving, UUID(uuidString: leaving) != nil { ProfileStorage.discard(accountId: leaving) }
            }
        } else {
            Task {
                await NowPlaying.shared.stopAndClear()
                WidgetSync.shared.clearProfileData()
                loginModel.logout()
            }
        }
    }

    // MARK: - Profiles

    func switchTo(_ profile: SavedProfile) async {
        guard profile.id != currentProfileId, switchingProfileId == nil,
              !DownloadManager.shared.hasActiveDownloads else { return }
        switchingProfileId = profile.id
        beginSessionChange()
        defer {
            switchingProfileId = nil
            isChangingSession = false
        }

        await saveCurrentSession()
        await SyncBridge.cancelRunning()
        // Before the session changes: its play reports belong to the previous account.
        await NowPlaying.shared.stopAndClear()
        await cookieStore.restore(profile.session)
        await loginModel.loadPersistedSession()
        // Studio's page must not open signed in to the previous account.
        await AuthService.clearGoogleWebsiteData()
        accountName = profile.name
        accountImageUrl = profile.thumbnailUrl
        await openStorage(of: profile.id)
        startAccountWork()
    }

    /// Opens Google's sign-in page, asking for an account instead of reusing the last one.
    func beginAddingAccount() async {
        guard canAddAccount, !DownloadManager.shared.hasActiveDownloads else { return }
        loginModel.isAddingAccount = true
        await AuthService.clearGoogleWebsiteData()
        isLoginSheetPresented = true
    }

    /// Runs before a new sign-in replaces the session.
    func prepareForNewSession() async {
        beginSessionChange()
        await saveCurrentSession()
        await SyncBridge.cancelRunning()
        // Before the session changes: its play reports belong to the previous account.
        if isLoggedIn { await NowPlaying.shared.stopAndClear() }
    }

    /// The new sign-in failed: the previous session is still the one in use.
    func cancelNewSession() {
        isChangingSession = false
    }

    private func beginSessionChange() {
        sessionEpoch += 1
        isChangingSession = true
        // A fetch still running for the previous session must not block the next one's.
        isFetchingAccountInfo = false
    }

    /// Runs once a new sign-in is saved, before the app sees it as signed in.
    func openProfileOfNewSession() async {
        let wasAdding = isLoggedIn
        let dataSyncId = await cookieStore.dataSyncId()
        let info = try? await InnerTubeClient.tropShared.accountInfo()
        let name = info?.name == "Guest" ? nil : info?.name
        // Google doesn't always send the same identifiers: an account seen before keeps its library.
        let seenBefore = [dataSyncId, info?.email].compactMap { $0 }.first(where: ProfileStorage.isClaimed)
        // ponytail: without a sync id or a menu this login gets a new profile; it can't be matched to an old one.
        let id = seenBefore ?? dataSyncId ?? info?.email ?? name ?? UUID().uuidString
        if wasAdding {
            accountName = name ?? ""
            accountImageUrl = info?.thumbnailUrl
        }
        await openStorage(of: id)
        isChangingSession = false
        // Signing in from signed out starts this when isLoggedIn flips.
        if wasAdding { startAccountWork() }
    }

    /// Moves the app to the account's database and downloads.
    private func openStorage(of accountId: String) async {
        currentProfileId = accountId
        let storage = ProfileStorage.claim(for: accountId)
        guard storage != ProfileStorage.active else { return }
        // A signed-out song saves its play time to the data it was playing with.
        await NowPlaying.shared.stopAndClear()
        // Signing in from signed out can happen during a download; it would land in the wrong folder.
        DownloadManager.shared.cancelAllForProfileChange()
        // Its scrobble timer ends with the song, before the Last.fm account changes.
        await LastFMIntegration.shared.syncState()
        ProfileStorage.activate(storage)
        await DatabaseService.shared.reopenForActiveProfile()
        await DownloadManager.shared.reloadForActiveProfile()
        await LikeStore.shared.refresh()
        await EpisodePlaybackStore.shared.reloadForActiveProfile()
        SearchViewModel.forgetRecency()
        LastFMTokenStore.shared.reloadForActiveProfile()
        ListenBrainz.shared.reloadForActiveProfile()
        Odesli.shared.reloadForActiveProfile()
        DiscordRpcManager.shared.reloadForActiveProfile()
        AppRouter.shared.closeAllPages()
        generation += 1
        WidgetSync.shared.clearProfileData()
        WidgetSync.shared.syncAll()
    }

    /// Saves the signed-in session under its account, so it can be switched back to.
    private func rememberCurrentProfile(_ info: AccountInfo, epoch: Int) async {
        guard let session = await cookieStore.sessionState(), epoch == sessionEpoch else { return }
        let id: String
        if let currentProfileId {
            id = currentProfileId
        } else {
            // A session signed in before profiles existed: it owns the app's current data.
            id = await cookieStore.dataSyncId() ?? info.email ?? info.name
            currentProfileId = id
            _ = ProfileStorage.claim(for: id)
        }
        let profile = SavedProfile(id: id, name: info.name, thumbnailUrl: info.thumbnailUrl ?? accountImageUrl, session: session)
        if let index = profiles.firstIndex(where: { $0.id == id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        saveProfiles()
    }

    /// Google rotates its tokens, so the saved copy goes out of date.
    private func saveCurrentSession() async {
        guard let session = await cookieStore.sessionState(),
              let index = profiles.firstIndex(where: { $0.id == currentProfileId }) else { return }
        profiles[index].session = session
        saveProfiles()
    }

    private func saveProfiles() {
        try? keychain.save(profiles, for: KeychainStorage.profilesKey)
    }
}

/// The Google sign-in web sheet, driven by `AccountState.shared`.
private struct LoginSheetHost: ViewModifier {
    @Bindable var state = AccountState.shared

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $state.isLoginSheetPresented, onDismiss: { state.loginModel.isAddingAccount = false }) {
                NavigationStack {
                    LoginWebView(model: state.loginModel)
                        .ignoresSafeArea()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { state.isLoginSheetPresented = false }
                            }
                        }
                }
            }
    }
}

extension View {
    func loginSheet() -> some View {
        modifier(LoginSheetHost())
    }
}
