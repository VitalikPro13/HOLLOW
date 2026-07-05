import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hollow/src/core/android_platform.dart';

/// Android version detection + screen-share-audio capability gating.
///
/// System-audio CAPTURE (for SENDING shared audio) uses the
/// `AudioPlaybackCapture` API, which requires Android 10 (API 29 / "Q"). Below
/// that the native layer's `Build.VERSION.SDK_INT >= Q` guard silently returns
/// false, so the audio toggle must be locked in the UI to avoid promising audio
/// that will never arrive.
///
/// Screen VIDEO share works on every supported version (minSdk 24 / Android
/// 7.0), and RECEIVE of shared audio works everywhere via the native decoder.
/// Only SENDING system audio is gated.
///
/// `Build.VERSION.SDK_INT` is NOT exposed by `dart:io` (unlike macOS, whose
/// version we parse from `Platform.operatingSystemVersion`), so it's fetched
/// over the platform channel and cached. Call [prime] once at startup so the
/// synchronous getters below are ready when the share sheet opens.
class AndroidScreenAudioSupport {
  /// API 29 = Android 10 (Q) — the AudioPlaybackCapture floor.
  static const int _audioCaptureApi = 29;

  /// Fetch + cache `Build.VERSION.SDK_INT`. Cheap to call repeatedly (cached
  /// after the first success). No-op off Android.
  static Future<void> prime() async {
    if (kIsWeb || !Platform.isAndroid) return;
    await androidSdkInt();
  }

  /// The cached API level, or null off Android / before [prime] resolves.
  static int? get sdkInt => androidSdkIntCached;

  /// Whether this device can SEND screen-share audio (Android 10+). Unknown
  /// (cache not yet primed) fails OPEN — the native guard is the real backstop.
  static bool get canSendScreenAudio {
    if (!Platform.isAndroid) return false;
    final v = sdkInt;
    if (v == null) return true; // unknown -> fail open, native guard still applies
    return v >= _audioCaptureApi;
  }

  /// True when the user is on an Android that can share a screen but CANNOT
  /// send audio (7.0–9) — used to lock the audio toggle + show a warning.
  /// Fails closed on unknown so we don't flash a "locked" state incorrectly:
  /// only blocks when we KNOW the version is too old.
  static bool get audioSendBlockedByOldOs {
    if (!Platform.isAndroid) return false;
    final v = sdkInt;
    if (v == null) return false; // unknown -> don't lock (let native guard decide)
    return v < _audioCaptureApi;
  }
}
