import AppKit
import SefirahCore
import SwiftUI

@main
struct SefirahApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Sefirah", id: "main") {
            RootView(model: model)
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
                .onOpenURL { model.handleURL($0) }
                .onDisappear {
                    NSApp.setActivationPolicy(.accessory)
                }
                .background(MainWindowActionBridge(appDelegate: appDelegate))
        }
        .defaultSize(width: 980, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Mirror") {
                Button("Start Mirroring") { model.startMirror() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(model.selectedDevice == nil || !model.canMirror)
                Button("Stop All Mirrors") { model.stopAllMirrors() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Divider()
                Button(model.activeMirrorController?.isMuted == true ? "Unmute Audio" : "Mute Audio") {
                    model.activeMirrorController?.toggleMute()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(model.activeMirrorController == nil)
                Button("Rotate Device") { model.activeMirrorController?.send(.rotateDevice) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.activeMirrorController == nil)
                Button("Paste Mac Clipboard to Phone") { model.activeMirrorController?.pasteFromMac() }
                    .disabled(model.activeMirrorController == nil)
            }
        }

        Window("Incoming Call", id: "call") {
            CallOverlayView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)

        MenuBarExtra("Sefirah", systemImage: "iphone") {
            MenuBarView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Installed by the main window's content so the menu bar can reopen the window even after it
    /// has been closed (an `NSWindow` that still exists is simply ordered to the front).
    private var openMainWindowAction: (() -> Void)?
    private var rightClickMonitor: Any?
    /// True between a handled secondary click on the menu bar icon and its matching mouse-up.
    private var swallowingMenuBarRightClick = false

    func registerOpenMainWindowAction(_ action: @escaping () -> Void) {
        openMainWindowAction = action
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A secondary click on the menu bar icon opens the main window (the icon's primary click
        // keeps showing the menu bar panel). The MenuBarExtra status item delivers right-clicks to
        // this process, so a local monitor can claim them.
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .rightMouseUp]) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                return self.handleMenuBarRightClick(event)
            }
            return handled ? nil : event
        }
    }

    private func handleMenuBarRightClick(_ event: NSEvent) -> Bool {
        switch event.type {
        case .rightMouseDown:
            guard isInMenuBar else { return false }
            swallowingMenuBarRightClick = true
            showMainWindow()
            return true
        case .rightMouseUp:
            guard swallowingMenuBarRightClick else { return false }
            swallowingMenuBarRightClick = false
            return true
        default:
            return false
        }
    }

    private var isInMenuBar: Bool {
        let location = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else {
            return false
        }
        return location.y >= screen.frame.maxY - NSStatusBar.system.thickness
    }

    /// Brings the main window to the front, reopening it through SwiftUI's scene opener when the
    /// `NSWindow` was released by closing it.
    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindowAction?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Sefirah lives in the menu bar. Activation/reopen events — including tapping a
        // mirrored phone notification — must not reopen the main window. Returning false
        // suppresses AppKit's and SwiftUI's default window restoration; use the menu bar
        // item's Show Window (or a secondary click on its icon) instead.
        false
    }
}

/// Hands SwiftUI's scene opener to the AppKit delegate so menu bar interactions can reopen the
/// main window after it has been closed.
private struct MainWindowActionBridge: View {
    let appDelegate: AppDelegate

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .onAppear {
                appDelegate.registerOpenMainWindowAction { openWindow(id: "main") }
            }
    }
}
