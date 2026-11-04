import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/services/frame_cryptor_service.dart';
import 'package:hollow/src/core/services/gossip_forward.dart';
import 'package:hollow/src/core/services/local_meter_loopback.dart';
import 'package:hollow/src/core/services/overlay_mic.dart';
import 'package:hollow/src/core/services/voice_channel_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';

import 'helpers/fake_frame_cryptor.dart';
import 'helpers/fake_mic.dart';

const _a = '12D3KooWAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _b = '12D3KooWBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const _c = '12D3KooWCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC';
const _d = '12D3KooWDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD';

class _Signal {
  _Signal(this.peerId, this.type, this.payload);
  final String peerId, type, payload;
}

final _signals = <_Signal>[];

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
  }) async =>
      _signals.add(_Signal(peerId, signalType, payload));

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

/// The native side of a voice channel's peer connections: every PC the
/// service opens, the tracks it sends, and an event sink per PC.
class _Native {
  int _made = 0;
  final sinks = <String, MockStreamHandlerEventSink>{};
  final received = <String, List<String>>{};
  final volumes = <(String, double)>[];

  /// Every volume call as the native side receives it: connection, receiver.
  final volumeCalls = <(String?, String?, double)>[];
  final sent = <String, List<(String track, String stream)>>{};

  /// The sender id each sent track's m-section carries in the SDP.
  final senderOf = <String, String>{};

  /// A stopped video transceiver comes first, and narrowing it throws.
  bool stoppedFirst = false;

  /// True when the leg's own audio m-section has no sender track (a forwarder
  /// without a microphone): addTrack then reuses it, keeping its own id.
  bool reuseAudioSection = false;

  /// Native calls in order, for what must happen before an offer.
  final calls = <String>[];

