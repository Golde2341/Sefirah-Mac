import AppKit
import Foundation
import OSLog
import SefirahCore
import SwiftUI

private let mirrorLaunchLog = Logger(subsystem: "io.github.madeye.sefirah.mac", category: "scrcpy")

/// Polls the general pasteboard's change count and reports when the Mac's clipboard changed, so
/// `AppModel` can push it to the phone in real time. Polling `NSPasteboard.changeCount` (rather than
/// content) is the only dependency-free observation mechanism; reading pasteboard content is deferred
/// until a change is actually detected. Remote clipboard applies (phone → Mac) call
/// `notePasteboardWritten()` so their own write isn't echoed straight back to the phone.
@MainActor
final class ClipboardSyncMonitor {
    private var timer: Timer?
    private var lastHandledChangeCount: Int

    /// Called on the main actor when the Mac clipboard changed and was not written by Sefirah itself.
    var onChange: (() -> Void)?

    init() {
        lastHandledChangeCount = NSPasteboard.general.changeCount
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        lastHandledChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Records the pasteboard revision right after Sefirah itself wrote to it (remote clipboard apply).
    func notePasteboardWritten() {
        lastHandledChangeCount = NSPasteboard.general.changeCount
    }

    private func poll() {
        let changeCount = NSPasteboard.general.changeCount
        guard changeCount != lastHandledChangeCount else { return }
        lastHandledChangeCount = changeCount
        onChange?()
    }
}

@MainActor
@Observable
final class AppModel: PairingDecider {
    var hasCompletedOnboarding: Bool
    var sessionError: String?
    var qrImage: NSImage?
    var qrDeepLink: String = ""
    var discovered: [DiscoveredPeer] = []
    var paired: [ConnectedPeer] = []
    var selectedDeviceID: String?
    var pendingPairing: DiscoveredPeer?
    var notifications: [NotificationSnapshot] = []
    var conversations: [ConversationSnapshot] = []
    var messages: [MessageSnapshot] = []
    var selectedThreadID: Int64?
    var composeText: String = ""
    var callLogs: [CallLogRecord] = []
    var apps: [ApplicationRecord] = []
    var live = DeviceLiveState()
    var general = GeneralSettings()
    var serverPort: Int?
    var incomingCall: CallInfo?
    var showMainWindow = true
    /// Drives the single tool-failure alert in RootView.
    var toolFailure: ToolFailure?
    /// Keys of running scrcpy sessions (device id, or "<device>:<package>").
    var mirroringKeys: Set<String> = []
    /// Keys whose launch is still in the adb phase (before scrcpy has spawned).
    var pendingMirrorKeys: Set<String> = []
    var bundledScrcpyVersion: String? { bundledTools?.version ?? nativeTools?.version }
    var adbRestartResult: String?
    var selectedTab: MainTab = .calls
    /// Native mirror sessions keyed like `mirroringKeys`.
    var mirrors: [String: MirrorController] = [:]
    /// Bumped when per-device settings are saved so views displaying them can refresh.
    private(set) var deviceSettingsRevision = 0

    private var pairingContinuation: CheckedContinuation<Bool, Never>?
    private(set) var session: SessionManager?
    private let database: AppDatabase
    private let hub: FeatureHub
    private let settings: SettingsStore
    private let identity: DeviceIdentity
    private let localDevice: LocalDeviceRecord
    private let bundledTools = BundledTools.locate()
    private let nativeTools = NativeTools.locate()
    private let scrcpyRunner: any ScrcpyRunning = ScrcpyRunnerRouter()
    private let commandRunner: any CommandRunning = ProcessCommandRunner()
    private let macNotifications = MacNotificationDelivery.shared
    private let clipboardMonitor = ClipboardSyncMonitor()
    private var terminateObserver: NSObjectProtocol?
    private var mediaRefreshTask: Task<Void, Never>?
    private var macPlaybackSources: [String: Set<String>] = [:]
    /// Paired-device adb serials, refreshed periodically; media transport prefers these keys.
    private var adbSerials: [String: String] = [:]
    /// "Phone speakers" while the phone's media stream routes to its internal speaker.
    private(set) var phoneMediaOutputLabel: String?
    /// Keys of running dedicated phone-audio sessions ("<device id>:audio").
    private(set) var audioMirrorKeys: Set<String> = []
    /// Keys whose phone-audio launch is still resolving tools/adb.
    private(set) var pendingAudioKeys: Set<String> = []
    /// Audio keys the user stopped on purpose, so their exit is not reported as a failure.
    private var intentionalAudioStops: Set<String> = []
    /// Last audio-device snapshot published per device, so refreshes only send diffs.
    private var publishedAudioDevices: [String: [String: AudioDeviceInfo]] = [:]
    private var maintenanceTask: Task<Void, Never>?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sefirah", isDirectory: true)
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Sefirah")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let loadedSettings = SettingsStore(directory: support.appendingPathComponent("settings"))
        let loadedGeneral = (try? loadedSettings.loadGeneral()) ?? GeneralSettings()

        var startupError: String?
        let db: AppDatabase
        do {
            db = try AppDatabase(fileURL: support.appendingPathComponent(SefirahConstants.databaseFileName))
        } catch {
            db = try! AppDatabase(inMemory: ())
            startupError = "Database: \(error.localizedDescription)"
        }

        let featureHub = FeatureHub(database: db)
        featureHub.actionsCatalog = loadedGeneral.actions

        let store = IdentityStore(directory: support.appendingPathComponent("identity"))
        let loadedIdentity = (try? store.loadOrCreate()) ?? (try! IdentityStore.generate())
        let repo = DeviceRepository(database: db)
        let name = loadedGeneral.localDeviceName.isEmpty
            ? (Host.current().localizedName ?? "Mac")
            : loadedGeneral.localDeviceName
        let loadedLocal = (try? repo.ensureLocalDevice(name: name))
            ?? LocalDeviceRecord(deviceId: UUID().uuidString, deviceName: name)

        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "HasCompletedOnboarding")
        sessionError = startupError
        qrImage = nil
        selectedDeviceID = nil
        pendingPairing = nil
        selectedThreadID = nil
        pairingContinuation = nil
        session = nil
        database = db
        hub = featureHub
        settings = loadedSettings
        identity = loadedIdentity
        localDevice = loadedLocal
        general = loadedGeneral

        do {
            let configuration = SessionConfiguration(
                identity: loadedIdentity,
                localDevice: loadedLocal,
                model: Host.current().localizedName ?? "Mac",
                repository: repo
            )
            let manager = try SessionManager(configuration: configuration)
            manager.pairingDecider = self
            manager.eventHandler = { [weak self] event in
                Task { @MainActor in
                    self?.handle(event)
                }
            }
            session = manager
            serverPort = try manager.startListening()
            try? manager.startDiscovery()
            let payload = try manager.pairingPayload()
            qrDeepLink = try payload.deepLink()
            qrImage = QrCodeImage.make(qrDeepLink)
            if qrImage == nil, sessionError == nil {
                sessionError = "Could not render pairing QR code"
            }
        } catch {
            sessionError = error.localizedDescription
        }

        paired = (try? DeviceRepository(database: db).fetchPairedDevices().map {
            ConnectedPeer(
                id: $0.deviceId,
                name: $0.name,
                model: $0.model,
                address: $0.addresses.first?.address ?? "",
                port: 5150,
                certificateDER: $0.certificate,
                isConnected: false
            )
        }) ?? []
        selectedDeviceID = paired.first?.id
        refreshDevice()

