/// How a video's poster frame is chosen: the frame-choice rule given sampled
/// luma, the ffmpeg arguments the bundled minimal build must accept, the
/// split of ffmpeg's sample stream, and the platform-decoder path phones and
/// macOS take for a file the person picked.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/services/at_rest.dart';
import 'package:hollow/src/core/services/video_thumbnail_service.dart';
import 'package:path/path.dart' as p;

List<PosterSample> _samples(List<double?> lumas) => [
  for (var i = 0; i < lumas.length; i++) PosterSample(i * 500, lumas[i]),
];

/// A RIFF/WEBP shell with [payload] bytes after the form type.
Uint8List _riff(int payload, {int fill = 0}) {
  final size = 4 + payload;
  return Uint8List.fromList([
    0x52, 0x49, 0x46, 0x46, //
    size & 0xFF, (size >> 8) & 0xFF, (size >> 16) & 0xFF, (size >> 24) & 0xFF,
    0x57, 0x45, 0x42, 0x50,
    ...List<int>.filled(payload, fill),
  ]);
}

/// A stand-in ffmpeg run: [exit] null = it never ends on its own, only when
/// killed.
class _FakeRun implements Process {
  _FakeRun({int? exit, List<int> out = const [], String err = ''}) {
    if (exit != null) _exit.complete(exit);
    stdout = Stream<List<int>>.fromIterable([if (out.isNotEmpty) out]);
    stderr = Stream<List<int>>.fromIterable([err.codeUnits]);
  }

  final _exit = Completer<int>();

  @override
  late final Stream<List<int>> stdout;
  @override
  late final Stream<List<int>> stderr;

  /// A pipe whose reader never reads: every flush waits forever.
  bool stdinBlocks = false;

  @override
  late final IOSink stdin = stdinBlocks
      ? IOSink(_NeverDrains())
      : IOSink(StreamController<List<int>>().sink);
  @override
  Future<int> get exitCode => _exit.future;
  @override
  int get pid => 0;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exit.isCompleted) _exit.complete(-9);
    return true;
  }
}

class _NeverDrains implements StreamConsumer<List<int>> {
  @override
  Future<void> addStream(Stream<List<int>> stream) => Completer<void>().future;
  @override
  Future<void> close() => Completer<void>().future;
}

