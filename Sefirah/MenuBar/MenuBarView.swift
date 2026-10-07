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

    private func openButton(for app: ApplicationRecord) -> some View {
        Button(app.appName) {
            model.startMirror(package: app.packageName, appName: app.appName)
        }
    }
}
