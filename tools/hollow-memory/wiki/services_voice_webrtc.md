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

Audio quality settings: `opusBitrate` (default 32000), `opusStereo` (default false). Device preferences: `preferredAudioInputDeviceId`, `preferredAudioOutputDeviceId`, `preferredCameraDeviceId`.

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

`VoiceChannelService.startCamera()`:
1. Returns early if camera already on
2. Captures camera at 640x480@30fps via `getUserMedia`. Uses `sourceId` in optional array for device selection
3. For each existing PC in stable state:
   - Calls `pc.addTrack(videoTrack, _localVideoStream!)`
   - Enables SFrame sender encryption for video
   - Sends renegotiation offer
4. PCs not in stable state get added to `_pendingCameraReneg` set (renegotiated later when stable)
5. Returns the local video stream for provider to create renderer

`VoiceChannelService.stopCamera()`:
1. For each PC: gets senders, removes video senders via `pc.removeTrack(sender)`, sends renegotiation if stable
2. Stops all tracks and disposes `_localVideoStream`

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

Audio quality: `opusBitrate` (default 32000), `opusStereo` (default false). Set by CallNotifier before offer/answer creation.

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

`VoiceService.createRenegotiationOffer()`: Creates offer on existing PC, returns SDP. Used when toggling video mid-call.

`VoiceService.handleRenegotiationOffer(sdp)`: Sets remote description, creates answer. Schedules `_checkRemoteVideoTrack()` after 150ms delay.

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

`toggleVideo()`: Uses addTrack/removeTrack pattern (NEVER replaceTrack):
- **Disable**: Gets senders, finds video sender, calls `pc.removeTrack(sender)`. Stops tracks, disposes `_localVideoStream`. Disposes `_localRenderer`. Sets `_isVideoEnabled = false`.
- **Enable**: Cleans up any leaked stream from previous failed enable. Captures camera (640x480@30fps, `sourceId` for device selection). Calls `pc.addTrack(videoTrack, _localVideoStream!)` to create fresh transceiver. Initializes local renderer. Sets `_isVideoEnabled = true`.
- Caller (CallNotifier) must trigger SDP renegotiation after toggleVideo returns.

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

`VoiceService.endCall()`:
1. Stops and disposes local audio stream (all tracks stopped individually)
2. Stops and disposes local video stream
3. Disposes local and remote renderers (srcObject=null first, then dispose)
4. Closes and disposes PC
5. Disposes `_frameCryptor`
6. Clears all state

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

Takes `localPeerId` and optional `iceServers`. Core state:

- `_connections`: Map<String, _PeerConn> -- active peer connections
- `_transfers`: Map<String, _IncomingTransfer> -- active incoming file transfers
- `_pendingIceCandidates`: Map<String, List<RTCIceCandidate>> -- queued before connection created
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
- **Same connId** (renegotiation): handles renegotiation glare (lower peerId wins via rollback), creates answer
- **Different connId** (initial glare): lower peerId is "polite" -- drops own connection and accepts incoming offer. Higher peerId is "impolite" -- ignores incoming offer
- **New connection**: Creates PC, wires `onDataChannel` (answerer receives DC this way), `onIceCandidate`, `onConnectionState`. Sets remote description, creates answer, flushes pending ICE.

`_handleAnswer(peerId, payload, connId)`: Validates connId matches, sets remote description.

`_handleIce(peerId, payload, connId)`: If no connection exists yet, queues candidate. Otherwise adds directly.

### Data Channel Setup

`_setupDataChannel(dc, peerId)`:
- `onDataChannelState`: On Open calls `_onDataChannelReady()`, on Closed calls `_onDataChannelClosed()` (only reacts to final Closed, not Closing -- prevents double-fire)
- `onMessage`: Routes to `_onDataChannelMessage()`, resets idle timer

`_onDataChannelReady(peerId)`:
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

`_cleanupConnection(peerId)`: Removes from `_connecting` and `_stunOnlyPeers`, cancels timers, closes data channel, closes/disposes PC.

`dispose()`: Disconnects all peers, clears transfers and pending ICE candidates.

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

### Resolution and Bitrate Capping

`_applyResolutionCap(maxWidth, maxHeight)`: Applied to the video sender's encoding parameters after `addTrack`. `getDisplayMedia` captures at native resolution -- this constrains the encoder:

1. Gets sender track settings (captureWidth/captureHeight)
2. Computes scale factor if capture exceeds target, sets `scaleResolutionDownBy`
3. Caps bitrate by pixel count tier:
   - 360p: 800 kbps
   - 480p: 1500 kbps
   - 720p: 3000 kbps
   - 1080p: 6000 kbps
   - 1440p: 9000 kbps
   - 4K: 15000 kbps
4. Higher than camera bitrates because screen content has sharp edges/text that compress poorly

### Outgoing Screen Share

`ScreenShareService.createOffer(sourceId, width, height, fps, {shareAudio})`:
1. Calls `desktopCapturer.getSources()` to refresh source list
2. Calls `navigator.mediaDevices.getDisplayMedia()` with source ID, frame rate, and audio flag
3. Validates video tracks exist (security check)
4. Creates local self-preview renderer
5. Creates PC, wires callbacks via `_setupCallbacks()`
6. Adds screen video track via `pc.addTrack()`
7. Applies resolution/bitrate cap
8. If audio tracks present, adds them all via `pc.addTrack()`
9. Creates offer, sets local description
10. Starts track poller (2s interval checks if screen track is still enabled)
11. Returns SDP offer string

`createOfferFromStream(stream, {maxWidth, maxHeight})`: Alternative for voice channels where one capture is shared across multiple peer connections. Takes pre-captured `MediaStream` instead of capturing new one. Caller manages track poller centrally. Otherwise same flow.

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

### System Audio Capture

When `shareAudio = true` is passed to `createOffer()`, `getDisplayMedia` is called with `'audio': true`. On Windows, the forked `flutter_webrtc` at `../flutter-webrtc-1.4.1/` provides WASAPI loopback capture inside `getDisplayMedia({audio: true})`. The captured audio track must NOT be attached to the returned MediaStream at the native level (`stream->AddTrack` crashes libwebrtc's sender iteration); instead Dart adds it via `pc.addTrack(audioTrack, stream)`. Audio tracks from getDisplayMedia are added individually to the PC after the video track.

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

`rotateKey(newIndex, newKey)`: Sets new shared key and updates key index on ALL active sender and receiver cryptors. Used on MLS epoch change.

### Enabling Encryption

`enableForSender(peerId, sender, {kind})`: Creates a sender-side `FrameCryptor` via `frameCryptorFactory.createFrameCryptorForRtpSender()` using AES-GCM algorithm. Keyed by `'$peerId:$kind'` where kind is `'audio'` or `'video'`. Registers `onFrameCryptorStateChanged` callback for logging. Enables immediately. Skips if already enabled for that key (dedup).

`enableForReceiver(peerId, receiver, {kind})`: Same pattern for receiver-side decryption via `frameCryptorFactory.createFrameCryptorForRtpReceiver()`. Keyed by `'$peerId:$kind'`.

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
