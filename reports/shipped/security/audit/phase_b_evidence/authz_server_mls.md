# Authz matrix evidence: SERVER LIFECYCLE, MLS GROUPS, CONFERENCES

Scope: rust/hollow_core/src (swarm.rs, sync_handler.rs, crypto_handler.rs, conference.rs,
fetch.rs, crypto/mls_manager.rs, crdt/server_state.rs) plus the Dart consumer of the
conference events (lib/src/core/providers/conference_provider.dart) where Rust delegates
the check to Dart. OpenMLS 0.9.0 source read from
D:/dev/cargo/registry/src/index.crates.io-1949cf8c6b5b557f/openmls-0.9.0 (Cargo.toml:49
`openmls = "0.9"`). All paths below are relative to rust/hollow_core/src unless stated.
node/test_harness.rs was being modified by another session while I read it, so harness
line numbers may drift; test NAMES are the stable reference.

## Common facts used by every section

- F1. Principal of every plaintext HavenMessage = relay-stamped `from`.
  `node/ws_client.rs:515-547` builds `WsEvent::Message/DirectMessage { room, from, data }`
  from the relay frame (`0x05`, `0x06`, and topic `0x08`: `let from = String::from_utf8_lossy(&after_topic[..sender_end])`).
  `node/swarm.rs:4560` `WsEvent::Message { room, from, data } | WsEvent::DirectMessage { room, from, data } =>`
  parses and hands `&from` as `peer_str` to `handle_incoming_request` (`swarm.rs:4920` `&local_peer_str, &from, is_invisible,`).
  The only pre-dispatch filter is a per-`from` token bucket (`swarm.rs:4576-4596`,
  `RATE_LIMIT_BURST: u32 = 100` at `swarm.rs:1167`). `room` is never used to gate.
  Topic-ring replays (the `~join` ring) arrive through the same arm (0x08 -> WsEvent::Message).
- F2. `local_peer_str` inside `handle_incoming_request` is the MASTER:
  `swarm.rs:566-570` "`local_peer_str` and `bundle_keypair` are the MASTER ... `device_peer_id` is THIS device's transport id"; `let master_peer_str = local_peer_str.clone();`.
- F3. `get_role`/`is_member`/`is_banned` collapse device->master through the resolver:
  `crdt/server_state.rs:1091` `let key = super::resolve_identity(peer_id);` (get_role),
  `:1272` (is_banned), `:1290` (is_member). `node/resolver.rs:34-39` unknown id resolves to itself; `:43-45` `a == b || resolve(a) == resolve(b)`.
- F4. None of the in-scope HavenMessage variants carries a signature field:
  `node/types.rs:1464-1496` ServerJoinRequest, `:1499-1511` ServerJoinRejected,
  `:1520-1539` ServerJoinResolved, `:1542-1544` ServerDeleteBroadcast,
  `:1548-1550` MemberKickBroadcast, `:1618-1696` Mls*, `:1705-1749` Conference*;
  MessageEnvelope `:3221-3223` ServerDelete `{ sid }`, `:3227-3229` MemberKick `{ sid }`.
  Authority for every one of them = the transport sender (F1) or, inside MLS, the leaf credential (F5).
- F5. MLS leaf credential is an UNBOUND string. `crypto/mls_manager.rs:88`
  `let signer = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm())` (fresh random MLS key,
  not the device Ed25519 key) and `:95` `let credential = BasicCredential::new(peer_id.as_bytes().to_vec());`.
  Sender of an MLS app message = that string: `mls_manager.rs:550-553`
  `let sender_credential = processed.credential(); let sender_peer_id = String::from_utf8_lossy(sender_credential.serialized_content())`.
  No credential-validation hook exists anywhere in hollow_core: grep for
  `add_proposals|remove_proposals|queued_proposals|StagedCommit|staged_commit|update_proposals|validate_credential|CredentialValidat|unverified_credential|new_from_welcome|StagedWelcome|group_id()`
  hits only `mls_manager.rs:262` (read-only identity extraction), `:484` (Welcome), `:562`, `:592-594` (merge). OpenMLS 0.9 has no application credential callback
  (grep `CredentialValidat|validate_credential|AuthenticationService` in openmls-0.9.0/src: no hits) and its Add validation checks
  key uniqueness only, not identity: openmls-0.9.0/src/group/public_group/validation.rs:184-187
  "ValSem101: ... Signature public key ... unique", "ValSem103: ... Encryption key ... unique". => RFC 9420 s5.3.1 credential validation at
  Add / Welcome / Update / Commit: **NONE FOUND**.
- F6. Honest server ids are 32 hex chars: `node/sync_handler.rs:613-617` `let server_id = hex::encode(&{ let mut buf = [0u8; 16]; getrandom::fill(&mut buf)`.
  Conference sids: `node/conference.rs:32` `CONF_SID_PREFIX: &str = "conf:"`, `:41-43` `sid.starts_with(CONF_SID_PREFIX)`.

---

### A-01 HavenMessage::ServerJoinRequest  (admits a joiner: MemberAdded op, snapshot + full op log, optional MLS leaf)

- Dispatch sites:
  - plaintext live unicast (0x06) and room broadcast: `swarm.rs:9879` arm.
  - relay topic `~join` ring (parked copy, 0x08 -> WsEvent::Message): same arm; written by `sync_handler.rs:1161-1183` `SendToRoomTopic { ... topic: super::types::JOIN_TOPIC`.
  - Olm / MLS / fetch.rs / WebRTC gossip: none (no MessageEnvelope twin; fetch.rs handles only MlsChannelMessage/PublicChannelMessage/Encrypted: `fetch.rs:470,545,717`; gossip only feeds CrdtOpBroadcast `swarm.rs:2966`).
- Handler: inline arm `swarm.rs:9879-10347`.
- Target object: `server_id` (server), the joiner = `member_master` derived from `device_list.master_peer_id` or `resolve(peer_str)`; leaf = `key_package` credential.
- State changes, in order:
  1. `swarm.rs:9920-9924` `crypto_handler::ingest_device_list(... peer_str, ... device_list.clone(), ...)` (resolver/device-store writes, gated inside ingest: `crypto_handler.rs:1309` verify, `:1323-1331` binds-sender, `:1384` `super::resolver::update(sender_peer_id, &list.master_peer_id)`).
  2. `swarm.rs:9992` `join_request_seen.insert(seen_key, std::time::Instant::now());` (RAM, live only).
  3. rejection paths: `join_resolutions.insert(...)` (`:10019`, `:10061`, `:10087`, `:10115`, `:10146`) + `send_join_rejection` (targeted `ServerJoinRejected` + ring `ServerJoinResolved`, `sync_handler.rs:1343-1356`).
  4. admit: `swarm.rs:10159-10163` `let op = state.create_op(CrdtPayload::MemberAdded { peer_id: member_master.clone(), display_name }); let _ = state.apply_op(&op);` -> op AUTHORED BY THE LOCAL MASTER (`crdt/server_state.rs:495` `author: hlc.actor().to_string()`, `:503` `op.sign(&signer.keypair, &signer.pk_b64)`).
  5. `swarm.rs:10171-10174` `MessageStore::open` + `save_server_state` + `insert_crdt_op`.
  6. `swarm.rs:10188-10193` MLS broadcast of `MessageEnvelope::CrdtOp`; `:10194-10206` plaintext `CrdtOpBroadcast` to every room peer.
  7. `swarm.rs:10209` `NetworkEvent::MemberJoined`; `:10217-10224` `PeerDiscovered`.
  8. parked only: `:10256-10262` owner may `create_group(&server_id)`; `:10271-10274` `pending_mls_key_packages.entry(server_id.clone()).or_default().push((peer_str.to_string(), kp_bytes));` -> batch timer adds the leaf and sends the Welcome (`swarm.rs:5058`, `:5079-5108`).
  9. `swarm.rs:10301-10307` `ServerStateSnapshot` and `:10314-10320` `SyncResponse` with ALL ops, both PLAINTEXT via `send_message_to_peer_in_room` (`crypto_handler.rs:2821-2832`, JSON into `SendDirect`).
  10. `swarm.rs:10327-10333` `join_resolutions.insert` + `publish_join_resolution(... true, "", admitted_op_json)`.
  11. `swarm.rs:10338-10344` KeyRequest to `peer_str`.
