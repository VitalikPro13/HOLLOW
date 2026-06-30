import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:webrtc_interface/webrtc_interface.dart';

import 'media_stream_track_impl.dart';
import 'utils.dart';

class NativeAudioManagement {
  static Future<void> selectAudioInput(String deviceId) async {
    await WebRTC.invokeMethod(
      'selectAudioInput',
      <String, dynamic>{'deviceId': deviceId},
    );
  }

  static Future<void> setSpeakerphoneOn(bool enable) async {
    await WebRTC.invokeMethod(
      'enableSpeakerphone',
      <String, dynamic>{'enable': enable},
    );
  }

  static Future<void> ensureAudioSession() async {
    await WebRTC.invokeMethod('ensureAudioSession');
  }

  static Future<void> setSpeakerphoneOnButPreferBluetooth() async {
    await WebRTC.invokeMethod('enableSpeakerphoneButPreferBluetooth');
  }

  static Future<void> setVolume(double volume, MediaStreamTrack track) async {
    if (track.kind == 'audio') {
      if (kIsWeb) {
        final constraints = track.getConstraints();
        constraints['volume'] = volume;
        await track.applyConstraints(constraints);
      } else {
        await WebRTC.invokeMethod('setVolume', <String, dynamic>{
          'trackId': track.id,
          'volume': volume,
          'peerConnectionId':
              track is MediaStreamTrackNative ? track.peerConnectionId : null
        });
      }
    }

    return Future.value();
  }

  /// Set the post-APM capture makeup gain (Hollow fork addition).
  ///
  /// Drives a native capture-post-processor that runs AFTER WebRTC's
  /// AGC/NS/EC on the local microphone, applying makeup gain followed by a
  /// soft limiter (~-3 dBFS ceiling). [gain] is a linear multiplier
  /// (1.0 = transparent). Process-global: affects every local audio track,
  /// so a single call covers both DM calls and server voice channels. No-op
  /// on web (no native APM hook).
  static Future<void> setCaptureGain(double gain) async {
    if (kIsWeb) return;
    await WebRTC.invokeMethod('setCaptureGain', <String, dynamic>{
      'gain': gain,
    });
  }

  /// Start a native PCM player for received screen-share audio (Hollow fork,
  /// mobile). Plays raw 48 kHz stereo int16 PCM on the MEDIA output path —
  /// deliberately OUTSIDE the WebRTC voice session, so the call's AEC/AGC/
  /// speech processing can't mangle the shared music. Desktop uses an
  /// out-of-process renderer exe instead; this is the Android/iOS sibling.
  /// No-op on web.
  static Future<void> startScreenAudioPlayer() async {
    if (kIsWeb) return;
    await WebRTC.invokeMethod('startScreenAudioPlayer');
  }

  /// Feed one decoded PCM buffer (interleaved 48 kHz stereo signed-16-bit LE)
  /// to the native screen-audio player started by [startScreenAudioPlayer].
  /// No-op on web. Safe to call before start (dropped natively).
  static Future<void> writeScreenAudioPcm(Uint8List pcm) async {
    if (kIsWeb) return;
    await WebRTC.invokeMethod('writeScreenAudioPcm', <String, dynamic>{
      'pcm': pcm,
    });
  }

  /// Stop and release the native screen-audio player. No-op on web.
  static Future<void> stopScreenAudioPlayer() async {
    if (kIsWeb) return;
    await WebRTC.invokeMethod('stopScreenAudioPlayer');
  }

  static Future<void> setMicrophoneMute(
      bool mute, MediaStreamTrack track) async {
    if (track.kind != 'audio') {
      throw 'The is not an audio track => $track';
    }

    if (!kIsWeb) {
      try {
        await WebRTC.invokeMethod(
          'setMicrophoneMute',
          <String, dynamic>{'trackId': track.id, 'mute': mute},
        );
      } on PlatformException catch (e) {
        throw 'Unable to MediaStreamTrack::setMicrophoneMute: ${e.message}';
      }
    }
    track.enabled = !mute;
  }

  // ADM APIs
  static Future<void> startLocalRecording() async {
    if (!kIsWeb) {
      try {
        await WebRTC.invokeMethod(
          'startLocalRecording',
          <String, dynamic>{},
        );
      } on PlatformException catch (e) {
        throw 'Unable to start local recording: ${e.message}';
      }
    }
  }

  static Future<void> stopLocalRecording() async {
    if (!kIsWeb) {
      try {
        await WebRTC.invokeMethod(
          'stopLocalRecording',
          <String, dynamic>{},
        );
      } on PlatformException catch (e) {
        throw 'Unable to stop local recording: ${e.message}';
      }
    }
  }

  static Future<bool> isVoiceProcessingEnabled() async {
    if (kIsWeb) return false;

    try {
      final result = await WebRTC.invokeMethod(
        'isVoiceProcessingEnabled',
        <String, dynamic>{},
      );
      return result as bool;
    } on PlatformException catch (e) {
      throw 'Unable to get isVoiceProcessingEnabled: ${e.message}';
    }
  }

  static Future<bool> isVoiceProcessingBypassed() async {
    if (kIsWeb) return false;

    try {
      final result = await WebRTC.invokeMethod(
        'isVoiceProcessingBypassed',
        <String, dynamic>{},
      );
      return result as bool;
    } on PlatformException catch (e) {
      throw 'Unable to get isVoiceProcessingBypassed: ${e.message}';
    }
  }

  static Future<void> setIsVoiceProcessingBypassed(bool value) async {
    if (kIsWeb) return;

    try {
      await WebRTC.invokeMethod(
        'setIsVoiceProcessingBypassed',
        <String, dynamic>{"value": value},
      );
    } on PlatformException catch (e) {
      throw 'Unable to set isVoiceProcessingBypassed: ${e.message}';
    }
  }
}
