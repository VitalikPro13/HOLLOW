# Rust Voice Handler — Voice Channels, 1:1 Calls, and WebRTC Signaling

The voice handler module manages all voice-related signaling in the Rust node layer. It covers three distinct scopes: WebRTC data channel peer tracking (connection/disconnection), 1:1 DM call signaling (invite/accept/reject/SDP/ICE/media state), and server voice channel signaling (join/leave/SDP/ICE/audio/camera/screen state). It also implements the mesh-to-gossip mode transition for large voice channels and per-peer rate limiting for voice channel signals.

Source file: `rust/hollow_core/src/node/voice_handler.rs` (932 lines)

Imports from: `crypto_handler::{peer_is_reachable, send_mls_broadcast, send_mls_to_peer, send_encrypted_message, send_message_to_peer}`, `types::*`, `gossip::GossipOverlay`

---

## handle_webrtc_peer_connected()

`voice_handler.rs:handle_webrtc_peer_connected(peer_id, webrtc_peers, gossip_overlays)`

Called when a WebRTC data channel becomes ready for a peer. This is for file transfer data channels, not voice/call media connections.

Steps:
1. Inserts `peer_id` into the `webrtc_peers: HashSet<String>` set
2. Iterates all `gossip_overlays` and calls `score.mark_connected()` on the peer's `PeerScore` entry in each overlay

The `webrtc_peers` set is used by `file_handler.rs` to determine which peers have active data channels for binary file/shard transfers.

---

## handle_webrtc_peer_disconnected()

`voice_handler.rs:handle_webrtc_peer_disconnected(peer_id, webrtc_peers, gossip_overlays)`

Called when a WebRTC data channel closes for a peer. Mirror of `handle_webrtc_peer_connected`.

Steps:
1. Removes `peer_id` from `webrtc_peers`
2. Iterates all `gossip_overlays` and calls `score.mark_disconnected()` on the peer's score

---

## handle_webrtc_send_signal()

`voice_handler.rs:handle_webrtc_send_signal(peer_id, signal_type, payload, conn_id, ws_cmd_tx, ws_room_peers)`

Outbound handler for WebRTC data channel signaling. Called from swarm.rs when Dart issues `NodeCommand::WebRtcSendSignal`. Translates a signal_type string + payload into the correct `HavenMessage` variant and sends it to the target peer via the WS relay.

Signal type mapping:
- `"offer"` -> `HavenMessage::RtcOffer { sdp: payload, conn_id }`
- `"answer"` -> `HavenMessage::RtcAnswer { sdp: payload, conn_id }`
- `"ice"` -> `HavenMessage::RtcIceCandidate { candidate, sdp_mid, sdp_mline_index, conn_id }` (parsed from JSON payload)

The `conn_id` field disambiguates multiple simultaneous WebRTC connections to the same peer (e.g., file transfer vs shard transfer). All signals are sent via `send_message_to_peer()` (plaintext HavenMessage over WS relay).

Incoming path: When a remote peer's RtcOffer/RtcAnswer/RtcIceCandidate arrives, `swarm.rs:handle_incoming_request()` processes them directly (not delegated to voice_handler). It validates SDP size against `MAX_SDP_SIZE` (64 KB) and emits `NetworkEvent::WebRtcSignal { peer_id, signal_type, payload, conn_id }` to Dart.

---

## handle_call_send_signal()

`voice_handler.rs:handle_call_send_signal(peer_id, signal_type, payload, ws_cmd_tx, ws_room_peers)`

Outbound handler for 1:1 DM call signaling. Called from swarm.rs when Dart issues `NodeCommand::CallSendSignal`. Supports 14 signal types covering the full call lifecycle plus screen sharing:

### Call lifecycle signals
- `"invite"` -> `HavenMessage::CallInvite { call_id, video, sframe_key }` — initiates a call. `video` indicates if video was requested. `sframe_key` is the caller's SFrame encryption key (base64 string).
- `"accept"` -> `HavenMessage::CallAccept { call_id, sframe_key }` — accepts incoming call, sends callee's SFrame key back.
- `"reject"` -> `HavenMessage::CallReject { call_id }` — rejects incoming call.
- `"end"` -> `HavenMessage::CallEnd { call_id }` — ends active call.
- `"busy"` -> `HavenMessage::CallBusy { call_id }` — auto-sent when already in a call.

