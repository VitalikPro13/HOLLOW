# Hollow Mobile Port Plan

## Current State

Windows desktop is fully functional. macOS and Linux need the same OS for testing/publishing.
Android and iOS are structurally ready — Flutter project directories exist, cargokit is configured,
and mobile navigation code already exists in `mobile_nav.dart` + `hollow_shell.dart` breakpoints.

Last attempt: app froze on the Android splash screen. Root cause unknown but likely either
Rust library init failure (cargokit build issue / SQLCipher linkage) or a desktop-only API
call crashing on startup (`fvp.registerWith()` or similar).

## Architecture Compatibility

### Works out of the box (no changes needed)
- **Rust core** — all deps are pure Rust or bundled C. `rustls-tls` (no native OpenSSL),
  `bundled-sqlcipher`, `ed25519-dalek`, `openmls`, `vodozemac`. Cross-compiles to ARM64/ARMv7.
- **flutter_rust_bridge 2.11.1** — cargokit configured in `rust_builder/` for Android (Gradle) and iOS (Podspec).
- **Forked flutter_webrtc** — has full Android/iOS native implementations. WASAPI patch is Windows-only, no-op on mobile.
- **Mobile layout** — `mobile_nav.dart` (bottom nav, 4 tabs) + `hollow_shell.dart` responsive breakpoints
  (<600px mobile, <1024px tablet, >=1024px desktop) already implemented.
- **Ed25519 keypairs, BIP-39 mnemonic** — pure Rust, platform-agnostic.
- **CRDT sync, MLS encryption, Olm DMs** — pure Rust, platform-agnostic.
- **WebRTC voice/video/data channels** — flutter_webrtc has native mobile implementations.
- **SQLCipher** — bundled via rusqlite feature, cargokit handles ARM compilation.

### Needs platform guards (minor work)
| Item | Issue | Fix |
|------|-------|-----|
| `fvp.registerWith()` | Desktop-only FFmpeg video player, may crash on mobile | Add `if (Platform.isWindows \|\| Platform.isLinux \|\| Platform.isMacOS)` guard in `main.dart` line 161 |
| `window_manager` | Desktop window chrome | Already guarded (line 145+) |
| `tray_manager` | System tray | Already guarded |
| `desktop_drop` | OS drag-and-drop in `chat_drop_zone.dart`, `imported_archives_view.dart` | Conditionally hide drop zone UI on mobile |
| `win32audio` | Windows audio output device selection | Already conditionally used |
| `local_notifier` | Desktop notifications | Need mobile notification alternative (later) |

### Needs FFmpeg fallback (medium work)
These services assume bundled FFmpeg binaries which don't exist on mobile:
- `audio_transcode_service.dart` — Opus transcoding. Mobile has native codec support, need platform-aware path.
- `video_thumbnail_service.dart` — FFmpeg thumbnail extraction. Use `video_player` frame extraction or placeholder on mobile.
- `audio_probe_service.dart` — FFmpeg audio probing. Skip or use mobile-native alternative.

**Strategy:** Each service's `findFfmpegBinary()` returns `null` on mobile → graceful skip/fallback.

### Needs permissions added
**Android** (`android/app/src/main/AndroidManifest.xml`):
```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
```

**iOS** (`ios/Runner/Info.plist`):
```xml
<key>NSMicrophoneUsageDescription</key>
<string>Hollow needs microphone access for voice calls.</string>
<key>NSCameraUsageDescription</key>
<string>Hollow needs camera access for video calls.</string>
```

## Won't work on mobile (acceptable)
- System tray / custom window chrome — not applicable
- Desktop drag-and-drop — use file picker instead
- `win32audio` output routing — mobile handles audio routing natively
- FFmpeg CLI transcoding — mobile codecs handle this natively
- Single-instance lock file — mobile OS manages app lifecycle

## Execution order

### Phase 1: Get it running (goal: past splash screen)
1. Add Android/iOS permissions
2. Add `fvp` platform guard in `main.dart`
3. Audit `main.dart` init sequence for any other desktop-only calls
4. `flutter run -d <android_device>` and check logs
5. If Rust init fails: debug cargokit build, check `hollow_debug.log`

### Phase 2: Platform guards
1. Wrap FFmpeg services with platform checks (graceful null return on mobile)
2. Conditionally hide `desktop_drop` zones on mobile
3. Test all core flows: login, DMs, servers, voice calls

### Phase 3: Mobile UX polish
1. Verify mobile navigation works end-to-end
2. Test responsive breakpoints on real phone screens
3. Touch targets, safe area insets, keyboard handling
4. File picker integration (replacing desktop drag-drop)
5. Mobile-specific notification handling (FCM/APNs — future)

### Phase 4: Platform-specific features (post-launch)
- Background voice calls (Android foreground service, iOS VoIP push)
- Push notifications (FCM + APNs)
- App store metadata and screenshots
- Mobile-specific performance optimization

## Build commands
```bash
# Android (debug on device)
flutter run -d <device_id>

# Android release APK (split per ABI for smaller size)
flutter build apk --split-per-abi

# Android App Bundle (for Play Store)
flutter build appbundle

# iOS (requires macOS)
flutter build ios --release

# List connected devices
flutter devices
```

## Risk assessment
- **Low risk:** Rust core, crypto, CRDT sync, basic UI — all platform-agnostic
- **Medium risk:** WebRTC on mobile (different ICE/TURN behavior, battery/network switching)
- **Medium risk:** SQLCipher first-open performance on older Android devices
- **Unknown:** Whatever caused the previous splash screen freeze — need logs to diagnose
