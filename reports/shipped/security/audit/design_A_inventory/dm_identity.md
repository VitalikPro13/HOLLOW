# Design A inventory: DMs, friends, siblings, linking, profiles, emotes

Evidence for design A (class A: "the relay is trusted to say who sent a plaintext
frame"). Read against the CURRENT tree on 2026-09-27 (main, uncommitted changes in
`api/crdt.rs` and `sync_handler.rs` only). Every line number below was re-read in this
session; older numbers in `phase_b_evidence/authz_dm.md` and `authz_identity.md` are
stale. Attacker model: P-01, a fully malicious relay.

Paths are relative to `rust/hollow_core/src/` unless they start with `relay-uws/` or `lib/`.

## 0. Common transport facts (apply to every plaintext variant below)

- **`from` is the only sender binding a plaintext frame has.** `node/ws_client.rs:523-536`
  turns 0x05 and 0x06 into `WsEvent::Message` / `WsEvent::DirectMessage { room, from, data }`
  straight from `parse_binary_relay_frame`; 0x08 topic frames (`:537-553`) parse
  `[room\0][topic\0][sender\0][payload]` the same way. Nothing client-side checks
  that `from` is the socket that wrote the payload.
- **The room is dropped before dispatch.** `node/swarm.rs:4576` matches
  `WsEvent::Message { room, from, data } | WsEvent::DirectMessage { room, from, data }`,
  parses `serde_json::from_str::<HavenMessage>` (`:4586`), rate-limits per `from`
  (`:4592-4612`), then calls `handle_incoming_request(...)` (`:4900-4947`) passing
  `&local_peer_str, &from, is_invisible` (`:4933`) and NO room. Inside, the sender is
  the parameter `peer_str: &str` (`:6670`). So no plaintext arm can tell which room,
  opcode (live 0x05, direct 0x06, topic/replay 0x08) or buffer a frame came from:
  re-routing a frame into another room is invisible to every handler below.
- **No self-origin filter.** Nothing between `:4576` and `:4947` refuses
  `from == device_peer_id` or `from == master`. `resolver::same_identity(a, b)` is
  `a == b || resolve(a) == resolve(b)` (`node/resolver.rs:42-44`), and `seed_self`
  maps our master to itself (`resolver.rs:81`), so a frame stamped with OUR OWN
  device id or master id passes every "verified-self" gate below.
- **Presence is relay-authored too.** `PeerJoined` / `RoomMembers` come from relay
  JSON (`relay-uws/src/ws_handler.cpp:534-555`). Several sends below fire on those
  events (`swarm.rs:3448-3752`, `:4088-4358`), so the relay can also TRIGGER them.
- **Send helpers.** `send_message_to_peer` (`node/crypto_handler.rs:2987-3015`) sends
  0x04 `SendDirect` into the FIRST room that lists the target
  (`ws_room_for_peer`, `:2671-2681`) and drops silently if none; `send_raw_to_peer`
  (`:3037-3050`) is the same for pre-serialised bytes; `send_message_to_peer_in_room`
  (`:3021-3033`) names the room explicitly; `fan_to_own_siblings`
  (`node/sync_handler.rs:43-63`) = `send_raw` to every `online_devices_for(our master)`
  (`crypto_handler.rs:2127-2152`, which reads relay presence).
- **Relay offline buffer (honest behaviour).** A 0x04 to a room that does not exist, or
  to a target not in the room, is buffered (`relay-uws/src/ws_handler.cpp:1723-1745`,
  `:1750-1775`: "buffer WITHOUT a push so it replays the instant they join the room")
  and replayed as 0x06 on the target's next join of THAT room, deleted on delivery
  (`:988-1013`). TTL `OFFLINE_BUFFER_TTL_SECS = 86400` (`relay-uws/src/state.h:39`);
  opted-in peers `OFFLINE_RETENTION_MIN_SECS = 3600` .. `MAX = 7 * 86400` (`:68-69`).
  The buffer rides the restart snapshot. So ANY plaintext 0x04 below can legitimately
  arrive up to 24 h (7 d opt-in) late.
- **Inbox mailbox.** A 0x04 addressed to a bare MASTER in `inbox:{M}` is buffered under
  the master key and replayed WITHOUT deletion to every socket that proves ownership
  (`ws_handler.cpp:409-422` "DO NOT remove it", proof rules `:424-484`). Re-delivery on
  every inbox join is by design.
- **The push fetch node** handles only Olm `Encrypted` on 0x06 for DMs
  (`node/fetch.rs:363-369`, `:903-960`); every other variant in this file is ignored
  there (`fetch.rs:959` `_ => None`).
- **Olm session availability.** On every `is_new` presence event we run
  `ensure_olm_session_and_drain` (`swarm.rs:3591-3605`, `:4250-4264`), which sends a
  device-signed `KeyRequest` when there is no confirmed session (`swarm.rs:115-127`).
  So a peer we share ANY room with normally holds an Olm session with us within a
  round trip; siblings and friends are always in that set. `send_dm_sync_reply`
  (`swarm.rs:5991-6024`) already shows the queue-until-session pattern
  (`pending_messages` + KeyRequest) an Olm twin would need.

---

## Part 1. Olm key exchange and the Olm frame

### KeyRequest

1. **Send sites.** Built by `signed_key_request` (`crypto_handler.rs:483-499`), always
   via `send_message_to_peer` (first-match room): `ensure_olm_session_and_drain`
   (`swarm.rs:115-127`), DM-room co-presence heal (`swarm.rs:3742-3751`), decrypt-failure
   re-key (`swarm.rs:6974-6980`, `:7051-7060`, `:7130-7139`), `send_dm_sync_reply`
   (`:6017-6023`), plus sweeps at `swarm.rs:4393`, `:4489`, `:5293`, `:9115`, `:9737`,
   `message_ops.rs:763`, `file_handler.rs:1383`, `voice_handler.rs:285`,
   `forwarder_client.rs:226` (not each re-read). To one DEVICE.
2. **Receive arms.** `swarm.rs:6690-6751`; forwarder process `forwarder/signaling.rs:272-279`.
3. **Effect.** Tears down our session: `olm.remove_session(peer_str)` (`:6736`), mints and
   persists an OTK (`:6739-6744`), replies with a signed `KeyBundle` (`:6746-6749`).
