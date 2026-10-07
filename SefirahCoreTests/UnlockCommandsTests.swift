import SefirahCore
import XCTest

/// `UnlockCommandRunner` — the unlock-before-launch hook shared by the native session and the
/// external scrcpy window backend.
final class UnlockCommandsTests: XCTestCase {
    private let adb = URL(fileURLWithPath: "/App/Contents/MacOS/adb")
    private let serial = "192.168.0.103:5555"
    private func ok() -> FakeCommandRunner.Step { .result(CommandResult(exitCode: 0, stdout: "", stderr: "")) }

    /// Thread-safe sink for the `@Sendable` warn closure.
    private final class Warnings: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ text: String) { lock.withLock { values.append(text) } }
        var all: [String] { lock.withLock { values } }
    }

    private func client(_ runner: FakeCommandRunner) -> AdbClient {
        AdbClient(adb: adb, environment: ["PATH": "/usr/bin"], runner: runner)
    }

    func testRunsEachCommandInOrderAndSkipsBlankAndPercentPwd() async throws {
        let runner = FakeCommandRunner([
            .result(CommandResult(exitCode: 1, stdout: "", stderr: "nope")),
            ok(),
        ])
        let adbClient = client(runner)
        let serial = self.serial
        let warnings = Warnings()
        try await UnlockCommandRunner.run(
            commands: [
                UnlockCommandEntry(command: "input keyevent 82"),
                UnlockCommandEntry(command: "   "),
                UnlockCommandEntry(command: "input text %pwd%"),
                UnlockCommandEntry(command: "wm dismiss-keyguard"),
            ],
            warn: { warnings.append($0) },
            shell: { try await adbClient.shell(serial: serial, [$0]) }
        )

        XCTAssertEqual(runner.calls, [
            ["-s", serial, "shell", "input keyevent 82"],
            ["-s", serial, "shell", "wm dismiss-keyguard"],
        ])
        let msgs = warnings.all
        XCTAssertEqual(msgs.count, 2, "\(msgs)")
        XCTAssertTrue(msgs[0].contains("exited 1"))
        XCTAssertTrue(msgs[1].contains("%pwd%"))
    }

    func testShellFailureWarnsAndContinues() async throws {
        let runner = FakeCommandRunner([.spawnError, ok()])
        let adbClient = client(runner)
        let serial = self.serial
        let warnings = Warnings()
        try await UnlockCommandRunner.run(
            commands: [UnlockCommandEntry(command: "a"), UnlockCommandEntry(command: "b")],
            warn: { warnings.append($0) },
            shell: { try await adbClient.shell(serial: serial, [$0]) }
        )

        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertEqual(warnings.all.count, 1)
        XCTAssertTrue(warnings.all[0].contains("failed"))
    }

    func testCancellationStopsBeforeTheNextCommand() async {
        let runner = FakeCommandRunner([ok(), ok()])
        let adbClient = client(runner)
        let serial = self.serial
        do {
            try await UnlockCommandRunner.run(
                commands: [UnlockCommandEntry(command: "a"), UnlockCommandEntry(command: "b")],
                warn: { _ in },
                shell: { command in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try await adbClient.shell(serial: serial, [command])
                }
            )
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            XCTAssertEqual(runner.calls.count, 1)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testShellWithoutSerialLetsAdbPickTheDevice() async throws {
        let runner = FakeCommandRunner([ok()])
        let adbClient = client(runner)
        try await UnlockCommandRunner.run(
            commands: [UnlockCommandEntry(command: "wm dismiss-keyguard")],
            warn: { _ in },
            shell: { try await adbClient.shell([$0]) }
        )
        XCTAssertEqual(runner.calls, [["shell", "wm dismiss-keyguard"]])
    }
}