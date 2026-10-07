import Foundation

/// Runs `DeviceSettings.unlockCommands` over `adb shell` before a mirror starts — shared by the
/// native session (before the scrcpy-server push) and the external scrcpy window (before the
/// process spawns), so both backends wake/unlock the phone the same way.
public enum UnlockCommandRunner {
    /// Executes each entry in order as one `adb shell "<command>"`, honouring `delayMs` after each.
    /// Blank commands are dropped and `%pwd%` commands are skipped (the Mac port has no password
    /// prompt yet). A failing command is reported through `warn` and never aborts the launch.
    ///
    /// - Parameters:
    ///   - shell: runs a single command against the device and returns the raw adb result.
    ///   - warn: sink for non-fatal problems (skipped command, non-zero exit, spawn failure).
    /// - Throws: `CancellationError` when the calling task is cancelled between commands.
    public static func run(
        commands: [UnlockCommandEntry],
        warn: @escaping @Sendable (String) -> Void,
        shell: @escaping @Sendable (String) async throws -> CommandResult
    ) async throws {
        for entry in commands {
            try Task.checkCancellation()
            let command = entry.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { continue }
            if command.contains("%pwd%") {
                warn("Unlock command with %pwd% skipped (password prompt not supported yet)")
                continue
            }
            do {
                let result = try await shell(command)
                if result.exitCode != 0 {
                    warn("Unlock command \"\(command)\" exited \(result.exitCode)")
                }
            } catch {
                warn("Unlock command \"\(command)\" failed: \(error)")
            }
            if entry.delayMs > 0 { try await Task.sleep(nanoseconds: UInt64(entry.delayMs) * 1_000_000) }
        }
    }
}
