import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hollow/src/core/android_platform.dart';

/// Android version detection for screen-share-audio gating.
///
/// SENDING system audio needs `AudioPlaybackCapture` (API 29, Android 10) and
/// the native guard silently returns false below that, so the UI must lock
/// the toggle rather than promise audio that never arrives. Video share and
/// RECEIVE of shared audio work on every supported version.
///
/// `SDK_INT` is not exposed by `dart:io`, so it comes over the platform
/// channel and is cached: call [prime] at startup so the getters are ready.
class AndroidScreenAudioSupport {
  /// API 29 = Android 10 (Q), the AudioPlaybackCapture floor.
  static const int _audioCaptureApi = 29;

  /// Fetches and caches `Build.VERSION.SDK_INT`. No-op off Android.
  static Future<void> prime() async {
    if (kIsWeb || !Platform.isAndroid) return;
    await androidSdkInt();
  }

  /// The cached API level, or null off Android / before [prime] resolves.
  static int? get sdkInt => androidSdkIntCached;

  /// Whether this device can SEND screen-share audio (Android 10+). Unknown
  /// fails OPEN, since the native guard is the real backstop.
  static bool get canSendScreenAudio {
    if (!Platform.isAndroid) return false;
    final v = sdkInt;
    if (v == null) return true;
    return v >= _audioCaptureApi;
  }

  /// True on an Android that can share a screen but CANNOT send audio (7.0
  /// to 9), which locks the audio toggle. Fails closed on unknown so a
  /// "locked" state never flashes on a version we have not read yet.
  static bool get audioSendBlockedByOldOs {
    if (!Platform.isAndroid) return false;
    final v = sdkInt;
    if (v == null) return false;
    return v < _audioCaptureApi;
  }
}
