import AppKit
import SefirahCore
import SwiftUI

struct NotificationAppSelectionView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filteredApps: [ApplicationRecord] {
        model.apps
            .filter { query.isEmpty || $0.appName.localizedCaseInsensitiveContains(query) }
            .sorted {
                $0.appName.localizedStandardCompare($1.appName) == .orderedAscending
            }
    }

    private var allFilteredSelected: Bool {
        guard !filteredApps.isEmpty else { return false }
        return filteredApps.allSatisfy { $0.filter != .disabled }
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Notification Apps")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") {
                    dismiss()
                }
            }

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search apps", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button(action: { query = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )

            // Select / Deselect All Button and status summary
            HStack {
                Button(allFilteredSelected ? "Deselect All" : "Select All") {
                    toggleSelectAll()
                }
                .disabled(filteredApps.isEmpty)

                Spacer()
                Text("\(model.apps.filter { $0.filter != .disabled }.count) of \(model.apps.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if filteredApps.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "No apps found" : "No matching apps",
                    systemImage: "magnifyingglass",
                    description: Text(query.isEmpty ? "Refresh the selected phone's app list, then try again." : "No apps match \"\(query)\".")
                )
            } else {
                List(filteredApps, id: \.appKey) { app in
                    Toggle(
                        app.appName,
                        isOn: Binding(
                            get: { app.filter != .disabled },
                            set: { model.setAppNotificationsEnabled(app, isEnabled: $0) }
                        )
                    )
                    .toggleStyle(.checkbox)
                }
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 480)
    }

    private func toggleSelectAll() {
        let enable = !allFilteredSelected
        for app in filteredApps {
            model.setAppNotificationsEnabled(app, isEnabled: enable)
        }
    }
}
