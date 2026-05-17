import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'video_thumbnail_service.dart';

/// Outcome of a recording session.
class RecordingResult {
  final String filePath;
  final Duration duration;
  final bool capturedSystemAudio;

  const RecordingResult({
    required this.filePath,
    required this.duration,
    required this.capturedSystemAudio,
  });
}

/// Spawns ffmpeg to capture the full screen + microphone (and on macOS 14.2+
/// also system audio via CoreAudio Process Tap) to an MP4 file the user can
/// upload to Google Classroom etc.
///
/// One recording at a time. Stateless on disk between sessions; the resulting
/// MP4 is the only artifact left behind.
class RecordingService {
  RecordingService._();

  static final RecordingService instance = RecordingService._();

  static const MethodChannel _channel = MethodChannel('FlutterWebRTC.Method');

  Process? _process;
  bool _nativeRecording = false; // true when macOS native path is active
  String? _currentFilePath;
  DateTime? _startedAt;
  bool _capturedSystemAudio = false;
  Completer<int>? _exitCompleter;
  final StringBuffer _stderrTail = StringBuffer();
  static const int _stderrTailLimit = 4096;

  bool get isRecording => _process != null || _nativeRecording;
  String? get currentFilePath => _currentFilePath;
  DateTime? get startedAt => _startedAt;

  /// Returns the directory where recordings are saved. Created if missing.
  Future<Directory> get recordingsDir async {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path;
    final base = Platform.isMacOS
        ? p.join(home, 'Movies', 'Hollow Recordings')
        : Platform.isWindows
            ? p.join(home, 'Videos', 'Hollow Recordings')
            : p.join(home, 'Videos', 'Hollow Recordings');
    final dir = Directory(base);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  String _timestampedFileName() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'Hollow_${n.year}-${two(n.month)}-${two(n.day)}_${two(n.hour)}-${two(n.minute)}-${two(n.second)}.mp4';
  }

  /// Begin recording. Throws [StateError] if already recording, or
  /// [RecordingException] on backend failure (native or ffmpeg).
  Future<void> start() async {
    if (isRecording) {
      throw StateError('Already recording');
    }

    final dir = await recordingsDir;
    final outFile = p.join(dir.path, _timestampedFileName());

    // macOS uses the native ScreenCaptureKit + AVAssetWriter recorder —
    // macOS: ScreenCaptureKit + AVAssetWriter, Windows: Graphics Capture + MF.
    // Both produce MP4 (H.264 + AAC) with mic + system audio natively.
    if (Platform.isMacOS || Platform.isWindows) {
      final method = Platform.isMacOS
          ? 'hollowMacStartScreenRecord'
          : 'hollowWinStartScreenRecord';
      try {
        final res = await _channel.invokeMethod<Map<Object?, Object?>>(
          method,
          {'path': outFile},
        );
        _capturedSystemAudio = res?['capturedSystemAudio'] == true;
      } on PlatformException catch (e) {
        throw RecordingException('Recording start failed: ${e.message ?? e.code}');
      }
      _nativeRecording = true;
      _currentFilePath = outFile;
      _startedAt = DateTime.now();
      return;
    }

    // Linux fallback: ffmpeg.
    final ffmpeg = VideoThumbnailService.findFfmpegBinary();
    if (ffmpeg == null) {
      throw const RecordingException(
        'ffmpeg binary not found — install ffmpeg or bundle it next to the app',
      );
    }

    final args = _linuxArgs(outFile);

    debugPrint('[REC] spawn $ffmpeg ${args.join(" ")}');

    final process = await Process.start(ffmpeg, args, runInShell: false);
    _process = process;
    _currentFilePath = outFile;
    _startedAt = DateTime.now();
    _exitCompleter = Completer<int>();
    _stderrTail.clear();

    // Mirror stderr to a sidecar log file next to the (planned) output AND
    // buffer the tail in-memory so we can include it in the failure message.
    final stderrLog = File('$outFile.stderr.log').openWrite();
    process.stderr.transform(utf8.decoder).listen((chunk) {
      stderrLog.write(chunk);
      debugPrint('[REC ffmpeg] ${chunk.trimRight()}');
      _stderrTail.write(chunk);
      if (_stderrTail.length > _stderrTailLimit) {
        final s = _stderrTail.toString();
        _stderrTail.clear();
        _stderrTail.write(s.substring(s.length - _stderrTailLimit));
      }
    }, onError: (e) {
      debugPrint('[REC] stderr stream error: $e');
    }, onDone: () {
      stderrLog.close();
    });
    process.stdout.listen((_) {}, onError: (_) {});
    unawaited(process.exitCode.then((code) {
      _exitCompleter?.complete(code);
    }));
  }

