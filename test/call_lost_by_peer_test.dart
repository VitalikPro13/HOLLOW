import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/services/link_watchdog.dart';
import 'package:hollow/src/rust/frb_generated.dart';

import 'helpers/test_app.dart';

/// #146: turning on "Always relay calls" offers a restart, and the restart
/// closed the app in the middle of the call. The other side kept the dead call
/// open and answered every new call from the same person with busy.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => RustLib.initMock(api: _Api()));
  setUp(() => _Api.signals.clear());
  setUp(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Method'),
          (_) async => null,
        ),
  );

  // bob-d1 and bob-d2 are two devices of one person.
  ({ProviderContainer c, _InCall call}) inCallWith(
    String peer, {
    CallDirection direction = CallDirection.incoming,
    String? answeredBy,
    bool lapsing = true,
  }) {
    final c = ProviderContainer(
      overrides: hollowTestOverrides(
        extra: [
          deviceLinkProvider.overrideWith(() => _Links()),
          callProvider.overrideWith(
            () => _InCall(
              CallState(
                status: CallStatus.active,
                peerId: peer,
                callId: 'c1',
                direction: direction,
                answeredBy: answeredBy,
              ),
              lapsing: lapsing,
            ),
          ),
        ],
      ),
    );
    addTearDown(c.dispose);
    return (c: c, call: c.read(callProvider.notifier) as _InCall);
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  test('their new call replaces the one our side is still holding', () async {
    final r = inCallWith('bob-d1');

    await r.call.handleCallSignal('bob-d1', 'invite', '{"call_id":"c2"}');
    await settle();

    final s = r.c.read(callProvider);
    expect(s.status, CallStatus.ringing);
    expect(s.callId, 'c2');
    expect(s.direction, CallDirection.incoming);
  });

  test('on our outgoing call, the device that answered may replace it',
      () async {
    final r = inCallWith('bob',
        direction: CallDirection.outgoing, answeredBy: 'bob-d1');

    await r.call.handleCallSignal('bob-d1', 'invite', '{"call_id":"c2"}');
    await settle();

    expect(r.c.read(callProvider).callId, 'c2');
  });

  test('our outgoing call remembers which device answered it', () async {
    final c = ProviderContainer(
      overrides: hollowTestOverrides(
        extra: [
          deviceLinkProvider.overrideWith(() => _Links()),
          callProvider.overrideWith(
            () => _InCall(
              const CallState(
                status: CallStatus.ringing,
                peerId: 'bob',
                callId: 'c1',
                direction: CallDirection.outgoing,
              ),
            ),
          ),
        ],
      ),
    );
    addTearDown(c.dispose);
    await c
        .read(callProvider.notifier)
        .handleCallSignal('bob-d1', 'accept', '{"call_id":"c1"}');
    expect(c.read(callProvider).answeredBy, 'bob-d1');
  });

  test('a sibling device that is not in the call cannot end it', () async {
    // Only the device in the call may end it, the rule call_book holds.
    for (final r in [
      inCallWith('bob-d1'),
      inCallWith('bob', direction: CallDirection.outgoing, answeredBy: 'bob-d1'),
    ]) {
      await r.call.handleCallSignal('bob-d2', 'invite', '{"call_id":"c2"}');
      await settle();
      final s = r.c.read(callProvider);
      expect(s.status, CallStatus.active);
      expect(s.callId, 'c1', reason: 'bob-d2 ended a call it never took');
    }
  });

  test('a call whose link is fine is not cut off by an invite', () async {
    final r = inCallWith('bob-d1', lapsing: false);

    await r.call.handleCallSignal('bob-d1', 'invite', '{"call_id":"c2"}');
    await settle();

    final s = r.c.read(callProvider);
    expect(s.status, CallStatus.active);
    expect(s.callId, 'c1');
  });

  test('someone else calling stays busy even while our link is down', () async {
    final r = inCallWith('bob-d1');

    await r.call.handleCallSignal('carol', 'invite', '{"call_id":"c9"}');
    await settle();

    final s = r.c.read(callProvider);
    expect(s.status, CallStatus.active);
    expect(s.callId, 'c1');
    expect(_Api.signals, contains('busy'));
  });

  group('while a lost call is being torn down', () {
    test('a third person calling is told busy, not silence', () async {
      final r = inCallWith('bob-d1');
      final a = r.call.handleCallSignal('bob-d1', 'invite', '{"call_id":"c2"}');
      final b = r.call.handleCallSignal('carol', 'invite', '{"call_id":"c3"}');
      await Future.wait([a, b]);
      await settle();

      expect(_Api.signals, contains('busy'));
      expect(r.c.read(callProvider).callId, 'c2');
    });

    test('the newest invite wins and the one it replaces is told busy',
        () async {
      final r = inCallWith('bob-d1');
      final a = r.call.handleCallSignal('bob-d1', 'invite', '{"call_id":"c2"}');
      final b = r.call.handleCallSignal('bob-d1', 'invite', '{"call_id":"c3"}');
      await Future.wait([a, b]);
      await settle();

      expect(r.c.read(callProvider).callId, 'c3');
      expect(_Api.signals, contains('busy'));
    });

    test('an end naming the waiting invite cancels it', () async {
      final r = inCallWith('bob-d1');
      final a = r.call.handleCallSignal('bob-d1', 'invite', '{"call_id":"c2"}');
      final b = r.call.handleCallSignal('bob-d1', 'end', 'c2');
      await Future.wait([a, b]);
      await settle();

      expect(r.c.read(callProvider).status, CallStatus.idle,
          reason: 'a cancelled invite must not ring');
    });
  });

  test(
    'the DM watchdog keeps a rebuilt connection lapsing until it connects',
    () {
      final watch = LinkWatchdog(
        peerConnection: () => null,
        isPolite: true,
        onHealth: (_) {},
        onRecoverLink: () async {},
        onGiveUp: () {},
      );
      addTearDown(watch.stop);
      watch.noteTransportState(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      watch.noteConnectionRebuilt();
      expect(
        watch.isLapsing,
        isTrue,
        reason: 'a fresh budget, never a fresh "healthy" with nobody there',
      );
      watch.noteTransportState(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      expect(watch.isLapsing, isFalse);
    },
  );

  group('the side that restarts hangs up first', () {
    test('a restart sends the hangup and leaves the call idle', () async {
      final r = inCallWith('alice');

      await hangUpBeforeExit(r.c.read);

      expect(r.c.read(callProvider).status, CallStatus.idle);
      expect(
        _Api.signals,
        contains('end'),
        reason: 'the other side must hear a hangup, not a dead connection',
      );
    });

    test('nothing to hang up sends nothing', () async {
      final c = ProviderContainer(overrides: hollowTestOverrides());
      addTearDown(c.dispose);
      await hangUpBeforeExit(c.read);
      expect(_Api.signals, isEmpty);
    });

    test('the exit hook runs once and never blocks the exit', () async {
      var runs = 0;
      beforeAppExit = () async {
        runs++;
        throw StateError('teardown failed');
      };
      await runBeforeAppExit();
      await runBeforeAppExit();
      expect(runs, 1);
    });

    test('every way the app ends itself hangs up first', () {
      String read(String path) =>
          File(path).readAsStringSync().replaceAll('\r\n', '\n');

      // Exits that cannot happen mid-call, each with the reason.
      const exitAllowlist = {
        'lib/main.dart': 'a second instance quits before runApp: no call yet',
        'lib/src/core/app_relaunch.dart': 'exitApp and relaunchApp: the hook '
            'has already run',
      };
      final exitCall = RegExp(r'(^|[^\w.])exit\(\s*\d');
      final offenders = <String>[];
      final seenAllowed = <String>{};
      for (final f in Directory('lib').listSync(recursive: true)) {
        final path = f.path.replaceAll('\\', '/');
        if (f is! File || !path.endsWith('.dart')) continue;
        if (path.startsWith('lib/src/rust/')) continue;
        final src = read(path);
        if (exitCall.hasMatch(src)) {
          exitAllowlist.containsKey(path)
              ? seenAllowed.add(path)
              : offenders.add('$path: exit() outside exitApp');
        }
        if (src.contains('SystemNavigator.pop(') &&
            path != 'lib/src/core/app_relaunch.dart') {
          offenders.add('$path: SystemNavigator.pop outside app_relaunch');
        }
        if (src.contains('windowManager.destroy(') && path != 'lib/main.dart') {
          offenders.add('$path: windowManager.destroy outside the quit paths');
        }
        if (path != 'lib/src/core/app_relaunch.dart' &&
            RegExp(r'Future<\w+> (relaunchApp|exitForRelaySwitch|exitApp)\(')
                .hasMatch(src)) {
          offenders.add('$path: a second exit helper');
        }
      }
      expect(offenders, isEmpty);
      expect(seenAllowed, exitAllowlist.keys.toSet(),
          reason: 'an allowlisted exit is gone: drop its entry');

      String body(String src, String head) {
        final at = src.indexOf(head);
        expect(at, isNot(-1), reason: '$head moved');
        // From the opening brace: a signature names itself.
        return src.substring(src.indexOf('async {', at), src.indexOf('\n}\n', at));
      }

      final relaunch = read('lib/src/core/app_relaunch.dart');
      for (final head in const [
        'Future<Never> exitApp(',
        'Future<Never> relaunchApp(',
        'Future<Never> exitForRelaySwitch(',
      ]) {
        final b = body(relaunch, head);
        expect(b.indexOf('await runBeforeAppExit();'), greaterThan(-1),
            reason: '$head ends the app without hanging up');
        expect(b.indexOf('await runBeforeAppExit();'),
            lessThan([b.indexOf('exit('), b.indexOf('relaunchApp()'),
                    b.indexOf('notifyShutdown'), b.indexOf('SystemNavigator')]
                .where((i) => i > -1)
                .fold<int>(b.length, (a, i) => i < a ? i : a)),
            reason: '$head must hang up before anything else');
      }

      final main = read('lib/main.dart');
      expect(read('lib/src/ui/shell/hollow_shell.dart'),
          contains('beforeAppExit = () => hangUpBeforeExit('),
          reason: 'nothing points the exit hook at the hang-up');
      for (final head in const [
        'Future<void> _quitApp(',
        'Future<void> _linuxQuit(',
      ]) {
        final b = body(main, head);
        final hook = b.indexOf('await runBeforeAppExit();');
        expect(hook, greaterThan(-1), reason: '$head quits mid-call');
        expect(hook, lessThan(b.indexOf('notifyShutdown')));
      }
    });
  });
}

class _InCall extends CallNotifier {
  final CallState initial;
  final bool lapsing;
  _InCall(this.initial, {this.lapsing = false});
  @override
  CallState build() => initial;
  @override
  bool get callLinkLapsing => lapsing;
}

class _Links extends DeviceLinkNotifier {
  @override
  DeviceLinkState build() =>
      const DeviceLinkState(links: {'bob-d1': 'bob', 'bob-d2': 'bob'});
}

class _Api implements RustLibApi {
  static final signals = <String>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    if (name.contains('crateApiNetworkCallSendSignal')) {
      signals.add('${invocation.namedArguments[#signalType]}');
    }
    return name.contains('crateApi')
        ? Future<void>.value()
        : super.noSuchMethod(invocation);
  }
}
