import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/local_meter_loopback.dart';

/// Records every start/stop and fails on any overlap, so a test reads as the
/// sequence the native side would have seen.
class _Rig {
  final calls = <String>[];
  int inFlight = 0;
  int maxInFlight = 0;
  Completer<void>? gate;
  bool failNextStart = false;
  int _n = 0;

  late final keeper = AloneMeterKeeper<String, String>(
    start: (source) async {
      _enter();
      try {
        if (gate != null) await gate!.future;
        if (failNextStart) {
          failNextStart = false;
          throw StateError('no pc');
        }
        final handle = '$source#${++_n}';
        calls.add('start $handle');
        return handle;
      } finally {
        inFlight--;
      }
    },
    stop: (handle) async {
      _enter();
      calls.add('stop $handle');
      inFlight--;
    },
  );

  void _enter() {
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
  }
}

void main() {
  test('alone with a microphone starts one loopback, a carrying peer stops it',
      () async {
    final r = _Rig();
    await r.keeper.update(source: 'mic', alone: true);
    await r.keeper.update(source: 'mic', alone: true);
    expect(r.calls, ['start mic#1']);
    expect(r.keeper.running, isTrue);

    await r.keeper.update(source: 'mic', alone: false);
    expect(r.calls, ['start mic#1', 'stop mic#1']);
    expect(r.keeper.running, isFalse);

    // The peer leaves: alone again.
    await r.keeper.update(source: 'mic', alone: true);
    expect(r.calls.last, 'start mic#2');
  });

  test('no microphone, no loopback', () async {
    final r = _Rig();
    await r.keeper.update(source: null, alone: true);
    expect(r.calls, isEmpty);
  });

  test('joining a room with someone already in it never starts one', () async {
    final r = _Rig();
    await r.keeper.update(source: 'mic', alone: false);
    expect(r.calls, isEmpty);
  });

  test('a new microphone moves the loopback: old stopped before new starts',
      () async {
    final r = _Rig();
    await r.keeper.update(source: 'micA', alone: true);
    await r.keeper.update(source: 'micB', alone: true);
    expect(r.calls, ['start micA#1', 'stop micA#1', 'start micB#2']);
  });

  test('leaving shuts it down and stays down', () async {
    final r = _Rig();
    await r.keeper.update(source: 'mic', alone: true);
    await r.keeper.shutdown();
    expect(r.calls, ['start mic#1', 'stop mic#1']);
    expect(r.keeper.running, isFalse);
  });

  test('a burst acts on the latest wish only', () async {
    final r = _Rig();
    unawaited(r.keeper.update(source: 'mic', alone: true));
    unawaited(r.keeper.update(source: 'mic', alone: false));
    await r.keeper.update(source: 'mic', alone: false);
    expect(r.calls, isEmpty);
  });

  test('a leave during a slow start stops it once the start lands, no overlap',
      () async {
    final r = _Rig()..gate = Completer<void>();
    final starting = r.keeper.update(source: 'mic', alone: true);
    await Future<void>.delayed(Duration.zero);
    final leaving = r.keeper.shutdown();
    r.gate!.complete();
    await Future.wait([starting, leaving]);
    expect(r.calls, ['start mic#1', 'stop mic#1']);
    expect(r.maxInFlight, 1);
    expect(r.keeper.running, isFalse);
  });

  test('a failed start is retried on the next update', () async {
    final r = _Rig()..failNextStart = true;
    await r.keeper.update(source: 'mic', alone: true);
    expect(r.keeper.running, isFalse);
    await r.keeper.update(source: 'mic', alone: true);
    expect(r.calls, ['start mic#1']);
    expect(r.keeper.running, isTrue);
  });

  test('the loopback never names an ICE server', () {
    // Nothing of it may reach the network (Always relay, zero-ICE rule): a
    // TURN or STUN entry here would send our own audio off the machine.
    final src = File('lib/src/core/services/local_meter_loopback.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(src, contains("'iceServers': <Map<String, dynamic>>[],"));
    expect(src, isNot(contains('urls')));
    expect(src, isNot(contains('turn:')));
    expect(src, isNot(contains('stun:')));
  });

  test('the receiving end never names our mic track (#97 hearing ourselves)',
      () {
    const mic = '3f2a9c1e-mic';
    const offer = 'a=msid:stream-1 $mic\r\n'
        'a=ssrc:1234 msid:stream-1 $mic\r\n';
    final seen = meterReceiverSdp(offer, mic);
    expect(seen, isNot(matches(RegExp(r'(?<!hollow-meter-)3f2a9c1e-mic'))));
    expect(seen, contains('a=msid:stream-1 hollow-meter-$mic'));
    expect(seen, contains('a=ssrc:1234 msid:stream-1 hollow-meter-$mic'));
  });
}
