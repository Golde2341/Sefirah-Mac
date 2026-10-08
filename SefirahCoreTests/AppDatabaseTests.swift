import SefirahCore
import SQLite3
import XCTest

final class AppDatabaseTests: XCTestCase {
    func testSchemaVersionIsNine() throws {
        let db = try AppDatabase(inMemory: ())
        XCTAssertEqual(db.schemaVersion, SefirahConstants.schemaVersion)
        XCTAssertEqual(db.schemaVersion, 9)
    }

    /// A short-lived build shipped "v8" as an `IsSystem` column; the identifier is already recorded
    /// in databases that ran it, so the hidden-notifications column must arrive as a fresh `v9`
    /// migration or `ApplicationRecord` reads fail (empty apps list and notification feed).
    func testUpgradeFromShortLivedV8AppliesHiddenNotifications() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sefirah-v8-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(SefirahConstants.databaseFileName)

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let seed = """
            CREATE TABLE SchemaVersionEntity (Version INTEGER PRIMARY KEY NOT NULL);
            CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
            CREATE TABLE ApplicationEntity (
                AppKey TEXT PRIMARY KEY NOT NULL,
                DeviceId TEXT NOT NULL,
                PackageName TEXT NOT NULL,
                AppName TEXT NOT NULL,
                Pinned INTEGER NOT NULL DEFAULT 0,
                Filter INTEGER NOT NULL DEFAULT 2,
                Icon BLOB,
                Hidden INTEGER NOT NULL DEFAULT 0,
                IsSystem INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO SchemaVersionEntity (Version) VALUES (5),(6),(7),(8);
            INSERT INTO grdb_migrations (identifier) VALUES ('v5'),('v6'),('v7'),('v8');
            INSERT INTO ApplicationEntity (AppKey, DeviceId, PackageName, AppName)
                VALUES ('phone:com.chat', 'phone', 'com.chat', 'Chat');
            """
        XCTAssertEqual(sqlite3_exec(handle, seed, nil, nil, nil), SQLITE_OK)

        let db = try AppDatabase(fileURL: url)
        XCTAssertEqual(db.schemaVersion, SefirahConstants.schemaVersion)
        let hub = FeatureHub(database: db)
        let apps = try hub.apps(deviceId: "phone")
        XCTAssertEqual(apps.map(\.packageName), ["com.chat"])
        XCTAssertFalse(apps[0].hiddenNotifications)
    }

    func testLocalAndPairedDeviceRoundTrip() throws {
        let db = try AppDatabase(inMemory: ())
        let repo = DeviceRepository(database: db)
        let local = try repo.ensureLocalDevice(name: "Studio")
        XCTAssertFalse(local.deviceId.isEmpty)
        XCTAssertEqual(try repo.ensureLocalDevice(name: "Studio").deviceId, local.deviceId)
        XCTAssertEqual(try repo.ensureLocalDevice(name: "Kitchen").deviceName, "Kitchen")

        let cert = Data([0x30, 0x82, 0x01, 0x00])
        let paired = PairedDeviceRecord(
            deviceId: "phone-1",
            name: "Pixel",
            model: "shiba",
            certificate: cert,
            addresses: [AddressEntry(address: "192.168.1.8", isEnabled: true)],
            phoneNumbers: [PhoneNumber(number: "+1555", subscriptionId: 0)]
        )
        try repo.upsertPairedDevice(paired)
        let fetched = try XCTUnwrap(try repo.fetchPairedDevice(id: "phone-1"))
        XCTAssertEqual(fetched.certificate, cert)
        XCTAssertEqual(fetched.addresses.first?.address, "192.168.1.8")
        XCTAssertEqual(fetched.phoneNumbers.first?.number, "+1555")
        XCTAssertEqual(try repo.fetchPairedDevices().count, 1)

        try repo.deletePairedDevice(id: "phone-1")
        XCTAssertTrue(try repo.fetchPairedDevices().isEmpty)
    }

    func testRelatedTablesAcceptRows() throws {
        let db = try AppDatabase(inMemory: ())
        try db.dbQueue.write { database in
            try ApplicationRecord(
                appKey: "d:com.foo",
                deviceId: "d",
                packageName: "com.foo",
                appName: "Foo",
                filter: .toastFeed
            ).insert(database)
            try ContactRecord(
                key: "d:c1",
                deviceId: "d",
                contactId: "c1",
                lookupKey: "lk",
                displayName: "Ada"
            ).insert(database)
            try PhoneNumberRecord(key: "d:c1:+1", contactKey: "d:c1", number: "+1").insert(database)
            try ConversationRecord(key: "d:1", deviceId: "d", threadId: 1, lastMessage: "hi").insert(database)
            try MessageRecord(
                key: "d:10",
                conversationKey: "d:1",
                deviceId: "d",
                uniqueId: 10,
                threadId: 1,
                body: "hi",
                timestamp: 1,
                read: false,
                subscriptionId: 0,
                messageType: 1,
                address: "+1"
            ).insert(database)
            try CallLogRecord(
                key: "d:3",
                deviceId: "d",
                callLogId: 3,
                phoneNumber: "+1",
                timestampMillis: 1,
                durationSeconds: 0,
                callType: .missed
            ).insert(database)
            try NotificationRecord(
                key: "d:n1",
                deviceId: "d",
                notificationKey: "n1",
                appPackage: "com.chat",
                appName: "Chat",
                timestampMillis: 1
            ).insert(database)
        }

        try db.dbQueue.read { database in
            XCTAssertEqual(try ApplicationRecord.fetchCount(database), 1)
            XCTAssertEqual(try ContactRecord.fetchCount(database), 1)
            XCTAssertEqual(try PhoneNumberRecord.fetchCount(database), 1)
            XCTAssertEqual(try ConversationRecord.fetchCount(database), 1)
            XCTAssertEqual(try MessageRecord.fetchCount(database), 1)
            XCTAssertEqual(try CallLogRecord.fetchCount(database), 1)
            XCTAssertEqual(try NotificationRecord.fetchCount(database), 1)
        }
    }
}
