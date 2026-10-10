import Foundation

public struct AdbDevice: Equatable, Sendable {
    public var serial: String
    /// device | offline | unauthorized | …
    public var state: String
    /// "model:Pixel_7" from `devices -l`.
    public var model: String?
    public var isTcp: Bool { serial.contains(":") }

    public init(serial: String, state: String, model: String? = nil) {
        self.serial = serial
        self.state = state
        self.model = model
    }
}

public struct CommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunning: Sendable {
    func run(_ executable: URL, _ arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> CommandResult
}

public enum AdbError: Error, Equatable, LocalizedError {
    case spawnFailed(String)
    case timeout(command: String)
    case connectFailed(host: String, message: String)
    case noDeviceFound(model: String)
    case commandFailed(command: String, exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .spawnFailed(let message):
            return "Could not start adb: \(message)"
        case .timeout(let command):
            return "adb timed out: \(command)"
        case .connectFailed(let host, let message):
            return "adb could not connect to \(host): \(message)"
        case .noDeviceFound(let model):
            return "No device matching \(model) is reachable over USB, TCP/IP or wireless debugging."
        case .commandFailed(let command, let exitCode, let stderr):
            return "adb \(command) failed (exit \(exitCode))\(stderr.isEmpty ? "" : ": \(stderr)")"
        }
    }
}

/// Runs a short-lived command with Process + Pipes; kills it after `timeout`.
public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: URL, _ arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let command = ([executable.lastPathComponent] + arguments).joined(separator: " ")
        let box = OutputBox()
        out.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty { fh.readabilityHandler = nil } else { box.appendOut(data) }
        }
        err.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty { fh.readabilityHandler = nil } else { box.appendErr(data) }
        }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeOnce()
            process.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                box.appendOut(out.fileHandleForReading.availableData)
                box.appendErr(err.fileHandleForReading.availableData)
                resumed.run { continuation.resume(returning: proc.terminationStatus) }
            }
            do {
                try process.run()
            } catch {
                resumed.run { continuation.resume(throwing: AdbError.spawnFailed(error.localizedDescription)) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                box.markTimedOut()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        if box.timedOut { throw AdbError.timeout(command: command) }
        return CommandResult(exitCode: status, stdout: box.stdoutText, stderr: box.stderrText)
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        private var timedOutFlag = false
        func appendOut(_ d: Data) { lock.lock(); out.append(d); lock.unlock() }
        func appendErr(_ d: Data) { lock.lock(); err.append(d); lock.unlock() }
        func markTimedOut() { lock.lock(); timedOutFlag = true; lock.unlock() }
        var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOutFlag }
        var stdoutText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
        var stderrText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { body() }
        }
    }
}

/// Pure parsers for adb output.
public enum AdbOutput {
    public static func parseDevices(_ stdout: String) -> [AdbDevice] {
        var result: [AdbDevice] = []
        for rawLine in stdout.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("List of devices") || line.hasPrefix("*") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { continue }
            let model = parts.dropFirst(2).first { $0.hasPrefix("model:") }.map { String($0.dropFirst("model:".count)) }
            result.append(AdbDevice(serial: parts[0], state: parts[1], model: model))
        }
        return result
    }

    public static func connectSucceeded(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("connected to") && !text.contains("cannot connect") && !text.contains("failed to connect")
    }

    public static func modelMatches(adbModel: String?, peerModel: String) -> Bool {
        guard let adbModel else { return false }
        let a = normalize(adbModel), b = normalize(peerModel)
        return !a.isEmpty && a == b
    }

    static func normalize(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}

public struct AdbClient: Sendable {
    public var adb: URL
    public var environment: [String: String]
    public var runner: any CommandRunning
    /// Delay between `tcpip` and the retried `connect` (legacy used 200 ms).
    public var tcpipSettleDelay: TimeInterval = 0.2

    public init(adb: URL, environment: [String: String], runner: any CommandRunning = ProcessCommandRunner()) {
        self.adb = adb
        self.environment = environment
        self.runner = runner
    }

