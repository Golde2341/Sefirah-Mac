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
        var attachmentPath: String?
    }

    private init() {}

    func deliver(_ notification: NotificationInfo, from deviceID: String, includeIcon: Bool) {
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
            appName: notification.appName?.nonEmpty,
            attachmentPath: includeIcon
                ? Self.writeAttachment(contactPhoto: notification.largeIcon, appIcon: notification.appIcon)
                : nil
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sefirah-notification-\(UUID().uuidString).json")
        guard (try? data.write(to: url)) != nil else { return }
        launch(arguments: ["--deliver", url.path])
    }

    /// Writes the richest image the phone sent — the contact photo (`largeIcon`) when available,
    /// otherwise the app icon (`appIcon`) — to a temporary file for the helper to attach to the
    /// notification, where it renders on the trailing side of the banner. Contact photos become
    /// circular avatars badged with the app icon (like WhatsApp's desktop notifications); app
    /// icons are rendered in the iOS squircle shape. Returns nil when there is no usable image.
    /// The helper deletes the file after scheduling the notification.
    private static func writeAttachment(contactPhoto: String, appIcon: String?) -> String? {
        let badge = appIcon?.nonEmpty
        var rendered: Data?
        if !contactPhoto.isEmpty {
            rendered = NotificationAttachmentImage.decodeAsContactPhoto(contactPhoto, appIcon: badge)
        }
        if rendered == nil, let badge {
            rendered = NotificationAttachmentImage.decodeAsAppIcon(badge)
        }
        guard let rendered else {
            if !contactPhoto.isEmpty || badge != nil {
                log.warning("Dropping notification image with unsupported format")
            }
            return nil
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sefirah-notification-attachment-\(UUID().uuidString).png")
        guard (try? rendered.write(to: url)) != nil else { return nil }
        return url.path
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