### WebRTC negotiation signals
- `"sdp_offer"` -> `HavenMessage::CallSdpOffer { call_id, sdp }` — WebRTC SDP offer for the main audio/video PC.
- `"sdp_answer"` -> `HavenMessage::CallSdpAnswer { call_id, sdp }` — WebRTC SDP answer.
- `"ice"` -> `HavenMessage::CallIceCandidate { call_id, candidate, sdp_mid, sdp_mline_index }` — ICE candidate.

### Media state signals
- `"video_state"` -> `HavenMessage::CallVideoState { call_id, enabled }` — camera on/off toggle.
- `"screen_state"` -> `HavenMessage::CallScreenState { call_id, enabled, quality }` — screen share on/off with optional quality preset.

### Screen share WebRTC signals (separate PC)
- `"screen_offer"` -> `HavenMessage::CallScreenOffer { call_id, sdp }`
- `"screen_answer"` -> `HavenMessage::CallScreenAnswer { call_id, sdp }`
- `"screen_ice"` -> `HavenMessage::CallScreenIce { call_id, candidate, sdp_mid, sdp_mline_index, role }` — `role` distinguishes sender vs receiver ICE candidates.

All signals sent via `send_message_to_peer()` (plaintext HavenMessage). JSON payloads are parsed with graceful fallback: if JSON parsing fails for invite/accept, the raw payload is used as the call_id. For SDP/ICE types, parsing failure causes an early return (no message sent).

Incoming path: All incoming Call* HavenMessages are processed directly in `swarm.rs:handle_incoming_request()`. SDP-carrying messages (CallSdpOffer, CallSdpAnswer, CallScreenOffer, CallScreenAnswer) are validated against `MAX_SDP_SIZE` (64 KB). Each incoming message is re-serialized as a JSON payload and emitted as `NetworkEvent::CallSignal { peer_id, signal_type, payload }` to Dart.

---

## handle_voice_channel_join()

`voice_handler.rs:handle_voice_channel_join(server_id, channel_id, mls, ws_cmd_tx, ws_room_peers, server_states, bundle_keypair, voice_channel_participants, voice_channel_gossip_mode, gossip_overlays, local_peer_str, event_tx)`

Called when the local user joins a server voice channel (`NodeCommand::VoiceChannelJoin`).

Steps:
1. **Dual-path broadcast (MLS primary, plaintext fallback):** Constructs `MessageEnvelope::VoiceChannelJoin { sid, cid }` and attempts MLS broadcast to the server group. If MLS is unavailable or fails, falls back to plaintext `HavenMessage::VoiceChannelJoin` sent individually to each reachable server member. This dual-path approach is CRITICAL for MLS epoch resilience after reconnection — voice channel state changes must work immediately, not wait for MLS epoch sync.
2. **Track participant locally:** Adds own peer ID to `voice_channel_participants["{server_id}:{channel_id}"]` (HashMap<String, HashSet<String>>).
3. **Emit local event:** Sends `NetworkEvent::VoiceChannelJoined { server_id, channel_id, peer_id }` so the local UI updates immediately (own join is not received back from the network).
4. **Check mode transition:** Calls `check_voice_mode_transition()` to evaluate mesh/gossip threshold.

The `vc_key` format throughout the module is `"{server_id}:{channel_id}"`.

---

## handle_voice_channel_leave()

`voice_handler.rs:handle_voice_channel_leave(server_id, channel_id, mls, ws_cmd_tx, ws_room_peers, server_states, bundle_keypair, voice_channel_participants, voice_channel_gossip_mode, gossip_overlays, local_peer_str, event_tx)`

Called when the local user leaves a server voice channel (`NodeCommand::VoiceChannelLeave`).