4. **Authorisation.** Device signature over
   `"hollow-keyrequest:{sender_device}:{recipient_device}:{ts}"` (`crypto_handler.rs:462-468`);
   `verify_key_exchange` checks `to == our device` (`:567-570`), `|now - ts| <= 300 s`
   (`KEY_EXCHANGE_SKEW_SECS = 300`, `:433`, `:573-576`), and the sig re-derives the
   sender id from `pk` (`:580`). Unsigned refused (`REQUIRE_SIGNED_KEY_EXCHANGE = true`,
   `:547`; `swarm.rs:6705-6710`). `key_exchange_device_unauthorized` (`:595-610`) refuses a
   revoked device or a device not in its known master's list; an UNKNOWN device
   (resolves to itself) passes as first contact. The relay cannot forge it.
5. **Timing.** Live; a buffered copy older than 300 s is refused.
6. **Replay.** Within 300 s a captured request re-runs the teardown: gated only by
   `decrypt_fail_cooldown` 5 s when a CONFIRMED session exists (`:6725-6730`); with an
   unconfirmed or no session every replay mints another OTK. Tracked as L6; AR-09 is CLOSED:
   the replay half by HOL-SEC-054 (live-frame guard), the minting half by HOL-SEC-111 (one
   key per requesting device, bounded slot table).
   Re-route to another device fails `to`.
7. **Session.** None by definition (this is how sessions start).
8. **Metadata.** `to`, `ts`, the sender device pubkey (already inside the peer id).
   Shows the relay which device pairs are (re)keying.

### KeyBundle

1. **Send.** Only as the answer to a KeyRequest: `signed_key_bundle(...)` (`crypto_handler.rs:503-525`)
   via `send_message_to_peer` (`swarm.rs:6746-6749`); forwarder `forwarder/signaling.rs:385`.
2. **Receive.** `swarm.rs:6753-6863`.
3. **Effect.** Pins the sender's Olm identity key (`note_olm_identity_key`, `:6794-6797`);
   if no session and it wins the glare tiebreak, `create_outbound_session` (`:6821`),
   sends an Olm `SessionAck` (`:6832-6837`), drains `pending_messages` (`:6839-6847`),
   flushes queued sync (`:6849-6855`).
4. **Authorisation.** Device sig over
   `"hollow-keybundle:{sender_device}:{recipient_device}:{identity_key}:{one_time_key}:{ts}"`
   (`crypto_handler.rs:444-454`), same `to`/`ts`/device-list rules as KeyRequest
   (`swarm.rs:6762-6788`). Not relay-forgeable.
5. **Timing.** Live (300 s).
6. **Replay.** Within 300 s: ignored when a session exists (`:6799-6801`); else builds an
   outbound session on the genuine keys (OTK possibly already spent, self-heals).
7. **Session.** None.
8. **Metadata.** The device's long-term Curve25519 identity key and an OTK.

### Encrypted (Olm frame; the carrier of every MessageEnvelope twin in Part 5)

1. **Send.** `encrypted_frame` (`crypto_handler.rs:653-671`) via `send_encrypted_message`
   (first-match room, `:2821-2863`), `send_encrypted_message_in_room` (explicit room,
   `:2871-2902`), `send_encrypted_image_to_peer` (0x08 image cap, `:2911-2942`). DMs fan to
   each recipient device plus our siblings inside `dm_room_code(local, recipient_master)`
   (`message_ops.rs:411`, `:423-429`).
2. **Receive.** `swarm.rs:6865-9966` (decrypt `:6880-7144`, envelope dispatch from `:7159`);
   push fetch node `fetch.rs:862-960`; forwarder `forwarder/signaling.rs:280-309`.
3. **Effect.** Decrypt with the session keyed by `peer_str`; on PreKey success, builds an
   inbound session and emits `SessionEstablished`, pins the key, SessionAck, drain,
   `request_dm_resync_after_rekey` (`:6990-7037`). On a NORMAL-message decrypt failure:
   `olm.remove_session(&peer_str)` at most once per 5 s (`:7098-7105`) plus a KeyRequest
   every 2 s (`:7130-7139`). On a PreKey that the existing session cannot open:
   `olm.remove_session(&peer_str)` then `create_inbound_session` (`:6915-6920`); if that
   also fails the session is gone and we re-key (`:6960-6984`).
4. **Authorisation.** Content: the Olm ratchet keyed by the relay-stamped `peer_str`
   (the session exists only after device-signed exchange). PreKey: device sig over
   `"hollow-olm-identity:{sender_device}:{identity_key}"` (`crypto_handler.rs:620-622`),
   "No recipient or timestamp" (`:618-619`), checked before any teardown (`swarm.rs:6896-6901`).
   A NORMAL frame has NO pre-decrypt check: any bytes stamped `from = X` reach
   `olm.decrypt(&peer_str, ...)` and, failing, tear down our session with X.
5. **Timing.** Relay-buffered up to 24 h / 7 d (Part 0); the push path exists for exactly that.
6. **Replay.** A replayed type-1 frame fails decrypt (chain key already consumed) and
   triggers the teardown above. A replayed genuine PreKey passes the identity check
   (standing fact, no freshness), fails on the existing session, and the code removes
   that session before the inbound rebuild fails on the spent OTK (`:6919`, `:6964`).
   PLAUSIBLE: the exact vodozemac error for a duplicate message was not traced
   (UNTRACED inside `crypto/olm_manager.rs`). This is A14's open half.
7. **Session.** n/a.
8. **Metadata.** Ciphertext length and timing; PreKeys carry the Olm identity key and its
   device proof. The ROOM is `dm_room_code` = `hex(sha256("dm-{a}-{b}")[..16])` of the two
   MASTERS (`node/types.rs:43-50`): the relay can compute it for any pair of masters it has
   seen and so maps who DMs whom, with device ids on both ends. C-24 (contact lists).

### Ack

1. **Send.** None in production (only `crypto/olm_manager.rs:317` test string).
2. **Receive.** No arm: falls to `swarm.rs:13464` `_ => {}`; fetch `fetch.rs:959`.
3. **Effect.** None. 4-8. n/a (dead variant; `node/types.rs:1436-1437`).

---

## Part 2. DM history sync

### DmSyncRequest

1. **Send.** `send_message_to_peer` to a DEVICE: PeerJoined (`swarm.rs:3684-3702`),
   RoomMembers (`:4266-4287`), post-rekey (`request_dm_resync_after_rekey`, `:5954-5985`),
   pagination (`:7597-7604`).
2. **Receive.** `swarm.rs:9967-10031`.
3. **Effect.** Resolves `convo_peer = resolve(peer_str)` (`:9975`) and serves up to 200 rows
   (gap rows first, `:9982-10001`; then `get_dm_messages_for_sibling` if `both_directions`
   else `get_dm_messages_since`, `:10003-10007`) as an Olm `DmSyncBatch` via
   `send_dm_sync_reply` (queue + KeyRequest if no session).
