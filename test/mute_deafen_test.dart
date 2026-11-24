/// Mute and deafen as one model (#154, Vitalik Nov 24): deafen mutes the mic,
/// unmuting while deafened undeafens too, and undeafening gives back the mic
/// from before the deafen. Driven through the real DM and voice room
/// notifiers: the button state, the transmit gate and what the others are
/// told must never disagree.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/mute_deafen.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/services/sound_service.dart';
import 'package:hollow/src/core/services/voice_channel_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = _Api();

  setUpAll(() {
    RustLib.initMock(api: api);
    SoundService.enabled = false;
    for (final name in ['FlutterWebRTC.Method', 'FlutterWebRTC.Event']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });
  setUp(api.sent.clear);

  group('the model', () {
    const open = MuteDeafen();
    const muted = MuteDeafen(muted: true);

    test('deafen mutes the mic', () {
      final d = open.tapDeafen();
      expect((d.muted, d.deafened), (true, true));
    });

    test('undeafen gives back an open mic', () {
      expect(open.tapDeafen().tapDeafen(), open);
    });

    test('undeafen keeps a mic that was muted before muted', () {
      expect(muted.tapDeafen().tapDeafen(), muted);
    });

    test('unmute while deafened talks and hears again in one tap', () {
      expect(open.tapDeafen().tapMute(), open);
      expect(muted.tapDeafen().tapMute(), open);
    });

    test('mute alone never deafens', () {
      expect(open.tapMute(), muted);
      expect(muted.tapMute(), open);
    });

    test('deafened is never unmuted, whatever the taps', () {
      const taps = ['m', 'd'];
      var states = {open, muted};
      for (var depth = 0; depth < 4; depth++) {
        states = {
          for (final s in states)
            for (final t in taps) t == 'm' ? s.tapMute() : s.tapDeafen()
        };
        for (final s in states) {
          expect(!s.deafened || s.muted, isTrue, reason: '$s');
        }
      }
    });
  });

  group('DM call', () {
    late ProviderContainer c;
    late CallNotifier n;
    setUp(() {
      c = ProviderContainer(overrides: [callProvider.overrideWith(_Active.new)]);
      addTearDown(c.dispose);
      n = c.read(callProvider.notifier);
    });

    /// Button, transmit gate, remote volume and the last `audio_state` sent.
    void agrees({required bool muted, required bool deafened}) {
      final s = c.read(callProvider);
      expect((s.isMuted, s.isDeafened), (muted, deafened), reason: 'buttons');
      expect(n.debugTxGated, muted || deafened, reason: 'transmit gate');
      expect(n.debugVoiceService.debugRemoteVolume, deafened ? 0.0 : 1.0,
          reason: 'what we hear');
      final told = api.lastAudioState('audio_state');
      expect((told['muted'], told['deafened']), (muted, deafened),
          reason: 'what the peer sees');
    }

    test('open mic: deafen, then undeafen = open again', () {
      n.toggleDeafen();
      agrees(muted: true, deafened: true);
      n.toggleDeafen();
      agrees(muted: false, deafened: false);
    });

    test('muted mic: deafen, then undeafen = still muted', () {
      n.toggleMute();
      agrees(muted: true, deafened: false);
      n.toggleDeafen();
      agrees(muted: true, deafened: true);
      n.toggleDeafen();
      agrees(muted: true, deafened: false);
    });

    test('unmute while deafened undeafens too', () {
      n.toggleMute();
      n.toggleDeafen();
      n.toggleMute();
      agrees(muted: false, deafened: false);
    });
  });

  group('voice room', () {
    late ProviderContainer c;
    late VoiceChannelNotifier n;
    late _Mesh mesh;
    setUp(() {
      c = ProviderContainer(
          overrides: [voiceChannelProvider.overrideWith(_Room.new)]);
      addTearDown(c.dispose);
      n = c.read(voiceChannelProvider.notifier);
      mesh = _Mesh();
      n.debugAdoptCall(mesh);
    });

    void agrees({required bool muted, required bool deafened}) {
      final s = c.read(voiceChannelProvider);
      expect((s.isMuted, s.isDeafened), (muted, deafened), reason: 'buttons');
      expect(mesh.gated, muted || deafened, reason: 'transmit gate');
      expect(mesh.deafened, deafened, reason: 'what we hear');
      final told = api.lastAudioState('vc:audio_state');
      expect((told['muted'], told['deafened']), (muted, deafened),
          reason: 'what the room sees');
    }

    test('open mic: deafen, then undeafen = open again', () {
      n.toggleDeafen();
      agrees(muted: true, deafened: true);
      n.toggleDeafen();
      agrees(muted: false, deafened: false);
    });

    test('muted mic: deafen, then undeafen = still muted', () {
      n.toggleMute();
      n.toggleDeafen();
      agrees(muted: true, deafened: true);
      n.toggleDeafen();
      agrees(muted: true, deafened: false);
    });

    test('unmute while deafened undeafens too', () {
      n.toggleDeafen();
      n.toggleMute();
      agrees(muted: false, deafened: false);
    });
  });
}

class _Active extends CallNotifier {
  @override
  CallState build() {
    super.build();
    return const CallState(
      status: CallStatus.active,
      peerId: 'peer',
      callId: 'c1',
      direction: CallDirection.outgoing,
    );
  }
}

class _Room extends VoiceChannelNotifier {
  @override
  VoiceChannelState build() {
    super.build();
    return const VoiceChannelState(
      currentServerId: 's',
      currentChannelId: 'v',
      participants: {
        's': {
          'v': {'peer'}
        }
      },
    );
  }
}

class _Mesh extends VoiceChannelService {
  _Mesh() : super(localPeerId: 'me', iceServers: const {});
  bool gated = false;
  bool deafened = false;

  @override
  void setMuted(bool muted) => gated = muted;

  @override
  Future<void> setDeafened(bool deafened) async => this.deafened = deafened;
}

class _Api implements RustLibApi {
  /// (signal type, payload); room signals are prefixed `vc:`.
  final sent = <(String, String)>[];

  Map<String, Object?> lastAudioState(String type) => jsonDecode(
          sent.lastWhere((s) => s.$1 == type).$2) as Map<String, Object?>;

  @override
  Future<void> crateApiNetworkCallSendSignal({
    required String peerId,
    required String signalType,
    required String payload,
  }) async =>
      sent.add((signalType, payload));

  @override
  Future<void> crateApiNetworkVoiceChannelSendSignal({
    required String serverId,
    required String channelId,
    required String peerId,
    required String signalType,
    required String payload,
  }) async =>
      sent.add(('vc:$signalType', payload));

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    return name.contains('crateApi')
        ? Future<void>.value()
        : super.noSuchMethod(invocation);
  }
}
