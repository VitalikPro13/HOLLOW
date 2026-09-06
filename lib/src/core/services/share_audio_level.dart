import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'screen_audio_receiver.dart';

/// Process-global level control for RECEIVED screen-share audio.
///
/// Share audio is raw mastered content (music at -14 LUFS or hotter) while
/// the voice chain converges near -16 LUFS, so unity playback drowns the
/// call. The volume slider (0 to 200%, where 100% is a -6 dB calibration and
/// 200% is unity, so it cannot clip), voice ducking and deafen fuse into one
/// target gain for the active [ScreenAudioReceiver], whose sink ramps it.
///
/// Static because only one receiver is ever active, owned per call.
class ShareAudioLevel {
  ShareAudioLevel._();

  /// -10 dB duck, the broadcast-standard depth for a bed under speech.
  static const double _duckFactor = 0.316;

  /// Holds the duck through inter-word gaps; the VAD updates every ~200 ms.
  static const Duration _hold = Duration(milliseconds: 400);

  static ScreenAudioReceiver? _receiver;
  static double _volumePercent = 100;
  static bool _duckEnabled = true;
  static bool _speakingHeld = false;
  static bool _deafened = false;
  static Timer? _holdTimer;

  /// The receiver providers attach their sink when share audio starts.
  static void attach(ScreenAudioReceiver receiver) {
    _receiver = receiver;
    _push();
    _setServoHoldReceiving(true);
  }

  /// Detach on teardown, identity-checked so a stale detach from a torn-down
  /// call cannot disconnect a newer receiver.
  static void detach(ScreenAudioReceiver receiver) {
    if (identical(_receiver, receiver)) {
      _receiver = null;
      _setServoHoldReceiving(false);
    }
  }

  // Capture-servo hold, the other half of the share-audio story: while share
  // audio is active on this device, music bleeding into the mic passes the
  // Voice Enhancement servo's speech floor and would re-calibrate the trim to
  // the music, burying the voice. Both sources OR into one native flag.

  static bool _holdSending = false;
  static bool _holdReceiving = false;

  /// The local user started/stopped SENDING a screen share WITH audio.
  static void setSendingShareAudio(bool active) {
    if (_holdSending == active) return;
    _holdSending = active;
    _pushServoHold();
  }

  static void _setServoHoldReceiving(bool active) {
    if (_holdReceiving == active) return;
    _holdReceiving = active;
    _pushServoHold();
  }

  static void _pushServoHold() {
    Helper.setCaptureServoHold(_holdSending || _holdReceiving)
        .catchError((_) {});
  }

  /// Share-volume slider value in percent (0–200, 100 = calibrated default).
  static void setVolumePercent(double percent) {
    _volumePercent = percent.clamp(0.0, 200.0).toDouble();
    _push();
  }

  static void setDuckEnabled(bool enabled) {
    _duckEnabled = enabled;
    _push();
  }

  static void setDeafened(bool deafened) {
    _deafened = deafened;
    _push();
  }

  /// Voice-activity sidechain: pass "is ANYONE, self included, speaking".
  /// Duck engages immediately; release waits [_hold].
  static void setSpeaking(bool speaking) {
    if (speaking) {
      _holdTimer?.cancel();
      _holdTimer = null;
      if (!_speakingHeld) {
        _speakingHeld = true;
        _push();
      }
    } else if (_speakingHeld && _holdTimer == null) {
      _holdTimer = Timer(_hold, () {
        _holdTimer = null;
        _speakingHeld = false;
        _push();
      });
    }
  }

  static double get _target {
    if (_deafened) return 0.0;
    final base = _volumePercent / 200.0;
    return _duckEnabled && _speakingHeld ? base * _duckFactor : base;
  }

  static void _push() => _receiver?.setGain(_target);
}
