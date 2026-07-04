import 'dart:async';
import 'dart:io';
// Prefixed alias so the top-level `pid` getter (this process's PID) is reachable
// inside start(), where the `pid` parameter would otherwise shadow it.
import 'dart:io' as io;
import 'dart:typed_data';

import '../../rust/api/network.dart' as network_api;

void _log(String msg) {
  network_api.logFromDart(message: msg);
}

/// Out-of-process screen audio capturer for Windows and Linux.
///
/// Spawns `screen_audio_capturer --mode pipe` as a child process.
/// The exe captures the system output (Windows: WASAPI loopback, per-app
/// capable; Linux: the default sink's PulseAudio/PipeWire monitor source,
/// whole-mix only) → Opus encodes → writes framed binary packets to stdout.
/// This process reads them and calls [onPacket].
///
/// Running in a separate process avoids libwebrtc's AudioDeviceModule
/// interfering with the WASAPI capture (causes audio looping).
///
/// Wire protocol (stdout, binary):
///   [uint16_le: payload_len][uint32_le: seq][...opus_bytes...]
///
/// Stop signal: write 'Q' to the process's stdin, or just kill it.
class ScreenAudioCapturer {
  Process? _process;
  StreamSubscription? _stdoutSub;
  bool _active = false;
  int _packetCount = 0;

  /// Residual bytes from the previous stdout chunk that didn't form a
  /// complete frame. The wire protocol frames can be split across OS pipe
  /// buffer boundaries.
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  bool get isActive => _active;

  /// Locate the bundled exe next to the Flutter app executable.
  static String? _findExePath() {
    final appDir = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    final ext = Platform.isWindows ? '.exe' : '';
    _log('[SCREEN-AUDIO] App dir: $appDir');

    final candidates = <String>[
      '$appDir${sep}screen_audio_capturer$ext',
      '$appDir${sep}screen_audio_test$ext',
      // Dev fallback (Windows builds under Release/, Linux at the build root)
      if (Platform.isWindows)
        '$appDir$sep..${sep}..${sep}..${sep}..${sep}..${sep}packages'
        '${sep}flutter_webrtc${sep}test_apps${sep}screen_audio_test'
        '${sep}build${sep}Release${sep}screen_audio_test.exe'
      else
        '$appDir$sep..${sep}..${sep}..${sep}..${sep}..${sep}packages'
        '${sep}flutter_webrtc${sep}test_apps${sep}screen_audio_test'
        '${sep}build${sep}screen_audio_test',
    ];

    for (final path in candidates) {
      final exists = File(path).existsSync();
      _log('[SCREEN-AUDIO] Checking: $path -> ${exists ? "FOUND" : "not found"}');
      if (exists) return path;
    }

    _log('[SCREEN-AUDIO] No capturer binary found in any location');
    return null;
  }

