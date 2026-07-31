import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hollow/src/core/hollow_data_dir.dart';

import 'package:record/record.dart' as rec;

import 'package:hollow/src/core/services/linux_pulse_capture.dart';
import 'package:hollow/src/core/services/video_thumbnail_service.dart';

/// Fixed encoding profile for voice messages.
///
/// **Desktop (Windows/macOS/Linux):** PCM16 captured by the `record` package
/// is piped into the bundled ffmpeg and re-encoded as Opus in an Ogg container
/// (16 kHz mono, 24 kbps). We go through ffmpeg because on Windows the
/// `record_windows` plugin relies on Media Foundation, which does not ship an
/// Opus MFT.
///
/// **Mobile (Android/iOS):** The `record` package encodes Opus natively via
/// Android's `MediaRecorder` / iOS's `AVAudioRecorder`. No ffmpeg needed.
///
/// ~90 KB per 30s of speech — Discord/WhatsApp-tier quality-per-byte.
class VoiceRecordingResult {
  final String filePath;
  final Duration duration;
  const VoiceRecordingResult({required this.filePath, required this.duration});
}

/// One-shot voice recorder. Create, [start], observe [amplitudes]/[elapsed],
/// then [stop] for the finished file or [cancel] to discard.
class VoiceMessageRecorder {
  static const int _sampleRate = 16000;
  static const int _bitRateKbps = 24;
  static const Duration _ampInterval = Duration(milliseconds: 100);

  static bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  final rec.AudioRecorder _recorder = rec.AudioRecorder();

  final _ampController = StreamController<double>.broadcast();
  final _elapsedController = StreamController<Duration>.broadcast();

  /// 0.0–1.0 mic level sampled every 100ms while recording.
  Stream<double> get amplitudes => _ampController.stream;

  /// Tick of elapsed recording duration (every 100ms).
  Stream<Duration> get elapsed => _elapsedController.stream;

  StreamSubscription<rec.Amplitude>? _ampSub;
  StreamSubscription<Uint8List>? _pcmSub;
  LinuxPulseCapture? _pulse;
  Timer? _elapsedTimer;
  DateTime? _startedAt;
  String? _outPath;
  Process? _ffmpeg;
  Completer<int>? _ffmpegExit;
  final _stderrBuf = StringBuffer();
  bool _disposed = false;
  bool _started = false;

  /// Throws [RecorderPermissionException] if mic permission is denied, or
  /// [RecorderFfmpegMissingException] if the bundled ffmpeg can't be found
  /// (desktop only — mobile uses native Opus encoder).
  Future<void> start({String? preferredDeviceId}) async {
    // Linux never touches the `record` plugin (its capture shells out to
    // `parecord`, absent on PipeWire) and has no mic permission prompt —
    // capture goes through libpulse-simple instead.
    if (!Platform.isLinux && !await _recorder.hasPermission()) {
      throw const RecorderPermissionException();
    }

    _outPath = await _buildTempPath();

    if (_isMobile) {
      await _startMobile(preferredDeviceId: preferredDeviceId);
    } else {
      await _startDesktop(preferredDeviceId: preferredDeviceId);
    }
  }

  /// Mobile path: record directly to .ogg via native Opus encoder.
  Future<void> _startMobile({String? preferredDeviceId}) async {
    await _recorder.start(
      rec.RecordConfig(
        encoder: rec.AudioEncoder.opus,
        numChannels: 1,
        sampleRate: _sampleRate,
        bitRate: _bitRateKbps * 1000,
        device: (preferredDeviceId != null && preferredDeviceId.isNotEmpty)
            ? rec.InputDevice(id: preferredDeviceId, label: '')
            : null,
      ),
      path: _outPath!,
    );
    _started = true;
    _startedAt = DateTime.now();

    _ampSub = _recorder.onAmplitudeChanged(_ampInterval).listen((amp) {
      if (_disposed) return;
      const minDb = -60.0;
      final clamped = amp.current.clamp(minDb, 0.0);
      final level = (clamped - minDb) / (0.0 - minDb);
      _ampController.add(level);
    });
    _elapsedTimer = Timer.periodic(_ampInterval, (_) {
      final start = _startedAt;
      if (start == null || _disposed) return;
      _elapsedController.add(DateTime.now().difference(start));
    });
  }

