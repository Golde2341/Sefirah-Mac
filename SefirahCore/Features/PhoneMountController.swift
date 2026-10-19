import AppKit
// The C globals behind the Finder-sidebar helper predate Swift concurrency; the wrapper below
// only touches them on the main actor.
@preconcurrency import CoreServices
import Foundation
import Observation
import dnssd
import os

private let mountLog = Logger(subsystem: "io.github.madeye.sefirah.mac", category: "phone-mount")

/// Buffers rclone's output: every line goes to the unified log, and the WebDAV ready banner
/// releases whoever is waiting for the bridge to come up.
final class BridgeLogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var lines: [String] = []
    private var ready = false
    private var exited = false
    private var readyContinuation: CheckedContinuation<Bool, Never>?

    /// Feed raw bytes; complete lines are kept (bounded) and scanned for the ready banner.
    func ingest(_ data: Data) {
        var completed: [String] = []
        var continuation: CheckedContinuation<Bool, Never>?

        lock.lock()
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<newline]
            pending = Data(pending[pending.index(after: newline)...])
            if let text = String(data: lineData, encoding: .utf8) {
                completed.append(text)
            }
        }
        for line in completed {
            lines.append(line)
            if lines.count > 80 { lines.removeFirst(lines.count - 80) }
            if !ready, line.contains("WebDav Server started") {
                ready = true
                continuation = readyContinuation
                readyContinuation = nil
            }
        }
        lock.unlock()

        for line in completed { mountLog.info("rclone: \(line, privacy: .public)") }
        continuation?.resume(returning: true)
    }

    /// The bridge's output ended (process exited or closed its streams).
    func markExited() {
        var continuation: CheckedContinuation<Bool, Never>?
        lock.lock()
        exited = true
        if !ready {
            continuation = readyContinuation
            readyContinuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: false)
    }

    /// Tail of the bridge's output, for error messages.
    func recentLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    /// True once the server banner arrived, false when the bridge exited or timed out.
    func waitForReady(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if ready {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            if exited {
                lock.unlock()
                continuation.resume(returning: false)
                return
            }
            readyContinuation = continuation
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                var timedOut: CheckedContinuation<Bool, Never>?
                self.lock.lock()
                if !self.ready, !self.exited {
                    timedOut = self.readyContinuation
                    self.readyContinuation = nil
                }
                self.lock.unlock()
                timedOut?.resume(returning: false)
            }
        }
    }
}

/// Pins a mounted volume into Finder's sidebar (the "Locations" volume list), the way
/// CloudMounter-style mounters do: the volume shows up for as long as it is mounted, and the
/// entry is remembered so a remount lands in the same place.
///
/// Uses the ancient-but-still-supported shared-file-list API. Every call is marked deprecated on
/// purpose: the enclosing declaration being deprecated keeps the compiler from warning about each
/// use of the likewise-deprecated `LSSharedFileList` entry points.
@available(macOS, deprecated: 10.11, message: "Wraps the deprecated LSSharedFileList API; macOS has no replacement for pinning a volume into the Finder sidebar.")
enum FinderSidebar {
    /// Resolve bookmarks without touching the network or showing anything to the user.
    private static let resolveFlags = UInt32(
        kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes
    )

    private static func favoriteVolumes() -> LSSharedFileList? {
        LSSharedFileListCreate(
            kCFAllocatorDefault,
            kLSSharedFileListFavoriteVolumes.takeUnretainedValue(),
            nil
        )?.takeRetainedValue()
    }

    private static func items(_ list: LSSharedFileList) -> [LSSharedFileListItem] {
        (LSSharedFileListCopySnapshot(list, nil)?.takeRetainedValue() as? [LSSharedFileListItem]) ?? []
    }

    private static func resolvedPath(of item: LSSharedFileListItem) -> String? {
        guard let url = LSSharedFileListItemCopyResolvedURL(item, resolveFlags, nil)?.takeRetainedValue()
        else { return nil }
        return (url as URL).standardizedFileURL.path
    }

