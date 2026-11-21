# Architecture (v0.3)

```text
SwiftUI window
  ├─ LauncherModel: UI state and background work
  ├─ AndroidBridge: Process calls to local emulator and adb
  ├─ ProfileStore: ~/Library/Application Support/AdFreeAndroidLauncher/profiles.json
  ├─ Screenshot preview: adb exec-out screencap -p, in memory only
  ├─ Key input: opt-in local key monitor; optional macOS global key monitor
  └─ Macro runner: bounded click sequence, finite/infinite repeat, delay, cancellation
                       ↓
       adb emu event mouse (console transport)
                       ↓
       Virtual Linux multi-touch input device
                       ↓
             Selected ARM64 Android AVD
```

The launcher discovers `ANDROID_SDK_ROOT`, `ANDROID_HOME`, and `~/Library/Android/sdk`, then checks `PATH`. AVD names come from `emulator -list-avds`. Connected `emulator-*` serials are matched to AVD names via `adb -s SERIAL emu avd name`; boot completion comes from `sys.boot_completed`. All install, launch, display, tap, and shutdown commands target that serial.

Starting an AVD passes `-memory` and `-gpu auto`. After boot, display size uses `wm size` and the refresh target uses Android's `peak_refresh_rate` setting. The UI retains native dimensions and derives 100/75/50% presets from them to preserve aspect ratio; it can reset an override to the AVD's physical size. This target is not a game FPS cap or guarantee. Profiles contain a package name, optional local display name, one character to coordinate key mappings, and saved click macros. Existing JSON profiles without macros decode as an empty macro list. The opt-in key capture button enables a local key monitor without extra permissions. When the emulator window has focus, the optional global key monitor requires macOS Accessibility permission.

Key mappings and macros send mouse press/release through the emulator console's `event mouse` command, not Android's `input tap` shell command. The emulator maps Android screen pixel coordinates to its virtual touch device. The emulator translates these requests into guest touch events. Device-level behavior should be checked on the target AVD. At macro start, PlayDesk finds the selected AVD's macOS process by its `-avd` argument. In the normal mode it tries to activate that process and waits up to 30 seconds for the user to click its window if activation fails; it pauses taps when the emulator loses Mac focus. The per-macro background option skips only these focus checks, allowing the console to keep sending touches while another Mac app is active. The macro runner authenticates once to the selected emulator's loopback console with the user's local console token and keeps the connection open for the run. The token is never logged or saved by PlayDesk. The runner checks the Android foreground package at startup and on a separate half-second monitor, schedules tap starts at the configured interval, limits each sequence to 32 taps, and supports finite or unlimited repeats with cooperative stop. Older saved macros decode with unlimited repeats and background mode disabled. This creates virtual hardware events in the guest input device. It is not a physical USB device, and exact timing or game acceptance is not guaranteed.

The app does not embed the Android display. The official emulator opens its own window. An on-demand PNG screenshot supports point selection for key mapping. A Play Store button is enabled only when `com.android.vending` is present in the selected booted AVD. Downloads and any Google account sign-in occur entirely inside that emulator. scrcpy is detected for future integration only. There is no launcher advertising, telemetry, account, or backend.
