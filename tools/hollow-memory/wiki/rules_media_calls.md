# Area rules: calls, WebRTC, audio, screen share

Moved out of CLAUDE.md on 2026-09-29, when the file was split by area (it had passed
its 50,000 character budget). CLAUDE.md sends every session here BEFORE it touches
calls, voice channels, meetings, WebRTC, audio capture or playback, screen share,
the media forwarder or the forked `flutter_webrtc`. Each rule names the memory that
holds its story. The privacy and crypto rules for media (SFrame, the forwarder's zero
ICE servers, Always relay, opt-in screen shares, `origin` checks, the signal
whitelist) stay in CLAUDE.md.

## Call surfaces

- Calls = ONE stage (`ui/call/`): focus moves only on a click; an INCOMING DM call's
  `peerId` is a DEVICE, outgoing a MASTER: compare via `isDmCallWith`. A call change
  reaches all 3 CallStage hosts (DM, voice channel, meeting). Wiki `ui_call_surfaces`,
  `feedback_call_stage_three_hosts`.
- 1:1 calls across devices = `node/call_book.rs`: ring EVERY online device, first accept wins,
  everything after routes by call_id to the device that answered (caller side) or rang (callee
  side). Dart keeps addressing the MASTER; never re-add a lowest-device pick for call signals.
  A device in a DM call, voice channel or meeting blocks the others from starting or joining
  one (buttons say why). An incoming call is BUSY only while a device is in a DM call; while one
  is in a voice channel or meeting, that device alone rings ("Answering will leave #channel")
  and the others stay silent. The locked "In a call on another device" strip is `CallElsewhereRow` /
  `MobileCallElsewhereBar`. `project_one_call_per_identity`.
- VAD/speaking state lives in `speaking_provider.dart`, NEVER in CallState/
  VoiceChannelState. REMOTE peers membership-select; OURSELVES = a bool
  (`vcLocalSpeakingProvider`, the set is DEVICE-keyed). LOCAL mic level =
  `Helper.getCaptureLevel()`, NEVER getStats. `feedback_getstats_no_local_audio_level`.

## WebRTC plumbing

- flutter_webrtc native input selection (audio+video) uses `sourceId`:
  `{'optional': [{'sourceId': deviceId}]}`; `{'deviceId': ...}` is silently ignored.
- TURN ICE config: each TURN URI = its OWN `IceServer` entry (native has one `uri` per
  struct). Credentials arrive via the authed WS (`NetworkEvent::TurnCredentials` ->
  `iceConfigProvider`); never re-add a Dart HTTP fetch; WS `discover_peers` is discovery.
- Multi-device data channels (`webrtc_service.dart`): the glare tiebreaker compares
  MASTER identities; answer/ICE match by `conn_id` AND identity (`pairRtcSignal`,
  `rtc_signal_pairing.dart`), never peer_id alone, never conn_id alone (the relay reads
  it); `conn_id` = `Random.secure()`; sends/sockets/keys stay DEVICE-keyed;
  `sendScreenAudio` drops over 256KB buffered. VC mesh glare is the
  OPPOSITE (`feedback_vc_join_double_announce_race`).
- Share WebRTC reconnection = receiver-initiates, sender-catches. `feedback_webrtc_patterns`.
- Windows mid-call media: `addTrack`/`removeTrack` + renegotiate, NEVER `replaceTrack`.
  Live `setParameters` WORKS. `project_webrtc_engine_screenshare_research`.
- `disconnected` is NOT a hangup, and NEVER restarts ICE: lanes HOLD it
  (`LinkWatchdog`, 45s); recovery REBUILDS the media session (an in-place restart kills
  SFrame), only after `failed`; ONLY `onGiveUp` ends a call. Cameras carry a rung cap.
  `project_call_hold_open_resilience`.
- Renegotiation glare: never drop an inbound `sdp_offer`; queue while busy + retry
  (`_queueRenegOffer`); camera auto-enable STAGGERED (polite 300ms / other 1500ms); a new
  reneg trigger must handle both sides at once. `feedback_renegotiation_glare`.
- DM/VC camera codecs are VP8-ONLY (`_constrainCameraCodecs`; else the iOS answerer
  dies); a failed inbound reneg ROLLS BACK to stable; route an inbound `sdp_offer` by
  CALL IDENTITY, never `status == active`. `project_ios_camera_black_screen_debug`.
- Always `await` WebRTC disposal (renderer/PC/stream); unawaited leaks ~200MB/session.
  Fork native: per-PC EventChannel teardown in Dispose (after Dart cancels), NEVER Close.
  `feedback_webrtc_close_dispose_eventchannel`.
- Forked `flutter_webrtc` (`packages/flutter_webrtc/`, pubspec `path:`): when iterating
  native C++, delete `build/windows/x64/plugins/flutter_webrtc/` first; test from Release
  with `--release`.
