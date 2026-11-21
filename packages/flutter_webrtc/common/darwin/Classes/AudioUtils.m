#if TARGET_OS_IPHONE
#import "AudioUtils.h"
#import <AVFoundation/AVFoundation.h>

@implementation AudioUtils

// Hollow fork: is a headset / BT / USB / CarPlay device physically attached?
//
// This exists because forcing the loudspeaker (overrideOutputAudioPort:
// .speaker) OVERRIDES a connected headset — the user is left wearing silent
// headphones while the call plays out of the phone, and iOS moves capture to
// the built-in mic with it. Every "speaker on" path must therefore ask this
// first.
//
// currentRoute alone is not enough: once an override is in effect the outputs
// list reports the built-in speaker and the headset vanishes from it. The
// headset's INPUT port stays listed in availableInputs regardless, so the two
// checks together survive an override that is already applied.
+ (BOOL)hasExternalAudioRoute {
  AVAudioSession* session = [AVAudioSession sharedInstance];
  for (AVAudioSessionPortDescription* output in session.currentRoute.outputs) {
    if (![output.portType isEqualToString:AVAudioSessionPortBuiltInSpeaker] &&
        ![output.portType isEqualToString:AVAudioSessionPortBuiltInReceiver]) {
      return YES;
    }
  }
  for (AVAudioSessionPortDescription* input in session.availableInputs) {
    if ([input.portType isEqualToString:AVAudioSessionPortHeadsetMic] ||
        [input.portType isEqualToString:AVAudioSessionPortBluetoothHFP] ||
        [input.portType isEqualToString:AVAudioSessionPortUSBAudio] ||
        [input.portType isEqualToString:AVAudioSessionPortCarAudio]) {
      return YES;
    }
  }
  return NO;
}

+ (void)ensureAudioSessionWithRecording:(BOOL)recording {
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  // we also need to set default WebRTC audio configuration, since it may be activated after
  // this method is called
  RTCAudioSessionConfiguration* config = [RTCAudioSessionConfiguration webRTCConfiguration];
  // require audio session to be either PlayAndRecord or MultiRoute
  if (recording && session.category != AVAudioSessionCategoryPlayAndRecord &&
      session.category != AVAudioSessionCategoryMultiRoute) {
    config.category = AVAudioSessionCategoryPlayAndRecord;
    // Hollow fork: MixWithOthers follows the ONE rule (HollowCallAudio
    // categoryOptions:): on while no CallKit call owns the session, so another
    // app's playback cannot interrupt it (device-proven 2026-07-05), off under
    // CallKit, which outranks it (#154). Keep the template's own flags: the
    // template carries route flags too (DefaultToSpeaker, baked in by
    // setSpeakerphoneOn), and a track add/dispose passing through here must
    // not clobber the user's speaker route.
    config.categoryOptions = [HollowCallAudio
        categoryOptions:config.categoryOptions |
                        AVAudioSessionCategoryOptionAllowBluetooth |
                        AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                        AVAudioSessionCategoryOptionAllowAirPlay];

    [session lockForConfiguration];
    NSError* error = nil;
    bool success = [session setCategory:config.category withOptions:config.categoryOptions error:&error];
    if (!success)
      NSLog(@"ensureAudioSessionWithRecording[true]: setCategory failed due to: %@", error);
    success = [session setMode:config.mode error:&error];
    if (!success)
      NSLog(@"ensureAudioSessionWithRecording[true]: setMode failed due to: %@", error);
    [session unlockForConfiguration];
  } else if (!recording && (session.category == AVAudioSessionCategoryAmbient ||
                            session.category == AVAudioSessionCategorySoloAmbient)) {
    config.mode = AVAudioSessionModeDefault;
    [session lockForConfiguration];
    NSError* error = nil;
    bool success = [session setMode:config.mode error:&error];
    if (!success)
      NSLog(@"ensureAudioSessionWithRecording[false]: setMode failed due to: %@", error);
    [session unlockForConfiguration];
  }
}

