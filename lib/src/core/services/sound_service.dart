import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// The bundled UI sound pack (issue #55, sounds contributed by GitHub user
/// Rong-Yao — see `project_default_ringtone` for the provenance of the
/// ringtone that shipped first).
///
/// One asset per *event*, not per call site: the same "join" cue plays whether
/// it was you or somebody else who walked into the channel, which is what makes
/// it readable as a channel event rather than a button click.
enum HollowSound {
  /// You joined a voice channel, or somebody joined the one you are in.
  joinVoice('sounds/join_voice.wav'),

  /// You left a voice channel, or somebody left the one you are in.
  leaveVoice('sounds/leave_voice.wav'),

  /// A screen share started in the channel you are in (yours or a peer's).
  joinStream('sounds/join_stream.wav'),

  /// A screen share ended in the channel you are in (yours or a peer's).
  leaveStream('sounds/leave_stream.wav'),

  /// Local self-toggle: mute, deafen, camera. Never fires for a remote peer's
  /// toggle — that would turn a busy channel into a clicking metronome.
  toggle('sounds/mute_un_cam.wav'),

  /// A message notification surfaced in-app.
  notification('sounds/notification.wav');

  const HollowSound(this.asset);

  /// Path under `assets/` (audioplayers' AssetSource is rooted at `assets/`).
  final String asset;
}

/// Plays the short one-shot UI sounds, and the outgoing-call ringback.
///
/// Fire-and-forget by design: every entry point is a `void` that swallows its
/// own failures. A missing codec on some Linux box must never be able to take
/// down a channel join or a mute toggle with it.
class SoundService {
  SoundService._();

  static final SoundService instance = SoundService._();

  /// Mirrors `soundEffectsEnabledProvider` / `soundEffectsVolumeProvider`.
  ///
  /// Plain statics rather than a `ref` read: the hot call sites are inside
  /// notifiers that fire during teardown, where reaching back into the
  /// container is exactly the kind of thing that throws while disposing.
  /// The notifiers push their value here on load and on every change.
  static bool enabled = true;
  static double volume = 0.5;

  /// The incoming-call ringtone volume — the outgoing ringback rides the same
  /// slider, and is independent of the effects volume above.
  static double ringtoneVolume = 0.5;

  final Map<HollowSound, AudioPlayer> _players = {};
  final Map<HollowSound, DateTime> _lastPlayed = {};
  AudioPlayer? _ringback;

  /// Collapses a burst into one sound. Five peers joining at once (a channel
  /// filling up after a relay reconnect) must not stack five copies.
  static const Duration _minGap = Duration(milliseconds: 150);

  /// Non-intrusive playback: request no audio focus and mix with whatever is
  /// already playing, so a mute blip can never duck or interrupt call audio.
  static final AudioContext _context = AudioContextConfig(
    focus: AudioContextConfigFocus.mixWithOthers,
  ).build();

  /// Play [sound], unless sounds are off.
  ///
  /// Pass [duringCall] for any cue whose clip can still be playing while
  /// WebRTC owns the audio session — which includes the join cue, since that
  /// fires a beat before the mic opens and outlives it. On iOS those are
  /// dropped: audioplayers sets the shared AVAudioSession category when it
  /// starts and deactivates the session when it ends, and doing either to a
  /// live `playAndRecord`/VoiceProcessingIO session is how you lose the mic
  /// mid-sentence. Android and desktop take the no-focus context above and
  /// play everything. (Revisit once someone can test it on a real iPhone —
  /// nothing else here is platform-conditional.)
  void play(HollowSound sound, {bool duringCall = false}) {
    if (!enabled) return;
    if (duringCall && Platform.isIOS) return;

    final now = DateTime.now();
    final last = _lastPlayed[sound];
    if (last != null && now.difference(last) < _minGap) return;
    _lastPlayed[sound] = now;

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
      // Restart from the top: a rapid re-trigger past the throttle window
      // should re-play, not queue behind the tail of the previous one.
      await player.stop();
      await player.play(AssetSource(sound.asset), volume: volume);
    } catch (e) {
      debugPrint('[HOLLOW-SFX] ${sound.name} failed: $e');
    }
  }

  /// Start the looping outgoing-call ringback (you pressed Call and are
  /// waiting for the other side to pick up). Idempotent — a second start while
  /// already ringing is ignored rather than layering a second loop.
  void startRingback() {
    if (_ringback != null) return;
    final player = AudioPlayer(playerId: 'hollow-ringback');
    _ringback = player;
    unawaited(() async {
      try {
        await player.setReleaseMode(ReleaseMode.loop);
        await player.setAudioContext(_context);
        // Deliberately the BUNDLED ringtone, not the user's custom pick: the
        // custom one identifies an INCOMING call, and hearing your own alert
        // song back at you while dialling reads as a bug.
        await player.play(
          AssetSource('sounds/default_ringtone.wav'),
          volume: ringtoneVolume,
        );
      } catch (e) {
        debugPrint('[HOLLOW-SFX] ringback failed: $e');
      }
    }());
  }

  /// Stop the outgoing ringback. Safe to call when nothing is ringing — every
  /// call teardown path funnels through here.
  void stopRingback() {
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
