# flutter_webrtc fork rebase 1.4.1 → 1.5.2 — execution spec

> Phase 1 of the WebRTC upgrade. Status: **groundwork complete, ready to execute.**
> Direction (Vitalik, 2026-06-25): **adopt upstream cleanly, trust the maintainers over our own recreations; fall back to custom code only where upstream genuinely lacks the feature.** ("We don't make our own encryption for a reason — the WebRTC audio plumbing is the same.")
> Companion memory: `project_flutter_webrtc_152_upgrade`. Fork divergence + data-channel-hack map: see that memory + the session that produced this.

## The three decisions
1. **Apple ADM** — ADOPT upstream's `RTCAudioDeviceModuleTypeAudioEngine` (drop the fork's forced `initWithAudioDeviceModuleType:0`). Upstream's own comment confirms the #1986 crash the fork worked around was fixed in WebRTC-SDK 144.7559.04+ (webrtc-sdk/webrtc#228). Gains Apple AEC/NS/AGC.
2. **Windows loopback** — ADOPT upstream's `application_loopback_capturer` + its `GetDisplayMedia` audio block (which calls `stream->AddTrack`). Drop the fork's `wasapi_loopback_capturer` audio path + its no-AddTrack workaround. Upstream's also gives per-PID app audio (HWND→PID).
3. **macOS deployment target** — KEEP the fork's `14.2` (upstream lowered to 10.15). Lowering the floor is a SEPARATE later task. But DO take upstream's WebRTC-SDK pin `144.7559.01`→`144.7559.09`.

## Scope
Desktops (Win/Mac/Linux) first. Mobile *receives* shared desktop audio for free once any desktop sends it through the real WebRTC track. Mobile *as sender* of its own screen audio (Android `AudioPlaybackCapture`) = deliberate later effort, not this.

---

## What upstream 1.4.1 → 1.5.2 is (ground truth)
66 files, +2699/−571, **zero deletions, zero renames.** Two feature groups:
- **(A) #2060 loopback audio** — new `common/cpp/include/loopback_capturer.h`, `windows/application_loopback_capturer.{cc,h}`, `windows/loopback_capturer_factory.cc`, `linux/loopback_capturer_factory.cc`; edits to `flutter_screen_capture.{h,cc}`, `windows/CMakeLists.txt`, `linux/CMakeLists.txt`.
- **(B) `FlutterRTCVideoPlatformView*` renderer rework** — new real files in `common/darwin/Classes/`, symlinks in `ios/Classes` + `macos/Classes`. Fork does NOT customize these.
- **libwebrtc acquisition reworked** — new `third_party/libwebrtc_version.ini` + rewritten `third_party/CMakeLists.txt` (per-OS/arch download from webrtc-sdk, normalized to `lib/libwebrtc.{dll,so}`, no `win64/`; symlink-extraction-hardened = #2100).

## Critical execution gotchas
- **EOL noise:** the fork is CRLF. A naive diff vs upstream flags 60+ files (every Android .java, README, LICENSE) as "modified" — pure CRLF/LF, NOT content. The TRUE fork-modified set (content differs after `tr -d '\r'`) is exactly **20 files** (listed below). Always compare CR-stripped: `diff <(tr -d '\r' < FORK) <(tr -d '\r' < UP)`.
- **`stream->AddTrack` is the #1 runtime risk** — see Risks.

## Strategy
**Mechanism (a): start from a clean upstream-1.5.2 copy (LF, correct symlinks inherited), re-apply the fork's small deltas on top.** Reasons: avoids whitespace-corrupting 60+ files (which `git apply` of upstream's LF diff onto the CRLF fork would do); inherits upstream-1.5.2's ~94 mode-120000 symlinks correct. KEEP the fork's windows/linux CMake structure as the base (it carries C++20 / `/await` / Opus FetchContent that upstream lacks) and merge upstream's additions INTO it.

The 20 true fork-modified files split into: **9 need real merge work**, **~11 carry forward verbatim** (upstream untouched those).

---

## Part A — the 9 real-merge files

