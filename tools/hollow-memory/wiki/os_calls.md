# OS call state: CallKit and Telecom (#154, 0.14.3)

The OS knows Hollow is in a call: iOS CallKit (pill, Dynamic Island, lock screen call UI,
OS mute, hold and hang-up), Android Jetpack core-telecom (CallStyle notification, Bluetooth,
watches, cars). It mirrors the call, voice room or meeting the app already runs; nothing in
call core decides anything new. Design: c154-calls `.team/DESIGN_OS_CALLS.md` (revision 4),
decisions in its section 11. Android's half is builder E's (`OsCallBridge.kt`,
`HollowCallService.kt`).

## Dart (`os_call_provider.dart`, `os_call_service.dart`)

- `osSessionProvider` derives AT MOST ONE session from `callProvider`, `voiceChannelProvider`
  and `conferenceProvider` (`deriveOsSession`, pure): a DM call we placed (from its first
  ring) or accepted (from `connecting`), else the voice room we sit in, `meet:<confId>` for a
  meeting's room. An incoming ring is NEVER a session (ring in Hollow only). A DM goes first:
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
- Probe keys: `osCall` (`none`, `dm placing`, `room live`...), `osCallMirrored`, `osCallMuted`,
  `osCallHeld`. Fleet: `scripts/probe_scenarios/fleet/c154_os_call_mobile.json` (j,k).

## iOS (`ios/Runner/OsCallController.swift`, fork `AudioUtils.{h,m}`)

- One `CXProvider` (max 1 group, 1 call per group, generic handles, NOT in Recents, mono mask
  icon `OsCallMask`), started calls only (`CXStartCallAction`; an accepted DM is reported as
  started, never as incoming). A start we did not request (Siri, Recents) fails. Our own mute
  and end transactions are marked so their callbacks are never echoed back as the person's.
- CallKit hears nothing about a call until it PERFORMS our `CXStartCallAction` (async after
  `begin`; rooms and meetings send `connected` right after `begin`). Until then `connected`
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
  `AVAudioPlayer.play()` would activate the session itself); the ringback waits for it
  (6 s) and is dropped if the call ends first.
- Route heal: the receiver picked in the system call UI (an `.override` while the app is not
  in front, a CallKit call live) ends speaker mode instead of being fought (RISK iOS-1).
- No PushKit, no VoIP push, no `voip` background mode.

## Traps

- A new call surface or a new way into one needs nothing here as long as it lands in the
  three providers; a new in-call unmute/undeafen control or call screen entry wraps its action
  in `unlessOsHeld`.
- Never add `setActive` to the fork on iOS: the session belongs to CallKit or `HollowCallAudio`.
- Never derive the uuid from an id: it reaches the OS and its logs.
- The iOS Simulator refuses every CallKit start (`requesttransaction error 1`): a simulator run
  always proves the FALLBACK path (`osCallMirrored` false), never CallKit itself.
- What only a phone settles is the design's section 7 (R1-R17).