    /// Add `/Volumes/<phone>` to Finder's sidebar unless it's already there.
    static func pinVolume(at path: String, name: String?) {
        guard let list = favoriteVolumes() else { return }
        let existing = items(list)
        guard !existing.contains(where: { resolvedPath(of: $0) == path }) else { return }
        guard let url = CFURLCreateWithFileSystemPath(
            kCFAllocatorDefault,
            path as CFString,
            .cfurlposixPathStyle,
            true
        ) else { return }
        // Insert after the last item instead of using `kLSSharedFileListItemLast`: the sentinel is
        // a bare pointer (0x2), which Swift's typed import chokes on (it retains the "reference").
        guard let anchor = existing.last else {
            mountLog.notice("Finder sidebar list is empty; skipping the pin for \(path, privacy: .public)")
            return
        }
        let displayName = (name?.isEmpty == false ? name! : (path as NSString).lastPathComponent) as CFString
        _ = LSSharedFileListInsertItemURL(list, anchor, displayName, nil, url, nil, nil)
    }
}

/// Publishes `Sefirah.local` → 127.0.0.1 over Bonjour so Finder's sidebar labels the phone's
/// network volume with a readable name instead of the raw loopback address. The A record is
/// registered as "shared", so several Sefirah installs on one network can all publish it: every
/// copy points at its own machine's loopback, which is exactly where that copy's bridge listens.
@MainActor
final class LoopbackHostName {
    static let shared = LoopbackHostName()

    /// True once the local mDNS responder accepted the record, i.e. the name resolves.
    private(set) var isActive = false
    private var connection: DNSServiceRef?

    /// Registers the record; idempotent and non-blocking, so it's safe to call at launch.
    func start() {
        guard connection == nil else { return }
        var connection: DNSServiceRef?
        guard DNSServiceCreateConnection(&connection) == kDNSServiceErr_NoError, let connection else {
            mountLog.error("could not open the Bonjour connection for \(PhoneMount.bonjourHostName, privacy: .public)")
            return
        }
        self.connection = connection
        DNSServiceSetDispatchQueue(connection, DispatchQueue.main)

        var record: DNSServiceRef?
        let address: [UInt8] = [127, 0, 0, 1]
        let error: DNSServiceErrorType = PhoneMount.bonjourHostName.withCString { fullName in
            address.withUnsafeBytes { bytes in
                DNSServiceRegisterRecord(
                    connection,
                    &record,
                    kDNSServiceFlagsShared,
                    UInt32(kDNSServiceInterfaceIndexAny),
                    fullName,
                    UInt16(kDNSServiceType_A),
                    UInt16(kDNSServiceClass_IN),
                    UInt16(bytes.count),
                    bytes.baseAddress,
                    120,
                    loopbackHostRegistrationReply,
                    nil
                )
            }
        }
        guard error == kDNSServiceErr_NoError else {
            mountLog.error("Bonjour registration for \(PhoneMount.bonjourHostName, privacy: .public) failed with \(error)")
            DNSServiceRefDeallocate(connection)
            self.connection = nil
            return
        }
    }

    fileprivate func registrationUpdated(error: DNSServiceErrorType) {
        isActive = error == kDNSServiceErr_NoError
        if !isActive {
            mountLog.notice("Bonjour name \(PhoneMount.bonjourHostName, privacy: .public) could not be registered (\(error))")
        }
    }
}

/// C callback for the A-record registration; hops back to the main actor.
private func loopbackHostRegistrationReply(
    _ sdRef: DNSServiceRef?,
    _ recordRef: DNSRecordRef?,
    _ flags: DNSServiceFlags,
    _ error: DNSServiceErrorType,
    _ context: UnsafeMutableRawPointer?
) {
    Task { @MainActor in
        LoopbackHostName.shared.registrationUpdated(error: error)
    }
}

/// Mounts paired phones' storage in Finder.
///
/// Each phone gets its own bridge: the phone's SFTP server is bridged to a loopback WebDAV
/// server (`rclone serve webdav`) and handed to Finder with one AppleScript `mount volume` call —
/// no kernel extension and no installer — so the volume appears under `/Volumes/<phone name>` as
/// the logged-in user. Every phone has independent config, cache, port and state, so several
/// phones can be mounted at the same time.
@MainActor
@Observable
public final class PhoneMountController {
    public enum Phase: Equatable, Sendable {
        case idle
        case mounting
        case mounted(MountedVolume)
        case unmounting

        public var volume: MountedVolume? {
            if case .mounted(let volume) = self { return volume }
            return nil
        }
    }

