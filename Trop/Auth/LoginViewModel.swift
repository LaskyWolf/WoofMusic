//
//  LoginViewModel.swift
//  Trop
//
//  Created by 686udjie on 28/06/2026.
//

import Foundation
import Combine

// Drives sign-in and session verification, owns the CookieStore + InnerTube coordination
    @MainActor
    final class LoginViewModel: ObservableObject {
        @Published var cookies: [String: String] = [:]
        @Published var sapisid: String?
        @Published var visitorData: String?
        @Published var dataSyncId: String?
        @Published var isLoggedIn = false
        @Published var isPresented = false
        /// The sign-in sheet is adding another account to a signed-in app.
        var isAddingAccount = false

        var canCaptureSession: Bool { !isLoggedIn || isAddingAccount }

        private let authService = AuthService.shared
        private let cookieStore = CookieStore()
        private var loadTask: Task<Void, Never>?

        func handleLogin(cookies: [String: String], sapisid: String?, visitorData: String?, dataSyncId: String? = nil) {
            self.cookies = cookies
            self.sapisid = sapisid
            self.visitorData = visitorData
            self.dataSyncId = dataSyncId

            loadTask?.cancel()
            loadTask = Task { [weak self] in
                guard let self else { return }
        do {
            await AccountState.shared.prepareForNewSession()
            try await self.authService.importSession(from: self.cookieString(from: cookies), dataSyncId: dataSyncId)
            // Before isLoggedIn flips: nothing may read or write the wrong profile's data.
            await AccountState.shared.openProfileOfNewSession()
            self.isAddingAccount = false
            self.isLoggedIn = true
            self.isPresented = false
        } catch {
            AccountState.shared.cancelNewSession()
            Log.loginViewModel.error("importSession failed: \(error)")
        }
            }
        }

        func logout() {
            Task { [weak self] in
                guard let self else { return }
                await self.authService.logout()
                self.cookies = [:]
                self.sapisid = nil
                self.visitorData = nil
                self.dataSyncId = nil
                self.isLoggedIn = false
            }
        }

        func restoreSessionIfPresent() {
            loadTask?.cancel()
            loadTask = Task { [weak self] in
                guard let self else { return }
                let loggedIn = await self.cookieStore.isLoggedIn()
                guard loggedIn else { return }

                // Before isLoggedIn flips: whichever tab opens first then
                // requests with the account, not as a guest.
                await self.loadPersistedSession()
                self.isLoggedIn = true
            }
        }

        func loadPersistedSession() async {
            cookies = await cookieStore.cookies()
            sapisid = await cookieStore.sapisid()
            visitorData = await cookieStore.visitorData()
            dataSyncId = await cookieStore.dataSyncId()
            await authService.loadPersistedSession()
        }

        private func cookieString(from dict: [String: String]) -> String {
            dict.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        }
    }
