# OS call state: CallKit and Telecom (#154, 0.14.3)

The OS knows Hollow is in a call: iOS CallKit (pill, Dynamic Island, lock screen call UI,
OS mute, hold and hang-up), Android Jetpack core-telecom (CallStyle notification, Bluetooth,
watches, cars). It mirrors the DM call the app already runs, from the moment it is answered;
nothing in call core decides anything new. Vitalik, Nov 22 (device checks): ONLY DM calls become
system calls (iOS has no call screen for a room; rooms and meetings stay in the app, like
Discord), and a call we place reaches the OS once ANSWERED (ringing out under CallKit, the
ringback played as call audio, at the ear, whatever the route said). Design: c154-calls `.team/DESIGN_OS_CALLS.md` (revision 4),
decisions in its section 11. Android: `OsCallBridge.kt`, `HollowCallService.kt` (below).

## Dart (`os_call_provider.dart`, `os_call_service.dart`)

- `osSessionProvider` derives AT MOST ONE session from `callProvider`, `voiceChannelProvider`
  and `conferenceProvider` (`deriveOsSession`, pure): a DM call once answered (`connecting`,
  placed or accepted), else the voice room we sit in, `meet:<confId>` for a meeting's room. No
  ring is ever a session, ours or theirs (ring in Hollow only; the ringback is a plain app
  sound). Rooms and meetings stay sessions in Dart because `begin` is what gives them audio on
  iOS; native sends every non-DM `kind` straight to the fallback (no CallKit). A DM goes first:
  `acceptCall` sets connecting before it leaves the room. Phones build it (`osCallPlatform`),
  desktops nothing.
- Android only (`osCallRingOutService`): while a call we place rings out (`ringsOut`, no session),
  `ringOut {on, title}` keeps `HollowCallService` up with NO OS call, so the microphone type is
  taken while the app is in front and an answer that finds the app in the background still has
  a mic (Android refuses a mic foreground service from the background). Sent after the
  session's own steps, so an answered call's `begin` takes the service over before the ring lets
  it go. The ring-out shows a PLAIN notification (a foreground service must show one): title,
  "Calling", Hang up; never a CallStyle or `CATEGORY_CALL` (no call chip), since ringing out is
  no call to the system (`OsCallRules.showsAsCall`). Its Hang up sends `osRingOutEnd`:
  `endCall()` only while the call still rings out. Any end of the ring (declined, busy, timeout,
  cancelled, answered elsewhere) leaves `ringing` and sends `ringOut {on: false}`, which stops
  the service unless a session holds it. Probe key `osRingOut`.
- The service LISTENS to the source notifiers (call, voice, conference, app lock, identity
  protection) and READS the derived providers: Riverpod 2 refreshes a derived provider only on
  a Flutter frame, a locked phone draws none, so a remote hang-up left the lock-screen call up
  until the app opened (Nov 22). Tests mount an `UncontrolledProviderScope` and pump no frame.
