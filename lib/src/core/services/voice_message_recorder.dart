import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hollow/src/core/hollow_data_dir.dart';

import 'package:record/record.dart' as rec;

import 'package:hollow/src/core/services/video_thumbnail_service.dart';

/// Fixed encoding profile for voice messages.
///
/// PCM16 captured by the `record` package is piped into the bundled ffmpeg
/// and re-encoded as Opus in an Ogg container (16 kHz mono, 24 kbps). We go
/// through ffmpeg instead of `record`'s native Opus encoder because on
/// Windows the `record_windows` plugin relies on Media Foundation, which
/// does not ship an Opus MFT — so native Opus throws "Not implemented".
/// ffmpeg (libopus) works identically on every desktop platform.
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

  final rec.AudioRecorder _recorder = rec.AudioRecorder();

  final _ampController = StreamController<double>.broadcast();
  final _elapsedController = StreamController<Duration>.broadcast();

  /// 0.0–1.0 mic level sampled every 100ms while recording.
  Stream<double> get amplitudes => _ampController.stream;

  /// Tick of elapsed recording duration (every 100ms).
  Stream<Duration> get elapsed => _elapsedController.stream;

  StreamSubscription<rec.Amplitude>? _ampSub;
  StreamSubscription<Uint8List>? _pcmSub;
  Timer? _elapsedTimer;
  DateTime? _startedAt;
  String? _outPath;
  Process? _ffmpeg;
  Completer<int>? _ffmpegExit;
  final _stderrBuf = StringBuffer();
  bool _disposed = false;
  bool _started = false;

  /// Throws [RecorderPermissionException] if mic permission is denied, or
  /// [RecorderFfmpegMissingException] if the bundled ffmpeg can't be found.
  Future<void> start({String? preferredDeviceId}) async {
    if (!await _recorder.hasPermission()) {
      throw const RecorderPermissionException();
    }

    final ffmpegPath = VideoThumbnailService.findFfmpegBinary();
    if (ffmpegPath == null) {
      throw const RecorderFfmpegMissingException();
    }

    _outPath = await _buildTempPath();

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

    // Drain stdout (ffmpeg writes nothing useful there at -loglevel error,
    // but an unread pipe will eventually block the child).
    _ffmpeg!.stdout.drain<void>();

    // Start PCM capture and forward to ffmpeg stdin.
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
      } catch (_) {
        // Pipe closed — cleanup runs in stop/cancel.
      }
    });

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

  /// Stop the recording and return the finished file path + duration.
  /// Returns null if encoding produced no output.
  Future<VoiceRecordingResult?> stop() async {
    final dur = _startedAt != null
        ? DateTime.now().difference(_startedAt!)
        : Duration.zero;
    await _teardownCapture();

    // Close ffmpeg stdin so the encoder flushes + exits.
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

    final outPath = _outPath;
    if (code != 0 || outPath == null) {
      _log('[VoiceRecorder] ffmpeg exit=$code stderr=${_stderrBuf.toString()}');
      // Best-effort cleanup of partial file.
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
    final proc = _ffmpeg;
    if (proc != null) {
      try { await proc.stdin.close(); } catch (_) {}
      proc.kill();
      _ffmpeg = null;
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
    try {
      await _recorder.stop();
    } catch (_) {}
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