+ (BOOL)selectAudioInput:(AVAudioSessionPort)type {
  RTCAudioSession* rtcSession = [RTCAudioSession sharedInstance];
  AVAudioSessionPortDescription* inputPort = nil;
  for (AVAudioSessionPortDescription* port in rtcSession.session.availableInputs) {
    if ([port.portType isEqualToString:type]) {
      inputPort = port;
      break;
    }
  }
  if (inputPort != nil) {
    NSError* errOut = nil;
    [rtcSession lockForConfiguration];
    [rtcSession setPreferredInput:inputPort error:&errOut];
    [rtcSession unlockForConfiguration];
    if (errOut != nil) {
      return NO;
    }
    return YES;
  }
  return NO;
}

+ (void)setSpeakerphoneOn:(BOOL)enable {
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  RTCAudioSessionConfiguration* config = [RTCAudioSessionConfiguration webRTCConfiguration];

  // Hollow fork: make the speaker route DURABLE by baking it into libwebrtc's
  // own session template (same technique as the MixWithOthers patch in
  // initWithChannel). libwebrtc re-applies webRTCConfiguration whenever its
  // audio unit restarts (camera toggle, track churn, renegotiation) — with
  // only a live overrideOutputAudioPort the route silently reverted to the
  // earpiece moments into a call. The session MODE is the durable selector
  // Apple honors: videoChat defaults output to the loudspeaker, voiceChat to
  // the receiver (LiveKit's policy; both keep VPIO). The live set below still
  // runs for the immediate flip.
  if (enable) {
    config.categoryOptions |= AVAudioSessionCategoryOptionDefaultToSpeaker;
    config.mode = AVAudioSessionModeVideoChat;
  } else {
    config.categoryOptions &= ~AVAudioSessionCategoryOptionDefaultToSpeaker;
    config.mode = AVAudioSessionModeVoiceChat;
  }
  config.categoryOptions = [HollowCallAudio categoryOptions:config.categoryOptions];
  [RTCAudioSessionConfiguration setWebRTCConfiguration:config];

  if(enable && config.category != AVAudioSessionCategoryPlayAndRecord) {
    NSLog(@"setSpeakerphoneOn: Category option 'defaultToSpeaker' is only applicable with category 'playAndRecord', ignore.");
    return;
  }

  [session lockForConfiguration];
  NSError* error = nil;
  if (!enable) {
    [session setMode:config.mode error:&error];
    // Hollow fork: every rebuild of the option mask takes MixWithOthers from
    // the one rule (see ensureAudioSessionWithRecording).
    BOOL success = [session setCategory:config.category
                            withOptions:[HollowCallAudio
                                            categoryOptions:AVAudioSessionCategoryOptionAllowAirPlay |
                                                            AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                                                            AVAudioSessionCategoryOptionAllowBluetooth]
                                  error:&error];

    success = [session.session overrideOutputAudioPort:AVAudioSessionPortOverrideNone
                                                 error:&error];
    if (!success)
      NSLog(@"setSpeakerphoneOn: Port override failed due to: %@", error);
  } else {
    [session setMode:config.mode error:&error];
    BOOL success = [session setCategory:config.category
                            withOptions:[HollowCallAudio
                                            categoryOptions:AVAudioSessionCategoryOptionDefaultToSpeaker |
                                                            AVAudioSessionCategoryOptionAllowAirPlay |
                                                            AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                                                            AVAudioSessionCategoryOptionAllowBluetooth]
                                  error:&error];

    // Hollow fork fix: this passed kAudioSessionProperty_OverrideAudioRoute
    // ('ovrr' — a legacy PROPERTY SELECTOR, not a port-override VALUE) to
    // overrideOutputAudioPort:, so forcing the loudspeaker was a broken
    // no-op. The correct value is AVAudioSessionPortOverrideSpeaker
    // (== kAudioSessionOverrideAudioRoute_Speaker, as selectAudioOutput
    // already uses).
    //
    // Hollow fork: but NEVER force it over a connected headset. The override
    // outranks headphones/BT/USB, so a speaker-on default (voice channels,
    // video calls, camera-on, the share-audio re-assert below) used to strand
    // a headset user in silence with the call blaring from the phone. With a
    // headset attached, "speaker" degrades to 'no override' — DefaultToSpeaker
    // still lands us on the loudspeaker the moment it unplugs, and the
    // route-change heal re-asserts a real override then.
    const AVAudioSessionPortOverride routeOverride =
        [AudioUtils hasExternalAudioRoute] ? AVAudioSessionPortOverrideNone
                                           : AVAudioSessionPortOverrideSpeaker;
    success = [session.session overrideOutputAudioPort:routeOverride
                                                 error:&error];
    if (!success)
      NSLog(@"setSpeakerphoneOn: Port override failed due to: %@", error);
  }
  // Commit the route (mirrors setSpeakerphoneOnButPreferBluetooth) — without
  // an active session the override may not take effect. Under CallKit only the
  // OS or HollowCallAudio activates (#154); the baked template carries the route.
  if (![HollowCallAudio callKitMode]) {
    BOOL activated = [session setActive:YES error:&error];
    if (!activated)
      NSLog(@"setSpeakerphoneOn: setActive failed due to: %@", error);
  }
  [session unlockForConfiguration];
}

