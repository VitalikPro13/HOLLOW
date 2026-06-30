import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../rust/api/network.dart' as network_api;
import '../../rust/api/screen_audio.dart' as screen_audio_api;

void _log(String msg) {
  network_api.logFromDart(message: msg);
}

/// Mobile (Android/iOS) renderer for RECEIVED screen-share audio.
///
/// The desktop [ScreenAudioRenderer] spawns an out-of-process exe that decodes
/// Opus + plays it via the OS audio API. A phone can't spawn a child process,
/// so this sibling decodes each Opus packet in Rust ([screen_audio_api]) and
/// streams the resulting PCM to a native player on the MEDIA output path
/// (`Helper.startScreenAudioPlayer` → Android AudioTrack / iOS AudioQueue),
/// deliberately OUTSIDE the WebRTC voice session so the call's AEC/AGC can't
/// mangle the shared music.
///
/// Data-channel payload handed to us is `[seq:4 LE][opus_bytes...]`; we strip
/// the 4-byte sequence and hand the bare Opus packet to the decoder (the seq
/// is unused — the data channel is reliable + ordered, same as desktop).
///
/// Decoding is async (FFI), so packets are decoded through a single serial
/// chain to preserve order. If the decode backlog grows (a stall), newer
/// packets are dropped — a real-time stream prefers a dropped packet over
/// unbounded latency, matching the desktop ring-buffer's overrun behavior.
class MobileScreenAudioRenderer {
  bool _active = false;
  bool _starting = false;
  int _packetCount = 0;
  int _droppedBacklog = 0;

  /// Serial tail: each decode awaits the previous so PCM is written in order.
  Future<void> _decodeChain = Future<void>.value();

  /// Number of packets currently queued behind the decode chain. Bounded so a
  /// decode stall can't accumulate unbounded latency/memory.
  int _pending = 0;
  static const int _kMaxPendingDecodes = 32;

  bool get isActive => _active;

  Future<bool> start() async {
    if (_active) return true;
    if (_starting) return false;
    _starting = true;
    try {
      await Helper.startScreenAudioPlayer();
      // Reset the Rust decoder so leftover inter-packet state from a previous
      // share session doesn't corrupt the first frames of this one.
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
