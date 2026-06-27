#import "MacScreenShareAudioCapturer.h"

#import <CoreMedia/CoreMedia.h>
#import <CoreAudioTypes/CoreAudioTypes.h>
#include <math.h>

#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#endif

static NSString * const kDomain = @"MacScreenShareAudioCapturer";

API_AVAILABLE(macos(13.0))
@interface MacScreenShareAudioCapturer () <SCStreamOutput, SCStreamDelegate>
@property(nonatomic, strong, nullable) SCStream *stream;
@property(nonatomic, strong, nullable) dispatch_queue_t audioQueue;
// SCK requires a SCREEN output to be added even for audio-only capture — without
// it the stream's frame pipeline tears down ("stream output NOT found") and the
// AUDIO callback never fires (silent capture on macOS 14/15). We add a minimal,
// low-frame-rate screen output and drop its frames. This queue serves it.
@property(nonatomic, strong, nullable) dispatch_queue_t videoQueue;
@property(nonatomic, copy, nullable) void (^onPcm)(NSData *pcm);
@property(nonatomic) BOOL active;
@end

@implementation MacScreenShareAudioCapturer

+ (instancetype)sharedInstance {
  static MacScreenShareAudioCapturer *instance;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[MacScreenShareAudioCapturer alloc] init];
  });
  return instance;
}

#pragma mark - Public

- (BOOL)startWithCallback:(void (^)(NSData *pcm))onPcm
                    error:(NSError * _Nullable * _Nullable)error {
  if (self.active) return YES;

  if (@available(macOS 13.0, *)) {
    self.onPcm = onPcm;
    self.audioQueue = dispatch_queue_create("com.anonlisten.hollow.screenshare.audiocap",
                                            DISPATCH_QUEUE_SERIAL);
    self.videoQueue = dispatch_queue_create("com.anonlisten.hollow.screenshare.videocap",
                                            DISPATCH_QUEUE_SERIAL);
    // Mark active up front and resolve shareable content + start the SCStream
    // ASYNCHRONOUSLY. NEVER block here: this runs on the main thread (Flutter
    // method-channel handler), and SCShareableContent can take seconds to
    // resolve while the screen-share VIDEO SCStream is already capturing —
    // blocking froze the whole app for the timeout. PCM simply starts flowing
    // once the stream is up; if it fails, no packets flow (caller tolerates it).
    self.active = YES;
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content,
                                                                   NSError *err) {
      if (!self.active) return;  // stopped before content resolved
      if (err || content.displays.firstObject == nil) {
        NSLog(@"[ScreenShareAudioCap] no shareable content: %@", err);
        self.active = NO;
        return;
      }
      NSError *startErr = nil;
      if (![self startStreamForDisplay:content.displays.firstObject error:&startErr]) {
        NSLog(@"[ScreenShareAudioCap] start failed: %@", startErr);
        self.active = NO;
      } else {
        NSLog(@"[ScreenShareAudioCap] capture started");
      }
    }];
    return YES;
  }

  if (error) {
    *error = [self errorWithCode:-1
                        message:@"System audio capture requires macOS 13.0 or later."];
  }
  return NO;
}

- (void)stop {
  self.active = NO;
  self.onPcm = nil;
  if (@available(macOS 13.0, *)) {
    SCStream *s = self.stream;
    self.stream = nil;
    if (s) {
      [s stopCaptureWithCompletionHandler:^(NSError *err) {
        if (err) NSLog(@"[ScreenShareAudioCap] stopCapture error: %@", err);
      }];
    }
  }
}

#pragma mark - Setup

- (BOOL)startStreamForDisplay:(SCDisplay *)display
                       error:(NSError **)error API_AVAILABLE(macos(13.0)) {
  // We only WANT audio, but SCK won't reliably deliver audio buffers unless a
  // SCREEN output is also attached — an audio-only stream tears its frame
  // pipeline down ("stream output NOT found") and didOutputSampleBuffer never
  // fires for audio (the silent-capture bug on macOS 14/15). So we add BOTH a
  // minimal screen output (frames dropped in the delegate) and the audio output.
  SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display
                                              excludingApplications:@[]
                                                   exceptingWindows:@[]];

  SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
  config.capturesAudio = YES;
  // EXCLUDE Hollow's own audio output from the share. Hollow plays the remote
  // peers' voices, so capturing system-wide output would re-broadcast those
  // voices back into the share -> the sender hears themselves / the call echoes.
  // YES = share only the OTHER apps' audio (browser/game/music), never the call.
  // (The recorder deliberately keeps this NO: a local recording SHOULD include
  // everyone's voices, and it has no live-loopback echo path.)
  config.excludesCurrentProcessAudio = YES;
  config.sampleRate = 48000;
  config.channelCount = 2;
  // The screen output is required (above) but we don't use the pixels. Keep it
  // tiny and very low frame-rate so it costs almost nothing. (A 2x2 / 1fps had
  // been used WITHOUT a screen output and audio stayed silent.)
  config.width = 16;
  config.height = 16;
  config.minimumFrameInterval = CMTimeMake(1, 2);  // ~0.5 fps, just to keep the pipe alive
  config.queueDepth = 5;

  NSError *err = nil;
  self.stream = [[SCStream alloc] initWithFilter:filter
                                   configuration:config
                                        delegate:self];
  if (![self.stream addStreamOutput:self
                               type:SCStreamOutputTypeAudio
                 sampleHandlerQueue:self.audioQueue
                              error:&err]) {
    if (error) *error = err ?: [self errorWithCode:-3 message:@"Failed to add audio output"];
    return NO;
  }
  // Required screen output — its frames are ignored in the delegate. A failure
  // here isn't fatal to audio on its own, but log it (it usually means audio
  // won't flow either).
  NSError *screenErr = nil;
  if (![self.stream addStreamOutput:self
                               type:SCStreamOutputTypeScreen
                 sampleHandlerQueue:self.videoQueue
                              error:&screenErr]) {
    NSLog(@"[ScreenShareAudioCap] screen output add failed (audio may stay silent): %@",
          screenErr);
  }

  // Start asynchronously — do NOT block. Capture begins when SCK calls back;
  // PCM then flows through the SCStreamOutput delegate.
  [self.stream startCaptureWithCompletionHandler:^(NSError *e) {
    if (e) {
      NSLog(@"[ScreenShareAudioCap] startCapture error: %@", e);
      self.active = NO;
    }
  }];
  return YES;
}

