import 'dart:io';

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

Map<String, dynamic> _receiver(String track, String kind) => {
      'receiverId': 'r-$track',
      'track': _track(track, kind),
      'rtpParameters': _params(),
    };

String _source(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

/// The body of the first function whose header contains [signature]: from
/// its opening brace to the matching close.
String _body(String source, String signature) {
  final at = source.indexOf(signature);
  expect(at, isNot(-1), reason: '$signature is gone; update this guard');
  final open = source.indexOf('{', at);
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) return source.substring(open, i + 1);
  }
  fail('$signature has no closing brace');
}

/// One dispatch arm: from [start] up to the next method name check ([next]).
String _arm(String source, String start, String next) {
  final at = source.indexOf(start);
  expect(at, isNot(-1), reason: '$start is gone; update this guard');
  final end = source.indexOf(next, at + start.length);
  return source.substring(at, end == -1 ? source.length : end);
}

void _expectNoLookup(String code, List<String> banned) {
  for (final b in banned) {
    expect(code, isNot(contains(b)), reason: 'the volume path reaches $b');
  }
}

const _fork = 'packages/flutter_webrtc';

/// HOL-SEC-190: the volume of a received voice is keyed by its connection
/// and receiver. A track id is whatever the sending peer wrote, so a lookup
/// by it could reach our own microphone or another member's voice.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => RustLib.initMock(api: _Api()));

  group('1:1 call', () {
    const webrtc = MethodChannel('FlutterWebRTC.Method');
    const events = EventChannel('FlutterWebRTC/peerConnectionEventpc0');
    final volumeCalls = <(String?, String?, double)>[];
    final receivers = <Map<String, dynamic>>[];
    MockStreamHandlerEventSink? sink;

    setUp(() {
      volumeCalls.clear();
      receivers
        ..clear()
        ..addAll([
          _receiver('mic-track', 'audio'),
          _receiver('far-camera', 'video'),
          _receiver('far-second-voice', 'audio'),
        ]);
      debugOverlayMic = overlayMicOn(FakeMic([]));
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockStreamHandler(events,
          MockStreamHandler.inline(onListen: (_, s) => sink = s));
      messenger.setMockMethodCallHandler(webrtc, (call) async {
        final args = (call.arguments as Map?) ?? const {};
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
            return {
              'sdp': 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n',
              'type': 'offer'
            };
          case 'getReceivers':
            return {'receivers': receivers};
          case 'setVolume':
            volumeCalls.add((
              args['peerConnectionId'] as String?,
              args['receiverId'] as String?,
              (args['volume'] as num).toDouble(),
            ));
            return null;
        }
        return null;
      });
    });

    tearDown(() {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(webrtc, null);
      messenger.setMockStreamHandler(events, null);
    });

    Future<VoiceService> call() async {
      final svc = VoiceService(localPeerId: 'me', iceServers: const {})
        ..isCallLive = () => true;
      await svc.createOffer('peer', 'call');
      await pumpEventQueue();
      return svc;
    }

    test('the call volume names the connection and every audio receiver',
        () async {
      final svc = await call();
      await svc.setRemoteAudioVolume(0.0);
      expect(
          volumeCalls,
          [
            ('pc0', 'r-mic-track', 0.0),
            ('pc0', 'r-far-second-voice', 0.0),
          ],
          reason: 'the far side named its voice with our microphone id, or '
              'its second audio section escaped the volume');
      await svc.endCall();
    });

    void voiceArrives(String track) => sink!.success({
          'event': 'onTrack',
          'streams': [
            {
              'streamId': 's-$track',
              'ownerTag': 'pc0',
              'audioTracks': [_track(track, 'audio')],
              'videoTracks': [],
            }
          ],
          'receiver': _receiver(track, 'audio'),
          'track': _track(track, 'audio'),
          'transceiver': null,
        });

    test('a voice that arrives after the call was turned down takes that volume',
        () async {
      final svc = await call();
      await svc.setRemoteAudioVolume(0.0);
      volumeCalls.clear();
      voiceArrives('t-new');
      await pumpEventQueue();
      expect(volumeCalls, contains(('pc0', 'r-t-new', 0.0)),
          reason: 'a new audio section played through deafen');
      await svc.endCall();
    });

    test('the next call starts at full volume', () async {
      final first = await call();
      await first.setRemoteAudioVolume(0.0);
      await first.endCall();
      await first.createOffer('peer', 'call-2');
      await pumpEventQueue();
      volumeCalls.clear();
      voiceArrives('t-next');
      await pumpEventQueue();
      expect(volumeCalls, isEmpty,
          reason: 'the last call\'s deafen carried into the next call');
      await first.endCall();
    });
  });

  group('guard', () {
    test('no app code sets a volume by track', () {
      final offenders = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        if (f.path.contains('${Platform.pathSeparator}rust${Platform.pathSeparator}')) {
          continue;
        }
        final text = _source(f.path);
        for (final banned in [
          'Helper.setVolume(',
          'NativeAudioManagement.setVolume(',
          'setRemoteTrackVolume(',
        ]) {
          if (text.contains(banned)) offenders.add('${f.path}: $banned');
        }
      }
      expect(offenders, isEmpty,
          reason: 'a received voice is named by its connection and receiver '
              '(setRemoteReceiverVolume), never by the track id its sender '
              'chose');
    });

    test('Android resolves a volume only among the named connection receivers',
        () {
      final src = _source('$_fork/android/src/main/java/com/cloudwebrtc/webrtc/'
          'MethodCallHandlerImpl.java');
      final body = _body(src, 'boolean receiverSetVolume(');
      for (final banned in [
        'getTrackForId',
        'localTracks',
        'mPeerConnectionObservers.entrySet',
        'mPeerConnectionObservers.values',
        'remoteTracks',
      ]) {
        expect(body, isNot(contains(banned)),
            reason: 'the volume lookup reaches $banned');
      }
      expect(body, contains('mPeerConnectionObservers.get(peerConnectionId)'));
      final dispatch = _body(src, 'case "setVolume":');
      expect(dispatch, contains('receiverSetVolume('));
      _expectNoLookup(dispatch, ['getTrackForId', 'localTracks', 'remoteTracks']);
      // The match runs over the transceivers onTrack handed over: a list from
      // getReceivers()/getTransceivers() is disposed by the next such call,
      // before the queued volume set runs.
      final pco = _body(
          _source('$_fork/android/src/main/java/com/cloudwebrtc/webrtc/'
              'PeerConnectionObserver.java'),
          'List<AudioTrack> receivedAudioTracks(');
      for (final banned in [
        'remoteTracks',
        'localTracks',
        'getReceivers()',
        'getTransceivers()',
      ]) {
        expect(pco, isNot(contains(banned)),
            reason: 'the volume lookup reaches $banned');
      }
      expect(pco, contains('receivingTransceivers'));
    });

    test('Apple resolves a volume only among the named connection receivers',
        () {
      final src = _source('$_fork/common/darwin/Classes/FlutterWebRTCPlugin.m');
      final body = _body(src, '- (BOOL)receiverSetVolume:');
      for (final banned in [
        'trackForId',
        '_localTracks',
        '_peerConnections.allKeys',
        'remoteTracks',
      ]) {
        expect(body, isNot(contains(banned)),
            reason: 'the volume lookup reaches $banned');
      }
      expect(body, contains('_peerConnections[peerConnectionId]'));
      final dispatch = _arm(src, '[@"setVolume" isEqualToString:call.method]',
          'isEqualToString:call.method]');
      expect(dispatch, contains('receiverSetVolume:'));
      _expectNoLookup(dispatch, ['trackForId', '_localTracks', 'remoteTracks']);
    });

    test('Windows and Linux resolve a volume only among the named connection '
        'receivers', () {
      final src = _source('$_fork/common/cpp/src/flutter_webrtc.cc');
      final body = _body(src, 'bool FlutterWebRTC::ReceiverSetVolume(');
      for (final banned in [
        'MediaTrackForId',
        'MediaTracksForId',
        'local_tracks_',
        'peerconnection_observers_',
        'PeerConnectionObserversForId',
      ]) {
        expect(body, isNot(contains(banned)),
            reason: 'the volume lookup reaches $banned');
      }
      expect(body, contains('PeerConnectionForId('));
      final dispatch = _arm(src, 'method_call.method_name().compare("setVolume")',
          'method_call.method_name().compare(');
      expect(dispatch, contains('ReceiverSetVolume('));
      _expectNoLookup(dispatch,
          ['MediaTrackForId', 'MediaTracksForId', 'local_tracks_', 'PeerConnectionObserversForId']);
    });
  });
}
