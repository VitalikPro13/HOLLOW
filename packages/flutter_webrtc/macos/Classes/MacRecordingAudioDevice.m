#import "MacRecordingAudioDevice.h"

#import <CoreAudio/CoreAudio.h>
#import <AVFoundation/AVFoundation.h>

#if __has_include(<CoreAudio/AudioHardwareTapping.h>)
#import <CoreAudio/AudioHardwareTapping.h>
#endif

static NSString * const kDomain = @"MacRecordingAudioDevice";

@interface MacRecordingAudioDevice ()
@property(nonatomic) AudioObjectID tapObjectID;
@property(nonatomic) AudioObjectID aggregateDeviceID;
@property(nonatomic, copy, nullable) NSString *aggregateUID;
@property(nonatomic) BOOL active;
@end

@implementation MacRecordingAudioDevice

+ (instancetype)sharedInstance {
  static MacRecordingAudioDevice *instance;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ instance = [[MacRecordingAudioDevice alloc] init]; });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _tapObjectID = kAudioObjectUnknown;
    _aggregateDeviceID = kAudioObjectUnknown;
  }
  return self;
}

#pragma mark - Public

- (NSInteger)startWithError:(NSError **)error {
  if (self.active && self.aggregateUID) {
    NSInteger idx = [MacRecordingAudioDevice avfoundationAudioIndexForUID:self.aggregateUID];
    if (idx >= 0) return idx;
  }

  if (@available(macOS 14.2, *)) {
    NSString *micUID = [self currentDefaultInputDeviceUID];

    AudioObjectID tapID = kAudioObjectUnknown;
    if (![self createTap:&tapID error:error]) {
      [self stop];
      return -1;
    }
    self.tapObjectID = tapID;

    NSString *tapUID = [self uidForTap:tapID];
    if (tapUID.length == 0) {
      if (error) {
        *error = [NSError errorWithDomain:kDomain code:-2
                                 userInfo:@{NSLocalizedDescriptionKey: @"Failed to read tap UID"}];
      }
      [self stop];
      return -1;
    }

    NSString *aggregateUID = [NSString stringWithFormat:@"com.anonlisten.hollow.recording.%@",
                              [NSUUID UUID].UUIDString];
    AudioObjectID aggID = kAudioObjectUnknown;
    if (![self createAggregateWithMicUID:micUID tapUID:tapUID aggregateUID:aggregateUID
                                    outID:&aggID error:error]) {
      [self stop];
      return -1;
    }
    self.aggregateDeviceID = aggID;
    self.aggregateUID = aggregateUID;

    // Block briefly until AVFoundation sees the freshly-created aggregate.
    NSInteger idx = -1;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.8];
    while ([NSDate.date compare:deadline] == NSOrderedAscending) {
      idx = [MacRecordingAudioDevice avfoundationAudioIndexForUID:aggregateUID];
      if (idx >= 0) break;
      [NSThread sleepForTimeInterval:0.03];
    }

    if (idx < 0) {
      if (error) {
        *error = [NSError errorWithDomain:kDomain code:-4
                                 userInfo:@{NSLocalizedDescriptionKey:
                                              @"Aggregate device not visible to AVFoundation"}];
      }
      [self stop];
      return -1;
    }

    self.active = YES;
    return idx;
  }

  if (error) {
    *error = [NSError errorWithDomain:kDomain code:-1
                             userInfo:@{NSLocalizedDescriptionKey:
                                          @"System audio capture requires macOS 14.2 or later"}];
  }
  return -1;
}

- (void)stop {
  if (@available(macOS 14.2, *)) {
    if (self.aggregateDeviceID != kAudioObjectUnknown) {
      AudioHardwareDestroyAggregateDevice(self.aggregateDeviceID);
      self.aggregateDeviceID = kAudioObjectUnknown;
    }
    if (self.tapObjectID != kAudioObjectUnknown) {
      AudioHardwareDestroyProcessTap(self.tapObjectID);
      self.tapObjectID = kAudioObjectUnknown;
    }
  }
  self.aggregateUID = nil;
  self.active = NO;
}

+ (NSInteger)screenCaptureIndex {
  // ffmpeg's avfoundation indev appends `Capture screen N` pseudo-devices
  // after the real video devices. So the first screen index equals the
  // count of physical video devices.
  NSArray<AVCaptureDevice *> *videos = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
  return (NSInteger)videos.count;
}

+ (NSInteger)defaultMicIndex {
  AudioObjectID deviceID = kAudioObjectUnknown;
  UInt32 size = sizeof(deviceID);
  AudioObjectPropertyAddress addr = {
    kAudioHardwarePropertyDefaultInputDevice,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain,
  };
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &deviceID) != noErr
      || deviceID == kAudioObjectUnknown) {
    return -1;
  }
  CFStringRef cfUID = NULL;
  size = sizeof(cfUID);
  AudioObjectPropertyAddress uidAddr = {
    kAudioDevicePropertyDeviceUID,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain,
  };
  if (AudioObjectGetPropertyData(deviceID, &uidAddr, 0, NULL, &size, &cfUID) != noErr || cfUID == NULL) {
    return -1;
  }
  NSString *uid = (__bridge_transfer NSString *)cfUID;
  return [self avfoundationAudioIndexForUID:uid];
}