        let runner = scrcpyRunner
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            runner.terminateAll()
            MainActor.assumeIsolated { self?.mirrors.values.forEach { $0.emergencyStop() } }
        }

        if loadedGeneral.restartAdbServerOnLaunch {
            restartAdbServer()
        }

        clipboardMonitor.onChange = { [weak self] in
            self?.sendClipboard()
        }
        if loadedGeneral.syncClipboardToPhone {
            clipboardMonitor.start()
        }

        mediaRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await publishMacPlaybackMetadata(to: paired.filter(\.isConnected).map(\.id))
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        maintenanceTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshAdbOnlineState()
                await self.refreshPhoneMediaOutput()
                self.publishAudioDevices(to: self.paired.filter(\.isConnected).map(\.id))
                var pruned = false
                for device in self.paired {
                    pruned = self.hub.prunePausedPlayback(deviceId: device.id, maxAge: 600) || pruned
                }
                if pruned { self.refreshDevice() }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    var selectedDevice: ConnectedPeer? {
        paired.first { $0.id == selectedDeviceID }
    }

    /// Playback sessions that started after the current connection (used by the rail and menu bar).
    var visiblePlayback: [PlaybackInfo] {
        guard let deviceID = selectedDeviceID else { return [] }
        return hub.visiblePlayback(deviceId: deviceID)
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: "HasCompletedOnboarding")
        showMainWindow = true
    }

    func pair(_ peer: DiscoveredPeer) {
        session?.pair(deviceId: peer.id)
    }

    func reconnect(_ peer: ConnectedPeer) {
        connectNow(peer)
        session?.reconnectPairedDevices()
        // adb shell works even when the companion app isn't running: wake it in the background and
        // retry the TLS dial once it has had a moment to start its network service.
        Task { [weak self] in
            guard let self else { return }
            _ = await self.wakePhone(peer)
            if self.paired.first(where: { $0.id == peer.id })?.isConnected != true {
                self.connectNow(peer)
            }
        }
    }

    /// Menu-bar action: wakes the selected phone in the background over adb and reconnects.
    func reconnectSelectedDevice() {
        guard let peer = selectedDevice else { return }
        reconnect(peer)
    }

    /// Selects a paired device from the menu bar dropdown and refreshes its cached data.
    func selectDevice(_ id: String) {
        guard selectedDeviceID != id else { return }
        selectedDeviceID = id
        refreshDevice()
    }

    private func connectNow(_ peer: ConnectedPeer) {
        if let host = PeerAddress.reconnectable(peer.address) {
            session?.connect(deviceId: peer.id, host: host, port: peer.port)
        }
    }

    private enum CompanionWakeResult {
        case woke
        /// `adb devices` lists the phone as offline: retrying won't help.
        case deviceOffline
        case failed
    }

    /// Asks the phone's companion app to start in the background over adb (its exported
    /// `NetworkService` handles a `CONNECT` action) and pauses so a following dial has a chance.
    /// Best effort: any adb problem is logged and the caller's normal reconnect still stands.
    private func wakePhone(_ peer: ConnectedPeer) async -> CompanionWakeResult {
        guard let adb = resolvedAdb else { return .failed }
        var env = ProcessInfo.processInfo.environment
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if env["PATH"] == nil { env["PATH"] = ScrcpyLaunchPlanner.defaultPath }
        let client = AdbClient(adb: adb, environment: env, runner: commandRunner)

        if let devices = try? await client.devices(), devices.contains(where: { device in
            device.state == "offline"
                && (device.serial == "\(peer.address):5555"
                    || AdbOutput.modelMatches(adbModel: device.model, peerModel: peer.model))
        }) {
            mirrorLaunchLog.info("Wake skipped: \(peer.name, privacy: .public) is offline in adb")
            return .deviceOffline
        }

        do {
            try await client.wakeCompanion(host: peer.address, model: peer.model)
            mirrorLaunchLog.info("Woke \(peer.name, privacy: .public) via adb")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return .woke
        } catch {
            mirrorLaunchLog.info("Companion wake skipped: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    /// Auto-connect: after a drop, wake the phone over adb and dial again after each wake. Makes a
    /// second attempt 5 s later unless the first look at adb already showed the phone offline, in
    /// which case retrying would not help.
    private func autoReconnect(deviceId: String) {
        guard general.autoReconnect, let peer = paired.first(where: { $0.id == deviceId }) else { return }
        Task { [weak self] in
            guard let self else { return }
            let first = await self.wakePhone(peer)
            guard first != .deviceOffline else { return }
            self.connectNow(peer)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard self.paired.first(where: { $0.id == peer.id })?.isConnected != true else { return }
            _ = await self.wakePhone(peer)
            self.connectNow(peer)
        }
    }

    /// Unpairs a device: stops its mirrors, tells the phone we're unpairing (best effort, only
    /// when connected), withdraws its delivered macOS notifications, then drops the pairing
    /// record, cached data and per-device settings. Falls back to another device if this one
    /// was selected — re-pairing is required to connect again.
    func forget(_ peer: ConnectedPeer) {
        stopMirrors(deviceId: peer.id)
        session?.send(to: peer.id, .pairMessage(PairMessage(pair: false)))
        session?.disconnect(deviceId: peer.id, forced: true)
        for notification in (try? hub.notifications(deviceId: peer.id)) ?? [] {
            macNotifications.remove(notificationKey: notification.notificationKey, from: peer.id)
        }
        try? DeviceRepository(database: database).deletePairedDevice(id: peer.id)
        try? hub.forgetDevice(deviceId: peer.id)
        try? settings.deleteDevice(id: peer.id)
        paired.removeAll { $0.id == peer.id }
        if selectedDeviceID == peer.id {
            selectedDeviceID = paired.first?.id
            refreshDevice()
        }
    }

    private func upsertPaired(_ peer: ConnectedPeer) {
        if let index = paired.firstIndex(where: { $0.id == peer.id }) {
            paired[index] = peer
            return
        }
        paired.removeAll { $0.id == peer.id }
        paired.append(peer)
        // A newly paired phone inherits the settings of the phone already configured (the unlock
        // commands stay device-specific, since the PIN/pattern is per phone).
        try? settings.seedDevice(id: peer.id, from: selectedDeviceID)
    }

    func acceptPendingPair() {
        pairingContinuation?.resume(returning: true)
        pairingContinuation = nil
        pendingPairing = nil
    }

    func declinePendingPair() {
        pairingContinuation?.resume(returning: false)
        pairingContinuation = nil
        pendingPairing = nil
    }

    func acceptPairing(_ peer: DiscoveredPeer) async -> Bool {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.pendingPairing = peer
                self.pairingContinuation = continuation
            }
        }
    }

    func replyToNotification(_ note: NotificationSnapshot, text: String) {
        guard let key = note.replyResultKey else { return }
        session?.send(to: note.deviceId, hub.reply(deviceId: note.deviceId, notificationKey: note.notificationKey, replyResultKey: key, text: text))
    }

    func invokeNotification(_ note: NotificationSnapshot, action: NotificationAction) {
        session?.send(
            to: note.deviceId,
            hub.invokeAction(deviceId: note.deviceId, notificationKey: note.notificationKey, index: action.actionIndex, label: action.label ?? "")
        )
    }

    func sendSms() {
        guard let deviceID = selectedDeviceID, let thread = selectedThreadID, !composeText.isEmpty else { return }
        let conversation = conversations.first { $0.threadId == thread }
        let message = hub.sendSms(threadId: thread, addresses: conversation?.addresses ?? [], body: composeText)
        session?.send(to: deviceID, message)
        composeText = ""
    }

    func findPhone() {
        toggleFindPhone(start: true)
    }

    func toggleFindPhone(start: Bool? = nil) {
        guard let deviceID = selectedDeviceID else { return }
        let playing = start ?? !live.soundPlaying
        session?.send(to: deviceID, hub.playSound(isPlaying: playing))
        live.soundPlaying = playing
    }

    func toggleDnd() {
        guard let deviceID = selectedDeviceID else { return }
        let enabled = !(live.dndEnabled ?? false)
        session?.send(to: deviceID, .dndState(DndState(isEnabled: enabled)))
        live.dndEnabled = enabled
    }

    func setRingerMode(_ mode: Int) {
        guard let deviceID = selectedDeviceID else { return }
        session?.send(to: deviceID, hub.setRingerMode(mode))
        live.ringerMode = mode
    }

    func setAudioLevel(_ streamType: AudioStreamType, level: Int) {
        guard let deviceID = selectedDeviceID else { return }
        session?.send(to: deviceID, hub.setAudioLevel(streamType, level: level))
        live.audioStreams[streamType] = level
    }

    func sendMediaAction(_ type: MediaActionType, source: String, value: Double? = nil) {
        guard let deviceID = selectedDeviceID else { return }
        let action = hub.mediaAction(type, source: source, value: value)
        // With the phone reachable over adb, transport keys go through `input keyevent` — the
        // companion app cannot dispatch media sessions while the screen is off.
        if MediaKeyEvent.keyCode(for: type) != nil, adbSerials[deviceID] != nil,
           let peer = paired.first(where: { $0.id == deviceID })
        {
            Task { [weak self] in
                guard let self else { return }
                if await self.sendMediaKeyEvent(type, device: peer) == false {
                    self.session?.send(to: deviceID, action)
                }
            }
        } else {
            session?.send(to: deviceID, action)
        }
        if let index = live.playback.firstIndex(where: { $0.source == source }) {
            switch type {
            case .play: live.playback[index].isPlaying = true
            case .pause, .stop: live.playback[index].isPlaying = false
            case .volumeUpdate:
                if let value { live.playback[index].volume = Int(value) }
            case .seek:
                if let value { live.playback[index].position = value }
            default: break
            }
        }
    }

    /// Sends a transport key code over adb. Returns false when adb could not deliver it, so the
    /// caller can fall back to the companion app.
    private func sendMediaKeyEvent(_ type: MediaActionType, device: ConnectedPeer) async -> Bool {
        guard let adb = resolvedAdb,
              let serial = adbSerials[device.id],
              let keyCode = MediaKeyEvent.keyCode(for: type)
        else { return false }
        var env = ProcessInfo.processInfo.environment
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if env["PATH"] == nil { env["PATH"] = ScrcpyLaunchPlanner.defaultPath }
        let client = AdbClient(adb: adb, environment: env, runner: commandRunner)
        do {
            let result = try await client.shell(serial: serial, ["input", "keyevent", String(keyCode)], timeout: 5)
            guard result.exitCode == 0 else {
                adbSerials[device.id] = nil
                return false
            }
            return true
        } catch {
            adbSerials[device.id] = nil
            return false
        }
    }

    /// Checks the phone's active media output route over adb (`dumpsys audio`) so the menu bar
    /// player can say "Phone speakers" when the internal speaker is in use.
    private func refreshPhoneMediaOutput() async {
        guard let deviceID = selectedDeviceID,
              let serial = adbSerials[deviceID],
              let adb = resolvedAdb,
              !visiblePlayback.isEmpty
        else {
            phoneMediaOutputLabel = nil
            return
        }
        var env = ProcessInfo.processInfo.environment
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if env["PATH"] == nil { env["PATH"] = ScrcpyLaunchPlanner.defaultPath }
        let client = AdbClient(adb: adb, environment: env, runner: commandRunner)
        guard let result = try? await client.shell(serial: serial, ["dumpsys", "audio"], timeout: 8),
              result.exitCode == 0
        else {
            phoneMediaOutputLabel = nil
            return
        }
        phoneMediaOutputLabel = PhoneAudioRoute.label(fromDumpsysAudio: result.stdout)
    }

    /// Publishes this Mac's audio output devices (volume, mute, default) so the phone's
    /// remote-playback UI can control them — the desktop `AudioFeature` equivalent.
    func publishAudioDevices(to deviceIDs: [String]) {
        guard !deviceIDs.isEmpty else { return }
        let devices = MacAudioController.outputDevices()
        for deviceID in deviceIDs where deviceSettings(for: deviceID).audioSync {
            var previous = publishedAudioDevices[deviceID] ?? [:]
            var current: [String: AudioDeviceInfo] = [:]
            for device in devices {
                let info = AudioDeviceInfo(
                    infoType: .new,
                    deviceId: device.uid,
                    deviceName: device.name,
                    volume: device.volume,
                    isMuted: device.isMuted,
                    isSelected: device.isDefault
                )
                current[device.uid] = info
                if let old = previous[device.uid] {
                    if old.volume != info.volume || old.isMuted != info.isMuted
                        || old.isSelected != info.isSelected || old.deviceName != info.deviceName
                    {
                        session?.send(to: deviceID, .audioDeviceInfo(
                            AudioDeviceInfo(
                                infoType: .active,
                                deviceId: info.deviceId,
                                deviceName: info.deviceName,
                                volume: info.volume,
                                isMuted: info.isMuted,
                                isSelected: info.isSelected
                            )
                        ))
                    }
                } else {
                    session?.send(to: deviceID, .audioDeviceInfo(info))
                }
            }
            for (uid, old) in previous where current[uid] == nil {
                session?.send(to: deviceID, .audioDeviceInfo(
                    AudioDeviceInfo(
                        infoType: .removed,
                        deviceId: uid,
                        deviceName: old.deviceName,
                        volume: old.volume,
                        isMuted: old.isMuted,
                        isSelected: false
                    )
                ))
            }
            previous = current
            publishedAudioDevices[deviceID] = previous
        }
    }

    /// Applies a volume/mute/default-device request from the phone.
    private func applyAudioAction(_ action: AudioAction) {
        let uid = action.source.isEmpty ? nil : action.source
        switch action.actionType {
        case .volumeUpdate:
            if let value = action.value {
                MacAudioController.setVolume(uid: uid, to: value)
            }
        case .toggleMute:
            MacAudioController.toggleMute(uid: uid)
        case .defaultDevice:
            MacAudioController.setDefaultOutput(uid: action.source)
        }
    }

    /// Re-checks which paired phones currently show up in `adb devices`.
    private func refreshAdbOnlineState() async {
        guard let adb = resolvedAdb, !paired.isEmpty else {
            adbSerials = [:]
            return
        }
        var env = ProcessInfo.processInfo.environment
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if env["PATH"] == nil { env["PATH"] = ScrcpyLaunchPlanner.defaultPath }
        let client = AdbClient(adb: adb, environment: env, runner: commandRunner)
        guard let devices = try? await client.devices() else {
            adbSerials = [:]
            return
        }
        let online = devices.filter { $0.state == "device" }
        var serials: [String: String] = [:]
        for peer in paired {
            let match = online.first { device in
                device.serial == "\(peer.address):5555"
                    || (device.isTcp && device.serial.hasPrefix("\(peer.address):"))
                    || AdbOutput.modelMatches(adbModel: device.model, peerModel: peer.model)
            }
            if let match { serials[peer.id] = match.serial }
        }
        adbSerials = serials
    }

    func sendClipboard() {
        guard let deviceID = selectedDeviceID else { return }
        let pasteboard = NSPasteboard.general
        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:])
        {
            session?.send(to: deviceID, hub.clipboard(type: "image/png", content: png.base64EncodedString()))
            return
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        session?.send(to: deviceID, hub.clipboard(type: "text/plain", content: text))
    }

    func launchScrcpy(package: String? = nil, appName: String? = nil) {
        Task { await launchScrcpyAsync(package: package, appName: appName) }
    }

    func launchScrcpyAsync(package: String? = nil, appName: String? = nil) async {
        guard let device = selectedDevice else { return }
        let key = package.map { "\(device.id):\($0)" } ?? device.id
        // Ignore re-entrant launches while the adb phase is still running for this key.
        guard !pendingMirrorKeys.contains(key) else { return }
        pendingMirrorKeys.insert(key)
        defer { pendingMirrorKeys.remove(key) }
        let deviceSettings = (try? settings.loadDevice(id: device.id)) ?? DeviceSettings(deviceId: device.id)
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let general = self.general
        let bundledTools = self.bundledTools
        func makePlan(_ serial: String?) throws -> ScrcpyLaunchPlan {
            try ScrcpyLaunchPlanner.plan(
                general: general, device: deviceSettings, bundled: bundledTools,
                serial: serial, package: package, appName: appName,
                baseEnvironment: env, home: home,
                isExecutable: { FileManager.default.isExecutableFile(atPath: $0.path) }
            )
        }

        // Resolve tools first with serial nil so tool errors surface before any adb call.
        let base: ScrcpyLaunchPlan
        do {
            base = try makePlan(nil)
        } catch {
            toolFailure = ToolFailure(
                title: "Screen mirroring unavailable",
                message: error.localizedDescription,
                detail: "Bundled scrcpy: \(bundledScrcpyVersion ?? "missing")",
                retryAction: { [weak self] in
                    self?.launchScrcpy(package: package, appName: appName)
                }
            )
            return
        }

        // Optional Wi-Fi connect + serial selection.
        let adbClient = base.adb.map { AdbClient(adb: $0, environment: base.environment, runner: commandRunner) }
        var serial: String?
        if let client = adbClient {
            if deviceSettings.adbTcpipModeEnabled {
                do {
                    serial = try await client.tryConnectTcp(host: device.address, model: device.model)
                } catch {
                    toolFailure = ToolFailure(
                        title: "Could not reach \(device.name) over ADB",
                        message: error.localizedDescription,
                        detail: "Enable Wireless debugging, or connect once over USB so Sefirah can switch the phone to TCP/IP mode.",
                        retryAction: { [weak self] in
                            self?.launchScrcpy(package: package, appName: appName)
                        }
                    )
                    return
                }
            } else if let devices = try? await client.devices() {
                serial = ScrcpyDeviceSelection.serial(
                    devices: devices, peerModel: device.model, preference: deviceSettings.scrcpyDevicePreference
                )
            } // adb listing failures are non-fatal here; scrcpy reports its own error which we surface on exit.
        }

        // Unlock-before-launch (parity with MirrorSession.run): wake/unlock the phone before scrcpy
        // spawns. Best effort — a failing command is logged and the launch continues, and launcher
        // arguments (window, size) are unchanged.
        if deviceSettings.unlockDeviceBeforeLaunch {
            if let client = adbClient {
                let lockedSerial = serial
                do {
                    try await UnlockCommandRunner.run(
                        commands: deviceSettings.unlockCommands,
                        warn: { mirrorLaunchLog.warning("\($0, privacy: .public)") },
                        shell: { command in
                            if let lockedSerial { try await client.shell(serial: lockedSerial, [command]) }
                            else { try await client.shell([command]) }
                        }
                    )
                } catch {
                    return // task cancelled while unlocking; do not spawn scrcpy
                }
            } else {
                mirrorLaunchLog.warning("Unlock commands skipped: no adb tool is available to the external backend")
            }
        }

        let plan: ScrcpyLaunchPlan
        if let serial, let withSerial = try? makePlan(serial) { plan = withSerial } else { plan = base }
        do {
            try scrcpyRunner.launch(plan, key: key) { [weak self] exit in
                Task { @MainActor in self?.handleScrcpyExit(exit, key: key, plan: plan, package: package, appName: appName) }
            }
            mirroringKeys.insert(key)
        } catch {
            toolFailure = ToolFailure(
                title: "Could not start scrcpy",
                message: error.localizedDescription,
                detail: plan.executable.path,
                retryAction: { [weak self] in
                    self?.launchScrcpy(package: package, appName: appName)
                }
            )
        }
    }

    private func handleScrcpyExit(_ exit: ScrcpyExit, key: String, plan: ScrcpyLaunchPlan, package: String?, appName: String?) {
        // A relaunch with the same key terminates the previous process; the runner already
        // tracks the replacement, so this exit belongs to the old one and must not clear the key.
        guard !scrcpyRunner.runningKeys.contains(key) else { return }
        mirroringKeys.remove(key)
        switch exit {
        case .normal:
            return
        case .failure(let code, let stderr), .signaled(let code, let stderr):
            toolFailure = ToolFailure(
                title: "scrcpy exited (code \(code))",
                message: ScrcpyDiagnostics.hint(exit: exit) ?? "scrcpy reported an error.",
                detail: stderr.isEmpty ? plan.executable.path : stderr,
                retryAction: { [weak self] in
                    self?.launchScrcpy(package: package, appName: appName)
                }
            )
        case .reported(let stderr):
            toolFailure = ToolFailure(
                title: "scrcpy reported an error",
                message: ScrcpyDiagnostics.hint(exit: exit) ?? "scrcpy exited with an error.",
                detail: stderr.isEmpty ? plan.executable.path : stderr,
                retryAction: { [weak self] in
                    self?.launchScrcpy(package: package, appName: appName)
                }
            )
        }
    }

    // MARK: - Phone audio → Mac

    private func phoneAudioKey(_ deviceID: String) -> String { "\(deviceID):audio" }

    func isPhoneAudioMirroring(deviceID: String) -> Bool {
        let key = phoneAudioKey(deviceID)
        return audioMirrorKeys.contains(key) || scrcpyRunner.runningKeys.contains(key)
    }

    /// True while the selected phone's audio is being played on this Mac.
    var isPhoneAudioActive: Bool {
        guard let id = selectedDeviceID else { return false }
        return isPhoneAudioMirroring(deviceID: id)
    }

    /// True while the selected phone's audio session is still starting.
    var isPhoneAudioPending: Bool {
        guard let id = selectedDeviceID else { return false }
        return pendingAudioKeys.contains(phoneAudioKey(id))
    }

    /// Menu-bar "phone speaker" toggle: forwards the phone's audio to this Mac (320 kbit/s, 500 ms
    /// buffer, no video) on the first tap and stops it on the next.
    func togglePhoneAudio() {
        guard let device = selectedDevice else { return }
        let key = phoneAudioKey(device.id)
        if audioMirrorKeys.contains(key) || scrcpyRunner.runningKeys.contains(key) {
            intentionalAudioStops.insert(key)
            scrcpyRunner.terminate(key: key)
            audioMirrorKeys.remove(key)
        } else {
            startPhoneAudio(device: device)
        }
    }

    private func startPhoneAudio(device: ConnectedPeer) {
        let key = phoneAudioKey(device.id)
        guard !pendingAudioKeys.contains(key),
              !audioMirrorKeys.contains(key),
              !scrcpyRunner.runningKeys.contains(key)
        else { return }
        pendingAudioKeys.insert(key)
        Task { [weak self] in
            guard let self else { return }
            await self.launchPhoneAudioAsync(device: device, key: key)
            self.pendingAudioKeys.remove(key)
        }
    }

    private func launchPhoneAudioAsync(device: ConnectedPeer, key: String) async {
        let deviceSettings = (try? settings.loadDevice(id: device.id)) ?? DeviceSettings(deviceId: device.id)
        let general = self.general
        let bundledTools = self.bundledTools
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        func makePlan(_ serial: String?) throws -> ScrcpyLaunchPlan {
            try ScrcpyLaunchPlanner.plan(
                general: general, device: deviceSettings, bundled: bundledTools,
                serial: serial, audioOnly: true,
                baseEnvironment: env, home: home,
                isExecutable: { FileManager.default.isExecutableFile(atPath: $0.path) }
            )
        }

        // Resolve tools first so tool errors surface before any adb call.
        let base: ScrcpyLaunchPlan
        do {
            base = try makePlan(nil)
        } catch {
            toolFailure = ToolFailure(
                title: "Phone audio unavailable",
                message: error.localizedDescription,
                detail: "Bundled scrcpy: \(bundledScrcpyVersion ?? "missing")"
            )
            return
        }

        // Reuse the periodic adb snapshot when available; otherwise connect/select like the mirror.
        var serial: String? = adbSerials[device.id]
        if serial == nil,
           let client = base.adb.map({ AdbClient(adb: $0, environment: base.environment, runner: commandRunner) })
        {
            if deviceSettings.adbTcpipModeEnabled {
                serial = try? await client.tryConnectTcp(host: device.address, model: device.model)
            } else if let devices = try? await client.devices() {
                serial = ScrcpyDeviceSelection.serial(
                    devices: devices, peerModel: device.model, preference: deviceSettings.scrcpyDevicePreference
                )
            }
        }

        let plan = serial.flatMap { try? makePlan($0) } ?? base
        do {
            try scrcpyRunner.launch(plan, key: key) { [weak self] exit in
                Task { @MainActor in
                    self?.handlePhoneAudioExit(exit, key: key, deviceID: device.id)
                }
            }
            audioMirrorKeys.insert(key)
        } catch {
            toolFailure = ToolFailure(
                title: "Could not start phone audio",
                message: error.localizedDescription,
                detail: plan.executable.path
            )
        }
    }

    private func handlePhoneAudioExit(_ exit: ScrcpyExit, key: String, deviceID: String) {
        // A relaunch with the same key terminates the previous process; ignore the stale exit.
        guard !scrcpyRunner.runningKeys.contains(key) else { return }
        audioMirrorKeys.remove(key)
        if intentionalAudioStops.remove(key) != nil { return }
        switch exit {
        case .normal:
            return
        case .failure(let code, let stderr), .signaled(let code, let stderr):
            toolFailure = ToolFailure(
                title: "Phone audio stopped (code \(code))",
                message: ScrcpyDiagnostics.hint(exit: exit) ?? "scrcpy reported an error.",
                detail: stderr,
                retryAction: { [weak self] in self?.retryPhoneAudio(deviceID: deviceID) }
            )
        case .reported(let stderr):
            toolFailure = ToolFailure(
                title: "Phone audio reported an error",
                message: ScrcpyDiagnostics.hint(exit: exit) ?? "scrcpy exited with an error.",
                detail: stderr,
                retryAction: { [weak self] in self?.retryPhoneAudio(deviceID: deviceID) }
            )
        }
    }

    private func retryPhoneAudio(deviceID: String) {
        guard let device = paired.first(where: { $0.id == deviceID }) else { return }
        startPhoneAudio(device: device)
    }

    func stopMirroring(key: String? = nil) {
        if let key {
            if audioMirrorKeys.contains(key) { intentionalAudioStops.insert(key) }
            scrcpyRunner.terminate(key: key)
            audioMirrorKeys.remove(key)
        } else {
            intentionalAudioStops.formUnion(audioMirrorKeys)
            scrcpyRunner.terminateAll()
            audioMirrorKeys.removeAll()
        }
    }

    // MARK: - Native mirror

    /// Launcher apps without the hidden ones; hidden apps live in `hiddenApps` behind
    /// device-owner authentication.
    var sortedApps: [ApplicationRecord] {
        let recentPositions = Dictionary(
            uniqueKeysWithValues: general.recentlyOpenedAppKeys.enumerated().map { ($0.element, $0.offset) }
        )

        return apps.filter { !$0.hidden }.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned {
                return lhs.pinned
            }

            let lhsRecentPosition = recentPositions[lhs.appKey]
            let rhsRecentPosition = recentPositions[rhs.appKey]
            if let lhsRecentPosition, let rhsRecentPosition, lhsRecentPosition != rhsRecentPosition {
                return lhsRecentPosition < rhsRecentPosition
            }
            if lhsRecentPosition != nil {
                return true
            }
            if rhsRecentPosition != nil {
                return false
            }
            return lhs.appName.localizedStandardCompare(rhs.appName) == .orderedAscending
        }
    }

    /// Recent apps for the menu bar; hidden apps never surface here.
    var recentlyOpenedApps: [ApplicationRecord] {
        general.recentlyOpenedAppKeys
            .compactMap { key in apps.first { $0.appKey == key && !$0.hidden } }
            .prefix(8)
            .map { $0 }
    }

    /// Apps the user hid from the launcher list; revealed in the Apps tab behind device-owner
    /// authentication (password or biometrics).
    var hiddenApps: [ApplicationRecord] {
        apps.filter(\.hidden)
            .sorted { $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }
    }

    func togglePinnedApp(_ app: ApplicationRecord) {
        let isPinned = !app.pinned
        guard (try? hub.setAppPinned(
            deviceId: app.deviceId,
            packageName: app.packageName,
            isPinned: isPinned
        )) != nil else { return }

        if let index = apps.firstIndex(where: { $0.appKey == app.appKey }) {
            apps[index].pinned = isPinned
        }
    }

    func setAppHidden(_ app: ApplicationRecord, isHidden: Bool) {
        guard (try? hub.setAppHidden(
            deviceId: app.deviceId,
            packageName: app.packageName,
            isHidden: isHidden
        )) != nil else { return }

        if let index = apps.firstIndex(where: { $0.appKey == app.appKey }) {
            apps[index].hidden = isHidden
        }
        if isHidden {
            // Hidden apps are muted until their notifications are explicitly allowed.
            withdrawBanners(forPackage: app.packageName, deviceId: app.deviceId)
        }
        if app.deviceId == selectedDeviceID {
            refreshDevice()
        }
    }

    /// Hidden apps keep their notifications muted; this per-app switch (behind device-owner
    /// authentication in Settings) lets them through while the app stays hidden in the Apps tab.
    func setAppHiddenNotificationsEnabled(_ app: ApplicationRecord, isEnabled: Bool) {
        guard (try? hub.setAppHiddenNotificationsEnabled(
            deviceId: app.deviceId,
            packageName: app.packageName,
            isEnabled: isEnabled
        )) != nil else { return }

        if let index = apps.firstIndex(where: { $0.appKey == app.appKey }) {
            apps[index].hiddenNotifications = isEnabled
        }
        if app.deviceId == selectedDeviceID {
            if !isEnabled {
                withdrawBanners(forPackage: app.packageName, deviceId: app.deviceId)
            }
            refreshDevice()
        }
    }

    /// Changes one app's notification level: `toastFeed` (banner + rail), `feed` (muted — rail
    /// only) or `disabled` (hidden entirely).
    func setAppNotificationFilter(_ app: ApplicationRecord, filter: NotificationFilter) {
        guard (try? hub.setAppNotificationFilter(
            deviceId: app.deviceId,
            packageName: app.packageName,
            filter: filter
        )) != nil else { return }

        if let index = apps.firstIndex(where: { $0.appKey == app.appKey }) {
            apps[index].filter = filter
        }
        if app.deviceId == selectedDeviceID {
            if filter != .toastFeed {
                withdrawBanners(forPackage: app.packageName, deviceId: app.deviceId)
            }
            refreshDevice()
        }
    }

    func setAppNotificationsEnabled(_ app: ApplicationRecord, isEnabled: Bool) {
        setAppNotificationFilter(app, filter: isEnabled ? .toastFeed : .disabled)
    }

    /// Withdraws already-delivered macOS banners for one app once it is muted or hidden.
    private func withdrawBanners(forPackage package: String, deviceId: String) {
        for note in notifications where note.appPackage == package {
            macNotifications.remove(notificationKey: note.notificationKey, from: deviceId)
        }
    }

    /// The app record behind a mirrored notification, when the phone's app list knows the package.
    func notificationApp(_ note: NotificationSnapshot) -> ApplicationRecord? {
        apps.first { $0.deviceId == note.deviceId && $0.packageName == note.appPackage }
    }

    /// Notification-card menu: toast / silent / hidden for the app behind the notification.
    /// Packages with no app-list entry (system components like `android`) get a placeholder record
    /// so the choice persists and can be managed in notification settings.
    func setNotificationFilter(_ note: NotificationSnapshot, filter: NotificationFilter) {
        if let app = notificationApp(note) {
            setAppNotificationFilter(app, filter: filter)
            return
        }
        guard filter != .toastFeed else { return }
        guard (try? hub.setNotificationOnlyAppFilter(
            deviceId: note.deviceId,
            packageName: note.appPackage,
            appName: note.appName,
            filter: filter
        )) != nil else { return }
        withdrawBanners(forPackage: note.appPackage, deviceId: note.deviceId)
        if note.deviceId == selectedDeviceID {
            refreshDevice()
        }
    }

    /// Apps whose notifications are currently silenced — muted apps plus hidden apps that haven't
    /// been allowed to notify. Listed in the Touch ID–locked "Hidden Notifications" settings.
    var hiddenNotificationApps: [ApplicationRecord] {
        apps.filter { $0.filter == .disabled || ($0.hidden && !$0.hiddenNotifications) }
            .sorted { $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }
    }

    /// Shows or hides one app's notifications from the locked "Hidden Notifications" sheet. An app
    /// hidden in the Apps tab stays hidden — only its notifications are switched.
    func setNotificationSuppressed(_ app: ApplicationRecord, isSuppressed: Bool) {
        if isSuppressed {
            if app.hidden {
                setAppHiddenNotificationsEnabled(app, isEnabled: false)
            } else {
                setAppNotificationsEnabled(app, isEnabled: false)
            }
            return
        }
        if app.filter == .disabled {
            setAppNotificationsEnabled(app, isEnabled: true)
        }
        if app.hidden, !app.hiddenNotifications {
            setAppHiddenNotificationsEnabled(app, isEnabled: true)
        }
    }

    func setAllAppNotificationsEnabled(_ isEnabled: Bool) {
        for app in apps {
            setAppNotificationsEnabled(app, isEnabled: isEnabled)
        }
    }

    /// Deletes one mirrored notification from the feed, withdraws its delivered banner, and asks
    /// the phone to cancel it in its shade too.
    func deleteNotification(_ note: NotificationSnapshot) {
        macNotifications.remove(notificationKey: note.notificationKey, from: note.deviceId)
        _ = try? hub.removeNotification(deviceId: note.deviceId, notificationKey: note.notificationKey)
        session?.send(to: note.deviceId, hub.dismissNotification(notificationKey: note.notificationKey))
        if note.deviceId == selectedDeviceID {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                refreshDevice()
            }
        }
    }

    /// Clears the mirrored notification feed for the selected device, withdrawing its delivered
    /// macOS banners, and dismisses the notifications on the phone too.
    func clearAllNotifications() {
        guard let deviceID = selectedDeviceID else { return }
        for note in notifications {
            macNotifications.remove(notificationKey: note.notificationKey, from: deviceID)
        }
        _ = try? hub.handle(deviceId: deviceID, .clearNotifications)
        session?.send(to: deviceID, .clearNotifications)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            refreshDevice()
        }
    }

    /// Dispatches to the native session or the external scrcpy window per `general.mirrorBackend`.
    func startMirror(package: String? = nil, appName: String? = nil) {
        if let package {
            recordRecentlyOpenedApp(packageName: package)
        }

        if general.mirrorBackend == .external {
            launchScrcpy(package: package, appName: appName)
            return
        }
        Task { await startNativeMirrorAsync(package: package, appName: appName) }
    }

    func mirrorController(for key: String) -> MirrorController? {
        mirrors[key]
    }

    private func recordRecentlyOpenedApp(packageName: String) {
        guard let app = apps.first(where: { $0.packageName == packageName }) else { return }

        general.recentlyOpenedAppKeys.removeAll { $0 == app.appKey }
        general.recentlyOpenedAppKeys.insert(app.appKey, at: 0)
        general.recentlyOpenedAppKeys = Array(general.recentlyOpenedAppKeys.prefix(8))
        saveGeneral()
    }

    /// Key of the session shown in the Mirror tab (set when a session starts or the user picks one).
    var focusedMirrorKey: String?

    /// Live (non-idle) native sessions of a device: the device mirror first, then per-app sessions by key.
    func mirrorSessions(for deviceId: String) -> [MirrorController] {
        mirrors.values
            .filter { $0.deviceId == deviceId && $0.state != .idle }
            .sorted { ($0.package == nil ? 0 : 1, $0.key) < ($1.package == nil ? 0 : 1, $1.key) }
    }

    /// The session the Mirror tab shows for the selected device: the focused one when live, else the first live session.
    var displayedMirrorController: MirrorController? {
        guard let id = selectedDeviceID else { return nil }
        let sessions = mirrorSessions(for: id)
        if let key = focusedMirrorKey, let focused = sessions.first(where: { $0.key == key }) { return focused }
        return sessions.first
    }

    /// The streaming session of the selected device (the displayed one first, then any other streaming session).
    var activeMirrorController: MirrorController? {
        guard let id = selectedDeviceID else { return nil }
        if let shown = displayedMirrorController, shown.state == .streaming { return shown }
        return mirrorSessions(for: id).first { $0.state == .streaming }
    }

    /// - Parameter reusing: an existing (inactive) controller to restart in place — the automatic
    ///   reconnect path, which must re-resolve the serial (`adb connect` after a Wi-Fi drop).
    func startNativeMirrorAsync(package: String? = nil, appName: String? = nil, reusing: MirrorController? = nil) async {
        guard let device = selectedDevice else { return }
        let key = package.map { "\(device.id):\($0)" } ?? device.id
        guard !pendingMirrorKeys.contains(key) else { return }
        if let reusing, reusing.key != key { return }   // selection changed while reconnecting
        if let existing = mirrors[key], existing.isActive { return }
        pendingMirrorKeys.insert(key)
        defer { pendingMirrorKeys.remove(key) }

        let controller = reusing ?? MirrorController(key: key, deviceId: device.id, title: appName ?? device.name, package: package)
        mirrors[key] = controller
        if reusing == nil {
            focusedMirrorKey = key
            selectedTab = .mirror
        }

        let deviceSettings = deviceSettings(for: device.id)
        controller.preferences = MirrorController.Preferences(
            clipboardReceive: deviceSettings.clipboardReceive,
            showClipboardToast: deviceSettings.showClipboardToast,
            physicalKeyboard: deviceSettings.physicalKeyboard,
            forwardHover: deviceSettings.forwardHover,
            flexDisplay: package != nil && deviceSettings.isVirtualDisplayEnabled && deviceSettings.flexDisplay,
            maxSize: Int(deviceSettings.videoResolution.trimmingCharacters(in: .whitespaces)) ?? 0
        )
        let deviceId = device.id
        controller.isDeviceOnline = { [weak self] in
            self?.paired.contains { $0.id == deviceId && $0.isConnected } ?? false
        }
        controller.relaunch = { [weak self, weak controller] in
            guard let self, let controller else { return }
            await self.startNativeMirrorAsync(package: package, appName: appName, reusing: controller)
        }
        controller.onFailed = { [weak self] error in
            self?.fallbackToExternalIfEnabled(after: error, key: key, package: package, appName: appName)
        }
        controller.onRemoteClipboardApplied = { [weak self] in
            self?.clipboardMonitor.notePasteboardWritten()
        }
        guard let tools = nativeTools else {
            controller.fail(.toolsMissing)
            return
        }
        var env = ProcessInfo.processInfo.environment
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if env["PATH"] == nil { env["PATH"] = ScrcpyLaunchPlanner.defaultPath }
        let adbURL = resolvedAdb ?? tools.adb
        let client = AdbClient(adb: adbURL, environment: env, runner: commandRunner)

        // Resolve the serial exactly like the external launch, but the native session needs one.
        let serial: String
        do {
            if deviceSettings.adbTcpipModeEnabled {
                serial = try await client.tryConnectTcp(host: device.address, model: device.model)
            } else {
                let devices = try await client.devices()
                if let chosen = ScrcpyDeviceSelection.serial(devices: devices, peerModel: device.model, preference: deviceSettings.scrcpyDevicePreference) {
                    serial = chosen
                } else {
                    let online = devices.filter { $0.state == "device" }
                    guard let only = online.first else {
                        controller.fail(.noDevice)
                        return
                    }
                    serial = only.serial
                }
            }
        } catch let error as AdbError {
            controller.fail(.adb(error))
            return
        } catch {
            controller.fail(.adb(.spawnFailed(error.localizedDescription)))
            return
        }

        let built: ServerOptionsBuilder.Result
        do {
            built = try ServerOptionsBuilder.build(
                settings: deviceSettings, package: package, scid: UInt32.random(in: 0...0x7fff_ffff),
                av1Supported: VideoFormat.av1Supported, verboseLogs: general.verboseMirrorLogs
            )
        } catch {
            controller.fail(.invalidOptions(error.localizedDescription))
            return
        }
        built.warnings.forEach(controller.addWarning)
        let config = MirrorSessionConfig(
            key: key, serial: serial, options: built.options,
            actions: ServerOptionsBuilder.startupActions(settings: deviceSettings, package: package),
            audioTargetLatencyMs: deviceSettings.audioBuffer > 0 ? deviceSettings.audioBuffer : 50,
            unlockCommands: deviceSettings.unlockDeviceBeforeLaunch ? deviceSettings.unlockCommands : []
        )
        let launcher = ServerLauncher(adb: client, serverJar: tools.server)
        controller.start(config: config, launcher: launcher)
    }

    /// `GeneralSettings.mirrorFallbackToExternal`: a native failure before streaming opens the scrcpy window instead.
    private func fallbackToExternalIfEnabled(after error: MirrorError, key: String, package: String?, appName: String?) {
        guard general.mirrorFallbackToExternal, canUseExternalScrcpy else { return }
        switch error {
        case .cancelled, .connectionLost, .noDevice, .adb: return   // nothing external scrcpy could do better
        default: break
        }
        guard let controller = mirrors[key], !controller.reconnecting else { return }
        controller.addWarning("Native mirror failed (\(error.title)); opening external scrcpy.")
        controller.stop()
        launchScrcpy(package: package, appName: appName)
    }

    func stopMirror(key: String) {
        if let controller = mirrors[key] { controller.stop() }
        if scrcpyRunner.runningKeys.contains(key) { scrcpyRunner.terminate(key: key) }
    }

    /// Stops every session of a device: the device mirror and its per-app sessions, native or external.
    func stopMirrors(deviceId: String) {
        for controller in mirrors.values where controller.deviceId == deviceId { controller.stop() }
        intentionalAudioStops.formUnion(audioMirrorKeys.filter { $0.hasPrefix(deviceId + ":") })
        for key in scrcpyRunner.runningKeys where key == deviceId || key.hasPrefix(deviceId + ":") {
            scrcpyRunner.terminate(key: key)
        }
        audioMirrorKeys = audioMirrorKeys.filter { !$0.hasPrefix(deviceId + ":") }
    }

    func stopAllMirrors() {
        intentionalAudioStops.formUnion(audioMirrorKeys)
        mirrors.values.forEach { $0.stop() }
        scrcpyRunner.terminateAll()
        audioMirrorKeys.removeAll()
    }

    /// True while any session of the device (device mirror or per-app) is running.
    func isMirroring(_ deviceId: String) -> Bool {
        mirroringKeys.contains { $0 == deviceId || $0.hasPrefix(deviceId + ":") }
            || mirrors.values.contains { $0.deviceId == deviceId && $0.isActive }
    }

    func isMirrorPending(_ key: String) -> Bool {
        pendingMirrorKeys.contains(key)
    }

    /// True when Mirror can work: native tools (or bundled/custom scrcpy for the external backend).
    var canMirror: Bool {
        if general.mirrorBackend == .native { return nativeTools != nil }
        return canUseExternalScrcpy
    }

    /// Bundled or custom scrcpy binary available for the external window (also the native fallback).
    var canUseExternalScrcpy: Bool {
        if bundledTools != nil { return true }
        if !general.scrcpyPath.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        guard let id = selectedDeviceID else { return false }
        return !deviceSettings(for: id).scrcpyPath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The adb the app would use for troubleshooting commands (override or bundled).
    private var resolvedAdb: URL? {
        let override = general.adbPath.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty { return URL(fileURLWithPath: override) }
        return bundledTools?.adb
    }

    /// True when adb is available for Wireless-debugging QR pairing.
    var canWirelessPair: Bool { resolvedAdb != nil }

    /// Builds a model for the Wireless-debugging QR pairing sheet, or nil when adb is unavailable.
    func makeWirelessPairingModel() -> WirelessPairingModel? {
        guard let adb = resolvedAdb else { return nil }
        var env = ProcessInfo.processInfo.environment
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if env["PATH"] == nil { env["PATH"] = ScrcpyLaunchPlanner.defaultPath }
        // Force the built-in mDNS backend on older platform-tools; harmless on current ones.
        env["ADB_MDNS_OPENSCREEN"] = "1"
        let context = WirelessPairingContext(adb: adb, environment: env, runner: commandRunner)
        return WirelessPairingModel(context: context) { [weak self] _ in
            Task { @MainActor in await self?.refreshAdbOnlineState() }
        }
    }

    func restartAdbServer() {
        guard let adb = resolvedAdb else {
            adbRestartResult = "No adb available."
            return
        }
        adbRestartResult = "Restarting…"
        var env = ProcessInfo.processInfo.environment
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if env["PATH"] == nil { env["PATH"] = ScrcpyLaunchPlanner.defaultPath }
        let runner = commandRunner
        Task {
            do {
                _ = try await runner.run(adb, ["kill-server"], environment: env, timeout: 5)
                let start = try await runner.run(adb, ["start-server"], environment: env, timeout: 10)
                adbRestartResult = start.exitCode == 0
                    ? "ADB server restarted."
                    : "adb start-server failed (exit \(start.exitCode)): \(start.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            } catch {
                adbRestartResult = error.localizedDescription
            }
        }
    }

    func openThirdPartyNotices() {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("scrcpy/NOTICES.md"),
           FileManager.default.fileExists(atPath: url.path)
        {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(string: "https://github.com/Genymobile/scrcpy/blob/master/LICENSE")!)
        }
    }

    func deviceSettings(for deviceId: String) -> DeviceSettings {
        (try? settings.loadDevice(id: deviceId)) ?? DeviceSettings(deviceId: deviceId)
    }

    func updateDeviceSettings(for deviceId: String, _ mutate: (inout DeviceSettings) -> Void) {
        var current = deviceSettings(for: deviceId)
        mutate(&current)
        do {
            try settings.saveDevice(current)
            // Device settings are stored on disk, not in observable state; bump a revision so
            // SwiftUI views that display them refresh.
            deviceSettingsRevision += 1
        } catch {
            toolFailure = ToolFailure(title: "Could not save device settings", message: error.localizedDescription, detail: nil)
        }
    }

    func runAction(_ item: ActionItem) {
        execute(ActionRunner.plan(item))
    }

    func execute(_ plan: ActionExecution) {
        guard !plan.command.isEmpty else { return }
        if plan.kind == "link", let url = URL(string: plan.arguments.first ?? "") {
            NSWorkspace.shared.open(url)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.command)
        process.arguments = plan.arguments
        do {
            try process.run()
        } catch {
            toolFailure = ToolFailure(title: "Could not run action", message: error.localizedDescription, detail: plan.command)
        }
    }

    func openSftp() {
        guard let sftp = live.lastSftp, let device = selectedDevice else { return }
        let path = sftp.paths.first
        if let url = SftpBrowse.finderURL(
            host: device.address,
            port: sftp.port,
            username: sftp.username,
            password: sftp.password,
            path: path
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    func saveGeneral() {
        try? settings.saveGeneral(general)
        hub.actionsCatalog = general.actions
        if let id = selectedDeviceID {
            sendActionList(to: id)
        }
    }

    /// Called when the "Sync clipboard to phone in real time" toggle changes: persists the setting and
    /// starts/stops the pasteboard monitor immediately.
    func clipboardSyncSettingChanged() {
        saveGeneral()
        if general.syncClipboardToPhone {
            clipboardMonitor.start()
        } else {
            clipboardMonitor.stop()
        }
    }

    func sendActionList(to deviceId: String) {
        session?.send(to: deviceId, .actionList(ActionRunner.actionList(from: general.actions)))
    }

    func handleURL(_ url: URL) {
        guard url.scheme == "sefirah" else { return }
        if url.host == "pair", let payload = try? QrCodePayload.parseDeepLink(url.absoluteString),
           let address = payload.addresses.first
        {
            session?.connect(deviceId: payload.deviceId, host: address, port: payload.port)
        } else if url.host == "notification" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let deviceID = items.first(where: { $0.name == "device" })?.value,
                  let package = items.first(where: { $0.name == "package" })?.value, !package.isEmpty
            else { return }
            openNotificationApp(
                deviceID: deviceID,
                appPackage: package,
                appName: items.first(where: { $0.name == "name" })?.value,
                notificationKey: items.first(where: { $0.name == "key" })?.value
            )
        } else if let package = url.host, !package.isEmpty {
            startMirror(package: package)
        }
    }

    /// Notification card clicked in the rail: same behaviour as clicking the macOS banner.
    func openNotification(_ note: NotificationSnapshot) {
        openNotificationApp(
            deviceID: note.deviceId,
            appPackage: note.appPackage,
            appName: note.appName,
            notificationKey: note.notificationKey
        )
    }

    /// Opens a mirrored notification on the phone — firing its content intent so messaging apps
    /// land on the right screen — and mirrors just the app on a virtual display. The URL is sent by
    /// the `Sefirah Phone` helper on a banner click. Opening a hidden app's notification asks for
    /// Touch ID (or the login password) first.
    private func openNotificationApp(
        deviceID: String,
        appPackage: String,
        appName: String?,
        notificationKey: String?
    ) {
        Task {
            await openNotificationAppAuthorized(
                deviceID: deviceID,
                appPackage: appPackage,
                appName: appName,
                notificationKey: notificationKey
            )
        }
    }

    private func openNotificationAppAuthorized(
        deviceID: String,
        appPackage: String,
        appName: String?,
        notificationKey: String?
    ) async {
        guard general.openAppOnNotificationClick else { return }
        if hub.isAppHidden(deviceId: deviceID, packageName: appPackage) {
            guard await DeviceOwnerAuth.authenticate(reason: "Open a notification from a hidden app") else { return }
        }

        if general.mirrorBackend == .native {
            // The native mirror renders in the main window's Mirror tab, so it must come forward.
            showMainWindow = true
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                window.makeKeyAndOrderFront(nil)
            }
        } else {
            // External scrcpy opens its own window. The URL activation can raise the main window;
            // dismiss it and return to menu-bar mode so the notification tap shows scrcpy only.
            dismissMainWindow()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                self?.dismissMainWindow()
            }
        }

        if selectedDeviceID != deviceID {
            selectedDeviceID = deviceID
            refreshDevice()
        }

        if let notificationKey, !notificationKey.isEmpty {
            // Ask the phone to fire the notification's PendingIntent so it opens the right screen.
            session?.send(to: deviceID, .notificationInfo(NotificationInfo(
                notificationKey: notificationKey,
                infoType: .invoke,
                timestampMillis: Int64(Date().timeIntervalSince1970 * 1000),
                appPackage: appPackage,
                appName: appName
            )))
        }
        // Mirror the app alone on a virtual display rather than the whole phone screen.
        startMirror(package: appPackage, appName: appName)
    }

    private func handle(_ event: SessionEvent) {
        switch event {
        case .discovered(let peer):
            if !discovered.contains(where: { $0.id == peer.id }) {
                discovered.append(peer)
            }
        case .pairingRequested(let peer):
            pendingPairing = peer
        case .paired(let peer), .connected(let peer):
            upsertPaired(peer)
            selectedDeviceID = peer.id
            completeOnboarding()
            // Sessions from before this connection stay hidden until they update again.
            hub.markPlaybackConnection(deviceId: peer.id, connectedAt: Date())
            refreshDevice()
            publishAudioDevices(to: [peer.id])
            sendActionList(to: peer.id)
            session?.send(to: peer.id, .requestApplicationList)
            Task { [weak self] in
                await self?.publishMacPlaybackMetadata(to: [peer.id])
            }
        case .disconnected(let deviceId, let forced):
            if let index = paired.firstIndex(where: { $0.id == deviceId }) {
                paired[index].isConnected = false
            }
            hub.markPlaybackConnection(deviceId: deviceId, connectedAt: nil)
            publishedAudioDevices[deviceId] = nil
            if selectedDeviceID == deviceId { refreshDevice() }
            if !forced {
                session?.reconnectPairedDevices()
                autoReconnect(deviceId: deviceId)
            }
        case .inboundMessage(let deviceId, let message):
            if case .audioAction(let action) = message {
                applyAudioAction(action)
                publishAudioDevices(to: [deviceId])
            }
            if case .mediaAction(let action) = message,
               MacMediaController.handles(action)
            {
                Task { [weak self] in
                    await MacMediaController.handle(action)
                    await self?.publishMacPlaybackMetadata(to: [deviceId])
                    if action.actionType == .next || action.actionType == .previous {
                        // Players occasionally report the previous track for a moment after a
                        // skip; take a second full snapshot so the phone lands on the new
                        // track's 0:00 in place. Removing the session instead would cancel and
                        // re-add the notification (flicker).
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        await self?.publishMacPlaybackMetadata(to: [deviceId])
                    }
                }
            }
            let result = try? hub.handle(deviceId: deviceId, message)
            apply(result?.effects ?? [], deviceId: deviceId)
            forwardNotification(message, from: deviceId)
            if deviceId == selectedDeviceID {
                refreshDevice()
            }
        }
    }

    private func publishMacPlaybackMetadata(to deviceIDs: [String]) async {
        guard !deviceIDs.isEmpty else { return }
        let playback = await MacMediaController.playbackInfos()
        let sources = Set(playback.map(\.source))

        for deviceID in deviceIDs {
            for info in playback {
                session?.send(to: deviceID, .playbackInfo(info))
            }

            for source in (macPlaybackSources[deviceID] ?? []).subtracting(sources) {
                session?.send(
                    to: deviceID,
                    .playbackInfo(PlaybackInfo(infoType: .removedSession, source: source, isPlaying: false))
                )
            }
            macPlaybackSources[deviceID] = sources
        }
    }

    func refreshDevice() {
        guard let id = selectedDeviceID else { return }
        notifications = (try? hub.notifications(deviceId: id)) ?? []
        conversations = (try? hub.conversations(deviceId: id)) ?? []
        callLogs = (try? hub.callLogs(deviceId: id)) ?? []
        apps = (try? hub.apps(deviceId: id)) ?? []
        live = hub.liveState(deviceId: id)
        incomingCall = live.incomingCall
        if let thread = selectedThreadID {
            messages = (try? hub.messages(deviceId: id, threadId: thread)) ?? []
        }
    }

    func selectThread(_ threadId: Int64) {
        selectedThreadID = threadId
        refreshDevice()
        if let deviceID = selectedDeviceID {
            session?.send(to: deviceID, .threadRequest(ThreadRequest(threadId: threadId)))
        }
    }

    private func apply(_ effects: [FeatureEffect], deviceId: String) {
        for effect in effects {
            switch effect {
            case .applyClipboard(let info):
                ClipboardApply.apply(info)
                clipboardMonitor.notePasteboardWritten()
            case .receiveFiles(let info):
                startFileReceive(deviceId: deviceId, info: info)
            case .executeAction(let execution):
                execute(execution)
            }
        }
    }

    /// Hides the main window and returns the app to menu-bar-only mode. Used so external
    /// scrcpy notification taps never leave the Sefirah window on screen.
    private func dismissMainWindow() {
        NSApp.windows.first { $0.identifier?.rawValue == "main" }?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    private func forwardNotification(_ message: SocketMessage, from deviceID: String) {
        guard case .notificationInfo(let notification) = message else { return }

        if notification.infoType == .removed {
            macNotifications.remove(notificationKey: notification.notificationKey, from: deviceID)
        } else if let appPackage = notification.appPackage, hub.shouldShowNotificationBanner(deviceId: deviceID, packageName: appPackage) {
            macNotifications.deliver(notification, from: deviceID, includeIcon: general.showNotificationIcons)
        }
    }

    private func startFileReceive(deviceId: String, info: FileTransferInfo) {
        guard let peer = paired.first(where: { $0.id == deviceId }) else { return }
        let destination: URL
        if info.isClipboard {
            destination = FileManager.default.temporaryDirectory.appendingPathComponent("SefirahClipboard", isDirectory: true)
        } else {
            destination = URL(fileURLWithPath: general.receivedFilesPath, isDirectory: true)
        }
        let localIdentity = self.identity
        let cert = peer.certificateDER
        let host = peer.address
        let port = info.serverInfo.port
        Task.detached { [weak self] in
            do {
                let urls = try await FileTransferClient.receive(
                    files: info.files,
                    destination: destination,
                    host: host,
                    port: port,
                    identity: localIdentity,
                    pinnedCertificateDER: cert
                )
                if info.isClipboard, let url = urls.first {
                    await MainActor.run {
                        ClipboardApply.applyFile(url, mimeType: info.files.first?.mimeType)
                        self?.clipboardMonitor.notePasteboardWritten()
                    }
                }
            } catch {
                await MainActor.run {
                    self?.sessionError = error.localizedDescription
                }
            }
        }
    }

}

enum MainTab: Hashable {
    case calls, messages, apps, mirror, settings
}

struct ToolFailure: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
    var detail: String?
    var retryAction: (() -> Void)?

    static func == (lhs: ToolFailure, rhs: ToolFailure) -> Bool {
        lhs.id == rhs.id
    }
}
