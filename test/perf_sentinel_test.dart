import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/perf_sentinel.dart';

// Pure-logic tests for the sentinel aggregation/rate-limit behavior: the
// whole point is QUIET BY DEFAULT — a stall storm must produce a bounded
// number of lines, and silence must produce zero.
void main() {
  group('FrameStallAggregator', () {
    test('frames below threshold never log', () {
      final lines = <String>[];
      final agg = FrameStallAggregator(sink: lines.add, graceFrames: 0);
      var t = 1000000;
      for (var i = 0; i < 10000; i++) {
        agg.onFrame(16, t);
        t += 16;
      }
      expect(lines, isEmpty);
    });

    test('startup grace frames are ignored even when they stall', () {
      final lines = <String>[];
      final agg = FrameStallAggregator(sink: lines.add, graceFrames: 30);
      var t = 1000000;
      for (var i = 0; i < 30; i++) {
        agg.onFrame(500, t);
        t += 500;
      }
      expect(lines, isEmpty);
      agg.onFrame(500, t);
      expect(lines, ['[SENTINEL] frame 500ms']);
    });

    test('rate limit: max one line per 5s window', () {
      final lines = <String>[];
      final agg = FrameStallAggregator(sink: lines.add, graceFrames: 0);
      const t0 = 1000000;
      agg.onFrame(150, t0); // first stall logs immediately
      agg.onFrame(200, t0 + 1000); // suppressed
      agg.onFrame(300, t0 + 4999); // suppressed
      agg.onFrame(120, t0 + 5000); // window elapsed -> logs
      expect(lines, [
        '[SENTINEL] frame 150ms',
        '[SENTINEL] frame 120ms',
      ]);
    });

    test('suppressed counter flushes once a minute with worst stall', () {
      final lines = <String>[];
      final agg = FrameStallAggregator(sink: lines.add, graceFrames: 0);
      const t0 = 1000000;
      agg.onFrame(150, t0); // logs
      agg.onFrame(200, t0 + 1000); // suppressed
      agg.onFrame(300, t0 + 2000); // suppressed, worst
      agg.onFrame(16, t0 + 65000); // healthy frame triggers the lazy flush
      expect(lines, [
        '[SENTINEL] frame 150ms',
        '[SENTINEL] frames suppressed=2 worst=300ms',
      ]);
      // Counter reset: a second minute with no stalls flushes nothing.
      agg.onFrame(16, t0 + 130000);
      expect(lines.length, 2);
    });
  });

  group('SlowCallLog', () {
    test('calls below threshold never log', () {
      final lines = <String>[];
      final log = SlowCallLog(sink: lines.add);
      log.report('mediaStreamTrackSetEnable', 49, 1000000);
      expect(lines, isEmpty);
    });

    test('first slow call logs immediately, repeats are summarized', () {
      final lines = <String>[];
      final log = SlowCallLog(sink: lines.add);
      const t0 = 1000000;
      log.report('mediaStreamTrackSetEnable', 2100, t0);
      log.report('mediaStreamTrackSetEnable', 90, t0 + 100); // suppressed
      log.report('mediaStreamTrackSetEnable', 400, t0 + 200); // suppressed
      log.report('mediaStreamTrackSetEnable', 60, t0 + 5100); // window over
      expect(lines, [
        '[SENTINEL] channel mediaStreamTrackSetEnable 2100ms',
        '[SENTINEL] channel mediaStreamTrackSetEnable 60ms '
            '(+2 suppressed, worst 400ms)',
      ]);
    });

    test('rate limit is per method — distinct methods log independently', () {
      final lines = <String>[];
      final log = SlowCallLog(sink: lines.add);
      const t0 = 1000000;
      log.report('createOffer', 80, t0);
      log.report('addTrack', 120, t0 + 10);
      expect(lines, [
        '[SENTINEL] channel createOffer 80ms',
        '[SENTINEL] channel addTrack 120ms',
      ]);
    });
  });
}
