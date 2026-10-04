import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/rtc_stream_intake.dart';

class _Stream implements RtcIncomingStream {
  @override
  final String sender;
  @override
  final int totalSize;
  @override
  final int bytesReceived;
  @override
  final DateTime lastFrameAt;
  _Stream(this.sender, this.lastFrameAt,
      {this.totalSize = 1000, this.bytesReceived = 100});
}

final _t0 = DateTime.utc(2026, 10, 3, 12);

/// HOL-SEC-116. The data channel file receiver judged as Rust's WS stream lane
/// does: a ceiling before any temp file, frames only from the stream's own
/// connection, nothing past the declared size, open streams bounded per sender.
void main() {
  RtcStreamOpen openFirst(
    Map<String, _Stream> open, {
    String id = 'f1',
    String sender = 'bob',
    String kind = 'file',
    int totalSize = 1000,
    int firstPayload = 100,
    DateTime? now,
  }) =>
      rtcStreamOpen(open,
          id: id,
          sender: sender,
          kind: kind,
          totalSize: totalSize,
          firstPayload: firstPayload,
          now: now ?? _t0);

  group('ceiling', () {
    test('a stream declaring past the send limit is refused before it opens',
        () {
      for (final kind in ['file', 'shard', 'share_chunk']) {
        final over = rtcStreamCeiling(kind) + 1;
        expect(openFirst({}, kind: kind, totalSize: over).refusal, isNotNull,
            reason: '$kind declaring $over bytes was opened');
        expect(openFirst({}, kind: kind, totalSize: over - 1).refusal, isNull,
            reason: '$kind at its ceiling was refused');
      }
      expect(rtcStreamCeiling('file'), 34 * 1024 * 1024 + 16);
      expect(rtcStreamCeiling('share_chunk'), 262144 + 16);
    });

    test('a declared size with the top bit set is refused', () {
      expect(openFirst({}, totalSize: -1, firstPayload: 0).refusal, isNotNull,
          reason: 'a u64 past 2^63 reads negative and slipped under the '
              'ceiling');
    });

    test('a first frame carrying more than its declared size is refused', () {
      expect(openFirst({}, totalSize: 10, firstPayload: 11).refusal, isNotNull,
          reason: 'the first frame wrote past the declared size');
      expect(openFirst({}, totalSize: 10, firstPayload: 10).refusal, isNull);
    });
  });

  group('sender', () {
    test("a continuation from another connection never touches the stream",
        () {
      final bob = _Stream('bob', _t0);
      expect(rtcChunkVerdict(bob, 'mallory', 10), RtcChunk.drop,
          reason: "another peer's chunk was appended to bob's stream");
      expect(rtcChunkVerdict(bob, 'bob#share', 10), RtcChunk.drop,
          reason: "bob's Share channel extended his general stream");
      expect(rtcChunkVerdict(bob, 'bob', 10), RtcChunk.append);
      expect(rtcChunkVerdict(null, 'bob', 10), RtcChunk.drop);
    });

    test("another connection's first frame cannot replace a live stream", () {
      final open = {'f1': _Stream('bob', _t0)};
      final live = openFirst(open,
          sender: 'mallory', now: _t0.add(const Duration(seconds: 9)));
      expect(live.refusal, isNotNull,
          reason: "mallory's first frame discarded bob's live stream");
      final idle = openFirst(open,
          sender: 'mallory', now: _t0.add(kRtcStreamTakeoverIdle));
      expect(idle.refusal, isNull);
      expect(idle.evict, ['f1']);
    });

    test('the same connection restarts its own stream', () {
      final open = {'f1': _Stream('bob', _t0)};
      final again = openFirst(open, now: _t0.add(const Duration(seconds: 1)));
      expect(again.refusal, isNull);
      expect(again.evict, ['f1']);
    });
  });

  group('declared size', () {
    test('bytes past the declared size fail the stream', () {
      final s = _Stream('bob', _t0, totalSize: 100, bytesReceived: 90);
      expect(rtcChunkVerdict(s, 'bob', 11), RtcChunk.overflow,
          reason: 'a chunk running past the declared size was written');
      expect(rtcChunkVerdict(s, 'bob', 10), RtcChunk.complete);
      expect(rtcChunkVerdict(s, 'bob', 9), RtcChunk.append);
    });
  });

  group('open streams', () {
    test('a sender keeps at most its share and pays with its own stalest', () {
      final open = <String, _Stream>{
        for (var i = 0; i < kMaxRtcStreamsPerSender; i++)
          'm$i': _Stream('mallory', _t0.add(Duration(seconds: 100 - i))),
        'b0': _Stream('bob', _t0),
      };
      final next = openFirst(open,
          id: 'm-new', sender: 'mallory', now: _t0.add(const Duration(minutes: 5)));
      expect(next.refusal, isNull);
      expect(next.evict, ['m${kMaxRtcStreamsPerSender - 1}'],
          reason: 'a sender held more than $kMaxRtcStreamsPerSender open '
              'streams');
    });

    test('past the total the heaviest sender pays, never a light one', () {
      final open = <String, _Stream>{
        for (var i = 0; i < kMaxRtcStreamsPerSender; i++)
          'm$i': _Stream('mallory', _t0.add(Duration(seconds: i + 1))),
        for (var i = 0; i < kMaxRtcStreams - kMaxRtcStreamsPerSender; i++)
          'p$i': _Stream('peer$i', _t0),
      };
      final next = openFirst(open,
          id: 'a1', sender: 'alice', now: _t0.add(const Duration(minutes: 5)));
      expect(next.refusal, isNull);
      expect(next.evict, ['m0'],
          reason: 'the receiver held more than $kMaxRtcStreams open streams, '
              'or a light sender paid for the heaviest');
    });

    test('a newcomer finding every sender at one stream is refused', () {
      final open = <String, _Stream>{
        for (var i = 0; i < kMaxRtcStreams; i++) 'p$i': _Stream('peer$i', _t0),
      };
      final next = openFirst(open, id: 'a1', sender: 'alice');
      expect(next.refusal, isNotNull);
      expect(next.evict, isEmpty);
    });

    test('one connection sends at most its share at once', () async {
      final slots = RtcSendSlots();
      for (var i = 0; i < kMaxRtcSendsPerConn; i++) {
        await slots.acquire();
      }
      var extra = false;
      final waiting = slots.acquire().then((_) => extra = true);
      await Future<void>.delayed(Duration.zero);
      expect(extra, isFalse,
          reason: 'a connection sent more than $kMaxRtcSendsPerConn streams '
              'at once');
      slots.release();
      await waiting;
      expect(extra, isTrue);
      expect(kMaxRtcSendsPerConn, lessThan(kMaxRtcStreamsPerSender));
    });
  });

  group('pinned to Rust', () {
    String read(String path) =>
        File(path).readAsStringSync().replaceAll('\r\n', '\n');

    int rustConst(String path, String name) {
      final m = RegExp('const $name: [a-z0-9]+ = ([^;]+);')
          .firstMatch(read(path));
      expect(m, isNotNull, reason: '$name is gone from $path');
      return m!
          .group(1)!
          .split('*')
          .map((f) => int.parse(f.trim().replaceAll('_', '')))
          .reduce((a, b) => a * b);
    }

    test('the ceilings and caps equal the WS stream lane', () {
      const node = 'rust/hollow_core/src/node';
      expect(rustConst('$node/file_transfer.rs', 'DEFAULT_MAX_FILE_SIZE'),
          kRtcSendLimit);
      expect(rustConst('$node/file_handler.rs', 'AES_GCM_TAG'), kRtcGcmTag);
      expect(rustConst('$node/file_handler.rs', 'SHARD_HEADER_SLACK'),
          kRtcShardHeaderSlack);
      expect(rustConst('$node/share_handler.rs', 'CHUNK_SIZE'),
          kRtcShareChunkSize);
      expect(
          rustConst(
              '$node/ws_stream_transfer.rs', 'MAX_RECV_STREAMS_PER_SENDER'),
          kMaxRtcStreamsPerSender);
      expect(rustConst('$node/ws_stream_transfer.rs', 'MAX_RECV_STREAMS'),
          kMaxRtcStreams);
      expect(
          read('$node/ws_stream_transfer.rs').contains(
              'const STREAM_TAKEOVER_IDLE: std::time::Duration = '
              'std::time::Duration::from_secs('
              '${kRtcStreamTakeoverIdle.inSeconds});'),
          isTrue);
    });
  });

  group('webrtc_service.dart', () {
    final src = File('lib/src/core/services/webrtc_service.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');

    String body(String head) {
      final at = src.indexOf(head);
      expect(at, isNot(-1), reason: head);
      return src.substring(at, src.indexOf('\n  }\n', at));
    }

    test('a first frame is judged before its temp file opens', () {
      final recv = body('void _onDataChannelMessage(');
      final opens = recv.indexOf('openWrite(');
      final judged = recv.indexOf('rtcStreamOpen(_transfers');
      expect(judged, isNot(-1));
      for (final step in [
        'if (open.refusal != null) {',
        'for (final stale in open.evict) {\n        _discardTransfer(stale);',
      ]) {
        final at = recv.indexOf(step);
        expect(at > judged && at < opens, isTrue, reason: step);
      }
    });

    test('a file or shard stream opens only under a stream id', () {
      final recv = body('void _onDataChannelMessage(');
      final shaped = recv.indexOf('if (!rtcStreamIdFits(kind, id)) {');
      expect(shaped, isNot(-1));
      expect(shaped, lessThan(recv.indexOf('rtcStreamOpen(_transfers')));
      expect(recv.substring(shaped, recv.indexOf('\n      }', shaped)),
          contains('return;'));
    });

    test('a file or shard send rides only its own device\'s channel', () {
      expect(rtcSendMayUseSibling('file'), isFalse);
      expect(rtcSendMayUseSibling('shard'), isFalse);
      expect(rtcSendMayUseSibling('share_chunk'), isTrue);
      final send = body('Future<void> sendFile(');
      expect(
          send,
          contains('rtcSendMayUseSibling(kind)\n'
              '        ? _openConnForIdentity(peerId, lane)\n'
              '        : _openConnForDevice(peerId, lane);'));
      expect(body('_PeerConn? _openConnForDevice('),
          isNot(contains('resolveIdentity')));
    });

    test('file progress goes to Rust by stream id, never to a card by id', () {
      expect(body('void _reportProgress('),
          contains('network_api\n        .webrtcTransferProgress('));
      final provider = File('lib/src/core/providers/webrtc_provider.dart')
          .readAsStringSync();
      expect(provider, isNot(contains('onFileProgress(')),
          reason: 'a stream id reached the file cards as if it were a file id');
      expect(src, isNot(contains('onProgress')));
    });

    test('continuations are judged before a byte is written', () {
      final recv = body('void _onDataChannelMessage(');
      final writes = recv.indexOf('transfer.sink.add(');
      final judged = recv.indexOf('rtcChunkVerdict(transfer, sender,');
      expect(judged, isNot(-1));
      for (final step in [
        'if (verdict == RtcChunk.drop) {',
        'if (verdict == RtcChunk.overflow) {',
      ]) {
        final at = recv.indexOf(step);
        expect(at > judged && at < writes, isTrue, reason: step);
        expect(recv.substring(at, recv.indexOf('\n      }', at)),
            contains('return;'),
            reason: step);
      }
      expect(
          body('static String _streamSender(').contains(
              "lane == _Lane.share ? '\$peerId#share' : peerId"),
          isTrue,
          reason: 'the sender key must name the lane');
    });

    test('sends hold a slot of their connection', () {
      final send = body('Future<void> sendFile(');
      final acquire = send.indexOf('await conn.sendSlots.acquire();');
      expect(acquire, isNot(-1));
      expect(acquire, lessThan(send.indexOf('AtRest.read(')));
      expect(send, contains('} finally {\n      conn.sendSlots.release();'));
    });
  });
}
