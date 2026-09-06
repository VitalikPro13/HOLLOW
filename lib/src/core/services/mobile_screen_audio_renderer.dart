import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../rust/api/network.dart' as network_api;
import '../../rust/api/screen_audio.dart' as screen_audio_api;

void _log(String msg) {
  network_api.logFromDart(message: msg);
}

/// Mobile (Android/iOS) renderer for RECEIVED screen-share audio.
///
/// A phone cannot spawn the child process the desktop renderer uses, so this
/// sibling decodes each Opus packet in Rust and streams the PCM to a native
/// player on the MEDIA output path, deliberately OUTSIDE the WebRTC voice
/// session so the call's AEC and AGC cannot mangle the shared music.
///
/// The data-channel payload is `[seq:4 LE][opus_bytes...]`; the sequence is
/// stripped and unused, since the channel is reliable and ordered. Decoding is
/// async FFI, so packets go through a single serial chain to preserve order,
/// and newer packets are dropped once the backlog grows: a real-time stream
/// prefers a dropped packet over unbounded latency.
class MobileScreenAudioRenderer {
  bool _active = false;
  bool _starting = false;
  int _packetCount = 0;
  int _droppedBacklog = 0;

  /// Serial tail: each decode awaits the previous so PCM is written in order.
  Future<void> _decodeChain = Future<void>.value();

  /// Packets currently queued behind the decode chain. Bounded so a decode
  /// stall cannot accumulate unbounded latency or memory.
  int _pending = 0;
  static const int _kMaxPendingDecodes = 32;

  bool get isActive => _active;

  /// Sets the playback gain target (0.0..=1.0); the Rust decoder ramps toward
  /// it click-free. Fire-and-forget FFI, so a rejection must not escape to the
  /// zone handler.
  void setGain(double gain) {
    screen_audio_api
        .setScreenAudioGain(gain: gain.clamp(0.0, 1.0).toDouble())
        .catchError((_) {});
  }

  Future<bool> start() async {
    if (_active) return true;
    if (_starting) return false;
    _starting = true;
    try {
      await Helper.startScreenAudioPlayer();
      // Reset the Rust decoder so leftover inter-packet state from a previous
      // share session cannot corrupt the first frames of this one.
      await screen_audio_api.resetScreenAudioDecoder();
      _active = true;
      _packetCount = 0;
      _droppedBacklog = 0;
      _decodeChain = Future<void>.value();
      _pending = 0;
      _log('[SCREEN-AUDIO-MOBILE] Started native player');
      return true;
    } catch (e) {
      _log('[SCREEN-AUDIO-MOBILE] start failed: $e');
      _active = false;
      return false;
    } finally {
      _starting = false;
    }
  }

  /// Feed a received data-channel packet: `[seq:4 LE][opus_bytes...]`.
  void pushPacket(Uint8List packet) {
    if (!_active) return;
    if (packet.length <= 4) return; // no opus payload

    // Drop if the decode chain is backed up (stall guard).
    if (_pending >= _kMaxPendingDecodes) {
      _droppedBacklog++;
      if (_droppedBacklog <= 5 || _droppedBacklog % 250 == 0) {
        _log('[SCREEN-AUDIO-MOBILE] decode backlog full, dropped '
            '#$_droppedBacklog');
      }
      return;
    }

    // Strip the 4-byte sequence prefix; copy out the bare Opus packet.
    final opus = Uint8List.sublistView(packet, 4);

    _pending++;
    _decodeChain = _decodeChain.then((_) async {
      if (!_active) return;
      try {
        final pcm = await screen_audio_api.decodeScreenAudio(opus: opus);
        if (!_active || pcm.isEmpty) return;
        await Helper.writeScreenAudioPcm(pcm);
        _packetCount++;
        if (_packetCount <= 5 || _packetCount % 500 == 0) {
          _log('[SCREEN-AUDIO-MOBILE] Played packet #$_packetCount');
        }
      } catch (e) {
        if (_packetCount <= 5) {
          _log('[SCREEN-AUDIO-MOBILE] decode/play error: $e');
        }
      }
    }).whenComplete(() {
      _pending--;
    });
  }

  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    _log('[SCREEN-AUDIO-MOBILE] Stopping (played $_packetCount packets)');
    // Let the in-flight decode chain settle, then tear down the native player.
    try {
      await _decodeChain;
    } catch (_) {}
    try {
      await Helper.stopScreenAudioPlayer();
    } catch (e) {
      _log('[SCREEN-AUDIO-MOBILE] stop error: $e');
    }
  }
}
