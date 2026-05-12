# Hollow Mobile Port Plan

## Status

**Android: fully functional.** Rust backend, E2E encrypted messaging, WebSocket relay,
identity, friends, servers — all working. Mobile UI redesign in progress.

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
- [x] Android data directory — `set_data_dir()` FFI + `hollowDataDir` Dart utility
- [x] Crash logging path — `path_provider` on mobile
- [x] TLS root certs — `tokio-tungstenite` switched to `webpki-roots` (Android can't read Java KeyStore)
- [x] WebSocket relay connection verified working on Android
- [x] E2E encrypted messaging verified (Olm key exchange + message flow between Android ↔ Windows)

## What's left

### Must fix (app runs but broken)
1. ~~**Android data directory**~~ — **DONE.** Added `set_data_dir()` FFI (Rust `OnceLock<String>`
   override in `identity/keys.rs`). Dart calls `identity_api.setDataDir()` in `main()` after
   `RustLib.init()` on Android/iOS, using `getApplicationDocumentsDirectory()` from `path_provider`.
2. ~~**Crash logging path**~~ — **DONE.** `_initCrashLogging()` now uses `getApplicationDocumentsDirectory()`
   on Android/iOS instead of `APPDATA`/`HOME` env vars.

### Mobile UX redesign (complete rewrite of mobile layout)

The desktop UI crammed into 360px is unusable. Mobile needs a fundamentally different
navigation model — touch-first, single-panel, designed for Hollow's aesthetic.

#### Design decisions (agreed 2026-05-12, refined 2026-05-12)

**Navigation model: Telegram-style unified list + expandable servers**

4 bottom tabs:
- **Chats** — unified conversation list mixing DMs and servers
- **Friends** — friend list, add friend, friend requests
- **Archive** — My Data (export per-DM/channel/server) + Imported Archives (browse, verify, view)
- **Settings** — profile card at top, ASOT-style section dividers, scrollable

**Chats tab — the unified conversation list:**
- Two item types in one scrollable list, ordered by most recent activity:
  - **DM rows:** avatar + name + last message preview + timestamp + unread badge
  - **Server rows:** server icon + name + unread count across all channels
- Tap a DM → full-screen chat view (push navigation)
- Tap a server → animated accordion expansion showing channels inline:
  - Text channels (indented, tap → full-screen chat)
  - Voice channels (show active member count, join button)
- Long-press a server row → context menu (Settings, Invite, Members, Leave)
- Pinned items stick to top of list
- This gives: 1 tap to any DM, 2 taps to any channel (same depth as Discord mobile)

**Chat view (full-screen, pushed from Chats list):**
- Chat header bar: back arrow + channel/DM name + icons (call, member panel, more)
- Tap channel name in header → slide-down sheet with:
  - Member list
  - Pinned messages
  - Media/files/links tabs (new feature — build on mobile first, backport to desktop)
  - Search
- Message input at bottom with attach button (uses `file_picker` on mobile, not drag-drop)
- Swipe right from left edge → back to conversation list

**Member panel:** slide-out bottom sheet (not a permanent side panel)

**Settings tab — ASOT-style divider layout:**
```
──────── Profile ────────
[avatar, name, status, edit button]

──────── Appearance ────────
[theme, accent color, animations toggle]

──────── Network ────────
[relay domain, relay list, connection status]

──────── Data ────────
[backup/restore, storage usage]

──────── About ────────
[version, licenses, links]
```
Full-width horizontal line with centered section text. No Material cards or grouped lists.

**Voice channel view — mobile redesign:**
- Portrait by default, landscape unlock when viewing remote screen share or video
- Participant grid that adapts to orientation
- Floating control pill (mute, deafen, camera, leave) — auto-hide in landscape
- Remote screen share: full-bleed with pinch-to-zoom, overlay controls auto-hide
- Camera supported, screen sharing NOT supported (sending — receiving is fine)

**Home dashboard (news/relay stats):** section in Settings tab under Network or About.
Not a dedicated tab.

#### Feature scope

**Ported (Rust logic exists, mobile UI needed):**
- DM + channel messaging (send/receive/edit/delete, reactions, reply)
- Server CRUD (create, join via invite, leave, settings)
- Channel CRUD (create, edit, delete)
- Friend system (add, accept, remove, block)
- Identity (create, restore from mnemonic, backup phrase)
- Profiles (display name, bio, avatar, banner, status)
- Roles & permissions (power roles + cosmetic labels)
- Typing indicators, unread tracking, notification badges
- Link previews (sender-generated)
- Relay domain switching, license key entry
- Emoji reactions, message signing / proof verification
- 1:1 DM voice calls (WebRTC over TURN)
- Server voice channels (WebRTC over TURN)
- Camera in voice/calls (no screen share sending)
- Viewing remote screen shares (with landscape + pinch-to-zoom)
- Archive export/import (.hollow-archive)
- Backup/restore (.hollow encrypted backup)
- Vault (shard storage, for servers 6+ members)
- Media/files/links browsing per channel (new — needs FFI queries)

**Excluded from mobile:**
- Hollow Share (STUN-only P2P — dead on mobile CGNAT networks)
- Downloads tab (no Share = no downloads)
- Screen share sending (explicitly excluded)
- `win32audio` output device selection (desktop-only)
- `desktop_drop` drag-and-drop (replaced with `file_picker`)
- Tray/window management (OS handles lifecycle)
- FFmpeg services (returns null on mobile, graceful skip)

**STUN note:** STUN only works when at least one side has public/cone NAT (home routers).
Mobile carriers use symmetric NAT/CGNAT — STUN fails mobile↔home and mobile↔mobile.
TURN is the only reliable path. This is why Share (STUN-only) is excluded.

#### Implementation order
1. [x] New mobile navigation shell (4-tab `MobileShell` with animated tab fades)
2. [x] Unified conversation list (`MobileChatsTab` — DM rows + server rows, sorted by activity)
3. [x] Server accordion expansion (animated channel list, on-demand loading via FFI)
4. [x] Full-screen chat view push route (`MobileChatRoute` — uses desktop ChatPane, needs mobile rewrite)
5. [ ] Mobile chat view rewrite (full-width messages, mobile input bar, no profile sidebar)
6. [ ] Chat header detail sheet (members, pins, media/files/links)
7. [ ] Long-press context menus (server settings, message actions)
8. [x] Friends tab (friend list, add friend dialog, incoming/outgoing requests, cancel)
9. [ ] Archive tab (My Data + Imported Archives, touch-friendly)
10. [x] Settings tab (profile card, peer ID copy, ASOT dividers, network status)
11. [x] FAB "+" button on Chats tab (Create Server, Join Server, Add Friend dialog)
12. [ ] Voice channel — mobile redesign (floating controls, participant grid)
13. [ ] Voice/video orientation handling (portrait default, landscape for screen share viewing)
14. [ ] File picker integration — attach button uses `file_picker` on mobile
15. [ ] Touch targets & safe areas — 48px minimum, system inset respect
16. [ ] Keyboard handling — `adjustResize` behavior (already set in AndroidManifest)

#### Not in scope (post-launch)
- Notifications — `local_notifier` is desktop-only. Mobile needs FCM (Android) / APNs (iOS)
- Background voice calls (Android foreground service, iOS VoIP push)
- App store publishing (Play Store + App Store)
- Performance optimization for mobile (battery, network switching)
- Screen share sending

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