Steps:
1. **Dual-path broadcast:** Same MLS-primary, plaintext-fallback pattern as join, using `MessageEnvelope::VoiceChannelLeave { sid, cid }`.
2. **Untrack participant:** Removes own peer ID from the `voice_channel_participants` set for this vc_key. If the set becomes empty, removes the entire entry and also removes the vc_key from `voice_channel_gossip_mode`.
3. **Emit local event:** `NetworkEvent::VoiceChannelLeft { server_id, channel_id, peer_id }`.
4. **Check mode transition:** Calls `check_voice_mode_transition()`.

---

## handle_voice_channel_send_signal()

`voice_handler.rs:handle_voice_channel_send_signal(server_id, channel_id, peer_id, signal_type, payload, mls, olm, crypto_store, ws_cmd_tx, ws_room_peers, server_states, bundle_keypair, local_peer_str, event_tx)`

Outbound handler for all voice channel signaling within server voice channels. Called from swarm.rs when Dart issues `NodeCommand::VoiceChannelSendSignal`. This is the most complex handler in the module because it supports 11 signal types and uses different delivery strategies depending on whether the signal is a broadcast or targeted.

### Signal types and their MessageEnvelope variants

All envelope variants include `sid`, `cid`, and a `target: None` field (target is unused in the current implementation; reserved for future SFU routing).

**SDP negotiation (targeted):**
- `"sdp_offer"` -> `MessageEnvelope::VoiceChannelSdpOffer { sid, cid, sdp, target }`
- `"sdp_answer"` -> `MessageEnvelope::VoiceChannelSdpAnswer { sid, cid, sdp, target }`
- `"ice"` -> `MessageEnvelope::VoiceChannelIce { sid, cid, candidate, sdp_mid, sdp_mline_index, target }`

**Screen share negotiation (targeted):**
- `"screen_offer"` -> `MessageEnvelope::VoiceChannelScreenOffer { sid, cid, sdp, target }`
- `"screen_answer"` -> `MessageEnvelope::VoiceChannelScreenAnswer { sid, cid, sdp, target }`
- `"screen_ice"` -> `MessageEnvelope::VoiceChannelScreenIce { sid, cid, candidate, sdp_mid, sdp_mline_index, role, target }` — `role` disambiguates sender/receiver.

**Renegotiation (targeted):**
- `"reneg_offer"` -> `MessageEnvelope::VoiceChannelRenegOffer { sid, cid, sdp, target }`
- `"reneg_answer"` -> `MessageEnvelope::VoiceChannelRenegAnswer { sid, cid, sdp, target }`

**Media state (broadcast):**
- `"audio_state"` -> `MessageEnvelope::VoiceChannelAudioState { sid, cid, muted, deafened, target }`
- `"screen_state"` -> `MessageEnvelope::VoiceChannelScreenState { sid, cid, enabled, target, quality }`
- `"camera_state"` -> `MessageEnvelope::VoiceChannelCameraState { sid, cid, enabled, target }`

### Delivery strategy (broadcast vs targeted)

The handler classifies signals as either broadcast or targeted based on `signal_type`:

**Broadcast signals** (`audio_state`, `screen_state`, `camera_state`):
1. Try `send_mls_broadcast()` to encrypt and send to the entire server MLS group
2. If MLS fails or is unavailable, fall back to plaintext `HavenMessage` variants sent individually to each reachable server member. The plaintext message variants are `HavenMessage::VoiceChannelAudioState`, `HavenMessage::VoiceChannelScreenState`, `HavenMessage::VoiceChannelCameraState`.

**Targeted signals** (all SDP/ICE/reneg types):
1. Try `send_mls_to_peer()` to encrypt the envelope for a specific peer within the MLS group
2. If MLS fails, fall back to Olm encryption via `send_encrypted_message()` (Olm is preferred over plaintext because SDP/ICE contain IP addresses — sensitive data)

This distinction is important: broadcast signals reveal no sensitive data (muted/deafened/enabled flags), while targeted signals contain SDP offers/answers and ICE candidates that expose IP addresses. Hence targeted signals use Olm as fallback (E2EE), not plaintext.

