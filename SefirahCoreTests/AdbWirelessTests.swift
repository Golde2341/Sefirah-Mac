import SefirahCore
import XCTest

final class AdbWirelessTests: XCTestCase {
    private let adb = URL(fileURLWithPath: "/App/Contents/MacOS/adb")

    private func client(_ runner: FakeCommandRunner) -> AdbClient {
        AdbClient(adb: adb, environment: ["PATH": "/usr/bin"], runner: runner)
    }

    func testQrTextFormat() {
        XCTAssertEqual(
            AdbWirelessPairing.qrText(serviceName: "sefirah-ab12cd34", password: "AbC123xYz"),
            "WIFI:T:ADB;S:sefirah-ab12cd34;P:AbC123xYz;;"
        )
    }

    func testRandomCredentialsHaveExpectedShape() {
        let name = AdbWirelessPairing.randomServiceName()
        XCTAssertTrue(name.hasPrefix("sefirah-"))
        XCTAssertEqual(name.count, "sefirah-".count + 8)
        XCTAssertTrue(name.dropFirst("sefirah-".count).allSatisfy { $0.isHexDigit })

        let password = AdbWirelessPairing.randomPassword()
        XCTAssertEqual(password.count, 12)
        XCTAssertTrue(password.allSatisfy { $0.isLetter || $0.isNumber })
    }

    func testParseMdnsServices() {
        let output = """
        List of discovered mdns services
        adbqr-1a2b3c4d\t_adb-tls-pairing\t192.168.1.20:37231
        Pixel_7\t_adb-tls-connect\t192.168.1.20:41235
        router\t_http._tcp\t192.168.1.1:80

        """
        XCTAssertEqual(AdbOutput.parseMdnsServices(output), [
            AdbMdnsService(instance: "adbqr-1a2b3c4d", serviceType: "_adb-tls-pairing", host: "192.168.1.20", port: 37231),
            AdbMdnsService(instance: "Pixel_7", serviceType: "_adb-tls-connect", host: "192.168.1.20", port: 41235),
        ])
    }

    func testParseMdnsServicesHandlesWhitespaceSeparatedOutput() {
        let output = "adbqr-1a2b3c4d _adb-tls-pairing._tcp. 10.0.0.5:5555\n"
        XCTAssertEqual(AdbOutput.parseMdnsServices(output), [
            AdbMdnsService(instance: "adbqr-1a2b3c4d", serviceType: "_adb-tls-pairing._tcp.", host: "10.0.0.5", port: 5555),
        ])
    }

    func testPairingServiceMatchesByName() {
        let services = [
            AdbMdnsService(instance: "other", serviceType: "_adb-tls-pairing._tcp.", host: "10.0.0.5", port: 1111),
            AdbMdnsService(instance: "sefirah-ab12cd34", serviceType: "_adb-tls-pairing._tcp.", host: "10.0.0.9", port: 2222),
        ]
        XCTAssertEqual(AdbWirelessPairing.pairingService(in: services, name: "sefirah-ab12cd34")?.host, "10.0.0.9")
    }

    func testPairingServiceFallsBackToLoneService() {
        let services = [AdbMdnsService(instance: "unknown", serviceType: "_adb-tls-pairing", host: "10.0.0.9", port: 2222)]
        XCTAssertEqual(AdbWirelessPairing.pairingService(in: services, name: "sefirah-ab12cd34")?.host, "10.0.0.9")
    }

    func testPairingServiceRejectsAmbiguousFallback() {
        let services = [
            AdbMdnsService(instance: "a", serviceType: "_adb-tls-pairing", host: "10.0.0.1", port: 1),
            AdbMdnsService(instance: "b", serviceType: "_adb-tls-pairing", host: "10.0.0.2", port: 2),
        ]
        XCTAssertNil(AdbWirelessPairing.pairingService(in: services, name: "sefirah-ab12cd34"))
    }

    func testConnectServicePrefersHostMatchThenLone() {
        let services = [
            AdbMdnsService(instance: "A", serviceType: "_adb-tls-connect._tcp.", host: "10.0.0.1", port: 40001),
            AdbMdnsService(instance: "B", serviceType: "_adb-tls-connect._tcp.", host: "10.0.0.2", port: 40002),
        ]
        XCTAssertEqual(AdbWirelessPairing.connectService(in: services, host: "10.0.0.2")?.port, 40002)
        XCTAssertNil(AdbWirelessPairing.connectService(in: services, host: "10.0.0.9"))

        let lone = [AdbMdnsService(instance: "B", serviceType: "_adb-tls-connect", host: "10.0.0.2", port: 40002)]
        XCTAssertEqual(AdbWirelessPairing.connectService(in: lone, host: "10.0.0.9")?.port, 40002)
    }

    func testPairSucceeded() {
        XCTAssertTrue(AdbOutput.pairSucceeded("Successfully paired to 10.0.0.2:37231 [guid=adb-xyz]"))
        XCTAssertTrue(AdbOutput.pairSucceeded("Already paired to 10.0.0.2:37231"))
        XCTAssertFalse(AdbOutput.pairSucceeded("Failed to pair: wrong password"))
        XCTAssertFalse(AdbOutput.pairSucceeded("cannot connect to 10.0.0.2:37231: Connection refused"))
    }

    func testPairCommandRunsAdbPair() async throws {
        let runner = FakeCommandRunner([
            .result(CommandResult(exitCode: 0, stdout: "Successfully paired to 10.0.0.2:37231", stderr: "")),
        ])
        try await client(runner).pair(host: "10.0.0.2", port: 37231, code: "abc123")
        XCTAssertEqual(runner.calls, [["pair", "10.0.0.2:37231", "abc123"]])
    }

    func testPairCommandThrowsOnFailureText() async {
        let runner = FakeCommandRunner([
            .result(CommandResult(exitCode: 0, stdout: "Failed to pair: wrong password", stderr: "")),
        ])
        do {
            try await client(runner).pair(host: "10.0.0.2", port: 37231, code: "abc123")
            XCTFail("expected throw")
        } catch {
            guard case .commandFailed(let command, _, let stderr)? = error as? AdbError else { return XCTFail("\(error)") }
            XCTAssertEqual(command, "pair 10.0.0.2:37231")
            XCTAssertTrue(stderr.contains("wrong password"))
        }
    }

    func testMdnsServicesParses() async throws {
        let runner = FakeCommandRunner([
            .result(CommandResult(
                exitCode: 0,
                stdout: "List of discovered mdns services\nfoo\t_adb-tls-pairing\t10.0.0.2:37231\n",
                stderr: ""
            )),
        ])
        let services = try await client(runner).mdnsServices()
        XCTAssertEqual(runner.calls, [["mdns", "services"]])
        XCTAssertEqual(services, [AdbMdnsService(instance: "foo", serviceType: "_adb-tls-pairing", host: "10.0.0.2", port: 37231)])
    }
}
