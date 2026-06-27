#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Captures system audio output on macOS 13.0+ via ScreenCaptureKit
/// (audio-only SCStream) and delivers it as raw interleaved 16-bit PCM
/// (48 kHz, stereo) through [onPcm].
///
/// This is the macOS SEND path for screen-share audio on macOS 13.0–14.1,
/// where the CoreAudio Process Tap ([MacScreenShareAudioTap], 14.2+) is not
/// available. The PCM is handed to Dart, encoded to Opus by the bundled
/// `screen_audio_capturer --mode encode` helper, and sent over the WebRTC data
/// channel (frame type 0x03) — the same wire the Windows WASAPI sender uses.
///
/// Unlike [MacScreenShareAudioTap], this does NOT touch the system default
/// input device: it taps audio directly out of an SCStream, so the user's mic
/// routing is untouched and the voice call's own mic track is unaffected.
///
/// Requires the Screen Recording TCC permission (same scope the screen-share
/// video already requests). The class is a singleton — one capture at a time.
@interface MacScreenShareAudioCapturer : NSObject

+ (instancetype)sharedInstance;

/// Begin capturing system audio. [onPcm] is invoked on a background queue with
/// interleaved 16-bit PCM (48 kHz stereo). Returns YES on success; on failure
/// (or pre-13.0) returns NO and fills [error].
- (BOOL)startWithCallback:(void (^)(NSData *pcm))onPcm
                    error:(NSError * _Nullable * _Nullable)error;

/// Stop capturing and tear down the SCStream. Safe to call multiple times.
- (void)stop;

/// Whether capture is currently active.
@property(nonatomic, readonly, getter=isActive) BOOL active;

@end

NS_ASSUME_NONNULL_END
