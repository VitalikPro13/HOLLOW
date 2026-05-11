# Hollow Mobile Port Plan

## Status

**Android: boots and renders UI.** Rust library compiles and loads, networking connects,
mobile layout displays. Remaining work is data directory plumbing and UI adaptation.

**iOS: untested.** Should work once macOS is available for building. Same Rust core, same
Flutter codebase. Cargokit + Podspec are configured.

## What's done

- [x] Android permissions (INTERNET, RECORD_AUDIO, CAMERA, ACCESS_NETWORK_STATE, FOREGROUND_SERVICE, WAKE_LOCK)
- [x] iOS permissions (NSMicrophoneUsageDescription, NSCameraUsageDescription)
- [x] `fvp.registerWith()` guarded with desktop platform check
- [x] `desktop_drop` DropTarget bypassed on mobile (ChatDropZone, ImportedArchivesView)
- [x] Package name fixed: `com.anonlisten.hollow`
- [x] iOS display name fixed: "Hollow"
- [x] macOS xcodeproj/xcscheme references fixed
- [x] Forked flutter_webrtc vendored into `packages/flutter_webrtc/`
- [x] Rust cross-compilation for Android (NDK linker config, OpenSSL 1.1.1w static linking)
- [x] Cargokit patched to pass OpenSSL headers and lib path via env vars

## What's left

### Must fix (app runs but broken)
1. **Android data directory** — Rust `dirs` crate returns `None` on Android. The `_bootstrap()` in
   `hollow_shell.dart` fails with "Could not find app data directory". Need to pass the Android
   app data path from Dart to Rust via FFI before `start_node()`.
2. **Crash logging path** — `_initCrashLogging()` in `main.dart` uses `APPDATA`/`HOME` env vars
   (desktop-only). On Android, use `getApplicationDocumentsDirectory()` from `path_provider`.
   Also fix the `StreamSink` cascade: guard writes with null check on the sink.

### Mobile UX work
3. **Layout overflow** — `home_dashboard.dart:118` Row overflows on narrow screens. The desktop
   layout renders on mobile because `_bootstrap()` fails before the layout mode is determined.
   Once data dir is fixed, the mobile breakpoints should kick in.
4. **Touch targets & safe areas** — audit all interactive elements for 48px minimum touch targets,
   respect system status bar and navigation bar insets.
5. **Keyboard handling** — text fields need `adjustResize` behavior (already set in AndroidManifest).
6. **File picker** — replace desktop drag-drop with `file_picker` on mobile (already a dependency).
7. **Notifications** — `local_notifier` is desktop-only. Mobile needs FCM (Android) / APNs (iOS).

### Post-launch
- Background voice calls (Android foreground service, iOS VoIP push)
- App store publishing (Play Store + App Store)
- Performance optimization for mobile (battery, network switching)
- Screen share audio per-platform (CoreAudio macOS, PulseAudio Linux)

## Architecture notes

### What works on mobile (no changes needed)
- **Rust core** — all deps are pure Rust or bundled C (`rustls-tls`, `bundled-sqlcipher`,
  `ed25519-dalek`, `openmls`, `vodozemac`). Cross-compiles to ARM64/ARMv7/x86_64.
- **flutter_rust_bridge 2.11.1** — cargokit handles NDK compilation + JNI library bundling.
- **Forked flutter_webrtc** (`packages/flutter_webrtc/`) — full Android/iOS native implementations.
  WASAPI loopback patch is Windows-only, no-op on mobile.
- **Mobile navigation** — `mobile_nav.dart` + `hollow_shell.dart` responsive breakpoints already
  implemented (<600px mobile, <1024px tablet, >=1024px desktop).
- **Crypto** — Ed25519, BIP-39, CRDT sync, MLS, Olm, SFrame — all pure Rust, platform-agnostic.
- **FFmpeg services** — `findFfmpegBinary()` returns null on mobile → graceful skip/fallback.

### What doesn't apply on mobile
- `window_manager` / `tray_manager` — already guarded with `Platform.isWindows || ...`
- `desktop_drop` — bypassed on mobile, use file picker instead
- `win32audio` — in try-catch, fails gracefully
- `fvp` — guarded, mobile uses native `video_player`
- Single-instance lock file — mobile OS manages lifecycle

---

## Building for Android (contributor guide)

### Prerequisites

1. **Flutter SDK** (stable channel, tested with 3.41.4)
2. **Rust toolchain** (stable) with Android targets:
   ```bash
   rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android
   ```
3. **Android SDK** with NDK 27+ installed (Android Studio → SDK Manager → SDK Tools → NDK)
4. **OpenSSL 1.1.1w static libraries** for Android (prebuilt per-architecture)
5. **Perl** (Strawberry Perl on Windows, or system perl on Linux/macOS) — needed if rebuilding OpenSSL

### OpenSSL for SQLCipher

