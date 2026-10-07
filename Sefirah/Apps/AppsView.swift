import SefirahCore
import SwiftUI

struct AppsView: View {
    @Bindable var model: AppModel
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Apps").font(.title2.weight(.semibold))
                Spacer()
                TextField("Search", text: $query)
                    .frame(width: 200)
                Button("Refresh") { model.refreshDevice() }
            }
            .padding()

            let filtered = model.sortedApps.filter {
                query.isEmpty || $0.appName.localizedCaseInsensitiveContains(query)
            }

            if filtered.isEmpty {
                ContentUnavailableView(
                    "No apps",
                    systemImage: "square.grid.2x2",
                    description: Text("Connected phones sync their launcher apps here.")
                )
            } else {
                List(filtered, id: \.appKey) { app in
                    AppRow(app: app, model: model)
                }
            }
        }
    }
}


private struct AppRow: View {
    let app: ApplicationRecord
    @Bindable var model: AppModel
    @State private var isHovering = false

    var body: some View {
        HStack {
            Text(app.appName)
            Spacer()

            if app.pinned || isHovering {
                Button {
                    model.togglePinnedApp(app)
                } label: {
                    Image(systemName: app.pinned ? "pin.fill" : "pin")
                        .foregroundStyle(app.pinned ? .orange : .secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(app.pinned ? "Unpin \(app.appName)" : "Pin \(app.appName)")
            }

            Button("Launch") {
                model.startMirror(package: app.packageName, appName: app.appName)
            }
            .disabled(model.selectedDevice.map {
                model.isMirrorPending("\($0.id):\(app.packageName)")
            } ?? true)
        }
        .onHover { isHovering = $0 }
    }
}
