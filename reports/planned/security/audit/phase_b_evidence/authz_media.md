# Authz matrix evidence: CALLS, VOICE CHANNELS, SCREEN SHARE, MEDIA FORWARDER, SFRAME KEYS

Read-only enumeration, 2026-09-26. Rust paths are relative to `rust/hollow_core/src/`, Dart paths
to the repo root. Every quote was read at the cited line.

LINE NUMBERS ARE PINNED TO HEAD `b009e9a0`. When reading started only `node/test_harness.rs` was
modified; during the run the parallel session began editing `crypto/olm_manager.rs`,
`forwarder/signaling.rs`, `node/crypto_handler.rs`, `node/fetch.rs`, `node/forwarder_client.rs`,
`node/message_ops.rs`, `node/swarm.rs`, `node/types.rs` and added
`reports/planned/security/audit/findings/HOL-SEC-003.md` (apparently fixing X-1 below). Every
`node/swarm.rs`, `node/types.rs`, `forwarder/signaling.rs`, `crypto/olm_manager.rs` and
`node/fetch.rs` citation was re-verified with `git show HEAD:<path>`; working-tree swarm.rs lines
are now shifted by up to +9. `node/voice_handler.rs`, `forwarder/engine.rs`, `forwarder/dispatch.rs`,
`node/embedded_forwarder.rs`, `crypto/mls_manager.rs`, `node/security_alerts.rs`,
`node/ws_client.rs` and all of `lib/` are unchanged from HEAD. X-1, S-01 and S-11 describe HEAD and
may already be closed in the working tree.

Principal shorthand: `peer_str` = relay-stamped sender DEVICE (`from`), `master_peer_str` in
`handle_incoming_request` = OUR master (`node/swarm.rs:570` `let master_peer_str = local_peer_str.clone();`),
`sender_peer_id` in the MLS arm = MLS leaf credential.

Where `from` comes from: the relay frame, parsed client-side with no check:
`node/ws_client.rs:521-524` (0x05) `if let Some((room, from, payload)) = parse_binary_relay_frame(&data[1..])`
and `node/ws_client.rs:535-548` (0x08 topic, sender taken from the frame). Every plaintext
HavenMessage reaches `handle_incoming_request` with `peer_str = &from` (`node/swarm.rs:4920`
`&local_peer_str, &from, is_invisible,`). A hostile relay (P-01) therefore picks `peer_str` freely
for every plaintext arm.

---

## Cross-cutting findings that change the answer for several rows

### X-1 Olm inbound PreKey sessions trust the identity key the frame carries (HOL-SEC-003 / A-DM-03)

Every "authenticated by Olm" claim below (CallSignal, VC targeted SDP/ICE over Olm, fwd_* at both
forwarder kinds) reduces to: which device may hold an Olm session keyed as `peer_str`.

- `node/swarm.rs:6697-6710`: a PreKey needs only a present `identity_key`: `let their_identity = match &identity_key { Some(k) => k, None => { ... return; } };`
- `node/swarm.rs:6712-6729`: with an existing session that cannot decrypt, the session is REPLACED:
  `olm.remove_session(&peer_str);` then `match olm.create_inbound_session(&peer_str, their_identity, &ciphertext)`.
- `node/swarm.rs:6799`: no session: `match olm.create_inbound_session(&peer_str, their_identity, &ciphertext)`.
- `crypto/olm_manager.rs:112` + `:123-128`: the key is parsed from the frame and the session stored
  under `peer_id` with no comparison to anything: `self.sessions.insert(peer_id.to_string(), session);`
- The only reaction to a different key is an alert AFTER the session is built and the plaintext is
  dispatched: `node/security_alerts.rs:162-171` (`Some(_) => { let _ = store.set_olm_key_pin(...); ... record(... KIND_KEY_CHANGED ...)`),
  and a first contact pins silently (`:174-176`).
- The only signed binding of a Curve25519 key to a device is the KeyBundle, and it binds the
  RESPONDER's keys only (`node/crypto_handler.rs:428` format
  `"hollow-keybundle:{sender_device}:{recipient_device}:{identity_key}:{one_time_key}:{ts}"`). The
  initiator's identity key inside the PreKey is bound to nothing.
- The relay learns one-time keys: KeyBundles are plaintext `HavenMessage::KeyBundle` sent by
  `send_message_to_peer` (`node/swarm.rs:6561-6566`, `node/crypto_handler.rs:2793-2799` plaintext `SendDirect`).
  A replayed signed KeyRequest makes the victim mint a fresh one (`node/swarm.rs:6556`
  `let otk = olm.generate_one_time_key();`), and the relay can force a re-key by corrupting one Olm
  frame (`node/swarm.rs:6911-6914` teardown on decrypt failure, then a KeyRequest at `:6942-6947`).
- The parallel session's uncommitted harness test
  `authz_olm_prekey_relay_cannot_open_a_session_as_another_device` (node/test_harness.rs, in the
  working-tree diff) drives exactly this with a forged `CallSignal { CallInvite }`, so this is known.
- Same pattern at the standalone forwarder: `forwarder/signaling.rs:396-408` (`olm_decrypt`),
  `:427` `match olm.create_inbound_session(from, their_identity, ciphertext)`.

Consequence for this area: "sender = the device whose Olm ratchet decrypted this" (the comment at
`node/swarm.rs:9056-9058`) holds against peers but NOT against the relay. The TRANSPORT-1 fix
(Call* only inside Olm) is bypassable by the relay via X-1.

### X-2 Plaintext voice presence and state: authority is the relay-stamped `from`

Join, leave and the four state signals always go out as a plaintext twin
(`node/voice_handler.rs:667-669` `fan_plaintext_to_members(ws_cmd_tx, ws_room_peers, state, local_peer_str, plain);`,
`node/voice_handler.rs:1277-1283` "UNCONDITIONAL plaintext twin"), and the plaintext receive arms key
the participant on `peer_str` (`node/swarm.rs:14066`, `:14085`, `:14104`, `:14121`, `:14139`, `:14153`).
No signature, no timestamp, no nonce. The relay can forge or replay any of these for any member
device.

### X-3 MLS-delivered VC envelopes: not bound to the decrypting group or to the leaf

