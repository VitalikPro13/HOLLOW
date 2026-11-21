import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/sound_service.dart';

/// Android cues go through the native `hollow/sfx` player: audioplayers'
/// Android side writes the GLOBAL audio mode (MODE_NORMAL) and turns the
/// speakerphone off whenever a player's audio context is set, which knocks a
/// live call out of communication mode and off the speaker (#154).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('hollow/sfx');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final originalPlayer = SoundService.newPlayer;
  final originalPlatform = SoundService.platform;
  late List<MethodCall> calls;
  late int playersMade;

  setUp(() {
    calls = [];
    playersMade = 0;
    SoundService.enabled = true;
    SoundService.volume = 0.4;
    SoundService.ringtoneVolume = 0.7;
    SoundService.newPlayer = () {
      playersMade++;
      return _SilentPlayer();
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() async {
    SoundService.instance.stopRingback();
    // Past the burst throttle, so the next test's cue of the same sound plays.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    messenger.setMockMethodCallHandler(channel, null);
    SoundService.newPlayer = originalPlayer;
    SoundService.platform = originalPlatform;
    SoundService.enabled = false;
  });

  test('on Android every cue, in a call or not, plays on the native player',
      () async {
    SoundService.platform = 'android';
    SoundService.instance.play(HollowSound.joinVoice, duringCall: true);
    SoundService.instance.play(HollowSound.toggle, duringCall: true);
    SoundService.instance.play(HollowSound.notification);
    await Future<void>.delayed(Duration.zero);

    expect(playersMade, 0, reason: 'audioplayers must never be touched');
    expect(calls.map((c) => c.method), ['play', 'play', 'play']);
    expect(calls.map((c) => (c.arguments as Map)['asset']), [
      'assets/sounds/join_voice.wav',
      'assets/sounds/mute_un_cam.wav',
      'assets/sounds/notification.wav',
    ]);
    expect((calls.first.arguments as Map)['volume'], 0.4);
  });

  test('on Android the ringback loops on the native player', () async {
    SoundService.platform = 'android';
    SoundService.instance.startRingback();
    SoundService.instance.startRingback();
    SoundService.instance.stopRingback();
    await Future<void>.delayed(Duration.zero);

    expect(playersMade, 0);
    expect(calls.map((c) => c.method), ['startLoop', 'stopLoop']);
    expect((calls.first.arguments as Map)['asset'],
        'assets/sounds/default_ringtone.wav');
    expect((calls.first.arguments as Map)['volume'], 0.7);
  });

  test('a desktop keeps audioplayers and never calls the native channel',
      () async {
    SoundService.platform = 'windows';
    SoundService.instance.play(HollowSound.leaveVoice, duringCall: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(playersMade, 1);
    expect(calls, isEmpty);
  });

  test('a missing native channel never throws out of a cue', () async {
    SoundService.platform = 'android';
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException();
    });
    expect(
      () => SoundService.instance.play(HollowSound.joinStream, duringCall: true),
      returnsNormally,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
}

class _SilentPlayer implements AudioPlayer {
  @override
  Future<void> setReleaseMode(ReleaseMode releaseMode) async {}

  @override
  Future<void> setAudioContext(AudioContext ctx) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<void> play(Source source,
      {double? volume,
      double? balance,
      AudioContext? ctx,
      Duration? position,
      PlayerMode? mode}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