- `OsCallService` (mounted once by `_OsCallMount` in `app.dart`'s phone Stack) reconciles
  through ONE queue: one native call at a time, each step reading the session as it is THEN.
  So a room -> DM switch is always `end` (room) before `begin` (DM), and a ring answered
  elsewhere inside one beat begins nothing.
- Keys: `dm:<callId>`, `vc:<server>/<channel>`, `meet:<confId>`; a media rebuild keeps the key
  and the OS call. The uuid native sees is a random v4 minted at `begin`, never derived from
  any id.
- EVERY session calls `begin` and `end`, whatever `available` said: iOS audio depends on it
  (below). `begin.live` = every uuid begun and not ended, so native drops what Dart lost.
- Title (`osCallTitle`): fixed at `begin`; a name only while a phone notification may show
  content (`notificationContentAllowed(read, mobile: true)`, the HOL-SEC-155 rule, shared with
  `system_notification_provider`); never an id ("Hollow" for anything not known yet); an 18+
  server the phone hides is never named. App Lock raised mid-call blanks it one way (defence
  only: the lock cannot rise during a call, `appLockBusyProvider`).
- Face (Android only, `osCallAvatars`): the friend's avatar rides as `avatar` (raw premultiplied
  RGBA) + `avatarSide` (160), and only beside a name (`osCallShowsAvatar`: Android, a title that is
  not "Hollow"), so whatever hides the name (HOL-SEC-155, a name not known yet) hides the face.
  `begin` and `ringOut {on: true}` go out AT ONCE with no face (the service must start while the
  app is in front); the face loads OFF the queue (`_faceThen`, at most `avatarTimeout` 1 s) and
  then follows as an `update` (a session) or a second `ringOut {on: true}` (the ring), queued and
  sent only if the same call is there (`identical(_live, mirror)`, or the same `callId` still
  ringing out) with a title still named and allowed. A ring is tracked by its `callId`
  (`_ringCall`, a new ring has a new id): another ring inside one beat
  (cancel, call someone else) is re-sent with its own title and `fresh: true`, so a late face
  never lands beside another friend's name. The one-way blank drops the face for good
  (`mirror.avatar = null`; the ring-out is re-sent `{on: true, title: "Hollow"}`). Bytes: `getAvatar` (image_gate
  `shown`), then `renderOsCallAvatar` draws the first frame (an animated avatar gives a still),
  centre-cropped, into pixels of our own: Android never decodes a peer's encoded image. Rooms,
  meetings and iOS (CallKit has no avatar) get none.
