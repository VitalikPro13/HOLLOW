import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/member_panel_provider.dart';
import 'package:hollow/src/core/services/realtime_session_flag.dart';
import 'package:hollow/src/core/services/relay_triggers.dart';

/// What iOS grants: [grant] from `begin`, and an expiry the test fires.
class _FakeTask implements RelayBackgroundTask {
  Duration? grant;
  int begun = 0;
  int ended = 0;
  void Function()? _expiring;

  bool get held => begun > ended;

  @override
  Future<Duration?> begin() async {
    begun++;
    return grant;
  }

  @override
  void end() => ended++;

  @override
  void listen(void Function()? onExpiring) => _expiring = onExpiring;

  void expire() => _expiring?.call();
}

/// A triggers service with a fake FFI: nudges land in [sent], every call to the
/// relay client in [control], in order; the clock is [now].
class _Rig {
  _Rig({required bool phone, this.realtime = false}) {
    triggers = RelayTriggers(
      phone: phone,
      nudge: (reason) {
        sent.add(reason);
        control.add('nudge:$reason');
      },
      setBackground: (background) => control.add('background:$background'),
      suspend: () {
        control.add('suspend');
        return suspendGate?.future ?? Future<void>.value();
      },
      backgroundTask: task,
      now: () => now,
      inCall: () => realtime,
      log: (_) {},
    );
    // A failed expect must not leave this observer on the shared binding.
    addTearDown(triggers.dispose);
  }

  final sent = <String>[];
  final control = <String>[];
  final task = _FakeTask();
  Completer<void>? suspendGate;
  bool realtime;
  DateTime now = DateTime(2026, 10, 6, 12);
  late final RelayTriggers triggers;

  int get suspends => control.where((c) => c == 'suspend').length;

  /// Advances the injected clock and the fake timers together.
  Future<void> wait(WidgetTester tester, Duration d) async {
    now = now.add(d);
    await tester.pump(d);
  }

  /// A call starts or ends; the wiring reports every change.
  void call(bool live) {
    realtime = live;
    triggers.onRealtimeChanged();
  }
}

/// What native code does: a method call on the triggers channel.
Future<void> _native(WidgetTester tester, String method) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    RelayTriggers.channelName,
    const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
    (_) {},
  );
}

/// Walks the binding through every intermediate state, as the engine does.
void _lifecycle(WidgetTester tester, List<AppLifecycleState> states) {
  for (final s in states) {
    tester.binding.handleAppLifecycleStateChanged(s);
  }
}

const _toBackground = [
  AppLifecycleState.inactive,
  AppLifecycleState.hidden,
  AppLifecycleState.paused,
];
const _toForeground = [
  AppLifecycleState.hidden,
  AppLifecycleState.inactive,
  AppLifecycleState.resumed,
];

const _tick = Duration(milliseconds: 100);

