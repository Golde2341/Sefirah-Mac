import Foundation
import GRDB

public struct NotificationSnapshot: Equatable, Sendable, Identifiable {
    public var id: String { key }
    public var key: String
    public var deviceId: String
    public var notificationKey: String
    public var appName: String
    public var appPackage: String
    public var title: String?
    public var text: String?
    public var timestampMillis: Int64
    public var replyResultKey: String?
    public var actions: [NotificationAction]
    /// Rendered artwork (contact photo + app badge, or the app icon) for the feed and banners.
    public var icon: Data?
}

public struct ConversationSnapshot: Equatable, Sendable, Identifiable {
    public var id: String { key }
    public var key: String
    public var deviceId: String
    public var threadId: Int64
    public var lastMessage: String?
    public var lastMessageTimestamp: Int64
    public var addresses: [String]
}

public struct MessageSnapshot: Equatable, Sendable, Identifiable {
    public var id: String { key }
    public var key: String
    public var threadId: Int64
    public var body: String
    public var timestamp: Int64
    public var outgoing: Bool
}

public struct DeviceLiveState: Equatable, Sendable {
    public var battery: BatteryState?
    public var ringerMode: Int?
    public var dndEnabled: Bool?
    public var playback: [PlaybackInfo]
    /// Wall-clock moment each session was last seen paused (used to drop stale player cards).
    public var pausedSince: [String: Date]
    /// When the current connection opened; sessions updated before it belong to a previous one.
    public var connectedAt: Date?
    /// Last update time per playback source, used with `connectedAt` to hide stale media.
    public var playbackUpdatedAt: [String: Date]
    public var audioStreams: [AudioStreamType: Int]
    public var incomingCall: CallInfo?
    public var clipboard: ClipboardInfo?
    public var lastTransfer: FileTransferInfo?
    public var lastSftp: SftpServerInfo?
    public var lastAction: ActionExecution?
    public var soundPlaying: Bool

    public init() {
        playback = []
        pausedSince = [:]
        connectedAt = nil
        playbackUpdatedAt = [:]
        audioStreams = [
            .media: 0,
            .ring: 0,
            .notification: 0,
            .alarm: 0,
            .voiceCall: 0,
        ]
        soundPlaying = false
    }
}

public enum FeatureEffect: Equatable, Sendable {
    case applyClipboard(ClipboardInfo)
    case receiveFiles(FileTransferInfo)
    case executeAction(ActionExecution)
}

public struct FeatureResult: Equatable, Sendable {
    public var outbound: [SocketMessage]
    public var effects: [FeatureEffect]

    public init(outbound: [SocketMessage] = [], effects: [FeatureEffect] = []) {
        self.outbound = outbound
        self.effects = effects
    }
}

/// In-process feature router. Tests feed `SocketMessage` values the same way `SessionManager` would.
public final class FeatureHub: @unchecked Sendable {
    private let database: AppDatabase
    private let lock = NSLock()
    public private(set) var live: [String: DeviceLiveState] = [:]
    public var actionsCatalog: [ActionItem] = []

    public init(database: AppDatabase) {
        self.database = database
    }