- OS actions go through the app's own paths: `osEnd` -> `endCall()` or
  `leaveVoiceForDmCall` (a meeting guest leaves the meeting, a HOST STEPS OUT, never "end for
  everyone"); `osMute` -> the provider's `toggleMute()`, then the OS is told the truth
  (`setMuted`), so a refused mute (not connected, moderator, PTT) snaps back; an `osMute` that
  repeats what Dart last sent is an echo and is dropped.
- Hold (`osHold`): deafen (mutes the mic and tells the others), remember (muted, deafened),
  restore exactly on `osHold(false)` only. While held, the app's unmute and undeafen do NOT
  act: they ask the OS (`requestUnhold`) through `unlessOsHeld` (`CallMuteButton`, the phone
  control rows). Opening a call screen while held ONLY shows it, never asks (Vitalik, Nov 21:
  a resume during a carrier call may hold the carrier call). A CallKit reset while held gives
  the audio back first.
- `CallNotifier.lastEndCause` (the `end` reason): set once per call by its FIRST `_cleanup`,
  no cause = `linkLost` (as the call record reads it), cleared when a new call starts.
- `osFailed` or `begin` answering `ok: false` = unmirrored: never begun again on `osReset`, still
  ended, still sent `connected`/`setMuted`/`update` (Android's fallback CallStyle uses them).
- Probe keys: `osCall` (`none`, `dm placing` = answered, media coming up, `room live`...),
  `osCallMirrored` (false for every room and meeting on iOS), `osCallMuted`,
  `osCallHeld`. Fleet: `scripts/probe_scenarios/fleet/c154_os_call_mobile.json` (j,k).

## iOS (`ios/Runner/OsCallController.swift`, fork `AudioUtils.{h,m}`)

- One `CXProvider` (max 1 group, 1 call per group, NOT in Recents, mono mask icon `OsCallMask`).
  Every call's handle is the constant "Hollow" (`anonymousHandle`): iOS treats the handle as the
  other side's contact and may keep it (Journaling Suggestions), so the title rides
  `localizedCallerName` only. Info.plist sets `SRResearchDataGeneration` NO (no SensorKit speech
  metrics during our calls). Then: started calls only (`CXStartCallAction`; an accepted DM is reported as
  started, never as incoming). A start we did not request (Siri, Recents) fails. Our own mute
  and end transactions are marked so their callbacks are never echoed back as the person's.
- `begin` with `kind != "dm"` (a room or meeting) takes the same branch as the debug forced
  fallback: `HollowCallAudio fallbackBegan`, `osFailed` with why "rooms and meetings stay in the
  app", never a CXStartCallAction.
- App sounds (`HollowSfxPlayer`, audioplayers' ringtone) play in whatever category the session
  holds; a call leaves playAndRecord, whose default output is the EARPIECE. So
  `+[HollowCallAudio restoreSoundsCategoryIfIdle]` puts the session back to `ambient` (mixes,
  headset first, else the loudspeaker; respects the silent switch, Vitalik's choice) at launch,
  in `deactivateOwnIfIdle`, `fallbackEnded`, `setSafetyNet:NO`, `callKitCallEnded` and
  `callKitDidDeactivate`, and at the end of both `setSpeakerphoneOn:` and
  `setSpeakerphoneOnButPreferBluetooth`. It runs only in CallKit mode and only when nothing holds
  call audio (a HELD CallKit call is still counted: its resume needs the call category). Every
  holder sets the call category itself when it activates (`prepareForCall:`, `activateOwn` from
  the template), so a restore just before a call starts costs nothing.
- Why the speaker methods restore: a hang-up from the system UI (lock screen, island, AirPods,
  car) runs native first, so CallKit's `didDeactivate` restores BEFORE Dart's call cleanup resets
  the route with `Helper.setSpeakerphoneOn(false)`, which writes playAndRecord + voiceChat onto the
  live session. The template keeps that route for the next call; the live session goes back.
- `HollowSfxPlayer.startLoop` waits for call audio only while a CallKit call exists; the
  ringback has none (ringing out is no OS call), so it plays at once. Except right after a call:
  the CallKit count drops at `end`, but CallKit's session stays up until `didDeactivate`
  (`+[HollowCallAudio callKitAudioActive]`). A ringback started there plays in the ended call's
  playAndRecord and dies with the deactivation, so it waits for
  `HollowCallKitAudioDeactivatedNotification` (at most 1.5 s, then plays anyway), restores, plays.
- CallKit hears nothing about a call until it PERFORMS our `CXStartCallAction` (async after
  `begin`). Until then `connected`
  sets `connectPending`, `update` and `setMuted` are only stored in `calls[uuid]`; the perform
  reports started-connecting, the LATEST title/video, `connectedAt` if pending, and the mute.
- Audio has ONE owner, the fork's `HollowCallAudio`: `AppDelegate` calls
  `HollowCallAudio.enableCallKitMode()` BEFORE the plugins register, which puts WebRTC on
  manual audio for the whole process; the fork never calls `setActive` again.
  `isAudioEnabled = CallKit activated || fallback count > 0 || safety net`. Own activations
  (fallback, net, after an interruption) are `setActive(true)` + `audioSessionDidActivate:`, so
  libwebrtc counts them like CallKit's.
- Fallback: CallKit refused the start, or no `didActivate` within 3 s, or `available` false:
  end the system call first, keep the uuid as `fallback`, activate through the owner, then
  `osFailed`. The count falls only at Dart's `end` (or a `begin.live` without the uuid).
  Forced in debug builds by `flutter run --dart-define=HOLLOW_OS_CALL_FALLBACK=1`: Dart sends
  `available {forceFallback: true}` before any `begin` (only when `kDebugMode`), native honours
  it only under `#if DEBUG` (the Runner's Debug and Debug-dev configs define `DEBUG`; before
  Nov 21 they did not, so the old scheme variable never compiled in).
- Safety net (fail open natively): a local audio track or a received voice for 3 s with audio
  off and NO CallKit call (none requested, live or held) enables audio and logs
  `[HOLLOW-OSCALL] safety net`. A data-channel-only connection never counts. Received voices
  are counted on the MAIN thread (`hollowNoteRemoteAudio`, fed by the peer connection
  delegate's hop; the delegate's `remoteTracks` belongs to the signaling thread, never read
  by the net). The net is never on while a CallKit call exists: `callKitCallBegan` clears it
  and the tick turns it off.
- MixWithOthers: ONE rule, `+[HollowCallAudio categoryOptions:]`, at all five fork sites (the
  template at init, `ensureAudioSessionWithRecording`, both `setSpeakerphoneOn:` lists,
  `setSpeakerphoneOnButPreferBluetooth`): on while no CallKit call exists, off while one
  does; `prepareForCall:` strips it from the template before the start.
- `HollowSfxPlayer`: a call cue, and ANY sound while a CallKit call exists with the owner not
  active (starting or held), waits 1 s for the call's activation, then is dropped (an
  `AVAudioPlayer.play()` would activate the session itself). A loop started under a CallKit call
  waits for it the same way (6 s); the ringback waits only right after a call (`startLoop` above).
- Route heal: the receiver picked in the system call UI (an `.override` while the app is not
  in front, a CallKit call live) ends speaker mode instead of being fought (RISK iOS-1).
- `UIBackgroundModes` carries `voip`: without it every `CXStartCallAction` fails
  `requesttransaction error 1` (unentitled) on a real iPhone too (iOS 18.7.8, Nov 22). No PushKit,
  no VoIP push: `voip` only lets CallKit show calls the app is in.

## Android (`OsCallBridge.kt`, `HollowCallService.kt`, fork `AudioSwitchManager`)

- `OsCallBridge` (an object, main thread) owns the `hollow/os_call` channel, registered ONLY from
  `MainActivity.configureFlutterEngine`, so an FCM or UnifiedPush engine never gets one. One
  Jetpack core-telecom call at a time (`CallsManager.addCall`, registered once per process with
  baseline + video capabilities), and ONLY for `kind == "dm"` (`OsCallRules.offersTelecom`: dm,
  registered, `FEATURE_TELECOM` / `FEATURE_CONNECTION_SERVICE`, not forced). A room, a meeting or
  an unknown kind answers `{ok: false}` and runs on the call service and its CallStyle alone.
  Every Telecom call is OUTGOING (`outgoing` is informational), `isLogExcluded = true` (no call
  log), address `hollow:<uuid>`, display name = the title Dart sent, `SUPPORTS_SET_INACTIVE` (a
  carrier call holds us instead of ending us).
- Every `begin` starts `HollowCallService` (below) first, Telecom or not (a service the ring-out
  started is only re-posted). FALLBACK when the call is not ADDED 2 s after `begin`
  (`ADD_DEADLINE_MS`), `addCall` throws, or the Telecom call is lost while the session lives:
  `osFailed`, audioswitch takes the audio as before Telecom, the service and CallStyle stay. A
  call added after the deadline is disconnected (`OsCallSession`). An OS hang-up (lock screen,
  headset, car) is NEVER a fallback (`HUNG_UP`): it sends `osEnd`, and a session Dart has not
  ended 3 s later (`OS_HANG_UP_WAIT_MS`) gets `osEnd` again and loses its Telecom audio
  (`releaseAudioFromTelecom(false)`), never carries on with no OS surface.
- `begin` ends any other call the bridge holds (one at a time covers `live`); `end` for an
  unknown or ended uuid is a no-op; `connected`/`setMuted`/`update` before the add are stored
  and applied at the add (`setActive` at `connected`).
- Audio owner while a Telecom call lives = Telecom (it is the MODE OWNER and applies its own
  route; R3 spike): before `addCall` the bridge calls `AudioSwitchManager.takeAudioForTelecom`,
  so `start()` does not activate audioswitch (no focus, no mode; it only remembers it was
  wanted) and `enableSpeakerphone` / `enableSpeakerButPreferBluetooth` / `selectAudioOutput`
  go to the bridge's `requestRoute`, mapped by `AudioEndpointMapping.forRequest` (headset wins:
  "loud" = Bluetooth, else wired, else speaker; speaker off = the headset, else the earpiece;
  an exact pick only if it exists) and sent with `requestEndpointChange`. A request before the
  add waits for the endpoint list. `hollowSelectedAudioOutput` reads Telecom's
  `currentCallEndpoint`; every endpoint change fires the fork's `onDeviceChange` for every
  engine. The start route goes in as `preferredStartingCallEndpoint` (`loud` -> speaker, else
  earpiece, nothing while a headset is attached) because core-telecom otherwise may move a call
  off the speaker at start. `releaseAudioFromTelecom(callGoesOn)`: a fallback activates
  audioswitch only while a mic track or audio connection still holds (`hasActivating`) and
  re-applies the last route request; an end activates nothing, and Telecom puts the mode back to
  normal, so app sounds play as media again. Telecom is the ONLY owner: Dart's `dm-call` hold
  never activates audioswitch, call mode ends 4 s after the last real audio even while an app
  key holds (a call placed from inside a room rings out of call mode once the room's audio is
  gone), and `takeAudioForTelecom` makes an audioswitch still active (a room handing over to a
  DM) step down, remembered as wanted.
- Mute (`MuteMirror`, spike D2): Telecom's mute IS the global mic mute. While the Telecom call
  is live and NOT held, `setMuted(m)` also writes `AudioManager.setMicrophoneMute(m)` (only when
  it differs), the app's mute is written once at the add, Telecom's `isMuted` reaches Dart as
  `osMute` only when it differs from the app's mute (our own write echoes back equal and is
  dropped), and within 1 s of the add a difference re-writes the app's mute instead (Telecom's
  first value can predate our write). `end` and a fallback clear a global mute our call or its
  Telecom side set. HELD: the global mute also mutes the carrier call, so the hold LIFTS a mute
  our call set, nothing is written or mirrored while held, and the resume writes the app's mute
  back; a Hollow call ending during the carrier call leaves that call unmuted. The CallStyle's
  Mute button sends `osMute(!appMuted)`; Dart answers with `setMuted`.
