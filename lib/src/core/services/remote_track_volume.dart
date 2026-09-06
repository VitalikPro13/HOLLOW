import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Sets the playback volume of a REMOTE audio track, tolerating tracks the
/// native registry cannot resolve: a receiver from a transceiver that never
/// carried media throws with nothing actually wrong, and unhandled that
/// aborted the caller's loop part-way through the mesh.
Future<void> setRemoteTrackVolume(double volume, MediaStreamTrack track) async {
  try {
    await Helper.setVolume(volume, track);
  } catch (e) {
    debugPrint('[HOLLOW-AUDIO] setVolume skipped for ${track.id}: $e');
  }
}
