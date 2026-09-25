import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';

/// The incoming-call ringtone: the user's trimmed clip looped over its range,
/// else the bundled default looped whole. One per incoming surface (the
/// desktop card, the phone's full screen).
class CallRingtone {
  AudioPlayer? _player;
  bool _wanted = false;

  /// [stillRinging] is asked after the settings load: the call may have been
  /// answered or declined meanwhile.
  Future<void> start(WidgetRef ref, {required bool Function() stillRinging}) async {
    _wanted = true;
    final String? path;
    final double volume, startSec, endSec;
    try {
      path = await ref.read(ringtonePathProvider.future);
      volume = await ref.read(ringtoneVolumeProvider.future);
      startSec = await ref.read(ringtoneStartProvider.future);
      endSec = await ref.read(ringtoneEndProvider.future);
    } catch (_) {
      // Settings unreadable (no store yet): the card still shows, silently.
      return;
    }
    if (!_wanted || !stillRinging() || _player != null) return;

    final hasCustom =
        path != null && path.isNotEmpty && File(path).existsSync();
    final player = AudioPlayer();
    _player = player;
    // A stop() racing these awaits disposes the player under them.
    try {
      await player.setVolume(volume);
      if (!hasCustom || endSec - startSec <= 0) {
        // The bundled default loops the whole file: no trim range applies.
        await player.setReleaseMode(ReleaseMode.loop);
        await player.play(AssetSource('sounds/default_ringtone.wav'));
        return;
      }
      // Looping is manual, within the clip range.
      final from = Duration(milliseconds: (startSec * 1000).round());
      await player.play(DeviceFileSource(path));
      await player.seek(from);
      player.onPositionChanged.listen((pos) {
        final at = pos.inMilliseconds / 1000.0;
        if (at >= endSec || at < startSec - 0.5) player.seek(from);
      });
    } catch (_) {}
  }

  Future<void> stop() async {
    _wanted = false;
    final player = _player;
    _player = null;
    await player?.stop();
    await player?.dispose();
  }
}
