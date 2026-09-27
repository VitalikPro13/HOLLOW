# Design A inventory: calls, voice channels, data channels, screen share, forwarder

Read-only evidence, 2026-09-27, HEAD `a71e72fa`. None of the files cited below differ from HEAD in
the working tree (`git status`: only `api/crdt.rs`, `node/sync_handler.rs` and docs are modified).
Rust paths are relative to `rust/hollow_core/src/`, Dart and relay paths to the repo root. Attacker
P-01 = a malicious relay: stamps any `from`, replays, re-routes, drops, delays, reorders.

---

## Cross-cutting transport facts (apply to every section)

- **`from` is relay-stamped and the room is discarded.** Opcodes: `node/ws_client.rs:523-535`
  (0x05 room, 0x06 direct → `WsEvent::Message`/`DirectMessage { room, from, data }`), `:537-551`
  (0x08 topic, sender parsed from the frame). The dispatcher passes `&from` but NOT `room`:
  `node/swarm.rs:4576` `WsEvent::Message { room, from, data } | WsEvent::DirectMessage { room, from, data } =>`
  → `:4933` `&local_peer_str, &from, is_invisible,` (the only `room` use is the recovery-pool
  gate `:4627`). No plaintext arm below can tell which room or opcode a frame arrived on.
- **Only rate gate before the arms** is a token bucket keyed on the relay-stamped `from`:
  `node/swarm.rs:4593-4595` `peer_rate_tokens.entry(from.clone())`, burst 100 / refill 20 per s
  (`:1171-1172`). The relay can rotate `from` freely.
- **Outbound opcodes.** `SendToRoom` → 0x03 (`node/ws_client.rs:1045-1048`), `SendDirect` → 0x04
  (`:1058-1062`). An HONEST relay parks a 0x04 whose target is not in the room and replays it on
  room join: `relay-uws/src/ws_handler.cpp:1750-1767` `buffer_offline_msg(target_str, room_str, ...)`,
  TTL `relay-uws/src/state.h:39` `OFFLINE_BUFFER_TTL_SECS = 86400;  // 24 hours`. So every
  "SendDirect" signal below can arrive up to 24 h late even with an honest relay.
- **Olm is now device-bound (X-1 / HOL-SEC-003 CLOSED).** A PreKey's Curve25519 key must be signed
  by the sending device, checked before any session is built or torn down:
  `node/swarm.rs:6896-6901` `if !crypto_handler::verify_olm_identity(peer_str, their_identity, identity_sig.as_deref(), identity_pk.as_deref(),)`;
  `node/crypto_handler.rs:640-649` (signature over `"hollow-olm-identity:{sender_device}:{identity_key}"`,
  `:620-622`, plus `!key_exchange_device_unauthorized(sender_device)`); pk re-derives the peer id
  (`node/crypto_handler.rs:1884-1889` `if derived_pid != sender_peer_str { return false; }`). Same
  check at the standalone forwarder: `forwarder/signaling.rs:404`. Test:
  `authz_olm_prekey_relay_cannot_open_a_session_as_another_device` (`node/test_harness.rs:3267`).
  Consequence: every Olm-carried signal below is bound to the sending DEVICE key.
- **Olm replay = relay-triggerable session teardown (availability, not forgery).** A replayed Normal
  message fails decrypt and the session is dropped: `node/swarm.rs:7093` `Decrypt FAILED for {peer_str}`
  → `:7102-7105` `olm.remove_session(&peer_str); ... decrypt_fail_cooldown.insert(...)` (5 s cooldown).
  A replayed genuine PreKey passes `verify_olm_identity` (the proof is a standing fact, no ts or
  recipient: `node/crypto_handler.rs:616-619`), then the live session is removed BEFORE the rebuild
  is tried: `node/swarm.rs:6919-6920` `olm.remove_session(&peer_str); match olm.create_inbound_session(...)`;
  the `Err(e2)` arm (`:6960-6985`) does not restore it. UNTRACED at vodozemac level (expected: the
  consumed OTK / message key makes both paths fail). Re-routing an Olm frame to another device has
  the same effect at that device.
- **Relay presence already equals forged leave/disconnect.** A relay `peer_left` removes the peer
  from every voice channel of that room and emits `VoiceChannelLeft` + `PeerDisconnected`:
  `node/swarm.rs:3764` `WsEvent::PeerLeft { room, peer_id } =>`, `:3838-3863`
  (`participants.remove(&peer_id);`), `:3870-3874` `NetworkEvent::PeerDisconnected`. Same from a
  `members` snapshot: `:3943-3963`.
- **No DTLS fingerprint check anywhere in the app.** `grep -i fingerprint` over `lib/` and
  `rust/hollow_core/src/` finds only Olm/identity fingerprints and a liveness counter
  (`lib/src/core/services/screen_share_service.dart:1123-1248`). DTLS authenticity therefore rests
  entirely on the signalling transport that carried the SDP.

---

### RtcOffer

