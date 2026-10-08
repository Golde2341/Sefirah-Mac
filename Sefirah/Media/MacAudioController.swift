import CoreAudio
import Foundation

/// Reads and controls the Mac's audio output devices so the phone's remote-playback UI can show
/// and change this Mac's volume, mute state and default output — the macOS counterpart of the
/// legacy desktop `AudioFeature`.
enum MacAudioController {
    struct Device: Equatable {
        var uid: String
        var name: String
        /// 0…1, matching the normalized value the phone sends in `AudioAction(VolumeUpdate)`.
        var volume: Double
        var isMuted: Bool
        var isDefault: Bool
    }

    /// All output-capable devices, the default one flagged.
    static func outputDevices() -> [Device] {
        let defaultID = defaultOutputDevice()
        return deviceIDs().compactMap { id in
            guard hasOutputChannels(id), let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let state = volumeState(id)
            return Device(
                uid: uid,
                name: stringProperty(id, kAudioObjectPropertyName) ?? uid,
                volume: state.volume,
                isMuted: state.muted,
                isDefault: id == defaultID
            )
        }
    }

    static var defaultOutputVolumePercent: Int {
        guard let id = defaultOutputDevice() else { return 0 }
        return Int((volumeState(id).volume * 100).rounded())
    }

    static func setVolume(uid: String?, to value: Double) {
        guard let id = resolve(uid) else { return }
        let clamped = Float(min(max(value, 0), 1))
        if !setScalarVolume(id, element: kAudioObjectPropertyElementMain, value: clamped) {
            _ = setScalarVolume(id, element: 1, value: clamped)
            _ = setScalarVolume(id, element: 2, value: clamped)
        }
        if clamped > 0 { setMute(id, muted: false) }
    }

    static func toggleMute(uid: String?) {
        guard let id = resolve(uid) else { return }
        setMute(id, muted: !muteState(id))
    }

    static func setDefaultOutput(uid: String) {
        guard let id = device(withUID: uid) else { return }
        var device = id
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        _ = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &device
        )
    }

    // MARK: - CoreAudio plumbing

    private static let outputScope = kAudioObjectPropertyScopeOutput

    private static func resolve(_ uid: String?) -> AudioDeviceID? {
        if let uid, let id = device(withUID: uid) { return id }
        return defaultOutputDevice()
    }

    private static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ) == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func device(withUID uid: String) -> AudioDeviceID? {
        deviceIDs().first { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    private static func hasOutputChannels(_ device: AudioDeviceID) -> Bool {
        var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: outputScope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = propertyAddress(selector)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func volumeState(_ device: AudioDeviceID) -> (volume: Double, muted: Bool) {
        var volume = scalarVolume(device, element: kAudioObjectPropertyElementMain)
        if volume == nil {
            let channels = [1, 2].compactMap { scalarVolume(device, element: AudioObjectPropertyElement($0)) }
            if !channels.isEmpty { volume = channels.reduce(0, +) / Double(channels.count) }
        }
        return (volume ?? 0, muteState(device))
    }

    private static func scalarVolume(_ device: AudioDeviceID, element: AudioObjectPropertyElement) -> Double? {
        var address = propertyAddress(kAudioDevicePropertyVolumeScalar, scope: outputScope, element: element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float(0)
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return Double(value)
    }

    @discardableResult
    private static func setScalarVolume(_ device: AudioDeviceID, element: AudioObjectPropertyElement, value: Float) -> Bool {
        var address = propertyAddress(kAudioDevicePropertyVolumeScalar, scope: outputScope, element: element)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        var value = value
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &value) == noErr
    }

    private static func muteState(_ device: AudioDeviceID) -> Bool {
        var address = propertyAddress(kAudioDevicePropertyMute, scope: outputScope)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private static func setMute(_ device: AudioDeviceID, muted: Bool) {
        var address = propertyAddress(kAudioDevicePropertyMute, scope: outputScope)
        guard AudioObjectHasProperty(device, &address) else { return }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return }
        var value: UInt32 = muted ? 1 : 0
        _ = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}
