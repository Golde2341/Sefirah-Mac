import AppKit
import Foundation
import OSLog
import SefirahCore

/// Posts mirrored phone notifications through the bundled `Sefirah Phone` helper app, so they
/// carry the phone icon while Sefirah's own app icon stays untouched. The helper relays clicks
/// back through a `sefirah://notification` URL handled by `AppModel`.
@MainActor
final class MacNotificationDelivery {
    static let shared = MacNotificationDelivery()
    private nonisolated static let log = Logger(subsystem: "io.github.madeye.sefirah.mac", category: "notifications")

    private struct Payload: Encodable {
        var identifier: String
        var title: String
        var subtitle: String
        var body: String
        var deviceID: String
        var appPackage: String
        var appName: String?
    }

    private init() {}

    func deliver(_ notification: NotificationInfo, from deviceID: String) {
        guard notification.infoType == .new,
              let appPackage = notification.appPackage?.nonEmpty
        else { return }

        let payload = Payload(
            identifier: Self.identifier(for: notification.notificationKey, deviceID: deviceID),
            title: notification.title?.nonEmpty ?? notification.appName?.nonEmpty ?? "New notification",
            subtitle: notification.appName?.nonEmpty ?? "",
            body: notification.text?.nonEmpty ?? "",
            deviceID: deviceID,
            appPackage: appPackage,
            appName: notification.appName?.nonEmpty
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sefirah-notification-\(UUID().uuidString).json")
        guard (try? data.write(to: url)) != nil else { return }
        launch(arguments: ["--deliver", url.path])
    }

    func remove(notificationKey: String, from deviceID: String) {
        launch(arguments: ["--remove", Self.identifier(for: notificationKey, deviceID: deviceID)])
    }

    private func launch(arguments: [String]) {
        guard let helper = Self.helperURL() else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: helper, configuration: configuration) { _, error in
            if let error {
                Self.log.error("Sefirah Phone helper failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func helperURL() -> URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/Helpers/Sefirah Phone.app", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func identifier(for notificationKey: String, deviceID: String) -> String {
        "android-notification:\(deviceID):\(notificationKey)"
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