---

## handle_webrtc_ping_report()

`voice_handler.rs:handle_webrtc_ping_report(peer_id, rtt_ms, gossip_overlays)`

Called when Dart reports a WebRTC data channel ping RTT measurement. Updates the `PeerScore` for the given peer in every gossip overlay by calling `score.update_latency(rtt_ms)`. This feeds into gossip neighbor selection (lower latency peers are preferred).

---

## check_voice_mode_transition()

`voice_handler.rs:check_voice_mode_transition(vc_key, server_id, channel_id, voice_channel_participants, voice_channel_gossip_mode, gossip_overlays, local_peer_str, event_tx)`

Evaluates whether a voice channel should switch between full-mesh and gossip-relay mode based on participant count. Called after every join/leave event (both local and remote).

### Thresholds (hysteresis)
- **Mesh to gossip:** triggers when participant count >= `VOICE_GOSSIP_THRESHOLD_UP` (6)
- **Gossip to mesh:** triggers when participant count < `VOICE_GOSSIP_THRESHOLD_DOWN` (4)
- The gap between 4 and 6 prevents rapid mode flapping when participants hover around the threshold.

### Mode transition behavior

**Switching to gossip mode:**
1. Queries the server's `GossipOverlay` for voice gossip neighbors via `overlay.get_voice_gossip_neighbors(participants, local_peer_str)`. This selects the best-scoring peers from the participant set up to `MAX_GOSSIP_NEIGHBORS` (12).
2. If no gossip overlay exists, falls back to the first 12 non-self participants.
3. Emits `NetworkEvent::VoiceChannelModeChanged { server_id, channel_id, mode: "gossip", gossip_neighbors }` — Dart receives the neighbor list and adjusts which peers to maintain WebRTC connections with.

**Switching to mesh mode:**
1. Emits `NetworkEvent::VoiceChannelModeChanged { server_id, channel_id, mode: "mesh", gossip_neighbors: [] }` — Dart establishes connections to all participants.

The `voice_channel_gossip_mode: HashMap<String, bool>` tracks the current mode per vc_key.

---

## vc_rate_check()

`voice_handler.rs:vc_rate_check(vc_signal_rate_tokens, sender_peer_id) -> bool`

Token bucket rate limiter for incoming voice channel signaling envelopes. Called from swarm.rs before processing any VC signal envelope from a remote peer.

Parameters:
- `vc_signal_rate_tokens: HashMap<String, (u32, Instant)>` — per-peer token bucket state (tokens remaining, last refill time)
- `VC_SIGNAL_RATE_BURST = 30` — maximum burst size (defined in `types.rs`)
- `VC_SIGNAL_RATE_REFILL = 10` — tokens per second refill rate (defined in `types.rs`)

Algorithm:
1. Get or create the peer's token bucket entry (initial: 30 tokens, now)
2. Calculate elapsed time since last refill, compute tokens to add at 10/sec rate
3. If refill > 0, add tokens (capped at burst limit of 30) and reset refill timer
4. If 0 tokens remain, log a security warning and return `false` (signal is dropped)
5. Otherwise, decrement tokens and return `true`

This prevents a malicious peer from flooding the node with VC signal envelopes. Normal WebRTC negotiation produces a burst of ~10-20 signals during connection setup, well within the 30-token burst limit.

---

## is_vc_participant()

`voice_handler.rs:is_vc_participant(voice_channel_participants, vc_key, sender_peer_id) -> bool`

Private helper that checks whether a given peer is currently tracked as a participant in a specific voice channel. Used by all incoming envelope handlers as a security gate.

---

## emit_vc_sdp_signal()

`voice_handler.rs:emit_vc_sdp_signal(voice_channel_participants, event_tx, sender_peer_id, sid, cid, sdp, signal_type, log_label)`

