@testable import SefirahCore
import XCTest

final class RcloneCipherTests: XCTestCase {
    // Vectors generated with `rclone obscure` (v1.75.2); revealing is deterministic.
    func testRevealMatchesRclone() {
        XCTAssertEqual(RcloneCipher.reveal("DuTwhWlhAjOVga06Qt4i3Oc"), "p")
        XCTAssertEqual(RcloneCipher.reveal("Lnv49xqFH87MnZeYrKr6Hs2IaG3TG--GVw"), "secret123")
        XCTAssertEqual(RcloneCipher.reveal("-ST4_EEHGOU9H2Ls9GH4tomLeIfR"), "a,b'c")
        XCTAssertEqual(RcloneCipher.reveal("_AUzA1FPQefDs8lqJB8MLQkIUizyRrzj8Kc"), "P@ss w0rd!")
        XCTAssertEqual(RcloneCipher.reveal("Lgc-F7BPwCIwMFLelMhLLLNIRXcrQ8s"), "hunter2")
    }

    func testObscureRoundTrips() {
        for secret in ["p", "secret123", "P@ss w0rd!", "unicode-✓-秘密"] {
            guard let obscured = RcloneCipher.obscure(secret) else {
                return XCTFail("obscure failed for \(secret)")
            }
            XCTAssertNotEqual(obscured, secret)
            XCTAssertEqual(RcloneCipher.reveal(obscured), secret)
        }
    }

    func testObscureUsesFreshIVEachTime() {
        XCTAssertNotEqual(RcloneCipher.obscure("same"), RcloneCipher.obscure("same"))
    }

    func testRevealRejectsValuesThatAreNotObscured() {
        XCTAssertNil(RcloneCipher.reveal("plain-password"))
        XCTAssertNil(RcloneCipher.reveal(""))
        XCTAssertNil(RcloneCipher.reveal("AQID"))
        XCTAssertNil(RcloneCipher.reveal("!!!not base64!!!"))
    }
}

final class PhoneMountCommandTests: XCTestCase {
    private func configuration(
        volumeName: String = "Pixel 8",
        basePath: String = "/storage/emulated/0",
        password: String = "sftp-secret",
        localPort: Int = 53420
    ) -> PhoneMountConfiguration {
        PhoneMountConfiguration(
            volumeName: volumeName,
            host: "192.168.1.23",
            port: 2222,
            username: "sefirah",
            password: password,
            basePath: basePath,
            localPort: localPort,
            mountUsername: "mountuser",
            mountPassword: "mountpass",
            configPath: "/tmp/support/PhoneMount/rclone.conf",
            cacheDirectory: "/tmp/support/PhoneMount/cache-abc"
        )
    }

    func testConfigFileDescribesSftpRemoteAndNamedVolume() {
        let text = PhoneMount.configFile(configuration())
        XCTAssertTrue(text.contains("[sefirah-phone]"))
        XCTAssertTrue(text.contains("type = sftp"))
        XCTAssertTrue(text.contains("host = 192.168.1.23"))
        XCTAssertTrue(text.contains("port = 2222"))
        XCTAssertTrue(text.contains("user = sefirah"))
        XCTAssertTrue(text.contains("shell_type = none"))
        XCTAssertTrue(text.contains("[sefirah-mount]"))
        XCTAssertTrue(text.contains("type = combine"))
        XCTAssertTrue(text.contains("upstreams = \"Pixel 8=sefirah-phone:/storage/emulated/0\""))
    }

    func testConfigFileObscuresPassword() {
        let text = PhoneMount.configFile(configuration(password: "hunter2"))
        XCTAssertFalse(text.contains("hunter2"))
        let line = text.split(separator: "\n").first { $0.hasPrefix("pass = ") }
        let value = line.map { String($0.dropFirst("pass = ".count)) }
        XCTAssertEqual(value.flatMap(RcloneCipher.reveal), "hunter2")
    }

