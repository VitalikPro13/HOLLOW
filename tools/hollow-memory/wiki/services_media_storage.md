# Media, Storage, and Core Services

## VoiceMessageRecorder

File: `lib/src/core/services/voice_message_recorder.dart`

One-shot voice message recorder that captures PCM audio from the microphone and encodes it to Opus via the bundled ffmpeg. Used by `lib/src/ui/chat/voice_recorder_bar.dart`.

### Why ffmpeg instead of native Opus

Windows' Media Foundation (which `record_windows` wraps) does not ship an Opus MFT. Calling `record`'s native Opus encoder on Windows throws "Not implemented". The recorder captures raw PCM16LE via the `record` package and pipes it through the bundled ffmpeg (libopus) which works identically on every desktop platform.

### Encoding profile

- **Input:** PCM16LE, 16 kHz mono (captured via `rec.AudioRecorder.startStream()` with `rec.AudioEncoder.pcm16bits`)
- **Output:** Opus in Ogg container, 16 kHz mono, 24 kbps VBR, `voip` application mode
- **Size:** ~90 KB per 30 seconds of speech
- **Output path:** `%APPDATA%/Hollow/temp/voice_{timestamp}_{random}.ogg` (or `$HOME/Hollow/temp/` on non-Windows)

### Constants

- `_sampleRate = 16000` (16 kHz)
- `_bitRateKbps = 24`
- `_ampInterval = Duration(milliseconds: 100)` (amplitude and elapsed sampling rate)

### Recording lifecycle

**start({String? preferredDeviceId})**

1. Checks microphone permission via `_recorder.hasPermission()`. Throws `RecorderPermissionException` if denied.
2. Locates bundled ffmpeg via `VideoThumbnailService.findFfmpegBinary()`. Throws `RecorderFfmpegMissingException` if not found.
3. Generates a temp output path via `_buildTempPath()`.
4. Spawns ffmpeg as a child process reading raw PCM16LE from stdin and encoding libopus to the `.ogg` output file. Args: `-f s16le -ar 16000 -ac 1 -i pipe:0 -c:a libopus -b:a 24k -vbr on -application voip -y <outPath>`.
5. Sets up a `Completer<int>` for ffmpeg exit code tracking.
6. Pipes ffmpeg stderr to `_stderrBuf` (StringBuffer) for error logging. Drains stdout to prevent pipe blocking.
7. Starts PCM capture via `_recorder.startStream()` with the configured `RecordConfig`. If `preferredDeviceId` is provided and non-empty, it is passed as an `InputDevice`.
8. Forwards PCM chunks from the recorder stream directly to ffmpeg's stdin.
9. Starts amplitude monitoring via `_recorder.onAmplitudeChanged(_ampInterval)` -- normalizes dB values from range [-60, 0] to [0.0, 1.0] and emits on the `amplitudes` stream.
10. Starts an elapsed timer (100ms periodic) that emits wall-clock duration on the `elapsed` stream.

**stop() -> VoiceRecordingResult?**

1. Captures the recording duration from wall-clock difference since `_startedAt`.
2. Calls `_teardownCapture()` to cancel PCM subscription, amplitude subscription, elapsed timer, and stop the recorder.
3. Flushes and closes ffmpeg stdin so the encoder writes the final frames and exits.
4. Awaits ffmpeg exit code with a 10-second timeout (kills the process on timeout, returns -1).
5. On non-zero exit or missing output, logs stderr and deletes the partial file. Returns null.
6. Verifies the output file exists and is non-empty. Returns a `VoiceRecordingResult(filePath, duration)`.

**cancel()**

1. Calls `_teardownCapture()`.
2. Closes ffmpeg stdin, kills the process, awaits exit with 3-second timeout.
3. Deletes the partial output file if it exists.

**dispose()**

Sets `_disposed = true`, tears down capture, kills ffmpeg if still running, disposes the `AudioRecorder`, and closes both stream controllers (`_ampController`, `_elapsedController`).

### Public state

- `hasStarted` (bool) -- whether capture actually began (widget uses this to decide between stop vs cancel)
- `amplitudes` (Stream<double>) -- 0.0-1.0 mic level, sampled every 100ms
- `elapsed` (Stream<Duration>) -- recording duration, ticked every 100ms

### Result type

