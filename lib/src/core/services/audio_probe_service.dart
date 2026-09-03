import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../rust/api/network.dart' as network_api;
import 'video_thumbnail_service.dart';

void _log(String msg) {
  network_api.logFromDart(message: msg);
}

/// Test seam for the ffmpeg invocation. Signature matches [Process.run].
typedef AudioProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// Extracts duration metadata from audio files using the bundled ffmpeg binary.
///
/// Reuses [VideoThumbnailService.findFfmpegBinary] to locate the binary and
/// the same `Duration: HH:MM:SS.cs` stderr parsing pattern.
///
/// Results are cached in-memory so repeated widget rebuilds don't re-probe.
class AudioProbeService {
  static final Map<String, int> _cache = {};

  /// The Ogg capture pattern that opens every page of an Ogg stream.
  static const List<int> _oggMagic = [0x4F, 0x67, 0x67, 0x53]; // "OggS"

  /// Replaces the ffmpeg invocation in tests. When set, the bundled-binary
  /// lookup is skipped too, so a test can observe whether a decoder would
  /// have been handed the bytes at all.
  @visibleForTesting
  static AudioProcessRunner? debugRunner;

  /// Drops the memoised durations. Tests only.
  @visibleForTesting
  static void debugResetCache() => _cache.clear();

  /// Cheap container sniff: true when the file opens with the Ogg capture
  /// pattern. Four bytes off the front of the file, no decoder involved.
  ///
  /// This is what stands between an auto-downloaded attachment and ffmpeg:
  /// an extension is the sender's choice, the magic is not. It proves only
  /// that the container claims to be Ogg, which is enough to refuse the
  /// obvious forgeries before anything memory-unsafe reads the bytes.
  /// The read itself is synchronous: it is four bytes, the caller has already
  /// stat'd the file, and the answer has to be in hand on the frame the bubble
  /// builds so the decision is made once rather than after a rebuild.
  static Future<bool> looksLikeOgg(String path) async {
    RandomAccessFile? handle;
    try {
      handle = File(path).openSync();
      final head = handle.readSync(_oggMagic.length);
      if (head.length < _oggMagic.length) return false;
      for (var i = 0; i < _oggMagic.length; i++) {
        if (head[i] != _oggMagic[i]) return false;
      }
      return true;
    } catch (_) {
      // Missing, locked, or vanished between the check and the read.
      return false;
    } finally {
      try {
        handle?.closeSync();
      } catch (_) {}
    }
  }

  /// Returns the duration in milliseconds for the audio file at [audioPath],
  /// or null if probing fails (missing ffmpeg, corrupt file, timeout).
  ///
  /// Results are cached by path — subsequent calls for the same path return
  /// instantly.
  ///
  /// This runs a decoder over bytes a stranger sent. Callers decide WHEN that
  /// is allowed to happen: see [AudioMessageBubble], which runs it without a
  /// tap only for a file that passes every voice-note test, and otherwise
  /// waits for the user to press play.
  static Future<int?> probeDurationMs(String audioPath) async {
    final cached = _cache[audioPath];
    if (cached != null) return cached;

    final runner = debugRunner;
    final ffmpeg =
        runner != null ? 'ffmpeg' : VideoThumbnailService.findFfmpegBinary();
    if (ffmpeg == null) return null;

    if (runner == null && !File(audioPath).existsSync()) return null;

    try {
      // Run ffmpeg with no output — we only need the stderr probe info.
      // -i <path>    input file (triggers format detection + probe)
      // -f null -    discard output (we just want the probe metadata)
      final args = ['-i', audioPath, '-f', 'null', '-'];
      final result = await (runner != null
              ? runner(ffmpeg, args)
              : Process.run(
                  ffmpeg,
                  args,
                  stdoutEncoding: null,
                  stderrEncoding: null,
                ))
          .timeout(const Duration(seconds: 5));

      final stderrStr = _bytesToString(result.stderr);
      final durationMs = _parseDuration(stderrStr);
      if (durationMs != null && durationMs > 0) {
        _cache[audioPath] = durationMs;
        return durationMs;
      }
      return null;
    } on TimeoutException {
      _log('[AudioProbe] ffmpeg timed out on: $audioPath');
      return null;
    } catch (e) {
      _log('[AudioProbe] probe failed: $e');
      return null;
    }
  }

  /// Parse `Duration: HH:MM:SS.cs` from ffmpeg stderr.
  /// Same regex pattern as [VideoThumbnailService._parseFfmpegStderr].
  static int? _parseDuration(String stderr) {
    final match =
        RegExp(r'Duration:\s*(\d+):(\d+):(\d+)\.(\d+)').firstMatch(stderr);
    if (match == null) return null;

    final h = int.tryParse(match.group(1) ?? '0') ?? 0;
    final m = int.tryParse(match.group(2) ?? '0') ?? 0;
    final s = int.tryParse(match.group(3) ?? '0') ?? 0;
    final csStr = match.group(4) ?? '0';
    final cs = int.tryParse(csStr) ?? 0;
    final ms = csStr.length == 2
        ? cs * 10
        : (csStr.length == 3 ? cs : (cs * 1000 ~/ _pow10(csStr.length)));
    return ((h * 3600 + m * 60 + s) * 1000) + ms;
  }

  static String _bytesToString(dynamic bytes) {
    if (bytes is List<int>) {
      try {
        return String.fromCharCodes(bytes);
      } catch (_) {
        return '';
      }
    }
    if (bytes is String) return bytes;
    return bytes?.toString() ?? '';
  }

  static int _pow10(int n) {
    var r = 1;
    for (var i = 0; i < n; i++) {
      r *= 10;
    }
    return r;
  }
}
