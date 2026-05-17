#import "MacScreenRecorder.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreMedia/CoreMedia.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

static NSString * const kDomain = @"MacScreenRecorder";

@interface MacScreenRecorder () <SCStreamDelegate, SCStreamOutput,
                                  AVCaptureAudioDataOutputSampleBufferDelegate>
@property(nonatomic, strong, nullable) SCStream *stream;
@property(nonatomic, strong, nullable) AVAssetWriter *writer;
@property(nonatomic, strong, nullable) AVAssetWriterInput *videoInput;
@property(nonatomic, strong, nullable) AVAssetWriterInput *systemAudioInput;
@property(nonatomic, strong, nullable) AVAssetWriterInput *micAudioInput;
@property(nonatomic, strong, nullable) AVCaptureSession *micSession;
@property(nonatomic, strong, nullable) dispatch_queue_t videoQueue;
@property(nonatomic, strong, nullable) dispatch_queue_t systemAudioQueue;
@property(nonatomic, strong, nullable) dispatch_queue_t micQueue;
@property(nonatomic) BOOL recording;
@property(nonatomic) BOOL writerStarted;
@property(nonatomic) BOOL lastRecordingCapturedSystemAudio;
@property(nonatomic, copy, nullable) NSString *outputPath;
@end

@implementation MacScreenRecorder

+ (instancetype)sharedInstance {
  static MacScreenRecorder *instance;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ instance = [[MacScreenRecorder alloc] init]; });
  return instance;
}

#pragma mark - Public

- (void)startWithOutputPath:(NSString *)outputPath
                 completion:(void (^)(NSError * _Nullable error))completion {
  if (self.recording) {
    completion([self errorWithCode:-100 message:@"Already recording"]);
    return;
  }
  if (@available(macOS 13.0, *)) {
    // OK
  } else {
    completion([self errorWithCode:-101 message:@"Recording requires macOS 13+"]);
    return;
  }

  self.outputPath = outputPath;
  self.writerStarted = NO;

  if (@available(macOS 13.0, *)) {
    [SCShareableContent
        getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *err) {
          if (err || content.displays.firstObject == nil) {
            NSError *e = err ?: [self errorWithCode:-2 message:@"No display available"];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(e); });
            return;
          }
          SCDisplay *display = content.displays.firstObject;
          NSError *startErr = [self startCaptureForDisplay:display];
          dispatch_async(dispatch_get_main_queue(), ^{ completion(startErr); });
        }];
  }
}

- (void)stopWithCompletion:(void (^)(NSError * _Nullable))completion {
  if (!self.recording) {
    completion(nil);
    return;
  }
  self.recording = NO;

  void (^finishWriter)(NSError *) = ^(NSError *streamErr) {
    [self.micSession stopRunning];
    self.micSession = nil;

    [self.videoInput markAsFinished];
    [self.systemAudioInput markAsFinished];
    [self.micAudioInput markAsFinished];

    AVAssetWriter *w = self.writer;
    if (w.status == AVAssetWriterStatusWriting) {
      [w finishWritingWithCompletionHandler:^{
        NSError *err = (w.status == AVAssetWriterStatusFailed) ? w.error : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(err); });
        self.writer = nil;
        self.videoInput = nil;
        self.systemAudioInput = nil;
        self.micAudioInput = nil;
      }];
    } else {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(streamErr ?: [self errorWithCode:-3 message:@"Writer in unexpected state"]);
      });
      self.writer = nil;
      self.videoInput = nil;
      self.systemAudioInput = nil;
      self.micAudioInput = nil;
    }
  };

  if (self.stream) {
    [self.stream stopCaptureWithCompletionHandler:^(NSError *err) {
      finishWriter(err);
    }];
    self.stream = nil;
  } else {
    finishWriter(nil);
  }
}

#pragma mark - Setup