- Wire: `node/types.rs:2334-2338` `RtcOffer { sdp: String, conn_id: String }`. No signature, ts, nonce.
- Send: Dart `lib/src/core/services/webrtc_service.dart:413-423` (`createOffer` → `webrtcSendSignal(... signalType: _sigOffer(lane), payload: ..., connId: connId)`)
  → `node/swarm.rs:2586-2591` → `node/voice_handler.rs:94-101`
  (`if signal_type == "offer" && !data_channel_peer_allowed(...) { ... return; }`,
  `"offer" => HavenMessage::RtcOffer { sdp: payload, conn_id }`) → `:145-146`
  `send_message_to_peer(ws_cmd_tx, ws_room_peers, &target, msg)`, which is a PLAINTEXT
  `SendDirect` into the first room that lists the target: `node/crypto_handler.rs:2993-2999`.
- Receive: `node/swarm.rs:13097-13118`: size cap `:13098`, then
  `:13104-13109` `if !voice_handler::data_channel_peer_allowed(server_states, master_peer_str, peer_str, db_path, db_passphrase,)`,
  then `NetworkEvent::WebRtcSignal { peer_id: peer_str, signal_type: "offer", ... }`. Dart
  `lib/src/core/providers/event_provider.dart:1361-1364` → `webrtc_provider.dart:95-107` →
  `webrtc_service.dart:752-904` `_handleOffer`.
- Effect: new `RTCPeerConnection` keyed `conns[peerId]` with THEIR conn id (`:844-852`
  `connId: connId, // Use THEIR connId`), `setRemoteDescription(offer)` (`:888`), answer sent back
  (`:893-898`). Glare with an existing conn of a different conn id: the polite side DROPS its live
  connection and takes the new offer (`:804-814` `if (politeSelf) { ... await disconnectPeer(peerId); }`);
  same conn id = renegotiation of the LIVE PC (`:770-801`).
- Authz: relay `from` + `data_channel_peer_allowed` = own identity, or (not blocked AND (shared
  non-deleted server with both as members OR accepted friend)): `node/voice_handler.rs:55-77`.
  Nothing binds the SDP to the sender. For P-01 the gate is satisfied by stamping `from` = any
  friend or co-member device.
- Timing: live, but parked ≤24 h by an honest relay when the target left the room.
- Replay / re-route: an old offer replayed makes a polite receiver tear down its live data channel
  (glare path above) and answer a dead conn; replay with the LIVE conn id (visible in plaintext)
  lands on the renegotiation path of the live PC. UNTRACED: what libwebrtc does with a changed
  fingerprint in a re-offer on a live transport.
- Session / twin: no Olm or MLS copy exists; an Olm session with the peer usually exists (friends)
  but is not used.
- Relay sees: full SDP (DTLS fingerprint, ICE ufrag/pwd, m-lines), conn id, who dials whom.
- Side note: the gate opens SQLCipher on the event loop per offer (`node/voice_handler.rs:72`
  `MessageStore::open(db_path, db_passphrase)`), reachable by relay-forged offers under rotating `from`.
- Tests: `authz_room_presence_alone_opens_no_channel_to_us` (`node/voice_handler.rs:2060`) covers
  the stranger gate only.

### RtcAnswer (candidate A12, traced)

- Wire: `node/types.rs:2341-2345`. Send: `node/voice_handler.rs:102` `"answer" => HavenMessage::RtcAnswer { sdp: payload, conn_id }`,
  plaintext `SendDirect` as above; Dart sends it from `webrtc_service.dart:893-898` / `:794-799`.
- Receive: `node/swarm.rs:13119-13132`: ONLY the size cap, then `WebRtcSignal { signal_type: "answer" }`.
  No block, friend, membership or pending-offer check in Rust.
- Dart: `webrtc_service.dart:906-934`. Match by peer id, then by conn id REGARDLESS of sender:
  `:914-918` `var conn = _connsFor(lane)[peerId]; if (conn == null || conn.connId != connId) { final byConn = _findConnByConnId(connId, lane); if (byConn != null) conn = byConn; }`
  then `:932-933` `await conn.pc.setRemoteDescription(RTCSessionDescription(..., 'answer'));`.
  The conn id is in the plaintext offer (and generated with `Random()`, `:1423-1428`, moot here).
- Authz: NOTHING beyond knowing the conn id; the relay-stamped `from` is not even compared.
- A12 trace (relay = Mallory, Alice dials Bob):
  1. Alice's `RtcOffer` (plaintext) gives Mallory `conn_id`, Alice's fingerprint and ICE creds.
  2. Mallory drops Bob's answer (or Bob never got the offer) and injects `rtc_answer{conn_id}` with
     ITS certificate fingerprint and ICE creds, any `from`; candidates via forged `rtc_ice` (next
     section) or inline.
  3. Alice applies it (`:932`). ICE checks run against Mallory's addresses with creds Mallory chose;
     DTLS completes because Alice checks the peer cert only against the fingerprint Mallory supplied
     (standard WebRTC; no app-level pin exists, see cross-cutting). SCTP opens `hollow-data`.
  4. The channel is attributed to Bob: the callbacks close over the map key
     (`webrtc_service.dart:1007-1010` `dc.onMessage = (msg) { _onDataChannelMessage(peerId, ...` ),
     and open reports Bob to Rust (`:1043` `network_api.webrtcPeerConnected(peerId: peerId);`) →
     `node/voice_handler.rs:18-24` `webrtc_peers.insert(peer_id.clone());`.
  5. Reverse leg: Mallory forges `rtc_offer` "from Alice" to Bob; Bob's only gate is
     `data_channel_peer_allowed(Alice)` (friend or co-member → passes), so Mallory can sit in both
     directions and proxy.