`VoiceRecordingResult` contains `filePath` (String) and `duration` (Duration).

### Exception types

- `RecorderPermissionException` -- microphone permission denied
- `RecorderFfmpegMissingException` -- bundled ffmpeg binary not found

---

## AudioTranscodeService

File: `lib/src/core/services/audio_transcode_service.dart`

Static-only service that transcodes Ogg/Opus audio files to PCM WAV for playback on Windows. Used by `lib/src/ui/chat/audio_message_bubble.dart`.

### Problem

Windows' Media Foundation (which `audioplayers_windows` wraps) cannot decode Opus-in-Ogg. On Linux (GStreamer) and macOS (AVFoundation), Ogg/Opus plays natively.

### Solution

Transcode Opus files to cached PCM WAV via the bundled ffmpeg before handing them to the audio player. The wire format stays Opus; only local playback uses the cached WAV.

### API

**`ensurePlayable(String inputPath) -> Future<String?>`**

1. Extracts the file extension from `inputPath`.
2. Short-circuits and returns `inputPath` unchanged if: (a) not on Windows, or (b) the extension is not in `_needsTranscode` (`{'ogg', 'opus'}`).
3. Locates ffmpeg via `VideoThumbnailService.findFfmpegBinary()`. Returns null if not found.
4. Checks if the input file exists. Returns null if not.
5. Computes a deterministic cache path via `_cachePathFor()` based on input path + file modification time.
6. If the cache file already exists and is non-empty, returns the cached path (cache hit).
7. Runs ffmpeg synchronously: `-y -i <input> -c:a pcm_s16le -ar 16000 -ac 1 <cachePath>`. This produces a 16 kHz mono PCM16LE WAV file.
8. On non-zero exit code, logs the error, deletes the partial cache file, returns null.
9. Returns the cache path on success.

### Cache strategy

- **Location:** `%APPDATA%/Hollow/audio_cache/` (or `$HOME/Hollow/audio_cache/`)
- **Key:** Non-crypto hash (multiply-and-add, mod `0x1fffffff`) of `"<inputPath>|<mtime_epoch_ms>"`. Re-downloads with different mtimes invalidate the cache automatically.
- **Filename pattern:** `{hash_hex8}_{mtime_hex}.wav`
- **No eviction policy** -- WAV files accumulate until manually cleaned.

---

## AudioProbeService

File: `lib/src/core/services/audio_probe_service.dart`

Static-only service that extracts audio duration metadata using the bundled ffmpeg. Used by `lib/src/ui/chat/audio_message_bubble.dart`.

### API

**`probeDurationMs(String audioPath) -> Future<int?>`**

1. Checks the in-memory cache (`_cache` -- static `Map<String, int>`). Returns immediately if cached.
2. Locates ffmpeg via `VideoThumbnailService.findFfmpegBinary()`. Returns null if not found.
3. Checks that the file exists synchronously (`existsSync()`). Returns null if not.
4. Runs ffmpeg: `-i <audioPath> -f null -`. This triggers format detection and probe without producing output. Uses `stdoutEncoding: null, stderrEncoding: null` for raw byte capture.
5. 5-second timeout. On timeout, logs and returns null.
6. Parses duration from ffmpeg stderr via `_parseDuration()`.
7. Caches and returns the result in milliseconds. Returns null if duration is zero or unparseable.

### Duration parsing

`_parseDuration(String stderr)` uses regex `Duration:\s*(\d+):(\d+):(\d+)\.(\d+)` to extract HH:MM:SS.cs from ffmpeg's stderr probe output. Handles variable centisecond digit counts (2 digits = centiseconds x10 for ms, 3 digits = direct ms, other lengths = proportional conversion via `_pow10()`).

### Caching

Static `Map<String, int>` keyed by file path. No eviction. Results persist for the lifetime of the process. Repeated widget rebuilds do not re-probe.

### Logging

Uses `network_api.logFromDart()` to write to `hollow_debug.log` (visible in release builds).

---

## VideoStreamServer

File: `lib/src/core/services/video_stream_server.dart`

Local HTTP server that enables progressive video playback during file downloads. The video player (fvp) connects to this server via a `http://127.0.0.1:<port>/video` URI, enabling playback before the full file has been downloaded.

Managed by `lib/src/core/providers/video_stream_provider.dart` via the `VideoStreamNotifier` and `videoStreamProvider` Riverpod provider.

