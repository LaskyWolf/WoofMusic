//
//  DiscordRpcManager.swift
//  Trop
//
//  Created by 686udjie on 31/08/2026.
//

import Foundation
import Combine
import UIKit

struct DiscordUser: Equatable {
    let id: String
    let username: String
    let name: String
    let avatar: String?
}

// DiscordSocialBridge calls its delegate on the main queue, so the
// nonisolated witnesses can assume the main actor.
extension DiscordRpcManager: nonisolated DiscordSocialBridgeDelegate {
    nonisolated func discordSocialAuthorizationSucceeded(
        withAccessToken accessToken: String,
        refreshToken: String,
        expiresIn: Int,
        scope: String
    ) {
        MainActor.assumeIsolated {
            log("Social SDK authorization succeeded scope=\(scope) expiresIn=\(expiresIn)s hasRefresh=\(!refreshToken.isEmpty)")
            self.accessToken = accessToken
            _authorized = true
            statusSubject.value = .authorizing
            DiscordTokenStore.shared.storeFull(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresInSec: Int64(expiresIn)
            )
        }
    }

    nonisolated func discordSocialAuthorizationFailed(_ message: String) {
        MainActor.assumeIsolated {
            log("Social SDK authorization failed: \(message)")
            lastErrorSubject.value = "discord_error_invalid_scope"
            statusSubject.value = .disconnected
            _authorized = false
            _ready = false
            finishAuthorization(false)
        }
    }

    nonisolated func discordSocialStatusChanged(_ status: Int) {
        MainActor.assumeIsolated {
            log("Social SDK status=\(status)")
            if status == 3 {
                _ready = true
                _authorized = true
                statusSubject.value = .connected
                lastErrorSubject.value = nil
                finishAuthorization(true)
                if let token = accessToken {
                    Task { [weak self] in
                        let user = await self?.fetchCurrentUserAsync2(token: token)
                        self?.currentUserSubject.value = user
                    }
                }
            } else if status == 0 {
                _ready = false
                statusSubject.value = .disconnected
            }
        }
    }
}

@MainActor
final class DiscordRpcManager: NSObject {
    static let shared = DiscordRpcManager()

    enum Status: String { case disconnected, authorizing, connected }

    // MARK: - Published state (mirrors StateFlow)
    private let statusSubject = CurrentValueSubject<Status, Never>(.disconnected)
    var connectionStatus: AnyPublisher<Status, Never> { statusSubject.eraseToAnyPublisher() }
    var connectionStatusValue: Status { statusSubject.value }

    private let lastErrorSubject = CurrentValueSubject<String?, Never>(nil)
    var lastError: AnyPublisher<String?, Never> { lastErrorSubject.eraseToAnyPublisher() }
    var lastErrorValue: String? { lastErrorSubject.value }

    private let currentUserSubject = CurrentValueSubject<DiscordUser?, Never>(nil)
    var currentUser: AnyPublisher<DiscordUser?, Never> { currentUserSubject.eraseToAnyPublisher() }
    var currentUserValue: DiscordUser? { currentUserSubject.value }

    private let settingsChangedSubject = CurrentValueSubject<Int, Never>(0)
    var settingsChanged: AnyPublisher<Int, Never> { settingsChangedSubject.eraseToAnyPublisher() }

    func notifySettingsChanged() {
        settingsChangedSubject.value += 1
        currentSongId = nil
        currentIsPlaying = false
    }

    // MARK: - Internal state
    private var initialized = false
    private var _ready = false
    private var _authorized = false
    private var accessToken: String?
    private var authorizeInProgress = false
    private var lastActivitySentAtMs: Int64 = 0
    private var lastActivity: ActivityPayload?
    private var currentSongId: String?
    private var currentIsPlaying: Bool = false

    private let auth = DiscordAuth()
    private let appId = DiscordDefaults.appId
    private let socialSDK = DiscordSocialBridge.shared()

    override private init() {
        super.init()
        socialSDK.delegate = self
    }

    private func log(_ msg: String) {
        Log.discord.info(msg)
    }

    // MARK: - Init

    func initializeIfNeeded() {
        guard !initialized else { return }
        initialized = true
        statusSubject.value = .disconnected
        Task {
            if let saved = DiscordTokenStore.shared.retrieve(), !saved.isEmpty {
                reconnectWithToken(saved)
            }
        }
    }

    // MARK: - Auth

    func authorize(presentingAnchor: UIWindow? = nil, onComplete: @escaping (Bool) -> Void) {
        if authorizeInProgress { onComplete(false); return }
        if _ready && _authorized { onComplete(true); return }
        if _authorized, let token = accessToken, !token.isEmpty {
            reconnectWithToken(token); onComplete(true); return
        }
        authorizeInProgress = true
        statusSubject.value = .authorizing
        lastErrorSubject.value = nil
        authorizationCompletion = onComplete

        Log.discord.info("Starting Discord Social SDK authorization")
        socialSDK.authorize()
    }

    private var authorizationCompletion: ((Bool) -> Void)?

    private func finishAuthorization(_ success: Bool) {
        authorizeInProgress = false
        authorizationCompletion?(success)
        authorizationCompletion = nil
    }

    func fetchCurrentUserAsync2(token: String) async -> DiscordUser? {
        guard let url = URL(string: "https://discord.com/api/v10/users/@me") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        guard let (data, http) = try? await HttpClient.data(for: req),
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String,
              let username = json["username"] as? String else { return nil }
        let gName = json["global_name"] as? String
        let name = (gName?.isEmpty == false) ? (gName ?? username) : username
        let hash = json["avatar"] as? String
        let avatar: String?
        if let hash, !hash.isEmpty, hash != "null" {
            avatar = "https://cdn.discordapp.com/avatars/\(id)/\(hash).png"
        } else { avatar = nil }
        return DiscordUser(id: id, username: username, name: name, avatar: avatar)
    }