4. **Authorisation.** Relay `from` only; no friendship, sibling or block check in the arm.
   Confidentiality holds because the reply is Olm-encrypted to `peer_str`'s session.
5. **Timing.** Normally live; buffered ≤24 h if the first-match room was left.
6. **Replay.** Harmless re-serve (bandwidth). A forged `from` only makes us send Olm
   ciphertext to that device.
7. **Session.** Normally yes (friends); reply path already queues when not.
8. **Metadata.** Plaintext `since_timestamp`, `both_directions` (reveals that the requester
   has sibling devices), and `GapDigest` = per UTC day `{d, n, h}` (`types.rs:4168-4182`):
   per-day message COUNTS of the conversation, including messages that never crossed the
   relay. C-24.

### DmSiblingSyncRequest

1. **Send.** `request_sibling_dm_backfill` (`crypto_handler.rs:26-67`, 15 s cooldown) from
   `on_verified_sibling` (`swarm.rs:299-302`) and `ingest_sibling_device_list`
   (`crypto_handler.rs:1803-1805`); pagination `swarm.rs:7835-7841`. `send_message_to_peer`.
2. **Receive.** `swarm.rs:10033-10094`.
3. **Effect.** Serves EVERY DM conversation, both directions (`get_dm_peer_ids`, `:10047`),
   as Olm `DmSiblingSyncBatch` per convo.
4. **Authorisation.** `same_identity(peer_str, local_peer_str)` (`:10037`): relay `from` only
   (Part 0). Reply is Olm to that device, so a forged request leaks ciphertext only.
5. **Timing.** Live; ≤24 h buffer possible.
6. **Replay.** Re-serves everything (bandwidth amplification).
7. **Session.** Siblings normally hold one.
8. **Metadata.** `per_convo_since: Vec<(friend_master, latest_ts)>` for ALL conversations
   plus per-convo `GapDigest` (`crypto_handler.rs:47-57`): our complete DM contact list,
   last-message times and per-day counts, in plaintext. C-24 (contact lists).

---

## Part 3. Friends

### FriendRequest

1. **Send.** Built by `social::build_friend_request` (`social.rs:78-147`, carries a
   device-signed `CarriedBundle`, our signed device list, our signed profile). Sent live via
   `send_message_to_peer` to each online target device (`social.rs:574-581`), else queued
   and deposited into `inbox:{target_master}` addressed to the bare master
   (`deposit_friend_request_to_inbox`, `social.rs:297-307`), re-deposited on every connect
   (`swarm.rs:3137-3144`...); drains at `swarm.rs:3475-3497`, `:4307-4323`, `:12758-12778`.
2. **Receive.** `swarm.rs:11300-11561`.
3. **Effect.** Ingests the carried list (resolver binding, revocations, `:11331-11362`);
   stores the carried bundle under `friendreq_in:{master}` (`:11369-11394`); stores the
   carried profile (`:11456-11464`); if WE have an outgoing request, AUTO-ACCEPTS
   (`handle_accept_friend_request`, `:11486-11517`); else `save_friend(master, "pending",
   "incoming", requested_at)` (`:11528`), joins the DM room (`:11540-11543`), pushes our
   profile + device list to the sender (`:11551-11556`), emits `FriendRequestReceived`.
4. **Authorisation.** Relay `from` + block check (`:11314`, `:11359`). The carried list
   must verify and name `peer_str` (`:11332-11341`), but the list is public and
   replayable, so it binds nothing to THIS frame. The carried bundle IS device-signed with
   recipient-master binding and a 7-day window (`crypto_handler.rs:686-701`, `:744-791`,
   `MAX_CARRIED_BUNDLE_AGE_SECS = 7 * 24 * 3600` `:681`), but it is optional
   (`if let (Some(bundle), Some(list))`, `:11369`) and does not cover `requested_at` or the
   profile. So: NOTHING beyond `from` binds a bundle-less request, and `requested_at` is
   unsigned even with a bundle.
5. **Timing.** Legitimately late: mailbox TTL (24 h baseline), re-deposited on each connect
   of the requester, so effectively "until answered".
6. **Replay.** Dedup by friend row (`:11404-11449`): accepted = ignore; declined or
   pending-incoming ignore only if `requested_at <= stored`. `save_friend` ADVANCES a pending
   row by `MAX(requested_at, ?4)` (`storage/messages.rs:3903-3905`) and freezes it on other
   statuses. A relay that rewrites or forges `requested_at` to a huge value makes every later
   genuine request from that person look stale (after a decline, permanently; the swallow
   path even re-sends our reject, `:11426-11434`). A forged request while we hold an
   outgoing one drives the mutual auto-accept (A8).
7. **Session.** None (first contact); the carried bundle exists to bootstrap one.
8. **Metadata.** Room `inbox:{target_master}` + sender device = "A asked B" (contact graph);
   sender's device list, signed profile (name, status, about, twitch, avatar hash), Olm
   identity key and OTK, `requested_at`. C-24 (profiles, contact lists, device grouping).

### FriendAccept

1. **Send.** `friend_accept_msg` / `send_friend_accept` (`social.rs:361-388`) into
   `dm_room_code` (explicit room, so buffered): accept flow `social.rs:725-727`,
   `:762-765`; drains `swarm.rs:3530-3545`, `:4344-4357`.
2. **Receive.** `swarm.rs:11563-11657`.
3. **Effect.** `save_friend(&master, "accepted", "", now)` (`:11628`), shares with siblings
   (`share_friend_with_siblings`, `:11630-11634`), pushes our profile, emits
   `FriendRequestAccepted`. Grants calls and data channels (`voice_handler.rs:420-433`,
   `:55-77` key on `"accepted"`).
4. **Authorisation.** Relay `from` + optional replayable list (`:11566-11590`) + block
   (`:11591`). Lands only on our pending-OUTGOING or accepted row (`:11609-11623`, HOL-SEC-036).
   Stale check `if let Some(stamp) = requested_at && stamp < stored` (`:11613`): an accept
   with `requested_at: None` skips it ("pre-0.11.1 senders, which stay honoured",
   `types.rs:1879-1880`). So the relay alone can complete any outgoing request of ours.
5. **Timing.** Buffered in the DM room ≤24 h/7 d; re-sent on every appearance while queued.
6. **Replay.** Idempotent on an accepted row; on a re-requested row an unstamped copy is
   honoured.
7. **Session.** Usually none at accept time for async friending; the accepter builds one
   from the carried bundle and sends a sentinel PreKey right after (`social.rs:728-749`),
   so an Olm twin would need ordering after that establisher.
