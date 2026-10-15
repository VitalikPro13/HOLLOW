import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/overlay_mic_provider.dart';
import 'package:hollow/src/core/providers/overlay_runtime_provider.dart';
import 'package:hollow/src/core/providers/roster_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/providers/voice_level_provider.dart';
import 'package:hollow/src/core/providers/webrtc_provider.dart';
import 'package:hollow/src/core/services/overlay_mic.dart';
import 'package:hollow/src/core/services/sound_service.dart';
import 'package:hollow/src/core/services/voice_channel_service.dart';
import 'package:hollow/src/core/services/voice_service.dart';
import 'package:hollow/src/core/services/webrtc_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';

import 'helpers/fake_mic.dart';
import 'helpers/test_app.dart';

/// Every path that opens call audio stops listening for the overlay first and
/// opens the mic only once listening has let go of it; listening comes back
/// after the call's teardown, and the app's locks and the server stop it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    RustLib.initMock(api: _Api());
    SoundService.enabled = false;
  });

  const webrtc = MethodChannel('FlutterWebRTC.Method');
  late List<String> events;
  late FakeMic mic;
  late OverlayMic listen;

  setUp(() {
    events = [];
    mic = FakeMic(events);
    listen = overlayMicOn(mic);
    debugOverlayMic = listen;
    overlayMicSupported = () => true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(webrtc, (call) async {
      switch (call.method) {
        case 'getUserMedia':
          events.add('call-getUserMedia');
          return {'streamId': 'mic', 'audioTracks': [], 'videoTracks': []};
        case 'frameCryptorFactoryCreateKeyProvider':
          return {'keyProviderId': 'kp'};
        case 'getCaptureLevel':
          return {'levelDb': -100.0};
      }
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(webrtc, null);
  });

  group('the call capture waits for the mic', () {
    test('joining a voice channel', () async {
      await listen.turnOn();
      final svc = VoiceChannelService(localPeerId: 'me', iceServers: const {});
      await svc.startAudio('srv', 'vc');
      await svc.closeAll();

      expect(events.indexOf('mic-released'), greaterThanOrEqualTo(0));
      expect(events.indexOf('mic-released'),
          lessThan(events.indexOf('call-getUserMedia')),
          reason: 'getUserMedia ran while listening still held the mic');
      expect(listen.holds, contains(OverlayMicHold.voiceChannel));
    });

    test('starting or answering a DM call', () async {
      await listen.turnOn();
      final svc = VoiceService(localPeerId: 'me', iceServers: const {});
      // No native peer connection here: the offer fails after the capture.
      await svc.createOffer('peer', 'call').catchError((_) => '');

      expect(events.indexOf('mic-released'), greaterThanOrEqualTo(0));
      expect(events.indexOf('mic-released'),
          lessThan(events.indexOf('call-getUserMedia')),
          reason: 'getUserMedia ran while listening still held the mic');
      expect(listen.holds, contains(OverlayMicHold.dmCall));
    });
  });

  group('a DM call', () {
    test('ringing out pauses listening, hanging up hands the mic back',
        () async {
      final c = ProviderContainer(overrides: hollowTestOverrides(extra: [
        voiceChannelProvider.overrideWith(_NotInRoom.new),
      ]));
      addTearDown(c.dispose);
      await listen.turnOn();
      final calls = c.read(callProvider.notifier);

      await calls.startCall('friend');
      expect(c.read(callProvider).status, CallStatus.ringing);
      expect(listen.status.value.paused, isTrue,
          reason: 'the mic must be free before the call can open it');

      await calls.endCall();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(c.read(callProvider).status, CallStatus.idle);
      expect(listen.status.value.listening, isTrue);
      expect(listen.holds, isEmpty);
    });
  });

  group('after a voice channel', () {
    ({ProviderContainer c, VoiceChannelNotifier vc, _Mesh mesh}) room() {
      final c = ProviderContainer(overrides: [
        voiceChannelProvider.overrideWith(_Room.new),
        webRtcProvider.overrideWith(_NoDataChannels.new),
      ]);
      addTearDown(c.dispose);
      final vc = c.read(voiceChannelProvider.notifier);
      final mesh = _Mesh(events);
      vc.debugAdoptCall(mesh);
      return (c: c, vc: vc, mesh: mesh);
    }

    test('listening resumes once the teardown has closed the mesh', () async {
      await listen.turnOn();
      await listen.yieldToCall(OverlayMicHold.voiceChannel);
      final r = room();

      await r.vc.leaveChannel();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(listen.status.value.listening, isTrue);
      expect(events.lastIndexOf('mic-open'),
          greaterThan(events.indexOf('mesh-closed')));
    });

    test('and stays off when it was turned off during the call', () async {
      await listen.turnOn();
      await listen.yieldToCall(OverlayMicHold.voiceChannel);
      await listen.turnOff();
      final r = room();

      await r.vc.leaveChannel();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(listen.status.value.listening, isFalse);
      expect(mic.opens, 1);
    });
  });

  group('overlayMicProvider', () {
    ProviderContainer app() {
      final c = ProviderContainer(overrides: [
        audioInputDeviceProvider.overrideWith(_NoInput.new),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('refuses while the overlay server is off', () async {
      final c = app();
      await expectLater(c.read(overlayMicProvider.notifier).turnOn(),
          throwsA(isA<OverlayMicRefused>()));
      expect(mic.opens, 0);
    });

    test('is off at start and listens once asked', () async {
      final c = app();
      expect(c.read(overlayMicProvider), const OverlayMicStatus());
      c.read(overlayServerRunningProvider.notifier).state = true;
      await c.read(overlayMicProvider.notifier).turnOn();
      expect(c.read(overlayMicProvider).listening, isTrue);
    });

    test('stops when the overlay server stops', () async {
      final c = app();
      c.read(overlayServerRunningProvider.notifier).state = true;
      await c.read(overlayMicProvider.notifier).turnOn();
      c.read(overlayServerRunningProvider.notifier).state = false;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(c.read(overlayMicProvider), const OverlayMicStatus());
      expect(mic.isOpen, isFalse);
    });

    test('stops when App Lock engages', () async {
      final c = app();
      c.read(overlayServerRunningProvider.notifier).state = true;
      await c.read(overlayMicProvider.notifier).turnOn();
      c.read(appLockedProvider.notifier).setLocked(true);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(c.read(overlayMicProvider).on, isFalse);
      expect(mic.isOpen, isFalse);
    });

    test('stops when the roster locks this device', () async {
      final c = app();
      c.read(overlayServerRunningProvider.notifier).state = true;
      await c.read(overlayMicProvider.notifier).turnOn();
      c.read(rosterGateProvider.notifier).removed('other', 0);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(c.read(overlayMicProvider).on, isFalse);
      expect(mic.isOpen, isFalse);
    });

    test('refuses while App Lock is engaged', () async {
      final c = app();
      c.read(overlayServerRunningProvider.notifier).state = true;
      c.read(appLockedProvider.notifier).setLocked(true);
      await expectLater(c.read(overlayMicProvider.notifier).turnOn(),
          throwsA(isA<OverlayMicRefused>()));
    });

    test('refuses on a phone', () async {
      overlayMicSupported = () => false;
      final c = app();
      c.read(overlayServerRunningProvider.notifier).state = true;
      await expectLater(c.read(overlayMicProvider.notifier).turnOn(),
          throwsA(isA<OverlayMicRefused>()));
    });

    test('feeds the listening level and speaking', () async {
      final c = app();
      c.read(overlayServerRunningProvider.notifier).state = true;
      await c.read(overlayMicProvider.notifier).turnOn();
      mic.feed(16384); // -6 dBFS
      await pumpEventQueue();
      expect(c.read(listenLevelProvider), closeTo(0.9, 0.01));
      expect(c.read(overlayMicSpeakingProvider), isTrue);
    });
  });
}

class _Api implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.memberName.toString().contains('crateApi')
          ? Future<void>.value()
          : super.noSuchMethod(invocation);
}

class _Room extends VoiceChannelNotifier {
  @override
  VoiceChannelState build() => const VoiceChannelState(
        currentServerId: 'srv',
        currentChannelId: 'vc',
        currentChannelName: 'room',
      );
}

class _NoDataChannels extends WebRtcNotifier {
  @override
  WebRtcService get service => throw StateError('no data channels here');
}

class _Mesh extends VoiceChannelService {
  _Mesh(this.events) : super(localPeerId: 'me', iceServers: const {});
  final List<String> events;

  @override
  Future<void> closeAll() async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    events.add('mesh-closed');
  }
}

class _NotInRoom extends VoiceChannelNotifier {
  @override
  VoiceChannelState build() => const VoiceChannelState();
}

class _NoInput extends AudioInputDeviceNotifier {
  @override
  Future<String?> build() async => null;
}
