import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/services/frame_cryptor_service.dart';
import 'package:hollow/src/core/services/local_meter_loopback.dart';
import 'package:hollow/src/core/services/overlay_mic.dart';
import 'package:hollow/src/core/services/pending_ice_queue.dart';
import 'package:hollow/src/core/services/voice_channel_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';

import 'helpers/fake_frame_cryptor.dart';
import 'helpers/fake_mic.dart';

/// A voice leg keeps the candidates its peer trickles while the leg is being
/// built, and only those.
///
/// The peer sends its offer and trickles candidates straight after it. Signals
/// are dispatched without waiting for the previous one, so candidates land
/// while the leg is still closing the old connection or opening the new one.
/// They were wiped there, so the leg had none of the peer's candidates and
/// lived on whatever it could discover itself; a relay-only peer has nothing
/// to discover and the leg never connected.

const _self = '12D3KooWAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _peer = '12D3KooWBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

class _Api implements RustLibApi {
  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  Future<void> crateApiNetworkVoiceChannelSendSignal({
    required String serverId,
    required String channelId,
    required String peerId,
    required String signalType,
    required String payload,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _track(String id) =>
    {'id': id, 'label': id, 'kind': 'audio', 'enabled': true};

Map<String, dynamic> _params() => {
      'transactionId': '',
      'rtcp': {'cname': '', 'reducedSize': false},
      'headerExtensions': [],
      'encodings': [],
      'codecs': [],
    };

String _sdp(String type, String ufrag) => [
      'v=0',
      'o=- 1 2 IN IP4 127.0.0.1',
      's=-',
      't=0 0',
      'm=audio 9 UDP/TLS/RTP/SAVPF 111',
      'c=IN IP4 0.0.0.0',
      'a=ice-ufrag:$ufrag',
      'a=ice-pwd:0123456789abcdef01234567',
      'a=mid:0',
      'a=rtpmap:111 opus/48000/2',
      '',
    ].join('\r\n');

String _cand(String ip, {String? ufrag}) =>
    'candidate:1 1 udp 2122260223 $ip 50000 typ host generation 0'
    '${ufrag == null ? '' : ' ufrag $ufrag'} network-id 1';

/// The native side: which PC each call reached, in order, with gates that
/// hold a call in native until the test lets it go.
class _Native {
  int _made = 0;
  final calls = <String>[];
  final pcs = <String>[];
  Completer<void>? createGate;
  Completer<void>? closeGate;
  Completer<void>? candidateGate;

  List<String> added(String pc) => [
        for (final c in calls)
          if (c.startsWith('cand:$pc:')) c.substring('cand:$pc:'.length),
      ];

  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (var i = 0; i < 8; i++) {
      messenger.setMockStreamHandler(
          EventChannel('FlutterWebRTC/peerConnectionEventpc$i'),
          MockStreamHandler.inline(onListen: (_, _) {}));
    }
    messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'), (call) async {
      final args = (call.arguments as Map?) ?? const {};
      final pc = args['peerConnectionId'] as String?;
      switch (call.method) {
        case 'getUserMedia':
          return {
            'streamId': 'mic',
            'audioTracks': [_track('mic-track')],
            'videoTracks': [],
          };
        case 'createPeerConnection':
          final gate = createGate;
          createGate = null;
          if (gate != null) await gate.future;
          final id = 'pc${_made++}';
          pcs.add(id);
          return {'peerConnectionId': id};
        case 'addTrack':
          return {
            'senderId': args['trackId'],
            'track': _track(args['trackId'] as String),
            'rtpParameters': _params(),
            'ownsTrack': false,
          };
        case 'createOffer':
          return {'sdp': _sdp('offer', 'self$pc'), 'type': 'offer'};
        case 'createAnswer':
          return {'sdp': _sdp('answer', 'self$pc'), 'type': 'answer'};
        case 'setRemoteDescription':
          calls.add('srd:$pc');
          return null;
        case 'addCandidate':
          calls.add('cand:$pc:${(args['candidate'] as Map)['candidate']}');
          final gate = candidateGate;
          candidateGate = null;
          if (gate != null) await gate.future;
          return null;
        case 'peerConnectionClose':
          calls.add('close:$pc');
          final gate = closeGate;
          closeGate = null;
          if (gate != null) await gate.future;
          return null;
        case 'getCaptureLevel':
          return {'levelDb': -100.0};
        case 'frameCryptorFactoryCreateKeyProvider':
          return {'keyProviderId': 'kp'};
      }
      return null;
    });
  }

  void uninstall() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'), null);
    for (var i = 0; i < 8; i++) {
      messenger.setMockStreamHandler(
          EventChannel('FlutterWebRTC/peerConnectionEventpc$i'), null);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => RustLib.initMock(api: _Api()));

  late _Native native;
  late VoiceChannelService svc;

  setUp(() async {
    native = _Native()..install();
    debugOverlayMic = overlayMicOn(FakeMic([]));
    svc = VoiceChannelService(
      localPeerId: _self,
      iceServers: const {},
      aloneMeter: AloneMeterKeeper<MediaStream, Object>(
          start: (_) async => Object(), stop: (_) async {}),
    );
    await svc.startAudio('srv', 'vc');
    svc.frameCryptor = FrameCryptorService(factory: FakeFrameCryptorFactory());
    await svc.frameCryptor!.init(sharedKey: true);
    await svc.setSframeKey(1, Uint8List(32));
  });