8. **Metadata.** Accepter's device list; the DM room join pair = the new friendship. C-24.

### FriendReject

1. **Send.** `send_friend_reject` (`social.rs:330-357`): live `send_message_to_peer` to online
   devices AND a deposit into `inbox:{requester_master}` (join, send, leave). From
   `handle_reject_friend_request` (`social.rs:857-862`) and the re-arm in the FriendRequest
   arm (`swarm.rs:11426-11434`).
2. **Receive.** `swarm.rs:11659-11764`.
3. **Effect.** `store.remove_friend(&master)` (`:11738`) for a pending-outgoing OR an
   ACCEPTED row, clears queues, leaves `inbox:{master}`, emits `FriendRequestRejected`.
4. **Authorisation.** Relay `from` + optional replayable list (`:11671-11707`). Acts when
   `("pending","outgoing",stored) => requested_at == 0 || requested_at >= stored` or
   `("accepted",_,stored) => requested_at != 0 && requested_at >= stored` (`:11727-11731`).
   `requested_at` is unsigned: a forged reject with `requested_at = i64::MAX` from a device
   the resolver maps to a friend deletes an ACCEPTED friendship. Relay alone.
5. **Timing.** Mailbox (TTL-only, re-delivered on every inbox join).
6. **Replay.** Stamp rule stops old genuine copies; does nothing against a forged stamp.
7. **Session.** Often none (decline of an async request); an Olm twin cannot cover this
   case, a device signature (recipient master, requested_at) can.
8. **Metadata.** Decliner's device list; `inbox:{requester}` deposit = "B declined A".

### FriendRemove

1. **Send.** `handle_remove_friend` → `send_message_to_peer(t, HavenMessage::FriendRemove)`
   to each online device (`social.rs:912-927`); else queued (`pending_friend_removals`,
   row `"removed","outgoing"`), drained on presence (`swarm.rs:3504-3524`, `:4325-4343`).
2. **Receive.** `swarm.rs:11766-11802`.
3. **Effect.** Writes `friend_removed:{master}` tombstone, `remove_friend(master)`
   (`:11775-11779`), clears our queued accept/request, emits `FriendRemoved`. Calls and
   data channels from that person stop being allowed (`voice_handler.rs:420-433`).
4. **Authorisation.** NOTHING beyond relay `from` (`let master = resolve(&peer_str)`,
   `:11770`). Unit variant: no stamp, no signature, no block check needed to act.
5. **Timing.** Live to online devices; drained later; ≤24 h buffer possible.
6. **Replay.** Any copy, any time, unfriends. Not idempotent-safe.
7. **Session.** Friends normally hold Olm sessions: an Olm twin is feasible except for
   a friend with no reachable device (the queued path).
8. **Metadata.** The frame itself = "A unfriended B".

### IdentityDestroyed (+ Olm twin DestroyIdentityOrder, Part 5)

1. **Send.** `handle_publish_destroy_identity` (`node/destroy.rs:319-382`): plaintext bytes
   `send_raw_to_peer` to each online own device (`:352`) alongside the Olm twin; offline own
   devices go to the relay kill list (`KillDeposit`, `:358-372`); with `notify_friends`,
   `announce_to_friends` sends 0x04 into each friend's `dm_room_code` to every known device
   AND the bare master (`:387-414`, buffered).
2. **Receive.** `swarm.rs:11804-11810` → `destroy::handle_identity_destroyed` (`destroy.rs:228-241`).
3. **Effect.** Own master: `judge_own_order` then `NetworkEvent::DestroyReceived` → wipe
   (`destroy.rs:137-158`). Foreign master we know: sets `identity_destroyed:{m}` banner and
   floor, `remove_peer_verified` (`destroy.rs:163-194`).
4. **Authorisation.** Master sig over
   `"hollow-destroy:{master}:{issued_at_ms}:{sorted targets}:{notify_friends}"`
   (`crypto_handler.rs:1231-1241`, verify `:1271-1293`), pubkey must derive to the master.
   Own lane adds: targets name this device or empty, `issued_at_ms >= device link stamp`,
   `> last applied this session` (`destroy.rs:106-134`). Delivery (`from`) is irrelevant by
   design. Not forgeable.
5. **Timing.** Kill list holds it for offline devices (relay), friend copies buffered.
6. **Replay.** Own lane: applied stamp is RAM-only on purpose (`destroy.rs:21-28`), so a
   restart re-opens replay, but only for orders that already target this device. Friend
   lane: persisted floor (`destroy.rs:181-187`); a copy withheld until after the identity
   reappears still lands once (floor 0 then). Low.
7. **Session.** Siblings: usually yes (twin exists). Friends: usually yes.
8. **Metadata.** Master id, target device ids (device grouping), and the friend fan-out
   = full friend list at destroy time. C-24.

---

## Part 4. Own-device (sibling) lane

### FriendListSync

1. **Send.** `send_message_to_peer` to a sibling device: `on_verified_sibling`
   (`swarm.rs:257-279`), FriendListRequest reply (`:12023-12026`), SiblingStateSyncRequest
   (`:12082-12085`), `ingest_sibling_device_list` (`crypto_handler.rs:1773-1791`);
   `share_friend_with_siblings` via `fan_to_own_siblings` (`social.rs:393-413`).
2. **Receive.** `swarm.rs:11812-11943`.
3. **Effect.** For each entry not already held (or held as `pending` when the entry says
   `accepted`): `save_friend(&fmaster, "accepted", "", entry.requested_at)` (`:11853`),
   JoinRoom its DM room (`:11861-11864`), sends our profile + device list into that room
   to `entry.peer_id` (`:11926-11930`), emits `FriendsBackfilled`. This settles a pending
   INCOMING request as accepted ("Our sibling's accept is our own consent", `:11845-11846`)
   and grants calls/data channels to the listed identity.
4. **Authorisation.** `same_identity(peer_str, local_peer_str)` (`:11816`): relay `from`
   only. The relay can plant ANY identity (its own included) as an accepted friend, or
   accept a pending request without consent (the L1 hole, re-opened through the sibling lane).
5. **Timing.** Mostly live; fan-out targets relay-reported online siblings.
6. **Replay.** Idempotent for held rows; new entries always land.
7. **Session.** Siblings normally hold Olm sessions; a fresh link races it (needs queueing).
8. **Metadata.** Every accepted friend's master id + `requested_at`, plaintext. C-24
   (contact lists). The relay can TRIGGER this send at will (Part 0 presence, or a forged
   FriendListRequest / SiblingStateSyncRequest, or replaying our own list, below).

