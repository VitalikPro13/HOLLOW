
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/webrtc_provider.dart';
import 'package:hollow/src/core/services/screen_share_service.dart';
import 'package:hollow/src/core/services/setup_failure_grace.dart';
import 'package:hollow/src/core/services/sound_service.dart';
import 'package:hollow/src/core/services/voice_channel_service.dart';
import 'package:hollow/src/core/services/voice_service.dart';
import 'package:hollow/src/core/services/webrtc_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';

/// A link that fails before its first connect gets a moment to revive.
///
/// Under "Always relay calls" coturn's peer lock refuses the remote's host and
/// srflx pairs in about a millisecond, so libwebrtc reports `failed` before the
/// remote relay candidate is added, then revives itself (failed, connecting,
/// connected in the same second). Every lane read that first `failed` as the
/// end: the DM caller hung up, the voice mesh closed the leg, the share and
/// data channel lanes tore down.
const _failed = RTCPeerConnectionState.RTCPeerConnectionStateFailed;
const _connecting = RTCPeerConnectionState.RTCPeerConnectionStateConnecting;
const _connected = RTCPeerConnectionState.RTCPeerConnectionStateConnected;

// Wall-clock: long enough that a loaded runner drains the event queue inside it.
const _grace = Duration(milliseconds: 500);
Future<void> _pastGrace() => Future<void>.delayed(_grace * 2);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = _Api();
  setUpAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['FlutterWebRTC.Method', 'FlutterWebRTC.Event']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    RustLib.initMock(api: api);
    SoundService.enabled = false;
  });
  setUp(api.logs.clear);

  group('SetupFailureGrace', () {
    test('a failure that revives and connects never expires', () async {
      var expired = 0;
      final g = SetupFailureGrace(onExpired: () => expired++, grace: _grace);
      expect(g.note(_failed), isTrue);
      g.note(_connecting);
      g.note(_connected);
      expect(g.isHolding, isFalse, reason: 'a connect must disarm the grace');
      await _pastGrace();
      expect(expired, 0);
      expect(g.isHolding, isFalse);
    });

    test('a failure that stays failed expires once, after the grace', () async {
      var expired = 0;
      final g = SetupFailureGrace(onExpired: () => expired++, grace: _grace);
      g.note(_failed);
      g.note(_failed);
      await Future<void>.delayed(_grace ~/ 2);
      expect(expired, 0, reason: 'expired before the grace ran out');
      await _pastGrace();
      expect(expired, 1);
    });

    test('flapping keeps the first deadline', () async {
      var expired = 0;
      final g = SetupFailureGrace(onExpired: () => expired++, grace: _grace);
      g.note(_failed);
      await Future<void>.delayed(_grace ~/ 2);
      g.note(_connecting);
      g.note(_failed);
      await Future<void>.delayed(_grace * 0.75);
      expect(expired, 1, reason: 'a re-failure restarted the clock');
    });

    test('still connecting at the deadline is not a failure', () async {
      var expired = 0;
      final g = SetupFailureGrace(onExpired: () => expired++, grace: _grace);
      g.note(_failed);
      g.note(_connecting);
      await _pastGrace();
      expect(expired, 0);
      g.note(_failed);
      await _pastGrace();
      expect(expired, 1, reason: 'a later failure must get its own verdict');
    });

    test('a cancelled grace never fires', () async {
      var expired = 0;
      final g = SetupFailureGrace(onExpired: () => expired++, grace: _grace);
      g.note(_failed);
      g.cancel();
      await _pastGrace();
      expect(expired, 0);
    });
  });

  group('DM call lane', () {
    ({ProviderContainer c, CallNotifier call}) rig() {
      final c = ProviderContainer(overrides: [
        callProvider.overrideWith(_Connecting.new),
        webRtcProvider.overrideWith(_DataChannels.new),
      ]);
      addTearDown(c.dispose);
      final call = c.read(callProvider.notifier)..setupFailureGrace = _grace;
      return (c: c, call: call);
    }

    test('failed, connecting, connected before the first connect keeps the '
        'call', () async {
      final r = rig();
      r.call.debugTransportState(_failed);
      await pumpEventQueue();
      r.call.debugTransportState(_connecting);
      r.call.debugTransportState(_connected);
      await _pastGrace();
      expect(r.c.read(callProvider).status, CallStatus.connecting,
          reason: 'the caller hung up on a failure libwebrtc revived');
    });

    test('a failure that stays failed still ends the call after the grace',
        () async {
      final r = rig();
      r.call.debugTransportState(_failed);
      await pumpEventQueue();
      expect(r.c.read(callProvider).status, CallStatus.connecting,
          reason: 'ended inside the grace');
      await _pastGrace();
      await pumpEventQueue();
      expect(r.c.read(callProvider).status, CallStatus.idle);
    });

    test('a failure the call then connects through keeps the call', () async {
      final r = rig();
      r.call.debugTransportState(_failed);
      r.call.debugVoiceService.onConnected!('peer');
      r.call.debugTransportState(_connected);
      await _pastGrace();
      await pumpEventQueue();
      expect(r.c.read(callProvider).status, CallStatus.active,
          reason: 'the setup grace outlived the connect');
      await r.call.endCall();
    });

    test("a hung-up call's grace never ends the next call", () async {
      final r = rig();
      r.call.debugTransportState(_failed);
      await r.call.endCall();
      expect(r.c.read(callProvider).status, CallStatus.idle);
      (r.call as _Connecting).redial('c2');
      await _pastGrace();
      await pumpEventQueue();
      expect(r.c.read(callProvider).status, CallStatus.connecting,
          reason: 'the old call\'s setup grace survived its teardown');
    });
  });

  group('voice channel lane', () {
    VoiceChannelService mesh(_FakePc pc) {
      final s = VoiceChannelService(localPeerId: 'me', iceServers: const {})
        ..setupFailureGrace = _grace
        ..debugAdoptPeer('peer', pc);
      addTearDown(() => s.closePeer('peer'));
      return s;
    }

    test('failed, connecting, connected before the first connect keeps the '
        'leg', () async {
      final pc = _FakePc();
      final s = mesh(pc);
      pc.fire(_failed);
      await pumpEventQueue();
      pc.fire(_connecting);
      pc.fire(_connected);
      await _pastGrace();
      expect(pc.closed, isFalse, reason: 'the leg was closed on a revivable '
          'failure');
      expect(s.pcFor('peer'), same(pc));
    });

    test('a leg that connects straight out of failed keeps the leg', () async {
      final pc = _FakePc();
      final s = mesh(pc);
      pc.fire(_failed);
      pc.fire(_connected);
      await _pastGrace();
      await pumpEventQueue();
      expect(pc.closed, isFalse,
          reason: 'the setup grace outlived the connect and closed the leg');
      expect(s.pcFor('peer'), same(pc));
    });

    test('a failure that stays failed closes the leg after the grace',
        () async {
      final pc = _FakePc();
      final s = mesh(pc);
      pc.fire(_failed);
      await pumpEventQueue();
      expect(pc.closed, isFalse, reason: 'closed inside the grace');
      await _pastGrace();
      await pumpEventQueue();
      expect(pc.closed, isTrue);
      expect(s.pcFor('peer'), isNull);
    });

    test('a replaced leg is not closed by the old one\'s grace', () async {
      final old = _FakePc();
      final s = mesh(old);
      old.fire(_failed);
      await s.closePeer('peer');
      final fresh = _FakePc();
      s.debugAdoptPeer('peer', fresh);
      await _pastGrace();
      await pumpEventQueue();
      expect(fresh.closed, isFalse);
      expect(s.pcFor('peer'), same(fresh));
    });
  });

  group('screen share lane', () {
    test('a share closed inside the grace is never dropped again', () async {
      var drops = 0;
      final s = ScreenShareService(localPeerId: 'me', iceServers: const {})
        ..setupFailureGrace = _grace
        ..onDisconnected = () => drops++;
      s.debugConnectionState(_failed);
      await s.close();
      await _pastGrace();
      expect(drops, 0);
    });

    test('closed inside the grace drops the leg once', () async {
      var drops = 0;
      final s = ScreenShareService(localPeerId: 'me', iceServers: const {})
        ..setupFailureGrace = _grace
        ..onDisconnected = () => drops++;
      addTearDown(s.close);
      s.debugConnectionState(_failed);
      s.debugConnectionState(
          RTCPeerConnectionState.RTCPeerConnectionStateClosed);
      await _pastGrace();
      expect(drops, 1);
    });

    test('failed, connecting, connected before the first connect keeps the '
        'leg', () async {
      var drops = 0;
      final s = ScreenShareService(localPeerId: 'me', iceServers: const {})
        ..setupFailureGrace = _grace
        ..onDisconnected = () => drops++;
      addTearDown(s.close);
      s.debugConnectionState(_failed);
      s.debugConnectionState(_connecting);
      s.debugConnectionState(_connected);
      await _pastGrace();
      expect(drops, 0);
    });

    test('a failure that stays failed drops the leg after the grace', () async {
      var drops = 0;
      final s = ScreenShareService(localPeerId: 'me', iceServers: const {})
        ..setupFailureGrace = _grace
        ..onDisconnected = () => drops++;
      addTearDown(s.close);
      s.debugConnectionState(_failed);
      expect(drops, 0, reason: 'dropped inside the grace');
      await _pastGrace();
      expect(drops, 1);
    });

    test('after a connect, failed still drops at once', () async {
      var drops = 0;
      final s = ScreenShareService(localPeerId: 'me', iceServers: const {})
        ..setupFailureGrace = _grace
        ..onDisconnected = () => drops++;
      addTearDown(s.close);
      s.debugConnectionState(_connected);
      s.debugConnectionState(_failed);
      expect(drops, 1);
    });
  });

  group('data channel lane', () {
    Future<({WebRtcService s, _FakePc pc})> dialed() async {
      late _FakePc pc;
      final s = WebRtcService(
        localPeerId: 'a',
        iceServers: const {'iceServers': <Object>[]},
        newPeerConnection: (_) async => pc = _FakePc(),
      )..setupFailureGrace = _grace;
      addTearDown(s.dispose);
      await s.connectToPeer('b');
      return (s: s, pc: pc);
    }

    test('failed, connecting, connected before the first connect keeps the '
        'connection', () async {
      final r = await dialed();
      r.pc.fire(_failed);
      await pumpEventQueue();
      r.pc.fire(_connecting);
      r.pc.fire(_connected);
      await _pastGrace();
      expect(r.pc.closed, isFalse);
    });

    test('a failure that stays failed closes after the grace', () async {
      final r = await dialed();
      r.pc.fire(_failed);
      await pumpEventQueue();
      expect(r.pc.closed, isFalse, reason: 'closed inside the grace');
      await _pastGrace();
      await pumpEventQueue();
      expect(r.pc.closed, isTrue);
    });

    test('a connection torn down inside the grace is not failed again',
        () async {
      final r = await dialed();
      r.pc.fire(_failed);
      await r.s.disconnectPeer('b');
      await pumpEventQueue();
      final before = api.disconnects;
      await _pastGrace();
      await pumpEventQueue();
      expect(api.disconnects, before,
          reason: 'a dead connection\'s grace reported it failed');
    });

    test('after a connect, failed still closes at once', () async {
      final r = await dialed();
      r.pc.fire(_connected);
      r.pc.fire(_failed);
      await pumpEventQueue();
      expect(r.pc.closed, isTrue);
    });
  });

  group('DM queued candidate flush', () {
    RTCIceCandidate cand(int i) =>
        RTCIceCandidate('candidate:$i 1 udp 1 10.0.0.$i 9 typ host', '0', 0);

    test('stops when the call\'s peer connection is replaced mid-flush',
        () async {
      final v = VoiceService(localPeerId: 'me');
      final first = _FakePc();
      final second = _FakePc();
      v.debugAdoptPeerConnection(first, callId: 'c1');
      for (var i = 0; i < 4; i++) {
        await v.handleIceCandidate('c1', cand(i).candidate!, '0', 0);
      }
      first.onAdd = () {
        first.closed = true;
        v.debugAdoptPeerConnection(second);
      };
      await v.handleAnswer('v=0');
      expect(first.added, hasLength(1));
      expect(second.added, isEmpty,
          reason: 'the old setup\'s candidates went to its replacement');
      expect(api.logs.where((l) => l.contains('Failed to add queued ICE')),
          isEmpty,
          reason: 'the flush kept adding to the closed peer connection');
    });

    test('stops quietly when the peer connection is torn down mid-flush',
        () async {
      final v = VoiceService(localPeerId: 'me');
      final pc = _FakePc();
      v.debugAdoptPeerConnection(pc, callId: 'c1');
      for (var i = 0; i < 4; i++) {
        await v.handleIceCandidate('c1', cand(i).candidate!, '0', 0);
      }
      pc.onAdd = () {
        pc.closed = true;
        v.debugAdoptPeerConnection(null);
      };
      await v.handleAnswer('v=0');
      expect(pc.added, hasLength(1));
      expect(api.logs.where((l) => l.contains('Failed to add queued ICE')),
          isEmpty,
          reason: 'the flush kept adding to a torn-down call');
    });
  });
}

