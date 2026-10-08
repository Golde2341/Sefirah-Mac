import AppKit
import SefirahCore
import XCTest

final class FeatureHubTests: XCTestCase {
    func testNotificationPersistReplyAndAction() throws {
        let hub = try makeHub()
        let inbound = SocketMessage.notificationInfo(
            NotificationInfo(
                notificationKey: "n1",
                infoType: .new,
                timestampMillis: 99,
                appPackage: "com.chat",
                appName: "Chat",
                title: "Ada",
                text: "hello",
                actions: [NotificationAction(notificationKey: "n1", label: "Mark", actionIndex: 0)],
                replyResultKey: "rk"
            )
        )
        _ = try hub.handle(deviceId: "phone", inbound)
        let notes = try hub.notifications(deviceId: "phone")
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].title, "Ada")
        XCTAssertEqual(notes[0].actions.first?.label, "Mark")

        let reply = hub.reply(deviceId: "phone", notificationKey: "n1", replyResultKey: "rk", text: "ok")
        guard case .notificationReply(let payload) = reply else { return XCTFail("reply") }
        XCTAssertEqual(payload.replyText, "ok")
        XCTAssertEqual(payload.notificationKey, "n1")

        let action = hub.invokeAction(deviceId: "phone", notificationKey: "n1", index: 0, label: "Mark")
        guard case .notificationAction(let invoked) = action else { return XCTFail("action") }
        XCTAssertEqual(invoked.actionIndex, 0)

        let dismissal = hub.dismissNotification(notificationKey: "n1")
        guard case .notificationInfo(let dismissed) = dismissal else { return XCTFail("dismissal") }
        XCTAssertEqual(dismissed.infoType, .removed)
        XCTAssertEqual(dismissed.notificationKey, "n1")

        _ = try hub.handle(deviceId: "phone", .clearNotifications)
        XCTAssertTrue(try hub.notifications(deviceId: "phone").isEmpty)
    }

    func testClipboardAndFileTransferAndCallInfo() throws {
        let hub = try makeHub()
        let clipboard = ClipboardInfo(clipboardType: "text/plain", content: "copied")
        let clipboardResult = try hub.handle(deviceId: "phone", .clipboardInfo(clipboard))
        XCTAssertEqual(hub.liveState(deviceId: "phone").clipboard?.content, "copied")
        XCTAssertEqual(clipboardResult.effects, [.applyClipboard(clipboard)])

        let transfer = FileTransferInfo(
            files: [FileMetadata(fileName: "a.png", mimeType: "image/png", fileSize: 12)],
            serverInfo: ServerInfo(port: 5152),
            isClipboard: false
        )
        let transferResult = try hub.handle(deviceId: "phone", .fileTransferInfo(transfer))
        XCTAssertEqual(hub.liveState(deviceId: "phone").lastTransfer?.serverInfo.port, 5152)
        XCTAssertEqual(transferResult.effects, [.receiveFiles(transfer)])

        _ = try hub.handle(
            deviceId: "phone",
            .callInfo(CallInfo(callState: .ringing, phoneNumber: "+1555"))
        )
        XCTAssertEqual(hub.liveState(deviceId: "phone").incomingCall?.phoneNumber, "+1555")
        _ = try hub.handle(
            deviceId: "phone",
            .callLogInfo(
                CallLogInfo(callLogId: 7, phoneNumber: "+1555", timestampMillis: 1, durationSeconds: 0, callType: .missed)
            )
        )
        XCTAssertEqual(try hub.callLogs(deviceId: "phone").first?.callType, .missed)
        _ = try hub.handle(deviceId: "phone", .callInfo(CallInfo(callState: .inProgress, phoneNumber: "+1555")))
        XCTAssertNil(hub.liveState(deviceId: "phone").incomingCall)
    }

    func testSmsConversationAndSend() throws {
        let hub = try makeHub()
        let conversation = ConversationInfo(
            infoType: .new,
            threadId: 44,
            recipients: ["+1555"],
            messages: [
                TextMessage(uniqueId: 1, addresses: ["+1555"], threadId: 44, body: "hi", timestamp: 10, messageType: 1, isTextMessage: true),
            ]
        )
        _ = try hub.handle(deviceId: "phone", .conversationInfo(conversation))
        XCTAssertEqual(try hub.conversations(deviceId: "phone").first?.lastMessage, "hi")
        XCTAssertEqual(try hub.messages(deviceId: "phone", threadId: 44).first?.body, "hi")

        let outbound = hub.sendSms(threadId: 44, addresses: ["+1555"], body: "reply")
        guard case .textMessage(let sent) = outbound else { return XCTFail("sms") }
        XCTAssertEqual(sent.body, "reply")
        XCTAssertEqual(sent.messageType, 2)
        XCTAssertEqual(sent.threadId, 44)

        _ = try hub.handle(
            deviceId: "phone",
            .conversationInfo(
                ConversationInfo(
                    infoType: .activeUpdated,
                    threadId: 44,
                    recipients: [],
                    messages: [
                        TextMessage(uniqueId: 2, addresses: ["+1555"], threadId: 44, body: "later", timestamp: 20, messageType: 1),
                    ]
                )
            )
        )
        XCTAssertEqual(try hub.conversations(deviceId: "phone").first?.addresses, ["+1555"])
        XCTAssertEqual(try hub.conversations(deviceId: "phone").first?.lastMessage, "later")
    }

    func testForgetDevicePurgesOnlyThatDevice() throws {
        let hub = try makeHub()
        _ = try hub.handle(deviceId: "phone", .notificationInfo(NotificationInfo(
            notificationKey: "n1", infoType: .new, timestampMillis: 1,
            appPackage: "com.chat", appName: "Chat", title: "Hi", text: "there"
        )))
        _ = try hub.handle(deviceId: "tablet", .notificationInfo(NotificationInfo(
            notificationKey: "n2", infoType: .new, timestampMillis: 1,
            appPackage: "com.chat", appName: "Chat", title: "Kept", text: "on the tablet"
        )))
        _ = try hub.handle(deviceId: "phone", .conversationInfo(ConversationInfo(
            infoType: .new, threadId: 7, recipients: ["+1555"],
            messages: [
                TextMessage(uniqueId: 1, addresses: ["+1555"], threadId: 7, body: "hi", timestamp: 10, messageType: 1, isTextMessage: true)
            ]
        )))
        XCTAssertEqual(try hub.notifications(deviceId: "phone").count, 1)
        XCTAssertEqual(try hub.conversations(deviceId: "phone").count, 1)
        XCTAssertEqual(try hub.messages(deviceId: "phone", threadId: 7).count, 1)

        try hub.forgetDevice(deviceId: "phone")

        XCTAssertTrue(try hub.notifications(deviceId: "phone").isEmpty)
        XCTAssertTrue(try hub.conversations(deviceId: "phone").isEmpty)
        XCTAssertTrue(try hub.messages(deviceId: "phone", threadId: 7).isEmpty)
        XCTAssertEqual(try hub.notifications(deviceId: "tablet").count, 1)
    }

    func testDeviceRailAndActionDispatch() throws {
        let hub = try makeHub()
        hub.actionsCatalog = [ActionItem(id: "lock", name: "Lock", actionId: "power", settings: ["powerKind": "Lock"])]
        _ = try hub.handle(deviceId: "phone", .batteryState(BatteryState(batteryLevel: 18, isCharging: false)))
        _ = try hub.handle(deviceId: "phone", .ringerModeState(RingerModeState(mode: 1)))
        _ = try hub.handle(deviceId: "phone", .dndState(DndState(isEnabled: true)))
        _ = try hub.handle(
            deviceId: "phone",
            .playbackInfo(PlaybackInfo(infoType: .playbackInfo, source: "spotify", trackTitle: "Song", isPlaying: true))
        )
        _ = try hub.handle(deviceId: "phone", .playSound(PlaySound(isPlaying: true)))
        let actionResult = try hub.handle(deviceId: "phone", .actionInfo(ActionInfo(actionId: "lock", actionName: "Lock")))
        _ = try hub.handle(deviceId: "phone", .audioStreamState(AudioStreamState(streamType: .media, level: 40)))
        _ = try hub.handle(deviceId: "phone", .audioStreamState(AudioStreamState(streamType: .ring, level: 12)))
        let state = hub.liveState(deviceId: "phone")
        XCTAssertEqual(state.battery?.batteryLevel, 18)
        XCTAssertEqual(state.ringerMode, 1)
        XCTAssertEqual(state.dndEnabled, true)
        XCTAssertEqual(state.playback.first?.trackTitle, "Song")
        XCTAssertTrue(state.soundPlaying)
        XCTAssertEqual(state.lastAction?.kind, "power")
        XCTAssertEqual(state.lastAction?.command, "/usr/bin/osascript")
        XCTAssertEqual(state.audioStreams[.media], 40)
        XCTAssertEqual(state.audioStreams[.ring], 12)
        guard case .executeAction(let execution) = actionResult.effects.first else {
            return XCTFail("expected executeAction effect")
        }
        XCTAssertEqual(execution.command, "/usr/bin/osascript")
        XCTAssertFalse(execution.command.contains("CGSession"))
    }

    func testDeviceControlOutboundRingerVolumeMediaAndFindPhone() throws {
        let hub = try makeHub()

        let ringer = hub.setRingerMode(0)
        guard case .ringerModeState(let payload) = ringer else { return XCTFail("ringer") }
        XCTAssertEqual(payload.mode, 0)
        let ringerJSON = try JSONSerialization.jsonObject(with: NDJSONCodec.encodeMessage(ringer)) as? [String: Any]
        XCTAssertEqual(ringerJSON?["type"] as? String, "RingerModeState")
        XCTAssertEqual(ringerJSON?["mode"] as? Int, 0)
        XCTAssertEqual(try NDJSONCodec.decodeMessage(from: NDJSONCodec.encodeMessage(ringer)), ringer)

        let volume = hub.setAudioLevel(.media, level: 77)
        guard case .audioStreamState(let stream) = volume else { return XCTFail("volume") }
        XCTAssertEqual(stream.streamType, .media)
        XCTAssertEqual(stream.level, 77)
        let volumeJSON = try JSONSerialization.jsonObject(with: NDJSONCodec.encodeMessage(volume)) as? [String: Any]
        XCTAssertEqual(volumeJSON?["type"] as? String, "AudioStreamState")
        XCTAssertEqual(volumeJSON?["streamType"] as? Int, 3)
        XCTAssertNotEqual(volumeJSON?["streamType"] as? String, "Media")
        XCTAssertEqual(try NDJSONCodec.decodeMessage(from: NDJSONCodec.encodeMessage(volume)), volume)

        let clamped = hub.setAudioLevel(.alarm, level: 140)
        guard case .audioStreamState(let alarm) = clamped else { return XCTFail("clamp") }
        XCTAssertEqual(alarm.level, 100)

        let play = hub.mediaAction(.play, source: "spotify")
        let playJSON = try JSONSerialization.jsonObject(with: NDJSONCodec.encodeMessage(play)) as? [String: Any]
        XCTAssertEqual(playJSON?["type"] as? String, "MediaAction")
        XCTAssertEqual(playJSON?["actionType"] as? String, "Play")
        XCTAssertEqual(playJSON?["source"] as? String, "spotify")
        XCTAssertEqual(try NDJSONCodec.decodeMessage(from: NDJSONCodec.encodeMessage(play)), play)

        let mediaVolume = hub.mediaAction(.volumeUpdate, source: "spotify", value: 55)
        guard case .mediaAction(let media) = mediaVolume else { return XCTFail("media volume") }
        XCTAssertEqual(media.actionType, .volumeUpdate)
        XCTAssertEqual(media.value, 55)

        let find = hub.playSound(isPlaying: true)
        guard case .playSound(let sound) = find else { return XCTFail("find") }
        XCTAssertTrue(sound.isPlaying)
        XCTAssertEqual(try NDJSONCodec.decodeMessage(from: NDJSONCodec.encodeMessage(find)), find)

        let clip = hub.clipboard(type: "text/plain", content: "from-mac")
        guard case .clipboardInfo(let info) = clip else { return XCTFail("clipboard") }
        XCTAssertEqual(info.clipboardType, "text/plain")
        XCTAssertEqual(info.content, "from-mac")
    }

    func testAppListStoresShapedIcon() throws {
        let hub = try makeHub()
        let png = try sampleIconPNG()
        _ = try hub.handle(deviceId: "phone", .applicationInfo(
            ApplicationInfo(packageName: "com.x", appName: "X", appIcon: png.base64EncodedString())
        ))
        let app = try XCTUnwrap(hub.apps(deviceId: "phone").first)
        let icon = try XCTUnwrap(app.icon)
        XCTAssertNotNil(NSImage(data: icon))

        // A later sync without an icon keeps what was stored.
        _ = try hub.handle(deviceId: "phone", .applicationInfo(
            ApplicationInfo(packageName: "com.x", appName: "X")
        ))
        XCTAssertEqual(try hub.apps(deviceId: "phone").first?.icon, icon)
    }

    func testHiddenAppsRoundTripAndSyncPreservesTheFlag() throws {
        let hub = try makeHub()
        _ = try hub.handle(deviceId: "phone", .applicationInfo(
            ApplicationInfo(packageName: "com.x", appName: "X")
        ))
        try hub.setAppHidden(deviceId: "phone", packageName: "com.x", isHidden: true)
        XCTAssertEqual(try hub.apps(deviceId: "phone").first?.hidden, true)

        // Re-syncing the app list keeps the user's hidden flag (and picks up name changes).
        _ = try hub.handle(deviceId: "phone", .applicationInfo(
            ApplicationInfo(packageName: "com.x", appName: "X Renamed")
        ))
        let reloaded = try XCTUnwrap(hub.apps(deviceId: "phone").first)
        XCTAssertTrue(reloaded.hidden)
        XCTAssertEqual(reloaded.appName, "X Renamed")
    }

    func testNotificationStoresArtwork() throws {
        let hub = try makeHub()
        let png = try sampleIconPNG()
        _ = try hub.handle(deviceId: "phone", .notificationInfo(NotificationInfo(
            notificationKey: "n1", infoType: .new, timestampMillis: 1,
            appPackage: "com.chat", appName: "Chat", title: "Ada", text: "hi",
            appIcon: png.base64EncodedString()
        )))
        let note = try XCTUnwrap(hub.notifications(deviceId: "phone").first)
        let icon = try XCTUnwrap(note.icon)
        XCTAssertNotNil(NSImage(data: icon))
    }

    func testPlaybackOrderPutsMostRecentFirst() throws {
        let hub = try makeHub()
        _ = try hub.handle(deviceId: "phone", .playbackInfo(
            PlaybackInfo(infoType: .playbackInfo, source: "a", trackTitle: "A", isPlaying: true)
        ))
        _ = try hub.handle(deviceId: "phone", .playbackInfo(
            PlaybackInfo(infoType: .playbackInfo, source: "b", trackTitle: "B", isPlaying: true)
        ))
        XCTAssertEqual(hub.liveState(deviceId: "phone").playback.map(\.trackTitle), ["B", "A"])

        // The most recently played session leads.
        _ = try hub.handle(deviceId: "phone", .playbackInfo(
            PlaybackInfo(infoType: .playbackInfo, source: "a", trackTitle: "A", isPlaying: true)
        ))
        XCTAssertEqual(hub.liveState(deviceId: "phone").playback.map(\.trackTitle), ["A", "B"])
    }

    func testRemoveSingleNotification() throws {
        let hub = try makeHub()
        for key in ["n1", "n2"] {
            _ = try hub.handle(deviceId: "phone", .notificationInfo(NotificationInfo(
                notificationKey: key, infoType: .new, timestampMillis: 1,
                appPackage: "com.chat", appName: "Chat", title: key, text: "hello"
            )))
        }
        try hub.removeNotification(deviceId: "phone", notificationKey: "n1")
        XCTAssertEqual(try hub.notifications(deviceId: "phone").map(\.notificationKey), ["n2"])
    }

    func testHiddenAppNotificationsStayMutedUntilAllowed() throws {
        let hub = try makeHub()
        _ = try hub.handle(deviceId: "phone", .applicationInfo(
            ApplicationInfo(packageName: "com.secret", appName: "Secret")
        ))
        _ = try hub.handle(deviceId: "phone", .notificationInfo(NotificationInfo(
            notificationKey: "s1", infoType: .new, timestampMillis: 1,
            appPackage: "com.secret", appName: "Secret", title: "Hi", text: "there"
        )))
        XCTAssertTrue(hub.shouldShowNotificationBanner(deviceId: "phone", packageName: "com.secret"))
        XCTAssertEqual(try hub.notifications(deviceId: "phone").count, 1)

        // Hiding the app mutes its notifications (banners and feed)…
        try hub.setAppHidden(deviceId: "phone", packageName: "com.secret", isHidden: true)
        XCTAssertTrue(hub.isAppHidden(deviceId: "phone", packageName: "com.secret"))
        XCTAssertFalse(hub.shouldShowNotificationBanner(deviceId: "phone", packageName: "com.secret"))
        XCTAssertTrue(try hub.notifications(deviceId: "phone").isEmpty)

        // …until the user allows them while the app stays hidden.
        try hub.setAppHiddenNotificationsEnabled(deviceId: "phone", packageName: "com.secret", isEnabled: true)
        XCTAssertTrue(hub.isAppHidden(deviceId: "phone", packageName: "com.secret"))
        XCTAssertTrue(hub.shouldShowNotificationBanner(deviceId: "phone", packageName: "com.secret"))
        XCTAssertEqual(try hub.notifications(deviceId: "phone").count, 1)

        // Muting an app wins even when its hidden notifications are allowed.
        try hub.setAppNotificationsEnabled(deviceId: "phone", packageName: "com.secret", isEnabled: false)
        XCTAssertFalse(hub.shouldShowNotificationBanner(deviceId: "phone", packageName: "com.secret"))
        XCTAssertTrue(try hub.notifications(deviceId: "phone").isEmpty)

        // Unhiding restores the per-app filter as the only deciding factor.
        try hub.setAppHidden(deviceId: "phone", packageName: "com.secret", isHidden: false)
        XCTAssertFalse(hub.shouldShowNotificationBanner(deviceId: "phone", packageName: "com.secret"))

        try hub.setAppNotificationsEnabled(deviceId: "phone", packageName: "com.secret", isEnabled: true)
        XCTAssertTrue(hub.shouldShowNotificationBanner(deviceId: "phone", packageName: "com.secret"))
        XCTAssertEqual(try hub.notifications(deviceId: "phone").count, 1)
    }

    func testMutingNotificationOnlyAppRegistersPlaceholder() throws {
        let hub = try makeHub()
        _ = try hub.handle(deviceId: "phone", .notificationInfo(NotificationInfo(
            notificationKey: "n1", infoType: .new, timestampMillis: 1,
            appPackage: "android", appName: "Android System", title: "Battery low", text: "20%"
        )))
        XCTAssertEqual(try hub.notifications(deviceId: "phone").count, 1)
        XCTAssertTrue(try hub.apps(deviceId: "phone").isEmpty)

        // Hiding from the notification's context menu registers a manageable placeholder record.
        try hub.setNotificationOnlyAppFilter(
            deviceId: "phone", packageName: "android", appName: "Android System", filter: .disabled
        )
        XCTAssertTrue(try hub.notifications(deviceId: "phone").isEmpty)
        let record = try XCTUnwrap(hub.apps(deviceId: "phone").first { $0.packageName == "android" })
        XCTAssertEqual(record.filter, .disabled)
        XCTAssertEqual(record.appName, "Android System")
        XCTAssertFalse(record.hidden)

        // Showing notifications through the record lets the stored notification back into the feed.
        try hub.setAppNotificationsEnabled(deviceId: "phone", packageName: "android", isEnabled: true)
        XCTAssertEqual(try hub.notifications(deviceId: "phone").count, 1)
    }

    func testMuteKeepsNotificationsInFeedWithoutBanners() throws {
        let hub = try makeHub()
        _ = try hub.handle(deviceId: "phone", .applicationInfo(
            ApplicationInfo(packageName: "com.chat", appName: "Chat")
        ))
        _ = try hub.handle(deviceId: "phone", .notificationInfo(NotificationInfo(
            notificationKey: "n1", infoType: .new, timestampMillis: 1,
            appPackage: "com.chat", appName: "Chat", title: "Hi", text: "there"
        )))

        // Default level: banner and feed.
        XCTAssertTrue(hub.shouldShowNotificationBanner(deviceId: "phone", packageName: "com.chat"))
        XCTAssertEqual(try hub.notifications(deviceId: "phone").count, 1)

        // Muted: no banner, but the notification still lands in the feed.
        try hub.setAppNotificationFilter(deviceId: "phone", packageName: "com.chat", filter: .feed)
        XCTAssertFalse(hub.shouldShowNotificationBanner(deviceId: "phone", packageName: "com.chat"))
        XCTAssertEqual(try hub.notifications(deviceId: "phone").count, 1)

        // Hidden: gone from the feed too.
        try hub.setAppNotificationFilter(deviceId: "phone", packageName: "com.chat", filter: .disabled)
        XCTAssertFalse(hub.shouldShowNotificationBanner(deviceId: "phone", packageName: "com.chat"))
        XCTAssertTrue(try hub.notifications(deviceId: "phone").isEmpty)

        // Back to normal.
        try hub.setAppNotificationFilter(deviceId: "phone", packageName: "com.chat", filter: .toastFeed)
        XCTAssertTrue(hub.shouldShowNotificationBanner(deviceId: "phone", packageName: "com.chat"))
        XCTAssertEqual(try hub.notifications(deviceId: "phone").count, 1)
    }

    func testPlaybackTransportUpdatesKeepMetadata() throws {
        let hub = try makeHub()
        _ = try hub.handle(deviceId: "phone", .playbackInfo(PlaybackInfo(
            infoType: .playbackInfo, source: "spotify", trackTitle: "Song", artist: "Artist",
            isPlaying: false, position: 109_136, maxSeekTime: 329_341, appName: "Spotify",
            volume: 40, canSeek: true
        )))
        // A transport-only update (just the play state) must not wipe the card.
        _ = try hub.handle(deviceId: "phone", .playbackInfo(PlaybackInfo(
            infoType: .playbackInfo, source: "spotify", isPlaying: true
        )))
        let session = try XCTUnwrap(hub.liveState(deviceId: "phone").playback.first)
        XCTAssertTrue(session.isPlaying)
        XCTAssertEqual(session.trackTitle, "Song")
        XCTAssertEqual(session.artist, "Artist")
        XCTAssertEqual(session.appName, "Spotify")
        XCTAssertEqual(session.maxSeekTime, 329_341)
        XCTAssertEqual(session.volume, 40)
        XCTAssertEqual(session.canSeek, true)
    }

    func testPausedSessionsPruneAfterMaxAge() throws {
        let hub = try makeHub()
        _ = try hub.handle(deviceId: "phone", .playbackInfo(
            PlaybackInfo(infoType: .playbackInfo, source: "a", trackTitle: "A", isPlaying: true)
        ))
        _ = try hub.handle(deviceId: "phone", .playbackInfo(
            PlaybackInfo(infoType: .playbackInfo, source: "a", isPlaying: false)
        ))
        XCTAssertEqual(hub.liveState(deviceId: "phone").playback.count, 1)

        XCTAssertFalse(hub.prunePausedPlayback(deviceId: "phone", maxAge: 600))
        XCTAssertTrue(hub.prunePausedPlayback(deviceId: "phone", maxAge: 600, now: Date().addingTimeInterval(601)))
        XCTAssertTrue(hub.liveState(deviceId: "phone").playback.isEmpty)
    }

    func testPlaybackConnectionEpochHidesPreConnectionSessions() throws {
        let hub = try makeHub()
        _ = try hub.handle(deviceId: "phone", .playbackInfo(
            PlaybackInfo(infoType: .playbackInfo, source: "a", trackTitle: "A", isPlaying: true)
        ))
        // No live connection recorded yet.
        XCTAssertTrue(hub.visiblePlayback(deviceId: "phone").isEmpty)

        // Updated after the connection opened -> visible.
        hub.markPlaybackConnection(deviceId: "phone", connectedAt: Date().addingTimeInterval(-10))
        XCTAssertEqual(hub.visiblePlayback(deviceId: "phone").count, 1)

        // A fresh connection hides the old update until it plays again, but the full snapshot is
        // kept so a transport-only update can still merge into it.
        hub.markPlaybackConnection(deviceId: "phone", connectedAt: Date())
        XCTAssertTrue(hub.visiblePlayback(deviceId: "phone").isEmpty)
        XCTAssertFalse(hub.liveState(deviceId: "phone").playback.isEmpty)
    }

    func testTransportKeyCodes() {
        XCTAssertEqual(MediaKeyEvent.keyCode(for: .play), 126)
        XCTAssertEqual(MediaKeyEvent.keyCode(for: .pause), 127)
        XCTAssertEqual(MediaKeyEvent.keyCode(for: .next), 87)
        XCTAssertEqual(MediaKeyEvent.keyCode(for: .previous), 88)
        XCTAssertNil(MediaKeyEvent.keyCode(for: .seek))
        XCTAssertNil(MediaKeyEvent.keyCode(for: .volumeUpdate))
    }

    private func sampleIconPNG() throws -> Data {
        let size = 64
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func makeHub() throws -> FeatureHub {
        FeatureHub(database: try AppDatabase(inMemory: ()))
    }
}