- Desktop libwebrtc (dll+so) is OUR patched build, vendored at `third_party/libwebrtc/`
  (BUILDING.md). Shares ride `ScreenContentProfile`, NEVER hint 'motion'; encoding caps
  ride `addTransceiver` init `sendEncodings` (a pre-negotiation setParameters is DROPPED).
  `project_webrtc_engine_screenshare_research`.

## Audio

- Mic gain/loudness: WebRTC APM AGC is DISABLED, NEVER re-enable it. Voice Enhancement
  owns loudness (`setCaptureGain`/`setVoiceEnhance`; `setVolume()` = NO-OP); NEVER a
  per-sample leveler or a bypass of iOS VPIO. Chain/servo/3 ports + g++ harness:
  `project_voice_agc_loudness_rvox`.
- AI noise suppression is LIVE: RNNoise default (DFN3 = desktop selector), ABI v3; WebRTC
  NS auto-disabled; its VAD gates upward boost; `frames>0` or the test didn't happen;
  capture buffers ALWAYS fullband mono. `project_dfn3_noise_suppression`,
  `project_voice_enhance_chain`.
- Call audio: the Android mic survives backgrounding ONLY via `CallForegroundService`
  (mic FGS in `AudioSwitchManager.start/stop`; never remove it); adaptive capture respects
  `setCaptureMuted` + `setCaptureServoHold`; voice-QUALITY bugs only count from a REMOTE
  peer. `feedback_capture_servo_mute_freeze`.
- Audio-track ops (`setEnabled`/`setVolume`/dispose) are blocking signaling-thread hops:
  ONLY via `runAudioTrackOp`/`HollowRunAudioTrackOp`/`HollowAudioOpQueue`; the FRB TRACE
  loggers are capped at Warn, NEVER remove the cap. `feedback_android_audio_track_proxy_ui_freeze`,
  `feedback_frb_trace_logger_cap`.
- A connected headset ALWAYS beats the loudspeaker (mobile): "speaker on" =
  `AudioRoutes.preferLoudRoute()`, NEVER a raw `.speaker` override (it outranks
  headphones and moves capture to the built-in mic); check availableInputs.
  `feedback_mobile_call_audio_route`.

## Linux audio and calls

- Linux calls (#72): the LAST PeerConnection kills libwebrtc's audio device module (Pulse
  never records), so `flutter_webrtc_base.cc` holds an ANCHOR PC for the process
  lifetime, NEVER remove it; the ENGINE fix = `hollow-pulse-reinit.patch`, harness
  `third_party/libwebrtc/adm_probe/`. libwebrtc logs = stderr from plugin construction
  (`HOLLOW_WEBRTC_LOG`) + `WebRtcNativeLog`. fvp on Linux = SOFTWARE decoders only
  (`registerVideoBackend()`, mdk hw decode segfaults). `project_linux_call_audio_adm_init`,
  `feedback_linux_fvp_hw_decoder_segfault`.
- Linux audio capture NEVER via `record` (needs `parecord`, absent on PipeWire): the mic
  test = WebRTC loopback, voice messages = `LinuxPulseCapture` (libpulse ffi).
  `feedback_linux_mic_parecord`.
- Linux audio enumeration: the libwebrtc ADM sees 0 devices on pipewire-pulse, so a
  libpulse shim (`hollowLinuxAudioDevices`) lists them. A distorted mic = HARDWARE first
  (`amixer sget Capture`). `feedback_linux_audio_libpulse_enum_shim`,
  `feedback_linux_agc_clipping_distortion`.
- Linux call stability: every WebRTC teardown fully awaited with ownership flags (no
  shared-stream double-free); open V4L2 ONCE per call, toggle via `track.enabled` (never
  stop/dispose mid-call). `feedback_linux_thread_leak_heap_corruption`.

## Screen share

- Screen capture: native (WGC/SCK); desktop share audio = the out-of-process
  `screen_audio_capturer` over `0x03`; SCK audio-only needs an ignored `.screen` output.
  `project_screen_capture`.
- Wayland share = PORTAL-FIRST: NEVER enumerate desktop sources there; shares ride the
  `wayland-portal:<gen>` sentinel, same gen = silent re-share.
  `feedback_wayland_window_capture_sigsegv`.
- Per-app share audio + anti-echo (Win+Linux): window shares pass the SOURCE ID
  (`windowHwnd`/`--window-xid`), NEVER `pid`; no fallback to system audio; entire-screen
  EXCLUDEs Hollow. `project_windows_per_app_screen_audio`.
- Mobile screen share: the same `0x03` Opus pipeline both ways (`api/screen_audio.rs`);
  realtime Rust crates REQUIRE `[profile.dev.package.*] opt-level=3` (else fake
  "jitter"); iOS: NEVER add message types to the `rtc_SSFD` socket.
  `project_mobile_screen_share_send`.
- `HotkeyController` = in-call only. `project_issue38_watch_gate_ptt_grid`.

## Media tooling

- The bundled ffmpeg is MINIMAL: test flags against `vendor/ffmpeg`'s binary, NEVER the
  system ffmpeg. `project_ffmpeg_minimal_build`.
