import Network
@testable import SefirahCore
import XCTest

final class FileTransferFramingTests: XCTestCase {
    func testControlWordsTolerateOptionalNewline() {
        XCTAssertEqual(FileTransferFraming.parseControl(Data("start".utf8)), .start)
        XCTAssertEqual(FileTransferFraming.parseControl(FileTransferFraming.encodeStart()), .start)
        XCTAssertEqual(FileTransferFraming.parseControl(Data("complete\n".utf8)), .complete)
        XCTAssertEqual(FileTransferFraming.parseControl(FileTransferFraming.encodeComplete()), .complete)
        XCTAssertNil(FileTransferFraming.parseControl(Data("nope".utf8)))
    }

    func testReceiveEngineWritesExactFileSizeThenSignalsComplete() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xfer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = [
            FileMetadata(fileName: "a.txt", mimeType: "text/plain", fileSize: 5),
            FileMetadata(fileName: "b.txt", mimeType: "text/plain", fileSize: 3),
        ]
        let engine = FileReceiveEngine(files: files, destination: directory)
        XCTAssertEqual(FileTransferFraming.parseControl(engine.beginSignal()), .start)

        let first = try engine.ingest(Data("hello".utf8))
        guard case .fileComplete(let name, let nextStart) = first else {
            return XCTFail("expected first file complete, got \(first)")
        }
        XCTAssertEqual(name, "a.txt")
        XCTAssertEqual(FileTransferFraming.parseControl(nextStart), .start)
        XCTAssertEqual(FileTransferFraming.parseControl(engine.completeSignal()), .complete)

        let second = try engine.ingest(Data("bye".utf8))
        XCTAssertEqual(second, .allComplete)
        XCTAssertEqual(engine.completedURLs.count, 2)
        XCTAssertEqual(try String(contentsOf: engine.completedURLs[0], encoding: .utf8), "hello")
        XCTAssertEqual(try String(contentsOf: engine.completedURLs[1], encoding: .utf8), "bye")
    }

    func testReceiveEngineRejectsOversizeChunk() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xfer-\(UUID().uuidString)")
        let engine = FileReceiveEngine(
            files: [FileMetadata(fileName: "x.bin", mimeType: "application/octet-stream", fileSize: 2)],
            destination: directory
        )
        XCTAssertThrowsError(try engine.ingest(Data("abcd".utf8))) { error in
            XCTAssertEqual(error as? FileTransferError, .sizeMismatch(expected: 2, actual: 4))
        }
    }

    func testSessionSendsStartReadsBytesAndWritesFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xfer-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = [
            FileMetadata(fileName: "a.txt", mimeType: "text/plain", fileSize: 5),
            FileMetadata(fileName: "b.txt", mimeType: "text/plain", fileSize: 3),
        ]
        let io = ScriptedPhoneIO(payloads: [Data("hello".utf8), Data("bye".utf8)])
        let urls = try await FileTransferSession.receive(files: files, destination: directory, io: io)
        XCTAssertEqual(io.controlWrites, [.start, .complete, .start, .complete])
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(try String(contentsOf: urls[0], encoding: .utf8), "hello")
        XCTAssertEqual(try String(contentsOf: urls[1], encoding: .utf8), "bye")
    }

    func testFileTransferClientLoopbackTCPWritesFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xfer-tcp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("abcd".utf8)
        let files = [FileMetadata(fileName: "n.txt", mimeType: "text/plain", fileSize: Int64(payload.count))]

        let queue = DispatchQueue(label: "io.github.madeye.sefirah.xfer.test")
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            func waitControl(_ expected: FileTransferFraming.Control, then body: @escaping () -> Void) {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 32) { content, _, _, _ in
                    if let content, FileTransferFraming.parseControl(content) == expected {
                        body()
                    } else {
                        waitControl(expected, then: body)
                    }
                }
            }
            waitControl(.start) {
                connection.send(content: payload, completion: .contentProcessed { _ in
                    waitControl(.complete) {
                        connection.cancel()
                    }
                })
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ResumeGate(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resumeSuccess()
                case .failed(let error):
                    gate.resumeFailure(error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        guard let port = listener.port else {
            listener.cancel()
            return XCTFail("listener port")
        }

        let client = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        let urls = try await FileTransferClient.receive(
            files: files,
            destination: directory,
            connection: client,
            queue: queue
        )
        listener.cancel()
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(try String(contentsOf: urls[0], encoding: .utf8), "abcd")
    }

    func testSessionSendWaitsForStartStreamsBytesAndWaitsForComplete() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xfer-send-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = directory.appendingPathComponent("a.txt")
        let second = directory.appendingPathComponent("b.txt")
        try Data("hello".utf8).write(to: first)
        try Data("bye".utf8).write(to: second)
        let files = [
            FileMetadata(fileName: "a.txt", mimeType: "text/plain", fileSize: 5),
            FileMetadata(fileName: "b.txt", mimeType: "text/plain", fileSize: 3),
        ]
        let io = ScriptedReceiverIO(controls: ["start", "complete", "start", "complete"])
        try await FileTransferSession.send(files: files, urls: [first, second], io: io)
        XCTAssertEqual(io.payload, Data("hellobye".utf8))
    }

    func testSessionSendFailsOnUnexpectedControl() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xfer-send-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: file)
        let io = ScriptedReceiverIO(controls: ["complete"])
        do {
            try await FileTransferSession.send(
                files: [FileMetadata(fileName: "a.txt", mimeType: "text/plain", fileSize: 5)],
                urls: [file],
                io: io
            )
            XCTFail("expected invalidHandshake")
        } catch {
            XCTAssertEqual(error as? FileTransferError, .invalidHandshake)
        }
    }

    func testSessionSendFailsWhenFileIsShorterThanMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xfer-send-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("a.txt")
        try Data("hi".utf8).write(to: file)
        let io = ScriptedReceiverIO(controls: ["start"])
        do {
            try await FileTransferSession.send(
                files: [FileMetadata(fileName: "a.txt", mimeType: "text/plain", fileSize: 5)],
                urls: [file],
                io: io
            )
            XCTFail("expected unexpectedEOF")
        } catch {
            XCTAssertEqual(error as? FileTransferError, .unexpectedEOF)
        }
    }

    func testFileTransferSenderTLSLoopbackStreamsFileToPinnedPeer() async throws {
        let macIdentity = try IdentityStore.generate()
        let phoneIdentity = try IdentityStore.generate()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xfer-send-tls-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = Data("sefirah-transfer".utf8)
        let fileURL = directory.appendingPathComponent("note.txt")
        try payload.write(to: fileURL)
        let files = [FileMetadata(fileName: "note.txt", mimeType: "text/plain", fileSize: Int64(payload.count))]

        let portBox = PortBox()
        let sendTask = Task {
            try await FileTransferSender.send(
                files: files,
                urls: [fileURL],
                identity: macIdentity,
                pinnedCertificateDER: phoneIdentity.certificateDER,
                acceptTimeout: 15
            ) { port in
                portBox.set(port)
            }
        }

        let port = try await withTimeout(seconds: 15) { try await portBox.wait() }
        let queue = DispatchQueue(label: "io.github.madeye.sefirah.xfer.send.test")
        let parameters = TLSFactory.parameters(
            identity: try SecIdentityFactory.makeIdentity(phoneIdentity),
            policy: .pin(macIdentity.certificateDER),
            stash: CertificateStash(),
            queue: queue
        )
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return XCTFail("invalid port \(port)")
        }
        let connection = NWConnection(host: .ipv4(.loopback), port: nwPort, using: parameters)
        try await waitReady(connection, queue: queue)
        let io = NWFileTransferIO(connection: connection)
        try await io.write(FileTransferFraming.encodeStart())
        var received = Data()
        while received.count < payload.count {
            let chunk = try await io.read(maxLength: payload.count - received.count)
            if chunk.isEmpty { throw FileTransferError.unexpectedEOF }
            received.append(chunk)
        }
        try await io.write(FileTransferFraming.encodeComplete())
        try await sendTask.value
        connection.cancel()
        XCTAssertEqual(received, payload)
    }
}

