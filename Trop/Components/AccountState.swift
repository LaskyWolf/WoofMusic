//
//  AccountState.swift
//  Trop
//
//  Created by 686udjie on 2/07/2026.
//

import SwiftUI
import Combine

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
            Task { await fetchAccountInfo() }
        } else {
            accountName = "Guest"
            accountImageUrl = nil
        }
    }

    private func fetchAccountInfo() async {
        do {
            let info = try await InnerTubeClient.tropShared.accountInfo()
            accountName = info.name
            accountImageUrl = info.thumbnailUrl
        } catch {
            Log.loginViewModel.error("Failed to fetch account info: \(error)")
        }
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