### Architecture

The server binds to the IPv4 loopback address on a random available port (`HttpServer.bind(InternetAddress.loopbackIPv4, 0)`). It opens the target file via `RandomAccessFile` and serves byte ranges on demand.

### State

- `_server` (HttpServer?) -- the bound HTTP server instance
- `_raf` (RandomAccessFile?) -- handle to the video file being served
- `_availableBytes` (int) -- how many bytes of the file are currently available on disk (updated as chunks arrive)
- `_totalSize` (int) -- the final expected total size of the file
- `_mimeType` (String) -- MIME type for response headers, defaults to `'video/mp4'`

### API

**`start(String filePath, int totalSize, String mimeType) -> Future<Uri>`**

1. Calls `stop()` to clean up any existing server.
2. Sets `_totalSize` and `_mimeType`.
3. Opens the file as a `RandomAccessFile` for reading.
4. Reads current file length as initial `_availableBytes`.
5. Binds `HttpServer` to loopback on port 0 (OS-assigned).
6. Returns `http://127.0.0.1:<port>/video`.

**`updateAvailableBytes(int bytes)`** -- called by `VideoStreamNotifier.updateProgress()` as download chunks arrive, so the server knows how far it can seek.

**`stop()`** -- force-closes the HTTP server, closes the `RandomAccessFile`, resets all state to zero.

**`uri`** (getter) -- returns the server URI if running, null otherwise.

### Range request handling

`_handleRequest(HttpRequest request)`:

1. If `_raf` is null, returns 503 Service Unavailable.
2. **No Range header:** If the full file is available (`_availableBytes >= _totalSize`), serves bytes 0 to `_totalSize - 1`. If partially available, serves bytes 0 to `_availableBytes - 1`. If nothing available, returns 503 with `Retry-After: 1`.
3. **With Range header:** Parses `bytes=(\d+)-(\d*)` regex. If `start >= _availableBytes`, returns 503 with `Retry-After: 1` (data not yet downloaded). Clamps `end` to `_availableBytes - 1` if it exceeds available data.

`_serveRange(request, raf, start, end, totalSize)`:

1. Sets response status to 206 Partial Content.
2. Sets headers: `Content-Type` (the stored MIME type), `Content-Length`, `Accept-Ranges: bytes`, `Content-Range: bytes start-end/totalSize`.
3. Seeks `RandomAccessFile` to `start`.
4. Reads and writes in 64 KB chunks (`chunkSize = 65536`) until the requested range is fully served.
5. Catches and logs errors during serving, best-effort closes response.

### Provider integration

`VideoStreamNotifier` (in `video_stream_provider.dart`) wraps `VideoStreamServer`:

- `startStream()` -- stops any previous server, starts a new one, creates `VideoStreamState` with the server URI and root hash.
- `updateProgress(rootHash, chunksHave, chunksTotal, chunkSize)` -- computes available bytes from chunk count and updates both the server and provider state. Only updates if `rootHash` matches current state.
- `markCompleted(rootHash)` -- sets available bytes to total size and marks `completed = true`.
- `stopStream()` -- stops the server and clears state.

---

## VideoThumbnailService

File: `lib/src/core/services/video_thumbnail_service.dart`

Static-only service that extracts first-frame thumbnails from video files using the bundled ffmpeg binary, encoding them as lossless WebP. Also provides the shared `findFfmpegBinary()` used by VoiceMessageRecorder, AudioTranscodeService, and AudioProbeService.

### ffmpeg binary location

**`findFfmpegBinary() -> String?`** (static, cached after first call via `_cachedFfmpegPath` / `_searchedForFfmpeg`)

1. Resolves the directory containing the running executable (`Platform.resolvedExecutable`).
2. Checks for `ffmpeg.exe` (Windows) or `ffmpeg` (other platforms) in that directory.
3. On macOS, also checks `Contents/MacOS/ffmpeg` as a fallback (`.app` bundle structure).
4. Returns the absolute path if found, null otherwise.
5. Logs the result via `network_api.logFromDart()`.

**`isAvailable`** (static getter) -- returns `findFfmpegBinary() != null`.

### Thumbnail cache

