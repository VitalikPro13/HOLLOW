/// Toasts and the call bar (regression pass 0.12, finding 3): a toast shown
/// while a call stage is up never covers its bar, the hang-up above all, on a
/// DM stage, a voice room and a meeting alike (they share the one bar).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/call/call_stage.dart';
import 'package:hollow/src/ui/call/call_stage_bar.dart';
import 'package:hollow/src/ui/call/call_stage_data.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';

import '../helpers/test_app.dart';

const _window = Size(1280, 800);
const _dockHeight = 58.0;
const _chatPanelWidth = 304.0;

/// The toast's resting gap above the window's bottom edge on desktop.
const _toastBottom = 32.0;

const _saved = 'Recording saved to D:\\dev\\tmp\\s36-profiles\\home\\Videos\\'
    'Hollow Recordings\\Hollow_2026-10-05_09-54-06.mp4';

final _quiet = Provider<bool>((_) => false);

class _Source extends CallStageSource {
  const _Source();

  @override
  CallStageData? watchData(BuildContext context, WidgetRef ref) =>
      CallStageData(
        people: [
          CallPerson(
            id: 'me',
            master: 'me',
            isSelf: true,
            name: 'You',
            speaking: _quiet,
          ),
          CallPerson(
            id: 'mira',
            master: 'mira',
            isSelf: false,
            name: 'mira',
            speaking: _quiet,
          ),
        ],
        shares: const [],
        focus: null,
        gridOn: false,
        onFocus: (_) {},
        onGrid: (_) {},
        onWatch: (_) {},
        onStopWatching: (_) {},
        onStopSharing: () {},
      );

  @override
  CallBarModel? watchBar(BuildContext context, WidgetRef ref,
          CallStageData data,
          {required bool fullscreen, required VoidCallback onFullscreen}) =>
      CallBarModel(
        startedAt: DateTime.now(),
        muted: false,
        deafened: false,
        onMute: () {},
        onDeafen: () {},
        cameraOn: false,
        onCamera: () {},
        sharing: false,
        onShare: () {},
        layout: null,
        onLayout: null,
        fullscreen: fullscreen,
        onFullscreen: onFullscreen,
        watching: false,
        leaveLabel: 'Leave the call',
        onLeave: () {},
      );
}

/// The desktop shell around a call: the stage (or [centre]) left of the chat
/// panel, the dock along the bottom, as in the session 36 screenshot.
Widget _desktop(Widget centre) => Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(child: centre),
              const SizedBox(width: _chatPanelWidth),
            ],
          ),
        ),
        const SizedBox(height: _dockHeight),
      ],
    );

Future<GlobalKey<NavigatorState>> _pump(
    WidgetTester tester, Widget body) async {
  tester.view.physicalSize = _window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final container = ProviderContainer(overrides: hollowTestOverrides());
  addTearDown(container.dispose);
  final nav = GlobalKey<NavigatorState>();
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      navigatorKey: nav,
      theme: HollowThemeData.dark(),
      home: Scaffold(body: body),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
  return nav;
}

/// Shows [message] the way non-widget code does and lets it finish arriving.
Future<void> _toast(WidgetTester tester, GlobalKey<NavigatorState> nav,
    String message) async {
  HollowToast.show(
    nav.currentContext!,
    message,
    type: HollowToastType.success,
    duration: const Duration(seconds: 15),
    overlayState: nav.currentState!.overlay,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Lets the toast leave on its own, so no timer outlives the test.
Future<void> _finish(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 16));
  await tester.pump(const Duration(milliseconds: 300));
}

Rect _toastRect(WidgetTester tester, String message) => tester.getRect(find
    .ancestor(of: find.text(message), matching: find.byType(Container))
    .first);

void _expectClear(WidgetTester tester, String message) {
  final toast = _toastRect(tester, message);
  final bar = tester.getRect(find.byType(CallStageBar));
  final hangUp = tester.getRect(find.byType(CallLeaveButton));
  expect(toast.overlaps(hangUp), isFalse,
      reason: 'toast $toast covers the hang-up $hangUp');
  expect(toast.overlaps(bar), isFalse,
      reason: 'toast $toast covers the call bar $bar');
  expect(toast.bottom, lessThanOrEqualTo(bar.top),
      reason: 'the toast rises above the bar, never below the window');
}

void main() {
  testWidgets('the recording toast clears the call bar and its hang-up',
      (tester) async {
    final nav = await _pump(tester, _desktop(const CallStage(source: _Source())));
    await _toast(tester, nav, _saved);
    _expectClear(tester, _saved);
    await _finish(tester);
  });

  testWidgets('a short toast clears a bar at the window bottom (fullscreen)',
      (tester) async {
    // The fullscreen stage puts the bar 16 px off the window's bottom edge,
    // right where a toast rests.
    final nav = await _pump(tester, const CallStage(source: _Source()));
    await _toast(tester, nav, 'Copied');
    _expectClear(tester, 'Copied');
    await _finish(tester);
  });

  testWidgets('with no call bar on screen a toast keeps its place',
      (tester) async {
    final nav = await _pump(tester, _desktop(const SizedBox.expand()));
    await _toast(tester, nav, _saved);
    expect(_toastRect(tester, _saved).bottom, _window.height - _toastBottom);
    await _finish(tester);
  });

  testWidgets('a bar under an opaque page is out of sight and moves nothing',
      (tester) async {
    final nav = await _pump(tester, _desktop(const CallStage(source: _Source())));
    // No transition, as the fullscreen stage's own route nearly is, so the
    // covered bar keeps its last rect right where the toast rests.
    nav.currentState!.push(PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => const Scaffold(body: SizedBox.expand()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _toast(tester, nav, _saved);
    expect(_toastRect(tester, _saved).bottom, _window.height - _toastBottom);
    await _finish(tester);
  });

  testWidgets('when the call ends the toast settles back to its place',
      (tester) async {
    final inCall = ValueNotifier(true);
    addTearDown(inCall.dispose);
    final nav = await _pump(
      tester,
      _desktop(ValueListenableBuilder<bool>(
        valueListenable: inCall,
        builder: (_, on, _) => on
            ? const CallStage(source: _Source())
            : const SizedBox.expand(),
      )),
    );
    await _toast(tester, nav, _saved);
    _expectClear(tester, _saved);
    inCall.value = false;
    await tester.pump();
    await tester.pump();
    expect(_toastRect(tester, _saved).bottom, _window.height - _toastBottom);
    await _finish(tester);
  });
}
