import Foundation
import Network
import Security

/// TLS data-plane client for inbound `FileTransferInfo`.
/// Connects to `serverInfo.port` with the pinned peer certificate, then runs `FileTransferSession`.
public enum FileTransferClient {
    public static func receive(
        files: [FileMetadata],
        destination: URL,
        host: String,
        port: Int,
        identity: DeviceIdentity,
        pinnedCertificateDER: Data
    ) async throws -> [URL] {
        let secIdentity = try SecIdentityFactory.makeIdentity(identity)
        let queue = DispatchQueue(label: "io.github.madeye.sefirah.xfer")
        let stash = CertificateStash()
        let parameters = TLSFactory.parameters(
            identity: secIdentity,
            policy: .pin(pinnedCertificateDER),
            stash: stash,
            queue: queue
        )
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw POSIXError(.ECONNREFUSED)
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        return try await receive(files: files, destination: destination, connection: connection, queue: queue)
    }

    /// Shared receive loop used by the TLS client and loopback tests.
    public static func receive(
        files: [FileMetadata],
        destination: URL,
        connection: NWConnection,
        queue: DispatchQueue
    ) async throws -> [URL] {
        try await waitReady(connection, queue: queue)
        defer { connection.cancel() }
        return try await FileTransferSession.receive(
            files: files,
            destination: destination,
            io: NWFileTransferIO(connection: connection)
        )
    }

    private static func waitReady(_ connection: NWConnection, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceResume(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resumeSuccess()
                case .failed(let error):
                    once.resumeFailure(error)
                case .cancelled:
                    once.resumeFailure(CancellationError())
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }
}

private final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resumeSuccess() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }

    func resumeFailure(_ error: Error) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }
}

final class NWFileTransferIO: FileTransferIO, @unchecked Sendable {
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func read(maxLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let content, !content.isEmpty {
                    continuation.resume(returning: content)
                    return
                }
                if isComplete {
                    continuation.resume(throwing: FileTransferError.unexpectedEOF)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}

/// TLS server used when the Mac sends files to the phone (`ShareTransfer`): the phone connects to
/// the advertised port and pulls the files with the same `start` / bytes / `complete` framing as
/// the receive path.
public enum FileTransferSender {
    public static func send(
        files: [FileMetadata],
        urls: [URL],
        identity: DeviceIdentity,
        pinnedCertificateDER: Data,
        acceptTimeout: TimeInterval = 60,
        onListening: @escaping @Sendable (Int) -> Void
    ) async throws {
        let secIdentity = try SecIdentityFactory.makeIdentity(identity)
        let queue = DispatchQueue(label: "io.github.madeye.sefirah.xfer.send")
        let stash = CertificateStash()
        let parameters = TLSFactory.parameters(
            identity: secIdentity,
            policy: .pin(pinnedCertificateDER),
            stash: stash,
            queue: queue
        )
        let listener = try NWListener(using: parameters)
        let accepted = AcceptedTransferConnection(queue: queue)
        listener.newConnectionHandler = { connection in
            accepted.attach(connection)
        }

        let port: Int = try await withCheckedThrowingContinuation { continuation in
            let box = TransferContinuation<Int>(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let rawPort = listener.port?.rawValue {
                        box.resume(returning: Int(rawPort))
                    } else {
                        box.resume(throwing: POSIXError(.EADDRNOTAVAIL))
                    }
                case .failed(let error):
                    box.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        defer { listener.cancel() }

        onListening(port)
        let connection = try await accepted.wait(timeout: acceptTimeout)
        defer { connection.cancel() }
        try await FileTransferSession.send(
            files: files,
            urls: urls,
            io: NWFileTransferIO(connection: connection)
        )
    }
}

private final class TransferContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }
}

/// Waits for the phone's connection to the short-lived file server to become ready (TLS
/// handshake complete), with a timeout so a phone that never connects cannot leak the listener.
private final class AcceptedTransferConnection: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var connection: NWConnection?
    private var isReady = false
    private var continuation: CheckedContinuation<NWConnection, Error>?
    private var settledError: Error?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func attach(_ connection: NWConnection) {
        lock.lock()
        let alreadyAttached = self.connection != nil
        if !alreadyAttached {
            self.connection = connection
        }
        lock.unlock()
        guard !alreadyAttached else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.markReady()
            case .failed(let error):
                self.fail(error)
            case .cancelled:
                self.fail(CancellationError())
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func wait(timeout: TimeInterval) async throws -> NWConnection {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWConnection, Error>) in
            lock.lock()
            if let settledError {
                lock.unlock()
                continuation.resume(throwing: settledError)
                return
            }
            if isReady, let connection {
                lock.unlock()
                continuation.resume(returning: connection)
                return
            }
            self.continuation = continuation
            lock.unlock()
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.fail(POSIXError(.ETIMEDOUT))
            }
        }
    }

    private func markReady() {
        lock.lock()
        guard settledError == nil else {
            lock.unlock()
            return
        }
        isReady = true
        let pending = continuation
        continuation = nil
        let connection = self.connection
        lock.unlock()
        guard let connection else { return }
        pending?.resume(returning: connection)
    }

    private func fail(_ error: Error) {
        lock.lock()
        guard settledError == nil else {
            lock.unlock()
            return
        }
        settledError = error
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }
}
