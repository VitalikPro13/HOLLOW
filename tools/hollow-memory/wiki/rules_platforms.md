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

## Rendering

- Windows + Linux run SKIA, not Impeller (`ImpellerSwitch::Disabled` /
  `fl_dart_project_set_enable_impeller`); `HollowShaderWarmUp` is gated to the same two,
  move both together. TEMPORARY. `project_desktop_skia_revert`.

## Windows

- Annotation mode: `window_manager` maximize/unmaximize only, never raw Win32 or
  `setFullScreen`. `feedback_annotation_window_management`.

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

## Android build

- SQLCipher links vendored static OpenSSL **3.5.8** per arch
  (`.cargo/android-openssl-headers/`, README inside; built on the Linux VM); the env vars
  must be SYSTEM env vars (Cargo `[env]` never reaches cargokit). **A failed cargokit
  Rust build does NOT fail `flutter build apk`: Gradle packages the STALE `.so`**;
  `build_release.ps1` scans the log for it. Rust TLS uses `webpki-roots`, NEVER
  `native-roots`. `feedback_android_platform`.

## Fonts

- Emoji font: NotoColorEmoji = an emoji-only subset (`scripts/subset_emoji_font.py`).
