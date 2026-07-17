import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'screen_audio_receiver.dart';

/// Process-global level control for RECEIVED screen-share audio.
///
/// Share audio is raw mastered content (music sits at −14 LUFS or hotter,
/// far denser than speech) while the voice chain converges at ~−16 LUFS, so
/// unity playback drowns the call. This bus fuses the three inputs that decide
/// how loud the share should play RIGHT NOW and pushes one target gain into
/// the active [ScreenAudioReceiver] (the sink ramps click-free):
///
///  * the persisted share-volume slider (0–200%, 100% = −6 dB calibration,
///    200% = the source's original loudness — gain never exceeds unity, so
///    the slider can't clip),
///  * voice-activity ducking (−10 dB while anyone in the call speaks, you
///    included — MV6-style; 400 ms hold so word gaps don't pump),
///  * deafen (hard zero — voice tracks are zeroed elsewhere, share audio
///    must follow).
///
/// Static because the receivers are per-call singletons owned by
/// call_provider / voice_channel_provider (only one is ever active) and the
/// speaking callbacks live in service-layer closures — mirroring
/// AudioSwitchManager-style process-global audio state.
class ShareAudioLevel {
  ShareAudioLevel._();

  /// −10 dB duck while voice is active — the broadcast-standard depth for a
  /// bed under speech.
  static const double _duckFactor = 0.316;

  /// Keep the duck through inter-word gaps; only release after this much
  /// continuous silence. (VAD itself updates every ~200 ms.)
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

  /// Detach on teardown; identity-checked so a stale detach from a torn-down
  /// call can't disconnect a newer receiver.
  static void detach(ScreenAudioReceiver receiver) {
    if (identical(_receiver, receiver)) {
      _receiver = null;
      _setServoHoldReceiving(false);
    }
  }

  // -------------------------------------------------------------------------
  // Capture-servo hold — the OTHER half of the share-audio story: while share
  // audio is active on this device (we SEND a share with audio, or PLAY a
  // received one on speakers), continuous music bleed into the mic passes the
  // Voice Enhancement servo's speech floor and would re-calibrate the trim to
  // the music (9 dB/s down), burying the voice. Both sources OR into one
  // native flag; the servo freezes at its pre-share speech calibration.
  // -------------------------------------------------------------------------

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

  /// Voice-activity sidechain — call with "is ANYONE (self included)
  /// currently speaking". Duck engages immediately; release waits [_hold].
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
