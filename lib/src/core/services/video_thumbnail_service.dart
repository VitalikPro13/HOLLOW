import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:path/path.dart' as p;

import '../../rust/api/network.dart' as network_api;

/// Log to hollow_debug.log (visible in release builds).
void _log(String msg) {
  network_api.logFromDart(message: msg);
}

/// Result of a successful video thumbnail extraction.
class VideoThumbnailResult {
  /// The thumbnail bytes, lossless WebP encoded.
  final Uint8List webpBytes;

  /// Original video duration in milliseconds.
  final int durationMs;

  /// Original video width in pixels (NOT thumbnail width — thumbnail is scaled
  /// down to a fixed target height while preserving aspect ratio).
  final int sourceWidth;

  /// Original video height in pixels.
  final int sourceHeight;

  const VideoThumbnailResult({
    required this.webpBytes,
    required this.durationMs,
    required this.sourceWidth,
    required this.sourceHeight,
  });
}

/// Extracts a single first-frame thumbnail from a video file using a bundled
/// ffmpeg binary, encoded as lossless WebP.
///
/// The bundled binary is located via [findFfmpegBinary] which checks the
/// directory containing the running executable. The binary is shipped via
/// `scripts/fetch_ffmpeg.{ps1,sh}` and bundled into the Flutter build by the
/// per-platform CMakeLists.txt / Xcode build phase.
///
/// All errors are swallowed and surfaced as `null` — never throws. Callers
/// should handle the null case by falling back to a degraded UI (e.g. send
/// the video to vault without a companion thumbnail message).
class VideoThumbnailService {
  static String? _cachedFfmpegPath;
  static bool _searchedForFfmpeg = false;

