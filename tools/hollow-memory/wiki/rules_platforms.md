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

## Process secrets and stacks (0.14)

- Every process entry (app init, node start, push fetch, the iOS extension, the forwarder)
  calls `crash_dumps::keep_secrets_out` (RLIMIT_CORE 0 on Unix, heap out of Windows Error
  Reporting dumps). Never `PR_SET_DUMPABLE=0` on Linux: xdg-desktop-portal and PipeWire
  identify a flatpak client through /proc/PID/root, and the flatpak loses them (HOL-SEC-200).
- Windows debug builds: tokio workers have a 2048 KiB stack and a debug poll frame keeps
  every future built in it (`Box::pin(f(..))` still builds `f` in the caller). A new swarm
  loop or request arm builds its future in a short non-async helper returning `BoxedStep`,
  runs store calls via `off_worker_stack`, and gets a Windows debug harness run on the PC;
  `0xc00000fd` = stack, not logic (74dae4d6, wiki `rust_swarm_event_loop`).

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
- `flutter_local_notifications_windows` is a VENDORED fork (`packages/`, `dependency_overrides`): every FFI
  entry point catches everything, because a WinRT throw (WPN_E_PLATFORM_UNAVAILABLE when the notification
  platform is down, or in an ssh logon session) crosses the Dart FFI boundary and terminates the app.
  `test/windows_toast_plugin_guard_test.dart` guards it; an upstream bump must re-apply the catches.
- `audioplayers_windows` is vendored the same way (`packages/audioplayers_windows`, 4.3.0): both
  method-channel handlers catch everything (a C++ throw through the embedder's C callback ends the
  process), and `RunSyncInMTA` rethrows a work item's failure on the caller, because the throw
  skipped `SetEvent` and left the platform thread waiting forever (a frozen window when Media
  Foundation fails). `local_auth_windows` awaits Windows Hello outside any try in a
  `fire_and_forget` coroutine (a WinRT failure = terminate), so App Lock calls it on phones only;
  a desktop biometric feature must fork it first. Both guarded by
  `test/windows_audio_plugin_guard_test.dart`.
- `std::time::Instant` counts from boot (Windows, macOS, Linux): `now.checked_sub(d)` fails on a
  machine up for less than `d`, and no instant that far back exists. A mark meaning "due now"
  is `node::types::Since::LongAgo` (elapsed = `Duration::MAX`), never an instant in the past;
  `earlier_by` (as far back as the clock reaches) only where a later start is harmless, e.g.
  test agers (wiki `rust_test_harness`, t15, t18). Tests pretend a fresh boot with
  `types::booted_moments_ago`.
- Known, not fixed: the vendored `setSourceUrl`/`setSourceBytes` threads hold a raw `AudioPlayer*`,
  so a dispose landing mid-set is a use-after-free (mostly unreachable: `SoundService` awaits play).

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
- Desktop ids: the tarball is `com.anonlisten.hollow` (CMake APPLICATION_ID, its `.desktop`,
  the GApplication id, the prgname = WM_CLASS instance), the flatpak `com.anonlisten.Hollow`
  (app id, exported `.desktop` and icon); both `.desktop` files carry
  `StartupWMClass=com.anonlisten.hollow`. Toasts name the running one (`FLATPAK_ID`), and the
  WM_CLASS class is `Hollow` (what GNOME shows for a window it cannot match). Renaming any of
  these breaks dock grouping or the notification header silently; `test/linux_notifier_test.dart`
  pins them.
- Wake inside the flatpak needs `--system-talk-name=org.freedesktop.login1` (logind's
  `PrepareForSleep(false)`), accepted only from the bus owner of `org.freedesktop.login1`.
  Network change = `GNetworkMonitor` (sees a new default route while NetworkManager still
  says connected, works without NM, goes through the portal), not NM `StateChanged`.

## macOS release signing

- The shipped app loads code only from its own bundle and the OS (HOL-SEC-187): the release
  script runs `scripts/macos_load_gate.sh strip` + `check` BEFORE signing (prebuilt pods
  such as mdk carry `/opt/homebrew/lib`, `/usr/local/lib` and CI-home rpaths beside weak
  loads we never ship), the build stage gates a copy the same way, and `signed` runs after
  signing (every Mach-O verifies in every slice and carries our team, no executable waives
  library validation). Absolute loads only from `/usr/lib` and `/System/Library`; symlinks
  and @-paths stay in the bundle, `..` only leading. A new pod that fails it gets its
  install name fixed, never a wider gate. `scripts/macos_load_gate_test.sh`, guard
  `test/macos_load_gate_guard_test.dart`.
