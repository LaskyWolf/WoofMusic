//
//  ActivityNotifier.swift
//  Trop
//

import BackgroundTasks
import UserNotifications

/// Shows a notification on this iPhone for each new Activity entry, found when
/// the app opens and when iOS runs it in the background. iOS decides when that
/// is, often hours apart, so this is not a push: YouTube's pushes need its own app.
enum ActivityNotifier {
    static let taskId = "com.laskywolf.Music.activity"
    /// Between background checks. iOS may run them later, never earlier.
    private static let refreshInterval: TimeInterval = 3 * 3600
    private static let announcedKey = "activity.announced"
    private static let askedKey = "activity.asked"
    private static let announcedLimit = 300

    /// Registers the background check. Called once, before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            scheduleRefresh()
            let work = Task {
                await checkNow()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: taskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: refreshInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Asks the first time Activity opens, when the reason for asking is on screen.
    static func askForPermissionOnce() async {
        guard !UserDefaults.standard.bool(forKey: askedKey) else { return }
        UserDefaults.standard.set(true, forKey: askedKey)
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Loads the notifications, then announces each unread one not announced before.
    /// Signed out it does nothing; without permission it only loads.
    static func checkNow() async {
        guard await AccountState.shared.isLoggedIn else { return }
        await ActivityStore.shared.refresh()
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized,
              let sections = await ActivityStore.shared.sections else { return }

        let announced = Set(UserDefaults.standard.stringArray(forKey: announcedKey) ?? [])
        let fresh = sections.flatMap(\.items).filter { !$0.isRead && !announced.contains($0.id) && !$0.message.isEmpty }
        // The first check after setup would announce the whole inbox: only the newest few.
        for item in fresh.prefix(5) {
            let content = UNMutableNotificationContent()
            content.title = "Woof Music"
            content.body = item.message
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
        }
        let updated = Array(announced) + fresh.map(\.id)
        UserDefaults.standard.set(Array(updated.suffix(announcedLimit)), forKey: announcedKey)
    }
}
