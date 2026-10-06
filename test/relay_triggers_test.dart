import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/member_panel_provider.dart';
import 'package:hollow/src/core/services/relay_triggers.dart';

/// A triggers service whose nudges land in [sent] and whose clock is [now].
class _Rig {
  _Rig({required bool phone, bool inCall = false}) : _inCall = inCall {
    triggers = RelayTriggers(
      phone: phone,
      nudge: sent.add,
      now: () => now,
      inCall: () => _inCall,
    );
  }

  final sent = <String>[];
  DateTime now = DateTime(2026, 10, 6, 12);
  final bool _inCall;
  late final RelayTriggers triggers;

  /// Advances the injected clock and the fake timers together.
  Future<void> wait(WidgetTester tester, Duration d) async {
    now = now.add(d);
    await tester.pump(d);
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

void main() {
  setUp(() {
    // Each test starts in the foreground.
    TestWidgetsFlutterBinding.ensureInitialized()
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  group('foreground (phones)', () {
    testWidgets('a return from the background nudges foreground once',
        (tester) async {
      final rig = _Rig(phone: true)..triggers.start();
      _lifecycle(tester, _toBackground);
      expect(rig.sent, isEmpty);
      _lifecycle(tester, _toForeground);
      expect(rig.sent, ['foreground']);
      await rig.wait(tester, kNudgeSettle * 2);
      expect(rig.sent, ['foreground']);
      rig.triggers.dispose();
    });

    testWidgets('a desktop window ignores lifecycle resumes', (tester) async {
      final rig = _Rig(phone: false)..triggers.start();
      _lifecycle(tester, _toBackground);
      _lifecycle(tester, _toForeground);
      await rig.wait(tester, kNudgeSettle * 2);
      expect(rig.sent, isEmpty);
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
      expect(rig.sent, ['foreground']);
      rig.triggers.dispose();
    });

    testWidgets('a network change still nudges during a call',
        (tester) async {
      final rig = _Rig(phone: true, inCall: true)..triggers.start();
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
  });
}
