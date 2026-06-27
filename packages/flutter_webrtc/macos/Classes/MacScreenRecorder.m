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
// Which inputs were actually added to the writer (only these may be
// markAsFinished'd; finishing an unattached input throws / corrupts the file).
@property(nonatomic) BOOL hasSystemAudioInput;
@property(nonatomic) BOOL hasMicInput;
// Per-track sample counts — a track added to the writer that receives ZERO
// sample buffers produces an unplayable MP4 (broken/empty track box).
@property(nonatomic) uint64_t videoSamples;
@property(nonatomic) uint64_t systemAudioSamples;
@property(nonatomic) uint64_t micSamples;
// PTS of the first video frame, used to start the writer session. Audio runs on
// independent clocks (SCK system-audio + the mic's separate AVCaptureSession),
// so a buffer can arrive with a timestamp BEFORE the session start. Appending a
// pre-session sample makes AVAssetWriter go to Failed mid-record -> no moov atom
// -> unplayable MP4 (the intermittent corruption). We drop any audio earlier
// than this gate. kCMTimeInvalid until the first video frame establishes it.
@property(nonatomic) CMTime sessionStartPts;
// Audio buffers dropped because they predated the session start (diagnostic).
@property(nonatomic) uint64_t systemAudioDropped;
@property(nonatomic) uint64_t micDropped;
// Which track's append FIRST flipped the writer to Failed, with the writer error
// captured AT THAT MOMENT (the real trigger — by stop() the message is masked).
@property(nonatomic, copy, nullable) NSString *firstFailTrack;
// The SCK system-audio ASBD (rate/channels/float/planar) from the first buffer,
// carried back to Dart in the stop diag so we can SEE what the AAC encoder is
// being fed (NSLog is invisible over SSH).
@property(nonatomic, copy, nullable) NSString *sysAudioAsbd;
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
  self.hasSystemAudioInput = NO;
  self.hasMicInput = NO;
  self.videoSamples = 0;
  self.systemAudioSamples = 0;
  self.micSamples = 0;
  self.systemAudioDropped = 0;
  self.micDropped = 0;
  self.firstFailTrack = nil;
  self.sysAudioAsbd = nil;
  self.sessionStartPts = kCMTimeInvalid;

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

    AVAssetWriter *w = self.writer;
    NSLog(@"[MacScreenRecorder] finishing: status=%ld writerStarted=%d "
          @"video=%llu sysAudio=%llu(added=%d,drop=%llu) "
          @"mic=%llu(added=%d,drop=%llu) err=%@",
          (long)w.status, self.writerStarted, self.videoSamples,
          self.systemAudioSamples, self.hasSystemAudioInput, self.systemAudioDropped,
          self.micSamples, self.hasMicInput, self.micDropped, w.error);

    void (^cleanup)(void) = ^{
      self.writer = nil;
      self.videoInput = nil;
      self.systemAudioInput = nil;
      self.micAudioInput = nil;
      self.hasSystemAudioInput = NO;
      self.hasMicInput = NO;
    };

    // Diagnostic prefix surfaced to Dart (lands in hollow_debug.log).
    // saDrop/micDrop = audio buffers dropped for predating the session start.
    // firstFail = which track's append FIRST flipped the writer to Failed (the
    // real trigger), captured at the moment of failure with the underlying error
    // — the stop-time localizedDescription is just the generic masked message.
    NSError *we = w.error;
    NSError *under = we.userInfo[NSUnderlyingErrorKey];
    NSString *diag = [NSString stringWithFormat:
        @"status=%ld started=%d v=%llu sa=%llu(%d,drop=%llu) mic=%llu(%d,drop=%llu) "
        @"firstFail=%@ asbd=[%@] wErr=[%@ %ld] under=[%@ %ld %@]",
        (long)w.status, self.writerStarted, self.videoSamples,
        self.systemAudioSamples, self.hasSystemAudioInput, self.systemAudioDropped,
        self.micSamples, self.hasMicInput, self.micDropped,
        self.firstFailTrack ?: @"none", self.sysAudioAsbd ?: @"?",
        we.domain ?: @"-", (long)we.code,
        under.domain ?: @"-", (long)under.code, under.localizedDescription ?: @"-"];

    // If the writer already FAILED mid-recording (almost always a rejected
    // audio sample buffer), finishWriting can't produce a moov -> corrupt file.
    // Surface the real writer error instead of a generic message.
    if (w.status == AVAssetWriterStatusFailed) {
      NSLog(@"[MacScreenRecorder] writer FAILED before stop: %@", w.error);
      [w cancelWriting];
      NSError *e = [self errorWithCode:-6
          message:[NSString stringWithFormat:@"writer failed mid-record: %@", diag]];
      dispatch_async(dispatch_get_main_queue(), ^{ completion(e); });
      cleanup();
      return;
    }

    // No video frames ever arrived -> nothing valid to finalize.
    if (!self.writerStarted || w.status != AVAssetWriterStatusWriting) {
      [w cancelWriting];
      NSError *e = streamErr ?: [self errorWithCode:-3
          message:[NSString stringWithFormat:@"no frames: %@", diag]];
      dispatch_async(dispatch_get_main_queue(), ^{ completion(e); });
      cleanup();
      return;
    }

    // AVFoundation requires EVERY input added to the writer to be marked
    // finished before finishWriting (else it stalls). So mark all added inputs.
    [self.videoInput markAsFinished];
    if (self.hasSystemAudioInput) [self.systemAudioInput markAsFinished];
    if (self.hasMicInput) [self.micAudioInput markAsFinished];

    [w finishWritingWithCompletionHandler:^{
      NSError *err = nil;
      if (w.status == AVAssetWriterStatusFailed) {
        err = [self errorWithCode:-7
            message:[NSString stringWithFormat:@"finishWriting failed: %@ | %@",
                     w.error.localizedDescription ?: @"?", diag]];
        NSLog(@"[MacScreenRecorder] finishWriting FAILED: %@", w.error);
      } else {
        NSLog(@"[MacScreenRecorder] finishWriting OK (%@) -> %@", diag, self.outputPath);
      }
      dispatch_async(dispatch_get_main_queue(), ^{ completion(err); });
      cleanup();
    }];
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
    self.hasSystemAudioInput = YES;
  } else {
    self.systemAudioInput = nil;
  }

  // 48 kHz to match the normalized mic delivery format (and the system-audio
  // track) — no rate conversion anywhere. Hardcoding 44100 here while the mic
  // delivers 48k was the prime suspect for the corrupt-MP4 + pitch issues.
  NSDictionary *micAudioSettings = @{
    AVFormatIDKey: @(kAudioFormatMPEG4AAC),
    AVNumberOfChannelsKey: @2,
    AVSampleRateKey: @48000,
    AVEncoderBitRateKey: @(160 * 1000),
  };
  self.micAudioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                          outputSettings:micAudioSettings];
  self.micAudioInput.expectsMediaDataInRealTime = YES;
  if ([self.writer canAddInput:self.micAudioInput]) {
    [self.writer addInput:self.micAudioInput];
    self.hasMicInput = YES;
  } else {
    self.micAudioInput = nil;
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
      // Normalize the mic delivery format to interleaved 16-bit stereo @ 48 kHz
      // so it MATCHES the SCK system-audio shape. Without this the mic delivers
      // its native format (often mono / float / a non-48k hardware rate), which
      // forces extra conversion in the AAC encoder and is a corruption risk.
      // Same shape for both audio sources = one predictable path into the muxer.
      micOutput.audioSettings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @48000,
        AVNumberOfChannelsKey: @2,
        AVLinearPCMBitDepthKey: @16,
        AVLinearPCMIsFloatKey: @NO,
        AVLinearPCMIsBigEndianKey: @NO,
        AVLinearPCMIsNonInterleaved: @NO,
      };
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
        // Written here on the video queue, read on the audio queues (see
        // audioBufferWithinSession:) — guard the cross-thread CMTime store.
        @synchronized(self) { self.sessionStartPts = pts; }  // audio before this is dropped
        self.writerStarted = YES;
      } else {
        return;
      }
    }

    if ([self appendSample:sampleBuffer toInput:self.videoInput track:@"video"]) {
      self.videoSamples++;
    }
    return;
  }

  if (type == SCStreamOutputTypeAudio) {
    if (!self.writerStarted) return;        // audio before the video session start
    if (!self.hasSystemAudioInput) return;  // input not attached to the writer
    // Drop buffers that predate the writer session — appending one fails the
    // writer mid-record (the intermittent no-moov corruption). SCK system audio
    // shares the SCStream clock with video, so this rarely fires, but the very
    // first audio buffer can still lead the first accepted video frame.
    if (![self audioBufferWithinSession:sampleBuffer]) {
      self.systemAudioDropped++;
      return;
    }
    // Capture the SCK audio format ONCE into a property so the stop-result diag
    // can carry it back to Dart (hollow_debug.log — NSLog is invisible over SSH).
    // This is the ASBD the AAC encoder must accept; a mismatch is what throws
    // OSStatus -12785 (kAudioCodecBadData) -> the corrupt-MP4 trigger.
    if (self.sysAudioAsbd == nil) {
      CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
      const AudioStreamBasicDescription *a =
          fmt ? CMAudioFormatDescriptionGetStreamBasicDescription(fmt) : NULL;
      if (a) {
        self.sysAudioAsbd = [NSString stringWithFormat:
            @"rate=%.0f ch=%u bits=%u flags=0x%x(f=%d planar=%d) bpf=%u fpp=%u",
            a->mSampleRate, a->mChannelsPerFrame, a->mBitsPerChannel,
            (unsigned)a->mFormatFlags,
            (a->mFormatFlags & kAudioFormatFlagIsFloat) ? 1 : 0,
            (a->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : 0,
            a->mBytesPerFrame, a->mFramesPerPacket];
        NSLog(@"[MacScreenRecorder] SCK sysaudio ASBD: %@", self.sysAudioAsbd);
      }
    }
    // Append SCK's system-audio sample buffer DIRECTLY (no custom gain rebuild).
    // The hand-rolled gainedCopyOfSampleBuffer rebuilds the CMSampleBuffer and is
    // the prime suspect for the pitch-down ("bass boost") on macOS 15 / stock
    // libwebrtc. Correct pitch matters more than the +6 dB boost; reinstate a
    // safe gain later once the format is confirmed.
    if ([self appendSample:sampleBuffer toInput:self.systemAudioInput track:@"sysaudio"]) {
      self.systemAudioSamples++;
    }
    return;
  }
}

