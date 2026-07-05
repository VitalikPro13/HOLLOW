//
//  FlutterSocketConnectionAudioReader.h
//
//  Hollow fork: server-side reader for the broadcast extension's app-audio
//  PCM socket (rtc_SSFD_audio). Audio deliberately rides its OWN App-Group
//  socket with a trivial [uint32_le length][payload] framing: interleaving
//  small audio messages with video frames on the CFHTTPMessage socket wedges
//  the stock frame parser permanently (a read that completes one message and
//  carries the start of the next inflates the body past Content-Length, so
//  "missing bytes" goes negative and never reaches zero — device-proven
//  2026-07-04: exactly 4 audio packets arrived, then the stream died).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class FlutterSocketConnection;

@interface FlutterSocketConnectionAudioReader : NSObject

// Fired (on the socket's network thread) with each PCM chunk
// (interleaved 48 kHz stereo s16le) from the broadcast extension.
@property(nonatomic, copy, nullable) void (^onAudioData)(NSData* pcm);

- (void)startWithConnection:(nonnull FlutterSocketConnection*)connection;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