  /// Start capturing audio. Opus packets are delivered via [onPacket].
  /// Each packet is `[uint32_le: seq][...opus_bytes...]` — ready to send
  /// over the data channel with the 0x03 type prefix.
  ///
  /// For a WINDOW share, [windowHwnd] is the window's HWND (the desktop source
  /// `id`): the exe resolves HWND -> owning pid -> the app's audio-rendering
  /// pids (the browser/Electron audio-service child process etc.), INCLUDE-
  /// captures that set and mixes — so only that app's audio is sent, and a
  /// silent app sends silence (NOT the whole system). This is preferred over
  /// [pid] because libwebrtc does not reliably populate a window pid (it arrives
  /// as 0). Requires Windows 10 2004+.
  ///
  /// [pid] is an alternative per-app target when a window pid is already known.
  ///
  /// If NEITHER is set (sharing the whole screen) captures system-wide, but
  /// EXCLUDES a process TREE so the call playback isn't re-captured and echoed
  /// back to the remote peer (the Windows equivalent of the macOS share path's
  /// excludesCurrentProcessAudio). By default the excluded tree is THIS process
  /// (hollow.exe). When [excludePid] is given (the out-of-process voice-render
  /// child's pid), that tree is excluded INSTEAD — the child is a descendant of
  /// hollow.exe, so excluding it drops only the call voices it plays while
  /// hollow.exe's own in-app media is still captured (Bug B). The exe falls back
  /// to plain system loopback if EXCLUDE capture is unavailable (Windows < 2004).
  Future<bool> start({
    int pid = 0,
    int windowHwnd = 0,
    int excludePid = 0,
    required void Function(Uint8List packet) onPacket,
  }) async {
    if (_active) return true;

    final exePath = _findExePath();
    if (exePath == null) {
      _log('[SCREEN-AUDIO] ERROR: screen_audio_capturer.exe not found');
      return false;
    }

    final args = ['--mode', 'pipe', '--duration', '0'];
    if (!Platform.isWindows) {
      // Linux: the exe captures the default sink's monitor source — no per-app
      // or exclude-tree capture, so the pid/hwnd/exclude flags don't apply.
    } else if (windowHwnd != 0) {
      // Per-app (window) share: hand the window HANDLE to the exe, which resolves
      // it to the owning pid then the real audio-rendering pid set (browser audio
      // service etc.) and INCLUDE-captures + mixes that set.
      args.addAll(['--window-hwnd', windowHwnd.toString()]);
    } else if (pid != 0) {
      // Per-app share with a known pid.
      args.addAll(['--window-pid', pid.toString()]);
    } else {
      // Whole-screen share: capture everything EXCLUDING one process tree. When a
      // voice-render child exists, exclude IT (drops only the call voices it
      // plays, keeps hollow.exe's media); otherwise exclude ourselves (legacy —
      // also drops Hollow's own media, but no voices are out-of-process to keep).
      final excludeTarget = excludePid != 0 ? excludePid : io.pid;
      args.addAll(['--exclude-pid', excludeTarget.toString()]);
    }

    _log('[SCREEN-AUDIO] Spawning: $exePath ${args.join(' ')}');

    try {
      _process = await Process.start(
        exePath,
        args,
        mode: ProcessStartMode.normal,
      );
    } on ProcessException catch (e) {
      _log('[SCREEN-AUDIO] ProcessException: ${e.message} '
          '(errorCode=${e.errorCode}, exe=$exePath)');
      return false;
    } catch (e) {
      _log('[SCREEN-AUDIO] Failed to spawn process: $e');
      return false;
    }

    _active = true;

    // Log stderr (diagnostics from the exe).
    _process!.stderr.transform(const SystemEncoding().decoder).listen((line) {
      // Trim trailing newlines for cleaner log output.
      for (final l in line.split('\n')) {
        final trimmed = l.trim();
        if (trimmed.isNotEmpty) {
          _log('[SCREEN-AUDIO-EXE] $trimmed');
        }
      }
    });

    // Read framed binary packets from stdout.
    _packetCount = 0;
    _stdoutSub = _process!.stdout.listen((List<int> chunk) {
      _buffer.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
      _drainFrames(onPacket);
    }, onDone: () {
      _log('[SCREEN-AUDIO] Process stdout closed');
      _active = false;
    }, onError: (e) {
      _log('[SCREEN-AUDIO] stdout error: $e');
    });

    // Monitor process exit.
    _process!.exitCode.then((code) {
      _log('[SCREEN-AUDIO] Process exited with code $code');
      _active = false;
    });

    _log('[SCREEN-AUDIO] Capture started (PID ${_process!.pid})');
    return true;
  }

  /// Parse complete frames from the buffer and deliver them.
  void _drainFrames(void Function(Uint8List) onPacket) {
    final bytes = _buffer.takeBytes();
    int offset = 0;

    while (offset + 2 <= bytes.length) {
      // Read payload length (uint16_le).
      final payloadLen = bytes[offset] | (bytes[offset + 1] << 8);
      final frameLen = 2 + payloadLen;

      if (offset + frameLen > bytes.length) {
        // Incomplete frame — put remainder back in buffer.
        break;
      }

      // Extract the payload: [seq_u32_le][opus_bytes...]
      // This is exactly what the data channel expects.
      final packet = Uint8List.sublistView(bytes, offset + 2, offset + frameLen);
      onPacket(packet);

      _packetCount++;
      if (_packetCount <= 5 || _packetCount % 500 == 0) {
        _log('[SCREEN-AUDIO] RX packet #$_packetCount (${packet.length} bytes)');
      }

      offset += frameLen;
    }

    // Put any remaining incomplete bytes back.
    if (offset < bytes.length) {
      _buffer.add(Uint8List.sublistView(bytes, offset));
    }
  }

  /// Stop capturing. Sends 'Q' to the process stdin, then kills if needed.
  Future<void> stop() async {
    if (!_active && _process == null) return;
    _active = false;

    _log('[SCREEN-AUDIO] Stopping capture...');

    // Signal graceful shutdown.
    try {
      _process?.stdin.add(Uint8List.fromList([0x51])); // 'Q'
      await _process?.stdin.flush();
    } catch (_) {}

    // Give it a moment to exit cleanly.
    bool exited = false;
    try {
      final code = await _process?.exitCode.timeout(
        const Duration(seconds: 2),
      );
      exited = true;
      _log('[SCREEN-AUDIO] Process exited cleanly with code $code');
    } catch (_) {}

    if (!exited) {
      _log('[SCREEN-AUDIO] Force killing process');
      _process?.kill();
    }

    await _stdoutSub?.cancel();
    _stdoutSub = null;
    _process = null;
    _buffer.clear();

    _log('[SCREEN-AUDIO] Stopped');
  }
}
