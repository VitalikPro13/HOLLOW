//
//  FlutterSocketConnectionAudioReader.m
//
//  See the header for why audio has its own socket + framing. The parser
//  below is a plain byte accumulator: it can split/merge reads arbitrarily
//  and never desyncs as long as the sender writes well-formed
//  [uint32_le length][payload] frames back-to-back.
//

#import "FlutterSocketConnectionAudioReader.h"
#import "FlutterSocketConnection.h"

static const NSUInteger kAudioReadChunk = 8 * 1024;
// PCM chunks are ~2-8 KB; anything above this means a desynced/hostile
// stream — reset rather than allocate unbounded.
static const uint32_t kAudioMaxFrame = 1 * 1024 * 1024;

@interface FlutterSocketConnectionAudioReader () <NSStreamDelegate>

@property(nonatomic, strong, nullable) FlutterSocketConnection* connection;
@property(nonatomic, strong) NSMutableData* buffer;

@end

@implementation FlutterSocketConnectionAudioReader

- (void)startWithConnection:(FlutterSocketConnection*)connection {
  self.buffer = [NSMutableData data];
  self.connection = connection;
  [self.connection openWithStreamDelegate:self];
}

- (void)stop {
  [self.connection close];
  self.connection = nil;
  self.buffer = nil;
}

// MARK: Private

- (void)readBytesFromStream:(NSInputStream*)stream {
  if (!stream.hasBytesAvailable || self.buffer == nil) {
    return;
  }

  uint8_t chunk[kAudioReadChunk];
  NSInteger bytesRead = [stream read:chunk maxLength:kAudioReadChunk];
  if (bytesRead <= 0) {
    return;
  }
  [self.buffer appendBytes:chunk length:(NSUInteger)bytesRead];

  // Drain every complete [u32le len][payload] frame.
  while (self.buffer.length >= 4) {
    uint32_t frameLen = 0;
    memcpy(&frameLen, self.buffer.bytes, 4);
    frameLen = CFSwapInt32LittleToHost(frameLen);

    if (frameLen == 0 || frameLen > kAudioMaxFrame) {
      NSLog(@"[HollowBroadcastAudio] bad frame length %u, resetting", frameLen);
      self.buffer.length = 0;
      return;
    }
    if (self.buffer.length < 4 + (NSUInteger)frameLen) {
      return;  // incomplete — wait for more bytes
    }

    NSData* pcm = [self.buffer subdataWithRange:NSMakeRange(4, frameLen)];
    void (^handler)(NSData*) = self.onAudioData;
    if (handler) {
      handler(pcm);
    }
    [self.buffer replaceBytesInRange:NSMakeRange(0, 4 + frameLen)
                           withBytes:NULL
                              length:0];
  }
}

@end

@implementation FlutterSocketConnectionAudioReader (NSStreamDelegate)

- (void)stream:(NSStream*)aStream handleEvent:(NSStreamEvent)eventCode {
  switch (eventCode) {
    case NSStreamEventOpenCompleted:
      NSLog(@"[HollowBroadcastAudio] server stream open completed");
      break;
    case NSStreamEventHasBytesAvailable:
      [self readBytesFromStream:(NSInputStream*)aStream];
      break;
    case NSStreamEventEndEncountered:
      NSLog(@"[HollowBroadcastAudio] server stream end encountered");
      break;
    case NSStreamEventErrorOccurred:
      NSLog(@"[HollowBroadcastAudio] server stream error: %@",
            aStream.streamError.localizedDescription);
      break;
    default:
      break;
  }
}

@end