### A1. `common/cpp/src/flutter_screen_capture.cc` — THE HARD ONE (fork 667 lines vs up 282/353)
The fork is a rewrite: native Graphics-Capture VIDEO (`NativeScreenCapturer`, resolution-constrained), data-channel ScreenAudio render pipeline (`StartScreenAudioCapture`/`StopScreenAudioCapture`/`ScreenAudioRender`/`ScreenAudioRenderStop`), `getSources` PID enrichment, `CleanupNativeCapturersForStream`. All fork-only, MUST survive.
**Resolution — base on the FORK's file; surgically apply upstream's audio path:**
- Replace ONLY the fork's Windows `want_audio` sub-block (≈ fork 250–311, the `WasapiLoopbackCapturer`+CaptureFrame, no-AddTrack) with **upstream's `capture_audio` block** (U152 ≈ 225–289): creates a `kCustom` `RTCAudioSource` with EC/AGC/NS disabled, `CreateLoopbackCapturer(source_id)`, `loopback_capturer_->Start(loopback_audio_source_)`, on success `stream->AddTrack(audio_track)` + register in `base_->local_tracks_`, else continue without audio.
- Switch audio members to upstream's single-session pair (`std::unique_ptr<LoopbackCapturer> loopback_capturer_` + `scoped_refptr<RTCAudioSource> loopback_audio_source_`); adapt `CleanupNativeCapturersForStream` to reset them + the `native_capturers_` map. (Drop the fork's `loopback_capturers_` map.)
- Add upstream's loopback teardown in `OnStop` + at GetDisplayMedia top.
- ADD `#include "loopback_capturer.h"`. KEEP fork includes for `screen_audio_capturer.h`/`opus_decoder_wrapper.h`/`wasapi_audio_renderer.h`/`native_screen_capturer.h` (still used). `wasapi_loopback_capturer.h` include likely becomes unused → remove only if compile confirms.
- KEEP verbatim: dtor, getSources PID block, target_width/height parsing, the ENTIRE native-video block + libwebrtc fallback, the 4 ScreenAudio methods.

