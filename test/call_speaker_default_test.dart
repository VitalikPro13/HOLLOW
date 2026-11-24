import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/services/audio_route.dart';
import 'package:hollow/src/core/services/sound_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';

import 'helpers/test_app.dart';

/// #154: a phone's call starts on the loudspeaker unless "Start calls on the
/// speaker" is off, which sends a 1:1 VOICE call to the earpiece. Video calls
/// stay loud either way, and a connected headset always beats the loudspeaker.
///
/// Drives the real `CallNotifier` (accept, then the voice service's
/// `onConnected`, where the start route is applied) and reads what reached the
/// fork's method channel. The setting comes from a fake message store that can
/// be closed, as it is on the first frame of a cold start.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const webrtcMethod = MethodChannel('FlutterWebRTC.Method');
  final api = _Api();
  late List<MethodCall> calls;
  late List<Map<String, Object?>> sources;

  Map<String, Object?> input(String uid, String portType, String label) => {
        'deviceId': uid,
        'groupId': portType,
        'label': label,
        'kind': 'audioinput',
      };

  setUpAll(() {
    RustLib.initMock(api: api);
    SoundService.enabled = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('FlutterWebRTC.Event'), (_) async => null);
  });

  setUp(() {
    CallNotifier.debugMobileOverride = true;
    VoiceChannelNotifier.debugMobileOverride = true;
    AudioRoutes.debugSupportedOverride = true;
    api
      ..storeOpen = true
      ..stored = null
      ..readDelay = Duration.zero;
    calls = [];
    sources = [
      input('BuiltInMicUID', 'MicrophoneBuiltIn', 'iPhone Microphone'),
    ];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(webrtcMethod, (call) async {
      calls.add(call);
      if (call.method == 'getSources') return {'sources': sources};
      return null;
    });
  });

  tearDown(() {
    CallNotifier.debugMobileOverride = null;
    VoiceChannelNotifier.debugMobileOverride = null;
    AudioRoutes.debugSupportedOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(webrtcMethod, null);
  });

  ProviderContainer container({bool video = false, bool inRoom = false}) {
    final c = ProviderContainer(overrides: [
      callProvider.overrideWith(() => _Ringing(video: video)),
      if (inRoom) voiceChannelProvider.overrideWith(_InRoom.new),
    ]);
    // Not disposed: a connected call leaves timers (camera turn-on, stats,
    // repair) that outlive the test and would read a disposed container.
    return c;
  }

  /// Accepts the ringing call and connects its media; returns whether the
  /// state says hands-free.
  Future<bool> acceptAndConnect(ProviderContainer c) async {
    final call = c.read(callProvider.notifier);
    await call.acceptCall();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    call.debugVoiceService.onConnected!('peer');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.read(callProvider).status, CallStatus.active);
    return c.read(callProvider).isSpeakerOn;
  }

  bool invoked(String method) => calls.any((c) => c.method == method);
  bool? speakerArg() {
    for (final c in calls) {
      if (c.method == 'enableSpeakerphone') {
        return (c.arguments as Map)['enable'] as bool?;
      }
    }
    return null;
  }

  bool forcedEarpiece() => calls.any((m) =>
      m.method == 'enableSpeakerphone' &&
      (m.arguments as Map)['enable'] == false);

  group('the start route', () {
    test('a voice call starts on the loudspeaker by default', () async {
      expect(kStartCallsOnSpeakerDefault, isTrue);
      expect(await acceptAndConnect(container()), isTrue);
      expect(speakerArg(), isTrue,
          reason: 'the loud route was never asked for');
    });

    test('switch off: a voice call starts on the earpiece', () async {
      api.stored = 'false';
      expect(await acceptAndConnect(container()), isFalse);
      expect(speakerArg(), isFalse);
      expect(invoked('enableSpeakerphoneButPreferBluetooth'), isFalse);
    });

    test('switch off: a video call still starts on the loudspeaker', () async {
      api.stored = 'false';
      expect(await acceptAndConnect(container(video: true)), isTrue);
      expect(speakerArg(), isTrue);
    });

    test('a connected headset beats the loudspeaker default', () async {
      sources
          .add(input('WiredMicUID', 'MicrophoneWired', 'Headset Microphone'));
      expect(await acceptAndConnect(container()), isTrue,
          reason: 'hands-free state: the headset, never the earpiece');
      expect(invoked('enableSpeakerphoneButPreferBluetooth'), isTrue);
      expect(speakerArg(), isNull,
          reason: 'a hard speaker override outranks the headset');
    });

    test('caller side: switch off, the call we placed starts on the earpiece',
        () async {
      api.stored = 'false';
      final c = ProviderContainer(overrides: hollowTestOverrides(extra: [
        voiceChannelProvider.overrideWith(_NotInRoom.new),
      ]));
      // Not disposed: the failed fake offer leaves a teardown that outlives
      // the test and would read a disposed container.
      final call = c.read(callProvider.notifier);
      await call.startCall('peer');
      final callId = c.read(callProvider).callId!;
      await call.handleCallSignal(
          'peer', 'accept', jsonEncode({'call_id': callId}));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      call.debugVoiceService.onConnected!('peer');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.read(callProvider).status, CallStatus.active);
      expect(c.read(callProvider).isSpeakerOn, isFalse);
      expect(speakerArg(), isFalse);
    });

    test('a call ending under a live voice room leaves the room its route',
        () async {
      final c = ProviderContainer(overrides: [
        callProvider.overrideWith(_Connecting.new),
        voiceChannelProvider.overrideWith(_InRoom.new),
      ]);
      addTearDown(c.dispose);
      final call = c.read(callProvider.notifier);
      call.debugVoiceService.onConnected!('peer');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      calls.clear();
      await call.endCall();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(forcedEarpiece(), isFalse);
    });

    test('cold start: switch saved OFF, the notifier built before the store '
        'opens', () async {
      // Phones mount the proximity controller on the first frame, which builds
      // the call notifier before HollowShell opens the message store.
      api
        ..storeOpen = false
        ..stored = 'false';
      final c = container();
      c.read(callProvider.notifier);
      await Future<void>.delayed(Duration.zero);
      api.storeOpen = true;
      expect(await acceptAndConnect(c), isFalse,
          reason: 'switch is OFF but the call went loud');
      expect(c.read(startCallsOnSpeakerProvider).valueOrNull, isFalse);
    });

    test('cold start: a read that failed before the store opened is retried',
        () async {
      api
        ..storeOpen = false
        ..stored = 'false';
      final c = container();
      await c
          .read(startCallsOnSpeakerProvider.future)
          .then<void>((_) {}, onError: (_) {});
      expect(c.read(startCallsOnSpeakerProvider).hasError, isTrue);
      api.storeOpen = true;
      expect(await acceptAndConnect(c), isFalse,
          reason: 'the early failure stuck and the default won');
    });

    test("a second call never reuses the first call's reading", () async {
      api.stored = 'false';
      final c = container();
      expect(await acceptAndConnect(c), isFalse);
      await c.read(callProvider.notifier).endCall();
      // The second call rings, and this time the store cannot answer.
      (c.read(callProvider.notifier) as _Ringing).debugRing('c2');
      api.storeOpen = false;
      c.invalidate(startCallsOnSpeakerProvider);
      calls.clear();
      expect(await acceptAndConnect(c), isTrue,
          reason: 'the stale OFF from the first call decided the second');
    });

    test('switch OFF, a slow store read: the call still starts on the earpiece',
        () async {
      api
        ..stored = 'false'
        ..readDelay = const Duration(milliseconds: 300);
      final c = container();
      final call = c.read(callProvider.notifier);
      await call.acceptCall();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      call.debugVoiceService.onConnected!('peer');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(c.read(callProvider).isSpeakerOn, isFalse,
          reason: 'a read that landed after onConnected was never applied');
    });

    test('a slow read never overrides a route the person chose meanwhile',
        () async {
      api
        ..stored = 'false'
        ..readDelay = const Duration(milliseconds: 300);
      final c = container();
      final call = c.read(callProvider.notifier);
      await call.acceptCall();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      call.debugVoiceService.onConnected!('peer');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      call.toggleSpeaker(); // loud by default -> the person picks the earpiece
      call.toggleSpeaker(); // -> and back to the speaker
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(c.read(callProvider).isSpeakerOn, isTrue,
          reason: "the late read overrode the person's own choice");
    });

    test('a slow read never lands on the next call', () async {
      api
        ..stored = 'false'
        ..readDelay = const Duration(milliseconds: 300);
      final c = container();
      final call = c.read(callProvider.notifier);
      await call.acceptCall();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      call.debugVoiceService.onConnected!('peer');
      await call.endCall();
      api.stored = 'true';
      (call as _Ringing).debugRing('c2');
      api.readDelay = Duration.zero;
      expect(await acceptAndConnect(c), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(c.read(callProvider).isSpeakerOn, isTrue,
          reason: "the first call's late OFF landed on the second call");
    });

    test("an older call's late read never decides a newer call's start",
        () async {
      api
        ..stored = 'false'
        ..readDelay = const Duration(milliseconds: 300);
      final c = container();
      final call = c.read(callProvider.notifier);
      await call.acceptCall(); // its read lands at about 300 ms with OFF
      await call.endCall();
      (call as _Ringing).debugRing('c2');
      api
        ..stored = 'true'
        ..readDelay = const Duration(milliseconds: 900);
      c.invalidate(startCallsOnSpeakerProvider); // the person changed it
      await call.acceptCall(); // its own read lands at about 900 ms with ON
      await Future<void>.delayed(const Duration(milliseconds: 400));
      call.debugVoiceService.onConnected!('peer');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.read(callProvider).isSpeakerOn, isTrue,
          reason: "the first call's OFF decided the second call");
    });

    test("a route chosen in one call never blocks the next call's late read",
        () async {
      final c = container();
      final call = c.read(callProvider.notifier);
      await acceptAndConnect(c);
      call.toggleSpeaker();
      await call.endCall();
      (call as _Ringing).debugRing('c2');
      api
        ..stored = 'false'
        ..readDelay = const Duration(milliseconds: 300);
      c.invalidate(startCallsOnSpeakerProvider); // the person changed it
      await call.acceptCall();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      call.debugVoiceService.onConnected!('peer');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(c.read(callProvider).isSpeakerOn, isFalse,
          reason: "the first call's choice blocked the second call's OFF");
    });

    test('a store that cannot answer at all leaves the default on', () async {
      api
        ..storeOpen = false
        ..stored = 'false';
      expect(await acceptAndConnect(container()), isTrue);
      expect(speakerArg(), isTrue);
    });
  });

  // The call notification's Speaker asks for a state, never a flip: it is
  // judged against the route audio is on, which hands-free can differ from.
  group('a set from the call notification', () {
    test('a DM call: on stays on, off goes to the earpiece, and it counts '
        "as the person's choice", () async {
      api
        ..stored = 'false'
        ..readDelay = const Duration(milliseconds: 300);
      final c = container();
      final call = c.read(callProvider.notifier);
      await call.acceptCall();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      call.debugVoiceService.onConnected!('peer');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.read(callProvider).isSpeakerOn, isTrue, reason: 'loud default');
      call.setSpeaker(true);
      expect(c.read(callProvider).isSpeakerOn, isTrue, reason: 'a set toggled');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(c.read(callProvider).isSpeakerOn, isTrue,
          reason: 'the late read overrode the choice');
      calls.clear();
      call.setSpeaker(false);
      call.setSpeaker(false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.read(callProvider).isSpeakerOn, isFalse);
      expect(forcedEarpiece(), isTrue);
    });

    test('a room: a set never toggles', () async {
      final c = ProviderContainer(overrides: [
        callProvider.overrideWith(_Idle.new),
        voiceChannelProvider.overrideWith(_InRoom.new),
      ]);
      addTearDown(c.dispose);
      final room = c.read(voiceChannelProvider.notifier);
      room.setSpeaker(true);
      expect(c.read(voiceChannelProvider).isSpeakerOn, isTrue);
      room.setSpeaker(false);
      room.setSpeaker(false);
      expect(c.read(voiceChannelProvider).isSpeakerOn, isFalse);
    });
  });

  group("the route reset never lands under someone else's audio", () {
    test('declining a DM ring while in a voice room keeps the room loud',
        () async {
      final c = container(inRoom: true);
      c.read(callProvider.notifier);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(voiceChannelProvider).isSpeakerOn, isTrue);
      await c.read(callProvider.notifier).rejectCall();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(forcedEarpiece(), isFalse,
          reason: 'the voice room was moved to the earpiece');
    });

    test('a ring declined outside any room never touches the route',
        () async {
      final c = container();
      c.read(callProvider.notifier);
      await Future<void>.delayed(Duration.zero);
      await c.read(callProvider.notifier).rejectCall();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(invoked('enableSpeakerphone'), isFalse,
          reason: 'a call that never reached media reset the route');
    });

    test('a call that connected resets the route when it ends', () async {
      final c = container();
      await acceptAndConnect(c);
      calls.clear();
      await c.read(callProvider.notifier).endCall();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(forcedEarpiece(), isTrue,
          reason: 'the next call would inherit the speaker');
    });

    test("leaving the room for an accepted DM call keeps the call's route",
        () async {
      // acceptCall marks the DM connecting BEFORE the room's leave lands.
      final c = container(inRoom: true);
      await c.read(callProvider.notifier).acceptCall();
      expect(c.read(callProvider).status, CallStatus.connecting);
      c.read(voiceChannelProvider.notifier).onLocalLeft();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(forcedEarpiece(), isFalse,
          reason: "the room's leave undid the DM call's route");
    });

    test('leave the room during a DM ring, then decline: the route is reset',
        () async {
      final c = container(inRoom: true);
      c.read(callProvider.notifier);
      await Future<void>.delayed(Duration.zero);
      c.read(voiceChannelProvider.notifier).onLocalLeft();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await c.read(callProvider.notifier).rejectCall();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(forcedEarpiece(), isTrue,
          reason: "the room's speaker route outlived the room and the ring");
    });

    test('leaving a room with no call resets the route', () async {
      final c = ProviderContainer(overrides: [
        callProvider.overrideWith(_Idle.new),
        voiceChannelProvider.overrideWith(_InRoom.new),
      ]);
      addTearDown(c.dispose);
      c.read(voiceChannelProvider.notifier).onLocalLeft();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(forcedEarpiece(), isTrue);
    });
  });
}

