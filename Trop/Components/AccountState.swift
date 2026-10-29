//
//  AccountState.swift
//  Trop
//
//  Created by 686udjie on 2/07/2026.
//

import SwiftUI
import Combine
import SwiftyTube

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

    @ObservationIgnored private var loginObserver: AnyCancellable?
    @ObservationIgnored private let cookieStore = CookieStore()
    @ObservationIgnored private var hasAttemptedTokenRefresh = false
    @ObservationIgnored private var isFetchingAccountInfo = false

    private init() {
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
            isLoginSheetPresented = false
            hasAttemptedTokenRefresh = false
            Task { await fetchAccountInfo() }
        } else {
            accountName = "Guest"
            accountImageUrl = nil
        }
    }

    /// Google can answer `account_menu` with a guest-shaped menu while the
    /// session still works (stale rotating tokens). Retry, then renew once.
    func fetchAccountInfo() async {
        guard isLoggedIn, !isFetchingAccountInfo else { return }
        isFetchingAccountInfo = true
        defer { isFetchingAccountInfo = false }
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
                return
            }
            if accountImageUrl != nil || attempt == 3 { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// Renews the rotating session tokens through a hidden webview (Google
    /// sign-in round trip) and stores the reissued cookies in the Keychain.
    private func refreshRotatedSession() async {
        let base = await cookieStore.cookies()
        guard let sapisid = await cookieStore.sapisid() else { return }
        let refreshed = await SessionTokenRefresher.shared.refreshRotatedTokens(baseCookies: base)
        guard !refreshed.isEmpty else { return }
        await cookieStore.save(
            cookies: refreshed,
            sapisid: sapisid,
            visitorData: refreshed["visitor_data"],
            dataSyncId: await cookieStore.dataSyncId()
        )
        await InnerTubeClient.tropShared.loadState(from: cookieStore)
        await fetchAccountInfo()
    }

    func signOut() {
        loginModel.logout()
    }
}

/// The Google sign-in web sheet, driven by `AccountState.shared`.
private struct LoginSheetHost: ViewModifier {
    @Bindable var state = AccountState.shared

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $state.isLoginSheetPresented) {
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
