import 'dart:io';
import 'dart:typed_data';

import '../../rust/api/network.dart' as network_api;

void _log(String msg) {
  network_api.logFromDart(message: msg);
}

/// Out-of-process audio renderer for received screen share audio (Windows).
///
/// Spawns `screen_audio_capturer.exe --mode render` which reads framed Opus
/// packets from stdin and plays them via waveOut — completely outside the
/// Flutter/libwebrtc process.
///
/// Wire protocol (stdin, binary):
///   [uint16_le: payload_len][uint32_le: seq][...opus_bytes...]
class ScreenAudioRenderer {
  Process? _process;
  bool _active = false;
  int _packetCount = 0;

  /// Last requested playback gain — re-sent on (re)spawn so the exe never
  /// plays at its built-in default when the user has a different setting.
  double _gain = -1;

  bool get isActive => _active;

  static String? _findExePath() {
    final appDir = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    final ext = Platform.isWindows ? '.exe' : '';
    _log('[SCREEN-AUDIO-RENDER] App dir: $appDir');

    final candidates = <String>[
      '$appDir${sep}screen_audio_capturer$ext',
      '$appDir${sep}screen_audio_test$ext',
    ];

    if (Platform.isMacOS) {
      final contentsDir = File(Platform.resolvedExecutable).parent.parent.path;
      candidates.addAll([
        '$contentsDir${sep}Resources${sep}screen_audio_capturer',
        '$contentsDir${sep}Resources${sep}screen_audio_test',
      ]);
    }

    if (Platform.isWindows) {
      candidates.add(
        '$appDir$sep..${sep}..${sep}..${sep}..${sep}..${sep}packages'
        '${sep}flutter_webrtc${sep}test_apps${sep}screen_audio_test'
        '${sep}build${sep}Release${sep}screen_audio_test.exe',
      );
    } else {
      candidates.add(
        '$appDir$sep..${sep}..${sep}..${sep}..${sep}..${sep}packages'
        '${sep}flutter_webrtc${sep}test_apps${sep}screen_audio_test'
        '${sep}build${sep}screen_audio_test',
      );
    }

    for (final path in candidates) {
      final exists = File(path).existsSync();
      _log('[SCREEN-AUDIO-RENDER] Checking: $path -> ${exists ? "FOUND" : "not found"}');
      if (exists) return path;
    }

    _log('[SCREEN-AUDIO-RENDER] No renderer binary found in any location');
    return null;
  }

  Future<bool> start() async {
    if (_active) return true;

    if (Platform.isAndroid || Platform.isIOS) {
      _log('[SCREEN-AUDIO-RENDER] Not supported on mobile');
      return false;
    }

    final exePath = _findExePath();
    if (exePath == null) {
      _log('[SCREEN-AUDIO-RENDER] ERROR: renderer binary not found');
      return false;
    }

    _log('[SCREEN-AUDIO-RENDER] Spawning: $exePath --mode render');

    try {
      _process = await Process.start(
        exePath,
        ['--mode', 'render'],
        mode: ProcessStartMode.normal,
      );
    } on ProcessException catch (e) {
      _log('[SCREEN-AUDIO-RENDER] ProcessException: ${e.message} '
          '(errorCode=${e.errorCode}, exe=$exePath)');
      return false;
    } catch (e) {
      _log('[SCREEN-AUDIO-RENDER] Failed to spawn: $e');
      return false;
    }

    _active = true;
    _packetCount = 0;

    _process!.stderr.transform(const SystemEncoding().decoder).listen((line) {
      for (final l in line.split('\n')) {
        final trimmed = l.trim();
        if (trimmed.isNotEmpty) {
          _log('[SCREEN-AUDIO-RENDER-EXE] $trimmed');
        }
      }
    });

    _process!.exitCode.then((code) {
      _log('[SCREEN-AUDIO-RENDER] Process exited with code $code');
      _active = false;
    });

    _log('[SCREEN-AUDIO-RENDER] Started (PID ${_process!.pid})');
    if (_gain >= 0) _sendGainFrame(_gain);
    return true;
  }

  /// Set the playback gain target (0.0..=1.0); the exe ramps toward it
  /// click-free (fast down / slow up). Sent as a control frame — seq
  /// 0xFFFFFFFF, cmd 0x01, float32 LE — on the same stdin pipe as audio.
  void setGain(double gain) {
    final clamped = gain.clamp(0.0, 1.0).toDouble();
    // Control frames ride between audio packets; skip byte-identical resends.
    if (clamped == _gain && _active) return;
    _gain = clamped;
    if (!_active || _process == null) return;
    _sendGainFrame(clamped);
  }

  void _sendGainFrame(double gain) {
    final payload = ByteData(9)
      ..setUint32(0, 0xFFFFFFFF, Endian.little)
      ..setUint8(4, 0x01)
      ..setFloat32(5, gain, Endian.little);
    final frame = Uint8List(2 + 9);
    frame[0] = 9;
    frame[1] = 0;
    frame.setRange(2, 11, payload.buffer.asUint8List());
    try {
      _process!.stdin.add(frame);
    } catch (e) {
      _log('[SCREEN-AUDIO-RENDER] gain frame write failed: $e');
    }
  }

  /// Feed a received Opus packet for playback.
  /// [packet] is `[uint32_le: seq][...opus_bytes...]` (from data channel).
  void pushPacket(Uint8List packet) {
    if (!_active || _process == null) return;

    // Frame it: [uint16_le: payload_len][payload...]
    final payloadLen = packet.length;
    final frame = Uint8List(2 + payloadLen);
    frame[0] = payloadLen & 0xFF;
    frame[1] = (payloadLen >> 8) & 0xFF;
    frame.setRange(2, 2 + payloadLen, packet);

    try {
      _process!.stdin.add(frame);
    } catch (e) {
      _log('[SCREEN-AUDIO-RENDER] stdin write failed: $e');
      _active = false;
      return;
    }

    _packetCount++;
    if (_packetCount <= 5 || _packetCount % 500 == 0) {
      _log('[SCREEN-AUDIO-RENDER] Pushed packet #$_packetCount');
    }
  }

  Future<void> stop() async {
    if (!_active && _process == null) return;
    _active = false;

    _log('[SCREEN-AUDIO-RENDER] Stopping...');

    try {
      _process?.stdin.close();
    } catch (_) {}

    bool exited = false;
    try {
      await _process?.exitCode.timeout(const Duration(seconds: 2));
      exited = true;
    } catch (_) {}

    if (!exited) {
      _process?.kill();
    }

    _process = null;
    _log('[SCREEN-AUDIO-RENDER] Stopped');
  }
}
