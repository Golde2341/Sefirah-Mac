import AppKit
import SefirahCore
import SwiftUI

/// Shared horizontal-swipe state: which card is being swiped, by how much, and whether the current
/// trackpad gesture has locked to the horizontal axis (so it stops scrolling the list).
@Observable
private final class NotificationSwipeState {
    var key: String?
    var offset: CGFloat = 0
    var isLocked = false
}

struct NotificationFeedView: View {
    @Bindable var model: AppModel
    @State private var replyText = ""
    @State private var hoveredKey: String?
    @State private var swipe = NotificationSwipeState()
    @State private var swipeMonitor: Any?

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
                        NotificationCard(
                            note: note,
                            model: model,
                            replyText: $replyText,
                            swipe: swipe,
                            onHover: { hovering in
                                if hovering {
                                    hoveredKey = note.key
                                } else if hoveredKey == note.key {
                                    hoveredKey = nil
                                }
                            },
                            onSwipeChanged: { delta in
                                swipe.key = note.key
                                swipe.offset = max(-500, min(80, delta))
                            },
                            onSwipeEnded: settleSwipe
                        )
                        // The card is already slid away when deleted — collapse the row without
                        // fading it a second time. New arrivals still fade in.
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                    }
                }
            }
        }
        .onAppear(perform: installSwipeMonitor)
        .onDisappear(perform: removeSwipeMonitor)
    }

    /// Completes or cancels the swipe: past the threshold the card flies out and is deleted, and
    /// the remaining cards slide up (the model animates the list change).
    private func settleSwipe() {
        swipe.isLocked = false
        guard let key = swipe.key, let note = model.notifications.first(where: { $0.key == key }) else {
            swipe.key = nil
            swipe.offset = 0
            return
        }
        if swipe.offset < -60 {
            // The card is already off to the left, so delete right away: the list closes the gap
            // immediately and rapid swipes stay quick.
            model.deleteNotification(note)
            if hoveredKey == key { hoveredKey = nil }
            DispatchQueue.main.async {
                if swipe.key == key {
                    swipe.key = nil
                    swipe.offset = 0
                }
            }
        } else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { swipe.offset = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if swipe.key == key, swipe.offset == 0 { swipe.key = nil }
            }
        }
    }

    /// A two-finger trackpad swipe arrives as a horizontal scroll gesture, not a mouse drag. Watch
    /// scroll events for the hovered card, drive the same slide-out state, and — once the gesture
    /// is clearly sideways — consume it so the list can't scroll vertically mid-swipe.
    private func installSwipeMonitor() {
        guard swipeMonitor == nil else { return }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let deltaX = event.scrollingDeltaX
            let deltaY = event.scrollingDeltaY
            // scrollingDelta respects the "natural scrolling" preference; compensate so the card
            // always follows the physical finger direction (positive = fingers moving right).
            let fingerDeltaX = event.isDirectionInvertedFromDevice ? deltaX : -deltaX
            let phase = event.phase
            let isMomentum = event.momentumPhase != []
            let handled = MainActor.assumeIsolated { () -> Bool in
                if swipe.isLocked {
                    if phase == .ended || phase == .cancelled || phase == .none {
                        // Momentum after the release must not start a fresh swipe.
                        settleSwipe()
                    } else if !isMomentum, swipe.key != nil {
                        // Follow the fingers both ways: sliding back cancels the swipe.
                        swipe.offset = max(-500, min(80, swipe.offset + fingerDeltaX))
                    }
                    return true
                }
                guard !isMomentum, phase != .ended, phase != .cancelled else { return false }
                if let hovered = hoveredKey, !model.notifications.contains(where: { $0.key == hovered }) {
                    hoveredKey = nil
                }
                guard let key = hoveredKey, abs(deltaX) > abs(deltaY), abs(deltaX) > 0.5 else { return false }
                swipe.key = key
                swipe.isLocked = true
                swipe.offset = max(-500, min(80, fingerDeltaX))
                return true
            }
            return handled ? nil : event
        }
    }

    private func removeSwipeMonitor() {
        if let swipeMonitor {
            NSEvent.removeMonitor(swipeMonitor)
        }
        swipeMonitor = nil
    }
}

/// One mirrored notification. Clicking it opens the notification on the phone; sliding left with
/// the mouse or a two-finger swipe deletes it from the feed.
private struct NotificationCard: View {
    let note: NotificationSnapshot
    @Bindable var model: AppModel
    @Binding var replyText: String
    let swipe: NotificationSwipeState
    let onHover: (Bool) -> Void
    let onSwipeChanged: (CGFloat) -> Void
    let onSwipeEnded: () -> Void
    @State private var isHovering = false

    private var offset: CGFloat {
        swipe.key == note.key ? swipe.offset : 0
    }

    var body: some View {
        card
            .overlay(alignment: .topTrailing) {
                Button {
                    model.deleteNotification(note)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .padding(6)
                .opacity(isHovering ? 1 : 0)
                .animation(.easeInOut(duration: 0.12), value: isHovering)
                .help("Remove notification")
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // Offset last so the hover ✕ rides along with the card instead of floating in place.
            .offset(x: offset)
            .onHover { hovering in
                isHovering = hovering
                onHover(hovering)
            }
            .highPriorityGesture(swipeToDelete)
    }

    private var card: some View {
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
                Text(note.appName).font(.caption).foregroundStyle(.secondary)
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

            Spacer(minLength: 0)
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

    private var swipeToDelete: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                onSwipeChanged(value.translation.width)
            }
            .onEnded { _ in
                onSwipeEnded()
            }
    }
}