### A2. `common/cpp/include/flutter_screen_capture.h`
Base on fork's header. ADD upstream includes (`loopback_capturer.h`, `rtc_audio_source.h`, `rtc_audio_track.h`) + members `loopback_capturer_` + `loopback_audio_source_`. REMOVE the fork's `loopback_capturers_` map (replaced by upstream's single member). KEEP fork's dtor decl, `#if _WIN32` forward-declares, the 4 ScreenAudio method decls, `native_capturers_`, `screen_audio_capturers_`, `AudioRenderSession`+`audio_render_sessions_`, `CleanupNativeCapturersForStream`.

### A3. `common/darwin/Classes/FlutterWebRTCPlugin.m` — clean (fork never touched the ADM)
**Base on upstream-1.5.2 VERBATIM** (free: AVAudioEngine ADM, `FLutter`→`Flutter` typo fix, macOS platform-view-factory wiring, `audioSessionManagementEnabled` gates, ADM observer hookup, `isVoiceProcessingEnabled`→`isPlatformVoiceProcessingAllowed`). Re-apply 6 fork additions at the upstream anchors:
1. `#import "CaptureGainProcessor.h"` after `#import "LocalVideoTrack.h"`.
2. macOS Mac-helper import block (`#if TARGET_OS_OSX` → `MacScreenShareAudioTap.h`, `MacAudioDevices.h`, `MacRecordingAudioDevice.h`, `MacScreenRecorder.h`, `<objc/runtime.h>` → `#endif`).
3. `CaptureGainProcessor* _captureGainProcessor;` ivar (last, after `loggerCallback`).
4. init `_captureGainProcessor = [[CaptureGainProcessor alloc] init]; [_audioManager.capturePostProcessingAdapter addProcessing:_captureGainProcessor];` after `_audioManager = AudioManager.sharedInstance;`.
5. The 9 macOS method-channel cases (`enableScreenShareSystemAudio`, `disableScreenShareSystemAudio`, `hollowMacAudioDevices`, `hollowMacStartRecordingAudio`, `hollowMacStopRecordingAudio`, `hollowMacStartScreenRecord`, `hollowMacStopScreenRecord`, `hollowMacEnterAnnotationMode`, `hollowMacExitAnnotationMode`; each `#if TARGET_OS_OSX … #else error #endif`) before the `createLocalMediaStream` case.
6. `setCaptureGain` case after the `setVolume` case.

### A4. `lib/src/helper.dart`
Base on upstream (gets `requestCapturePermission({bool fullScreenOnly = false})`). Add the fork's `setCaptureGain(double gain)` static (delegates to `NativeAudioManagement.setCaptureGain`) in the same relative spot. Disjoint.

### A5. `windows/CMakeLists.txt` — UNION (base on FORK's; KEEP C++20/`/await`/Opus)
**Sources** = fork's list + upstream's `application_loopback_capturer.cc` + `loopback_capturer_factory.cc`.
**Link libs** = fork's (`opus`, `mfplat/mfreadwrite/mfuuid/mf`, `d3d11`, `dxgi`, `windowsapp`, `RuntimeObject`) + upstream's NEW `avrt.lib ksuser.lib mmdevapi.lib ole32.lib uuid.lib winmm.lib` (do NOT also add upstream's `runtimeobject.lib` — dupes fork's `RuntimeObject.lib`).
**Path change:** `lib/win64/libwebrtc.dll.lib` → `lib/libwebrtc.dll.lib` (link) and `lib/win64/libwebrtc.dll` → `lib/libwebrtc.dll` (bundled). KEEP `CMAKE_CXX_STANDARD 20`, the Opus FetchContent block, `/await`, svpng include, `-DLIB_WEBRTC_API_DLL/-DRTC_DESKTOP_DEVICE`.

### A6. `linux/CMakeLists.txt` — UNION (base on FORK's)
**Sources** = fork's + upstream's `loopback_capturer_factory.cc` (nullptr stub on Linux).
**Path change** (both link + bundled): `lib/${FLUTTER_TARGET_PLATFORM}/libwebrtc.so` → `lib/libwebrtc.so`. KEEP fork's C++17, svpng include, GTK link, `$ORIGIN` RPATH.

### A7. `android/src/main/java/com/cloudwebrtc/webrtc/MethodCallHandlerImpl.java` — UNION (collision)
Base on upstream-1.5.2 (gets: `dispose()` try/catch hardening around streamDispose/media-stream/local-track/peerConnection; `requestCapturePermission` reading `fullScreenOnly` → `getUserMediaImpl.requestCapturePermission(result, fullScreenOnly)`; new `getAudioDeviceModule()` getter; `streamDispose` IllegalState catches). Re-apply 3 fork CaptureGain bits: field `captureGainProcessor` (~145), ctor init `audioProcessingController.capturePostProcessing.addProcessor(...)` (~342), `case "setCaptureGain":` (~790). Disjoint from upstream's regions.

### A8. `macos/flutter_webrtc.podspec`
Only change vs fork: `WebRTC-SDK '144.7559.01'` → `'144.7559.09'`. KEEP `s.osx.deployment_target = '14.2'`, weak ScreenCaptureKit, `s.version '1.4.0'`.

### A9. `macos/Classes/FlutterScreenCaptureKitCapturer.{h,m}` — KEEP FORK
Fork has window-capture + target-resolution that `FlutterRTCDesktopCapturer.m` depends on; upstream's change is cosmetic nullability only. KEEP fork's `.h`+`.m` verbatim. Optional 1-liner in `.m`: annotate `@property … SCStream *stream;` with `API_AVAILABLE(macos(12.3))` to silence a warning.

---

## Part B — carry forward VERBATIM (fork-only changes; upstream untouched)
`common/cpp/include/flutter_webrtc_base.h`, `common/cpp/src/flutter_webrtc_base.cc`, `common/cpp/src/flutter_webrtc.cc`, `common/darwin/Classes/FlutterRTCDesktopCapturer.m`, `lib/src/native/audio_management.dart`, `lib/src/native/desktop_capturer_impl.dart`, `lib/src/desktop_capturer.dart`, `ios/Classes/FlutterRTCAudioSink.mm`, `ios/Classes/audio_sink_bridge.cpp` (the last 2 are forwarder text, see Part E).

## Part C — copy in 21 upstream-new files
- **Loopback (real):** `common/cpp/include/loopback_capturer.h`, `windows/application_loopback_capturer.{cc,h}` (.cc 737 lines, ApplicationLoopbackAudio Win10-20H1+, per-PID via HWND→PID, all sample formats), `windows/loopback_capturer_factory.cc`, `linux/loopback_capturer_factory.cc` (stub).
- **PlatformView (real, into `common/darwin/Classes/`):** `FlutterRTCVideoPlatformTypes.h`, `FlutterRTCVideoPlatformView.{h,m}`, `FlutterRTCVideoPlatformViewController.{h,m}`, `FlutterRTCVideoPlatformViewFactory.{h,m}`.
- **PlatformView per-platform (SYMLINKS):** `ios/Classes/FlutterRTCVideoPlatformTypes.h` + 7 `macos/Classes/FlutterRTCVideoPlatformView*` — mode 120000 → `../../common/darwin/Classes/<base>`. Inherited free if basing on U152.

## Part D — third_party
1. Replace `third_party/CMakeLists.txt` with upstream-1.5.2's verbatim (fork's was stock 1.4.1).
2. Add `third_party/libwebrtc_version.ini` verbatim (`binary_version = libwebrtc.m144.7559.09`, base url `https://github.com/webrtc-sdk/libwebrtc/releases/download`).
3. KEEP `third_party/svpng/`.
4. DELETE stale `third_party/downloads/` (old v1.4.0 single zip) + `third_party/libwebrtc/` (old win64-layout tree). New CMake fetches `libwebrtc-{win|linux}-{x64|arm64}-release.zip` → normalizes to `lib/libwebrtc.{dll,so}`.

