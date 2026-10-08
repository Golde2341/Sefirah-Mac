# Sefirah for Mac

<p align="center">
  <img alt="Hero image" src="./.github/readme-images/Readme-Hero.png" />
</p>

<p align="center">
  <a style="text-decoration:none" href="https://crowdin.com/project/sefirah"><img src="https://badges.crowdin.net/sefirah/localized.svg" alt="Sefirah Desktop Localization Status" /></a>
  <a style="text-decoration:none" href="https://github.com/shrimqy/Sefirah-Android"><img src="https://img.shields.io/badge/android-repo-sefirah?logo=github" alt="Sefirah-Android" /></a>
  <a style="text-decoration:none" href="https://discord.gg/MuvMqv4MES"><img src="https://img.shields.io/discord/1310140719138340925?label=Discord&color=7289da" alt="Sefirah Discord" /></a>
</p>

**Sefirah** for macOS is a native **SwiftUI** companion for [Sefirah Android](https://github.com/shrimqy/Sefirah-Android): clipboard, notifications, media, files, SMS and screen mirroring between your Android phone and your Mac. It speaks the same TLS + NDJSON protocol as the Windows/Linux desktop app, so an already-paired phone needs no Android-side changes.

The original C#/Uno Windows & Linux sources live in [`legacy/`](legacy/) as a protocol reference.

## Features

- **Pairing**: LAN discovery (Bonjour/UDP), QR pairing (`sefirah://pair`), mutual TLS with pinned certificates and a verification code you confirm on both devices.
- **Clipboard sharing**: real-time Mac → phone sync, automatic phone → Mac application (text, images and files).
- **Notifications**: mirror Android notifications to the Mac — per-app enable/disable, reply and action buttons, tap to open the matching app and mirror it on the Mac,
- **Media**: control the phone's playback from the Mac. A glass mini-player in the menu bar.
- **Files**: receive files sent from the phone's share sheet into a folder you choose, and open the phone's storage in Finder over SFTP.
- **SMS**: view conversations, read and send texts from the Messages tab.
- **Calls**: call log and an incoming-call overlay with caller details.
- **Apps**: the phone's launcher apps. Hidden apps are kept behind Touch ID / login-password authentication.
- **Screen mirroring**: mirror your screen using scrcpy.
- **Device controls**: ringer mode, per-stream volume, Do Not Disturb, find phone, battery status, wake/power actions, and custom Link / Power / Run actions that sync to the phone.
- **Menu bar**: tray-first app, configurable feature buttons, media player, reconnect, and quick status.
- **Connectivity helpers**: ADB auto-connect over Wi-Fi, waking the companion app in the background when you hit Connect, and optional auto-connect that wakes the phone over ADB twice (5 s apart) when it drops.

## Installation

### macOS app

Download the latest zip from [Releases](https://github.com/Golde2341/Sefirah-Mac/releases), unzip it and drag **Sefirah.app** to `/Applications`.

> The current builds are not yet Developer ID signed/notarized, so macOS will warn on first launch:
> try to open the app, then go to **System Settings → Privacy & Security → Open Anyway** (macOS 15+),
> or right-click → **Open** on older versions, or run `xattr -dr com.apple.quarantine /Applications/Sefirah.app`.
> Signing/notarization is planned; until then this step is normal.

Sefirah lives in the menu bar. On first launch it walks you through pairing.

### Android app

[<img alt="Get it on Google Play" height="80" src="https://play.google.com/intl/en_us/badges/images/generic/en_badge_web_generic.png">](https://play.google.com/store/apps/details?id=com.castle.sefirah)
[<img alt="Get it on IzzyOnDroid" height="80" src="https://gitlab.com/IzzyOnDroid/repo/-/raw/master/assets/IzzyOnDroid.png">](https://apt.izzysoft.de/fdroid/index/apk/com.castle.sefirah)

## Getting started

1. **Set up the Android app**: allow the necessary permissions on its onboarding page. (**Note:** allow restricted settings from *App Info* after attempting to grant notification access or accessibility permission — Android blocks side-loaded apps from requesting sensitive permissions.)
2. **Same network**: connect your phone and Mac to the same Wi-Fi network.
3. **Pair**:
   - Scan the QR code shown by the Mac from the Android app, or use manual/auto connect on the phone.
   - The Mac shows a pairing dialog — check that the verification codes match on both devices and accept.
   - Allow notifications when macOS asks about **“Sefirah Phone”** — that's the helper that posts your mirrored notifications.
4. **Firewall**: if the devices can't connect even though they discover each other, open these ports on your Mac: **5149** (UDP discovery) and **5150–5169** (TLS control + file transfer).
5. **Single time adb pairing**: enable usb and wireles debugging in your phone via developer options, then enable `Connect over Wi-Fi (ADB TCP/IP)` in settings, then mirror your screen, this will automatically pair your device so wireless debugging doesn't disconnect.
> [!TIP]
> If your android device's wireless debuging server goes offline when you turn it off, try setting `No data transfer` or `Charge only` as default USB configuration in developer settings

## How to use

### Clipboard

- Copy on the Mac and it syncs to the phone when *Sync Mac clipboard to phone in real time* is enabled (General settings) — text, images and files.
- Phone → Mac clipboard applies automatically; images can be placed on the Mac clipboard.
- Use the **Clipboard** button in the device rail or the menu bar to push the current clipboard on demand.

### Notifications

- Mirrored notifications appear in the device rail and as macOS banners.
- Enable/disable per app under **Settings → Notifications → Configure Apps…**, and choose whether to open the corresponding app on the phone when you click a notification.
- “Show app icons in notifications” controls the artwork on the banner; “Clear All” in the rail clears the current feed.
- **Reply** and notification **actions** can be used directly from the rail and the banner.

### Media

- The phone's current sessions appear in the device rail with artwork, metadata and a seek bar; the active phone output (speakers / Bluetooth / headphones) is shown on the card.
- Controls: previous / play-pause / next, seek, and per-session volume.
- The menu bar mini-player can be toggled under **Settings → Menu bar → Media player**.

### Files & storage

- Send a file from Android's share sheet and pick Sefirah — the file is saved to the folder set in **Settings → General → Received files**.
- **Files** in the device rail opens the phone's storage in Finder over `sftp://`.

### SMS & calls

- Grant the SMS permissions in the Android app, reconnect, and the **Messages** tab fills with your threads — read and send texts.
- Incoming calls show an overlay with the caller's name/number; the **Calls** tab keeps the call log.

### Apps

- The **Apps** tab lists the phone's launcher apps: switch between list, grid and double grid in the header.
- **Click** an app to launch it (it opens in the Mirror tab, or in the scrcpy window with the external backend).
- **Right-click** to pin (pinned apps sort first) or hide.
- Hidden apps live in the lock strip at the bottom — click *Reveal* and authenticate with Touch ID or your login password.

### Screen mirroring

- Sefirah bundles [scrcpy](https://github.com/Genymobile/scrcpy) (`scrcpy`, `adb`, `scrcpy-server`), so **Mirror** works with no extra setup: connect the phone over USB with USB debugging enabled, or use Wi-Fi ADB.
- **Backend**: the default **native** backend renders in the app's *Mirror* tab (VideoToolbox decode, AVAudioEngine audio, forwarded mouse/keyboard). The **external** backend opens the classic scrcpy window (with Sefirah's icon and label).
- **App launches (virtual display)**: apps open on a virtual display (`new_display` + `START_APP`), optionally resizing with the window; per-app **unlock commands** (a PIN template is included) run before launch.
- **Screen off**: turn the phone screen off while mirroring, and choose separately whether launching an *app* also turns it off — so you can keep the phone screen on for app mirroring while whole-screen mirroring blanks it.
- Toolbar: Back / Home / Recents / Rotate / Screen off / Notifications / Mute / Volume / Power / Fullscreen. The *Mirror* menu adds ⌘⇧M start, ⌘⇧. stop, ⌘⇧U mute, ⌘⇧R rotate.
- Per-device settings (Settings → Screen mirroring): Wi-Fi ADB, screen off, UHID keyboard, clipboard autosync, hover forwarding, video (codec, max size, bit rate, fps, crop, display id, rotation), audio (Mac / Mac+phone / phone only, Opus/AAC/raw, bit rate, buffer, microphone), virtual display, and custom `key=value` server options. Advanced options take custom scrcpy/adb paths and can restart the ADB server on launch.
- A lost connection is retried once automatically (re-running `adb connect` for Wi-Fi devices). With **Auto-connect when the phone disconnects** enabled, Sefirah also wakes the companion app over ADB — twice, 5 seconds apart — and skips the retry when ADB reports the device offline.

Some phones (Xiaomi/HyperOS) silently drop injected touches until *USB debugging (Security settings)* is enabled; the mirror still works read-only and the toolbar keys keep working.

## Limitations

- **Sensitive notifications** (Android 15+) are hidden by the OS. Grant the permission over ADB:

  ```sh
  adb shell appops set com.castle.sefirah RECEIVE_SENSITIVE_NOTIFICATIONS allow
  ```

  On some devices (e.g. OnePlus) this may fail until you disable **system optimization** or **Disable permission monitoring** for apps in **Developer options → Apps**, then run the command again.
- **Android storage** opens via `sftp://` in Finder — there is no Finder/File Provider integration like the Windows Explorer extension.
- **Bluetooth calling** (the Windows hands-free feature) is not implemented on macOS.
- **Sending files from the Mac to the phone** is not implemented yet; clipboard (text/images/files) and SFTP browsing are the current paths.
- The macOS app is **not notarized yet** — see the installation note above.

## Ports

Open **5149–5169** on the Mac firewall (UDP **5149** for discovery, TLS **5150–5169** for the control channel, **5152–5169** for file transfer).

## Build

Requires Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), macOS 14+.

```sh
scripts/fetch-scrcpy.sh   # vendors scrcpy/adb/scrcpy-server (pinned in scripts/scrcpy.lock)
xcodegen generate
xcodebuild -scheme Sefirah -destination 'platform=macOS' test
```

Open `Sefirah.xcodeproj` after generating. `xcodegen generate` fails if `Vendor/scrcpy/` has not been
populated, and a pre-build script fails the build if the vendored version drifts from the lock file.

> **Contributors:** the checked-in project carries manual wiring that XcodeGen can't model (the
> Icon Composer bundles `Sefirah.icon` / `SefirahPhone.icon` and the full-bleed legacy icon script).
> If you regenerate the project, re-apply the patches noted in `project.yml` or the app icons will
> be missing.
Design notes for the native mirror: [`docs/design/native-mirror.md`](docs/design/native-mirror.md).

Release flow: archive → `xcodebuild -exportArchive -exportOptionsPlist scripts/ExportOptions.plist` →
`scripts/verify-bundle.sh build/export/Sefirah.app` → `notarytool submit` → `stapler staple`.

Local (unsigned/ad-hoc) builds must be packaged with `ENABLE_HARDENED_RUNTIME=NO`: with no Developer ID
identity the app is ad-hoc signed, and hardened runtime's library validation refuses to load the
equally ad-hoc `SefirahCore.framework` ("different Team IDs"). Keep hardened runtime on for the
Developer ID + notarized release — it is required there.

## Protocol notes

- UDP discovery `:5149`, TLS control channel `:5150–5169`
- Mutual TLS, ECDSA P-256, verification code = SHA-256 of sorted SPKIs (first 8 hex chars)
- QR pairing URL scheme: `sefirah://pair?data=...`

Upstream Windows/Linux documentation: [`legacy/README.md`](legacy/README.md). Android app: [Sefirah-Android](https://github.com/shrimqy/Sefirah-Android).

## Support

Feel free to open an issue if you want to report a bug, provide feedback, or ask a question.

If you have any specific questions or need further details, please reach out on [the Discord server](https://discord.gg/MuvMqv4MES) or by email — I would be happy to help.

## Thanks

I would like to express my thanks to [@PrimalZed](https://github.com/PrimalZed) for his work on [CloudSync](https://github.com/PrimalZed/CloudSync) and
to [@rom1v](https://github.com/rom1v) for developing [Scrcpy](https://github.com/Genymobile/scrcpy). Without them Android storage and Screen mirroring features wouldn't be possible.