    /// `adb devices -l`
    public func devices() async throws -> [AdbDevice] {
        let result = try await runner.run(adb, ["devices", "-l"], environment: environment, timeout: 5)
        guard result.exitCode == 0 else {
            throw AdbError.commandFailed(command: "devices -l", exitCode: result.exitCode, stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return AdbOutput.parseDevices(result.stdout)
    }

    /// `adb connect host:port` → serial
    public func connect(host: String, port: Int = AdbTcpIp.defaultPort) async throws -> String {
        let target = "\(host):\(port)"
        let result = try await runner.run(adb, ["connect", target], environment: environment, timeout: 8)
        let combined = (result.stdout + "\n" + result.stderr)
        guard result.exitCode == 0, AdbOutput.connectSucceeded(combined) else {
            throw AdbError.connectFailed(host: target, message: combined.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return target
    }

    /// `adb -s serial tcpip port`
    public func tcpip(serial: String, port: Int = AdbTcpIp.defaultPort) async throws {
        let result = try await runner.run(adb, ["-s", serial, "tcpip", String(port)], environment: environment, timeout: 5)
        guard result.exitCode == 0 else {
            throw AdbError.commandFailed(command: "-s \(serial) tcpip \(port)", exitCode: result.exitCode, stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

// MARK: - Connection priority (USB → TCP/IP :6767 → wireless debugging)

/// The classic adb-over-TCP port Sefirah uses. Deliberately not 5555: Shizuku occupies 5555 on
/// the phone, so Sefirah's own ADB TCP/IP mode listens on 6767.
public enum AdbTcpIp {
    public static let defaultPort = 6767
}

/// Which transport an adb serial came from, in Sefirah's connection priority order.
public enum AdbConnectionKind: String, Sendable, Equatable {
    /// Priority 1 — a USB-attached device.
    case usb
    /// Priority 2 — classic `adb tcpip` on `AdbTcpIp.defaultPort` (`ip:6767`).
    case tcpip
    /// Priority 3 — Android 11+ wireless debugging (`adb pair` + mDNS).
    case wireless
}

public struct AdbConnection: Equatable, Sendable {
    public var kind: AdbConnectionKind
    public var serial: String

    public init(kind: AdbConnectionKind, serial: String) {
        self.kind = kind
        self.serial = serial
    }
}

/// Pure priority ordering over the adb serials the server already knows about. No side effects —
/// `AdbClient.resolveConnection` decides when to actively connect/switch.
public enum AdbConnectionPriority {
    /// USB (1st) → TCP/IP on `tcpipPort` (2nd) → any other TCP serial, i.e. wireless debugging
    /// (3rd). Only devices matching the peer by model or by the peer's network address qualify;
    /// duplicate serials are dropped.
    public static func candidates(
        devices: [AdbDevice],
        address: String,
        model: String,
        tcpipPort: Int = AdbTcpIp.defaultPort
    ) -> [AdbConnection] {
        let tcpTarget = "\(address):\(tcpipPort)"
        let matched = devices.filter { device in
            device.state == "device"
                && (AdbOutput.modelMatches(adbModel: device.model, peerModel: model)
                    || device.serial == tcpTarget
                    || device.serial.hasPrefix(address + ":"))
        }

        var result: [AdbConnection] = []
        var seen: Set<String> = []

        func add(_ kind: AdbConnectionKind, _ serial: String) {
            if seen.insert(serial).inserted { result.append(AdbConnection(kind: kind, serial: serial)) }
        }

        if let usb = matched.first(where: { !$0.isTcp }) {
            add(.usb, usb.serial)
        }
        if let tcp = matched.first(where: { $0.serial == tcpTarget })
            ?? matched.first(where: { $0.isTcp && $0.serial.hasSuffix(":\(tcpipPort)") })
        {
            add(.tcpip, tcp.serial)
        }
        for device in matched where device.isTcp { add(.wireless, device.serial) }
        return result
    }
}

extension AdbClient {
    /// Resolves the best adb serial for a peer, always trying the priorities in order:
    ///   1. USB — the matching USB device (also enabling `address:6767` behind it, best effort).
    ///   2. TCP/IP — `address:6767`, connecting it if the server doesn't already know it.
    ///   3. Wireless debugging — an already-paired `_adb-tls-connect` mDNS service.
    public func resolveConnection(
        address: String,
        model: String,
        tcpipPort: Int = AdbTcpIp.defaultPort,
        enableTcpIpOnUsb: Bool = true,
        connectWireless: Bool = true
    ) async -> AdbConnection? {
        let devices = (try? await devices()) ?? []
        let known = AdbConnectionPriority.candidates(
            devices: devices, address: address, model: model, tcpipPort: tcpipPort
        )

        // 1. USB wins, and we still open the classic TCP port so the phone stays reachable after
        //    the cable is unplugged — but USB remains the serial we hand back. Skipped when
        //    `address:6767` is already up, so repeated resolutions don't churn adbd.
        if let usb = known.first(where: { $0.kind == .usb }) {
            if enableTcpIpOnUsb, !known.contains(where: { $0.kind == .tcpip }) {
                _ = await enableTcpIp(serial: usb.serial, address: address, port: tcpipPort)
            }
            return usb
        }

        // 2. Classic TCP/IP on the configured port.
        if let tcpip = known.first(where: { $0.kind == .tcpip }) { return tcpip }
        if let serial = try? await connect(host: address, port: tcpipPort) {
            return AdbConnection(kind: .tcpip, serial: serial)
        }

        // 3. Wireless debugging.
        if connectWireless, let serial = await connectWirelessDevice(address: address) {
            return AdbConnection(kind: .wireless, serial: serial)
        }
        return known.first(where: { $0.kind == .wireless })
    }

    /// `adb -s serial tcpip <port>` then `adb connect address:<port>`. Best effort — returns the
    /// connected TCP serial on success, nil when the device can't be switched (the existing
    /// connection is kept, e.g. USB stays the live transport).
    @discardableResult
    public func enableTcpIp(
        serial: String,
        address: String,
        port: Int = AdbTcpIp.defaultPort
    ) async -> String? {
        do {
            try await tcpip(serial: serial, port: port)
        } catch {
            return nil
        }
        if tcpipSettleDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(tcpipSettleDelay * 1_000_000_000))
        }
        return try? await connect(host: address, port: port)
    }

    /// Connects to one already-paired wireless-debugging device (`_adb-tls-connect` mDNS service),
    /// preferring the service whose host is the peer's address and falling back to the only one
    /// visible. Returns the connected serial, or nil.
    public func connectWirelessDevice(address: String) async -> String? {
        guard let services = try? await mdnsServices() else { return nil }
        let connectServices = services.filter { $0.serviceType.hasPrefix(AdbWirelessPairing.connectServiceType) }
        guard let service = connectServices.first(where: { $0.host == address }) ?? (connectServices.count == 1 ? connectServices[0] : nil) else {
            return nil
        }
        return try? await connect(host: service.host, port: service.port)
    }
}

/// Pure port of the legacy DeviceSelection logic.
public enum ScrcpyDeviceSelection {
    /// nil = let scrcpy pick (exactly one device, or none visible — scrcpy reports that itself).
    public static func serial(devices: [AdbDevice], peerModel: String, preference: ScrcpyDevicePreferenceType) -> String? {
        let online = devices.filter { $0.state == "device" }
        guard online.count > 1 else { return nil }
        let matches = online.filter { AdbOutput.modelMatches(adbModel: $0.model, peerModel: peerModel) }
        guard !matches.isEmpty else { return nil }
        let usb = matches.first { !$0.isTcp }
        let tcp = matches.first { $0.isTcp }
        switch preference {
        case .usb: return usb?.serial ?? tcp?.serial
        case .tcpip: return tcp?.serial ?? usb?.serial
        case .auto, .askEverytime: return tcp?.serial ?? usb?.serial
        }
    }
}

/// Starts the paired Android companion in the background over adb. Its exported
/// `sefirah.network.NetworkService` accepts a `CONNECT` action and dials the last paired desktop,
/// which is what makes the normal TLS reconnect succeed when the app wasn't running.
public enum CompanionWake {
    public static let serviceComponent = "com.castle.sefirah/sefirah.network.NetworkService"
    public static let connectAction = "CONNECT"

    /// `am start-foreground-service -n <component> -a CONNECT`
    public static let shellArguments = [
        "am", "start-foreground-service", "-n", serviceComponent, "-a", connectAction,
    ]
}

/// Parses the phone's active media output route out of `adb shell dumpsys audio`.
public enum PhoneAudioRoute {
    /// Human label for the media stream's active output: "Phone speakers", "Bluetooth device" or
    /// "Headphones". Nil when the dump doesn't say or the route is something else.
    public static func label(fromDumpsysAudio dump: String) -> String? {
        var inMusicStream = false
        for rawLine in dump.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- STREAM_MUSIC") {
                inMusicStream = true
                continue
            }
            if line.hasPrefix("- STREAM_") {
                inMusicStream = false
                continue
            }
            guard inMusicStream, line.hasPrefix("Devices:") else { continue }
            let devices = line.lowercased()
            if devices.contains("speaker") { return "Phone speakers" }
            if devices.contains("bt_") || devices.contains("bluetooth") { return "Bluetooth device" }
            if devices.contains("wired") || devices.contains("headset") || devices.contains("headphones") {
                return "Headphones"
            }
            return nil
        }
        return nil
    }
}

/// Android key codes for the media transport controls. Sent over adb when the phone is
/// reachable, since the companion app cannot dispatch media sessions with the screen off.
public enum MediaKeyEvent {
    public static func keyCode(for action: MediaActionType) -> Int? {
        switch action {
        case .play: 126
        case .pause: 127
        case .stop: 86
        case .next: 87
        case .previous: 88
        default: nil
        }
    }
}

extension AdbClient {
    /// Resolves the device with the connection priority (USB → TCP/IP → wireless debugging) and
    /// asks the companion app to start its network service in the background.
    public func wakeCompanion(host: String, model: String) async throws {
        guard let connection = await resolveConnection(address: host, model: model) else {
            throw AdbError.noDeviceFound(model: model)
        }
        let result = try await shell(serial: connection.serial, CompanionWake.shellArguments, timeout: 10)
        guard result.exitCode == 0 else {
            throw AdbError.commandFailed(
                command: "start-foreground-service",
                exitCode: result.exitCode,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}

// MARK: - Native mirror helpers (all thread `-s serial`)

extension AdbClient {
    /// `adb -s serial push local remote`
    public func push(serial: String, local: URL, remote: String, timeout: TimeInterval = 20) async throws {
        let result = try await runner.run(adb, ["-s", serial, "push", local.path, remote], environment: environment, timeout: timeout)
        guard result.exitCode == 0 else {
            throw AdbError.commandFailed(command: "-s \(serial) push", exitCode: result.exitCode, stderr: Self.trim(result.stderr + result.stdout))
        }
    }

    /// `adb -s serial forward tcp:0 localabstract:<socketName>` → the port adb picked (first stdout line).
    public func forward(serial: String, socketName: String) async throws -> UInt16 {
        let result = try await runner.run(adb, ["-s", serial, "forward", "tcp:0", "localabstract:\(socketName)"], environment: environment, timeout: 5)
        guard result.exitCode == 0, let port = AdbOutput.parseForwardPort(result.stdout) else {
            throw AdbError.commandFailed(command: "-s \(serial) forward", exitCode: result.exitCode, stderr: Self.trim(result.stderr + result.stdout))
        }
        return port
    }

    /// `adb -s serial forward --remove tcp:<port>`
    public func forwardRemove(serial: String, port: UInt16) async throws {
        let result = try await runner.run(adb, ["-s", serial, "forward", "--remove", "tcp:\(port)"], environment: environment, timeout: 5)
        guard result.exitCode == 0 else {
            throw AdbError.commandFailed(command: "-s \(serial) forward --remove", exitCode: result.exitCode, stderr: Self.trim(result.stderr))
        }
    }

    /// `adb -s serial shell <command…>`; returns the raw result (callers decide what an error is).
    public func shell(serial: String, _ command: [String], timeout: TimeInterval = 5) async throws -> CommandResult {
        try await runner.run(adb, ["-s", serial, "shell"] + command, environment: environment, timeout: timeout)
    }

    /// `adb shell <command…>` without `-s`; adb picks the single attached device, exactly the rule
    /// scrcpy itself applies when it launches without `--serial`.
    public func shell(_ command: [String], timeout: TimeInterval = 5) async throws -> CommandResult {
        try await runner.run(adb, ["shell"] + command, environment: environment, timeout: timeout)
    }

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension AdbOutput {
    /// `adb forward tcp:0 …` prints the assigned port ("62990\n"); older adbs print nothing for explicit ports.
    public static func parseForwardPort(_ stdout: String) -> UInt16? {
        for line in stdout.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let port = UInt16(trimmed), port > 0 { return port }
        }
        return nil
    }
}
