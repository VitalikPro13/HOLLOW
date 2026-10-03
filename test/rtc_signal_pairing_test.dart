import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/rtc_signal_pairing.dart';

class _Conn implements RtcSignalEndpoint {
  @override
  final String peerId;
  @override
  final String connId;
  _Conn(this.peerId, this.connId);
}

/// A-MED-08. The relay reads `conn_id`, so a conn_id alone must never let
/// another identity answer or feed ICE into an offer we made.
void main() {
  String linked(String id) => const {'bob-phone': 'bob'}[id] ?? id;
  String cold(String id) => id;

  group('pairRtcSignal', () {
    final ours = _Conn('bob', 'c1');
    final conns = {'bob': ours};

    test('an answer from another identity carrying our offer conn_id is not '
        'paired', () {
      expect(pairRtcSignal(conns, 'mallory', 'c1', linked), isNull);
    });

    test('a device of the dialled identity still pairs', () {
      expect(pairRtcSignal(conns, 'bob-phone', 'c1', linked), same(ours));
    });

    test('the peer we dialled pairs on its own conn_id only', () {
      expect(pairRtcSignal(conns, 'bob', 'c1', linked), same(ours));
      expect(pairRtcSignal(conns, 'bob', 'c2', linked), isNull);
      expect(pairRtcSignal(conns, 'bob-phone', 'c2', linked), isNull);
    });

    test('a cold link map fails closed for a sibling device', () {
      expect(pairRtcSignal(conns, 'bob-phone', 'c1', cold), isNull);
    });
  });

  group('PendingRtcIce', () {
    test("another identity's queued ICE is never flushed into our PC", () {
      final queue = PendingRtcIce<String>();
      queue.add(linked('mallory'), 'c1', 'forged');
      expect(queue.take(linked('bob'), 'c1'), isEmpty);
    });

    test('a sibling device of the offerer flushes with the offer', () {
      final queue = PendingRtcIce<String>();
      queue.add(linked('bob-phone'), 'c1', 'cand');
      expect(queue.take(linked('bob'), 'c1'), ['cand']);
      expect(queue.take(linked('bob'), 'c1'), isEmpty);
    });
  });

  group('webrtc_service.dart', () {
    final src = File('lib/src/core/services/webrtc_service.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');

    test('connection ids come from a secure random source', () {
      expect(src.contains('Random()'), isFalse,
          reason: 'conn_id pairs an answer to our offer; a predictable one '
              'can be guessed. Use Random.secure().');
    });

    test('answers and ICE pair only through pairRtcSignal', () {
      String body(String head) {
        final at = src.indexOf(head);
        expect(at, isNot(-1), reason: head);
        return src.substring(at, src.indexOf('\n  }\n', at));
      }

      for (final head in [
        'Future<void> _handleAnswer(',
        'Future<void> _handleIce(',
        'Future<void> _flushPendingIce(',
      ]) {
        expect(body(head).contains('_pairSignal('), isTrue, reason: head);
      }
      expect(
          body('_PeerConn? _pairSignal(')
              .contains('pairRtcSignal(_connsFor(lane), peerId, connId, '
                  'resolveIdentity)'),
          isTrue);
      expect(src.contains('PendingRtcIce<RTCIceCandidate>'), isTrue);
    });
  });
}
