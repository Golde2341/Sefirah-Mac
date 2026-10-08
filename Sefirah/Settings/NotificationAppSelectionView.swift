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
        return filteredApps.allSatisfy { $0.filter == .toastFeed }
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

            Text("Checked apps show banners with sound. Unchecked apps stay in the notification list without sound — all apps remain listed. To remove an app's notifications entirely, use Hide Notifications from its right-click menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

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
                Text("\(model.apps.filter { $0.filter == .toastFeed }.count) of \(model.apps.count) with sound")
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
                            get: { app.filter == .toastFeed },
                            set: { model.setAppNotificationFilter(app, filter: $0 ? .toastFeed : .feed) }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .help(app.filter == .toastFeed ? "Sound: banners with sound" : (app.filter == .feed ? "Silent: appears in the list without sound" : "Hidden notifications: use the Hidden Notifications settings to restore"))
                }
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 480)
    }

    private func toggleSelectAll() {
        if allFilteredSelected {
            // Mute (silent) everything shown, but leave deliberately hidden apps hidden.
            for app in filteredApps where app.filter != .disabled {
                model.setAppNotificationFilter(app, filter: .feed)
            }
        } else {
            for app in filteredApps {
                model.setAppNotificationFilter(app, filter: .toastFeed)
            }
        }
    }
}

/// Apps whose notifications are silenced, reachable only after device-owner authentication from
/// Settings → Notifications. Checking an app shows its notifications again; apps hidden in the
/// Apps tab stay hidden either way.
struct HiddenNotificationsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Hidden Notifications")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
            }

            Text("Notifications from these apps are hidden. Uncheck an app to show its notifications again — apps hidden in the Apps tab stay hidden.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.hiddenNotificationApps.isEmpty {
                ContentUnavailableView(
                    "No hidden notifications",
                    systemImage: "bell.slash",
                    description: Text("Right-click a notification or an app to hide its notifications.")
                )
            } else {
                List(model.hiddenNotificationApps, id: \.appKey) { app in
                    Toggle(
                        isOn: Binding(
                            get: { app.filter == .disabled || (app.hidden && !app.hiddenNotifications) },
                            set: { model.setNotificationSuppressed(app, isSuppressed: $0) }
                        )
                    ) {
                        HStack(spacing: 6) {
                            Text(app.appName)
                            if app.hidden {
                                Text("Hidden app")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 320)
    }
}
