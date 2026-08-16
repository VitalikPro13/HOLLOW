import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/display_scale_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/settings/accessibility_section.dart';

import '../helpers/test_app.dart';

/// Issue #20 — the Display Size controls in Settings > Accessibility.
///
/// The interface-scale slider is the interesting one: it resizes the very
/// surface it lives on, so it must NOT commit on every drag tick (the track
/// would move out from under the pointer and the value would oscillate). It
/// commits on release instead, while the percentage label tracks the drag.
void main() {
  late ProviderContainer container;

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: hollowTestOverrides(),
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                container = ProviderScope.containerOf(context);
                return const AccessibilitySettingsView();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('renders both scale controls at their defaults', (tester) async {
    await pumpSettings(tester);
    expect(find.text('Interface scale'), findsOneWidget);
    expect(find.text('Chat text size'), findsOneWidget);
    // Both sit at 100%, and the min/max captions frame the desktop range.
    expect(find.text('100%'), findsNWidgets(2));
    expect(find.byType(Slider), findsNWidgets(2));
  });

  testWidgets('interface scale commits on release, not mid-drag',
      (tester) async {
    await pumpSettings(tester);
    expect(container.read(uiScaleProvider), kUiScaleDefault);

    final slider = find.byType(Slider).first;
    final center = tester.getCenter(slider);
    final gesture = await tester.startGesture(center);
    await tester.pump();
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();

    // Mid-drag: the label has moved, the app has not.
    expect(
      container.read(uiScaleProvider),
      kUiScaleDefault,
      reason: 'committing mid-drag makes the slider fight the pointer',
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(container.read(uiScaleProvider), greaterThan(kUiScaleDefault));
  });

  testWidgets('chat text size commits live', (tester) async {
    await pumpSettings(tester);
    expect(container.read(chatTextScaleProvider), kChatTextScaleDefault);

    final slider = find.byType(Slider).last;
    final center = tester.getCenter(slider);
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();

    expect(
      container.read(chatTextScaleProvider),
      greaterThan(kChatTextScaleDefault),
      reason: 'nothing it resizes is on screen, so it can preview live',
    );
    await gesture.up();
    await tester.pumpAndSettle();
  });

  test('scale helpers snap and label on the 5% grid', () {
    expect(snapScale(1.13), closeTo(1.15, 0.0001));
    expect(snapScale(1.12), closeTo(1.10, 0.0001));
    expect(scalePercentLabel(1.25), '125%');
    expect(scaleDivisions(0.75, 2.0), 25);
  });
}