- (NSError * _Nullable)startCaptureForDisplay:(SCDisplay *)display API_AVAILABLE(macos(13.0)) {
  NSError *err = nil;

  SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display
                                               excludingApplications:@[]
                                                    exceptingWindows:@[]];

  SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
  config.width = (NSInteger)display.width * 2;
  config.height = (NSInteger)display.height * 2;
  config.minimumFrameInterval = CMTimeMake(1, 30);
  config.pixelFormat = kCVPixelFormatType_32BGRA;
  config.queueDepth = 6;
  config.showsCursor = YES;
  config.scalesToFit = NO;
  // Capture system audio (peer voices, music, alerts) and DON'T exclude
  // our own process — WebRTC plays remote peer audio inside Hollow.
  config.capturesAudio = YES;
  config.excludesCurrentProcessAudio = NO;
  config.sampleRate = 48000;
  config.channelCount = 2;
  self.lastRecordingCapturedSystemAudio = YES;

  // AVAssetWriter MP4 (H.264 + AAC, two audio tracks: system + mic).
  NSURL *outURL = [NSURL fileURLWithPath:self.outputPath];
  [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];

  self.writer = [AVAssetWriter assetWriterWithURL:outURL fileType:AVFileTypeMPEG4 error:&err];
  if (!self.writer) return err;

  NSDictionary *videoSettings = @{
    AVVideoCodecKey: AVVideoCodecTypeH264,
    AVVideoWidthKey: @(config.width),
    AVVideoHeightKey: @(config.height),
    AVVideoCompressionPropertiesKey: @{
      AVVideoAverageBitRateKey: @(8 * 1000 * 1000),
      AVVideoMaxKeyFrameIntervalKey: @60,
      AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
    },
  };
  self.videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                       outputSettings:videoSettings];
  self.videoInput.expectsMediaDataInRealTime = YES;
  if (![self.writer canAddInput:self.videoInput]) {
    return [self errorWithCode:-4 message:@"Cannot add video input"];
  }
  [self.writer addInput:self.videoInput];

  NSDictionary *systemAudioSettings = @{
    AVFormatIDKey: @(kAudioFormatMPEG4AAC),
    AVNumberOfChannelsKey: @2,
    AVSampleRateKey: @48000,
    AVEncoderBitRateKey: @(160 * 1000),
  };
  self.systemAudioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                             outputSettings:systemAudioSettings];
  self.systemAudioInput.expectsMediaDataInRealTime = YES;
  if ([self.writer canAddInput:self.systemAudioInput]) {
    [self.writer addInput:self.systemAudioInput];
  }

  NSDictionary *micAudioSettings = @{
    AVFormatIDKey: @(kAudioFormatMPEG4AAC),
    AVNumberOfChannelsKey: @2,
    AVSampleRateKey: @44100,
    AVEncoderBitRateKey: @(160 * 1000),
  };
  self.micAudioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                          outputSettings:micAudioSettings];
  self.micAudioInput.expectsMediaDataInRealTime = YES;
  if ([self.writer canAddInput:self.micAudioInput]) {
    [self.writer addInput:self.micAudioInput];
  }

  self.videoQueue = dispatch_queue_create("com.anonlisten.hollow.rec.video", DISPATCH_QUEUE_SERIAL);
  self.systemAudioQueue = dispatch_queue_create("com.anonlisten.hollow.rec.sysaudio", DISPATCH_QUEUE_SERIAL);
  self.micQueue = dispatch_queue_create("com.anonlisten.hollow.rec.mic", DISPATCH_QUEUE_SERIAL);

  // SCStream — capture screen + system audio.
  self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
  if (![self.stream addStreamOutput:self type:SCStreamOutputTypeScreen
                  sampleHandlerQueue:self.videoQueue error:&err]) {
    return err;
  }
  if (![self.stream addStreamOutput:self type:SCStreamOutputTypeAudio
                  sampleHandlerQueue:self.systemAudioQueue error:&err]) {
    NSLog(@"[MacScreenRecorder] System-audio output add failed: %@", err);
    err = nil;
  }

  // Microphone via AVCaptureSession (separate track).
  self.micSession = [[AVCaptureSession alloc] init];
  AVCaptureDevice *micDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
  if (micDevice) {
    AVCaptureDeviceInput *micInput = [AVCaptureDeviceInput deviceInputWithDevice:micDevice
                                                                            error:&err];
    if (micInput && [self.micSession canAddInput:micInput]) {
      [self.micSession addInput:micInput];
      AVCaptureAudioDataOutput *micOutput = [[AVCaptureAudioDataOutput alloc] init];
      [micOutput setSampleBufferDelegate:self queue:self.micQueue];
      if ([self.micSession canAddOutput:micOutput]) {
        [self.micSession addOutput:micOutput];
      }
      [self.micSession startRunning];
    }
  }

  __block NSError *startErr = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [self.stream startCaptureWithCompletionHandler:^(NSError *e) {
    startErr = e;
    dispatch_semaphore_signal(sem);
  }];
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

  if (startErr) {
    [self.micSession stopRunning];
    self.micSession = nil;
    return startErr;
  }

  self.recording = YES;
  return nil;
}

#pragma mark - SCStreamOutput

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type API_AVAILABLE(macos(13.0)) {
  if (!self.recording) return;
  if (!CMSampleBufferIsValid(sampleBuffer)) return;
  if (!CMSampleBufferDataIsReady(sampleBuffer)) return;

  if (type == SCStreamOutputTypeScreen) {
    // Inspect frame status. Skip only frames we genuinely can't write —
    // suspended (3) or stopped (5). Accept complete (0), idle (1), blank
    // (2), and started (4) so a static desktop still records from frame
    // one rather than waiting up to several seconds for a change.
    int status = 0;
    CFArrayRef attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, NO);
    if (attachmentsArray && CFArrayGetCount(attachmentsArray) > 0) {
      CFDictionaryRef attachments = (CFDictionaryRef)CFArrayGetValueAtIndex(attachmentsArray, 0);
      CFNumberRef statusRef = CFDictionaryGetValue(attachments, (__bridge CFStringRef)@"SCStreamFrameInfoStatus");
      if (statusRef) {
        CFNumberGetValue(statusRef, kCFNumberIntType, &status);
      }
    }
    if (status == 3 || status == 5) return;

    if (!self.writerStarted) {
      CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
      if ([self.writer startWriting]) {
        [self.writer startSessionAtSourceTime:pts];
        self.writerStarted = YES;
      } else {
        return;
      }
    }

    if (self.videoInput.readyForMoreMediaData) {
      [self.videoInput appendSampleBuffer:sampleBuffer];
    }
    return;
  }

  if (type == SCStreamOutputTypeAudio) {
    if (!self.writerStarted) return;
    // Boost system audio (peer voices, music) — needs more gain than the
    // mic because the underlying playback level is typically quieter than
    // what comes off a hardware microphone.
    CMSampleBufferRef boosted = [self gainedCopyOfSampleBuffer:sampleBuffer factor:6.0f]
                                ?: sampleBuffer;
    if (self.systemAudioInput.readyForMoreMediaData) {
      [self.systemAudioInput appendSampleBuffer:boosted];
    }
    if (boosted != sampleBuffer) {
      CFRelease(boosted);
    }
    return;
  }
}