+ (void)setSpeakerphoneOnButPreferBluetooth {
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  RTCAudioSessionConfiguration* config = [RTCAudioSessionConfiguration webRTCConfiguration];
  [session lockForConfiguration];
  NSError* error = nil;
  [session setMode:config.mode error:&error];
  BOOL success = [session setCategory:config.category
                          withOptions:[HollowCallAudio
                                          categoryOptions:AVAudioSessionCategoryOptionAllowAirPlay |
                                                          AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                                                          AVAudioSessionCategoryOptionAllowBluetooth |
                                                          AVAudioSessionCategoryOptionDefaultToSpeaker]
                                error:&error];

  success = [session overrideOutputAudioPort:kAudioSessionOverrideAudioRoute_None
                                        error:&error];
  if (!success)
    NSLog(@"setSpeakerphoneOnButPreferBluetooth: Port override failed due to: %@", error);

  if (![HollowCallAudio callKitMode]) {
    success = [session setActive:YES error:&error];
    if (!success)
      NSLog(@"setSpeakerphoneOnButPreferBluetooth: Audio session override failed: %@", error);
  }
  [session unlockForConfiguration];
}

+ (void)deactiveRtcAudioSession {
  // Under CallKit only the OS or HollowCallAudio deactivates (#154).
  if ([HollowCallAudio callKitMode]) {
    return;
  }
  NSError* error = nil;
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  [session lockForConfiguration];
  if ([session isActive]) {
    BOOL success = [session setActive:NO error:&error];
    if (!success)
      NSLog(@"RTC Audio session deactive failed: %@", error);
    else
      NSLog(@"RTC AudioSession deactive is successful ");
  }
  [session unlockForConfiguration];
}


+ (AVAudioSessionMode)audioSessionModeFromString:(NSString*)mode {
  if([@"default_" isEqualToString:mode]) {
    return AVAudioSessionModeDefault;
  } else if([@"voicePrompt" isEqualToString:mode]) {
    return AVAudioSessionModeVoicePrompt;
  } else if([@"videoRecording" isEqualToString:mode]) {
    return AVAudioSessionModeVideoRecording;
  } else if([@"videoChat" isEqualToString:mode]) {
    return AVAudioSessionModeVideoChat;
  } else if([@"voiceChat" isEqualToString:mode]) {
    return AVAudioSessionModeVoiceChat;
  } else if([@"gameChat" isEqualToString:mode]) {
    return AVAudioSessionModeGameChat;
  } else if([@"measurement" isEqualToString:mode]) {
    return AVAudioSessionModeMeasurement;
  } else if([@"moviePlayback" isEqualToString:mode]) {
    return AVAudioSessionModeMoviePlayback;
  } else if([@"spokenAudio" isEqualToString:mode]) {
    return AVAudioSessionModeSpokenAudio;
  } 
  return AVAudioSessionModeDefault;
}

