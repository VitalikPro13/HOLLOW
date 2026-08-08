# Rust Voice Handler — Voice Channels, 1:1 Calls, and WebRTC Signaling

The voice handler module manages all voice-related signaling in the Rust node layer. It covers three distinct scopes: WebRTC data channel peer tracking (connection/disconnection), 1:1 DM call signaling (invite/accept/reject/SDP/ICE/media state), and server voice channel signaling (join/leave/SDP/ICE/audio/camera/screen state). It also implements the mesh-to-gossip mode transition for large voice channels and per-peer rate limiting for voice channel signals.

Source file: `rust/hollow_core/src/node/voice_handler.rs` (932 lines)

Imports from: `crypto_handler::{peer_is_reachable, send_mls_broadcast, send_encrypted_message, send_message_to_peer}`, `types::*`, `gossip::GossipOverlay`

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

The `conn_id` field disambiguates multiple simultaneous WebRTC connections to the same peer (e.g., file transfer vs shard transfer).

**Multi-device:** the signal is sent to `pick_online_device(ws_room_peers, peer_id)`, NOT the raw `peer_id`. `peer_id` may be the conversation MASTER (the UI key), which no socket authenticates as → a direct send is dropped and the data channel (used for P2P file transfer) never forms. `pick_online_device` resolves the master to ONE concrete online device (deterministic lowest id) — NOT a fan-out (a duplicate offer/answer to several devices creates competing peer connections / glare for one `conn_id`). **CRITICAL:** if `peer_id` is ALREADY a live device id (exact match in a room), it's returned UNCHANGED — so an ANSWER/ICE flows back to the EXACT device that sent the offer; the master→device pick only applies to an outbound offer where Dart only knows the master.

Incoming path: When a remote peer's RtcOffer/RtcAnswer/RtcIceCandidate arrives, `swarm.rs:handle_incoming_request()` processes them directly (not delegated to voice_handler). It validates SDP size against `MAX_SDP_SIZE` (64 KB) and emits `NetworkEvent::WebRtcSignal { peer_id, signal_type, payload, conn_id }` to Dart (the sender's DEVICE id).

---

## handle_call_send_signal()

`voice_handler.rs:handle_call_send_signal(peer_id, signal_type, payload, ws_cmd_tx, ws_room_peers)`

Outbound handler for 1:1 DM call signaling. Called from swarm.rs when Dart issues `NodeCommand::CallSendSignal`. Supports 14 signal types covering the full call lifecycle plus screen sharing.

**Multi-device:** like WebRTC signaling above, the final send targets `pick_online_device(ws_room_peers, peer_id)` (the friend's master → ONE online device), not the bare master — else invite/accept/sdp/ice/state are silently dropped and the call never rings/connects. Already-live-device ids pass through unchanged (answer/ICE returns to the exact peer). **Incoming attribution is collapsed device→master on the Dart side:** `event_provider`'s `NetworkEvent_CallSignal` handler resolves the caller's device id via `deviceLinkProvider.identityOf` BEFORE `handleCallSignal`, so all `call.peerId == widget.peerId` checks match the DM master key (without it, a call from a multi-device friend showed under the raw device id = a "different DM", and the screen-share control gated OFF because `isCallWithThisPeer` was false). See memory `feedback_multidevice_targeting_sweep`. Signal types:

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

`voice_handler.rs:handle_voice_channel_join(server_id, channel_id, mls, ws_cmd_tx, ws_room_peers, server_states, bundle_keypair, voice_channel_participants, voice_channel_gossip_mode, gossip_overlays, mls_epoch_hint_cooldown, local_peer_str, device_peer_id, event_tx)`

Called when the local user joins a server voice channel (`NodeCommand::VoiceChannelJoin`).

Steps:
0. **Restricted-channel guard (Phase 2 subgroups):** if `server.channel_uses_subgroup(channel_id)` (restricted, non-public), REJECT the join when `!can_see_channel(local_peer)` — return before announcing or touching SFrame. A modified client can't join a channel its role can't see.
1. **Always-plaintext broadcast (MLS + plaintext simultaneously):** Constructs `MessageEnvelope::VoiceChannelJoin { sid, cid }` and sends MLS broadcast if available, PLUS always sends plaintext `HavenMessage::VoiceChannelJoin` to each reachable server member regardless of MLS success. Both paths fire unconditionally — MLS provides forward secrecy, plaintext ensures delivery survives stale MLS epochs. Receivers deduplicate via `HashSet::insert` (idempotent) and `_peerConnections.containsKey` guard.
2. **Track participant locally:** Adds our **DEVICE peer id** (`device_peer_id`, NOT the master) to `voice_channel_participants["{server_id}:{channel_id}"]` (HashMap<String, HashSet<String>>) — SELF is keyed exactly like every remote entry (self-ghost fix 2026-08-07; see memory `feedback_vc_self_ghost_device_keyed_self`).
3. **Emit SFrame key:** the group key is the channel's SUBGROUP (`subgroup_id(server, channel)`) when restricted, else the bare `server_id`. Emits `NetworkEvent::MlsEpochChanged { server_id, epoch, sframe_key, channel_id }` (channel_id = `Some(cid)` for a restricted channel so Dart routes the key to that channel's cryptor). If restricted but we don't hold the subgroup yet (just promoted / just joined), calls `crypto_handler::request_subgroup_bootstrap` — the resulting Welcome → MlsEpochChanged delivers the key. NEVER falls back to the server-group key for a restricted channel. If NON-restricted and the SERVER group is missing (0.8.6): calls `crypto_handler::request_server_group_bootstrap` (owner-targeted KeyPackage) — joining a VC keyless while peers encrypt would play their audio as ciphertext.
4. **Emit local event:** Sends `NetworkEvent::VoiceChannelJoined { server_id, channel_id, peer_id: device_peer_id, is_self: true }` so the local UI updates immediately (own join is not received back from the network). `is_self` is set by the emitting handler, which knows for certain — Dart's event_provider branches on the FLAG, never on comparing peer_id to a local id (every id-form guess there has produced a self-dial bug).
5. **Check mode transition:** Calls `check_voice_mode_transition()` to evaluate mesh/gossip threshold.

