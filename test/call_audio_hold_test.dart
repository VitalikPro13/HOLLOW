import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/services/audio_route.dart';
import 'package:hollow/src/core/services/call_audio_hold.dart';
import 'package:hollow/src/core/services/sound_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';

import 'helpers/test_app.dart';

/// #154: Android call audio (the audio mode and the microphone foreground
/// service) is held by the DM call itself from the moment the person commits
/// to it until it is idle, and by a voice room for its whole life. Tracks and
/// connections alone leave gaps: a media restart drops all of them until the
/// peer's new offer, and a call answered inside a room has none between the
/// room's leave and the offer. A foreground service lost in such a gap cannot
/// start again from the background, and the mic records silence.
///
/// Drives the real `CallNotifier` against a faked fork channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const webrtcMethod = MethodChannel('FlutterWebRTC.Method');
  final calls = <String>[];

  setUpAll(() {
    RustLib.initMock(api: _Api());
    SoundService.enabled = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Event'),
          (_) async => null,
        );
  });

  setUp(() {
    calls.clear();
    CallAudioHold.debugAndroidOverride = true;
    CallAudioHold.debugReset();
    CallNotifier.debugMobileOverride = true;
    VoiceChannelNotifier.debugMobileOverride = true;
    AudioRoutes.debugSupportedOverride = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(webrtcMethod, (call) async {
          if (call.method == 'holdCallAudioKey' ||
              call.method == 'releaseCallAudioKey') {
            calls.add('${call.method}:${(call.arguments as Map)['key']}');
          }
          if (call.method == 'getSources') return {'sources': const []};
          return null;
        });
  });

  tearDown(() {
    CallAudioHold.debugAndroidOverride = null;
    CallNotifier.debugMobileOverride = null;
    VoiceChannelNotifier.debugMobileOverride = null;
    AudioRoutes.debugSupportedOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(webrtcMethod, null);
  });

  const hold = 'holdCallAudioKey:dm-call';
  const release = 'releaseCallAudioKey:dm-call';

  ProviderContainer container({_Room? room}) => ProviderContainer(
    overrides: hollowTestOverrides(
      extra: [
        voiceChannelProvider.overrideWith(() => room ?? _Room(inRoom: false)),
      ],
    ),
  );

  test('mediaRestartKeepsCallAudioUntilTheNewOffer', () async {
    final c = container();
    final call = c.read(callProvider.notifier);
    await call.startCall('peer');
    final callId = c.read(callProvider).callId!;
    expect(calls, [hold], reason: 'placing the call holds call audio');
    // The peer's watchdog rebuilds the media: every track and connection here
    // goes until its new offer lands.
    await call.handleCallSignal('peer', 'media_restart', callId);
    expect(c.read(callProvider).status, isNot(CallStatus.idle));
    expect(calls, [hold], reason: 'the rebuild must not let call audio go');
    expect(CallAudioHold.held, contains('dm-call'));
    await call.handleCallSignal('peer', 'end', callId);
    expect(calls, [hold, release]);
    expect(CallAudioHold.held, isEmpty);
  });

  test('acceptFromRoomHoldsCallAudioUntilTheOffer', () async {
    final room = _Room(inRoom: true);
    final c = container(room: room);
    final call = c.read(callProvider.notifier);
    await call.handleCallSignal('peer', 'invite', '{"call_id":"c2"}');
    expect(c.read(callProvider).status, CallStatus.ringing);
    expect(calls, isEmpty, reason: 'a ring holds nothing; the app may be away');
    await call.acceptCall();
    expect(room.leaves, 1);
    expect(
      room.callHeldAtLeave,
      isTrue,
      reason:
          'the call holds before the room lets go, so the gap until '
          'the offer never empties call audio',
    );
    expect(calls, [hold]);
    expect(c.read(callProvider).status, CallStatus.connecting);
    await call.handleCallSignal('peer', 'end', 'c2');
    expect(calls, [hold, release]);
  });

  test('every way a held call ends lets call audio go', () async {
    final ends = <String, Future<void> Function(CallNotifier, String)>{
      'local hang-up': (call, _) => call.endCall(),
      'remote end': (call, id) => call.handleCallSignal('peer', 'end', id),
      'reject by the peer': (call, id) =>
          call.handleCallSignal('peer', 'reject', id),
      'link lost': (call, _) => call.handlePeerDisconnected('peer'),
    };
    for (final entry in ends.entries) {
      calls.clear();
      final c = container();
      final call = c.read(callProvider.notifier);
      await call.startCall('peer');
      await entry.value(call, c.read(callProvider).callId!);
      await pumpEventQueue();
      expect(c.read(callProvider).status, CallStatus.idle, reason: entry.key);
      expect(calls, [hold, release], reason: entry.key);
    }
  });

  test('a ring we decline never held call audio', () async {
    final c = container();
    final call = c.read(callProvider.notifier);
    await call.handleCallSignal('peer', 'invite', '{"call_id":"c3"}');
    await call.rejectCall();
    expect(calls, isEmpty);
  });

  test('only Android holds call audio', () async {
    CallAudioHold.debugAndroidOverride = false;
    final c = container();
    await c.read(callProvider.notifier).startCall('peer');
    expect(calls, isEmpty);
  });

  test('a voice room holds call audio for its whole life', () {
    // The room's join and leave paths are paired with the relay's realtime
    // flag, which already marks a room's whole life on every path.
    final src = File(
      'lib/src/core/providers/voice_channel_provider.dart',
    ).readAsStringSync();
    int count(String s) => s.allMatches(src).length;
    final acquires = count("RealtimeSessionFlag.acquire('voice-channel')");
    final releases = count("RealtimeSessionFlag.release('voice-channel')");
    expect(acquires, greaterThan(0));
    expect(count("CallAudioHold.acquire('voice-channel')"), acquires);
    expect(count("CallAudioHold.release('voice-channel')"), releases);
    for (final line in src.split('\n')) {
      if (line.contains("RealtimeSessionFlag.acquire('voice-channel')") ||
          line.contains("RealtimeSessionFlag.release('voice-channel')")) {
        final i = src.indexOf(line);
        final next = src.substring(i + line.length).trimLeft();
        expect(
          next.startsWith('CallAudioHold.'),
          isTrue,
          reason:
              'each realtime flag edge of a room is a call audio edge: '
              '${line.trim()}',
        );
      }
    }
  });
}

class _Room extends VoiceChannelNotifier {
  final bool inRoom;
  int leaves = 0;
  bool? callHeldAtLeave;
  _Room({required this.inRoom});

  @override
  VoiceChannelState build() => inRoom
      ? const VoiceChannelState(
          currentServerId: 'srv',
          currentChannelId: 'room',
        )
      : const VoiceChannelState();

  @override
  Future<void> leaveChannel() async {
    leaves++;
    callHeldAtLeave = CallAudioHold.held.contains('dm-call');
    state = const VoiceChannelState();
  }
}

class _Api implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    return name.contains('crateApi')
        ? Future<void>.value()
        : super.noSuchMethod(invocation);
  }
}
