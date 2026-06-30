#import "ScreenAudioPlayer.h"

#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>
#import <stdlib.h>
#import <string.h>

// Must match the senders (desktop OpusDecoderWrapper / encode mode). Macros,
// not `static const`, so they're usable as ivar-array bounds (ObjC follows C:
// a `static const int` is not an integer constant expression there).
#define kSampleRate 48000
#define kChannels 2
#define kNumBuffers 8
// 10 ms per audio-queue buffer: 480 frames/channel.
#define kFramesPerBuf (kSampleRate / 100)
#define kSamplesPerBuf (kFramesPerBuf * kChannels)              // 960
#define kBytesPerBuf (kSamplesPerBuf * (int)sizeof(int16_t))

// Jitter buffer caps (in samples, interleaved). Mirror audio_player_mac.cpp:
// hold at most ~1 s; on overrun drop down to ~200 ms of backlog.
#define kMaxQueuedSamples ((size_t)kSampleRate * kChannels)        // 1 s
#define kDrainToSamples ((size_t)(kSampleRate / 5) * kChannels)    // 200 ms

@interface ScreenAudioPlayer ()
// Pull `maxSamples` interleaved int16 samples from the ring into `out`.
// Returns how many were available (< maxSamples on underrun). Audio-thread.
- (size_t)fillBuffer:(int16_t *)out maxSamples:(size_t)maxSamples;
@end

@implementation ScreenAudioPlayer {
  AudioQueueRef _queue;
  AudioQueueBufferRef _buffers[kNumBuffers];
  BOOL _running;

  // Sample ring buffer (interleaved int16), guarded by _lock.
  int16_t *_ring;
  size_t _ringCap;   // capacity in samples
  size_t _ringHead;  // read index
  size_t _ringSize;  // valid samples
  os_unfair_lock _lock;
}

static void AQOutputCallback(void *userData, AudioQueueRef queue,
                             AudioQueueBufferRef buf) {
  ScreenAudioPlayer *player = (__bridge ScreenAudioPlayer *)userData;
  if (player == nil) {
    memset(buf->mAudioData, 0, kBytesPerBuf);
    buf->mAudioDataByteSize = kBytesPerBuf;
    AudioQueueEnqueueBuffer(queue, buf, 0, NULL);
    return;
  }
  int16_t *out = (int16_t *)buf->mAudioData;
  size_t n = [player fillBuffer:out maxSamples:kSamplesPerBuf];
  if (n < (size_t)kSamplesPerBuf) {
    memset(out + n, 0, (kSamplesPerBuf - n) * sizeof(int16_t));
  }
  buf->mAudioDataByteSize = kBytesPerBuf;
  AudioQueueEnqueueBuffer(queue, buf, 0, NULL);
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _lock = OS_UNFAIR_LOCK_INIT;
    _ringCap = kMaxQueuedSamples + kSamplesPerBuf;
    _ring = (int16_t *)calloc(_ringCap, sizeof(int16_t));
    _ringHead = 0;
    _ringSize = 0;
  }
  return self;
}

- (void)dealloc {
  [self stop];
  if (_ring) {
    free(_ring);
    _ring = NULL;
  }
}

- (BOOL)start {
  if (_running) return YES;
  if (_ring == NULL) return NO;

  AudioStreamBasicDescription fmt = {0};
  fmt.mSampleRate = kSampleRate;
  fmt.mFormatID = kAudioFormatLinearPCM;
  fmt.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
  fmt.mBitsPerChannel = 16;
  fmt.mChannelsPerFrame = kChannels;
  fmt.mBytesPerFrame = kChannels * sizeof(int16_t);
  fmt.mFramesPerPacket = 1;
  fmt.mBytesPerPacket = fmt.mBytesPerFrame;

  OSStatus err = AudioQueueNewOutput(&fmt, AQOutputCallback,
                                     (__bridge void *)self, NULL, NULL, 0, &_queue);
  if (err != noErr) {
    NSLog(@"[ScreenAudioPlayer] AudioQueueNewOutput failed: %d", (int)err);
    return NO;
  }

  for (int i = 0; i < kNumBuffers; i++) {
    err = AudioQueueAllocateBuffer(_queue, kBytesPerBuf, &_buffers[i]);
    if (err != noErr) {
      NSLog(@"[ScreenAudioPlayer] AudioQueueAllocateBuffer failed: %d", (int)err);
      AudioQueueDispose(_queue, true);
      _queue = NULL;
      return NO;
    }
    memset(_buffers[i]->mAudioData, 0, kBytesPerBuf);
    _buffers[i]->mAudioDataByteSize = kBytesPerBuf;
    AudioQueueEnqueueBuffer(_queue, _buffers[i], 0, NULL);
  }

  err = AudioQueueStart(_queue, NULL);
  if (err != noErr) {
    NSLog(@"[ScreenAudioPlayer] AudioQueueStart failed: %d", (int)err);
    AudioQueueDispose(_queue, true);
    _queue = NULL;
    return NO;
  }

  _running = YES;
  NSLog(@"[ScreenAudioPlayer] started");
  return YES;
}

- (void)stop {
  if (!_running && _queue == NULL) return;
  _running = NO;
  if (_queue) {
    AudioQueueStop(_queue, true);
    AudioQueueDispose(_queue, true);
    _queue = NULL;
  }
  os_unfair_lock_lock(&_lock);
  _ringHead = 0;
  _ringSize = 0;
  os_unfair_lock_unlock(&_lock);
  NSLog(@"[ScreenAudioPlayer] stopped");
}

- (void)write:(NSData *)pcm {
  if (!_running || pcm.length == 0) return;
  const int16_t *samples = (const int16_t *)pcm.bytes;
  size_t count = pcm.length / sizeof(int16_t);
  if (count == 0) return;

  // A single buffer is at most ~10 ms (kSamplesPerBuf) and the ring has one
  // buffer of headroom above kMaxQueuedSamples, so a write never overflows
  // capacity — only the 1 s jitter cap is enforced here.
  if (count > _ringCap) {
    samples += (count - _ringCap);
    count = _ringCap;
  }

  os_unfair_lock_lock(&_lock);
  // Overrun: if appending would exceed the 1 s cap, drop the oldest so the
  // backlog after this write is ~200 ms (mirrors desktop audio_player_mac).
  if (_ringSize + count > kMaxQueuedSamples && _ringSize > kDrainToSamples) {
    size_t drop = _ringSize - kDrainToSamples;
    _ringHead = (_ringHead + drop) % _ringCap;
    _ringSize -= drop;
  }
  size_t writePos = (_ringHead + _ringSize) % _ringCap;
  for (size_t i = 0; i < count; i++) {
    _ring[writePos] = samples[i];
    writePos = (writePos + 1) % _ringCap;
  }
  _ringSize += count;
  os_unfair_lock_unlock(&_lock);
}

- (size_t)fillBuffer:(int16_t *)out maxSamples:(size_t)maxSamples {
  os_unfair_lock_lock(&_lock);
  size_t n = (_ringSize >= maxSamples) ? maxSamples : _ringSize;
  for (size_t i = 0; i < n; i++) {
    out[i] = _ring[_ringHead];
    _ringHead = (_ringHead + 1) % _ringCap;
  }
  _ringSize -= n;
  os_unfair_lock_unlock(&_lock);
  return n;
}

@end
