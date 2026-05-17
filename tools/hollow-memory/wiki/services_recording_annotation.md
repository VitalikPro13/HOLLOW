# Recording and Annotation Services

## RecordingService

File: `lib/src/core/services/recording_service.dart`

Singleton (`RecordingService.instance`). Captures the screen + audio to MP4 file. One recording at a time.

### Platform Paths

**macOS (native):** Calls `hollowMacStartScreenRecord` / `hollowMacStopScreenRecord` via `FlutterWebRTC.Method` channel. Native ScreenCaptureKit + AVAssetWriter in `packages/flutter_webrtc/macos/Classes/MacScreenRecorder.m`. Produces H.264 + AAC MP4 with system audio (Process Tap) + mic (AVCaptureSession). Both audio tracks boosted 6x.

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

Singleton. Three concurrent capture sources feeding one Media Foundation Sink Writer:

- **Video:** Windows.Graphics.Capture → D3D11 staging texture → BGRA copy → MF sample → H.264 stream
- **System audio:** WASAPI loopback (default render endpoint) → PCM16 → AAC stream
- **Mic audio:** WASAPI capture (default capture endpoint) → PCM16 → AAC stream

Shared D3D11 device (BGRA support + video support + multithread). QPC-based timestamps. Writer starts lazily on first video frame. Frame rate limited to 30fps via QPC interval check. Graceful degradation: if loopback fails → video+mic only, if mic fails → video+system only.

CMake links: `mfplat`, `mfreadwrite`, `mfuuid`, `mf`, `d3d11`, `dxgi`, `windowsapp` (WinRT), `Mmdevapi`, `Avrt`. C++20 + `/await` for C++/WinRT.