    public struct MountedVolume: Equatable, Sendable {
        public let deviceID: String
        public let name: String
        public let path: String
        public let port: Int
    }

    /// Everything the UI needs to know about one phone's mount.
    public struct Session: Equatable, Sendable {
        public var phase: Phase = .idle
        public var lastError: String?

        public init(phase: Phase = .idle, lastError: String? = nil) {
            self.phase = phase
            self.lastError = lastError
        }

        public var volume: MountedVolume? { phase.volume }
        public var isBusy: Bool { phase == .mounting || phase == .unmounting }
    }

    /// Mount state per device, in connection order. Devices appear once they are used.
    public private(set) var sessions: [String: Session] = [:]

    @ObservationIgnored private let supportDirectory: URL
    @ObservationIgnored private let rcloneURL: URL?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var runtimes: [String: Runtime] = [:]
    /// Ports picked by mounts that are starting or running but not bound yet.
    @ObservationIgnored private var reservedPorts: Set<Int> = []

    /// Bridge plumbing for one phone; not observable, only touched on the main actor.
    private final class Runtime {
        var process: Process?
        var pipe: Pipe?
        var collector: BridgeLogCollector?
        var livenessTask: Task<Void, Never>?
        var stopRequested = false
        var port: Int?
        var configPath: String?
    }

    private static let staleStatesKey = "PhoneMount.staleStates"
    /// Older builds stored a single mount here; still read once so an upgrade cleans it up.
    private static let legacyStaleStateKey = "PhoneMount.staleState"

    /// Everything needed to clean up a mount the app didn't get to unmount (crash, force quit).
    private struct StaleState: Codable, Equatable {
        var pid: Int32
        var port: Int
        var volumePath: String
        var configPath: String
        var deviceID: String
    }

    public init(
        supportDirectory: URL,
        rcloneURL: URL? = MountTools.locateRclone(),
        defaults: UserDefaults = .standard
    ) {
        self.supportDirectory = supportDirectory
        self.rcloneURL = rcloneURL
        self.defaults = defaults
        // Publish the loopback name early so mounts can use it right away.
        LoopbackHostName.shared.start()
        Task { [weak self] in await self?.cleanUpStaleState() }
    }

    // MARK: - Queries

    /// False when the app was built without the bundled rclone helper, so mounts can't start.
    public var hasBundledBridge: Bool { rcloneURL != nil }

    /// Mount state of one phone; `.idle` for phones that were never mounted.
    public func session(for deviceID: String) -> Session { sessions[deviceID] ?? Session() }

    public func phase(for deviceID: String) -> Phase { session(for: deviceID).phase }
    public func volume(for deviceID: String) -> MountedVolume? { session(for: deviceID).volume }
    public func isMounted(deviceID: String) -> Bool { volume(for: deviceID) != nil }
    public func isBusy(deviceID: String) -> Bool { session(for: deviceID).isBusy }
    public func lastError(for deviceID: String) -> String? { session(for: deviceID).lastError }

    /// Volumes currently in Finder, oldest mount first.
    public var mountedVolumes: [MountedVolume] {
        sessions.values.compactMap(\.volume)
    }

    // MARK: - Mounting

    /// Expose `sftp`'s storage as `/Volumes/<device name>`, opening it in Finder on success.
    /// Each phone mounts independently; mounting one never unmounts another.
    public func mount(deviceID: String, deviceName: String, sftp: SftpServerInfo, host: String) async {
        guard !isBusy(deviceID: deviceID), !isMounted(deviceID: deviceID) else { return }
        update(deviceID) { $0.lastError = nil }
        guard let rcloneURL else {
            update(deviceID) { $0.lastError = PhoneMountError.rcloneMissing.errorDescription }
            return
        }
        update(deviceID) { $0.phase = .mounting }
        do {
            let volume = try await startMount(
                deviceID: deviceID,
                deviceName: deviceName,
                sftp: sftp,
                host: host,
                rcloneURL: rcloneURL
            )
            update(deviceID) { $0.phase = .mounted(volume) }
            watchLiveness(volume)
            FinderSidebar.pinVolume(at: volume.path, name: volume.name)
            mountLog.info("mounted \(volume.path, privacy: .public)")
            NSWorkspace.shared.open(URL(fileURLWithPath: volume.path))
        } catch {
            await stopBridge(deviceID: deviceID)
            removeConfigFile(for: deviceID)
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            update(deviceID) { $0.lastError = message; $0.phase = .idle }
            mountLog.error("mount failed for \(deviceID, privacy: .public): \(message, privacy: .public)")
        }
    }