Private helper used by all SDP-carrying voice channel envelope handlers. Performs two security checks before emitting to Dart:
1. **Participant check:** Verifies sender is a current VC participant via `is_vc_participant()`. Blocks non-participants.
2. **SDP size limit:** Rejects SDP payloads exceeding 64 KB (`sdp.len() > 64 * 1024`).

If both checks pass, wraps the SDP in a JSON object `{"sdp": sdp}` and emits `NetworkEvent::VoiceChannelSignal { server_id, channel_id, peer_id, signal_type, payload }`.

Used by: `handle_envelope_voice_channel_sdp_offer`, `handle_envelope_voice_channel_sdp_answer`, `handle_envelope_voice_channel_screen_offer`, `handle_envelope_voice_channel_screen_answer`, `handle_envelope_voice_channel_reneg_offer`, `handle_envelope_voice_channel_reneg_answer`.

---

## Incoming Voice Channel Envelope Handlers (MLS Path)

These handlers process `MessageEnvelope` variants that arrive via the MLS-encrypted path. They are called from `swarm.rs` after MLS decryption and envelope deserialization.

### handle_envelope_voice_channel_join()

`voice_handler.rs:handle_envelope_voice_channel_join(server_states, voice_channel_participants, voice_channel_gossip_mode, gossip_overlays, event_tx, local_peer_str, sender_peer_id, sid, cid)`

Processes a remote peer joining a voice channel via MLS.

Security checks:
1. Ignores if `sender_peer_id == local_peer_str` (own message echoed back)
2. Validates sender is a server member via `server_states[sid].members.contains_key(sender_peer_id)`. Blocks non-members with security log.
3. Validates the target channel is a Voice type channel via `server_states[sid].channels[cid].channel_type == ChannelType::Voice`. Blocks non-voice channels with security log.

If valid:
1. Adds sender to `voice_channel_participants[vc_key]`
2. Emits `NetworkEvent::VoiceChannelJoined { server_id, channel_id, peer_id }`
3. Calls `check_voice_mode_transition()`

### handle_envelope_voice_channel_leave()

`voice_handler.rs:handle_envelope_voice_channel_leave(voice_channel_participants, voice_channel_gossip_mode, gossip_overlays, event_tx, local_peer_str, sender_peer_id, sid, cid)`

Processes a remote peer leaving a voice channel via MLS.

1. Ignores if sender is self
2. Removes sender from `voice_channel_participants[vc_key]`. If set becomes empty, removes the entry and clears gossip mode.
3. Emits `NetworkEvent::VoiceChannelLeft { server_id, channel_id, peer_id }`
4. Calls `check_voice_mode_transition()`

Note: No server membership check on leave — if someone is in the participant set, they can leave. This avoids edge cases where a kicked member can't leave cleanly.

### handle_envelope_voice_channel_sdp_offer()

Delegates to `emit_vc_sdp_signal()` with `signal_type = "sdp_offer"`. Participant check + 64 KB SDP size limit.

### handle_envelope_voice_channel_sdp_answer()

Delegates to `emit_vc_sdp_signal()` with `signal_type = "sdp_answer"`. Same guards.

### handle_envelope_voice_channel_screen_offer()

Delegates to `emit_vc_sdp_signal()` with `signal_type = "screen_offer"`.

### handle_envelope_voice_channel_screen_answer()

Delegates to `emit_vc_sdp_signal()` with `signal_type = "screen_answer"`.

### handle_envelope_voice_channel_reneg_offer()

Delegates to `emit_vc_sdp_signal()` with `signal_type = "reneg_offer"`. Used for WebRTC renegotiation when tracks are added/removed mid-call.

### handle_envelope_voice_channel_reneg_answer()

Delegates to `emit_vc_sdp_signal()` with `signal_type = "reneg_answer"`.

### handle_envelope_voice_channel_ice()

`voice_handler.rs:handle_envelope_voice_channel_ice(voice_channel_participants, event_tx, sender_peer_id, sid, cid, candidate, sdp_mid, sdp_mline_index)`

Processes an incoming ICE candidate for voice channel WebRTC negotiation.
1. Participant check via `is_vc_participant()`
2. Constructs JSON payload: `{"candidate", "sdpMid", "sdpMLineIndex"}`
3. Emits `NetworkEvent::VoiceChannelSignal` with `signal_type = "ice"`