- **Location:** `~/.hollow/files/{basename}.thumb.webp` (or `$HOLLOW_DATA_DIR/files/` if env var set)
- **`thumbCachePathFor(String videoPath) -> String?`** -- computes the canonical cache path: strips the video's extension, appends `.thumb.webp`, places in `~/.hollow/files/`.
- **`cachedThumbFor(String videoPath) -> String?`** -- synchronous check: returns cache path if file exists on disk, null otherwise. Safe to call from `build()`.
- **`_hollowFilesDir()`** -- resolves `~/.hollow/files/` from `USERPROFILE` or `HOME`, creates the directory if needed.

### Thumbnail extraction

**`ensureCachedThumb(String videoPath) -> Future<String?>`**

1. Computes cache path. Returns null if unable.
2. If cache file already exists, returns the path immediately (no re-extraction).
3. If source video doesn't exist, returns null.
4. Calls `extractVideoThumbnail()`.
5. Writes the resulting WebP bytes to the cache path with `flush: true`.

**`extractVideoThumbnail({required String videoPath, int targetHeight = 480}) -> Future<VideoThumbnailResult?>`**

1. Locates ffmpeg. Returns null if missing.
2. Verifies source video exists.
3. Creates a system temp directory (`hollow_thumb_` prefix).
4. Runs ffmpeg with args:
   - `-y` overwrite output
   - `-ss 00:00:00.5` seek 0.5s (avoids black first frames)
   - `-i <videoPath>` input
   - `-vf scale=-2:<targetHeight>` scale to target height, auto-width (even number)
   - `-frames:v 1` one frame only
   - `-c:v libwebp -lossless 1 -compression_level 6 -pred mixed` lossless WebP with max compression
5. 10-second timeout. On timeout, logs and returns null.
6. On non-zero exit, logs truncated stderr (first 500 chars) and returns null.
7. Reads the output WebP file. Returns null if empty or missing.
8. Parses ffmpeg stderr for source video metadata (duration, dimensions) via `_parseFfmpegStderr()`.
9. Returns `VideoThumbnailResult(webpBytes, durationMs, sourceWidth, sourceHeight)`.
10. Cleans up the temp directory in `finally` block.

### ffmpeg stderr parsing

**`_parseFfmpegStderr(String stderr) -> _ParsedProbe`**

Extracts two pieces of metadata from ffmpeg's stderr probe output:

1. **Duration:** Regex `Duration:\s*(\d+):(\d+):(\d+)\.(\d+)` parses HH:MM:SS.cs. Handles variable fractional digit counts (2 digits = centiseconds, 3 = milliseconds, other = proportional via `_pow10()`).
2. **Dimensions:** Regex `Stream #\d+:\d+.*?: Video:.*?(\d{2,5})x(\d{2,5})` captures the first video stream's WxH resolution.

### Result type

`VideoThumbnailResult` contains:
- `webpBytes` (Uint8List) -- the lossless WebP thumbnail image bytes
- `durationMs` (int) -- source video duration in milliseconds
- `sourceWidth` (int) -- source video width in pixels (NOT the thumbnail width)
- `sourceHeight` (int) -- source video height in pixels

---

## NetworkService

File: `lib/src/core/services/network_service.dart`

Thin Dart wrapper around the FFI network layer (`lib/src/rust/api/network.dart`). Exists for testability -- all calls are 1:1 pass-throughs to the generated `flutter_rust_bridge` FFI bindings.

Registered as a singleton Riverpod provider in `lib/src/core/providers/service_providers.dart`:
```
final networkServiceProvider = Provider<NetworkService>((_) => NetworkService());
```

### Methods

All methods directly delegate to `ffi.*` (the auto-generated FFI module `lib/src/rust/api/network.dart`):

| Method | FFI Target | Purpose |
|--------|-----------|---------|
| `startNode()` | `ffi.startNode()` | Starts the Rust networking node, returns local peer ID |
| `pollNetworkEvent()` | `ffi.pollNetworkEvent()` | Polls for a single network event (nullable) |
| `watchNetworkEvents()` | `ffi.watchNetworkEvents()` | Returns a Stream<NetworkEvent> (Rust StreamSink bridge) |
| `getLocalPeerId()` | `ffi.getLocalPeerId()` | Returns the local peer ID string (nullable) |
| `getOlmFingerprint()` | `ffi.getOlmFingerprint()` | Returns the Olm identity fingerprint (nullable) |
| `sendMessage(...)` | `ffi.sendMessage(...)` | Sends a DM. Params: `peerId`, `text`, `messageId`, optional `replyToMid`, optional `linkPreview` (LinkPreviewRef) |
| `sendChannelMessage(...)` | `ffi.sendChannelMessage(...)` | Sends a server channel message. Params: `serverId`, `channelId`, `text`, `messageId`, optional `replyToMid`, optional `linkPreview` |
| `joinRoom(roomCode:)` | `ffi.joinRoom(roomCode:)` | Joins a WebSocket relay room |
| `stopNode()` | `ffi.stopNode()` | Shuts down the Rust networking node |

