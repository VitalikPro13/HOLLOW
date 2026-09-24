import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';

/// The iOS swipe back on [hollowMobileRoute]: a drag from the left edge drives
/// the route, pops past half the width, and settles back when short.
void main() {
  Future<void> pushDetail(
    WidgetTester tester, {
    HollowRouteTransition transition = HollowRouteTransition.slideRight,
    bool canPop = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  hollowMobileRoute<void>(
                    transition: transition,
                    builder: (_) => PopScope(
                      canPop: canPop,
                      child: const Scaffold(body: Center(child: Text('detail'))),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('detail'), findsOneWidget);
  }

  Future<void> swipe(WidgetTester tester, double fraction) async {
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    final gesture = await tester.startGesture(const Offset(5, 300));
    // Slow steps, so the release is judged by distance rather than as a fling.
    const steps = 20;
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(Offset(width * fraction / steps, 0));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  // The variant sets debugDefaultTargetPlatformOverride for each test.
  final ios = TargetPlatformVariant.only(TargetPlatform.iOS);

  group('on iOS', () {
    testWidgets('a swipe past half the width pops', (tester) async {
      await pushDetail(tester);
      await swipe(tester, 0.7);
      expect(find.text('detail'), findsNothing);
      expect(find.text('open'), findsOneWidget);
    }, variant: ios);

    testWidgets('a short swipe settles back', (tester) async {
      await pushDetail(tester);
      await swipe(tester, 0.2);
      expect(find.text('detail'), findsOneWidget);
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      expect(nav.userGestureInProgress, isFalse);
    }, variant: ios);

    testWidgets('the page below follows the finger from the left',
        (tester) async {
      await pushDetail(tester);
      final width =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      final gesture = await tester.startGesture(const Offset(5, 300));
      await gesture.moveBy(const Offset(40, 0));
      await gesture.moveBy(Offset(width / 2 - 40, 0));
      await tester.pump();
      // Half way: the detail page sits half off screen, the page below is
      // still shifted left by half its parallax.
      expect(tester.getCenter(find.text('detail')).dx, closeTo(width, 2));
      expect(
        tester.getCenter(find.text('open')).dx,
        closeTo(width / 2 - width * 0.15, 2),
      );
      await gesture.up();
      await tester.pumpAndSettle();
    }, variant: ios);

    testWidgets('a drag away from the edge does nothing', (tester) async {
      await pushDetail(tester);
      final gesture = await tester.startGesture(const Offset(200, 300));
      await gesture.moveBy(const Offset(300, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('detail'), findsOneWidget);
    }, variant: ios);

    testWidgets('a page that must not pop ignores the swipe', (tester) async {
      await pushDetail(tester, canPop: false);
      await swipe(tester, 0.7);
      expect(find.text('detail'), findsOneWidget);
    }, variant: ios);

    testWidgets('under Reduce motion the swipe still follows the finger',
        (tester) async {
      // The statics directly: setMode would start the shared ticker's timer.
      final rm = ReduceMotionController.instance.effective;
      rm.value = true;
      HollowDurations.animationsDisabled = true;
      addTearDown(() {
        rm.value = false;
        HollowDurations.animationsDisabled = false;
      });
      await pushDetail(tester);
      final width =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      final gesture = await tester.startGesture(const Offset(5, 300));
      await gesture.moveBy(const Offset(40, 0));
      await gesture.moveBy(Offset(width / 2 - 40, 0));
      await tester.pump();
      expect(tester.getCenter(find.text('detail')).dx, closeTo(width, 2));
      await gesture.moveBy(Offset(width / 4, 0));
      await gesture.up();
      // No settle animation: one frame lands it.
      await tester.pump();
      await tester.pump();
      expect(find.text('detail'), findsNothing);
    }, variant: ios);

    testWidgets('a slide-up page has no swipe back', (tester) async {
      await pushDetail(tester, transition: HollowRouteTransition.slideUp);
      await swipe(tester, 0.7);
      expect(find.text('detail'), findsOneWidget);
    }, variant: ios);
  });

  testWidgets('Android leaves the edge to the system back gesture',
      (tester) async {
    await pushDetail(tester);
    await swipe(tester, 0.7);
    expect(find.text('detail'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
