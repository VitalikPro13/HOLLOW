# Recording and Annotation Services

## RecordingService

File: `lib/src/core/services/recording_service.dart`

Singleton (`RecordingService.instance`). Captures the screen + audio to MP4 file. One recording at a time.

### Platform Paths

**macOS (native):** Calls `hollowMacStartScreenRecord` / `hollowMacStopScreenRecord` via `FlutterWebRTC.Method` channel. Native ScreenCaptureKit + AVAssetWriter in `packages/flutter_webrtc/macos/Classes/MacScreenRecorder.m`. Produces H.264 + 2 AAC tracks: system audio (from the SCK stream, `excludesCurrentProcessAudio=NO` so call voices are captured) + mic (a separate `AVCaptureSession`, normalized to 48k s16 stereo to match). No gain boost (the old 6x rebuild caused pitch issues — removed). **Corruption fix (2026-06-27):** every `appendSampleBuffer` is guarded on `writer.status==AVAssetWriterStatusWriting` — without it, one rejected audio buffer (the AAC encoder threw OSStatus `-12785` on the SCK system-audio format) flipped the writer to Failed and the OTHER tracks kept appending to a dead writer → `cancelWriting` → MP4 with no moov atom (unplayable). The stop path also surfaces `firstFail`/`asbd` diagnostics to Dart (`_recLog` → `hollow_debug.log`) since native NSLog is invisible over SSH.

**Windows (native):** Calls `hollowWinStartScreenRecord` / `hollowWinStopScreenRecord`. Native Windows.Graphics.Capture + Media Foundation in `packages/flutter_webrtc/windows/win_screen_recorder.cc`. Produces H.264 + AAC MP4 with system audio (WASAPI loopback) + mic (WASAPI capture). Frame rate limited to 30fps (skips frames from high-refresh monitors).

**Linux (ffmpeg):** Spawns `ffmpeg -f x11grab` + PulseAudio. Requires ffmpeg binary.

### Method Channel API

- `hollowMac/WinStartScreenRecord` — args: `{path: String}`, returns: `{capturedSystemAudio: bool}`
- `hollowMac/WinStopScreenRecord` — no args, returns: `bool`

### State

- `isRecording` — true when native or ffmpeg active
- `_nativeRecording` — true for macOS/Windows native path (controls stop method branching)
- `_capturedSystemAudio` — whether system audio was captured
- `isAvailable` — true on macOS/Windows always, true on Linux only if ffmpeg found

### Recording Output

Files saved to `~/Movies/Hollow Recordings` (macOS) or `~/Videos/Hollow Recordings` (Windows/Linux). Filename: `Hollow_YYYY-MM-DD_HH-MM-SS.mp4`.

## RecordingProvider

File: `lib/src/core/providers/recording_provider.dart`

`NotifierProvider<RecordingNotifier, RecordingState>`. Manages recording UI state. Optimistic start (sets `isMyRecording` immediately, rolls back on failure). Tracks `remoteRecording` map for peers who are recording. Toast notifications for remote peer start/stop, recording saved, and errors.

## RecordingIndicator

File: `lib/src/ui/components/recording_indicator.dart`

Pulsing red "REC" dot + elapsed timer. Three constructors: default (full), `.compact` (smaller), `.dotOnly` (just the dot). Uses `FadeTransition` for GPU-composited pulse animation.

## Annotation Overlay

File: `lib/src/ui/annotation/annotation_overlay.dart`

Static class. Creates a Flutter `OverlayEntry` with drawing canvas + toolbar. Manages platform-specific window state.

### Windows Flow

Enter: `windowManager.setSkipTaskbar(true)` → `setAlwaysOnTop(true)` → `setBackgroundColor(transparent)` → `maximize()`. Saves `_wasMaximized` state.

Exit: `setBackgroundColor(dark)` → `setAlwaysOnTop(false)` → `setSkipTaskbar(false)` → `unmaximize()` (only if wasn't maximized before).

**Critical:** Never use raw Win32 window manipulation or `setFullScreen` — fights with `window_manager` and causes squished layouts on restore. Maximize/unmaximize is the only safe approach.

### macOS Flow

Enter: calls `hollowMacEnterAnnotationMode` — reconfigures NSWindow to transparent + borderless + fullscreen + always-on-top.

Exit: calls `hollowMacExitAnnotationMode` — restores all saved NSWindow state.

### Annotation Canvas

File: `lib/src/ui/annotation/annotation_canvas.dart`

`Listener` widget capturing pointer down/move/up. Builds `Stroke` objects and commits to `AnnotationController`. Tools: freehand, line, arrow, eraser. Renders via `AnnotationPainter` (CustomPaint).

### Annotation Controller

File: `lib/src/ui/annotation/annotation_controller.dart`

`ChangeNotifier`. Holds stroke list with undo/redo via history index. Tool, color, width, line style state. Eraser is destructive (removes strokes from list).

### Annotation Toolbar

File: `lib/src/ui/annotation/annotation_toolbar.dart`

Floating dark panel with tool buttons, line style picker, color palette, width slider, undo/redo/clear/close. Uses LucideIcons. `AnimatedOpacity` for disabled state.

### Toggle Button

File: `lib/src/ui/annotation/annotation_toggle_button.dart`

In `WindowTitleBar`. Visible on macOS and Windows only. Hover reveals "Annotate" text label. Uses LucideIcons.pencil.

## WinScreenRecorder (C++)

File: `packages/flutter_webrtc/windows/win_screen_recorder.h/.cc`

Singleton. Rewritten 2026-08-05 (issue #53): video plus **ONE mixed audio track** feeding a Media Foundation Sink Writer:

- **Video:** Windows.Graphics.Capture → D3D11 staging texture → BGRA copy → MF sample → H.264 stream
- **Audio (single 48 kHz stereo AAC track):** WASAPI loopback + WASAPI mic capture each push s16/48k/stereo into a ring (`AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | SRC_DEFAULT_QUALITY` — the OS converts every device format; the old native-format capture fed 44.1k/mono PCM into fixed-format streams → pitched/dead tracks); a timeline mixer thread (60 ms jitter lag) sums with saturation and writes sample-count timestamps. **NEVER two AAC tracks** — mainstream players render only the FIRST audio track, so the old mic-as-track-2 design made recordings miss the recorder's own voice. Zero-fill for absent sources (WASAPI loopback delivers NO packets during silence — waiting on both sources would stall the track).
- **Device selection:** `Start(path, render_device_id, capture_device_id)` — Dart passes Hollow's configured win32audio endpoint ids (`audioOutputDeviceProvider`/`audioInputDeviceProvider`; win32audio ids ARE `IMMDevice::GetId()` strings) so the recorder loopbacks the device remote voices actually play on; falls back to the eConsole defaults (the old always-default behavior recorded silence when the user routed calls to a non-default headset). `WriteSample` failures log once (previously discarded — audio-less files finalized "successfully").

Shared D3D11 device (BGRA support + video support + multithread). QPC-based timestamps. Writer starts lazily on first video frame; the mixer drops buffered audio until then. Frame rate limited to 30fps via QPC interval check. macOS (`MacScreenRecorder.m`) still has the OLD two-track design — fix pending (HOLLOW_PLAN checkbox ~2069). See memory `project_issue53_call_recorder`.

CMake links: `mfplat`, `mfreadwrite`, `mfuuid`, `mf`, `d3d11`, `dxgi`, `windowsapp` (WinRT), `Mmdevapi`, `Avrt`. C++20 + `/await` for C++/WinRT.
