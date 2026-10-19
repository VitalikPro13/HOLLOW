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

## iOS on the real iPhone

- The iPhone 13 mini on the Mac mini's USB carries Vitalik's REAL TestFlight Hollow
  (`com.anonlisten.hollow`, his identity and data). Only the dev variant goes on it
  (`flutter run --flavor dev`, `com.anonlisten.hollow.dev`, own team, App Group and keychain
  group); never install, build to, launch or remove a `com.anonlisten.hollow` build there.
  Before a first install, read the ids from the built `.app` and both `.appex`
  (Info.plist + `codesign -d --entitlements`). Every iOS id comes from
  `ios/Flutter/Variant-{prod,dev}.xcconfig`; a new id goes there, never as a literal.
  BUILDING.md "iOS dev variant", `feedback_pixel8_debug_flutter_run_only`.

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
- cargokit's Gradle plugin adds the emulator ABIs (x86, x64) to a DEBUG build only when the
  build names no `--target-platform` (`plugin.gradle`); before session 44 it always did, so the
  fleet's arm64 APK ran three Rust builds (a cold mini build: 19:36 for both phone apps).

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

- Emoji font: NotoColorEmoji = an emoji-only subset (`scripts/subset_emoji_font.py`). Each OS shows its OWN emoji (#104): Windows 10 and 11 fallback = `['NotoColorEmojiFlags', 'Segoe UI Emoji', 'NotoColorEmoji']` (Segoe has no flag images, so a 64-codepoint Noto flags subset goes first; Noto fills gaps); Linux = Noto alone; macOS/phones = native. Noto is a CBDT bitmap (one 109 ppem strike) and looks jagged when Windows shrinks it; Noto COLRv1 draws BLANK in Flutter's Windows engine. Newer ZWJ emoji Segoe lacks draw as pieces (accepted); the picker cell scales them down to stay one line. Memory `project_emoji_font_native_per_os`.

## Debug builds: dependency optimization and the shared dev cache (session 43)

- Debug builds optimize every DEPENDENCY (`[profile.dev.package."*"]` opt-level 2,
  `debug = "line-tables-only"`): backtraces through deps keep file:line, a debugger shows no
  variables there. hollow_core itself stays opt-level 0 with full debuginfo; release is
  untouched.
- `scripts\flutter_win.ps1` DEBUG builds (`build windows --debug`, `run`, `test`; so also
  `fleet.ps1 -Build`) set `HOLLOW_CARGOKIT_SHARED_DIR` (default `D:\dev\cache\hollow-cargokit`,
  or under `HOLLOW_DEV_CACHE`) and, once seeded, `FIREBASE_CPP_SDK_DIR`
  (`D:\dev\cache\firebase_cpp_sdk_windows`). Release and profile builds REMOVE the variable,
  `build_release.ps1` clears it too, and cargokit ignores it for them (`SharedBuildOptions.from`).
  One debug tree on its own: `HOLLOW_CARGOKIT_SHARED_DIR=off`.
- cargokit `shared_build.dart` keys every shared build by CONTENT (`computeBuildKey`: path
  crates' files, lock, manifests, cargo configs on cargo's cwd path, toolchain, triple, flags,
  build variables). A key cargo did not build last resets the path crates' fingerprints first:
  cargo calls an OLDER tree fresh by mtime and would link another tree's code. A key built
  before is served from `dll\<key>` with NO cargo run. `build.lock` serializes cargo across
  trees, cached sets are immutable, readers hold `use.lock`, eviction keeps 3
  (`HOLLOW_CARGOKIT_SHARED_KEEP`, each set ~1.8 GB with the static lib and PDB).
- A NEW input to the Rust build outside a path crate's folder (a file `include_str!`'d from
  elsewhere in non-test code, a variable a `build.rs` reads that `_keyEnv` misses) must join
  `computeBuildKey`, or a cached DLL hides the change. Tests: `dart pub get --offline`, then
  `dart run test/shared_build_test.dart` in `rust_builder/cargokit/build_tool` (`dart test`
  cannot start on the pinned test package).
- Shared builds pin MSBuild's per-project `VSTEL_MSBuildProjectFullPath` to one value: the
  `cc` crate registers it as a build-script input, and a per-tree value rebuilt every C
  dependency (SQLCipher, ring, aws-lc, libwebp) on each switch of trees. A Rust edit that is
  slow only after ANOTHER tree built: `cargo build -v` names the variable
  ("Dirty <crate>: the env variable X changed"); pin it the same way.
- `fleet.ps1` Stage-Peer hashes the staged `hollow_core.dll` and `kernel_blob.bin` against the
  build output and throws on a mismatch (a cached DLL can carry an older timestamp).
- `scripts\dev_cache.ps1` shows the cache, `-Clear` drops the Rust part (refused while a build
  holds the lock), `-SeedFirebase [-From]` copies an extracted SDK in once, `-SeedWorktree
  <path>` gives a new worktree its gitignored configs and a warm nextest target with the
  path-crate fingerprints reset.

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
- Quick patches (0.12.2): the build rides `"build": N` on the version entry and `APP_BUILD`
  beside `APP_VERSION` (never pubspec's `+N`); `version` / `latest` stay three-part forever
  (0.12.1 refuses the whole manifest otherwise). Paths use `release_tag` (`0.12.2-b1`), people
  see `0.12.2+1`. New apps pick the newest (version, build) entry with a URL for THEIR
  platform and install kind (`VersionManifest.updateFor`), never `latest`; the full-platform
  entry stays FIRST (old apps and the website read the first; `hollow-manifest sign` refuses
  otherwise). A malformed `build`/`critical` skips its entry only, never the manifest.
  `status.json` and `news.json` are SIGNED (`fetch_signed_feed`, domain-separated from the
  manifest, size-capped while streaming); an unsigned feed shows nothing in 0.12.2+. Sign
  status ONLY via `scripts/sign_feeds.*` (stamp never below the live copy; over 1 h ahead is
  refused). Wiki `security_write_gates` §45.