### Command dispatch pattern

The Dart UI layer calls `NetworkService` methods which invoke generated FFI functions. These FFI functions send commands to the Rust event loop in `rust/hollow_core/src/node/swarm.rs` via `NodeCommand` variants dispatched through an `mpsc` channel. The Rust side processes commands in its main select loop, calling into domain-specific handler modules (`crypto_handler`, `sync_handler`, `message_ops`, etc.).

---

## StorageService

File: `lib/src/core/services/storage_service.dart`

Thin Dart wrapper around the FFI storage layer (`lib/src/rust/api/storage.dart`). Provides message persistence via the SQLCipher-encrypted database.

Registered as a singleton Riverpod provider in `lib/src/core/providers/service_providers.dart`:
```
final storageServiceProvider = Provider<StorageService>((_) => StorageService());
```

### Methods

All methods directly delegate to `ffi.*` (the auto-generated FFI module `lib/src/rust/api/storage.dart`):

| Method | FFI Target | Purpose |
|--------|-----------|---------|
| `openMessageStore()` | `ffi.openMessageStore()` | Opens/initializes the SQLCipher database |
| `saveMessage(...)` | `ffi.saveMessage(...)` | Saves a DM. Params: `peerId`, `text`, `isMine`, `timestamp` (PlatformInt64), optional `signature`, optional `publicKey`. Returns row ID (PlatformInt64) |
| `loadMessages(peerId:, limit:)` | `ffi.loadMessages(...)` | Loads DMs for a peer, returns `List<StoredMessage>` |
| `saveChannelMessage(...)` | `ffi.saveChannelMessage(...)` | Saves a server channel message. Params: `serverId`, `channelId`, `senderId`, `text`, `isMine`, `timestamp`, optional `signature`, optional `publicKey`. Returns row ID |
| `loadChannelMessages(serverId:, channelId:, limit:)` | `ffi.loadChannelMessages(...)` | Loads channel messages, returns `List<StoredChannelMessage>` |

### Database initialization

`openMessageStore()` is called during app startup. The Rust side opens (or creates) the SQLCipher database file, runs schema migrations, and makes the connection available for subsequent read/write calls. The encryption key is derived from the user's identity.

### Settings KV store

The settings key-value store is accessed directly via FFI functions (e.g., `set_license_key()`, `get_license_key()`) rather than through `StorageService`. `StorageService` specifically wraps message persistence operations.

---

## IdentityService

File: `lib/src/core/services/identity_service.dart`

Thin Dart wrapper around the FFI identity layer (`lib/src/rust/api/identity.dart`). Manages Ed25519 keypair lifecycle.

Registered as a singleton Riverpod provider in `lib/src/core/providers/service_providers.dart`:
```
final identityServiceProvider = Provider<IdentityService>((_) => IdentityService());
```

### Methods

| Method | FFI Target | Purpose |
|--------|-----------|---------|
| `loadOrCreateIdentity()` | `ffi.loadOrCreateIdentity()` | Loads existing keypair from disk or generates a new one. Returns `IdentityInfo` |
| `generateNewIdentity()` | `ffi.generateNewIdentity()` | Forces creation of a fresh Ed25519 keypair + BIP-39 mnemonic. Returns `IdentityInfo` |
| `restoreIdentityFromMnemonic(phrase:)` | `ffi.restoreIdentityFromMnemonic(phrase:)` | Restores a keypair from a BIP-39 mnemonic phrase. Returns `IdentityInfo` |

### Identity flow

