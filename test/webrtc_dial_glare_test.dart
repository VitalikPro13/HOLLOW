import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/services/webrtc_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';

/// Two ends dialling each other at once keep exactly one data channel: the
/// lower identity yields, whichever of the two crossings happens.
///
/// On the fleet (session 40) a downloader started its own Share dial while it
/// was still building the answer to the seeder's offer. Both connections were
/// stored under the same key, the open one fell out of the map, and the lane
/// timed out and redialled every 10 s until the transfer ended.
void main() {
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(api.signals.clear);

  // 'a' < 'b': a yields, b keeps its own dial.
  for (final lane in _Lane.values) {
    group('${lane.name} lane', () {
      test('an offer during our dial: the lower id yields and answers', () async {
        final r = _Rig('a');
        final dial = lane.dial(r.service, 'b');
        await r.pump();
        final offer = r.service.handleSignal('b', lane.offer, 'v=0', 'theirs');
        await r.pump();
        r.finishAll();
        await Future.wait([dial, offer]);

        expect(r.live, hasLength(1), reason: 'two connections outlived the crossing');
        expect(api.sent(lane.offer), isEmpty, reason: 'the yielding side still offered');
        expect(api.sent(lane.answer).single.connId, 'theirs');
        await r.openAll();
        expect(lane.has(r.service, 'b'), isTrue, reason: 'the open channel is not the stored one');
        await r.service.dispose();
      });

      test('an offer during our dial: the higher id keeps its dial', () async {
        final r = _Rig('b');
        final dial = lane.dial(r.service, 'a');
        await r.pump();
        final offer = r.service.handleSignal('a', lane.offer, 'v=0', 'theirs');
        await r.pump();
        r.finishAll();
        await Future.wait([dial, offer]);

        expect(r.live, hasLength(1), reason: 'two connections outlived the crossing');
        expect(api.sent(lane.answer), isEmpty, reason: 'the keeping side answered too');
        expect(api.sent(lane.offer), hasLength(1));
        await r.openAll();
        expect(lane.has(r.service, 'a'), isTrue, reason: 'the open channel is not the stored one');
        await r.service.dispose();
      });

      for (final me in ['a', 'b']) {
        final them = me == 'a' ? 'b' : 'a';
        test('our dial while an offer is being answered ($me vs $them): the answer stays', () async {
          final r = _Rig(me);
          final offer = r.service.handleSignal(them, lane.offer, 'v=0', 'theirs');
          await r.pump();
          final dial = lane.dial(r.service, them);
          await r.pump();
          r.finishAll();
          await Future.wait([dial, offer]);

          expect(r.made, hasLength(1), reason: 'we built a connection to dial over an answer in flight');
          expect(api.sent(lane.offer), isEmpty, reason: 'we dialled over an answer in flight');
          expect(api.sent(lane.answer).single.connId, 'theirs');
          await r.openAll();
          expect(lane.has(r.service, them), isTrue, reason: 'the open channel is not the stored one');
          await r.service.dispose();
        });
      }

      test('an offer after our dial is stored: the lower id never sends its offer', () async {
        final r = _Rig('a')..offerGate = Completer<void>();
        final dial = lane.dial(r.service, 'b');
        await r.pump();
        r.finishAll();
        await r.pump();
        final offer = r.service.handleSignal('b', lane.offer, 'v=0', 'theirs');
        await r.pump();
        r.finishAll();
        await offer;
        r.offerGate!.complete();
        await dial;
        await r.pump();

        expect(r.live, hasLength(1), reason: 'two connections outlived the crossing');
        expect(api.sent(lane.offer), isEmpty, reason: 'the yielding side still offered');
        await r.openAll();
        expect(lane.has(r.service, 'b'), isTrue);
        await r.service.dispose();
      });

      test('a newer offer over our open channel closes it out once', () async {
        final r = _Rig('a');
        final dial = lane.dial(r.service, 'b');
        await r.pump();
        r.finishAll();
        await dial;
        await r.openAll();
        api.disconnects = 0;
        final offer = r.service.handleSignal('b', lane.offer, 'v=0', 'theirs');
        await r.pump();
        r.finishAll();
        await offer;
        r.made.first.channel?.fire(RTCDataChannelState.RTCDataChannelClosed);
        await r.pump();

        expect(api.disconnects, 1, reason: 'Rust heard the replaced channel close ${api.disconnects} times');
        expect(r.live, hasLength(1));
        await r.openAll();
        expect(lane.has(r.service, 'b'), isTrue);
        await r.service.dispose();
      });

      test('a superseded connection closing never takes the live one with it', () async {
        final r = _Rig('a');
        final dial = lane.dial(r.service, 'b');
        await r.pump();
        r.finishAll();
        await dial;
        final ours = r.made.single;
        final offer = r.service.handleSignal('b', lane.offer, 'v=0', 'theirs');
        await r.pump();
        r.finishAll();
        await offer;
        await r.openAll();
        ours.channel?.fire(RTCDataChannelState.RTCDataChannelClosed);
        ours.onConnectionState?.call(RTCPeerConnectionState.RTCPeerConnectionStateFailed);
        await r.pump();
        expect(lane.has(r.service, 'b'), isTrue, reason: 'a stale close tore down the live channel');
        await r.service.dispose();
      });
    });
  }
}

