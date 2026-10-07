import SefirahCore
import SwiftUI

/// Configurator for a device's unlock commands (port of the legacy Windows `UnlockSettingsPage`):
/// the enable toggle, an editable command list with per-command delays, reordering and a
/// PIN-lockscreen template. Every edit is saved immediately.
struct UnlockCommandsSettingsView: View {
    @Bindable var model: AppModel
    let deviceId: String
    @Environment(\.dismiss) private var dismiss

    private var commands: [UnlockCommandEntry] {
        model.deviceSettings(for: deviceId).unlockCommands
    }

    var body: some View {
        let _ = model.deviceSettingsRevision
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unlock commands").font(.title2.weight(.semibold))
                    Text(model.paired.first { $0.id == deviceId }?.name ?? "Device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Toggle("Run unlock commands before launching", isOn: binding(\.unlockDeviceBeforeLaunch))

            Text("Commands run in order over adb shell before the mirror connects. Add a delay (ms) after a command when the phone needs time to react. `%pwd%` prompts are not supported on macOS yet — type the PIN in the command instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Menu("Add template") {
                    Button("PIN lockscreen") { addPINTemplate() }
                }
                Button("Add command") { addCommand() }
                Spacer()
                Text("\(commands.count) command(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if commands.isEmpty {
                ContentUnavailableView(
                    "No unlock commands",
                    systemImage: "lock.open",
                    description: Text("Add a command, or use the PIN lockscreen template.")
                )
            } else {
                List {
                    ForEach(Array(commands.enumerated()), id: \.offset) { index, _ in
                        row(at: index)
                    }
                    .onMove { offsets, destination in
                        model.updateDeviceSettings(for: deviceId) { settings in
                            settings.unlockCommands.move(fromOffsets: offsets, toOffset: destination)
                        }
                    }
                }
                .listStyle(.inset)
                .frame(maxHeight: .infinity)
            }

            Text("The PIN template wakes the phone, swipes up to the PIN pad, enters 0000 and presses Enter — replace 0000 with your PIN.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .frame(minWidth: 560, minHeight: 480)
    }

    // MARK: - Rows

    private func row(at index: Int) -> some View {
        HStack(spacing: 8) {
            TextField("input keyevent 26", text: commandBinding(index))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            Text("Delay")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Pause after this command, in milliseconds")
            TextField("0", value: delayBinding(index), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
            Text("ms")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button { move(index, by: -1) } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(index == 0)
            .help("Move up")
            Button { move(index, by: 1) } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(index >= commands.count - 1)
            .help("Move down")
            Button(role: .destructive) { remove(index) } label: {
                Image(systemName: "trash")
            }
            .help("Remove command")
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Editing

    private func addCommand() {
        model.updateDeviceSettings(for: deviceId) { settings in
            settings.unlockCommands.append(UnlockCommandEntry(command: ""))
        }
    }

    /// Common recipe for a PIN-protected lockscreen: wake, reveal the PIN pad, type the PIN, Enter.
    private func addPINTemplate() {
        let template = [
            UnlockCommandEntry(command: "input keyevent 224", delayMs: 500),
            UnlockCommandEntry(command: "input swipe 540 1600 540 600 300", delayMs: 500),
            UnlockCommandEntry(command: "input text 0000", delayMs: 300),
            UnlockCommandEntry(command: "input keyevent 66", delayMs: 0),
        ]
        model.updateDeviceSettings(for: deviceId) { settings in
            settings.unlockCommands.append(contentsOf: template)
        }
    }

    private func remove(_ index: Int) {
        model.updateDeviceSettings(for: deviceId) { settings in
            guard settings.unlockCommands.indices.contains(index) else { return }
            settings.unlockCommands.remove(at: index)
        }
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        model.updateDeviceSettings(for: deviceId) { settings in
            guard settings.unlockCommands.indices.contains(index),
                  settings.unlockCommands.indices.contains(target) else { return }
            settings.unlockCommands.swapAt(index, target)
        }
    }

    // MARK: - Bindings

    private func commandBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { entry(at: index)?.command ?? "" },
            set: { value in
                model.updateDeviceSettings(for: deviceId) { settings in
                    guard settings.unlockCommands.indices.contains(index) else { return }
                    settings.unlockCommands[index].command = value
                }
            }
        )
    }

    private func delayBinding(_ index: Int) -> Binding<Int> {
        Binding(
            get: { entry(at: index)?.delayMs ?? 0 },
            set: { value in
                model.updateDeviceSettings(for: deviceId) { settings in
                    guard settings.unlockCommands.indices.contains(index) else { return }
                    settings.unlockCommands[index].delayMs = max(0, value)
                }
            }
        )
    }

    private func entry(at index: Int) -> UnlockCommandEntry? {
        let list = commands
        guard list.indices.contains(index) else { return nil }
        return list[index]
    }

    private func binding<T: Equatable>(_ keyPath: WritableKeyPath<DeviceSettings, T>) -> Binding<T> {
        Binding(
            get: { model.deviceSettings(for: deviceId)[keyPath: keyPath] },
            set: { value in
                guard model.deviceSettings(for: deviceId)[keyPath: keyPath] != value else { return }
                model.updateDeviceSettings(for: deviceId) { $0[keyPath: keyPath] = value }
            }
        )
    }
}