void main() {
  setUp(() {
    // Each test starts in the foreground.
    TestWidgetsFlutterBinding.ensureInitialized()
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  group('foreground (phones)', () {
    testWidgets('a return from the background is one set_background(false)',
        (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      _lifecycle(tester, _toForeground);
      await rig.wait(tester, kNudgeSettle * 2);
      // It IS the foreground probe: no relay_nudge('foreground') beside it.
      expect(rig.control, ['background:true', 'background:false']);
      expect(rig.sent, isEmpty);
      rig.triggers.dispose();
    });

    testWidgets('every trip away tells the relay', (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      _lifecycle(tester, _toForeground);
      _lifecycle(tester, _toBackground);
      expect(rig.control,
          ['background:true', 'background:false', 'background:true']);
      rig.triggers.dispose();
    });

    testWidgets('a desktop window ignores lifecycle changes', (tester) async {
      final rig = _Rig(phone: false)..triggers.start();
      _lifecycle(tester, _toBackground);
      await rig.wait(tester, const Duration(minutes: 5));
      _lifecycle(tester, _toForeground);
      await rig.wait(tester, kNudgeSettle * 2);
      expect(rig.control, isEmpty);
      rig.triggers.dispose();
    });
  });

  group('phone model', () {
    testWidgets('the background tells the relay at once and suspends 10 s later',
        (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      expect(rig.control, ['background:true']);
      await rig.wait(tester, kSuspendAfterBackground - _tick);
      expect(rig.suspends, 0);
      await rig.wait(tester, _tick);
      expect(rig.control, ['background:true', 'suspend']);
      await rig.wait(tester, const Duration(minutes: 5));
      expect(rig.suspends, 1);
      rig.triggers.dispose();
    });

    testWidgets('a return within 10 s suspends nothing and probes once',
        (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      await rig.wait(tester, kSuspendAfterBackground - _tick);
      _lifecycle(tester, _toForeground);
      await rig.wait(tester, const Duration(minutes: 1));
      expect(rig.control, ['background:true', 'background:false']);
      expect(rig.sent, isEmpty);
      rig.triggers.dispose();
    });

    testWidgets('a return after the suspend probes once too', (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      await rig.wait(tester, const Duration(minutes: 3));
      _lifecycle(tester, _toForeground);
      await rig.wait(tester, const Duration(minutes: 1));
      expect(rig.control, ['background:true', 'suspend', 'background:false']);
      rig.triggers.dispose();
    });

    testWidgets('each trip away is judged on its own', (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      await rig.wait(tester, const Duration(seconds: 6));
      _lifecycle(tester, _toForeground);
      await rig.wait(tester, const Duration(seconds: 2));
      _lifecycle(tester, _toBackground);
      // The first trip's 10 s would end here; the second trip's has 6 s to go.
      await rig.wait(tester, const Duration(seconds: 4));
      expect(rig.suspends, 0);
      await rig.wait(tester, const Duration(seconds: 6));
      expect(rig.suspends, 1);
      rig.triggers.dispose();
    });

    testWidgets('an inactive phone is still on screen', (tester) async {
      // Notification shade, app switcher peek, a system or biometric prompt.
      final rig = _Rig(phone: true)..triggers.start();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await rig.wait(tester, const Duration(minutes: 1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await rig.wait(tester, const Duration(minutes: 1));
      expect(rig.control, isEmpty);
      rig.triggers.dispose();
    });

    testWidgets('a phone already away at start goes the same way',
        (tester) async {
      _lifecycle(tester, _toBackground);
      final rig = _Rig(phone: true)..triggers.start();
      expect(rig.control, ['background:true']);
      await rig.wait(tester, kSuspendAfterBackground);
      expect(rig.control, ['background:true', 'suspend']);
      rig.triggers.dispose();
    });

    testWidgets('dispose cancels a pending suspend', (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      rig.triggers.dispose();
      await rig.wait(tester, const Duration(minutes: 1));
      expect(rig.suspends, 0);
    });

    testWidgets('desktops never suspend', (tester) async {
      final rig = _Rig(phone: false)..triggers.start();
      _lifecycle(tester, _toBackground);
      rig.triggers.onRelayConnected();
      rig.call(true);
      rig.call(false);
      await rig.wait(tester, const Duration(minutes: 5));
      expect(rig.control, isEmpty);
      rig.triggers.dispose();
    });
  });

  group('real-time sessions', () {
    testWidgets('a live call keeps the socket in the background',
        (tester) async {
      final rig = _Rig(phone: true, realtime: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      await rig.wait(tester, const Duration(minutes: 5));
      // Still in use: the relay keeps showing it (plan section 8, decision 6).
      expect(rig.control, isEmpty);
      rig.triggers.dispose();
    });

    testWidgets('the flag goes out when the call ends while away',
        (tester) async {
      final rig = _Rig(phone: true, realtime: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      await rig.wait(tester, const Duration(seconds: 30));
      expect(rig.control, isEmpty);
      rig.call(false);
      expect(rig.control, ['background:true']);
      await rig.wait(tester, kSuspendAfterBackground);
      expect(rig.control, ['background:true', 'suspend']);
      rig.triggers.dispose();
    });

    testWidgets('a return during a call is the one foreground probe as ever',
        (tester) async {
      final rig = _Rig(phone: true, realtime: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      await rig.wait(tester, const Duration(seconds: 30));
      _lifecycle(tester, _toForeground);
      rig.call(false);
      await rig.wait(tester, const Duration(minutes: 1));
      expect(rig.control, ['background:false']);
      rig.triggers.dispose();
    });

    testWidgets('a call ending twice while away tells the relay once',
        (tester) async {
      final rig = _Rig(phone: true, realtime: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      rig.call(false);
      await rig.wait(tester, const Duration(seconds: 2));
      rig.call(true);
      await rig.wait(tester, const Duration(seconds: 2));
      rig.call(false);
      expect(rig.control, ['background:true', 'nudge:$kCallNudge']);
      rig.triggers.dispose();
    });

    testWidgets('a call not reported yet keeps the flag back too',
        (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      // Live, but the wiring's change notice has not arrived.
      rig.realtime = true;
      _lifecycle(tester, _toBackground);
      await rig.wait(tester, const Duration(minutes: 1));
      expect(rig.control, isEmpty);
      rig.call(false);
      expect(rig.control, ['background:true']);
      rig.triggers.dispose();
    });

    testWidgets('a phone launched behind the screen in a call tells nothing',
        (tester) async {
      _lifecycle(tester, _toBackground);
      final rig = _Rig(phone: true, realtime: true)..triggers.start();
      await rig.wait(tester, const Duration(minutes: 1));
      expect(rig.control, isEmpty);
      rig.triggers.dispose();
    });

    testWidgets('a call that ends while away suspends 10 s later',
        (tester) async {
      final rig = _Rig(phone: true, realtime: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      await rig.wait(tester, const Duration(seconds: 30));
      rig.call(false);
      await rig.wait(tester, kSuspendAfterBackground - _tick);
      expect(rig.suspends, 0);
      await rig.wait(tester, _tick);
      expect(rig.control, ['background:true', 'suspend']);
      rig.triggers.dispose();
    });

    testWidgets('a call ringing in before the suspend cancels it',
        (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      await rig.wait(tester, const Duration(seconds: 5));
      rig.call(true);
      await rig.wait(tester, const Duration(minutes: 1));
      expect(rig.suspends, 0);
      expect(rig.sent, [kCallNudge]);
      rig.triggers.dispose();
    });

    testWidgets('a call while suspended nudges call once', (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      await rig.wait(tester, kSuspendAfterBackground);
      rig.call(true);
      // The ring becomes the call: still live, no second nudge.
      rig.triggers.onRealtimeChanged();
      await rig.wait(tester, const Duration(minutes: 2));
      expect(rig.control, ['background:true', 'suspend', 'nudge:$kCallNudge']);
      rig.triggers.dispose();
    });

    testWidgets('a session not reported yet still blocks the suspend',
        (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      await rig.wait(tester, const Duration(seconds: 5));
      // Live, but the wiring's change notice has not arrived.
      rig.realtime = true;
      await rig.wait(tester, const Duration(minutes: 1));
      expect(rig.suspends, 0);
      rig.triggers.dispose();
    });

    testWidgets('a call in the foreground nudges nothing', (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      rig.call(true);
      rig.call(false);
      await rig.wait(tester, const Duration(minutes: 1));
      expect(rig.control, isEmpty);
      rig.triggers.dispose();
    });
  });

  group('the relay back while away', () {
    testWidgets('closes again 10 s later', (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      await rig.wait(tester, kSuspendAfterBackground);
      // A push woke the session: the live node collects, then the phone lets go.
      rig.triggers.onRelayConnected();
      await rig.wait(tester, kSuspendAfterBackground - _tick);
      expect(rig.suspends, 1);
      await rig.wait(tester, _tick);
      expect(rig.suspends, 2);
      rig.triggers.dispose();
    });

    testWidgets('never pushes a pending suspend back', (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      await rig.wait(tester, const Duration(seconds: 6));
      rig.triggers.onRelayConnected();
      await rig.wait(tester, const Duration(seconds: 4));
      expect(rig.suspends, 1);
      await rig.wait(tester, const Duration(minutes: 1));
      expect(rig.suspends, 1);
      rig.triggers.dispose();
    });

    testWidgets('is left alone in the foreground', (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      rig.triggers.onRelayConnected();
      await rig.wait(tester, const Duration(minutes: 1));
      expect(rig.control, isEmpty);
      rig.triggers.dispose();
    });

    testWidgets('is left alone during a call', (tester) async {
      final rig = _Rig(phone: true, realtime: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      rig.triggers.onRelayConnected();
      await rig.wait(tester, const Duration(minutes: 1));
      expect(rig.suspends, 0);
      rig.triggers.dispose();
    });
  });

  group('iOS background task', () {
    testWidgets('is held from the background until the suspend returned',
        (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      rig.suspendGate = Completer<void>();
      _lifecycle(tester, _toBackground);
      await tester.pump();
      expect(rig.task.begun, 1);
      await rig.wait(tester, kSuspendAfterBackground);
      expect(rig.suspends, 1);
      expect(rig.task.held, isTrue, reason: 'the suspend has not returned yet');
      rig.suspendGate!.complete();
      await tester.pump();
      expect(rig.task.held, isFalse);
      expect(rig.task.ended, 1);
      rig.triggers.dispose();
    });

    testWidgets('a return ends it and cancels the suspend', (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      await rig.wait(tester, const Duration(seconds: 3));
      _lifecycle(tester, _toForeground);
      await tester.pump();
      expect(rig.task.held, isFalse);
      await rig.wait(tester, const Duration(minutes: 1));
      expect(rig.suspends, 0);
      rig.triggers.dispose();
    });

    testWidgets('a short grant suspends before the task expires',
        (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      rig.task.grant = const Duration(seconds: 12);
      _lifecycle(tester, _toBackground);
      final early = const Duration(seconds: 12) - kBackgroundTaskMargin;
      await rig.wait(tester, early - _tick);
      expect(rig.suspends, 0);
      await rig.wait(tester, _tick);
      expect(rig.suspends, 1);
      rig.triggers.dispose();
    });

    testWidgets('a grant inside the margin suspends at once', (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      rig.task.grant = kBackgroundTaskMargin - const Duration(seconds: 1);
      _lifecycle(tester, _toBackground);
      await rig.wait(tester, _tick);
      expect(rig.suspends, 1);
      rig.triggers.dispose();
    });

    testWidgets('a long grant keeps the 10 s', (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      rig.task.grant = const Duration(seconds: 29);
      _lifecycle(tester, _toBackground);
      await rig.wait(tester, kSuspendAfterBackground - _tick);
      expect(rig.suspends, 0);
      await rig.wait(tester, _tick);
      expect(rig.suspends, 1);
      rig.triggers.dispose();
    });

    testWidgets('an expiry suspends at once', (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      await rig.wait(tester, const Duration(seconds: 2));
      rig.task.expire();
      await tester.pump();
      expect(rig.suspends, 1);
      await rig.wait(tester, const Duration(minutes: 1));
      expect(rig.suspends, 1);
      rig.triggers.dispose();
    });

    testWidgets('a live call holds none', (tester) async {
      final rig = _Rig(phone: true, realtime: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      await rig.wait(tester, const Duration(minutes: 1));
      expect(rig.task.begun, 0);
      rig.triggers.dispose();
    });

    testWidgets('a call ending while away takes one for its suspend',
        (tester) async {
      final rig = _Rig(phone: true, realtime: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      await rig.wait(tester, const Duration(minutes: 1));
      rig.call(false);
      await tester.pump();
      expect(rig.task.held, isTrue);
      await rig.wait(tester, kSuspendAfterBackground);
      expect(rig.suspends, 1);
      expect(rig.task.held, isFalse);
      rig.triggers.dispose();
    });

    testWidgets('a reconnect during the suspend keeps one task to the next',
        (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      rig.suspendGate = Completer<void>();
      _lifecycle(tester, _toBackground);
      await rig.wait(tester, kSuspendAfterBackground);
      expect(rig.suspends, 1);
      rig.triggers.onRelayConnected();
      rig.suspendGate!.complete();
      await tester.pump();
      expect(rig.task.held, isTrue, reason: 'the next suspend still needs it');
      await rig.wait(tester, kSuspendAfterBackground);
      expect(rig.suspends, 2);
      expect(rig.task.begun, 1);
      expect(rig.task.ended, 1);
      rig.triggers.dispose();
    });

    testWidgets('a call ringing in ends it', (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      await rig.wait(tester, const Duration(seconds: 2));
      rig.call(true);
      await tester.pump();
      expect(rig.task.held, isFalse);
      rig.triggers.dispose();
    });
  });

  group('focus (desktop)', () {
    testWidgets('focus after a long absence nudges focus', (tester) async {
      final rig = _Rig(phone: false)..triggers.start();
      rig.triggers.onFocusChanged(false);
      await rig.wait(tester, kFocusNudgeMinAway);
      rig.triggers.onFocusChanged(true);
      expect(rig.sent, ['focus']);
      rig.triggers.dispose();
    });

    testWidgets('focus after a short absence does not', (tester) async {
      final rig = _Rig(phone: false)..triggers.start();
      rig.triggers.onFocusChanged(false);
      await rig.wait(tester, kFocusNudgeMinAway - const Duration(seconds: 1));
      rig.triggers.onFocusChanged(true);
      await rig.wait(tester, kNudgeSettle * 2);
      expect(rig.sent, isEmpty);
      rig.triggers.dispose();
    });

    testWidgets('the absence counts from the first blur', (tester) async {
      final rig = _Rig(phone: false)..triggers.start();
      rig.triggers.onFocusChanged(false);
      await rig.wait(tester, const Duration(seconds: 20));
      // A repeated blur must not restart the absence.
      rig.triggers.onFocusChanged(false);
      await rig.wait(tester, const Duration(seconds: 20));
      rig.triggers.onFocusChanged(true);
      expect(rig.sent, ['focus']);
      rig.triggers.dispose();
    });

    testWidgets('a focus with no blur before it does not', (tester) async {
      final rig = _Rig(phone: false)..triggers.start();
      await rig.wait(tester, kFocusNudgeMinAway * 2);
      rig.triggers.onFocusChanged(true);
      expect(rig.sent, isEmpty);
      rig.triggers.dispose();
    });

    testWidgets('each return is judged by its own absence', (tester) async {
      final rig = _Rig(phone: false)..triggers.start();
      rig.triggers.onFocusChanged(false);
      await rig.wait(tester, kFocusNudgeMinAway);
      rig.triggers.onFocusChanged(true);
      await rig.wait(tester, kNudgeSettle * 2);
      rig.triggers.onFocusChanged(false);
      await rig.wait(tester, const Duration(seconds: 2));
      rig.triggers.onFocusChanged(true);
      await rig.wait(tester, kNudgeSettle * 2);
      expect(rig.sent, ['focus']);
      rig.triggers.dispose();
    });

    testWidgets('phones ignore window focus', (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      rig.triggers.onFocusChanged(false);
      await rig.wait(tester, kFocusNudgeMinAway * 2);
      rig.triggers.onFocusChanged(true);
      expect(rig.sent, isEmpty);
      rig.triggers.dispose();
    });
  });

  group('native events', () {
    testWidgets('network and wake map to their reasons', (tester) async {
      final rig = _Rig(phone: false)..triggers.start();
      await _native(tester, 'network');
      await _native(tester, 'wake');
      expect(rig.sent, ['network', 'wake']);
      rig.triggers.dispose();
    });

    testWidgets('an unknown event nudges nothing', (tester) async {
      final rig = _Rig(phone: false)..triggers.start();
      await _native(tester, 'foreground');
      await _native(tester, 'focus');
      await _native(tester, 'sleep');
      await _native(tester, kCallNudge);
      await _native(tester, kPushNudge);
      await rig.wait(tester, kNudgeSettle * 2);
      expect(rig.sent, isEmpty);
      rig.triggers.dispose();
    });

    testWidgets('nothing arrives after dispose', (tester) async {
      final rig = _Rig(phone: false)..triggers.start();
      rig.triggers.dispose();
      await _native(tester, 'network');
      expect(rig.sent, isEmpty);
    });

    testWidgets('dispose hands the channel back', (tester) async {
      final rig = _Rig(phone: false)..triggers.start();
      // A handler answers with a success envelope; no handler, with null.
      var answered = 0;
      Future<void> send() =>
          tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            RelayTriggers.channelName,
            const StandardMethodCodec()
                .encodeMethodCall(const MethodCall('network')),
            (reply) {
              if (reply != null) answered++;
            },
          );
      await send();
      await tester.pump();
      expect(answered, 1);
      rig.triggers.dispose();
      await send();
      await tester.pump();
      expect(answered, 1, reason: 'no handler answers once disposed');
    });

    testWidgets('a disposed service ignores focus too', (tester) async {
      final rig = _Rig(phone: false)..triggers.start();
      rig.triggers.onFocusChanged(false);
      rig.triggers.dispose();
      await rig.wait(tester, kFocusNudgeMinAway * 2);
      rig.triggers.onFocusChanged(true);
      expect(rig.sent, isEmpty);
    });
  });

  test('the focus gap outlasts one heartbeat cycle', () {
    // 15 s heartbeat plus its 10 s deadline (plan 9.5, 9.9).
    expect(kFocusNudgeMinAway, greaterThan(const Duration(seconds: 25)));
    expect(kFocusNudgeMinAway, lessThanOrEqualTo(const Duration(minutes: 1)));
  });

  test('a burst settles within the client probe window', () {
    // The client skips a probe within 2 s of a frame (plan 9.6); a longer
    // settle would only delay the probe of the settled path.
    expect(kNudgeSettle, lessThanOrEqualTo(const Duration(seconds: 2)));
    expect(kNudgeSettle, greaterThanOrEqualTo(const Duration(milliseconds: 500)));
  });

  test('the phone numbers are the plan\'s', () {
    // Plan 9.9: Android closes 10 s after backgrounding.
    expect(kSuspendAfterBackground, const Duration(seconds: 10));
    // A suspend may take the client's whole 5 s bound (SUSPEND_MAX), so it has
    // to start at least that long before an iOS task runs out.
    expect(kBackgroundTaskMargin, greaterThan(const Duration(seconds: 5)));
    expect(kCallNudge, 'call');
  });

  group('coalescing', () {
    testWidgets('a burst nudges at once and once more when it settles',
        (tester) async {
      final rig = _Rig(phone: false)..triggers.start();
      for (var i = 0; i < 5; i++) {
        await _native(tester, 'network');
        await rig.wait(tester, const Duration(milliseconds: 100));
      }
      expect(rig.sent, ['network']);
      await rig.wait(tester, kNudgeSettle);
      expect(rig.sent, ['network', 'network']);
      await rig.wait(tester, kNudgeSettle * 3);
      expect(rig.sent, ['network', 'network']);
      rig.triggers.dispose();
    });

    testWidgets('a single event gets no trailing nudge', (tester) async {
      final rig = _Rig(phone: false)..triggers.start();
      await _native(tester, 'wake');
      await rig.wait(tester, kNudgeSettle * 3);
      expect(rig.sent, ['wake']);
      rig.triggers.dispose();
    });

    testWidgets('the trailing nudge waits for the burst to go quiet',
        (tester) async {
      final rig = _Rig(phone: false)..triggers.start();
      final step = kNudgeSettle * 0.9;
      await _native(tester, 'network');
      await rig.wait(tester, step);
      await _native(tester, 'network');
      await rig.wait(tester, step);
      await _native(tester, 'network');
      await rig.wait(tester, step);
      expect(rig.sent, ['network']);
      await rig.wait(tester, kNudgeSettle - step);
      expect(rig.sent, ['network', 'network']);
      rig.triggers.dispose();
    });

    testWidgets('a new burst after a quiet spell nudges at once again',
        (tester) async {
      final rig = _Rig(phone: false)..triggers.start();
      await _native(tester, 'network');
      await rig.wait(tester, kNudgeSettle * 2);
      await _native(tester, 'network');
      expect(rig.sent, ['network', 'network']);
      rig.triggers.dispose();
    });

    testWidgets('reasons do not swallow each other', (tester) async {
      final rig = _Rig(phone: false)..triggers.start();
      await _native(tester, 'wake');
      await _native(tester, 'network');
      expect(rig.sent, ['wake', 'network']);
      rig.triggers.dispose();
    });

    testWidgets('dispose cancels a pending trailing nudge', (tester) async {
      final rig = _Rig(phone: false)..triggers.start();
      await _native(tester, 'network');
      await _native(tester, 'network');
      rig.triggers.dispose();
      await rig.wait(tester, kNudgeSettle * 2);
      expect(rig.sent, ['network']);
    });
  });

  group('phone in the background', () {
    testWidgets('a network change waits for the foreground', (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      await _native(tester, 'network');
      await rig.wait(tester, kNudgeSettle * 2);
      expect(rig.sent, isEmpty);
      _lifecycle(tester, _toForeground);
      expect(rig.sent, isEmpty);
      expect(rig.control.last, 'background:false');
      rig.triggers.dispose();
    });

    testWidgets('a network change still nudges during a call',
        (tester) async {
      final rig = _Rig(phone: true, realtime: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      await _native(tester, 'network');
      expect(rig.sent, ['network']);
      rig.triggers.dispose();
    });

    testWidgets('an inactive phone is still in front', (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await _native(tester, 'network');
      expect(rig.sent, ['network']);
      rig.triggers.dispose();
    });

    testWidgets('a desktop window hidden to the tray still nudges',
        (tester) async {
      final rig = _Rig(phone: false)..triggers.start();
      _lifecycle(tester, _toBackground);
      await _native(tester, 'network');
      await _native(tester, 'wake');
      expect(rig.sent, ['network', 'wake']);
      rig.triggers.dispose();
    });
  });

  group('provider wiring', () {
    testWidgets('window focus reaches the triggers through the provider',
        (tester) async {
      final rig = _Rig(phone: false);
      final container = ProviderContainer(overrides: [
        relayRealtimeProvider.overrideWithValue(false),
        relayTriggersProvider
            .overrideWith((ref) => wireRelayTriggers(ref, rig.triggers)),
      ]);
      container.read(relayTriggersProvider);
      container.read(windowFocusedProvider.notifier).state = false;
      await rig.wait(tester, kFocusNudgeMinAway);
      container.read(windowFocusedProvider.notifier).state = true;
      expect(rig.sent, ['focus']);

      // Started by the provider: native events arrive.
      await _native(tester, 'wake');
      expect(rig.sent, ['focus', 'wake']);

      // Disposed with the container: they stop.
      container.dispose();
      await _native(tester, 'network');
      expect(rig.sent, ['focus', 'wake']);
    });

    testWidgets('a session and the relay status reach the phone model',
        (tester) async {
      final rig = _Rig(phone: true);
      final live = StateProvider<bool>((_) => false);
      final container = ProviderContainer(overrides: [
        relayRealtimeProvider.overrideWith((ref) => ref.watch(live)),
        relayTriggersProvider
            .overrideWith((ref) => wireRelayTriggers(ref, rig.triggers)),
      ]);
      container.read(relayTriggersProvider);
      _lifecycle(tester, _toBackground);

      rig.realtime = true;
      container.read(live.notifier).state = true;
      // The container flushes on a zero timer, which only an elapse fires.
      await tester.pump(Duration.zero);
      expect(rig.sent, [kCallNudge]);

      rig.realtime = false;
      container.read(live.notifier).state = false;
      await rig.wait(tester, kSuspendAfterBackground);
      expect(rig.suspends, 1);

      container.read(connectionStatusProvider.notifier).onRelayConnected();
      await rig.wait(tester, kSuspendAfterBackground);
      expect(rig.suspends, 2);
      container.dispose();
    });
  });

  group('what counts as real time', () {
    setUp(() => RealtimeSessionFlag.sink = (_) {});
    tearDown(() {
      RealtimeSessionFlag.reset();
      RealtimeSessionFlag.sink = null;
    });

    test('a held session flag', () async {
      final container = ProviderContainer(
          overrides: [callProvider.overrideWith(_IdleCall.new)]);
      addTearDown(container.dispose);
      final seen = <bool>[];
      container.listen<bool>(relayRealtimeProvider, (_, live) => seen.add(live),
          fireImmediately: true);
      RealtimeSessionFlag.acquire('voice-channel');
      await Future<void>.delayed(Duration.zero);
      RealtimeSessionFlag.release('voice-channel');
      await Future<void>.delayed(Duration.zero);
      expect(seen, [false, true, false]);
    });

    test('a call ringing in', () {
      final container = ProviderContainer(
          overrides: [callProvider.overrideWith(_RingingCall.new)]);
      addTearDown(container.dispose);
      expect(container.read(relayRealtimeProvider), isTrue);
    });

    test('an idle phone', () {
      final container = ProviderContainer(
          overrides: [callProvider.overrideWith(_IdleCall.new)]);
      addTearDown(container.dispose);
      expect(container.read(relayRealtimeProvider), isFalse);
    });

    test('a meeting lobby waiting for the host or seating us', () {
      for (final (status, live) in [
        (ConferenceLobbyStatus.waiting, true),
        (ConferenceLobbyStatus.admitted, true),
        (ConferenceLobbyStatus.denied, false),
        (ConferenceLobbyStatus.none, false),
      ]) {
        final container = ProviderContainer(overrides: [
          callProvider.overrideWith(_IdleCall.new),
          conferenceProvider.overrideWith(() => _Lobby(status)),
        ]);
        expect(container.read(relayRealtimeProvider), live, reason: '$status');
        container.dispose();
      }
    });
  });
}

class _IdleCall extends CallNotifier {
  @override
  CallState build() => const CallState();
}

class _RingingCall extends CallNotifier {
  @override
  CallState build() => const CallState(
      status: CallStatus.ringing, direction: CallDirection.incoming);
}

class _Lobby extends ConferenceNotifier {
  _Lobby(this.status);
  final ConferenceLobbyStatus status;

  @override
  ConferenceState build() => ConferenceState(lobbyStatus: status);
}
