import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Sets the playback volume of ONE received voice, named by its connection
/// and receiver, never by its track id: the sender writes that id, and a
/// lookup by it reached our own microphone or another member (HOL-SEC-190).
///
/// A failure is logged and swallowed (false) so one dead connection never
/// aborts the caller's loop part-way through the mesh.
Future<bool> setRemoteReceiverVolume(
    double volume, RTCRtpReceiver receiver) async {
  try {
    await Helper.setReceiverVolume(volume, receiver);
    return true;
  } catch (e) {
    debugPrint('[HOLLOW-AUDIO] setVolume skipped for '
        '${receiver.receiverId}: $e');
    return false;
  }
}
