# OS call state: CallKit and Telecom (#154, 0.14.3)

The OS knows Hollow is in a call: iOS CallKit (pill, Dynamic Island, lock screen call UI,
OS mute, hold and hang-up), Android Jetpack core-telecom (CallStyle notification, Bluetooth,
watches, cars). It mirrors the DM call the app already runs, from the moment it is answered;
nothing in call core decides anything new. Vitalik, Nov 22 (device checks): ONLY DM calls become
system calls (iOS has no call screen for a room; rooms and meetings stay in the app, like
Discord), and a call we place reaches the OS once ANSWERED (ringing out under CallKit, the
ringback played as call audio, at the ear, whatever the route said). Design: c154-calls `.team/DESIGN_OS_CALLS.md` (revision 4),
decisions in its section 11. Android's half is builder E's (`OsCallBridge.kt`,
`HollowCallService.kt`).

## Dart (`os_call_provider.dart`, `os_call_service.dart`)

- `osSessionProvider` derives AT MOST ONE session from `callProvider`, `voiceChannelProvider`
  and `conferenceProvider` (`deriveOsSession`, pure): a DM call once answered (`connecting`,
  placed or accepted), else the voice room we sit in, `meet:<confId>` for a meeting's room. No
  ring is ever a session, ours or theirs (ring in Hollow only; the ringback is a plain app
  sound). Rooms and meetings stay sessions in Dart because `begin` is what gives them audio on
  iOS; native sends every non-DM `kind` straight to the fallback (no CallKit). A DM goes first:
  `acceptCall` sets connecting before it leaves the room. Desktops build nothing
  (`osCallPlatform`).
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
- What only a phone settles is the design's section 7 (R1-R17).
