import AppKit
import Darwin
import Foundation
import OSLog
import SefirahCore

enum ScrcpyAppRunnerError: LocalizedError {
    case wrapperUnavailable
    case launchFailed(String)
    case processIdentifierUnavailable

    var errorDescription: String? {
        switch self {
        case .wrapperUnavailable:
            "Could not prepare the Sefirah Mirror helper app."
        case .launchFailed(let message):
            "Could not launch scrcpy through LaunchServices: \(message)"
        case .processIdentifierUnavailable:
            "scrcpy launched but its process could not be located."
        }
    }
}

/// Runs the external scrcpy through its generated wrapper app via LaunchServices, which is what
/// makes macOS show Sefirah's icon and name in the Dock. The wrapper's script stub records the
/// pid and captures output, so this runner can terminate the process and diagnose its exit
/// without a wait status (LaunchServices does not provide one).
final class ScrcpyAppRunner: ScrcpyRunning, @unchecked Sendable {
    private static let log = Logger(subsystem: "io.github.madeye.sefirah.mac", category: "scrcpy")

    private final class Entry: @unchecked Sendable {
        let pid: pid_t
        let logURL: URL
        let onExit: @Sendable (ScrcpyExit) -> Void
        let source: DispatchSourceProcess

        init(pid: pid_t, logURL: URL, onExit: @escaping @Sendable (ScrcpyExit) -> Void, source: DispatchSourceProcess) {
            self.pid = pid
            self.logURL = logURL
            self.onExit = onExit
            self.source = source
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let monitorQueue = DispatchQueue(label: "io.github.madeye.sefirah.scrcpy-app-runner")

    var runningKeys: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(entries.keys)
    }

    func launch(_ plan: ScrcpyLaunchPlan, key: String, onExit: @escaping @Sendable (ScrcpyExit) -> Void) throws {
        terminate(key: key)

        guard let prepared = prepareWrapper(plan) else { throw ScrcpyAppRunnerError.wrapperUnavailable }
        let token = UUID().uuidString
        var environment = plan.environment
        if environment["SCRCPY_SERVER_PATH"] == nil, let server = prepared.serverPath {
            environment["SCRCPY_SERVER_PATH"] = server.path
        }
        if environment["SCRCPY_ICON_DIR"] == nil {
            environment["SCRCPY_ICON_DIR"] = prepared.iconDirectory.path
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [prepared.launchScript.path, token, prepared.logDirectory.path] + plan.arguments
        configuration.environment = environment
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false

        try open(app: prepared.app, configuration: configuration)

        let pidURL = prepared.logDirectory.appendingPathComponent("\(token).pid")
        guard let pid = waitForPID(at: pidURL) else {
            terminateUntrackedInstance()
            throw ScrcpyAppRunnerError.processIdentifierUnavailable
        }
        let logURL = prepared.logDirectory.appendingPathComponent("\(token).log")

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: monitorQueue)
        let entry = Entry(pid: pid, logURL: logURL, onExit: onExit, source: source)
        lock.lock()
        entries[key] = entry
        lock.unlock()

        source.setEventHandler { [weak self] in self?.finished(key: key, pid: pid) }
        source.resume()

        // If it exited before the source was armed the handler may not fire.
        if kill(pid, 0) != 0 { finished(key: key, pid: pid) }
    }

    func terminate(key: String) {
        lock.lock()
        let entry = entries[key]
        lock.unlock()
        guard let entry else { return }
        kill(entry.pid, SIGTERM)
    }

    func terminateAll() {
        lock.lock()
        let all = Array(entries.values)
        lock.unlock()
        for entry in all { kill(entry.pid, SIGTERM) }
    }

    // MARK: - Internals

    private func finished(key: String, pid: pid_t) {
        lock.lock()
        // Ignore a stale exit when the key was relaunched with a newer process.
        guard let entry = entries[key], entry.pid == pid else {
            lock.unlock()
            return
        }
        entries.removeValue(forKey: key)
        lock.unlock()
        entry.source.cancel()
        entry.onExit(Self.exit(for: entry.logURL))
    }

    /// LaunchServices gives no wait status, so classify from the captured log: only runs whose
    /// log ends with real errors become failures (a plain "Device disconnected" is normal).
    private static func exit(for logURL: URL) -> ScrcpyExit {
        let tail = readTail(logURL)
        let errors = tail.split(separator: "\n").filter { $0.contains("ERROR:") }
        let meaningful = errors.filter { !$0.contains("Device disconnected") }
        return meaningful.isEmpty ? .normal(code: 0) : .reported(stderr: tail)
    }

    private static func readTail(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(ScrcpyAppWrapper.logTailBytes) ? size - UInt64(ScrcpyAppWrapper.logTailBytes) : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func prepareWrapper(_ plan: ScrcpyLaunchPlan) -> ScrcpyAppWrapper.Prepared? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { ScrcpyAppWrapper.prepare(scrcpy: plan.executable, environment: plan.environment) }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { ScrcpyAppWrapper.prepare(scrcpy: plan.executable, environment: plan.environment) }
        }
    }

    private func open(app: URL, configuration: NSWorkspace.OpenConfiguration) throws {
        let box = OpenResult()
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
            box.set(error.map { .failure($0) } ?? .success(()))
            semaphore.signal()
        }
        semaphore.wait()
        try box.result.get()
    }

    private func waitForPID(at url: URL) -> pid_t? {
        for _ in 0..<100 {
            if let raw = try? String(contentsOf: url, encoding: .utf8) {
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if let pid = pid_t(text), pid > 0 { return pid }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    /// Best effort when a launch could not be tracked: stop the newest wrapper instance so a
    /// stray mirror window is not left behind (other sessions keep running).
    private func terminateUntrackedInstance() {
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: ScrcpyAppWrapper.bundleIdentifier)
        let newest = instances.max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        newest?.terminate()
    }
}

private final class OpenResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Void, Error> = .failure(ScrcpyAppRunnerError.launchFailed("no response"))

    func set(_ new: Result<Void, Error>) {
        lock.lock(); value = new; lock.unlock()
    }

    var result: Result<Void, Error> {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Picks the runner for a launch: scrcpy always goes through the wrapper app so macOS shows
/// Sefirah's Dock icon/name; if the wrapper cannot be prepared the plain process runner is used.
final class ScrcpyRunnerRouter: ScrcpyRunning, @unchecked Sendable {
    private static let log = Logger(subsystem: "io.github.madeye.sefirah.mac", category: "scrcpy")

    private let process = ScrcpyProcessRunner()
    private let wrapper = ScrcpyAppRunner()

    var runningKeys: Set<String> {
        process.runningKeys.union(wrapper.runningKeys)
    }

    func launch(_ plan: ScrcpyLaunchPlan, key: String, onExit: @escaping @Sendable (ScrcpyExit) -> Void) throws {
        do {
            try wrapper.launch(plan, key: key, onExit: onExit)
            return
        } catch {
            Self.log.warning("Wrapper launch failed, falling back to direct scrcpy: \(error.localizedDescription, privacy: .public)")
        }
        try process.launch(plan, key: key, onExit: onExit)
    }

    func terminate(key: String) {
        process.terminate(key: key)
        wrapper.terminate(key: key)
    }

    func terminateAll() {
        process.terminateAll()
        wrapper.terminateAll()
    }
}