    /// Host name Finder gets for the bridge. The plain "Sefirah" when the user installed the
    /// `/etc/hosts` alias, otherwise the Bonjour name, otherwise the bare loopback address.
    private func preferredLoopbackHost() -> String {
        if Self.hostsFileMapsLoopback(name: PhoneMount.finderHostName) {
            return PhoneMount.finderHostName
        }
        if LoopbackHostName.shared.isActive {
            return PhoneMount.bonjourHostName
        }
        return "127.0.0.1"
    }

    private static func hostsFileMapsLoopback(name: String) -> Bool {
        guard let contents = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) else { return false }
        return PhoneMount.hostsFileMapsLoopback(contents, name: name)
    }

    private func startMount(
        deviceID: String,
        deviceName: String,
        sftp: SftpServerInfo,
        host: String,
        rcloneURL: URL
    ) async throws -> MountedVolume {
        let directory = supportDirectory.appendingPathComponent("PhoneMount", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent(PhoneMount.mountConfigFileName(for: deviceID))
        // Per-device cache: pending uploads only ever replay onto the phone they came from.
        let cacheURL = directory.appendingPathComponent(
            PhoneMount.mountCacheDirectoryName(for: deviceID),
            isDirectory: true
        )

        guard let localPort = nextFreePort() else {
            throw PhoneMountError.noPortAvailable
        }
        reservedPorts.insert(localPort)

        let runtime = Runtime()
        runtime.port = localPort
        runtime.configPath = configURL.path
        runtimes[deviceID] = runtime

        let (mountUser, mountPass) = mountCredentials(for: deviceID)
        let preferredName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantedName = PhoneMount.volumeName(
            for: preferredName.isEmpty ? (sftp.pathNames.first ?? "") : preferredName
        )
        // Two phones with the same reported name get distinct volumes ("Pixel 8 2").
        let takenNames = Set(sessions.compactMap { $0.key == deviceID ? nil : $0.value.volume?.name })
        let configuration = PhoneMountConfiguration(
            volumeName: PhoneMount.disambiguatedVolumeName(wantedName, taken: takenNames),
            host: host,
            port: sftp.port,
            username: sftp.username,
            password: sftp.password,
            basePath: sftp.paths.first ?? "/",
            localPort: localPort,
            mountUsername: mountUser,
            mountPassword: mountPass,
            configPath: configURL.path,
            cacheDirectory: cacheURL.path
        )

        // 1. Config: SFTP remote for the phone + a named `combine` root Finder can mount.
        try Data(PhoneMount.configFile(configuration).utf8).write(to: configURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)

        // 2. Bridge process; its output drives both logging and the ready wait.
        let collector = BridgeLogCollector()
        let process = Process()
        process.executableURL = rcloneURL
        process.arguments = PhoneMount.arguments(configuration)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor [weak self] in self?.bridgeDidExit(deviceID: deviceID, status: status) }
        }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                collector.markExited()
            } else {
                collector.ingest(data)
            }
        }
        do {
            try process.run()
        } catch {
            throw PhoneMountError.bridgeFailedToStart(error.localizedDescription)
        }
        runtime.process = process
        runtime.pipe = pipe
        runtime.collector = collector

        let ready = await collector.waitForReady(timeout: 12)
        guard ready else {
            let detail = collector.recentLines().suffix(4).joined(separator: " — ")
            throw PhoneMountError.bridgeFailedToStart(detail.isEmpty ? "no response from the bridge" : detail)
        }

        // 3. Ask Finder to mount the loopback URL (credentials in the URL keep it prompt-free).
        //    Finder's NetAuthAgent occasionally stalls the first request for a host it has seen
        //    before (a volume that was mounted in an earlier session); a prompt retry then
        //    completes instantly, so give it two tries and check the mount table in between.
        //    Prefer the branded loopback name so the sidebar row is readable, falling back to the
        //    raw address if the name can't be reached on this network.
        let preferredHost = preferredLoopbackHost()
        var candidateHosts = [preferredHost]
        if preferredHost != "127.0.0.1" {
            candidateHosts.append("127.0.0.1")
        }
        var mountFailure: Error?
        var mountedHost: String?
        mounting: for (hostIndex, candidateHost) in candidateHosts.enumerated() {
            let attempts: [Int] = [20, 45]
            for (attemptIndex, timeout) in attempts.enumerated() {
                do {
                    try await runMountScript(
                        url: PhoneMount.mountURL(configuration, host: candidateHost),
                        timeoutSeconds: timeout
                    )
                    mountFailure = nil
                    mountedHost = candidateHost
                    break mounting
                } catch {
                    mountFailure = error
                    if await currentMountPoint(port: localPort) != nil {
                        mountFailure = nil
                        mountedHost = candidateHost
                        break mounting
                    }
                    if attemptIndex < attempts.count - 1 {
                        mountLog.notice("mount request stalled; retrying once")
                        try? await Task.sleep(for: .milliseconds(800))
                    } else if hostIndex < candidateHosts.count - 1 {
                        mountLog.notice("mounting through \(candidateHost, privacy: .public) failed; falling back to 127.0.0.1")
                    }
                }
            }
        }
        if let mountFailure { throw mountFailure }
        if let mountedHost {
            mountLog.info("Finder mounted \(configuration.volumeName, privacy: .public) via \(mountedHost, privacy: .public)")
        }

        // 4. Locate the mount point; fall back to the name we asked for.
        let volumePath = await currentMountPoint(port: localPort) ?? "/Volumes/\(configuration.volumeName)"
        persistStaleState(StaleState(
            pid: process.processIdentifier,
            port: localPort,
            volumePath: volumePath,
            configPath: configURL.path,
            deviceID: deviceID
        ))
        return MountedVolume(deviceID: deviceID, name: configuration.volumeName, path: volumePath, port: localPort)
    }

    /// First free loopback port, skipping ports another mount already picked.
    private func nextFreePort() -> Int? {
        let reserved = reservedPorts
        return PortAllocator.firstFreePort(probe: { port in
            !reserved.contains(port) && PortProbe.isFree(port)
        })
    }

    private func runMountScript(url: String, timeoutSeconds: Int) async throws {
        let source = PhoneMount.appleScriptMountScript(url: url, timeoutSeconds: timeoutSeconds)
        let errorInfo: NSDictionary? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var info: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&info)
                continuation.resume(returning: info)
            }
        }
        guard let errorInfo else { return }
        throw PhoneMountError.mountScriptFailed(Self.appleScriptMessage(from: errorInfo))
    }

    private nonisolated static func appleScriptMessage(from info: NSDictionary) -> String {
        let number = (info["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
        let message = (info["NSAppleScriptErrorMessage"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if number == -1743 {
            return "Sefirah needs permission to control Finder: System Settings → Privacy & Security → Automation → Sefirah → Finder."
        }
        if let message, !message.isEmpty { return message }
        if let number { return "Finder could not mount the volume (AppleScript error \(number))." }
        return "Finder could not mount the volume."
    }

    private func currentMountPoint(port: Int) async -> String? {
        guard let result = await Self.run("/sbin/mount", []) else { return nil }
        return PhoneMount.mountPoint(inMountOutput: result.output, port: port)
    }

    // MARK: - Unmounting

    /// Eject the phone's volume and stop its bridge, flushing rclone's cache on the way out.
    public func unmount(deviceID: String) async {
        guard let volume = volume(for: deviceID) else { return }
        update(deviceID) { $0.phase = .unmounting }
        runtimes[deviceID]?.livenessTask?.cancel()
        runtimes[deviceID]?.livenessTask = nil

        var ejected = false
        if let result = await Self.run("/usr/sbin/diskutil", ["unmount", volume.path]), result.status == 0 {
            ejected = true
        } else if let forced = await Self.run("/usr/sbin/diskutil", ["unmount", "force", volume.path]),
                  forced.status == 0
        {
            ejected = true
        }
        guard ejected else {
            let message = PhoneMountError
                .unmountFailed("“\(volume.name)” is still in use — close its files and try again.")
                .errorDescription
            update(deviceID) { $0.lastError = message; $0.phase = .mounted(volume) }
            watchLiveness(volume)
            return
        }

        await stopBridge(deviceID: deviceID)
        removeConfigFile(for: deviceID)
        clearStaleState(deviceID: deviceID)
        update(deviceID) { $0.phase = .idle }
        mountLog.info("unmounted \(volume.path, privacy: .public)")
    }

    /// Unmount every phone; used when the app is about to quit.
    public func unmountAll() async {
        for deviceID in mountedVolumes.map(\.deviceID) {
            await unmount(deviceID: deviceID)
        }
    }

    /// The phone disconnected: take its volume down too (other phones stay mounted).
    public func handleDisconnect(deviceID: String) {
        guard let volume = volume(for: deviceID) else { return }
        mountLog.info("phone disconnected; unmounting \(volume.path, privacy: .public)")
        Task { await self.unmount(deviceID: deviceID) }
    }

    /// Best-effort cleanup during app termination; anything left behind is picked up next launch.
    public func prepareForTermination() {
        for (deviceID, runtime) in runtimes {
            runtime.livenessTask?.cancel()
            runtime.livenessTask = nil
            if let volume = volume(for: deviceID) {
                let unmount = Process()
                unmount.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                unmount.arguments = ["unmount", "force", volume.path]
                try? unmount.run()
            }
            if let process = runtime.process {
                process.terminationHandler = nil
                if process.isRunning {
                    process.interrupt() // SIGINT lets rclone flush pending cache uploads
                }
            }
        }
        // Give every bridge a moment to flush before the process goes away.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, runtimes.values.contains(where: { $0.process?.isRunning == true }) {
            usleep(50_000)
        }
        for runtime in runtimes.values {
            if let process = runtime.process, process.isRunning { process.terminate() }
            runtime.pipe?.fileHandleForReading.readabilityHandler = nil
        }
    }

    // MARK: - Bridge lifecycle

    private func stopBridge(deviceID: String) async {
        guard let runtime = runtimes[deviceID] else { return }
        runtime.stopRequested = true
        defer {
            if let port = runtime.port { reservedPorts.remove(port) }
            runtime.pipe?.fileHandleForReading.readabilityHandler = nil
            runtime.pipe = nil
            runtime.process = nil
            runtime.collector = nil
            runtimes[deviceID] = nil
        }
        guard let process = runtime.process else { return }
        process.terminationHandler = nil
        guard process.isRunning else { return }

        process.interrupt() // SIGINT: rclone flushes the VFS cache and exits
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(120))
        }
        if process.isRunning {
            mountLog.notice("rclone ignored SIGINT; sending SIGTERM")
            process.terminate()
            let second = Date().addingTimeInterval(3)
            while process.isRunning, Date() < second {
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        if process.isRunning {
            mountLog.error("rclone still running; killing it")
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func bridgeDidExit(deviceID: String, status: Int32) {
        mountLog.info("rclone for \(deviceID, privacy: .public) exited with status \(status)")
        guard let runtime = runtimes[deviceID], !runtime.stopRequested else { return }
        let detail = runtime.collector?.recentLines().suffix(3).joined(separator: " — ") ?? ""
        switch phase(for: deviceID) {
        case .mounting:
            let message = PhoneMountError
                .bridgeFailedToStart(detail.isEmpty ? "the bridge exited during startup" : detail)
                .errorDescription
            update(deviceID) { $0.lastError = message; $0.phase = .idle }
        case .mounted(let volume):
            update(deviceID) { $0.lastError = "The phone volume disconnected unexpectedly."; $0.phase = .idle }
            Task { [weak self] in await self?.finishExternalTeardown(volume: volume) }
        case .idle, .unmounting:
            break
        }
    }

    private func finishExternalTeardown(volume: MountedVolume) async {
        let deviceID = volume.deviceID
        runtimes[deviceID]?.livenessTask?.cancel()
        runtimes[deviceID]?.livenessTask = nil
        _ = await Self.run("/usr/sbin/diskutil", ["unmount", "force", volume.path])
        await stopBridge(deviceID: deviceID)
        removeConfigFile(for: deviceID)
        clearStaleState(deviceID: deviceID)
    }

    /// Watches for the user ejecting the volume in Finder (the mount point simply disappears).
    private func watchLiveness(_ volume: MountedVolume) {
        let deviceID = volume.deviceID
        runtimes[deviceID]?.livenessTask?.cancel()
        runtimes[deviceID]?.livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                guard let self, !Task.isCancelled else { return }
                guard case .mounted(let current) = self.phase(for: deviceID), current == volume else { return }
                if !FileManager.default.fileExists(atPath: volume.path) {
                    mountLog.info("volume \(volume.path, privacy: .public) was ejected in Finder")
                    self.update(deviceID) { $0.phase = .idle }
                    await self.stopBridge(deviceID: deviceID)
                    self.removeConfigFile(for: deviceID)
                    self.clearStaleState(deviceID: deviceID)
                    return
                }
            }
        }
    }

    // MARK: - Session state

    private func update(_ deviceID: String, _ mutate: (inout Session) -> Void) {
        var session = sessions[deviceID] ?? Session()
        mutate(&session)
        sessions[deviceID] = session
    }

    // MARK: - Stale state

    private func cleanUpStaleState() async {
        var states = staleStates()
        if let legacy = defaults.data(forKey: Self.legacyStaleStateKey),
           let one = try? JSONDecoder().decode(StaleState.self, from: legacy)
        {
            states.append(one)
            defaults.removeObject(forKey: Self.legacyStaleStateKey)
        }
        setStaleStates([])
        for state in states {
            mountLog.notice("cleaning up leftover mount (pid \(state.pid), volume \(state.volumePath, privacy: .public))")
            if ProcInfo.executablePath(pid: state.pid)?.hasSuffix("/rclone") == true {
                kill(state.pid, SIGINT)
            }
            if FileManager.default.fileExists(atPath: state.volumePath) {
                _ = await Self.run("/usr/sbin/diskutil", ["unmount", "force", state.volumePath])
            }
            if FileManager.default.fileExists(atPath: state.configPath) {
                try? FileManager.default.removeItem(atPath: state.configPath)
            }
        }
    }

    private func staleStates() -> [StaleState] {
        guard let data = defaults.data(forKey: Self.staleStatesKey) else { return [] }
        return (try? JSONDecoder().decode([StaleState].self, from: data)) ?? []
    }

    private func setStaleStates(_ states: [StaleState]) {
        if states.isEmpty {
            defaults.removeObject(forKey: Self.staleStatesKey)
        } else if let data = try? JSONEncoder().encode(states) {
            defaults.set(data, forKey: Self.staleStatesKey)
        }
    }

    private func persistStaleState(_ state: StaleState) {
        var states = staleStates().filter { $0.deviceID != state.deviceID }
        states.append(state)
        setStaleStates(states)
    }

    private func clearStaleState(deviceID: String) {
        setStaleStates(staleStates().filter { $0.deviceID != deviceID })
    }

    private func removeConfigFile(for deviceID: String) {
        let configURL = supportDirectory
            .appendingPathComponent("PhoneMount", isDirectory: true)
            .appendingPathComponent(PhoneMount.mountConfigFileName(for: deviceID))
        try? FileManager.default.removeItem(at: configURL)
    }

    /// Loopback credentials Finder uses for the bridge; random per device and kept in defaults so
    /// macOS keychain entries stay stable across mounts.
    private func mountCredentials(for deviceID: String) -> (String, String) {
        let userKey = "PhoneMount.user.\(deviceID)"
        let passKey = "PhoneMount.pass.\(deviceID)"
        if let user = defaults.string(forKey: userKey), !user.isEmpty,
           let pass = defaults.string(forKey: passKey), !pass.isEmpty
        {
            return (user, pass)
        }
        let user = Self.randomToken(length: 12)
        let pass = Self.randomToken(length: 28)
        defaults.set(user, forKey: userKey)
        defaults.set(pass, forKey: passKey)
        return (user, pass)
    }

    private static func randomToken(length: Int) -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    // MARK: - Commands

    private struct CommandResult {
        var status: Int32
        var output: String
    }

    private nonisolated static func run(_ executable: String, _ arguments: [String]) async -> CommandResult? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: CommandResult(
                    status: process.terminationStatus,
                    output: String(data: data, encoding: .utf8) ?? ""
                ))
            }
        }
    }
}
