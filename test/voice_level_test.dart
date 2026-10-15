import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/overlay_runtime_provider.dart';
import 'package:hollow/src/core/providers/speaking_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/providers/voice_level_provider.dart';
import 'package:hollow/src/core/services/voice_channel_service.dart';
import 'package:hollow/src/core/services/voice_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';

/// Voice levels for the stream overlay (plan 16.4): one 0..1 scale for every
/// source, faster polls only while an OBS page streams, and nothing that draws
/// a speaking cue rebuilds when a level moves.
void main() {
  setUpAll(() => RustLib.initMock(api: _Api()));

  group('normalisation', () {
    test('dBFS maps -60..0 onto 0..1, clamped', () {
      expect(levelFromDb(-60), 0.0);
      expect(levelFromDb(-30), closeTo(0.5, 1e-9));
      expect(levelFromDb(0), 1.0);
      expect(levelFromDb(-100), 0.0);
      expect(levelFromDb(6), 1.0);
      expect(levelFromDb(null), 0.0);
      expect(levelFromDb(double.nan), 0.0);
    });

    test('an inbound-rtp audioLevel goes through 20*log10 first', () {
      expect(levelFromAudioLevel(1.0), 1.0);
      expect(levelFromAudioLevel(0.1), closeTo(40 / 60, 1e-9));
      expect(levelFromAudioLevel(0.001), closeTo(0.0, 1e-9));
      expect(levelFromAudioLevel(0), 0.0);
      expect(levelFromAudioLevel(null), 0.0);
    });

    test('remote levels keep two decimals and leave quiet peers out', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(vcLevelsProvider.notifier).set({'a': 0.123, 'b': 0.001});
      expect(c.read(vcLevelsProvider), {'a': 0.12});
    });
  });

  group('poll interval', () {
    test('100 ms while an OBS page streams, else 200 ms', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(voicePollIntervalProvider), kVoicePollNormal);
      c.read(overlayOpenStreamsProvider.notifier).state = 2;
      expect(c.read(voicePollIntervalProvider), kVoicePollFast);
      c.read(overlayOpenStreamsProvider.notifier).state = 0;
      expect(c.read(voicePollIntervalProvider), kVoicePollNormal);
      expect(kVoicePollFast, const Duration(milliseconds: 100));
      expect(kVoicePollNormal, const Duration(milliseconds: 200));
    });

    test('a voice channel in progress switches with the streams', () async {
      final c = ProviderContainer(
          overrides: [voiceChannelProvider.overrideWith(_Room.new)]);
      addTearDown(c.dispose);
      final mesh = _Mesh();
      c.read(voiceChannelProvider.notifier).debugAdoptCall(mesh);

      c.read(overlayOpenStreamsProvider.notifier).state = 1;
      await pumpEventQueue();
      expect(mesh.pollInterval, kVoicePollFast);
      c.read(overlayOpenStreamsProvider.notifier).state = 0;
      await pumpEventQueue();
      expect(mesh.pollInterval, kVoicePollNormal);
    });

    test('a DM call service takes a new interval', () {
      final svc = VoiceService(localPeerId: 'me', iceServers: const {});
      expect(svc.pollInterval, kVoicePollNormal);
      svc.setPollInterval(kVoicePollFast);
      expect(svc.pollInterval, kVoicePollFast);
    });
  });

  test('a level change rebuilds nothing that draws a speaking cue', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    var speakingNotices = 0;
    c.listen(vcSpeakingProvider, (_, _) => speakingNotices++);
    c.listen(vcLocalSpeakingProvider, (_, _) => speakingNotices++);
    c.listen(callSpeakingProvider, (_, _) => speakingNotices++);

    c.read(vcLevelsProvider.notifier).set({'peer': 0.7});
    c.read(vcLocalLevelProvider.notifier).set(0.4);
    c.read(callLevelProvider.notifier).set(local: 0.3, remote: 0.9);
    c.read(listenLevelProvider.notifier).set(0.5);

    expect(speakingNotices, 0);
    expect(c.read(callLevelProvider), (local: 0.3, remote: 0.9));
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
  VoiceChannelState build() {
    super.build();
    return const VoiceChannelState(
        currentServerId: 'srv', currentChannelId: 'vc');
  }
}

class _Mesh extends VoiceChannelService {
  _Mesh() : super(localPeerId: 'me', iceServers: const {});
}
