# Voice, WebRTC, and Screen Share Services

Five Dart service classes manage all real-time media and data channel transport. Each operates at a different scope: VoiceChannelService handles multi-peer mesh audio/video in server voice channels, VoiceService handles 1:1 DM calls, WebRtcService handles data channel file transfers, ScreenShareService handles dedicated screen share peer connections, and FrameCryptorService handles SFrame E2EE across all of them.

Source files:
- `lib/src/core/services/voice_channel_service.dart`
- `lib/src/core/services/voice_service.dart`
- `lib/src/core/services/webrtc_service.dart`
- `lib/src/core/services/screen_share_service.dart`
- `lib/src/core/services/frame_cryptor_service.dart`

---

## VoiceChannelService

File: `lib/src/core/services/voice_channel_service.dart`

Manages WebRTC mesh connections for server voice channels. Each remote participant gets a dedicated `RTCPeerConnection`. Audio is captured once and shared across all PCs. All logging goes through `_vcLog()` which calls `network_api.logFromDart()`.

### Constructor and State

`VoiceChannelService` takes `localPeerId` (String) and `iceServers` (Map<String, dynamic>). Core state maps:

- `_peerConnections`: Map<String, RTCPeerConnection> -- one PC per remote peer
- `_pendingCandidates`: Map<String, List<RTCIceCandidate>> -- ICE candidates received before remote description is set
- `_remoteDescSet`: Map<String, bool> -- tracks whether remote description has been set per peer
- `_localAudioStream`: shared MediaStream captured once for all PCs
- `_localVideoStream`: shared camera MediaStream (null when camera off)
- `_isMuted`, `_isCameraOn`: local media state
- `_serverId`, `_channelId`: current voice channel context (null when inactive)

Audio quality settings: `opusBitrate` (default 32000), `opusStereo` (default false). Device preferences: `preferredAudioInputDeviceId`, `preferredAudioOutputDeviceId`, `preferredCameraDeviceId`. Voice processing fields (all applied in `startAudio` + live-updatable): `micGain` (default 1.0 = 50%, range 0.68–4.0, key `mic_gain_v2`) via `Helper.setCaptureGain()` (NOT `setVolume`, a no-op on local tracks); `voiceEnhance` (default true — the native EQ+compressor+limiter chain; OFF = legacy flat gain + −3 dBFS limiter), `enhanceMakeupDb` (default 3.6 = the 30% strength), `enhanceDynamic` (default true — the auto-level servo, ignores micGain/makeup) via `Helper.setVoiceEnhance(enabled, makeupDb:, dynamicMode:)`. `updateMicGain` / `updateVoiceEnhance` / `updateVoiceEnhanceStrength` / `updateVoiceEnhanceDynamic` apply mid-session.

### Lifecycle

`VoiceChannelService.startAudio(serverId, channelId)` initializes a voice channel session:
1. Stores server/channel IDs
2. Creates a `FrameCryptorService` instance and calls `init(sharedKey: true)`
3. Captures local audio via `navigator.mediaDevices.getUserMedia()` with echo cancellation, noise suppression, auto gain control. Uses `sourceId` in optional array for device selection (CRITICAL: `deviceId` is ignored by flutter_webrtc native)
4. Sets preferred audio output via `Helper.selectAudioOutput()`
5. Starts VAD polling timer (`_startVadTimer()`) and local mic amplitude monitor (`_startLocalVad()`)

If audio capture fails, the service proceeds without local audio (user can still hear others).

`VoiceChannelService.closeAll()` tears down everything:
1. Cancels VAD timer
2. Stops and disposes local video stream (no renegotiation -- closing everything)
3. Calls `closePeer()` on each peer (disposes PC, renderers, streams, SFrame cryptors)
4. Stops and disposes local audio stream
5. Disposes remaining video renderers/streams (only disposes synthetic streams -- libwebrtc-owned streams must not be disposed from Dart)
6. Resets all state maps and flags
7. Disposes `frameCryptor`
8. Stops local VAD recorder

CRITICAL: All `dispose()`, `close()`, `stop()` calls are awaited. Unawaited disposal leaks ~200 MB per session.

### Peer Connection Creation

`VoiceChannelService._createPeerConnection(peerId)`:
1. Closes any existing connection to that peer via `closePeer()`
2. Calls `createPeerConnection(iceServers)`
3. Initializes `_remoteDescSet[peerId] = false` and empty pending candidates list
4. Wires `onIceCandidate`: serializes candidate to JSON, sends via `network_api.voiceChannelSendSignal()` with signal type `'ice'`
5. Wires `onConnectionState`:
   - On `Connected`: fires `onPeerConnected` callback, then after 1s delay logs ICE route diagnostics (TURN/STUN/LAN/P2P) by walking `getStats()` candidate-pair reports
   - On `Failed` or `Closed`: calls `closePeer(peerId)`
6. Wires `onTrack`:
   - Audio tracks: calls `_enableSframeReceiver(peerId, pc)`
   - Video tracks: calls `_handleRemoteVideoTrack(peerId, event, pc)`
   - Gossip mode: forwards audio tracks to all other gossip neighbor PCs (with dedup via `_forwardedSources` set)

### Glare Prevention

`VoiceChannelService.onPeerJoinedMyChannel(peerId)` determines who creates the offer:
- In gossip mode, skips non-neighbors
- Skips if already connected
- Lower `localPeerId` (lexicographic comparison) creates the offer; higher waits for incoming offer

This same pattern applies to renegotiation glare in `_handleRenegOffer()`: if both sides sent a renegotiation offer simultaneously, the lower peerId wins (other peer rolls back via `setLocalDescription(RTCSessionDescription(null, 'rollback'))`).

### Signal Handling

`VoiceChannelService.handleSignal()` dispatches on `signalType`:

- `'sdp_offer'` -> `_handleSdpOffer()`: Creates PC, adds local audio tracks, enables SFrame sender, sets remote description, creates answer with Opus munging, sends answer. If camera is on, immediately adds video tracks and sends renegotiation offer.
- `'sdp_answer'` -> `_handleSdpAnswer()`: Sets remote description on existing PC, flushes pending ICE candidates. If camera is on, adds video tracks and sends renegotiation.
- `'ice'` -> `_handleIce()`: If remote description not set, queues candidate (capped at 100 per peer for security). Otherwise adds directly.
- `'reneg_offer'` -> `_handleRenegOffer()`: Handles renegotiation with glare prevention. After setting remote description and creating answer, calls `_checkRemoteVideoTrack()` as safety net for renderers.
- `'reneg_answer'` -> `_handleRenegAnswer()`: Sets remote description, then checks for pending camera renegotiations.

### addTrack / removeTrack Pattern (CRITICAL)

NEVER use `replaceTrack` on Windows. The service exclusively uses `pc.addTrack(track, stream)` to add media and `pc.removeTrack(sender)` to remove it. This creates fresh transceivers each time, which reliably fires `onTrack` on the remote peer. The `replaceTrack` pattern silently fails on libwebrtc Windows -- the receiver renderer stays bound to a stale muted track.

`_addLocalAudioTracks(pc)`: Iterates `_localAudioStream.getAudioTracks()` and calls `pc.addTrack()` for each.

`_addLocalVideoTracks(pc)`: Same pattern for `_localVideoStream.getVideoTracks()`.

### Camera (Video) Management

`startCamera`/`stopCamera` are SERIALIZED against each other via a shared `_cameraLock` (chained-future) so a rapid stop->start can't open two V4L2 capturers at once. The public methods delegate to `_startCameraInner`/`_stopCameraInner`.

