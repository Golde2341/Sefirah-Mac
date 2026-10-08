import SefirahCore
import SwiftUI

struct NotificationFeedView: View {
    @Bindable var model: AppModel
    @State private var replyText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notifications").font(.headline)
                Spacer()
                if !model.notifications.isEmpty {
                    Button("Clear All") { model.clearAllNotifications() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Clear the mirrored notification feed")
                }
            }
            if model.notifications.isEmpty {
                Text("No notifications").foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.notifications) { note in
                        notificationCard(note)
                    }
                }
            }
        }
    }

    private func notificationCard(_ note: NotificationSnapshot) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Same artwork as the notification banner: contact photo badged with the app icon,
            // or the app icon's iOS squircle.
            if let image = IconImageCache.image(for: note.icon, key: note.key) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(note.appName).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.general.openAppOnNotificationClick, !note.appPackage.isEmpty {
                        Button("Open App") {
                            model.openNotification(note)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
                Text(note.title ?? "").font(.headline)
                Text(note.text ?? "").foregroundStyle(.secondary)
                HStack {
                    if note.replyResultKey != nil {
                        TextField("Reply", text: $replyText)
                        Button("Send") {
                            model.replyToNotification(note, text: replyText)
                            replyText = ""
                        }
                    }
                    ForEach(note.actions, id: \.actionIndex) { action in
                        Button(action.label ?? "Action") {
                            model.invokeNotification(note, action: action)
                        }
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            if model.general.openAppOnNotificationClick, !note.appPackage.isEmpty {
                model.openNotification(note)
            }
        }
    }
}
