/// A DM call the link ended stays on screen 5 s saying "Connection lost"
/// (#154, Vitalik Nov 24); a hang-up never lingers and a new call replaces
/// it at once. Drives the real `CallNotifier` for what sets it, and the
/// notifier alone (fake clock) for how long it stays.
library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/models/call_record.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/lost_call_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/services/sound_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';

import 'helpers/test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    RustLib.initMock(api: _Api());
    SoundService.enabled = false;
    for (final name in ['FlutterWebRTC.Method', 'FlutterWebRTC.Event']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });

  // Not disposed: a teardown can outlive the test and read the container.
  ProviderContainer container(CallStatus status) =>
      ProviderContainer(overrides: hollowTestOverrides(extra: [
        callProvider.overrideWith(() => _Call(status)),
        voiceChannelProvider.overrideWith(_NotInRoom.new),
      ]));

  group('what lingers', () {
    // A live call's only link-lost end: the link watch giving up (a closed
    // transport is terminal to it, like a spent window).
    test('a live call whose link watch gave up', () async {
      final c = container(CallStatus.active);
      final calls = c.read(callProvider.notifier)..debugStartLinkWatch();
      calls.debugTransportState(
          RTCPeerConnectionState.RTCPeerConnectionStateClosed);
      await pumpEventQueue();
      expect(c.read(callProvider).status, CallStatus.idle);
      expect(calls.lastEndCause, CallEndCause.linkLost);
      final lost = c.read(lostCallProvider);
      expect(lost?.callId, 'c1');
      expect(lost?.peerMaster, 'peer');
      expect(lost?.secondsLeft, kLostCallLingerSeconds);
    });

    // A hang-up already under way when the watch gives up closes at once and
    // keeps its own cause.
    test('never a hang-up the give-up crosses', () async {
      final c = container(CallStatus.active);
      final calls = c.read(callProvider.notifier)..debugStartLinkWatch();
      final ending = calls.endCall();
      calls.debugTransportState(
          RTCPeerConnectionState.RTCPeerConnectionStateClosed);
      await ending;
      await pumpEventQueue();
      expect(c.read(callProvider).status, CallStatus.idle);
      expect(c.read(lostCallProvider), isNull);
      expect(calls.lastEndCause, CallEndCause.localHangup);
    });

    test('never a remote hang-up the give-up crosses', () async {
      final c = container(CallStatus.active);
      final calls = c.read(callProvider.notifier)..debugStartLinkWatch();
      final ending = calls.handleCallSignal('peer', 'end', 'c1');
      calls.debugTransportState(
          RTCPeerConnectionState.RTCPeerConnectionStateClosed);
      await ending;
      await pumpEventQueue();
      expect(c.read(callProvider).status, CallStatus.idle);
      expect(c.read(lostCallProvider), isNull);
      expect(calls.lastEndCause, CallEndCause.remoteEnd);
    });

    test('never a hang-up', () async {
      final c = container(CallStatus.active);
      await c.read(callProvider.notifier).endCall();
      expect(c.read(callProvider).status, CallStatus.idle);
      expect(c.read(lostCallProvider), isNull);
    });

    test('never a call that had not connected yet', () async {
      final c = container(CallStatus.connecting);
      c.read(callProvider.notifier).debugTransportState(
          RTCPeerConnectionState.RTCPeerConnectionStateClosed);
      await pumpEventQueue();
      expect(c.read(callProvider).status, CallStatus.idle);
      expect(c.read(lostCallProvider), isNull);
    });
  });

  group('how long', () {
    testWidgets('counts 5 to 1, then goes', (tester) async {
      final c = ProviderContainer(overrides: [
        callProvider.overrideWith(() => _Seeded(const CallState())),
      ]);
      addTearDown(c.dispose);
      c.read(lostCallProvider.notifier).show(callId: 'c1', peerMaster: 'p');
      for (var left = 5; left >= 1; left--) {
        expect(c.read(lostCallProvider)?.secondsLeft, left);
        await tester.pump(const Duration(seconds: 1));
      }
      expect(c.read(lostCallProvider), isNull);
    });

    testWidgets('a new call replaces it at once', (tester) async {
      final call = _Seeded(const CallState());
      final c = ProviderContainer(
          overrides: [callProvider.overrideWith(() => call)]);
      addTearDown(c.dispose);
      c.read(lostCallProvider.notifier).show(callId: 'c1', peerMaster: 'p');
      call.set(const CallState(
          status: CallStatus.ringing,
          direction: CallDirection.incoming,
          peerId: 'q',
          callId: 'c2'));
      expect(c.read(lostCallProvider), isNull);
      await tester.pump(const Duration(seconds: 6));
    });
  });
}

class _Call extends CallNotifier {
  final CallStatus status;
  _Call(this.status);

  @override
  CallState build() {
    super.build();
    return CallState(
      status: status,
      peerId: 'peer',
      callId: 'c1',
      direction: CallDirection.outgoing,
      startedAt: status == CallStatus.active ? DateTime.now() : null,
    );
  }
}

class _Seeded extends CallNotifier {
  CallState seed;
  _Seeded(this.seed);

  @override
  CallState build() => seed;

  void set(CallState s) => state = s;
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