- The MLS arm decrypts under `group_key` built from the frame's own `server_id`
  (`node/swarm.rs:10888-10891`) and gets the leaf (`:10957` `Ok(Some((plaintext, sender_peer_id)))`),
  but every VC handler is called with `peer_str`, the relay `from`, not the leaf
  (`node/swarm.rs:11369-11379` comment "keyed by the ROUTABLE WS sender (`peer_str`), NOT the MLS
  leaf credential" and `peer_str.to_string(), sid, cid,`). No line compares `peer_str` with
  `sender_peer_id` (awk over 10884-11600: every `peer_str` use listed, none is such a compare).
- The envelope's `sid` is never compared with the decrypting group's `server_id` (awk over
  10884-11545 for `sid != server_id` / `sid == server_id`: NOT FOUND).

---

### A-MED-01 MessageEnvelope::CallSignal and its 17 whitelisted Call* inner variants (1:1 call control, SFrame key hand-off)

- Dispatch sites:
  - Olm MessageEnvelope arm: `node/swarm.rs:9059-9063` `Ok(MessageEnvelope::CallSignal { signal }) => { voice_handler::handle_call_signal_message(peer_str, master_peer_str, *signal, event_tx,).await; }`
  - MLS MessageEnvelope arm: REJECTED `node/swarm.rs:11522-11524` `MessageEnvelope::CallSignal { .. } => { hollow_log!("[HOLLOW-SECURITY] REJECTED call signal envelope via MLS from {sender_peer_id}"); }`
  - fetch.rs (push node): not handled, dropped: `node/fetch.rs:756` `Ok(_) => None, // Other envelope types — ignore in fetch mode.`
  - Plaintext HavenMessage Call*: REJECTED, see A-MED-02.
  - Relay topic ring / sync backfill / gossip / data channel: none found.
- Handler: `handle_call_signal_message`, `node/voice_handler.rs:377-552`.
- Target object: `call_id` (all variants), plus `sframe_key` (CallInvite, CallAccept), SDP/ICE,
  mute/video/screen/recording booleans. No peer is named; the event carries `peer_id: peer_str`
  (`node/voice_handler.rs:386-390`).
- State changes (Rust): none except emitting `NetworkEvent::CallSignal` to Dart
  (`node/voice_handler.rs:384-392` `event_tx.send(NetworkEvent::CallSignal { peer_id: peer_str.to_string(), signal_type: ..., payload: ... })`).
  Dart then acts (ring, tear down, set remote description, install SFrame key):
  `lib/src/core/providers/event_provider.dart:1373-1380` resolves `peerId` to master
  (`ref.read(deviceLinkProvider).identityOf(peerId)`) and calls `handleCallSignal`
  (`lib/src/core/providers/call_provider.dart:1641-1683`).
- Checks before the first state change, in order:
  1. Olm decrypt keyed by `peer_str` (sender DEVICE, relay-stamped; see X-1): `node/swarm.rs:6880` `match olm.decrypt(&peer_str, message_type, &ciphertext)` or the PreKey paths `:6718`, `:6729`, `:6799`.
  2. Global per-`from` token bucket for every WS frame: `node/swarm.rs:4576-4596` (`peer_rate_tokens.entry(from.clone())`).
  3. Variant whitelist: anything but the 17 Call* is logged and dropped `node/voice_handler.rs:543-550` (`REJECTED non-call message {kind} smuggled inside a call signal envelope`).
  4. CallInvite only: block guard on the resolved MASTER of the sender device, siblings exempt: `node/voice_handler.rs:398-402` `if !super::resolver::same_identity(peer_str, master_peer_str) && super::blocklist::is_blocked(peer_str) { return; }` (`node/blocklist.rs:42` `let master = super::resolver::resolve(peer_id);`).
  5. SDP size cap for CallSdpOffer/Answer/ScreenOffer/ScreenAnswer: `node/voice_handler.rs:436`, `:447`, `:493`, `:504` `if sdp.len() > MAX_SDP_SIZE` (`node/types.rs:20` `64 * 1024`).
  6. Dart: `call_id` equality with the current call, per handler:
     `_handleReject` `call_provider.dart:1929` `if (state.callId != callId) return;`,
     `_handleEnd` `:1936`, `_handleBusy` `:1948`, `_handleSdpOffer` `:1991`, `_handleSdpAnswer` `:2073`,
     `_handleIce` `:2106`, `_handleVideoState` `:2121`, `_handleAudioState` `:2153`
     (`if (callId != null && state.callId != callId) return;`; Rust always emits the key so `null` never happens,
     `node/voice_handler.rs:475-479`), `_handleScreenState` `:2167`, `_handleScreenOffer` `:2205` + consent `:2208`
     `if (!state.watchingRemoteShare)`, `_handleScreenAnswer` `:2265`, `_handleScreenIce` `:2275`,
     `_handleScreenWatch` `:1535`, `_handleMediaRestart` `:743`; `_handleAccept` `:1892-1896`
     (`state.status != CallStatus.ringing || state.direction != CallDirection.outgoing || state.callId != callId`).
     `recording_start/stop` ignore `call_id` entirely: `:1677-1680` `ref.read(recordingProvider.notifier).onRemoteRecordingStart(peerId);`.
     `_handleInvite` has no `call_id` gate and no relationship gate (`:1789-1881`).
- Who can sign: unsigned (authority = the Olm session keyed `peer_str`). No inner signature on any Call* variant (`node/types.rs:2398-2440`).
- Binding (sender to the call it names): NONE FOUND. Rust binds nothing; Dart compares only
  `call_id`, never `peerId` against `state.peerId` in any of the handlers listed in check 6. The
  only identity compares are the glare/busy decision (`call_provider.dart:1810-1815`
  `links.sameIdentity(state.peerId ?? '', peerId)`) and the reneg retry/drain (`:2037`, `:2096`
  `state.peerId == peerId`). `_handleAccept` then dials whoever sent the accept:
  `:1909-1913` `await _service.createOffer(peerId, callId, withVideo: false,)`.
  `call_id` is 16 bytes from a NON-cryptographic PRNG: `call_provider.dart:2404-2408`
  `final r = Random(); return List.generate(16, (_) => r.nextInt(256)...)`. It also appears in
  plain logs (`node/voice_handler.rs:404` `CallInvite from {peer_str} call={call_id}`).
- SFrame key from CallInvite/CallAccept, where installed and for which peer:
  - Rust passes it through untouched: `node/voice_handler.rs:405-409` (invite) and `:413-416` (accept).
  - Callee: stored at `call_provider.dart:1858-1865` (`sframeKey: sframeKey,` in the new `CallState`), installed in `_handleSdpOffer` `:2054-2060` `await _service.setSframeKey(peerId, keyBytes);` where `peerId` is the MASTER of the device that sent the sdp_offer (event_provider.dart:1377-1378).
  - Caller: installs ITS OWN generated key (`call_provider.dart:933` `final sframeKey = _generateSframeKey();`, `:2412-2413` `Random.secure()`) in `_handleAccept` `:1915-1918`; the accept's `sframe_key` is never read (`:1883-1890` reads only `call_id`). Also re-applied on media restart `:723-727`.
  - Glare (polite side) adopts the remote invite's key (`:1855-1857` comment, `:1864`).
  - The cryptor is a SHARED-key cryptor; `peerId` is only a participant label: `lib/src/core/services/voice_service.dart:1314` `await _frameCryptor!.init(sharedKey: true);`, `:1332` `await _frameCryptor!.rotateKey(0, key);`, `:1338` `enableForSender(peerId, sender)`, `:1350` `enableForReceiver(peerId, receiver)`.
- Transport parity: Olm only. MLS rejects (`node/swarm.rs:11522`), plaintext rejects (A-MED-02), fetch.rs ignores (`node/fetch.rs:756`).
- Freshness / replay: Olm ratchet (a replayed Normal message fails to decrypt, `node/swarm.rs:6880`, and the failure TEARS DOWN the session `:6911-6914`, which is itself a relay-triggerable re-key, feeding X-1). Survives restart via persisted sessions (`persist_olm_session`, `:6956`). No per-call nonce or timestamp.
- Absent fields: `CallInvite.video` and `.sframe_key` `#[serde(default)]` (`node/types.rs:2398`); empty key means Dart skips `setSframeKey` (`call_provider.dart:2055` `if (keyHex.isNotEmpty)`), i.e. the call runs WITHOUT SFrame on the legacy bare-id invite (`node/voice_handler.rs:281` builds `sframe_key: String::new()` for a non-JSON payload). `CallAccept.sframe_key` default, unused.
- Blast radius: local, reversible (a call). Media content is protected only by the SFrame key; control (end, hijack of the answer leg, fake mute/screen state) is protected only by `call_id` secrecy plus Olm.
- Tests: `plaintext_call_signal_is_rejected` (node/test_harness.rs:3187) (plaintext path), `call_signal_routes_to_friend_device_and_drops_unknown` (:2961, unknown type dropped at :3083-3096), `call_invite_never_exposes_sframe_key_to_the_relay` (:3106). No test rejects an Olm-authenticated signal whose `call_id` belongs to a call with ANOTHER peer. The in-flight HOL-SEC-003 test covers the X-1 route.
- SUSPICION S-01 (relay impersonates a friend's device in a call, via X-1). Mallory = relay. It replays Alice's signed KeyRequest to Bob (or corrupts a frame to force one), takes Bob's fresh OTK from the plaintext KeyBundle, opens an inbound Olm session at Bob as Alice's device with its own Curve25519 key, and sends `CallSignal{CallInvite{sframe_key: relay-chosen}}`. Bob rings "Alice calling"; on accept the media key is the relay's. Anchors: `node/swarm.rs:6728-6729`, `:6799`, `node/voice_handler.rs:405-409`. CONFIRMED-BY-READING for the Rust path (no identity-key check before dispatch); exploit demonstrated by the parallel session's in-flight test.
- SUSPICION S-02 (call control bound only by call_id). Mallory = any peer holding an Olm session with Bob (no friendship needed for the session, see check list: KeyRequest at `node/swarm.rs:6507-6567` has no relationship gate). If Mallory learns or guesses the `call_id` of Alice's call with Bob she can end it (`_handleEnd`), answer the caller's ringing call and receive its offer (`_handleAccept` dials `peerId` = Mallory, `call_provider.dart:1909-1913`), or re-point an active call's renegotiation (`_handleSdpAnswer` `:2077` `await _service.handleAnswer(sdp);`). Content stays SFrame-protected (Mallory lacks the key). `call_id` uses `Random()` (`call_provider.dart:2405`) and is logged. PLAUSIBLE (hard precondition: learning the id).
- SUSPICION S-03 (no relationship gate on ringing). Any peer with an Olm session and no block entry can ring: Rust gate is only the blocklist (`node/voice_handler.rs:398-402`), Dart `_handleInvite` has none (`call_provider.dart:1789-1881`). A blocked user's device not yet in the resolver resolves to itself (`node/blocklist.rs:42`) and is not blocked. PLAUSIBLE (policy question).

### A-MED-02 HavenMessage::Call* plaintext arm (the 17 variants in the clear)

- Dispatch site: plaintext `node/swarm.rs:13939-13957`.
- Handler: inline reject: `hollow_log!("[HOLLOW-SECURITY] REJECTED plaintext call signal from {peer_str}");`
- State changes: none.
- Checks: variant match only (all 17 listed at `:13939-13955`: CallInvite, CallAccept, CallReject, CallEnd, CallBusy, CallMediaRestart, CallSdpOffer, CallSdpAnswer, CallIceCandidate, CallVideoState, CallAudioState, CallScreenState, CallScreenOffer, CallScreenAnswer, CallScreenIce, CallScreenWatch, CallRecordingState). Matches the whitelist in `handle_call_signal_message` (`node/voice_handler.rs:395-542`, 17 arms).
- Transport parity: fetch.rs has no Call* arm (`node/fetch.rs` HavenMessage arms: MlsChannelMessage :470, PublicChannelMessage :545, Encrypted :717). The gossip data-channel path only ever builds `CrdtOpBroadcast` (`node/swarm.rs:2966` `HavenMessage::CrdtOpBroadcast { server_id, op_json },`).
- Tests: `plaintext_call_signal_is_rejected` (node/test_harness.rs:3187-3223).
- SUSPICION: none on this arm.

### A-MED-03 HavenMessage::VoiceChannelJoin (plaintext) and MessageEnvelope::VoiceChannelJoin (MLS) (adds sender to a voice channel's participant set; peers dial it)

- Dispatch sites:
  - Plaintext: `node/swarm.rs:14034-14077`.
  - MLS: rate gate `node/swarm.rs:11347-11367` then `:11374-11381` → `voice_handler::handle_envelope_voice_channel_join` (`node/voice_handler.rs:1467-1537`).
  - Olm: IGNORED as MLS-only `node/swarm.rs:9155` (`Ok(MessageEnvelope::VoiceChannelJoin { .. })` in the "Received MLS-only envelope via Olm ... ignoring" arm, `:9162`).
  - Conference reply: a plaintext `VoiceChannelJoin` sent back by peers `node/voice_handler.rs:1514-1525`.
  - fetch.rs: none.
- Target object: `server_id`/`sid`, `channel_id`/`cid`. The participant added is always the sender transport id, never a payload field (plaintext `:14065-14066` `.insert(peer_str.to_string())`; MLS `node/voice_handler.rs:1526-1527` `.insert(sender_peer_id.clone())` where `sender_peer_id` = `peer_str`, `node/swarm.rs:11379`).
- State changes, in order:
  1. RAM `voice_channel_participants` insert (plaintext `node/swarm.rs:14065-14066`; MLS `node/voice_handler.rs:1526-1527`). This set is the gate for every later VC signal (`is_vc_participant`, `node/voice_handler.rs:1455-1463`).
  2. MLS conf path only, BEFORE the insert: outbound plaintext reply `node/voice_handler.rs:1519-1524` `send_message_to_peer_in_room(ws_cmd_tx, &sid, &sender_peer_id, HavenMessage::VoiceChannelJoin {..})`.
  3. Event `VoiceChannelJoined { is_self: false }` (`node/swarm.rs:14067-14070`, `node/voice_handler.rs:1528-1531`). Dart dials the peer when in the same channel: `lib/src/core/providers/event_provider.dart:1402-1407` `if (vcState.currentServerId == serverId && vcState.currentChannelId == channelId) { vcNotifier.onRemotePeerJoined(peerId, ...`.
  4. `check_voice_mode_transition` may emit `VoiceChannelModeChanged` (`node/voice_handler.rs:1381-1419`).
- Checks before the first state change:
  - Plaintext, in order: self-echo `node/swarm.rs:14036` `if peer_str == local_peer_str || peer_str == device_peer_id { return; }`; membership on the resolved MASTER of the relay-stamped device: non-conf `:14046-14048` `s.is_member(peer_str)` (`crdt/server_state.rs:1289-1291` `let key = super::resolve_identity(peer_id); self.members.contains_key(&key)`), conf `:14043-14044` `m.group_members(&server_id).iter().any(|c| c == peer_str)` (leaf set of the named conf group); channel type `:14053-14056` `ch.channel_type == ... ChannelType::Voice` (conf: `channel_id == CONF_CHANNEL`).
  - MLS, in order: MLS decrypt of the frame's own group (`node/swarm.rs:10955`); VC rate bucket keyed `peer_str` (`:11365` `if !voice_handler::vc_rate_check(vc_signal_rate_tokens, peer_str)`); self-echo `node/voice_handler.rs:1482`; member `:1488-1492` `let is_member = if is_conf { true } else { server_states.get(&sid).map(|s| s.is_member(&sender_peer_id)).unwrap_or(false) };`; voice type `:1493-1498`; reject `:1499-1506`.
  - NOT checked anywhere on receive: channel visibility for a restricted voice channel. The only `can_see_channel` gate is on OUR OWN outbound join (`node/voice_handler.rs:579-590` `.is_some_and(|s| s.can_see_channel(local_peer_str, &channel_id));`).
- Who can sign: unsigned. Authority = relay `from` (plaintext) or relay `from` + possession of SOME MLS group key (MLS, see X-3).
- Binding: sender to membership = `is_member(peer_str)` (quoted above). Sender to channel visibility: NONE FOUND. MLS conf path: sender to the named conference: NONE FOUND (`is_conf => true`, `node/voice_handler.rs:1488`, and `sid` is not compared with the decrypting group, X-3).
- Transport parity: plaintext conf = leaf check (`node/swarm.rs:14043-14044`); MLS conf = no check (`node/voice_handler.rs:1488`). MLS has the VC rate bucket (`node/swarm.rs:11365`), plaintext only the global bucket (`:4576-4596`).
- Freshness / replay: plaintext NONE FOUND (relay may replay any old join). MLS: generation replay dropped `node/swarm.rs:10956` `Ok(None) => return,`. RAM only; `WsEvent::Disconnected` purges remote participants (per CLAUDE.md; not re-verified here).
- Absent fields: none (no Option fields on either variant, `node/types.rs:2604-2616`, `:3389-3400`).
- Blast radius: local RAM + Dart dials the joiner (ICE candidates, i.e. our IPs, go to it via Olm). Presence of every restricted-channel participant is fanned in plaintext to ALL server members, not only those who can see the channel: `node/voice_handler.rs:638` `for member in state.members.keys() {`.
- Tests: `voice_channel_join_leave_and_signal_routing` (:5202; unknown type dropped :5326); `restricted_voice_channel_subgroup_enforces_sframe_membership` (:7978) tests only the SENDER-side guard (`:8128-8150`, its own comment: "even a modified client that bypassed the guard could not derive the SFrame key"). No test for a modified client's inbound join to a restricted channel, a relay-forged plaintext join, or a cross-group conference join.
- SUSPICION S-04 (restricted voice channel join not gated on receive). Mallory = server member who cannot see restricted voice channel V, modified client. She sends `VoiceChannelJoin{sid, V}` (plaintext or MLS). Alice (in V) adds her (`node/swarm.rs:14065-14066` / `node/voice_handler.rs:1526-1527`) and dials her (`event_provider.dart:1402-1407`), handing Mallory ICE candidates and a roster seat; Mallory can then send screen_watch/state signals as a participant (A-MED-05/07). Audio stays under the subgroup SFrame key she lacks. CONFIRMED-BY-READING (no `can_see_channel` on any inbound join path).
- SUSPICION S-05 (cross-group conference join over MLS). Mallory = co-member of ANY MLS group Alice holds (e.g. a shared server) who knows conference id `conf:B`. She MLS-broadcasts `MessageEnvelope::VoiceChannelJoin{sid:"conf:B", cid:"main"}` in the shared server's group. Alice decrypts under that group, `is_conf` makes `is_member = true` (`node/voice_handler.rs:1488`), no check ties `sid` to the decrypting group (X-3); Alice replies with her own join (`:1519-1524`), inserts Mallory (`:1526-1527`) and, if in meeting B, Dart dials her. That bypasses the host's waiting-room admission for roster and ICE exposure; media stays under the conf group key. PLAUSIBLE (Rust path CONFIRMED-BY-READING; Dart dial path read at event_provider.dart:1402-1407, conf id knowledge assumed).
- SUSPICION S-06 (relay-forged presence). Mallory = relay. Injects plaintext `VoiceChannelJoin` with `from` = any member device (passes `is_member(peer_str)`), making peers dial that device, or replays old joins. PLAUSIBLE, low (availability/roster integrity).

### A-MED-04 HavenMessage::VoiceChannelLeave (plaintext) and MessageEnvelope::VoiceChannelLeave (MLS) (removes sender from participants; peers tear down the leg)

- Dispatch sites: plaintext `node/swarm.rs:14079-14100`; MLS `node/swarm.rs:11382-11388` → `node/voice_handler.rs:1541-1572`; Olm ignored (`node/swarm.rs:9156`); fetch.rs none.
- Target object: `server_id`/`sid`, `channel_id`/`cid`; the removed participant is always the transport sender.
- State changes: RAM remove `node/swarm.rs:14084-14089` `participants.remove(peer_str);` (MLS `node/voice_handler.rs:1556-1561` `participants.remove(&sender_peer_id);`); event `VoiceChannelLeft` (`node/swarm.rs:14091-14094`, `node/voice_handler.rs:1563-1566`); Dart `onRemotePeerLeft(peerId, inOurChannel: ...)` (`event_provider.dart:1431-1437`).
- Checks before the first state change: self-echo only (`node/swarm.rs:14081`, `node/voice_handler.rs:1553`). MLS adds the decrypt and `vc_rate_check` (`node/swarm.rs:11365`). No membership check (none needed to remove oneself).
- Who can sign: unsigned; authority = relay `from` (plaintext).
- Binding: sender removes only itself (`participants.remove(peer_str)`). One member cannot name another. Only the relay can choose `from`.
- Transport parity: identical logic on both.
- Freshness / replay: plaintext NONE FOUND; MLS generation dedup `node/swarm.rs:10956`.
- Absent fields: none.
- Blast radius: local; Dart closes the peer leg when `inOurChannel`.
- Tests: `voice_channel_join_leave_and_signal_routing` (:5202). No forged-leave test.
- SUSPICION S-07 (relay can tear down a live P2P voice leg). Mallory = relay. Injects plaintext `VoiceChannelLeave` with `from` = Bob's device to Alice; Alice removes Bob and Dart tears down a leg whose media may be direct P2P (outside relay reach). PLAUSIBLE, low (availability).

### A-MED-05 VoiceChannelAudioState / ScreenState / CameraState / RecordingState (plaintext HavenMessage + MLS MessageEnvelope) (UI state: mute, deafen, sharing, camera, recording indicator)

- Dispatch sites: plaintext `node/swarm.rs:14102-14117`, `:14119-14135`, `:14137-14149`, `:14151-14164`; MLS `node/swarm.rs:11407-11412`, `:11434-11439`, `:11483-11488`, `:11489-11494` → `node/voice_handler.rs:1788-1807`, `:1809-1833`, `:1950-1969`, `:1971-1991`; Olm IGNORED (`node/swarm.rs:9157-9160`).
- Target object: `server_id`, `channel_id`; the state is attributed to the transport sender.
- State changes: only `NetworkEvent::VoiceChannelSignal { peer_id: peer_str, signal_type: "audio_state" | "screen_state" | "camera_state" | "recording_start/stop" }` (e.g. `node/swarm.rs:14112-14115`).
- Checks: participant membership of the transport sender: plaintext `node/swarm.rs:14104` `voice_channel_participants.get(&vc_key).map(|p| p.contains(peer_str)).unwrap_or(false)` (same at `:14121`, `:14139`, `:14153`); MLS `node/voice_handler.rs:1798`, `:1819`, `:1959`, `:1980` via `is_vc_participant` (`:1461` `.map(|p| p.contains(sender_peer_id))`), after `vc_rate_check` (`node/swarm.rs:11365`).
- Who can sign: unsigned.
- Binding: to the sender's own tile only (`peer_id: peer_str`). NONE needed for "for another member"; only the relay picks `from`.
- Transport parity: identical checks; the sender ALWAYS emits both (MLS + plaintext twin, `node/voice_handler.rs:1273-1283`), so the plaintext copy is always present on the relay.
- Freshness / replay: plaintext NONE FOUND; Dart applies last-received (both copies arrive; `node/voice_handler.rs:1255-1258` "small, idempotent, last-writer-wins").
- Absent fields: `quality: Option<String>` on ScreenState, cosmetic.
- Blast radius: UI only.
- Tests: `vc_state_signal_reaches_a_deaf_member` (:20103) is a delivery test. No rejection test.
- SUSPICION S-08 (relay forges deafen/mute/recording). Mallory = relay. Drops Alice's MLS copy and injects a plaintext `VoiceChannelAudioState{deafened:true}` from Alice's device, so Bob believes Alice cannot hear him while she can; or `recording_stop` so the recording indicator clears while Alice records (equivalent to dropping `recording_start`, which the relay can already do). PLAUSIBLE, low.

### A-MED-06 VC targeted signals: VoiceChannelSdpOffer / SdpAnswer / Ice / RenegOffer / RenegAnswer / LegRestart (Olm-direct or MLS)

- Dispatch sites:
  - Olm inline: SdpOffer `node/swarm.rs:9189-9203`, SdpAnswer `:9204-9218`, Ice `:9219-9235`, RenegOffer `:9277-9291`, RenegAnswer `:9292-9306`, LegRestart `:9307-9312` (→ `node/voice_handler.rs:1696-1711`).
  - MLS: `node/swarm.rs:11389-11406`, `:11465-11482` → `node/voice_handler.rs:1575-1618`, `:1686-1719`, `:1722-1747`.
  - Plaintext HavenMessage: none (no such variants).
- Sender side: whitelist `node/voice_handler.rs:1091-1205` (unknown type `:1200-1203` logs and yields None); targeted types go Olm-direct `:1080-1084` `send_encrypted_message_in_room(olm, crypto_store, &peer_id, &server_id, &env_json, ...)`; self-target belt `:1059-1062`.
- Target object: `sid`, `cid`; `target: Option<String>` exists but the sender always builds `target: None` (e.g. `:1102`); the MLS arm filters on it vs our MASTER `node/swarm.rs:10974-10977`.
- State changes: `VoiceChannelSignal` event only (Dart sets remote descriptions / adds candidates / rebuilds the leg for `leg_restart`).
- Checks: sender (`peer_str`) in `voice_channel_participants` for that `sid:cid` (Olm `node/swarm.rs:9191`, `:9206`, `:9221`, `:9279`, `:9294`; MLS `node/voice_handler.rs:1587`, `:1702`, `:1733`), then SDP ≤ 64 KiB (`node/swarm.rs:9194`, `node/voice_handler.rs:1591`). MLS path additionally `vc_rate_check` (`node/swarm.rs:11365`).
- Who can sign: unsigned; Olm session (X-1) or MLS group key (X-3).
- Binding: sender must be a participant; no binding to "a leg we actually have with this sender" in Rust (Dart concern).
- Transport parity: DIFFERENCE: Olm arm has no `vc_rate_check` (only use is `node/swarm.rs:11365`, inside the MLS arm). Otherwise identical guards.
- Freshness: Olm ratchet / MLS generation dedup.
- Absent fields: `target` Option (serde default), unused by the sender.
- Blast radius: local media renegotiation.
- Tests: `vc_reconnecting_peer_can_receive_signals_again` (:5793, comment at :5891 on the non-participant drop), `vc_leg_restart_signal_round_trips` (:5920). No test asserts a non-participant rejection on these types.
- SUSPICION: none beyond X-1 (a relay-opened Olm session as a participant device can inject SDP) and S-04 (a non-qualifying member becomes a participant).

### A-MED-07 Screen-share VC signals with `origin`: VoiceChannelScreenOffer / ScreenAnswer / ScreenIce / ScreenWatch / ScreenAssign / ScreenFeedState

- Dispatch sites: Olm `node/swarm.rs:9239-9276` (all call the shared voice_handler functions); MLS `node/swarm.rs:11415-11462`. Plaintext: none.
- Handlers: `emit_vc_screen_sdp_signal` `node/voice_handler.rs:1624-1658` (offer/answer), `handle_envelope_voice_channel_screen_ice` `:1750-1786`, `..._screen_watch` `:1836-1871`, `..._screen_assign` `:1877-1908`, `..._screen_feed_state` `:1917-1948`.
- Target object: `sid`, `cid`, `origin {peer, kind, stream}` (Option on offer/answer/ice, required Box on assign/feed_state, `node/types.rs:3459`, `:3472`, `:3490`, `:3570`, `:3594`); assign also names `forwarder` and `feed_target`; watch carries `want`, `route`, `fwd_capable`, `relay_private`, `fwd_simulcast`, `fwd_feed`.
- State changes: `VoiceChannelSignal` event only. Dart consequences: `screen_watch{want:true}` is the consent that makes the sharer stream to the requester (#38); `screen_assign` makes the viewer join `fwd:{forwarder}` and send `fwd_attach` (`lib/src/core/providers/voice_channel_provider.dart:3248-3260`) and may start a feed (`:3203`).
- Checks, in order: participant (`node/voice_handler.rs:1637`, `:1764`, `:1852`, `:1889`, `:1929`), SDP ≤ 64 KiB (offer/answer `:1641`), origin spoof guard `inbound_origin_ok` (offer/answer `:1645`, ice `:1768`, assign `:1894`, feed_state `:1934`; NOT on screen_watch, which has no origin):
  `node/voice_handler.rs:1236-1242` `None => true, Some(o) => { super::resolver::same_identity(&o.peer, sender_peer_id) || super::resolver::same_identity(&o.peer, local_peer_str) }`.
  Dart then gates assign on consent: `voice_channel_provider.dart:3196` `if (originPeer.isEmpty || !state.watchingScreenShares.contains(originPeer)) { return; }` and Always-relay `:3223-3230`.
- Who can sign: unsigned; Olm (X-1) / MLS (X-3).
- Binding: origin to sender = `same_identity(o.peer, sender)` (MASTER collapse, so any sibling device of the sender qualifies) OR origin names US. For assign/feed_state the doc comment says the origin "must name the authenticated sender assigning viewers to ITS OWN stream" (`:1874-1876`) but the function also admits origin = ourselves; Dart comment `voice_channel_provider.dart:3194` "Rust already dropped spoofed origins (origin must name the SENDER)" is therefore stronger than the code. Harmless today only because Dart requires the origin to be a share WE watch (never our own).
- Transport parity: identical (Olm and MLS both call the same voice_handler functions; MLS adds `vc_rate_check`).
- Freshness: Olm ratchet / MLS generation dedup.
- Absent fields: `origin: None` on offer/answer/ice = "sender is the originator" (accepted, `:1237`). Assign/feed_state without origin cannot be built (`:1157`, `:1168`) and deserialize requires it.
- Blast radius: local; routes the viewer's media leg to a forwarder the sharer names (SFrame ciphertext only).
- Tests: `vc_screen_origin_attribution_round_trip` (:5558; spoofed origin dropped :5763-5765), `vc_screen_assign_and_route_round_trip` (:15737; spoofed assign dropped :15926-15927).
- SUSPICION S-09 (low): `inbound_origin_ok` accepts `origin == local` for assign/feed_state contrary to its callers' stated contract (`node/voice_handler.rs:1240`, `:1894`, `:1934`); safe only through the Dart consent gate at `voice_channel_provider.dart:3196`. PLAUSIBLE, hardening.

### A-MED-08 HavenMessage::RtcOffer / RtcAnswer / RtcIceCandidate / RtcShareOffer / RtcShareAnswer / RtcShareIceCandidate (WebRTC data-channel setup)

- Dispatch sites: plaintext only, `node/swarm.rs:13791-13889`. Sent plaintext: `node/voice_handler.rs:60-106` → `send_message_to_peer` (`node/crypto_handler.rs:2793-2799`, raw JSON `SendDirect`). fetch.rs: none.
- Handler: inline; emits `NetworkEvent::WebRtcSignal { peer_id: peer_str, signal_type, payload, conn_id }` (e.g. `node/swarm.rs:13806-13811`); Dart `WebRtcService.handleSignal` (`lib/src/core/services/webrtc_service.dart:473-495`).
- Target object: `conn_id` (the PC), SDP (contains DTLS fingerprints and ICE candidates in the clear).
- State changes: Dart creates/answers a PeerConnection (offer) or `setRemoteDescription` (answer, `webrtc_service.dart:931-932`) or `addCandidate`. A connected data channel is later used under `peerId` for file/shard/share bytes and gossip ops (`node/swarm.rs:2909-2967` feeds `WebRtcGossipOpReceived` into `handle_incoming_request` as `CrdtOpBroadcast` with `&sender_peer_id`).
- Checks: SDP ≤ 64 KiB on offers/answers (`node/swarm.rs:13792`, `:13814`, `:13844`, `:13864`); block guard on OFFERS only (`:13799-13803`, `:13850-13854`, master-resolved, siblings exempt). No relationship, room or membership gate. Dart answer matching falls back to `conn_id` regardless of sender: `webrtc_service.dart:914-918` `var conn = _connsFor(lane)[peerId]; if (conn == null || conn.connId != connId) { final byConn = _findConnByConnId(connId, lane); if (byConn != null) conn = byConn; }`; ICE likewise `:966-970`.
- Who can sign: unsigned (authority = relay `from`). Not encrypted.
- Binding: answer/ICE to the offer = `conn_id` only (NONE FOUND to the sender identity). `conn_id` is `Random()`-generated (`webrtc_service.dart:1423-1427`) and travels in the plaintext offer.
- Transport parity: single transport.
- Freshness: NONE FOUND (a stale answer is ignored only if `conn.connId != connId`, `:927-930`).
- Absent fields: none.
- Blast radius: transport hijack; payload confidentiality rests on app-layer encryption (file bytes are AES with keys from the E2EE FileHeader, `node/file_handler.rs:1613-1636`), ops rest on CRDT signatures. IP addresses exposed to the relay by design.
- Tests: none found for forged answers.
- SUSPICION S-10 (relay MITMs every data channel). Mallory = relay. Reads `conn_id` and the DTLS fingerprint from Alice's plaintext `RtcOffer`, drops Bob's answer and injects `RtcAnswer{conn_id}` with its own fingerprint (any `from` works because of the conn_id fallback); Alice's channel labelled "Bob" now terminates at the relay, which can also forge a fresh `RtcOffer` from Bob's id (no gate beyond the blocklist). Anything received on that channel is attributed to Bob (`sender_peer_id`). CONFIRMED-BY-READING for signaling; impact bounded by app-layer crypto (not traced here).

### A-MED-09 Forwarder-bound fwd_* at the standalone (VPS) forwarder: FwdStreamRegister / FwdStreamAuth / FwdStreamUnregister / FwdIngestOffer / FwdAttach / FwdDetach / FwdEgressAnswer

- Dispatch site: `forwarder/signaling.rs:246-323`, only 0x06 direct frames (`:257`), Olm-decrypted (`:284-291`), whitelisted (`:295-307` → `EngineCmd::Signal { sender, envelope: env }`), everything else ignored (`:310-321`). Room presence text frames drive `EngineCmd::PeerGone` (`:165-208`).
- Handler: `engine::handle_signal` `forwarder/engine.rs:283-501`; admission in `forwarder/dispatch.rs`.
- Target object: `origin {peer, kind, stream}` → `stream_key` = `(o.peer, o.kind, o.stream)` (`forwarder/stream.rs:30-31`); register also names `allowed_viewers`, `low_viewers`, `feeder`; auth names `add`/`remove` viewer ids.
- State changes and their checks:
  - Register: `admit_register` (`forwarder/dispatch.rs:39-49`): `if origin_peer != sender { return Err(FwdErrorCode::NotAuthorized); }` (`:42-44`, exact device string vs relay/Olm `sender`), caps `:49`. Then insert or replace allowlist/low/feeder (`forwarder/engine.rs:311-328`); re-register refreshes the feeder `:318` `s.feeder = feeder;`.
  - Auth / Unregister: `admit_owner_op` `forwarder/dispatch.rs:61-65` `Some(s) if s.owner != sender => Err(FwdErrorCode::NotAuthorized)`; then allowlist edits `forwarder/engine.rs:337-347` (removing a viewer also kills its leg `:343-346`) or `streams.remove(&key)` `:356-358`.
  - IngestOffer: `admit_ingest_offer` `forwarder/dispatch.rs:85-90` (owner, or `!s.feeder.is_empty() && s.feeder == sender`); then REPLACES the ingest leg `forwarder/engine.rs:374-377` `if let Some(old) = s.ingest.take() { old.shut_down(); }`.
  - Attach: `admit_attach` `forwarder/dispatch.rs:106-108` `if !s.sender_allowlisted { return Err(FwdErrorCode::NotAuthorized); }` where `sender_allowlisted = s.allowlist.contains(sender)` (`forwarder/engine.rs:276`); duplicate attach replaces the sender's own leg `:436-438`.
  - Detach / EgressAnswer: looked up by `sender` only (`forwarder/engine.rs:487`, `:494`), so a peer can touch only its own leg.
- Who can sign: unsigned; authority = the Olm session keyed by the relay frame's `sender` (X-1: `forwarder/signaling.rs:427`). The forwarder's KeyRequest responder verifies the signature but deliberately skips the device-list check (`forwarder/signaling.rs:359-361` comment).
- Binding: register origin to sender `forwarder/dispatch.rs:42`; owner ops to owner `:63`; attach to the owner's allowlist `:106`. All CONFIRMED.
- Transport parity: single transport. `origin` is `#[serde(default)]` on every fwd envelope (`node/types.rs:3687-3780`); an absent origin is `peer: ""`, which never equals a real sender and never matches a registered key.
- Freshness / replay: Olm ratchet only; register is idempotent. RAM only (restart drops all streams).
- Relay-controlled inputs: `members` / `peer_left` text frames (`forwarder/signaling.rs:180-205`) → `handle_peer_gone` (`forwarder/engine.rs:506-543`), which spares live media (`:518-525`, `:531-538`).
- Blast radius: availability of a share; media is SFrame ciphertext (the forwarder holds no group keys, `forwarder/dispatch.rs:78-80`).
- Tests: `forwarder/dispatch.rs` unit tests `register_requires_origin_eq_sender` (:154), `owner_ops` (:178), `ingest_offer_owner_or_delegated_feeder` (:188), `feeder_may_never_administer_the_stream` (:210), `empty_feeder_is_never_a_wildcard` (:221), `attach_gates` (:231), `viewer_ops` (:252).
- SUSPICION S-11 (via X-1, low): the relay can open an Olm session at the forwarder as a sharer's device (the forwarder mints an OTK for any valid signed KeyRequest, `forwarder/signaling.rs:376-383`, and accepts any PreKey identity key, `:427`), then unregister the victim's stream or add itself to the allowlist (ciphertext only). PLAUSIBLE.

### A-MED-10 Forwarder-bound fwd_* at an EMBEDDED peer forwarder (a member's desktop)

- Dispatch site: client Olm arm `node/swarm.rs:9391-9410` → `EmbeddedForwarder::handle_inbound` (`node/embedded_forwarder.rs:151-189`); MLS copy ignored (`node/swarm.rs:11529-11540`).
- Checks before the engine: `if !self.enabled { return false; }` (`:157-159`, the Settings toggle); register only: expectation gate `:163-179` `if !self.expectations.contains(&(origin.peer.clone(), origin.kind.clone()))` → explicit `FwdError not_authorized`. Expectations are set only from OUR OWN advertised `fwd_capable` watch (`:97-124`). Then the same engine admission as A-MED-09.
- Sender principal: `peer_str` from the swarm Olm arm (X-1 applies; shares the node's OlmManager).
- Feeder: `set_feed` (`:223-263`) is driven by Dart after an origin-checked `screen_assign{feed_target}`; it injects `FwdAttach` into our engine AS the target forwarder (`:246-249` `sender: target_forwarder`), and `handle_feed_answer` routes that forwarder's `FwdIngestAnswer` to the engine only if `is_feed_target(sender)` (`:278-284`).
- Transport parity: Olm only.
- Tests: `forwarder_room_and_signal_round_trip` (:15488), `fwd_room_join_skips_discovery_but_keeps_olm` (:15627). No test for the expectation-gate refusal found (grep of test_harness.rs for "no capability advertised"/"not_authorized": none).
- SUSPICION: none beyond X-1.

### A-MED-11 Client-bound fwd_*: MessageEnvelope::FwdIngestAnswer / FwdEgressOffer / FwdError (forwarder → client)

- Dispatch site: Olm `node/swarm.rs:9319-9387`; MLS ignored `:11529-11540`.
- Rust checks: SDP ≤ `MAX_SDP_SIZE` only (`:9320`, `:9365`); the comment says the trust decision is Dart's (`:9315-9318`). Feed answers from a forwarder we feed go to our engine (`:9327-9337`).
- Dart gate (`lib/src/core/providers/voice_channel_provider.dart:3296-3326`): ingest answer only from a forwarder we opened a branch with `:3306-3307` `final branch = _fwdBranches[fromPeer]; if (branch == null) return;`; egress offer only for an assigned AND watched origin from that assignment's forwarder `:3336-3338` `if (assignment == null || assignment.forwarder != fromPeer) return; if (!state.watchingScreenShares.contains(originPeer)) return;`; FwdError keyed on `fromPeer` in all three branches `:3367`, `:3375-3376`, `:3384-3385`.
- Who can sign: unsigned; Olm session with `fromPeer` (X-1).
- Binding: `fromPeer` == the forwarder WE chose (sharer side) or the SHARER named (viewer side). CONFIRMED in Dart.
- Tests: `vc_screen_assign_and_route_round_trip` (:15737) covers delivery; no forged-forwarder rejection test found.
- SUSPICION: none beyond X-1.

### A-MED-12 WsEvent::MediaForwarderInfo (relay) and the `fwd:{id}` room

- Source: relay command `get_media_forwarder` (`relay-uws/src/ws_handler.cpp:2335-2350`: static `config.forwarder_peer_id` + `online` from `peer_sockets`). Client parse `node/ws_client.rs:1246-1255`; swarm forwards it verbatim `node/swarm.rs:4532-4536` `let _ = event_tx.send(NetworkEvent::MediaForwarderInfo { peer_id, online, }).await;`; Dart stores it `lib/src/core/providers/event_provider.dart:329-332` → `forwarderInfoProvider`.
- What it is trusted for: (a) the sharer's VPS rung / branch target (`voice_channel_provider.dart:2492-2493`, `:2535-2538`, `:2558`, `:2605`), i.e. where SFrame-encrypted share media is uploaded; (b) the ONLY forwarder a viewer with "Always relay calls" accepts (`:3223-3230` `if (advertised.isEmpty || forwarder != advertised) { ... _fallbackToDirect(originPeer); return; }`). Not trusted for any key, membership or attribution.
- Checks: none in Rust (no signature, no pinning).
- Binding: NONE FOUND between the advertised id and any operator identity; the relay picks it.
- Blast radius: routing only; SFrame keeps content opaque.
- SUSPICION S-12 (low): a hostile relay can advertise a MEMBER's device (or its own) as "the infra forwarder"; an Always-relay viewer then attaches to it (`:3223-3230` accepts because `forwarder == advertised`), exposing its address to that member, which is what the Always-relay promise excludes. The relay already knows the address, so this is a promise gap, not a new capability for the relay. PLAUSIBLE.

### A-MED-13 SFrame / media key installs and rotations (Rust sources and the Dart peer they are installed for)

DM calls (key chosen by the caller, carried in Olm):
- Generated `call_provider.dart:2412-2413` (`Random.secure()`), sent in the Olm CallInvite, passed through by Rust (`node/voice_handler.rs:405-409`, `:413-416`), installed on a SHARED-key cryptor labelled with the peer's MASTER: callee `call_provider.dart:2057`, caller `:1918`, media restart `:726`; DM screen share `call_provider.dart:2432-2440` (`'screen:$peerId'`). Authority for the key = whoever holds the Olm session (X-1, S-01).

Voice channels / conferences (key = `export_secret(group, "sframe", b"", 32)` of OUR MLS state; no remote party supplies key bytes directly). Every Rust emission of `NetworkEvent::MlsEpochChanged`:
1. Our join / heal re-export: `node/voice_handler.rs:754-761` (`mls_mgr.export_secret(group_key, "sframe", b"", 32)`), called from `handle_voice_channel_join` `:612-616` and `handle_voice_sframe_heal` `:824`.
2. Inbound MLS commit applied: `node/crypto_handler.rs:3004-3011` (after `handle_mls_commit_frame`, dispatched from `node/swarm.rs:11982`). Authority = any leaf of the group (MLS area).
3. Inbound MLS Welcome: `node/swarm.rs:11925-11932`. See S-13.
4. Our batch removal: `node/swarm.rs:5016-5023`; our batch add: `node/swarm.rs:5067-5074`.
5. Our subgroup leaf removal: `node/crypto_handler.rs:2446-2452`; server-group identity-leaf removal: `node/sync_handler.rs:332-339`.
6. Conference admit / kick (host): `node/conference.rs:389-394`, `node/conference.rs:470-475`.
Dart installs the key for the whole channel, not a peer: `lib/src/core/providers/event_provider.dart:1532-1536` → `onEpochChanged` (`voice_channel_provider.dart:4064-4103`), which caches per `(server, channel)`, ignores other servers/channels (`:4070-4076`), refuses a server-group key over a restricted channel (`:4080-4084`), then `voice_channel_service.dart:737` `await frameCryptor!.rotateKey(epoch % 16, key);` and enables it on every PC (`:738-749`); screen cryptors `'screen:$peerId'` (`voice_channel_provider.dart:4408-4419`).

- SUSPICION S-13 (MlsWelcome drops the live group BEFORE verifying, and adopts any group that consumed one of our KeyPackages). Anchors: `node/swarm.rs:11873-11876` `if mls_mgr.has_group(&group_key) { ... mls_mgr.remove_group(&group_key); }` precedes `:11878` `match mls_mgr.join_from_welcome(&group_key, &welcome_bytes)`; the Err arm does not restore it (`:11972-11976`). `crypto/mls_manager.rs:469-496` checks neither the MLS group id against `server_id`, nor the member credentials against CRDT membership, nor who sent it (`peer_str` is unused), nor that we asked (no `mls_bootstrap_requested` check before `:11878`). The frame is a plaintext HavenMessage, so `peer_str` is relay-chosen.
  (a) Mallory = relay or any peer that can SendDirect to Alice: a syntactically valid base64 garbage `MlsWelcome{server_id: X}` makes Alice drop her server-X group (voice SFrame export and channel decrypt stop until re-bootstrap; the removal persists at the next MLS persist). CONFIRMED-BY-READING.
  (b) Mallory = relay that captured one of Alice's KeyPackages (sent plaintext, `node/swarm.rs:10931-10936` `HavenMessage::MlsKeyPackage` via `send_raw_to_identity`, which is a raw `SendDirect`, `node/crypto_handler.rs:3306-3328`), or a malicious member acting as coordinator: build a private group with that KeyPackage and Welcome Alice into it under `server_id = X`. Alice replaces her group, emits `MlsEpochChanged` from the attacker group (`node/swarm.rs:11928-11931`) and her voice SFrame key and outgoing MLS channel traffic for X are now under a key the attacker knows. PLAUSIBLE (Hollow-side gates CONFIRMED absent; OpenMLS KeyPackage single-use and race timing not exercised). Overlaps the MLS area.

---

## SUSPICIONS (summary)

- S-01 node/swarm.rs:6728-6729, :6799 (X-1, HOL-SEC-003): relay opens an Olm session as a friend's device and rings with its own SFrame key via CallSignal. CONFIRMED-BY-READING (Rust path).
- S-02 lib/src/core/providers/call_provider.dart:1929-2275 (call_id-only binding, no peerId compare) + :2405 (`Random()` call_id): an Olm peer knowing the call_id can end, answer or re-point another person's call. PLAUSIBLE.
- S-03 node/voice_handler.rs:398-402 + call_provider.dart:1789: only the blocklist gates ringing; no relationship gate. PLAUSIBLE (policy).
- S-04 node/swarm.rs:14041-14066 and node/voice_handler.rs:1487-1527: no `can_see_channel` on inbound VC join; a non-qualifying member becomes a participant and gets dialed. CONFIRMED-BY-READING.
- S-05 node/voice_handler.rs:1488 (+ X-3, no sid-to-group binding in node/swarm.rs:10884-11545): MLS VoiceChannelJoin for `conf:*` from any shared MLS group bypasses conference admission for roster/dial. PLAUSIBLE.
- S-06 node/swarm.rs:14034-14076: relay-forged plaintext VC joins for any member device. PLAUSIBLE, low.
- S-07 node/swarm.rs:14079-14094: relay-forged plaintext VC leave tears down a live P2P leg. PLAUSIBLE, low.
- S-08 node/swarm.rs:14102-14164: relay-forged plaintext deafen/mute/recording state. PLAUSIBLE, low.
- S-09 node/voice_handler.rs:1240, :1894, :1934: origin guard also admits origin == receiver on assign/feed_state, contrary to its stated contract; safe only via Dart consent (voice_channel_provider.dart:3196). hardening.
- S-10 node/swarm.rs:13813-13826 + lib/src/core/services/webrtc_service.dart:914-918: plaintext Rtc* and conn_id-only answer matching let the relay MITM data channels. CONFIRMED-BY-READING (signaling).
- S-11 forwarder/signaling.rs:376-383, :427 (X-1 at the forwarder): relay impersonates a sharer to unregister or re-allowlist its stream. PLAUSIBLE, low.
- S-12 node/swarm.rs:4532-4536 + voice_channel_provider.dart:3223-3230: relay-chosen forwarder id is the Always-relay allowlist. PLAUSIBLE, low.
- S-13 node/swarm.rs:11873-11878 (+ crypto/mls_manager.rs:469-496): MlsWelcome removes the live group before verifying and adopts any Welcome built on our KeyPackage; forced group drop CONFIRMED, key substitution PLAUSIBLE.
- Parity note (not a suspicion by itself): Olm VC SDP/ICE arms lack `vc_rate_check` (only at node/swarm.rs:11365).
