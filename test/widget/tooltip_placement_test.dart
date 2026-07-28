import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/ui_scale.dart';

/// Issue #20 follow-up: a tooltip on the bottom dock rendered BELOW its button
/// and off the bottom edge — the user saw an empty sliver of a box. The old
/// code compared a guessed 28px height against `MediaQuery.size`, which on
/// desktop is the whole window while the overlay is 32px shorter (the title
/// bar). Both halves of that are fixed: the tooltip measures itself, and the
/// MediaQuery below `UiScale` reports the slot.
void main() {
  const window = Size(1200, 800);
  const barHeight = 32.0;
  const label = 'Browse Public Channels';
  final buttonKey = GlobalKey();

  Future<void> pumpDock(WidgetTester tester, double scale) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: HollowThemeData.dark(),
        // The real desktop chrome: a title bar the app cannot paint into,
        // then everything else under the interface scale.
        builder: (context, child) => Column(
          children: [
            const SizedBox(height: barHeight, width: double.infinity),
            Expanded(
              child: ClipRect(
                child: UiScaleBox(scale: scale, child: child!),
              ),
            ),
          ],
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: HollowTooltip(
              message: label,
              child: Container(
                key: buttonKey,
                width: 40,
                height: 40,
                color: Colors.blue,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> hoverButton(WidgetTester tester) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byKey(buttonKey)));
    // 400ms hover delay + the 100ms fade/slide.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 200));
  }

  for (final scale in const [0.8, 1.0, 1.25]) {
    testWidgets('a dock tooltip stays inside the app at ${scale}x',
        (tester) async {
      await pumpDock(tester, scale);
      await hoverButton(tester);

      expect(find.text(label), findsOneWidget);
      final tip = tester.getRect(find.text(label));
      final button = tester.getRect(find.byKey(buttonKey));

      // Window space: nothing may spill past the bottom edge or hide under
      // the title bar.
      expect(tip.bottom, lessThanOrEqualTo(window.height),
          reason: 'tooltip runs off the bottom of the window at ${scale}x');
      expect(tip.top, greaterThanOrEqualTo(barHeight),
          reason: 'tooltip hides under the title bar at ${scale}x');
      // No room below a bottom-docked button, so it has to flip above it.
      expect(tip.bottom, lessThanOrEqualTo(button.top + 1),
          reason: 'tooltip did not flip above the button at ${scale}x');
    });
  }

  testWidgets('a tooltip on a bottom button survives 2x text scaling',
      (tester) async {
    // The old flat 28px height estimate was never right for a wrapped,
    // scaled-up label — exactly the case a11y users hit.
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: HollowThemeData.dark(),
        builder: (context, child) => Column(
          children: [
            const SizedBox(height: barHeight, width: double.infinity),
            Expanded(
              child: ClipRect(
                child: UiScaleBox(
                  scale: 1.0,
                  child: MediaQuery.withClampedTextScaling(
                    minScaleFactor: 2.0,
                    maxScaleFactor: 2.0,
                    child: child!,
                  ),
                ),
              ),
            ),
          ],
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: HollowTooltip(
              message: label,
              child: Container(
                key: buttonKey,
                width: 40,
                height: 40,
                color: Colors.blue,
              ),
            ),
          ),
        ),
      ),
    );
    await hoverButton(tester);

    final tip = tester.getRect(find.text(label));
    expect(tip.bottom, lessThanOrEqualTo(window.height));
    expect(tip.top, greaterThanOrEqualTo(barHeight));
    expect(tip.left, greaterThanOrEqualTo(0));
    expect(tip.right, lessThanOrEqualTo(window.width));
  });
}