### handle_envelope_voice_channel_screen_ice()

`voice_handler.rs:handle_envelope_voice_channel_screen_ice(voice_channel_participants, event_tx, sender_peer_id, sid, cid, candidate, sdp_mid, sdp_mline_index, role)`

Same as ICE but for screen share peer connections. Includes `role` in the JSON payload to distinguish sender vs receiver ICE.

### handle_envelope_voice_channel_audio_state()

`voice_handler.rs:handle_envelope_voice_channel_audio_state(voice_channel_participants, event_tx, sender_peer_id, sid, cid, muted, deafened)`

Processes audio state change (mute/deafen). Participant check, then emits `NetworkEvent::VoiceChannelSignal` with `signal_type = "audio_state"` and payload `{"muted", "deafened"}`.

### handle_envelope_voice_channel_screen_state()

`voice_handler.rs:handle_envelope_voice_channel_screen_state(voice_channel_participants, event_tx, sender_peer_id, sid, cid, enabled, quality)`

Processes screen share state change. Participant check, then emits with `signal_type = "screen_state"` and payload `{"enabled"}` plus optional `"quality"` field.

### handle_envelope_voice_channel_camera_state()

`voice_handler.rs:handle_envelope_voice_channel_camera_state(voice_channel_participants, event_tx, sender_peer_id, sid, cid, enabled)`

Processes camera state change. Participant check, then emits with `signal_type = "camera_state"` and payload `{"enabled"}`.

---

## Plaintext Voice Channel Handlers (swarm.rs)

When MLS is unavailable, voice channel signals arrive as plaintext `HavenMessage` variants processed directly in `swarm.rs:handle_incoming_request()`. These mirror the MLS envelope handlers but are separate code paths:

- `HavenMessage::VoiceChannelJoin { server_id, channel_id }` — same member + voice channel validation, adds to participants, emits VoiceChannelJoined, calls `check_voice_mode_transition()`
- `HavenMessage::VoiceChannelLeave { server_id, channel_id }` — removes from participants, cleans up empty sets, emits VoiceChannelLeft, calls `check_voice_mode_transition()`
- `HavenMessage::VoiceChannelAudioState { server_id, channel_id, muted, deafened }` — participant check, emits VoiceChannelSignal
- `HavenMessage::VoiceChannelScreenState { server_id, channel_id, enabled, quality }` — participant check, emits VoiceChannelSignal
- `HavenMessage::VoiceChannelCameraState { server_id, channel_id, enabled }` — participant check, emits VoiceChannelSignal

Note: Plaintext path does NOT handle SDP/ICE signals. Those are only sent via targeted MLS or Olm (fallback) because they contain IP addresses.

---

## Incoming 1:1 Call and WebRTC Data Channel Handlers (swarm.rs)

These are processed directly in `swarm.rs:handle_incoming_request()`, not delegated to voice_handler.rs:

### WebRTC data channel signals
- `HavenMessage::RtcOffer { sdp, conn_id }` — SDP size check (64 KB), emits `NetworkEvent::WebRtcSignal` with `signal_type = "offer"`
- `HavenMessage::RtcAnswer { sdp, conn_id }` — SDP size check, emits WebRtcSignal with `signal_type = "answer"`
- `HavenMessage::RtcIceCandidate { candidate, sdp_mid, sdp_mline_index, conn_id }` — emits WebRtcSignal with `signal_type = "ice"`, payload is JSON-encoded candidate

