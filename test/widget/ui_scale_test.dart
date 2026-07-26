import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/ui/components/ui_scale.dart';

/// Guards the interface-scale contract (issue #20): the child lays out in a
/// viewport divided by the scale and is painted back up to fill the window,
/// so text, icons and spacing all grow together and hit testing still lands.
void main() {
  Future<void> pumpScaled(
    WidgetTester tester,
    double scale, {
    required Widget child,
    Size window = const Size(1200, 800),
  }) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: UiScaleBox(scale: scale, child: child),
      ),
    );
  }

  testWidgets('scale 1.0 is a pass-through (no transform inserted)',
      (tester) async {
    await pumpScaled(tester, 1.0, child: const SizedBox.expand());
    expect(find.byType(Transform), findsNothing);
  });

  testWidgets('the child lays out at window / scale', (tester) async {
    late Size seen;
    await pumpScaled(
      tester,
      2.0,
      window: const Size(1600, 1200),
      child: LayoutBuilder(
        builder: (context, constraints) {
          seen = constraints.biggest;
          return const SizedBox.expand();
        },
      ),
    );
    // A window with room to spare at 200%: the app lays out as if it were
    // half the size, then every logical pixel is painted twice as large.
    expect(seen, const Size(800, 600));
  });

  testWidgets('fills the slot it is given, not the whole window',
      (tester) async {
    // The desktop tree is Column[32px title bar, Expanded(UiScale)], so the
    // paintable slot is 32px SHORTER than the window. Sizing from
    // MediaQuery.size instead pushed exactly 32px of app — the entire bottom
    // dock — under the bottom edge at every scale except 1.0.
    const window = Size(1200, 800);
    const barHeight = 32.0;
    for (final scale in const [0.85, 1.1, 1.5]) {
      late Size laidOut;
      tester.view.physicalSize = window;
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              const SizedBox(height: barHeight, width: double.infinity),
              Expanded(
                child: UiScaleBox(
                  scale: scale,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      laidOut = constraints.biggest;
                      return const SizedBox.expand();
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      // Painted height == the slot height, to the pixel: no overflow, no gap.
      expect(
        laidOut.height * scale,
        closeTo(window.height - barHeight, 0.5),
        reason: 'app overflows or under-fills its slot at ${scale}x',
      );
      expect(laidOut.width * scale, closeTo(window.width, 0.5));
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  testWidgets('a window too small for the chosen zoom gets a reduced one',
      (tester) async {
    late Size seen;
    await pumpScaled(
      tester,
      2.0,
      // 800 tall cannot show the app at 200% without dropping under the
      // Settings dialog's own height — which is how you zoom yourself out of
      // the control that undoes the zoom.
      window: const Size(1200, 800),
      child: LayoutBuilder(
        builder: (context, constraints) {
          seen = constraints.biggest;
          return const SizedBox.expand();
        },
      ),
    );
    expect(seen.height, greaterThanOrEqualTo(470.0));
    expect(seen.width, greaterThanOrEqualTo(410.0));
  });

  test('effectiveUiScale never shrinks below 100% and never inflates', () {
    // Roomy window: the request stands.
    expect(effectiveUiScale(1.5, const Size(1600, 1200)), 1.5);
    // Cramped window: reduced, but only as far as the floor requires.
    expect(effectiveUiScale(2.0, const Size(1200, 800)), lessThan(2.0));
    expect(effectiveUiScale(2.0, const Size(1200, 800)), greaterThan(1.0));
    // A window smaller than the floor is the window's problem — the UI is
    // never shrunk under the user to compensate.
    expect(effectiveUiScale(2.0, const Size(300, 300)), 1.0);
    expect(effectiveUiScale(0.8, const Size(300, 300)), 0.8);
  });

  testWidgets('MediaQuery below the scale reports the scaled viewport',
      (tester) async {
    late MediaQueryData mq;
    await pumpScaled(
      tester,
      1.25,
      child: Builder(
        builder: (context) {
          mq = MediaQuery.of(context);
          return const SizedBox.expand();
        },
      ),
    );
    expect(mq.size.width, closeTo(1200 / 1.25, 0.01));
    expect(mq.size.height, closeTo(800 / 1.25, 0.01));
    // One logical pixel now covers 1.25x more device pixels — image decoding
    // (cacheWidth) depends on this staying honest.
    expect(mq.devicePixelRatio, closeTo(1.25, 0.001));
  });

  testWidgets('a scaled button still receives taps at its painted position',
      (tester) async {
    var taps = 0;
    await pumpScaled(
      tester,
      1.5,
      child: Align(
        alignment: Alignment.topLeft,
        child: GestureDetector(
          onTap: () => taps++,
          child: Container(width: 100, height: 40, color: Colors.red),
        ),
      ),
    );
    // The box is 100x40 logical, painted at 150x60 in window space. A tap at
    // (140, 50) is outside the un-transformed box but inside the painted one.
    await tester.tapAt(const Offset(140, 50));
    expect(taps, 1);
  });

  group('MultipliedTextScaler', () {
    test('composes with the platform scaler instead of replacing it', () {
      const scaler = MultipliedTextScaler(
        base: TextScaler.linear(1.3),
        factor: 1.5,
      );
      expect(scaler.scale(10), closeTo(19.5, 0.001));
    });

    test('is value-equal so MediaQuery does not churn', () {
      const a = MultipliedTextScaler(base: TextScaler.noScaling, factor: 1.2);
      const b = MultipliedTextScaler(base: TextScaler.noScaling, factor: 1.2);
      const c = MultipliedTextScaler(base: TextScaler.noScaling, factor: 1.3);
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });
  });
}