  /// Stop the current recording, finalize the MP4, and return the result.
  /// Returns null if no recording was active.
  Future<RecordingResult?> stop() async {
    final filePath = _currentFilePath;
    final startedAt = _startedAt;
    final capturedSystem = _capturedSystemAudio;
    if (filePath == null || startedAt == null) return null;

    // Native path (macOS/Windows): ask the native recorder to flush & finalize.
    if (_nativeRecording) {
      final method = Platform.isMacOS
          ? 'hollowMacStopScreenRecord'
          : 'hollowWinStopScreenRecord';
      try {
        await _channel.invokeMethod<bool>(method);
      } on PlatformException catch (e) {
        debugPrint('[REC] native stop failed: ${e.message}');
      }
      final duration = DateTime.now().difference(startedAt);
      _nativeRecording = false;
      _currentFilePath = null;
      _startedAt = null;
      _capturedSystemAudio = false;

      final outFile = File(filePath);
      final outSize = outFile.existsSync() ? outFile.lengthSync() : 0;
      if (outSize < 1024) {
        if (outFile.existsSync()) {
          try { outFile.deleteSync(); } catch (_) {}
        }
        throw RecordingException('Recording failed (${outSize}B written)');
      }
      return RecordingResult(
        filePath: filePath,
        duration: duration,
        capturedSystemAudio: capturedSystem,
      );
    }

    final proc = _process;
    if (proc == null) return null;

    // Ask ffmpeg to finalize. Sending 'q' on stdin makes it flush the moov
    // atom — sending SIGINT/SIGKILL would leave a corrupt MP4. We escalate
    // through SIGINT/SIGTERM/SIGKILL if ffmpeg won't budge (e.g. it's stuck
    // waiting for frames from a broken capture pipeline).
    try {
      proc.stdin.write('q');
      await proc.stdin.flush();
      await proc.stdin.close();
    } catch (_) {}

    int? exitCode;
    Future<int?> waitFor(Duration d) async {
      try {
        return await _exitCompleter!.future.timeout(d);
      } on TimeoutException {
        return null;
      }
    }

    exitCode = await waitFor(const Duration(seconds: 2));
    if (exitCode == null && !Platform.isWindows) {
      proc.kill(ProcessSignal.sigint);
      exitCode = await waitFor(const Duration(seconds: 2));
    }
    if (exitCode == null) {
      proc.kill(ProcessSignal.sigterm);
      exitCode = await waitFor(const Duration(seconds: 1));
    }
    if (exitCode == null && !Platform.isWindows) {
      proc.kill(ProcessSignal.sigkill);
      exitCode = await waitFor(const Duration(seconds: 1));
    }

    if (Platform.isMacOS) {
      try {
        await _channel.invokeMethod<bool>('hollowMacStopRecordingAudio');
      } catch (_) {}
    }

    final duration = DateTime.now().difference(startedAt);
    _process = null;
    _currentFilePath = null;
    _startedAt = null;
    _capturedSystemAudio = false;
    _exitCompleter = null;

    final outFile = File(filePath);
    final outSize = outFile.existsSync() ? outFile.lengthSync() : 0;
    if (outSize < 1024) {
      final tail = _stderrTail.toString().trim();
      final detail = tail.isEmpty ? '' : '\n${_lastLines(tail, 10)}';
      // Clean up zero-byte garbage.
      if (outFile.existsSync()) {
        try { outFile.deleteSync(); } catch (_) {}
      }
      throw RecordingException(
          'Recording failed (exit=$exitCode, ${outSize}B)$detail');
    }

    return RecordingResult(
      filePath: filePath,
      duration: duration,
      capturedSystemAudio: capturedSystem,
    );
  }

  List<String> _linuxArgs(String outFile) {
    return [
      '-y',
      '-hide_banner',
      '-loglevel', 'warning',
      '-f', 'x11grab',
      '-framerate', '30',
      '-i', ':0.0',
      '-f', 'pulse',
      '-i', 'default',
      '-c:v', 'libx264',
      '-preset', 'veryfast',
      '-pix_fmt', 'yuv420p',
      '-c:a', 'aac',
      '-b:a', '160k',
      '-movflags', '+faststart',
      outFile,
    ];
  }

  /// Whether recording is supported on this platform.
  static bool get isAvailable {
    if (Platform.isMacOS || Platform.isWindows) return true;
    return VideoThumbnailService.isAvailable;
  }

  static String _lastLines(String text, int n) {
    final lines = text.split('\n');
    if (lines.length <= n) return text;
    return lines.sublist(lines.length - n).join('\n');
  }
}

class RecordingException implements Exception {
  final String message;
  const RecordingException(this.message);

  @override
  String toString() => 'RecordingException: $message';
}
