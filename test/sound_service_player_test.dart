import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/sound_service.dart';

/// A player whose setup waits on [ready], like a native create that answers
/// late while the platform thread is busy closing a peer connection.
class _FakePlayer implements AudioPlayer {
  _FakePlayer(this.ready);

  final Future<void> ready;
  int plays = 0;
  bool disposed = false;

  /// Calls that reached this player after it was disposed.
  int callsAfterDispose = 0;

  void _touch() {
    if (disposed) callsAfterDispose++;
  }

  @override
  Future<void> setReleaseMode(ReleaseMode releaseMode) async {
    _touch();
    await ready;
  }

  @override
  Future<void> setAudioContext(AudioContext ctx) async => _touch();

  @override
  Future<void> stop() async => _touch();

  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  Future<void> play(Source source,
      {double? volume,
      double? balance,
      AudioContext? ctx,
      Duration? position,
      PlayerMode? mode}) async {
    _touch();
    plays++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late List<_FakePlayer> made;
  late Completer<void> ready;
  final original = SoundService.newPlayer;

  setUp(() {
    made = [];
    ready = Completer<void>();
    SoundService.enabled = true;
    SoundService.newPlayer = () {
      final player = _FakePlayer(ready.future);
      made.add(player);
      return player;
    };
  });

  tearDown(() {
    SoundService.newPlayer = original;
    SoundService.enabled = false;
  });

  test('two cues of a sound whose player is still being made share one player',
      () async {
    // A peer's leave arrives twice (MLS, then the plaintext copy), past the
    // burst throttle but before the first cue's player has finished setup.
    SoundService.instance.play(HollowSound.leaveVoice, duringCall: true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    SoundService.instance.play(HollowSound.leaveVoice, duringCall: true);
    ready.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(made, hasLength(1));
    expect(made.single.plays, 2);
  });

  test('a player whose setup failed is made afresh by the next cue', () async {
    SoundService.instance.play(HollowSound.joinStream);
    ready.completeError(StateError('no codec'));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(made, hasLength(1));
    expect(made.single.plays, 0);

    ready = Completer<void>()..complete();
    SoundService.instance.play(HollowSound.joinStream);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(made, hasLength(2));
    expect(made.last.plays, 1);
  });

  test('a player whose setup failed is disposed', () async {
    SoundService.instance.play(HollowSound.leaveStream);
    ready.completeError(StateError('no codec'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(made.single.disposed, isTrue);
  });

  test('a ringback stopped mid-setup is disposed after its setup, and a '
      'restart gets a fresh player', () async {
    final first = Completer<void>();
    ready = first;
    SoundService.instance.startRingback();
    SoundService.instance.stopRingback();
    ready = Completer<void>()..complete();
    SoundService.instance.startRingback();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(made, hasLength(2));
    expect(made.first.disposed, isFalse);

    first.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(made.first.disposed, isTrue);
    expect(made.first.callsAfterDispose, 0);
    expect(made.last.disposed, isFalse);

    SoundService.instance.stopRingback();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(made.last.disposed, isTrue);
  });
}