+ (AVAudioSessionCategory)audioSessionCategoryFromString:(NSString *)category {
  if([@"ambient" isEqualToString:category]) {
    return AVAudioSessionCategoryAmbient;
  } else if([@"soloAmbient" isEqualToString:category]) {
    return AVAudioSessionCategorySoloAmbient;
  } else if([@"playback" isEqualToString:category]) {
    return AVAudioSessionCategoryPlayback;
  } else if([@"record" isEqualToString:category]) {
    return AVAudioSessionCategoryRecord;
  } else if([@"playAndRecord" isEqualToString:category]) {
    return AVAudioSessionCategoryPlayAndRecord;
  } else if([@"multiRoute" isEqualToString:category]) {
    return AVAudioSessionCategoryMultiRoute;
  }
  return AVAudioSessionCategoryAmbient;
}

+ (void) setAppleAudioConfiguration:(NSDictionary*)configuration {
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  RTCAudioSessionConfiguration* config = [RTCAudioSessionConfiguration webRTCConfiguration];

  NSString* appleAudioCategory = configuration[@"appleAudioCategory"];
  NSArray* appleAudioCategoryOptions = configuration[@"appleAudioCategoryOptions"];
  NSString* appleAudioMode = configuration[@"appleAudioMode"];
  
  [session lockForConfiguration];

  if(appleAudioCategoryOptions != nil) {
    config.categoryOptions = 0;
    for(NSString* option in appleAudioCategoryOptions) {
      if([@"mixWithOthers" isEqualToString:option]) {
        config.categoryOptions |= AVAudioSessionCategoryOptionMixWithOthers;
      } else if([@"duckOthers" isEqualToString:option]) {
        config.categoryOptions |= AVAudioSessionCategoryOptionDuckOthers;
      } else if([@"allowBluetooth" isEqualToString:option]) {
        config.categoryOptions |= AVAudioSessionCategoryOptionAllowBluetooth;
      } else if([@"allowBluetoothA2DP" isEqualToString:option]) {
        config.categoryOptions |= AVAudioSessionCategoryOptionAllowBluetoothA2DP;
      } else if([@"allowAirPlay" isEqualToString:option]) {
        config.categoryOptions |= AVAudioSessionCategoryOptionAllowAirPlay;
      } else if([@"defaultToSpeaker" isEqualToString:option]) {
        config.categoryOptions |= AVAudioSessionCategoryOptionDefaultToSpeaker;
      }
    }
  }

  if(appleAudioCategory != nil) {
    config.category = [AudioUtils audioSessionCategoryFromString:appleAudioCategory];
    [session setCategory:config.category withOptions:config.categoryOptions error:nil];
  }

  if(appleAudioMode != nil) {
    config.mode = [AudioUtils audioSessionModeFromString:appleAudioMode];
    [session setMode:config.mode error:nil];
  }

  [session unlockForConfiguration];

}

