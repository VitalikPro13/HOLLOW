#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Provides an audio source for local screen recording that mixes the user's
/// default microphone with system audio output (other call participants,
/// alerts, music). Implemented via macOS 14.2+ CoreAudio Process Tap +
/// Aggregate Device, exposed to AVFoundation so ffmpeg's `avfoundation`
/// indev can consume it.
///
/// Unlike `MacScreenShareAudioTap`, this does NOT swap the system default
/// input — WebRTC keeps using the plain mic, so remote peers don't hear
/// themselves echoed.
///
/// Singleton — only one recording audio source active at a time.
@interface MacRecordingAudioDevice : NSObject

+ (instancetype)sharedInstance;

/// Create the tap + aggregate device, return the avfoundation audio device
/// index (the position ffmpeg expects after `:`). Returns -1 on failure.
- (NSInteger)startWithError:(NSError * _Nullable * _Nullable)error;

/// Tear down tap and aggregate. Safe to call multiple times.
- (void)stop;

/// Avfoundation index for the first screen-capture pseudo-device — i.e. the
/// number of physical video devices, since ffmpeg appends screens after them.
+ (NSInteger)screenCaptureIndex;

/// Avfoundation index for the system default input device (the user's mic),
/// or -1 if not found. Used as a fallback when the tap can't be created.
+ (NSInteger)defaultMicIndex;

@property(nonatomic, readonly, getter=isActive) BOOL active;

@end

NS_ASSUME_NONNULL_END
