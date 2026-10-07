import AppKit
import Foundation

/// Generates the small app bundle the external scrcpy is launched through so macOS shows
/// Sefirah's phone icon and name in the Dock instead of the generic executable icon.
///
/// LaunchServices is required for that association: directly executing a binary inside a bundle
/// keeps the bare-process identity on recent macOS. The bundle's executable is a copy of `/bin/sh`
/// (LaunchServices refuses script executables) running a generated script that `exec`s the chosen
/// scrcpy binary in place — bundled or custom — so the binary keeps its own `scrcpy-server`
/// lookup. The script records its pid and redirects output to a per-launch log, which
/// `ScrcpyAppRunner` uses to watch and diagnose the process.
///
/// The wrapper lives under Application Support and is refreshed when the scrcpy path or binary changes.
@MainActor
enum ScrcpyAppWrapper {
    nonisolated static let bundleIdentifier = "io.github.madeye.sefirah.mirror"
    nonisolated static let appName = "Sefirah Mirror"
    /// How much of a run's log is kept for diagnostics.
    nonisolated static let logTailBytes = 16 * 1024

    struct Prepared {
        var app: URL
        var launchScript: URL
        var logDirectory: URL
        /// Device-side server the runner should pass as `SCRCPY_SERVER_PATH` when the app's
        /// environment does not already set it.
        var serverPath: URL?
        /// Directory holding `scrcpy.png` / `disconnected.png`; passed as `SCRCPY_ICON_DIR` so
        /// scrcpy sets Sefirah's icon as the app/window icon instead of its own logo.
        var iconDirectory: URL
    }