    @discardableResult
    public func handle(deviceId: String, _ message: SocketMessage) throws -> FeatureResult {
        lock.lock()
        defer { lock.unlock() }
        var outbound: [SocketMessage] = []
        var effects: [FeatureEffect] = []
        var state = live[deviceId] ?? DeviceLiveState()

        switch message {
        case .notificationInfo(let info):
            try persistNotification(deviceId: deviceId, info)
        case .notificationAction, .notificationReply:
            break
        case .clearNotifications:
            try database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM NotificationEntity WHERE DeviceId = ?", arguments: [deviceId])
            }
        case .clipboardInfo(let info):
            state.clipboard = info
            effects.append(.applyClipboard(info))
        case .fileTransferInfo(let info):
            state.lastTransfer = info
            effects.append(.receiveFiles(info))
        case .conversationInfo(let info):
            try persistConversation(deviceId: deviceId, info)
        case .textMessage(let text):
            try persistConversation(
                deviceId: deviceId,
                ConversationInfo(infoType: .new, threadId: text.threadId, recipients: text.addresses, messages: [text])
            )
        case .contactInfo(let contact):
            try persistContact(deviceId: deviceId, contact)
        case .callInfo(let info):
            if info.callState == .ringing {
                state.incomingCall = info
            } else {
                state.incomingCall = nil
            }
        case .callLogInfo(let log):
            try persistCallLog(deviceId: deviceId, log)
        case .batteryState(let battery):
            state.battery = battery
        case .ringerModeState(let ringer):
            state.ringerMode = ringer.mode
        case .audioStreamState(let stream):
            state.audioStreams[stream.streamType] = stream.level
        case .dndState(let dnd):
            state.dndEnabled = dnd.isEnabled
        case .playbackInfo(let playback):
            if playback.infoType == .removedSession {
                state.playback.removeAll { $0.source == playback.source }
                state.pausedSince[playback.source] = nil
                state.playbackUpdatedAt[playback.source] = nil
            } else {
                state.playbackUpdatedAt[playback.source] = Date()
                if playback.isPlaying {
                    state.pausedSince[playback.source] = nil
                } else if state.pausedSince[playback.source] == nil {
                    state.pausedSince[playback.source] = Date()
                }
                if let index = state.playback.firstIndex(where: { $0.source == playback.source }) {
                    // Merge so transport-only updates don't wipe metadata; most recent leads.
                    let merged = playback.merging(state.playback[index])
                    state.playback.remove(at: index)
                    state.playback.insert(merged, at: 0)
                } else {
                    state.playback.insert(playback, at: 0)
                }
            }
        case .playSound(let sound):
            state.soundPlaying = sound.isPlaying
        case .sftpServerInfo(let sftp):
            state.lastSftp = sftp
        case .actionInfo(let action):
            if let execution = ActionRunner.handleIncoming(action, catalog: actionsCatalog) {
                state.lastAction = execution
                effects.append(.executeAction(execution))
            }
        case .applicationInfo(let app):
            try persistApp(deviceId: deviceId, app)
        case .applicationList(let list):
            for app in list.appList {
                try persistApp(deviceId: deviceId, app)
            }
        default:
            break
        }

