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
    }

    var selectedDevice: ConnectedPeer? {
        paired.first { $0.id == selectedDeviceID }
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
        session?.send(to: deviceID, hub.mediaAction(type, source: source, value: value))
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

    func stopMirroring(key: String? = nil) {
        if let key {
            scrcpyRunner.terminate(key: key)
        } else {
            scrcpyRunner.terminateAll()
        }
    }

    // MARK: - Native mirror

    var sortedApps: [ApplicationRecord] {
        let recentPositions = Dictionary(
            uniqueKeysWithValues: general.recentlyOpenedAppKeys.enumerated().map { ($0.element, $0.offset) }
        )

        return apps.sorted { lhs, rhs in
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

    var recentlyOpenedApps: [ApplicationRecord] {
        general.recentlyOpenedAppKeys
            .compactMap { key in apps.first { $0.appKey == key } }
            .prefix(8)
            .map { $0 }
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

    func setAppNotificationsEnabled(_ app: ApplicationRecord, isEnabled: Bool) {
        guard (try? hub.setAppNotificationsEnabled(
            deviceId: app.deviceId,
            packageName: app.packageName,
            isEnabled: isEnabled
        )) != nil else { return }

        if let index = apps.firstIndex(where: { $0.appKey == app.appKey }) {
            apps[index].filter = isEnabled ? .toastFeed : .disabled
        }
    }

    func setAllAppNotificationsEnabled(_ isEnabled: Bool) {
        for app in apps {
            setAppNotificationsEnabled(app, isEnabled: isEnabled)
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
        for key in scrcpyRunner.runningKeys where key == deviceId || key.hasPrefix(deviceId + ":") {
            scrcpyRunner.terminate(key: key)
        }
    }

    func stopAllMirrors() {
        mirrors.values.forEach { $0.stop() }
        scrcpyRunner.terminateAll()
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
                appName: items.first(where: { $0.name == "name" })?.value
            )
        } else if let package = url.host, !package.isEmpty {
            startMirror(package: package)
        }
    }

    /// Opens a mirrored notification's app on the phone; the URL is sent by the `Sefirah Phone`
    /// helper when one of its notifications is clicked.
    private func openNotificationApp(deviceID: String, appPackage: String, appName: String?) {
        guard general.openAppOnNotificationClick else { return }

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
            refreshDevice()
            sendActionList(to: peer.id)
            session?.send(to: peer.id, .requestApplicationList)
            Task { [weak self] in
                await self?.publishMacPlaybackMetadata(to: [peer.id])
            }
        case .disconnected(let deviceId, let forced):
            if let index = paired.firstIndex(where: { $0.id == deviceId }) {
                paired[index].isConnected = false
            }
            if !forced {
                session?.reconnectPairedDevices()
                autoReconnect(deviceId: deviceId)
            }
        case .inboundMessage(let deviceId, let message):
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
        } else if let appPackage = notification.appPackage, hub.isNotificationEnabled(deviceId: deviceID, packageName: appPackage) {
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