  /// The PC opened for each leg, in order.
  final pcs = <String>[];

  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (var i = 0; i < 8; i++) {
      final id = 'pc$i';
      messenger.setMockStreamHandler(
          EventChannel('FlutterWebRTC/peerConnectionEvent$id'),
          MockStreamHandler.inline(
              onListen: (_, sink) => sinks[id] = sink));
    }
    messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'), (call) async {
      final args = (call.arguments as Map?) ?? const {};
      final pc = args['peerConnectionId'] as String?;
      calls.add('${call.method}:${pc ?? ''}');
      switch (call.method) {
        case 'getUserMedia':
          if (reuseAudioSection) {
            throw PlatformException(code: 'NotAllowedError');
          }
          return {
            'streamId': 'mic',
            'audioTracks': [_track('mic-track')],
            'videoTracks': [],
          };
        case 'createPeerConnection':
          final id = 'pc${_made++}';
          pcs.add(id);
          return {'peerConnectionId': id};
        case 'addTrack':
          final streams = (args['streamIds'] as List?) ?? const [];
          final trackId = args['trackId'] as String;
          (sent[pc!] ??= []).add((trackId, (streams.firstOrNull ?? '') as String));
          final senderId = reuseAudioSection && sent[pc]!.length == 1
              ? 'section0-$pc'
              : trackId;
          senderOf[trackId] = senderId;
          return {
            'senderId': senderId,
            'track': _track(args['trackId'] as String),
            'rtpParameters': _params(),
            'ownsTrack': false,
          };
        case 'createOffer':
          final lines = [
            'v=0',
            for (final (track, stream) in sent[pc] ?? const <(String, String)>[])
              ...[
                'm=audio 9 UDP/TLS/RTP/SAVPF 111',
                'a=msid:$stream ${senderOf[track]}'
              ],
          ];
          return {'sdp': '${lines.join('\r\n')}\r\n', 'type': 'offer'};
        case 'getReceivers':
          return {
            'receivers': [
              for (final t in received[pc] ?? const <String>[])
                {'receiverId': 'r-$t', 'track': _track(t), 'rtpParameters': _params()},
            ]
          };
        case 'setVolume':
          // What the native side may resolve: the named receiver on the named
          // connection, never a track id (HOL-SEC-190).
          final receiverId = args['receiverId'] as String?;
          final volume = (args['volume'] as num).toDouble();
          volumeCalls.add((pc, receiverId, volume));
          for (final t in received[pc] ?? const <String>[]) {
            if (receiverId != null && 'r-$t' == receiverId) {
              volumes.add((t, volume));
            }
          }
          return null;
        case 'getCaptureLevel':
          return {'levelDb': -100.0};
        case 'frameCryptorFactoryCreateKeyProvider':
          return {'keyProviderId': 'kp'};
        case 'removeTrack':
          return true;
        case 'getTransceivers':
          return {
            'transceivers': [
              if (stoppedFirst)
                {
                  'transceiverId': 'stopped-$pc',
                  'direction': 'stopped',
                  'mid': '2',
                  'sender': {
                    'senderId': 'ss-$pc',
                    'track': {},
                    'rtpParameters': _params(),
                    'ownsTrack': false,
                  },
                  'receiver': {
                    'receiverId': 'sr-$pc',
                    'track': {
                      'id': 'st-$pc',
                      'label': 'st',
                      'kind': 'video',
                      'enabled': true
                    },
                    'rtpParameters': _params(),
                  },
                },
              {
                'transceiverId': 'video-$pc',
                'direction': 'recvonly',
                'mid': '1',
                'sender': {
                  'senderId': 'vs-$pc',
                  'track': {},
                  'rtpParameters': _params(),
                  'ownsTrack': false,
                },
                'receiver': {
                  'receiverId': 'vr-$pc',
                  'track': {
                    'id': 'vt-$pc',
                    'label': 'vt',
                    'kind': 'video',
                    'enabled': true
                  },
                  'rtpParameters': _params(),
                },
              }
            ]
          };
        case 'getRtpSenderCapabilities':
          return {
            'codecs': [
              for (final m in ['video/VP8', 'video/H264', 'video/AV1', 'video/H265', 'video/rtx'])
                {'mimeType': m, 'clockRate': 90000},
            ],
            'headerExtensions': [],
            'fecMechanisms': [],
          };
        case 'setCodecPreferences':
          if ((args['transceiverId'] as String).startsWith('stopped-')) {
            throw PlatformException(code: 'InvalidState', message: 'stopped');
          }
          calls.add('codecs:${args['transceiverId']}:'
              '${(args['codecs'] as List).map((c) => (c as Map)['mimeType']).join(',')}');
          return null;
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
          EventChannel('FlutterWebRTC/peerConnectionEvent$i'), null);
    }
  }

  void connected(String pc) => sinks[pc]!
      .success({'event': 'peerConnectionState', 'state': 'connected'});

  void stable(String pc) =>
      sinks[pc]!.success({'event': 'signalingState', 'state': 'stable'});

  /// [pc] receives a speaker's voice straight from it.
  void voiceArrives(String pc, String track, String stream) {
    (received[pc] ??= []).add(track);
    sinks[pc]!.success({
        'event': 'onTrack',
        'streams': [
          {
            'streamId': stream,
            'ownerTag': pc,
            'audioTracks': [_track(track)],
            'videoTracks': [],
          }
        ],
        'receiver': {
          'receiverId': 'r-$track',
          'track': _track(track),
          'rtpParameters': _params(),
        },
        'track': _track(track),
        'transceiver': null,
      });
  }
}

