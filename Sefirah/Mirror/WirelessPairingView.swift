import AppKit
import OSLog
import SefirahCore
import SwiftUI

/// Everything the pairing sheet needs to talk to adb (bundled or overridden).
struct WirelessPairingContext {
    var adb: URL
    var environment: [String: String]
    var runner: any CommandRunning
    /// The paired phone being connected; used to recognise any of its adb transports.
    var peerAddress: String
    var peerModel: String
}

/// Drives the "pair over Wi-Fi (QR code)" sheet.
///
/// Flow: show a QR code; the phone scans it and advertises an `_adb-tls-pairing` mDNS service
/// under the name we chose; we discover it with `adb mdns services`, pair with `adb pair`, then
/// wait for the phone's `_adb-tls-connect` service and connect.
@MainActor
@Observable
final class WirelessPairingModel: Identifiable {
    enum Phase: Equatable {
        case idle
        case waitingForScan
        case pairing
        case connecting
        case connected(serial: String)
        case failed(String)
    }

    let id = UUID()
    let serviceName: String
    let qrImage: NSImage?
    private(set) var phase: Phase = .idle

    private let password: String
    private let context: WirelessPairingContext
    private let onConnected: @MainActor (String) -> Void
    private var task: Task<Void, Never>?

    private nonisolated static let log = Logger(
        subsystem: "io.github.madeye.sefirah.mac", category: "wireless-pairing"
    )

    /// Re-check adb's mDNS view / device list twice a second while the sheet is open.
    private static let pollInterval: Duration = .milliseconds(500)

    init(context: WirelessPairingContext, onConnected: @escaping @MainActor (String) -> Void) {
        self.context = context
        self.onConnected = onConnected
        let serviceName = AdbWirelessPairing.randomServiceName()
        let password = AdbWirelessPairing.randomPassword()
        self.serviceName = serviceName
        self.password = password
        self.qrImage = QrCodeImage.make(
            AdbWirelessPairing.qrText(serviceName: serviceName, password: password),
            scale: 10
        )
    }

    var statusText: String {
        switch phase {
        case .idle: return "Ready."
        case .waitingForScan: return "Waiting for the phone to scan the code…"
        case .pairing: return "Pairing…"
        case .connecting: return "Paired. Connecting…"
        case .connected(let serial): return "Connected as \(serial)."
        case .failed(let message): return message
        }
    }

    var isWorking: Bool {
        switch phase {
        case .waitingForScan, .pairing, .connecting: return true
        default: return false
        }
    }

    var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        let client = AdbClient(adb: context.adb, environment: context.environment, runner: context.runner)

        if let check = try? await client.mdnsCheck(),
           !check.lowercased().contains("daemon version")
        {
            phase = .failed("adb's mDNS discovery is unavailable. Update Android platform-tools or restart adb.")
            return
        }

        phase = .waitingForScan
        var pairing: AdbMdnsService?
        let pairDeadline = Date().addingTimeInterval(120)
        while !Task.isCancelled, Date() < pairDeadline {
            let snapshot = await self.snapshot(client: client)
            // adb already reaches the phone over USB, TCP/IP or wireless debugging — nothing left
            // to pair, so the sheet can close right away.
            if let serial = connectedSerial(in: snapshot) {
                phase = .connected(serial: serial)
                onConnected(serial)
                return
            }
            if let match = AdbWirelessPairing.pairingService(in: snapshot.services, name: serviceName) {
                pairing = match
                break
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
        guard let pairing else {
            if !Task.isCancelled {
                phase = .failed("Timed out. Make sure the phone is on the same Wi-Fi and the code was scanned.")
            }
            return
        }

        phase = .pairing
        Self.log.notice("pairing with \(pairing.host, privacy: .public):\(pairing.port)")
        do {
            try await client.pair(host: pairing.host, port: pairing.port, code: password)
        } catch {
            phase = .failed("Pairing failed: \(error.localizedDescription)")
            return
        }

        phase = .connecting
        if let serial = await waitForConnectedDevice(client: client, host: pairing.host) {
            // A QR pairing also opens the classic TCP/IP port (6767) so Sefirah keeps a stable
            // `ip:6767` endpoint going forward. Restarting adbd drops the wireless transport, so
            // if the switch fails we restore the wireless connection instead.
            let preferred: String
            if let tcpSerial = await client.enableTcpIp(serial: serial, address: pairing.host) {
                preferred = tcpSerial
            } else if let restored = await client.connectWirelessDevice(address: pairing.host) {
                preferred = restored
            } else {
                preferred = serial
            }
            Self.log.notice("connected as \(preferred, privacy: .public)")
            phase = .connected(serial: preferred)
            onConnected(preferred)
        } else {
            phase = .failed("Paired, but could not connect. Keep Wireless debugging on and try again.")
        }
    }

    /// One sample of adb's device list plus its mDNS services.
    private func snapshot(client: AdbClient) async -> (devices: [AdbDevice], services: [AdbMdnsService]) {
        let devices = (try? await client.devices()) ?? []
        let services = (try? await client.mdnsServices()) ?? []
        return (devices, services)
    }

    /// The phone's serial if adb reaches it over USB, TCP/IP or wireless debugging. Logs every ping
    /// so the polling is visible in Console / `log stream`.
    private func connectedSerial(
        in snapshot: (devices: [AdbDevice], services: [AdbMdnsService])
    ) -> String? {
        if let serial = AdbWirelessPairing.connectedSerial(
            devices: snapshot.devices,
            services: snapshot.services,
            address: context.peerAddress,
            model: context.peerModel
        ) {
            Self.log.notice("ping: \(self.context.peerAddress, privacy: .public) connected as \(serial, privacy: .public)")
            return serial
        }
        let seen = snapshot.devices.map(\.serial).joined(separator: ", ")
        Self.log.notice("ping: no match for \(self.context.peerAddress, privacy: .public); adb sees [\(seen, privacy: .public)]")
        return nil
    }

    private func waitForConnectedDevice(client: AdbClient, host: String) async -> String? {
        let deadline = Date().addingTimeInterval(30)
        while !Task.isCancelled, Date() < deadline {
            let snapshot = await self.snapshot(client: client)
            if let serial = connectedSerial(in: snapshot) {
                return serial
            }
            if let service = AdbWirelessPairing.connectService(in: snapshot.services, host: host),
               let connected = try? await client.connect(host: service.host, port: service.port)
            {
                return connected
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return nil
    }
}

/// Sheet that shows the QR code and the live pairing status.
struct WirelessPairingView: View {
    let model: WirelessPairingModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair over Wi-Fi").font(.headline)
            Text("On the phone, open Developer options → Wireless debugging → Pair device with QR code, then scan this code.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            if let qr = model.qrImage {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(10)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .opacity(model.isWorking ? 1 : 0)
                Text(model.statusText)
                    .font(.callout)
                    .foregroundStyle(model.isFailed ? Color.red : (model.isConnected ? Color.green : Color.secondary))
                    .multilineTextAlignment(.center)
            }

            HStack {
                Button("Cancel") {
                    model.cancel()
                    dismiss()
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.isConnected)
            }
            .frame(maxWidth: 320)
        }
        .padding(24)
        .frame(width: 400)
        .task { model.start() }
        .onChange(of: model.phase) { _, phase in
            // Pairing finished and the device is reachable: close the sheet unprompted.
            if case .connected = phase { dismiss() }
        }
        .onDisappear { model.cancel() }
    }
}
