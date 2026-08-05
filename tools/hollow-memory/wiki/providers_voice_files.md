# Voice, Call, File Transfer, and WebRTC Providers

Covers five Riverpod providers that manage real-time media, file transfers, and peer-to-peer data channels. All live in `lib/src/core/providers/`.

---

## VoiceChannelProvider

**File:** `lib/src/core/providers/voice_channel_provider.dart`
**Provider:** `voiceChannelProvider` — `NotifierProvider<VoiceChannelNotifier, VoiceChannelState>`

Manages multi-user voice channels within servers, including audio, camera video, and screen sharing. Coordinates with `VoiceChannelService` (the WebRTC audio/video service) and `ScreenShareService` (dedicated per-peer screen share PCs).

### State Shape: VoiceChannelState

All fields are immutable; updates go through `copyWith()`.

| Field | Type | Default | Purpose |
|---|---|---|---|
| `participants` | `Map<String, Map<String, Set<String>>>` | `{}` | server_id -> channel_id -> Set<peer_id>. Global participant roster across all voice channels. |
| `currentServerId` | `String?` | `null` | Server the local user is currently in. |
| `currentChannelId` | `String?` | `null` | Voice channel the local user is currently in. |
| `isMuted` | `bool` | `false` | Local mic muted. |
| `isDeafened` | `bool` | `false` | Local deafened (muted + no audio output). |
| `peerAudioStates` | `Map<String, PeerAudioState>` | `{}` | Remote peer mute/deafen state, keyed by peer_id. |
| (speaking) | — | — | MOVED (2026-07): REMOTE speaking peers live in `vcSpeakingProvider` (`speaking_provider.dart`, Set<String> with setEquals guard) so 1-4Hz VAD flips don't rebuild every voiceChannelProvider watcher; OUR OWN speaking is `vcLocalSpeakingProvider` (bool) — the set is DEVICE-id keyed and self tests silently missed (issue #37). Both reset alongside `clearCurrent`. |
| `peerVolumes` | `Map<String, double>` | `{}` | Per-peer volume overrides, 0.0-2.0 range (default 1.0). |
| `voiceMode` | `String` | `'mesh'` | Current topology: `"mesh"` (direct PCs to all) or `"gossip"` (PCs to neighbors only). |
| `gossipNeighbors` | `Set<String>` | `{}` | Peer IDs of gossip neighbors (gossip mode only). |
| `joinedAt` | `DateTime?` | `null` | When the local user joined the current channel. |
| `isScreenSharing` | `bool` | `false` | Whether local user is sharing their screen. |
| `screenShareLabel` | `String?` | `null` | Quality label for local screen share (e.g. `"1080p60"`, `"4K30"`). |
| `peerScreenSharing` | `Map<String, bool>` | `{}` | Remote peers currently sharing (peer_id -> true). |
| `peerScreenShareLabels` | `Map<String, String>` | `{}` | Quality labels for remote screen shares (peer_id -> label). |
| `focusedScreenSharePeerId` | `String?` | `null` | Which sharer is displayed full-bleed. |
| `focusedSourceType` | `String` | `'screen'` | Focused source in mixed mode: `'screen'` or `'camera'`. |
| `isCameraOn` | `bool` | `false` | Whether local camera is on. |
| `peerCameraOn` | `Map<String, bool>` | `{}` | Remote peers with camera on (peer_id -> true). |

**Computed getters on VoiceChannelState:**
- `getParticipants(serverId, channelId)` -- returns `Set<String>` of peer IDs in a specific channel.
- `isInVoiceChannel` -- true if `currentChannelId != null`.
- `getPeerAudioState(peerId)` -- returns `PeerAudioState` (defaults to unmuted/undeafened).
- (speaking checks: remote `ref.watch(vcSpeakingProvider.select((s) => s.contains(peerId)))`, self `ref.watch(vcLocalSpeakingProvider)` — no longer on VoiceChannelState. NEVER membership-test the set for ourselves.)
- `getPeerVolume(peerId)` -- returns saved volume or 1.0.
- `isScreenShareActive` -- true if any local or remote screen share is active.
- `isCameraActive` -- true if any local or remote camera is active.

**`copyWith()` special flags:**
- `clearCurrent: true` -- resets all current-channel fields to defaults (used on leave).
- `clearScreenShareLabel: true` -- sets `screenShareLabel` to null.
- `clearFocusedSharer: true` -- sets `focusedScreenSharePeerId` to null.

### Helper Class: PeerAudioState

Simple value class with `isMuted` and `isDeafened` bools.

### Notifier Internal State

The `VoiceChannelNotifier` holds significant mutable state beyond the immutable `VoiceChannelState`:

- `_service` (`VoiceChannelService?`) -- the WebRTC audio/video service, created on join, destroyed on leave.
- `_outgoingScreenShares` (`Map<String, ScreenShareService>`) -- one `ScreenShareService` per peer we send our screen share to.
- `_incomingScreenShares` (`Map<String, ScreenShareService>`) -- one `ScreenShareService` per peer sharing their screen to us.
- `_earlyScreenIce` (`Map<String, List<Map<String, dynamic>>>`) -- ICE candidates that arrived before the corresponding `ScreenShareService` was created. Keyed by `"incoming:peerId"` or `"outgoing:peerId"`.
- `_screenCaptureStream` (`MediaStream?`) -- shared screen capture stream, captured once and reused across all outgoing PCs.
- `_localScreenPreviewRenderer` (`RTCVideoRenderer?`) -- local self-preview of screen share.
- `_screenShareMaxWidth` / `_screenShareMaxHeight` -- resolution of the current screen capture.
- `_screenTrackPoller` (`Timer?`) -- polls every 2s to detect window close (track muted = stopped).
- `_leaving` (`bool`) -- guard against concurrent `leaveChannel()` calls.
- `_stoppingScreenShare` (`bool`) -- guard against concurrent `stopScreenShare()` calls.
- `preVcChannelId` (`String?`) -- the text channel selected before joining VC, restored on leave.
- `_localCameraRenderer` (`RTCVideoRenderer?`) -- self-view for camera.
- `_remoteCameraRenderers` (`Map<String, RTCVideoRenderer>`) -- remote camera renderers, managed by the service's `onRemoteVideoChanged` callback.

### Public API: Renderer Access

- `VoiceChannelNotifier.service` -- exposes the `VoiceChannelService` instance (or null).
- `VoiceChannelNotifier.getScreenShareRenderer(peerId)` -- returns the `RTCVideoRenderer` for an incoming screen share from a specific peer (from `_incomingScreenShares[peerId].remoteRenderer`).
- `VoiceChannelNotifier.localScreenShareRenderer` -- returns local screen preview renderer (works even when alone in channel).
- `VoiceChannelNotifier.getCameraRenderer(peerId)` -- returns camera renderer for a peer; if `peerId` equals local peer, returns `_localCameraRenderer`, otherwise `_remoteCameraRenderers[peerId]`.

### Methods: Join/Leave Lifecycle

**`joinChannel(serverId, channelId)`**
1. Blocks if local user is in a 1:1 call (`callProvider.status != idle`).
2. If already in a voice channel, calls `leaveChannel()` first.
3. Sends `voiceChannelJoin` FFI to Rust.
4. Does NOT update state here -- waits for the local join event to call `onLocalJoined`.

**`onLocalJoined(serverId, channelId)`**
Called by event_provider after the Rust event arrives. This is the real initialization:
0. **Takes a join generation** (`final gen = ++_joinGen;`). Everything below is awaited, and the user can leave or hop channels straight through it — `_joinSuperseded(gen, svc)` is re-checked before `startAudio`, after it, and between per-peer dials, returning early when this run no longer owns the call. Both `leaveChannel()` and `_teardownCall()` bump `_joinGen`. See memory `feedback_voice_join_generation_guard`.
1. Updates state with `currentServerId`, `currentChannelId`, `isMuted: false`, `isDeafened: false`, `joinedAt: DateTime.now()`.
2. Creates `VoiceChannelService` with local peer ID and ICE config, and configures it through a LOCAL `svc` handle — never `_service!`, which a leave landing between two awaits nulls (the 0.8.5 "Null check operator used on a null value" crash).
3. Loads device preferences from `audioInputDeviceProvider`, `audioOutputDeviceProvider`, `cameraDeviceProvider`.
4. Loads audio quality preset (bitrate, stereo) from `audioQualityProvider`.
5. Loads mic gain from `micGainProvider` (default 1.0 = "50%", key `mic_gain_v2`) plus `voiceEnhanceProvider` / `voiceEnhanceStrengthProvider` (→ `enhanceStrengthToMakeupDb`) / `voiceEnhanceDynamicProvider` into the service fields. Adds `ref.listen` on all four for live mid-session updates (`updateMicGain` / `updateVoiceEnhance` / `updateVoiceEnhanceStrength` / `updateVoiceEnhanceDynamic`).
6. Wires service callbacks:
   - `onSpeakingChanged(Set<String> remotePeers, bool localSpeaking)` -- writes `vcSpeakingProvider` + `vcLocalSpeakingProvider` (NOT state — see speaking_provider.dart).
   - `onPeerConnected` -- when an audio PC connects, sends screen share offer if local is sharing (deferred send to ensure MLS is ready).
   - `onRemoteVideoChanged` -- manages `_remoteCameraRenderers` map and updates `peerCameraOn` state.
