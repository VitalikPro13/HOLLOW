import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/overlay_hosts.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';

/// The full-surface drag on a phone page (#154): a drag that starts anywhere
/// takes the page back, on iOS and Android alike, while what sits under the
/// finger (a long press, a vertical scroll, a sideways scroller, a composer)
/// keeps its own gestures. A leftward drag drives whatever the page offers,
/// and a driven push lands the page only past a third of the width.
void main() {
  const both = TargetPlatformVariant(
      {TargetPlatform.iOS, TargetPlatform.android});

  late List<String> log;

  /// A page with a long-press target, a vertical list, a sideways scroller
  /// and an excluded "composer".
  Widget detail({HollowSwipeDrive? Function()? onLeft}) => HollowPageSwipe(
        onSwipeLeft: onLeft,
        child: Scaffold(
          body: Column(children: [
            GestureDetector(
              onLongPress: () => log.add('long press'),
              child: const SizedBox(
                  height: 80, width: 400, child: Text('message')),
            ),
            SizedBox(
              height: 120,
              child: ListView(
                key: const Key('sideways'),
                scrollDirection: Axis.horizontal,
                children: [
                  for (var i = 0; i < 20; i++)
                    SizedBox(width: 100, child: Text('tile $i')),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                key: const Key('vertical'),
                children: [
                  for (var i = 0; i < 60; i++)
                    SizedBox(height: 40, child: Text('row $i')),
                ],
              ),
            ),
            const HollowPageSwipeExclusion(
              child: SizedBox(
                  height: 60, width: 400, child: Text('composer')),
            ),
          ]),
        ),
      );

  Future<NavigatorState> pushDetail(WidgetTester tester,
      {HollowSwipeDrive? Function()? onLeft}) async {
    log = [];
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      home: const Scaffold(body: Center(child: Text('list'))),
    ));
    nav.currentState!
        .push(hollowMobileRoute<void>(builder: (_) => detail(onLeft: onLeft)));
    await tester.pumpAndSettle();
    expect(find.text('message'), findsOneWidget);
    return nav.currentState!;
  }

  Future<void> drag(WidgetTester tester, Offset from, Offset by) async {
    final gesture = await tester.startGesture(from);
    const steps = 20;
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(by / steps.toDouble());
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('a drag from the middle of the page goes back', (tester) async {
    await pushDetail(tester);
    await drag(tester, const Offset(200, 500), const Offset(200, 0));
    expect(find.text('message'), findsNothing);
    expect(find.text('list'), findsOneWidget);
  }, variant: both);

  testWidgets('a drag under a third of the width settles back',
      (tester) async {
    final nav = await pushDetail(tester);
    await drag(tester, const Offset(100, 500), const Offset(100, 0));
    expect(find.text('message'), findsOneWidget);
    expect(nav.userGestureInProgress, isFalse);
  }, variant: both);

  testWidgets('a diagonal drag over still content moves nothing',
      (tester) async {
    await pushDetail(tester);
    await drag(tester, const Offset(150, 40), const Offset(160, 160));
    expect(find.text('message'), findsOneWidget);
  }, variant: both);

  testWidgets('a page that must not pop ignores the drag', (tester) async {
    log = [];
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      home: const Scaffold(body: Text('shell')),
    ));
    nav.currentState!.push(hollowMobileRoute<void>(
      builder: (_) => const PopScope(
        canPop: false,
        child: HollowPageSwipe(
          child: Scaffold(body: Center(child: Text('kept'))),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await drag(tester, const Offset(100, 400), const Offset(300, 0));
    expect(find.text('kept'), findsOneWidget);
  }, variant: both);

  testWidgets('a long press on a message still opens its actions',
      (tester) async {
    await pushDetail(tester);
    await tester.longPress(find.text('message'));
    await tester.pumpAndSettle();
    expect(log, ['long press']);
    expect(find.text('message'), findsOneWidget);
  }, variant: both);

  testWidgets('a vertical scroll that wanders sideways stays a scroll',
      (tester) async {
    await pushDetail(tester);
    await drag(tester, const Offset(200, 600), const Offset(60, -300));
    expect(find.text('message'), findsOneWidget);
    expect(find.text('row 0'), findsNothing);
  }, variant: both);

  testWidgets('a sideways scroller inside the page keeps its drag',
      (tester) async {
    await pushDetail(tester);
    await drag(tester, const Offset(300, 140), const Offset(-250, 0));
    await drag(tester, const Offset(100, 140), const Offset(250, 0));
    expect(find.text('message'), findsOneWidget);
  }, variant: both);

  testWidgets('a drag that starts in the composer never moves the page',
      (tester) async {
    await pushDetail(tester);
    await drag(tester, const Offset(100, 770), const Offset(250, 0));
    expect(find.text('message'), findsOneWidget);
  }, variant: both);

  testWidgets('a leftward drag drives what the page offers', (tester) async {
    final drive = _RecordingDrive();
    await pushDetail(tester, onLeft: () => drive);
    await drag(tester, const Offset(300, 500), const Offset(-200, 0));
    expect(drive.moved, lessThan(-0.4));
    expect(drive.ended, isTrue);
    expect(find.text('message'), findsOneWidget);
  }, variant: both);

  // Review L10: a narrow desktop window runs the phone shell too, where a
  // mouse drag selects text or scrolls and must never take the page back.
  testWidgets('a mouse drag never moves the page', (tester) async {
    await pushDetail(tester);
    final gesture = await tester.startGesture(const Offset(200, 500),
        kind: PointerDeviceKind.mouse);
    for (var i = 0; i < 20; i++) {
      await gesture.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('message'), findsOneWidget);
  }, variant: both);

  testWidgets('with nothing to the left, a leftward drag does nothing',
      (tester) async {
    await pushDetail(tester);
    await drag(tester, const Offset(300, 500), const Offset(-200, 0));
    expect(find.text('message'), findsOneWidget);
  }, variant: both);

  group('a swipe in', () {
    late List<String> pushed;

    Future<NavigatorState> start(WidgetTester tester) async {
      pushed = [];
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: const Scaffold(body: Text('shell')),
      ));
      nav.currentState!.push(hollowMobileRoute<void>(
        builder: (_) => HollowPageSwipe(
          swipeIn: HollowSwipeIn(
            preview: (_) => const ColoredBox(
                color: Color(0xFF000000), child: Center(child: Text('preview'))),
            route: () {
              pushed.add('route');
              return hollowMobileRoute<void>(
                  builder: (_) =>
                      const Scaffold(body: Center(child: Text('channel'))));
            },
            onPushed: (popped) => popped.then((_) => pushed.add('popped')),
          ),
          child: const Scaffold(body: Center(child: Text('list'))),
        ),
      ));
      await tester.pumpAndSettle();
      return nav.currentState!;
    }

    testWidgets('the preview follows the finger and nothing is pushed yet',
        (tester) async {
      await start(tester);
      final gesture = await tester.startGesture(const Offset(300, 400));
      await gesture.moveBy(const Offset(-40, 0));
      await gesture.moveBy(const Offset(-160, 0));
      await tester.pump();
      expect(tester.getCenter(find.text('preview')).dx, closeTo(400, 2));
      expect(pushed, isEmpty);
      await gesture.up();
      await tester.pumpAndSettle();
    }, variant: both);

    testWidgets('a release past a third lands the page', (tester) async {
      final nav = await start(tester);
      await drag(tester, const Offset(300, 400), const Offset(-180, 0));
      expect(pushed, ['route']);
      expect(tester.getCenter(find.text('channel')).dx, closeTo(200, 1));
      expect(find.text('preview'), findsNothing);
      expect(nav.userGestureInProgress, isFalse);
      nav.pop();
      await tester.pumpAndSettle();
      expect(pushed, ['route', 'popped']);
    }, variant: both);

    // Review H1: pushing a route cancels the finger, which the recognizer
    // reports as a release. The lock cover, a call screen or a dialog pushed
    // mid-drag must stay on top, never with the channel landed above it.
    testWidgets('a route pushed mid swipe-in stays on top', (tester) async {
      final nav = await start(tester);
      final gesture = await tester.startGesture(const Offset(300, 400));
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(-20, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      // Past a third: now something arrives over everything, as the lock
      // cover does (opaque, instant).
      nav.push(PageRouteBuilder<void>(
        settings: const RouteSettings(name: 'cover'),
        opaque: true,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) =>
            const Scaffold(body: Center(child: Text('cover'))),
      ));
      await tester.pump();
      await tester.pumpAndSettle();
      await gesture.up();
      await tester.pumpAndSettle();

      String? top;
      nav.popUntil((r) {
        top = r.settings.name;
        return true;
      });
      expect(pushed, isEmpty, reason: 'the cancelled drag pushed the channel');
      expect(top, 'cover');
      expect(find.text('preview'), findsNothing);
      expect(OverlayHosts.openCount, 0);
    }, variant: both);

    // The preview is a raw overlay entry, which the navigator stacks above
    // every route it pushes: the lock must be able to clear it first.
    testWidgets('the lock clears the preview, and the release lands nothing',
        (tester) async {
      await start(tester);
      final gesture = await tester.startGesture(const Offset(300, 400));
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(-20, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.text('preview'), findsOneWidget);
      expect(OverlayHosts.openCount, 1);
      OverlayHosts.dismissAll();
      await tester.pump();
      expect(find.text('preview'), findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(pushed, isEmpty);
      expect(find.text('list'), findsOneWidget);
      expect(OverlayHosts.openCount, 0);
    }, variant: both);

    testWidgets('a short pull pushes nothing', (tester) async {
      await start(tester);
      await drag(tester, const Offset(300, 400), const Offset(-80, 0));
      expect(pushed, isEmpty);
      expect(find.text('preview'), findsNothing);
      expect(find.text('list'), findsOneWidget);
    }, variant: both);
  });

  testWidgets('with nothing else under the finger, a drag right still goes '
      'back on a page that also takes drags left', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      home: const Scaffold(body: Text('shell')),
    ));
    final drive = _RecordingDrive();
    nav.currentState!.push(hollowMobileRoute<void>(
      builder: (_) => HollowPageSwipe(
        onSwipeLeft: () => drive,
        child: const Scaffold(body: SizedBox.expand()),
      ),
    ));
    await tester.pumpAndSettle();
    await drag(tester, const Offset(100, 400), const Offset(300, 0));
    expect(find.text('shell'), findsOneWidget);
    expect(drive.ended, isFalse);
  }, variant: both);

  testWidgets('an instant push arrives with no transition', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      home: const Scaffold(body: Text('list')),
    ));
    nav.currentState!.push(hollowMobileRoute<void>(
        instant: true,
        builder: (_) => const Scaffold(body: Center(child: Text('server')))));
    await tester.pump();
    await tester.pump();
    expect(tester.getCenter(find.text('server')).dx,
        closeTo(tester.view.physicalSize.width / tester.view.devicePixelRatio / 2, 1));
  });

  testWidgets('under Reduce motion a released drag lands in one frame',
      (tester) async {
    final rm = ReduceMotionController.instance.effective;
    rm.value = true;
    HollowDurations.animationsDisabled = true;
    addTearDown(() {
      rm.value = false;
      HollowDurations.animationsDisabled = false;
    });
    await pushDetail(tester);
    final gesture = await tester.startGesture(const Offset(150, 500));
    await gesture.moveBy(const Offset(40, 0));
    await gesture.moveBy(const Offset(160, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump();
    expect(find.text('message'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

class _RecordingDrive extends HollowSwipeDrive {
  double moved = 0;
  bool ended = false;

  @override
  void update(double delta) => moved += delta;

  @override
  void end(double velocity) => ended = true;
}
