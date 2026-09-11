import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/services/at_rest.dart';
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

  /// Original video width in pixels, not the thumbnail's.
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

/// Extracts a single first-frame thumbnail from a video file as lossless WebP,
/// using the ffmpeg binary bundled next to the running executable by
/// `scripts/fetch_ffmpeg.{ps1,sh}` and the per-platform build.
///
/// All errors surface as `null` and none escape, so a caller falls back to a
/// degraded UI rather than failing the send.
class VideoThumbnailService {
  static String? _cachedFfmpegPath;
  static bool _searchedForFfmpeg = false;

  /// Absolute path to the bundled ffmpeg binary, or null. Looks next to the
  /// running executable, where CMake and Xcode put it. Cached after the first
  /// call.
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

  /// Whether thumbnail extraction is available, meaning ffmpeg was found.
  static bool get isAvailable => findFfmpegBinary() != null;

  /// Canonical local thumbnail cache path for a video file, always under
  /// `~/.hollow/files/` so thumbnails do not leak into the user's documents or
  /// downloads. Null when [videoPath] is not a recognized video file path.
  static String? thumbCachePathFor(String videoPath) {
    try {
      final name = p.basename(videoPath);
      if (name.isEmpty) return null;
      // A picked video's own name would otherwise sit in the folder next to
      // files that are all opaque ids.
      final base = sha256.convert(utf8.encode(name)).toString().substring(0, 32);
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

  /// Extracts a thumbnail for [videoPath] and persists it at
  /// `{video}.thumb.webp`, returning an existing cache file immediately.
  /// Null on any failure: no ffmpeg, no permissions, a crashed extraction.
  static Future<String?> ensureCachedThumb(String videoPath) async {
    final cachePath = thumbCachePathFor(videoPath);
    if (cachePath == null) return null;
    if (File(cachePath).existsSync()) return cachePath;
    if (!File(videoPath).existsSync()) return null;

    final result = await extractVideoThumbnail(videoPath: videoPath);
    if (result == null) return null;

    try {
      await AtRest.write(cachePath, result.webpBytes);
      return cachePath;
    } catch (e) {
      _log('[VideoThumbnail] failed to cache thumbnail: $e');
      return null;
    }
  }

  /// Extracts a first-frame thumbnail from [videoPath] as lossless WebP,
  /// scaled to [targetHeight] pixels tall with the width rounded to an even
  /// number for codec compatibility.
  ///
  /// Null on any failure, never throws. Times out after 10 seconds.
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

    try {
      // An attachment on disk is ciphertext, so ffmpeg reads it from stdin.
      // A file the user picked keeps its path: -ss before -i cannot seek a
      // pipe, and a moov atom written at the end of an mp4 is unreachable
      // through one.
      final piped = AtRest.isManaged(videoPath);
      final stdinBytes = piped ? await AtRest.read(videoPath) : null;

      // Every flag must exist in the MINIMAL build (vendor/ffmpeg). `-pred
      // mixed` was rejected as "Unrecognized option" and silently killed
      // EVERY extraction, taking video dimensions and posters with it. Test a
      // new flag against the bundled binary, never a system ffmpeg.
      //
      // -ss 00:00:00.5 avoids a fully-black first frame; on a pipe it has to
      // follow -i, which decodes to the seek point instead of jumping.
      final run = await runFfmpeg(
        ffmpeg,
        <String>[
          '-y',
          if (!piped) ...['-ss', _thumbSeekPoint],
          '-i', piped ? 'pipe:0' : videoPath,
          if (piped) ...['-ss', _thumbSeekPoint],
          '-vf', 'scale=-2:$targetHeight',
          '-frames:v', '1',
          '-update', '1',
          '-c:v', 'libwebp',
          '-lossless', '1',
          '-compression_level', '6',
          '-f', 'image2pipe',
          'pipe:1',
        ],
        stdinBytes: stdinBytes,
        timeout: const Duration(seconds: 10),
      );

      if (run.exitCode != 0) {
        // Log the TAIL of stderr: ffmpeg prints its version banner and build
        // config first, so a head-truncated log hides the actual error.
        _log('[VideoThumbnail] ffmpeg exit ${run.exitCode}: '
            '${_tail(run.stderrText, 500)}');
        return null;
      }
      if (run.stdoutBytes.isEmpty) {
        _log('[VideoThumbnail] ffmpeg produced no image');
        return null;
      }

      // ffmpeg writes its probe info (Duration, Stream details) to stderr even
      // on success, so parse it for the source dimensions and duration.
      final parsed = _parseFfmpegStderr(run.stderrText);

      _log('[VideoThumbnail] extracted ${run.stdoutBytes.length} bytes, '
          '${parsed.width}x${parsed.height}, ${parsed.durationMs}ms');

      return VideoThumbnailResult(
        webpBytes: run.stdoutBytes,
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
    }
  }

  /// Where the poster frame is taken from, past a first frame that is often
  /// solid black.
  static const String _thumbSeekPoint = '00:00:00.5';

  /// Runs the bundled ffmpeg, optionally feeding it [stdinBytes], and collects
  /// both output streams.
  ///
  /// Shared by the thumbnail, duration-probe and audio-transcode paths: an
  /// attachment is ciphertext on disk, so none of them can name a file and
  /// none of them may write a plaintext one.
  static Future<FfmpegRun> runFfmpeg(
    String ffmpeg,
    List<String> args, {
    Uint8List? stdinBytes,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final proc = await Process.start(ffmpeg, args);
    final out = BytesBuilder(copy: false);
    final err = BytesBuilder(copy: false);
    final drained = Future.wait<void>([
      proc.stdout.forEach(out.add),
      proc.stderr.forEach(err.add),
    ]);

    if (stdinBytes != null) {
      // `-frames:v 1` makes ffmpeg exit before it has read the whole input, so
      // the write end breaks by design.
      unawaited(proc.stdin.done.catchError((Object _) {}));
      try {
        proc.stdin.add(stdinBytes);
        await proc.stdin.flush();
      } catch (_) {}
      try {
        await proc.stdin.close();
      } catch (_) {}
    }

    int exitCode;
    try {
      exitCode = await proc.exitCode.timeout(timeout);
    } on TimeoutException {
      proc.kill(ProcessSignal.sigkill);
      rethrow;
    }
    await drained;

    return FfmpegRun(
      exitCode: exitCode,
      stdoutBytes: out.takeBytes(),
      stderrText: String.fromCharCodes(err.takeBytes()),
    );
  }

  static String _tail(String s, int max) =>
      s.length <= max ? s : '...${s.substring(s.length - max)}';

  /// Parses ffmpeg's stderr probe output for the duration and the source
  /// video dimensions.
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

    // Source dimensions: the first WxH after a "Video:" stream line, which
    // is the primary video track.
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

/// One bundled-ffmpeg invocation's exit code and both output streams.
class FfmpegRun {
  final int exitCode;
  final Uint8List stdoutBytes;
  final String stderrText;

  const FfmpegRun({
    required this.exitCode,
    required this.stdoutBytes,
    required this.stderrText,
  });
}
