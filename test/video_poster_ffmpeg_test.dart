/// A real ffmpeg cuts a poster from real clips: one that fades in from black
/// over two seconds, one shorter than half a second, and one that is black
/// throughout. The poster must not be black where the clip has anything
/// else to show, and every clip gets one.
///
/// Runs only where an ffmpeg exists: `HOLLOW_TEST_FFMPEG` names one (the
/// bundled minimal build on Windows), else a system ffmpeg. The minimal build
/// cannot make clips (no lavfi, no H.264 encoder), so `HOLLOW_TEST_POSTER_CLIPS`
/// may name a folder holding `fade_in.mp4`, `short.mp4` and `black.mp4` made
/// elsewhere; otherwise the clips are generated here.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/services/at_rest.dart';
import 'package:hollow/src/core/services/video_thumbnail_service.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

const _systemFfmpegs = [
  '/opt/homebrew/bin/ffmpeg',
  '/usr/local/bin/ffmpeg',
  '/usr/bin/ffmpeg',
];

/// An ffmpeg that can write the poster: the app's own encoder is libwebp,
/// which some system builds (Homebrew's 9.x) leave out.
String? _findFfmpeg() {
  final named = Platform.environment['HOLLOW_TEST_FFMPEG'];
  for (final c in [
    ?named,
    'vendor/ffmpeg/ffmpeg-win-x64.exe',
    'vendor/ffmpeg/ffmpeg-macos-arm64',
    'vendor/ffmpeg/ffmpeg-macos-x64',
    'vendor/ffmpeg/ffmpeg-linux-x64',
    ..._systemFfmpegs,
  ]) {
    if (!File(c).existsSync()) continue;
    try {
      final r = Process.runSync(c, const ['-hide_banner', '-encoders']);
      if ('${r.stdout}'.contains('libwebp')) return File(c).absolute.path;
    } catch (_) {}
  }
  return null;
}

/// Mean BT.601 luma (0-255) of an encoded still.
double _luma(Uint8List encoded) {
  final image = img.decodeImage(encoded);
  if (image == null) fail('the poster does not decode');
  var sum = 0.0;
  for (final px in image) {
    sum += 0.299 * px.r + 0.587 * px.g + 0.114 * px.b;
  }
  return sum / (image.width * image.height);
}