#pragma mark - Microphone capture

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
  if (!self.recording || !self.writerStarted) return;
  if (!self.hasMicInput) return;  // input not attached to the writer
  if (!CMSampleBufferIsValid(sampleBuffer)) return;

  // The mic is a SEPARATE AVCaptureSession with its OWN hardware clock, started
  // before the first SCK video frame — so its early buffers routinely predate
  // the writer session start. Appending one of those flips the writer to Failed
  // and the file finalizes with no moov atom (the intermittent corruption).
  // Drop anything earlier than the session start.
  if (![self audioBufferWithinSession:sampleBuffer]) {
    self.micDropped++;
    return;
  }

  // Append directly (no custom gain rebuild — see system-audio note above).
  if ([self appendSample:sampleBuffer toInput:self.micAudioInput track:@"mic"]) {
    self.micSamples++;
  }
}

#pragma mark - Session gating

/// YES if [sampleBuffer]'s presentation timestamp is at or after the writer
/// session start. Audio from independent clocks can arrive before the session
/// was started (at the first video frame's PTS); appending a pre-session sample
/// makes AVAssetWriter fail mid-record. Returns NO (drop) until the first video
/// frame has established the session start.
- (BOOL)audioBufferWithinSession:(CMSampleBufferRef)sampleBuffer {
  CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  if (CMTIME_IS_INVALID(pts)) return NO;
  // sessionStartPts is written on the video queue and read here on the audio
  // queues — guard the cross-thread CMTime read against a torn read.
  CMTime start;
  @synchronized(self) { start = self.sessionStartPts; }
  if (CMTIME_IS_INVALID(start)) return NO;
  return CMTimeCompare(pts, start) >= 0;
}

