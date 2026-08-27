import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/video_quality_ladder.dart';

/// The bug this file exists for: call cameras were added with a bare
/// `pc.addTrack` and no encoding caps at all, so on a congested uplink the
/// encoder kept probing upward, loss climbed, the ICE consent checks sharing
/// that uplink starved, and the transport read the link as dead. The picture
/// never degraded; it took the call with it.
///
/// The promise these tests pin: video always has somewhere further to fall,
/// and the bottom of the ladder is a call that still carries voice.

VideoSendSample _s(double loss, {int? avail, double? rtt}) =>
    VideoSendSample(fractionLost: loss, availableOutgoingBps: avail, roundTripMs: rtt);

/// Feed [n] identical samples, returning how many times the rung moved.
int _feed(VideoLadderGovernor g, VideoSendSample sample, int n) {
  var moves = 0;
  for (var i = 0; i < n; i++) {
    if (g.observe(sample)) moves++;
  }
  return moves;
}

void main() {
  group('falling', () {
    test('a clean link stays at full quality', () {
      final g = VideoLadderGovernor();
      _feed(g, _s(0.0), 20);
      expect(g.index, 0);
      expect(g.isDegraded, isFalse);
    });

    test('one bad sample is not enough: real links blip', () {
      final g = VideoLadderGovernor();
      expect(g.observe(_s(0.12)), isFalse);
      expect(g.index, 0);
    });

    test('two consecutive bad samples step down one rung', () {
      final g = VideoLadderGovernor();
      g.observe(_s(0.12));
      expect(g.observe(_s(0.12)), isTrue);
      expect(g.index, 1);
    });

    test('severe loss skips a rung instead of stepping politely', () {
      final g = VideoLadderGovernor();
      expect(g.observe(_s(0.30)), isTrue);
      expect(g.index, 2,
          reason: 'at a quarter of the packets gone the picture is already '
              'unwatchable, so a single step just wastes an interval');
    });

    test('sustained bad loss walks all the way down to paused', () {
      final g = VideoLadderGovernor();
      _feed(g, _s(0.15), 20);
      expect(g.isPaused, isTrue,
          reason: 'the bottom rung protects the audio absolutely');
      expect(g.rung.maxBitrateBps, 0);
    });

    test('high latency alone counts as bad: a link this deep in its buffers '
        'is about to drop', () {
      final g = VideoLadderGovernor();
      g.observe(_s(0.0, rtt: 600));
      expect(g.observe(_s(0.0, rtt: 600)), isTrue);
      expect(g.index, 1);
    });

    test('an estimator below the rung asks for is bad before it becomes loss',
        () {
      final g = VideoLadderGovernor();
      // Rung 0 wants 700kbps; 300kbps of headroom is a squeeze.
      g.observe(_s(0.0, avail: 300000));
      expect(g.observe(_s(0.0, avail: 300000)), isTrue);
      expect(g.index, 1);
    });
  });

  group('climbing', () {
    test('is slower than falling', () {
      final g = VideoLadderGovernor();
      _feed(g, _s(0.15), 4); // down at least one rung
      final fell = g.index;
      expect(fell, greaterThan(0));

      // A handful of good samples is not yet a recovery.
      _feed(g, _s(0.0, avail: 5000000), 3);
      expect(g.index, fell);

      _feed(g, _s(0.0, avail: 5000000), 3);
      expect(g.index, fell - 1);
    });

    test('never climbs more than one rung at a time', () {
      final g = VideoLadderGovernor();
      g.collapse();
      final moves = _feed(g, _s(0.0, avail: 5000000), 6);
      expect(moves, 1);
      expect(g.index, kCameraLadder.length - 2);
    });

    test('will not climb into a ceiling it just fell through', () {
      final g = VideoLadderGovernor();
      _feed(g, _s(0.15), 4);
      final fell = g.index;
      // Loss is gone, but the estimator says there is no room for the rung
      // above. Staying put is correct: climbing re-creates the congestion.
      _feed(g, _s(0.0, avail: 60000), 10);
      expect(g.index, greaterThanOrEqualTo(fell));
    });

    test('with no estimator opinion it still recovers on loss alone', () {
      final g = VideoLadderGovernor();
      _feed(g, _s(0.15), 4);
      final fell = g.index;
      _feed(g, _s(0.0), 6);
      expect(g.index, fell - 1);
    });
  });

  group('flapping does not park at the top', () {
    test('alternating bad and neutral still walks down', () {
      final g = VideoLadderGovernor();
      for (var i = 0; i < 12; i++) {
        g.observe(_s(i.isEven ? 0.12 : 0.05));
      }
      expect(g.isDegraded, isTrue,
          reason: 'clearing the streak on every neutral sample would let a '
              'link in trouble hold full quality forever');
    });
  });

  group('explicit moves', () {
    test('collapse drops straight to the bottom', () {
      final g = VideoLadderGovernor();
      expect(g.collapse(), isTrue);
      expect(g.isPaused, isTrue);
    });

    test('releaseCollapse returns to the rung the ladder had earned', () {
      final g = VideoLadderGovernor();
      _feed(g, _s(0.15), 4); // measured its way down
      final earned = g.index;
      expect(earned, greaterThan(0));
      g.collapse();
      expect(g.isPaused, isTrue);
      expect(g.releaseCollapse(), isTrue);
      expect(g.index, earned,
          reason: 'a two second stutter says nothing new about bandwidth, so '
              'the measured rung stands');
      expect(g.isCollapsed, isFalse);
    });

    test('releaseCollapse without a collapse does nothing', () {
      final g = VideoLadderGovernor();
      _feed(g, _s(0.15), 4);
      final earned = g.index;
      expect(g.releaseCollapse(), isFalse);
      expect(g.index, earned);
    });

    test('restore returns to full quality for a fresh path', () {
      final g = VideoLadderGovernor();
      g.collapse();
      expect(g.restore(), isTrue);
      expect(g.index, 0);
      expect(g.isDegraded, isFalse);
    });

    test('a move that changes nothing reports no change', () {
      final g = VideoLadderGovernor();
      expect(g.restore(), isFalse);
    });
  });

  group('the ladder itself', () {
    test('every rung asks for strictly less than the one above', () {
      for (var i = 1; i < kCameraLadder.length; i++) {
        expect(kCameraLadder[i].maxBitrateBps,
            lessThan(kCameraLadder[i - 1].maxBitrateBps));
        expect(kCameraLadder[i].scaleDownBy,
            greaterThanOrEqualTo(kCameraLadder[i - 1].scaleDownBy));
      }
    });

    test('the last rung sends nothing, so audio always has the whole uplink',
        () {
      expect(kCameraLadder.last.isPaused, isTrue);
    });

    test('rung labels carry no em dashes (they reach the UI)', () {
      for (final rung in kCameraLadder) {
        expect(rung.label.contains('—'), isFalse);
      }
    });
  });
}