        live[deviceId] = state
        return FeatureResult(outbound: outbound, effects: effects)
    }

    public func reply(deviceId: String, notificationKey: String, replyResultKey: String, text: String) -> SocketMessage {
        .notificationReply(
            NotificationReply(notificationKey: notificationKey, replyResultKey: replyResultKey, replyText: text)
        )
    }

    public func invokeAction(deviceId: String, notificationKey: String, index: Int, label: String) -> SocketMessage {
        .notificationAction(
            NotificationAction(notificationKey: notificationKey, label: label, actionIndex: index)
        )
    }

    /// Outbound dismissal: asks the phone to cancel this notification in its shade as well
    /// (`NotificationFeature.removeNotification` on Android). The phone answers with a `Removed`
    /// echo, which is a no-op here because the row is already gone.
    public func dismissNotification(notificationKey: String) -> SocketMessage {
        .notificationInfo(NotificationInfo(notificationKey: notificationKey, infoType: .removed, timestampMillis: 0))
    }

    public func setRingerMode(_ mode: Int) -> SocketMessage {
        .ringerModeState(RingerModeState(mode: mode))
    }

    public func setAudioLevel(_ streamType: AudioStreamType, level: Int) -> SocketMessage {
        .audioStreamState(AudioStreamState(streamType: streamType, level: min(100, max(0, level))))
    }

    public func mediaAction(_ type: MediaActionType, source: String, value: Double? = nil) -> SocketMessage {
        .mediaAction(MediaAction(actionType: type, source: source, value: value))
    }

    public func playSound(isPlaying: Bool) -> SocketMessage {
        .playSound(PlaySound(isPlaying: isPlaying))
    }

    public func clipboard(type: String, content: String) -> SocketMessage {
        .clipboardInfo(ClipboardInfo(clipboardType: type, content: content))
    }

    public func sendSms(threadId: Int64, addresses: [String], body: String, subscriptionId: Int = 0) -> SocketMessage {
        .textMessage(
            TextMessage(
                uniqueId: Int64(Date().timeIntervalSince1970 * 1000),
                addresses: addresses,
                threadId: threadId,
                body: body,
                timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                messageType: 2,
                isTextMessage: true
            )
        )
    }

    /// Purges everything cached for a forgotten device: notifications, conversations and their
    /// messages, message attachments, call log, the app list (including per-app notification
    /// filters) and live state. The pairing record itself is owned by `DeviceRepository`.
    public func forgetDevice(deviceId: String) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM AttachmentEntity WHERE MessageKey IN (SELECT Key FROM MessageEntity WHERE DeviceId = ?)",
                arguments: [deviceId]
            )
            try db.execute(sql: "DELETE FROM MessageEntity WHERE DeviceId = ?", arguments: [deviceId])
            try db.execute(sql: "DELETE FROM ConversationEntity WHERE DeviceId = ?", arguments: [deviceId])
            try db.execute(sql: "DELETE FROM CallLogEntity WHERE DeviceId = ?", arguments: [deviceId])
            try db.execute(sql: "DELETE FROM NotificationEntity WHERE DeviceId = ?", arguments: [deviceId])
            try db.execute(sql: "DELETE FROM ApplicationEntity WHERE DeviceId = ?", arguments: [deviceId])
        }
        lock.lock()
        live[deviceId] = nil
        lock.unlock()
    }

    /// Removes one mirrored notification from the feed (local only; the phone keeps its own).
    public func removeNotification(deviceId: String, notificationKey: String) throws {
        let key = "\(deviceId):\(notificationKey)"
        try database.dbQueue.write { db in
            _ = try NotificationRecord.deleteOne(db, key: key)
        }
    }

    public func notifications(deviceId: String) throws -> [NotificationSnapshot] {
        try database.dbQueue.read { db in
            let rows = try NotificationRecord
                .filter(Column("DeviceId") == deviceId)
                .order(Column("TimestampMillis").desc)
                .fetchAll(db)
            return rows.map { row in
                let payload = decodePayload(row.payloadJSON)
                return NotificationSnapshot(
                    key: row.key,
                    deviceId: row.deviceId,
                    notificationKey: row.notificationKey,
                    appName: row.appName,
                    appPackage: row.appPackage,
                    title: row.title,
                    text: row.text,
                    timestampMillis: row.timestampMillis,
                    replyResultKey: row.replyResultKey,
                    actions: payload,
                    icon: row.largeIcon
                )
            }
        }
    }

    public func conversations(deviceId: String) throws -> [ConversationSnapshot] {
        try database.dbQueue.read { db in
            let rows = try ConversationRecord
                .filter(Column("DeviceId") == deviceId)
                .order(Column("LastMessageTimestamp").desc)
                .fetchAll(db)
            return rows.map { row in
                let addresses = (try? JSONDecoder().decode([String].self, from: Data((row.addressesJSON ?? "[]").utf8))) ?? []
                return ConversationSnapshot(
                    key: row.key,
                    deviceId: row.deviceId,
                    threadId: row.threadId,
                    lastMessage: row.lastMessage,
                    lastMessageTimestamp: row.lastMessageTimestamp,
                    addresses: addresses
                )
            }
        }
    }

    public func messages(deviceId: String, threadId: Int64) throws -> [MessageSnapshot] {
        try database.dbQueue.read { db in
            let key = ConversationRecord(key: "", deviceId: deviceId, threadId: threadId).key.isEmpty
                ? "\(deviceId):\(threadId)"
                : "\(deviceId):\(threadId)"
            let rows = try MessageRecord
                .filter(Column("ConversationKey") == key)
                .order(Column("Timestamp").asc)
                .fetchAll(db)
            return rows.map {
                MessageSnapshot(
                    key: $0.key,
                    threadId: $0.threadId,
                    body: $0.body,
                    timestamp: $0.timestamp,
                    outgoing: $0.messageType == 2
                )
            }
        }
    }

    public func callLogs(deviceId: String) throws -> [CallLogRecord] {
        try database.dbQueue.read { db in
            try CallLogRecord.filter(Column("DeviceId") == deviceId)
                .order(Column("TimestampMillis").desc)
                .fetchAll(db)
        }
    }

    public func apps(deviceId: String) throws -> [ApplicationRecord] {
        try database.dbQueue.read { db in
            try ApplicationRecord.filter(Column("DeviceId") == deviceId)
                .order(Column("AppName").asc)
                .fetchAll(db)
        }
    }

    public func setAppPinned(deviceId: String, packageName: String, isPinned: Bool) throws {
        let appKey = "\(deviceId):\(packageName)"
        try database.dbQueue.write { db in
            if var record = try ApplicationRecord.fetchOne(db, key: appKey) {
                record.pinned = isPinned
                try record.update(db)
            }
        }
    }

    public func setAppHidden(deviceId: String, packageName: String, isHidden: Bool) throws {
        let appKey = "\(deviceId):\(packageName)"
        try database.dbQueue.write { db in
            if var record = try ApplicationRecord.fetchOne(db, key: appKey) {
                record.hidden = isHidden
                try record.update(db)
            }
        }
    }

    public func setAppNotificationsEnabled(deviceId: String, packageName: String, isEnabled: Bool) throws {
        let appKey = "\(deviceId):\(packageName)"
        let filter: NotificationFilter = isEnabled ? .toastFeed : .disabled
        try database.dbQueue.write { db in
            if var record = try ApplicationRecord.fetchOne(db, key: appKey) {
                record.filter = filter
                try record.update(db)
            }
        }
    }

    public func isNotificationEnabled(deviceId: String, packageName: String) -> Bool {
        let appKey = "\(deviceId):\(packageName)"
        let record = try? database.dbQueue.read { db in
            try ApplicationRecord.fetchOne(db, key: appKey)
        }
        guard let record else { return true }
        return record.filter != .disabled
    }

    /// Records when the current connection opened (nil on disconnect). Sessions are kept — a
    /// transport-only update after a reconnect then merges into the full pre-existing snapshot —
    /// but `visiblePlayback` only surfaces sessions updated after this moment.
    public func markPlaybackConnection(deviceId: String, connectedAt: Date?) {
        lock.lock()
        defer { lock.unlock() }
        var state = live[deviceId] ?? DeviceLiveState()
        state.connectedAt = connectedAt
        live[deviceId] = state
    }

    /// Sessions that have played (been updated) since the current connection — what the rail and
    /// menu bar player should show.
    public func visiblePlayback(deviceId: String) -> [PlaybackInfo] {
        lock.lock()
        defer { lock.unlock() }
        guard let state = live[deviceId], let connectedAt = state.connectedAt else { return [] }
        return state.playback.filter { session in
            (state.playbackUpdatedAt[session.source] ?? .distantPast) > connectedAt
        }
    }

    /// Drops sessions paused for longer than `maxAge`. Returns true when something was removed.
    @discardableResult
    public func prunePausedPlayback(deviceId: String, maxAge: TimeInterval, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var state = live[deviceId] else { return false }
        let before = state.playback.count
        state.playback.removeAll { session in
            guard !session.isPlaying, let pausedAt = state.pausedSince[session.source] else { return false }
            return now.timeIntervalSince(pausedAt) > maxAge
        }
        let sources = Set(state.playback.map(\.source))
        state.pausedSince = state.pausedSince.filter { sources.contains($0.key) }
        guard state.playback.count != before else { return false }
        live[deviceId] = state
        return true
    }

    public func liveState(deviceId: String) -> DeviceLiveState {
        lock.lock()
        defer { lock.unlock() }
        return live[deviceId] ?? DeviceLiveState()
    }

    private func persistNotification(deviceId: String, _ info: NotificationInfo) throws {
        let key = "\(deviceId):\(info.notificationKey)"
        if info.infoType == .removed {
            try database.dbQueue.write { db in
                _ = try NotificationRecord.deleteOne(db, key: key)
            }
            return
        }
        let payload = NotificationActionPayload(actions: info.actions)
        let json = (try? String(data: JSONEncoder().encode(payload), encoding: .utf8)) ?? ""
        let record = NotificationRecord(
            key: key,
            deviceId: deviceId,
            notificationKey: info.notificationKey,
            appPackage: info.appPackage ?? "",
            appName: info.appName ?? "",
            title: info.title,
            text: info.text,
            timestampMillis: info.timestampMillis,
            groupKey: info.groupKey,
            tag: info.tag,
            replyResultKey: info.replyResultKey,
            largeIcon: notificationArtwork(for: info),
            payloadJSON: json
        )
        try database.dbQueue.write { db in
            try record.save(db)
        }
    }

    private func persistConversation(deviceId: String, _ info: ConversationInfo) throws {
        let key = "\(deviceId):\(info.threadId)"
        if info.infoType == .removed {
            try database.dbQueue.write { db in
                _ = try ConversationRecord.deleteOne(db, key: key)
                try db.execute(sql: "DELETE FROM MessageEntity WHERE ConversationKey = ?", arguments: [key])
            }
            return
        }
        let latest = info.messages.max(by: { $0.timestamp < $1.timestamp })
        let incomingAddresses = info.recipients.isEmpty
            ? nil
            : String(data: try JSONEncoder().encode(info.recipients), encoding: .utf8)
        try database.dbQueue.write { db in
            var conversation = try ConversationRecord.fetchOne(db, key: key)
                ?? ConversationRecord(key: key, deviceId: deviceId, threadId: info.threadId)
            if let incomingAddresses {
                conversation.addressesJSON = incomingAddresses
            }
            if let latest {
                conversation.lastMessageTimestamp = latest.timestamp
                conversation.lastMessage = latest.body
            }
            if !info.messages.isEmpty {
                conversation.hasRead = info.messages.contains(where: \.read)
            }
            conversation.timeStamp = Int64(Date().timeIntervalSince1970)
            try conversation.save(db)
            for text in info.messages {
                let message = MessageRecord(
                    key: "\(deviceId):\(text.uniqueId)",
                    conversationKey: key,
                    deviceId: deviceId,
                    uniqueId: text.uniqueId,
                    threadId: text.threadId,
                    body: text.body,
                    timestamp: text.timestamp,
                    read: text.read,
                    subscriptionId: text.subscriptionId,
                    messageType: text.messageType,
                    address: text.addresses.first ?? ""
                )
                try message.save(db)
            }
        }
    }

    private func persistContact(deviceId: String, _ contact: ContactInfo) throws {
        let id = contact.id ?? contact.lookupKey
        let key = "\(deviceId):\(id)"
        let record = ContactRecord(
            key: key,
            deviceId: deviceId,
            contactId: id,
            lookupKey: contact.lookupKey,
            displayName: contact.displayName
        )
        try database.dbQueue.write { db in
            try record.save(db)
        }
    }

    private func persistCallLog(deviceId: String, _ log: CallLogInfo) throws {
        let record = CallLogRecord(
            key: "\(deviceId):\(log.callLogId)",
            deviceId: deviceId,
            callLogId: log.callLogId,
            phoneNumber: log.phoneNumber,
            timestampMillis: log.timestampMillis,
            durationSeconds: log.durationSeconds,
            callType: log.callType
        )
        try database.dbQueue.write { db in
            try record.save(db)
        }
    }

    private func persistApp(deviceId: String, _ app: ApplicationInfo) throws {
        let appKey = "\(deviceId):\(app.packageName)"
        // Render the launcher icon once (small iOS-shaped PNG) so list/grid views never re-decode
        // the phone's base64 bitmap while scrolling. A missing icon keeps what we already stored.
        let icon = app.appIcon.flatMap { NotificationAttachmentImage.decodeAsAppIcon($0, size: 128) }
        try database.dbQueue.write { db in
            let existing = try ApplicationRecord.fetchOne(db, key: appKey)
            let record = ApplicationRecord(
                appKey: appKey,
                deviceId: deviceId,
                packageName: app.packageName,
                appName: app.appName,
                pinned: existing?.pinned ?? false,
                filter: existing?.filter ?? .toastFeed,
                icon: icon ?? existing?.icon,
                hidden: existing?.hidden ?? false
            )
            try record.save(db)
        }
    }

    /// Contact photo badged with the app icon when available, else the app icon alone — the same
    /// artwork the banner shows, rendered once for the rail's notification feed.
    private func notificationArtwork(for info: NotificationInfo) -> Data? {
        if !info.largeIcon.isEmpty,
           let photo = NotificationAttachmentImage.decodeAsContactPhoto(info.largeIcon, appIcon: info.appIcon)
        {
            return photo
        }
        if let appIcon = info.appIcon, !appIcon.isEmpty {
            return NotificationAttachmentImage.decodeAsAppIcon(appIcon)
        }
        return nil
    }

    private func decodePayload(_ json: String) -> [NotificationAction] {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(NotificationActionPayload.self, from: data)
        else { return [] }
        return payload.actions
    }
}

private struct NotificationActionPayload: Codable {
    var actions: [NotificationAction]
}