### FriendListRequest

1. **Send.** `on_verified_sibling` (`swarm.rs:292-295`), `ingest_sibling_device_list`
   (`crypto_handler.rs:1795-1798`).
2. **Receive.** `swarm.rs:12000-12030`.
3. **Effect.** Replies with our full accepted-friend list as plaintext `FriendListSync` to `peer_str`.
4. **Authorisation.** `same_identity` on relay `from` (`:12004`).
5. **Timing.** Live. 6. **Replay.** Each copy re-sends the list.
7. **Session.** Yes normally.
8. **Metadata.** The request is empty; its ANSWER leaks the friend list. On-demand
   C-24 leak: the relay stamps `from` = one of our devices and reads the reply.

### SiblingStateSyncRequest

1. **Send.** `NodeCommand::RequestStateSync` → `SendDirect` in `inbox:{master}` or any room
   listing the source (`swarm.rs:1475-1510`).
2. **Receive.** `swarm.rs:12045-12100`.
3. **Effect.** Sends `SiblingServerAnnounce` for every server we belong to (`:12060-12069`),
   `FriendListSync` (`:12072-12088`), `PersonalEmoteSync` (`:12090-12092`), `ReadMarkers`
   (`:12094-12096`), all plaintext, to `peer_str`.
4. **Authorisation.** `same_identity` on relay `from` (`:12049`).
5. **Timing.** Live. 6. **Replay.** Each copy re-sends everything.
7. **Session.** Yes normally.
8. **Metadata.** One frame makes us publish server ids, friend list, emote set and read
   positions in plaintext. C-24.

### ReadMarkers

1. **Send.** `NodeCommand::SyncReadMarkers` → `fan_to_own_siblings` (`swarm.rs:2269-2275`);
   `send_read_markers_to_sibling` (`crypto_handler.rs:73-93`) from `on_verified_sibling`
   (`swarm.rs:285-287`), `ingest_sibling_device_list` (`crypto_handler.rs:1806-1808`),
   SiblingStateSyncRequest (`swarm.rs:12094-12096`).
2. **Receive.** `swarm.rs:12032-12043` → `ReadMarkersReceived` → Dart
   `unread_provider.dart:39-69` → `storage::apply_remote_read_marker` (`storage/messages.rs:5030-5038`).
3. **Effect.** `if ts <= current_ts { return Ok(None) }` then writes `seen_ts:{key} = ts`;
   `read_marker_floor` takes `max(row, seen_ts)` (`messages.rs:4983-4999`). No upper bound
   on `ts`: a marker with a far-future `ts` marks every present AND future message of that
   conversation read, permanently (never-regress), and retires its notifications.
4. **Authorisation.** `same_identity` on relay `from` (`:12036`). Relay alone.
5. **Timing.** Live; ≤24 h buffer possible.
6. **Replay.** Old copies no-op (monotone); forged future stamps stick.
7. **Session.** Yes normally.
8. **Metadata.** `key` = `dm:<master>` or `ch:<server>:<channel>` (`api/network.rs:463`),
   plus message id and ts: DM partners, channels read, reading position and time. C-24.

### PersonalEmoteSync

1. **Send.** `send_personal_emotes_to_sibling` (`swarm.rs:135-166`) from
   `on_verified_sibling` (`:280-282`) and SiblingStateSyncRequest (`:12090-12092`);
   deltas `NodeCommand::SyncPersonalEmotes` → `fan_to_own_siblings` (`:1512-1526`).
2. **Receive.** `swarm.rs:11945-11998`.
3. **Effect.** `merge_personal_emote_entry` per row, LWW on `added_at`, empty hash =
   tombstone (`types.rs:1957-1962`), up to 512 rows (`:11954`); missing blobs pulled over the
   asset rail from our own devices (`:11981-11990`); emits `PersonalEmotesUpdated`.
4. **Authorisation.** `same_identity` on relay `from` (`:11948`); shape checks only
   (`:11959-11965`, `added_at >= 0`, no ceiling). Relay alone: a tombstone with a huge
   `added_at` deletes a name for good; forged rows add emotes (bytes still hash-checked).
5. **Timing.** Live. 6. **Replay.** LWW makes old copies no-ops.
7. **Session.** Yes normally.
8. **Metadata.** Emote names, content hashes, source, timestamps. C-24 (profile-adjacent).

### SiblingProveRequest

1. **Send.** `issue_sibling_challenge` (`swarm.rs:351-386`, 60 s TTL, 64 pending) when an
   unproven peer is in our `inbox:{master}` (PeerJoined `:3571-3586`, RoomMembers `:4228-4245`).
2. **Receive.** `swarm.rs:10103-10115`.
3. **Effect.** Signs `"hollow-sibling:{our_master}:{our_device}:{nonce}"` with the MASTER key
   (`crypto_handler.rs:946-965`) and replies to `peer_str`.
4. **Authorisation.** None: answered for ANY sender in any room with an attacker-chosen
   `nonce`. Safe because the payload binds our own device id and a unique prefix, but it
   is a master-key signing oracle for that one prefix.
5. **Timing.** Live. 6. **Replay.** Each copy yields a fresh signature; no state.
7. **Session.** Not needed (unproven peer by definition).
8. **Metadata.** Our master pubkey (already public) + that this device holds the master key.

### SiblingProveResponse

1. **Send.** `swarm.rs:10111-10114`.
2. **Receive.** `swarm.rs:10117-10149`.
3. **Effect.** `on_verified_sibling` (`swarm.rs:179-346`): `resolver::update`, re-signs our
   device list with the new device (`merge_sibling_device_id`, `crypto_handler.rs:1332-1380`),
   pushes profile, friends, emotes, read markers, requests friends and DM backfill,
   re-announces servers (plaintext `SendDirect` in `inbox:{master}`, `:304-320`), and
   auto-requests a snapshot if we are empty (`:331-345`).
4. **Authorisation.** Pending nonce for `peer_str` (`:10121-10133`, 60 s) + master sig
   binding OUR master, the challenged device id and the nonce (`crypto_handler.rs:971-997`)
   + not revoked (`sibling_proof_refused`, `:1307-1324`). Not relay-forgeable. BUT
   `on_verified_sibling` is ALSO reached with no proof whenever a peer that already
   resolves to us shows up in our inbox (`swarm.rs:3573-3579`, `:4231-4237`): relay presence
   alone replays the whole convergence and its plaintext leaks.
