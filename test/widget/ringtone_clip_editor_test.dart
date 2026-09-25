import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/dialogs/ringtone_clip_editor_dialog.dart';

class _Start extends RingtoneStartNotifier {
  static double? saved;
  static bool fail = false;
  @override
  Future<double> build() async => 2.0;
  @override
  Future<void> setStart(double seconds) async {
    if (fail) throw Exception('disk says no');
    saved = seconds;
    state = AsyncData(seconds);
  }
}

class _End extends RingtoneEndNotifier {
  static double? saved;
  @override
  Future<double> build() async => 10.0;
  @override
  Future<void> setEnd(double seconds) async {
    saved = seconds;
    state = AsyncData(seconds);
  }
}

class _Duration extends RingtoneDurationNotifier {
  // The stale 60 s the old dialog trusted.
  @override
  Future<double> build() async => 60.0;
  @override
  Future<void> setDuration(double seconds) async => state = AsyncData(seconds);
}

class _Volume extends RingtoneVolumeNotifier {
  @override
  Future<double> build() async => 0.5;
}

/// Loud first half, a dead drop in the middle, a quieter tail: the shapes a
/// person trims around.
RingtoneWaveform _songLike(double seconds, {int buckets = 2048}) {
  final min = Float32List(buckets);
  final max = Float32List(buckets);
  final rms = Float32List(buckets);
  final rng = math.Random(7);
  for (var i = 0; i < buckets; i++) {
    final t = i / buckets;
    double level;
    if (t < 0.08) {
      level = t / 0.08 * 0.5;
    } else if (t < 0.45) {
      level = 0.55 + 0.35 * math.sin(t * 60).abs();
    } else if (t < 0.5) {
      level = 0.0;
    } else if (t < 0.52) {
      level = 1.0;
    } else {
      level = 0.3 + 0.2 * math.sin(t * 25).abs();
    }
    final jitter = 0.85 + rng.nextDouble() * 0.15;
    max[i] = level * jitter;
    min[i] = -level * (0.8 + rng.nextDouble() * 0.2);
    rms[i] = level * 0.45 * jitter;
  }
  return RingtoneWaveform(durationSecs: seconds, min: min, max: max, rms: rms);
}

List<Override> _overrides() => [
      ringtoneStartProvider.overrideWith(_Start.new),
      ringtoneEndProvider.overrideWith(_End.new),
      ringtoneDurationProvider.overrideWith(_Duration.new),
      ringtoneVolumeProvider.overrideWith(_Volume.new),
    ];

