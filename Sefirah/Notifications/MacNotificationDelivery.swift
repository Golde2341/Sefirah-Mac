import Foundation
import SefirahCore
import UserNotifications

@MainActor
final class MacNotificationDelivery: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MacNotificationDelivery()

    var onNotificationClick: ((_ deviceID: String, _ appPackage: String, _ appName: String?) -> Void)?

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
    }

    /// Registers the app as the notification center delegate before launch completes.
    func configure() {
        center.delegate = self
    }

    /// Requests the notification interactions Sefirah uses for synchronized phone alerts.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                return false
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    func deliver(_ notification: NotificationInfo, from deviceID: String) {
        guard notification.infoType == .new else { return }

        Task {
            guard await requestAuthorizationIfNeeded() else { return }

            let content = UNMutableNotificationContent()
            content.title = notification.title?.nonEmpty ?? notification.appName?.nonEmpty ?? "New notification"
            content.subtitle = notification.appName?.nonEmpty ?? ""
            content.body = notification.text?.nonEmpty ?? ""
            content.sound = .default
            var userInfo: [String: Any] = [
                "deviceID": deviceID,
                "notificationKey": notification.notificationKey,
            ]
            if let appPackage = notification.appPackage?.nonEmpty {
                userInfo["appPackage"] = appPackage
            }
            if let appName = notification.appName?.nonEmpty {
                userInfo["appName"] = appName
            }
            content.userInfo = userInfo

            let request = UNNotificationRequest(
                identifier: identifier(for: notification.notificationKey, deviceID: deviceID),
                content: content,
                trigger: nil
            )

            try? await center.add(request)
        }
    }

    func remove(notificationKey: String, from deviceID: String) {
        let identifier = identifier(for: notificationKey, deviceID: deviceID)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let deviceID = userInfo["deviceID"] as? String,
           let appPackage = userInfo["appPackage"] as? String,
           !appPackage.isEmpty {
            let appName = userInfo["appName"] as? String
            Task { @MainActor in
                MacNotificationDelivery.shared.onNotificationClick?(deviceID, appPackage, appName)
            }
        }
        completionHandler()
    }

    private func identifier(for notificationKey: String, deviceID: String) -> String {
        "android-notification:\(deviceID):\(notificationKey)"
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