5. **Timing.** Live (60 s). 6. **Replay.** Nonce is single-use (`remove`, `:10141`).
7. **Session.** Not yet (this is the step before trust).
8. **Metadata.** Master pubkey; the convergence it triggers leaks Part 4's payloads.

### LinkSnapshotRequest

1. **Send.** Code path `handle_link_code_resolved` to the peer the RELAY named in
   `LinkCodeResolved` (`link_handler.rs:131-148`, `swarm.rs:4567-4575`); mnemonic path
   `handle_request_link_snapshot` (`link_handler.rs:151-168`) from `on_verified_sibling`
   auto-pull (`swarm.rs:331-345`) or `NodeCommand::RequestLinkSnapshot` (`:2177-2181`).
2. **Receive.** `swarm.rs:12103-12114`.
3. **Effect.** `SiblingLinkAvailable` prompt with the requester's self-reported counts
   (`link_handler.rs:172-186`). On the user's Accept, `AcceptLinkPush` exports the FULL
   backup (identity key included) encrypted with our claimed code, or with
   `local_peer_str` (our MASTER id) when no code is claimed (`swarm.rs:2182-2193`), and
   streams it to `target_peer` (`link_handler.rs:192-252`).
4. **Authorisation.** `link_request_allowed` (`link_handler.rs:73-85`): `same_identity` on
   relay `from`, or `from` listed in `link:{claimed code}` (relay presence). Relay alone
   raises the prompt; one click then sends a blob whose passphrase the relay knows (the
   master id, or the code it brokered). O2's fix does not hold against P-01 (HOL-SEC-002 /
   embargoed `project_link_snapshot_relay_decrypt`).
5. **Timing.** Live. 6. **Replay.** Re-raises the prompt.
7. **Session.** Code path: none (strangers until linked). Mnemonic path: usually yes.
8. **Metadata.** The code travels to the relay (`ClaimLinkCode`/`ResolveLinkCode`,
   `relay-uws/src/state.h:252-257`) and names the room `link:{CODE}` (`link_handler.rs:89-91`).

### LinkSnapshotKey

1. **Send.** `handle_accept_link_push` (`link_handler.rs:225-232`), empty `aes_key`/`aes_nonce`.
2. **Receive.** `swarm.rs:12116-12123` → `handle_inbound_link_key` (`link_handler.rs:257-272`);
   stream completion `file_handler.rs:2331-2392` → `stash_pending_link`, imported at next
   launch replacing `identity.key` and the DB (`api/storage.rs:1752-1804`).
3. **Effect.** Registers a pending stash; the following `LinkSnapshot` stream from the same
   `sender_peer` is stashed and imported over our identity on restart.
4. **Authorisation.** `snapshot_was_asked(sender)` (`link_handler.rs:263`) where the asked
   peer was chosen by the relay (code path) and `sender` is relay `from`; the blob only
   has to decrypt under the code/master id the relay knows and contain `identity.key`
   (`api/storage.rs:1765-1768`). Relay alone can plant an identity (O3, folded into HOL-SEC-002).
5. **Timing.** Live. 6. **Replay.** Needs a live ask.
7. **Session.** None on the code path.
8. **Metadata.** The whole snapshot is decryptable by the relay (embargoed, see above).

### LinkDeclined

1. **Send.** `NodeCommand::DeclineLinkPush` (`swarm.rs:2195-2199`).
2. **Receive.** `swarm.rs:12125-12131`: emits `LinkFailed` ("declined by other device").
3. **Effect.** UI only. 4. **Authorisation.** None (not even `snapshot_was_asked`).
5-7. Live; replay just fails a link UI; no session needed. 8. That a link was declined.

### LinkSnapshotAck

1. **Send.** `file_handler.rs:2375-2378` after stashing.
2. **Receive.** `swarm.rs:12133-12139`: emits `LinkPushComplete`.
3. **Effect.** Sender UI flips to "Data sent". 4. **Authorisation.** None.
5-7. Live; replay/forgery can show success early. 8. `link_id` = device-id tails
   (`link_handler.rs:219-221`).

### PeerDisconnecting

1. **Send.** None in Rust today (`grep`: only the arm and `types.rs:1611-1613`).
2. **Receive.** `swarm.rs:10095-10101`: emits `PeerDisconnected { peer_id: peer_str }`.
3. **Effect (Dart).** `event_provider.dart:340-347` → `call_provider.dart:1702-1715` ends a
   not-yet-connected call with that device; `voice_channel_provider.dart:1355-1374` removes
   it from every VC and `closePeer`; `recording_provider.dart:160` clears that peer's
   REC indicator (`onRemoteRecordingStop`).
4. **Authorisation.** NOTHING beyond relay `from`. Relay alone (A13; hiding the REC badge
   is the privacy-relevant part).
5-7. Live; replayable; no twin needed (delete the variant). 8. None.

---

## Part 5. Profiles, emotes and misc

### ProfileUpdate (plaintext) and MessageEnvelope::ProfileUpdate (MLS twin)

1. **Send.** Plaintext `HavenMessage::ProfileUpdate` from `send_own_profile_inner`
   (`social.rs:1732-1825`, first-match or explicit room) on every PeerJoined/RoomMembers
   announce to every peer of every room, server rooms included (`swarm.rs:3547-3553`,
   `:4058-4072`, `:4100-4106`), friend flows (`:11551-11556`, `:11647-11652`,
   `social.rs:717-721`, `:784-791`), sibling flows (`swarm.rs:221-237`), device-set growth
   (`:12724-12743`), self-revocation (`destroy.rs:305-308`), backfilled friends
   (`swarm.rs:11909-11930`). `handle_update_profile` sends the MLS twin to each server
   group and plaintext to every other room peer (`social.rs:1203-1269`).
2. **Receive.** Plaintext `swarm.rs:12688-12874`. MLS `swarm.rs:10517-10542` →
   `social::handle_envelope_profile_update` (`social.rs:1903-2024`); sender = the MLS leaf's
   device (`sender.device`, read at `swarm.rs:10281`). Olm copy ignored (`:8561-8577`).
3. **Effect.** Ingests the carried device list FIRST (resolver, revocations, sibling merge,
   re-announce, `:12709-12743`); drains a queued friend request (`:12751-12779`); emits
   `PeerStatusChanged invisible` if flagged (`:12691-12696`); saves the profile under the
   master (`save_incoming_profile`, `social.rs:1343-1430`) incl. banner, showcase board and
   assets, frame, animated hashes, support creds; updates member display names; may pull
   the full profile (`maybe_request_full_profile`, `social.rs:1836-1885`).
