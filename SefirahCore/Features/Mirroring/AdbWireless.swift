import Foundation

/// One row from `adb mdns services` — an mDNS service the adb server currently sees on the LAN.
public struct AdbMdnsService: Equatable, Sendable {
    /// The service instance name, e.g. `adbqr-1a2b3c4d`.
    public var instance: String
    /// The service type, e.g. `_adb-tls-pairing._tcp.`.
    public var serviceType: String
    public var host: String
    public var port: Int

    public init(instance: String, serviceType: String, host: String, port: Int) {
        self.instance = instance
        self.serviceType = serviceType
        self.host = host
        self.port = port
    }
}

/// Helpers for Android 11+ "Wireless debugging" pairing over a QR code.
///
/// The QR only carries a service name and a password. After the phone scans it, the phone
/// advertises an `_adb-tls-pairing` mDNS service under that name, and the desktop pairs with
/// `adb pair`, which runs the actual SPAKE2/TLS handshake. No cryptography is implemented here.
public enum AdbWirelessPairing {
    public static let pairingServiceType = "_adb-tls-pairing"
    public static let connectServiceType = "_adb-tls-connect"

    /// The string encoded in the QR, e.g. `WIFI:T:ADB;S:sefirah-ab12cd34;P:9xQ2…;;`.
    public static func qrText(serviceName: String, password: String) -> String {
        "WIFI:T:ADB;S:\(serviceName);P:\(password);;"
    }

    /// Random mDNS service name (`S:`), e.g. `sefirah-1a2b3c4d`.
    public static func randomServiceName() -> String {
        "sefirah-" + String((0..<8).map { _ in "0123456789abcdef".randomElement()! })
    }

    /// Random pairing password (`P:`), matching the alphabet adb pairing codes use.
    public static func randomPassword() -> String {
        let alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<12).map { _ in alphabet.randomElement()! })
    }

    /// The phone normally echoes the QR's `S:` in the pairing service instance name. Some
    /// devices publish a different name, so a lone pairing service is accepted as a fallback —
    /// the password still guards against pairing with the wrong device.
    public static func pairingService(in services: [AdbMdnsService], name: String) -> AdbMdnsService? {
        let pairing = services.filter { $0.serviceType.hasPrefix(pairingServiceType) }
        if let match = pairing.first(where: { $0.instance == name }) { return match }
        return pairing.count == 1 ? pairing[0] : nil
    }

    /// The `_adb-tls-connect` service of the phone we just paired: match by host, else accept a
    /// lone connect service.
    public static func connectService(in services: [AdbMdnsService], host: String) -> AdbMdnsService? {
        let connect = services.filter { $0.serviceType.hasPrefix(connectServiceType) }
        if let match = connect.first(where: { $0.host == host }) { return match }
        return connect.count == 1 ? connect[0] : nil
    }
}

extension AdbClient {
    /// `adb mdns check` — non-empty non-error output contains the daemon version when available.
    @discardableResult
    public func mdnsCheck() async throws -> String {
        let result = try await runner.run(adb, ["mdns", "check"], environment: environment, timeout: 5)
        return result.stdout + result.stderr
    }

    /// `adb mdns services` — the `_adb-tls-*` services the adb server currently sees.
    public func mdnsServices() async throws -> [AdbMdnsService] {
        let result = try await runner.run(adb, ["mdns", "services"], environment: environment, timeout: 5)
        guard result.exitCode == 0 else {
            throw AdbError.commandFailed(
                command: "mdns services",
                exitCode: result.exitCode,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return AdbOutput.parseMdnsServices(result.stdout)
    }

    /// `adb pair host:port code` — the actual pairing handshake (SPAKE2 + TLS), run by adb.
    public func pair(host: String, port: Int, code: String) async throws {
        let target = "\(host):\(port)"
        let result = try await runner.run(adb, ["pair", target, code], environment: environment, timeout: 30)
        let combined = result.stdout + "\n" + result.stderr
        guard result.exitCode == 0, AdbOutput.pairSucceeded(combined) else {
            throw AdbError.commandFailed(
                command: "pair \(target)",
                exitCode: result.exitCode,
                stderr: combined.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}

extension AdbOutput {
    /// Parses `adb mdns services` rows: `instance  _service._tcp.  ip:port`.
    public static func parseMdnsServices(_ stdout: String) -> [AdbMdnsService] {
        var result: [AdbMdnsService] = []
        for rawLine in stdout.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts: [String]
            if line.contains("\t") {
                parts = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            } else {
                parts = line.split(whereSeparator: { $0 == " " }).map(String.init)
            }
            let fields = parts.filter { !$0.isEmpty }
            guard fields.count >= 3, fields[1].hasPrefix("_adb-tls-") else { continue }
            let endpoint = fields[2]
            guard let colon = endpoint.lastIndex(of: ":") else { continue }
            let host = String(endpoint[endpoint.startIndex..<colon])
            let portText = String(endpoint[endpoint.index(after: colon)...])
            guard !host.isEmpty, let port = Int(portText) else { continue }
            result.append(AdbMdnsService(instance: fields[0], serviceType: fields[1], host: host, port: port))
        }
        return result
    }

    /// `adb pair` success text. Mirrors the legacy Windows check: failure words win, and success
    /// is marked by "successfully paired" (adb reports "already paired" for a repeat).
    public static func pairSucceeded(_ output: String) -> Bool {
        let text = output.lowercased()
        if text.contains("cannot connect") || text.contains("cannot resolve")
            || text.contains("failed to authenticate") || text.contains("failed to connect")
            || text.contains("unable to connect")
        {
            return false
        }
        return text.contains("successfully paired") || text.contains("already paired")
    }
}
