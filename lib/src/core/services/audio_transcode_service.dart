import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/services/at_rest.dart';
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

    // Both ends are pipes: the source is ciphertext on disk and the WAV must
    // not touch it as plaintext either.
    final args = [
      '-hide_banner',
      '-loglevel', 'error',
      '-y',
      '-i', 'pipe:0',
      '-c:a', 'pcm_s16le',
      '-ar', '16000',
      '-ac', '1',
      '-f', 'wav',
      'pipe:1',
    ];

    int exitCode;
    Uint8List wav;
    String stderrText;
    if (runner != null) {
      final result = await runner(ffmpeg, args);
      exitCode = result.exitCode;
      wav = Uint8List(0);
      stderrText = '${result.stderr}';
    } else {
      final run = await VideoThumbnailService.runFfmpeg(
        ffmpeg,
        args,
        stdinBytes: await AtRest.read(inputPath),
        timeout: const Duration(seconds: 30),
      );
      exitCode = run.exitCode;
      wav = run.stdoutBytes;
      stderrText = run.stderrText;
    }

    if (exitCode != 0 || wav.isEmpty) {
      // ignore: avoid_print
      print('[AudioTranscode] ffmpeg exit=$exitCode stderr=$stderrText');
      return null;
    }

    await AtRest.write(cachePath, patchWavSizes(wav));
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

/// Fills in the RIFF and `data` lengths of a WAV that ffmpeg wrote to a pipe.
///
/// A non-seekable output cannot be rewound, so ffmpeg leaves both fields at
/// 0xFFFFFFFF and Media Foundation refuses the file. Returns [wav] unchanged
/// when it is not a WAV, so a caller never has to check first.
Uint8List patchWavSizes(Uint8List wav) {
  if (wav.length < 44) return wav;
  final view = ByteData.sublistView(wav);
  if (_tagAt(wav, 0) != 'RIFF' || _tagAt(wav, 8) != 'WAVE') return wav;

  view.setUint32(4, wav.length - 8, Endian.little);

  var offset = 12;
  while (offset + 8 <= wav.length) {
    final tag = _tagAt(wav, offset);
    final size = view.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (tag == 'data') {
      view.setUint32(offset + 4, wav.length - body, Endian.little);
      return wav;
    }
    // A placeholder length before `data` means the chunk table is unusable.
    if (size == 0xFFFFFFFF || body + size > wav.length) return wav;
    offset = body + size + (size.isOdd ? 1 : 0);
  }
  return wav;
}

String _tagAt(Uint8List bytes, int offset) =>
    String.fromCharCodes(bytes, offset, offset + 4);