4. **Authorisation.** Device list: master sig + `device_list_binds_sender(list, peer_str)`
   (`crypto_handler.rs:882-888`, `:1438-1446`). Profile fields: master sig over
   `(peer_id, updated_at, display_name, status, about_me, twitch_username, avatar_hash)`
   with prefix `"hollow-profile1:"` (`crypto_handler.rs:309-326`), REQUIRED
   (`social.rs:1372-1374`); avatar bytes must hash to the signed hash (`:1409-1415`);
   `support_creds` has its own master sig (`:1460-1487`). UNSIGNED and relay-rewritable
   while the signed part is kept: `banner_b64`, `showcase_board`, `showcase_assets_b64`,
   `avatar_frame`, `avatar_anim`, `banner_anim`, `is_invisible` (N1, open half).
5. **Timing.** Announces are live; explicit-room sends and buffered copies ≤24 h/7 d.
6. **Replay.** `save_profile` accepts a copy up to 24 h OLDER than the stored row:
   `OR (excluded.updated_at < user_profiles.updated_at AND ABS(...) < 86400000)`
   (`storage/messages.rs:2979-2981`) = relay rollback of name/status within a day; same or
   newer `updated_at` rewrites the unsigned fields at will. Device lists: union, tombstones
   max-version-wins, so replay cannot un-revoke; the relay CAN withhold a newer list (a drop).
7. **Session.** Friends and co-members hold Olm sessions; server members already get the MLS twin.
8. **Metadata.** Everything: name, status, about, twitch, avatar/banner hashes (full bytes
   on a full send), showcase, frame and animation hashes, support credentials, invisible
   flag, and the signed DEVICE LIST (device grouping), to every room peer incl. strangers.
   C-24 (profiles, device grouping), routinely.

### ProfileRequest

1. **Send.** `on_verified_sibling` if our own profile is empty (`swarm.rs:247-255`),
   RoomMembers when no profile row for that device (`:4118-4128`), `maybe_request_full_profile`
   (`social.rs:1884`).
2. **Receive.** `swarm.rs:13293-13302`.
3. **Effect.** `send_own_profile_full_to_peer` = plaintext ProfileUpdate WITH avatar, banner
   and showcase-asset bytes to `peer_str` (`social.rs:1714-1729`, `:1777-1788`).
4. **Authorisation.** None (no relationship, block or invisibility gate).
5-7. Live; each copy re-sends; no session needed today.
8. **Metadata.** On-demand full profile in plaintext for any requester the relay names. C-24.

### ProfileRequestFor

1. **Send.** RoomMembers proxy for offline server members (`swarm.rs:4130-4159`),
   post-join backfill (`:9030-9050`).
2. **Receive.** `swarm.rs:13319-13326` → `handle_profile_request_for` (`social.rs:2028-2075`).
3. **Effect.** If we cache a SIGNED profile for `target_peer_id`, send a plaintext
   `ProfileRelay` (avatar bytes included) to `peer_str`.
4. **Authorisation.** None: any sender, any target id.
5-7. Live; replayable; no session needed.
8. **Metadata.** Target id plus the answer = oracle for "does this device know X"
   (contact-graph probing) and third-party profiles in plaintext. C-24.

### ProfileRelay

1. **Send.** `social.rs:2057-2069` (answer to ProfileRequestFor).
2. **Receive.** `swarm.rs:13328-13336` → `handle_profile_relay` (`social.rs:2079-2187`).
3. **Effect.** Saves the relayed profile + avatar under `source_peer_id` if strictly newer
   (`:2137-2141`), updates member names, emits `ProfileUpdated`.
4. **Authorisation.** Subject's master sig over the signed subset, REQUIRED (`:2105-2115`);
   avatar bytes must match the signed hash (`:2126-2132`). Forwarder (`from`) irrelevant.
5. **Timing.** Live. 6. **Replay.** Strictly-newer rule: no rollback on this path.
7. **Session.** n/a (third-party data, self-authenticating).
8. **Metadata.** Third-party profile incl. avatar bytes. C-24.

### EmoteRequest

1. **Send.** `dispatch_asks` (`emotes.rs:108-148`): `SendDirect` to ONE holder, in the server
   room (channel context) or the DM-hint master's device room (`:73-103`).
2. **Receive.** `swarm.rs:13304-13309` → `handle_emote_request` (`emotes.rs:460-506`).
3. **Effect.** Replies with `EmoteAssets` for up to 20 valid hashes we hold, budgeted.
4. **Authorisation.** None (content addressing: knowing the hash is the capability).
5-7. Live (asks persist across reconnects); replay re-serves; no session needed today.
8. **Metadata.** Which asset hashes a device renders, per room. C-24 (profile media: the
   rail also carries `AssetKind::Profile` animated avatars/banners).

### EmoteAssets

1. **Send.** `emotes.rs:500-505`.
2. **Receive.** `swarm.rs:13311-13317` → `handle_emote_assets` (`emotes.rs:516-594`).
3. **Effect.** Caches blobs for hashes WE asked (`pending.get(&hash)`, `:550`), after
   size/container/canvas checks (`:558-572`); `missing` rotates the ask only from a device
   we asked (`:528-535`, `:568-570`).
4. **Authorisation.** Content hash (`asset` receipt cap). Relay `from` matters only for the
   rotation steer (can make us skip holders: a drop).
5-7. Live; replay no-op; no session needed.
8. **Metadata.** The asset BYTES in plaintext (custom emotes, stickers, GIFs, animated
   profile media). C-24.

### AutoDownloadPref

1. **Send.** `advertise_auto_dl_pref_to_peer` (`file_handler.rs:134-150`) on PeerJoined
   (`swarm.rs:3555-3564`), RoomMembers (`:4108-4116`), settings change (`file_handler.rs:155-184`).
2. **Receive.** `swarm.rs:12679-12686`: `peer_auto_dl.insert(peer_str, mb.min(2048))`.
3. **Effect.** Our DM file pushes to that device become metadata-only when
   `*mb == 0 || msg.file_size > mb MB` (`file_handler.rs:1165-1173`).
4. **Authorisation.** NOTHING beyond relay `from`. Relay alone (DoS; the receive gate
   still enforces). 5-7. Live; RAM only; no session needed today.
8. **Metadata.** Per-conversation auto-download setting.

### PeerExchange

1. **Send.** `handle_gossip_exchange` (`gossip_relay.rs:179-198`), to gossip neighbours.
2. **Receive.** `swarm.rs:13266-13290`.
3. **Effect.** Adds listed ids that are server members to `overlay.known_peers` (rotation pool).
4. **Authorisation.** Relay `from` must be a current neighbour (`:13275`); listed ids must be
   members (`:13281-13282`, J6). Relay can inject real members only.