#pragma mark - Helpers

+ (NSInteger)avfoundationAudioIndexForUID:(NSString *)uid {
  if (uid.length == 0) return -1;
  // Deprecated but still returns aggregate devices (the modern
  // AVCaptureDeviceDiscoverySession doesn't expose aggregate types).
  NSArray<AVCaptureDevice *> *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio];
  for (NSInteger i = 0; i < (NSInteger)devices.count; i++) {
    if ([devices[i].uniqueID isEqualToString:uid]) return i;
  }
  return -1;
}

- (BOOL)createTap:(AudioObjectID *)outID error:(NSError **)error API_AVAILABLE(macos(14.2)) {
  CATapDescription *desc = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
  desc.muteBehavior = CATapUnmuted;
  desc.exclusive = NO;
  desc.mixdown = YES;
  desc.privateTap = YES;
  desc.name = @"Hollow Recording Tap";

  AudioObjectID tapID = kAudioObjectUnknown;
  OSStatus s = AudioHardwareCreateProcessTap(desc, &tapID);
  if (s != noErr || tapID == kAudioObjectUnknown) {
    if (error) {
      *error = [NSError errorWithDomain:kDomain code:s
                               userInfo:@{NSLocalizedDescriptionKey:
                                            [NSString stringWithFormat:@"AudioHardwareCreateProcessTap failed: %d", (int)s]}];
    }
    return NO;
  }
  *outID = tapID;
  return YES;
}

- (BOOL)createAggregateWithMicUID:(NSString * _Nullable)micUID
                            tapUID:(NSString *)tapUID
                      aggregateUID:(NSString *)aggregateUID
                              outID:(AudioObjectID *)outID
                              error:(NSError **)error API_AVAILABLE(macos(14.2)) {
  NSMutableArray *subDeviceList = [NSMutableArray array];
  if (micUID.length > 0) {
    [subDeviceList addObject:@{ @(kAudioSubDeviceUIDKey): micUID }];
  }
  [subDeviceList addObject:@{ @(kAudioSubTapUIDKey): tapUID }];

  // NOT private: ffmpeg runs in a separate subprocess and would otherwise
  // not see the aggregate device. We tear it down on stop() so it doesn't
  // leak into the system device list permanently.
  NSDictionary *desc = @{
    @(kAudioAggregateDeviceUIDKey): aggregateUID,
    @(kAudioAggregateDeviceNameKey): @"Hollow Recording Mix",
    @(kAudioAggregateDeviceIsPrivateKey): @NO,
    @(kAudioAggregateDeviceIsStackedKey): @NO,
    @(kAudioAggregateDeviceTapListKey): @[@{@(kAudioSubTapUIDKey): tapUID}],
    @(kAudioAggregateDeviceSubDeviceListKey): subDeviceList,
  };

  AudioObjectID aggID = kAudioObjectUnknown;
  OSStatus s = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)desc, &aggID);
  if (s != noErr || aggID == kAudioObjectUnknown) {
    if (error) {
      *error = [NSError errorWithDomain:kDomain code:s
                               userInfo:@{NSLocalizedDescriptionKey:
                                            [NSString stringWithFormat:@"AudioHardwareCreateAggregateDevice failed: %d", (int)s]}];
    }
    return NO;
  }
  *outID = aggID;
  return YES;
}

- (NSString * _Nullable)currentDefaultInputDeviceUID {
  AudioObjectID deviceID = kAudioObjectUnknown;
  UInt32 size = sizeof(deviceID);
  AudioObjectPropertyAddress addr = {
    kAudioHardwarePropertyDefaultInputDevice,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain,
  };
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &deviceID) != noErr
      || deviceID == kAudioObjectUnknown) {
    return nil;
  }
  CFStringRef cfUID = NULL;
  size = sizeof(cfUID);
  AudioObjectPropertyAddress uidAddr = {
    kAudioDevicePropertyDeviceUID,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain,
  };
  if (AudioObjectGetPropertyData(deviceID, &uidAddr, 0, NULL, &size, &cfUID) != noErr || cfUID == NULL) {
    return nil;
  }
  return (__bridge_transfer NSString *)cfUID;
}

- (NSString * _Nullable)uidForTap:(AudioObjectID)tapID API_AVAILABLE(macos(14.2)) {
  CFStringRef cfUID = NULL;
  UInt32 size = sizeof(cfUID);
  AudioObjectPropertyAddress addr = {
    kAudioTapPropertyUID,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain,
  };
  if (AudioObjectGetPropertyData(tapID, &addr, 0, NULL, &size, &cfUID) != noErr || cfUID == NULL) {
    return nil;
  }
  return (__bridge_transfer NSString *)cfUID;
}

@end