## Part E — symlinks
~80 existing + 14 new PlatformView = ~94 mode-120000 (each = `../../common/darwin/Classes/<base>`, NO trailing newline). Re-add 4 fork CaptureGainProcessor.{h,m} links (ios+macos). **KEEP as forwarder TEXT (mode 100644), do NOT let the U152 overlay revert to symlinks:** `ios/Classes/audio_sink_bridge.cpp` + `ios/Classes/FlutterRTCAudioSink.mm` (5-line `#include "../../common/darwin/Classes/<name>"`). Windows symlink recreate: `git update-index --add --cacheinfo 120000,<blob>,<path>` (can reuse U152 blob ids).

## Part F — pubspec
Fork `pubspec.yaml`: `version: 1.4.1` → `1.5.2` (the ONLY upstream pubspec delta; dart_webrtc ^1.8.0 / webrtc_interface ^1.5.1 / sdk `>=3.3.0 <4.0.0` unchanged). Repo-root `pubspec.yaml` = path ref, no change. `pubspec.lock` regenerates on `flutter pub get` (don't hand-edit).

## Risks & verification
1. **`stream->AddTrack` (HIGHEST) —** upstream's adopted audio block calls `stream->AddTrack` on a kCustom track; the fork's removed code documented this as crashing the pinned libwebrtc during sender iteration/setParameters. We bet m144 fixed it (consistent with upstream fixing the sibling #1986). VALIDATE on Windows: screen-share WITH system audio in a real call, watch for crash. Fallback: keep `CreateLoopbackCapturer`, drop the `AddTrack` line, attach the track Dart-side (fork's original strategy).
2. Relative `#include "../../../windows/…"` — some unused after the audio-block swap (`wasapi_loopback_capturer.h` likely). Remove only what compile flags; KEEP the screen-audio/opus/renderer/native-video headers.
3. Linux-safety of merged `.cc` — `CreateLoopbackCapturer` returns nullptr on Linux; do NOT `#if _WIN32`-wrap the adopted block.
4. libwebrtc download path — delete `third_party/{downloads,libwebrtc}`, configure fresh, confirm it lands `lib/libwebrtc.dll.lib` (not `lib/win64/`).
5. New Windows libs / no double RuntimeObject.
6. C++20/`/await` MUST stay in the merged windows CMake (fork's native files use coroutines).
7. Symlinks: `git ls-files -s …/ios/Classes …/macos/Classes | grep -c '^120000'` ≈ 94; the 2 audio-sink forwarders are 100644.

**Windows validate** (Vitalik runs the final `flutter run`):
```
rm -rf build/windows/x64/plugins/flutter_webrtc
rm -rf packages/flutter_webrtc/third_party/{downloads,libwebrtc}
flutter pub get
flutter build windows --release
# Vitalik: flutter run -d windows --release → test share / share-with-audio / a voice call (capture gain)
```
Linux: SSH build flow. iOS/macOS: Vitalik Xcode Archive — NEVER `flutter build ios`.
