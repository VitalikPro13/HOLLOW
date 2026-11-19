import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:image/image.dart' as img;

import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/services/at_rest.dart';
import 'package:path/path.dart' as p;

import '../../rust/api/network.dart' as network_api;

/// Log to hollow_debug.log (visible in release builds). A log line never
/// fails the caller, before the node is up or in a widget test.
void _log(String msg) {
  try {
    network_api.logFromDart(message: msg).catchError((Object _) {});
  } catch (_) {}
}

/// Result of a successful video thumbnail extraction.
class VideoThumbnailResult {
  /// The poster still: lossless WebP from ffmpeg, JPEG from the platform's
  /// own decoder (phones, macOS).
  final Uint8List posterBytes;

  /// Original video duration in milliseconds.
  final int durationMs;

  /// Original video width in pixels, not the thumbnail's.
  final int sourceWidth;

  /// Original video height in pixels.
  final int sourceHeight;

  const VideoThumbnailResult({
    required this.posterBytes,
    required this.durationMs,
    required this.sourceWidth,
    required this.sourceHeight,
  });

  /// The extension [posterBytes] carries, for a path a decoder reads by name.
  String get posterExt =>
      VideoThumbnailService.isWebp(posterBytes) ? 'webp' : 'jpg';
}

/// One frame of the poster search: where it sits in the clip and its mean
/// luma (0-255), null when that frame could not be read.
class PosterSample {
  final int atMs;
  final double? luma;
  const PosterSample(this.atMs, this.luma);
}

/// Cuts a video's poster still: the first frame in its opening seconds that is
/// neither black nor still fading in. Windows and Linux use the ffmpeg bundled
/// next to the executable (`scripts/fetch_ffmpeg.{ps1,sh}`); phones and macOS
/// use the platform decoder for a file the person picked, since they ship no
/// ffmpeg.
///
/// All errors surface as `null` and none escape, so a caller falls back to a
/// degraded UI rather than failing the send.
class VideoThumbnailService {
  static String? _cachedFfmpegPath;
  static bool _searchedForFfmpeg = false;

  /// Replaces the binary lookup in tests, so a test can tell whether ffmpeg
  /// would have run on a machine that has it.
  @visibleForTesting
  static String? debugFfmpegPath;

  /// Replaces [Process.start] for every bundled-ffmpeg run in tests.
  @visibleForTesting
  static Future<Process> Function(String executable, List<String> arguments)?
  debugStartProcess;

  /// Overrides whether the platform decoder cuts posters, so a test on any host
  /// can drive either path.
  @visibleForTesting
  static bool? debugNativeFrames;

  /// The platform decoder's channel (VideoPoster.swift, VideoPoster.kt).
  static const String nativeChannelName = 'hollow/video_poster';

  static const MethodChannel _nativeFrames = MethodChannel(nativeChannelName);

  static bool get _usesNativeFrames =>
      debugNativeFrames ??
      (Platform.isIOS || Platform.isAndroid || Platform.isMacOS);

