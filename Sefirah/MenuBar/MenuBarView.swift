import AppKit
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
                if model.recentlyOpenedApps.isEmpty {
                    Text("No recently opened apps")
                } else {
                    ForEach(model.recentlyOpenedApps, id: \.appKey) { app in
                        Button(app.appName) {
                            model.startMirror(package: app.packageName, appName: app.appName)
                        }
                    }
                }
            } label: {
                Label("Recently Opened Apps", systemImage: "clock")
            }
            .disabled(model.recentlyOpenedApps.isEmpty)

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
}
