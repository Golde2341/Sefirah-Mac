import Foundation

public enum ScrcpyArguments {
    public static func build(
        settings: DeviceSettings,
        serial: String?,
        package: String? = nil,
        appName: String? = nil
    ) -> [String] {
        var args: [String] = []
        if let package, !package.isEmpty {
            args.append("--start-app=\(package)")
            if let appName, !appName.isEmpty {
                args.append("--window-title=\(appName)")
            }
        }
        if let custom = nonempty(settings.customArguments) {
            args.append(contentsOf: splitArguments(custom))
        }
        if let serial, !serial.isEmpty {
            args.append("-s")
            args.append(serial)
        }
        // App launches can keep the phone screen on independently of full-screen mirroring.
        if settings.screenOff, package == nil || settings.screenOffOnAppLaunch {
            args.append("--turn-screen-off")
        }
        if settings.physicalKeyboard { args.append("--keyboard=uhid") }
        if !settings.scrcpyClipboardAutosync { args.append("--no-clipboard-autosync") }
        if settings.disableVideoForwarding { args.append("--no-video") }
        if let resolution = nonempty(settings.videoResolution) {
            args.append("--max-size=\(resolution)")
        }
        let bitrate = (package != nil && settings.flexDisplay) ? "16M" : settings.videoBitrate
        if let bitrate = nonempty(bitrate) {
            args.append("--video-bit-rate=\(bitrate)")
        }
        switch settings.videoCodec {
        case 1: args.append("--video-codec=h265")
        case 2: args.append("--video-codec=av1")
        default: break
        }
        switch settings.audioCodec {
        case 1: args.append("--audio-codec=aac")
        case 2: args.append("--audio-codec=raw")
        default: break
        }
        if settings.videoBuffer > 0 { args.append("--video-buffer=\(settings.videoBuffer)") }
        if settings.frameRate > 0 { args.append("--max-fps=\(settings.frameRate)") }
        if let crop = nonempty(settings.crop) { args.append("--crop=\(crop)") }
        if let display = nonempty(settings.display) { args.append("--display-id=\(display)") }
        if let audioBitrate = nonempty(settings.audioBitrate) {
            args.append("--audio-bit-rate=\(audioBitrate)")
        }
        if settings.audioBuffer > 0 { args.append("--audio-buffer=\(settings.audioBuffer)") }
        if settings.audioOutputBuffer > 0 {
            args.append("--audio-output-buffer=\(settings.audioOutputBuffer)")
        }
        if settings.forwardMicrophone { args.append("--audio-source=mic") }
        switch settings.audioOutputMode {
        case .remote: args.append("--no-audio")
        case .both: args.append("--audio-dup")
        case .desktop: break
        }
        if package != nil, settings.isVirtualDisplayEnabled {
            if let size = nonempty(settings.virtualDisplaySize) {
                args.append("--new-display=\(size)")
            } else {
                args.append("--new-display")
            }
            if settings.flexDisplay {
                args.append("-x")
                args.append("--keep-active")
            }
        }
        return args
    }

    /// Dedicated phone→Mac audio forwarding ("play phone audio on this Mac").
    public static let audioOnlyBitRate = "320K"
    /// 500 ms jitter buffer: decoupled from video, it trades latency for glitch-free playback so a
    /// concurrently running screen mirror never stutters because of audio underruns.
    public static let audioOnlyBufferMs = 500

    /// Arguments for an audio-only scrcpy session: no video and no window, Mac playback only.
    /// The default `--audio-source=output` forwards the whole audio output and mutes the phone.
    public static func buildAudioOnly(settings: DeviceSettings, serial: String?) -> [String] {
        var args: [String] = []
        if let custom = nonempty(settings.customArguments) {
            args.append(contentsOf: splitArguments(custom))
        }
        if let serial, !serial.isEmpty {
            args.append(contentsOf: ["-s", serial])
        }
        args.append("--no-video")
        args.append("--no-window")
        args.append("--audio-bit-rate=\(audioOnlyBitRate)")
        args.append("--audio-buffer=\(audioOnlyBufferMs)")
        switch settings.audioCodec {
        case 1: args.append("--audio-codec=aac")
        case 2: args.append("--audio-codec=raw")
        default: break
        }
        if settings.audioOutputBuffer > 0 {
            args.append("--audio-output-buffer=\(settings.audioOutputBuffer)")
        }
        return args
    }

    private static func nonempty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func splitArguments(_ line: String) -> [String] {
        line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}