  /// Absolute path to the bundled ffmpeg binary, or null. Looks next to the
  /// running executable, where CMake and Xcode put it. Cached after the first
  /// call.
  static String? findFfmpegBinary() {
    final override = debugFfmpegPath;
    if (override != null) return override;
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
        candidates.addAll(['/usr/local/bin/ffmpeg', '/usr/bin/ffmpeg']);
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
  /// `<data root>/files/` so thumbnails do not leak into the user's documents
  /// or downloads. Null when [videoPath] is not a recognized video file path.
  ///
  /// Keyed by the whole path, size and modification time: two picks named
  /// `IMG_0001.MOV` in different folders, or a file replaced in place, are
  /// different videos.
  static String? thumbCachePathFor(String videoPath) {
    try {
      if (p.basename(videoPath).isEmpty) return null;
      final stat = FileStat.statSync(videoPath);
      final identity =
          '${p.normalize(p.absolute(videoPath))}|${stat.size}|'
          '${stat.modified.millisecondsSinceEpoch}';
      // Hashed, so a picked video's own name never sits in a folder of ids.
      final base = sha256
          .convert(utf8.encode(identity))
          .toString()
          .substring(0, 32);
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
      await AtRest.write(cachePath, result.posterBytes);
      return cachePath;
    } catch (e) {
      _log('[VideoThumbnail] failed to cache thumbnail: $e');
      return null;
    }
  }

  /// Cuts a poster from [videoPath], scaled to at most [targetHeight] pixels
  /// tall, with the source video's dimensions and duration.
  ///
  /// Null on any failure, never throws. Decoding is bounded by ten seconds
  /// ([extractBudget]), counted once an attachment's bytes are read.
  static Future<VideoThumbnailResult?> extractVideoThumbnail({
    required String videoPath,
    int targetHeight = 480,
  }) async {
    if (!File(videoPath).existsSync()) {
      _log('[VideoThumbnail] source video does not exist: $videoPath');
      return null;
    }

    // An attachment on disk is ciphertext: only ffmpeg reading our own pipe
    // may see it, so the platform decoder takes picked files alone.
    final piped = AtRest.isManaged(videoPath);
    if (_usesNativeFrames && !piped) {
      return _extractNative(videoPath, targetHeight);
    }

    final ffmpeg = findFfmpegBinary();
    if (ffmpeg == null) {
      _log('[VideoThumbnail] cannot extract — ffmpeg binary not available');
      return null;
    }

    try {
      // A file the user picked keeps its path: -ss before -i cannot seek a
      // pipe, and a moov atom written at the end of an mp4 is unreachable
      // through one.
      final stdinBytes = piped ? await AtRest.read(videoPath) : null;
      final clock = Stopwatch()..start();

      int? picked;
      try {
        final sampled = await runFfmpeg(
          ffmpeg,
          posterSampleArgs(videoPath, piped: piped),
          stdinBytes: stdinBytes,
          timeout: sampleBudget,
        );
        if (sampled.exitCode == 0) {
          picked = pickPosterMs(samplesFromStream(sampled.stdoutBytes));
        } else {
          _log(
            '[VideoThumbnail] poster sampling exit ${sampled.exitCode}: '
            '${_tail(sampled.stderrText, 300)}',
          );
        }
      } on TimeoutException {
        _log('[VideoThumbnail] poster sampling timed out; using the old frame');
      }

      for (final atMs in _frameLadder(picked)) {
        final left = extractBudget - clock.elapsed;
        if (left <= Duration.zero) throw TimeoutException('poster', left);
        final run = await runFfmpeg(
          ffmpeg,
          posterFrameArgs(
            videoPath,
            piped: piped,
            atMs: atMs,
            targetHeight: targetHeight,
          ),
          stdinBytes: stdinBytes,
          timeout: left,
        );
        if (run.exitCode != 0) {
          // Log the TAIL of stderr: ffmpeg prints its version banner and build
          // config first, so a head-truncated log hides the actual error.
          _log(
            '[VideoThumbnail] ffmpeg exit ${run.exitCode}: '
            '${_tail(run.stderrText, 500)}',
          );
          return null;
        }
        // Empty = the clip ends before this point; the next rung is earlier.
        if (run.stdoutBytes.isEmpty) continue;

        // ffmpeg writes its probe info (Duration, Stream details) to stderr
        // even on success, so parse it for the source dimensions and duration.
        final parsed = _parseFfmpegStderr(run.stderrText);
        _log(
          '[VideoThumbnail] extracted ${run.stdoutBytes.length} bytes at '
          '${atMs}ms, ${parsed.width}x${parsed.height}, ${parsed.durationMs}ms',
        );
        return VideoThumbnailResult(
          posterBytes: run.stdoutBytes,
          durationMs: parsed.durationMs,
          sourceWidth: parsed.width,
          sourceHeight: parsed.height,
        );
      }
      _log('[VideoThumbnail] ffmpeg produced no image');
      return null;
    } on TimeoutException {
      _log('[VideoThumbnail] ffmpeg timed out after 10s on: $videoPath');
      return null;
    } catch (e) {
      _log('[VideoThumbnail] extraction failed: $e');
      return null;
    }
  }

  /// The platform decoder's poster (AVFoundation, MediaMetadataRetriever),
  /// chosen by the same rule as ffmpeg's. Each call has its own deadline here
  /// and on the native side, which abandons a decode that hangs.
  static Future<VideoThumbnailResult?> _extractNative(
    String videoPath,
    int targetHeight,
  ) async {
    final clock = Stopwatch()..start();
    try {
      Map<String, Object?>? sampled;
      try {
        sampled = await _nativeFrames
            .invokeMapMethod<String, Object?>('sample', {
              'path': videoPath,
              'timesMs': posterSampleTimesMs,
              'deadlineMs': sampleBudget.inMilliseconds,
            })
            .timeout(sampleBudget);
      } on TimeoutException {
        _log('[VideoThumbnail] native sampling timed out; using the old frame');
      } catch (e) {
        _log('[VideoThumbnail] native sampling failed: $e');
      }
      final lumas = (sampled?['lumas'] as List?) ?? const [];
      final picked = pickPosterMs([
        for (var i = 0; i < lumas.length && i < posterSampleTimesMs.length; i++)
          PosterSample(posterSampleTimesMs[i], (lumas[i] as num?)?.toDouble()),
      ]);
      for (final atMs in _frameLadder(picked)) {
        final left = extractBudget - clock.elapsed;
        if (left <= Duration.zero) throw TimeoutException('poster', left);
        final cut = await _nativeFrames
            .invokeMapMethod<String, Object?>('frame', {
              'path': videoPath,
              'atMs': atMs,
              'maxHeight': targetHeight,
              'deadlineMs': left.inMilliseconds,
            })
            .timeout(left);
        final bytes = cut?['image'];
        if (bytes is! Uint8List || bytes.isEmpty) continue;
        _log(
          '[VideoThumbnail] native poster ${bytes.length} bytes at ${atMs}ms',
        );
        // Sampling's metadata when it answered, else the cut's own.
        final meta = sampled ?? cut!;
        return VideoThumbnailResult(
          posterBytes: bytes,
          durationMs: (meta['durationMs'] as num?)?.toInt() ?? 0,
          sourceWidth: (meta['width'] as num?)?.toInt() ?? 0,
          sourceHeight: (meta['height'] as num?)?.toInt() ?? 0,
        );
      }
      _log('[VideoThumbnail] native decoder produced no image');
      return null;
    } on TimeoutException {
      _log('[VideoThumbnail] native poster timed out after 10s');
      return null;
    } catch (e) {
      _log('[VideoThumbnail] native poster failed: $e');
      return null;
    }
  }

  /// Everything one poster may take, sampling and the final cut together.
  @visibleForTesting
  static Duration extractBudget = const Duration(seconds: 10);

  /// Sampling's share, so the old frame still fits when sampling stalls.
  @visibleForTesting
  static Duration sampleBudget = const Duration(seconds: 5);

  /// The old poster point, past a first frame that is often solid black or a
  /// codec's grey.
  static const int _legacySeekMs = 500;

  /// Sampled frames are this far apart, over the opening seconds only: a pipe
  /// cannot seek, so anything later costs a decode of everything before it.
  static const int _sampleStepMs = 500;
  static const int _sampleCount = 12;
  static const int _sampleSide = 32;

  /// Mean luma below this is a black frame (ffmpeg's blackframe calls a pixel
  /// black under 32).
  static const double _nearBlackLuma = 24;

  @visibleForTesting
  static final List<int> posterSampleTimesMs = List<int>.unmodifiable([
    for (var i = 0; i < _sampleCount; i++) i * _sampleStepMs,
  ]);

  /// Where to cut, best first: the chosen frame, else the old half-second
  /// frame, else the first frame (a clip shorter than half a second).
  static Iterable<int> _frameLadder(int? picked) => <int>{
    picked ?? _legacySeekMs,
    0,
  };

  /// The first sampled frame that is lit and done brightening (neither of
  /// the next two samples is much brighter), or null when none is (the
  /// caller keeps the old frame). Only the next two count: a flash or a
  /// brighter scene later in the window is content, not a fade. Frame 0
  /// counts only for a clip with nothing later.
  @visibleForTesting
  static int? pickPosterMs(List<PosterSample> samples) {
    final lit = samples.where((s) => s.luma != null).toList()
      ..sort((a, b) => a.atMs.compareTo(b.atMs));
    var pool = lit.where((s) => s.atMs >= _legacySeekMs).toList();
    if (pool.isEmpty) pool = lit;
    for (var i = 0; i < pool.length; i++) {
      final luma = pool[i].luma!;
      if (luma < _nearBlackLuma) continue;
      final rising = pool
          .skip(i + 1)
          .take(_settleLookahead)
          .any((next) => next.luma! > luma * _riseFactor + _riseSlack);
      if (!rising) return pool[i].atMs;
    }
    return null;
  }

  /// A later sample this much brighter means the picture is still fading in.
  static const double _riseFactor = 1.15;
  static const double _riseSlack = 4;
  static const int _settleLookahead = 2;

  /// One ffmpeg run that writes [_sampleCount] tiny frames, [_sampleStepMs]
  /// apart from the start, as concatenated WebP. Only `scale` and output
  /// rate conversion: the bundled minimal build has no stats or select filter.
  @visibleForTesting
  static List<String> posterSampleArgs(
    String videoPath, {
    required bool piped,
  }) => <String>[
    '-y',
    '-i',
    piped ? 'pipe:0' : videoPath,
    '-vf',
    'scale=$_sampleSide:$_sampleSide',
    '-r',
    '${1000 ~/ _sampleStepMs}',
    '-frames:v',
    '$_sampleCount',
    '-c:v',
    'libwebp',
    '-lossless',
    '1',
    '-compression_level',
    '0',
    '-f',
    'image2pipe',
    'pipe:1',
  ];

  /// The poster cut at [atMs].
  ///
  /// Every flag must exist in the MINIMAL build (vendor/ffmpeg). `-pred
  /// mixed` was rejected as "Unrecognized option" and silently killed EVERY
  /// extraction, taking video dimensions and posters with it. Test a new flag
  /// against the bundled binary, never a system ffmpeg.
  @visibleForTesting
  static List<String> posterFrameArgs(
    String videoPath, {
    required bool piped,
    required int atMs,
    required int targetHeight,
  }) {
    // On a pipe -ss has to follow -i, which decodes to the point instead of
    // jumping.
    final seek = atMs > 0
        ? <String>['-ss', (atMs / 1000).toStringAsFixed(3)]
        : const <String>[];
    return <String>[
      '-y',
      if (!piped) ...seek,
      '-i',
      piped ? 'pipe:0' : videoPath,
      if (piped) ...seek,
      '-vf',
      'scale=-2:$targetHeight',
      '-frames:v',
      '1',
      '-update',
      '1',
      '-c:v',
      'libwebp',
      '-lossless',
      '1',
      '-compression_level',
      '6',
      '-f',
      'image2pipe',
      'pipe:1',
    ];
  }

  /// The sampling run's frames, each with its time and luma.
  @visibleForTesting
  static List<PosterSample> samplesFromStream(Uint8List stream) {
    final frames = splitWebpStream(stream);
    return [
      for (var i = 0; i < frames.length && i < _sampleCount; i++)
        PosterSample(i * _sampleStepMs, meanLuma(frames[i])),
    ];
  }

  /// Splits image2pipe's back-to-back WebP files on their RIFF sizes; stops at
  /// the first one that does not parse.
  @visibleForTesting
  static List<Uint8List> splitWebpStream(Uint8List bytes) {
    final out = <Uint8List>[];
    var at = 0;
    while (at + 12 <= bytes.length &&
        isWebp(Uint8List.sublistView(bytes, at))) {
      final size =
          bytes[at + 4] |
          bytes[at + 5] << 8 |
          bytes[at + 6] << 16 |
          bytes[at + 7] << 24;
      final end = at + 8 + size;
      if (size < 4 || end > bytes.length) break;
      out.add(Uint8List.sublistView(bytes, at, end));
      at = end + (size & 1);
    }
    return out;
  }

  /// Whether [bytes] open as a RIFF WebP file.
  static bool isWebp(Uint8List bytes) =>
      bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50;

  /// Mean BT.601 luma (0-255) of a WebP still, null when it does not decode.
  @visibleForTesting
  static double? meanLuma(Uint8List webp) {
    try {
      final image = img.decodeWebP(webp);
      if (image == null || image.width == 0 || image.height == 0) return null;
      var sum = 0.0;
      for (final px in image) {
        sum +=
            0.299 * px.rNormalized +
            0.587 * px.gNormalized +
            0.114 * px.bNormalized;
      }
      return 255 * sum / (image.width * image.height);
    } catch (_) {
      return null;
    }
  }

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
    final proc = await (debugStartProcess ?? Process.start)(ffmpeg, args);
    // Armed before stdin: a pipe ffmpeg stops reading can block the write
    // itself, and the kill is what unblocks it.
    var timedOut = false;
    final deadline = Timer(timeout, () {
      timedOut = true;
      proc.kill(ProcessSignal.sigkill);
    });
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
      Future<void> write() async {
        try {
          proc.stdin.add(stdinBytes);
          await proc.stdin.flush();
        } catch (_) {}
        try {
          await proc.stdin.close();
        } catch (_) {}
      }

      // A process that ends or is killed mid-write leaves the write behind.
      await Future.any<void>([write(), proc.exitCode]);
    }

    final exitCode = await proc.exitCode;
    deadline.cancel();
    if (timedOut) throw TimeoutException('ffmpeg', timeout);
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
    final durMatch = RegExp(
      r'Duration:\s*(\d+):(\d+):(\d+)\.(\d+)',
    ).firstMatch(stderr);
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
    final videoStreamRe = RegExp(
      r'Stream #\d+:\d+.*?: Video:.*?(\d{2,5})x(\d{2,5})',
    );
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
