import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/overlay_mic.dart';
import 'package:hollow/src/core/services/voice_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';

import 'helpers/fake_mic.dart';

class _Api implements RustLibApi {
  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _track(String id, String kind) =>
    {'id': id, 'label': id, 'kind': kind, 'enabled': true};

Map<String, dynamic> _params() => {
      'transactionId': '',
      'rtcp': {'cname': '', 'reducedSize': false},
      'headerExtensions': [],
      'encodings': [],
      'codecs': [],
    };

/// A 1:1 call's re-offer narrows every video section to VP8, including one
/// the far side created (its camera, our camera off): our own full codec list
/// on it, H.265 and AV1 among them, is what an iOS answerer fails to apply.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => RustLib.initMock(api: _Api()));

  const webrtc = MethodChannel('FlutterWebRTC.Method');
  final calls = <String>[];
  var stoppedFirst = false;

  Map<String, dynamic> camera(String id) => {
        'transceiverId': id,
        'direction': 'recvonly',
        'mid': '1',
        'sender': {
          'senderId': 'unused-$id',
          'track': {},
          'rtpParameters': _params(),
          'ownsTrack': false,
        },
        'receiver': {
          'receiverId': '$id-receiver',
          'track': _track('$id-track', 'video'),
          'rtpParameters': _params(),
        },
      };

  setUp(() {
    calls.clear();
    stoppedFirst = false;
    debugOverlayMic = overlayMicOn(FakeMic([]));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(webrtc, (call) async {
      final args = (call.arguments as Map?) ?? const {};
      calls.add(call.method);
      switch (call.method) {
        case 'getUserMedia':
          return {
            'streamId': 'mic',
            'audioTracks': [_track('mic-track', 'audio')],
            'videoTracks': [],
          };
        case 'createPeerConnection':
          return {'peerConnectionId': 'pc0'};
        case 'addTrack':
          return {
            'senderId': 'mic-sender',
            'track': _track(args['trackId'] as String, 'audio'),
            'rtpParameters': _params(),
            'ownsTrack': false,
          };
        case 'createOffer':
          return {'sdp': 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n', 'type': 'offer'};
        case 'getTransceivers':
          return {
            'transceivers': [
              if (stoppedFirst) camera('stopped-camera'),
              camera('far-camera'),
            ]
          };
        case 'getRtpSenderCapabilities':
          return {
            'codecs': [
              for (final m in [
                'video/VP8',
                'video/H264',
                'video/AV1',
                'video/H265',
                'video/rtx'
              ])
                {'mimeType': m, 'clockRate': 90000},
            ],
            'headerExtensions': [],
            'fecMechanisms': [],
          };
        case 'setCodecPreferences':
          if (args['transceiverId'] == 'stopped-camera') {
            throw PlatformException(code: 'InvalidState', message: 'stopped');
          }
          calls.add('codecs:${args['transceiverId']}:'
              '${(args['codecs'] as List).map((c) => (c as Map)['mimeType']).join(',')}');
          return null;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(webrtc, null);
  });

  test("a re-offer narrows the far side's camera section to VP8 first",
      () async {
    final svc = VoiceService(localPeerId: 'me', iceServers: const {})
      ..isCallLive = () => true;
    await svc.createOffer('peer', 'call');
    calls.clear();

    expect(await svc.createRenegotiationOffer(), isNotNull);
    final codecsAt = calls.indexOf('codecs:far-camera:video/VP8,video/rtx');
    expect(codecsAt, isNot(-1),
        reason: 'the re-offer kept our H.264, H.265 and AV1 on a video '
            'section the far side created');
    expect(codecsAt, lessThan(calls.lastIndexOf('createOffer')),
        reason: 'the codecs were narrowed after the offer was made');
    await svc.endCall();
  });
  test('a transceiver that cannot be narrowed leaves the rest narrowed',
      () async {
    final svc = VoiceService(localPeerId: 'me', iceServers: const {})
      ..isCallLive = () => true;
    await svc.createOffer('peer', 'call');
    stoppedFirst = true;
    calls.clear();

    expect(await svc.createRenegotiationOffer(), isNotNull);
    expect(calls, contains('codecs:far-camera:video/VP8,video/rtx'),
        reason: 'one stopped transceiver left the live camera section on '
            'every codec');
    await svc.endCall();
  });
}
