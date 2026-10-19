import AppKit
import SefirahCore
import SwiftUI

struct DeviceRailView: View {
    @Bindable var model: AppModel

    private let streamOrder: [AudioStreamType] = [.media, .ring, .notification, .alarm, .voiceCall]
    @State private var wirelessPairing: WirelessPairingModel?
    @State private var showAdbInfo = false
    @State private var isCheckingAdb = false
    @State private var isPreviewHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let device = model.selectedDevice {
                HStack(alignment: .top, spacing: 12) {
                    phonePreview(device)
                    VStack(alignment: .leading, spacing: 8) {
                        deviceCard(device)
                        Picker("Ringer", selection: ringerBinding) {
                            Text("Silent").tag(0)
                            Text("Vibrate").tag(1)
                            Text("Ring").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(!device.isConnected)
                        deviceActions(device)
                        if let status = model.fileTransferStatus {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let battery = model.live.battery {
                    Label(
                        "\(battery.batteryLevel)%\(battery.isCharging ? " charging" : "")",
                        systemImage: battery.isCharging ? "battery.100.bolt" : "battery.100"
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Volume").font(.caption).foregroundStyle(.secondary)
                    ForEach(streamOrder, id: \.self) { type in
                        StreamVolumeRow(
                            type: type,
                            level: model.live.audioStreams[type] ?? 0,
                            enabled: device.isConnected
                        ) { model.setAudioLevel(type, level: $0) }
                    }
                }

                ForEach(model.visiblePlayback, id: \.source) { session in
                    mediaCard(session, connected: device.isConnected)
                }
                NotificationFeedView(model: model)
            } else {
                Text("Available devices").font(.headline)
                if model.discovered.isEmpty {
                    Text("No phone connected. Pair a device from Settings or complete onboarding.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.discovered) { peer in
                    Button("\(peer.name)  \(peer.verificationKey)") { model.pair(peer) }
                }
            }
            Spacer()
            if let error = model.sessionError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $wirelessPairing) { WirelessPairingView(model: $0) }
    }

    private var ringerBinding: Binding<Int> {
        Binding(
            get: { model.live.ringerMode ?? 2 },
            set: { model.setRingerMode($0) }
        )
    }

    /// The phone preview doubles as the mirror button: click to mirror (or to stop mirroring).
    private func phonePreview(_ device: ConnectedPeer) -> some View {
        Button {
            if model.isMirroring(device.id) {
                model.stopMirrors(deviceId: device.id)
            } else if !model.isMirrorPending(device.id) {
                model.startMirror()
            }
        } label: {
            ZStack {
                if let wallpaper = model.deviceWallpapers[device.id] {
                    Image(nsImage: wallpaper)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(
                        colors: [
                            Color(red: 0.0, green: 0.44, blue: 1.0),
                            Color(red: 0.18, green: 0.56, blue: 1.0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                // Resting state sits dimmed; hovering brightens it and reveals the cast glyph.
                Color.black.opacity(isPreviewHovered ? 0.15 : 0.35)
                if model.isMirrorPending(device.id) {
                    ZStack {
                        Color.black.opacity(0.45)
                        ProgressView()
                            .controlSize(.small)
                    }
                } else if isPreviewHovered, previewInteractable(device) {
                    Image(systemName: "airplayvideo")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.55), radius: 3)
                }
            }
            .frame(width: 54, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.primary.opacity(0.3), lineWidth: 1.5)
            )
            .animation(.easeInOut(duration: 0.12), value: isPreviewHovered)
        }
        .buttonStyle(.plain)
        .disabled(
            model.isMirrorPending(device.id)
                || (!model.isMirroring(device.id) && !model.canMirror)
        )
        .onHover { isPreviewHovered = $0 }
        .help(previewHelp(device))
        .accessibilityLabel(model.isMirroring(device.id) ? "Stop mirroring" : "Mirror the phone screen")
    }

    private func previewInteractable(_ device: ConnectedPeer) -> Bool {
        model.isMirroring(device.id) || model.canMirror || model.isMirrorPending(device.id)
    }

    private func previewHelp(_ device: ConnectedPeer) -> LocalizedStringKey {
        if model.isMirroring(device.id) { return "Stop mirroring" }
        if model.isMirrorPending(device.id) { return "Starting the mirror…" }
        if model.canMirror { return "Mirror the phone screen" }
        return "Bundled adb/scrcpy is missing. Reinstall Sefirah or set a custom scrcpy path in Settings."
    }

    /// Icon-only phone actions under the ringer control: find, DND, files and clipboard (the
    /// phone preview is the mirror button).
    private func deviceActions(_ device: ConnectedPeer) -> some View {
        HStack(spacing: 8) {
            actionButton(
                systemImage: model.live.soundPlaying ? "speaker.slash.fill" : "iphone.radiowaves.left.and.right",
                help: model.live.soundPlaying ? "Stop ringing the phone" : "Ring the phone"
            ) {
                model.toggleFindPhone()
            }

            actionButton(
                systemImage: model.live.dndEnabled == true ? "minus.circle.fill" : "minus.circle",
                help: model.live.dndEnabled == true ? "Do Not Disturb is on" : "Turn on Do Not Disturb",
                tint: model.live.dndEnabled == true ? Color.accentColor : Color.primary
            ) {
                model.toggleDnd()
            }

            mountButton(device)

            actionButton(systemImage: "doc.on.clipboard", help: "Send the Mac clipboard to the phone") {
                model.sendClipboard()
            }

            actionButton(
                systemImage: "square.and.arrow.up",
                help: "Send files to the phone",
                isEnabled: device.isConnected
            ) {
                chooseFilesToSend()
            }
        }
    }

    /// Folder button for the action row: mounts this phone's storage in Finder, becomes an eject
    /// button while its volume is mounted, and a spinner while its bridge starts or stops. Every
    /// phone keeps its own mount, so mounting another phone doesn't affect this one.
    @ViewBuilder
    private func mountButton(_ device: ConnectedPeer) -> some View {
        let session = model.phoneMount.session(for: device.id)
        if session.isBusy {
            ProgressView()
                .controlSize(.small)
                .frame(width: 34, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.quaternary)
                )
        } else if session.volume != nil {
            actionButton(
                systemImage: "eject",
                help: "Unmount the phone's files",
                tint: Color.accentColor
            ) {
                model.togglePhoneMount(for: device)
            }
        } else {
            actionButton(
                systemImage: "folder",
                help: "Mount the phone's files in Finder",
                isEnabled: device.isConnected
            ) {
                model.togglePhoneMount(for: device)
            }
        }
    }

    /// Files-only open panel; picks one or more files and hands them to the model to send.
    private func chooseFilesToSend() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose files to send to the phone"
        panel.prompt = "Send"
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            model.sendFiles(panel.urls)
        }
    }

    /// Compact rectangular icon button used by the phone action row.
    private func actionButton(
        systemImage: String,
        help: LocalizedStringKey,
        tint: Color = .primary,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 34, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.quaternary)
        )
        .help(help)
    }

