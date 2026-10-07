import AppKit
import Foundation
import UserNotifications

/// Sefirah Phone — the tiny helper app that posts mirrored phone notifications under its own
/// identity, so they carry the phone icon while Sefirah's own app icon stays untouched.
///
/// Modes (each exits when done):
/// - `--deliver <payload.json>`: post one notification.
/// - `--remove <identifier>`: remove a pending/delivered notification.
/// - no arguments: launched by the system for a notification click; relay it to Sefirah.
@main
final class SefirahPhoneApp: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = SefirahPhoneApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        switch CommandLine.arguments.dropFirst().first {
        case "--deliver":
            guard CommandLine.arguments.count > 2 else { exit(1) }
            deliver(payloadPath: CommandLine.arguments[2])
        case "--remove":
            guard CommandLine.arguments.count > 2 else { exit(1) }
            remove(identifier: CommandLine.arguments[2])
        default:
            // Launched for a notification click (or accidentally); never linger.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { exit(0) }
        }
    }

    // MARK: - Delivering

    private struct Payload: Sendable {
        var identifier: String
        var title: String
        var subtitle: String
        var body: String
        var deviceID: String?
        var appPackage: String?
        var appName: String?
    }

    private func deliver(payloadPath: String) {
        guard let data = FileManager.default.contents(atPath: payloadPath),
              let payload = Self.parsePayload(data)
        else { exit(1) }
        try? FileManager.default.removeItem(atPath: payloadPath)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { exit(2) }
            let content = UNMutableNotificationContent()
            content.title = payload.title
            content.subtitle = payload.subtitle
            content.body = payload.body
            content.sound = .default
            var userInfo: [String: String] = [:]
            if let deviceID = payload.deviceID { userInfo["deviceID"] = deviceID }
            if let appPackage = payload.appPackage { userInfo["appPackage"] = appPackage }
            if let appName = payload.appName { userInfo["appName"] = appName }
            content.userInfo = userInfo

            let request = UNNotificationRequest(identifier: payload.identifier, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { _ in exit(0) }
        }
    }

    private static func parsePayload(_ data: Data) -> Payload? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return nil }
        return Payload(
            identifier: dictionary["identifier"] as? String ?? UUID().uuidString,
            title: dictionary["title"] as? String ?? "",
            subtitle: dictionary["subtitle"] as? String ?? "",
            body: dictionary["body"] as? String ?? "",
            deviceID: dictionary["deviceID"] as? String,
            appPackage: dictionary["appPackage"] as? String,
            appName: dictionary["appName"] as? String
        )
    }

    // MARK: - Removing

    private func remove(identifier: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }

    // MARK: - Clicking

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let deviceID = userInfo["deviceID"] as? String
        let package = userInfo["appPackage"] as? String
        let appName = userInfo["appName"] as? String
        Task { @MainActor in
            Self.relayToSefirah(deviceID: deviceID, package: package, appName: appName)
            completionHandler()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        }
    }

    private static func relayToSefirah(deviceID: String?, package: String?, appName: String?) {
        guard let deviceID, let package, !package.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "sefirah"
        components.host = "notification"
        var items = [
            URLQueryItem(name: "device", value: deviceID),
            URLQueryItem(name: "package", value: package),
        ]
        if let appName, !appName.isEmpty {
            items.append(URLQueryItem(name: "name", value: appName))
        }
        components.queryItems = items
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }
}