SQLCipher requires OpenSSL headers at compile time and `libcrypto.a` at link time. Android's NDK
doesn't ship OpenSSL, so we prebuilt static `libcrypto.a` from OpenSSL 1.1.1w for each architecture.

**Prebuilt libs location:** `rust/hollow_core/.cargo/android-openssl-headers/`
```
android-openssl-headers/
├── include/openssl/   # OpenSSL 1.1.1w headers (platform-independent)
└── lib/
    ├── aarch64/libcrypto.a   # ARM64 (real phones)
    ├── armv7/libcrypto.a     # ARMv7 (older phones)
    ├── x86_64/libcrypto.a    # x86_64 (emulators)
    └── i686/libcrypto.a      # x86 (old emulators)
```

**Why OpenSSL 1.1.1w (not 3.x)?** OpenSSL 3.x has a provider system that requires Perl template
processing during build. Cross-compiling OpenSSL 3.x from Windows fails because Windows Perl
(Strawberry) can't produce Unix-like paths, and Git Bash's Perl is too stripped-down. OpenSSL 1.1.1w
builds cleanly and has all the crypto functions SQLCipher needs.

### Environment variables

The build requires these system environment variables (set via `setx /M` on Windows):

**For Android cross-compilation (per-target):**
```
X86_64_LINUX_ANDROID_OPENSSL_INCLUDE_DIR = <project>/rust/hollow_core/.cargo/android-openssl-headers/include
X86_64_LINUX_ANDROID_OPENSSL_LIB_DIR     = <project>/rust/hollow_core/.cargo/android-openssl-headers/lib/x86_64
X86_64_LINUX_ANDROID_OPENSSL_STATIC      = 1
```
(Same pattern for `AARCH64_LINUX_ANDROID_*`, `ARMV7_LINUX_ANDROIDEABI_*`, `I686_LINUX_ANDROID_*`)

**For Windows desktop builds:**
```
OPENSSL_DIR         = C:\Program Files\OpenSSL-Win64
OPENSSL_LIB_DIR     = C:\Program Files\OpenSSL-Win64\lib\VC\x64\MD
OPENSSL_INCLUDE_DIR = C:\Program Files\OpenSSL-Win64\include
```

**For cargokit (OpenSSL headers in CFLAGS + lib path in RUSTFLAGS):**
```
HOLLOW_ANDROID_OPENSSL_INCLUDE = <project>/rust/hollow_core/.cargo/android-openssl-headers/include
HOLLOW_ANDROID_OPENSSL_LIB     = <project>/rust/hollow_core/.cargo/android-openssl-headers/lib
```

### Cargo config

`rust/hollow_core/.cargo/config.toml` contains NDK linker paths for each Android target.
These are machine-specific (your NDK install path). Example:

```toml
[target.x86_64-linux-android]
linker = "C:\\...\\ndk\\27.0.12077973\\...\\bin\\x86_64-linux-android21-clang.cmd"
```

### Rebuilding OpenSSL (if needed)

Only needed if you don't have the prebuilt `libcrypto.a` files. From Git Bash:

```bash
# Download OpenSSL 1.1.1w
curl -sL "https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-1.1.1w.tar.gz" | tar xz
cd openssl-1.1.1w

# Set NDK tools
NDK_BIN="$ANDROID_SDK/ndk/<version>/toolchains/llvm/prebuilt/<host>/bin"
export CC="$NDK_BIN/x86_64-linux-android21-clang.cmd"  # or aarch64, armv7a, i686
export AR="$NDK_BIN/llvm-ar.exe"
export RANLIB="$NDK_BIN/llvm-ranlib.exe"

# Need GNU make on PATH (gmake from Strawberry Perl on Windows)
export PATH="/tmp/makebin:$PATH"

# Configure and build
perl ./Configure linux-x86_64 no-shared no-tests no-comp no-asm -DANDROID -fPIC
make -j4 build_libs

# Copy results
cp libcrypto.a <project>/rust/hollow_core/.cargo/android-openssl-headers/lib/x86_64/
```

Repeat for each architecture: `linux-generic32` for armv7, `linux-aarch64` for arm64, `linux-x86_64` for x86_64.

### Build commands

```bash
# Debug on emulator/device
flutter run -d <device_id>

# Release APK (split per ABI)
flutter build apk --split-per-abi

# App Bundle (Play Store)
flutter build appbundle

# List connected devices
flutter devices
```

## Building for iOS

Requires macOS. Cargokit + Podspec are configured in `rust_builder/ios/`. The same OpenSSL 1.1.1w
headers should work (they're platform-independent C headers). Static `libcrypto.a` needs to be
built for `aarch64-apple-ios` and `aarch64-apple-ios-sim` targets. iOS uses CommonCrypto natively,
but SQLCipher's `bundled-sqlcipher` feature still needs OpenSSL headers for compilation.

```bash
flutter build ios --release
```