The `vc_key` format throughout the module is `"{server_id}:{channel_id}"`.

**`auto_leave_invisible_voice_channels()`** — after a role/visibility/kick/ban CRDT op applies, leaves any voice channel the local node is in but can no longer SEE (`!can_see_channel`, or no longer a member). Runs the normal `handle_voice_channel_leave` teardown. Invoked from BOTH the plaintext `CrdtOpBroadcast` apply path AND the MLS `CrdtOp` apply path in swarm.rs (the MLS path usually wins the apply race and previously ran no reconcile/auto-leave).

**MLS-path VC handlers key on the routable WS sender, not the MLS leaf credential.** In the swarm.rs MLS envelope dispatch, all `VoiceChannel*` handlers receive `peer_str.to_string()` (the relay-reported sender), NOT `sender_peer_id` (the MLS leaf credential). For a multi-device sender these differ; the leaf credential is not a live socket, so using it adds a phantom 2nd participant and makes SDP/ICE replies Olm-target an unreachable id. The plaintext VC path already uses the routable sender — matching it lets the participant Set dedup the two arrivals.

**The participant set is device-keyed INCLUDING self (self-ghost fix, 2026-08-07).** Every self membership/exclusion compare uses `device_peer_id` (master kept only as a legacy belt): the Disconnected keep-only-self retain, the reconnect VC re-broadcast check, `auto_leave_invisible_voice_channels`, the conference reply-on-join check, and gossip-neighbor self-exclusion. Inbound join/leave self-echo guards match BOTH id forms. Regression: harness `vc_self_participant_is_device_keyed_no_self_dial` (runs device≠master seeds — the other VC tests use identical seeds and can't catch a mixup).

---

## handle_voice_sframe_heal() (0.8.6, issue #27)

`voice_handler.rs:handle_voice_sframe_heal(server_id, channel_id, peer_id, escalate, mls, ws_cmd_tx, ws_room_peers, server_states, pending_mls_removals, mls_bootstrap_requested, crypto_store, local_peer_str, event_tx)` — `NodeCommand::VoiceSframeHeal`, fired by Dart's heal ladder (FFI `voice_sframe_heal`) when voice cryptors report sustained decrypt failures against `peer_id`.

Group key resolution: conference sid → the sid itself; restricted channel → `subgroup_id(server, channel)`; else bare `server_id`.

1. **Cheap fix always:** a held-but-INACTIVE group (we were evicted — see the swarm.rs commit eviction check) is dropped first (`is_active()`), then: group usable → `export_and_emit_sframe` re-emits the CURRENT `MlsEpochChanged` (idempotent for Dart); group missing → cooldown-guarded (`MLS_BOOTSTRAP_TIMEOUT`) bootstrap request: `request_subgroup_bootstrap` (restricted) / `request_server_group_bootstrap` (server group, owner-targeted; NEW 0.8.6) — then return.
2. **Escalation** (`escalate: true`, Dart applies a 60s cooldown + max-2-per-peer budget): conferences re-emit ONLY (dropping the conf group would drop admission). Authority = server owner (server group) / `elect_subgroup_coordinator` (subgroup):
   - **We are NOT the authority:** drop our group, persist, fresh KeyPackage → authority (`MlsKeyPackage`), arm `mls_bootstrap_requested` — the fresh Welcome lands us on the authority's epoch.
   - **We ARE the authority:** queue ALL of the failing peer's leaves (`same_identity` match) into `pending_mls_removals[group_key]` + send `MlsKeyPackageRequest` to the peer's master. The batch timer's removal commit re-keys everyone; the peer converges via the re-add Welcome or (if its group is forked/it got evicted) its own commit-fail / eviction recovery.

**Eviction check (swarm.rs MlsCommit Ok-arm, 0.8.6):** a commit that removes OUR OWN leaf merges cleanly but leaves the OpenMLS group INACTIVE — `has_group` stays true while export/encrypt fail forever (a silent permanent SFrame wedge). After every processed commit: `!mls.is_active(group_key)` → drop the group; if we're still a CRDT member (heal remove+re-add, NOT a kick/ban) → cooldown-guarded re-bootstrap from owner/coordinator. Harness coverage: `sframe_heal_reemits_current_epoch_key`, `sframe_heal_escalation_rebootstraps_non_authority`, `sframe_heal_escalation_authority_removes_and_readds_peer`. Full story: memory `project_sframe_heal_ladder`.

---

## handle_voice_channel_leave()

`voice_handler.rs:handle_voice_channel_leave(server_id, channel_id, mls, ws_cmd_tx, ws_room_peers, server_states, bundle_keypair, voice_channel_participants, voice_channel_gossip_mode, gossip_overlays, local_peer_str, device_peer_id, event_tx)`

Called when the local user leaves a server voice channel (`NodeCommand::VoiceChannelLeave`).

Steps:
1. **Always-plaintext broadcast:** Same MLS + plaintext simultaneous pattern as join, using `MessageEnvelope::VoiceChannelLeave { sid, cid }`. Both paths fire unconditionally.
2. **Untrack participant:** Removes our DEVICE id (and the master form, as a legacy belt) from the `voice_channel_participants` set for this vc_key. If the set becomes empty, removes the entire entry and also removes the vc_key from `voice_channel_gossip_mode`.
3. **Emit local event:** `NetworkEvent::VoiceChannelLeft { server_id, channel_id, peer_id: device_peer_id, is_self: true }`.
4. **Check mode transition:** Calls `check_voice_mode_transition()`.

---

## handle_voice_channel_send_signal()

`voice_handler.rs:handle_voice_channel_send_signal(server_id, channel_id, peer_id, signal_type, payload, mls, olm, crypto_store, ws_cmd_tx, ws_room_peers, server_states, bundle_keypair, local_peer_str, device_peer_id, event_tx)`

Outbound handler for all voice channel signaling within server voice channels. Called from swarm.rs when Dart issues `NodeCommand::VoiceChannelSendSignal`. This is the most complex handler in the module because it supports 11 signal types and uses different delivery strategies depending on whether the signal is a broadcast or targeted.

**Self-target belt (first check, 2026-08-07):** a `peer_id` matching EITHER of our own id forms (master or device) is dropped with a loud log before anything else — encrypting to ourselves can never succeed (it produced the "Encryption failed: No session" storms of the self-ghost bug, one per trickled ICE candidate) and a master-form target is never routable. Sibling devices have distinct device ids and are never blocked.

### Signal types and their MessageEnvelope variants

All envelope variants include `sid`, `cid`, and a `target: None` field (target is unused in the current implementation; reserved for future SFU routing).

**SDP negotiation (targeted):**
- `"sdp_offer"` -> `MessageEnvelope::VoiceChannelSdpOffer { sid, cid, sdp, target }`
- `"sdp_answer"` -> `MessageEnvelope::VoiceChannelSdpAnswer { sid, cid, sdp, target }`
- `"ice"` -> `MessageEnvelope::VoiceChannelIce { sid, cid, candidate, sdp_mid, sdp_mline_index, target }`

**Screen share negotiation (targeted):**
- `"screen_offer"` -> `MessageEnvelope::VoiceChannelScreenOffer { sid, cid, sdp, target, origin }`
- `"screen_answer"` -> `MessageEnvelope::VoiceChannelScreenAnswer { sid, cid, sdp, target, origin }`
- `"screen_ice"` -> `MessageEnvelope::VoiceChannelScreenIce { sid, cid, candidate, sdp_mid, sdp_mline_index, role, target, origin }` — `role` disambiguates sender/receiver.

**`origin` (media forwarding step 2, 2026-08-05):** `Option<Box<StreamOrigin>>` with
`{peer, kind, stream}` — the stream's ORIGINATOR (routable device id), the stream kind
(`"screen"`), and a per-share-session random id. `#[serde(default)]` +
`skip_serializing_if` ⇒ absent on old clients and byte-identical wire when unset; absent means
"the delivering sender is the originator" (every direct leg today). Dart parses it from the
payload's `origin` sub-object (`parse_stream_origin`). Receivers key attribution, watch-consent,
dedup and SFrame cryptor registration on `origin.peer`; transport routing stays on the sender.
**Spoof guard `inbound_origin_ok()`**: an inbound origin must be resolver-`same_identity` with
the Olm/MLS-authenticated sender (offer / outgoing-role ICE) or with the local identity
(answer / incoming-role ICE echoing our own share) — anything else drops the WHOLE signal with a
`[HOLLOW-SECURITY]` log (the SFrame group key is shared, so a spoofed origin would attribute the
spoofer's pixels to the victim). Forwarder-delivered legs ride the separate `fwd_*` namespace (see
below), never these variants. The screen offer/answer/ICE Olm arms in swarm.rs were
consolidated into the shared `handle_envelope_voice_channel_screen_*` handlers so guards live in
ONE place for both Olm and MLS paths (`emit_vc_screen_sdp_signal` = the screen twin of
`emit_vc_sdp_signal` with the origin guard + payload passthrough).

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
1. Olm-encrypt via `send_encrypted_message()` + `SendDirect` to the specific peer

This distinction is important: broadcast signals reveal no sensitive data (muted/deafened/enabled flags), while targeted signals contain SDP offers/answers and ICE candidates that expose IP addresses. Hence targeted signals always use Olm (E2EE), not plaintext.

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
1. Queries the server's `GossipOverlay` for voice gossip neighbors via `overlay.get_voice_gossip_neighbors(participants, local_device_str)`. This selects the best-scoring peers from the participant set up to `MAX_GOSSIP_NEIGHBORS` (12). Self-exclusion compares the DEVICE id — the participant set (self included) is device-keyed.
2. If no gossip overlay exists, falls back to the first 12 non-self participants (same device-id exclusion).
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
1. **Eviction:** If the map exceeds 16 entries, evicts all entries older than 10 minutes to prevent unbounded growth.
2. Get or create the peer's token bucket entry (initial: 30 tokens, now)
3. Calculate elapsed time since last refill, compute tokens to add at 10/sec rate
4. If refill > 0, add tokens (capped at burst limit of 30) and reset refill timer
5. If 0 tokens remain, log a security warning and return `false` (signal is dropped)
6. Otherwise, decrement tokens and return `true`

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

Used by: `handle_envelope_voice_channel_sdp_offer`, `handle_envelope_voice_channel_sdp_answer`, `handle_envelope_voice_channel_reneg_offer`, `handle_envelope_voice_channel_reneg_answer`. The screen offer/answer handlers use `emit_vc_screen_sdp_signal()` instead — same two checks plus the media-forwarding origin spoof guard, and the payload forwards `origin` when present.

---

## Incoming Voice Channel Envelope Handlers (MLS Path)

These handlers process `MessageEnvelope` variants that arrive via the MLS-encrypted path. They are called from `swarm.rs` after MLS decryption and envelope deserialization.

### handle_envelope_voice_channel_join()

`voice_handler.rs:handle_envelope_voice_channel_join(server_states, voice_channel_participants, voice_channel_gossip_mode, gossip_overlays, event_tx, local_peer_str, sender_peer_id, sid, cid)`

Processes a remote peer joining a voice channel via MLS.

Security checks:
1. Ignores if the sender matches EITHER of our own id forms (`local_peer_str` OR `device_peer_id`) — an echo carries our DEVICE id, so the master compare alone would admit our own join as a remote participant
2. Validates sender is a server member via `server_states[sid].members.contains_key(sender_peer_id)`. Blocks non-members with security log.
3. Validates the target channel is a Voice type channel via `server_states[sid].channels[cid].channel_type == ChannelType::Voice`. Blocks non-voice channels with security log.

If valid:
1. Adds sender to `voice_channel_participants[vc_key]`
2. Emits `NetworkEvent::VoiceChannelJoined { server_id, channel_id, peer_id, is_self: false }`
3. Calls `check_voice_mode_transition()`

### handle_envelope_voice_channel_leave()

`voice_handler.rs:handle_envelope_voice_channel_leave(voice_channel_participants, voice_channel_gossip_mode, gossip_overlays, event_tx, local_peer_str, device_peer_id, sender_peer_id, sid, cid)`

Processes a remote peer leaving a voice channel via MLS.

1. Ignores if sender is self (both id forms, same as the join twin)
2. Removes sender from `voice_channel_participants[vc_key]`. If set becomes empty, removes the entry and clears gossip mode.
3. Emits `NetworkEvent::VoiceChannelLeft { server_id, channel_id, peer_id, is_self: false }`
4. Calls `check_voice_mode_transition()`

Note: No server membership check on leave — if someone is in the participant set, they can leave. This avoids edge cases where a kicked member can't leave cleanly.

### handle_envelope_voice_channel_sdp_offer()

Delegates to `emit_vc_sdp_signal()` with `signal_type = "sdp_offer"`. Participant check + 64 KB SDP size limit.

### handle_envelope_voice_channel_sdp_answer()

Delegates to `emit_vc_sdp_signal()` with `signal_type = "sdp_answer"`. Same guards.

### handle_envelope_voice_channel_screen_offer()

Delegates to `emit_vc_screen_sdp_signal()` with `signal_type = "screen_offer"` — participant
check + 64 KB SDP limit + the `inbound_origin_ok()` spoof guard; forwards `origin` in the
emitted payload. Called from BOTH the MLS dispatch arms and the (consolidated) Olm dispatch
arms in swarm.rs.

### handle_envelope_voice_channel_screen_answer()

Delegates to `emit_vc_screen_sdp_signal()` with `signal_type = "screen_answer"`. Same guards +
origin passthrough; also serves both Olm and MLS paths. (`screen_ice` applies the same origin
guard inline in its own handler.)

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

## Call Signal Whitelist + CallAudioState (2026-06)

`handle_call_send_signal` (1:1) and `handle_voice_channel_send_signal` (VC) are **whitelists**: each Dart `signalType` string maps to a dedicated `HavenMessage`/`MessageEnvelope` variant; unknown types fall into `_ =>` and are SILENTLY dropped (hollow_log only). Adding a new 1:1 signal type requires three touches:
1. `HavenMessage` variant in `types.rs` (use `#[serde(default)]` on fields so old builds' messages don't fail deserialization) — e.g. `CallAudioState { call_id, muted, deafened }` (`#[serde(rename = "call_audio_state")]`).
2. The match arm in `handle_call_send_signal` (voice_handler.rs) parsing the JSON payload.
3. The incoming dispatch arm in `swarm.rs` (next to `CallVideoState`) re-emitting `NetworkEvent::CallSignal { signal_type, payload }` to Dart.

No frb codegen needed — `HavenMessage` is internal, and `call_send_signal`/`NetworkEvent::CallSignal` are already generic over the type string. `CallAudioState` carries the 1:1 mute/deafen badge sync (Dart `audio_state`).

**Recording indicator (issue #53, 2026-08-05):** Dart's `recording_start`/`recording_stop` signals are whitelisted on BOTH paths. 1:1 → `HavenMessage::CallRecordingState { call_id, recording }` (`call_recording_state`); VC → broadcast-class `MessageEnvelope::VoiceChannelRecordingState { sid, cid, recording, target }` (`vc_recording_state`) + plaintext `HavenMessage` twin — added to `is_broadcast`, the VC rate-limiter list, the MLS-only-via-Olm list, and `target()`. Receive handlers gate on VC participant membership and reconstruct the Dart-facing signal-type string from the `recording` bool. The VC Dart sender fires ONE broadcast (`peerId: ''`) — a per-peer loop would emit N duplicate MLS broadcasts. Harness-covered in both the DM and VC signal-routing tests.

## Phase 2 — viewer-peer forwarders (FIELD-VERIFIED COMPLETE 2026-08-07, all four runs; details in reports/MEDIA_FORWARDING_PLAN.md §7)

The SAME `fwd_*` contract now also terminates at an **embedded engine inside desktop app
builds** (`node/embedded_forwarder.rs` bridges the swarm's Olm dispatch ↔ `forwarder::engine`;
cargokit passes `--features forwarder`, mobile target-scoped out). A fwd-capable watcher on a
direct route gets PROMOTED by the sharer (self-assigned via `vc_screen_assign{forwarder: itself}`
— `ForwarderSendSignal` to one's own device id short-circuits into the engine, no Olm), serves
up to 3 remote viewers, and its own display rides its engine as viewer #0. Ladder: peer branch →
VPS infra forwarder → direct+TURN; `relay_private` (Always-relay users) skips the peer rungs
both sharer-side and via a viewer-side hard refusal. Key rules: register BEFORE any assign
(same-socket ordering vs the instant local self-attach); a branch head's `direct_failed` =
demote, never re-ladder; presence events never kill a branch whose MEDIA LEG is alive (relay
ghost-eviction broadcasts spurious PeerLeft); branch ingest legs are INSIDE both SFrame re-key
sweeps. `vc_screen_watch` gained `fwd_capable` + `relay_private` (`#[serde(default)]`).

**Opportunistic rebalancer (2026-08-07, field-verified twice 2026-08-08):** watch ORDER no
longer decides the topology. A fresh `route=direct fwd_capable` watch arriving while the VPS
infra branch carries viewers promotes that watcher and migrates the branch's viewers onto the
new peer branch (`_maybeRebalanceOntoCandidate` in voice_channel_provider.dart, hooked into
`_handleScreenWatch`'s direct path) — one blink per migrated viewer, ≤3 legs, `relay_private`
viewers stay on operator infra, per-viewer failed-forwarder memory honored, no chains.
Migration is MAKE-BEFORE-BREAK: viewers leave the VPS branch LOCALLY only (no eager
`fwd_stream_auth` removal — the VPS killing the old egress leg before the assign lands reads
as a branch failure and would permanently fail-mark the fresh candidate); the viewer retires
its own leg on assign receipt and the emptied branch's 30 s linger unregisters. Viewer-side
fwd→fwd reassignment releases the OLD forwarder's room (stale fwd-room membership = the
routing-blackhole shape; own room excluded — bridge-owned) and arms the shared 20 s no-show
watchdog (`_armWatchNoShowTimer`). An honest `route=relay` probe from a direct-capable watcher
(ICE race: TURN won nomination) correctly does NOT trigger it — the approved ICE
detect-and-repair follow-up pair (report §7, 2026-08-08) closes that gap.

**2026-08-07 hardening (field-verified same day):** the fwd control plane carries **NO rate
limiter** — the per-peer token bucket (20/5) was REMOVED from both `forwarder/signaling.rs` and
`embedded_forwarder.rs` after the field proved it silently ate the last-in-burst large control
frame (a viewer's fwd-room join fires the client's discovery cascade at the forwarder, ~45
frames in 1 s, and the SDP offer/answer always arrives last). DoS bound = cheap parse failure +
the KeyRequest 5 s cooldown + explicit-FwdError admission caps — never re-add a silent drop.
Engine `handle_peer_gone` now mirrors the client presence tolerance: presence loss only tears
legs/streams with NO connected media (`owner_gone` mark + sweep reaps once legs dry; admitted
owner ops clear it). The VPS signaling loop re-sends its room join every 30 s ping tick
(idempotent at the relay; also replays anything the relay buffered during a membership loss).
Every inbound 0x06 logs size + outcome (sizes/types only); the idle per-minute aggregate line is
throttled (it used to rotate field evidence out of journald). Relay `/server-stats` gained
non-identifying delivery counters: `send_dropped`/`send_backpressure` (uWS send status, was
silently ignored) + `fwd_delivered`/`fwd_buffered` (directs to the configured forwarder id).

## Media forwarder control plane (`fwd_*`) — step 3 phase 1, 2026-08-06

Screen shares can be served through a **blind packet forwarder** instead of a per-viewer PC. The
forwarder is NOT a Hollow node: no CRDT, no MLS, no storage, no group keys. It terminates only the
hop-by-hop DTLS-SRTP; payloads stay SFrame-encrypted under the ORIGINATOR's key end to end.
Phase 1 = one infra forwarder on the VPS (`hollow-forwarder`); phase 2 = viewer-peer forwarders
running the same module in-app. Detail + the field-bug post-mortem:
`reports/MEDIA_FORWARDING_PLAN.md`, memory `project_media_forwarding_epic`.

**Why a separate namespace:** a forwarder can never satisfy `is_vc_participant` / CRDT / MLS gates,
so its signalling cannot ride the `vc_*` lane. `fwd_*` envelopes are Olm-direct inside a dedicated
`fwd:{forwarder_peer_id}` relay room and are NEVER room-broadcast, never MLS
(`MessageEnvelope::target()` unchanged; the MLS dispatch has explicit ignore arms for all ten).

**Envelope variants** (`node/types.rs`, all fields `#[serde(default)]`, `origin: Box<StreamOrigin>`):
client→forwarder `fwd_stream_register {origin, allowed_viewers}`, `fwd_stream_auth {origin, add,
remove}`, `fwd_stream_unregister {origin}`, `fwd_ingest_offer {origin, sdp}`, `fwd_attach {origin}`,
`fwd_detach {origin}`, `fwd_egress_answer {origin, sdp}`; forwarder→client `fwd_ingest_answer`,
`fwd_egress_offer`, `fwd_error {origin, code, detail}` with codes
`full|over_budget|not_authorized|unknown_stream|shutting_down`. Tag `fwd_ice` is RESERVED and
unimplemented — both legs exchange COMPLETE SDPs (the forwarder has a fixed public host candidate).

**Client plumbing:** `node/forwarder_client.rs` — `build_fwd_signal_envelope()` whitelists the
client-sendable types (the forwarder-sendable ones are test-only `cfg(test)` arms so the harness can
impersonate the role); `handle_forwarder_send_signal()` encrypts and sends through the
**DETERMINISTIC `fwd:{id}` room**, never `ws_room_for_peer` (that lookup silently dropped the first
signal of every share because the room join hadn't landed — same class as the DM one-way-loss rule).
No session yet ⇒ queue in `pending_messages` + a signed KeyRequest through the same explicit room.
Commands: `NodeCommand::{ForwarderSendSignal, JoinForwarderRoom, LeaveForwarderRoom}` — the join
arms deliberately do NOT reuse `NodeCommand::JoinRoom`, which mutates `active_room` and fires
`RoomCleared` (that would wipe the open DM pane). Inbound: `NetworkEvent::ForwarderSignal
{from_peer, signal_type, payload}` for the three client-bound types (SDP size-capped in Rust; the
"only from the discovered forwarder, only for a watched+assigned origin" trust decision is Dart's).
FFI: `forwarder_send_signal` / `join_forwarder_room` / `leave_forwarder_room`.

**VC-lane additions:** `vc_screen_watch` gained `route` (`""` old client / `"direct"` / `"relay"` /
`"direct_failed"`) — the viewer's self-reported route class, ADVISORY, and a non-empty value is also
the step-3-capable-client marker (old viewers must never receive an assignment). New broadcast-class
peer variant `vc_screen_assign {sid, cid, origin, forwarder, target}` (sharer→viewer; `forwarder`
empty = revert-to-direct) with the FULL new-variant touch list: `target()`, build arm, Olm arm, MLS
arm, VC rate-limiter list, `is_vc_participant` gate, and the `inbound_origin_ok` spoof guard in its
offer-direction form (`handle_envelope_voice_channel_screen_assign`).

**Relay discovery:** `get_media_forwarder` text command (relay-uws `ws_handler.cpp`, mirrors
`get_turn_credentials`) replies `{peer_id, online}` from the `--forwarder-peer-id` startup config +
a `peer_sockets` lookup; guests refused; NEVER an HTTP variant. Client fires
`WsCommand::GetMediaForwarder` on every `WsEvent::Connected` (static id ⇒ no refresh timer) →
`NetworkEvent::MediaForwarderInfo` → Dart `forwarderInfoProvider`.
