import AppKit
import SefirahCore
import SwiftUI

struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let device = model.selectedDevice {
                Text(device.name).font(.headline)
                Text(device.isConnected ? "Connected" : "Disconnected")
            } else {
                Text("Sefirah").font(.headline)
            }
            if let note = model.notifications.first {
                Text(note.title ?? note.appName).lineLimit(1)
            }
            Divider()
            if model.general.menuBarOpenApps {
                Menu {
                    let pinned = model.sortedApps.filter(\.pinned)
                    let recent = model.recentlyOpenedApps.filter { !$0.pinned }
                    if pinned.isEmpty && recent.isEmpty {
                        Text("No apps to open")
                    } else {
                        if !pinned.isEmpty {
                            Section("Pinned") {
                                ForEach(pinned, id: \.appKey) { app in
                                    openButton(for: app)
                                }
                            }
                        }
                        if !recent.isEmpty {
                            Section("Recent") {
                                ForEach(recent, id: \.appKey) { app in
                                    openButton(for: app)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Open apps", systemImage: "square.grid.2x2")
                }
                .disabled(model.recentlyOpenedApps.isEmpty && model.apps.allSatisfy { !$0.pinned })
            }
            if model.general.menuBarScreenMirror {
                screenMirrorButton
            }
            if model.general.menuBarDnd {
                Button {
                    model.toggleDnd()
                } label: {
                    Label(model.live.dndEnabled == true ? "DND On" : "DND", systemImage: "moon")
                }
                .disabled(model.selectedDevice?.isConnected != true)
            }
            if model.general.menuBarRinger {
                Picker("Ringer", selection: ringerBinding) {
                    Text("Silent").tag(0)
                    Text("Vibrate").tag(1)
                    Text("Ring").tag(2)
                }
                .pickerStyle(.menu)
                .disabled(model.selectedDevice?.isConnected != true)
            }
            if model.general.menuBarSendClipboard {
                Button {
                    model.sendClipboard()
                } label: {
                    Label("Send clipboard", systemImage: "doc.on.clipboard")
                }
                .disabled(model.selectedDevice?.isConnected != true)
            }
            if showsMenuBarButtons {
                Divider()
            }
            Button("Show Window") {
                NSApp.setActivationPolicy(.regular)
                model.showMainWindow = true
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button(model.live.soundPlaying ? "Stop find phone" : "Find phone") {
                model.toggleFindPhone()
            }
            Button("Quit Sefirah") {
                NSApp.terminate(nil)
            }
        }
        .padding(8)
        .frame(minWidth: 220)
    }

    private var showsMenuBarButtons: Bool {
        model.general.menuBarOpenApps || model.general.menuBarScreenMirror || model.general.menuBarDnd
            || model.general.menuBarRinger || model.general.menuBarSendClipboard
    }

    private var ringerBinding: Binding<Int> {
        Binding(
            get: { model.live.ringerMode ?? 2 },
            set: { model.setRingerMode($0) }
        )
    }

    @ViewBuilder
    private var screenMirrorButton: some View {
        if let device = model.selectedDevice, model.isMirroring(device.id) {
            Button {
                model.stopMirrors(deviceId: device.id)
            } label: {
                Label("Stop mirroring", systemImage: "stop.circle")
            }
        } else {
            Button {
                startMirroring()
            } label: {
                Label("Screen mirror", systemImage: "rectangle.on.rectangle")
            }
            .disabled(model.selectedDevice?.isConnected != true || !model.canMirror)
        }
    }

    /// Native mirrors render in the app's Mirror tab, so bring the window up before starting one.
    private func startMirroring() {
        if model.general.mirrorBackend == .native {
            NSApp.setActivationPolicy(.regular)
            model.showMainWindow = true
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        model.startMirror()
    }

    private func openButton(for app: ApplicationRecord) -> some View {
        Button(app.appName) {
            model.startMirror(package: app.packageName, appName: app.appName)
        }
    }
}