#pragma mark - SCStreamOutput

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type API_AVAILABLE(macos(13.0)) {
  if (!self.active) return;
  if (type != SCStreamOutputTypeAudio) return;
  if (!CMSampleBufferIsValid(sampleBuffer)) return;
  if (!CMSampleBufferDataIsReady(sampleBuffer)) return;

  void (^cb)(NSData *) = self.onPcm;
  if (!cb) return;

  CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
  if (!format) return;
  const AudioStreamBasicDescription *asbd =
      CMAudioFormatDescriptionGetStreamBasicDescription(format);
  if (!asbd) return;

  size_t neededSize = 0;
  OSStatus s = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer, &neededSize, NULL, 0, NULL, NULL, 0, NULL);
  if (neededSize == 0) neededSize = sizeof(AudioBufferList);

  AudioBufferList *abl = (AudioBufferList *)malloc(neededSize);
  if (!abl) return;
  CMBlockBufferRef block = NULL;
  s = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer, NULL, abl, neededSize, kCFAllocatorDefault, kCFAllocatorDefault,
      kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &block);
  if (s != noErr || !block) {
    free(abl);
    if (block) CFRelease(block);
    return;
  }

  const BOOL isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
  const BOOL isInt16 = (asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) &&
                       asbd->mBitsPerChannel == 16;
  const BOOL nonInterleaved =
      (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
  const UInt32 channels = asbd->mChannelsPerFrame ?: 2;

  NSMutableData *out = [NSMutableData data];

  if (!nonInterleaved && abl->mNumberBuffers >= 1) {
    // Interleaved: one buffer holds all channels.
    AudioBuffer *b = &abl->mBuffers[0];
    if (isInt16) {
      [out appendBytes:b->mData length:b->mDataByteSize];
    } else if (isFloat) {
      const float *p = (const float *)b->mData;
      UInt32 n = b->mDataByteSize / sizeof(float);
      [self appendFloat:p count:n to:out];
    }
  } else if (nonInterleaved && abl->mNumberBuffers >= channels) {
    // Planar: interleave the per-channel buffers into s16.
    UInt32 framesPerChan = 0;
    if (isFloat)
      framesPerChan = abl->mBuffers[0].mDataByteSize / sizeof(float);
    else if (isInt16)
      framesPerChan = abl->mBuffers[0].mDataByteSize / sizeof(int16_t);

    [out setLength:(NSUInteger)framesPerChan * channels * sizeof(int16_t)];
    int16_t *dst = (int16_t *)out.mutableBytes;
    for (UInt32 f = 0; f < framesPerChan; f++) {
      for (UInt32 c = 0; c < channels; c++) {
        int16_t v = 0;
        if (isFloat) {
          float fv = ((const float *)abl->mBuffers[c].mData)[f];
          v = [self floatToS16:fv];
        } else if (isInt16) {
          v = ((const int16_t *)abl->mBuffers[c].mData)[f];
        }
        dst[f * channels + c] = v;
      }
    }
  }

  free(abl);
  CFRelease(block);

  if (out.length > 0) cb(out);
}

#pragma mark - SCStreamDelegate

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
  NSLog(@"[ScreenShareAudioCap] stream stopped: %@", error);
  self.active = NO;
}

#pragma mark - Helpers

- (int16_t)floatToS16:(float)fv {
  float v = fv * 32767.0f;
  if (v > 32767.0f) v = 32767.0f;
  if (v < -32768.0f) v = -32768.0f;
  return (int16_t)lrintf(v);
}

- (void)appendFloat:(const float *)p count:(UInt32)n to:(NSMutableData *)out {
  NSUInteger base = out.length;
  [out setLength:base + (NSUInteger)n * sizeof(int16_t)];
  int16_t *dst = (int16_t *)((uint8_t *)out.mutableBytes + base);
  for (UInt32 i = 0; i < n; i++) dst[i] = [self floatToS16:p[i]];
}

- (NSError *)errorWithCode:(NSInteger)code message:(NSString *)message {
  return [NSError errorWithDomain:kDomain code:code
                         userInfo:@{NSLocalizedDescriptionKey: message}];
}

@end
