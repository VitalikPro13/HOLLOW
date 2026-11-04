import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/frame_cryptor_service.dart';
import 'package:hollow/src/core/services/gossip_forward.dart';
import 'package:hollow/src/core/services/voice_channel_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';

import 'helpers/fake_frame_cryptor.dart';

class _LogApi implements RustLibApi {
  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The body of the method whose declaration starts with [signature].
String _body(String src, String signature) {
  final at = src.indexOf(signature);
  expect(at, greaterThanOrEqualTo(0), reason: 'no $signature');
  final open = src.indexOf('{', src.indexOf(')', at));
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}' && --depth == 0) return src.substring(open, i + 1);
  }
  fail('unbalanced $signature');
}

String _src(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

const _peer = '12D3KooWBob';
const _origin = '12D3KooWCarolCarolCarolCarolCarolCarolCarolCarolCaro';

/// C-MEDIA-08: a 1:1 call's camera and a voice channel's forwarded voices carry
/// an SFrame layer like everything else, whatever the version on the far side.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => RustLib.initMock(api: _LogApi()));

  group('a cryptor follows the sender it protects', () {
    test('nothing is bound before a key, then each new sender gets its own',
        () async {
      final native = FakeFrameCryptorFactory();
      final sframe = FrameCryptorService(factory: native);
      await sframe.init();
      await sframe.rebindSender(_peer, FakeRtpSender('cam1'), kind: 'video');
      expect(native.calls.where((c) => c.contains('setEnabled:true')), isEmpty,
          reason: 'a keyless cryptor drops or leaks frames');

      await sframe.rotateKey(2, Uint8List(32));
      native.calls.clear();
      await sframe.rebindSender(_peer, FakeRtpSender('cam1'), kind: 'video');
      expect(native.calls, ['tx0.setKeyIndex:2', 'tx0.setEnabled:true']);

      native.calls.clear();
      await sframe.rebindSender(_peer, FakeRtpSender('cam1'), kind: 'video');
      expect(native.calls, isEmpty,
          reason: 'the same sender was unbound, leaving frames in clear');

      await sframe.rebindSender(_peer, FakeRtpSender('cam2'), kind: 'video');
      expect(native.calls, [
        'tx0.setEnabled:false',
        'tx0.dispose',
        'tx1.setKeyIndex:2',
        'tx1.setEnabled:true',
      ], reason: 'a camera switch kept the cryptor on the dead sender');
    });

    test('a new inbound transceiver moves the decryptor', () async {
      final native = FakeFrameCryptorFactory();
      final sframe = FrameCryptorService(factory: native);
      await sframe.init();
      await sframe.rotateKey(0, Uint8List(32));
      await sframe.rebindReceiver(_peer, FakeRtpReceiver('r1'), kind: 'video');
      native.calls.clear();
      await sframe.rebindReceiver(_peer, FakeRtpReceiver('r2'), kind: 'video');
      expect(native.calls, [
        'rx0.setEnabled:false',
        'rx0.dispose',
        'rx1.setKeyIndex:0',
        'rx1.setEnabled:true',
      ]);
    });

    test('a leg that closes takes its forwarded voices\' cryptors with it',
        () async {
      final native = FakeFrameCryptorFactory();
      final sframe = FrameCryptorService(factory: native);
      await sframe.init();
      await sframe.rotateKey(0, Uint8List(32));
      await sframe.rebindSender(_peer, FakeRtpSender('f'),
          kind: forwardCryptorKind(_origin));
      await sframe.rebindReceiver(_peer, FakeRtpReceiver('g'),
          kind: forwardCryptorKind(_origin));
      native.calls.clear();
      await sframe.disableForPeer(_peer);
      expect(native.calls, containsAll(['tx0.dispose', 'rx1.dispose']));
    });
  });

  group('a forwarded voice names its origin on the wire', () {
    const sdp = 'v=0\r\n'
        'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
        'a=msid:own-stream own-mic\r\n'
        'a=ssrc:111 msid:own-stream own-mic\r\n'
        'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
        'a=msid:native-stream carol-mic\r\n'
        'a=ssrc:222 msid:native-stream carol-mic\r\n';

    test('only the forwarded track is renamed, and it reads back', () {
      final marked = markForwardedTracks(sdp, {'carol-mic': _origin});
      expect(marked, contains('a=msid:own-stream own-mic\r\n'));
      expect(marked, contains('a=msid:$kForwardStreamPrefix$_origin carol-mic\r\n'));
      expect(marked,
          contains('a=ssrc:222 msid:$kForwardStreamPrefix$_origin carol-mic\r\n'));
      expect(forwardedTracksIn(marked), {'carol-mic': _origin});
      expect(forwardedTracksIn(sdp), isEmpty,
          reason: 'a plain microphone was taken for a forwarded voice');
      expect('$kForwardStreamPrefix$_origin'.length, lessThanOrEqualTo(64));
    });

    test('an origin that is no peer id is never written or believed', () {
      expect(markForwardedTracks(sdp, {'carol-mic': 'a b'}), sdp);
      expect(forwardOriginOfStream('${kForwardStreamPrefix}x/../y'), isNull);
      expect(forwardOriginOfStream('other-stream'), isNull);
    });
  });

  group('a forward is asked for and renegotiated only when needed', () {
    const a = 'a', b = 'b', c = 'c';

    test('a room whose legs are up or settling in asks for nothing', () {
      expect(
          forwardWants(
              gossip: true,
              self: b,
              members: {a, c},
              live: {a},
              settling: {c}),
          isEmpty,
          reason: 'a neighbour still dialling is not a voice to forward');
      expect(
          forwardWants(
              gossip: false, self: a, members: {b, c}, live: {b}, settling: {}),
          isEmpty,
          reason: 'a mesh asks nobody to forward');
      expect(
          forwardWants(
              gossip: true, self: a, members: {b, c}, live: {b}, settling: {}),
          {c},
          reason: 'the end of a chain hears the far end only forwarded');
      expect(
          forwardWants(
              gossip: true, self: a, members: {b, c}, live: {c}, settling: {}),
          {b},
          reason: 'a neighbour whose leg never came up is heard by nobody');
    });

    test('forwarding ships off', () {
      expect(gossipForwardingEnabled, isFalse,
          reason: 'a re-sent remote track aborts libwebrtc on a forwarder '
              'whose microphone runs');
    });

    test('a leg gets only the voices it asked for that we hear straight', () {
      expect(forwardsFor(leg: a, self: b, wanted: {c, a, b, 'd'}, heard: {a, c}),
          {c});
      expect(forwardsFor(leg: a, self: b, wanted: {}, heard: {a, c}), isEmpty);
    });

    test('a burst of forward changes renegotiates each leg once', () async {
      final renegs = <String>[];
      final batch = ForwardRenegBatcher((leg) async => renegs.add(leg),
          delay: const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(renegs, isEmpty, reason: 'nothing changed, nothing renegotiated');
      batch
        ..touch(a)
        ..touch(a)
        ..touch(c)
        ..touch(a);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(renegs..sort(), [a, c]);
      batch.touch(c);
      batch.cancel(c);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(renegs, [a, c], reason: 'a closed leg was renegotiated');
    });

    test('the service asks only on a change and renegotiates through the batch',
        () {
      final src = _src('lib/src/core/services/voice_channel_service.dart');
      final wants = _body(src, 'void _sendWants(');
      expect(wants, contains('forwardWants('));
      final unchanged = RegExp(r'if \(_setEquals\(_wantSent\[leg\][^,]*, want\)\) continue;')
          .firstMatch(wants);
      expect(unchanged, isNotNull, reason: 'an unchanged want is sent again');
      expect(unchanged!.start, lessThan(wants.indexOf('voiceChannelSendSignal(')),
          reason: 'an unchanged want is sent again');
      expect(_body(src, 'Future<void> _renegotiateForwards('),
          contains('_sendRenegotiationOffer(peerId, iceRestart: true)'),
          reason: 'a forward renegotiation ran the far camera net');
      expect(RegExp(r"case 'fwd_want':\s*_onForwardWant\(").hasMatch(src), isTrue);
    });
  });

  test('every camera sender and receiver of a 1:1 call is bound', () {
    final src = _src('lib/src/core/services/voice_service.dart');
    for (final signature in [
      'Future<void> _addLocalVideoTracks(',
      'Future<bool> _enableVideoDesktop(',
      'Future<bool> _toggleVideoLinux(',
      'Future<bool> _swapVideoSender(',
      'Future<void> setSframeKey(',
    ]) {
      expect(_body(src, signature), contains('_bindSframeVideoSender('),
          reason: '$signature sends the camera without SFrame');
    }
    for (final signature in [
      'void _onRemoteTrack(',
      'Future<void> setSframeKey(',
      'Future<bool> _adoptOrphanRemoteVideoReceiver(',
      'Future<void> rebindSframeReceivers(',
    ]) {
      expect(_body(src, signature), contains('_bindSframeVideoReceiver('),
          reason: '$signature leaves the camera undecrypted');
    }
    expect(_body(src, 'Future<void> healSframeAfterTransportRebuild('),
        contains("kind: 'video'"));
    expect(_body(src, 'Future<void> _disableVideoDesktop('),
        contains("disableSender(peerId, kind: 'video')"));
  });

  test('a voice is forwarded only under SFrame and read back as forwarded', () {
    final src = _src('lib/src/core/services/voice_channel_service.dart');
    final forward = _body(src, 'Future<void> _syncForwards(');
    expect(forward, contains('&& fc != null && fc.isEnabled;'),
        reason: 'a keyless forward leaves in clear');
    expect(forward.indexOf('rebindSender('),
        greaterThan(forward.indexOf('addTrack(')));
    expect(forward.indexOf('_fwdReneg.touch('),
        greaterThan(forward.indexOf('rebindSender(')),
        reason: 'a renegotiation could carry a forward before its cryptor');
    expect(_body(src, 'void _forwardGossipAudio('), isNot(contains('addTrack(')));
    final onTrack = _body(src, 'void _onPeerTrack(');
    final forwardedFirst = RegExp(
        r'if \(fwdOrigin != null && _acceptsForward\(peerId, fwdOrigin\)\) \{\s*unawaited\(_receiveForwarded\([^;]*\);\s*return;\s*\}');
    final branch = forwardedFirst.firstMatch(onTrack);
    expect(branch, isNotNull,
        reason: 'a forwarded voice falls through to the mic path');
    expect(branch!.start, lessThan(onTrack.indexOf('_rebindSframeReceiver(')),
        reason: 'a forwarded voice would take the forwarder\'s mic decryptor');
    expect("'sdp': _forPeer(".allMatches(src).length, 4,
        reason: 'an SDP leaves without its forwarded tracks marked');
    expect(
        RegExp(r'_fwdIn\[peerId\] = _forwardsIn\(peerId, sdp\);\n\s*await pc\.setRemoteDescription')
            .allMatches(src)
            .length,
        4,
        reason: 'a remote SDP is applied before its forwarded tracks are known');
  });
  test('a voice channel stays a full mesh while everyone fits the leg cap', () {
    // Gossip forwards nothing yet, so the node's switch point is the most
    // people a mesh of maxVoicePcs legs holds, plus one.
    final rust = _src('rust/hollow_core/src/node/gossip.rs');
    int constant(String name) => int.parse(
        RegExp('pub const $name: usize = (\\d+);').firstMatch(rust)!.group(1)!);
    expect(constant('VOICE_GOSSIP_THRESHOLD_UP'),
        VoiceChannelService.maxVoicePcs + 2);
    expect(constant('VOICE_GOSSIP_THRESHOLD_DOWN'),
        constant('VOICE_GOSSIP_THRESHOLD_UP'),
        reason: 'a channel that fits a mesh again would stay partly deaf');
    expect(gossipForwardingEnabled, isFalse);
  });
}
