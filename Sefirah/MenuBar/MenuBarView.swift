import AppKit
import SefirahCore
import SwiftUI

struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    /// Contrast color for the panel's iconography.
    private let accent = Color.blue

    private let ringerModes = [0, 1, 2]

    @State private var openAppsExpanded = false
    @State private var ringerExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.general.menuBarMediaPlayer, let session = model.visiblePlayback.first {
                mediaChip(session)
            }
            if let note = model.notifications.first {
                notificationChip(note)
            }
            Divider()
            if showsMenuBarButtons {
                featureRows
                Divider()
            }
            VStack(alignment: .leading, spacing: 2) {
                MenuBarRowButton(title: "Show Window", systemImage: "macwindow", tint: accent) {
                    showWindow()
                }
                if let device = model.selectedDevice, !device.isConnected {
                    MenuBarRowButton(
                        title: "Reconnect",
                        systemImage: "arrow.clockwise",
                        tint: .orange
                    ) {
                        model.reconnectSelectedDevice()
                    }
                }
                MenuBarRowButton(title: "Quit Sefirah", systemImage: "power", tint: .red) {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(10)
        .frame(minWidth: 280)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.16), .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)

            if model.paired.count > 1 {
                Menu {
                    ForEach(model.paired) { device in
                        Button {
                            model.selectDevice(device.id)
                        } label: {
                            if device.id == model.selectedDeviceID {
                                Label(device.name, systemImage: "checkmark")
                            } else {
                                Text(device.name)
                            }
                        }
                    }
                } label: {
                    headerLabel
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                headerLabel
            }
            Spacer(minLength: 0)
        }
    }

    /// Selected device name and status; doubles as the multi-device dropdown's label.
    private var headerLabel: some View {
        HStack(spacing: 5) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.selectedDevice?.name ?? "Sefirah")
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if model.paired.count > 1 {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var statusColor: Color {
        guard let device = model.selectedDevice else { return .secondary }
        return device.isConnected ? .green : .orange
    }

    private var statusText: String {
        guard let device = model.selectedDevice else { return "No device" }
        return device.isConnected ? "Connected" : "Disconnected"
    }

    /// Android 15-style player card, glass-ified with materials: album art backdrop, source chip,
    /// big play button and a transport row. Shown while playing, and up to 10 minutes after pausing
    /// (older sessions are pruned; sessions from before the current connection are cleared).
    private func mediaChip(_ session: PlaybackInfo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Spacer(minLength: 0)
                    HStack(spacing: 3) {
                        Image(systemName: outputIconName)
                            .font(.system(size: 9, weight: .semibold))
                        Text(model.phoneMediaOutputLabel ?? model.selectedDevice?.name ?? "This phone")
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                }

                Spacer(minLength: 0)

                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.trackTitle ?? "Playback")
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(session.artist ?? session.appName ?? session.source)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)

                    Spacer(minLength: 0)

                    glassCircleButton(
                        session.isPlaying ? "pause.fill" : "play.fill",
                        diameter: 38,
                        fontSize: 15
                    ) {
                        model.sendMediaAction(session.isPlaying ? .pause : .play, source: session.source)
                    }
                }

                HStack(spacing: 6) {
                    transportButton("backward.fill") {
                        model.sendMediaAction(.previous, source: session.source)
                    }

                    if let max = session.maxSeekTime, max > 0 {
                        Slider(
                            value: Binding(
                                get: { min(session.position ?? 0, max) },
                                set: { model.sendMediaAction(.seek, source: session.source, value: $0) }
                            ),
                            in: (session.minSeekTime ?? 0)...max
                        )
                        .controlSize(.mini)
                        .tint(.white)
                        .disabled(session.canSeek == false)
                    } else {
                        Spacer()
                    }
                    transportButton("forward.fill") {
                        model.sendMediaAction(.next, source: session.source)
                    }
                }
                .padding(.horizontal, -4)
        }
        .padding(12)
        // The art is a background so it can't stretch the card layout; the content defines the size.
        .frame(height: 122)
        .frame(maxWidth: .infinity)
        .background { mediaBackdrop(session) }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }

    /// Album art fills the card under a glass wash; falls back to plain glass.
    @ViewBuilder
    private func mediaBackdrop(_ session: PlaybackInfo) -> some View {
        if let data = artworkData(session.thumbnail),
           let image = IconImageCache.image(for: data, key: "menu-media:\(session.source)")
        {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .overlay {
                    LinearGradient(
                        colors: [.black.opacity(0.65), .black.opacity(0.15)],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                }
                .overlay {
                    Rectangle().fill(.ultraThinMaterial).opacity(0.25)
                }
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
        }
    }

    private var outputIconName: String {
        guard let label = model.phoneMediaOutputLabel else { return "iphone" }
        if label.contains("Headphones") { return "headphones" }
        if label.contains("Bluetooth") { return "antenna.radiowaves.left.and.right" }
        return "speaker.wave.2.fill"
    }

    /// Borderless transport glyph for the skip buttons — no glass disc, so it can hug the edge.
    private func transportButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func glassCircleButton(
        _ symbol: String,
        diameter: CGFloat,
        fontSize: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private func artworkData(_ thumbnail: String?) -> Data? {
        guard let thumbnail, !thumbnail.isEmpty else { return nil }
        return Data(base64Encoded: thumbnail, options: [.ignoreUnknownCharacters])
    }

    private func notificationChip(_ note: NotificationSnapshot) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
            Text(note.title ?? note.appName)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    // MARK: - Configurable buttons

    private var showsMenuBarButtons: Bool {
        model.general.menuBarOpenApps || model.general.menuBarScreenMirror || model.general.menuBarDnd
            || model.general.menuBarRinger || model.general.menuBarSendClipboard || model.general.menuBarFindPhone
    }

    @ViewBuilder
    private var featureRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.general.menuBarOpenApps {
                MenuBarRowButton(
                    title: "Open apps",
                    systemImage: "square.grid.2x2",
                    tint: accent,
                    disabled: !hasApps,
                    disclosure: .degrees(openAppsExpanded ? 90 : 0)
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        openAppsExpanded.toggle()
                        if openAppsExpanded { ringerExpanded = false }
                    }
                }
                if openAppsExpanded {
                    openAppsList
                }
            }
            if model.general.menuBarScreenMirror {
                screenMirrorRow
            }
            if model.general.menuBarDnd {
                dndRow
            }
            if model.general.menuBarRinger {
                MenuBarRowButton(
                    title: "Ringer",
                    systemImage: "bell",
                    trailing: ringerName(model.live.ringerMode ?? 2),
                    tint: accent,
                    disabled: !isConnected,
                    disclosure: .degrees(ringerExpanded ? 90 : 0)
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        ringerExpanded.toggle()
                        if ringerExpanded { openAppsExpanded = false }
                    }
                }
                if ringerExpanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(ringerModes, id: \.self) { mode in
                            MenuBarSubRow(
                                title: ringerName(mode),
                                selected: model.live.ringerMode == mode,
                                tint: accent
                            ) {
                                model.setRingerMode(mode)
                                withAnimation(.easeInOut(duration: 0.15)) { ringerExpanded = false }
                            }
                        }
                    }
                }
            }
            if model.general.menuBarSendClipboard {
                MenuBarRowButton(
                    title: "Send clipboard",
                    systemImage: "doc.on.clipboard",
                    tint: accent,
                    disabled: !isConnected
                ) {
                    model.sendClipboard()
                }
            }
            if model.general.menuBarFindPhone {
                MenuBarRowButton(
                    title: model.live.soundPlaying ? "Stop find phone" : "Find phone",
                    systemImage: "iphone.radiowaves.left.and.right",
                    tint: accent,
                    disabled: !isConnected
                ) {
                    model.toggleFindPhone()
                }
            }
        }
    }

    private var hasApps: Bool {
        !model.recentlyOpenedApps.isEmpty || model.apps.contains(where: \.pinned)
    }

    private var openAppsList: some View {
        let pinned = model.sortedApps.filter(\.pinned)
        let recent = model.recentlyOpenedApps.filter { !$0.pinned }
        return VStack(alignment: .leading, spacing: 2) {
            if pinned.isEmpty, recent.isEmpty {
                MenuBarSubRow(title: "No apps to open", disabled: true, tint: accent) {}
            } else {
                if !pinned.isEmpty {
                    if !recent.isEmpty {
                        sectionLabel("Pinned")
                    }
                    ForEach(pinned, id: \.appKey) { app in
                        MenuBarSubRow(title: LocalizedStringKey(app.appName), tint: accent) { launch(app) }
                    }
                }
                if !recent.isEmpty {
                    if !pinned.isEmpty {
                        sectionLabel("Recent")
                    }
                    ForEach(recent, id: \.appKey) { app in
                        MenuBarSubRow(title: LocalizedStringKey(app.appName), tint: accent) { launch(app) }
                    }
                }
            }
        }
    }

    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 35)
            .padding(.top, 4)
    }

    @ViewBuilder
    private var screenMirrorRow: some View {
        if let device = model.selectedDevice, model.isMirroring(device.id) {
            MenuBarRowButton(title: "Stop mirroring", systemImage: "stop.circle", tint: accent) {
                model.stopMirrors(deviceId: device.id)
            }
        } else {
            MenuBarRowButton(
                title: "Screen mirror",
                systemImage: "rectangle.on.rectangle",
                tint: accent,
                disabled: !isConnected || !model.canMirror
            ) {
                startMirror(package: nil, appName: nil)
            }
        }
    }

    private var dndRow: some View {
        MenuBarRowButton(
            title: "Do Not Disturb",
            systemImage: model.live.dndEnabled == true ? "moon.fill" : "moon",
            trailing: model.live.dndEnabled == true ? "On" : "Off",
            tint: accent,
            disabled: !isConnected
        ) {
            model.toggleDnd()
        }
    }

    private func ringerName(_ mode: Int) -> LocalizedStringKey {
        switch mode {
        case 0: "Silent"
        case 1: "Vibrate"
        default: "Ring"
        }
    }

    private var isConnected: Bool { model.selectedDevice?.isConnected == true }

    // MARK: - Actions

    private func launch(_ app: ApplicationRecord) {
        startMirror(package: app.packageName, appName: app.appName)
        withAnimation(.easeInOut(duration: 0.15)) { openAppsExpanded = false }
    }

    /// Native mirrors render in the app's Mirror tab, so bring the window up before starting one.
    private func startMirror(package: String?, appName: String?) {
        if model.general.mirrorBackend == .native {
            showWindow()
        }
        model.startMirror(package: package, appName: appName)
    }

    private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        model.showMainWindow = true
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Icon + title row shared by the panel's buttons.
private struct MenuBarRowLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    var trailing: LocalizedStringKey?
    var tint: Color = .blue
    var disclosure: Angle?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if let disclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(disclosure)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Plain button row with a hover highlight.
private struct MenuBarRowButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var trailing: LocalizedStringKey?
    var tint: Color = .blue
    var disabled = false
    var disclosure: Angle?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            MenuBarRowLabel(title: title, systemImage: systemImage, trailing: trailing, tint: tint, disclosure: disclosure)
                .background(
                    hovering ? tint.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .onHover { hovering = $0 && !disabled }
    }
}

/// Indented row for the Open apps / Ringer lists.
private struct MenuBarSubRow: View {
    let title: LocalizedStringKey
    var selected = false
    var disabled = false
    var tint: Color = .blue
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            .padding(.leading, 35)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                hovering ? tint.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .onHover { hovering = $0 && !disabled }
    }
}
