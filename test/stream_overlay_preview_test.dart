import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/ui/settings/stream_overlay/overlay_preview_engine.dart';
import 'package:hollow/src/ui/settings/stream_overlay/overlay_stage.dart';

/// The look editor's preview must draw what OBS draws: these pin the engine to
/// `node/overlay_page/overlay.js` (Person.render, scheduleBlink) and the stage
/// to `overlay.css`.
void main() {
  const idle = 'a';
  const talk = 'b';
  const loud = 'c';
  const blink = 'd';
  const muted = 'e';

  OverlayPreviewLook look({
    Map<String, String> states = const {'idle': idle, 'talking': talk},
    int holdMs = 250,
    bool scale = false,
    bool avatar = false,
  }) =>
      OverlayPreviewLook(
        states: states,
        holdMs: holdMs,
        blinkEverySec: 5,
        loudThreshold: 0.75,
        scaleWithVoice: scale,
        hasAvatar: avatar,
      );

  // Timers run on the test's fake clock; [now] is the engine's own clock,
  // moved with it.
  var now = 0;
  Future<void> elapse(WidgetTester tester, int ms) async {
    for (var i = 0; i < ms; i += 10) {
      now += 10;
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  setUp(() => now = 0);

  testWidgets('the talking image holds for hold_ms after speech ends, then idles',
      (tester) async {
    {
      final e = OverlayPreviewEngine(look: look(), nowMs: () => now);
      e.update(state: 'talking', level: 0.5);
      expect(e.value.shown, 'talking');
      expect(e.value.image, talk);
      e.update(state: 'idle', level: 0);
      await elapse(tester, 240);
      expect(e.value.shown, 'talking', reason: 'still inside the hold');
      await elapse(tester, 20);
      expect(e.value.shown, 'idle');
      expect(e.value.image, idle);
      e.dispose();
    }
  });

  testWidgets('loud shows at or above the threshold and holds on the way down',
      (tester) async {
    {
      final e = OverlayPreviewEngine(
          look: look(states: {'idle': idle, 'talking': talk, 'loud': loud}),
          nowMs: () => now);
      e.update(state: 'talking', level: 0.74);
      expect(e.value.image, talk);
      e.update(state: 'talking', level: 0.75);
      expect(e.value.loud, isTrue);
      expect(e.value.image, loud);
      e.update(state: 'talking', level: 0.3);
      expect(e.value.image, loud, reason: 'the loud hold');
      await elapse(tester, 260);
      expect(e.value.loud, isFalse);
      expect(e.value.image, talk);
      e.dispose();
    }
  });

  test('without a loud image, loud keeps the talking image', () {
    final e = OverlayPreviewEngine(look: look());
    e.update(state: 'talking', level: 1);
    expect(e.value.loud, isTrue);
    expect(e.value.image, talk);
    e.dispose();
  });

  test('no talking image: idle image while talking; no idle: the avatar', () {
    final e = OverlayPreviewEngine(
        look: look(states: const {}, avatar: true));
    e.update(state: 'talking', level: 0.5);
    expect(e.value.image, kOverlayAvatarLayer);
    e.look = look(states: const {});
    expect(e.value.image, isNull, reason: 'no avatar either: initials');
    e.dispose();
  });

  test('muted without its own image stands in with the idle image', () {
    final e = OverlayPreviewEngine(look: look());
    e.update(state: 'muted', level: 0);
    expect(e.value.standIn, isTrue);
    expect(e.value.image, idle);
    e.look = look(states: const {'idle': idle, 'muted': muted});
    expect(e.value.standIn, isFalse);
    expect(e.value.image, muted);
    e.dispose();
  });

  testWidgets('a blink lasts 150 ms and comes every N s give or take 40%',
      (tester) async {
    {
      final e = OverlayPreviewEngine(
        look: look(states: const {'idle': idle, 'blink': blink}),
        random: math.Random(1),
        nowMs: () => now,
      );
      expect(e.blinkArmed, isTrue);
      await elapse(tester, 2990);
      expect(e.value.blinking, isFalse, reason: 'never before 60% of 5 s');
      var at = -1;
      for (var ms = 3000; ms <= 7000 && at < 0; ms += 10) {
        await elapse(tester, 10);
        if (e.value.blinking) at = ms;
      }
      expect(at, inInclusiveRange(3000, 7000));
      expect(e.value.image, blink);
      await elapse(tester, 130);
      expect(e.value.blinking, isTrue);
      await elapse(tester, 30);
      expect(e.value.blinking, isFalse);
      expect(e.value.image, idle);
      e.dispose();
    }
  });

  test('no blink while talking, and the waiting blink is dropped', () {
    final e = OverlayPreviewEngine(
        look: look(states: const {'idle': idle, 'blink': blink}));
    expect(e.blinkArmed, isTrue);
    e.update(state: 'talking', level: 0.5);
    expect(e.blinkArmed, isFalse);
    e.blinkNow();
    expect(e.value.blinking, isFalse);
    e.dispose();
  });

  test('blinkWait stays within 60% to 140% of the period', () {
    final r = math.Random(7);
    for (var i = 0; i < 500; i++) {
      final ms = blinkWait(5, r).inMilliseconds;
      expect(ms, inInclusiveRange(3000, 7000));
    }
  });

  test('scale with voice: amp = min(1.3, 0.3 + level), else 1', () {
    final e = OverlayPreviewEngine(look: look(scale: true));
    e.update(state: 'talking', level: 0.5);
    expect(e.value.amp, closeTo(0.8, 1e-9));
    e.update(state: 'talking', level: 1);
    expect(e.value.amp, closeTo(1.3, 1e-9));
    e.look = look();
    expect(e.value.amp, 1.0);
    e.dispose();
  });

  test('shake keyframes: rest, left at 25%, right at 75%, rest', () {
    expect(shakeAt(0).$1, 0);
    expect(shakeAt(17).$1, closeTo(-17 / 35, 1e-9), reason: 'left first');
    expect(shakeAt(35).$1, closeTo(-1, 1e-9));
    expect(shakeAt(70).$1, closeTo(0, 1e-9));
    expect(shakeAt(105).$1, closeTo(1, 1e-9));
    expect(shakeAt(105).$2, closeTo(1.5, 1e-9));
    expect(shakeAt(140).$1, 0, reason: 'a new cycle');
  });

  test('dim is brightness 0.6, grayscale is the CSS luminance matrix', () {
    final dim = filterMatrix(0.6, 0);
    expect(dim[0], closeTo(0.6, 1e-9));
    expect(dim[1], closeTo(0, 1e-9));
    final gray = filterMatrix(1, 1);
    expect(gray.sublist(0, 3), [0.2126, 0.7152, 0.0722]);
    expect(gray.sublist(5, 8), [0.2126, 0.7152, 0.0722]);
  });

  group('the circle belongs to the avatar layer', () {
    Widget stage(String? image) => MaterialApp(
          home: Center(
            child: OverlayStage(
              size: 160,
              frame: OverlayPreviewFrame(shown: 'idle', image: image),
              effects: const OverlayStageEffects(
                  talking: 'none', transition: 'crossfade'),
              colour: const Color(0xFF5EB5FF),
              initials: 'VI',
              layers: const {kOverlayAvatarLayer, talk},
              layerBuilder: (key, fit) => SizedBox.expand(
                  key: ValueKey('layer-$key'),
                  child: FittedBox(fit: fit, child: const SizedBox.square(dimension: 10))),
            ),
          ),
        );

    bool round(WidgetTester tester, String key) => find
        .ancestor(
            of: find.byKey(ValueKey('layer-$key')),
            matching: find.byType(ClipOval))
        .evaluate()
        .isNotEmpty;

    double opacityOf(WidgetTester tester, Finder f) => tester
        .widget<AnimatedOpacity>(
            find.ancestor(of: f, matching: find.byType(AnimatedOpacity)).first)
        .opacity;

    testWidgets('an outgoing avatar keeps its circle through the fade, both ways',
        (tester) async {
      await tester.pumpWidget(stage(kOverlayAvatarLayer));
      expect(round(tester, kOverlayAvatarLayer), isTrue);
      expect(round(tester, talk), isFalse, reason: 'a look image keeps its shape');

      await tester.pumpWidget(stage(talk));
      await tester.pump(const Duration(milliseconds: 60));
      expect(round(tester, kOverlayAvatarLayer), isTrue, reason: 'mid-fade, leaving');
      expect(round(tester, talk), isFalse);

      await tester.pumpWidget(stage(kOverlayAvatarLayer));
      await tester.pump(const Duration(milliseconds: 60));
      expect(round(tester, kOverlayAvatarLayer), isTrue, reason: 'mid-fade, arriving');
      await tester.pumpAndSettle();
    });

    testWidgets('the initials fade out under an arriving image rather than vanish',
        (tester) async {
      await tester.pumpWidget(stage(null));
      final initials = find.text('VI');
      expect(opacityOf(tester, initials), 1);
      await tester.pumpWidget(stage(talk));
      await tester.pump(const Duration(milliseconds: 60));
      expect(initials, findsOneWidget, reason: 'still on screen mid-fade');
      expect(opacityOf(tester, initials), 0, reason: 'fading towards 0');
      await tester.pumpAndSettle();
    });
  });
}
