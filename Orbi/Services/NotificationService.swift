import AppKit
import Foundation
import Observation
import OSLog
import UserNotifications

/// UNUserNotificationCenter wrapper: water reminder with "Drank ✓" / "Snooze 15m" actions.
@MainActor
@Observable
final class NotificationService: NSObject, WaterReminderPosting {
    enum Authorization: Equatable { case unknown, allowed, denied }

    private(set) var authorization: Authorization = .unknown

    @ObservationIgnored var onDrank: (() -> Void)?
    @ObservationIgnored var onSnooze: (() -> Void)?
    /// Body text for the reminder, e.g. "5 of 8 glasses today."
    @ObservationIgnored var waterSummary: (() -> String)?

    static let waterCategory = "WATER_REMINDER"
    static let drankAction = "DRANK"
    static let snoozeAction = "SNOOZE_15"
    static let waterRequestID = "water-reminder"

    @ObservationIgnored private let log = Logger(subsystem: "com.berke.Orbi", category: "Notifications")
    private var center: UNUserNotificationCenter { .current() }

    /// Must run at launch so action taps that launch the app are delivered.
    func configure() {
        center.delegate = self
        let drank = UNNotificationAction(identifier: Self.drankAction, title: "Drank ✓", options: [])
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "Snooze 15m", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.waterCategory, actions: [drank, snooze],
                                   intentIdentifiers: [], options: []),
        ])
    }

    func requestAuthorization() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            log.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
        }
        await refreshAuthorization()
    }

    func refreshAuthorization() async {
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional: authorization = .allowed
        case .denied: authorization = .denied
        default: authorization = .unknown
        }
    }

    func postWaterReminder() {
        let content = UNMutableNotificationContent()
        content.title = "Water + stretch break 💧"
        content.body = waterSummary?() ?? "Time for a glass of water."
        content.categoryIdentifier = Self.waterCategory
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.waterRequestID, content: content, trigger: nil)
        center.add(request) { [log] error in
            if let error { log.error("Posting reminder failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func clearWaterReminder() {
        center.removeDeliveredNotifications(withIdentifiers: [Self.waterRequestID])
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    fileprivate func handle(action: String) {
        switch action {
        case Self.drankAction: onDrank?()
        case Self.snoozeAction: onSnooze?()
        default: break  // plain tap / dismiss
        }
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    /// Show banners even when Orbi is the active app (e.g. its panel is open).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        await MainActor.run { self.handle(action: action) }
    }
}