enum _Lane {
  general('offer', 'answer'),
  share('share_offer', 'share_answer');

  const _Lane(this.offer, this.answer);
  final String offer;
  final String answer;

  Future<void> dial(WebRtcService s, String peer) => this == general
      ? s.connectToPeer(peer)
      : s.connectShareToPeer(peer, const {'iceServers': <Object>[]});

  bool has(WebRtcService s, String peer) =>
      this == general ? s.hasPeerChannel(peer) : s.hasShareChannel(peer);
}

/// A service whose peer connections are built only when the test says so.
class _Rig {
  _Rig(String me) {
    service = WebRtcService(
      localPeerId: me,
      iceServers: const {'iceServers': <Object>[]},
      newPeerConnection: (_) {
        final c = Completer<RTCPeerConnection>();
        _pending.add(c);
        return c.future;
      },
    );
  }

  late final WebRtcService service;
  Completer<void>? offerGate;
  final _pending = <Completer<RTCPeerConnection>>[];
  final made = <_FakePc>[];

  List<_FakePc> get live => made.where((p) => !p.closed).toList();

  /// Builds every peer connection asked for so far, oldest first.
  void finishAll() {
    for (final c in _pending) {
      final pc = _FakePc(this);
      made.add(pc);
      c.complete(pc);
    }
    _pending.clear();
  }

  Future<void> pump() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Opens the data channel of every connection still alive.
  Future<void> openAll() async {
    for (final pc in live) {
      if (pc.channel == null) {
        final dc = _FakeDc();
        pc.channel = dc;
        pc.onDataChannel?.call(dc);
      }
      pc.channel!.fire(RTCDataChannelState.RTCDataChannelOpen);
    }
    await pump();
  }
}

class _FakePc extends RTCPeerConnection {
  _FakePc(this.rig);
  final _Rig rig;
  bool closed = false;
  _FakeDc? channel;

  @override
  Future<RTCDataChannel> createDataChannel(String label, RTCDataChannelInit dataChannelDict) async =>
      channel = _FakeDc();

  @override
  Future<RTCSessionDescription> createOffer([Map<String, dynamic>? constraints]) async {
    await rig.offerGate?.future;
    return RTCSessionDescription('v=0 offer', 'offer');
  }

  @override
  Future<RTCSessionDescription> createAnswer([Map<String, dynamic>? constraints]) async =>
      RTCSessionDescription('v=0 answer', 'answer');

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {}

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {}

  @override
  Future<void> addCandidate(RTCIceCandidate candidate) async {}

  @override
  RTCSignalingState? get signalingState => RTCSignalingState.RTCSignalingStateStable;

  @override
  Future<void> close() async => closed = true;

  @override
  Future<void> dispose() async => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDc extends RTCDataChannel {
  RTCDataChannelState _state = RTCDataChannelState.RTCDataChannelConnecting;

  void fire(RTCDataChannelState s) {
    _state = s;
    onDataChannelState?.call(s);
  }

  @override
  RTCDataChannelState? get state => _state;

  @override
  String? get label => 'fake';

  @override
  Future<void> send(RTCDataChannelMessage message) async {}

  @override
  Future<void> close() async => _state = RTCDataChannelState.RTCDataChannelClosed;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Api implements RustLibApi {
  final signals = <({String type, String connId})>[];

  List<({String type, String connId})> sent(String type) =>
      signals.where((s) => s.type == type).toList();

  @override
  Future<void> crateApiNetworkWebrtcSendSignal({
    required String peerId,
    required String signalType,
    required String payload,
    required String connId,
  }) async =>
      signals.add((type: signalType, connId: connId));

  int disconnects = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    if (name.contains('PeerDisconnected')) disconnects++;
    return name.contains('crateApi') ? Future<void>.value() : super.noSuchMethod(invocation);
  }
}
