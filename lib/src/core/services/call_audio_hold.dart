import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Android call audio (audio mode, focus and the microphone foreground
/// service) held by a DM call or voice room from the moment the person commits
/// to it until it ends, across media rebuilds and room-to-call handovers that
/// drop every track and connection for seconds. The fork also holds for each
/// mic track and audio connection; this covers the gaps between them, where a
/// lost foreground service could not start again from the background.
class CallAudioHold {
  CallAudioHold._();

  static final _held = <String>{};

  @visibleForTesting
  static bool? debugAndroidOverride;

  static bool get _enabled =>
      debugAndroidOverride ?? (!kIsWeb && Platform.isAndroid);

  static Set<String> get held => Set.unmodifiable(_held);

  /// Every acquire reaches the fork, held or not: it retries a foreground
  /// service the system refused earlier.
  static void acquire(String key) {
    if (!_enabled) return;
    _held.add(key);
    unawaited(Helper.holdCallAudioKey(key).catchError((_) {}));
  }

  /// Safe when [key] was never held: teardown paths run on failures too.
  static void release(String key) {
    if (!_enabled || !_held.remove(key)) return;
    unawaited(Helper.releaseCallAudioKey(key).catchError((_) {}));
  }

  @visibleForTesting
  static void debugReset() => _held.clear();
}
