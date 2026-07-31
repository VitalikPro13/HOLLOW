import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Are WE talking right now? Read from the native capture post-processor,
/// shared by DM calls (`voice_service.dart`) and voice channels
/// (`voice_channel_service.dart`) so the two can't drift apart.
///
/// **Why not getStats** (issue #37). `audioLevel` is only specified on
/// `media-source` and `inbound-rtp`; `outbound-rtp` is not required to carry
/// it, and desktop reports no outgoing level at all — so the local indicator
/// was permanently dark on Windows while remote peers, which DO come from
/// `inbound-rtp`, worked fine. Remote detection still uses getStats; only the
/// local side moved here.
///
/// **Why not the `record` package** (what the Settings mic test uses): it
/// opens a SECOND handle on the microphone, and `record_linux` shells out to
/// `parecord`, which PipeWire systems don't have — that was the original
/// report. The capture processor is already in the audio path on every
/// platform, needs no second handle, and works with nobody else connected.
class LocalSpeakingDetector {
  /// Speech floor in dBFS against the capture RMS. Measured pre-chain, so
  /// this is the raw voice, not the servo's normalized output.
  ///
  /// -45 dBFS sits below conversational speech (which lands around -30 to
  /// -20 even on a quiet mic) and above room tone on a typical desktop
  /// setup. The AI denoiser runs BEFORE the meter, so on machines with it
  /// enabled the floor is mostly moot — steady noise is already gone.
  static const double speakingFloorDb = -45.0;

  /// Voice probability at which the denoiser's own VAD counts as speech.
  /// Matches the chain's upward-boost gate (full boost at 0.75), one notch
  /// down so the indicator lights slightly before the boost engages.
  static const double vadSpeechProb = 0.6;

  /// Below this the reading is treated as "no meter" rather than silence:
  /// the native default is -100, so a plugin that predates `getCaptureLevel`
  /// (or a processor that has never seen a frame) can't be mistaken for a
  /// mic that is merely quiet.
  static const double _noMeterDb = -99.0;

  bool _speaking = false;
  bool _sawMeter = false;

  /// True once the native meter has produced a real reading. Until then
  /// callers should assume nothing — the plugin may be an older build.
  bool get hasMeter => _sawMeter;

  /// Polls the capture level once. [muted] short-circuits: a muted mic is
  /// never speaking, and the processor deliberately keeps metering while
  /// muted (the APM still feeds it real audio) so the value would otherwise
  /// keep flickering behind a muted button.
  Future<bool> poll({required bool muted}) async {
    if (muted) {
      _speaking = false;
      return false;
    }
    final Map<String, dynamic> level;
    try {
      level = await Helper.getCaptureLevel();
    } catch (_) {
      return _speaking;
    }
    final levelDb = (level['levelDb'] as num?)?.toDouble();
    if (levelDb == null || levelDb <= _noMeterDb) {
      // No meter yet (older plugin, or no frame processed). Hold the last
      // state rather than asserting silence.
      return _speaking;
    }
    _sawMeter = true;

    // Prefer the denoiser's own voice probability when it is running: it
    // separates speech from steady noise far better than a level threshold.
    final vad = (level['vad'] as num?)?.toDouble() ?? -1.0;
    _speaking = vad >= 0.0
        ? vad >= vadSpeechProb && levelDb > speakingFloorDb
        : levelDb > speakingFloorDb;
    return _speaking;
  }

  void reset() {
    _speaking = false;
  }
}
