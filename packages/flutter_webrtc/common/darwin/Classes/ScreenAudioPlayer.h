#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Hollow fork: native PCM player for RECEIVED screen-share audio on iOS.
 *
 * The desktop app decodes + plays shared audio in an out-of-process exe; a
 * phone can't spawn one, so Dart decodes the Opus frames in Rust and streams
 * raw PCM here via the startScreenAudioPlayer / writeScreenAudioPcm /
 * stopScreenAudioPlayer method channel.
 *
 * Plays via AudioQueue (mirrors the desktop audio_player_mac.cpp), rendering
 * into the call's existing AVAudioSession WITHOUT changing its category — a
 * WebRTC call owns a playAndRecord/voiceChat session, and switching it
 * mid-call would disrupt the call audio. Hardware AEC on iOS processes the
 * mic CAPTURE, not this independent playback render, so the shared music is
 * not mangled by the call's echo cancellation.
 *
 * PCM is interleaved 48 kHz stereo signed-16-bit little-endian.
 */
@interface ScreenAudioPlayer : NSObject

/// Start the audio queue. Returns NO on failure.
- (BOOL)start;

/// Enqueue one decoded PCM buffer (interleaved 48 kHz stereo s16le). Thread
/// safe; non-blocking. Drops oldest samples when the jitter buffer overruns.
- (void)write:(NSData *)pcm;

/// Stop and tear down the audio queue.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
