import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Are WE talking right now? Read from the native capture post-processor,
/// shared by DM calls and voice channels so the two cannot drift apart.
///
/// Not getStats (issue #37): `audioLevel` is only specified on `media-source`
/// and `inbound-rtp`, and desktop reports no outgoing level at all, so the
/// local indicator was permanently dark on Windows. Remote detection still
/// uses getStats; only the local side moved here.
///
/// Not the `record` package either: it opens a SECOND handle on the mic, and
/// `record_linux` shells out to `parecord`, which PipeWire systems lack.
class LocalSpeakingDetector {
  /// Speech floor in dBFS against the capture RMS, measured pre-chain. -45
  /// sits below conversational speech and above room tone; the AI denoiser
  /// runs BEFORE the meter, so with it on the floor is mostly moot.
  static const double speakingFloorDb = -45.0;

  /// Voice probability at which the denoiser's VAD counts as speech. One
  /// notch below the chain's upward-boost gate, so the indicator lights first.
  static const double vadSpeechProb = 0.6;

  /// Below this the reading is "no meter", not silence: the native default is
  /// -100, so a plugin predating `getCaptureLevel` is not read as a quiet mic.
  static const double _noMeterDb = -99.0;

  bool _speaking = false;
  bool _sawMeter = false;

  /// True once the native meter has produced a real reading. Until then
  /// callers should assume nothing: the plugin may be an older build.
  bool get hasMeter => _sawMeter;

  /// Polls the capture level once. [muted] short-circuits: the processor
  /// deliberately keeps metering while muted, so the value would otherwise
  /// flicker behind a muted button.
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
      // No meter yet: hold the last state rather than asserting silence.
      return _speaking;
    }
    _sawMeter = true;

    // Prefer the denoiser's VAD: it beats a level threshold on steady noise.
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
