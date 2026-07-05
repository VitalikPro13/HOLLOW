//
//  FlutterBroadcastScreenCapturer.h
//  RCTWebRTC
//
//  Created by Alex-Dan Bumbu on 06/01/2021.
//

#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>
NS_ASSUME_NONNULL_BEGIN

extern NSString* const kRTCScreensharingSocketFD;
extern NSString* const kRTCAppGroupIdentifier;
extern NSString* const kRTCScreenSharingExtension;

@class FlutterSocketConnectionFrameReader;

@interface FlutterBroadcastScreenCapturer : RTCVideoCapturer

// Hollow fork: fired for each app-audio PCM chunk (48 kHz stereo s16le) the
// broadcast extension sends alongside the video frames. Set BEFORE
// startCapture. Called on the socket's network thread.
@property(nonatomic, copy, nullable) void (^onAudioData)(NSData* pcm);

- (void)startCapture;
- (void)stopCapture;
- (void)stopCaptureWithCompletionHandler:(nullable void (^)(void))completionHandler;

@end

NS_ASSUME_NONNULL_END