- Library validation admits ANY Mach-O our team signed, old Hollow libraries too: never sign
  anything with this team that loads code from a data path, a download or a plug-in folder.
- `Release.entitlements` keeps `disable-library-validation` ONLY for ad-hoc builds (a clone,
  the CI dry run): ad-hoc + library validation refuses the app's own ad-hoc frameworks
  ("different Team IDs"). The release signs with the file minus that key. Never sign a
  distributed build with the waiver: it lets any file dropped into a user-owned bundle load.
- HOL-SEC-187 keychain: the sign stage seals every nested Mach-O's cdhash into Info.plist
  (`macos_load_gate.sh seal`, after the last nested signature, before the app's), embeds
  the Developer ID profile (`MAC_PROVISION_PROFILE`, CI secret
  `DEVELOPER_ID_PROFILE_BASE64`) and adds application-identifier, team-identifier and
  `group.com.anonlisten.hollow.keys` to the shipped entitlements, never to
  `Release.entitlements`; `signed` checks the profile, the claims, the seal and refuses a
  JIT engine. Debug is ALWAYS ad-hoc (`Flutter-Debug.xcconfig` never includes
  `LocalSigning.xcconfig`) and so never opens a keychain-protected identity: develop on
  throwaway data roots. `BundleSeal.checkAtStart()` stays the first line of
  `MainFlutterWindow.awakeFromNib`. Wiki `security_write_gates` §43b.
- Library validation on means no legacy DAL camera plug-ins in Hollow (macOS 12/13 only;
  14.1+ dropped them everywhere); Camera Extensions run out of process and still work.

## Toolchain pins (0.14)

- Flutter 3.47.9 everywhere (CI, `release-apple.yml`, BUILDING.md, and the old iMac that signs
  Apple builds). Bump all of them together. Wiki `couplings_gotchas` "Flutter 3.47.9
  upgrade leftovers".
- mdk (fvp's media engine) = the 0.40.1 release asset (fvp 0.40.0) pinned by SHA-256 on
  Windows, Linux and Android (`FVP_DEPS_URL` + `FVP_DEPS_SHA256`; a wrong digest fails the
  build); Apple takes it through fvp's checksummed Swift package, never a CocoaPods pin (it
  embedded mdk twice; fvp's podspec still says 0.39, ignore it). Never let fvp fall back to
  the SourceForge nightly. `test/mdk_pin_guard_test.dart` fails when the three pins and the
  resolved fvp's `Package.swift` name different mdk versions.
- `build_release.ps1` refuses to build with any `NATIVEAPI_*` variable set (tray_manager 0.7
  would bundle a WinUI runtime). Linux build deps are the X11 and Xi headers (libx11-dev,
  libxi-dev), not AppIndicator (the flatpak still carries its AppIndicator module).
- tray_manager 0.7: ONE native menu, items refreshed in place before the right-click opens
  it; the menu's modal loop never runs inside a Dart callback.
- A Windows `hollow://` launch the running copy did not take is retried once.
- SQLCipher 4.20.0 on SQLite 3.54.1 via rusqlite 0.42 (`sqlcipher-src`); every bump runs
  `scripts/sqlcipher_amalgamation_diff.py` against the upstream tag and reopens a database
  the old build wrote (WAL row included). zip 9.5.1: the ignored replay test opens every zip
  kind an older build wrote through its real import path. Wiki `rust_storage_db` "Bumping
  rusqlite / SQLCipher", `rust_archive`.

## Android build

- SQLCipher links vendored static OpenSSL **3.5.8** per arch
  (`.cargo/android-openssl-headers/`, README inside; built on the Linux VM); the env vars
  must be SYSTEM env vars (Cargo `[env]` never reaches cargokit). **A failed cargokit
  Rust build does NOT fail `flutter build apk`: Gradle packages the STALE `.so`**;
  `build_release.ps1` scans the log for it. Rust TLS uses `webpki-roots`, NEVER
  `native-roots`. `feedback_android_platform`.
- Kotlin incremental compilation is OFF (`android/gradle.properties`, `kotlin.incremental=false`).
  Plugin sources live in version-named pub-cache dirs, so a package bump moves every file, and
  incremental Kotlin then emitted NO class for a moved file whose class kept its name: desktop_drop
  0.7.0 -> 0.8.4 built an empty jar that Gradle called up to date, and `:app` failed with
  `GeneratedPluginRegistrant.java: cannot find symbol DesktopDropPlugin` (11-15). The
  `hollowKotlinFullBuild` input in `android/build.gradle.kts` made every tree rebuild its Kotlin
  once; bump it to force that again. Never fix it by hand-editing the registrant (regenerated).
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
- Test builds never reach the OS's own data folder: `identity::data_dir()` with no override
  and no `HOLLOW_DATA_DIR` gives a per-process root under the test temp root
  (`os_data_root`, `test_tmp::process_dir`; test `tests_never_touch_the_real_data_root`).
  Before #155's review about 120 tests (ws_client wire tests, recovery, vault, the destroy
  harness journeys, file transfer) wrote `messages.db` and `vault/<id>` into the real
  `%APPDATA%\hollow` and `~/Library/Application Support/hollow` of whoever ran the suite.
  Flutter tests get the same through `test/flutter_test_config.dart` (data root and the
  profile registry anchor in a temp folder; `test/real_profile_isolation_test.dart`); a test
  that overrides `debugDefaultDesktopDataRoot` restores the PREVIOUS value, never null.
- Release builds keep stderr quiet (`mirror_to_stderr`: debug builds and the forwarder only):
  the systemd journal would keep a copy no wipe reaches. The log file exists only while an
  identity does and is erased by the wipe. HOL-SEC-156.
- The updater accepts a manifest version only as three numeric parts (`is_release_version`),
  and Windows script paths go through `bat_quoted_path`. HOL-SEC-147.
- Every post-update relaunch carries the app's ORIGINAL argv (#155): a relaunch without
  `--portable` comes back on another profile (with a profiles.json pin, the pinned one; with
  none and an empty folder, Welcome). Windows quotes each argument with `bat_quoted_arg`
  (`%` doubled, a trailing `\` run doubled for CommandLineToArgvW) and REFUSES the update for
  one holding `"` or a control character, before anything is extracted; `update.bat` opens
  with `setlocal DisableDelayedExpansion` and `chcp 65001` (the file is UTF-8, so a non-ASCII
  username's paths decode). macOS passes `--args` and a `HOLLOW_DATA_DIR` override as
  `open --env` (LaunchServices gives the app its own environment), every path `sh_quote`d.
  Only the RUNNING build's script counts: an update FROM 0.14.1 or older still drops them.
  `update_bat_tests` runs the real script under `cmd /V:ON` on Windows.
- `update.bat` waits for the pid that wrote it (`tasklist /FI "PID eq"` plus the image name),
  never for every `hollow.exe` (another install or profile held updates forever), and a failed
  `xcopy` relaunches NOTHING (a half-copied app starts on mismatched parts): it says so and
  `pause`s, keeping the staged files. Over ssh `tasklist` answers "Access denied", so the
  pid-wait test returns early there and is run in a desktop session.
- The self-restart (`relaunchApp`, `self_restart_snippet`) hands `Start-Process` ONE command
  line (`argv_quote` + `ps_quote`): as a list, Windows PowerShell joined it unquoted and an
  argument with a space split. A non-Unicode argv refuses instead of panicking; macOS keeps
  `HOLLOW_DATA_DIR` via `open --env`.
- A release never carries profile data (#155): `build_release.ps1` refuses a Release folder
  holding `hollow_data`, a portable marker, `*.db`/`-wal`/`-shm`, `hollow.lock` or `identity.*`
  (`release_payload_guard.ps1`, self-test `release_payload_guard_selftest.ps1`, source guard
  `test/release_payload_guard_test.dart`); `hollow.iss` excludes the same; `extract_zip_to`
  skips `hollow_data/` and a marker beside the exe. `-SkipSign` builds an unsigned candidate.
- The Inno installer and uninstaller `taskkill /IM hollow.exe` EVERY copy (a portable one, a
  fleet peer): hold the `pc-fleet` lease when installing on the PC.
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
