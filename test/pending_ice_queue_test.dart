import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/services/pending_ice_queue.dart';

/// The bug this file exists for: a peer connection is built while the queue is
/// holding candidates for the very call being built, and a blanket clear threw
/// them away. Each candidate is sent once, so a dropped one is gone for the
/// life of the call and the connection has to survive on peer-reflexive
/// discovery alone. That usually works, which is what made it intermittent.
RTCIceCandidate _cand(String id) => RTCIceCandidate(
      'candidate:$id 1 udp 2122260223 192.168.1.5 54321 typ host',
      '0',
      0,
    );

void main() {
  group('discardExcept', () {
    test('KEEPS the candidates for the call being set up', () {
      final q = PendingIceQueue();
      q.add('call-A', _cand('a1'));
      q.add('call-A', _cand('a2'));

      // Building the peer connection for call-A must not sweep out A's own
      // candidates. This is the regression.
      expect(q.discardExcept('call-A'), 0);
      expect(q.take('call-A').length, 2);
    });

    test('drops a previous call and keeps the current one in the same pass',
        () {
      final q = PendingIceQueue();
      q.add('old-call', _cand('o1'));
      q.add('call-A', _cand('a1'));
      q.add('old-call', _cand('o2'));

      expect(q.discardExcept('call-A'), 2);
      expect(q.length, 1);
      expect(q.take('call-A').length, 1);
    });

    test('a null keep drops everything, which is what a call ending wants', () {
      final q = PendingIceQueue();
      q.add('call-A', _cand('a1'));
      q.add('call-B', _cand('b1'));

      expect(q.discardExcept(null), 2);
      expect(q.isEmpty, isTrue);
    });

    test('reports zero when there was nothing to drop', () {
      final q = PendingIceQueue();
      expect(q.discardExcept('call-A'), 0);
      q.add('call-A', _cand('a1'));
      expect(q.discardExcept('call-A'), 0);
    });
  });

  group('take', () {
    test('returns only the named call, oldest first, and removes just those',
        () {
      final q = PendingIceQueue();
      q.add('call-A', _cand('a1'));
      q.add('call-B', _cand('b1'));
      q.add('call-A', _cand('a2'));

      final got = q.take('call-A');
      expect(got.map((c) => c.candidate).toList(),
          [_cand('a1').candidate, _cand('a2').candidate]);
      expect(q.length, 1, reason: 'call-B untouched');
    });

    test('is empty for a call with nothing queued', () {
      final q = PendingIceQueue();
      q.add('call-A', _cand('a1'));
      expect(q.take('call-B'), isEmpty);
      expect(q.length, 1);
    });

    test('draining twice does not double-deliver', () {
      final q = PendingIceQueue();
      q.add('call-A', _cand('a1'));
      expect(q.take('call-A').length, 1);
      expect(q.take('call-A'), isEmpty);
    });
  });

  group('cap', () {
    test('refuses past the ceiling and says so exactly once', () {
      final lines = <String>[];
      final q = PendingIceQueue(maxEntries: 3, log: lines.add);

      expect(q.add('call-A', _cand('1')), isTrue);
      expect(q.add('call-A', _cand('2')), isTrue);
      expect(q.add('call-A', _cand('3')), isTrue);
      expect(q.add('call-A', _cand('4')), isFalse);
      expect(q.add('call-A', _cand('5')), isFalse);

      expect(q.length, 3);
      expect(lines.length, 1, reason: 'latched, not one line per candidate');
      expect(lines.first, contains('[SENTINEL]'));
    });

    test('re-arms the notice once the queue drains', () {
      final lines = <String>[];
      final q = PendingIceQueue(maxEntries: 1, log: lines.add);

      q.add('call-A', _cand('1'));
      q.add('call-A', _cand('2')); // refused, logs
      expect(lines.length, 1);

      q.take('call-A');
      q.add('call-B', _cand('1'));
      q.add('call-B', _cand('2')); // refused again, logs again
      expect(lines.length, 2);
    });

    test('stays silent while it never fills', () {
      final lines = <String>[];
      final q = PendingIceQueue(maxEntries: 64, log: lines.add);
      for (var i = 0; i < 20; i++) {
        q.add('call-A', _cand('$i'));
      }
      expect(lines, isEmpty);
    });
  });
}