  /// Desktop path: capture PCM and pipe through bundled ffmpeg for Opus encoding.
  Future<void> _startDesktop({String? preferredDeviceId}) async {
    final ffmpegPath = VideoThumbnailService.findFfmpegBinary();
    if (ffmpegPath == null) {
      throw const RecorderFfmpegMissingException();
    }

    // Spawn ffmpeg reading raw PCM16LE from stdin, encoding libopus → .ogg.
    _ffmpeg = await Process.start(
      ffmpegPath,
      [
        '-hide_banner',
        '-loglevel', 'error',
        '-f', 's16le',
        '-ar', '$_sampleRate',
        '-ac', '1',
        '-i', 'pipe:0',
        '-c:a', 'libopus',
        '-b:a', '${_bitRateKbps}k',
        '-vbr', 'on',
        '-application', 'voip',
        '-y',
        _outPath!,
      ],
    );
    _ffmpegExit = Completer<int>();
    _ffmpeg!.exitCode.then((code) {
      if (!(_ffmpegExit?.isCompleted ?? true)) {
        _ffmpegExit!.complete(code);
      }
    });
    _ffmpeg!.stderr
        .transform(const SystemEncoding().decoder)
        .listen(_stderrBuf.write);

    _ffmpeg!.stdout.drain<void>();

    if (Platform.isLinux) {
      final pulse = await LinuxPulseCapture.start(
        device: (preferredDeviceId != null && preferredDeviceId.isNotEmpty)
            ? preferredDeviceId
            : null,
        sampleRate: _sampleRate,
        channels: 1,
      );
      _pulse = pulse;
      _started = true;
      _startedAt = DateTime.now();

      // Chunks arrive every ~100 ms, so they double as the level-meter tick.
      _pcmSub = pulse.chunks.listen((chunk) {
        final proc = _ffmpeg;
        if (proc != null) {
          try {
            proc.stdin.add(chunk);
          } catch (_) {}
        }
        if (!_disposed) {
          _ampController.add(_levelFromPcm16(chunk));
        }
      }, onError: (Object e) {
        _log('[VoiceRecorder] pulse capture error: $e');
      });
    } else {
      final stream = await _recorder.startStream(
        rec.RecordConfig(
          encoder: rec.AudioEncoder.pcm16bits,
          numChannels: 1,
          sampleRate: _sampleRate,
          device: (preferredDeviceId != null && preferredDeviceId.isNotEmpty)
              ? rec.InputDevice(id: preferredDeviceId, label: '')
              : null,
        ),
      );
      _started = true;
      _startedAt = DateTime.now();

      _pcmSub = stream.listen((chunk) {
        final proc = _ffmpeg;
        if (proc == null) return;
        try {
          proc.stdin.add(chunk);
        } catch (_) {}
      });

      _ampSub = _recorder.onAmplitudeChanged(_ampInterval).listen((amp) {
        if (_disposed) return;
        const minDb = -60.0;
        final clamped = amp.current.clamp(minDb, 0.0);
        final level = (clamped - minDb) / (0.0 - minDb);
        _ampController.add(level);
      });
    }
    _elapsedTimer = Timer.periodic(_ampInterval, (_) {
      final start = _startedAt;
      if (start == null || _disposed) return;
      _elapsedController.add(DateTime.now().difference(start));
    });
  }

  /// Same dBFS (-60..0) → 0..1 mapping the `record` amplitude path uses,
  /// computed from a raw PCM16LE chunk's RMS.
  static double _levelFromPcm16(Uint8List chunk) {
    final samples =
        Int16List.view(chunk.buffer, chunk.offsetInBytes, chunk.length >> 1);
    if (samples.isEmpty) return 0.0;
    double sum = 0;
    for (final s in samples) {
      sum += (s * s).toDouble();
    }
    final rms = math.sqrt(sum / samples.length) / 32768.0;
    const minDb = -60.0;
    final db = rms <= 0 ? minDb : 20.0 * math.log(rms) / math.ln10;
    return (db.clamp(minDb, 0.0) - minDb) / (0.0 - minDb);
  }

