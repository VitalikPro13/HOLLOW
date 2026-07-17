import 'dart:io';
import 'dart:typed_data';

import 'mobile_screen_audio_renderer.dart';
import 'screen_audio_renderer.dart';

/// Common interface for the platform receivers of screen-share audio.
///
/// Desktop ([ScreenAudioRenderer]) decodes + plays via an out-of-process exe;
/// mobile ([MobileScreenAudioRenderer]) decodes Opus in Rust and plays via a
/// native media-path audio sink. Both consume the same data-channel payload
/// (`[seq:4 LE][opus_bytes...]`) and share the start/push/stop lifecycle, so
/// the call/voice-channel providers hold this interface and stay
/// platform-agnostic.
abstract class ScreenAudioReceiver {
  Future<bool> start();
  void pushPacket(Uint8List packet);
  Future<void> stop();

  /// Set the playback gain target (0.0..=1.0). The sink ramps toward it
  /// (fast down / slow up) so changes are click-free; driven by
  /// [ShareAudioLevel] (share-volume slider + voice-activity ducking +
  /// deafen), never called with raw UI values directly.
  void setGain(double gain);

  /// Pick the receiver for the current platform.
  factory ScreenAudioReceiver.forPlatform() {
    if (Platform.isAndroid || Platform.isIOS) {
      return _MobileAdapter(MobileScreenAudioRenderer());
    }
    return _DesktopAdapter(ScreenAudioRenderer());
  }
}

class _DesktopAdapter implements ScreenAudioReceiver {
  _DesktopAdapter(this._inner);
  final ScreenAudioRenderer _inner;

  @override
  Future<bool> start() => _inner.start();
  @override
  void pushPacket(Uint8List packet) => _inner.pushPacket(packet);
  @override
  Future<void> stop() => _inner.stop();
  @override
  void setGain(double gain) => _inner.setGain(gain);
}

class _MobileAdapter implements ScreenAudioReceiver {
  _MobileAdapter(this._inner);
  final MobileScreenAudioRenderer _inner;

  @override
  Future<bool> start() => _inner.start();
  @override
  void pushPacket(Uint8List packet) => _inner.pushPacket(packet);
  @override
  Future<void> stop() => _inner.stop();
  @override
  void setGain(double gain) => _inner.setGain(gain);
}