+ (void)prepareForCall:(BOOL)loud {
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  RTCAudioSessionConfiguration* config = [RTCAudioSessionConfiguration webRTCConfiguration];
  AVAudioSessionCategoryOptions options = AVAudioSessionCategoryOptionAllowBluetooth |
                                          AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                                          AVAudioSessionCategoryOptionAllowAirPlay;
  if (loud) {
    options |= AVAudioSessionCategoryOptionDefaultToSpeaker;
  }
  config.category = AVAudioSessionCategoryPlayAndRecord;
  config.categoryOptions = [HollowCallAudio categoryOptions:options];
  config.mode = loud ? AVAudioSessionModeVideoChat : AVAudioSessionModeVoiceChat;
  [RTCAudioSessionConfiguration setWebRTCConfiguration:config];

  [session lockForConfiguration];
  NSError* error = nil;
  if (![session setCategory:config.category withOptions:config.categoryOptions error:&error])
    NSLog(@"prepareForCall: setCategory failed: %@", error);
  if (![session setMode:config.mode error:&error])
    NSLog(@"prepareForCall: setMode failed: %@", error);
  [session unlockForConfiguration];
}

@end

NSString* const HollowCallAudioActivatedNotification = @"HollowCallAudioActivated";

static BOOL gHollowCallKitMode = NO;
static NSInteger gHollowCallKitCalls = 0;
static BOOL gHollowCallKitAudioActive = NO;
static NSInteger gHollowFallback = 0;
static BOOL gHollowNet = NO;
// We activated the session ourselves (for a fallback session or the net).
static BOOL gHollowOwnActive = NO;

@implementation HollowCallAudio

+ (void)enableCallKitMode {
  if (gHollowCallKitMode) {
    return;
  }
  gHollowCallKitMode = YES;
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  session.useManualAudio = YES;
  session.isAudioEnabled = NO;
  NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
  [center addObserver:self
             selector:@selector(interruptionChanged:)
                 name:AVAudioSessionInterruptionNotification
               object:nil];
  [center addObserver:self
             selector:@selector(mediaServicesReset:)
                 name:AVAudioSessionMediaServicesWereResetNotification
               object:nil];
}

+ (BOOL)callKitMode {
  return gHollowCallKitMode;
}

+ (AVAudioSessionCategoryOptions)categoryOptions:(AVAudioSessionCategoryOptions)options {
  if (gHollowCallKitCalls > 0) {
    return options & ~AVAudioSessionCategoryOptionMixWithOthers;
  }
  // Without it another app's non-mixable playback INTERRUPTS a call session no
  // CallKit call owns, and a backgrounded call collapses (device-proven 2026-07-05).
  return options | AVAudioSessionCategoryOptionMixWithOthers;
}

+ (void)applyMixRuleToTemplate {
  RTCAudioSessionConfiguration* config = [RTCAudioSessionConfiguration webRTCConfiguration];
  config.categoryOptions = [self categoryOptions:config.categoryOptions];
  [RTCAudioSessionConfiguration setWebRTCConfiguration:config];
}

+ (void)callKitCallBegan {
  gHollowCallKitCalls++;
  [self applyMixRuleToTemplate];
  // The net covers a call no OS call holds; CallKit activates this one. Our
  // own hold is dropped (the session left alone if CallKit already has it).
  [self setSafetyNet:NO];
}

+ (void)callKitCallEnded {
  if (gHollowCallKitCalls > 0) {
    gHollowCallKitCalls--;
  }
  [self applyMixRuleToTemplate];
}

+ (NSInteger)callKitCalls {
  return gHollowCallKitCalls;
}

+ (void)callKitReset {
  gHollowCallKitCalls = 0;
  gHollowCallKitAudioActive = NO;
  [self applyMixRuleToTemplate];
  [self applyAudioEnabled];
  [self reactivateOwnHolders];
}

+ (void)callKitDidActivate:(AVAudioSession*)session {
  // RTCAudioSession first: it must count the activation before WebRTC's audio
  // unit starts and asks for one itself.
  [[RTCAudioSession sharedInstance] audioSessionDidActivate:session];
  gHollowCallKitAudioActive = YES;
  [self applyAudioEnabled];
  [[NSNotificationCenter defaultCenter] postNotificationName:HollowCallAudioActivatedNotification
                                                      object:nil];
}

