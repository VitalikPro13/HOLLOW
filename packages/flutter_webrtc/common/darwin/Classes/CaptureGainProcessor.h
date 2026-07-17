#import <Foundation/Foundation.h>
#import "AudioProcessingAdapter.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Hollow fork addition: a capture-post-processor that runs AFTER WebRTC's own
 * APM (AGC/NS/EC) on the local microphone. WebRTC's AGC normalizes to a
 * conservative target (~-18 dBFS), so calls come out quieter than users
 * expect. The prebuilt WebRTC.framework exposes no AGC target-level knob, so
 * this post-processor is where the missing loudness/polish is added.
 *
 * Two modes, switched live via -setEnhance::
 *  - enhance OFF (legacy): flat makeup gain + a -3 dBFS soft limiter.
 *  - enhance ON (default from the app): a STATIC broadcast voice chain —
 *    trim -> EQ (HP 100 Hz 24 dB/oct, low shelf 110 Hz +6 dB, peaking
 *    291/-3, 3k/+2, 7k/+3.5, 12k/+1.5 dB) -> compressor (-18 dBFS, 3:1,
 *    10/100 ms, +12 dB makeup) -> smoothed peak limiter (-1 dBFS) -> tanh
 *    safety net. All parameters FIXED (no adaptive leveler) — fixed biquads
 *    cannot zipper, and the one compressor uses the Giannoulis decoupled
 *    smooth detector: the anti-crackle rules from the reverted adaptive
 *    chain. This is the C reference port of
 *    common/cpp/src/flutter_capture_gain_processor.cc — keep them in sync.
 *
 * audioProcessingProcess: runs on the realtime audio thread; gain/enhance are
 * read lock-free each frame and can be updated live mid-call.
 */
@interface CaptureGainProcessor : NSObject <ExternalAudioProcessingDelegate>

/** Linear makeup-gain multiplier (1.0 = transparent in legacy mode; in
 *  enhance mode rescaled so the slider's "100%" (2.0) is unity trim).
 *  Thread-safe. */
- (void)setGain:(float)gain;

/** Enables the EQ+compressor+limiter voice chain. Thread-safe, live. */
- (void)setEnhance:(BOOL)enabled;

/** Compressor makeup gain (dB) for the enhance chain — the "strength" knob
 *  (0 = no loudness boost, 12 = default). Thread-safe, live. */
- (void)setEnhanceMakeup:(float)db;

/** Dynamic mode: a slow speech-gated RMS meter servos the input trim so any
 *  mic lands at the calibrated speech level; the manual gain/strength knobs
 *  are ignored while active. Thread-safe, live. */
- (void)setEnhanceDynamic:(BOOL)enabled;

/** Mic muted: freeze the dynamic servo's adaptation — what the mic hears
 *  while muted is never call speech (e.g. shared music on the speakers), and
 *  adapting to it buries the voice on unmute. Thread-safe, live. */
- (void)setMuted:(BOOL)muted;

/** Share audio active on this device (sending or playing): freeze the servo
 *  for the whole share — continuous room bleed passes the speech floor and
 *  would re-calibrate the trim to the music. Thread-safe, live. */
- (void)setServoHold:(BOOL)hold;

@end

NS_ASSUME_NONNULL_END