  /// Stop the recording and return the finished file path + duration.
  /// Returns null if encoding produced no output.
  Future<VoiceRecordingResult?> stop() async {
    final dur = _startedAt != null
        ? DateTime.now().difference(_startedAt!)
        : Duration.zero;
    await _teardownCapture();

    final outPath = _outPath;

    if (_isMobile) {
      // Mobile: recorder wrote directly to file, just verify output.
      if (outPath == null) return null;
      final outFile = File(outPath);
      if (!await outFile.exists() || await outFile.length() == 0) {
        return null;
      }
      return VoiceRecordingResult(filePath: outPath, duration: dur);
    }

    // Desktop: close ffmpeg stdin so the encoder flushes + exits.
    final proc = _ffmpeg;
    if (proc == null) return null;
    try {
      await proc.stdin.flush();
    } catch (_) {}
    try {
      await proc.stdin.close();
    } catch (_) {}

    final code = await _ffmpegExit!.future
        .timeout(const Duration(seconds: 10), onTimeout: () {
      proc.kill();
      return -1;
    });
    _ffmpeg = null;

    if (code != 0 || outPath == null) {
      _log('[VoiceRecorder] ffmpeg exit=$code stderr=${_stderrBuf.toString()}');
      if (outPath != null) {
        try { await File(outPath).delete(); } catch (_) {}
      }
      return null;
    }
    final outFile = File(outPath);
    if (!await outFile.exists() || await outFile.length() == 0) {
      return null;
    }
    return VoiceRecordingResult(filePath: outPath, duration: dur);
  }

  /// Stop recording and delete the partial file.
  Future<void> cancel() async {
    await _teardownCapture();
    if (!_isMobile) {
      final proc = _ffmpeg;
      if (proc != null) {
        try { await proc.stdin.close(); } catch (_) {}
        proc.kill();
        try {
          await _ffmpegExit!.future
              .timeout(const Duration(seconds: 3), onTimeout: () => -1);
        } catch (_) {}
        _ffmpeg = null;
      }
    }
    final outPath = _outPath;
    if (outPath != null) {
      try {
        final f = File(outPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _teardownCapture();
    if (!_isMobile) {
      final proc = _ffmpeg;
      if (proc != null) {
        try { await proc.stdin.close(); } catch (_) {}
        proc.kill();
        _ffmpeg = null;
      }
    }
    await _recorder.dispose();
    await _ampController.close();
    await _elapsedController.close();
  }

  /// Public read-only flag — the widget needs to know whether capture
  /// actually started before cleanup (to decide between stop vs cancel).
  bool get hasStarted => _started;

  Future<void> _teardownCapture() async {
    await _pcmSub?.cancel();
    _pcmSub = null;
    await _ampSub?.cancel();
    _ampSub = null;
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    final pulse = _pulse;
    _pulse = null;
    if (pulse != null) {
      await pulse.stop();
    }
    if (!Platform.isLinux) {
      try {
        await _recorder.stop();
      } catch (_) {}
    }
  }

  static Future<String> _buildTempPath() async {
    final sep = Platform.pathSeparator;
    final dir = Directory('$hollowDataDir${sep}temp');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final rand = math.Random().nextInt(1 << 30);
    return '${dir.path}${sep}voice_${stamp}_$rand.ogg';
  }

  static void _log(String msg) {
    // ignore: avoid_print
    print(msg);
  }
}

class RecorderPermissionException implements Exception {
  const RecorderPermissionException();
  @override
  String toString() => 'Microphone permission denied';
}

class RecorderFfmpegMissingException implements Exception {
  const RecorderFfmpegMissingException();
  @override
  String toString() =>
      'Bundled ffmpeg binary not found — reinstall or rebuild Hollow';
}
