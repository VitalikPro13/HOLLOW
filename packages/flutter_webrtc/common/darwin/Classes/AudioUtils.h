#if TARGET_OS_IPHONE

#import <WebRTC/WebRTC.h>

@interface AudioUtils : NSObject
+ (void)ensureAudioSessionWithRecording:(BOOL)recording;
// needed for wired headphones to use headphone mic
+ (BOOL)selectAudioInput:(AVAudioSessionPort)type;
+ (void)setSpeakerphoneOn:(BOOL)enable;
+ (void)setSpeakerphoneOnButPreferBluetooth;
// Hollow fork: YES when a headset / BT / USB / CarPlay device is physically
// attached, even while a loudspeaker override is hiding it from currentRoute.
+ (BOOL)hasExternalAudioRoute;
+ (void)deactiveRtcAudioSession;
+ (void) setAppleAudioConfiguration:(NSDictionary*)configuration;
@end

#endif