- What Mallory gets on that channel (`webrtc_service.dart:1160-1323`):
  - **Screen-share audio in PLAINTEXT.** `0x03` frames are raw Opus
    (`:1196-1200` `// Screen audio packet: [0x03][seq:4][opus_data...]`), sent by DM calls
    (`lib/src/core/providers/call_provider.dart:1425-1427` `webrtc.sendScreenAudio(peerId, packet);`)
    and voice channels (`voice_channel_provider.dart:1654`, `:1925`). No app-layer encryption on
    that path (grep for encrypt/cipher/aes/sframe in `screen_audio_capturer.dart`,
    `screen_audio_receiver.dart`, `mobile_screen_audio_capturer.dart`, `api/screen_audio.rs`: none).
    The whitepaper claims DTLS suffices (`WHITEPAPER.md:542` "Screen share audio over data channels
    is encrypted at the transport layer (DTLS) but does not use SFrame."); the threat model left it
    open (`reports/planned/security/audit/threat_model.md:169` "F-43 ... (verify B: encrypted?)").
    Against P-01 the DTLS claim does not hold: the DM call itself is Olm+SFrame, its share audio is not.
  - **Audio injection.** The receive callbacks ignore the sender:
    `call_provider.dart:420-430` `webrtc.onScreenAudioReceived = (fromPeer, data) async { ... _screenAudioRenderer?.pushPacket(data);`
    (`fromPeer` unused), `voice_channel_provider.dart:835-846` likewise; one renderer, no per-peer
    key (`lib/src/core/services/screen_audio_receiver.dart:15`, `:39`). Any peer with an open
    general channel (a friend or co-member, not only the relay) can play audio into our share-audio
    output during a call. New observation, not in candidate_findings.
  - File and shard bytes: routed to "Bob" because `webrtc_peers` holds him
    (`node/file_handler.rs:2698` `if webrtc_peers.contains(peer_str) {`); content is AES-GCM under
    the key from the E2EE FileHeader (`node/file_handler.rs:2448-2456`), so ciphertext only;
    availability loss (Bob never receives).
  - Gossip CRDT ops (`0x04`): fed to the signed-op ingest (`node/swarm.rs:2913-2924`); forgery
    blocked by op signatures (design E), drop/delay possible.
- Timing / replay: a replayed stale answer is ignored on conn-id mismatch (`:927-930`); with the
  live conn id it hits a stable PC and throws (caught, `:494-496`).
- Session / twin: none. Relay sees the full answer SDP.
- Verdict A12: CONFIRMED-BY-READING end to end on the app side; the DTLS step is standard libwebrtc
  behaviour, not exercised in a test. Impact is bounded by app-layer crypto EXCEPT screen-share
  audio, which is plaintext to Mallory, and the Rust belief that a direct channel with Bob exists.
- Tests: none for a forged answer.

### RtcIceCandidate

- Wire `node/types.rs:2348-2354`; send `node/voice_handler.rs:103-116` (plaintext `SendDirect`);
  receive `node/swarm.rs:13133-13146` (no check at all). Dart `webrtc_service.dart:946-980`: same
  conn-id fallback (`:966-970`), else QUEUED by conn id (`:971-976`
  `_pendingIceCandidates.putIfAbsent(connId, () => []).add(candidate);`) and flushed into whatever
  PC later takes that conn id (`:984-993`).
- Authz: NOTHING beyond the conn id. The relay can steer any PC's connectivity to addresses it
  chooses (needed for A12 step 3). Queue is unbounded per conn id (UNTRACED memory bound).
- Relay sees: every candidate (IPs), by design.

### RtcShareOffer

- Wire `node/types.rs:2366-2371`; send `node/voice_handler.rs:120` (NOT behind
  `data_channel_peer_allowed`, which only guards `"offer"`, `:94-99`); plaintext `SendDirect`.
- Receive `node/swarm.rs:13149-13168`: size cap, block guard only:
  `:13156-13160` `if !super::resolver::same_identity(peer_str, master_peer_str) && super::blocklist::is_blocked(peer_str) { return; }`.
  By design reachable by strangers holding a share link (`node/voice_handler.rs:50-54` "Share links
  keep their own lane and are not gated here").
- Effect: second PC on the Share lane (`webrtc_service.dart:752-904` with `_Lane.share`), answered
  from the STUN-only config (`:841-842`); the lane accepts only share-chunk frames
  (`:1104-1109`, `:1190-1193`).
- Authz: relay `from` + blocklist. Same A12 MITM shape: chunks are hash-checked and link-key
  encrypted (`node/share_handler.rs:1962-1971`), so ciphertext only, but the §7A promise "Share
  bytes never ride the relay" (`WHITEPAPER.md:629`) is not enforceable against P-01, which can
  terminate the "direct" leg itself.

### RtcShareAnswer / RtcShareIceCandidate

- Wire `node/types.rs:2373-2387`; send `node/voice_handler.rs:121-134`; receive
  `node/swarm.rs:13169-13195`: size cap on the answer only, no other check. Dart: identical
  conn-id-fallback code as RtcAnswer / RtcIceCandidate (`webrtc_service.dart:487-492` → `_handleAnswer`/`_handleIce`
  with `_Lane.share`), plus relay-candidate stripping (`:933`, `:953-957`).
- Authz: NOTHING beyond the conn id. Relay sees SDP and candidates.

---

### Call* in the clear (all 17 HavenMessage variants)

CallInvite, CallAccept, CallReject, CallEnd, CallBusy, CallMediaRestart, CallSdpOffer,
CallSdpAnswer, CallIceCandidate, CallVideoState, CallAudioState, CallScreenState, CallScreenOffer,
CallScreenAnswer, CallScreenIce, CallScreenWatch, CallRecordingState.

- Plaintext arm REJECTS: `node/swarm.rs:13245-13263`
  `hollow_log!("[HOLLOW-SECURITY] REJECTED plaintext call signal from {peer_str}");`. MLS copy
  rejected: `:10806-10808`. `fetch.rs`: no arm for any of them (grep: none).
- The ONLY accepted path is `MessageEnvelope::CallSignal { signal: Box<HavenMessage> }`
  (`node/types.rs:3295-3297`) inside Olm: `node/swarm.rs:8552-8556`
  `Ok(MessageEnvelope::CallSignal { signal }) => { voice_handler::handle_call_signal_message(peer_str, master_peer_str, *signal, event_tx, db_path, db_passphrase,).await; }`
  (`master_peer_str` = OUR master). Whitelist again at `node/voice_handler.rs:603-610` (`REJECTED non-call message ... smuggled inside a call signal envelope`).
- Common send path: Dart `call_provider.dart:2301-2307` `network_api.callSendSignal(...)` →
  `node/swarm.rs:2636-2645` → `node/voice_handler.rs:185-262`: one target device
  (`:207` `pick_online_device`), NO plaintext fallback (`:224-234` `if !olm.has_session(&target) { ... DROPPED, requesting key bundle ... return; }`),
  Olm `SendDirect` into `dm_room_code(local_master, resolve(target))` (`:245-250`), else first
  shared room (`:251-261`).
- Common Dart gate: `event_provider.dart:1373-1381` collapses the device to its master, then
  `call_provider.dart:1645-1650` `if (signalType != 'invite' && !_fromCallPeer(peerId)) { ... return; }`
  with `_fromCallPeer` = identity equality with the live call's peer (`:2414-2419`). Call ids are
  `Random.secure()` (`:2421-2426`). M1 FIXED.
- Common properties for every Call* below:
  - Sender binding: Olm session keyed by the sender DEVICE (device-signed key exchange, see
    cross-cutting). No inner signature, no timestamp, no nonce on any Call* (`node/types.rs:2393-2513`).
  - Replay by P-01: blocked by the Olm ratchet (decrypt fails) but costs a session teardown.
    Re-route to another device: decrypt fails there, same teardown.
  - Delay by P-01 (hold, then deliver once): nothing rejects an aged signal. An honest relay also
    parks the 0x04 ≤24 h (cross-cutting).
  - Relay sees: an Olm frame of a given size in `dm_room_code(A, B)` (who calls whom, when, SDP-sized
    bursts), never content.

### CallInvite

- Wire `node/types.rs:2392-2393` `CallInvite { call_id, video, sframe_key }` (`video`, `sframe_key`
  `#[serde(default)]`). Built `node/voice_handler.rs:313-323`; Dart `call_provider.dart:922-961`
  (`_generateSframeKey()` `Random.secure()`, `:2429-2434`; payload `{'call_id','video','sframe_key'}`).
- Receive `node/voice_handler.rs:455-470`: `if !call_invite_allowed(master_peer_str, peer_str, db_path, db_passphrase) { ... return; }`
  = own identity, or not blocked AND friend status `accepted` for `resolve(peer)` (`:420-433`). M2 FIXED.
- Effect (Dart `call_provider.dart:1797-1889`): glare/busy decision (`:1817-1824`), busy reply
  (`:1831-1850`), else `CallState(status: ringing, peerId, callId, sframeKey: sframeKey)`
  (`:1866-1873`), 30 s auto-reject (`:1880-1888`). No `_fromCallPeer` gate (by design), no age check.
- Key authority: the SFrame media key is whatever the Olm-authenticated caller device put in the
  invite; installed later in `_handleSdpOffer` (`:2062-2068`). Legacy bare-id invite = empty key =
  no SFrame (`node/voice_handler.rs:320-322`, `call_provider.dart:2063` `if (keyHex.isNotEmpty)`);
  only a friend's modified client can send that, not the relay.
- Timing: a held or honest-relay-parked invite rings late; the caller's timeout `end`
  (`call_provider.dart:964-970`) is parked behind it in order with an honest relay, droppable by P-01
  (phantom ring; an accept goes nowhere because the caller's state is idle, `_fromCallPeer` false).
- Tests: `authz_only_a_friend_or_our_own_device_rings_us` (`node/voice_handler.rs:2122`),
  `call_invite_never_exposes_sframe_key_to_the_relay` (`node/test_harness.rs:3140`),
  `plaintext_call_signal_is_rejected` (`:3221`), `call_signal_routes_to_friend_device_and_drops_unknown` (`:2995`).

### CallAccept

- Wire `node/types.rs:2396-2397`; callee sends `{'call_id', 'sframe_key': state.sframeKey}`
  (`call_provider.dart:1000-1004`); Rust passes through (`node/voice_handler.rs:471-477`).
- Effect `call_provider.dart:1891-1934`: only if `status == ringing && direction == outgoing && callId`
  matches (`:1900-1904`); then DIALS the sender device (`:1917-1921` `_service.createOffer(peerId, callId, withVideo: false,)`)
  and installs the CALLER's own key (`:1923-1926`); the accept's `sframe_key` is never read.
- Authz: Olm device + `_fromCallPeer` (a sibling device of the callee may accept) + call id.

### CallReject / CallEnd / CallBusy

- Wire `node/types.rs:2400-2409` (bare `call_id`). Rust emits unconditionally (`node/voice_handler.rs:478-489`).
- Effect: `_handleReject` `call_provider.dart:1936-1941`, `_handleEnd` `:1943-1953` (closes both
  screen-share PCs, `_service.endCall()`), `_handleBusy` `:1955-1964`; each `if (state.callId != callId) return;`.
- Authz: Olm device + `_fromCallPeer` + call id. Relay can only DROP (a dropped `end` leaves the
  other side on the hold-open ladder; `handleRelayReconnected` re-sends a held hangup, `:1721-1728`).

### CallMediaRestart

- Wire `node/types.rs:2411-2420`; Rust `node/voice_handler.rs:490-493`; Dart `call_provider.dart:742-754`:
  call id match, then `_pendingMediaRestart = _service.endCall();` (the next offer is treated as initial).
- Authz: Olm device + `_fromCallPeer` + call id. Not forgeable by P-01.

### CallSdpOffer / CallSdpAnswer (DTLS question)

- Wire `node/types.rs:2422-2428`; Rust size cap then emit (`node/voice_handler.rs:494-516`,
  `MAX_SDP_SIZE` 64 KiB `node/types.rs:20`).
- Effect: offer `call_provider.dart:1994-2074` (renegotiation if a PC exists `:2012-2049`, else
  `_service.handleOffer(...)` and `setSframeKey(peerId, ...)` `:2055-2068`, answer sent `:2070-2071`);
  answer `:2076-2088` `await _service.handleAnswer(sdp);`.
- Authz: Olm device + `_fromCallPeer` + call id.
- DTLS: the fingerprint rides inside Olm, so it is authenticated to the sending DEVICE key. P-01
  cannot substitute it. Media is additionally SFrame under the Olm-carried key. A12 does NOT apply
  to the DM call media path; it applies to that call's screen-share AUDIO (data channel, above).

### CallIceCandidate

- Wire `node/types.rs:2430-2437`; Rust `node/voice_handler.rs:517-525`; Dart `call_provider.dart:2110-2122`
  (call id match → `_service.handleIceCandidate`). Olm-bound; relay sees nothing.

### CallVideoState / CallAudioState / CallScreenState / CallRecordingState

- Wire `node/types.rs:2439-2463`, `:2504-2513`; Rust emit `node/voice_handler.rs:526-551`, `:593-602`.
- Effect: `remoteVideoEnabled` (`call_provider.dart:2124-2156`), `remoteMuted/Deafened`
  (`:2158-2166`, `if (json['call_id'] != state.callId) return;`), remote screen badge / tear-down of
  the incoming share PC on `enabled:false` (`:2168-2205`), REC indicator
  (`:1685-1688` → `lib/src/core/providers/recording_provider.dart:146-160`; call id NOT checked, peer is).
- Authz: Olm device + `_fromCallPeer` (+ call id except recording). Not forgeable by P-01.

### CallScreenOffer / CallScreenAnswer / CallScreenIce / CallScreenWatch

- Wire `node/types.rs:2465-2502`; Rust `node/voice_handler.rs:552-592` (SDP cap on offer/answer).
- Effect: offer only when we asked (`call_provider.dart:2215-2218` `if (!state.watchingRemoteShare) { ... return; }`),
  new `ScreenShareService`, SFrame `'screen:$peerId'` (`:2258-2261`, `:2436-2464`); answer only
  with an outgoing share (`:2272`); ICE routed by `role` (`:2289-2296`); watch starts/stops our
  outgoing share to that peer (`:1530-1570`, call id checked `:1534`).
- DTLS: fingerprint inside Olm (device-bound); video SFrame'd. Share AUDIO is not on this PC: it
  rides the general data channel (A12).

---

### VoiceChannelJoin (plaintext HavenMessage + MLS twin)

- Wire: plaintext `node/types.rs:2597-2602` `vc_join { server_id, channel_id }`; MLS
  `node/types.rs:3301-3306` `vc_join { sid, cid }`.
- Send: `node/voice_handler.rs:616-686` → `broadcast_vc_presence` `:712-730`: MLS server-group
  broadcast when held (`:723-726`, `send_mls_broadcast` = 0x03 `SendToRoom` into room `server_id`,
  `node/crypto_handler.rs:2685-2711`) PLUS an unconditional plaintext fan-out to every member
  (`:727-729` → `:690-702` → `send_raw_to_identity`, plaintext `SendDirect` per online device,
  `node/crypto_handler.rs:3623-3647`). Other plaintext sends: re-announce on `PeerJoined`
  (`node/swarm.rs:3400-3431`, gated `:3414-3416` on `is_member(&peer_id)` and
  `can_see_channel(&peer_id, vc_cid)`); conference reply (`node/voice_handler.rs:1549-1560`).
- Receive plaintext `node/swarm.rs:13342-13375`: self-echo `:13344`; conference: `from` must be a
  leaf of the named conf group (`:13349-13352` `m.group_members(&server_id).iter().any(|c| c == peer_str)`);
  server: `voice_join_refusal(server_states.get(&server_id), peer_str, &channel_id)` (`:13356`) =
  member (master-resolved), voice type, `can_see_channel` (`node/voice_handler.rs:1577-1593`). S-04 FIXED.
- Receive MLS `node/swarm.rs:10612-10665`: `vc_rate_check` keyed `peer_str` (`:10630`), leaf must
  equal `from` (`:10656` `if sender_peer_id != peer_str =>` drop; X-3 FIXED), envelope must name the
  decrypting group's server (`:10304-10309` → `node/crypto_handler.rs:2731` `sid == server_id`; S-05
  FIXED), then `node/voice_handler.rs:1513-1572` (conf: only `cid == "main"`, `:1533-1535`;
  server: `voice_join_refusal`, `:1536`). Olm copy ignored (`node/swarm.rs:8569`).
- Effect: `voice_channel_participants[sid:cid].insert(from)` (`:13363-13364` / `voice_handler.rs:1561-1562`);
  this set gates every later VC signal (`is_vc_participant`, `:1501-1509`). `VoiceChannelJoined`
  → Dart roster (`voice_channel_provider.dart:561-571`) and, if we sit in that channel, we DIAL the
  device (`event_provider.dart:1402-1408` → `voice_channel_provider.dart:1002-1051`
  `_service!.onPeerJoinedMyChannel(peerId)`), sending it our Olm-wrapped SDP/ICE and our
  screen/camera/mute state.
- Authz (plaintext): relay `from` + membership/visibility of that `from`. NOTHING binds the frame to
  the device beyond `from`: P-01 can seat any member device that can see the channel.
- Timing: live; plaintext copy parkable ≤24 h by an honest relay (0x04); MLS copy is a live 0x03.
- Replay: plaintext NONE (P-01 re-seats a device that left: phantom tile, a dial, our ICE to that
  device via Olm). MLS: `Decrypted::Replay` drop (`node/swarm.rs:10273`).
- Session / twin: MLS twin exists whenever the server group is held; the plaintext twin is
  unconditional, so P-01 drops the MLS copy and forges the plaintext one.
- Relay sees (plaintext): `server_id`, `channel_id` (incl. restricted channels), the joining device,
  and, via the fan-out targets, which member devices are online. Note: presence of a RESTRICTED
  voice channel also reaches members who cannot see it, both twins (`fan_plaintext_to_members`
  iterates `state.members`, `:698`; MLS copy on the server-wide group by design, `node/types.rs:3832-3846`);
  the receiver refuses to seat but reads the frame.
- Tests: `voice_channel_join_leave_and_signal_routing` (`node/test_harness.rs:5389`),
  `authz_voice_frames_over_mls_come_from_their_leaf` (`:24669`),
  `authz_voice_seat_only_for_a_member_who_can_see_the_channel` (`crdt/server_state.rs:3017`),
  source guard `channel_ingest_gates_stay_wired` (`node/crypto_handler.rs:6094`, asserts
  `voice_join_refusal(` in both arms `:6123-6128`). No test for a relay-forged plaintext join.

### VoiceChannelLeave (plaintext + MLS twin)

- Wire `node/types.rs:2604-2609` / `:3308-3313`. Send `node/voice_handler.rs:976-1025` (same
  MLS + unconditional plaintext shape via `broadcast_vc_presence`).
- Receive plaintext `node/swarm.rs:13377-13398`: self-echo only, then `participants.remove(peer_str)`
  and `VoiceChannelLeft`. MLS `node/voice_handler.rs:1597-1628` after rate + leaf checks.
- Effect: Dart `event_provider.dart:1411-1439` → `voice_channel_provider.dart:1057-1074`
  `await _service!.onPeerLeftMyChannel(peerId);` tears down the live (possibly direct P2P) leg,
  its screen share and camera.
- Authz: relay `from` only (it removes only itself for honest peers). P-01 can drop any
  participant's leg. Marginal power over P-01's own presence events: none (a relay `peer_left`
  already does this, `node/swarm.rs:3838-3863`). Replay: none (plaintext). Relay sees sid/cid/device.
- Candidate A11: still PLAUSIBLE, but for leave it adds nothing beyond relay presence control.

### VoiceChannelAudioState / VoiceChannelScreenState / VoiceChannelCameraState / VoiceChannelRecordingState (plaintext + MLS twin)

- Wire plaintext `node/types.rs:2611-2650`; MLS `node/types.rs:3335-3346`, `:3407-3418`, `:3564-3585`.
- Send: `node/voice_handler.rs:1115-1124` (`is_broadcast`) → `:1306-1330` MLS server-group broadcast
  when held + `// UNCONDITIONAL plaintext twin` (`:1323-1329`, built `:1335-1363`).
- Receive plaintext `node/swarm.rs:13400-13462`: `voice_channel_participants.get(&vc_key).map(|p| p.contains(peer_str))`
  (e.g. `:13402`), then `VoiceChannelSignal { peer_id: peer_str, ... }`. MLS: rate + leaf == from,
  then `node/voice_handler.rs:1844-1889`, `:2004-2045` (`is_vc_participant`). Olm copies ignored
  (`node/swarm.rs:8571-8574`).
- Effect (Dart `voice_channel_provider.dart:1077-1141`): mute/deafen badge (`:1399-1409`); REC
  indicator (`:1088-1095` → `recording_provider.dart:146-160`); camera tile flag (`:1498-1512`);
  screen state: badge + sound, and `enabled:false` TEARS DOWN a share we are watching
  (`:2201-2208` `sharing.remove(peerId); ... _cleanupPeerScreenShare(peerId);`).
- Authz: relay `from` + that `from` being a seated participant. P-01 can forge any of these for any
  participant: fake deafen, hide the REC indicator after it showed (a pure drop cannot un-show it;
  the Dart side is last-writer-wins, `node/voice_handler.rs:1300-1304`), kill a watched share.
- Replay: plaintext none; MLS replay-dropped. Relay sees mute/deafen, share on/off + quality label,
  camera on/off, recording on/off per device, per channel.
- Tests: `vc_state_signal_reaches_a_deaf_member` (`node/test_harness.rs:20452`, delivery only).

### PeerDisconnecting (candidate A13)

- Wire `node/types.rs:1611-1613` `#[serde(rename = "disconnecting")] PeerDisconnecting,`.
- Send: NONE. Repo-wide grep finds only the enum and the receive arm (`node/swarm.rs:10095`); no
  Rust or Dart code builds it. Receive-only dead arm.
- Receive `node/swarm.rs:10095-10101`: no check, emits `NetworkEvent::PeerDisconnected { peer_id: peer_str }`.
- Effect (`event_provider.dart:340-347`): peer removed from presence, general data channel torn
  down (`webRtcProvider.disconnectPeer`), `callProvider.handlePeerDisconnected` (ends a call that
  is not yet connected when `state.peerId == peerId`, raw id compare, `call_provider.dart:1702-1715`;
  the call peer is usually the MASTER after `identityOf`, `event_provider.dart:1378`, so a device id
  rarely matches: UNTRACED which case holds per platform), `voiceChannelProvider.onPeerDisconnected`
  (removes the device from every roster and closes its VC PC, `voice_channel_provider.dart:1355-1374`),
  REC indicator cleared (`recording_provider.dart:160`).
- Authz: relay `from` only. A peer can only disconnect itself; P-01 gains nothing over sending
  `peer_left` (`node/swarm.rs:3870-3874`). Relay sees the bare type. A13: CONFIRMED forgeable, no
  marginal capability; the arm could simply be deleted.

---

### MessageEnvelope VC targeted signals (transport and binding only)

VoiceChannelSdpOffer, VoiceChannelSdpAnswer, VoiceChannelIce, VoiceChannelRenegOffer,
VoiceChannelRenegAnswer, VoiceChannelLegRestart, VoiceChannelScreenOffer, VoiceChannelScreenAnswer,
VoiceChannelScreenIce, VoiceChannelScreenWatch, VoiceChannelScreenAssign, VoiceChannelScreenFeedState
(`node/types.rs:3315-3562`). No plaintext HavenMessage form exists.

- Send: Olm only. `node/voice_handler.rs:1125-1131` `// Targeted SDP/ICE: Olm encrypted + SendDirect.`
  `send_encrypted_message_in_room(olm, crypto_store, &peer_id, &server_id, &env_json, ...)`; without a
  session `olm.encrypt` errs and only `MessageSendFailed` results (`node/crypto_handler.rs:2892-2899`;
  UNTRACED whether Dart re-keys and retries). `target` is always `None` (`:1147-1245`).
- Receive: Olm arms `node/swarm.rs:8582-8705`, sender = the Olm-authenticated device, gate =
  `from` seated in `sid:cid` (e.g. `:8584`), SDP ≤ 64 KiB; screen signals share `voice_handler`
  functions with the origin guard (`node/voice_handler.rs:1277-1289`, `:1701`, `:1824`); assign
  requires origin == sender (`:1951`), feed_state origin == us (`:1989`) (M3 FIXED). MLS arms (legacy
  senders) `node/swarm.rs:10674-10766` after rate + leaf == from + group-fit. No `vc_rate_check` on
  the Olm arms (only `:10630`, MLS).
- DTLS: VC SDPs (initial, reneg, screen) carry their fingerprint inside Olm, bound to the sending
  device; P-01 cannot substitute it. Voice/camera/screen media are SFrame under the MLS export
  (`node/voice_handler.rs:814` `mls_mgr.export_secret(group_key, "sframe", b"", 32)`), so even a
  broken DTLS leg would give ciphertext. Dart applies the answer to the PC keyed by that exact
  device (`lib/src/core/services/voice_channel_service.dart:427-446`).
- Relay sees: Olm frames in room `server_id` from device X to device Y (who dials whom, when).
- Residual: the participant set these arms trust can be filled by relay-forged plaintext
  `vc_join` (above), but that only makes us DIAL a real device over Olm; it cannot inject SDP.

### MessageEnvelope Fwd* (transport and binding only)

FwdStreamRegister, FwdStreamAuth, FwdStreamUnregister, FwdIngestOffer, FwdIngestAnswer, FwdAttach,
FwdDetach, FwdEgressOffer, FwdEgressAnswer, FwdError (`node/types.rs:3598-3709`).

- Send: Olm-direct into room `fwd:{forwarder}`; no session = queue + signed KeyRequest
  (`node/forwarder_client.rs:127-155`, `:162-205`). Client whitelist `:61-121`. `place() == Direct`
  (`node/types.rs:3770-3780`); MLS copies ignored (`node/swarm.rs:10813-10824`).
- Forwarder side (VPS): 0x06 only, Olm-decrypted with the PreKey identity check
  (`forwarder/signaling.rs:258`, `:280-309`, `:404`); `admit_register` origin == sender
  (`forwarder/dispatch.rs:42-44`), owner-only auth/unregister (`:61-65`), ingest owner or named
  feeder (`:86-89`), attach needs allowlist (`:106-108`). Presence `members`/`peer_left` text frames
  from the relay drive `PeerGone` (`forwarder/signaling.rs:180-205`): P-01 can unregister streams
  (availability).
- Embedded forwarder: register only behind our own advertised expectation
  (`node/embedded_forwarder.rs:163-179`); feed answers only from a forwarder we feed (`:278-284`).
- Client side: Rust passes through with an SDP cap (`node/swarm.rs:8712-8780`); Dart accepts an
  ingest answer only from our branch (`voice_channel_provider.dart:3300-3304`), an egress offer only
  from the assigned forwarder for a watched origin (`:3330-3332`).
- DTLS: forwarder SDPs ride Olm, bound to the forwarder's key; the forwarder is a designed media
  middlebox holding only SFrame ciphertext (`forwarder/dispatch.rs:78-80`).
- J5 unchanged: the VPS forwarder id comes from the relay (`relay-uws/src/ws_handler.cpp:2349-2363`,
  `node/swarm.rs:4547-4550`, `event_provider.dart:329-332`) and is the ONLY forwarder an
  Always-relay viewer accepts (`voice_channel_provider.dart:3217-3225`
  `if (advertised.isEmpty || forwarder != advertised) {`). P-01 can name any device, including a
  member's, defeating the Always-relay "operator infrastructure only" promise; content stays SFrame.
- Relay sees: who talks to which forwarder, frame sizes; the forwarder sees origin, viewer
  allowlists (device ids) and SDPs.

---

## Status of the named candidates

| Row | Now |
|---|---|
| A11 | PLAUSIBLE. Plaintext join and the four state signals are forgeable by P-01 for any seated member device (join also for any member who can see the channel); leave adds nothing beyond `peer_left`. `screen_state{enabled:false}` also tears down a watched share. |
| A12 | CONFIRMED-BY-READING (app side). Forged `rtc_answer` / `rtc_share_answer` accepted by conn id alone, any `from`; no fingerprint check anywhere. Content exposed: screen-share audio (plaintext Opus, DM calls and voice channels); everything else on the channel is app-layer encrypted or signed. |
| A13 | CONFIRMED forgeable, zero marginal capability over relay presence; no send site exists. |
| J5 | Unchanged (see Fwd*). |
| M1, M2, M3 | FIXED as described (`_fromCallPeer`, `Random.secure`, `call_invite_allowed`, origin == sender / == us). |
| X-1, X-3, S-04, S-05 (authz_media.md) | FIXED (Olm identity proof; leaf == from; `mls_envelope_fits_group`; `voice_join_refusal`). |
| New | Any peer with an open general data channel can inject share audio into our renderer during a call (sender ignored). Olm replay or re-route by P-01 drops the live session (availability). |