/// Append [sampleBuffer] to [input] safely. The CRITICAL guard is
/// writer.status == Writing BEFORE every append: once ANY append flips the
/// writer to Failed (one track's rejected buffer), continuing to append on the
/// OTHER tracks keeps a dead writer dead and guarantees finishWriting can't
/// produce a moov -> corrupt MP4. So the first track to fail records the trigger
/// (firstFailTrack + the writer error at that instant) and every track then
/// stops appending. Returns YES if the sample was appended.
- (BOOL)appendSample:(CMSampleBufferRef)sampleBuffer
             toInput:(AVAssetWriterInput *)input
               track:(NSString *)track {
  AVAssetWriter *w = self.writer;
  if (!w || w.status != AVAssetWriterStatusWriting) {
    if (w && w.status == AVAssetWriterStatusFailed && self.firstFailTrack == nil) {
      // Failed before THIS track even tried — another track was the trigger.
      self.firstFailTrack = [NSString stringWithFormat:@"%@(after)", track];
    }
    return NO;
  }
  if (!input.readyForMoreMediaData) return NO;
  if ([input appendSampleBuffer:sampleBuffer]) return YES;

  // Append returned NO — capture the trigger ONCE (the first track to fail).
  if (self.firstFailTrack == nil) {
    NSError *e = w.error;
    NSError *u = e.userInfo[NSUnderlyingErrorKey];
    self.firstFailTrack = [NSString stringWithFormat:@"%@ [%@ %ld / %@ %ld %@]",
        track, e.domain ?: @"-", (long)e.code,
        u.domain ?: @"-", (long)u.code, u.localizedDescription ?: @"-"];
    NSLog(@"[MacScreenRecorder] FIRST append fail on %@: %@", track, self.firstFailTrack);
  }
  return NO;
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
