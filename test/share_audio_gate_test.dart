import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';

/// HOL-SEC-058. Share audio played from any open data channel, so a friend or
/// co-member with a modified client could play into a call as if it were the
/// sharer.
void main() {
  group('a DM call', () {
    CallNotifier inCall({required bool watching}) {
      final container = ProviderContainer(overrides: [
        callProvider.overrideWith(() => _InCall(CallState(
              status: CallStatus.active,
              peerId: 'alice',
              callId: 'c1',
              direction: CallDirection.outgoing,
              watchingRemoteShare: watching,
            ))),
        deviceLinkProvider
            .overrideWith(() => _Links(const {'alice-phone': 'alice'})),
      ]);
      addTearDown(container.dispose);
      return container.read(callProvider.notifier);
    }

    test('plays share audio only from the call peer, from any of its devices',
        () {
      final call = inCall(watching: true);
      expect(call.acceptsShareAudioFrom('alice'), isTrue);
      expect(call.acceptsShareAudioFrom('alice-phone'), isTrue);
      expect(call.acceptsShareAudioFrom('mallory'), isFalse);
    });

    test('plays nothing while we are not watching the share', () {
      expect(inCall(watching: false).acceptsShareAudioFrom('alice'), isFalse);
    });
  });

  test('a voice channel plays share audio only from a sharer we watch', () {
    final container = ProviderContainer(overrides: [
      voiceChannelProvider.overrideWith(() =>
          _Room(const VoiceChannelState(watchingScreenShares: {'bob'}))),
    ]);
    addTearDown(container.dispose);
    final vc = container.read(voiceChannelProvider.notifier);
    expect(vc.acceptsShareAudioFrom('bob'), isTrue);
    expect(vc.acceptsShareAudioFrom('mallory'), isFalse);
  });
}

class _InCall extends CallNotifier {
  final CallState initial;
  _InCall(this.initial);
  @override
  CallState build() => initial;
}

class _Room extends VoiceChannelNotifier {
  final VoiceChannelState initial;
  _Room(this.initial);
  @override
  VoiceChannelState build() => initial;
}

class _Links extends DeviceLinkNotifier {
  final Map<String, String> links;
  _Links(this.links);
  @override
  DeviceLinkState build() => DeviceLinkState(links: links);
}
