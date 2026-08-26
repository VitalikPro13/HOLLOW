import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/call_setup_trace.dart';

/// Pure-logic tests for the setup timeline. The load-bearing claim is
/// `gatherExposedMs`: it is the number the pre-gathering decision rests on, so
/// it must be zero when gathering hid behind the SDP wait and exact when it
/// did not.
CallSetupTrace _trace({
  required bool outgoing,
  required List<String> lines,
  required List<int> clock,
}) {
  var i = 0;
  return CallSetupTrace(
    callId: 'test',
    outgoing: outgoing,
    sink: lines.add,
    // First read is the constructor's origin; each mark consumes the next.
    clockMs: () => clock[i++],
  );
}

void main() {
  group('gatherExposedMs', () {
    test('is zero when the candidates were ready before the answer', () {
      final lines = <String>[];
      // origin=0, sld=100, cand-host=110, cand-srflx=140, remote-sdp=400
      final t = _trace(
          outgoing: true, lines: lines, clock: [0, 100, 110, 140, 400]);
      t.mark(CallSetupTrace.kSld);
      t.mark(CallSetupTrace.kCandHost);
      t.mark(CallSetupTrace.kCandSrflx);
      t.mark(CallSetupTrace.kRemoteSdp);

      expect(t.candsReadyMs, 40);
      // The usable set was in hand 260ms before the answer: free.
      expect(t.gatherExposedMs, 0);
    });

    test('IGNORES a late gather-done, which never blocks connectivity', () {
      final lines = <String>[];
      // The regression this guards: gathering `complete` landed 200ms AFTER
      // the answer, but every usable candidate was in hand 260ms BEFORE it.
      // Judging by gather-done reported a 200ms cost that did not exist.
      // origin=0, sld=100, cand-relay=140, remote-sdp=400, gather-done=600
      final t = _trace(
          outgoing: true, lines: lines, clock: [0, 100, 140, 400, 600]);
      t.mark(CallSetupTrace.kSld);
      t.mark(CallSetupTrace.kCandRelay);
      t.mark(CallSetupTrace.kRemoteSdp);
      t.mark(CallSetupTrace.kGatherDone);

      expect(t.gatherDoneMs, 500);
      expect(t.gatherExposedMs, 0);
    });

    test('is the overhang when a candidate landed after the answer', () {
      final lines = <String>[];
      // origin=0, sld=100, cand-host=110, remote-sdp=300, cand-relay=480
      final t = _trace(
          outgoing: true, lines: lines, clock: [0, 100, 110, 300, 480]);
      t.mark(CallSetupTrace.kSld);
      t.mark(CallSetupTrace.kCandHost);
      t.mark(CallSetupTrace.kRemoteSdp);
      t.mark(CallSetupTrace.kCandRelay);

      expect(t.candsReadyMs, 380);
      // Only the 180ms of relay allocation past the answer was ever a cost.
      expect(t.gatherExposedMs, 180);
    });

    test('is null on the callee -- it has no comparable wait', () {
      final lines = <String>[];
      final t = _trace(
          outgoing: false, lines: lines, clock: [0, 100, 300, 480]);
      t.mark(CallSetupTrace.kSld);
      t.mark(CallSetupTrace.kRemoteSdp);
      t.mark(CallSetupTrace.kCandRelay);

      expect(t.candsReadyMs, 380);
      expect(t.gatherExposedMs, isNull);
    });

    test('is null when a mark is missing rather than guessing', () {
      final lines = <String>[];
      final t = _trace(outgoing: true, lines: lines, clock: [0, 100]);
      t.mark(CallSetupTrace.kSld);

      expect(t.candsReadyMs, isNull);
      expect(t.gatherExposedMs, isNull);
    });
  });

  group('human vs machine split', () {
    test('the human ring gap is never counted as machine time', () {
      final lines = <String>[];
      // origin=0, start=0, accept=8000 (slow human), connected=8900
      final t = _trace(
          outgoing: true, lines: lines, clock: [0, 0, 8000, 8900]);
      t.mark(CallSetupTrace.kStart);
      t.mark(CallSetupTrace.kAccept);
      t.mark(CallSetupTrace.kConnected);

      expect(t.humanMs, 8000);
      expect(t.machineMs, 900);
    });
  });

  group('mark()', () {
    test('keeps the FIRST write — srflx fires once per candidate', () {
      final lines = <String>[];
      final t = _trace(outgoing: true, lines: lines, clock: [0, 50, 90, 120]);
      t.mark(CallSetupTrace.kCandSrflx);
      t.mark(CallSetupTrace.kCandSrflx);
      t.mark(CallSetupTrace.kCandSrflx);

      expect(t.elapsed(CallSetupTrace.kCandSrflx), 50);
    });

    test('is inert after finish, so a later call cannot pollute the line', () {
      final lines = <String>[];
      final t = _trace(outgoing: true, lines: lines, clock: [0, 10, 20, 30]);
      t.mark(CallSetupTrace.kSld);
      t.finish(reason: 'torn-down');
      t.mark(CallSetupTrace.kConnected);

      expect(t.elapsed(CallSetupTrace.kConnected), isNull);
      expect(lines.length, 2);
    });
  });

  group('finish()', () {
    test('emits deltas, not cumulative times', () {
      final lines = <String>[];
      // origin=0, accept=0, gum-audio=600, pc=620, connected=900
      final t =
          _trace(outgoing: true, lines: lines, clock: [0, 0, 600, 620, 900]);
      t.mark(CallSetupTrace.kAccept);
      t.mark(CallSetupTrace.kGumAudio);
      t.mark(CallSetupTrace.kPc);
      t.mark(CallSetupTrace.kConnected);
      t.finish();

      expect(lines[1], contains('accept=+0'));
      expect(lines[1], contains('gum-audio=+600'));
      expect(lines[1], contains('pc=+20'));
      expect(lines[1], contains('connected=+280'));
    });

    test('an aborted call still reports how far it got', () {
      final lines = <String>[];
      final t = _trace(outgoing: true, lines: lines, clock: [0, 0, 600]);
      t.mark(CallSetupTrace.kAccept);
      t.mark(CallSetupTrace.kGumAudio);
      t.finish(reason: 'torn-down');

      expect(lines.first, contains('torn-down'));
      expect(lines.first, contains('machine=n/a'));
      expect(lines.first, contains('gather-exposed=n/a'));
      expect(lines[1], contains('gum-audio=+600'));
    });

    test('is idempotent', () {
      final lines = <String>[];
      final t = _trace(outgoing: true, lines: lines, clock: [0, 0]);
      t.mark(CallSetupTrace.kAccept);
      t.finish();
      t.finish();

      expect(lines.length, 2);
    });
  });
}
