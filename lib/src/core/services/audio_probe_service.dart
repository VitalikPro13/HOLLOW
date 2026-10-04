import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../rust/api/network.dart' as network_api;
import 'at_rest.dart';
import 'video_thumbnail_service.dart';

void _log(String msg) {
  network_api.logFromDart(message: msg);
}

/// Test seam for the ffmpeg invocation. Signature matches [Process.run].
typedef AudioProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// Extracts duration metadata from audio files using the bundled ffmpeg
/// binary, reusing [VideoThumbnailService.findFfmpegBinary] and the same
/// `Duration: HH:MM:SS.cs` stderr parsing. Results are memoised so repeated
/// widget rebuilds do not re-probe.
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

  /// Duration of the Ogg file at [path] from its page headers, or null. Reads
  /// the bytes in Dart and decodes nothing, so it is the one duration a
  /// received file may get before the user asks for it.
  static Future<int?> oggDurationMs(String path) async {
    try {
      return oggDurationFromBytes(await AtRest.read(path));
    } catch (_) {
      return null;
    }
  }

  /// The last page's granule position over the stream's sample rate, less
  /// the Opus pre-skip. Opus and Vorbis only; null for anything else.
  static int? oggDurationFromBytes(Uint8List b) {
    if (!_oggPageAt(b, 0)) return null;
    final view = ByteData.sublistView(b);
    final serial = view.getUint32(14, Endian.little);
    final body = 27 + b[26];
    if (b.length < body + 19) return null;
    final int rate;
    final int preSkip;
    if (_bytesAt(b, body, _opusHead)) {
      rate = 48000;
      preSkip = view.getUint16(body + 10, Endian.little);
    } else if (_bytesAt(b, body, _vorbisIdent)) {
      rate = view.getUint32(body + 12, Endian.little);
      preSkip = 0;
    } else {
      return null;
    }
    if (rate <= 0) return null;
    for (var i = b.length - 27; i > 0; i--) {
      if (!_oggPageAt(b, i)) continue;
      if (view.getUint32(i + 14, Endian.little) != serial) continue;
      // -1 marks a page on which no packet ends.
      final granule = view.getInt64(i + 6, Endian.little);
      if (granule <= 0) continue;
      final samples = granule - preSkip;
      if (samples <= 0 || samples > rate * 86400) return null;
      return samples * 1000 ~/ rate;
    }
    return null;
  }

  static const List<int> _opusHead = [
    0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64, // "OpusHead"
  ];
  static const List<int> _vorbisIdent = [
    0x01, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73, // "\x01vorbis"
  ];

  static bool _oggPageAt(Uint8List b, int i) =>
      i + 27 <= b.length && _bytesAt(b, i, _oggMagic) && b[i + 4] == 0;

  static bool _bytesAt(Uint8List b, int i, List<int> want) {
    if (i + want.length > b.length) return false;
    for (var k = 0; k < want.length; k++) {
      if (b[i + k] != want[k]) return false;
    }
    return true;
  }

  /// Duration in milliseconds for the audio file at [audioPath], or null when
  /// probing fails (missing ffmpeg, corrupt file, timeout). Cached by path.
  ///
  /// This runs a decoder over bytes a stranger sent, so it runs only once the
  /// user has pressed play ([AudioMessageBubble]).
  static Future<int?> probeDurationMs(String audioPath) async {
    final cached = _cache[audioPath];
    if (cached != null) return cached;

    final runner = debugRunner;
    final ffmpeg =
        runner != null ? 'ffmpeg' : VideoThumbnailService.findFfmpegBinary();
    if (ffmpeg == null) return null;

    if (runner == null && !File(audioPath).existsSync()) return null;

    try {
      // No output wanted, only the stderr probe info: -i triggers format
      // detection, `-f null -` discards the decode. An attachment on disk is
      // ciphertext, so ffmpeg reads it from stdin.
      final piped = runner == null && AtRest.isManaged(audioPath);
      final args = ['-i', piped ? 'pipe:0' : audioPath, '-f', 'null', '-'];
      const budget = Duration(seconds: 5);
      final String stderrStr;
      if (runner != null) {
        final result = await runner(ffmpeg, args).timeout(budget);
        stderrStr = _bytesToString(result.stderr);
      } else {
        final run = await VideoThumbnailService.runFfmpeg(
          ffmpeg,
          args,
          stdinBytes: piped ? await AtRest.read(audioPath) : null,
          timeout: budget,
        );
        stderrStr = run.stderrText;
      }
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

  /// Parses `Duration: HH:MM:SS.cs` from ffmpeg stderr, with the same regex
  /// as [VideoThumbnailService._parseFfmpegStderr].
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