- Checks before the FIRST state change, in order:
  1. `swarm.rs:9885` `if !server_states.contains_key(&server_id) {` -> nothing (server we hold).
  2. device list, when present: `:9905` `if !crypto_handler::verify_device_list(list)` (signer key -> claimed master, `crypto_handler.rs:778-793`); `:9907` `!list.devices.iter().any(|d| d == peer_str)` (sender DEVICE named); `:9909` `list.revoked.iter().any(|r| r == peer_str)`. Principal: relay-stamped sender device vs the CARRIED list only (no comparison with the stored list's version).
  3. absent list: `:9930` `None => super::resolver::resolve(&peer_str),` (resolver, no check).
  Then (after ingest, i.e. after state change 1):
  4. `:9938` `is_sibling = same_identity(peer_str, local_peer_str) && peer_str != local_peer_str` (resolver).
  5. parked: `:9954` `if already_member { return; }`; `:9961` `join_resolutions.get(&resolution_key).is_some_and(|t| *t >= requested_at)`.
     live: coordinator election `:10001-10009` (`elect_server_coordinator`, owner preferred, `crypto_handler.rs:2112-2126`), bypassed by a repeat within 12 s (`:9984-9986`, `JOIN_SERVE_RETRY_WINDOW` = 12 s at `swarm.rs:22`) or a sibling (`:9993`).
  6. `:10016` `if !is_sibling && state.is_banned(&member_master)` (MASTER).
  7. `:10032-10038` Twitch: `twitch::validate_follow_credential(entry_json, &member_master, &twitch_settings)`.
  8. `:10072-10096` owner-verify: `if oid != local_peer_str {` non-owner nodes refuse/return.
  9. `!already_member` only: `:10111` private, `:10129` NSFW, `:10141-10142` member cap.
  10. parked leaf only: `:10244` `Ok(id) if id != peer_str =>` drop the KeyPackage (credential string must equal the RELAY-STAMPED device).
- WHO ADMITS: any CRDT member node that wins the local election, not only Owner/Admin. The local node never checks its own role before `create_op(MemberAdded)`. Ingest by other members accepts it from any member author: `crdt/server_state.rs:1335-1339` `CrdtPayload::MemberAdded { .. } => { ... self.is_member(&op.author) }`, and `apply_op` MemberAdded (`:721-738`) inserts without a ban/private/cap check. Parked requests skip the election entirely (every member that reads the ring serves it unless resolved).
- Who can sign: unsigned request (F4). The carried `SignedDeviceList` is master-signed over `"hollow-devices:{master_peer_id}:{version}:{devices}:{revoked}"` (`crypto_handler.rs:733`), but it is a public, replayable object; nothing binds it to THIS request or this server.
- Binding (sender -> joiner identity): `swarm.rs:9907` sender device must be listed in the carried list. Binding (request -> server) : NONE FOUND (unsigned `server_id`). Binding (admitter authority -> admission): NONE FOUND beyond `is_member(op.author)`.
- Transport parity: one arm serves live and ring copies; differences are intentional (`parked` skips election, `already_member` early return, KP only on parked).
- Freshness / replay: `requested_at` nonce + `join_resolutions` (RAM `HashMap`, lost on restart: parameter `join_resolutions: &mut HashMap<String, i64>` `swarm.rs:6453`), `already_member`. Live copies have no replay guard (join_request_seen is a 12 s election bypass, not a guard). Survives restart: NO (the ring's own resolution frames re-teach it only if the ring still holds them).
- Absent fields: `device_list` None -> resolver fallback, accepted as legacy (`:9927-9930`; exercised as ACCEPT by test `parked_join_with_a_bad_carried_device_list_is_dropped`, which injects a no-list parked request from an arbitrary `legacy_device` and asserts it IS admitted). `requested_at` 0 -> no resolution recorded or published (`:10018`, `:10326`). `key_package` None -> no leaf. `twitch_proof_json` None -> `twitch_required` rejection. `nsfw_confirmed` false -> consent round-trip.
- Blast radius: MemberAdded propagates to every member (CRDT + ring resolution). Reversible only by a kick/ban op.
- Tests (rejections): `parked_join_with_a_bad_carried_device_list_is_dropped` (tampered list), `parked_join_rejection_reaches_an_offline_joiner` (reason "banned"), `nsfw_server_gates_join_until_confirmed`, `parked_nsfw_join_asks_for_consent_once_then_completes`, `twitch_follow_gate_accepts_bucket_and_refuses_the_rest`, `late_member_does_not_reserve_a_parked_join`, `op_allowed_ingest_matrix` (crdt/server_state.rs, "stranger MemberAdded" false). Private-server, server-full and owner-verify rejections: none found (grep `server_private`, `server_full`, `twitch_owner_offline` in test_harness.rs: 0 hits).
- SUSPICION S-01 (CONFIRMED-BY-READING): relay-forged joins. The request is unsigned and the relay controls `from`; signed device lists are public. Mallory = relay injects `ServerJoinRequest { server_id: S, device_list: Some(alice_public_list) }` with `from = alice_device` into any public server's room (S is the room code, so the relay knows it). The coordinator admits Alice's MASTER (`:9925`, `:10159`) against her will and replicates it. Same for re-adding someone who left. (Test above proves a list-less injected frame from an arbitrary id is admitted.)
- SUSPICION S-02 (CONFIRMED-BY-READING): member-authored MemberAdded bypasses ban, private and cap. The gates at `:10016`, `:10111`, `:10141` exist only in this handler; ingest `server_state.rs:1335-1339` and `apply_op` `:721-738` do not repeat them. Mallory = plain member of PRIVATE server P broadcasts her own signed `CrdtOpBroadcast{MemberAdded{peer_id: eve_or_banned_bob}}`; every member admits it; Eve/Bob then pass the MlsKeyPackage gate (`swarm.rs:11695-11696`, membership only, no ban check) and get a leaf.
- SUSPICION S-03 (CONFIRMED-BY-READING): the parked-leaf identity check compares the KeyPackage credential with the relay-stamped `peer_str` (`:10244`), which the relay chooses, and the credential is an unbound string (F5). Relay forges `{parked: true, device_list: victim_list, key_package: relay_made_kp_with_credential=victim_device}` from `victim_device` for a non-member victim: it passes, the relay's leaf is queued (`:10271-10274`), the Welcome is buffered to `victim_device` in the room (`swarm.rs:5091-5107`) and read by the relay, which then decrypts the server group.
- SUSPICION S-04 (CONFIRMED-BY-READING, low): any request from a member identity is answered with the server's full CRDT state and op log in PLAINTEXT (`:10300-10321`), including for a PRIVATE server (the private gate only covers `!already_member`, `:10107-10111`). A relay spoofing a member device gets the whole state on demand.
- Observation (not scored): the carried list is not compared with the stored list's version, so a pre-revocation list still attributes a revoked device to its master at `:9903-9926`; `crypto_handler.rs:819-823` states every device holds the master key, which already defeats this for a revoked sibling.

### A-02 HavenMessage::ServerJoinResolved  (ring answer: stops re-serving; carries the MemberAdded op; resolves the joiner's own parked ask)

- Dispatch sites: plaintext only, `swarm.rs:10352`; normally read from the `~join` ring (published by `sync_handler.rs:1195-1218`).
- Handler: inline `swarm.rs:10352-10419`.
- Target object: `server_id`, `joiner_master`, `requested_at`; `op_json`.
- State changes: joiner side `:10374-10377` `sync_handler::handle_join_refused(...)` -> `sync_handler.rs:1276` `pending_server_joins.remove`, `:1277-1279` `LeaveRoom`, `:1290` / `:1308` pending-join row delete / upsert "rejected", `:1294-1322` events `PendingJoinUpdated`/`TwitchJoinRejected`, `:1303`/`:1323` discard KeyPackage. Member side `:10402-10404` `join_resolutions.insert(key, requested_at)` (max-wins), `:10409-10417` `apply_remote_crdt_op(...)`.
- Checks before first state change:
  - Joiner side: `:10360-10361` `if let Some(pending) = pending_server_joins.get(&server_id) { if joiner_master == local_peer_str && requested_at == pending.requested_at {` then `if admitted { return; }`. NO sender check at all (the membership gate below runs after this branch).
  - Member side: `:10385` server held; `:10388-10396` `let sender_master = super::resolver::resolve(&peer_str); ... any(|m| same_identity(&m.peer_id, &sender_master))` (relay-stamped sender resolved to master must be a CRDT member). No role check.
  - `op_json`: `apply_remote_crdt_op` -> `swarm.rs:6162` `state.admit_remote_op(&op)` (author signature + `op_allowed` on `op.author`).
- Who can sign: unsigned (F4); the embedded op is author-signed (`crdt/operations.rs:102-120`).
- Binding: sender membership only (`:10393`). Binding of `joiner_master`/`requested_at` to anything the sender is entitled to answer: NONE FOUND.
- Transport parity: single site.
- Freshness: member side max-wins on the wire `requested_at` (RAM). Joiner side exact nonce match.
- Absent fields: every field `#[serde(default)]` (`types.rs:1521-1538`); `server_id` "" falls through both branches; `op_json` None -> map update only.
- Blast radius: joiner-side refusal is local (user can ask again); member-side map poisoning is RAM, re-armed on every restart while the frame sits in the 3-day ring.
- Tests: `discarded_parked_join_ignores_a_late_answer`, `late_member_does_not_reserve_a_parked_join` (positive dedup). No test of a forged resolution.
- SUSPICION S-05 (CONFIRMED-BY-READING): any room member, or the relay, can refuse a parked join. The nonce is readable in the parked ring copy (`sync_handler.rs:1166-1170`). Mallory publishes `ServerJoinResolved{joiner_master: alice, requested_at: <from ring>, admitted: false, reason: "anything"}`; Alice's branch at `:10361` runs before any membership gate. The code comment at `:10370-10373` acknowledges "a hostile member could write one".
- SUSPICION S-06 (CONFIRMED-BY-READING): a member can freeze a joiner's parked admissions. `requested_at: i64::MAX` with `joiner_master: victim` passes `:10393` and `:10402`; every later parked request from the victim is skipped at `swarm.rs:9961` (`*t >= requested_at`) on every member that read the ring, until restart, and again after restart from the ring.

### A-03 HavenMessage::ServerJoinRejected  (refuses our pending join)

- Dispatch sites: plaintext targeted, relay-buffered (`sync_handler.rs:1343-1350`), arm `swarm.rs:10421`.
- Handler: inline `:10421-10439` -> `sync_handler::handle_join_refused` (state changes as A-02 joiner side).
- Checks: `:10426` `let Some(pending) = pending_server_joins.get(&server_id) else { return };` and `:10431` `if requested_at != 0 && requested_at != pending.requested_at {` return. No sender check of any kind.
- Who can sign: unsigned. Binding sender -> "entitled to refuse": NONE FOUND.
- Freshness: nonce equality, but `requested_at == 0` skips it (`types.rs:1508` "0 = a pre-nonce client: refuse whatever is pending").
- Absent fields: `requested_at` default 0 -> accepted as legacy, refuses whatever is pending.
- Blast radius: local, the join ask is dropped; user must re-ask.
- Tests: `parked_join_rejection_reaches_an_offline_joiner` (positive). No forged-rejection test.
- SUSPICION S-07 (CONFIRMED-BY-READING, low): any peer sharing a room with the joiner, or the relay, cancels any pending join with `ServerJoinRejected{server_id, reason, requested_at: 0}`; no nonce knowledge needed.

### A-04 HavenMessage::ServerDeleteBroadcast  (legacy owner delete -> local tombstone)

- Dispatch sites: plaintext only, `swarm.rs:10440`. Current senders use the CRDT `ServerDeleted` op; the only producer of this variant in src is none (grep `ServerDeleteBroadcast` hits only types.rs and this arm).
- Handler: inline `:10440-10482`.
- Target object: `server_id`.
- State changes: `:10465-10466` `let op = state.create_op(CrdtPayload::ServerDeleted { deleted_at: now_ms }); let _ = state.apply_op(&op);` (op AUTHORED AND SIGNED BY THE RECEIVER's master, `server_state.rs:495`, `:503`; apply latches `deleted` and clears members/roles/channels `server_state.rs:671-678`); `:10467-10471` `insert_crdt_op` + `save_server_state`; `:10473-10475` `mls_mgr.remove_group(&server_id)`; `:10477` `NetworkEvent::ServerDeleted`.
- Checks: `:10445-10450` `let sender_role = state.get_role(&peer_str); if sender_role != ...Owner { return; }` (relay-stamped sender DEVICE resolved to master, F3). `:10460` `if !state.is_deleted()`.
- Who can sign: unsigned (authority = transport sender).
- Binding: `:10446-10447` role of `peer_str` in the named server. That is the only binding.
- Transport parity: MLS twin A-05 checks the leaf credential instead; Olm twin ignored (`swarm.rs:9149`, `:9162`).
- Freshness: none; idempotent via `is_deleted`.
- Absent fields: none.
- Blast radius: IRREVERSIBLE locally (no un-delete path: the only writes of `deleted` are `server_state.rs:671` set). If the receiving device belongs to the OWNER, the synthesized op is a valid Owner-authored, Owner-signed `ServerDeleted` (`op_allowed` `server_state.rs:1427` `ServerDeleted { .. } => sender_role == MemberRole::Owner`), sits in the op log, and is served to anyone by the plaintext SyncRequest responder (`swarm.rs:9461-9473`, delta from `op_log`, no requester check), so it propagates.
- Tests: none found for this arm (grep test_harness.rs: 0 hits).
- SUSPICION S-08 (CONFIRMED-BY-READING for the local tombstone; PLAUSIBLE for network propagation): hostile relay deletes any server. Mallory = relay sends `ServerDeleteBroadcast{server_id: S}` to every member with `from` = the owner's master id or any owner device id (public in device lists). `get_role` resolves to Owner (F3), each member tombstones S locally. Delivered to the owner's own device, the tombstone it mints is a genuine owner op and replicates to everyone via sync.

### A-05 MessageEnvelope::ServerDelete  (MLS twin of A-04)

- Dispatch sites: MLS arm `swarm.rs:11154-11161`; Olm arm ignores it (`swarm.rs:9149` `Ok(MessageEnvelope::ServerDelete { .. })` -> `:9162` "ignoring"); fetch.rs: not handled (`fetch.rs:491-542` only ChannelMessage).
- Handler: `sync_handler::handle_envelope_server_delete` `sync_handler.rs:3103-3142`.
- Target object: envelope `sid` (NOT the group the frame was decrypted under).
- State changes: `:3129-3132` create_op/apply/`crdt_store.insert_op`/`save_state_snapshot`; `:3133-3136` remove_group; `:3137` `ServerDeleted` event.
- Checks: `sync_handler.rs:3113-3116` `server_states.get(&sid).map(|s| s.get_role(sender_peer_id)) ... if sender_role != Owner { return; }` where `sender_peer_id` = `&sender_master` = `resolver::resolve(<MLS leaf credential>)` (`swarm.rs:10984`, `:11158`). `:3124` `if !state.is_deleted()`.
- Who can sign: unsigned; authority = MLS leaf credential (F5).
- Binding: role of the leaf credential in `sid`. Binding of `sid` to the MLS group the message came from: NONE FOUND (`swarm.rs:11154` passes the envelope's `sid`; `server_id`/`group_key` of the frame are not compared).
- Transport parity: A-04 uses relay `from`, A-05 uses leaf credential; Olm path dead.
- Freshness: MLS generation reuse drop (`mls_manager.rs:544-546` -> `Ok(None)`), otherwise none.
- Blast radius: as A-04.
- Tests: none found.
- SUSPICION S-09 (CONFIRMED-BY-READING local, PLAUSIBLE propagation): member -> Owner impersonation over MLS. Any member Mallory gets a leaf whose credential string is the owner's master id (see S-12), then sends an MLS app message `ServerDelete{sid: S}`; every member attributes it to the owner (F5, `swarm.rs:10984`) and tombstones S.
- SUSPICION S-10 (CONFIRMED-BY-READING): cross-group confusion, stranger level. Because `sid` is not bound to the decrypting group, a CONFERENCE host (or any conference participant when the waiting room is off) can do S-09 from inside a `conf:{id}` group the victim joined: the host adds a second leaf credentialed as S's owner (`conference.rs:367` `add_member` with any KeyPackage; no credential check `mls_manager.rs:304-313`), sends `MlsChannelMessage{server_id: "conf:X"}` containing `ServerDelete{sid: S}`; the victim decrypts under `conf:X` (`swarm.rs:10888-10891`, `:10955`) and runs `handle_envelope_server_delete` for S.

### A-06 HavenMessage::MemberKickBroadcast  (tells the kicked member to drop the server)

- Dispatch sites: plaintext only `swarm.rs:10484`. Produced by `sync_handler.rs:1612-1618` (kick) and `:1877` (ban).
- Handler: inline `:10484-10523`.
- Target object: implicit = the receiver itself in `server_id` (the message names no member).
- State changes: `:10509` `server_states.remove(&server_id)`; `:10510-10511` `MessageStore::open` + `delete_server_state`; `:10514-10516` remove server MLS group; `:10519` `ServerDeleted` event. (Not done here, unlike the CRDT self-eviction path `swarm.rs:6363-6387`: subgroup groups are not removed and no `LeaveRoom` is sent.)
- Checks: `:10490-10502` `sender_perms = state.get_permissions(&peer_str)`, `(sender_perms & KICK_MEMBERS) == 0` -> reject; `!sender_role.outranks(&our_role)` -> reject. Principal: relay-stamped sender device -> master.
- Who can sign: unsigned.
- Binding: sender's KICK permission and rank in `server_id`. Binding to an actual `MemberRemoved` of us: NONE FOUND (a moderator can make a member drop the server with no CRDT record; the others still list the victim).
- Transport parity: the kicker ALSO sends an Olm-encrypted `MessageEnvelope::MemberKick` (`sync_handler.rs:1610` `let envelope = MessageEnvelope::MemberKick { sid: server_id.clone() };`, `:1616` `send_encrypted_message(...)`) but the Olm receiver IGNORES it (`swarm.rs:9150`, `:9162`). The only live kick signal is this unauthenticated plaintext one.
- Freshness / replay: NONE FOUND; a replayed kick after rejoin kicks again.
- Blast radius: local; server state row deleted; user can rejoin.
- Tests: none found for this arm.
- SUSPICION S-11 (CONFIRMED-BY-READING, medium): relay forges `MemberKickBroadcast{server_id}` with `from` = any Admin/Moderator/Owner device; every lower-ranked member deletes its local server state. Also a legitimate moderator can "silently kick" without a MemberRemoved op.

### A-07 MessageEnvelope::MemberKick  (MLS twin of A-06)

- Dispatch sites: MLS `swarm.rs:11163-11170`; Olm ignored (`:9150`).
- Handler: `sync_handler.rs:3146-3179`.
- Checks: `:3157-3164` `get_role(sender_peer_id)`, `get_role(local_peer)`, `get_permissions(sender_peer_id)`; KICK bit and `outranks`. Principal: leaf credential -> master (`swarm.rs:11167` `&sender_master`).
- State changes: `:3169` `server_states.remove(&sid)`, `:3170` `crdt_store.delete_server`, `:3171-3174` remove group, `:3175` event.
- Binding: `sid` not bound to the decrypting group (as A-05). NONE FOUND.
- Freshness: MLS generation only.
- Tests: none found.
- SUSPICION: same as S-09/S-10 with kick semantics (credential forged as the owner kicks anyone locally).

### A-08 HavenMessage::MlsKeyPackage  (ask the coordinator for a leaf in a server group or subgroup)

- Dispatch sites: plaintext only `swarm.rs:11679`.
- Handler: inline `:11679-11856`, then MLS batch timer `swarm.rs:4944-5150`.
- Target object: `server_id` (+ `channel_id` -> `group_key` `:11682-11685`); the leaf = the KeyPackage's own credential.
- State changes: `:11808` `mls_mgr.create_group(&group_key)` (lazy); `:11831` `pending_mls_removals...push(stale_peer.clone())` (stale sweep); `:11841` queue removal of the SENDER device's existing leaf; `:11850-11853` `pending_mls_key_packages.entry(group_key.clone()).or_default().push((peer_str.to_string(), kp_bytes));`. Timer: `swarm.rs:5007` removals commit + broadcast; `:5058` `mls_mgr.add_members_batch(&group_key, &queued)`; `:5079-5108` Welcome to `peer_id_str` (= the relay-stamped sender), buffered in the room when absent; `:5117-5120` commit broadcast.
- Checks before first state change:
  1. `:11694-11700` `let is_member = state.members.keys().any(|k| super::resolver::same_identity(peer_str, k)); if !is_member { return; }` (relay-stamped sender device -> master must be a CRDT member). No ban check.
  2. subgroup: `:11701-11706` `state.can_see_channel(&sender_master, cid)` with `sender_master = resolve(peer_str)`.
  3. `:11719-11734` sibling fast path (resolver: `same_identity(peer_str, local_peer_str)`), else coordinator election `:11743-11801` (owner preferred; no group + not owner -> return `:11796-11799`).
  4. Inside `add_members_batch`: `mls_manager.rs:340` `if existing_members.contains(peer_id)` (compares the QUEUED sender id, not the KP credential) and `:347` `kp_in.validate(self.provider.crypto(), ProtocolVersion::Mls10)` (self-signature under the KP's own key).
  The KP's credential identity is never compared with `peer_str`, never checked to resolve to a CRDT member, and never checked against a signed device list (F5).
- Who can sign: unsigned frame; the KeyPackage is self-signed by an unbound MLS key.
- Binding (leaf credential -> sender -> member): NONE FOUND for the credential; sender membership only via resolver.
- Transport parity: the parked-join path (A-01) does check `key_package_identity == peer_str` (`swarm.rs:10244`); this path does not.
- Freshness: none (each frame queues a KP; dedup per sender id per batch `swarm.rs:5049-5052`).
- Absent fields: `channel_id` None -> server group.
- Blast radius: adds a leaf that can decrypt all future group traffic until removed; the stale sweep (`:11818-11833`) keeps any leaf whose credential resolves to a member identity.
- Tests: `three_member_live_join_lands_at_minimal_epoch` (positive; it also shows an INJECTED `MlsKeyPackageRequest` from the owner's device id triggering a full remove + re-add). Non-member rejection (`L6`): none found.
- SUSPICION S-12 (CONFIRMED-BY-READING, critical): hostile relay obtains a leaf in any server group, private ones included. Mallory = relay sends `MlsKeyPackage{server_id: S, key_package: relay_kp}` to the owner device with `from` = any member device (ideally one without a leaf, else it also evicts that device via `:11839-11842`), with the relay's KP credentialed as that member's MASTER id so the stale sweep keeps it. The owner queues it, commits the add and Welcomes `from` via the relay (`swarm.rs:5091-5107`); the relay joins and decrypts every MLS channel message, file header (AES keys) and the voice SFrame export for S.
- SUSPICION S-13 (CONFIRMED-BY-READING, critical): any member gets a leaf credentialed as ANY identity (owner master included) by sending its own KP with a chosen credential; attribution of every unsigned MLS envelope then follows the forged credential (feeds S-09, S-10).
- SUSPICION S-14 (CONFIRMED-BY-READING): no ban check here, so a banned-but-(re)added identity (S-02) gets a leaf.

### A-09 HavenMessage::MlsWelcome  (join a group)

- Dispatch sites: plaintext only `swarm.rs:11858`.
- Handler: inline `:11858-11980`; `mls_manager.rs:469-497` `join_from_welcome`.
- Target object: `group_key` = `server_id` or `subgroup_id(server_id, channel_id)` from the wire (`:11859-11862`).
- State changes, in order: `:11873-11876` `if mls_mgr.has_group(&group_key) { mls_mgr.remove_group(&group_key); }` (BEFORE validating the Welcome); `:11878` `join_from_welcome(&group_key, &welcome_bytes)` which inserts under the WIRE key (`mls_manager.rs:495` `self.groups.insert(server_id.to_string(), group);`); `:11880` persist; `:11881-11885` clear bootstrap/grace/failure maps; `:11891-11896` parked join -> `PendingJoinUpdated "ready"`; `:11916-11921` `conf:` -> `NetworkEvent::ConferenceAdmitted` (Dart takes a seat, `conference_provider.dart:570-576`, no host check); `:11926-11931` `MlsEpochChanged` with `export_secret("sframe")` of the NEW group (voice keys); `:11938-11970` SyncRequest and channel sync requests to `peer_str`.
- Checks: NONE. No sender check, no "did we ask" (`pending_server_joins`, `mls_bootstrap_requested`, `awaiting_mls_after_parked_join` are cleared, not consulted), no membership of `server_id`, no subgroup qualification, no comparison of the Welcome's GroupId with `group_key` (`mls_manager.rs:484-492` `StagedWelcome::new_from_welcome(&self.provider, &config, welcome, None)` -> `into_group`), no credential validation of the tree's leaves (F5). OpenMLS only requires that the Welcome be encrypted to a KeyPackage whose private half we hold.
- Who can sign: unsigned frame; Welcome authenticity = whoever built a group containing one of our KeyPackages.
- Binding (group -> server we asked to join): NONE FOUND. Can ANY member, or the relay, make us join a group: YES, given one of our KeyPackages, and those are handed out on request to anyone (A-13), broadcast in plaintext in conference knocks (`conference.rs:257-264`), and ride plaintext `MlsKeyPackage` frames the relay sees.
- Transport parity: single site.
- Freshness: KeyPackage private half is consumed on success, so a replay fails, BUT the existing group was already removed at `:11875`.
- Absent fields: `channel_id` None -> server group.
- Blast radius: replaces our group for that key (runtime; persisted state is reloaded by `GroupId::from_slice(server_id)` at `mls_manager.rs:146`, so an attacker who sets the GroupId to the server id also survives restart).
- Tests: none found for rejection.
- SUSPICION S-15 (CONFIRMED-BY-READING): state change before check. Any peer or the relay sends `MlsWelcome{server_id: S, welcome: <garbage or a replay of our own old Welcome>}`: `:11875` drops our live group, `:11878` fails, we re-bootstrap (epoch churn for everyone). For a `conf:` group there is no re-bootstrap (`crypto_handler.rs:3024` looks up `server_states`, which never holds `conf:` ids), so the participant is cut out of the meeting.
- SUSPICION S-16 (CONFIRMED-BY-READING for the Rust steps; PLAUSIBLE end-to-end): group substitution. Mallory (relay, or any peer that can reach Alice) asks Alice for a KeyPackage (A-13), builds her own group with GroupId = S and a leaf credentialed as S's owner, and Welcomes Alice as `server_id: S`. Alice now encrypts S traffic and derives S voice SFrame keys from Mallory's group (`:11926-11931`), and accepts Mallory's unsigned envelopes (ServerDelete, MemberKick, Typing, FileHeader...) as coming from the owner.
- SUSPICION S-17 (CONFIRMED-BY-READING Rust side): conference lobby hijack. A knocking joiner broadcasts its KeyPackage to the whole `conf:X` room (`conference.rs:257-264`); any other occupant Welcomes it into her own `conf:X` group first; Rust emits `ConferenceAdmitted` (`:11916-11921`) and the joiner's media keys come from the attacker's group.

### A-10 HavenMessage::MlsCommit  (apply a membership change)

- Dispatch sites: plaintext room broadcast `swarm.rs:11982` (sent by `crypto_handler.rs:2859-2888`).
- Handler: `crypto_handler::handle_mls_commit_frame` `crypto_handler.rs:2920-3057`; `mls_manager.rs:572-601` `process_commit`.
- Target object: `group_key` from wire `server_id`/`channel_id`; the commit's proposals.
- State changes: `mls_manager.rs:593-595` `merge_staged_commit` (any Add/Remove/Update the commit carries); `crypto_handler.rs:2965` persist; `:2972` cache commit; eviction `:2979-3000` remove group + stamp bootstrap throttle; `:3005-3010` `MlsEpochChanged`; FAILURE `:3019-3052` `mls_mgr.remove_group(&group_key)` + mint and send a KeyPackage to the owner/coordinator.
- Checks: `:2941` `if !mls_mgr.has_group(&group_key)`; `:2948-2954` epoch guard ONLY when the wire `epoch` is present (`wire_epoch.is_some_and(...)`); OpenMLS: committer must be a current leaf and the commit well-formed. Sender (`peer_str`) is only logged (`swarm.rs:11983`). Who may evict whom / who may add: NOT checked against CRDT roles or membership; the committer is not required to be the owner/coordinator; added leaves' credentials are not validated (F5). NONE FOUND.
- Who can sign: MLS commit is signed by the committer's leaf key (OpenMLS); unbound to identity (F5).
- Binding: NONE FOUND (proposal -> CRDT authority).
- Transport parity: catch-up path (A-12) has a sender membership gate; this path has none.
- Freshness: epoch guard only when `epoch` present; a stripped-`epoch` replay goes to `process_commit`, fails, and drops the group.
- Absent fields: `epoch` None (`types.rs:1657-1658` "Absent from legacy senders") -> no guard -> failure -> drop group.
- Blast radius: forced re-bootstrap (two epochs for the whole group) per victim per 60 s (`MLS_BOOTSTRAP_TIMEOUT` `swarm.rs:7`); for conferences permanent loss of the group.
- Tests: `stale_epoch_heal_probe_converges_via_commit_replay` etc. (positive). No rejection test.
- SUSPICION S-18 (CONFIRMED-BY-READING): unauthenticated group drop. Anyone who can reach the victim (relay, any room peer) sends `MlsCommit{server_id: S, commit: "AAAA", epoch: None}` (or replays a real old commit with `epoch` stripped): `process_commit` errors (`mls_manager.rs:580-589`) and `crypto_handler.rs:3021` removes the victim's group.
- SUSPICION S-19 (CONFIRMED-BY-READING): any leaf-holding member can commit Remove of any other leaves or Add of arbitrary-credential leaves; every receiver merges it (no role/membership check), e.g. a plain member evicting the owner's leaves or adding a leaf named as the owner.

### A-11 HavenMessage::MlsEpochProbe  ("am I behind?")

- Dispatch sites: plaintext `swarm.rs:12000`; the same handler also runs for `SyncRequest.mls_epoch` hints (`swarm.rs:9485-9491`, `direct_probe = false`).
- Handler: `crypto_handler::handle_epoch_hint` `crypto_handler.rs:3146-3251` with `direct_probe = true` (`swarm.rs:12011`).
- State changes: `:3207` cooldown stamp; `:3215-3222` send `MlsCommitCatchup`; or `:3230-3242` `pending_mls_removals.entry(group_key).push(leaf)` for EVERY leaf of `resolve(from_peer)` + send `MlsKeyPackageRequest` to `from_peer`; or `:3246-3249` send our own probe.
- Checks: `:3165` conference skip; `:3172` server held; `:3173` group held; `:3179` `state.members.keys().any(|m| same_identity(m, from_peer))` (relay-stamped sender -> master is a member); `:3204` cooldown 10 s per (group, master) (`EPOCH_HINT_COOLDOWN` `:3061`). Direct probe skips the responder election (`:3197`).
- Who can sign: unsigned.
- Binding: sender membership; the leaves evicted are those of the SENDER's resolved master (`:3231-3233`), so an honest relay limits a member to evicting itself.
- Freshness: cooldown only (RAM).
- Absent fields: `channel_id` None -> server group.
- Blast radius: target member evicted and re-added (2 epochs for all) every 10 s.
- Tests: `stale_epoch_heal_probe_converges_via_commit_replay`, `stale_epoch_vc_join_probe_converges_via_commit_replay`, `stale_epoch_first_contact_hint_converges_on_reconnect` (positive).
- SUSPICION S-20 (CONFIRMED-BY-READING, DoS): relay sends `MlsEpochProbe{server_id: S, epoch: 0}` to the owner with `from` = Bob's device; when the RAM commit cache cannot bridge (cap 8, `mls_manager.rs:76`; empty after restart), the owner queues all of Bob's leaves for removal (`:3230-3234`). Repeatable every 10 s per target.

### A-12 HavenMessage::MlsCommitCatchup  (replayed commits for a stale member)

- Dispatch sites: plaintext `swarm.rs:12016`.
- Handler: inline `:12016-12069` -> `handle_mls_commit_frame` per frame.
- Checks: `:12021-12027` sender (relay-stamped, resolved) is a CRDT member; `:12033` group held; `:12038-12039` sort + truncate 16; `:12046` each frame must be exactly `own + 1`.
- State changes: as A-10 per frame; failure drops the group (`crypto_handler.rs:3021`).
- Binding: membership of sender only; frames not bound to any authority beyond OpenMLS.
- Freshness: epoch chaining.
- Tests: the stale-epoch tests above (positive).
- SUSPICION S-21 (CONFIRMED-BY-READING): a member (or relay spoofing one) sends one garbage frame labelled `own+1`; `handle_mls_commit_frame` fails and drops the group (same primitive as S-18, with a membership gate that S-18 lacks).

### A-13 HavenMessage::MlsKeyPackageRequest  (make us mint and send a KeyPackage)

- Dispatch sites: plaintext `swarm.rs:12071`.
- Handler: inline `:12071-12107`.
- State changes: `:12092` `mint_key_package(mls_mgr, crypto_store)` -> `crypto_handler.rs:1912-1913` generate + `persist_mls_state` (private half persisted); `:12095-12102` send `MlsKeyPackage` to `peer_str`.
- Checks: NONE (not server membership, not group, not sender identity; `server_id` is only echoed).
- Who can sign: unsigned.
- Binding: NONE FOUND.
- Freshness: NONE FOUND.
- Blast radius: persistent storage growth (each unconsumed KeyPackage's private half stays in the MLS blob, `crypto_handler.rs:1900-1904`); supplies KeyPackages for S-16/S-17; if the requester is a legitimate coordinator it drives a leaf repair (2 epochs), as shown by the injected request in test `three_member_live_join_lands_at_minimal_epoch`.
- Tests: the positive test above only.
- SUSPICION S-22 (CONFIRMED-BY-READING): anyone (stranger in a shared room, relay with any `from`) obtains fresh KeyPackages on demand and makes the victim grow its persisted MLS storage; with a spoofed coordinator `from` it forces a remove + re-add.

### A-14 crypto/mls_manager.rs  (credential validation summary for item 3)

- Add (commit author side): `add_member` `mls_manager.rs:296-323`, `add_members_batch` `:327-378`: `kp_in.validate(...)` only (`:307-309`, `:347`). Credential validation: NONE FOUND.
- Welcome: `join_from_welcome` `:469-497`: no GroupId, sender or tree check. NONE FOUND.
- Update / Commit receive: `process_commit` `:572-601`: `process_message` then `merge_staged_commit` with no inspection of the `StagedCommit`. NONE FOUND.
- App message receive: `decrypt_fresh` `:527-569`: credential returned as the sender id, unvalidated.
- `key_package_identity` `:258-265` is the only credential reader, used only at `swarm.rs:10242-10246` (parked joins), and it compares against a relay-controlled value.
- Signature key <-> device identity binding: none; the MLS signer is independent of the device Ed25519 key (`:88`).

### A-15 HavenMessage::MlsChannelMessage  (decrypt, then dispatch the inner MessageEnvelope)

- Dispatch sites: live `swarm.rs:10884`; push background node `fetch.rs:470-544` (only `ChannelMessage`, signature-checked at `fetch.rs:518-523`, conference sids skipped `:499`).
- Principal used after decryption:
  - `swarm.rs:10955-10957` `Ok(Some((plaintext, sender_peer_id)))` = MLS LEAF CREDENTIAL (F5); `:10984` `let sender_master = super::resolver::resolve(&sender_peer_id);`.
  - Leaf-attributed arms: ChannelMessage/Edit/LinkPreviewSet/Delete/Reactions (`:10987-11034`, these also carry their own `sig`/`pk`, verification not traced here), FileHeader (`:11040` `sender_peer_id`), ServerDelete/MemberKick (`:11158`, `:11167`), Typing (`:11175`), ProfileUpdate (`:11189`), SyncReq/ChannelSyncReq/Probe/Batch (`:11210`, `:11227`, `:11237`, `:11256`), Shard*/Vault (`:11270-11342`), BroadcastMeta (`:11499`).
  - Relay-attributed arms: all VoiceChannel* (`:11365` rate check on `peer_str`; `:11374-11493` handlers get `peer_str.to_string()`; comment `:11369-11373` "keyed by the ROUTABLE WS sender (`peer_str`), NOT the MLS leaf credential").
  - Decrypt-failure path uses `peer_str` (`:11550-11568`, `:11578-11595`).
  - `peer_str` and the leaf credential are never compared (no line in `:10884-11677` does it).
- Checks: group held (`:10896`); decrypt; target filter `:10974-10978` (`target != local_peer` -> drop). No check that the envelope's `sid` equals the frame's `server_id`/group (cross-group, S-10).
- Could a relay rewriting `from` re-attribute a member's valid MLS message? Leaf-attributed arms: NO (credential comes from MLS). VoiceChannel* arms: YES.
- Freshness: `SecretReuseError` -> `Ok(None)` (`mls_manager.rs:544-546`); past epochs kept = 3 (`:25`).
- Failure handling: 3 sustained failures over >= 3 s (`MLS_DECRYPT_FAIL_WINDOW` `swarm.rs:12`) -> `:11627` `mls_mgr.remove_group(&group_key)` + re-bootstrap.
- Tests: `server_join_forms_mls_and_channel_message_decrypts`, subgroup tests (positive).
- SUSPICION S-23 (PLAUSIBLE): relay re-stamps `from` on a member's MLS VoiceChannel* frame (SDP offer/answer/ICE/Join/Leave) so the receiver binds Bob's signaling to Carol's participant slot or makes Carol appear to join/leave; content cannot be forged, attribution can.
- SUSPICION S-24 (CONFIRMED-BY-READING, DoS): garbage `MlsChannelMessage` bodies from anyone (relay, any room peer) spaced over 3 s drop the group at `:11627` (another drop primitive, like S-18).
- SUSPICION (see S-10): envelope `sid` not bound to the decrypting group.

### A-16 Per-channel subgroups "{server}#{channel}"  (item 5)

- Key: `mls_manager.rs:44-46` `format!("{server_id}#{channel_id}")`; split `:52-57`. No validation that ids lack `#`: NOT FOUND (server ids are hex by construction F6; channel ids and wire `server_id` values are not checked in the handlers read).
- Which channels: `crdt/server_state.rs:1635-1641` `channel_uses_subgroup`: not effectively public AND (`visibility != Everyone || !visibility_labels.is_empty()`).
- Who qualifies: `server_state.rs:1568-1583` `can_see_channel_at`: Owner always; unexpired grant; label gate (Admin+ or holds label); else tier ladder.
- Who creates:
  - reconcile coordinator: `crypto_handler.rs:2334-2359` owner if online, else lowest online qualifying master holding a leaf, else `elect_subgroup_coordinator`; `:2363` must itself qualify; `:2364-2370` `mls.create_group(&group_key)`.
  - MlsKeyPackage handler: `swarm.rs:11766-11785` elected subgroup coordinator; `:11806-11812` lazy create.
  - ANY peer via MlsWelcome with `channel_id: Some(cid)` (`swarm.rs:11859-11861`, no qualification check) - see A-09.
- Who adds: `reconcile_subgroups_for_server` only REQUESTS KeyPackages (`crypto_handler.rs:2391-2405`) from online qualifying members without a leaf; the add happens in the batch timer from `MlsKeyPackage` frames whose SENDER passes `can_see_channel(resolve(peer_str), cid)` (`swarm.rs:11701-11706`). KP credential unchecked (F5).
- Who removes: reconcile `crypto_handler.rs:2373-2381` `still_ok = server.is_member(&leaf_master) && server.can_see_channel(&leaf_master, &cid)` where `leaf_master = resolve(leaf credential)`; kick/ban `remove_identity_from_subgroups` `:2413-2467` by `{master} + devices_for(master)`.
- Trigger: after CRDT ops that change roles/visibility/labels/grants/membership (`swarm.rs:6392-6420`, MLS path `swarm.rs:11137-11151`).
- Receive-side enforcement of subgroup commits: as A-10 (none).
- Tests: `restricted_channel_subgroup_enforces_visibility`, `label_gated_channel_subgroup_and_fallback`, `restricted_voice_channel_subgroup_enforces_sframe_membership`.
- SUSPICION S-25 (CONFIRMED-BY-READING): a qualifying member (or the relay spoofing one, per S-12) can seat a leaf credentialed as another qualifying identity; reconcile keeps it because the check is on `resolve(credential)` (`:2375-2376`), so the restriction is only as strong as the unvalidated credential.

### A-17 HavenMessage::ConferenceJoinRequest  (knock; host admits via MLS add)

- Dispatch sites: plaintext room broadcast `swarm.rs:13892-13899`.
- Handler: `conference.rs:288-344`, `admit_peer` `:349-397`.
- State changes: `:338-340` `host_state.pending.insert(sender_peer.to_string(), ConfPendingJoin { key_package_b64 })` (OVERWRITES any earlier entry for that id); `:341-343` `ConferenceJoinRequestReceived` event; auto-admit `:332-336` -> `:367` `mls_mgr.add_member(&sid, &kp_bytes)`, `:374` merge, `:381-384` Welcome to `peer_id`, `:386-387` commit broadcast, `:390-395` SFrame emit. Also `:315-319` / `:325-330` sends Denied / LobbyInfo.
- Checks: `:303` host of an active meeting; `:304` `if sender_peer == local_peer_str { return; }` (device vs master compare); `:306` `blocklist::is_blocked(sender_peer)`; `:313-320` `if &access_hash != expected` -> deny. No KP-credential check (F5; `admit_peer` -> `add_member` `mls_manager.rs:304-313`).
- Who can sign: unsigned; the access hash is `sha256("{conf_id}:{code}")` (`conference.rs:52-58`), deterministic, no nonce, and travels in plaintext to the room (`:257-264`).
- Binding: sender id -> KP credential: NONE FOUND. Access-hash -> this knock: NONE FOUND (replayable).
- Freshness: none.
- Absent fields: `access_hash` default "" -> denied only when a code is set; `avatar_hash` "".
- Tests: `conference_waiting_room_admits_denies_and_chats` (asserts `wrong_code` denial).
- SUSPICION S-26 (CONFIRMED-BY-READING): the relay sees every room code (the conf id is the room name) and every knock's access hash in the clear, so it can knock and pass the code check by replay; with the waiting room off it is auto-admitted with a leaf.
- SUSPICION S-27 (CONFIRMED-BY-READING, Rust side): waiting-room KeyPackage swap. After Bob knocks, the relay re-sends a knock with `from = bob_device` and its own KeyPackage; `:338` overwrites Bob's pending KP; Dart dedups the UI entry by peer id (`conference_provider.dart:543`), so the host admits "Bob" and `handle_conference_admit` (`conference.rs:409-415`) adds the relay's leaf. The relay collects the Welcome sent to `bob_device` and holds the meeting's MLS and SFrame keys.
- SUSPICION S-28 (CONFIRMED-BY-READING): chat attribution uses the leaf credential (`conference.rs:531-546`), which any admitted participant chooses freely, so "one room member cannot spoof another's lines" (`:528-530`) does not hold; with an empty credential it falls back to the relay-stamped `sender_peer` (`:544`).

### A-18 HavenMessage::ConferenceJoinDenied

- Dispatch: `swarm.rs:13900-13903`. State: `clear_pending_knock(&conf_id)` (`conference.rs:93-99`), `NetworkEvent::ConferenceJoinDenied`. Dart `onDenied` (`conference_provider.dart:578-584`) checks only active conf and not-host.
- Checks: NONE (no host check in Rust or Dart).
- SUSPICION S-29 (CONFIRMED-BY-READING, low): any room occupant or the relay denies a knocker.

### A-19 HavenMessage::ConferenceLobbyInfo

- Dispatch: `swarm.rs:13904-13908` emits `host_peer_id: peer_str.to_string()`. Dart `onLobbyInfo` (`conference_provider.dart:559-567`) sets `hostPeerId` from ANY sender, last writer wins.
- Checks: NONE in Rust; Dart only `activeConfId == confId && !isHost`.
- SUSPICION S-30 (CONFIRMED-BY-READING): any occupant (or the relay) becomes the "known host" for the victim's UI, which is the value the Ended/Kicked checks trust (A-21, A-22).

### A-20 HavenMessage::ConferenceChat

- Dispatch: `swarm.rs:13909-13913` -> `conference.rs:513-548`.
- Checks: `:523` group held; `:531` MLS decrypt (membership proof); attribution = credential (S-28).
- State: `persist_mls_state` `:539`; event `ConferenceChatMessage`. Not persisted.
- Freshness: MLS generation.

### A-21 HavenMessage::ConferenceEnded

- Dispatch: `swarm.rs:13914-13921` (`clear_pending_knock`, event with `by_peer_id: peer_str`). Comment `:13915-13916` delegates validation to Dart.
- Dart `onEnded` (`conference_provider.dart:588-605`): `expectedHost = state.hostPeerId ?? own id`; rejects when `!links.sameIdentity(byPeerId, expectedHost)`; else leaves the voice call and the room.
- SUSPICION S-31 (CONFIRMED-BY-READING, low): chained with S-30 (send LobbyInfo first), any occupant or the relay ends the meeting for a participant.

### A-22 HavenMessage::ConferenceKicked

- Dispatch: `swarm.rs:13922-13930`; Dart `onKicked` (`conference_provider.dart:623-641`): if `expectedHost` is null or empty the check is SKIPPED (`expectedHost != null && expectedHost.isNotEmpty && !sameIdentity(...)`), else compared with the spoofable `hostPeerId`.
- SUSPICION S-32 (CONFIRMED-BY-READING, low): as S-31; and with no LobbyInfo seen yet, any sender is accepted.

### A-23 conf:{id} vs real server ids

- Honest ids cannot collide: servers are 32 hex (F6), conference sids carry `conf:` (`conference.rs:37-39`), conf ids are 32 hex when minted (`api/conference.rs:74-77`). No validation that a joined/inbound `server_id` lacks the `conf:` prefix or `#`: NOT FOUND (looked at `sync_handler.rs:1360-1479` `handle_join_server`, `swarm.rs:9879-9888`, `api/conference.rs:153-162` takes `conf_id` from the caller verbatim). A malicious owner could mint a `conf:`-prefixed server id, which only changes that server's own handling (`crypto_handler.rs:3165`, `:3268`; `message_ops.rs:2396`; `fetch.rs:499`).
- The real cross-effect is not an id collision but the unbound envelope `sid` (S-10): a `conf:` group can carry ServerDelete/MemberKick for a real server.

---

## Adjacent observation (outside my assigned arms, noted because A-04 depends on it)

- `swarm.rs:9457-9475` plaintext `SyncRequest` serves the op-log delta for any held server to any `peer_str` with no membership check, which is also how a forged owner tombstone (S-08) would spread.

## SUSPICION index

S-01 relay-forged ServerJoinRequest admits any identity with a public device list (swarm.rs:9903-9931, 10159)
S-02 member-authored MemberAdded bypasses ban/private/cap at ingest (crdt/server_state.rs:1335-1339, 721-738)
S-03 parked KP identity check compares with relay-stamped peer_str, relay gets a leaf (swarm.rs:10244, 10271)
S-04 plaintext snapshot + full op log served on demand, private servers included (swarm.rs:10300-10321)
S-05 forged ServerJoinResolved refuses a parked join, no sender check on joiner branch (swarm.rs:10360-10378)
S-06 requested_at=i64::MAX resolution freezes a joiner's parked admissions (swarm.rs:10402-10404, 9961)
S-07 ServerJoinRejected with requested_at=0 from anyone cancels any pending join (swarm.rs:10426-10438)
S-08 relay-forged ServerDeleteBroadcast tombstones servers; at owner's device it mints a valid owner op (swarm.rs:10446-10471)
S-09 MLS ServerDelete/MemberKick authority = unvalidated leaf credential (sync_handler.rs:3113-3116, swarm.rs:10984)
S-10 envelope sid not bound to decrypting group; conference group can delete a real server (swarm.rs:11154-11169)
S-11 relay-forged MemberKickBroadcast; Olm MemberKick sent but ignored (swarm.rs:10489-10522, 9150; sync_handler.rs:1610-1616)
S-12 relay obtains an MLS leaf in any server group by spoofing a member's MlsKeyPackage (swarm.rs:11694-11697, 11850; 5058-5107)
S-13 any member seats a leaf credentialed as any identity, owner included (mls_manager.rs:88,95,339-350)
S-14 no ban check on MlsKeyPackage (swarm.rs:11695-11697)
S-15 MlsWelcome removes the live group before validating; ungated (swarm.rs:11873-11878)
S-16 Welcome-based group substitution using a requested KeyPackage (swarm.rs:11858-11931, 12071-12106; mls_manager.rs:484-495)
S-17 conference lobby hijack via broadcast KeyPackage + ungated Welcome (conference.rs:257-264; swarm.rs:11916-11921)
S-18 unauthenticated garbage/epoch-stripped MlsCommit drops the group (crypto_handler.rs:2948-2954, 3019-3022)
S-19 commits from any leaf merged with no role/membership check on Add/Remove (mls_manager.rs:587-595)
S-20 relay-spoofed MlsEpochProbe evicts a member's leaves every 10 s (crypto_handler.rs:3179, 3230-3234)
S-21 member-sent garbage MlsCommitCatchup frame drops the group (swarm.rs:12021-12066)
S-22 MlsKeyPackageRequest ungated: KeyPackages on demand + storage growth (swarm.rs:12071-12106)
S-23 VoiceChannel* over MLS attributed to relay-stamped peer_str, never compared with leaf (swarm.rs:11365-11493) PLAUSIBLE
S-24 garbage MlsChannelMessage x3 over 3 s drops the group (swarm.rs:11604-11628)
S-25 subgroup membership keyed on resolve(unvalidated credential) (crypto_handler.rs:2373-2381)
S-26 relay sees conf ids and replays access hashes (conference.rs:52-58, 257-264, 313-320)
S-27 waiting-room KeyPackage swap by relay (conference.rs:338-340, 409-415)
S-28 conference chat attribution by chosen credential (conference.rs:531-546)
S-29 ConferenceJoinDenied from anyone (swarm.rs:13900-13903)
S-30 ConferenceLobbyInfo from anyone sets the host Dart trusts (swarm.rs:13904-13908; conference_provider.dart:559-567)
S-31 ConferenceEnded accepted from the spoofed host (conference_provider.dart:588-605)
S-32 ConferenceKicked accepted from anyone when no host known (conference_provider.dart:623-633)