1. On first launch, `loadOrCreateIdentity()` finds no existing keypair on disk and generates one (Ed25519 via ed25519-dalek, derived from a BIP-39 mnemonic).
2. The returned `IdentityInfo` (from the Rust `identity` module) contains the peer ID (public key hex), the mnemonic phrase (for backup), and the Olm fingerprint.
3. On subsequent launches, `loadOrCreateIdentity()` loads the persisted keypair from disk.
4. The user can explicitly generate a new identity via `generateNewIdentity()` or restore from backup via `restoreIdentityFromMnemonic()`.
5. The identity is coordinated with `IdentityProvider` on the Dart side which exposes the `IdentityInfo` to the UI via Riverpod.

---

## SharedTickers

File: `lib/src/core/shared_tickers.dart`

Singleton that provides centralized animation tickers shared across the entire app. Instead of each animated widget spawning its own `AnimationController` + `Ticker`, all decorative animations read from shared `ValueNotifier`s driven by a single `Ticker` (plus one low-framerate `Timer` for ambient).

Used by: `SelectionShimmer`, `StatusDot`, `TypingDots`, `AmbientBackground`, and various divider/glow effects throughout the shell and panels.

### Initialization

Called once in `main()`: `SharedTickers.instance.start()`. Registers as a `WidgetsBindingObserver` for app lifecycle events.

### Shared ValueNotifiers

| Notifier | Cycle | Shape | Used By |
|----------|-------|-------|---------|
| `shimmer` | 4s (`_shimmerCycleUs = 4000000`) | Linear 0.0 -> 1.0, repeating | SelectionShimmer, _ShimmerDivider, _SectionDivider glow |
| `pulse` | 6s total / 3s per direction (`_pulseCycleUs = 6000000`) | Ping-pong 0 -> 1 -> 0 with `Curves.easeInOut` | StatusDot breathing glow |
| `typingDots` | 1.2s (`_typingCycleUs = 1200000`) | Linear 0.0 -> 1.0, repeating | TypingDots indicator |
| `ambient` | 45s (`_ambientCycleUs = 45000000`) | Linear 0.0 -> 1.0, repeating, ~15fps | AmbientBackground drift |

### Tick implementation

**Main ticker** (`_ticker: Ticker`): Drives `shimmer`, `pulse`, and `typingDots` at full framerate (vsync). The `_onTick(Duration elapsed)` callback computes each value from `elapsed.inMicroseconds` modulo the cycle duration.

- **Shimmer:** `(us % 4000000) / 4000000` -- straight linear ramp.
- **Pulse:** Two-step transform: (1) linear ping-pong via `pulseLinear < 0.5 ? pulseLinear * 2.0 : 2.0 - pulseLinear * 2.0`, then (2) `Curves.easeInOut.transform()` for smooth breathing.
- **TypingDots:** `(us % 1200000) / 1200000` -- straight linear ramp.

**Ambient timer** (`_ambientTimer: Timer`): Runs at ~15fps (67ms interval) to save CPU for the slow 45-second ambient background cycle. Uses a manual `Stopwatch` since `Timer.periodic` doesn't provide elapsed time.

### Pause/Resume

**`pause()`:** Stops the `Ticker`, cancels the ambient `Timer`, stops the ambient `Stopwatch`. Called when the window is hidden, minimized, or unfocused.

**`resume()`:** Disposes the old `Ticker` (Tickers cannot restart once stopped), creates a new one, restarts the ambient stopwatch and timer. No-ops if `disabled` is true.

### Disable flag

`disabled` (bool): When true, `start()` and `resume()` are no-ops. All decorative animations stay frozen. Set before `start()` on app launch or toggled at runtime from the "Disable Animations" user setting.

### App lifecycle integration

Implements `WidgetsBindingObserver.didChangeAppLifecycleState()`:

| State | Action |
|-------|--------|
| `paused`, `hidden`, `detached` | `pause()` -- stop all tickers |
| `resumed` | `resume()` -- restart all tickers |
| `inactive` | No-op -- keep running during dialog overlays / focus loss |

### Widget consumption pattern

Widgets use `ValueListenableBuilder<double>` to listen to a specific notifier:

```dart
ValueListenableBuilder<double>(
  valueListenable: SharedTickers.instance.shimmer,
  builder: (_, value, child) => /* use value 0.0-1.0 */,
);
```

This ensures only the widget subtree that depends on the animation value rebuilds, and all widgets sharing the same animation type are driven by a single underlying ticker rather than N independent ones.
