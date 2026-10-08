import AppKit
import SefirahCore
import SwiftUI

/// How the Apps tab lays out the phone's launcher apps.
enum AppsViewMode: String, CaseIterable, Identifiable {
    case list
    case grid
    case doubleGrid

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .list: "list.bullet"
        case .grid: "square.grid.2x2"
        case .doubleGrid: "square.grid.3x3.fill"
        }
    }

    var help: LocalizedStringKey {
        switch self {
        case .list: "List"
        case .grid: "Grid"
        case .doubleGrid: "Double grid"
        }
    }
}

struct AppsView: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @AppStorage("AppsViewMode") private var viewMode: AppsViewMode = .list

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Apps").font(.title2.weight(.semibold))
                Spacer()
                Picker("View", selection: $viewMode) {
                    ForEach(AppsViewMode.allCases) { mode in
                        Image(systemName: mode.systemImage)
                            .help(mode.help)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
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
                switch viewMode {
                case .list:
                    listLayout(filtered)
                case .grid:
                    gridLayout(filtered, compact: false)
                case .doubleGrid:
                    gridLayout(filtered, compact: true)
                }
            }
        }
    }

    private func listLayout(_ apps: [ApplicationRecord]) -> some View {
        List(apps, id: \.appKey) { app in
            AppRow(app: app, model: model)
        }
    }

    private func gridLayout(_ apps: [ApplicationRecord], compact: Bool) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: compact ? 64 : 96), spacing: compact ? 10 : 16)],
                spacing: compact ? 10 : 16
            ) {
                ForEach(apps, id: \.appKey) { app in
                    AppTile(app: app, model: model, compact: compact)
                }
            }
            .padding()
        }
    }
}

/// The app's iOS-shaped icon, decoded once per icon payload.
private struct AppIconView: View {
    let app: ApplicationRecord
    var size: CGFloat

    var body: some View {
        if let image = AppIconCache.image(for: app) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                .fill(.quaternary)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "app")
                        .font(.system(size: size * 0.42))
                        .foregroundStyle(.secondary)
                }
        }
    }
}

@MainActor
private enum AppIconCache {
    private static let images = NSCache<NSString, NSImage>()

    static func image(for app: ApplicationRecord) -> NSImage? {
        guard let data = app.icon else { return nil }
        let key = "\(app.appKey)#\(data.count)#\(data.hashValue)" as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }
}

/// List row: click launches on the phone, right-click pins.
private struct AppRow: View {
    let app: ApplicationRecord
    @Bindable var model: AppModel

    private var isPending: Bool {
        model.selectedDevice.map { model.isMirrorPending("\($0.id):\(app.packageName)") } ?? true
    }

    var body: some View {
        Button {
            model.startMirror(package: app.packageName, appName: app.appName)
        } label: {
            HStack(spacing: 10) {
                AppIconView(app: app, size: 26)
                Text(app.appName)
                Spacer()
                if app.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPending)
        .contextMenu {
            Button(app.pinned ? "Unpin" : "Pin") { model.togglePinnedApp(app) }
        }
    }
}

/// Grid cell: click launches on the phone, right-click pins.
private struct AppTile: View {
    let app: ApplicationRecord
    @Bindable var model: AppModel
    let compact: Bool

    private var isPending: Bool {
        model.selectedDevice.map { model.isMirrorPending("\($0.id):\(app.packageName)") } ?? true
    }

    var body: some View {
        Button {
            model.startMirror(package: app.packageName, appName: app.appName)
        } label: {
            VStack(spacing: compact ? 4 : 6) {
                AppIconView(app: app, size: compact ? 40 : 64)
                    .overlay(alignment: .topTrailing) {
                        if app.pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: compact ? 7 : 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(compact ? 2 : 3)
                                .background(.orange, in: Circle())
                                .offset(x: compact ? 3 : 6, y: compact ? -2 : -4)
                        }
                    }
                Text(app.appName)
                    .font(compact ? .caption2 : .caption)
                    .lineLimit(compact ? 1 : 2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact ? 4 : 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPending)
        .help(app.appName)
        .contextMenu {
            Button(app.pinned ? "Unpin" : "Pin") { model.togglePinnedApp(app) }
        }
    }
}