class _Connecting extends CallNotifier {
  @override
  CallState build() {
    super.build();
    return _seed('c1');
  }

  /// A new outgoing call, as `startCall` leaves it before the transport is up.
  void redial(String callId) => state = _seed(callId);

  static CallState _seed(String callId) => CallState(
        status: CallStatus.connecting,
        peerId: 'peer',
        callId: callId,
        direction: CallDirection.outgoing,
      );
}

class _DataChannels extends WebRtcNotifier {
  final _service = WebRtcService(
    localPeerId: 'me',
    iceServers: const {'iceServers': <Object>[]},
    newPeerConnection: (_) async => _FakePc(),
  );

  @override
  WebRtcService get service => _service;
}

class _FakePc extends RTCPeerConnection {
  bool closed = false;
  RTCPeerConnectionState? _state;
  final added = <RTCIceCandidate>[];
  void Function()? onAdd;

  void fire(RTCPeerConnectionState s) {
    _state = s;
    onConnectionState?.call(s);
  }

  @override
  RTCPeerConnectionState? get connectionState => _state;

  @override
  Future<void> addCandidate(RTCIceCandidate candidate) async {
    if (closed) throw StateError('addCandidate on a closed peer connection');
    added.add(candidate);
    final hook = onAdd;
    onAdd = null;
    hook?.call();
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<RTCDataChannel> createDataChannel(
          String label, RTCDataChannelInit dataChannelDict) async =>
      _FakeDc();

  @override
  Future<RTCSessionDescription> createOffer(
          [Map<String, dynamic>? constraints]) async =>
      RTCSessionDescription('v=0 offer', 'offer');

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {}

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {}

  @override
  Future<List<StatsReport>> getStats([MediaStreamTrack? track]) async => [];

  @override
  Future<List<RTCRtpReceiver>> getReceivers() async => [];

  @override
  Future<List<RTCRtpSender>> getSenders() async => [];

  @override
  Future<List<RTCRtpTransceiver>> getTransceivers() async => [];

  @override
  RTCSignalingState? get signalingState =>
      RTCSignalingState.RTCSignalingStateStable;

  @override
  Future<void> close() async => closed = true;

  @override
  Future<void> dispose() async => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDc extends RTCDataChannel {
  @override
  RTCDataChannelState? get state => RTCDataChannelState.RTCDataChannelConnecting;

  @override
  String? get label => 'fake';

  @override
  Future<void> send(RTCDataChannelMessage message) async {}

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Api implements RustLibApi {
  final logs = <String>[];
  int disconnects = 0;

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async =>
      logs.add(message);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    if (name.contains('PeerDisconnected')) disconnects++;
    return name.contains('crateApi')
        ? Future<void>.value()
        : super.noSuchMethod(invocation);
  }
}
