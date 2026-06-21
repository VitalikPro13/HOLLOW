#import <Foundation/Foundation.h>
#import "AudioProcessingAdapter.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Hollow fork addition: a capture-post-processor that runs AFTER WebRTC's own
 * APM (AGC/NS/EC) on the local microphone. WebRTC's AGC normalizes to a
 * conservative target (~-18 dBFS), so calls come out quieter than users
 * expect. This applies a makeup gain followed by a soft limiter with a
 * ~-3 dBFS ceiling so the boost can never clip — the OBS-style chain.
 *
 * The prebuilt WebRTC.framework exposes no AGC target-level knob, so this
 * post-processor is how we add the missing loudness.
 *
 * audioProcessingProcess: runs on the realtime audio thread; the gain is read
 * lock-free each frame and can be updated live mid-call via -setGain:.
 */
@interface CaptureGainProcessor : NSObject <ExternalAudioProcessingDelegate>

/** Linear makeup-gain multiplier (1.0 = transparent). Thread-safe. */
- (void)setGain:(float)gain;

@end

NS_ASSUME_NONNULL_END
