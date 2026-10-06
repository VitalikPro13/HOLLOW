# Area rules: desktop platforms, Android build, packaging

Moved out of CLAUDE.md on 2026-09-29, when the file was split by area. CLAUDE.md sends
every session here BEFORE it touches a platform runner (`windows/`, `linux/`, `macos/`,
`android/`), the flatpak, the updater, process lifecycle (restart, single instance) or
the rendering backend. Linux call and audio rules are in `rules_media_calls.md`; the
release pipeline is the `release` skill.

## Process lifecycle (all desktops)

- Self-restart ONLY via `relaunchApp()` (a Rust waiter; anything Dart spawns dies before
  Flutter is up). `project_profile_switcher_issue47`.
- The single-instance guard = `SingleInstanceLock` (a KERNEL file lock, never a bare pid
  file): in a flatpak EVERY launch is pid 2, so a stale pid file = a silent exit (#69).
  `feedback_flatpak_pid_namespace_instance_lock`.
- Relay triggers (resumable sessions): native code ONLY forwards `network` / `wake` on the
  `hollow/relay_triggers` channel; `lib/src/core/services/relay_triggers.dart` decides
  (coalescing, focus gap, phones in the background drop `network`) and calls `relay_nudge`.
  A new listener keeps that split; `test/relay_triggers_native_test.dart` pins the channel
  name in every runner, the two Swift copies identical and the build entries.
  `RESUMABLE_SESSIONS_PLAN.md` 3.7, 9.6.

## Rendering

- Windows + Linux run SKIA, not Impeller (`ImpellerSwitch::Disabled` /
  `fl_dart_project_set_enable_impeller`); `HollowShaderWarmUp` is gated to the same two,
  move both together. TEMPORARY. `project_desktop_skia_revert`.

## Windows

- Annotation mode: `window_manager` maximize/unmaximize only, never raw Win32 or
  `setFullScreen`. `feedback_annotation_window_management`.
- Wake = `WM_POWERBROADCAST` with `PBT_APMRESUMEAUTOMATIC` only (the user-input resume that
  follows would nudge twice). `NotifyIpInterfaceChange` fires without a real change (at start,
  under heavy build load; VirtualBox and Tailscale adapters), so the runner keeps at most ONE
  queued network message; each extra costs one heartbeat at most.

## Linux

- Updates branch on ONE detector `linux_install_kind()`: tarball = `update.sh` dir swap
  (`tar`, NEVER the `zip` crate), flatpak = the hash-verified bundle installed on the
  HOST via `flatpak-spawn`, and EVERY relaunch host-side (anything inside the sandbox dies
  with the app). `project_linux_auto_update`.
- Window close = minimize to the taskbar, never the tray; a 2nd close when minimized =
  quit. wlroots has NO minimize: poll, arm a 2nd-press quit, never on `isMinimized()`
  false alone. `project_linux_window_fix`.
- Window transparency: set the RGBA visual at window CREATION in `my_application.cc`
  (before realize, guarded on `is_composited`) + FlView bg `#00000000`; an X11 visual
  can't swap at runtime. `feedback_linux_window_transparency_annotate`.
- Flatpak: `flatpak/` + `build-flatpak.sh`; requires `--socket=x11` (NOT
  `fallback-x11`), `--socket=session-bus` + `--own-name` (else it never launches, #59),
  and a bundled libsecret. `feedback_flatpak_libsecret_and_vm_no_gui`.
- Wake inside the flatpak needs `--system-talk-name=org.freedesktop.login1` (logind's
  `PrepareForSleep(false)`), accepted only from the bus owner of `org.freedesktop.login1`.
  Network change = `GNetworkMonitor` (sees a new default route while NetworkManager still
  says connected, works without NM, goes through the portal), not NM `StateChanged`.

## Android build

- SQLCipher links vendored static OpenSSL **3.5.8** per arch
  (`.cargo/android-openssl-headers/`, README inside; built on the Linux VM); the env vars
  must be SYSTEM env vars (Cargo `[env]` never reaches cargokit). **A failed cargokit
  Rust build does NOT fail `flutter build apk`: Gradle packages the STALE `.so`**;
  `build_release.ps1` scans the log for it. Rust TLS uses `webpki-roots`, NEVER
  `native-roots`. `feedback_android_platform`.

## App icons

- One source: `assets/branding/hollow_mark.svg`. `scripts/make_app_icons.py` renders every
  platform's icon from it (Windows ICO and its runner copy, macOS on the 824/1024 tile, iOS
  full bleed with no alpha, web, installer, `hollow_logo_rounded.png`, Android sources); then
  `dart run flutter_launcher_icons`, then `scripts/make_tray_unread_icon.py`. 32 and 16 px are
  hand-drawn pixel grids in the script, keyhole included at the vector's proportion.
- `HollowMark` (`components/hollow_mark.dart`: the dock's Home tile, the About logo) draws the
  same path in Dart. Change the mark and change it too, or the dock keeps the old logo.
  `project_logo_refresh_2026_10`.

## Fonts

- Emoji font: NotoColorEmoji = an emoji-only subset (`scripts/subset_emoji_font.py`).

## Tests and logs (session 34)

- Rust test temp dirs ONLY via `crate::test_tmp::tempdir()` / `TestDir` (root
  `HOLLOW_TEST_TMP`, else `%TEMP%/hollow-tests`; leftovers named `hollow-test-*` are swept
  after 3 h); a source scan refuses any new `tempfile::`. A dropped harness `TestNode` aborts
  its loop (`AbortOnDrop`). On this box `HOLLOW_TEST_TMP=D:\dev\tmp\hollow-tests`.
- Release builds keep stderr quiet (`mirror_to_stderr`: debug builds and the forwarder only):
  the systemd journal would keep a copy no wipe reaches. The log file exists only while an
  identity does and is erased by the wipe. HOL-SEC-156.
- The updater accepts a manifest version only as three numeric parts (`is_release_version`),
  and Windows script paths go through `bat_quoted_path`. HOL-SEC-147.