#pragma mark - Microphone capture (boosted +6 dB)

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
  if (!self.recording || !self.writerStarted) return;
  if (!CMSampleBufferIsValid(sampleBuffer)) return;

  CMSampleBufferRef boosted = [self gainedCopyOfSampleBuffer:sampleBuffer factor:6.0f]
                              ?: sampleBuffer;
  if (self.micAudioInput.readyForMoreMediaData) {
    [self.micAudioInput appendSampleBuffer:boosted];
  }
  if (boosted != sampleBuffer) {
    CFRelease(boosted);
  }
}

/// Multiply every PCM sample by [factor] with saturation. Supports int16
/// (most common) and float32 interleaved/non-interleaved. Returns a new
/// CMSampleBuffer with retained ownership (caller releases) or NULL if the
/// format isn't handled.
- (CMSampleBufferRef)gainedCopyOfSampleBuffer:(CMSampleBufferRef)src factor:(float)factor {
  CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(src);
  if (!format) return NULL;
  const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format);
  if (!asbd) return NULL;

  // Ask how big the ABL needs to be. For non-interleaved formats we need
  // mNumberBuffers slots which can't fit in the inline `AudioBufferList`.
  size_t neededSize = 0;
  OSStatus s = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      src, &neededSize, NULL, 0, NULL, NULL, 0, NULL);
  if (neededSize == 0) neededSize = sizeof(AudioBufferList);

  AudioBufferList *abl = (AudioBufferList *)malloc(neededSize);
  CMBlockBufferRef inBlock = NULL;
  s = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      src, NULL, abl, neededSize, kCFAllocatorDefault, kCFAllocatorDefault,
      kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &inBlock);
  if (s != noErr || !inBlock) {
    free(abl);
    if (inBlock) CFRelease(inBlock);
    return NULL;
  }

  // Apply gain in place on the retained block buffer's memory.
  BOOL handled = NO;
  for (UInt32 i = 0; i < abl->mNumberBuffers; i++) {
    AudioBuffer *b = &abl->mBuffers[i];
    if (asbd->mFormatFlags & kAudioFormatFlagIsFloat) {
      float *p = (float *)b->mData;
      UInt32 n = b->mDataByteSize / sizeof(float);
      for (UInt32 k = 0; k < n; k++) {
        float v = p[k] * factor;
        if (v > 1.0f) v = 1.0f;
        if (v < -1.0f) v = -1.0f;
        p[k] = v;
      }
      handled = YES;
    } else if ((asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) &&
               asbd->mBitsPerChannel == 16) {
      int16_t *p = (int16_t *)b->mData;
      UInt32 n = b->mDataByteSize / sizeof(int16_t);
      for (UInt32 k = 0; k < n; k++) {
        int32_t v = (int32_t)((float)p[k] * factor);
        if (v > INT16_MAX) v = INT16_MAX;
        if (v < INT16_MIN) v = INT16_MIN;
        p[k] = (int16_t)v;
      }
      handled = YES;
    }
  }
  free(abl);

  if (!handled) {
    CFRelease(inBlock);
    return NULL;
  }

  // Build a new CMSampleBuffer wrapping the boosted block.
  CMSampleBufferRef out = NULL;
  CMItemCount numSamples = CMSampleBufferGetNumSamples(src);
  CMSampleTimingInfo timing;
  CMSampleBufferGetSampleTimingInfo(src, 0, &timing);

  s = CMAudioSampleBufferCreateWithPacketDescriptions(
      kCFAllocatorDefault, inBlock, true, NULL, NULL, format,
      (CMItemCount)numSamples, timing.presentationTimeStamp, NULL, &out);
  CFRelease(inBlock);
  if (s != noErr || !out) return NULL;
  return out;
}

#pragma mark - SCStreamDelegate

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
  NSLog(@"[MacScreenRecorder] stream stopped: %@", error);
}

#pragma mark - Helpers

- (NSError *)errorWithCode:(NSInteger)code message:(NSString *)message {
  return [NSError errorWithDomain:kDomain code:code
                         userInfo:@{NSLocalizedDescriptionKey: message}];
}

@end