6. Calls `_service.startAudio(serverId, channelId)`.
7. Iterates existing participants in the channel and calls `_service.onPeerJoinedMyChannel(peerId)` for each.

**`leaveChannel()`**
Guarded by `_leaving` flag. Order matters:
1. Captures server/channel IDs before any state changes.
2. Sends `voiceChannelLeave` FFI to Rust FIRST (ensures server knows even if cleanup fails).
3. Best-effort cleanup via `_teardownCall()` (shared with the forced-leave path): disposes local camera renderer, disposes all remote camera renderers, `_cleanupAllScreenShares()`, stops screen-audio, `_service.closeAll()`, nullifies service.
4. Resets `_leaving` flag.

**`_teardownCall()`** — extracted shared media teardown (renderers, screen share/audio, `_service.closeAll()`). Idempotent. Called by `leaveChannel()` AND by `onLocalLeft()` when the leave was server-forced.

**`onLocalLeft()`**
Called by event_provider on the `VoiceChannelLeft` event for the local peer. Two cases: (1) the USER pressed leave → `leaveChannel()` already ran teardown and nulled `_service`; or (2) Rust FORCED us out (lost channel visibility / demoted / kicked) by emitting `VoiceChannelLeft` directly — `_service` is still live and the call still running, so `onLocalLeft` runs `_teardownCall()` to actually hang up. Detects the forced case by `_service != null`. Then resets `_leaving`, restores mobile audio route, `copyWith(clearCurrent: true)`.

### Methods: Peer Events

**`onPeerJoined(serverId, channelId, peerId)`** -- adds peer to `participants` map. Called for all voice channel join events globally.

**`onPeerLeft(serverId, channelId, peerId)`** -- removes peer from `participants` map, cleans up their audio state.

**`onRemotePeerJoined(peerId)`** -- called when a remote peer joins the local user's current channel. Calls `_service.onPeerJoinedMyChannel(peerId)`. If local is screen sharing, sends `screen_state` signal to the new peer (actual `screen_offer` is deferred to `onPeerConnected` callback). If local camera is on, sends `camera_state` signal.

**`onRemotePeerLeft(peerId)`** -- calls `_service.onPeerLeftMyChannel(peerId)`, cleans up peer's screen share and camera state.

**`onPeerDisconnected(peerId)`** -- removes peer from ALL voice channels (complete disconnect). Tears down WebRTC connection, screen share, and camera for that peer.

### Methods: Audio Controls

**`toggleMute()`** -- flips `isMuted`, calls `_service.setMuted()`, broadcasts audio state to all peers.

**`toggleDeafen()`** -- flips `isDeafened` (which also forces mute), calls `_service.setMuted()` and `_service.setDeafened()` (fire-and-forget, so it carries its own `.catchError`), broadcasts audio state.

**`setPeerVolume(peerId, volume)`** -- stores in `peerVolumes` map, calls `_service.setRemoteVolume()`.

**`_broadcastAudioState()`** -- sends `audio_state` signal (JSON with `muted` and `deafened`) to every peer in the current channel via `voiceChannelSendSignal` FFI.

**`_onRemoteAudioState(peerId, payload)`** -- parses incoming `audio_state` signal, updates `peerAudioStates` map.

### Methods: Camera

**`toggleCamera()`**
- ON: calls `_service.startCamera()`, creates local renderer, updates state, broadcasts `camera_state(enabled: true)`.
- OFF: calls `_service.stopCamera()`, disposes local renderer, updates state, broadcasts `camera_state(enabled: false)`.

**`_broadcastCameraState(enabled)`** -- sends `camera_state` signal to all peers.

**`_handleCameraState(peerId, payload)`** -- incoming handler. On enable, adds to `peerCameraOn`. On disable, removes from `peerCameraOn` but does NOT dispose the renderer (kept alive for transceiver reuse when peer re-enables).

**`_cleanupPeerCamera(peerId)`** -- removes renderer from `_remoteCameraRenderers`, disposes it, removes from `peerCameraOn`.

### Methods: Screen Sharing

**`startScreenShare(sourceId, width, height, fps, {shareAudio})`**
1. Guards: must be in voice channel, not leaving, not already sharing, not sharing in DM call.
2. Captures screen via `navigator.mediaDevices.getDisplayMedia()`.
3. Creates local preview renderer tied to capture stream.
4. Builds quality label from resolution map (360p/480p/720p/1080p/1440p/4K + fps).
5. Sets state: `isScreenSharing: true`, `screenShareLabel`, auto-focuses self.
6. Iterates all channel participants, calls `_sendScreenShareToPeer(peerId)` for each.
7. Broadcasts `screen_state(enabled: true)` to all peers.
8. Starts track poller (2s interval, detects window close via `track.muted`).

**`stopScreenShare()`**
Guarded by `_stoppingScreenShare` flag:
1. Cancels track poller.
2. Closes all outgoing `ScreenShareService` instances.
3. Disposes local preview renderer.
4. Stops and disposes capture stream.
5. Broadcasts `screen_state(enabled: false)`.
6. Updates focus: if local was focused, picks next remote sharer or clears focus.

**`_sendScreenShareToPeer(peerId)`**
Creates an outgoing `ScreenShareService` for one peer:
1. Creates service with ICE config.
2. Wires `onIceCandidate` to send `screen_ice` signals with `role: 'outgoing'`.
3. Calls `service.createOfferFromStream(_screenCaptureStream)` with resolution limits.
4. Enables SFrame E2EE on the outgoing PC using the voice channel's `FrameCryptorService`.
5. Flushes any early ICE candidates from `_earlyScreenIce`.
6. Sends `screen_offer` signal with SDP.

**`_handleScreenOffer(peerId, payload, serverId, channelId)`**
Incoming screen share offer handler:
1. Marks peer as sharing and auto-focuses if no one is focused.
2. Closes existing incoming service for this peer if any.
3. Creates incoming `ScreenShareService`.
4. Wires `onIceCandidate` (role: 'incoming') and `onRemoteTrackReady` (triggers state rebuild for UI).
5. Calls `service.handleOffer(sdp)` to generate answer.
6. Enables SFrame E2EE on the incoming PC.
7. Flushes early ICE candidates.
8. Sends `screen_answer` signal.

**`_handleScreenAnswer(peerId, payload)`** -- routes answer SDP to the outgoing service for that peer.

**`_handleScreenIce(peerId, payload)`** -- routes ICE candidates based on `role` field. `role: 'incoming'` routes to outgoing service (their incoming = our outgoing) and vice versa. If the service doesn't exist yet, queues to `_earlyScreenIce`.

**`_handleScreenState(peerId, payload)`** -- handles `screen_state` signal. On enable: adds to `peerScreenSharing`, stores quality label, auto-focuses. On disable: removes from maps, cleans up incoming service, switches focus to next sharer.

**`_broadcastScreenState(enabled)`** -- sends `screen_state` to all peers with optional quality label.

**`_cleanupPeerScreenShare(peerId)`** -- closes both incoming and outgoing `ScreenShareService` for a peer, updates `peerScreenSharing` map, switches focus if needed.

**`_cleanupAllScreenShares()`** -- closes all outgoing and incoming services, disposes preview renderer, stops capture stream, clears early ICE queue, resets screen share state.

**`_dropShareCryptors(peerId)`** (0.8.6) -- `frameCryptor.disableForPeer('screen:$peerId')`; called at EVERY share-service close/replace path (stopScreenShare, offer/outgoing replace, per-peer + all-shares cleanup). enableFor* is idempotent per (participant, kind) — without the drop a RESTARTED share keeps cryptors bound to the dead PC and the new tracks go untransformed.

**`setFocusedScreenShare(peerId)`** -- sets which sharer is displayed full-bleed.

**`setFocusedSource(peerId, sourceType)`** -- sets focused peer and source type (for mixed screen+camera mode).

### Methods: MLS/Gossip