class _Ringing extends CallNotifier {
  _Ringing({required this.video});
  final bool video;

  /// A new incoming call on the same notifier.
  void debugRing(String callId) => state = CallState(
        status: CallStatus.ringing,
        peerId: 'peer',
        callId: callId,
        direction: CallDirection.incoming,
      );

  @override
  CallState build() {
    super.build();
    return CallState(
      status: CallStatus.ringing,
      peerId: 'peer',
      callId: 'c1',
      direction: CallDirection.incoming,
      isVideoCall: video,
    );
  }
}

class _Connecting extends CallNotifier {
  @override
  CallState build() {
    super.build();
    return const CallState(
      status: CallStatus.connecting,
      peerId: 'peer',
      callId: 'c1',
      direction: CallDirection.incoming,
    );
  }
}

class _Idle extends CallNotifier {
  @override
  CallState build() {
    super.build();
    return const CallState();
  }
}

class _NotInRoom extends VoiceChannelNotifier {
  @override
  VoiceChannelState build() => const VoiceChannelState();
}

class _InRoom extends VoiceChannelNotifier {
  @override
  VoiceChannelState build() => const VoiceChannelState(
      currentServerId: 's', currentChannelId: 'v', isSpeakerOn: true);
}

class _Api implements RustLibApi {
  bool storeOpen = true;
  String? stored;
  Duration readDelay = Duration.zero;

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async {
    if (readDelay > Duration.zero) await Future<void>.delayed(readDelay);
    if (!storeOpen) throw 'Message store is not open';
    return key == 'start_calls_on_speaker' ? stored : null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    return name.contains('crateApi')
        ? Future<void>.value()
        : super.noSuchMethod(invocation);
  }
}
