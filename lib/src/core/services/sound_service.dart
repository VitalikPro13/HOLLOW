import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The bundled UI sound pack (issue #55, sounds contributed by GitHub user
/// Rong-Yao; `project_default_ringtone` carries the ringtone's provenance).
///
/// One asset per EVENT, not per call site: the same "join" cue plays whether
/// it was you or somebody else, so it reads as a channel event.
enum HollowSound {
  /// You joined a voice channel, or somebody joined the one you are in.
  joinVoice('sounds/join_voice.wav'),

  /// You left a voice channel, or somebody left the one you are in.
  leaveVoice('sounds/leave_voice.wav'),

  /// A screen share started in the channel you are in (yours or a peer's).
  joinStream('sounds/join_stream.wav'),

  /// A screen share ended in the channel you are in (yours or a peer's).
  leaveStream('sounds/leave_stream.wav'),

  /// Local self-toggle: mute, deafen, camera. Never a remote peer's toggle,
  /// which would turn a busy channel into a clicking metronome.
  toggle('sounds/mute_un_cam.wav'),

  /// A message notification surfaced in-app.
  notification('sounds/notification.wav');

  const HollowSound(this.asset);

  /// Path under `assets/` (audioplayers' AssetSource is rooted at `assets/`).
  final String asset;
}

/// Plays the short one-shot UI sounds and the outgoing-call ringback.
///
/// Fire-and-forget by design: every entry point is a `void` that swallows its
/// own failures, so a missing codec cannot take a channel join down with it.
class SoundService {
  SoundService._();

  static final SoundService instance = SoundService._();

  /// Mirrors `soundEffectsEnabledProvider` / `soundEffectsVolumeProvider`, as
  /// plain statics rather than a `ref` read: the hot call sites are inside
  /// notifiers that fire during teardown, where reaching back into the
  /// container is exactly the kind of thing that throws while disposing.
  static bool enabled = true;
  static double volume = 0.5;

  /// Incoming-call ringtone volume; the outgoing ringback rides the same
  /// slider, independent of the effects volume above.
  static double ringtoneVolume = 0.5;

  final Map<HollowSound, AudioPlayer> _players = {};
  final Map<HollowSound, DateTime> _lastPlayed = {};
  AudioPlayer? _ringback;

  /// Ringback idempotence lives here, not on [_ringback], null on native.
  bool _ringbackOn = false;

  /// Collapses a burst into one sound. Five peers joining at once (a channel
  /// filling up after a relay reconnect) must not stack five copies.
  static const Duration _minGap = Duration(milliseconds: 150);

  /// Non-intrusive playback: request no audio focus and mix with whatever is
  /// already playing, so a mute blip can never duck or interrupt call audio.
  static final AudioContext _context = AudioContextConfig(
    focus: AudioContextConfigFocus.mixWithOthers,
  ).build();

  /// iOS-only native player (`HollowSfxPlayer` in `ios/Runner/AppDelegate.swift`).
  ///
  /// audioplayers is unusable for in-call cues on iOS: it applies the shared
  /// `AVAudioSession` CATEGORY when a player's context is set and calls
  /// `setActive(false)` when its last player stops, and either one aimed at a
  /// live `playAndRecord` session takes the mic down mid-sentence. AVAudioPlayer
  /// plays into whatever session exists and never reconfigures it.
  static const MethodChannel _iosSfx = MethodChannel('hollow/sfx');

  /// Route this platform's playback through the native player.
  static bool get _useNative => Platform.isIOS;

  void _invokeNative(String method, [Map<String, dynamic>? args]) {
    unawaited(_iosSfx.invokeMethod<void>(method, args).catchError((e) {
      // Fire-and-forget: a missing channel (an older Runner) must not take
      // down a channel join, and a sync try/catch would not catch this.
      debugPrint('[HOLLOW-SFX] native $method failed: $e');
    }));
  }

  /// Plays [sound], unless sounds are off.
  ///
  /// [duringCall] marks a cue whose clip can still be playing while WebRTC
  /// owns the audio session, the join cue included since it fires a beat
  /// before the mic opens. On iOS that means "do not activate the session";
  /// elsewhere every cue plays on the no-focus context above.
  void play(HollowSound sound, {bool duringCall = false}) {
    if (!enabled) return;

    final now = DateTime.now();
    final last = _lastPlayed[sound];
    if (last != null && now.difference(last) < _minGap) return;
    _lastPlayed[sound] = now;

    if (_useNative) {
      _invokeNative('play', {
        // The native lookup wants the full Flutter asset key.
        'asset': 'assets/${sound.asset}',
        'volume': volume,
        'activateSession': !duringCall,
      });
      return;
    }
    unawaited(_play(sound));
  }

  Future<void> _play(HollowSound sound) async {
    try {
      var player = _players[sound];
      if (player == null) {
        player = AudioPlayer(playerId: 'hollow-sfx-${sound.name}');
        await player.setReleaseMode(ReleaseMode.stop);
        await player.setAudioContext(_context);
        _players[sound] = player;
      }
      // Restart from the top: a re-trigger past the throttle should re-play,
      // not queue behind the tail of the previous one.
      await player.stop();
      await player.play(AssetSource(sound.asset), volume: volume);
    } catch (e) {
      debugPrint('[HOLLOW-SFX] ${sound.name} failed: $e');
    }
  }

  /// Starts the looping outgoing-call ringback. Idempotent: a second start
  /// while already ringing is ignored rather than layering a second loop.
  void startRingback() {
    if (_ringbackOn) return;
    _ringbackOn = true;
    if (_useNative) {
      // Matters more here than for the one-shots: the ringback runs right
      // through call setup, so letting audioplayers restate the session
      // category there was a standing risk to the outgoing mic.
      _invokeNative('startLoop', {
        'asset': 'assets/sounds/default_ringtone.wav',
        'volume': ringtoneVolume,
        // Nothing owns the session yet while we're dialling.
        'activateSession': true,
      });
      return;
    }
    final player = AudioPlayer(playerId: 'hollow-ringback');
    _ringback = player;
    unawaited(() async {
      try {
        await player.setReleaseMode(ReleaseMode.loop);
        await player.setAudioContext(_context);
        // Deliberately the BUNDLED ringtone, not the user's pick: the custom
        // one identifies an INCOMING call, and hearing it back while
        // dialling reads as a bug.
        await player.play(
          AssetSource('sounds/default_ringtone.wav'),
          volume: ringtoneVolume,
        );
      } catch (e) {
        debugPrint('[HOLLOW-SFX] ringback failed: $e');
      }
    }());
  }

  /// Stops the outgoing ringback. Safe to call when nothing is ringing.
  void stopRingback() {
    if (!_ringbackOn) return;
    _ringbackOn = false;
    if (_useNative) {
      _invokeNative('stopLoop');
      return;
    }
    final player = _ringback;
    if (player == null) return;
    _ringback = null;
    unawaited(() async {
      try {
        await player.stop();
        await player.dispose();
      } catch (_) {}
    }());
  }
}