  tearDown(() async {
    await svc.closeAll();
    native.uninstall();
  });

  Future<void> signal(String type, Map<String, dynamic> body) =>
      svc.handleSignal(_peer, type, jsonEncode(body), 'srv', 'vc');

  Future<void> offer(String ufrag) =>
      signal('sdp_offer', {'sdp': _sdp('offer', ufrag)});

  Future<void> ice(String candidate) => signal('ice', {
        'candidate': candidate,
        'sdpMid': '0',
        'sdpMLineIndex': 0,
      });

  test('a candidate that lands while the leg opens is added once the offer is set',
      () async {
    final createGate = native.createGate = Completer<void>();
    final answering = offer('peer1');
    await pumpEventQueue();
    await ice(_cand('10.0.0.1', ufrag: 'peer1'));
    await ice(_cand('10.0.0.2'));
    createGate.complete();
    await answering;

    final pc = native.pcs.single;
    expect(native.added(pc),
        [_cand('10.0.0.1', ufrag: 'peer1'), _cand('10.0.0.2')],
        reason: 'the candidates trickled during the leg setup were wiped');
    expect(native.calls.indexOf('srd:$pc'),
        lessThan(native.calls.indexWhere((c) => c.startsWith('cand:$pc:'))),
        reason: 'a candidate reached the leg before its offer');
  });

  test('a candidate that lands while the old leg closes reaches the new one',
      () async {
    await offer('peer1');
    final old = native.pcs.single;

    final closeGate = native.closeGate = Completer<void>();
    final rebuilding = offer('peer2');
    await pumpEventQueue();
    expect(native.calls, contains('close:$old'));
    await ice(_cand('10.0.0.3', ufrag: 'peer2'));
    closeGate.complete();
    await rebuilding;

    final fresh = native.pcs.last;
    expect(fresh, isNot(old));
    expect(native.added(fresh), [_cand('10.0.0.3', ufrag: 'peer2')],
        reason: 'the rebuild wiped a candidate meant for the new leg');
  });

  test("an old session's candidate never reaches the leg built after it",
      () async {
    await offer('peer1');
    final old = native.pcs.single;

    final createGate = native.createGate = Completer<void>();
    final rebuilding = offer('peer2');
    await pumpEventQueue();
    await ice(_cand('10.0.0.4', ufrag: 'peer1'));
    await ice(_cand('10.0.0.5', ufrag: 'peer2'));
    createGate.complete();
    await rebuilding;

    final fresh = native.pcs.last;
    expect(fresh, isNot(old));
    expect(native.added(fresh), [_cand('10.0.0.5', ufrag: 'peer2')],
        reason: "the previous session's candidate leaked into the new leg");
  });

  test('candidates held for a replaced leg go with it', () async {
    // We dial (the lower id), and the peer trickles before answering.
    await svc.onPeerJoinedMyChannel(_peer);
    final dialed = native.pcs.single;
    await ice(_cand('10.0.0.6'));

    // The peer rebuilds with an offer of its own instead.
    await offer('peer2');
    final fresh = native.pcs.last;
    expect(fresh, isNot(dialed));
    expect(native.added(fresh), isEmpty,
        reason: 'a candidate held for the replaced leg reached the new one');
  });

  test('a flush stops once its leg is gone', () async {
    final createGate = native.createGate = Completer<void>();
    final answering = offer('peer1');
    await pumpEventQueue();
    await ice(_cand('10.0.0.7', ufrag: 'peer1'));
    await ice(_cand('10.0.0.8', ufrag: 'peer1'));
    final candidateGate = native.candidateGate = Completer<void>();
    createGate.complete();
    await pumpEventQueue();
    final pc = native.pcs.single;
    expect(native.added(pc), [_cand('10.0.0.7', ufrag: 'peer1')]);

    await svc.onPeerLeftMyChannel(_peer);
    candidateGate.complete();
    await answering;

    expect(native.added(pc), [_cand('10.0.0.7', ufrag: 'peer1')],
        reason: 'the flush kept adding candidates to a closed leg');
  });

  group('candidateFitsRemoteSdp', () {
    test('a candidate naming the description ufrag fits', () {
      expect(candidateFitsRemoteSdp(_cand('1.1.1.1', ufrag: 'u1'), _sdp('offer', 'u1')),
          isTrue);
    });

    test('a candidate naming another ufrag does not', () {
      expect(candidateFitsRemoteSdp(_cand('1.1.1.1', ufrag: 'u0'), _sdp('offer', 'u1')),
          isFalse);
    });

    test('a candidate without a ufrag fits', () {
      expect(candidateFitsRemoteSdp(_cand('1.1.1.1'), _sdp('offer', 'u1')), isTrue);
    });

    test('a description without a ufrag takes every candidate', () {
      expect(candidateFitsRemoteSdp(_cand('1.1.1.1', ufrag: 'u0'), 'v=0\r\n'), isTrue);
    });

    test('a ufrag that only prefixes the real one does not fit', () {
      expect(candidateFitsRemoteSdp(_cand('1.1.1.1', ufrag: 'u1'), _sdp('offer', 'u12')),
          isFalse);
    });
  });
}
