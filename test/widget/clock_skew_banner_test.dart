// Issue #72: the clock warning's thresholds, copy and banner.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/clock_skew_provider.dart';
import 'package:hollow/src/core/services/date_time_settings.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/shell/clock_skew_banner.dart';

void main() {
  group('level', () {
    test('a minute either way is quiet, past it warns, past four minutes is urgent', () {
      for (final sign in [1, -1]) {
        expect(clockSkewLevelFor(sign * 60, ClockSkewLevel.none), ClockSkewLevel.none);
        expect(clockSkewLevelFor(sign * 61, ClockSkewLevel.none), ClockSkewLevel.warn);
        expect(clockSkewLevelFor(sign * 82, ClockSkewLevel.none), ClockSkewLevel.warn);
        expect(clockSkewLevelFor(sign * 240, ClockSkewLevel.none), ClockSkewLevel.warn);
        expect(clockSkewLevelFor(sign * 241, ClockSkewLevel.none), ClockSkewLevel.urgent);
      }
    });

    test('a showing warning holds until the clock is clearly back', () {
      expect(clockSkewLevelFor(58, ClockSkewLevel.warn), ClockSkewLevel.warn);
      expect(clockSkewLevelFor(54, ClockSkewLevel.warn), ClockSkewLevel.none);
      expect(clockSkewLevelFor(58, ClockSkewLevel.none), ClockSkewLevel.none);
    });
  });

  group('notifier', () {
    test('clears when the clock is fixed, a dismissal holds until it gets worse', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(clockSkewProvider.notifier);
      expect(c.read(clockSkewProvider).visible, isFalse);
      n.onOffset(82);
      expect(c.read(clockSkewProvider).visible, isTrue);
      n.dismiss();
      expect(c.read(clockSkewProvider).visible, isFalse);
      n.onOffset(90);
      expect(c.read(clockSkewProvider).visible, isFalse, reason: 'still the dismissed level');
      n.onOffset(-600);
      expect(c.read(clockSkewProvider).level, ClockSkewLevel.urgent);
      expect(c.read(clockSkewProvider).visible, isTrue, reason: 'a louder level shows again');
      n.onOffset(1);
      expect(c.read(clockSkewProvider).visible, isFalse);
      n.onOffset(82);
      expect(c.read(clockSkewProvider).visible, isTrue, reason: 'a fixed clock forgot the dismissal');
      n.onOffset(null);
      expect(c.read(clockSkewProvider).visible, isFalse, reason: 'a relay that tells no time backs no warning');
      expect(c.read(clockSkewProvider).offsetSecs, isNull);
    });
  });

  group('copy', () {
    test('says how far and which way in plain words', () {
      expect(clockSkewHeadline(82), 'Your device clock is 82 seconds behind');
      expect(clockSkewHeadline(-180), 'Your device clock is 3 minutes ahead');
      expect(clockSkewHeadline(-1), 'Your device clock is 1 second ahead');
      expect(clockSkewHeadline(5 * 3600), 'Your device clock is 5 hours behind');
      expect(clockSkewHeadline(3 * 86400), 'Your device clock is 3 days behind');
    });

    test('the urgent words say what goes wrong for the way the clock is off', () {
      expect(clockSkewDetail(ClockSkewLevel.urgent, offsetSecs: -600, canOpen: true, ios: false),
          startsWith('Others may not get your messages, and you may miss their calls.'));
      expect(clockSkewDetail(ClockSkewLevel.urgent, offsetSecs: 600, canOpen: true, ios: false),
          startsWith('You may not get messages from others, and they may miss your calls.'));
    });

    test('carries no em dash and no colon', () {
      for (final level in [ClockSkewLevel.warn, ClockSkewLevel.urgent]) {
        for (final canOpen in [true, false]) {
          for (final ios in [true, false]) {
            for (final off in [-700, 700]) {
              final s = clockSkewHeadline(off) +
                  clockSkewDetail(level, offsetSecs: off, canOpen: canOpen, ios: ios);
              expect(s.contains('—'), isFalse);
              expect(s.contains(':'), isFalse);
            }
          }
        }
      }
    });
  });

  group('banner', () {
    Widget app(ProviderContainer c) => UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: HollowThemeData.dark(),
            home: const Scaffold(body: Column(children: [ClockSkewBanner()])),
          ),
        );

    testWidgets('shows past a minute, goes away when the clock is right', (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(app(c));
      expect(find.textContaining('Your device clock'), findsNothing);
      c.read(clockSkewProvider.notifier).onOffset(82);
      await tester.pump();
      expect(find.text('Your device clock is 82 seconds behind'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Dismiss clock warning')), findsOneWidget);
      c.read(clockSkewProvider.notifier).onOffset(-600);
      await tester.pump();
      expect(find.text('Your device clock is 10 minutes ahead'), findsOneWidget);
      expect(find.textContaining('Others may not get your messages'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Dismiss clock warning')), findsNothing,
          reason: 'the urgent state cannot be put away');
      c.read(clockSkewProvider.notifier).onOffset(0);
      await tester.pump();
      expect(find.textContaining('Your device clock'), findsNothing);
    });

    testWidgets('on a phone the button sits under the words, beside them on a desktop',
        (tester) async {
      Future<bool> stacked(Size size) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        final c = ProviderContainer();
        addTearDown(c.dispose);
        c.read(clockSkewProvider.notifier).onOffset(-600);
        await tester.pumpWidget(app(c));
        final words = tester.getRect(find.textContaining('Others may not get'));
        final button = find.text('Open time settings');
        if (button.evaluate().isEmpty) return false;
        return tester.getRect(button).top > words.bottom;
      }

      addTearDown(tester.view.reset);
      if (!canOpenDateTimeSettings) return;
      expect(await stacked(const Size(375, 800)), isTrue);
      expect(await stacked(const Size(1280, 800)), isFalse);
    });
  });
}
