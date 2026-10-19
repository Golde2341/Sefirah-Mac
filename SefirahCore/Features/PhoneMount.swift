import CommonCrypto
import Darwin
import Foundation

// MARK: - rclone obscure

/// rclone's `obscure` transform: AES-256-CTR under a fixed key with the IV prepended, encoded
/// base64url without padding.
///
/// rclone config files expect password values in this form, so `PhoneMount` writes the phone's
/// SFTP password through ``obscure(_:)``. The implementation is kept byte-compatible with
/// upstream: anything it writes round-trips through `rclone reveal`.
public enum RcloneCipher {
    static let key: [UInt8] = [
        0x9c, 0x93, 0x5b, 0x48, 0x73, 0x0a, 0x55, 0x4d,
        0x6b, 0xfd, 0x7c, 0x63, 0xc8, 0x86, 0xa9, 0x2b,
        0xd3, 0x90, 0x19, 0x8e, 0xb8, 0x12, 0x8a, 0xfb,
        0xf4, 0xde, 0x16, 0x2b, 0x8b, 0x95, 0xf6, 0x38,
    ]

    /// Obscure `plaintext` the way `rclone obscure` does. A fresh random IV is prepended, so the
    /// output differs between calls.
    public static func obscure(_ plaintext: String) -> String? {
        let iv = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        guard iv.count == 16, let ciphertext = aesCTR(Data(plaintext.utf8), iv: iv) else {
            return nil
        }
        return base64URLEncode(iv + ciphertext)
    }

    /// Reveal a value produced by `rclone obscure` (or ``obscure(_:)``); nil when the input is not
    /// an obscured value.
    public static func reveal(_ obscured: String) -> String? {
        guard let data = base64URLDecode(obscured), data.count > 16 else { return nil }
        guard let plaintext = aesCTR(Data(data.dropFirst(16)), iv: Data(data.prefix(16))) else {
            return nil
        }
        return String(data: plaintext, encoding: .utf8)
    }

    /// AES-256-CTR (big-endian counter, matching Go's `cipher.NewCTR`).
    private static func aesCTR(_ input: Data, iv: Data) -> Data? {
        var cryptor: CCCryptorRef?
        let created = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBytes.baseAddress,
                    keyBytes.baseAddress,
                    key.count,
                    nil,
                    0,
                    0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }
        guard created == kCCSuccess, let cryptor else { return nil }
        defer { CCCryptorRelease(cryptor) }

        var output = Data(count: input.count)
        var moved = 0
        let updated = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                CCCryptorUpdate(
                    cryptor,
                    inputBytes.baseAddress,
                    input.count,
                    outputBytes.baseAddress,
                    input.count,
                    &moved
                )
            }
        }
        return updated == kCCSuccess ? output : nil
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var padded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        return Data(base64Encoded: padded)
    }
}

// MARK: - Mount configuration

/// Everything the bridge needs to expose the phone's storage as a local WebDAV volume.
public struct PhoneMountConfiguration: Sendable, Equatable {
    /// Name shown for the volume in Finder (`/Volumes/<name>`).
    public var volumeName: String
    /// Phone address as the Mac reaches it (its paired IP).
    public var host: String
    /// Phone SFTP port.
    public var port: Int
    /// Phone SFTP credentials.
    public var username: String
    public var password: String
    /// Phone path served as the volume root (usually the primary storage root).
    public var basePath: String
    /// Local loopback port the bridge listens on.
    public var localPort: Int
    /// Credentials macOS uses to reach the loopback bridge (stored per device).
    public var mountUsername: String
    public var mountPassword: String
    /// rclone config written for this mount (deleted on unmount).
    public var configPath: String
    /// rclone's VFS cache directory (kept between mounts so pending uploads resume).
    public var cacheDirectory: String

    public init(
        volumeName: String,
        host: String,
        port: Int,
        username: String,
        password: String,
        basePath: String,
        localPort: Int,
        mountUsername: String,
        mountPassword: String,
        configPath: String,
        cacheDirectory: String
    ) {
        self.volumeName = volumeName
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.basePath = basePath
        self.localPort = localPort
        self.mountUsername = mountUsername
        self.mountPassword = mountPassword
        self.configPath = configPath
        self.cacheDirectory = cacheDirectory
    }
}

/// rclone remote names used by the generated config; never change them — the VFS cache is keyed
/// by remote path, so a rename would orphan pending uploads.
enum PhoneMountRemote {
    static let sftp = "sefirah-phone"
    static let combine = "sefirah-mount"
}