    private func deviceCard(_ device: ConnectedPeer) -> some View {
        VStack(alignment: .leading) {
            Text(device.name).font(.title3.weight(.semibold))
            HStack(spacing: 8) {
                deviceStatus(device)
            }
            if model.paired.count > 1 {
                Picker("Device", selection: $model.selectedDeviceID) {
                    ForEach(model.paired) { peer in
                        Text(peer.name).tag(Optional(peer.id))
                    }
                }
                .onChange(of: model.selectedDeviceID) { _, _ in model.refreshDevice() }
            }
        }
        .contextMenu {
            if !device.isConnected {
                Button("Connect") { model.reconnect(device) }
            }
            Button("Forget Device", role: .destructive) { model.forget(device) }
        }
    }

    /// The selected phone's connection status. Green "Connected" once both the app and adb see the
    /// phone. While adb can't see it, "Connected" becomes an orange button that re-checks adb and,
    /// if the phone is still invisible to adb, opens the Wireless-debugging QR pairing sheet; the
    /// info button explains which features need adb.
    @ViewBuilder
    private func deviceStatus(_ device: ConnectedPeer) -> some View {
        if !device.isConnected {
            Text("Disconnected").foregroundStyle(.secondary)
            Button("Connect") { model.reconnect(device) }
                .controlSize(.small)
        } else if model.isAdbConnected(device.id) {
            Text("Connected").foregroundStyle(.green)
        } else {
            Button("Connected") {
                isCheckingAdb = true
                Task {
                    let connected = await model.connectAdb(for: device.id)
                    isCheckingAdb = false
                    if !connected {
                        wirelessPairing = model.makeWirelessPairingModel(deviceID: device.id)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)
            .disabled(!model.canWirelessPair || isCheckingAdb)
            .help("ADB can't see this phone yet. Click to connect over adb, or pair over Wi-Fi (QR code).")
            Button {
                showAdbInfo = true
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("ADB status: not connected")
            .popover(isPresented: $showAdbInfo, arrowEdge: .bottom) {
                adbInfoPopover(device)
            }
        }
    }

    private func adbInfoPopover(_ device: ConnectedPeer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Phone not connected to adb", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout.weight(.medium))
            Text("The app can reach \(device.name), but adb can't see it. Mirroring and clipboard features will not be available until the phone is connected over adb.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.canWirelessPair {
                Text("Bundled adb is unavailable — reinstall Sefirah or set a custom adb path in Settings.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private func mediaCard(_ session: PlaybackInfo, connected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                mediaArtwork(session)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.trackTitle ?? "Playback")
                        .font(.headline)
                        .lineLimit(2)
                    if let artist = session.artist, !artist.isEmpty {
                        Text(artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let app = session.appName, !app.isEmpty {
                        Text(app).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }

            if let max = session.maxSeekTime, max > 0 {
                VStack(spacing: 2) {
                    Slider(
                        value: Binding(
                            get: { min(session.position ?? 0, max) },
                            set: { model.sendMediaAction(.seek, source: session.source, value: $0) }
                        ),
                        in: (session.minSeekTime ?? 0)...max
                    )
                    .disabled(!connected || session.canSeek == false)
                    HStack {
                        Text(timeText(min(session.position ?? 0, max)))
                        Spacer()
                        Text(timeText(max))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            HStack {
                if session.canGoPrevious != false {
                    Button {
                        model.sendMediaAction(.previous, source: session.source)
                    } label: {
                        Image(systemName: "backward.fill")
                    }
                    .disabled(!connected)
                }
                Button {
                    model.sendMediaAction(session.isPlaying ? .pause : .play, source: session.source)
                } label: {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                }
                .disabled(!connected)
                if session.canGoNext != false {
                    Button {
                        model.sendMediaAction(.next, source: session.source)
                    } label: {
                        Image(systemName: "forward.fill")
                    }
                    .disabled(!connected)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Album art from the phone, with a music-note placeholder when the session has none.
    @ViewBuilder
    private func mediaArtwork(_ session: PlaybackInfo) -> some View {
        if let data = artworkData(session.thumbnail),
           let image = IconImageCache.image(for: data, key: "media:\(session.source)")
        {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(width: 76, height: 76)
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)
                .frame(width: 76, height: 76)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
        }
    }

    private func artworkData(_ thumbnail: String?) -> Data? {
        guard let thumbnail, !thumbnail.isEmpty else { return nil }
        return Data(base64Encoded: thumbnail, options: [.ignoreUnknownCharacters])
    }

    /// The phone reports positions and durations in milliseconds.
    private func timeText(_ milliseconds: Double) -> String {
        let total = Int((milliseconds / 1000).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct StreamVolumeRow: View {
    var title: String?
    var type: AudioStreamType?
    var level: Int
    var enabled: Bool
    var onCommit: (Int) -> Void
    @State private var value: Double

    init(title: String? = nil, type: AudioStreamType?, level: Int, enabled: Bool, onCommit: @escaping (Int) -> Void) {
        self.title = title
        self.type = type
        self.level = level
        self.enabled = enabled
        self.onCommit = onCommit
        _value = State(initialValue: Double(level))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title ?? type?.railLabel ?? "Volume")
                Spacer()
                Text("\(Int(value))")
            }
            .font(.caption)
            Slider(value: $value, in: 0...100, step: 1) { editing in
                if !editing { onCommit(Int(value.rounded())) }
            }
            .disabled(!enabled)
        }
        .onChange(of: level) { _, newValue in
            value = Double(newValue)
        }
    }
}

private extension AudioStreamType {
    var railLabel: String {
        switch self {
        case .media: "Media"
        case .ring: "Ring"
        case .notification: "Notification"
        case .alarm: "Alarm"
        case .voiceCall: "Call"
        }
    }
}