- Hold (spike D3): `onSetInactive` -> `osHold(true)`; Telecom NEVER resumes a call it put on
  hold for a carrier call and raises `onSetActive` only for its own requests, so
  `requestUnhold` = `setActive()` and on Success the bridge sends `osHold(false)` itself; a
  failure sends nothing (Dart stays held). Resume re-aligns the global mute. A fallback while
  held sends `osHold(false)` (nothing could resume it).
- `update` re-posts the CallStyle with the new title. core-telecom 1.1.0 cannot rename a live
  call, so a headset, watch or car keeps the begin title (reachable only if the title rule
  flips mid-call, which App Lock cannot do during a call).
- `HollowCallService` (not exported, `phoneCall|microphone`): THE call foreground service from
  `ringOut` or `begin` to `end` (or the ring-out's end). `phoneCall` alone does NOT keep a
  backgrounded mic (spike Q1), so the `microphone` type is taken at start when RECORD_AUDIO is
  granted, else added from `MainActivity.onResume` (the permission dialog closing resumes us),
  never from the background (refused on API 34+). Types are tried phoneCall + microphone, then
  phoneCall alone, then microphone alone (`foregroundAttempts`); a start refused every way ends
  the service and the call goes on without one, a refused microphone upgrade keeps the running
  phoneCall foreground. Its notification is the CallStyle
  (`CallNotification`, channel `hollow_ongoing_call`, DEFAULT importance, no sound or vibration:
  LOW may hide the status-bar call chip): Person = the title, Hang up + Mute/Unmute through
  `CallActionReceiver` (not exported, explicit immutable PendingIntents) -> `osEnd` / `osMute`
  (a ring-out's plain notification has Hang up only -> `osRingOutEnd`); a chronometer from
  `connected`. Titles are one-way natively too (`TitleLatch`, per Call and per ring; a new ring
  or Dart's `fresh` starts it over): once "Hollow", a later named title stays "Hollow". The face:
  `OsCallRules.avatarFor` keeps an `avatar` only for a DM, only beside a name that is not
  "Hollow" (after the latch) and only when it is exactly `side * side * 4` bytes (side 1..256), and
  `CallNotification` copies those pixels into a bitmap (no decoder) as the CallStyle Person's
  icon, or the ring-out's large icon. Every look carries its face afresh: an `update` without
  one removes it. Swipe-away: Android 14+ lets the person dismiss any `setOngoing` foreground
  notification EXCEPT a CallStyle (or media) one (Android 14 behaviour changes, "non-dismissable
  notifications"), so the answered call and the room notification stay, and the plain ring-out
  can be swiped. Every look sets a delete intent (`ACTION_DISMISSED`): while the service still
  carries a look and runs in the foreground (`repostsAfterDismiss`) it posts the same
  notification again, so the ring-out comes straight back and the ring never stopped (the
  service keeps running when only its notification is dismissed). A CallStyle for the ring-out
  is not an option: SystemUI shows the status-bar call chip for any ongoing CallStyle. A stop that
  lands before `startForeground` still calls it first, then stops.
- The fork's `CallForegroundService` stands down once the bridge hears `available`
  (`appOwnsCallService`, cleared on detach), so a build without the Dart service keeps it.
- Engine detach (`MainActivity.onDestroy`) and `onTaskRemoved` (swipe-away) end every call and
  ring-out, Telecom included: no ghost call on the status bar, a headset or a car.
- Forced fallback in debug builds: Dart's `available {forceFallback: true}` (the
  `HOLLOW_OS_CALL_FALLBACK` define), or `adb shell setprop debug.hollow.os_call_fallback 1` (read
  at each `begin`, no rebuild; `0` to undo). Release builds ignore both. Debug builds log one
  `HollowOsCall STATUS <event> mode= micMute= path= route= held= fgs= telecomAudio= recs=` line per
  transition (no names).
- N5 in the fork: ONE `AudioSwitchManager` per process (first engine makes it, never replaced),
  each engine its own event sink, device changes fan to every live engine, and an engine's detach
  releases only its own `CallAudioHolders` holds (the last engine's also stops the manager). The
  idle release (4 s after the last hold) also forgets a start remembered under Telecom.
- Pure rules (`OsCallRules.kt`: the Telecom offer, `OsCallSession`, `MuteMirror`, `RingOut`;
  `AudioEndpointMapping.kt`) are pinned by JVM tests in `android/app/src/test/kotlin/`.

## Traps

- A new call surface or a new way into one needs nothing here as long as it lands in the
  three providers; a new in-call unmute/undeafen control or call screen entry wraps its action
  in `unlessOsHeld`.
- Never add `setActive` to the fork on iOS: the session belongs to CallKit or `HollowCallAudio`.
- The sounds-category restore sees only `HollowCallAudio`'s holders. Audio it does not track (a
  voice note being recorded by `record` or played by audioplayers, inline video, the settings
  ringtone preview) can be running when call audio goes idle and is switched to `ambient` under
  it: a recording loses its input, playback starts obeying the silent switch. Accepted: the
  restore runs only at call-audio-idle transitions (and the speaker methods), never per sound,
  so the window is one call ending while such audio plays.
- Never derive the uuid from an id: it reaches the OS and its logs.
- The iOS Simulator refuses every CallKit start (`requesttransaction error 1`): a simulator run
  always proves the FALLBACK path (`osCallMirrored` false), never CallKit itself. A device without
  `voip` refuses the same way, so never blame that error on the simulator alone.
- Android: never write the global mic mute while Telecom holds our call: it mutes the carrier
  call too.
- Android: a route call (`Helper.setSpeakerphoneOn`, `selectAudioOutput`) during a Telecom call
  goes to Telecom; reading audioswitch's own selected device then is stale
  (`repinScreenAudioToRoute` reads `selectedAudioOutputTypeName()`).
- Android: a new way to place a call needs nothing here as long as it lands in `callProvider`
  as an outgoing `ringing` call; a foreground service started only once the app is in the
  background gets no microphone.
- The Android emulator has only the speaker endpoint and a silent mic: earpiece, wired,
  Bluetooth and audibility are Pixel proofs (design section 7, R3).
- What only a phone settles is the design's section 7 (R1-R17).
- Android: never give the call notification a peer's encoded image (`setLargeIcon` from bytes,
  `IconCompat.createWithData`): only the pixels Dart drew (`avatarFor`).