    // MARK: - setActivity / clear

    func setActivity(activity: DiscordActivity, songId: String?, isPlaying: Bool = true, status: PresenceStatus = .online) {
        guard _ready else { Log.discord.debug("setActivity skipping not ready songId=\(songId ?? "-") status=\(status.rawValue)"); return }
        let largeChanged = activity.largeImage != nil
            && activity.largeImage != lastActivity?.largeImage
        let smallChanged = activity.smallImage != nil
            && activity.smallImage != lastActivity?.smallImage
        let stateChanged = songId != currentSongId
            || isPlaying != currentIsPlaying || largeChanged || smallChanged
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if !stateChanged, lastActivitySentAtMs > 0, (now - lastActivitySentAtMs) < 2000 { Log.discord.debug("setActivity debounced"); return }
        lastActivitySentAtMs = now
        currentSongId = songId; currentIsPlaying = isPlaying

        let buttons: [(String, String)] = {
            var arr: [(String, String)] = []
            if let l = activity.button1Label, !l.isEmpty, let u = activity.button1Url, !u.isEmpty { arr.append((l, u)) }
            if let l = activity.button2Label, !l.isEmpty, let u = activity.button2Url, !u.isEmpty { arr.append((l, u)) }
            return arr
        }()

        let payloadNoImages = DiscordPresence.buildActivity(
            name: activity.name ?? "",
            type: ActivityType(rawValue: activity.activityType) ?? .listening,
            details: activity.details,
            state: activity.state,
            largeImage: activity.largeImage, largeText: activity.largeText,
            smallImage: activity.smallImage, smallText: activity.smallText,
            startMs: activity.startTimestamp > 0 ? activity.startTimestamp : nil,
            endMs: activity.endTimestamp,
            buttons: buttons
        )
        lastActivity = payloadNoImages
        Log.discord.debug(
            "Sending activity songId=\(songId ?? "-") playing=\(isPlaying) "
                + "type=\(payloadNoImages.type) hasLarge=\(activity.largeImage != nil) "
                + "hasSmall=\(activity.smallImage != nil) buttons=\(buttons.count)"
        )
        socialSDK.updateActivity(
                withName: payloadNoImages.name,
                activityType: activity.activityType,
                details: payloadNoImages.details,
                state: payloadNoImages.state,
                startTimeMs: payloadNoImages.startMs ?? 0,
                endTimeMs: payloadNoImages.endMs ?? 0,
                largeImage: activity.largeImage,
                largeText: activity.largeText,
                smallImage: activity.smallImage,
                smallText: activity.smallText,
                buttons: buttons.map { ["label": $0.0, "url": $0.1] }
        )

    }

    func clear() {
        guard _ready else { return }
        if lastActivity == nil, currentSongId == nil { return }
        lastActivity = nil; currentSongId = nil; currentIsPlaying = false
        socialSDK.clearActivity()
    }

    // MARK: - reconnect

    func reconnectWithToken(_ token: String) {
        guard initialized else { return }
        Task {
            self.accessToken = token
            DiscordTokenStore.shared.storeAccessToken(token)
            self.statusSubject.value = .authorizing
            // proactive refresh
            let refreshToken = DiscordTokenStore.shared.getRefreshToken()
            let expiresAt = DiscordTokenStore.shared.getExpiresAt()
            let nowSec = Int64(Date().timeIntervalSince1970)
            let needsRefresh = refreshToken != nil && !refreshToken!.isEmpty && expiresAt > 0 && (expiresAt - nowSec) < 3600
            if needsRefresh, let rt = refreshToken {
                do {
                    let refreshed = try await self.auth.refresh(refreshToken: rt)
                    self.accessToken = refreshed.accessToken
                    DiscordTokenStore.shared.storeFull(
                        accessToken: refreshed.accessToken,
                        refreshToken: refreshed.refreshToken,
                        expiresInSec: refreshed.expiresInSec)
                } catch DiscordAuthError.invalidGrant {
                    self.lastErrorSubject.value = "discord_error_token_refresh_failed"
                    self.logout(); return
                } catch {
                    self.log("refresh failed, continuing with old token: \(error)")
                }
            }
            self.socialSDK.connect(withAccessToken: self.accessToken ?? token)
        }
    }

    // MARK: - disconnect / logout

    func disconnect() {
        socialSDK.disconnect()
        statusSubject.value = .disconnected; _ready = false; _authorized = false
        currentSongId = nil; currentIsPlaying = false
    }

    func logout() {
        disconnect()
        accessToken = nil
        currentUserSubject.value = nil
        DiscordTokenStore.shared.clear()
        lastErrorSubject.value = nil
        lastActivity = nil
    }

    // MARK: - Helpers

    func isReady() -> Bool { _ready }
    func getAccessToken() -> String? { accessToken }
    /// A playing song's start time moves only on a seek, so a start within
    /// a few seconds of the sent one means the presence is still accurate.
    func isShowingSong(songId: String, isPlaying: Bool, startMs: Int64) -> Bool {
        guard currentSongId == songId, currentIsPlaying == isPlaying, let lastActivity else { return false }
        return abs(startMs - (lastActivity.startMs ?? 0)) < 3_000
    }

}
