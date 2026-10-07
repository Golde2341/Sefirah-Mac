import Foundation

public struct GeneralSettings: Codable, Sendable, Equatable {
    public var startupOption: StartupOptions
    public var theme: Theme
    public var scrcpyPath: String
    public var adbPath: String
    public var remoteStoragePath: String
    public var receivedFilesPath: String
    public var localDeviceName: String
    public var actions: [ActionItem]
    /// Device-qualified app keys, most recently launched first.
    public var recentlyOpenedAppKeys: [String]
    /// Native in-app mirror (default) or the bundled/external scrcpy binary.
    public var mirrorBackend: MirrorBackend
    /// Run scrcpy-server with `log_level=debug`.
    public var verboseMirrorLogs: Bool
    /// When the native mirror fails before streaming, open the external scrcpy window instead.
    public var mirrorFallbackToExternal: Bool
    /// Open the corresponding app when clicking a notification banner or item.
    public var openAppOnNotificationClick: Bool
    /// Restart the local adb server (`adb kill-server` + `start-server`) when Sefirah launches.
    public var restartAdbServerOnLaunch: Bool
    /// Continuously push the Mac clipboard to the phone as it changes.
    public var syncClipboardToPhone: Bool
    /// Menu bar panel: show the Open apps submenu.
    public var menuBarOpenApps: Bool
    /// Menu bar panel: show the Screen mirror button.
    public var menuBarScreenMirror: Bool
    /// Menu bar panel: show the Do Not Disturb button.
    public var menuBarDnd: Bool
    /// Menu bar panel: show the Ringer mode picker.
    public var menuBarRinger: Bool
    /// Menu bar panel: show the Send clipboard button.
    public var menuBarSendClipboard: Bool
    /// Menu bar panel: show the Find phone button.
    public var menuBarFindPhone: Bool

    public init(
        startupOption: StartupOptions = .inTray,
        theme: Theme = .default,
        scrcpyPath: String = "",
        adbPath: String = "",
        remoteStoragePath: String = SefirahConstants.defaultRemoteStorageDirectory.path,
        receivedFilesPath: String = SefirahConstants.defaultDownloadsDirectory.path,
        localDeviceName: String = "",
        actions: [ActionItem] = [],
        recentlyOpenedAppKeys: [String] = [],
        mirrorBackend: MirrorBackend = .native,
        verboseMirrorLogs: Bool = false,
        mirrorFallbackToExternal: Bool = false,
        openAppOnNotificationClick: Bool = true,
        restartAdbServerOnLaunch: Bool = false,
        syncClipboardToPhone: Bool = false,
        menuBarOpenApps: Bool = true,
        menuBarScreenMirror: Bool = true,
        menuBarDnd: Bool = true,
        menuBarRinger: Bool = true,
        menuBarSendClipboard: Bool = true,
        menuBarFindPhone: Bool = true
    ) {
        self.startupOption = startupOption
        self.theme = theme
        self.scrcpyPath = scrcpyPath
        self.adbPath = adbPath
        self.remoteStoragePath = remoteStoragePath
        self.receivedFilesPath = receivedFilesPath
        self.localDeviceName = localDeviceName
        self.actions = actions
        self.recentlyOpenedAppKeys = recentlyOpenedAppKeys
        self.mirrorBackend = mirrorBackend
        self.verboseMirrorLogs = verboseMirrorLogs
        self.mirrorFallbackToExternal = mirrorFallbackToExternal
        self.openAppOnNotificationClick = openAppOnNotificationClick
        self.restartAdbServerOnLaunch = restartAdbServerOnLaunch
        self.syncClipboardToPhone = syncClipboardToPhone
        self.menuBarOpenApps = menuBarOpenApps
        self.menuBarScreenMirror = menuBarScreenMirror
        self.menuBarDnd = menuBarDnd
        self.menuBarRinger = menuBarRinger
        self.menuBarSendClipboard = menuBarSendClipboard
        self.menuBarFindPhone = menuBarFindPhone
    }

    /// Tolerant decoding so `general.json` files written before a field existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GeneralSettings()
        startupOption = try c.decodeIfPresent(StartupOptions.self, forKey: .startupOption) ?? defaults.startupOption
        theme = try c.decodeIfPresent(Theme.self, forKey: .theme) ?? defaults.theme
        scrcpyPath = try c.decodeIfPresent(String.self, forKey: .scrcpyPath) ?? defaults.scrcpyPath
        adbPath = try c.decodeIfPresent(String.self, forKey: .adbPath) ?? defaults.adbPath
        remoteStoragePath = try c.decodeIfPresent(String.self, forKey: .remoteStoragePath) ?? defaults.remoteStoragePath
        receivedFilesPath = try c.decodeIfPresent(String.self, forKey: .receivedFilesPath) ?? defaults.receivedFilesPath
        localDeviceName = try c.decodeIfPresent(String.self, forKey: .localDeviceName) ?? defaults.localDeviceName
        actions = try c.decodeIfPresent([ActionItem].self, forKey: .actions) ?? defaults.actions
        recentlyOpenedAppKeys = try c.decodeIfPresent([String].self, forKey: .recentlyOpenedAppKeys) ?? defaults.recentlyOpenedAppKeys
        mirrorBackend = try c.decodeIfPresent(MirrorBackend.self, forKey: .mirrorBackend) ?? defaults.mirrorBackend
        verboseMirrorLogs = try c.decodeIfPresent(Bool.self, forKey: .verboseMirrorLogs) ?? defaults.verboseMirrorLogs
        mirrorFallbackToExternal = try c.decodeIfPresent(Bool.self, forKey: .mirrorFallbackToExternal) ?? defaults.mirrorFallbackToExternal
        openAppOnNotificationClick = try c.decodeIfPresent(Bool.self, forKey: .openAppOnNotificationClick) ?? defaults.openAppOnNotificationClick
        restartAdbServerOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .restartAdbServerOnLaunch) ?? defaults.restartAdbServerOnLaunch
        syncClipboardToPhone = try c.decodeIfPresent(Bool.self, forKey: .syncClipboardToPhone) ?? defaults.syncClipboardToPhone
        menuBarOpenApps = try c.decodeIfPresent(Bool.self, forKey: .menuBarOpenApps) ?? defaults.menuBarOpenApps
        menuBarScreenMirror = try c.decodeIfPresent(Bool.self, forKey: .menuBarScreenMirror) ?? defaults.menuBarScreenMirror
        menuBarDnd = try c.decodeIfPresent(Bool.self, forKey: .menuBarDnd) ?? defaults.menuBarDnd
        menuBarRinger = try c.decodeIfPresent(Bool.self, forKey: .menuBarRinger) ?? defaults.menuBarRinger
        menuBarSendClipboard = try c.decodeIfPresent(Bool.self, forKey: .menuBarSendClipboard) ?? defaults.menuBarSendClipboard
        menuBarFindPhone = try c.decodeIfPresent(Bool.self, forKey: .menuBarFindPhone) ?? defaults.menuBarFindPhone
    }
}

public enum MirrorBackend: String, Codable, Sendable, Equatable, CaseIterable {
    case native = "Native"
    case external = "External"
}