const _probe =
    'Duration: 00:00:06.00, start: 0.000000\n'
    '  Stream #0:0[0x1](und): Video: h264 (High), yuv420p, 640x360, 30 fps\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pickPosterMs', () {
    test('a_late_flash_does_not_move_a_steady_poster', () {
      final at = VideoThumbnailService.pickPosterMs(
        _samples([100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 250]),
      );
      expect(at, 500);
    });

    test('a_pan_to_a_brighter_scene_does_not_move_a_steady_poster', () {
      final at = VideoThumbnailService.pickPosterMs(
        _samples([60, 60, 60, 60, 60, 60, 200, 200, 200, 200, 200, 200]),
      );
      expect(at, 500);
    });

    test('a_dark_steady_video_keeps_the_old_frame', () {
      final at = VideoThumbnailService.pickPosterMs(
        _samples(List<double?>.filled(12, 20)),
      );
      expect(at, isNull);
    });

    test('a_fade_in_picks_the_first_frame_after_it_settles', () {
      // 0 to 2 s fade, then steady.
      final at = VideoThumbnailService.pickPosterMs(
        _samples([0, 15, 32, 64, 96, 128, 127, 129, 128, 126, 128, 127]),
      );
      expect(at, 2500);
    });

    test('a_steady_video_keeps_the_old_half_second_frame', () {
      final at = VideoThumbnailService.pickPosterMs(
        _samples([110, 112, 111, 109, 113, 110]),
      );
      expect(at, 500);
    });

    test('a_black_opening_is_skipped', () {
      final at = VideoThumbnailService.pickPosterMs(
        _samples([0, 0, 1, 2, 90, 92, 91]),
      );
      expect(at, 2000);
    });

    test('a_slow_fade_takes_the_first_frame_that_stops_rising', () {
      final at = VideoThumbnailService.pickPosterMs(
        _samples([0, 5, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100]),
      );
      expect(at, 5000, reason: '90 then 100: no longer rising much');
    });

    test('nothing_lit_means_no_choice_and_the_caller_keeps_the_old_frame', () {
      expect(
        VideoThumbnailService.pickPosterMs(_samples([0, 3, 8, 12, 20, 23])),
        isNull,
      );
      expect(VideoThumbnailService.pickPosterMs(const []), isNull);
      expect(
        VideoThumbnailService.pickPosterMs(_samples([null, null])),
        isNull,
      );
    });

    test('frame_zero_counts_only_for_a_clip_with_nothing_later', () {
      expect(VideoThumbnailService.pickPosterMs(_samples([120])), 0);
      expect(
        VideoThumbnailService.pickPosterMs(_samples([120, 10, 10])),
        isNull,
        reason: 'a later frame exists, so frame 0 is never the pick',
      );
      expect(VideoThumbnailService.pickPosterMs(_samples([5])), isNull);
    });

    test('unreadable_frames_are_skipped_not_counted_as_black', () {
      final at = VideoThumbnailService.pickPosterMs(
        _samples([0, null, null, 100, 101]),
      );
      expect(at, 1500);
    });
  });

  group('ffmpeg arguments', () {
    test('sampling_uses_only_what_the_minimal_build_has', () {
      for (final piped in const [false, true]) {
        final args = VideoThumbnailService.posterSampleArgs(
          '/v/clip.mp4',
          piped: piped,
        );
        final vf = args[args.indexOf('-vf') + 1];
        expect(
          vf,
          matches(RegExp(r'^scale=\d+:\d+$')),
          reason: 'the minimal build has scale and no other video filter',
        );
        expect(args[args.indexOf('-r') + 1], '2');
        expect(args[args.indexOf('-frames:v') + 1], '12');
        expect(args[args.indexOf('-i') + 1], piped ? 'pipe:0' : '/v/clip.mp4');
        expect(args, containsAllInOrder(['-c:v', 'libwebp']));
        expect(args.last, 'pipe:1');
        expect(args, isNot(contains('-ss')));
      }
      expect(VideoThumbnailService.posterSampleTimesMs, [
        0,
        500,
        1000,
        1500,
        2000,
        2500,
        3000,
        3500,
        4000,
        4500,
        5000,
        5500,
      ]);
    });

    test('a_file_seeks_before_input_and_a_pipe_after', () {
      final file = VideoThumbnailService.posterFrameArgs(
        '/v/a.mp4',
        piped: false,
        atMs: 2000,
        targetHeight: 480,
      );
      expect(file.indexOf('-ss'), lessThan(file.indexOf('-i')));
      expect(file[file.indexOf('-ss') + 1], '2.000');

      final pipe = VideoThumbnailService.posterFrameArgs(
        '/v/a.mp4',
        piped: true,
        atMs: 500,
        targetHeight: 480,
      );
      expect(pipe.indexOf('-ss'), greaterThan(pipe.indexOf('-i')));
      expect(pipe[pipe.indexOf('-i') + 1], 'pipe:0');
      expect(pipe[pipe.indexOf('-ss') + 1], '0.500');
      expect(pipe[pipe.indexOf('-vf') + 1], 'scale=-2:480');
    });

    test('the_first_frame_needs_no_seek', () {
      final args = VideoThumbnailService.posterFrameArgs(
        '/v/a.mp4',
        piped: false,
        atMs: 0,
        targetHeight: 480,
      );
      expect(args, isNot(contains('-ss')));
    });
  });

  group('splitWebpStream', () {
    test('back_to_back_files_split_on_their_sizes', () {
      final a = _riff(10, fill: 1);
      final b = _riff(3, fill: 2); // odd size: one pad byte follows
      final c = _riff(6, fill: 3);
      final stream = Uint8List.fromList([...a, ...b, 0, ...c]);
      final parts = VideoThumbnailService.splitWebpStream(stream);
      expect(parts.map((x) => x.length), [a.length, b.length, c.length]);
      expect(parts[1].last, 2);
      expect(parts[2].last, 3);
    });

    test('a_truncated_or_foreign_tail_stops_the_split', () {
      final a = _riff(8);
      final cut = _riff(20).sublist(0, 18);
      expect(
        VideoThumbnailService.splitWebpStream(
          Uint8List.fromList([...a, ...cut]),
        ).length,
        1,
      );
      expect(
        VideoThumbnailService.splitWebpStream(
          Uint8List.fromList([...a, ...List<int>.filled(16, 7)]),
        ).length,
        1,
      );
      expect(VideoThumbnailService.splitWebpStream(Uint8List(0)), isEmpty);
    });

    test('a_frame_that_does_not_decode_has_no_luma', () {
      expect(VideoThumbnailService.meanLuma(_riff(12)), isNull);
      final samples = VideoThumbnailService.samplesFromStream(
        Uint8List.fromList([..._riff(8), ..._riff(8)]),
      );
      expect(samples.map((s) => s.atMs), [0, 500]);
      expect(samples.every((s) => s.luma == null), isTrue);
    });
  });

  group('ffmpeg ladder', () {
    late Directory picks;
    late List<List<String>> runs;

    setUp(() {
      picks = Directory.systemTemp.createTempSync('hollow_poster_ladder');
      runs = [];
      VideoThumbnailService.debugNativeFrames = false;
      VideoThumbnailService.debugFfmpegPath = 'ffmpeg';
    });

    tearDown(() {
      VideoThumbnailService.debugNativeFrames = null;
      VideoThumbnailService.debugFfmpegPath = null;
      VideoThumbnailService.debugStartProcess = null;
      try {
        picks.deleteSync(recursive: true);
      } catch (_) {}
    });

    String picked() {
      final path = p.join(picks.path, 'clip.mp4');
      File(path).writeAsBytesSync([0, 0, 0, 0x18]);
      return path;
    }

    void serve(Process Function(int run) next) {
      VideoThumbnailService.debugStartProcess = (exe, args) async {
        runs.add(args);
        return next(runs.length);
      };
    }

    test('a_stalled_sampling_run_still_cuts_the_old_frame', () async {
      serve(
        (run) => run == 1
            ? _FakeRun()
            : _FakeRun(exit: 0, out: [1, 2, 3], err: _probe),
      );
      final watch = Stopwatch()..start();
      final result = await VideoThumbnailService.extractVideoThumbnail(
        videoPath: picked(),
      );
      expect(result?.posterBytes, [1, 2, 3]);
      expect(
        (result!.sourceWidth, result.sourceHeight, result.durationMs),
        (640, 360, 6000),
      );
      expect(runs, hasLength(2));
      expect(runs[1][runs[1].indexOf('-ss') + 1], '0.500');
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    });

    test('a_failed_sampling_run_still_cuts_the_old_frame', () async {
      serve(
        (run) => run == 1
            ? _FakeRun(exit: 1, err: 'Unrecognized option')
            : _FakeRun(exit: 0, out: [4, 5], err: _probe),
      );
      final result = await VideoThumbnailService.extractVideoThumbnail(
        videoPath: picked(),
      );
      expect(result?.posterBytes, [4, 5]);
      expect(runs[1][runs[1].indexOf('-ss') + 1], '0.500');
    });

    test('a_stdin_write_that_never_drains_still_times_out', () async {
      final run = _FakeRun()..stdinBlocks = true;
      VideoThumbnailService.debugStartProcess = (exe, args) async => run;
      final watch = Stopwatch()..start();
      await expectLater(
        VideoThumbnailService.runFfmpeg(
          'ffmpeg',
          const ['-i', 'pipe:0'],
          stdinBytes: Uint8List(64),
          timeout: const Duration(milliseconds: 300),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      expect(await run.exitCode, -9, reason: 'the stuck ffmpeg is killed');
    });

    test('a_failed_cut_is_no_poster', () async {
      serve(
        (run) => run == 1
            ? _FakeRun(exit: 1)
            : _FakeRun(exit: 1, err: 'Encoder not found'),
      );
      expect(
        await VideoThumbnailService.extractVideoThumbnail(videoPath: picked()),
        isNull,
      );
      expect(runs, hasLength(2), reason: 'a real error is not retried at 0');
    });
  });

  group('poster cache', () {
    late Directory root;
    late Directory picks;

    setUp(() {
      root = Directory.systemTemp.createTempSync('hollow_poster_cache_root');
      picks = Directory.systemTemp.createTempSync('hollow_poster_cache_pick');
      overrideHollowDataDir(root.path);
    });

    tearDown(() {
      for (final d in [root, picks]) {
        try {
          d.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    String pick(String folder, List<int> bytes) {
      final dir = Directory(p.join(picks.path, folder))..createSync();
      final path = p.join(dir.path, 'IMG_0001.MOV');
      File(path).writeAsBytesSync(bytes);
      return path;
    }

    test('two_picks_with_one_name_keep_their_own_posters', () {
      final a = pick('camera', [1, 2, 3]);
      final b = pick('downloads', [1, 2, 3]);
      final pa = VideoThumbnailService.thumbCachePathFor(a);
      expect(pa, isNotNull);
      expect(pa, VideoThumbnailService.thumbCachePathFor(a));
      expect(pa, isNot(VideoThumbnailService.thumbCachePathFor(b)));
      expect(p.basename(pa!), isNot(contains('IMG_0001')));
    });

    test('a_video_replaced_in_place_gets_a_new_poster', () {
      final a = pick('camera', [1, 2, 3]);
      final before = VideoThumbnailService.thumbCachePathFor(a);
      File(a).writeAsBytesSync([1, 2, 3, 4, 5]);
      expect(VideoThumbnailService.thumbCachePathFor(a), isNot(before));
    });
  });

  group('platform decoder', () {
    const channel = MethodChannel('hollow/video_poster');
    late Directory root;
    late Directory picks;
    late List<MethodCall> calls;
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
    Map<String, Object?> framed({int w = 640, int h = 360, int d = 3000}) => {
      'image': jpeg,
      'durationMs': d,
      'width': w,
      'height': h,
    };

    setUp(() {
      root = Directory.systemTemp.createTempSync('hollow_poster_native_root');
      picks = Directory.systemTemp.createTempSync('hollow_poster_native_pick');
      overrideHollowDataDir(root.path);
      calls = [];
      VideoThumbnailService.debugNativeFrames = true;
      VideoThumbnailService.debugFfmpegPath = null;
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      VideoThumbnailService.debugNativeFrames = null;
      VideoThumbnailService.debugFfmpegPath = null;
      VideoThumbnailService.debugStartProcess = null;
      VideoThumbnailService.extractBudget = const Duration(seconds: 10);
      VideoThumbnailService.sampleBudget = const Duration(seconds: 5);
      AtRest.debugRead = null;
      for (final d in [root, picks]) {
        try {
          d.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    void answer(Object? Function(MethodCall call) reply) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return reply(call);
          });
    }

    String picked() {
      final path = p.join(picks.path, 'IMG_0001.MOV');
      File(path).writeAsBytesSync([0, 0, 0, 0x18]);
      return path;
    }

    test('a_picked_video_takes_the_frame_after_its_fade', () async {
      answer(
        (call) => switch (call.method) {
          'sample' => {
            'durationMs': 6000,
            'width': 1080,
            'height': 1920,
            'lumas': [0.0, 15.0, 32.0, 64.0, 96.0, 128.0, 127.0, null],
          },
          'frame' => framed(w: 1, h: 1, d: 1),
          _ => null,
        },
      );
      final result = await VideoThumbnailService.extractVideoThumbnail(
        videoPath: picked(),
      );
      expect(result, isNotNull);
      expect(result!.posterBytes, jpeg);
      expect(result.posterExt, 'jpg');
      expect(
        (result.sourceWidth, result.sourceHeight, result.durationMs),
        (1080, 1920, 6000),
      );
      expect(calls.map((c) => c.method), ['sample', 'frame']);
      expect(
        calls[0].arguments['timesMs'],
        VideoThumbnailService.posterSampleTimesMs,
      );
      expect(calls[1].arguments['atMs'], 2500);
      expect(calls[1].arguments['maxHeight'], 480);
    });

    test('a_short_clip_falls_back_to_its_first_frame', () async {
      answer(
        (call) => switch (call.method) {
          'sample' => {
            'durationMs': 300,
            'width': 640,
            'height': 360,
            'lumas': [5.0],
          },
          // Nothing exists half a second in.
          'frame' => call.arguments['atMs'] == 0 ? framed() : null,
          _ => null,
        },
      );
      final result = await VideoThumbnailService.extractVideoThumbnail(
        videoPath: picked(),
      );
      expect(result?.posterBytes, jpeg);
      expect(calls.skip(1).map((c) => c.arguments['atMs']), [500, 0]);
    });

    test('a_failed_sample_still_cuts_the_old_frame', () async {
      answer(
        (call) => call.method == 'sample'
            ? throw PlatformException(code: 'boom')
            : framed(w: 1920, h: 1080, d: 4000),
      );
      final result = await VideoThumbnailService.extractVideoThumbnail(
        videoPath: picked(),
      );
      expect(result?.posterBytes, jpeg);
      expect(
        (result!.sourceWidth, result.sourceHeight, result.durationMs),
        (1920, 1080, 4000),
        reason: 'the frame answer carries the dimensions when sampling did not',
      );
      expect(calls.last.arguments['atMs'], 500);
    });

    test(
      'a_platform_sample_that_never_answers_still_cuts_the_old_frame',
      () async {
        VideoThumbnailService.sampleBudget = const Duration(milliseconds: 200);
        VideoThumbnailService.extractBudget = const Duration(milliseconds: 800);
        answer(
          (call) => call.method == 'sample'
              ? Completer<Object?>().future
              : framed(w: 1280, h: 720, d: 9000),
        );
        final watch = Stopwatch()..start();
        final result = await VideoThumbnailService.extractVideoThumbnail(
          videoPath: picked(),
        );
        expect(result?.posterBytes, jpeg);
        expect((result!.sourceWidth, result.sourceHeight), (1280, 720));
        expect(calls.last.arguments['atMs'], 500);
        expect(watch.elapsed, lessThan(const Duration(milliseconds: 800)));
      },
    );

    test('a_platform_frame_that_never_answers_ends_at_the_budget', () async {
      VideoThumbnailService.sampleBudget = const Duration(milliseconds: 200);
      VideoThumbnailService.extractBudget = const Duration(milliseconds: 500);
      answer(
        (call) => call.method == 'sample'
            ? {
                'durationMs': 6000,
                'width': 640,
                'height': 360,
                'lumas': [90.0],
              }
            : Completer<Object?>().future,
      );
      final watch = Stopwatch()..start();
      final result = await VideoThumbnailService.extractVideoThumbnail(
        videoPath: picked(),
      );
      expect(result, isNull);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('an_attachment_on_disk_never_reaches_the_platform_decoder', () async {
      answer((call) => fail('the platform decoder saw ${call.arguments}'));
      final files = Directory(p.join(root.path, 'files'))
        ..createSync(recursive: true);
      final path = p.join(files.path, 'received.mp4');
      File(path).writeAsBytesSync([0x48, 0x46, 0x45, 0x31]);

      // A phone has no ffmpeg: no poster, and no plaintext copy either.
      expect(
        await VideoThumbnailService.extractVideoThumbnail(videoPath: path),
        isNull,
      );

      // Where an ffmpeg exists, it reads the ciphertext through our pipe.
      final runs = <List<String>>[];
      AtRest.debugRead = (_) async => Uint8List.fromList([0, 0, 0, 0x18]);
      VideoThumbnailService.debugFfmpegPath = 'ffmpeg';
      VideoThumbnailService.debugStartProcess = (exe, args) async {
        runs.add(args);
        throw const ProcessException('ffmpeg', <String>[], 'stubbed');
      };
      expect(
        await VideoThumbnailService.extractVideoThumbnail(videoPath: path),
        isNull,
      );
      expect(runs, hasLength(1));
      expect(runs.single, contains('pipe:0'));
      expect(calls, isEmpty);
    });
  });
}
