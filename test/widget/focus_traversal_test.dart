import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';

/// Phase 2.6 — keyboard focus + activation.
///
/// Proves the three core interactive components are KEYBOARD-OPERABLE:
///   - they enter the Tab focus chain (so `Tab` reaches them and Voice
///     Control's numbered overlays land correctly),
///   - Enter / Space activate the focused control,
///   - activation fires the callback EXACTLY ONCE (the GestureDetector +
///     Semantics(onTap) + ActivateAction must not stack), and
///   - a disabled control is NOT focusable.
///
/// Runs headless (~1s); stands in for the device keyboard pass on the
/// foundation mechanics. (The real per-surface Tab-order sweep is Vitalik's.)
Widget _host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: HollowThemeData.dark(),
      home: Scaffold(body: Center(child: child)),
    );

/// Moves keyboard focus to the next focusable, then activates with [key].
Future<void> _tabThenPress(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.pumpAndSettle();
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  group('HollowButton keyboard', () {
    testWidgets('Tab focuses + Enter activates exactly once', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(HollowButton.filled(
          onPressed: () => taps++,
          child: const Text('Save'),
        )),
      );

      await _tabThenPress(tester, LogicalKeyboardKey.enter);
      expect(taps, 1, reason: 'Enter on a focused button fires onPressed once');
    });

    testWidgets('Space activates exactly once', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(HollowButton.filled(
          onPressed: () => taps++,
          child: const Text('Save'),
        )),
      );

      await _tabThenPress(tester, LogicalKeyboardKey.space);
      expect(taps, 1, reason: 'Space on a focused button fires onPressed once');
    });

    testWidgets('disabled button is not focusable', (tester) async {
      await tester.pumpWidget(
        _host(const HollowButton.filled(onPressed: null, child: Text('Save'))),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      // Nothing focusable in the tree → focus stays on the root scope, which
      // has no enclosing context node.
      expect(
        FocusManager.instance.primaryFocus?.context,
        anyOf(isNull, isNot(_isWithin<HollowFocusRing>(tester))),
        reason: 'a disabled button must stay out of the focus chain',
      );
    });
  });

  group('HollowPressable keyboard', () {
    testWidgets('Tab focuses + Enter activates exactly once', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(HollowPressable(
          onTap: () => taps++,
          semanticLabel: 'Settings',
          child: const Icon(Icons.settings),
        )),
      );

      await _tabThenPress(tester, LogicalKeyboardKey.enter);
      expect(taps, 1, reason: 'Enter on a focused pressable fires onTap once');
    });

    testWidgets('tappable row (semanticButton:false) is still focusable',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(HollowPressable(
          onTap: () => taps++,
          semanticButton: false,
          semanticLabel: 'Conversation row',
          child: const SizedBox(width: 120, height: 48),
        )),
      );

      await _tabThenPress(tester, LogicalKeyboardKey.enter);
      expect(taps, 1,
          reason: 'rows must be keyboard-reachable + activatable too');
    });

    testWidgets('non-interactive pressable is not focusable', (tester) async {
      await tester.pumpWidget(
        _host(const HollowPressable(
          onTap: null,
          child: Text('Static'),
        )),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.context,
        anyOf(isNull, isNot(_isWithin<HollowFocusRing>(tester))),
        reason: 'a non-interactive pressable must stay out of the focus chain',
      );
    });
  });

  group('HollowToggle keyboard', () {
    testWidgets('Tab focuses + Space flips exactly once', (tester) async {
      var changes = 0;
      bool? last;
      await tester.pumpWidget(
        _host(HollowToggle(
          value: false,
          onChanged: (v) {
            changes++;
            last = v;
          },
          semanticLabel: 'Reduce motion',
        )),
      );

      await _tabThenPress(tester, LogicalKeyboardKey.space);
      expect(changes, 1, reason: 'Space on a focused toggle flips it once');
      expect(last, true);
    });

    testWidgets('disabled toggle is not focusable', (tester) async {
      await tester.pumpWidget(
        _host(const HollowToggle(value: false, onChanged: null)),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.context,
        anyOf(isNull, isNot(_isWithin<HollowFocusRing>(tester))),
        reason: 'a disabled toggle must stay out of the focus chain',
      );
    });
  });

  group('focus ring token', () {
    testWidgets('theme exposes a focusRing color distinct from transparent',
        (tester) async {
      late HollowTheme hollow;
      await tester.pumpWidget(
        _host(Builder(builder: (context) {
          hollow = HollowTheme.of(context);
          return const SizedBox();
        })),
      );
      expect(hollow.focusRing.a, greaterThan(0.0),
          reason: 'focus ring must be visible (non-transparent)');
    });
  });

  group('focus ring geometry', () {
    // Regression: the ring must paint at EXACTLY the visible control's box,
    // even when an ancestor stretches the control wider than its content
    // (a `SizedBox(width: ...)` around a MainAxisSize.min button). The first
    // ring impl filled a Positioned.fill Stack → on a stretched/centered
    // control the ring was larger + off-centre than the button. The CustomPaint
    // foregroundPainter paints at the child's own size, fixing it.
    Finder ringPaint() => find.byWidgetPredicate((w) =>
        w is CustomPaint &&
        w.foregroundPainter?.runtimeType.toString() == '_FocusRingPainter');

    testWidgets('ring matches the button box at content width', (tester) async {
      await tester.pumpWidget(_host(HollowButton.outline(
        onPressed: () {},
        compact: true,
        icon: const Icon(Icons.edit, size: 14),
        child: const Text('Edit Nickname'),
      )));
      await tester.pumpAndSettle();

      final ring = tester.getSize(ringPaint().first);
      final box = tester.getSize(find.byType(AnimatedContainer).first);
      expect(ring, box,
          reason: 'ring must equal the visible button box, got ring=$ring box=$box');
    });

    testWidgets('ring still matches when the button is stretched wide',
        (tester) async {
      // A 400px-wide container around a min-size button — the classic
      // "Edit Nickname / Edit Profile" full-width wrapper.
      await tester.pumpWidget(_host(SizedBox(
        width: 400,
        child: HollowButton.outline(
          onPressed: () {},
          compact: true,
          icon: const Icon(Icons.edit, size: 14),
          child: const Text('Edit Profile'),
        ),
      )));
      await tester.pumpAndSettle();

      final ring = tester.getSize(ringPaint().first);
      final box = tester.getSize(find.byType(AnimatedContainer).first);
      // Whatever the button's box is (it fills the 400 here), the ring matches
      // it — never larger, never offset.
      expect(ring, box,
          reason: 'stretched: ring must still equal the button box, '
              'got ring=$ring box=$box');
    });
  });
}

/// Matcher: the focused node's context is inside a [T] subtree. Used to assert
/// focus did NOT land inside our focusable component for the disabled cases.
Matcher _isWithin<T extends Widget>(WidgetTester tester) =>
    predicate<BuildContext>((ctx) {
      return ctx.findAncestorWidgetOfExactType<T>() != null;
    }, 'within a $T');
