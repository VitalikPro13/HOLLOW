import 'dart:async';
import 'dart:io';
// Prefixed alias so start()'s `pid` parameter cannot shadow the top-level one.
import 'dart:io' as io;
import 'dart:typed_data';

import '../../rust/api/network.dart' as network_api;

void _log(String msg) {
  network_api.logFromDart(message: msg);
}

/// Out-of-process screen audio capturer for Windows and Linux.
///
/// A separate process because libwebrtc's AudioDeviceModule interferes with
/// the WASAPI capture in-process and the audio loops. The child Opus-encodes
/// and writes framed packets to stdout, `[uint16_le len][uint32_le seq][opus]`;
/// writing 'Q' to its stdin stops it.
class ScreenAudioCapturer {
  Process? _process;
  StreamSubscription? _stdoutSub;
  bool _active = false;
  int _packetCount = 0;

  /// Residual bytes from the previous stdout chunk: a frame can be split
  /// across an OS pipe buffer boundary.
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

  /// Starts capturing. Opus packets reach [onPacket] as
  /// `[uint32_le seq][opus]`, ready for the data channel behind its 0x03
  /// prefix.
  ///
  /// A WINDOW share passes [windowHwnd] (the desktop source `id`), never
  /// [pid]: libwebrtc does not reliably populate a window pid. The exe
  /// resolves it to the app's audio-rendering pids and INCLUDE-captures that
  /// set, so a silent app sends silence and never the system mix. Windows
  /// 10 2004+.
  ///
  /// With neither set (whole screen) it captures system-wide EXCLUDING one
  /// process tree, so call playback is not re-captured and echoed back to the
  /// peer: [excludePid]'s tree, the out-of-process voice-render child, when
  /// given, otherwise our own. Plain loopback below Windows 2004.
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
      // Linux mirrors the Windows model through per-sink-input capture: a
      // window share resolves the X11 window id to a pid and INCLUDE-captures
      // its tree (an unresolvable app sends silence, never the system mix),
      // entire-screen captures everything except Hollow's own tree.
      if (windowHwnd != 0) {
        args.addAll(['--window-xid', windowHwnd.toString()]);
      } else if (pid != 0) {
        args.addAll(['--window-pid', pid.toString()]);
      } else {
        final excludeTarget = excludePid != 0 ? excludePid : io.pid;
        args.addAll(['--exclude-pid', excludeTarget.toString()]);
      }
    } else if (windowHwnd != 0) {
      // The exe resolves the window HANDLE to the owning pid, then to the
      // real audio-rendering pid set, and INCLUDE-captures that.
      args.addAll(['--window-hwnd', windowHwnd.toString()]);
    } else if (pid != 0) {
      args.addAll(['--window-pid', pid.toString()]);
    } else {
      // Exclude the voice-render child's tree when there is one, which drops
      // only the call voices it plays; otherwise exclude ourselves.
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

    _process!.stderr.transform(const SystemEncoding().decoder).listen((line) {
      for (final l in line.split('\n')) {
        final trimmed = l.trim();
        if (trimmed.isNotEmpty) {
          _log('[SCREEN-AUDIO-EXE] $trimmed');
        }
      }
    });

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

    _process!.exitCode.then((code) {
      _log('[SCREEN-AUDIO] Process exited with code $code');
      _active = false;
    });

    _log('[SCREEN-AUDIO] Capture started (PID ${_process!.pid})');
    return true;
  }

  void _drainFrames(void Function(Uint8List) onPacket) {
    final bytes = _buffer.takeBytes();
    int offset = 0;

    while (offset + 2 <= bytes.length) {
      final payloadLen = bytes[offset] | (bytes[offset + 1] << 8);
      final frameLen = 2 + payloadLen;

      if (offset + frameLen > bytes.length) {
        break;
      }

      // The payload is exactly what the data channel expects.
      final packet = Uint8List.sublistView(bytes, offset + 2, offset + frameLen);
      onPacket(packet);

      _packetCount++;
      if (_packetCount <= 5 || _packetCount % 500 == 0) {
        _log('[SCREEN-AUDIO] RX packet #$_packetCount (${packet.length} bytes)');
      }

      offset += frameLen;
    }

    if (offset < bytes.length) {
      _buffer.add(Uint8List.sublistView(bytes, offset));
    }
  }

  /// Stop capturing. Sends 'Q' to the process stdin, then kills if needed.
  Future<void> stop() async {
    if (!_active && _process == null) return;
    _active = false;

    _log('[SCREEN-AUDIO] Stopping capture...');

    try {
      _process?.stdin.add(Uint8List.fromList([0x51])); // 'Q'
      await _process?.stdin.flush();
    } catch (_) {}

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