// MARK: - Command building

/// Pure builders for everything the mount bridge runs. Kept free of processes and UI so the
/// pieces can be unit-tested; ``PhoneMountController`` wires them to rclone and Finder.
public enum PhoneMount {
    /// Default first candidate for the loopback bridge port.
    public static let defaultPortBase = 53420
    /// How many ports above the base are tried before giving up.
    public static let defaultPortCount = 40

    /// Suffix-free host name the bridge is mounted through once the user installed the
    /// `/etc/hosts` alias, so Finder's sidebar row reads just "Sefirah".
    public static let finderHostName = "Sefirah"
    /// Bonjour name that publishes this Mac's loopback address for the bridge. mDNS host names
    /// always end in `.local`, so this is the no-setup fallback for Finder's label.
    public static let bonjourHostName = "Sefirah.local"

    /// Sanitised volume name: letters, digits, spaces, `.`, `_` and `-` survive; anything else
    /// becomes a space. Falls back to "Phone" and is capped so Finder always has a usable name.
    public static func volumeName(for raw: String, fallback: String = "Phone") -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._-")
        let mapped = String(raw.unicodeScalars.map { scalar in
            allowed.contains(Character(scalar)) ? Character(scalar) : " "
        })
        let collapsed = mapped.split(separator: " ").joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " ._"))
        let capped = String(trimmed.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: " ._"))
        return capped.isEmpty ? fallback : capped
    }

    /// Volume name that doesn't clash with another mounted phone: "Pixel 8" becomes "Pixel 8 2".
    /// Keeps two devices with the same reported name from fighting over one `/Volumes` entry.
    public static func disambiguatedVolumeName(_ preferred: String, taken: Set<String>) -> String {
        guard taken.contains(preferred) else { return preferred }
        for index in 2...20 {
            let candidate = "\(preferred) \(index)"
            if !taken.contains(candidate) { return candidate }
        }
        return "\(preferred) \(UUID().uuidString.prefix(4))"
    }

    /// Device ids become file names for the per-device bridge config and cache.
    public static func safeIdentifier(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let mapped = String(raw.unicodeScalars.map { scalar in
            allowed.contains(Character(scalar)) ? Character(scalar) : "-"
        })
        return mapped.isEmpty ? "device" : mapped
    }

    /// Per-device rclone config file name inside the support directory's `PhoneMount` folder.
    public static func mountConfigFileName(for deviceID: String) -> String {
        "rclone-\(safeIdentifier(deviceID)).conf"
    }

    /// Per-device cache directory name inside the support directory's `PhoneMount` folder.
    public static func mountCacheDirectoryName(for deviceID: String) -> String {
        "cache-\(safeIdentifier(deviceID))"
    }

    /// True when `/etc/hosts`-style `contents` maps `name` to the loopback address the bridge
    /// listens on (127.0.0.1). Comments and blank lines are ignored, matching is case-insensitive.
    public static func hostsFileMapsLoopback(_ contents: String, name: String) -> Bool {
        let wanted = name.lowercased()
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine
            if let hash = line.firstIndex(of: "#") { line = line[..<hash] }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == "127.0.0.1" else { continue }
            if fields.dropFirst().contains(where: { $0.lowercased() == wanted }) { return true }
        }
        return false
    }

    /// rclone config for the mount: an SFTP remote pointed at the phone plus a `combine` remote
    /// that gives the served tree a top-level entry with the volume's name.
    public static func configFile(_ configuration: PhoneMountConfiguration) -> String {
        let obscured = RcloneCipher.obscure(configuration.password) ?? ""
        let upstream = "\(iniValue(configuration.volumeName))=\(PhoneMountRemote.sftp):\(iniValue(pathValue(configuration.basePath)))"
        return """
        # Generated by Sefirah for the Finder mount; deleted when the volume is unmounted.
        [\(PhoneMountRemote.sftp)]
        type = sftp
        host = \(iniValue(configuration.host))
        port = \(configuration.port)
        user = \(iniValue(configuration.username))
        pass = \(obscured)
        shell_type = none

        [\(PhoneMountRemote.combine)]
        type = combine
        upstreams = "\(upstream)"

        """
    }

    /// `rclone serve webdav` invocation for the bridge.
    public static func arguments(_ configuration: PhoneMountConfiguration) -> [String] {
        [
            "serve", "webdav", "\(PhoneMountRemote.combine):",
            "--config", configuration.configPath,
            "--addr", "127.0.0.1:\(configuration.localPort)",
            "--user", configuration.mountUsername,
            "--pass", configuration.mountPassword,
            "--vfs-cache-mode", "writes",
            "--vfs-cache-max-size", "2G",
            "--vfs-cache-max-age", "24h",
            "--cache-dir", configuration.cacheDirectory,
            "--dir-cache-time", "5s",
            "--contimeout", "15s",
            "--timeout", "1m",
            "--log-level", "INFO",
            "--stats", "0",
        ]
    }

    /// Loopback WebDAV URL handed to Finder. The last path component becomes the volume name and
    /// `host` is the name Finder shows in its sidebar (a branded loopback name by default).
    public static func mountURL(
        _ configuration: PhoneMountConfiguration,
        host: String = "127.0.0.1"
    ) -> String {
        let user = configuration.mountUsername
            .addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? configuration.mountUsername
        let password = configuration.mountPassword
            .addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? configuration.mountPassword
        let name = configuration.volumeName
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? configuration.volumeName
        return "http://\(user):\(password)@\(host):\(configuration.localPort)/\(name)/"
    }

    /// AppleScript that asks Finder to mount the bridge volume. The explicit timeout keeps a
    /// wedged Finder from hanging the app.
    public static func appleScriptMountScript(url: String, timeoutSeconds: Int = 45) -> String {
        let escaped = url
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        with timeout of \(timeoutSeconds) seconds
            mount volume "\(escaped)"
        end timeout
        """
    }

    /// Extract the mount point of the bridge volume from `mount(8)` output. Matches on the
    /// loopback port (Finder may have mounted through a host name rather than the raw address)
    /// so a stale volume with the same name can't be picked up.
    public static func mountPoint(inMountOutput output: String, port: Int) -> String? {
        let needle = ":\(port)/"
        for line in output.split(separator: "\n") {
            guard line.contains(needle) else { continue }
            guard let onRange = line.range(of: " on ") else { continue }
            let remainder = line[onRange.upperBound...]
            guard let parenRange = remainder.range(of: " (") else { continue }
            let path = remainder[..<parenRange.lowerBound].trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { return path }
        }
        return nil
    }

    /// `mount(8)` source string for the bridge volume (used to recognise our own mounts).
    public static func mountSource(port: Int) -> String {
        "http://127.0.0.1:\(port)/"
    }

    private static func pathValue(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "/" : trimmed
    }

    /// Keep values safe for the config file's single-line `key = value` format.
    private static func iniValue(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }
}

// MARK: - Local helpers

/// Picks the loopback port for the bridge.
public enum PortAllocator {
    /// First port in `base..<base+count` for which `probe` reports free; nil when all are taken.
    public static func firstFreePort(
        from base: Int = PhoneMount.defaultPortBase,
        count: Int = PhoneMount.defaultPortCount,
        probe: (Int) -> Bool = PortProbe.isFree
    ) -> Int? {
        for port in base..<(base + count) where probe(port) {
            return port
        }
        return nil
    }
}

/// Loopback port availability via a bind test.
public enum PortProbe {
    /// True when a TCP socket can bind `127.0.0.1:<port>` right now.
    public static func isFree(_ port: Int) -> Bool {
        guard port > 0, port < 65_536 else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

/// Process inspection used to recognise leftover bridge processes from a previous run.
public enum ProcInfo {
    /// Executable path of a running process, or nil when no such process exists.
    public static func executablePath(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is a C macro Swift can't import.
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}

// MARK: - Errors

/// Failures surfaced while mounting or unmounting the phone volume.
public enum PhoneMountError: Error, LocalizedError, Equatable {
    case rcloneMissing
    case bridgeFailedToStart(String)
    case mountScriptFailed(String)
    case mountPointNotFound
    case unmountFailed(String)
    case noPortAvailable

    public var errorDescription: String? {
        switch self {
        case .rcloneMissing:
            return "The bundled rclone helper is missing — run scripts/fetch-rclone.sh and rebuild Sefirah."
        case .bridgeFailedToStart(let detail):
            return detail.isEmpty
                ? "The mount bridge failed to start."
                : "The mount bridge failed to start: \(detail)"
        case .mountScriptFailed(let detail):
            return detail
        case .mountPointNotFound:
            return "macOS mounted the volume but its mount point could not be found."
        case .unmountFailed(let detail):
            return detail.isEmpty
                ? "Could not unmount the phone volume."
                : "Could not unmount the phone volume: \(detail)"
        case .noPortAvailable:
            return "No free local port is available for the mount bridge."
        }
    }
}