`startCamera()` -> `_startCameraInner()`:
1. Returns early if camera already on
2. **LINUX:** if `_localVideoStream` is still open from an earlier enable this session (stopCamera kept it open — see below), just resumes the existing track via `track.enabled = true` instead of reopening `/dev/video*`. Otherwise captures fresh.
3. Captures camera at 640x480@30fps via `getUserMedia` (only if no open stream). Uses `sourceId` in optional array for device selection
4. For each existing PC in stable state: `pc.addTrack(videoTrack, _localVideoStream!)`, enables SFrame sender encryption for video, sends renegotiation offer
5. PCs not in stable state get added to `_pendingCameraReneg` set (renegotiated later when stable)
6. Returns the local video stream for provider to create renderer

`stopCamera()` -> `_stopCameraInner()`:
1. For each PC: gets senders, removes video senders via `pc.removeTrack(sender)`, sends renegotiation if stable
2. **LINUX:** does NOT stop/dispose `_localVideoStream` — only pauses it via `track.enabled = false`, keeping the V4L2 device OPEN for the whole channel session. libwebrtc's V4L2 `StopCapture()` does not join its CaptureThread, so closing + reopening `/dev/video*` races the RaceChecker and aborts the process (`video_capture_v4l2.cc:417`). The device is released exactly once in `closeAll()`, where nothing reopens after. Windows/macOS stop+dispose the stream normally (no V4L2, no race).

### Renegotiation

`_sendRenegotiationOffer(peerId)`: Creates offer on existing PC, munges Opus params, sends via `voiceChannelSendSignal` with type `'reneg_offer'`.

`_handleRenegOffer()`: Includes glare prevention (lower peerId wins). After creating answer, calls `_checkRemoteVideoTrack()` safety net.

`_checkRemoteVideoTrack(peerId, pc)`: Walks PC's receivers looking for a video track without a corresponding renderer. If found, creates a synthetic `MediaStream`, initializes an `RTCVideoRenderer`, stores both, enables SFrame receiver decryption for video, and notifies via `onRemoteVideoChanged` callback. Does NOT clean up renderers when video is gone -- renderers survive across camera off/on cycles so the same stream can resume receiving frames.

`_checkPendingCameraReneg(peerId)`: Called when a PC reaches stable state after answer. If the peer was in `_pendingCameraReneg`, adds video tracks (if not already present) and sends renegotiation offer.

### SFrame Encryption

Four methods manage per-peer, per-kind SFrame encryption:

- `_enableSframeSender(peerId, pc)`: Gets senders, finds audio sender, calls `frameCryptor.enableForSender(peerId, sender)`. Returns early if frameCryptor is null or key not yet set.
- `_enableSframeReceiver(peerId, pc)`: Same for receivers (decryption).
- `_enableSframeSenderVideo(peerId, pc)`: Same as sender but for video track kind `'video'`.
- `_enableSframeReceiverVideo(peerId, pc)`: Same as receiver but for video.

`VoiceChannelService.setSframeKey(epoch, key)`: Called when MLS epoch key arrives. Uses `epoch % 16` as key ring index (keyRingSize=16). Enables encryption/decryption on all existing PCs for both audio and video.

### Remote Video Track Handling

`_handleRemoteVideoTrack(peerId, event, pc)`:
1. Gets MediaStream from `event.streams.first` if available (libwebrtc-owned, `isSynthetic = false`). Otherwise creates synthetic stream via `createLocalMediaStream()` and adds the track (`isSynthetic = true`).
2. Disposes old renderer for this peer (if any). Only disposes old stream if it was synthetic.
3. Creates new `RTCVideoRenderer`, initializes it, sets `srcObject`.
4. Enables SFrame receiver decryption for video.
5. After 100ms delay (renderer needs a frame), notifies via `onRemoteVideoChanged` callback.

### Audio Controls

- `setMuted(bool)`: Toggles `track.enabled` on local audio tracks
- `setDeafened(bool)`: Sets volume 0.0 or 1.0 on all remote audio receiver tracks via `Helper.setVolume()`
- `setRemoteVolume(peerId, volume)`: Per-peer volume control

### Voice Activity Detection (VAD)

Two-tier detection: remote peers via WebRTC getStats, local mic via `record` package amplitude.

Remote VAD (`_pollAudioLevels()` every 200ms):
- Iterates each PC, calls `_checkInboundAudio()` which reads `getStats()` for `inbound-rtp` audio reports
- `_detectSpeech()`: Checks `audioLevel` (0.0-1.0, threshold 0.01) first, falls back to `totalAudioEnergy` delta (threshold 0.0001)
- Maintains `_prevEnergy` map for delta calculation using `'in-$peerId'` keys

Local VAD (`_startLocalVad()`):
- Creates `AudioRecorder` from `record` package, starts PCM stream at 16kHz
- Subscribes to `onAmplitudeChanged(150ms)`: converts dBFS (-60..0) to normalized 0.0..1.0, sets `_localSpeaking = true` if level > 0.30

`_speakingPeers` set updated on change, fires `onSpeakingChanged` callback with copy.

### Gossip Mode

When `gossipMode = true` and `gossipNeighbors` is set:
- `onPeerJoinedMyChannel()` only connects to peers in `gossipNeighbors`
- `onTrack` handler forwards received audio tracks to all other gossip neighbor PCs
- `_forwardedSources` set prevents forwarding loops (dedup by peerId)

### SDP Opus Munging

`_mungeOpusParams(sdp)`: Finds the Opus payload type from `a=rtpmap` lines, then replaces or inserts `a=fmtp` line with: `minptime=10`, `useinbandfec=1`, `maxaveragebitrate=$opusBitrate`, and optionally `stereo=1;sprop-stereo=1`.

### Peer Cleanup

`closePeer(peerId)`:
1. Removes and closes/disposes the PC
2. Clears pending candidates, remote desc state, pending camera reneg
3. Disposes video renderer (sets srcObject=null first), notifies `onRemoteVideoChanged(peerId, null)`
4. Disposes remote video stream (only if synthetic)
5. Cleans up forwarded sources, prev energy
6. Calls `frameCryptor.disableForPeer(peerId)` to dispose per-peer cryptors

### Callbacks

- `onSpeakingChanged`: fires when the set of speaking peer IDs changes
- `onRemoteVideoChanged`: fires when a peer's video renderer arrives or is removed
- `onPeerConnected`: fires when a peer's audio PC reaches connected state (used by provider to send screen share offers)

---

## VoiceService

File: `lib/src/core/services/voice_service.dart`

Manages a single `RTCPeerConnection` for 1:1 DM voice/video calls. Separate from `WebRtcService` which handles data channels. Created when a call starts, destroyed when it ends. Each call gets its own ICE negotiation.

### Constructor and State

Takes `localPeerId` and optional `iceServers` (defaults to STUN-only: relay.anonlisten.com:3478, stun.cloudflare.com:3478, stun.l.google.com:19302).

Key state:
- `_pc`: single RTCPeerConnection
- `_localStream`: local audio MediaStream
- `_localVideoStream`: local camera MediaStream
- `_activePeerId`, `_activeCallId`: current call context
- `_isMuted`, `_isVideoEnabled`, `_useFrontCamera`: media state
- `_pendingCandidates`: ICE candidates received before setRemoteDescription
- `_remoteDescriptionSet`: boolean guard for candidate queuing
- `_localRenderer`, `_remoteRenderer`: RTCVideoRenderer for video self-preview and remote video
- `_remoteStream`, `_remoteStreamIsSynthetic`: remote video stream ownership tracking
- `_frameCryptor`: FrameCryptorService instance for SFrame E2EE

