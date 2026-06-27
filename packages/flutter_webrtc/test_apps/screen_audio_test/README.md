# Screen Audio Test

Standalone test app for WASAPI audio capture + Opus encoding on Windows.
Validates the capture pipeline in isolation before wiring it to WebRTC data channels (Phase 2).

In production this same binary (renamed `screen_audio_capturer` / `.exe`) is the
out-of-process screen-share-audio helper Hollow spawns:

| Mode | Platforms | Role |
|------|-----------|------|
| `--mode pipe` (WASAPI capture → Opus → stdout) | **Windows only** | SENDER (Windows) — feeds the `0x03` data-channel frames |
| `--mode encode` (raw PCM stdin → Opus → stdout) | **Windows, macOS, Linux** | SENDER encode stage — paired with a native PCM capturer |
| `--mode render` (stdin → Opus decode → playback) | **Windows, macOS, Linux** | RECEIVER — plays incoming `0x03` frames |

macOS SEND by OS version (the native capturer differs; encoding is always this binary):
- **macOS 14.2+**: system audio via the native Process Tap → WebRTC audio track (`MacScreenShareAudioTap.m`). Does not use `encode`.
- **macOS 13.0–14.1**: ScreenCaptureKit audio-only (`MacScreenShareAudioCapturer.m`) → PCM to Dart → `--mode encode` → `0x03` data channel.
- **macOS 10.15–12.x**: no system-audio capture API exists; the "Share audio" toggle is locked off in the UI.
- **Linux SEND** (PulseAudio monitor → `--mode encode`) is unimplemented.

### encode mode wire protocol

```
stdin  (PCM in):  [uint16_le pcm_byte_len][...int16 samples, 48kHz stereo interleaved...]
stdout (Opus out):[uint16_le payload_len][uint32_le seq][...opus_bytes...]
```
The encoder re-blocks incoming PCM into 10ms (480-sample/channel) Opus frames.
`--bitrate <bps>` overrides the 128k default (e.g. 256000 for higher fidelity).

The **render** path is cross-platform today: `audio_player_{win,mac,linux}.cpp`
provide waveOut / AudioQueue / PulseAudio-simple playback respectively, so a
Windows sender → macOS/Linux receiver works once the binary is bundled.

## macOS / Linux build & bundle

```
# from the project root — builds a universal (arm64+x86_64) binary on macOS,
# down to deployment target 10.15, and bundles it if a Release build exists.
bash scripts/build_screen_audio.sh
```

Run it **before** `flutter build macos` / `flutter build linux`. On macOS the
Runner has a "Bundle screen audio capturer" run-script phase that copies the
built binary into `Hollow.app/Contents/Resources/screen_audio_capturer`; the
release pipeline (`scripts/macos_resign_and_dmg.sh`) re-signs it with Developer ID.

## What it does

Captures system audio or a specific process's audio via WASAPI loopback, Opus-encodes it in real-time, and writes both a raw PCM `.wav` and an Opus-encoded `.ogg` file.

## Build

Requires Visual Studio 2022 and CMake 3.20+. First build downloads Opus v1.5.2 and libogg v1.3.5 via FetchContent.

```
cd packages/flutter_webrtc/test_apps/screen_audio_test
cmake -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
```

## Usage

```
# Capture all desktop audio for 10 seconds
build\Release\screen_audio_test.exe --mode system --duration 10

# Capture all audio EXCEPT this process (EXCLUDE self)
build\Release\screen_audio_test.exe --mode process --duration 10

# Capture ONLY a specific process's audio (INCLUDE mode)
build\Release\screen_audio_test.exe --mode process --pid 12345 --duration 10

# WAV only (skip Opus encoding)
build\Release\screen_audio_test.exe --mode system --format wav

# Custom output basename
build\Release\screen_audio_test.exe --mode system --output my_capture
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--mode` | `system` | `system` (all desktop audio) or `process` (per-process) |
| `--pid` | self | Target PID for process mode. Omit = EXCLUDE self. Specify = INCLUDE only that process |
| `--duration` | `10` | Capture duration in seconds |
| `--format` | `both` | `wav`, `opus`, or `both` |
| `--output` | `captured_audio` | Output file basename (extensions added automatically) |

### Finding a process PID

```powershell
Get-Process | Where-Object { $_.MainWindowTitle } | Format-Table Id, ProcessName, MainWindowTitle -AutoSize
```

## Capture modes

- **System loopback** (`--mode system`): Captures the default audio render endpoint — everything playing through your speakers/headphones. Uses `WasapiLoopbackCapturer` (same as the screen recorder). Requires audio to be playing.

- **Process EXCLUDE** (`--mode process`, no `--pid`): Captures all system audio EXCEPT this test app's own output. Uses `PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE`. Requires Windows 10 2004+ (build 19041).

- **Process INCLUDE** (`--mode process --pid <PID>`): Captures ONLY the specified process's audio output. Uses `PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE`. Fully isolates one app's audio — no bleed from other processes or microphone.

## Output

- `*.wav` — Raw 48kHz stereo 16-bit PCM. Ground truth for verifying capture quality.
- `*.ogg` — Opus-encoded at 128kbps stereo. Playable in VLC, Chrome, ffmpeg, etc.

## Technical details

- WASAPI loopback at 48kHz stereo 16-bit (matches Opus native rate)
- Process loopback uses `ActivateAudioInterfaceAsync` with `AUTOCONVERTPCM` + `SRC_DEFAULT_QUALITY` for 48kHz
- Opus encoder: `OPUS_APPLICATION_AUDIO`, 128kbps, complexity 10
- OGG container per RFC 7845 (OpusHead + OpusTags + audio pages)
- 10ms frames (480 samples/channel) — direct match between WASAPI callback and Opus frame size
