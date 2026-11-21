import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/call_record.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/services/audio_route.dart';
import 'package:hollow/src/core/services/sound_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';

import 'helpers/test_app.dart';

/// #154: why the last DM call ended, as the OS call mirror reads it once the
/// call is idle (`end` reason local / remote / failed). Set once per call by
/// its first teardown, a teardown with no cause reads as a lost link (as the
/// call record does), and a new call starts with none.
///
/// Drives the real `CallNotifier`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const webrtcMethod = MethodChannel('FlutterWebRTC.Method');

  setUpAll(() {
    RustLib.initMock(api: _Api());
    SoundService.enabled = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('FlutterWebRTC.Event'), (_) async => null);
  });

  setUp(() {
    CallNotifier.debugMobileOverride = true;
    VoiceChannelNotifier.debugMobileOverride = true;
    AudioRoutes.debugSupportedOverride = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(webrtcMethod, (call) async {
      if (call.method == 'getSources') return {'sources': const []};
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

  // Not disposed: the failed fake offer leaves a teardown that outlives the
  // test and would read a disposed container.
  ProviderContainer container() => ProviderContainer(
      overrides: hollowTestOverrides(extra: [
        voiceChannelProvider.overrideWith(_NotInRoom.new),
      ]));

  test('a call torn down with no cause reads as a lost link', () async {
    final c = container();
    final call = c.read(callProvider.notifier);
    await call.startCall('peer');
    // Gone before it connected: the teardown names no cause.
    await call.handlePeerDisconnected('peer');
    expect(c.read(callProvider).status, CallStatus.idle);
    expect(call.lastEndCause, CallEndCause.linkLost);
  });

  test('a second teardown of the same call keeps the first one\'s cause',
      () async {
    final c = container();
    final call = c.read(callProvider.notifier);
    await call.startCall('peer');
    final callId = c.read(callProvider).callId!;
    // Our hang-up and the peer's end cross: both reach the teardown.
    final ours = call.endCall();
    await call.handleCallSignal('peer', 'end', callId);
    await ours;
    expect(c.read(callProvider).status, CallStatus.idle);
    expect(call.lastEndCause,
        anyOf(CallEndCause.localHangup, CallEndCause.remoteEnd));
  });

  test('a new call starts with no end cause of its own', () async {
    final c = container();
    final call = c.read(callProvider.notifier);
    await call.startCall('peer');
    final callId = c.read(callProvider).callId!;
    await call.handleCallSignal('peer', 'end', callId);
    expect(call.lastEndCause, CallEndCause.remoteEnd);
    await call.startCall('peer');
    expect(c.read(callProvider).status, CallStatus.ringing);
    expect(call.lastEndCause, isNull,
        reason: 'the last call\'s end belongs to the last call');
  });

  test('an incoming call starts with no end cause of its own', () async {
    final c = container();
    final call = c.read(callProvider.notifier);
    await call.startCall('peer');
    final callId = c.read(callProvider).callId!;
    await call.handleCallSignal('peer', 'end', callId);
    expect(call.lastEndCause, CallEndCause.remoteEnd);
    await call.handleCallSignal('peer', 'invite', '{"call_id":"c2"}');
    expect(c.read(callProvider).status, CallStatus.ringing);
    expect(call.lastEndCause, isNull);
  });
}

class _NotInRoom extends VoiceChannelNotifier {
  @override
  VoiceChannelState build() => const VoiceChannelState();
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
