import 'dart:async';

import 'package:flutter/services.dart';

import '../../rust/api/network.dart' as network_api;
import '../../rust/api/screen_audio.dart' as screen_audio_api;
import '../perf_sentinel.dart';

void _log(String msg) {
  network_api.logFromDart(message: msg);
}

/// Mobile (Android/iOS) screen-share-audio SEND path — the encode mirror of
/// `MobileScreenAudioRenderer`.
///
/// Desktop spawns an out-of-process `screen_audio_capturer` exe to capture +
/// Opus-encode system audio; a phone can't spawn a child process, so native
/// capture streams raw PCM to Dart and the encode happens in Rust
/// (`unsafe-libopus`, no NDK) via `encode_screen_audio`.
///
/// Native capture front-ends (both deliver interleaved 48 kHz stereo s16le on
/// the `FlutterWebRTC/ScreenShareAudio` EventChannel — the same contract the
/// macOS SCK send path uses):
///  - Android: `AudioPlaybackCapture` riding the screen share's live
///    MediaProjection (`startScreenShareAudioCapture`). The mic path is
///    untouched — the user talks over the shared audio.
///  - iOS: the ReplayKit broadcast extension's app-audio samples, forwarded
///    by the plugin from the app-group socket.
///
/// Pipeline:
///   native capture --PCM--> EventChannel --> this --FFI--> Rust Opus encode
///     --> onPacket([seq:4 LE][opus]) --> sendScreenAudio (0x03 data channel)
class MobileScreenAudioCapturer {
  static const MethodChannel _method = MethodChannel('FlutterWebRTC.Method');
  static const EventChannel _pcmChannel =
      EventChannel('FlutterWebRTC/ScreenShareAudio');

  StreamSubscription? _pcmSub;
  bool _active = false;
  int _pcmChunks = 0;
  int _packetCount = 0;
  int _dropped = 0;

  // Encode FFI calls are async; a serial chain preserves PCM order (Opus is
  // stateful — out-of-order frames corrupt the prediction state).
  Future<void> _encodeChain = Future.value();
  int _pending = 0;

  // If the encode chain backs up (device stall), drop incoming PCM instead of
  // queueing unbounded — mirrors the receive path's backlog guard.
  static const int _kMaxPendingEncodes = 32;

  bool get isActive => _active;

  /// Start native capture + the Rust encoder. Wire packets `[seq:4 LE][opus]`
  /// are delivered via [onPacket], ready to prefix with 0x03 for the data
  /// channel. Returns false when native capture can't start (no live screen
  /// share projection, Android < 10, permission missing).
  Future<bool> start({
    required void Function(Uint8List packet) onPacket,
  }) async {
    if (_active) return true;

    try {
      await screen_audio_api.resetScreenAudioEncoder();
    } catch (e) {
      _log('[MOBILE-AU-SCREEN] encoder init failed: $e');
      return false;
    }

    // Subscribe BEFORE starting native capture so no leading PCM is lost.
    _pcmChunks = 0;
    _packetCount = 0;
    _dropped = 0;
    _pcmSub = _pcmChannel.receiveBroadcastStream().listen((event) {
      if (!_active || event is! Uint8List) return;
      _feedPcm(event, onPacket);
    }, onError: (e) => _log('[MOBILE-AU-SCREEN] PCM stream error: $e'));

    bool ok = false;
    try {
      ok = await PerfSentinel.timedChannelCall<bool>(
              _method, 'startScreenShareAudioCapture') ??
          false;
    } catch (e) {
      _log('[MOBILE-AU-SCREEN] native capture start failed: $e');
    }
    if (!ok) {
      _log('[MOBILE-AU-SCREEN] Native capture unavailable');
      await _pcmSub?.cancel();
      _pcmSub = null;
      return false;
    }

    _active = true;
    _log('[MOBILE-AU-SCREEN] Capture started');
    return true;
  }

  void _feedPcm(Uint8List pcm, void Function(Uint8List) onPacket) {
    if (_pending >= _kMaxPendingEncodes) {
      _dropped++;
      if (_dropped <= 3 || _dropped % 200 == 0) {
        _log('[MOBILE-AU-SCREEN] encode backlog, dropped $_dropped chunks');
      }
      return;
    }
    _pending++;
    _encodeChain = _encodeChain.then((_) async {
      try {
        final packets = await screen_audio_api.encodeScreenAudio(pcm: pcm);
        if (!_active) return;
        for (final packet in packets) {
          onPacket(packet);
          _packetCount++;
          if (_packetCount <= 5 || _packetCount % 500 == 0) {
            _log('[MOBILE-AU-SCREEN] TX packet #$_packetCount '
                '(${packet.length} bytes)');
          }
        }
      } catch (e) {
        if (_packetCount <= 5) _log('[MOBILE-AU-SCREEN] encode failed: $e');
      } finally {
        _pending--;
      }
    });
    _pcmChunks++;
    if (_pcmChunks <= 5 || _pcmChunks % 500 == 0) {
      _log('[MOBILE-AU-SCREEN] Fed PCM chunk #$_pcmChunks (${pcm.length} bytes)');
    }
  }

  Future<void> stop() async {
    if (!_active && _pcmSub == null) return;
    _active = false;
    _log('[MOBILE-AU-SCREEN] Stopping...');
    try {
      await PerfSentinel.timedChannelCall<void>(
          _method, 'stopScreenShareAudioCapture');
    } catch (_) {}
    await _pcmSub?.cancel();
    _pcmSub = null;
    // Let in-flight encodes settle, then free the Rust encoder state.
    try {
      await _encodeChain;
    } catch (_) {}
    try {
      await screen_audio_api.stopScreenAudioEncoder();
    } catch (_) {}
    _log('[MOBILE-AU-SCREEN] Stopped ($_packetCount packets, '
        '$_dropped dropped chunks)');
  }
}
