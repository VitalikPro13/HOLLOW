#import "CaptureGainProcessor.h"

#import <WebRTC/WebRTC.h>
#import <math.h>
#import <stdatomic.h>

// WebRTC's APM delivers float PCM in int16 scale (~ +/-32768), not +/-1.0.
static const float kFullScale = 32768.0f;
// -3 dBFS ceiling: 10^(-3/20) = 0.7079.
static const float kCeiling = 0.7079f * kFullScale;  // ~23197
// Soft-knee threshold: pass through untouched below this, smoothly saturate
// above it. 0.6 * ceiling keeps normal speech fully linear.
static const float kKnee = 0.6f * kCeiling;
static const float kRange = kCeiling - kKnee;

// Soft limiter, C1-continuous at the knee, asymptotes to +/-kCeiling so the
// signal can never clip. Transparent below the knee.
static inline float SoftLimit(float x) {
  const float ax = fabsf(x);
  if (ax <= kKnee) {
    return x;
  }
  const float over = ax - kKnee;
  const float limited = kKnee + kRange * tanhf(over / kRange);
  return x < 0.0f ? -limited : limited;
}

@implementation CaptureGainProcessor {
  _Atomic(float) _gain;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    atomic_init(&_gain, 1.0f);
  }
  return self;
}

- (void)setGain:(float)gain {
  atomic_store_explicit(&_gain, gain, memory_order_relaxed);
}

#pragma mark - ExternalAudioProcessingDelegate

- (void)audioProcessingInitializeWithSampleRate:(size_t)sampleRateHz
                                       channels:(size_t)channels {
}

- (void)audioProcessingProcess:(RTC_OBJC_TYPE(RTCAudioBuffer) *)audioBuffer {
  const float gain = atomic_load_explicit(&_gain, memory_order_relaxed);
  const int frames = (int)audioBuffer.frames;
  for (int ch = 0; ch < (int)audioBuffer.channels; ch++) {
    float *samples = [audioBuffer rawBufferForChannel:ch];
    if (samples == NULL) {
      continue;
    }
    for (int i = 0; i < frames; i++) {
      samples[i] = SoftLimit(samples[i] * gain);
    }
  }
}

- (void)audioProcessingRelease {
}

@end
