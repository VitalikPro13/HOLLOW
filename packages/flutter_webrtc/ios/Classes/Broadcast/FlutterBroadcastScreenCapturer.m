//
//  FlutterBroadcastScreenCapturer.m
//  RCTWebRTC
//
//  Created by Alex-Dan Bumbu on 06/01/2021.
//

#import "FlutterBroadcastScreenCapturer.h"
#import "FlutterSocketConnection.h"
#import "FlutterSocketConnectionAudioReader.h"
#import "FlutterSocketConnectionFrameReader.h"

NSString* const kRTCScreensharingSocketFD = @"rtc_SSFD";
// Hollow fork: separate socket for broadcast app-audio PCM — small audio
// messages interleaved on the video socket wedge the CFHTTPMessage parser
// (see FlutterSocketConnectionAudioReader.h).
NSString* const kRTCScreensharingAudioSocketFD = @"rtc_SSFD_audio";
NSString* const kRTCAppGroupIdentifier = @"RTCAppGroupIdentifier";
NSString* const kRTCScreenSharingExtension = @"RTCScreenSharingExtension";

@interface FlutterBroadcastScreenCapturer ()

@property(nonatomic, retain) FlutterSocketConnectionFrameReader* capturer;
@property(nonatomic, retain) FlutterSocketConnectionAudioReader* audioReader;

@end

@interface FlutterBroadcastScreenCapturer (Private)

@property(nonatomic, readonly) NSString* appGroupIdentifier;

@end

@implementation FlutterBroadcastScreenCapturer

- (void)startCapture {
  if (!self.appGroupIdentifier) {
    return;
  }

  NSString* socketFilePath = [self filePathForApplicationGroupIdentifier:self.appGroupIdentifier];
  FlutterSocketConnectionFrameReader* frameReader =
      [[FlutterSocketConnectionFrameReader alloc] initWithDelegate:self.delegate];
  FlutterSocketConnection* connection =
      [[FlutterSocketConnection alloc] initWithFilePath:socketFilePath];
  self.capturer = frameReader;
  [self.capturer startCaptureWithConnection:connection];

  // Hollow fork: second server socket for the extension's app-audio PCM.
  NSString* audioSocketFilePath =
      [[socketFilePath stringByDeletingLastPathComponent]
          stringByAppendingPathComponent:kRTCScreensharingAudioSocketFD];
  FlutterSocketConnection* audioConnection =
      [[FlutterSocketConnection alloc] initWithFilePath:audioSocketFilePath];
  if (audioConnection) {
    FlutterSocketConnectionAudioReader* audioReader =
        [[FlutterSocketConnectionAudioReader alloc] init];
    audioReader.onAudioData = self.onAudioData;
    self.audioReader = audioReader;
    [self.audioReader startWithConnection:audioConnection];
  }
}

- (void)stopCapture {
  [self.capturer stopCapture];
  [self.audioReader stop];
  self.audioReader = nil;
}
- (void)stopCaptureWithCompletionHandler:(nullable void (^)(void))completionHandler {
  [self stopCapture];
  if (completionHandler != nil) {
    completionHandler();
  }
}
// MARK: Private Methods

- (NSString*)appGroupIdentifier {
  NSDictionary* infoDictionary = [[NSBundle mainBundle] infoDictionary];
  return infoDictionary[kRTCAppGroupIdentifier];
}

- (NSString*)filePathForApplicationGroupIdentifier:(nonnull NSString*)identifier {
  NSURL* sharedContainer =
      [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:identifier];
  NSString* socketFilePath =
      [[sharedContainer URLByAppendingPathComponent:kRTCScreensharingSocketFD] path];

  return socketFilePath;
}

@end