    /// Returns the prepared wrapper for `scrcpy`, generating or refreshing it as needed. nil when
    /// it cannot be prepared (callers fall back to launching the binary directly).
    ///
    /// The binary is copied into the wrapper so the running process resolves its main bundle to
    /// the wrapper (and keeps Sefirah's Dock icon after launch); that requires a known
    /// `scrcpy-server`, taken from the environment or discovered next to the binary. When none is
    /// found the script execs the original path instead (mirror works, icon may revert).
    static func prepare(scrcpy: URL, environment: [String: String]) -> Prepared? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let root = support.appendingPathComponent("Sefirah", isDirectory: true)
        let app = root.appendingPathComponent("\(appName).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let launchScript = resources.appendingPathComponent("launch.sh")
        let iconDirectory = resources.appendingPathComponent("icons", isDirectory: true)
        // Runtime files live outside the bundle: writing into a signed app would invalidate it.
        let logDirectory = root.appendingPathComponent("MirrorLogs", isDirectory: true)

        let server = environment["SCRCPY_SERVER_PATH"].map { URL(fileURLWithPath: $0) }
            ?? discoverServer(for: scrcpy)
        let copyBinary = server != nil

        if !isCurrent(scrcpy: scrcpy, copyBinary: copyBinary, server: server, contents: contents, launchScript: launchScript) {
            guard (try? assemble(
                scrcpy: scrcpy,
                copyBinary: copyBinary,
                server: server,
                app: app,
                contents: contents,
                resources: resources,
                launchScript: launchScript,
                iconDirectory: iconDirectory
            )) != nil else { return nil }
        }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: launchScript.path),
              fm.isExecutableFile(atPath: contents.appendingPathComponent("MacOS/sh").path)
        else { return nil }
        try? fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        return Prepared(
            app: app,
            launchScript: launchScript,
            logDirectory: logDirectory,
            serverPath: server,
            iconDirectory: iconDirectory
        )
    }

    /// Looks for the device-side server next to the scrcpy binary or in its prefix.
    private static func discoverServer(for scrcpy: URL) -> URL? {
        let directory = scrcpy.deletingLastPathComponent()
        let candidates = [
            directory.appendingPathComponent("scrcpy-server"),
            directory.deletingLastPathComponent().appendingPathComponent("share/scrcpy/scrcpy-server"),
            directory.deletingLastPathComponent().appendingPathComponent("Resources/scrcpy-server"),
            URL(fileURLWithPath: "/opt/homebrew/share/scrcpy/scrcpy-server"),
            URL(fileURLWithPath: "/usr/local/share/scrcpy/scrcpy-server"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Wrapper assembly

    private static func assemble(
        scrcpy: URL,
        copyBinary: Bool,
        server: URL?,
        app: URL,
        contents: URL,
        resources: URL,
        launchScript: URL,
        iconDirectory: URL
    ) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: app)
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        let sh = contents.appendingPathComponent("MacOS/sh")
        try fm.copyItem(at: URL(fileURLWithPath: "/bin/sh"), to: sh)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sh.path)

        if copyBinary {
            // The canonical location matters: Foundation resolves the main bundle from
            // Contents/MacOS, so the running scrcpy keeps the wrapper's Dock icon/name.
            let target = contents.appendingPathComponent("MacOS/scrcpy")
            try fm.copyItem(at: scrcpy, to: target)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            signNested(target)
        }

        try script(scrcpy: scrcpy, copyBinary: copyBinary).write(to: launchScript, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchScript.path)

        try infoPlist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try writeIcon(to: resources.appendingPathComponent("AppIcon.icns"))
        try writeScrcpyIcons(to: iconDirectory)
        try stampValue(for: scrcpy, server: server, copyBinary: copyBinary).write(
            to: resources.appendingPathComponent("wrapper-stamp"),
            atomically: true,
            encoding: .utf8
        )
        // Gatekeeper refuses to launch an unsigned bundle; ad-hoc signing and registering fixes it.
        try sign(app)
        registerWithLaunchServices(app)
    }

    private static func isCurrent(
        scrcpy: URL,
        copyBinary: Bool,
        server: URL?,
        contents: URL,
        launchScript: URL
    ) -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: contents.appendingPathComponent("MacOS/sh").path),
              fm.isExecutableFile(atPath: launchScript.path),
              !copyBinary || fm.isExecutableFile(atPath: contents.appendingPathComponent("MacOS/scrcpy").path),
              fm.fileExists(atPath: contents.appendingPathComponent("Resources/icons/scrcpy.png").path),
              fm.fileExists(atPath: contents.appendingPathComponent("Resources/icons/disconnected.png").path),
              let stamp = try? String(contentsOf: contents.appendingPathComponent("Resources/wrapper-stamp"), encoding: .utf8),
              let expected = try? stampValue(for: scrcpy, server: server, copyBinary: copyBinary)
        else { return false }
        return stamp == expected
    }

    private static func stampValue(for scrcpy: URL, server: URL?, copyBinary: Bool) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: scrcpy.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        // The leading version forces a rebuild whenever the wrapper's generated contents change.
        return "v2:\(scrcpy.path):\(size):\(modified):\(copyBinary ? server?.path ?? "" : "-")"
    }

    /// Ad-hoc signs the freshly assembled bundle. Nested code (the scrcpy copy in `MacOS`) is
    /// signed separately first; `--deep` is deliberately avoided.
    private static func sign(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--timestamp=none", app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Gives the copied binary a valid ad-hoc signature so the wrapper bundle seals cleanly.
    private static func signNested(_ binary: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--timestamp=none", binary.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Indexes the fresh wrapper so the Dock can resolve its icon and name before the first
    /// process check-in. Best effort: failures only cost the custom icon.
    private static func registerWithLaunchServices(_ app: URL) {
        let lsregister = URL(
            fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        )
        guard FileManager.default.isExecutableFile(atPath: lsregister.path) else { return }
        let process = Process()
        process.executableURL = lsregister
        process.arguments = ["-f", app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Icon

    private static func writeIcon(to destination: URL) throws {
        let fm = FileManager.default
        let iconset = destination.deletingLastPathComponent().appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try? fm.removeItem(at: iconset)
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: iconset) }

        let variants: [(name: String, pixels: Int)] = [
            ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
        ]
        for variant in variants {
            guard let bitmap = SefirahIcon.bitmap(pixels: variant.pixels),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: iconset.appendingPathComponent(variant.name))
        }

        let iconutil = Process()
        iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        iconutil.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
        try iconutil.run()
        iconutil.waitUntilExit()
        guard iconutil.terminationStatus == 0, fm.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// scrcpy replaces the app icon with `scrcpy.png` from `SCRCPY_ICON_DIR` (and
    /// `disconnected.png` when the device drops); provide Sefirah's icon there so the Dock keeps it.
    private static func writeScrcpyIcons(to directory: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let bitmap = SefirahIcon.bitmap(pixels: 256),
              let png = bitmap.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: directory.appendingPathComponent("scrcpy.png"))
        try png.write(to: directory.appendingPathComponent("disconnected.png"))
    }

    // MARK: - Bundle metadata

    /// `$1` is a per-launch token and `$2` the log directory; the rest are scrcpy arguments.
    /// The pid written here survives `exec`, so the app can terminate and watch the real process.
    /// The copy inside the bundle is preferred: the process then resolves its main bundle to the
    /// wrapper, which is what keeps Sefirah's Dock icon after launch.
    private static func script(scrcpy: URL, copyBinary: Bool) -> String {
        let target = copyBinary ? "\"$DIR/../MacOS/scrcpy\"" : shellQuote(scrcpy.path)
        return """
        #!/bin/sh
        # Generated by Sefirah.
        TOKEN="$1"
        LOG_DIR="$2"
        shift 2
        DIR="$(cd "$(dirname "$0")" && pwd)"
        mkdir -p "$LOG_DIR"
        echo $$ > "$LOG_DIR/$TOKEN.pid"
        exec \(target) "$@" >"$LOG_DIR/$TOKEN.log" 2>&1
        """
    }

    /// Single-quotes a path for `/bin/sh` (embedded quotes are escaped the POSIX way).
    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let infoPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>CFBundleDevelopmentRegion</key>
    \t<string>en</string>
    \t<key>CFBundleExecutable</key>
    \t<string>sh</string>
    \t<key>CFBundleIdentifier</key>
    \t<string>\(bundleIdentifier)</string>
    \t<key>CFBundleInfoDictionaryVersion</key>
    \t<string>6.0</string>
    \t<key>CFBundleName</key>
    \t<string>\(appName)</string>
    \t<key>CFBundleDisplayName</key>
    \t<string>\(appName)</string>
    \t<key>CFBundleIconFile</key>
    \t<string>AppIcon</string>
    \t<key>CFBundlePackageType</key>
    \t<string>APPL</string>
    \t<key>CFBundleShortVersionString</key>
    \t<string>1.0</string>
    \t<key>CFBundleVersion</key>
    \t<string>1</string>
    \t<key>LSMinimumSystemVersion</key>
    \t<string>14.0</string>
    \t<key>NSHighResolutionCapable</key>
    \t<true/>
    \t<key>LSApplicationCategoryType</key>
    \t<string>public.app-category.utilities</string>
    </dict>
    </plist>
    """
}
