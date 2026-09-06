import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/services/audio_probe_service.dart';
import 'package:hollow/src/core/services/video_thumbnail_service.dart';

/// Windows' Media Foundation, which `audioplayers_windows` wraps, cannot decode
/// Opus-in-Ogg, so those files are transcoded to a local PCM WAV cache via the
/// bundled ffmpeg before playback. The wire format stays Opus.
class AudioTranscodeService {
  static const _cacheSubdir = 'audio_cache';

  /// Extensions that need transcoding on Windows for `audioplayers` to play.
  static const _needsTranscode = {'ogg', 'opus'};

  /// Replaces the ffmpeg invocation in tests. When set, the bundled-binary
  /// lookup is skipped, so a test can observe whether a decoder would have
  /// been handed the bytes at all.
  @visibleForTesting
  static AudioProcessRunner? debugRunner;

  /// Returns a path `audioplayers` can open, transcoding to a cached WAV for
  /// an Ogg/Opus file on Windows and returning the input path otherwise.
  /// Null only when transcoding fails; the original is still on disk, so the
  /// caller can surface an error.
  static Future<String?> ensurePlayable(String inputPath) async {
    final lower = inputPath.toLowerCase();
    final dot = lower.lastIndexOf('.');
    final ext = dot >= 0 ? lower.substring(dot + 1) : '';

    // Only the Windows audioplayers backend struggles with Opus; GStreamer
    // on Linux and AVFoundation on macOS play Ogg/Opus natively.
    if (!Platform.isWindows || !_needsTranscode.contains(ext)) {
      return inputPath;
    }

    final runner = debugRunner;
    final ffmpeg =
        runner != null ? 'ffmpeg' : VideoThumbnailService.findFfmpegBinary();
    if (ffmpeg == null) return null;

    final inputFile = File(inputPath);
    if (!await inputFile.exists()) return null;

    final stat = await inputFile.stat();
    final cachePath = await _cachePathFor(inputPath, stat.modified);

    final cachedFile = File(cachePath);
    if (await cachedFile.exists() && await cachedFile.length() > 0) {
      return cachePath;
    }

    final args = [
      '-hide_banner',
      '-loglevel', 'error',
      '-y',
      '-i', inputPath,
      '-c:a', 'pcm_s16le',
      '-ar', '16000',
      '-ac', '1',
      cachePath,
    ];
    final result = runner != null
        ? await runner(ffmpeg, args)
        : await Process.run(ffmpeg, args);
    if (result.exitCode != 0) {
      // ignore: avoid_print
      print('[AudioTranscode] ffmpeg exit=${result.exitCode} '
          'stderr=${result.stderr}');
      try { await cachedFile.delete(); } catch (_) {}
      return null;
    }
    return cachePath;
  }

  static Future<String> _cachePathFor(
    String inputPath,
    DateTime mtime,
  ) async {
    final sep = Platform.pathSeparator;
    final dir = Directory('$hollowDataDir$sep$_cacheSubdir');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    // Key by input path plus mtime so a re-download invalidates the cache.
    // A fast non-crypto hash: this needs path-safe uniqueness, not security.
    final key = '$inputPath|${mtime.millisecondsSinceEpoch}';
    var hash = 0;
    for (final code in key.codeUnits) {
      hash = 0x1fffffff & (hash * 31 + code);
    }
    final tag = hash.toRadixString(16).padLeft(8, '0');
    final stamp = mtime.millisecondsSinceEpoch.toRadixString(16);
    return '${dir.path}$sep${tag}_$stamp.wav';
  }
}