void main() {
  final ffmpeg = _findFfmpeg();
  final skip = ffmpeg == null ? 'no ffmpeg on this machine' : null;

  late Directory work;
  late Directory root;
  final clips = <String, String>{};

  setUpAll(() async {
    if (ffmpeg == null) return;
    work = Directory.systemTemp.createTempSync('hollow_poster_clips');
    final given = Platform.environment['HOLLOW_TEST_POSTER_CLIPS'];
    for (final name in const ['fade_in', 'short', 'black']) {
      final path = given != null
          ? p.join(given, '$name.mp4')
          : p.join(work.path, '$name.mp4');
      clips[name] = path;
    }
    if (given != null) return;
    // Any ffmpeg with lavfi and H.264 makes the clips; the bundled one may not.
    Future<void> make(String out, String source, List<String> vf) async {
      final makers = [
        ffmpeg,
        ..._systemFfmpegs.where((c) => File(c).existsSync()),
      ];
      for (final maker in makers) {
        final r = await Process.run(maker, [
          '-hide_banner', '-loglevel', 'error', '-y', //
          '-f', 'lavfi', '-i', source,
          ...vf,
          '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
          // A pipe cannot reach a moov atom written at the end.
          '-movflags', '+faststart', out,
        ]);
        if (r.exitCode == 0) return;
      }
      fail('no ffmpeg here can make $out');
    }

    await make(clips['fade_in']!, 'testsrc2=size=640x360:rate=30:duration=6', [
      '-vf',
      'fade=t=in:st=0:d=2',
    ]);
    await make(
      clips['short']!,
      'testsrc2=size=640x360:rate=30:duration=0.3',
      const [],
    );
    await make(
      clips['black']!,
      'color=black:size=640x360:rate=30:duration=3',
      const [],
    );
  });

  tearDownAll(() {
    if (ffmpeg == null) return;
    try {
      work.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    if (ffmpeg == null) return;
    root = Directory.systemTemp.createTempSync('hollow_poster_root');
    overrideHollowDataDir(root.path);
    VideoThumbnailService.debugFfmpegPath = ffmpeg;
    // ffmpeg's path on every host, picked files too (macOS would ask AVFoundation).
    VideoThumbnailService.debugNativeFrames = false;
    AtRest.debugRead = (path) => File(path).readAsBytes();
  });

  tearDown(() {
    VideoThumbnailService.debugFfmpegPath = null;
    VideoThumbnailService.debugNativeFrames = null;
    AtRest.debugRead = null;
    if (ffmpeg == null) return;
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// The clip as a received attachment: under the data root, so the service
  /// pipes its bytes instead of naming the file.
  String managedCopy(String name) {
    final dir = Directory(p.join(root.path, 'files'))
      ..createSync(recursive: true);
    final dest = p.join(dir.path, '$name.mp4');
    File(clips[name]!).copySync(dest);
    expect(AtRest.isManaged(dest), isTrue);
    return dest;
  }

  /// The frame the old code took: half a second in.
  Future<Uint8List> frameAt(String path, String seek) async {
    final run = await VideoThumbnailService.runFfmpeg(ffmpeg!, [
      '-y', '-ss', seek, '-i', path, //
      '-vf', 'scale=-2:480', '-frames:v', '1', '-update', '1',
      '-c:v', 'libwebp', '-lossless', '1', '-compression_level', '6',
      '-f', 'image2pipe', 'pipe:1',
    ]);
    expect(run.exitCode, 0, reason: run.stderrText);
    return run.stdoutBytes;
  }

  test('sampling_sees_the_fade_rise_then_settle', () async {
    final run = await VideoThumbnailService.runFfmpeg(
      ffmpeg!,
      VideoThumbnailService.posterSampleArgs(clips['fade_in']!, piped: false),
    );
    expect(run.exitCode, 0, reason: run.stderrText);
    final samples = VideoThumbnailService.samplesFromStream(run.stdoutBytes);
    expect(samples, hasLength(12));
    final lumas = [for (final s in samples) s.luma!];
    // Half-second steps through a two-second fade, then the steady picture.
    for (var i = 1; i <= 4; i++) {
      expect(lumas[i], greaterThan(lumas[i - 1]), reason: '$lumas');
    }
    expect(lumas[0], lessThan(5), reason: '$lumas');
    expect(lumas[5], closeTo(lumas[11], 12), reason: '$lumas');
    expect(
      VideoThumbnailService.pickPosterMs(samples),
      inInclusiveRange(1500, 2500),
      reason: '$lumas',
    );
  }, skip: skip);

  test('the_old_half_second_frame_of_a_fade_in_is_black', () async {
    final old = await frameAt(clips['fade_in']!, '00:00:00.5');
    final full = await frameAt(clips['fade_in']!, '00:00:04');
    expect(_luma(full), greaterThan(60), reason: 'the clip itself is bright');
    expect(
      _luma(old),
      lessThan(0.3 * _luma(full)),
      reason: 'what every fade-in video showed as its poster',
    );
  }, skip: skip);

  for (final piped in const [false, true]) {
    final how = piped ? 'through_a_pipe' : 'from_a_picked_file';

    test('a_fade_in_poster_is_not_black_$how', () async {
      final path = piped ? managedCopy('fade_in') : clips['fade_in']!;
      final full = _luma(await frameAt(clips['fade_in']!, '00:00:04'));
      final watch = Stopwatch()..start();
      final result = await VideoThumbnailService.extractVideoThumbnail(
        videoPath: path,
      );
      watch.stop();
      expect(result, isNotNull);
      expect(
        _luma(result!.posterBytes),
        greaterThan(0.8 * full),
        reason: 'the poster is a frame after the fade, not inside it',
      );
      expect(result.sourceWidth, 640);
      expect(result.sourceHeight, 360);
      expect(result.durationMs, inInclusiveRange(5900, 6100));
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    }, skip: skip);

    test(
      'a_clip_shorter_than_half_a_second_still_gets_a_poster_$how',
      () async {
        final path = piped ? managedCopy('short') : clips['short']!;
        final result = await VideoThumbnailService.extractVideoThumbnail(
          videoPath: path,
        );
        expect(result, isNotNull, reason: 'a 0.3 s clip has a frame at 0');
        expect(_luma(result!.posterBytes), greaterThan(40));
        expect(result.sourceWidth, 640);
      },
      skip: skip,
    );

    test('a_black_clip_still_gets_its_old_poster_$how', () async {
      final path = piped ? managedCopy('black') : clips['black']!;
      final result = await VideoThumbnailService.extractVideoThumbnail(
        videoPath: path,
      );
      expect(
        result,
        isNotNull,
        reason: 'nothing better exists, so the old frame stands',
      );
      expect(_luma(result!.posterBytes), lessThan(10));
    }, skip: skip);
  }
}
