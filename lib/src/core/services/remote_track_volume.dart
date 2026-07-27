import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Set the playback volume of a REMOTE audio track, tolerating tracks the
/// native side can't resolve.
///
/// `Helper.setVolume` looks the track up in the platform's registry, which only
/// holds local tracks plus remote tracks that arrived attached to a stream. A
/// receiver from a transceiver that never carried media has a track object on
/// the Dart side but no native entry, so the call comes back as
/// `PlatformException(setVolume, setVolume() Unable to find provided track)`.
/// Nothing is wrong with the call — there is simply nothing to turn down — but
/// left unhandled it aborted the caller's loop (deafen stopped part-way through
/// the mesh) and surfaced as a platform error in the crash log.
Future<void> setRemoteTrackVolume(double volume, MediaStreamTrack track) async {
  try {
    await Helper.setVolume(volume, track);
  } catch (e) {
    debugPrint('[HOLLOW-AUDIO] setVolume skipped for ${track.id}: $e');
  }
}
