import 'dart:async';
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
    final redirectStarts = <Map<dynamic, dynamic>>[];
    // setVolume and voiceRedirectStop in the order native receives them.
    final order = <String>[];
    // Holds the next voiceRedirectStart in native until completed.
    Completer<void>? gate;
    var redirectPid = 4242;
    MockStreamHandlerEventSink? sink;

    setUp(() {
      volumeCalls.clear();
      redirectStarts.clear();
      order.clear();
      gate = null;
      redirectPid = 4242;
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
            order.add('setVolume:${args['receiverId']}:${args['volume']}');
            return null;
          case 'voiceRedirectStart':
            redirectStarts.add(args);
            final held = gate;
            gate = null;
            if (held != null) await held.future;
            return {'pid': redirectPid};
          case 'voiceRedirectStop':
            order.add('voiceRedirectStop');
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
    List<(String?, String?, double)> redirected(Map<dynamic, dynamic> args) => [
          for (final r in (args['receivers'] as List? ?? const []))
            (
              (r as Map)['peerConnectionId'] as String?,
              r['receiverId'] as String?,
              (r['volume'] as num).toDouble(),
            ),
        ];

    test('the share redirect names the connection and every audio receiver '
        'at the call volume', () async {
      final svc = await call();
      await svc.setRemoteAudioVolume(0.0);
      expect(await svc.startVoiceRedirect(), 4242);
      expect(redirectStarts, hasLength(1));
      expect(redirectStarts.single.containsKey('trackIds'), isFalse,
          reason: 'the redirect named a voice by the track id its sender chose');
      expect(
          redirected(redirectStarts.single),
          [
            ('pc0', 'r-mic-track', 0.0),
            ('pc0', 'r-far-second-voice', 0.0),
          ],
          reason: 'a redirected voice played at full volume through deafen');
      await svc.endCall();
    });

    test('after the share the call plays at the volume it was turned to',
        () async {
      final svc = await call();
      await svc.setRemoteAudioVolume(0.0);
      await svc.startVoiceRedirect();
      order.clear();
      await svc.stopVoiceRedirect();
      expect(order.first, 'voiceRedirectStop');
      expect(
          order.skip(1),
          containsAll([
            'setVolume:r-mic-track:0.0',
            'setVolume:r-far-second-voice:0.0',
          ]),
          reason: 'the voice came back at full volume after the share while '
              'the call was turned down');
      await svc.endCall();
    });

    test('a voice that arrives during the share joins the redirect', () async {
      final svc = await call();
      await svc.setRemoteAudioVolume(0.5);
      await svc.startVoiceRedirect();
      redirectStarts.clear();
      receivers.add(_receiver('t-new', 'audio'));
      voiceArrives('t-new');
      await pumpEventQueue();
      expect(redirectStarts.expand(redirected), [('pc0', 'r-t-new', 0.5)],
          reason: 'a new voice played from hollow.exe into the shared screen');
      await svc.endCall();
    });

    List<String?> namedReceivers() => [
          for (final a in redirectStarts)
            for (final r in redirected(a)) r.$2,
        ];

    test('a voice that arrives while the redirect arms joins it', () async {
      final svc = await call();
      await svc.setRemoteAudioVolume(0.5);
      final held = gate = Completer<void>();
      final arming = svc.startVoiceRedirect();
      await pumpEventQueue();
      // Native is still spawning the child when the far side's voice lands.
      receivers.add(_receiver('t-mid', 'audio'));
      voiceArrives('t-mid');
      await pumpEventQueue();
      held.complete();
      expect(await arming, 4242);
      await pumpEventQueue();
      expect(redirectStarts.expand(redirected), contains(('pc0', 'r-t-mid', 0.5)),
          reason: 'a voice that arrived while the redirect armed plays from '
              'hollow.exe into the shared screen for the whole share');
      expect(namedReceivers().where((r) => r == 'r-mic-track'), hasLength(1),
          reason: 'a voice already named was attached twice');
      await svc.endCall();
    });

    test('a voice named in the arm is not sent again when its track event '
        'lands during the arm', () async {
      final svc = await call();
      receivers.add(_receiver('t-early', 'audio'));
      final held = gate = Completer<void>();
      final arming = svc.startVoiceRedirect();
      await pumpEventQueue();
      voiceArrives('t-early');
      await pumpEventQueue();
      held.complete();
      await arming;
      await pumpEventQueue();
      expect(namedReceivers().where((r) => r == 'r-t-early'), hasLength(1),
          reason: 'native re-attached a voice the arm already named');
      await svc.endCall();
    });

    test('a call that ends while the redirect arms redirects nothing after it',
        () async {
      final svc = await call();
      final held = gate = Completer<void>();
      final arming = svc.startVoiceRedirect();
      await pumpEventQueue();
      await svc.endCall();
      held.complete();
      await arming;
      await svc.createOffer('peer', 'call-2');
      await pumpEventQueue();
      redirectStarts.clear();
      voiceArrives('t-next');
      await pumpEventQueue();
      expect(redirectStarts, isEmpty,
          reason: 'the ended call\'s redirect took the next call\'s voice');
      await svc.endCall();
    });

    test('an arm that does not start leaves no voice redirected', () async {
      final svc = await call();
      await svc.setRemoteAudioVolume(0.5);
      redirectPid = 0;
      expect(await svc.startVoiceRedirect(), 0);
      expect(order, contains('voiceRedirectStop'),
          reason: 'native may hold voices silent from a lost child; the '
              'share falls back to excluding hollow.exe and never stops it');
      expect(order, contains('setVolume:r-mic-track:0.5'));
      redirectStarts.clear();
      voiceArrives('t-late');
      await pumpEventQueue();
      expect(redirectStarts, isEmpty);
      await svc.endCall();
    });

    test('no redirect outlives its call', () async {
      final svc = await call();
      await svc.startVoiceRedirect();
      await svc.endCall();
      await svc.createOffer('peer', 'call-2');
      await pumpEventQueue();
      redirectStarts.clear();
      voiceArrives('t-next');
      await pumpEventQueue();
      expect(redirectStarts, isEmpty);
      await svc.endCall();
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
    test('voice_redirect_resolves_only_named_receivers', () {
      // HOL-SEC-191: the Windows entire-screen share redirects received
      // voices to a child process. A track id is whatever the sender wrote,
      // so a redirect by it could take our own microphone or skip a member.
      final offenders = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final text = _source(f.path);
        if (text.contains('RemoteAudioTrackIds')) offenders.add(f.path);
      }
      expect(offenders, isEmpty,
          reason: 'a redirected voice is named by its connection and '
              'receiver, never by the track id its sender chose');

      // Typed by receiver, so a caller holding track ids does not compile.
      final management = _source('$_fork/lib/src/native/audio_management.dart');
      final signature = management.substring(
          management.indexOf('static Future<int> voiceRedirectStart('));
      expect(signature.substring(0, signature.indexOf(' async')),
          contains('RTCRtpReceiver'));
      final dart = management.substring(
          management.indexOf('static Future<int> voiceRedirectStart('),
          management.indexOf('static Future<void> voiceRedirectStop('));
      expect(dart, isNot(contains('trackId')));
      expect(dart, contains("'peerConnectionId'"));
      expect(dart, contains("'receiverId'"));

      final cc = _source('$_fork/common/cpp/src/flutter_voice_redirect.cc');
      _expectNoLookup(cc, [
        'MediaTrackForId',
        'MediaTracksForId',
        'local_tracks_',
        'PeerConnectionObserversForId',
        'remote_streams',
        'track->id()',
      ]);
      final start = _body(cc, 'bool FlutterVoiceRedirect::Start(');
      expect(start, contains('PeerConnectionForId('));
      expect(start, contains('receiver->id()'));

      final webrtc = _source('$_fork/common/cpp/src/flutter_webrtc.cc');
      final dispatch = _arm(webrtc,
          'method_call.method_name().compare("voiceRedirectStart")',
          'method_call.method_name().compare(');
      expect(dispatch, isNot(contains('trackIds')));
      expect(dispatch, contains('"receivers"'));
    });

    test('a render child lost mid-share is never replaced or restarted over',
        () {
      // The capturer excludes only the child pid the share armed with: a new
      // child's voices would be captured. A writer that stopped on a failed
      // write leaves a joinable thread, and assigning over it terminates.
      final cc = _source('$_fork/common/cpp/src/flutter_voice_redirect.cc');
      final lost = _body(cc, 'bool FlutterVoiceRedirect::ChildLost(');
      expect(lost, contains('WaitForSingleObject(child_process_, 0) == WAIT_OBJECT_0'));
      expect(lost, contains('!writer_running_.load()'));
      final start = _body(cc, 'bool FlutterVoiceRedirect::Start(');
      expect(start.indexOf('ChildLost()'), allOf(isNot(-1),
          lessThan(start.indexOf('SpawnChild()'))));
      expect(start, matches(RegExp(
          r'if \(!lost\) \{\s*if \(!SpawnChild\(\)\) return false;\s*StartWriter\(\);')),
          reason: 'a dead child was respawned under a pid the capturer does '
              'not exclude');
      expect(start, contains('return !lost;'));
      expect(start, matches(RegExp(r'if \(entries_\.empty\(\) && fresh\) \{\s*(//[^\n]*\s*)*Stop\(base\);')),
          reason: 'a mid-share Start that ends with no voices stopped the '
              'child, so the next voice spawns one the capturer cannot see');
      final writer = _body(cc, 'void FlutterVoiceRedirect::StartWriter(');
      final join = writer.indexOf('writer_thread_.join()');
      expect(join, allOf(isNot(-1),
          lessThan(writer.indexOf('writer_thread_ = std::thread('))));
      expect('writer_thread_ = std::thread('.allMatches(cc), hasLength(1),
          reason: 'the writer thread is assigned outside StartWriter');
      final spawn = _body(cc, 'bool FlutterVoiceRedirect::SpawnChild(');
      expect(spawn, isNot(contains('already up')));
    });

    test('one connection cannot take every redirect slot', () {
      final cc = _source('$_fork/common/cpp/src/flutter_voice_redirect.cc');
      final start = _body(cc, 'bool FlutterVoiceRedirect::Start(');
      expect(start, contains('DropClosedConnections(base);'));
      final drop = _body(cc, 'void FlutterVoiceRedirect::DropClosedConnections(');
      expect(drop, matches(RegExp(r'PeerConnectionForId\(e\.pc_id\)\s*!=\s*nullptr')));
      expect(start, contains('TapsOn(t.pc_id) < kMaxVoicesPerConnection'),
          reason: 'one peer filled the 256 stream ids and starved everyone');
      // A voice over a cap is kept silent in hollow.exe, never left playing
      // into the shared screen.
      expect(start, isNot(contains('break;')));
      expect(start, matches(RegExp(
          r'if \(tapped\) track->AddSink\(sink\.get\(\)\);\s*track->SetVolume\(0\.0\);')));
      final detach = _body(cc, 'void FlutterVoiceRedirect::Detach(');
      expect(detach, contains('if (tapped) track->RemoveSink(sink.get());'));
      final taps = _body(cc, 'size_t FlutterVoiceRedirect::TapsOn(');
      expect(taps, contains('e.tapped'));
      final free = _body(cc, 'int FlutterVoiceRedirect::FreeStreamId(');
      expect(free, contains('e.tapped'));
    });

    test('a redirected voice keeps the volume the listener chose', () {
      final cc = _source('$_fork/common/cpp/src/flutter_voice_redirect.cc');
      // The sink taps PCM before the track volume, so the redirect applies
      // the wanted volume itself and drops a silenced voice.
      final sink = _body(cc, 'void OnData(');
      expect(sink, contains('gain <= 0.0f) return;'));
      expect(sink, contains('* gain'));
      // While redirected, hollow.exe's own playout of the voice stays silent.
      final start = _body(cc, 'bool FlutterVoiceRedirect::Start(');
      expect(start, contains('track->SetVolume(0.0)'));
      // Stop gives each voice back at its wanted volume, never full volume.
      expect(cc, isNot(contains('SetVolume(1')));
      final stop = _body(cc, 'void FlutterVoiceRedirect::Stop(');
      expect(stop, contains('/*restore=*/true'));
      final detach = _body(cc, 'void FlutterVoiceRedirect::Detach(');
      expect(detach, contains('SetVolume(wanted)'));
      expect(detach, contains('Gain()'));
      // A volume set during the share reaches the redirect, never hollow.exe's
      // own playout of a redirected voice.
      final webrtc = _source('$_fork/common/cpp/src/flutter_webrtc.cc');
      final set = _body(webrtc, 'bool FlutterWebRTC::ReceiverSetVolume(');
      expect(
          set,
          matches(RegExp(r'SetWantedVolume\([^;]*\)\)\s*\{\s*'
              r'redirected\.push_back\([^;]*;\s*continue;')),
          reason: 'a volume change during the share also reached the '
              'in-process playout of a redirected voice');
      expect(set,
          contains('for (const auto& track : redirected) track->SetVolume(0.0);'));
    });
  });
}