### 1:1 call signals
All emit `NetworkEvent::CallSignal { peer_id, signal_type, payload }`:
- `HavenMessage::CallInvite { call_id, video, sframe_key }` -> signal_type "invite", JSON payload with all fields
- `HavenMessage::CallAccept { call_id, sframe_key }` -> signal_type "accept"
- `HavenMessage::CallReject { call_id }` -> signal_type "reject", payload is raw call_id
- `HavenMessage::CallEnd { call_id }` -> signal_type "end"
- `HavenMessage::CallBusy { call_id }` -> signal_type "busy"
- `HavenMessage::CallSdpOffer { call_id, sdp }` -> signal_type "sdp_offer" (SDP size check)
- `HavenMessage::CallSdpAnswer { call_id, sdp }` -> signal_type "sdp_answer" (SDP size check)
- `HavenMessage::CallIceCandidate { call_id, candidate, sdp_mid, sdp_mline_index }` -> signal_type "ice"
- `HavenMessage::CallVideoState { call_id, enabled }` -> signal_type "video_state"
- `HavenMessage::CallScreenState { call_id, enabled, quality }` -> signal_type "screen_state"
- `HavenMessage::CallScreenOffer { call_id, sdp }` -> signal_type "screen_offer" (SDP size check)
- `HavenMessage::CallScreenAnswer { call_id, sdp }` -> signal_type "screen_answer" (SDP size check)
- `HavenMessage::CallScreenIce { call_id, candidate, sdp_mid, sdp_mline_index, role }` -> signal_type "screen_ice"

---

## State Maps and Constants

### Swarm state consumed by voice_handler

- `voice_channel_participants: HashMap<String, HashSet<String>>` — key is `"{server_id}:{channel_id}"`, value is set of peer IDs currently in the voice channel. Used for participant tracking, security gates, and mode transition evaluation.
- `voice_channel_gossip_mode: HashMap<String, bool>` — key is vc_key, value is whether gossip mode is active. Cleaned up when a vc_key's participant set becomes empty.
- `webrtc_peers: HashSet<String>` — peers with active WebRTC data channels (for file transfers, not voice).
- `vc_signal_rate_tokens: HashMap<String, (u32, Instant)>` — per-peer token bucket for rate limiting VC signals.

### Constants

- `VC_SIGNAL_RATE_BURST = 30` (types.rs) — max tokens in rate limiter bucket
- `VC_SIGNAL_RATE_REFILL = 10` (types.rs) — tokens per second refill rate
- `MAX_SDP_SIZE = 64 * 1024` (types.rs) — 64 KB SDP size limit
- `VOICE_GOSSIP_THRESHOLD_UP = 6` (gossip.rs) — switch mesh -> gossip at this participant count
- `VOICE_GOSSIP_THRESHOLD_DOWN = 4` (gossip.rs) — switch gossip -> mesh below this count
- `MAX_GOSSIP_NEIGHBORS = 12` (gossip.rs) — max gossip relay neighbors per voice channel

---

## Security Model

1. **Server membership validation:** Voice channel join (both MLS and plaintext paths) checks that the sender is a member of the server and the target channel is of Voice type.
2. **Participant validation:** All voice channel signal handlers (SDP, ICE, audio/screen/camera state) verify the sender is a current participant before processing. Non-participants are blocked with security logs.
3. **SDP size limits:** 64 KB maximum on all SDP payloads (both data channel and voice/call paths). Prevents memory exhaustion from malformed SDPs.
4. **Rate limiting:** Token bucket (30 burst, 10/sec refill) per peer for VC signal envelopes. Prevents signal flooding.
5. **IP address protection:** Voice channel SDP/ICE signals use MLS-targeted encryption or Olm fallback (never plaintext) because SDPs and ICE candidates expose IP addresses. Broadcast state signals (muted/deafened/enabled) can fall back to plaintext since they contain no sensitive data.
6. **Avatar/banner size limits in profile context:** While not in voice_handler itself, the profile update path in swarm.rs caps avatar data at 1 MB and banner data at 2 MB for incoming base64 payloads.

---

## PeerJoined Voice Channel Sync

When a new peer joins a WS room (`PeerJoined` event in swarm.rs), the existing node sends `HavenMessage::VoiceChannelJoin` for every voice channel the local user is currently in. This ensures newly connected peers immediately learn about existing voice channel participants. The sync iterates `voice_channel_participants`, splits each vc_key back into server_id and channel_id, and sends individual plaintext join messages.