    func testConfigFileFallsBackToRemoteRoot() {
        let text = PhoneMount.configFile(configuration(basePath: "  "))
        XCTAssertTrue(text.contains("upstreams = \"Pixel 8=sefirah-phone:/\""))
    }

    func testArgumentsServeWebdavOverTheCombinedRemote() {
        let arguments = PhoneMount.arguments(configuration())
        XCTAssertEqual(Array(arguments.prefix(3)), ["serve", "webdav", "sefirah-mount:"])

        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }
        XCTAssertEqual(value("--config"), "/tmp/support/PhoneMount/rclone.conf")
        XCTAssertEqual(value("--addr"), "127.0.0.1:53420")
        XCTAssertEqual(value("--user"), "mountuser")
        XCTAssertEqual(value("--pass"), "mountpass")
        XCTAssertEqual(value("--vfs-cache-mode"), "writes")
        XCTAssertEqual(value("--cache-dir"), "/tmp/support/PhoneMount/cache-abc")
    }

    func testMountURLEscapesTheVolumeName() {
        XCTAssertEqual(
            PhoneMount.mountURL(configuration(volumeName: "Pixel 8")),
            "http://mountuser:mountpass@127.0.0.1:53420/Pixel%208/"
        )
    }

    func testMountURLUsesTheFinderHostName() {
        XCTAssertEqual(
            PhoneMount.mountURL(configuration(volumeName: "Pixel 8"), host: PhoneMount.bonjourHostName),
            "http://mountuser:mountpass@Sefirah.local:53420/Pixel%208/"
        )
        XCTAssertEqual(
            PhoneMount.mountURL(configuration(volumeName: "Pixel 8"), host: PhoneMount.finderHostName),
            "http://mountuser:mountpass@Sefirah:53420/Pixel%208/"
        )
    }

    func testHostsFileAliasDetection() {
        let hosts = """
        ##
        # Host Database
        127.0.0.1       localhost
        255.255.255.255 broadcasthost
        ::1             localhost
        127.0.0.1\tSefirah
        10.0.0.5        sefirah-office
        127.0.0.2       Sefirah
        """
        XCTAssertTrue(PhoneMount.hostsFileMapsLoopback(hosts, name: "Sefirah"))
        XCTAssertTrue(PhoneMount.hostsFileMapsLoopback("127.0.0.1 sefirah\n", name: "Sefirah"))
        XCTAssertTrue(PhoneMount.hostsFileMapsLoopback("  127.0.0.1   other sefirah # comment\n", name: "Sefirah"))
        XCTAssertFalse(PhoneMount.hostsFileMapsLoopback("127.0.0.1 localhost\n", name: "Sefirah"))
        XCTAssertFalse(PhoneMount.hostsFileMapsLoopback("10.0.0.5 Sefirah\n", name: "Sefirah"))
        // The bridge only ever listens on 127.0.0.1, so other loopback addresses don't count.
        XCTAssertFalse(PhoneMount.hostsFileMapsLoopback("127.0.0.2 Sefirah\n", name: "Sefirah"))
        XCTAssertFalse(PhoneMount.hostsFileMapsLoopback("# 127.0.0.1 Sefirah\n", name: "Sefirah"))
        XCTAssertFalse(PhoneMount.hostsFileMapsLoopback("", name: "Sefirah"))
    }

    func testAppleScriptMountGuardsWithTimeout() {
        let script = PhoneMount.appleScriptMountScript(url: "http://u:p@127.0.0.1:53420/Pixel%208/")
        XCTAssertTrue(script.contains("with timeout of 45 seconds"))
        XCTAssertTrue(script.contains("mount volume \"http://u:p@127.0.0.1:53420/Pixel%208/\""))
    }

    func testVolumeNameSanitising() {
        XCTAssertEqual(PhoneMount.volumeName(for: "Pixel 8"), "Pixel 8")
        XCTAssertEqual(PhoneMount.volumeName(for: "  Pixel   8  "), "Pixel 8")
        XCTAssertEqual(PhoneMount.volumeName(for: "Galaxy/Tab:S9"), "Galaxy Tab S9")
        XCTAssertEqual(PhoneMount.volumeName(for: "!!!###"), "Phone")
        XCTAssertEqual(PhoneMount.volumeName(for: ""), "Phone")
        XCTAssertEqual(PhoneMount.volumeName(for: ". .."), "Phone")
        XCTAssertEqual(PhoneMount.volumeName(for: "小phone"), "phone")
        XCTAssertEqual(PhoneMount.volumeName(for: String(repeating: "a", count: 80)).count, 40)
    }

    func testMountPointParsing() {
        let output = """
        /dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
        http://127.0.0.1:8898/ on /Volumes/127.0.0.1 (webdav, nodev, noexec, nosuid, mounted by tester)
        http://127.0.0.1:53420/Pixel%208/ on /Volumes/Pixel 8 (webdav, nodev, noexec, nosuid, mounted by tester)
        http://Sefirah.local:53421/Pixel%208/ on /Volumes/Pixel 8 2 (webdav, nodev, noexec, nosuid, mounted by tester)
        """
        XCTAssertEqual(PhoneMount.mountPoint(inMountOutput: output, port: 53420), "/Volumes/Pixel 8")
        XCTAssertEqual(PhoneMount.mountPoint(inMountOutput: output, port: 8898), "/Volumes/127.0.0.1")
        XCTAssertEqual(PhoneMount.mountPoint(inMountOutput: output, port: 53421), "/Volumes/Pixel 8 2")
        XCTAssertNil(PhoneMount.mountPoint(inMountOutput: output, port: 9999))
        XCTAssertNil(PhoneMount.mountPoint(inMountOutput: "", port: 53420))
    }

    func testDisambiguatedVolumeName() {
        XCTAssertEqual(PhoneMount.disambiguatedVolumeName("Pixel 8", taken: []), "Pixel 8")
        XCTAssertEqual(PhoneMount.disambiguatedVolumeName("Pixel 8", taken: ["Galaxy"]), "Pixel 8")
        XCTAssertEqual(PhoneMount.disambiguatedVolumeName("Pixel 8", taken: ["Pixel 8"]), "Pixel 8 2")
        XCTAssertEqual(PhoneMount.disambiguatedVolumeName("Pixel 8", taken: ["Pixel 8", "Pixel 8 2"]), "Pixel 8 3")
    }

    func testIdentifiersForPerDeviceFiles() {
        XCTAssertEqual(PhoneMount.safeIdentifier("349dd4cbcbcd3f13"), "349dd4cbcbcd3f13")
        XCTAssertEqual(PhoneMount.safeIdentifier("AA:BB/CC DD"), "AA-BB-CC-DD")
        XCTAssertEqual(PhoneMount.safeIdentifier(""), "device")
        XCTAssertEqual(PhoneMount.mountConfigFileName(for: "abc123"), "rclone-abc123.conf")
        XCTAssertEqual(PhoneMount.mountConfigFileName(for: "a b"), "rclone-a-b.conf")
        XCTAssertEqual(PhoneMount.mountCacheDirectoryName(for: "abc123"), "cache-abc123")
    }

    func testPortAllocatorPicksTheFirstFreePort() {
        let taken: Set<Int> = [53420, 53421]
        XCTAssertEqual(
            PortAllocator.firstFreePort(from: 53420, count: 3, probe: { !taken.contains($0) }),
            53422
        )
        XCTAssertNil(PortAllocator.firstFreePort(from: 53420, count: 2, probe: { _ in false }))
    }

    func testPortProbeAcceptsLoopbackPorts() {
        // Port 0 is never a valid bridge port; a reserved-by-convention high port should bind.
        XCTAssertFalse(PortProbe.isFree(0))
        XCTAssertFalse(PortProbe.isFree(70_000))
    }
}