Audio quality: `opusBitrate` (default 32000), `opusStereo` (default false). Set by CallNotifier before offer/answer creation. Voice processing: `micGain` (default 1.0 = 50%, range 0.68–4.0) + `voiceEnhance`/`enhanceMakeupDb`/`enhanceDynamic` — applied via `Helper.setCaptureGain()` + `Helper.setVoiceEnhance()` in `_captureLocalAudio()` (see VoiceChannelService above for semantics; the native chain lives in the fork's capture post-processor, all 4 platforms). `updateMicGain`/`updateVoiceEnhance*` apply mid-call. NOTE: iOS VPIO is deliberately NOT bypassed (kills Apple AEC → feedback howl on speaker; do-not comment at the capture site).

### SDP Offer/Answer Flow

`VoiceService.createOffer(peerId, callId, {withVideo})`:
1. Stores active peer/call IDs
2. Calls `_initPeerConnection()` to create PC with callbacks
3. Calls `_startLocalAudio()` to capture mic and add audio tracks to PC
4. If `withVideo`, captures camera via `_startCamera()` and initializes local renderer
5. Creates offer, munges Opus params, sets local description
6. Returns SDP string

`VoiceService.handleOffer(peerId, callId, sdp, {withVideo})`:
1. Same setup as createOffer (init PC, start audio, optionally start camera)
2. Sets remote description from incoming SDP
3. Flushes pending ICE candidates
4. Creates answer, munges Opus params, sets local description
5. Returns SDP answer string

`VoiceService.handleAnswer(sdp)`:
1. Sets remote description on existing PC
2. Flushes pending candidates
3. Schedules `_checkRemoteVideoTrack()` after 150ms delay as safety net

### Renegotiation (Mid-Call Media Changes)

`VoiceService.createRenegotiationOffer()`: Creates offer on existing PC, returns SDP. Used when toggling video mid-call. Self-heals first: if `signalingState` is have-remote-offer/have-remote-pranswer (a previously failed inbound renegotiation), rolls the stale remote offer back to stable before `createOffer` (otherwise createOffer errors with "Error (null)" forever).

`VoiceService.handleRenegotiationOffer(sdp)`: Sets remote description, creates answer. Schedules `_checkRemoteVideoTrack()` after 150ms delay. **On ANY failure, rolls the PC back to stable** (setLocalDescription/setRemoteDescription with type `'rollback'`, best-effort both) then rethrows — a poisoned offer must never wedge the call in have-remote-offer (which kills video in BOTH directions for the rest of the call).

**Camera codec constraint — `_constrainCameraCodecs(trackId)` (CRITICAL, all platforms):** `setCodecPreferences` on the camera sender's transceiver keeping ONLY VP8 + rtx/red/ulpfec. H.265/AV1 payload types kill the iOS answerer outright; even H264/VP9 entries make iOS's FIRST call of a session fail applying its own answer while VideoToolbox is cold ("Failed to set local video description recv parameters" → first call black, later calls fine). VP8/libvpx is software everywhere and is what negotiation picked in every working session. Applied in `toggleVideo` enable, `_addLocalVideoTracks` (initial video call, awaited before createOffer), and `voice_channel_service._preferVp8ForVideoTrackOnPc` (same constraint for VC cameras). Screen share (separate PC) deliberately NOT constrained.

**Diagnostics:** `_probeVideoStats(label)` / `_scheduleVideoStatsProbes(label)` — `[HOLLOW-VIDEO-STATS]` inbound/outbound video RTP stats (frames encoded/sent/received/decoded, codec, size) probed at 2/6/12s after video enable (`'send'`) and after a remote video track binds (`'recv'`). `_handleRemoteVideoTrack` also re-asserts `renderer.srcObject = stream` at +400ms/+1200ms (guarded by renderer/stream still current) and logs `renderer.value` (width/height) — distinguishes "no frames arriving" (value stays 0x0) from binding/UI failures.

`_checkRemoteVideoTrack()`: Safety net for when `onTrack` does not fire after renegotiation. Walks PC receivers looking for a video track. If `_remoteRenderer` is already non-null, returns immediately (trusts that onTrack built it correctly -- running safety net here would pick up stale inactive transceivers from previous toggles). Creates synthetic stream, builds renderer, commits new state BEFORE disposing old state (so dispose failure doesn't trash working renderer). Notifies UI via `onRemoteVideoTrack` callback.

### ICE Candidate Handling

`VoiceService.handleIceCandidate(candidate, sdpMid, sdpMLineIndex)`:
- If remote description not yet set or no PC, queues the candidate
- Otherwise adds directly via `pc.addCandidate()`

`_flushPendingCandidates()`: Iterates and adds all queued candidates, clears the list.

### Peer Connection Setup

`_initPeerConnection(peerId, callId)`:
1. Closes/disposes existing PC if any
2. Logs ICE config diagnostics (number of server groups, TURN availability)
3. Creates PC via `createPeerConnection(iceServers)`
4. Wires `onIceCandidate`: Logs candidate type (host/srflx/relay), sends via `network_api.callSendSignal()` with JSON payload containing call_id
5. Wires `onTrack`: Video tracks go to `_handleRemoteVideoTrack()`, audio auto-plays via libwebrtc
6. Wires `onIceConnectionState` and `onIceGatheringState` for logging
7. Wires `onConnectionState`:
   - `Connected`: fires `onConnected` callback, logs ICE route diagnostics after 1s delay
   - `Failed`/`Closed`/`Disconnected`: fires `onDisconnected` callback

### Media Controls

`toggleMute()`: Toggles `track.enabled` on first audio track. Returns void.

`setRemoteAudioVolume(volume)`: Sets volume on remote audio receiver track via `Helper.setVolume()`. Range: 0.0 (silent) to 2.0 (2x).

`toggleVideo()`: SERIALIZED via a chained-future `_videoToggleLock` (each toggle awaits the prior one's full completion) so rapid on/off can't overlap. Delegates to `_toggleVideoInner()`. On **non-Linux** (Windows/macOS) uses the addTrack/removeTrack pattern (NEVER replaceTrack):
- **Disable**: Gets senders, finds video sender, `pc.removeTrack(sender)`. Stops tracks, disposes `_localVideoStream`. Disposes `_localRenderer`. Sets `_isVideoEnabled = false`.
- **Enable**: Cleans up any leaked stream from a previous failed enable. Captures camera (640x480@30fps, `sourceId` for device selection). `pc.addTrack(videoTrack, _localVideoStream!)` (fresh transceiver). Initializes local renderer. Sets `_isVideoEnabled = true`.

On **Linux**, `_toggleVideoInner` returns early into `_toggleVideoLinux()`, which NEVER closes/reopens the V4L2 device (that races libwebrtc's CaptureThread and aborts — `video_capture_v4l2.cc:417`). Instead the camera is opened ONCE on the first enable (`getUserMedia` + `addTrack`) and subsequent toggles flip `track.enabled` (pause/resume frames); the local preview renderer is disposed on pause and recreated on resume so the UI doesn't show a frozen frame. The device is released only in `endCall` (`_teardownMedia`), where nothing reopens after. Tradeoff: the camera LED may stay lit on Linux while video is "off" (frames suppressed, nothing transmitted; the remote gets `video_state:enabled=false` to hide the tile).

Caller (CallNotifier) triggers SDP renegotiation after toggleVideo returns (a no-op SDP for the Linux pause/resume case — harmless).

`switchCamera()`: Mobile only. Calls `Helper.switchCamera()` on the video track, toggles `_useFrontCamera`.

### SFrame Encryption for DM Calls

`VoiceService.setSframeKey(peerId, key)`:
1. Creates `FrameCryptorService` if needed, calls `init(sharedKey: true)`
2. Sets shared key at index 0 (DM calls use a single random key exchanged in CallInvite)
3. Enables on sender (outgoing audio) via `_frameCryptor.enableForSender()`
4. Enables on receiver (incoming audio) via `_frameCryptor.enableForReceiver()`

### Remote Video Track Handling

`_handleRemoteVideoTrack(peerId, event)`:
1. Stashes old renderer/stream state before building new
2. Picks new stream: prefers `event.streams.first` (libwebrtc-owned, NOT disposed from Dart). Falls back to synthetic stream if `event.streams` is empty (Windows/libwebrtc renegotiation quirk)
3. Builds new `RTCVideoRenderer`, initializes, sets `srcObject`
4. Commits new state FIRST, then best-effort disposes old (only disposes synthetic old streams)
5. After 100ms delay, notifies UI via `onRemoteVideoTrack` callback
6. Error handling: does NOT trash existing state on error -- previous renderer may still be usable

### Camera Initial Setup

`_startCamera(pc)`: Used only for initial call setup when user places/accepts a video call. Mid-call camera goes through `toggleVideo()`. Captures at 640x480@30fps, uses `sourceId` for device selection or `facingMode` for mobile. Calls `pc.addTrack()`. Returns true on success, false if no camera available (audio-only call continues).

### Call End Cleanup

`VoiceService.endCall()` calls `_teardownMedia()` (a reusable full-teardown helper) then clears call identity. `_teardownMedia()` is ALSO run at the START of `createOffer`/`handleOffer` (before media capture) so a re-entrant call — e.g. a second inbound offer during the getUserMedia window — can't orphan the prior session's streams. It:
1. Stops and disposes local audio stream (all tracks stopped individually)
2. Stops and disposes local video stream (on Linux this is the single V4L2 device close per call)
3. Disposes local and remote renderers (srcObject=null FIRST so a Linux "texture not found" throw can't strand a half-disposed renderer; only synthetic remote streams are disposed)
4. Closes and disposes PC — `close()` and `dispose()` get SEPARATE try/catch so a `close()` throw can't skip the thread-set-freeing `dispose()`
5. Disposes `_frameCryptor`
6. Clears media state

`createOffer`/`handleOffer` also wrap their body in try/catch -> `await endCall(); rethrow` so a throw mid-setup (e.g. unsupported-codec SDP) disposes the partial PC + capturers instead of leaking them.

### SDP Opus Munging

Identical to VoiceChannelService's `_mungeOpusParams()`. Finds Opus payload type, replaces/inserts `a=fmtp` line with bitrate and stereo params.

### SDP Dump Logging

`_dumpSdp(label, sdp)`: Logs key SDP lines (m=, a=sendrecv/recvonly/sendonly/inactive, a=ssrc, a=mid, a=msid) for debugging. Does not log the full SDP.

---

## WebRtcService

File: `lib/src/core/services/webrtc_service.dart`

Manages WebRTC peer connections with data channels for binary file transfers (vault shards, DM files, Share chunks). Completely separate from voice/video services. Uses a chunked binary protocol over SCTP data channels.

### Constants

- `_kChunkSize`: 64 KB per data channel message (safe across all platforms, SCTP max ~256KB)
- `_kMaxBufferedAmount`: 256 KB max SCTP send buffer before waiting (well below 16MB data channel buffer limit, ~4 chunks in-flight)
- Type bytes: `_kTypeFile` (0x00), `_kTypeShard` (0x01), `_kTypeShareChunk` (0x02), `_kTypeContinuation` (0xFF), `_kTypePing` (0xFE), `_kTypePong` (0xFC)
- `_kIdleTimeout`: 90s (3x keepalive interval)
- `_kKeepaliveInterval`: 30s

Default ICE servers: STUN only (relay.anonlisten.com:3478, stun.cloudflare.com:3478, stun.l.google.com:19302).

### Constructor and State

Takes `localPeerId`, optional `iceServers`, and optional `resolveIdentity` (device→master resolver, injected from `deviceLinkProvider.identityOf`; defaults to a no-op — used ONLY for the multi-device glare tiebreaker, see `_handleOffer`). Core state:

- `_connections`: Map<String, _PeerConn> -- active peer connections (keyed by DEVICE peer_id)
- `_transfers`: Map<String, _IncomingTransfer> -- active incoming file transfers
- `_pendingIceCandidates`: Map<String, List<RTCIceCandidate>> -- queued before connection created, KEYED BY conn_id (not peer_id; sibling-device-relabel safe)
- `_intentionalClose`: Set<String> -- peers we're intentionally closing (prevents reconnect trigger)
- `_connecting`: Set<String> -- guards against concurrent `connectToPeer()` calls for same peer
- `_pingSentAt`: Map<String, DateTime> -- for RTT measurement
- `_stunOnlyPeers`: Set<String> -- peers connected with STUN-only config (Share)

### Callbacks

- `onProgress(transferId, bytesDone, totalBytes)`: receiver-side progress
- `onSendComplete(transferId)`: send completed
- `onReceiveComplete(transferId, tempPath, senderPeerId, kind, shardIndex)`: receive completed
- `onShareConnectionFailed(peerId)`: STUN-only connection failed
- `onReconnectNeeded(peerId)`: reconnection requested after non-idle disconnect

### Connection Lifecycle

`WebRtcService.connectToPeer(peerId, {iceConfigOverride})`:
1. Returns early if already connected or connecting (dedup via `_connecting` set)
2. If `iceConfigOverride` provided, marks peer as STUN-only (`_stunOnlyPeers`)
3. Creates PC, stores in `_connections`
4. Creates ordered data channel named `'hollow-data'` via `pc.createDataChannel()`
5. Wires `onIceCandidate`: serializes and sends via `network_api.webrtcSendSignal()`
6. Wires `onConnectionState` handler
7. Creates and sends SDP offer (raw SDP string, not JSON-wrapped)
8. Starts 10s timeout: if data channel hasn't opened, cleans up and notifies Rust via `webrtcPeerDisconnected`

`_handleOffer(peerId, payload, connId)`:
- **Glare tiebreaker is MULTI-DEVICE-SAFE**: `politeSelf = resolveIdentity(localPeerId).compareTo(resolveIdentity(peerId)) < 0` — compares MASTER identities, NOT raw device ids. The relay tags a multi-device peer with a DIFFERENT device id on each side, so a raw-id compare is not antisymmetric → both sides could pick "impolite" → nobody answers → the channel never opens (the deadlock that broke screen-share audio, 2026-06-26). `resolveIdentity` is injected from `deviceLinkProvider.identityOf` (no-op on single-device).
- **Same connId** (renegotiation): renegotiation glare — `politeSelf` rolls back, else ignores theirs.
- **Different connId** (initial glare): `politeSelf` drops own connection and accepts incoming offer; else ignores it.
- **New connection**: closes any prior connection for this peer_id first (close-before-replace, avoids an orphaned still-delivering channel), creates PC, wires `onDataChannel` (answerer receives DC this way — does NOT call `_onDataChannelReady` directly; the state handler is the single trigger), `onIceCandidate`, `onConnectionState`. Sets remote description, creates answer, flushes pending ICE (by conn_id).

`_handleAnswer(peerId, payload, connId)`: matches the connection by peer_id first, then FALLS BACK to `_findConnByConnId(connId)` — a multi-device peer's answer can arrive tagged with a DIFFERENT sibling device id than the offer target ("Answer from X but no connection exists" → timeout), and `conn_id` is the hop-invariant correlator. Then validates connId, sets remote description.

`_handleIce(peerId, payload, connId)`: same peer_id-then-conn_id matching as `_handleAnswer`. If no PC found, queues the candidate KEYED BY conn_id (flushed by `_flushPendingIce(connId)`). Otherwise adds directly.

`_findConnByConnId(connId)`: scans `_connections.values` for a matching `connId` regardless of which peer_id key it's stored under (multi-device sibling-device relabeling).

### Data Channel Setup

`_setupDataChannel(dc, peerId)`:
- `onDataChannelState`: On Open calls `_onDataChannelReady()`, on Closed calls `_onDataChannelClosed()` (only reacts to final Closed, not Closing -- prevents double-fire)
- `onMessage`: Routes to `_onDataChannelMessage()`, resets idle timer

`_onDataChannelReady(peerId)`:
0. Idempotency guard: returns early if the connection already has a keepalive timer (it can fire more than once for the same live channel — answerer `onDataChannel` + `onDataChannelState`, reconnect churn — which would double-start the keepalive + re-notify Rust)
1. Resets idle timer
2. Starts keepalive ping timer (every 30s sends `[0xFE]` byte)
3. Notifies Rust via `network_api.webrtcPeerConnected()`

`_onDataChannelClosed(peerId)`:
1. Checks if intentional close
2. Cancels idle timer, removes connection
3. Fails any in-progress incoming transfers from this peer (closes sink, deletes temp file, notifies Rust via `webrtcTransferFailed`)
4. Notifies Rust via `webrtcPeerDisconnected()`

### Binary Protocol

First chunk header layout: `[type:1][id:64][total_size:8][extra...][data]`
- Extra bytes: shard = u16 LE shard_index (2 bytes), share_chunk = u32 LE chunk_index (4 bytes), file = none
- Total header: 73 bytes (file), 75 bytes (shard), 77 bytes (share_chunk)

Continuation chunk: `[0xFF][id:64][payload...]` -- 65 byte header

Transfer IDs are padded to exactly 64 bytes (null-padded UTF-8).

### Sending Files

`WebRtcService.sendFile(peerId, transferId, filePath, totalSize, kind, shardIndex, {chunkIndex})`:
1. Validates data channel is open
2. Reads entire file into memory (`File(filePath).readAsBytes()`)
3. Builds first chunk with type byte, padded ID, total size, extra bytes, and initial data
4. Sends continuation chunks in a loop with backpressure:
   - Checks `dc.getBufferedAmount()` after each send
   - Waits 1ms and re-checks while buffer exceeds `_kMaxBufferedAmount` (256 KB)
5. After loop, verifies data channel is still open (dc.send() doesn't throw on closing channel -- silently drops bytes). If closed mid-send, notifies Rust via `webrtcTransferFailed`
6. On success, fires `onSendComplete` and notifies Rust via `webrtcSendComplete`

`sendBroadcast()`: Currently reuses `sendFile()` with a composite transfer ID. Broadcast metadata (broadcastId, ttl, originPeerId) will be added to the 0x02 header format in a later iteration.

### Receiving Files

`_onDataChannelMessage(peerId, data)`:
- **Ping (0xFE)**: Replies with pong (0xFC)
- **Pong (0xFC)**: Computes RTT, reports to Rust via `webrtcPingReport()`
- **Continuation (0xFF)**: Extracts transfer ID, appends payload to transfer's IOSink. Emits progress every 512KB. Completes when `bytesReceived >= totalSize`
- **First chunk (0x00/0x01/0x02)**: Extracts type, ID, total size, extra fields. Creates temp file at `~/.hollow/files/.webrtc_recv_$id.tmp`. Opens IOSink. Discards stale transfer if same ID exists (re-request with new AES key). Writes first payload.

`_completeIncomingTransfer(transferId)`: Closes IOSink, fires `onReceiveComplete`, notifies Rust via `webrtcTransferComplete` (or `webrtcShareChunkComplete` for share_chunk kind with u32 chunk_index).

### Connection State Management

`_handleConnectionState(peerId, state)`:
- `Connected`: Logs ICE route after 1s delay
- `Failed`: Cleans up connection, notifies Rust. If STUN-only peer, fires `onShareConnectionFailed`. Does NOT force reconnect -- lets `_onDataChannelClosed` or Share tick drive reconnection

### Idle/Keepalive System

- `_resetIdleTimer(peerId)`: Cancels and restarts 90s idle timer. On timeout, disconnects peer and notifies Rust
- Keepalive ping every 30s (0xFE byte). Remote responds with pong (0xFC). RTT measured and reported to Rust for peer scoring

### ICE Route Logging

`_logIceRoute(peerId)`: After 1s delay on connection, walks `getStats()` to find succeeded candidate-pair. Classifies as TURN (relayed), STUN (direct P2P), LAN (direct host-host), or P2P (other).

### Internal Classes

`_PeerConn`: Holds `RTCPeerConnection`, `RTCDataChannel?`, `connId`, `peerId`, `isOfferer`, `idleTimer`, `keepaliveTimer`.

`_IncomingTransfer`: Holds `transferId`, `senderPeerId`, `totalSize`, `kind`, `shardIndex`, `chunkIndex`, `tempPath`, `IOSink`, `bytesReceived`, `lastProgressReport`.

### Cleanup

`disconnectPeer(peerId)`: Adds to `_intentionalClose`, calls `_cleanupConnection()`.

`_cleanupConnection(peerId)`: Removes from `_connecting`/`_stunOnlyPeers`, removes the `_PeerConn` from the map, delegates to `_closeConn()`.

`_closeConn(conn)`: Cancels BOTH timers (idle + keepalive), closes the data channel, then `pc.close()` and `pc.dispose()` in SEPARATE try/catch blocks (a `close()` throw must not skip the thread-set-freeing `dispose()`).

EVERY path that drops a PC from the connections map routes through `_closeConn` and awaits it before any recreate:
- `_onDataChannelClosed` (every normal disconnect — the highest-frequency path) now captures the conn and runs `_closeConn` (previously it only removed the map entry + cancelled idleTimer, leaking the PC's thread-set AND the keepalive Timer).
- The `_handleOffer` supersede AWAITS `_closeConn(prior)` before creating the new PC (was fire-and-forget, racing the new PC's construction).
- The `connectToPeer` catch disposes a partially-built PC (guarded by connId so a glare supersede isn't clobbered).

`dispose()`: Disconnects all peers (awaited per-peer), closes every in-flight transfer's `IOSink` + deletes its temp file before clearing `_transfers`, then clears all collateral sets/maps.

---

## ScreenShareService

File: `lib/src/core/services/screen_share_service.dart`

Manages a dedicated `RTCPeerConnection` for one direction of screen sharing. Each direction (outgoing/incoming) gets its own instance. This avoids transceiver conflicts that occur when screen sharing reuses the voice call's PC.

### Constructor and State

Takes `localPeerId` and `iceServers`. State:

- `_pc`: single RTCPeerConnection
- `_screenStream`: local screen capture MediaStream (outgoing only)
- `_localRenderer`: self-preview of outgoing screen
- `_remoteRenderer`: renderer for incoming screen
- `_remoteStream`: incoming screen MediaStream
- `_screenTrackPoller`: Timer that checks if screen track ended
- `_pendingCandidates`, `_remoteDescriptionSet`: ICE queuing (same pattern as VoiceService)
- `preferredAudioOutputDeviceId`: set by CallNotifier before handleOffer

### Callbacks

- `onIceCandidate`: ICE candidate to send to peer
- `onConnected`, `onDisconnected`: connection state changes
- `onRemoteTrackReady`: remote screen renderer is ready
- `onScreenShareEnded`: local screen track ended (user closed shared window)

### Native Screen Capture (Resolution Enforcement)

libwebrtc's desktop capturer ignores all resolution constraints (`scaleResolutionDownBy`, mandatory width/height). Native platform capture APIs were used to replace it:

**Windows:** `NativeScreenCapturer` (`packages/flutter_webrtc/windows/native_screen_capturer.{h,cc}`) uses Graphics Capture API + D3D11, downscales via `ScaleBGRA()`, pushes frames via `RTCVideoFrame::CreateFromBGRA()` → `RTCVideoSource::OnCapturedFrame()`. **⚠️ As of the 1.5.2 / stock-libwebrtc-m144 rebase (2026-06-26) this is GATED OFF and screen-share video falls back to libwebrtc's own desktop capturer.** `CreateFromBGRA` only exists in the fork's OLD custom-patched libwebrtc; stock webrtc-sdk m144 lacks it. The file stays on disk and all its call sites in `flutter_screen_capture.{cc,h}` are behind `#if defined(_WIN32) && defined(HOLLOW_USE_NATIVE_SCREEN_CAPTURER)` — re-enable by defining that macro + linking a libwebrtc that exports `CreateFromBGRA` (or port the 2 call sites to stock `RTCVideoFrame::Create()` + a BGRA→I420 conversion). So Windows screen-share resolution control via the native capturer is currently INACTIVE; whether stock m144's quality scaler respects resolution on its own is an open question. `StartMonitor(HMONITOR)`/`StartWindow(HWND)` (gated). See `project_flutter_webrtc_152_upgrade`.

**macOS:** `FlutterScreenCaptureKitCapturer` accepts `width:height:` params — `SCStreamConfiguration.width/height` set to target dimensions (GPU-accelerated downscale). Window capture via `SCContentFilter initWithDesktopIndependentWindow:`. Both screen and window sources use ScreenCaptureKit path. (Unaffected by the rebase — does not use `CreateFromBGRA`.)

**Linux:** Falls back to libwebrtc's desktop capturer.

**Cleanup:** `CleanupNativeCapturersForStream(stream_id)` called from `streamDispose` in `flutter_webrtc.cc`. Stops `NativeScreenCapturer` (gated) and `WasapiLoopbackCapturer`.

**NOTE — the `screen_audio_capturer.exe` is AUDIO-ONLY.** A common misconception is that a native capturer streams VIDEO over the data channel; it does not. `screen_audio_test.exe` (`test_apps/screen_audio_test/`) handles ONLY screen-share system audio (WASAPI loopback → Opus → data channel `0x03` → playback). All screen-share VIDEO goes through a WebRTC video track (native capturer when enabled, else libwebrtc's). A native-video-over-data-channel path does not exist (it's a candidate future architecture).

### Resolution and Bitrate Capping

`_applyResolutionCap(maxWidth, maxHeight, fps)`: Belt-and-suspenders on the video sender's encoding parameters after `addTrack`. Native capture handles the real resolution control; this constrains the encoder as a second layer:

1. Sets `degradationPreference = MAINTAIN_FRAMERATE` to prevent adaptive quality from overriding resolution
2. Gets sender track settings (captureWidth/captureHeight)
3. Computes scale factor if capture exceeds target, sets `scaleResolutionDownBy`
4. Sets `maxFramerate` to user-selected fps
5. Caps bitrate by pixel count tier:
   - 360p: 800 kbps
   - 480p: 1500 kbps
   - 720p: 3000 kbps
   - 1080p: 6000 kbps
   - 1440p: 9000 kbps
   - 4K: 15000 kbps
6. Higher than camera bitrates because screen content has sharp edges/text that compress poorly

### Outgoing Screen Share

`ScreenShareService.createOffer(sourceId, width, height, fps, {shareAudio})`:
1. Calls `desktopCapturer.getSources()` to refresh source list
2. Calls `navigator.mediaDevices.getDisplayMedia()` with source ID, frame rate, width, height, and audio flag — width/height in mandatory constraints trigger native capture on Windows/macOS
3. Validates video tracks exist (security check)
4. Creates local self-preview renderer
5. Creates PC, wires callbacks via `_setupCallbacks()`
6. Adds screen video track via `pc.addTrack()`
7. Applies resolution/bitrate cap
8. If audio tracks present, adds them all via `pc.addTrack()`
9. Creates offer, sets local description
10. Starts track poller (2s interval checks if screen track is still enabled)
11. Returns SDP offer string

`createOfferFromStream(stream, {maxWidth, maxHeight, fps})`: Alternative for voice channels where ONE capture is shared across multiple per-peer services. Takes a pre-captured `MediaStream` instead of capturing a new one. Sets `_ownsScreenStream = false` so `close()` does NOT stop/dispose the shared stream — disposing it would kill the share for every other peer AND double-free it (the provider disposes it once itself), which was the `corrupted size vs prev_size` heap abort on screen-share stop. `createOffer` keeps `_ownsScreenStream = true` (it captured its own stream). All three PC-creating methods (`createOffer`/`createOfferFromStream`/`handleOffer`) begin with an idempotent `close()` if a PC already exists, and wrap their body in try/catch -> `close(); rethrow`. `close()` resets the ownership flags to defaults at the end so the next reuse starts clean.

`handleAnswer(sdp)`: Sets remote description, flushes pending ICE candidates.

### Incoming Screen Share

`ScreenShareService.handleOffer(sdp)`:
1. Creates PC, wires callbacks
2. Wires `pc.onTrack` for remote screen video via `_handleRemoteVideoTrack()`
3. Sets remote description
4. Flushes pending ICE candidates
5. Creates answer
6. Sets preferred audio output device
7. Returns SDP answer string

### Remote Video Track Handling

`_handleRemoteVideoTrack(event)`:
1. Prefers `event.streams.first` if available
2. Falls back to checking `pc.getRemoteStreams()` for any stream with video tracks
3. Last resort: creates synthetic stream via `createLocalMediaStream()`
4. Disposes old renderer, creates new `RTCVideoRenderer`, sets srcObject
5. After 100ms delay, fires `onRemoteTrackReady` callback

### ICE Handling

`handleIceCandidate(candidate, sdpMid, sdpMLineIndex)`: If remote description set and PC exists, adds directly. Otherwise queues.

### PC Callbacks

`_setupCallbacks()`:
- `onIceCandidate`: Delegates to external `onIceCandidate` callback
- `onConnectionState`:
  - `Connected`: fires `onConnected`, logs ICE route diagnostics after 1s
  - `Failed`/`Closed`/`Disconnected`: fires `onDisconnected`

### Track End Detection

`_startTrackPoller()`: Polls every 2s. If screen stream is null or first video track is disabled, cancels poller and fires `onScreenShareEnded`. This compensates for `onEnded` not being wired on native desktop.

### Teardown

`ScreenShareService.close()`:
1. Cancels track poller
2. Disposes local renderer (srcObject=null first)
3. Stops all tracks and disposes screen stream
4. Disposes remote renderer
5. Closes and disposes PC
6. Clears pending candidates

### Static Utility

`getDesktopSources()`: Returns `List<DesktopCapturerSource>` for screen/window picker UI.

### Screen Share Audio

**Windows:** Out-of-process capture and playback to avoid libwebrtc ADM interference.

`startScreenAudioCapture(streamId, {pid, windowHwnd, excludePid, onPacket})`:
1. Creates `ScreenAudioCapturer` (`lib/src/core/services/screen_audio_capturer.dart`)
2. Spawns `screen_audio_capturer.exe --mode pipe [--window-hwnd <HWND> | --window-pid <PID> | --exclude-pid <excludeTarget>] --duration 0` (entire-screen uses `--exclude-pid`, where `excludeTarget` = the voice-render child pid when the redirect is armed, else `io.pid`/hollow.exe)
3. Exe captures audio per the arg (per-app INCLUDE+mix for a window, system-minus-the-excluded-tree for entire-screen), Opus encodes, writes framed binary to stdout
4. Dart reads stdout, parses `[uint16_le: len][uint32_le: seq][opus...]` frames
5. Delivers packets via `onPacket` callback → `WebRtcService.sendScreenAudio()` → data channel type 0x03

Receiver (DESKTOP): `ScreenAudioRenderer` (`lib/src/core/services/screen_audio_renderer.dart`) spawns `screen_audio_capturer --mode render`, pipes received packets via stdin → Opus decode → platform audio playback (waveOut on Windows / AudioQueue on macOS / PulseAudio on Linux). Picked via `ScreenAudioReceiver.forPlatform()` (`screen_audio_receiver.dart`), a thin interface with desktop/mobile adapters, used behind `onScreenAudioReceived` in `call_provider` + `voice_channel_provider`.

Receiver (MOBILE, Android + iOS, LIVE 2026-06-30): a phone can't spawn the exe, so `MobileScreenAudioRenderer` (`mobile_screen_audio_renderer.dart`) decodes each 0x03 Opus packet in RUST (`api/screen_audio.rs`, `decodeScreenAudio`/`resetScreenAudioDecoder`, pure-Rust `unsafe-libopus` — no NDK; 48k stereo s16le) through a single serial Future chain (preserves order; drops when >32 decodes backed up), then streams PCM to a native MEDIA-path sink via `Helper.startScreenAudioPlayer/writeScreenAudioPcm/stopScreenAudioPlayer` (`audio_management.dart`, the `setCaptureGain` method-channel precedent). **Android:** `ScreenAudioPlayer.java` — `AudioTrack` USAGE_MEDIA/CONTENT_TYPE_MUSIC, dedicated writer thread + drop-oldest queue. **iOS:** `ScreenAudioPlayer.{h,m}` in `common/darwin/Classes` (AudioQueue ring buffer, port of `audio_player_mac.cpp`; symlink forwarders in BOTH ios/ and macos/Classes since macOS shares `FlutterWebRTCPlugin.m`). Plays OUTSIDE the WebRTC voice session so the call's AEC/AGC doesn't mangle music — quality beats Discord (which routes shared audio through a voice track). **Android speaker-mute fix:** the `audioswitch` fork's deprecated `setSpeakerphoneOn(true)` global override steals the media track's speaker route in MODE_IN_COMMUNICATION; `repinScreenAudioToRoute()` (MethodCallHandlerImpl, on every route toggle) calls `ScreenAudioPlayer.setPreferredOutput` → `AudioTrack.setPreferredDevice(TYPE_BUILTIN_SPEAKER)`. iOS receive + iOS speaker mode untested as of 2026-06-30.

`_stopScreenAudioCapture()`: Sends 'Q' to exe stdin, waits 2s, force-kills if needed.

**Per-WINDOW (per-app) audio — Discord INCLUDE-set model (Windows, LIVE + confirmed 2026-06-30):** sharing a window now captures ONLY that app's audio (a silent app → silence, not the system). The window's desktop-source `id` IS the decimal HWND, so the dialog passes `windowHwnd` (NOT the unreliable `pid` — libwebrtc populates a window `pid` of 0, which is what made window shares fall back to system audio) through `ScreenShareSelection` → provider → `startScreenAudioCapture(windowHwnd:)` → exe `--window-hwnd`. The exe (`packages/flutter_webrtc/test_apps/screen_audio_test/`): `PidForWindowHandle` (`GetWindowThreadProcessId`, links `user32.lib`) → `ResolveWindowToAudioPids` (`audio_session_enum.cc`: enumerate all `eRender` endpoints → `IAudioSessionManager2::GetSessionEnumerator` → per-session `IAudioSessionControl2::GetProcessId/GetState`; map the window pid → audio-rendering pid SET by **exe-image-name match** [the browser/Electron audio-service child shares the top-level exe name — the load-bearing signal] ∪ process-tree descendants, shell/system hosts a hard boundary; self-`CoInitializeEx` since the exe main thread isn't COM-init'd) → `MultiProcessCapturer` (`multi_process_capturer.cc`: one `ProcessAudioCapturer` INCLUDE per pid, each buffers 10ms 48k-stereo frames; a wall-clock-phase-locked mixer thread [`timeBeginPeriod(1)`] sums+saturates and emits one 10ms frame, zero-filling short sources; 0 sources → silence). **The per-app path NEVER falls back to system** (an unresolvable hwnd → empty set → silence). A working INCLUDE on a real PID yields only that tree's audio OR silence by MS design, so "captures everything" proves the per-app path isn't engaging.

**Entire-screen anti-echo that KEEPS Hollow's OWN media (Windows, LIVE + 2-machine confirmed 2026-06-30 — this is "Bug B"):** the naive `--exclude-pid <hollow>` (capture system MINUS hollow.exe via `PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE`) also dropped Hollow's OWN legitimately-played media (a video opened in a chat). Windows filters loopback by process TREE only (no per-audio-session GUID), and Hollow's call voices (libwebrtc) + its in-app media render from the SAME hollow.exe, so they can't be split in-process. The fix moves the VOICES out of process, and is **armed ONLY during an entire-screen share WITH audio** (so regular calls are 100% untouched — no AEC/deafen/output-device change normally). Works for BOTH 1:1 calls and voice channels.

Three layers:
- **Tap + mute (fork C++, `common/cpp/src/flutter_voice_redirect.cc` NEW):** each REMOTE call/VC voice track is tapped via the prebuilt libwebrtc wrapper's `RTCAudioTrack::AddSink(AudioTrackSink*)` (`OnData` = decoded PCM; no libwebrtc rebuild) and `SetVolume(0)`'d. `SetVolume(0)` zeroes the voice in hollow.exe's output MIX (so its loopback capture has no voice) while the sink STILL receives full-volume PCM UPSTREAM of the output volume — the load-bearing property (suspect it first if a voice ever doubles). `FlutterWebRTCBase::voice_redirect()` (lazy) owns it; `MediaTrackForId(id)` resolves the track (same lookup `setVolume` uses).
- **Out-of-proc render (exe `--mode render-pcm` NEW):** `FlutterVoiceRedirect` spawns a render-pcm CHILD (`CreateProcess` + stdin pipe + a writer thread so the libwebrtc audio thread never blocks on the pipe; `CancelSynchronousIo` for safe teardown). `VoiceRedirectSink` tags each track's PCM with a stream_id and forwards `[u16 len][u8 stream_id][u16 rate][u8 ch][int16 PCM]`. The exe's `RunRenderPcmMode` (`main.cpp`) is a multi-stream renderer+MIXER: per-stream linear resample→48k stereo + wall-clock-paced mixer (same model as `MultiProcessCapturer`) → `AudioPlayer` (waveOut). One child mixes all VC peers. Method channels `voiceRedirectStart {trackIds}→{pid}` / `voiceRedirectStop` (mirror `setCaptureGain`); Dart `Helper.voiceRedirectStart/Stop`.
- **Capture exclude (the simple key):** the render-pcm child is a DESCENDANT of hollow.exe, so `EXCLUDE_TARGET_PROCESS_TREE` on the CHILD pid drops only the child's audio (the voices), NOT its ancestor hollow.exe → Hollow's media IS captured, and it's dynamic for free (no include-set re-enum). So the capturer just passes the child pid as the EXISTING `--exclude-pid` (`ScreenAudioCapturer.start(excludePid:)`; default `io.pid` when no redirect).

**Orchestration (`call_provider` + `voice_channel_provider`):** only `pid==0 && windowHwnd==0` (entire-screen) arms it. Collect remote audio track ids via `VoiceService.getRemoteAudioTrackIds()` / `VoiceChannelService.getAllRemoteAudioTrackIds()` (walk `getReceivers()`), `Helper.voiceRedirectStart(ids)`→child pid, pass as `excludePid`. **STOP order matters:** close the capturer FIRST, THEN disarm (restore SetVolume(1.0) + kill child) — else the brief restored-volume window gets re-captured (echo blip). Disarm in stopScreenShare + call/VC teardown (idempotent). **VC late-joiner:** `_sendScreenShareToPeer` re-calls `voiceRedirectStart` with all current VC track ids when armed (Start is incremental — AddSinks only new ids, child pid unchanged so the capturer isn't restarted). **Known risk (flagged):** during the share the mic AEC can't reference the out-of-proc voices → if both talk, the remote could hear their own echo; mitigation if it surfaces = `SetVolume(0.1)` for an AEC reference.

**Hollow as its OWN window in the share picker is NOT supported** (investigated + skipped 2026-06-30): libwebrtc drops the calling process's own windows from its enumerator, AND `GetDisplayMedia`'s video path (`flutter_screen_capture.cc`) only captures via a libwebrtc-enumerated `MediaSource` (a synthetic Dart picker entry fails "source not found!"). It would need a Windows-Graphics-Capture→`RTCVideoSource::OnCapturedFrame` frame-inject pipeline for our own HWND. Skipped because entire-screen already shows Hollow's window + plays its media.

**macOS (13.0+) — ALSO the data channel** (the Process Tap is RETIRED; it injected into the system default input which the CoreAudio voice ADM doesn't follow → 0 tracks). `MacSckScreenAudioCapturer` (`lib/src/core/services/mac_sck_screen_audio_capturer.dart`) drives `MacScreenShareAudioCapturer.m` (audio-only `SCStream`) → PCM over `EventChannel("FlutterWebRTC/ScreenShareAudio")` → `screen_audio_capturer --mode encode` (PCM→Opus) → `onPacket` → `sendScreenAudio` (0x03). Native gotchas (confirmed 2026-06-27): the SCStream MUST also add a minimal ignored `.screen` output (an audio-only stream's audio callback never fires), and `excludesCurrentProcessAudio=YES` so Hollow's own output (remote peers' voices) isn't re-broadcast into the share (the "I hear myself" echo). macOS <13.0: no API, the dialog locks the audio toggle.

**Multi-device send routing (CRITICAL, all platforms):** `sendScreenAudio`/`hasPeerChannel`/`connectToPeer` receive the call's MASTER peerId, but `_connections` is keyed by DEVICE id. `_openConnForIdentity()` resolves master→the call's open device channel (via the injected `resolveIdentity` = `deviceLinkProvider.identityOf`), with a single-open-channel fallback for a cold device-link map. Without it, `_connections[master]` missed → every Opus packet silently dropped (this was the macOS silent-audio cause). **The fallback is guarded (2026-07-02 audit fix):** both the `sendScreenAudio` fallback AND the `connectToPeer` "one open channel exists — reuse, don't dial" short-circuit only fire when `resolveIdentity(open.first.peerId) == open.first.peerId` (the channel's owner is UNKNOWN to the link map). A resolvable owner that didn't match `_openConnForIdentity` is a genuinely DIFFERENT person — the old unguarded version silently skipped dialing a second peer (a late-joining VC screen-share viewer lost its data channel / could get another viewer's audio duplicated) because "cold map" and "different person" look identical to a bare openCount check.

**Backpressure:** `sendScreenAudio` DROPS packets when the SCTP send buffer is backed up (>256KB) — the reliable+ordered `hollow-data` channel force-closes at the 16MB cap under audio load (esp. over TURN). Desktop emits no `bufferedAmount` change event, so it POLLS `getBufferedAmount()` every 12 sends and caches per device id.

**getDisplayMedia audio:** Always `false` for data-channel-audio platforms (Windows + macOS 13.0+) — audio rides the data channel, never the WebRTC track (the WASAPI/AudioSource track path crashes on Windows and isn't used on macOS).

---

## FrameCryptorService

File: `lib/src/core/services/frame_cryptor_service.dart`

Wraps flutter_webrtc's `FrameCryptor` + `KeyProvider` APIs for SFrame encryption of WebRTC audio/video. One instance per session: voice channel session (shared key) or DM call session (per-participant key).

### Initialization

`FrameCryptorService.init({sharedKey})`:
- Creates `KeyProvider` via `frameCryptorFactory.createDefaultKeyProvider()` with options:
  - `sharedKey`: true for server voice channels (all members share MLS epoch key), false for DM calls
  - `ratchetSalt`: `'hollow-sframe-salt'` (fixed salt)
  - `ratchetWindowSize`: 16
  - `failureTolerance`: -1 (unlimited)
  - `keyRingSize`: 16
  - `discardFrameWhenCryptorNotReady`: false

### Key Management

`setKey(participantId, index, key)`: Sets per-participant key. SECURITY: zeros key bytes after setting (Phase 6.25).

`setSharedKey(index, key)`: Sets shared key for all participants (server voice channels). SECURITY: zeros key bytes after setting.

`rotateKey(newIndex, newKey)`: Sets new shared key and updates key index on ALL active sender and receiver cryptors. Also updates `currentKeyIndex` field. Used by `setSframeKey()` on MLS epoch change.

`setKeyIndexForPeer(peerId, index)`: Sets the key index on all sender and receiver cryptors matching the given peerId prefix. Called after creating new cryptors to ensure they use the correct epoch key index.

`currentKeyIndex`: Tracks the active key index. New cryptors must call `setKeyIndex(currentKeyIndex)` after creation — they default to index 0 which may not match the current epoch.

### Enabling Encryption

`enableForSender(peerId, sender, {kind})`: Creates a sender-side `FrameCryptor` via `frameCryptorFactory.createFrameCryptorForRtpSender()` using AES-GCM algorithm. Keyed by `'$peerId:$kind'` where kind is `'audio'`, `'video'`, `'screen_audio'`, or `'screen_video'`. Registers `onFrameCryptorStateChanged` callback for logging. Enables immediately. Skips if already enabled for that key (dedup). **IMPORTANT:** Call `setKeyIndexForPeer` after this to set the correct key index.

`enableForReceiver(peerId, receiver, {kind})`: Same pattern for receiver-side decryption via `frameCryptorFactory.createFrameCryptorForRtpReceiver()`. Keyed by `'$peerId:$kind'`. **IMPORTANT:** Call `setKeyIndexForPeer` after this.

### Per-Peer Cleanup

`disableForPeer(peerId)`: Iterates kinds `['audio', 'video', 'screen_audio', 'screen_video']`, removes and disables/disposes both sender and receiver cryptors for each kind. Called by `VoiceChannelService.closePeer()`.

### Cryptor Maps

- `_senderCryptors`: Map<String, FrameCryptor> keyed by `'peerId:kind'`
- `_receiverCryptors`: Map<String, FrameCryptor> keyed by `'peerId:kind'`

### Disposal

`dispose()`: Disables and disposes all sender cryptors, then all receiver cryptors, then disposes the KeyProvider. Each operation wrapped in try/catch for safety. Sets `_enabled = false`.

### Integration Points

- **VoiceChannelService**: Creates instance during `startAudio()` with `sharedKey: true`. Key set via `setSframeKey(epoch, key)` when MLS epoch key arrives. Enables per-PC on initial handshake and renegotiation. Disposes per-peer on `closePeer()`. Full dispose on `closeAll()`.
- **VoiceService**: Created lazily in `setSframeKey()` with `sharedKey: true`. Key set at index 0 (single random key from CallInvite). Enables on sender/receiver audio only. Disposed on `endCall()`.
- **ScreenShareService**: Does not directly use FrameCryptorService (screen share E2EE is handled separately if needed by the caller).

### Key Source By Context

- **Server voice channels**: MLS epoch key, rotated on epoch change. `VoiceChannelService.setSframeKey(epoch, key)` uses `epoch % 16` as key ring index.
- **DM calls**: Random AES-128-GCM key generated by caller, exchanged in `CallInvite` signaling message (encrypted via Olm). Set at key ring index 0.