+ (void)callKitDidDeactivate:(AVAudioSession*)session {
  gHollowCallKitAudioActive = NO;
  [self applyAudioEnabled];
  [[RTCAudioSession sharedInstance] audioSessionDidDeactivate:session];
  // CallKit took the session down with its call; a session still running
  // without CallKit gets it back.
  [self reactivateOwnHolders];
}

+ (void)fallbackBegan {
  gHollowFallback++;
  [self activateOwn];
  [self applyAudioEnabled];
}

+ (void)fallbackEnded {
  if (gHollowFallback > 0) {
    gHollowFallback--;
  }
  [self applyAudioEnabled];
  [self deactivateOwnIfIdle];
}

+ (NSInteger)fallbackCount {
  return gHollowFallback;
}

+ (void)setSafetyNet:(BOOL)on {
  if (gHollowNet == on) {
    return;
  }
  gHollowNet = on;
  if (on) {
    [self activateOwn];
  }
  [self applyAudioEnabled];
  if (!on) {
    [self deactivateOwnIfIdle];
  }
}

+ (BOOL)ownerActive {
  return gHollowCallKitAudioActive || gHollowOwnActive;
}

+ (void)applyAudioEnabled {
  const BOOL want = gHollowCallKitAudioActive || gHollowFallback > 0 || gHollowNet;
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  if (session.isAudioEnabled != want) {
    session.isAudioEnabled = want;
  }
}

+ (void)activateOwn {
  if (gHollowOwnActive) {
    return;
  }
  RTCAudioSession* rtc = [RTCAudioSession sharedInstance];
  AVAudioSession* av = [AVAudioSession sharedInstance];
  RTCAudioSessionConfiguration* config = [RTCAudioSessionConfiguration webRTCConfiguration];
  NSError* error = nil;
  [rtc lockForConfiguration];
  [rtc setCategory:config.category
       withOptions:[self categoryOptions:config.categoryOptions]
             error:&error];
  [rtc setMode:config.mode error:&error];
  const BOOL ok = [av setActive:YES error:&error];
  [rtc unlockForConfiguration];
  if (!ok) {
    NSLog(@"[HOLLOW-OSCALL] activating the call session failed: %@", error);
    return;
  }
  gHollowOwnActive = YES;
  // Counted like a CallKit activation; libwebrtc takes it as an interruption
  // end and (re)starts its audio unit.
  [rtc audioSessionDidActivate:av];
  [[NSNotificationCenter defaultCenter] postNotificationName:HollowCallAudioActivatedNotification
                                                      object:nil];
}

+ (void)deactivateOwnIfIdle {
  if (!gHollowOwnActive || gHollowFallback > 0 || gHollowNet) {
    return;
  }
  gHollowOwnActive = NO;
  if (gHollowCallKitAudioActive) {
    return;
  }
  AVAudioSession* av = [AVAudioSession sharedInstance];
  NSError* error = nil;
  if (![av setActive:NO
          withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                error:&error]) {
    NSLog(@"[HOLLOW-OSCALL] deactivating the call session failed: %@", error);
  }
  [[RTCAudioSession sharedInstance] audioSessionDidDeactivate:av];
}

+ (void)reactivateOwnHolders {
  if (gHollowCallKitAudioActive || !(gHollowFallback > 0 || gHollowNet)) {
    return;
  }
  gHollowOwnActive = NO;
  [self activateOwn];
}

// N3: Siri, an alarm or another app's call UI interrupted a session no CallKit
// call owns; nothing else would bring it back.
+ (void)interruptionChanged:(NSNotification*)notification {
  NSNumber* type = notification.userInfo[AVAudioSessionInterruptionTypeKey];
  if (type.unsignedIntegerValue != AVAudioSessionInterruptionTypeEnded) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [self reactivateOwnHolders];
  });
}

+ (void)mediaServicesReset:(NSNotification*)notification {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self reactivateOwnHolders];
  });
}

@end
#endif