  /// Returns the absolute path to the bundled ffmpeg binary if found, or null.
  ///
  /// Looks next to the running executable (where CMake / Xcode bundles it).
  /// Result is cached after the first call.
  static String? findFfmpegBinary() {
    if (_searchedForFfmpeg) return _cachedFfmpegPath;
    _searchedForFfmpeg = true;

    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      final binaryName = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';

      final candidates = <String>[
        // Bundled next to the executable (Windows install layout).
        p.join(exeDir.path, binaryName),
      ];

      if (Platform.isMacOS) {
        // On macOS `resolvedExecutable` is `<Bundle>/Contents/MacOS/hollow`.
        // The preferred location for bundled tools is `Contents/Resources/`.
        final contentsDir = exeDir.parent;
        candidates.addAll([
          p.join(contentsDir.path, 'Resources', 'ffmpeg'),
          p.join(contentsDir.path, 'MacOS', 'ffmpeg'),
          // Common dev fallbacks if the user installed ffmpeg manually.
          '/opt/homebrew/bin/ffmpeg',
          '/usr/local/bin/ffmpeg',
        ]);
      } else if (Platform.isLinux) {
        candidates.addAll([
          '/usr/local/bin/ffmpeg',
          '/usr/bin/ffmpeg',
        ]);
      }

      for (final path in candidates) {
        if (File(path).existsSync()) {
          _cachedFfmpegPath = path;
          _log('[VideoThumbnail] ffmpeg binary located: $path');
          return _cachedFfmpegPath;
        }
      }

      _log('[VideoThumbnail] ffmpeg binary NOT found. Tried: $candidates');
      return null;
    } catch (e) {
      _log('[VideoThumbnail] error locating ffmpeg binary: $e');
      return null;
    }
  }

  /// Whether thumbnail extraction is available on this install.
  /// Returns true if the bundled ffmpeg binary was found.
  static bool get isAvailable => findFfmpegBinary() != null;

  /// Returns the canonical local thumbnail cache path for a video file.
  ///
  /// Always places thumbnails in `~/.hollow/files/` so they don't leak
  /// into the user's documents/downloads folders.
  ///
  /// Returns null if [videoPath] is not a recognized video file path.
  static String? thumbCachePathFor(String videoPath) {
    try {
      final base = p.basenameWithoutExtension(videoPath);
      if (base.isEmpty) return null;
      final filesDir = _hollowFilesDir();
      return p.join(filesDir, '$base.thumb.webp');
    } catch (_) {
      return null;
    }
  }

  static String _hollowFilesDir() {
    final dir = p.join(hollowDataDir, 'files');
    Directory(dir).createSync(recursive: true);
    return dir;
  }

  /// Returns the cached thumbnail path if it already exists on disk for the
  /// given video, otherwise null. Sync — safe to call from build().
  static String? cachedThumbFor(String videoPath) {
    final cachePath = thumbCachePathFor(videoPath);
    if (cachePath == null) return null;
    return File(cachePath).existsSync() ? cachePath : null;
  }

  /// Extract a thumbnail for [videoPath] and persist it to the local cache
  /// at `{video}.thumb.webp`. If the cache file already exists, returns its
  /// path immediately without re-extracting.
  ///
  /// Returns the cache path on success, null on any failure (no ffmpeg, no
  /// permissions, extraction crashed, etc.).
  static Future<String?> ensureCachedThumb(String videoPath) async {
    final cachePath = thumbCachePathFor(videoPath);
    if (cachePath == null) return null;
    if (File(cachePath).existsSync()) return cachePath;
    if (!File(videoPath).existsSync()) return null;

    final result = await extractVideoThumbnail(videoPath: videoPath);
    if (result == null) return null;

    try {
      await File(cachePath).writeAsBytes(result.webpBytes, flush: true);
      return cachePath;
    } catch (e) {
      _log('[VideoThumbnail] failed to cache thumbnail: $e');
      return null;
    }
  }

  /// Extracts a first-frame thumbnail from [videoPath] as a lossless WebP.
  ///
  /// The thumbnail is scaled to [targetHeight] pixels tall (default 480),
  /// preserving aspect ratio (width is computed automatically and rounded
  /// to the nearest even number for codec compatibility).
  ///
  /// Returns null on any failure (binary missing, ffmpeg crash, timeout,
  /// unsupported format, corrupt video). Never throws.
  ///
  /// Times out after 10 seconds.
  static Future<VideoThumbnailResult?> extractVideoThumbnail({
    required String videoPath,
    int targetHeight = 480,
  }) async {
    final ffmpeg = findFfmpegBinary();
    if (ffmpeg == null) {
      _log('[VideoThumbnail] cannot extract — ffmpeg binary not available');
      return null;
    }

    if (!File(videoPath).existsSync()) {
      _log('[VideoThumbnail] source video does not exist: $videoPath');
      return null;
    }

    Directory? tempDir;
    try {
      tempDir = await Directory.systemTemp.createTemp('hollow_thumb_');
      final outPath = p.join(tempDir.path, 'thumb.webp');

      // -y                       overwrite output without asking
      // -ss 00:00:00.5           seek 0.5s in (avoids fully-black first frame)
      // -i <video>               input
      // -vf scale=-2:H           scale to height H, width auto (even)
      // -frames:v 1              output one frame
      // -update 1                single-image output (no %d pattern needed)
      // -c:v libwebp             use libwebp encoder
      // -lossless 1              lossless mode (matches Hollow image pipeline)
      // -compression_level 6     max compression effort
      // -f image2                explicit muxer — the bundled MINIMAL ffmpeg
      //                          (vendor/ffmpeg, --disable-everything) has no
      //                          `webp` muxer, so the .webp extension can't
      //                          drive the format guess
      //
      // CRITICAL — flags must exist in the MINIMAL build: `-pred mixed` was
      // rejected with "Unrecognized option" by the n7.1 minimal build, which
      // silently killed EVERY thumbnail extraction (and with it video
      // dimensions + posters). Test any new flag against the bundled binary,
      // not a system ffmpeg.
      final result = await Process.run(
        ffmpeg,
        [
          '-y',
          '-ss', '00:00:00.5',
          '-i', videoPath,
          '-vf', 'scale=-2:$targetHeight',
          '-frames:v', '1',
          '-update', '1',
          '-c:v', 'libwebp',
          '-lossless', '1',
          '-compression_level', '6',
          '-f', 'image2',
          outPath,
        ],
        stdoutEncoding: null, // raw bytes
        stderrEncoding: null,
      ).timeout(const Duration(seconds: 10));

      if (result.exitCode != 0) {
        final stderrStr = _bytesToString(result.stderr);
        // Log the TAIL of stderr — ffmpeg prints its version banner + build
        // config first, so a head-truncated log shows only the banner and
        // hides the actual error (exactly how the -pred failure went unseen).
        _log('[VideoThumbnail] ffmpeg exit ${result.exitCode}: ${_tail(stderrStr, 500)}');
        return null;
      }

      final outFile = File(outPath);
      if (!outFile.existsSync()) {
        _log('[VideoThumbnail] ffmpeg succeeded but output file missing: $outPath');
        return null;
      }
      final bytes = await outFile.readAsBytes();
      if (bytes.isEmpty) {
        _log('[VideoThumbnail] ffmpeg produced empty file');
        return null;
      }

      // ffmpeg writes its probe info (Duration, Stream details) to stderr even
      // on success. Parse it to recover source dimensions + duration.
      final stderrStr = _bytesToString(result.stderr);
      final parsed = _parseFfmpegStderr(stderrStr);

      _log('[VideoThumbnail] extracted ${bytes.length} bytes, '
          '${parsed.width}x${parsed.height}, ${parsed.durationMs}ms');

      return VideoThumbnailResult(
        webpBytes: Uint8List.fromList(bytes),
        durationMs: parsed.durationMs,
        sourceWidth: parsed.width,
        sourceHeight: parsed.height,
      );
    } on TimeoutException {
      _log('[VideoThumbnail] ffmpeg timed out after 10s on: $videoPath');
      return null;
    } catch (e) {
      _log('[VideoThumbnail] extraction failed: $e');
      return null;
    } finally {
      if (tempDir != null) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {
          // ignore cleanup failures
        }
      }
    }
  }

  // ---- helpers ----

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

  static String _tail(String s, int max) =>
      s.length <= max ? s : '...${s.substring(s.length - max)}';

  /// Parses ffmpeg's stderr probe output for duration + source video dimensions.
  ///
  /// Example lines:
  ///   `  Duration: 00:01:23.45, start: 0.000000, bitrate: 1234 kb/s`
  ///   `    Stream #0:0[0x1](und): Video: h264 (...), yuv420p, 1920x1080, ...`
  static _ParsedProbe _parseFfmpegStderr(String stderr) {
    int durationMs = 0;
    int width = 0;
    int height = 0;

    // Duration: HH:MM:SS.cs
    final durMatch = RegExp(r'Duration:\s*(\d+):(\d+):(\d+)\.(\d+)').firstMatch(stderr);
    if (durMatch != null) {
      final h = int.tryParse(durMatch.group(1) ?? '0') ?? 0;
      final m = int.tryParse(durMatch.group(2) ?? '0') ?? 0;
      final s = int.tryParse(durMatch.group(3) ?? '0') ?? 0;
      final csStr = durMatch.group(4) ?? '0';
      // ffmpeg uses centiseconds (2 digits) — pad/truncate to 3 for ms.
      final cs = int.tryParse(csStr) ?? 0;
      final ms = csStr.length == 2
          ? cs * 10
          : (csStr.length == 3 ? cs : (cs * 1000 ~/ _pow10(csStr.length)));
      durationMs = ((h * 3600 + m * 60 + s) * 1000) + ms;
    }

    // Source video dimensions — first WxH after a "Video:" stream line.
    // Use the first stream's dimensions (the primary video track).
    final videoStreamRe = RegExp(r'Stream #\d+:\d+.*?: Video:.*?(\d{2,5})x(\d{2,5})');
    final videoMatch = videoStreamRe.firstMatch(stderr);
    if (videoMatch != null) {
      width = int.tryParse(videoMatch.group(1) ?? '0') ?? 0;
      height = int.tryParse(videoMatch.group(2) ?? '0') ?? 0;
    }

    return _ParsedProbe(durationMs: durationMs, width: width, height: height);
  }

  static int _pow10(int n) {
    var r = 1;
    for (var i = 0; i < n; i++) {
      r *= 10;
    }
    return r;
  }
}

class _ParsedProbe {
  final int durationMs;
  final int width;
  final int height;
  const _ParsedProbe({
    required this.durationMs,
    required this.width,
    required this.height,
  });
}