private func waitReady(_ connection: NWConnection, queue: DispatchQueue) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let gate = ResumeGate(continuation)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                gate.resumeSuccess()
            case .failed(let error):
                gate.resumeFailure(error)
            case .cancelled:
                gate.resumeFailure(CancellationError())
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw POSIXError(.ETIMEDOUT)
        }
        guard let result = try await group.next() else {
            throw POSIXError(.ETIMEDOUT)
        }
        group.cancelAll()
        return result
    }
}

private final class PortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var port: Int?
    private var continuation: CheckedContinuation<Int, Error>?

    func set(_ port: Int) {
        lock.lock()
        let pending = continuation
        continuation = nil
        self.port = port
        lock.unlock()
        pending?.resume(returning: port)
    }

    func wait() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let port {
                lock.unlock()
                continuation.resume(returning: port)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

/// Fake phone for the send direction: hands out `start` / `complete` bytes and records the
/// file bytes the Mac streams back.
private final class ScriptedReceiverIO: FileTransferIO, @unchecked Sendable {
    private let queue = DispatchQueue(label: "scripted-receiver-io")
    private var controls: [UInt8]
    private var written = Data()

    var payload: Data {
        queue.sync { written }
    }

    init(controls: [String]) {
        // `FileTransferSession.send` stops reading as soon as a control word matches, so the
        // scripted stream can be the plain concatenation of the words.
        self.controls = Array(controls.joined().utf8)
    }

    func write(_ data: Data) async throws {
        queue.sync { written.append(data) }
    }

    func read(maxLength: Int) async throws -> Data {
        queue.sync {
            guard !controls.isEmpty else { return Data() }
            return Data([controls.removeFirst()])
        }
    }
}

private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resumeSuccess() {
        take()?.resume()
    }

    func resumeFailure(_ error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let pending = continuation
        continuation = nil
        return pending
    }
}

private final class ScriptedPhoneIO: FileTransferIO, @unchecked Sendable {
    private let queue = DispatchQueue(label: "scripted-phone-io")
    private var payloads: [Data]
    private var pending: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var controlWritesStorage: [FileTransferFraming.Control] = []

    var controlWrites: [FileTransferFraming.Control] {
        queue.sync { controlWritesStorage }
    }

    init(payloads: [Data]) {
        self.payloads = payloads
    }

    func write(_ data: Data) async throws {
        queue.sync {
            if let control = FileTransferFraming.parseControl(data) {
                controlWritesStorage.append(control)
                if control == .start, !payloads.isEmpty {
                    pending.append(payloads.removeFirst())
                }
            }
            flushLocked()
        }
    }

    func read(maxLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.sync {
                waiters.append(continuation)
                flushLocked(maxLength: maxLength)
            }
        }
    }

    private func flushLocked(maxLength: Int = FileTransferFraming.chunkSize) {
        guard !waiters.isEmpty, !pending.isEmpty else { return }
        let waiter = waiters.removeFirst()
        waiter.resume(returning: takeLocked(maxLength: maxLength))
    }

    private func takeLocked(maxLength: Int) -> Data {
        var chunk = pending.removeFirst()
        if chunk.count > maxLength {
            pending.insert(Data(chunk.dropFirst(maxLength)), at: 0)
            chunk = Data(chunk.prefix(maxLength))
        }
        return chunk
    }
}