Future<void> _open(
  WidgetTester tester,
  Future<RingtoneWaveform> Function(String) load, {
  Size size = const Size(1280, 800),
  bool light = false,
  Key? boundaryKey,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(ProviderScope(
    overrides: _overrides(),
    child: RepaintBoundary(
      key: boundaryKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: light ? HollowThemeData.light() : HollowThemeData.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showHollowDialog(
                  context: context,
                  builder: (_) => RingtoneClipEditorDialog(
                    filePath: r'C:\Music\morning theme.mp3',
                    loadWaveform: load,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<Uint8List> _paint(RingtoneWaveformPainter painter, Size size) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF000000));
  painter.paint(canvas, size);
  final image = await recorder
      .endRecording()
      .toImage(size.width.toInt(), size.height.toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  setUp(() {
    _Start.saved = null;
    _Start.fail = false;
    _End.saved = null;
  });

  group('RingtoneWaveformPainter', () {
    const size = Size(200, 80);
    const muted = Color(0xFF808080);
    const accent = Color(0xFF00FF00);

    RingtoneWaveform halfLoudHalfSilent() {
      const n = 400;
      final min = Float32List(n);
      final max = Float32List(n);
      final rms = Float32List(n);
      for (var i = 0; i < n ~/ 2; i++) {
        min[i] = -1;
        max[i] = 1;
        rms[i] = 0.5;
      }
      // One narrow spike in the silent half, a single bucket wide.
      max[300] = 1;
      return RingtoneWaveform(durationSecs: 20, min: min, max: max, rms: rms);
    }

    int alphaAt(Uint8List px, int x, int y) {
      final i = (y * size.width.toInt() + x) * 4;
      return px[i] + px[i + 1] + px[i + 2];
    }

    testWidgets('draws the real envelope: loud reaches the top, silence stays '
        'a hairline, a one-bucket spike survives the fold', (tester) async {
      final painter = RingtoneWaveformPainter(
        wave: halfLoudHalfSilent(),
        start: 15,
        end: 19,
        playhead: null,
        accent: accent,
        muted: muted,
        playheadColor: const Color(0xFFFFFFFF),
      );
      final px = (await tester.runAsync(() => _paint(painter, size)))!;
      expect(alphaAt(px, 50, 3), greaterThan(0), reason: 'loud column near the top');
      expect(alphaAt(px, 50, 76), greaterThan(0), reason: 'loud column near the bottom');
      expect(alphaAt(px, 120, 10), 0, reason: 'silence is not drawn tall');
      expect(alphaAt(px, 120, 40), greaterThan(0), reason: 'silence keeps a hairline');
      expect(alphaAt(px, 150, 20), greaterThan(0), reason: 'the spike at bucket 300');
      // Inside the selection (15 to 19 s = x 150 to 190) the sound is accent.
      final i = (40 * 200 + 170) * 4;
      expect(px[i + 1], greaterThan(px[i]), reason: 'selected sound is accent');
    });

    testWidgets('a file with no peaks draws a flat line and the selection',
        (tester) async {
      final painter = RingtoneWaveformPainter(
        wave: const RingtoneWaveform(durationSecs: 20),
        start: 0,
        end: 10,
        playhead: 5,
        accent: accent,
        muted: muted,
        playheadColor: const Color(0xFFFFFFFF),
      );
      final px = (await tester.runAsync(() => _paint(painter, size)))!;
      expect(alphaAt(px, 150, 10), 0);
      expect(alphaAt(px, 150, 40), greaterThan(0));
    });
  });

  group('RingtoneClipEditorDialog', () {
    testWidgets('uses the decoded length, not a cached or made-up one',
        (tester) async {
      await _open(tester, (_) async => _songLike(12.3));
      expect(find.text('00:12.3'), findsOneWidget);
      expect(find.text('00:02.0'), findsOneWidget);
      expect(find.text('00:10.0'), findsOneWidget);
      expect(find.text('Drag an edge to trim, or the middle to move the '
          'selection.'), findsOneWidget);
      expect(find.text('8.0 s selected (30 s max)'), findsOneWidget);
    });

    testWidgets('every step control is a labelled HollowIconButton',
        (tester) async {
      await _open(tester, (_) async => _songLike(12.3));
      expect(find.byType(HollowIconButton), findsNWidgets(8));
      await tester.tap(find.byWidgetPredicate(
          (w) => w is HollowIconButton && w.label == 'Move 1 second later'));
      await tester.pump();
      expect(find.text('00:03.0'), findsOneWidget);
      expect(find.text('00:11.0'), findsOneWidget);
    });

    testWidgets('Save awaits both writes and closes', (tester) async {
      await _open(tester, (_) async => _songLike(12.3));
      await tester.tap(find.text('Save'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(_Start.saved, 2.0);
      expect(_End.saved, 10.0);
      expect(find.byType(RingtoneClipEditorDialog), findsNothing);
    });

    testWidgets('a failed save stays open with a plain line', (tester) async {
      _Start.fail = true;
      await _open(tester, (_) async => _songLike(12.3));
      await tester.tap(find.text('Save'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(RingtoneClipEditorDialog), findsOneWidget);
      expect(find.text("Hollow couldn't save the trim. Try again."),
          findsOneWidget);
    });

    testWidgets('a file whose sound cannot be drawn is trimmed by time',
        (tester) async {
      await _open(
          tester, (_) async => const RingtoneWaveform(durationSecs: 40));
      expect(find.text('00:40.0'), findsOneWidget);
      expect(find.textContaining("can't draw a waveform"),
          findsOneWidget);
    });

    testWidgets('an unreadable file says so instead of pretending 60 s',
        (tester) async {
      await _open(tester, (_) async => const RingtoneWaveform(durationSecs: 0));
      expect(find.textContaining("Hollow can't read this file"), findsOneWidget);
      expect(find.text('Save'), findsNothing);
      expect(find.textContaining('01:00'), findsNothing);
    });
  });

  // Renders for reading by eye. Output: $HOLLOW_SHOT_DIR or
  // build/ui_screenshots.
  group('screenshots', () {
    const shotKey = Key('shot');
    final outDir = Platform.environment['HOLLOW_SHOT_DIR'] ??
        '${Directory.current.path}${Platform.pathSeparator}build'
            '${Platform.pathSeparator}ui_screenshots';

    setUpAll(() async {
      final lucide = await rootBundle
          .load('packages/lucide_icons_flutter/assets/lucide.ttf');
      await (FontLoader('packages/lucide_icons_flutter/Lucide')
            ..addFont(Future.value(lucide)))
          .load();
      for (final face in Directory('assets/fonts').listSync()) {
        final name = face.uri.pathSegments.last;
        if (!name.endsWith('.ttf') ||
            !(name.startsWith('Onest') || name.startsWith('GeistMono'))) {
          continue;
        }
        final family = name.startsWith('Onest') ? 'Onest' : 'GeistMono';
        final bytes = File(face.path).readAsBytesSync();
        await (FontLoader(family)
              ..addFont(Future.value(ByteData.view(bytes.buffer))))
            .load();
      }
    });

    Future<void> capture(WidgetTester tester, String name) async {
      final boundary =
          tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        final file = File('$outDir${Platform.pathSeparator}$name.png');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(data!.buffer.asUint8List());
      });
    }

    for (final (name, size, light) in const [
      ('ringtone_trim_desktop_dark', Size(1100, 700), false),
      ('ringtone_trim_desktop_light', Size(1100, 700), true),
      ('ringtone_trim_phone_dark', Size(390, 844), false),
    ]) {
      testWidgets(name, (tester) async {
        await _open(tester, (_) async => _songLike(47.6),
            size: size, light: light, boundaryKey: shotKey);
        await capture(tester, name);
      });
    }
  });
}
