import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/services/local_meter_loopback.dart';
import 'package:hollow/src/core/services/overlay_mic.dart';
import 'package:hollow/src/core/services/voice_channel_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';

import 'helpers/fake_mic.dart';

/// Muted = mic off (Vitalik, 2026-10-15): alone in a voice room, the meter
/// loopback is the only thing that keeps our capture recording, so it runs
/// only while we are unmuted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => RustLib.initMock(api: _Api()));

  const webrtc = MethodChannel('FlutterWebRTC.Method');
  late List<String> calls;
  late List<bool> trackEnabled;
  late VoiceChannelService svc;

  setUp(() {
    calls = [];
    trackEnabled = [];
    debugOverlayMic = overlayMicOn(FakeMic([]));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(webrtc, (call) async {
      switch (call.method) {
        case 'getUserMedia':
          return {
            'streamId': 'mic',
            'audioTracks': [
              {'id': 'a1', 'label': 'mic', 'kind': 'audio', 'enabled': true},
            ],
            'videoTracks': [],
          };
        case 'mediaStreamTrackSetEnable':
          trackEnabled.add((call.arguments as Map)['enabled'] as bool);
          return null;
        case 'frameCryptorFactoryCreateKeyProvider':
          return {'keyProviderId': 'kp'};
        case 'getCaptureLevel':
          return {'levelDb': -100.0};
      }
      return null;
    });
    svc = VoiceChannelService(
      localPeerId: 'me',
      iceServers: const {},
      aloneMeter: AloneMeterKeeper<MediaStream, Object>(
        start: (stream) async {
          calls.add('start');
          return Object();
        },
        stop: (_) async => calls.add('stop'),
      ),
    );
  });
  tearDown(() async {
    await svc.closeAll();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(webrtc, null);
  });

  test('alone and unmuted the loopback runs; muting stops it, unmuting '
      'while still alone starts it again', () async {
    await svc.startAudio('srv', 'vc');
    await pumpEventQueue();
    expect(calls, ['start']);

    svc.setMuted(true);
    await pumpEventQueue();
    expect(calls, ['start', 'stop']);

    svc.setMuted(false);
    await pumpEventQueue();
    expect(calls, ['start', 'stop', 'start']);
  });

  test('a join muted before the mic opens never records alone', () async {
    svc.setMuted(true);
    await svc.startAudio('srv', 'vc');
    await pumpEventQueue();
    expect(calls, isEmpty);
    expect(trackEnabled, contains(false),
        reason: 'the track opened live behind a muted button');
  });

  test('a join applies the transmit gate before the mic opens', () {
    // Push-to-talk starts gated: the service must know before startAudio, or
    // the loopback records alone until the gate lands.
    final src = File('lib/src/core/providers/voice_channel_provider.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final start = src.indexOf('await svc.startAudio(serverId, channelId);');
    expect(start, isNonNegative);
    final before = src.substring(0, start).trimRight();
    expect(before.endsWith('_applyTxGate();'), isTrue,
        reason: 'the join opens the mic before the service knows the gate');
  });

  test('a failed overlay handover still opens the call mic', () async {
    final mic = FakeMic([]);
    final listen = overlayMicOn(mic);
    debugOverlayMic = listen;
    await listen.turnOn();
    listen.onLevelDb = (_) => throw StateError('listener gone');
    await svc.startAudio('srv', 'vc');
    await pumpEventQueue();
    expect(calls, ['start'], reason: 'the join gave up on its microphone');
  });
}

class _Api implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.memberName.toString().contains('crateApi')
          ? Future<void>.value()
          : super.noSuchMethod(invocation);
}