5-7. Live; replay harmless; server members share MLS (twin possible).
8. **Metadata.** Server id + neighbour ids (relay already sees room membership).

---

## Part 6. MessageEnvelope twins inside Olm (sender = the Olm session, not forgeable)

### DirectMessage (`swarm.rs:7231-7352`; push `fetch.rs:936-938`)
- Checks: revoked device dropped (`:7244-7247`), block (`:7251-7253`), v2 sig REQUIRED with
  context `"dm"`, recipient master, `ts` and extras (`:7272-7296`); dedup by `mid`
  (`:7306-7310`). Own-sibling echo carries `convo`. Timing: relay-buffered ≤24 h/7 d, push.
  Replay: Olm refuses; `mid` dedup. Metadata: DM room pair (Part 1, Encrypted).

### DmSyncBatch (`swarm.rs:7353-7618`)
- Block check except siblings (`:7361-7365`); `mine` inverted on the friend path (`:7381`);
  per-item backfill sig "Valid or nothing" (`:7408-7421`); `change_may_touch_row` (`:7422-7425`);
  deletions need the author's proof (`:7522-7534`). Pagination sends a plaintext
  DmSyncRequest (`:7597-7604`).

### DmSiblingSyncBatch (`swarm.rs:7619-7852`)
- `same_identity(peer_str, local)` (`:7622`) on an OLM-authenticated `peer_str`, so this
  one is sound; per-item sigs and `change_may_touch_row` as above.

### SessionAck (`swarm.rs:8533-8547`; sent `:6832-6837`, `:6937-6941`, `:7007-7011`)
- Marks the session bidirectional, emits `SessionEstablished`. Olm-authenticated.

### DestroyIdentityOrder (`swarm.rs:8528-8532` → `destroy::handle_envelope_destroy_identity`, `destroy.rs:217-226`)
- Same `judge_own_order` as the plaintext twin; refused over MLS (`swarm.rs:10799-10801`).

### MessageEnvelope::ProfileUpdate
- MLS only (see Part 5); Olm copy ignored (`swarm.rs:8567`). DM-shaped envelopes over MLS
  are ignored (`swarm.rs:10789-10794`).

---

## Part 7. Cross-cutting tables

### Relay-alone, state-changing (nothing beyond `from`, or a public replayable list)

| Variant | Gate today | What the relay gets |
|---|---|---|
| FriendRemove | none (`swarm.rs:11770`) | unfriend anyone, tombstone, calls refused |
| FriendReject | stamp compare on an unsigned stamp (`:11727-11731`) | delete a pending request OR an accepted friendship (`requested_at = i64::MAX`) |
| FriendAccept | own outgoing row; unstamped copy honoured (`:11613`) | complete our outgoing request without the other side |
| FriendRequest | block only; bundle optional; stamp unsigned | fake incoming requests, drive mutual auto-accept, poison `requested_at` |
| FriendListSync | `same_identity(from)` (`:11816`) | plant accepted friends (calls, data channels), accept pending requests |
| ReadMarkers | `same_identity(from)` (`:12036`) | permanently mark conversations read (future `ts`) |
| PersonalEmoteSync | `same_identity(from)` (`:11948`) | add emotes; permanently tombstone names |
| LinkSnapshotRequest | `same_identity(from)` or link-room presence | prompt; one click = backup under a relay-known passphrase |
| LinkSnapshotKey (+stream) | `snapshot_was_asked(from)` | plant an identity on the linking device (HOL-SEC-002) |
| PeerDisconnecting | none | drop VC legs, end ringing calls, hide REC badge |
| AutoDownloadPref | none | stop our file pushes to a device |
| Encrypted (normal frame) | none before decrypt | tear down any Olm session every 5 s (A14) |
| Encrypted (replayed PreKey) | device proof has no freshness | tear down the live session (PLAUSIBLE, vodozemac UNTRACED) |
| ProfileUpdate unsigned fields | none | rewrite banner, showcase, frame, animations, invisible; roll back signed fields ≤24 h |
| DmSyncRequest / DmSiblingSyncRequest / FriendListRequest / SiblingStateSyncRequest / ProfileRequest / ProfileRequestFor | none or `same_identity(from)` | force sends; the plaintext answers leak (below) |

### C-24 leaks in this area ("never learns profiles, contact lists, or which devices belong to one person")

| Leak | Where |
|---|---|
| Full profiles (text, hashes, invisible flag, support creds) on every presence announce, to every room peer | `social.rs:1732-1825`, `swarm.rs:4058-4106` |
| Full avatar/banner/showcase bytes on demand | ProfileRequest `swarm.rs:13293-13302`, ProfileRelay `social.rs:2057` |
| Signed device lists (device grouping) | ProfileUpdate, FriendRequest/Accept/Reject, JoinInbox proof (`swarm.rs:3119-3136`), IdentityDestroyed targets |
| Friend list | FriendListSync (`swarm.rs:273-276`, `:12023-12026`, `:12082-12085`), destroy fan-out (`destroy.rs:387-414`) |
| DM contact list + per-day counts | DmSiblingSyncRequest (`crypto_handler.rs:47-66`), DmSyncRequest gap digest |
| Contact graph from room names | `dm_room_code` of masters (`types.rs:43-50`), `inbox:{master}` deposits, profile-proxy oracle |
| Read positions per conversation | ReadMarkers (`crypto_handler.rs:73-93`, `swarm.rs:2269-2275`) |
| Server list bound to identity | SiblingServerAnnounce in `inbox:{master}` (`swarm.rs:304-320`, `:12060-12069`) |
| Emote set and asset bytes | PersonalEmoteSync, EmoteRequest/EmoteAssets |
| Whole identity + DB on link | code/master id as passphrase (embargoed, HOL-SEC-002) |

### Session availability summary (for choosing "Olm twin" vs "device signature")

- Olm session normally present: FriendRemove (friends), all sibling-lane variants,
  DmSyncRequest, DmSiblingSyncRequest, ProfileRequest/Update to friends, AutoDownloadPref,
  PeerExchange (MLS too), EmoteRequest/Assets to friends and siblings.
- No session by construction: KeyRequest/KeyBundle, FriendRequest, FriendReject (async
  decline), FriendAccept (async accept; session built right after), SiblingProveRequest/
  Response, the link code path, ProfileUpdate/ProfileRequest to strangers in shared rooms.
- Self-authenticating already: IdentityDestroyed, ProfileRelay, carried profile/bundle,
  device lists (need only a freshness/recipient story, not a transport one).
