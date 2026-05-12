import 'dart:io';

import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/services/video_thumbnail_service.dart';

/// Windows' Media Foundation (which `audioplayers_windows` wraps) cannot
/// decode Opus-in-Ogg. We transcode those files to a local PCM WAV cache
/// via the bundled ffmpeg before handing them to the player. The wire
/// format stays Opus; only local playback uses the cached WAV.
class AudioTranscodeService {
  static const _cacheSubdir = 'audio_cache';

  /// Extensions that need transcoding on Windows for `audioplayers` to play.
  static const _needsTranscode = {'ogg', 'opus'};

  /// Returns a file path that `audioplayers` can open. Transcodes to a
  /// cached WAV if the input is an Ogg/Opus file on Windows. On non-Windows
  /// platforms or for already-supported formats, returns the input path.
  ///
  /// Returns null only if transcoding fails (original path is still on
  /// disk — callers can surface an error toast).
  static Future<String?> ensurePlayable(String inputPath) async {
    final lower = inputPath.toLowerCase();
    final dot = lower.lastIndexOf('.');
    final ext = dot >= 0 ? lower.substring(dot + 1) : '';

    // Only Windows' audioplayers backend has trouble with Opus. On Linux
    // (GStreamer) and macOS (AVFoundation) Ogg/Opus plays natively.
    if (!Platform.isWindows || !_needsTranscode.contains(ext)) {
      return inputPath;
    }

    final ffmpeg = VideoThumbnailService.findFfmpegBinary();
    if (ffmpeg == null) return null;

    final inputFile = File(inputPath);
    if (!await inputFile.exists()) return null;

    final stat = await inputFile.stat();
    final cachePath = await _cachePathFor(inputPath, stat.modified);

    // Cache hit — reuse.
    final cachedFile = File(cachePath);
    if (await cachedFile.exists() && await cachedFile.length() > 0) {
      return cachePath;
    }

    final result = await Process.run(
      ffmpeg,
      [
        '-hide_banner',
        '-loglevel', 'error',
        '-y',
        '-i', inputPath,
        '-c:a', 'pcm_s16le',
        '-ar', '16000',
        '-ac', '1',
        cachePath,
      ],
    );
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
    // Key by input path + mtime so re-downloads invalidate the cache.
    // Fast non-crypto hash — we only need path-safe uniqueness, not security.
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