/// A gossip forwarder answers a want with a renegotiation that carries the
/// asked voice under SFrame, whether it sat in the channel before the switch
/// to gossip or joined after it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => RustLib.initMock(api: _Api()));

  late _Native native;
  late VoiceChannelService svc;
  late FakeFrameCryptorFactory cryptors;

  Future<VoiceChannelService> join(String self) async {
    final s = VoiceChannelService(
      localPeerId: self,
      iceServers: const {},
      aloneMeter: AloneMeterKeeper<MediaStream, Object>(
          start: (_) async => Object(), stop: (_) async {}),
    );
    await s.startAudio('srv', 'vc');
    cryptors = FakeFrameCryptorFactory();
    s.frameCryptor = FrameCryptorService(factory: cryptors);
    await s.frameCryptor!.init(sharedKey: true);
    await s.setSframeKey(1, Uint8List(32));
    return s;
  }

  /// Opens our leg to [peer] and returns its native PC id.
  Future<String> leg(String peer) async {
    await svc.connectToPeer(peer);
    await pumpEventQueue();
    final pc = native.pcs.last;
    native.stable(pc);
    native.connected(pc);
    await pumpEventQueue();
    return pc;
  }

  Iterable<_Signal> sent(String type, String to) =>
      _signals.where((s) => s.type == type && s.peerId == to);

  Future<void> want(String from, Set<String> origins) => svc.handleSignal(
      from, 'fwd_want', jsonEncode({'origins': origins.toList()}), 'srv', 'vc');

  Future<void> settle() async {
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await pumpEventQueue();
  }

  setUp(() {
    _signals.clear();
    native = _Native()..install();
    debugOverlayMic = overlayMicOn(FakeMic([]));
    // The forwarding paths stay tested for the day a viable transport flips
    // the flag back on.
    gossipForwardingEnabled = true;
  });

  tearDown(() async {
    await svc.closeAll();
    native.uninstall();
    gossipForwardingEnabled = false;
  });

  void expectForwardedTo(String pc, String to, String origin) {
    expect(native.sent[pc], contains(('t-$origin', 's-$origin')),
        reason: 'the asked voice never went onto the leg');
    final reneg = sent('reneg_offer', to);
    expect(reneg, hasLength(1),
        reason: 'the forward never reached the far side, or took two offers');
    final sdp = (jsonDecode(reneg.single.payload) as Map)['sdp'] as String;
    expect(forwardedTracksIn(sdp), {native.senderOf['t-$origin']: origin},
        reason: 'the forwarded voice left unnamed, so it would take the '
            "forwarder's own decryptor");
    expect(
        cryptors.calls.where((c) => c.startsWith('tx') && c.endsWith('setEnabled:true')),
        isNotEmpty,
        reason: 'the forwarded voice left without SFrame');
  }

  test('a member that was in the channel before the switch forwards', () async {
    svc = await join(_b);
    final toA = await leg(_a);
    final toC = await leg(_c);
    native.voiceArrives(toC, 't-$_c', 's-$_c');
    native.voiceArrives(toA, 't-$_a', 's-$_a');
    await settle();
    _signals.clear();

    // The mode event may not have reached us yet; the want alone decides.
    await want(_a, {_c});
    await settle();
    expectForwardedTo(toA, _a, _c);
  });

  test('a forwarder without a microphone names the voice it forwards',
      () async {
    native.reuseAudioSection = true;
    svc = await join(_b);
    final toA = await leg(_a);
    final toC = await leg(_c);
    native.voiceArrives(toC, 't-$_c', 's-$_c');
    native.voiceArrives(toA, 't-$_a', 's-$_a');
    await settle();
    _signals.clear();

    await want(_a, {_c});
    await settle();
    expect(native.senderOf['t-$_c'], isNot('t-$_c'),
        reason: 'the fake must model the reused section');
    expectForwardedTo(toA, _a, _c);
  });

  test("a forward's renegotiation offers the leg's video as VP8 alone", () async {
    svc = await join(_b);
    final toA = await leg(_a);
    final toC = await leg(_c);
    native.voiceArrives(toC, 't-$_c', 's-$_c');
    native.voiceArrives(toA, 't-$_a', 's-$_a');
    await settle();
    native.calls.clear();

    await want(_a, {_c});
    await settle();
    final offerAt = native.calls.lastIndexOf('createOffer:$toA');
    final codecsAt =
        native.calls.indexOf('codecs:video-$toA:video/VP8,video/rtx');
    expect(codecsAt, isNot(-1),
        reason: 'the re-offer kept H.264, H.265 or AV1 on the video section, '
            'which an iOS offerer fails to apply');
    expect(codecsAt, lessThan(offerAt),
        reason: 'the codecs were narrowed after the offer was made');
  });

  test("a stopped video section never keeps a forward's re-offer off VP8",
      () async {
    svc = await join(_b);
    final toA = await leg(_a);
    final toC = await leg(_c);
    native.voiceArrives(toC, 't-$_c', 's-$_c');
    native.voiceArrives(toA, 't-$_a', 's-$_a');
    await settle();
    native.stoppedFirst = true;
    native.calls.clear();

    await want(_a, {_c});
    await settle();
    expect(native.calls, contains('codecs:video-$toA:video/VP8,video/rtx'),
        reason: 'one stopped transceiver left the live video section on '
            'every codec');
  });

  test('a member that joined after the switch forwards a voice it hears later',
      () async {
    svc = await join(_b);
    svc.gossipNeighbors = {_a, _c};
    svc.gossipMode = true;
    final toA = await leg(_a);
    await want(_a, {_c});
    await settle();
    expect(sent('reneg_offer', _a), isEmpty,
        reason: 'nothing to forward yet, nothing to renegotiate');

    final toC = await leg(_c);
    native.voiceArrives(toC, 't-$_c', 's-$_c');
    await settle();
    expectForwardedTo(toA, _a, _c);
  });

  test('an asker repeats its want once the leg is up at both ends', () async {
    svc = await join(_a);
    svc.channelMembers = () => {_b, _c};
    svc.gossipNeighbors = {_b};
    svc.gossipMode = true;
    await svc.connectToPeer(_b);
    await settle();
    expect(sent('fwd_want', _b), hasLength(1));

    // The far side may have had no leg to file the first want under.
    native.stable(native.pcs.last);
    native.connected(native.pcs.last);
    await settle();
    expect(sent('fwd_want', _b), hasLength(2),
        reason: 'a want the forwarder dropped is never asked again');
    expect(
        (jsonDecode(sent('fwd_want', _b).last.payload) as Map)['origins'], [_c]);
  });

  List<dynamic> lastWant(String to) =>
      (jsonDecode(sent('fwd_want', to).last.payload) as Map)['origins'] as List;

  test('a member with no live leg is asked for, neighbour or not', () async {
    svc = await join(_c);
    svc.legSetupGrace = const Duration(milliseconds: 1500);
    svc.channelMembers = () => {_a, _b, _d};
    svc.gossipNeighbors = {_b};
    svc.gossipMode = true;
    // A non-neighbour's leg came up in the switch race; the neighbour's never.
    await leg(_a);
    await settle();
    expect(lastWant(_a), [_d],
        reason: 'a neighbour still inside its setup grace is not asked for');

    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await settle();
    expect(lastWant(_a), [_b, _d],
        reason: 'a neighbour whose leg never formed is heard by nobody');
  });

  test('the dialing side offers again a neighbour leg that never came up',
      () async {
    gossipForwardingEnabled = false;
    svc = await join(_a);
    svc.legSetupGrace = const Duration(milliseconds: 1200);
    svc.channelMembers = () => {_b};
    svc.gossipNeighbors = {_b};
    svc.gossipMode = true;
    // The offer reaches a far side whose voice channel is not up yet.
    await svc.connectToPeer(_b);
    await settle();
    expect(sent('sdp_offer', _b), hasLength(1));

    await Future<void>.delayed(const Duration(milliseconds: 1000));
    await settle();
    expect(sent('sdp_offer', _b), hasLength(2),
        reason: 'an offer the far side lost leaves the leg down for good');
    expect(native.pcs, hasLength(2), reason: 'the stuck leg was not rebuilt');
  });

  test('the answering side asks for a neighbour leg that never came up',
      () async {
    gossipForwardingEnabled = false;
    svc = await join(_c);
    svc.legSetupGrace = const Duration(milliseconds: 1200);
    svc.channelMembers = () => {_b};
    svc.gossipNeighbors = {_b};
    svc.gossipMode = true;
    await settle();
    expect(sent('leg_restart', _b), isEmpty,
        reason: 'a leg still inside its setup grace was asked for');

    await Future<void>.delayed(const Duration(milliseconds: 1000));
    await settle();
    expect(sent('leg_restart', _b), hasLength(1),
        reason: 'the dialing side never hears that its offer was lost');
  });

  test('with forwarding off no heard voice goes onto another leg, and none is asked for',
      () async {
    gossipForwardingEnabled = false;
    svc = await join(_b);
    svc.channelMembers = () => {_a, _c};
    final toA = await leg(_a);
    final toC = await leg(_c);
    native.voiceArrives(toC, 't-$_c', 's-$_c');
    native.voiceArrives(toA, 't-$_a', 's-$_a');
    svc.gossipNeighbors = {_a};
    svc.gossipMode = true;
    await settle();

    await want(_a, {_c});
    await settle();
    expect(native.sent[toA]?.map((t) => t.$1), isNot(contains('t-$_c')),
        reason: "a remote track on a sender races the audio device's capture "
            'thread, and libwebrtc aborts the process');
    expect(sent('reneg_offer', _a), isEmpty);
    expect(sent('fwd_want', _a), isEmpty,
        reason: 'a want nobody may answer only costs the far side work');
  });

  test('turning forwarding off takes a live forward back off its leg',
      () async {
    svc = await join(_b);
    final toA = await leg(_a);
    final toC = await leg(_c);
    native.voiceArrives(toC, 't-$_c', 's-$_c');
    native.voiceArrives(toA, 't-$_a', 's-$_a');
    await settle();
    await want(_a, {_c});
    await settle();
    expectForwardedTo(toA, _a, _c);
    native.calls.clear();

    gossipForwardingEnabled = false;
    await svc.setSframeKey(2, Uint8List(32));
    await settle();
    expect(native.calls, contains('removeTrack:$toA'),
        reason: 'the forwarder kept a remote track on a sender with '
            'forwarding off');
  });
  test('with forwarding off a listener that misses a member asks nobody',
      () async {
    gossipForwardingEnabled = false;
    svc = await join(_b);
    svc.channelMembers = () => {_a, _c, _d};
    await leg(_a);
    await leg(_c);
    svc.gossipNeighbors = {_a, _c};
    svc.gossipMode = true;
    await settle();
    expect(
        forwardWants(
            gossip: true,
            self: _b,
            members: {_a, _c, _d},
            live: {_a, _c},
            settling: const {}),
        {_d},
        reason: 'the setup no longer produces a want, so it proves nothing');
    expect(sent('fwd_want', _a), isEmpty,
        reason: 'a want nobody may answer went out with forwarding off');
    expect(sent('fwd_want', _c), isEmpty);
  });

  test('with forwarding off a voice its leg names a forward obeys that member volume',
      () async {
    gossipForwardingEnabled = false;
    svc = await join(_b);
    svc.channelMembers = () => {_a};
    final toA = await leg(_a);
    native.voiceArrives(toA, 't-mic-of-a', '${kForwardStreamPrefix}NoSuchMember1');
    await settle();
    native.volumes.clear();
    await svc.setRemoteVolume(_a, 0.0);
    expect(native.volumes, contains(('t-mic-of-a', 0.0)),
        reason: "A's only voice kept playing after the listener turned A to 0, "
            'because it called itself a forward');
  });

  test('an ordinary voice obeys that member volume', () async {
    gossipForwardingEnabled = false;
    svc = await join(_b);
    svc.channelMembers = () => {_a};
    final toA = await leg(_a);
    native.voiceArrives(toA, 't-mic-of-a', 's-a');
    await settle();
    native.volumes.clear();
    await svc.setRemoteVolume(_a, 0.0);
    expect(native.volumes, contains(('t-mic-of-a', 0.0)));
  });

  test("with forwarding off a forward named with another member's track id never silences that member",
      () async {
    gossipForwardingEnabled = false;
    svc = await join(_b);
    svc.channelMembers = () => {_a, _c};
    final toA = await leg(_a);
    final toC = await leg(_c);
    native.voiceArrives(toC, 't-c', 's-c');
    native.voiceArrives(toA, 't-a', 's-a');
    native.voiceArrives(toA, 't-c', '$kForwardStreamPrefix$_c');
    await settle();
    await Future<void>.delayed(const Duration(seconds: 4));
    native.volumes.clear();
    await svc.setDeafened(true);
    await svc.setDeafened(false);
    final cAfter = native.volumes.where((v) => v.$1 == 't-c').toList();
    expect(cAfter.last, ('t-c', 1.0),
        reason: "C's own voice stayed at 0 after the listener un-deafened: "
            "A's claimed forward put C's track id on the silent list");
  });

  test('un-deafen restores every member', () async {
    gossipForwardingEnabled = false;
    svc = await join(_b);
    svc.channelMembers = () => {_a, _c};
    final toA = await leg(_a);
    final toC = await leg(_c);
    native.voiceArrives(toC, 't-c', 's-c');
    native.voiceArrives(toA, 't-a', 's-a');
    await settle();
    native.volumes.clear();
    await svc.setDeafened(true);
    await svc.setDeafened(false);
    expect(native.volumes.where((v) => v.$1 == 't-c').last, ('t-c', 1.0));
  });

  /// B hears A and C on live legs and asks both for D, whom it hears on none.
  Future<(String, String)> askForD() async {
    svc = await join(_b);
    svc.channelMembers = () => {_a, _c, _d};
    final toA = await leg(_a);
    final toC = await leg(_c);
    native.voiceArrives(toA, 't-a', 's-a');
    native.voiceArrives(toC, 't-c', 's-c');
    svc.gossipNeighbors = {_a, _c};
    svc.gossipMode = true;
    await settle();
    expect(sent('fwd_want', _a), isNotEmpty, reason: 'B never asked A for D');
    return (toA, toC);
  }

  test('with forwarding on a forward that leg was never asked for is its own voice',
      () async {
    svc = await join(_b);
    svc.channelMembers = () => {_a};
    final toA = await leg(_a);
    native.voiceArrives(toA, 't-mic-of-a', '${kForwardStreamPrefix}NoSuchMember1');
    await settle();
    native.volumes.clear();
    await svc.setRemoteVolume(_a, 0.0);
    expect(native.volumes, contains(('t-mic-of-a', 0.0)),
        reason: 'a forward of a voice nobody asked A for escaped the volume');
  });

  test('with forwarding on an asked forward is taken as one', () async {
    final (toA, _) = await askForD();
    native.voiceArrives(toA, 't-d', '$kForwardStreamPrefix$_d');
    await settle();
    native.volumes.clear();
    await svc.setRemoteVolume(_a, 0.0);
    expect(native.volumes, contains(('t-a', 0.0)));
    expect(native.volumes, isNot(contains(('t-d', 0.0))),
        reason: "D's forwarded voice took A's volume");
  });

  test('with forwarding on a forward of a member we hear on our own leg is its own voice',
      () async {
    final (toA, _) = await askForD();
    final toD = await leg(_d);
    native.voiceArrives(toD, 't-d', 's-d');
    native.received[toA]!.clear();
    native.voiceArrives(toA, 't-x', '$kForwardStreamPrefix$_d');
    await pumpEventQueue();
    native.volumes.clear();
    await svc.setRemoteVolume(_a, 0.0);
    expect(native.volumes, contains(('t-x', 0.0)),
        reason: 'a forward of a member heard on its own leg escaped the '
            "forwarder's volume");
  });

  test("with forwarding on a copy kept silent never silences another leg's voice",
      () async {
    final (toA, toC) = await askForD();
    native.voiceArrives(toA, 't-d', '$kForwardStreamPrefix$_d');
    await settle();
    // C's copy of D reuses A's microphone id; A's copy came first, so C's
    // stays silent.
    native.voiceArrives(toC, 't-a', '$kForwardStreamPrefix$_d');
    await settle();
    await Future<void>.delayed(const Duration(seconds: 4));
    native.volumes.clear();
    await svc.setDeafened(true);
    await svc.setDeafened(false);
    expect(native.volumes, contains(('t-a', 1.0)),
        reason: "A's own voice stayed at 0: C's silent copy was keyed by a "
            'track id that A also carries');
  });
  test('a forward whose SFrame cryptor never bound is taken back off its leg',
      () async {
    svc = await join(_b);
    final toA = await leg(_a);
    final toC = await leg(_c);
    native.voiceArrives(toC, 't-$_c', 's-$_c');
    native.voiceArrives(toA, 't-$_a', 's-$_a');
    await settle();
    cryptors.failSenders = true;
    await want(_a, {_c});
    await settle();
    expect(native.calls, contains('removeTrack:$toA'),
        reason: 'a forward stayed on its leg with no cryptor');
    expect(sent('reneg_offer', _a), isEmpty,
        reason: 'a renegotiation would carry the voice in clear');
  });
  test('turning forwarding off stops taking forwards it asked for', () async {
    final (toA, _) = await askForD();
    gossipForwardingEnabled = false;
    native.received[toA]!.clear();
    native.voiceArrives(toA, 't-x', '$kForwardStreamPrefix$_d');
    await pumpEventQueue();
    native.volumes.clear();
    await svc.setRemoteVolume(_a, 0.0);
    expect(native.volumes, contains(('t-x', 0.0)),
        reason: 'a forward taken with forwarding off escaped the volume');
  });

  test("with forwarding off an SDP's forward marks never shield a member's voice",
      () async {
    gossipForwardingEnabled = false;
    svc = await join(_b);
    svc.channelMembers = () => {_a};
    final toA = await leg(_a);
    final sdp = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
        'a=msid:${kForwardStreamPrefix}NoSuchMember1 t-mic-of-a\r\n';
    await svc
        .handleSignal(_a, 'reneg_offer', jsonEncode({'sdp': sdp}), 'srv', 'vc')
        .catchError((_) {});
    await settle();
    native.voiceArrives(toA, 't-mic-of-a', 's-a');
    await settle();
    native.volumes.clear();
    await svc.setRemoteVolume(_a, 0.0);
    expect(native.volumes, contains(('t-mic-of-a', 0.0)),
        reason: "A's SDP named its own voice a forward and it escaped the "
            'volume');
  });

  // HOL-SEC-190: volume is keyed by (connection, receiver), never a track id.
  group('receiver-keyed volume', () {
    setUp(() => gossipForwardingEnabled = false);

    test('a member volume names that leg and its receiver, never a track id',
        () async {
      svc = await join(_b);
      svc.channelMembers = () => {_a};
      final toA = await leg(_a);
      native.voiceArrives(toA, 'mic-track', 's-a');
      await settle();
      native.volumeCalls.clear();
      await svc.setRemoteVolume(_a, 0.0);
      expect(native.volumeCalls, [(toA, 'r-mic-track', 0.0)],
          reason: "A's voice was named by its track id, which A chose: here "
              'it is our own microphone id');
    });

    test('a member volume covers every voice on that leg', () async {
      svc = await join(_b);
      svc.channelMembers = () => {_a};
      final toA = await leg(_a);
      native.voiceArrives(toA, 't-a1', 's-a');
      native.voiceArrives(toA, 't-a2', 's-a2');
      await settle();
      native.volumes.clear();
      await svc.setRemoteVolume(_a, 0.0);
      expect(native.volumes, containsAll([('t-a1', 0.0), ('t-a2', 0.0)]),
          reason: "A's second audio section escaped A's volume");
    });

    test('deafen reaches every leg even when two legs carry the same track id',
        () async {
      svc = await join(_b);
      svc.channelMembers = () => {_a, _c};
      final toA = await leg(_a);
      final toC = await leg(_c);
      native.voiceArrives(toA, 't-same', 's-a');
      native.voiceArrives(toA, 't-a2', 's-a2');
      native.voiceArrives(toC, 't-same', 's-c');
      await settle();
      native.volumeCalls.clear();
      await svc.setDeafened(true);
      expect(
          native.volumeCalls,
          containsAll([
            (toA, 'r-t-same', 0.0),
            (toA, 'r-t-a2', 0.0),
            (toC, 'r-t-same', 0.0),
          ]),
          reason: 'a voice kept playing after deafen');
      expect(native.volumeCalls.every((c) => c.$2 != null), isTrue,
          reason: 'a volume call named no receiver');
    });

    test('a voice that arrives while deafened starts silent', () async {
      svc = await join(_b);
      svc.channelMembers = () => {_a};
      final toA = await leg(_a);
      native.voiceArrives(toA, 't-a', 's-a');
      await settle();
      await svc.setDeafened(true);
      native.volumes.clear();
      native.voiceArrives(toA, 't-a-new', 's-a-new');
      await settle();
      expect(native.volumes, contains(('t-a-new', 0.0)),
          reason: 'a new audio section from A played through deafen');
    });

    test('a voice that arrives after a member was turned down takes that volume',
        () async {
      svc = await join(_b);
      svc.channelMembers = () => {_a};
      final toA = await leg(_a);
      native.voiceArrives(toA, 't-a', 's-a');
      await settle();
      await svc.setRemoteVolume(_a, 0.25);
      native.volumes.clear();
      native.voiceArrives(toA, 't-a-new', 's-a-new');
      await settle();
      expect(native.volumes, contains(('t-a-new', 0.25)),
          reason: "A's new audio section played at full volume");
    });

    test('moving a member slider while deafened keeps them silent', () async {
      svc = await join(_b);
      svc.channelMembers = () => {_a};
      final toA = await leg(_a);
      native.voiceArrives(toA, 't-a', 's-a');
      await settle();
      await svc.setDeafened(true);
      native.volumes.clear();
      await svc.setRemoteVolume(_a, 0.5);
      expect(native.volumes.where((v) => v.$2 != 0.0), isEmpty,
          reason: 'the slider undid deafen for that member');
      await svc.setDeafened(false);
      expect(native.volumes.last, ('t-a', 0.5),
          reason: 'un-deafen forgot the volume chosen while deafened');
    });
  });
}
