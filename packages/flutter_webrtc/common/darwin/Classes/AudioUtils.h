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
// Hollow fork (#154): configure playAndRecord and the start route for a call
// the OS is about to own, WITHOUT activating; strips MixWithOthers.
+ (void)prepareForCall:(BOOL)loud;
@end

// Hollow fork (#154): the ONE owner of the call audio session on iOS once the
// app runs calls through CallKit (DESIGN_OS_CALLS 2.2). WebRTC runs on manual
// audio for the whole process; audio is enabled only while CallKit activated
// the session, a fallback session holds it, or the safety net does. The fork
// never calls setActive itself. Main thread only.
extern NSString* const HollowCallAudioActivatedNotification;
// CallKit took its session down (or dropped it in a reset).
extern NSString* const HollowCallKitAudioDeactivatedNotification;

@interface HollowCallAudio : NSObject
// Before the engine runs Dart: manual audio for the process from now on.
+ (void)enableCallKitMode;
+ (BOOL)callKitMode;
// MixWithOthers ON while no CallKit call exists, OFF while one does: the ONE
// rule every fork site that builds category options goes through.
+ (AVAudioSessionCategoryOptions)categoryOptions:(AVAudioSessionCategoryOptions)options;
// A CallKit call was requested / ended or forgotten (counted).
+ (void)callKitCallBegan;
+ (void)callKitCallEnded;
+ (NSInteger)callKitCalls;
// providerDidReset: CallKit dropped its calls and its audio.
+ (void)callKitReset;
+ (void)callKitDidActivate:(AVAudioSession*)session;
+ (void)callKitDidDeactivate:(AVAudioSession*)session;
// CallKit's session is still up: true from didActivate to didDeactivate, so
// for a moment after the last CallKit call ended.
+ (BOOL)callKitAudioActive;
// A session running without CallKit (counted): activates through the owner.
+ (void)fallbackBegan;
+ (void)fallbackEnded;
+ (NSInteger)fallbackCount;
// The plugin's fail-open net (2.4b).
+ (void)setSafetyNet:(BOOL)on;
// Something holds the session active right now.
+ (BOOL)ownerActive;
// No call holds the session: back to the category for the app's own sounds
// (ambient: mixes with other audio, a headset first, else the loudspeaker).
// A call leaves playAndRecord behind, whose default output is the earpiece.
+ (void)restoreSoundsCategoryIfIdle;
@end

#endif