**`onEpochChanged(serverId, epoch, sframeKey, {channelId})`** -- called when an MLS epoch rotates (`NetworkEvent_MlsEpochChanged`). `channelId == null` = the server-wide group key (non-restricted voice channels); `channelId != null` = a restricted channel's per-channel MLS SUBGROUP key. Caches every key in `_sframeKeys` keyed by `_sframeCacheKey(serverId, channelId)`, then applies it to the live `FrameCryptorService` ONLY if it belongs to the channel we're actually in (a subgroup key must match `currentChannelId`; the server-group key applies to whatever non-restricted channel we're in — and since 0.8.6 the MIRROR guard: a server-group key is NEVER applied while in a restricted channel, which would clobber the subgroup key). After applying, re-runs `_enableSframeOnScreenSharePc` on existing share PCs so a share started before the FIRST key still gets cryptors. On join, the cached key is applied: a restricted channel (`_channelUsesSubgroup`, mirrors Rust `channel_uses_subgroup` via `channelListProvider` visibility/isPublic) uses ONLY its subgroup key — it NEVER falls back to the server-group key (that would defeat the cryptographic isolation); if no subgroup key is cached yet it awaits the Welcome/Commit → MlsEpochChanged(channelId).

**SFrame heal ladder (0.8.6, issue #27)** -- `svc.onSframeCryptorState → _onSframeCryptorState`: failure states (MissingKey/DecryptionFailed/EncryptionFailed/InternalError) tracked per `'peer|kind|rx/tx'` in `_sframeFailures`; a 2s `_sframeHealTimer` advances a per-peer ladder once a failure persists ≥2s: **step 1** re-apply cached key + `svc.rebindReceiversFor(peer)`; **step 2** (+4s) `network_api.voiceSframeHeal(escalate:false)` → Rust re-exports + re-emits the current MLS key (or bootstraps if the group is missing/inactive); **step 3** (+8s, 60s global cooldown, max 2 escalations per peer per session — `_sframeEscalations`) `escalate:true` → MLS re-bootstrap (non-authority drops its group + KeyPackage→owner/coordinator; authority removes+re-adds the failing peer's leaves). While escalation is on cooldown the ladder keeps cycling step 2 (this is also what re-keys US after the authority evicted+re-added our leaf). After 2 failed escalations the peer is marked unhealable (step 4, log once) — an old client that never encrypts must not put the server MLS group through surgery forever. Ok/KeyRatcheted clears the peer's tracking (+escalation budget); state resets on `_teardownCall` and per-peer on `onRemotePeerLeft`. DM calls: heal-lite in `voice_service` (self-rebind + `onSframeHealNeeded` → CallNotifier re-applies the static call key from `state.sframeKey`, 5s throttle). Full story: memory `project_sframe_heal_ladder`.

**Keyless watchdog (2026-08-05, issue #47→#27):** the ladder above only arms from CRYPTOR-state callbacks — with ZERO SFrame keys no cryptors exist, so a node that lost its MLS groups (e.g. post-profile-switch mnemonic recovery) sat keyless and audibly garbled forever. `_armSframeKeylessWatchdog()` on VC join ticks every 5 s while `frameCryptor?.isEnabled != true`, nudging `voiceSframeHeal(peerId:'', escalate:false)` (Rust's group-less branch re-requests the MLS bootstrap, rate-limited by `MLS_BOOTSTRAP_TIMEOUT`); stops on first key, leave, or ~2 min. See memory `project_issue47_sframe_keystore_fix`.

**Voice eviction on lost visibility** (`event_provider._evictVoiceIfInvisible`, called from `_refreshServerState`): on a role/visibility change, if the user is in a voice channel on that server they can no longer see (`can_see` recomputed from `serverChannelsProvider` + `myRoleProvider`, on a 150/600/1400ms ramp to defeat the CrdtStore write race), it calls `voiceChannelProvider.leaveChannel()` — the real hangup. Belt-and-suspenders alongside the Rust `auto_leave_invisible_voice_channels`.

**`onModeChanged(serverId, channelId, mode, gossipNeighbors)`**
Handles voice topology changes:
- **mesh -> gossip:** Closes audio PCs to non-neighbor peers, ensures PCs to all gossip neighbors. Sets `_service.gossipMode = true`.
- **gossip -> mesh:** Reconnects to all participants. Sets `_service.gossipMode = false`.
- **gossip neighbor update (same mode):** Closes PCs to removed neighbors, connects to new ones.

### Signal Dispatch: handleSignal()

The `handleSignal(peerId, signalType, payload, serverId, channelId)` method is the main entry point for all incoming voice channel signals:
- `audio_state` -- dispatched to `_onRemoteAudioState()`.
- `camera_state` -- dispatched to `_handleCameraState()`.
- `screen_offer` -- dispatched to `_handleScreenOffer()`.
- `screen_answer` -- dispatched to `_handleScreenAnswer()`.
- `screen_ice` -- dispatched to `_handleScreenIce()`.
- `screen_state` -- dispatched to `_handleScreenState()`.
- All other signals (SDP offer/answer, ICE for audio) -- forwarded to `_service.handleSignal()`.

### SFrame E2EE on Screen Share

`_enableSframeOnScreenSharePc(pc, frameCryptor, peerId, {isSender})` -- enables SFrame encryption/decryption on a screen share `RTCPeerConnection`. For senders, iterates `pc.getSenders()` and calls `frameCryptor.enableForSender()` with kind `'screen_video'` or `'screen_audio'`. For receivers, iterates `pc.getReceivers()` and calls `frameCryptor.enableForReceiver()`. Uses the voice channel's existing `FrameCryptorService` instance from the audio service.

---

## CallProvider

**File:** `lib/src/core/providers/call_provider.dart`
**Provider:** `callProvider` -- `NotifierProvider<CallNotifier, CallState>`

Manages 1:1 DM calls (audio and video) with a single remote peer. Uses `VoiceService` for the audio/video WebRTC connection and `ScreenShareService` for screen sharing (separate PCs).

### State Shape: CallState

| Field | Type | Default | Purpose |
|---|---|---|---|
| `status` | `CallStatus` | `idle` | State machine: `idle`, `ringing`, `connecting`, `active`. |
| `peerId` | `String?` | `null` | Remote peer's ID. |
| `callId` | `String?` | `null` | Unique call identifier (16-byte random hex). |
| `direction` | `CallDirection?` | `null` | `outgoing` or `incoming`. |
| `isMuted` | `bool` | `false` | Local mic muted. |
| `startedAt` | `DateTime?` | `null` | When call became active (for duration display). |
| `isVideoEnabled` | `bool` | `false` | Local camera on. |
| `remoteVideoEnabled` | `bool` | `false` | Remote peer's camera on. Set ONLY by `_handleVideoState`, never by `onRemoteVideoTrack`. |
| `remoteVideoTrackSeq` | `int` | `0` | Bumped when a remote video renderer becomes ready (and by `_handleVideoState`'s timed re-pokes). The renderer lives OUTSIDE this state on VoiceService — without the bump the UI never rebuilds when the track arrives after the `video_state` signal and the remote camera stays invisible. |
| `isVideoCall` | `bool` | `false` | Whether this was initiated as a video call. |
| (speaking) | — | — | MOVED (2026-07): local/remote speaking live in `callSpeakingProvider` (`speaking_provider.dart`, record of 2 bools) — VAD flips no longer rebuild every callProvider watcher. |
| `isRemoteSpeaking` | `bool` | `false` | Remote peer VAD — updated every 200ms from `VoiceService`. |
| `isScreenSharing` | `bool` | `false` | Local is sharing screen. |
| `remoteScreenSharing` | `bool` | `false` | Remote is sharing screen. |
| `sframeKey` | `String` | `''` | Hex-encoded 32-byte SFrame key for E2EE. |
| `screenShareLabel` | `String?` | `null` | Local screen share quality label. |
| `remoteScreenShareLabel` | `String?` | `null` | Remote screen share quality label. |

**Static constant:** `CallState.idle` -- the default idle state.

### Enums

- `CallStatus` -- `idle`, `ringing`, `connecting`, `active`
- `CallDirection` -- `outgoing`, `incoming`

### Notifier Internal State

- `_voiceService` (`VoiceService?`) -- lazily created via the `_service` getter. The getter also keeps ICE config and device preferences up to date on every access.
- `_ringTimer` (`Timer?`) -- 30-second ring timeout (both outgoing and incoming).
- `_statsTimer` (`Timer?`) -- 5-second post-connect stats dump timer.
- `_renegotiationInProgress` (`bool`) -- guards against concurrent SDP renegotiations (security hardening, Phase 6.25).
- `_outgoingScreenShare` (`ScreenShareService?`) -- outgoing screen share PC (local sharing to remote).
- `_incomingScreenShare` (`ScreenShareService?`) -- incoming screen share PC (remote sharing to local).

### Public API: Renderer Access

- `CallNotifier.screenShareRenderer` -- returns `_incomingScreenShare?.remoteRenderer`.
- `CallNotifier.localScreenShareRenderer` -- returns `_outgoingScreenShare?.localRenderer`.
- `CallNotifier.voiceService` -- exposes the `VoiceService` for UI renderer access.

### Service Initialization

The `_service` getter lazily creates `VoiceService` with `localPeerId` and `iceConfig`, then wires callbacks:
- `onConnected(peerId)` -- transitions state from `connecting` to `active`, sets `startedAt`, schedules stats dump, starts VAD (`_voiceService.startVad()`), wires `onSpeakingChanged` callback. For video calls: auto-enables camera after 300ms delay (proven mid-call addTrack/renegotiate path).
- `onDisconnected(peerId)` -- sends `end` signal, calls `_cleanup()`.
- `onRemoteVideoTrack(peerId)` -- prepares the renderer but does NOT set `remoteVideoEnabled`. On mobile, SDP negotiation creates video transceivers even for audio-only calls, triggering this callback spuriously. `remoteVideoEnabled` is set exclusively by `_handleVideoState` (explicit `video_state` signal).
- `onSpeakingChanged(local, remote)` -- writes `callSpeakingProvider` (no status gate; stopVad's (false,false) resets it).

`_ensureDevicePreferences()` -- awaits async device preference providers before starting media. Called before `createOffer` and `handleOffer` to ensure correct device selection.

### Methods: Call Actions

**`startCall(peerId, {withVideo})`**
1. Guards: must be idle.
2. Generates random call ID (16-byte hex) and SFrame key (32-byte secure random hex).
3. Sets state to `ringing` / `outgoing`. Does NOT preset `isVideoEnabled` (camera activates post-connect).
4. Sends `invite` signal with JSON `{call_id, video, sframe_key}`.
5. Starts 30-second ring timeout timer.

**`acceptCall()`**
1. Guards: must be `ringing` + `incoming`.
2. Cancels ring timer.
3. Transitions to `connecting`.
4. Sends `accept` signal with JSON `{call_id, sframe_key}`.

**`rejectCall()`**
1. Guards: must be `ringing` + `incoming`.
2. Sends `reject` signal, calls `_cleanup()`.

**`endCall()`**
1. Sends `end` signal.
2. Closes both screen share services.
3. Calls `_service.endCall()` and `_cleanup()`.

**`toggleMute()`** -- calls `_service.toggleMute()`, syncs `isMuted` from service.

**`toggleVideo()`**
1. Calls `_service.toggleVideo()`.
2. If state actually changed, sends `video_state` signal so remote UI updates.
3. Creates SDP renegotiation offer (guarded by `_renegotiationInProgress`) so remote WebRTC stack picks up the new track. Without renegotiation, `replaceTrack` alone is silently ignored by the receiver.

**`switchCamera()`** -- calls `_service.switchCamera()` (front/back camera swap) and writes the RETURNED facing into `CallState.isFrontCamera` (true = front; default true, reset on call end). VoiceChannelNotifier has the twin (`VoiceChannelState.isFrontCamera`, reset via clearCurrent; also synced from the service getter when the camera turns on). Mobile local previews use it as the mirror flag — mirror ONLY when front-facing (a mirrored back camera reads reversed); remote tiles never mirror. The in-place capturer swap keeps the same track/sender, so NO renegotiation and NO SFrame rebind. Flip buttons: VC route + DM call screen controls (conditional 7th button while the camera is on).

**`setRemoteVolume(volume)`** -- adjusts remote peer's audio volume.

### Methods: Screen Sharing

**`startScreenShare({sourceId, width, height, fps, shareAudio})`**
1. Creates outgoing `ScreenShareService`.
2. Wires ICE candidates as `screen_ice` signals with `role: 'offerer'`.
3. Wires `onScreenShareEnded` to auto-stop.
4. Creates offer from source, enables SFrame E2EE.
5. Sends `screen_offer` and `screen_state(enabled: true)` signals.

**`stopScreenShare()`** -- closes outgoing service, sends `screen_state(enabled: false)`.

### Signal Dispatch: handleCallSignal()

Master dispatcher `handleCallSignal(peerId, signalType, payload)` routes by `signalType`:

| Signal | Handler | Direction |
|---|---|---|
| `invite` | `_handleInvite` | incoming |
| `accept` | `_handleAccept` | incoming |
| `reject` | `_handleReject` | incoming |
| `end` | `_handleEnd` | incoming |
| `busy` | `_handleBusy` | incoming |
| `sdp_offer` | `_handleSdpOffer` | incoming |
| `sdp_answer` | `_handleSdpAnswer` | incoming |
| `ice` | `_handleIce` | incoming |
| `video_state` | `_handleVideoState` | incoming |
| `screen_state` | `_handleScreenState` | incoming |
| `screen_offer` | `_handleScreenOffer` | incoming |
| `screen_answer` | `_handleScreenAnswer` | incoming |
| `screen_ice` | `_handleScreenIce` | incoming |

### Signal Handlers Detail

**`_handleInvite(peerId, payload)`**
- Parses JSON `{call_id, video, sframe_key}`.
- If busy (not idle), sends `busy` signal back.
- **Glare resolution:** If both peers invite simultaneously, the peer with the lower `localPeerId` (lexicographic) is "polite" and accepts the remote invite. The "impolite" peer ignores the remote invite. SECURITY: During glare, the local SFrame key is preserved (not replaced by attacker-injectable remote key).
- Sets state to `ringing` / `incoming`.
- Starts 30-second auto-reject timer.

**`_handleAccept(peerId, payload)`**
- Only processes if `ringing` + `outgoing` + matching `callId`.
- Transitions to `connecting`.
- Awaits device preferences.
- Creates audio-only offer (video added post-connect via renegotiation).
- Enables SFrame E2EE using the key generated in `startCall()`, then zeroes the key bytes.
- Sends `sdp_offer`.

**`_handleReject(peerId, payload)` / `_handleEnd(peerId, payload)`** -- tear down on matching `callId` (`_cleanup()`; `_handleEnd` also closes screen-share PCs + `_service.endCall()`).

**`_handleBusy(peerId, payload)`** -- the dialed peer is already in another call and auto-rejected via the `busy` signal (sent from `_handleInvite`'s busy branch on the callee). On matching `callId`: runs `_cleanup()` FIRST (so the "Calling…" sheet dismisses), then `_showBusyToast(peerId)`. Without the toast this looked like "the call starts and immediately finishes" with no feedback. **Ordering trap:** the toast must run *after* `_cleanup()` — an earlier version toasted first, and a thrown toast (see below) aborted `_handleBusy` before cleanup, leaving the outgoing "Calling…" sheet stuck on mobile. `_showBusyToast` resolves the peer name via `profileProvider` + `displayNameForPeer`, then posts in a post-frame callback wrapped in try/catch using `HollowToast.show(overlay.context, msg, overlayState: overlay)` where `overlay = hollowNavigatorKey.currentState?.overlay`. **Overlay gotcha:** `Overlay.of(hollowNavigatorKey.currentContext)` throws "No Overlay widget found" (Navigator's own context has no Overlay ancestor) — passing `overlayState` inserts directly and avoids the lookup (see `HollowToast` in `ui_share_animations_components.md`). Toast text: `"<name> is in a call, try again later"`.

**`_handleSdpOffer(peerId, payload)`**
Two paths, routed by **call identity, NOT status**: `if (_service.hasActiveCall)` (a PC exists for this call) → renegotiation; only otherwise → initial setup. CRITICAL: `status == active` lags ICE/DTLS by seconds; an offer arriving in that connecting window (the staggered camera auto-enable lands right in it) used to fall into the initial-setup branch and was silently consumed — never answered, never retried (the "first camera enable invisible" bug). The 1200ms glare retry and `_drainQueuedRenegOffer` also gate on `hasActiveCall`, not status.
1. **Renegotiation:** Guarded by `_renegotiationInProgress` (queue while busy). Calls `_service.handleRenegotiationOffer(sdp)`, sends `sdp_answer`.
2. **Initial setup:** Awaits device preferences, calls `_service.handleOffer()` (audio-only), enables SFrame E2EE, sends `sdp_answer`.

**`_handleSdpAnswer(peerId, payload)`** -- forwards to `_service.handleAnswer(sdp)`.

**`_handleIce(peerId, payload)`** -- forwards to `_service.handleIceCandidate()`.

**`_handleVideoState(peerId, payload)`** -- updates `remoteVideoEnabled` (logs via `_callLog`, including dropped callId mismatches). On enable, schedules seq re-pokes at +400ms/+1.2s/+2.5s (bumps `remoteVideoTrackSeq`) so the UI re-evaluates after the SDP round-trip even if no other state change fires.

**`_handleScreenState(peerId, payload)`** -- updates `remoteScreenSharing` and `remoteScreenShareLabel`. On disable, closes incoming screen share service.

**`_handleScreenOffer(peerId, payload)`** -- creates incoming `ScreenShareService`, wires ICE and `onRemoteTrackReady` callbacks, handles offer, enables SFrame, sends `screen_answer`.

**`_handleScreenAnswer(peerId, payload)`** -- forwards answer to outgoing screen share service.

**`_handleScreenIce(peerId, payload)`** -- routes ICE by `role`: `'offerer'` candidates go to incoming service, `'answerer'` candidates go to outgoing service.

### Helper Methods

**`handlePeerDisconnected(peerId)`** -- auto-ends call if the peer goes offline.

**`_cleanup()`** -- cancels timers, resets `_renegotiationInProgress`, closes both screen share services, resets `focusedDmSourceProvider`, resets state to `CallState.idle`.

**`_generateCallId()`** -- 16-byte random hex string.

**`_generateSframeKey()`** -- 32-byte cryptographically secure random hex string.

**`_enableSframeOnScreenShare(pc, peerId, {isSender})`** -- enables SFrame on screen share PC tracks using the call's `FrameCryptorService`.

**`_hexToBytes(hex)`** -- converts hex string to `Uint8List`.

**`_scheduleStatsDump(peerId)`** -- logs WebRTC stats (outbound/inbound audio bytes/packets, ICE candidate pair) 5 seconds after call goes active. Uses `_callLog()` which writes to `hollow_debug.log`.

### Companion Providers

**`focusedDmSourceProvider`** -- `StateProvider<DmFocusedSource>`. Tracks which source (screen or camera, which peer) is displayed in the big tile during a DM call's screen share view. `DmFocusedSource` has `peerId` and `type` (`'screen'` or `'camera'`). Reset to `DmFocusedSource.none()` on cleanup.

---

## FileTransferProvider

**File:** `lib/src/core/providers/file_transfer_provider.dart`
**Provider:** `fileTransferProvider` -- `NotifierProvider<FileTransferNotifier, Map<String, FileTransferState>>`

State is a `Map<String, FileTransferState>` keyed by file ID (which is the message ID for sent files, or a Rust-assigned ID for received files).

### State Shape: FileTransferState

| Field | Type | Default | Purpose |
|---|---|---|---|
| `fileId` | `String` | required | Unique identifier (message ID). |
| `fileName` | `String` | required | Display name. |
| `sizeBytes` | `int` | required | Total size in bytes. |
| `totalChunks` | `int` | required | Total chunks (or total MB for streamed transfers). |
| `chunksReceived` | `int` | `0` | Progress counter. |
| `isComplete` | `bool` | `false` | Transfer finished. |
| `isSending` | `bool` | `false` | True for outgoing transfers. |
| `isDownloading` | `bool` | `false` | True while an active download is in flight. |
| `contentId` | `String?` | `null` | Vault content ID (for 6+ member server vault uploads). |
| `vaultPhase` | `String?` | `null` | Vault download phase label ("Collecting shards...", "Reconstructing...", "Decrypting..."). |
| `error` | `String?` | `null` | Error message if transfer failed. |
| `diskPath` | `String?` | `null` | Path to completed file on disk. |
| `isImage` | `bool` | `false` | Whether the file is an image (for inline rendering). |
| `width` | `int?` | `null` | Image/video pixel width. |
| `height` | `int?` | `null` | Image/video pixel height. |
| `videoThumb` | `VideoThumbRef?` | `null` | Video thumbnail reference. When non-null, this file is a thumbnail for a vault-stored video. UI renders play button overlay. |
| `shareRootHash` | `String?` | `null` | Share root hash for share-backed files (>34 MB channel files). |
| `seeders` | `int?` | `null` | Active seeder count (updated from ShareProgress events). |
| `declined` | `bool` | `false` | Auto-download gate pin (issue #41). Set by `markDeclined()` on the `FileFailed("auto_download_off")` sentinel; while true, `onFileProgress` IGNORES progress from ANY source (Rust WS poll AND the Dart WebRTC data-channel receive) so the bubble keeps its Download button while the unwanted push is discarded. Cleared by `clearDeclined()` (called from every manual-download entry point) and on completion. |

**Computed:** `progress` -- `chunksReceived / totalChunks` (0.0-1.0).

### Internal State

- `_pendingShareSends` (`Map<String, _PendingShareSend>`) -- context for pending share-backed file sends. Keyed by file path. Stored until `ShareCreated` fires, then the `FileHeader` is sent with `share_ref`.
- `_videoExtensions` -- static const set: `{mp4, webm, mov, mkv, avi, m4v}`.

### Helper Class: _PendingShareSend

Stores context for a large file (>34 MB) that is being turned into a hidden Share:
- `serverId`, `channelId`, `messageText`, `fileName`, `messageId`, `filePath`, `isVideo`, `videoThumb`.

### Methods: Sending

**`sendFile({peerId, serverId, channelId, filePath, messageId, messageText, memberCount})`**
Complex routing logic for different file types and server sizes:

1. Creates optimistic `FileTransferState` entry with `isSending: true`.
2. Detects video files by extension.
3. Determines vault mode: `serverId != null && channelId != null && memberCount >= 6`.
4. For ALL video files: pre-extracts thumbnail via `VideoThumbnailService.extractVideoThumbnail()` to get source dimensions for the `FileHeader`'s `width/height` fields.

**Send path routing:**

- **Large channel file (>34 MB, has serverId/channelId):** Creates a hidden Share via `share_api.shareCreateFromFile()`. Stores context in `_pendingShareSends`. Returns immediately; the `FileHeader` is sent later when `ShareCreated` fires.
- **Video + vault mode (6+ members):** Delegates to `_sendVaultVideo()`.
- **Large DM file (>34 MB, no serverId):** Rejected (no Share system for DMs yet). Removes the optimistic state entry.
- **Default path:** Calls `network_api.sendFile()` for P2P streaming. If vault mode, also triggers `crdt_api.vaultUploadFile()` for erasure-coded shard distribution (P2P delivers to online peers; vault ensures offline peers can reconstruct).

**`_sendVaultVideo({serverId, channelId, filePath, fileName, ext, messageId, messageText, preExtractedThumb})`**

Vault video pipeline (Phase 6.75):
1. Uses pre-extracted thumbnail or extracts one. On failure, falls back to legacy dual-call path.
2. Vault-uploads the video via `crdt_api.vaultUploadFile()` to get `contentId`.
3. Writes thumbnail to temp `.webp` file.
4. Builds `VideoThumbRef` with `cid`, `ext`, `name`, `size`, `durMs`.
5. Sends the thumbnail via `network_api.sendFile()` with `vthumb` field set. Passes SOURCE VIDEO dimensions (not thumbnail dimensions) as `overrideWidth/overrideHeight`.
6. Updates local `FileTransferState` with `contentId` and `videoThumb` so sender's UI renders the play button immediately.
7. Cleans up temp dir.

**`onShareCreatedForFile(link, fileName, rootHash)`**
Called when `ShareCreated` event fires. Matches against `_pendingShareSends` by filename suffix. Decodes the share link to extract `rootHash` and `keyHex`, then calls `network_api.sendFile()` with `shareRootHash` and `shareKeyHex` so receivers can download via Share.

### Methods: Receiving Events

**`onFileHeaderReceived({fileId, fileName, sizeBytes, isImage, width, height, isVaultMode, videoThumb, shareRootHash})`**
Creates a new `FileTransferState` entry. Skips if entry already exists (prevents overwriting completed or in-progress entries from sync). Does NOT set `isDownloading: true` on header alone -- waits for actual progress.

**`onFileProgress(fileId, chunksReceived, totalChunks)`**
Three cases:
1. No existing entry (WebRTC race): creates minimal entry with `isDownloading: true`.
2. Existing entry with `totalChunks == 0`: replaces with full state including `isDownloading: true`.
3. Normal: updates `chunksReceived`.

**`onFileCompleted(fileId, diskPath)`**
Sets `isComplete: true`, `isDownloading: false`, `diskPath`. If no prior entry existed, creates one.

**`onSeedersUpdate(fileId, seeders)`** -- updates seeder count from ShareProgress events.

**`onFileFailed(fileId, error)`** -- sets error string on the transfer state.

### Methods: Vault Events

**`onVaultDownloadProgress(contentId, phase, progress)`** -- matches by `contentId` across all entries, updates `vaultPhase` and sets `isDownloading: true`.

**`onVaultDownloadComplete(contentId, diskPath)`** -- matches by `contentId`, sets `isComplete: true`, clears `vaultPhase`. If no entry matched, creates a synthetic `vault:{contentId}` entry so polling can find it.

---

## WebRtcProvider

**File:** `lib/src/core/providers/webrtc_provider.dart`
**Provider:** `webRtcProvider` -- `NotifierProvider<WebRtcNotifier, WebRtcState>`

Manages WebRTC data channel connections for file transfers and vault shard distribution. This is the general-purpose P2P data channel layer, distinct from the voice/call-specific WebRTC connections.

### State Shape: WebRtcState

| Field | Type | Default | Purpose |
|---|---|---|---|
| `peers` | `Map<String, WebRtcPeerStatus>` | `{}` | Per-peer connection status. |

**Enum: WebRtcPeerStatus** -- `connecting`, `connected`, `failed`.

### Service Initialization

The `service` getter lazily creates `WebRtcService` with `localPeerId` and `iceConfig`. Keeps ICE config up to date on every access (TURN credential refresh). Wires callbacks on first creation:

- `onProgress(transferId, bytesDone, totalBytes)` -- passes to `fileTransferProvider.notifier.onFileProgress()`. Clamps `bytesDone` to prevent overshoot (ciphertext slightly larger than plaintext).
- `onSendComplete(transferId)` -- logs completion.
- `onReceiveComplete(transferId, tempPath, senderPeerId, kind, shardIndex)` -- logs completion. Rust handles the rest via `webrtcTransferComplete` FFI (called by `WebRtcService`).
- `onReconnectNeeded(peerId)` -- re-establishes connection after 2s delay (e.g., after buffer overflow crash).
- `onShareConnectionFailed(peerId)` -- shows error toast for STUN-only connections that failed (strict NAT scenario).

### Methods

**`handleSignal(peerId, signalType, payload, connId)`** -- incoming signaling from Rust events. Updates peer status to `connecting` if not already tracked, then delegates to `service.handleSignal()`.

**`handleSendFile(peerId, transferId, filePath, totalSize, kind, shardIndex, {chunkIndex})`** -- handles `WebRtcSendFile` event from Rust. Delegates to `service.sendFile()`.

**`ensureConnection(peerId, {iceConfigOverride})`** -- proactively establishes a data channel connection. No-op if `service.hasPeerChannel(peerId)` is already true. Sets peer status to `connecting`, calls `service.connectToPeer()`. Optional `iceConfigOverride` for STUN-only connections (Share system).

**`onPeerConnected(peerId)`** -- marks peer as `connected` in state (called when data channel opens).

**`disconnectPeer(peerId)`** -- calls `service.disconnectPeer()`, removes from state.

**`relayBroadcast({broadcastId, ttl, originPeerId, filePath, totalSize, kind, shardIndex, excludePeerId})`** -- relays a broadcast file to all connected peers except `excludePeerId`. Used for gossip overlay file distribution. Iterates `state.peers`, sends to each `connected` peer.

**`disposeAll()`** -- disposes service, resets state.

---

## ShareTabProvider

**File:** `lib/src/core/providers/share_tab_provider.dart`
**Provider:** `shareTabProvider` -- `NotifierProvider<ShareTabNotifier, List<ShareItemState>>`

Manages the Share tab UI state. Shares are Hollow's BitTorrent-like P2P file distribution system for large files. The provider tracks all active shares (downloading and seeding).

### Companion Providers

- `shareTabOpenProvider` -- `StateProvider<bool>`, default `false`. Whether the Share tab panel is open.
- `shareDownloadPathProvider` -- `AsyncNotifierProvider<ShareDownloadPathNotifier, String>`. Persists the user's preferred download directory via `storage_api.saveSetting(key: 'share_download_path')`.

### State Shape: ShareItemState

| Field | Type | Default | Purpose |
|---|---|---|---|
| `rootHash` | `String` | required | Unique identifier (Merkle root hash). |
| `fileName` | `String` | required | Display name. |
| `totalSize` | `int` | required | Total file size in bytes. |
| `chunksHave` | `int` | `0` | Chunks downloaded. |
| `chunksTotal` | `int` | `0` | Total chunks in manifest. |
| `seeders` | `int` | `0` | Connected seeders. |
| `leechers` | `int` | `0` | Connected leechers. |
| `bytesPerSec` | `int` | `0` | Current download speed. |
| `seeding` | `bool` | `false` | Whether this node is seeding. |
| `bytesUploaded` | `int` | `0` | Total bytes uploaded to peers. |
| `state` | `String` | `'downloading'` | Lifecycle state: `'downloading'`, `'completed'`, `'failed'`. |
| `shareLink` | `String` | `''` | The `hollow://share/...` link. |
| `diskPath` | `String?` | `null` | Path to completed file on disk. |
| `error` | `String?` | `null` | Error message if failed. |
| `createdAt` | `int` | `0` | Epoch ms timestamp. |
| `serverId` | `String?` | `null` | Associated server (for context). |
| `contextType` | `String?` | `null` | Context type label. |

### Internal State

- `pendingManifests` (`Map<String, (String, int, int)>`) -- manifests that have been received but not yet accepted by the user. Keyed by `rootHash`, value is `(fileName, totalSize, chunkCount)`.

### Methods: Data Loading

**`loadAll()`** -- calls `share_api.shareList()`. The response arrives as a `ShareList` event which triggers `handleShareList()`.

**`handleShareList(entries)`** -- replaces state with mapped `ShareEntry` list from Rust. Preserves live progress fields (`chunksHave`, `seeding`, `seeders`, `leechers`, `bytesPerSec`, `bytesUploaded`) from existing state entries to prevent momentary regression when the list is refreshed.

### Methods: Event Handlers

**`handleShareProgress(rootHash, chunksHave, chunksTotal, seeders, leechers, bytesPerSec)`** -- updates progress fields for a specific share.

**`handleShareCompleted(rootHash, diskPath)`** -- transitions share to `state: 'completed'`, sets `diskPath`, enables `seeding: true`.

**`handleShareFailed(rootHash, error)`**
- If error is `'Cancelled'` or `'No seeders found'`: removes the share from the list entirely (unless it was previously completed).
- Otherwise: sets `state: 'failed'` and stores the error.

**`handleShareCreated(rootHash, link, fileName, totalSize)`** -- either updates an existing entry to `'completed'` + seeding, or prepends a new entry to the list. Used when the local user creates a share from a file.

**`handleShareManifestReady(rootHash, fileName, totalSize, chunkCount)`** -- stores in `pendingManifests` map, notifies listeners. This represents a manifest that arrived from a peer but hasn't been accepted yet (two-step download: manifest ready -> user accepts -> download starts).

**`clearPendingManifest(rootHash)`** -- removes from `pendingManifests`.

**`startDownload(rootHash, shareLink)`** -- consumes a pending manifest, creates a new `ShareItemState` with `state: 'downloading'`, prepends to list.

**`handleShareSeedingChanged(rootHash, seeding, seeders, leechers, bytesUploaded)`** -- updates seeding status and peer counts.

**`setShareLink(rootHash, link)`** -- updates the share link for an existing entry.

**`removeShare(rootHash)`** -- removes a share from the list entirely.

### Helper Functions (top-level)

- `downloadingShares(shares)` -- filters to `state == 'downloading'` or `state == 'failed'`.
- `seedingShares(shares)` -- filters to `state == 'completed'`.

### ShareDownloadPathNotifier

Persists download path via SQLCipher settings (`storage_api.loadSetting` / `storage_api.saveSetting`). Key: `'share_download_path'`. Returns empty string if unset.

---

## Cross-Provider Interactions

### VoiceChannelProvider <-> CallProvider (bidirectional since issue #49, 2026-08-04)
A DM call and a server voice channel must never run at the same time. Both
gates live at provider chokepoints, so new UI entry points inherit them:
- **VC side blocks:** `VoiceChannelNotifier.joinChannel()` checks
  `callProvider.status != idle` and returns — no longer silently: it shows
  an info toast ("You're in a call. Hang up to join a voice channel.") via
  the post-frame `hollowNavigatorKey` overlay pattern.
- **Call side auto-leaves (newest-chosen wins):** `CallNotifier.startCall()`
  (now async) and `acceptCall()` call `_leaveVoiceChannelIfActive()` —
  awaits `leaveChannel()` (tears down VC screen share cleanly) in try/catch.
  Both RE-CHECK call state after the await (`status != idle` in startCall;
  `status == connecting && callId` match in acceptCall) because the teardown
  is long enough for invite glare or a caller hang-up. Do NOT re-read
  `isInVoiceChannel` right after the await — VC state clears asynchronously
  via `onLocalLeft` (the Rust `VoiceChannelLeft` event), not in
  `leaveChannel()` itself.
- **UI warns before the fact:** `IncomingCallOverlay` (and the dormant
  `MobileIncomingCallOverlay`) show "Answering will leave #channel"
  (hollow.warning, cached alongside the other exit-animation display info)
  while ringing in a VC; the DM-header call buttons (chat_pane
  `_confirmLeaveVoiceForCall`, mobile_chat_route `startAndOpen`) confirm
  with a "Start Call?" HollowDialog before starting. An incoming invite
  while in a VC still RINGS (only an active DM call replies `busy`).
- `VoiceChannelNotifier.startScreenShare()` checks `callProvider.isScreenSharing` and blocks if already sharing in a DM call.

### FileTransferProvider <-> ShareTabProvider
- `FileTransferNotifier.sendFile()` creates hidden shares for >34 MB files via `share_api.shareCreateFromFile()`.
- `FileTransferNotifier.onShareCreatedForFile()` is called from `event_provider` when a `ShareCreated` event fires, linking the share back to the pending file send.
- `FileTransferNotifier.onSeedersUpdate()` receives seeder counts from `ShareProgress` events bridged via `event_provider`.
- `FileTransferState.shareRootHash` links a file transfer entry to its backing share.

### WebRtcProvider <-> FileTransferProvider
- `WebRtcNotifier._wireCallbacks()` bridges `onProgress` events directly to `fileTransferProvider.notifier.onFileProgress()`.
- Progress uses raw byte counts as chunk values (the ratio `chunksReceived/totalChunks` drives the progress bar).

### All Providers <-> event_provider
All five providers are driven by events from `event_provider.dart`, which watches the Rust `StreamSink` and dispatches `NetworkEvent` variants to the appropriate provider methods.

## Live Device Switching (2026-07-10)

Mic/camera/speaker Settings picker changes apply to ACTIVE calls/voice channels. Before this, `audioInputDeviceProvider`/`cameraDeviceProvider`/`audioOutputDeviceProvider` writes only persisted — the running service kept the old stream until the next call.

- **call_provider**: `ref.listen` on the three device providers in `_wireCallbacks` (next to the mic-gain listeners), guarded `prev?.valueOrNull == next.valueOrNull` (AsyncNotifier listeners also fire on initial load). Mic/camera changes call `_applyInputDeviceChange`/`_applyCameraDeviceChange` → `VoiceService.setAudioInputDevice/setCameraDevice`; when the service reports a swap, `_sendDeviceSwitchReneg` sends the `sdp_offer` through the SAME `_renegotiationInProgress` glare guard as `toggleVideo`. Output → `setAudioOutputDevice` directly.
- **voice_channel_provider**: same three listeners registered ONCE via `_deviceListenersWired` (the join path re-runs per join and would stack duplicates — the pre-existing mic-gain listeners do stack, harmlessly, because they're idempotent). Camera goes through `_applyCameraDevice`, which rebinds `_localCameraRenderer.srcObject` to the stream `setCameraDevice` returns. The VC service renegotiates per-PC internally.
- Service-side mechanics + the SFrame both-ends rebind rule: services_voice_webrtc.md §Live Device Switching. Camera switch is a NO-OP on Linux (V4L2 open-once).

## AI Noise Suppression (RNNoise default / DFN3 optional — LIVE 2026-07-18)

Denoise at the HEAD of the native capture post-processor (post-AEC, the Krisp slot). **Field-proven live on Windows (16 kHz path) and Android (48 kHz fullband)**: RNNoise (`nnnoiseless`, instant init, ~1 MB, 0.07–1 ms/frame) is the DEFAULT engine everywhere; DeepFilterNet3 stays behind the desktop Engine selector (heavy: 0.5 s desktop / 15 s Pixel model load). Full forensics: memory `project_dfn3_noise_suppression`.

- **CRITICAL — the capture buffer is ALWAYS live FULLBAND MONO** (`audio->channels()[0]`); the wrapper's `num_bands` is the APM's internal split count, NOT the buffer layout (both desktop libwebrtc and the Android AAR are the same LiveKit adapter code). Ports call the Rust adapter with `bands=1, channels=1` ALWAYS — passing the metadata through ran filterbank synthesis on raw PCM = the Pixel "pixelated mic" bug.
- **The ENHANCE CHAIN treats the buffer as fullband too (2026-07-18):** C++ + Java ports recognize `buffer_size == rate/100` and run the FULL chain on it (`eff_bands=1, eff_chans=1`) — before this, 48 kHz devices (Pixel, Linux; `num_bands=3` metadata) always rode the linear-gains-only split branch and NEVER got the EQ/de-esser/limiter (nor the legacy soft limiter in C++). Split-band + multi-channel branches remain as dormant insurance for unknown wrapper shapes; darwin was already fullband. Harness-verified (bands=3 output bit-identical to bands=1; EQ demonstrably engaged). Remote-peer listen test pending. See memory `project_voice_enhance_chain` (Fullband-layout fix).
- **Settings:** `noiseSuppressAiProvider` (key `noise_suppress_ai`, DEFAULT false) + `noiseSuppressEngineProvider` (key `noise_suppress_engine`, 'rnnoise' default | 'dfn3'; `noiseSuppressEngineToNative` → 0/1). Toggles: desktop `audio_section._buildNoiseSuppressAiToggle` + `_EngineChip` selector (shown while ON); mobile toggle only (RNNoise). Engine switch mid-call = LIVE native handle swap (old handle deliberately leaks, latches reset) — no re-capture, no reneg; `updateNoiseSuppressEngine` on both services.
- **Services** (`voice_service` + `voice_channel_service`, kept behavior-identical): `noiseSuppressAi`/`noiseSuppressEngine` prefs + `_dfnFallbackNsOn` + `_wantWebrtcNs` drive the `noiseSuppression`/`googNoiseSuppression` getUserMedia constraints (legacy NS off while AI-NS owns suppression). `updateNoiseSuppressAi` = native toggle + SAME-DEVICE mic re-capture via shared `_recaptureMic` (DM returns bool → caller renegs, VC renegs internally). `reconcileNoiseSuppressAi` (+4 s after toggle-on, engine switch AND call/session start) re-arms WebRTC NS + re-captures when the engine can't run — a call must never sit with NO suppression.
- **Native (ABI v3):** `rust/hollow_dfn` — `EngineKind` (0=RNNoise, 1=DFN3, never renumber), `Adapter` (direct 48k, 16k polyphase resample pair in `resample.rs`, dormant 3-band merge/split in `split_band.rs` — a line-by-line WebRTC ThreeBandFilterBank port, C++-oracle-verified, ~12 dB round-trip SNR is the bank's own ceiling) + `hollow_core/src/dfn_ffi.rs` (`hollow_dfn_create_engine`/`process_ex`/`last_vad`; rc 4 = unsupported shape → formatOk latch, NOT bail). Per-port runtime binding unchanged (GetModuleHandleW / own dlopen / RTLD_DEFAULT / DfnBridge JNI). Realtime watchdog (EMA >6 ms → latched session bypass). DSP porting trap: usize index arithmetic from C++ needs `wrapping_sub` — a trailing negative intermediate panics in DEBUG builds only (phones under `flutter run`).
- **RNNoise VAD → chain speech gate:** the engine's free per-frame voice probability (via `hollow_dfn_last_vad`, `vad_presence_` in each port) REPLACES the upward-compression stage's SNR+modulation presence while actively denoising — smoothstep kVadZeroProb 0.40 .. kVadFullProb 0.75 (3 ports, keep in sync) — breath (~0.1–0.4) no longer gets boosted. Fallback to the legacy gates on -1 (AI-NS off / DFN3 / bailed); legacy gate STATE stays warm for converged mid-call fallback. Downward gate untouched.
- **Diagnostics (iron rule: frames>0 or the field test didn't happen):** `Helper.getNoiseSuppressAiActive()` → `available/enabled/ready/bailed/formatOk/active` + `frames/emaMs/engine/vad` + raw shape `rate/channels/bands/bufferSize` + performance sentinels `chainEmaMs/captureGaps/worstGapMs` (2026-07-18: smoothed WHOLE-chain cost per 10 ms frame, and >30 ms inter-Process() gap count/worst — the release-reliable surface for the native audio sentinels); services log the map at every capture and reconcile into hollow_debug.log. `vad: -1` = the chain gate is running on fallback gating. Reference 48k-fullband chain cost ≈3.1 ms EMA (Pixel), 16k Windows ≈0.09 ms.
- **Capture level meter → speaking indicators (2026-07-31, issue #37, 3 ports KEEP IN SYNC):** `MeasureCaptureLevel()` runs in `ProcessChain()` right after the denoiser and BEFORE the chain — frame RMS into a decaying peak-hold (40 dB/s), dBFS, in an atomic `level_db_` (-100 = silence/no frames yet). Surfaced by `Helper.getCaptureLevel()` → `{levelDb, vad}` (its OWN method channel, not the status map — it is polled ~5 Hz during a call). Consumed by `LocalSpeakingDetector` (`lib/src/core/services/local_speaking_detector.dart`), which prefers the DFN/RNNoise `vad` when running and otherwise thresholds `levelDb` against `speakingFloorDb = -45`; both thresholds are DART constants so they retune without a native rebuild.
  - Measured pre-chain deliberately: post-chain the servo drives every mic to the same -16 dBFS target and flattens the discrimination a VAD needs.
  - **NEVER read the LOCAL level from getStats** — `audioLevel` is only specified on `media-source` and `inbound-rtp`; Windows reports `outbound-rtp.audioLevel = null` (log-verified). Remote peers still come from `inbound-rtp` and are fine. The pre-2026-07-31 `record`-package meter opened a SECOND mic handle and failed outright on both PipeWire (`parecord` absent) and Vitalik's Windows box (`No audio recording device was found`).
  - **Known limit:** alone in a channel there is no PeerConnection, libwebrtc never starts the ADM, so no frames reach the meter and the self indicator stays dark. Our `RTCAudioDevice` wrapper exposes no `StartRecording`, so activating it means a wider libwebrtc wrapper or a throwaway loopback PC — judged not worth it.
  - Harness-verifiable without a device build: compile the real `.cc` with the two documented `hollow_dfn` stubs; a -20 dBFS sine must read -23.01 dBFS and the hold must fall 4 dB per 100 ms.
- **Performance sentinels in the ports (2026-07-18, 3 ports KEEP IN SYNC):** `Process()` is now a thin wrapper (capture-gap detector + whole-chain cost EMA, log-once latches, never bails) around the renamed `ProcessChain()`; audio-track ops go through `runAudioTrackOp()` (Java) / `HollowRunAudioTrackOp()` (darwin) / `HollowAudioOpQueue` (desktop C++, added 2026-07-19 with the dispose-path fix) which log enqueue→run >500 ms once per episode. Full map: memory `project_perf_sentinels`.

## Share-Audio Level: ShareAudioLevel Bus, Ducking, Servo Freezes (2026-07-17)

Received screen-share audio (the 0x03 pure-Opus stream) used to play RAW at unity while the voice chain converges at ~−16 LUFS — mastered music drowned voices. All fixes are RECEIVER-side, zero wire changes.

- **`ShareAudioLevel`** (`lib/src/core/services/share_audio_level.dart`, static bus): target gain = `deafened ? 0 : (sliderPercent/200) × (duckEnabled && speaking ? 0.316 : 1)`. Slider 0–200% (100% = −6 dB calibration, 200% = source loudness — never above unity, can't clip); duck = −10 dB while ANYONE speaks (self included), 400 ms hold. Providers `attach/detach` the active `ScreenAudioReceiver`; the existing `onSpeakingChanged` callbacks feed `setSpeaking` (1:1: local||remote; VC: set nonempty); `toggleDeafen` feeds `setDeafened` (deafen previously did NOT silence share audio — voice tracks only). Settings: `shareAudioVolumeProvider` + `shareAudioDuckProvider` (settings_provider.dart, persisted), seeded + `ref.listen`-updated in both call providers like micGain.
- **Sinks ramp, Dart sets targets** — envelope τ≈30 ms down / τ≈300 ms up, DUPLICATED in both sinks (keep in sync): mobile = Rust `decode_screen_audio` (`api/screen_audio.rs`, `set_screen_audio_gain` FFI); desktop = render exe control frame on stdin (`[u16 len=9][seq=0xFFFFFFFF][cmd 0x01][f32 LE]`, `ScreenAudioRenderer.setGain` re-sends on respawn).
- **Capture-servo freezes** (`Helper.setCaptureMuted` / `Helper.setCaptureServoHold` → all 3 CaptureGainProcessor ports): the Voice Enhancement dynamic servo adapts only when `!muted && !hold`. Muted set by 1:1 `toggleMute` / VC `setMuted`, cleared on teardown. Hold = share audio ACTIVE on the device: SENDING with audio (both providers' start/stop/error/teardown paths) OR PLAYING a received share (`ShareAudioLevel.attach/detach`). Without these, room bleed passing the servo's −55 dBFS speech floor re-calibrates the trim to the music (9 dB/s down) and buries the voice. ANY future adaptive capture stage must respect both flags.
- **Android call FGS**: `CallForegroundService` (fork, `foregroundServiceType="microphone"`) started/stopped from `AudioSwitchManager.start()/stop()` — the mic is OS-silenced in backgrounded apps without it. `ScreenCaptureForegroundService` (mediaProjection) does NOT cover the mic.
- **Android stop-share ANR fix**: `OrientationAwareScreenCapturer.stopCapture` is no longer synchronized (volatile `stopping` flag; `onFrame` bails monitor-free) — the old monitor-held wait for the texture thread deadlocked against per-frame `changeCaptureFormat`.
- Memories: `project_share_audio_loudness_ducking`, `feedback_capture_servo_mute_freeze`, `project_android_background_mic_fgs`, `feedback_android_stopcapture_deadlock`, `feedback_same_room_dual_device_audio_testing`.

## Call Audio State, Speaker Routing & Renegotiation Glare (2026-06)

### CallState additions (call_provider.dart)
`isSpeakerOn` (mobile audio route), `isDeafened` (local), `remoteMuted` + `remoteDeafened` (synced from the peer). All reset by `_cleanup()` (state → `CallState()`).

### toggleDeafen() / toggleSpeaker() (CallNotifier)
- `toggleDeafen`: silences the remote via `_service.setRemoteAudioVolume(0.0)` AND forces mic mute; un-deafen restores `_lastRemoteVolume` (tracked in `setRemoteVolume`, which becomes store-only while deafened) and KEEPS the mic muted (mirrors voice channels).
- `toggleSpeaker` / `_setSpeakerRoute`: `Helper.setSpeakerphoneOn` (Android/iOS only). Defaults applied in `onConnected` (video call → speaker, voice → earpiece); camera-on mid-call in `toggleVideo` auto-switches to speaker; `_cleanup()` resets the OS route to earpiece.

### audio_state signal (1:1 mute/deafen badge sync)
`_sendAudioState()` fires from `toggleMute`/`toggleDeafen`: `_sendSignal(peerId, 'audio_state', {call_id, muted, deafened})` → handled by `_handleAudioState` → `remoteMuted`/`remoteDeafened`. **CRITICAL: call signal types are WHITELISTED in Rust** — `handle_call_send_signal` (voice_handler.rs) maps each type to a dedicated `HavenMessage` variant and silently DROPS unknown types. A new signal type needs: (1) `HavenMessage` variant in types.rs, (2) the send match arm, (3) the incoming dispatch arm in swarm.rs re-emitting `NetworkEvent::CallSignal`. `audio_state` ↔ `HavenMessage::CallAudioState`.

### Renegotiation glare fix (one-way video)
Root cause: on video-call connect BOTH peers auto-enabled cameras ~300ms later → both sent `sdp_offer`s simultaneously → each side's `_renegotiationInProgress` guard dropped the other's offer with no retry → one peer's track never announced → one-way video. Fixes in call_provider.dart:
- **Staggered auto-enable**: polite peer (`localPeerId.compareTo(peerId) < 0`, same convention as invite glare) waits 300ms, the other 1500ms.
- **Queue, never drop**: `_handleSdpOffer` while busy → `_queueRenegOffer` (drained in `_handleSdpAnswer` after the round-trip settles + a 2s safety timer); a failed answer (SDP glare / have-local-offer) retries the same payload after 1200ms, max 2 attempts (`_renegOfferAttempts`, reset on success). Queue/attempt state cleared in `_cleanup()`.

### VoiceChannelProvider additions
- `isSpeakerOn` + `toggleSpeaker()` (speaker ON by default on `onLocalJoined`; OS route reset in `onLocalLeft`).
- **Late-joiner state push**: `onRemotePeerJoined` sends `audio_state` (when muted/deafened) to the new peer alongside the existing `screen_state`/`camera_state` pushes — audio state is otherwise only broadcast on toggle, so late joiners never saw existing mute badges. Any new toggle-broadcast state must be added there too.
