# Authz matrix evidence: IDENTITY, DEVICES, SIBLINGS, LINKING, DESTROY, PROFILES

Read-only enumeration, 2026-09-26. Paths are relative to `rust/hollow_core/src/` unless
they start with `lib/` (Dart) or `relay-uws/`.

LINE-NUMBER NOTE: a concurrent session was editing the tree during this read (HOL-SEC-003
work: `node/crypto_handler.rs` +61 lines inserted after L596, `node/swarm.rs` +1 after L570
and +8/9 around L6709, `node/types.rs` +9 after L1413). Every line number below was
re-grepped AFTER those edits landed. If they drift again, the verbatim quotes re-locate them.
Files cited that were NOT modified: social.rs, destroy.rs, link_handler.rs, file_handler.rs,
resolver.rs, security_alerts.rs, fetch.rs, storage/messages.rs, api/storage.rs, crdt/*.

---------------------------------------------------------------------------------------------

## SUSPICION INDEX (details in the sections)

S1  CONFIRMED-BY-READING. A foreign device list can CLAIM another identity's MASTER id (and
    any device id not yet in our resolver). `speaks_for` treats "resolves to itself" as
    unbound, and a master id is never a key in the resolver map. Effects at the victim:
    device_links re-homed, resolver maps friend-master -> attacker, the victim's ACCEPTED
    friend row for that master is MIGRATED to the attacker and the original row DELETED,
    and at next boot `canonicalize_members` folds that master's server member entry and
    ROLE register into the attacker's master. Reachable by a stranger via FriendRequest's
    carried list. crypto_handler.rs:1409-1414, 1526, 1534; storage/messages.rs:2746, 3860;
    swarm.rs:822, 857; crdt/server_state.rs:431, 437.
S2  CONFIRMED-BY-READING. Same `speaks_for` gap on the `revoked` side: a foreign list can
    "revoke" a legacy (device==master) contact or any unbound device id: we drop that
    device's DMs/typing for the rest of the process, delete our Olm session with it, and if
    we are MLS coordinator queue its leaf for removal. crypto_handler.rs:1419-1433;
    swarm.rs:13417, 6067-6094, 7311.
S3  CONFIRMED-BY-READING. Revocation is not final against a revoked device (every device
    holds the master key). The binding rule checks the INCOMING list's `revoked`, never our
    stored tombstones. A revoked device signs a higher-version list naming itself in
    `devices` and the legit siblings in `revoked`: siblings get `SelfRevoked` (wipe),
    friends un-revoke it and revoke the siblings. crypto_handler.rs:867-873, 1594-1620,
    1419-1420; the design comment at crypto_handler.rs:879-884 claims the opposite.
S4  CONFIRMED-BY-READING. A revoked sibling re-enters via the sibling proof: `on_verified_sibling`
    re-binds it in the resolver BEFORE `merge_sibling_device_id` refuses it, then hands it
    our friend list, servers, read markers, emote set, and (via the rebinding) Olm sessions
    and full DM backfill. swarm.rs:199 then 206; crypto_handler.rs:1299; crypto_handler.rs:585-594.
S5  CONFIRMED-BY-READING. Remote identity/DB deletion: any peer (or the relay) can register
    a link session with `LinkSnapshotKey` and push a `LinkSnapshot` stream; we stash it with
    no check that we started a link, and the next launch DELETES identity.key,
    identity.device and messages.db BEFORE trying to decrypt. swarm.rs:12883-12889;
    file_handler.rs:2275, 2290; api/storage.rs:1756-1759; lib/src/ui/shell/hollow_shell.dart:694-695.
S6  CONFIRMED-BY-READING (one human click). Any peer can pop the global "Send your data?
    Your other device is asking to sync" dialog with `LinkSnapshotRequest`; with no link
    code claimed, Accept encrypts the full backup (identity.key included) with our PUBLIC
    master peer id and streams it to the requester. swarm.rs:12874-12880, 2183-2186;
    lib/src/core/providers/device_link_sync_provider.dart:278; hollow_shell.dart:1483-1487;
    device_link_dialog.dart:155-157, 656.
S7  CONFIRMED-BY-READING. Remote-triggerable PANIC of the swarm task: plaintext ProfileUpdate
    truncates free text with byte slicing (`display_name[..64]` etc.), which panics on a
    non-char boundary. Any room peer or the relay can kill the node. swarm.rs:13484-13487.
S8  CONFIRMED-BY-READING (relay + any authed peer). The relay kill list keeps ONE entry per
    target and replaces it on a higher relay-visible `issued_at_ms` that is not bound to the
    blob; any authed peer can deposit junk for any device id, the target acks junk, and the
    genuine remote-wipe order is gone (or pre-emptively blocked with issued_at_ms=i64::MAX).
    relay-uws/src/kill_list.h:59-66, 77-83; ws_handler.cpp:1193-1222; destroy.rs:246-249;
    fetch.rs:242-244.
S9  CONFIRMED-BY-READING (P-01 relay). Every plaintext sibling lane authorises on
    `same_identity(peer_str, local)`, i.e. on the relay-stamped `from`. A hostile relay can
    inject FriendListSync (writes "accepted" friend rows + joins DM rooms), PersonalEmoteSync,
    ReadMarkers, SiblingServerAnnounce, and trigger FriendListRequest / SiblingStateSyncRequest
    (which answer with our friend list, server list, emote set and read markers in PLAINTEXT).
    swarm.rs:12590/12624, 12719, 12807, 10847, 12775, 12820.
S10 CONFIRMED-BY-READING. Destroy-notice replay loop: `note_identity_reappeared` writes the
    destroyed marker as "" (parses to None), so any holder of an old IdentityDestroyed order
    (every notified friend, the relay) can replay it after the identity returns, and every
    re-announce of any list (even a replayed OLD one) raises "identity reappeared".
    destroy.rs:175, 178-179, 198, 85; crypto_handler.rs:1397.
S11 CONFIRMED-BY-READING (P-01 relay). Plaintext ProfileUpdate stores avatar bytes without
    comparing them to the signed `avatar_hash` (ProfileRelay does compare), and banner bytes,
    showcase board/assets, frame and anim hashes are outside the signature. The relay can
    rewrite them in flight. social.rs:1345-1356 vs 2058-2064; crypto_handler.rs:299-315.
S12 CONFIRMED-BY-READING (low). `saved` is true even when save_profile's WHERE refused a
    stale row (Ok with 0 rows), so a relay-replayed OLD signed profile still rewrites
    `member.display_name` in ServerState. social.rs:1351-1360; storage/messages.rs:2897-2899;
    swarm.rs:13565-13567; social.rs:1940-1944.
S13 PLAUSIBLE. First-come squatting of NEW device ids: whichever foreign list names an unbound
    device first owns it at this node; the real owner's later list is filtered out by the
    same `speaks_for`. crypto_handler.rs:1413-1416.
S14 PLAUSIBLE (low). FriendListSync never checks the `friend_removed:{master}` tombstone, so
    a stale (genuine) sibling can re-add a friend this device removed. swarm.rs:12605-12624.
S15 PLAUSIBLE (low). link_handler.rs:166 byte-slices relay-stamped `target_peer`
    (`&target_peer[target_peer.len().saturating_sub(8)..]`); a non-ASCII `from` (hostile
    relay) panics when the user accepts.

---------------------------------------------------------------------------------------------

## 1. Every ingest of a SignedDeviceList

### 1.0 Call-site table (all non-test callers; grep of the 5 function names)

| # | Carrier message | Call site | Pre-check before ingest | Uses ingest result for attribution? |
|---|---|---|---|---|
| 1 | HavenMessage::ProfileUpdate (plaintext, relay `from`) | swarm.rs:13410 `let ingest_outcome = super::crypto_handler::ingest_device_list(` | none | resolve(peer_str) inside save_incoming_profile (social.rs:1312) |
| 2 | MessageEnvelope::ProfileUpdate (MLS, sender = leaf credential) | swarm.rs:11195 -> social.rs:1874 `let outcome = super::crypto_handler::ingest_device_list(` | MLS decrypt only; sender = `sender_peer_id` from `decrypt_fresh` (swarm.rs:10966) | resolve(leaf) |
| 3 | HavenMessage::FriendRequest.device_list | swarm.rs:12163 | verify_device_list + device_list_binds_sender (swarm.rs:12152-12158) | resolve(peer_str) after ingest (swarm.rs:12170) |
| 4 | HavenMessage::FriendReject.device_list | swarm.rs:12471 | verify + sender in devices + not in list.revoked (swarm.rs:12455-12463) | `list.master_peer_id.clone()` REGARDLESS of whether ingest bound (swarm.rs:12476) |
| 5 | HavenMessage::ServerJoinRequest.device_list | swarm.rs:9929 | verify + sender in devices + not revoked (swarm.rs:9914-9919) | `list.master_peer_id.clone()` REGARDLESS (swarm.rs:9934) |
| - | MessageEnvelope::ProfileUpdate via Olm | swarm.rs:9161 `| Ok(MessageEnvelope::ProfileUpdate { .. })` -> "ignoring" | - | not ingested |
| - | fetch.rs push node | no device-list ingest (grep of fetch.rs for device_list/ProfileUpdate: NOT FOUND) | - | - |
| - | ServerJoinRequest sent by SiblingServerAnnounce | swarm.rs:10879-10886 sends `device_list: None` | - | falls to `None => super::resolver::resolve(&peer_str)` swarm.rs:9939 |

Other callers of the verify helpers: `verify_device_list` also in `verify_carried_bundle`
(crypto_handler.rs:751 region, `if !verify_device_list(sender_device_list)`), not a store.
`is_minimal_self_revocation` only at crypto_handler.rs:1385 and 1595. `speaks_for` is a closure
local to the foreign branch (crypto_handler.rs:1409).

Entry gate common to all: crypto_handler.rs:1357 `if list.master_peer_id.is_empty() || list.devices.is_empty() {` -> return. Then the branch:
crypto_handler.rs:1363 `if list.master_peer_id == local_master_peer_id {` -> sibling path (A-02),
else foreign path (A-01). NOTE the branch is taken on the CLAIMED master before any signature
check; the sibling path verifies itself (crypto_handler.rs:1581).

### A-01 ingest_device_list, FOREIGN master branch (friend / stranger / member list)
- Dispatch sites: rows 1-5 of the table above.
- Handler: `ingest_device_list`, crypto_handler.rs:1344.
- Target object: `list.master_peer_id`, every id in `list.devices` and `list.revoked`, and the
  delivering `sender_peer_id`.
- Checks before the FIRST state change, in order:
  1. crypto_handler.rs:1370 `if !verify_device_list(&list) {` -> signer key derives to
     `list.master_peer_id` (crypto_handler.rs:839-840 `Some(derived) if derived == list.master_peer_id => {}`)
     and signature over `"hollow-devices:{master_peer_id}:{version}:{}:{}"` (crypto_handler.rs:793-796).
     Principal: SIGNER KEY = claimed master.
  2. crypto_handler.rs:1384-1385 `if !device_list_binds_sender(&list, sender_peer_id)` `&& !is_minimal_self_revocation(...)`.
     `device_list_binds_sender` (crypto_handler.rs:867-873): `if list.revoked.iter().any(|r| r == sender_peer_id) { return false; }`
     then `sender_peer_id == list.master_peer_id || list.devices.iter().any(|d| d == sender_peer_id)`.
     Principal: relay-stamped SENDER DEVICE (or MLS leaf credential) vs the INCOMING list only.
- State changes, in order:
  1. crypto_handler.rs:1397 `super::destroy::note_identity_reappeared(` -> destroy.rs:198
     `let _ = store.save_setting(&destroyed_key(master), "");` + security alert (see A-34/S10).
     Runs BEFORE any version comparison, so a replayed OLD list triggers it.
  2. crypto_handler.rs:1409-1414 filter:
     `let speaks_for = |id: &String| {` / `if id == local_device_peer_id || id == local_master_peer_id { return false; }` /
     `let bound = super::resolver::resolve(id);` / `bound == *id || bound == list.master_peer_id`.
  3. crypto_handler.rs:1419-1420 revoked set, only when `list.version > prev_version`:
     `let mut r: Vec<String> = list.revoked.iter().filter(|d| speaks_for(d)).cloned().collect();`
     else keeps `prev_revoked`.
  4. crypto_handler.rs:1431 `super::resolver::mark_revoked(&new_revoked);` (RAM, process-lifetime).
  5. crypto_handler.rs:1441-1445 `if sender_peer_id != list.master_peer_id && !is_revoked(sender_peer_id) && speaks_for(...)` ->
     `super::resolver::update(sender_peer_id, &list.master_peer_id);`
  6. nothing-new path: crypto_handler.rs:1472 `super::resolver::update_many(` + 1481
     `store.migrate_friend_to_master(dev, &list.master_peer_id)` for merged + sender, emit
     DeviceListUpdated, return.
  7. changed path: crypto_handler.rs:1515 `store.save_device_list(` (storage/messages.rs:2739
     `DELETE FROM device_links WHERE master_peer_id = ?1` then 2746
     `INSERT OR REPLACE INTO device_links (device_peer_id, master_peer_id)` = re-homes a device
     that another master held), 1524 `super::resolver::forget_many(&new_revoked);`,
     1526 `super::resolver::update_many(`, 1534 `store.migrate_friend_to_master(dev, &stored.master_peer_id)`
     (storage/messages.rs:3852-3860 upserts the master row as accepted-if-either-accepted and
     `DELETE FROM friends WHERE peer_id = ?1` on the device key), 1548 `note_new_devices(`,
     DeviceListUpdated.
  8. Returned `newly_revoked` -> swarm.rs:13417 / 11209 `enforce_device_revocations(`:
     swarm.rs:6067-6072 Olm `olm.remove_session(id)` + `crypto_store.delete_session(`;
     swarm.rs:6078-6094 coordinator `pending_mls_removals` push for any group where
     `mls_mgr.group_members(&server_id).iter().any(|m| m == id)`.
     (FriendRequest / FriendReject / ServerJoinRequest callers discard the outcome with `let _ =`,
     so their revocations do NOT reach enforce_device_revocations; parity difference.)
- Who can sign: the master key of `list.master_peer_id`, payload above.
- Binding (signer -> each listed id): `speaks_for` crypto_handler.rs:1414
  `bound == *id || bound == list.master_peer_id`. There is NO device-side countersignature;
  a list may name any id that is not already a KEY in our resolver bound elsewhere.
  Binding for ids that are another identity's MASTER: NONE FOUND (resolver keys are devices:
  resolver.rs:55-64 `update_many` inserts only the listed devices; `seed_self` inserts
  master->master only for OUR master, resolver.rs:69-77).
- Transport parity: rows 1-2 have no pre-check (ingest's own gates only); rows 3-5 add
  pre-checks equivalent to binds_sender (rows 4-5 omit the `== list.master_peer_id` legacy
  case). Rows 4-5 attribute to `list.master_peer_id` even when ingest refused to bind the sender
  (e.g. sender already bound to another master) (swarm.rs:9934, 12476). Rows 3-5 drop
  `newly_revoked` (no Olm/MLS enforcement).
- Freshness / replay: version only matters for the REVOKED set (crypto_handler.rs:1419);
  device ADDS are union-merged at any version ("UNION-merge MINUS tombstones, never
  reject-on-stale" comment + loop crypto_handler.rs:1451-1460). No timestamp, no expiry.
  An old list replayed by the relay from a listed device can re-add a device dropped without
  revocation. `mark_revoked` is RAM-only (resolver.rs:26), lost at restart.
- Absent fields: `SignedDeviceList` fields are all `#[serde(default)]` (types.rs:69-80); empty
  devices -> ignored (1357). Absent list on ProfileUpdate -> ingest no-op (1356
  `let Some(list) = list else { return IngestOutcome::default() };`).
- Blast radius: persisted (device_lists, device_links, friends); propagates into ServerState
  via the CRDT resolver hook (swarm.rs:807 `crate::crdt::set_identity_resolver(super::resolver::resolve);`)
  and boot-time `canonicalize_members` (swarm.rs:857). Local to the ingesting node, but any
  attacker can broadcast to every peer it shares a room with.
- Tests exercising a rejection: crypto_handler.rs:4990 `a_foreign_device_list_cannot_revoke_or_claim_other_identities_devices`
  (covers OUR ids and a BOUND friend device only), 5033 `ingest_rejects_list_delivered_by_an_unlisted_device`,
  5150 `self_revocation_carve_out_admits_only_the_minimal_diff`, 5280 `carried_list_binds_the_sending_device`;
  harness test_harness.rs:21367 `replayed_device_list_from_an_unlisted_device_does_not_bind`,
  21494 `friend_request_from_an_unlisted_device_does_not_bind`, 17988 `friend_reject_with_bad_carried_list_is_dropped`,
  19238 `parked_join_with_a_bad_carried_device_list_is_dropped`. None covers an UNBOUND or
  MASTER id, or a legacy device==master contact.
- SUSPICION S1 (CONFIRMED-BY-READING): Mallory (stranger) knows Alice's master and the master id
  Bm of Alice's friend Bob (or of an owner of a server Alice is in). She signs
  `{master: M, devices: [Md, Bm], v1}` and delivers it in a FriendRequest from Md to
  `inbox:{alice}`. Checks pass (Md is listed). `speaks_for(Bm)`: resolve(Bm) returns Bm
  (not a key) -> true. Alice: device_links Bm->M persisted, resolver Bm->M, and
  `migrate_friend_to_master(Bm, M)` turns Alice's accepted friendship with Bob into an accepted
  friendship with Mallory and deletes Bob's row. The FriendRequest arm then finds
  `Some(("accepted", _, _))` for M (swarm.rs:12218) and returns silently. At next boot the
  friend sweep (swarm.rs:819-823) re-applies it and `canonicalize_members` (swarm.rs:857 ->
  crdt/server_state.rs:431 `self.members.entry(master).or_insert(info);`, 437
  `changed |= fold_lww(&mut self.roles, &resolve);`) moves Bob's member entry and role register
  under M, so Alice's node judges Mallory with Bob's role and Bob with Mallory's
  (`get_role`/`is_member`/`is_banned` all resolve first: crdt/server_state.rs:1091, 1272, 1290).
  Same via ProfileUpdate (plaintext or MLS), FriendReject, ServerJoinRequest.
- SUSPICION S2 (CONFIRMED-BY-READING): Mallory's list at a higher version with
  `revoked: [X]` where X is a legacy contact (device==master, resolver maps X->X so
  `bound == *id`) or any device id Alice has not bound yet. Alice: `mark_revoked([X])`
  -> swarm.rs:7311 `if super::resolver::is_revoked(&peer_str) {` drops X's DMs (and typing,
  swarm.rs:13354) until restart; Olm session with X deleted; if Alice is coordinator, X's MLS
  leaf queued for removal.
- SUSPICION S13 (PLAUSIBLE): first-come claim of a device Alice has not met yet; the real
  owner's list is later filtered by the same closure (crypto_handler.rs:1413-1414).

### A-02 ingest_sibling_device_list (list for OUR OWN master) incl. SelfRevoked
- Dispatch sites: the same five carriers (a list whose `master_peer_id == local master` from any
  sender). FriendRequest first returns if the sender already resolves to us
  (swarm.rs:12125 `if super::resolver::same_identity(peer_str, master_peer_str) {`), so an
  UNBOUND sender carrying our list still reaches this path.
- Handler: `ingest_sibling_device_list`, crypto_handler.rs:1568.
- Checks before first state change: 1581 `if !verify_device_list(&list) {` (our master's key);
  1594-1595 same `device_list_binds_sender || is_minimal_self_revocation` rule against the
  INCOMING list (principal: sender device vs incoming list). NO check of the sender against our
  STORED revoked set, NO check that the sender is a device we already know.
- State changes, in order:
  1. crypto_handler.rs:1618-1620 `if list.version > our_version && list.revoked.iter().any(|r| r == local_device_peer_id) {`
     -> `let _ = event_tx.send(NetworkEvent::SelfRevoked).await;` -> Dart
     lib/src/core/providers/event_provider.dart:877-881 `_selfNuke(...)` -> `wipe_api.destroyLocal()` (event_provider.dart:160).
     This is the ONLY emitter of SelfRevoked in the crate (grep).
  2. 1624-1629 merged revoked = incoming if newer else ours; 1635 `super::resolver::mark_revoked(&merged_revoked);`
  3. 1646-1652 union of `list.devices` minus revoked, NO `speaks_for` filter (any id, including
     another identity's bound device, is unioned into OUR set).
  4. 1657 `forget_many`, 1659 `super::resolver::update_many(` local master, all unioned devices.
  5. if changed: 1670-1672 re-sign with OUR master at `our_version.max(list.version).saturating_add(1)`,
     1678 save_device_list, 1682 seed_self, DeviceListUpdated; caller re-announces to every room
     peer (swarm.rs:13425-13444).
  6. 1699-1733 if sender not in merged revoked: send `FriendListSync` (our accepted friends,
     plaintext, 1714), `FriendListRequest` (1723), `request_sibling_dm_backfill` (1729),
     `send_read_markers_to_sibling` (1732).
- Who can sign: any holder of our master key = every device of the identity (swarm.rs:569
  `let master_keypair = bundle_keypair.clone();` shows each node holds it).
- Binding: sender must be in the incoming list's `devices`; NONE FOUND tying it to our stored set.
- Freshness: `version > our_version` for tombstones and SelfRevoked; union needs no freshness.
- Blast radius: SelfRevoked = irreversible local wipe; changed set is re-signed and propagated to
  every friend.
- Tests: crypto_handler.rs:5150 `self_revocation_carve_out_admits_only_the_minimal_diff` runs the
  sibling lane too, but only with the rogue INCLUDING itself in `revoked`; the variant where the
  revoked device omits itself is not tested.
- SUSPICION S3 (CONFIRMED-BY-READING): R was revoked (our stored list v5 revoked=[R]). R's
  modified client signs `{devices:[R], revoked:[A], v6}` and sends a ProfileUpdate from R to
  A (e.g. via `inbox:{master}`). binds_sender: R not in the incoming `revoked`, R in `devices`
  -> true. A: v6 > v5 and A in revoked -> SelfRevoked -> wipe. At friends (A-01): `speaks_for(R)`
  is true because R was `forget`-ed, new_revoked=[A] replaces the tombstone set, R is re-bound
  and A dropped. The comment at crypto_handler.rs:879-884 ("CRYPTO-1's sender rule is the only
  thing that makes a revocation final against exactly that attacker") does not hold: the rule
  reads only what the attacker wrote.

## 2. Every WRITE to node/resolver.rs state

Mutators (resolver.rs): `update` 48, `update_many` 55, `seed_self` 69, `warm_from_links` 81,
`forget` 119, `forget_many` 126, `mark_revoked` 136, `clear_all` 178 (+ cfg(test) `clear_for_test` 166).
Two maps: LINKS device->master (17) and REVOKED set (26, RAM only, never persisted).
`crdt::set_identity_resolver(resolve)` (swarm.rs:807) makes every ServerState role / ban /
membership lookup read LINKS.

| Call site | Fn | Data fed | Verified first? |
|---|---|---|---|
| swarm.rs:199 `super::resolver::update(peer_id, local_peer_str);` | update | routing-layer peer id of a peer that either already resolves to us (swarm.rs:3560/4218) or answered a sibling challenge (swarm.rs:10826-10835) | master-key possession only; NOT checked against our stored `revoked` (S4). Runs BEFORE merge_sibling_device_id's revoked refusal (crypto_handler.rs:1299) |
| swarm.rs:781 | warm_from_links | DB `device_links` | whatever save_device_list persisted (includes S1 claims) |
| swarm.rs:793/795 | seed_self | own stored list + this device | own data |
| crypto_handler.rs:1029 | seed_self | build_local_device_list (own) | own |
| crypto_handler.rs:1074, 1094 (forget), 1097 (mark_revoked), 1098 | seed_self/forget/mark_revoked | revoke_own_device, local FFI action | local user |
| crypto_handler.rs:1163 (forget), 1165 (mark_revoked), 1166 | forget/mark_revoked/seed_self | revoke_all_other_devices, local FFI | local user |
| crypto_handler.rs:1300, 1305, 1320 | seed_self | merge_sibling_device_id (own list + sibling proven by master key) | proof yes; revoked id refused at 1299 |
| crypto_handler.rs:1431 | mark_revoked | foreign list `revoked` filtered by speaks_for | signature + sender binding; filter admits unbound / self-mapped / master ids (S2) |
| crypto_handler.rs:1445 | update | foreign sender -> list master | binds_sender + speaks_for |
| crypto_handler.rs:1472 | update_many | foreign merged set (nothing-new path) | speaks_for-filtered earlier ingests (S1) |
| crypto_handler.rs:1524 | forget_many | foreign new_revoked | as 1431 (S2) |
| crypto_handler.rs:1526 | update_many | foreign stored.devices | speaks_for (S1, S13) |
| crypto_handler.rs:1635 | mark_revoked | our-master-signed list revoked set | signature + incoming-list binding only (S3) |
| crypto_handler.rs:1657 | forget_many | same | same |
| crypto_handler.rs:1659 | update_many | union of a sibling list's devices, NO speaks_for filter | signature only; any master-key holder can bind ANY id (incl. a friend's device) to our master |
| crypto_handler.rs:1682 | seed_self | re-signed union | same |
| api/network.rs:1751, 2587, 2771 | warm_from_links | DB device_links (push/attribution FFI) | persisted data |
| api/network.rs:2775, push_enrich.rs:215 | seed_self | own master + own device | own |
| push_enrich.rs:212 | warm_from_links | DB | persisted |
| forwarder/mod.rs:179 | seed_self | forwarder's own id | own |
| clear_all | only in #[cfg(test)] code (crypto_handler tests, social.rs tests from L2121, crdt tests) | - | no production caller found |

Consequence of the 1659 row: a sibling (or revoked sibling, S3) can bind Bob's device Bd to OUR
master at our node; then `same_identity(Bd, local)` is true and Bd passes every sibling gate
(DmSiblingSyncRequest at swarm.rs:10729 serves our FULL DM history to it; Olm key exchange is
allowed because `key_exchange_device_unauthorized` only checks `devices_for(master)`,
crypto_handler.rs:586-594). Only master-key holders can do this; relevant to ID-1.

## 3. Sibling lanes

Common fact: every plaintext HavenMessage arrives via swarm.rs:4561 `WsEvent::Message { room, from, data } | WsEvent::DirectMessage {`
and is dispatched with `&from` as `peer_str` (swarm.rs:4888 call, `&local_peer_str, &from, is_invisible,`).
`from` is relay-stamped; there is no per-frame signature on these variants. So a
`same_identity(peer_str, local)` gate authorises the RELAY's claim (P-01), and a genuine sibling.

### A-10 HavenMessage::SiblingProveRequest (sign a nonce with our master key)
- Dispatch: plaintext only, swarm.rs:10795.
- Handler: inline; swarm.rs:10800-10806 `super::crypto_handler::build_sibling_proof(master_keypair, device_peer_id, &nonce);`
  -> `send_message_to_peer(... SiblingProveResponse { nonce, sig_b64, master_pubkey_b64 })`.
- Checks: NONE (any peer, any nonce).
- Signed: `"hollow-sibling:{master_peer_id}:{device_peer_id}:{nonce}"` (crypto_handler.rs:926) with the MASTER key.
- Observation (no suspicion): an unconditional master-key signing oracle over an
  attacker-chosen suffix. Every other master-signed format I found starts with a different fixed
  prefix (`hollow-devices:` 793, `hollow-destroy:` 1214, `hollow-profile1:` 315, `hollow-msg2:/3:` 233-236,
  `hollow-crdt1:` crdt/operations.rs:80, `hollow-pack:` api/stickers.rs:429, support-creds domain bytes),
  so no cross-protocol forgery found. It also tells any stranger which master a device belongs to.

### A-11 HavenMessage::SiblingProveResponse (become a verified sibling)
- Dispatch: plaintext, swarm.rs:10809.
- Checks in order: 10813 pending challenge for THIS `peer_str`; 10817 nonce equality; 10821
  `issued_at.elapsed() >= Duration::from_secs(60)` reject; 10826 `verify_sibling_proof(local_peer_str, peer_str, &nonce, ...)`
  (crypto_handler.rs:961-962 pubkey must derive to OUR master; payload binds the challenged
  device id = routing `peer_str`). Principal: master-key possession + relay-stamped device id.
- State changes: swarm.rs:10835 `on_verified_sibling(` -> swarm.rs:199 resolver update;
  206 `merge_sibling_device_id` (persist + re-sign own list, refuses a revoked id at
  crypto_handler.rs:1299 `if revoked.iter().any(|r| r == sibling_device_peer_id) {`);
  221 re-announce profile to all room peers if grew; 232 our profile+list to sibling;
  251-254 ProfileRequest if our profile empty; 257-278 FriendListSync (our accepted friends, plaintext);
  280 personal emotes; 285 read markers; 292-295 FriendListRequest; 299 DM backfill request;
  308-320 SiblingServerAnnounce for every server we are a member of; 331-345 if we are empty,
  `link_handler::set_my_link_code(local_peer_str);` + LinkSnapshotRequest.
- Binding: proof binds (our master, challenged device, nonce). No check against our stored revoked set.
- Freshness: nonce + 60 s, in-RAM challenge map (swarm.rs:351-386).
- Tests: test_harness.rs:8962 `genuine_siblings_converge_via_proof_handshake`; 8675
  `friend_request_between_strangers_does_not_merge` (stranger rejection). No revoked-device test.
- SUSPICION S4 (CONFIRMED-BY-READING): revoked device R (modified client, still holds the master
  key) joins `inbox:{master}`; we resolve R to itself (forgotten), challenge it (swarm.rs:3568 / 4226),
  it answers, `on_verified_sibling` runs: swarm.rs:199 re-binds R to our master before
  crypto_handler.rs:1299 refuses the list merge, and every push in on_verified_sibling still
  runs. With R bound, R passes DmSiblingSyncRequest (full DM history), FriendListRequest,
  SiblingStateSyncRequest, and Olm key exchange (crypto_handler.rs:592-594 `!super::resolver::devices_for(&master)...any(|d| d == sender_device)`).
  The REVOKED set that would drop R's DMs is RAM-only and empty after a restart.

### A-12 HavenMessage::SiblingServerAnnounce (join a server our sibling created)
- Dispatch: plaintext, swarm.rs:10843. Check: 10847 `if !super::resolver::same_identity(&peer_str, local_peer_str) {` (relay-stamped sender).
- State: pending_server_joins insert, JoinRoom `server_id`, ServerJoinRequest with `device_list: None`
  to the announcer (swarm.rs:10871-10888).
- SUSPICION S9 (P-01): the relay forges `from` = one of our known siblings and makes us join any
  room name and send a join request. No privilege gain found (the responder is our own identity).

### A-13 HavenMessage::FriendListSync (write accepted friend rows)
- Dispatch: plaintext only, swarm.rs:12586. Senders: crypto_handler.rs:1714, swarm.rs:275, 12796, 12855.
- Check: 12590 `if !super::resolver::same_identity(peer_str, local_peer_str) {` (relay-stamped device -> resolver).
- State per entry: skip self (12612), skip existing row (12619-12621), 12624
  `.save_friend(&fmaster, "accepted", "", entry.requested_at)`, JoinRoom dm room (12633),
  SendDirect our full light profile + device list to `entry.peer_id` (12697-12701), then
  FriendsBackfilled event.
- Signed: unsigned (authority = relay-stamped sender). Entry status is ignored; every entry is saved "accepted".
- Freshness: none. Removal tombstone (`social::removed_key`) not consulted (S14).
- Tests: none found for a rejected FriendListSync.
- SUSPICION S9 (CONFIRMED-BY-READING, P-01): relay sets `from` to Alice's sibling device and
  injects `FriendListSync{friends:[{peer_id: M}]}`: Alice stores M as an accepted friend, joins
  their DM room and announces herself to M.

### A-14 HavenMessage::FriendListRequest (make us send our friend list)
- swarm.rs:12771; check 12775 same_identity(peer_str). Reply: our accepted friends as a
  PLAINTEXT FriendListSync to `peer_str` (12794-12797). Relay-triggerable exfil of the friend
  list (P-01) - although the relay already sees these on genuine sibling sync.

### A-15 HavenMessage::SiblingStateSyncRequest
- swarm.rs:12816; check 12820 same_identity. Sends SiblingServerAnnounce for every server we are
  a member of (12831-12840), FriendListSync (12853-12856), personal emotes (12861), read markers
  (12865), all plaintext to `peer_str`. Same P-01 note.

### A-16 HavenMessage::ReadMarkers
- swarm.rs:12803; check 12807 same_identity; emits `ReadMarkersReceived` (12813) -> Dart
  (never-regress apply). P-01 can advance read pointers (clear unread badges). Low.

### A-17 HavenMessage::PersonalEmoteSync
- swarm.rs:12716; check 12719 same_identity; per-row validation 12730-12733
  (`valid_emote_name`, `valid_emote_hash`, `source.len() > 64`, `added_at < 0`), cap 512 rows
  (12725); `merge_personal_emote_entry` (12737); asks OUR siblings for missing blobs (12755).
  Test: test_harness.rs:12175 `personal_emote_sync_from_non_sibling_is_dropped` (stranger, not relay-forged).

### A-18 HavenMessage::DmSiblingSyncRequest (serve our full DM history)
- swarm.rs:10725; check 10729 same_identity(peer_str). Serves every conversation both directions
  via `send_dm_sync_reply` Olm-encrypted `DmSiblingSyncBatch` to `peer_str` (10744-10783).
- P-01 can only trigger it (Olm to the real device). Gains meaning under S4 and the 1659 row.

### A-19 MessageEnvelope::DmSiblingSyncBatch (write sibling-supplied DM rows)
- Dispatch: Olm arm only, swarm.rs:7692; MLS arm rejects (swarm.rs:11516 region
  `| MessageEnvelope::DmSiblingSyncBatch { .. }` -> "Unexpected DM envelope via MLS").
- Checks: Olm session for `peer_str` (HOL-SEC-003 territory), 7695 same_identity, then per item
  7734 `check_backfill_signature(sender_m, "dm", recipient_m, ...)` with sender/recipient derived
  from `msg.mine` and `convo` (7715-7719), reject if not acceptable (7739).
- Binding: each row's own author signature over the DM context naming our master; the sibling
  cannot forge rows. Deletions need the author's deletion proof (7839-7843); file metadata via
  `file_meta_write_allowed` (7856).

## 4. Device linking

### A-20 HavenMessage::LinkSnapshotRequest (ask a device to push its full backup)
- Dispatch: plaintext, swarm.rs:12874; no gate (comment 12875-12877 "same_identity is deliberately NOT required").
- Handler: link_handler.rs:119 -> emits `NetworkEvent::SiblingLinkAvailable` (link_handler.rs:127).
- Dart: device_link_sync_provider.dart:278 `if (state.phase == LinkPhase.waiting || state.phase == LinkPhase.receiving) return;`
  (idle passes) -> confirmPush; hollow_shell.dart:1483-1487 pops `showDeviceLinkDialog` globally;
  device_link_dialog.dart:155-157 does NOT mint a code when the phase is already confirmPush;
  copy device_link_dialog.dart:656 `'Your other device is asking to sync. This sends your full history and identity to it.'`
  (the requester's id is not shown).
- On Accept: swarm.rs:2179-2186 code = pending_link_code, else `_ => local_peer_str.to_string(),`
  -> link_handler.rs:151 `export_backup_bytes(link_code, ...)` (identity.key inside) streamed to the
  requester (link_handler.rs:171-193).
- SUSPICION S6 (CONFIRMED-BY-READING; needs one click): Mallory (server co-member, friend, inbox
  visitor, or the relay) sends LinkSnapshotRequest; Alice sees "Your other device is asking";
  one click sends her identity backup encrypted with her public master peer id. Broader than
  HOL-SEC-002 (the passphrase here is public to everyone, not just the relay).

### A-21 HavenMessage::LinkSnapshotKey (register an inbound link session)
- Dispatch: plaintext, swarm.rs:12883; no gate at all.
- State: link_handler.rs:208 `pending_link_snapshots.insert(link_id.to_string(), LinkSnapshotState { code });`
  with `code = my_link_code()` = "" unless set (link_handler.rs:34-35 `unwrap_or_default()`).
  Map is unbounded (any number of link_ids).

### A-22 StreamKind::LinkSnapshot receive (stash a backup for next-launch import)
- Dispatch: WsEvent::BinaryDirect swarm.rs:4386 -> ws_stream_receive (accepts unsolicited first
  chunks of TYPE_LINK, node/ws_stream_transfer.rs:336-363) -> file_handler::handle_completed_stream
  (swarm.rs:4404) -> file_handler.rs:2237-2241 -> `handle_link_snapshot_stream` file_handler.rs:2261.
- Check: file_handler.rs:2275 `let Some(state) = pending_link_snapshots.remove(&link_id) else {` only.
  No check that we initiated a link, that the sender is the peer we resolved, or that the sender
  is the one who sent the LinkSnapshotKey.
- State: 2290 `crate::api::storage::stash_pending_link(&blob, &state.code)` (api/storage.rs:1728-1731
  writes pending_link.hollow + pending_link.code), 2302-2305 LinkSnapshotAck, 2307 LinkComplete.
- Next launch: hollow_shell.dart:694-695 `if (await storage_api.hasPendingLink()) { await storage_api.importPendingLink(); }`
  before unlock -> api/storage.rs:1756-1759 deletes `"identity.key", "identity.device", "messages.db", ...`
  BEFORE 1761 `import_backup_bytes(&blob, code.trim())`; 1764-1765 stash removed regardless.
- SUSPICION S5 (CONFIRMED-BY-READING): Mallory in any shared room (inbox, server, DM) or the relay
  sends LinkSnapshotKey{link_id:"link_x"} then a TYPE_LINK stream with id "link_x" and junk bytes.
  Alice's next launch deletes her identity and database; import fails; Welcome screen. If the
  blob is a valid `.hollow` encrypted with "" (the default code), Alice's device imports
  Mallory's chosen identity instead (PLAUSIBLE: depends on argon2 accepting an empty password).
- Tests: none found for an unsolicited link snapshot.

### A-23 HavenMessage::LinkDeclined / A-24 HavenMessage::LinkSnapshotAck
- swarm.rs:12892 / 12900: no gate; UI events only (`LinkFailed` "declined by other device",
  `LinkPushComplete`). Any peer can abort or falsely complete a link UI. Low.

## 5. Destroy

### A-30 MessageEnvelope::DestroyIdentityOrder (Olm sibling lane)
- Dispatch: Olm arm swarm.rs:9044 -> destroy.rs:207 -> apply_own_order (always the own branch).
  MLS arm rejects: swarm.rs:11524 `MessageEnvelope::DestroyIdentityOrder { .. } => {` + log.
- Handler: destroy.rs:131 `apply_own_order` -> destroy.rs:100 `judge_own_order`.
- Checks in order: 107 `if !verify_destroy_identity(order) {` (pubkey derives to claimed master,
  crypto_handler.rs:1248-1269, payload `"hollow-destroy:{master}:{issued_at_ms}:{targets csv}:{notify_friends}"`
  crypto_handler.rs:1214); 110 `if order.master_peer_id != local_master {`; 113 targets empty or
  name this device; 119-121 `if linked_at > 0 && order.issued_at_ms < linked_at {`;
  123 `if order.issued_at_ms <= last_applied(local_device) {`; 126 `mark_applied` (RAM).
- State: destroy.rs:143 `NetworkEvent::DestroyReceived` -> Dart event_provider.dart:883-887 `_selfNuke`.
- Binding: signer == our master (110). Link stamp written once per device at node start
  (swarm.rs:1027 `super::destroy::stamp_device_link(`; destroy.rs:71-78).
- Freshness: link stamp (persisted) + last_applied (RAM, deliberately not persisted, destroy.rs:21-28).
- Tests: destroy.rs:431 `destroy_identity_signature_and_freshness_rules`, 490, 503;
  test_harness.rs:23776 `destroy_refuses_signal_older_than_link_time`, 23841 `kill_signal_with_foreign_blob_is_dropped`.

### A-31 HavenMessage::IdentityDestroyed (plaintext twin + friend notice)
- Dispatch: plaintext swarm.rs:12578 -> destroy.rs:218; branch 226 `if order.master_peer_id == local_master {`
  -> own order (A-30 rules) else `apply_friend_order` (destroy.rs:157).
- Friend branch checks: 163 verify signature; 169-170 master known (friend row OR stored device
  list); 175 `if identity_destroyed_at(&store, &master).is_some_and(|prev| order.issued_at_ms <= prev) {`.
- Friend branch state: 178 `save_setting(&destroyed_key(&master), ...)`, 179
  `store.remove_peer_verified(&master)`, 181 `IdentityDestroyedByFriend` -> Dart banner +
  verified reload (event_provider.dart:890-895).
- Parity: Olm lane never runs the friend branch; MLS rejects; plaintext does both.
- SUSPICION S10 (CONFIRMED-BY-READING): after the identity returns, destroy.rs:198 writes "" and
  destroy.rs:85 `.and_then(|v| v.parse::<i64>().ok())` reads it as None, so the SAME old order
  passes 175 again. Anyone who received the plaintext notice (every friend when notify_friends,
  destroy.rs:375-402, and the relay) can replay it forever: banner back on, verified flag removed
  each time. And crypto_handler.rs:1397 clears it on ANY bound list, a replayed old one included,
  raising a false "identity reappeared" alert. Relay alone can toggle both ways.

### A-32 WsEvent::KillSignal (relay-parked order, full node)
- Dispatch: swarm.rs:4420 -> destroy.rs:237 `handle_kill_signal`. Undecodable blob -> KillAck
  (destroy.rs:246-249); judged by apply_own_order; ack on RejectPermanent (254-256).
- Relay side: relay-uws/src/ws_handler.cpp:329-332 delivers `state.kill_list.find(peer_id)` on auth;
  1193-1222 `handle_kill_deposit` accepts any non-guest, non-fetch socket, any peer-id-shaped
  target, relay-visible `issued_at_ms` not bound to the blob; kill_list.h:63
  `if (it != entries.end() && issued_at_ms <= it->second.issued_at_ms) return false;` else REPLACE
  (one entry per target); kill_list.h:77-83 `ack` erases. Client ignores the stored count
  (node/ws_client.rs:1311-1313 logs only).
- SUSPICION S8 (CONFIRMED-BY-READING): Mallory (any authed user) deposits junk for Alice's stolen
  device D with issued_at_ms = i64::MAX: it replaces Alice's genuine order (or blocks any later
  one), D receives junk, acks, and survives.

### A-33 fetch.rs handle_kill_frame (push isolate)
- fetch.rs:110 per text frame; 227-267: `kill_signal` JSON -> decode (junk -> ack, 242-244) ->
  `judge_own_order` (246) -> Apply: `crate::api::wipe::destroy_data_root(&root)` (252) + ack.
- Same rules as A-30 (fresh process, so `last_applied` is always 0 there). Same S8 exposure.

### A-34 Paths that end in a wipe (complete list found)
1. `NetworkEvent::SelfRevoked` <- crypto_handler.rs:1620 only (A-02), reachable over the 5 carriers.
2. `NetworkEvent::DestroyReceived` <- destroy.rs:143 only (A-30, A-31 own branch, A-32).
3. `api::wipe::destroy_data_root` <- fetch.rs:252 (A-33) and Dart `_selfNuke` for 1-2.
4. NOT a wipe event but destroys identity+DB: `import_pending_link` (A-22, S5).
Security-alert side effect of destroy: A-31 / crypto_handler.rs:1397.

## 6. Profiles

### A-40 HavenMessage::ProfileUpdate (plaintext)
- Dispatch: swarm.rs:13389 (any peer sharing a room; relay-stamped `from`).
- Order: 13392-13397 invisible flag -> PeerStatusChanged for `peer_str`; 13410 device-list ingest
  (A-01/A-02); 13417 enforce revocations; 13425-13444 re-announce; 13452-13479 friend-request drain
  keyed on the freshly learned master; 13484-13487 truncation; 13533 `social::verified_profile_proof(`;
  13540 `social::save_incoming_profile(`; 13554 maybe_request_full_profile; 13565-13567 member
  display name; ProfileUpdated.
- Checks before the profile write: social.rs:1513-1518 signature over
  `profile_signing_payload(peer_id=resolve(sender), updated_at, display_name, status, about_me, twitch_username, avatar_hash)`
  (crypto_handler.rs:299-315), key must derive to that master (crypto_handler.rs:356 ->
  verify_message_signature). social.rs:1317 `let Some(proof) = proof else { return (master, false); };`
  (no proof = no write). social.rs:1325-1333 empty-name guard. support_creds: social.rs:1400-1403
  older updated_at preserves, 1405 `verify_support_creds_sig` (own master sig) then
  `sanitize_incoming_support_creds`. Images: social.rs:1345-1350 `gated_profile_image`.
- Subject binding: the subject IS `resolve(sender)` (social.rs:1312); the signature is checked
  against that master (social.rs:1518). Correct as long as the resolver is correct (see S1).
- Unsigned fields (stored if the text signature verifies): avatar BYTES (hash in payload but not
  compared), banner bytes, showcase_board, showcase_assets, avatar_frame, avatar_anim, banner_anim
  (sanitised shape only: social.rs:1424-1469).
- Freshness: save_profile WHERE (storage/messages.rs:2897-2899) accepts newer, or older within
  86 400 000 ms. support_creds has its own older-than-stored rule.
- SUSPICION S7 (CONFIRMED-BY-READING): swarm.rs:13484
  `let display_name = if display_name.len() > 64 { display_name[..64].to_string() } else { display_name };`
  (same for status [..96], about_me [..256], twitch_username [..64], 13485-13487). A 63-ASCII +
  one multibyte-char name panics the `run_event_loop` task (tokio::spawn, swarm.rs:485; no
  catch_unwind in the crate outside dfn_ffi.rs). Sender: anyone in a shared room, or the relay.
  `clip_text` (crypto_handler.rs:1749) exists for exactly this and is not used here.
  The MLS twin does not truncate (no panic, but no caps either; parity difference).
- SUSPICION S11 (CONFIRMED-BY-READING, P-01): the relay rewrites avatar_b64 in a full profile
  reply (ProfileRequest answers are plaintext, social.rs:1645-1660/1751-1753) and the new bytes
  are saved: save_incoming_profile never compares `profile_blob_hash(avatar)` with the signed
  hash, while handle_profile_relay does (social.rs:2058-2064). Banner/showcase/frame/anim are
  unsigned on this path (avatar_frame/anim acknowledged in social.rs:1460-1462).
- SUSPICION S12 (low): stale replay still sets `member.display_name` (see index).
- Tests: crypto_handler.rs:4251 `profile_signature_binds_subject_and_every_field`, 4305
  `relay_tampering_with_an_own_profile_update_fails`; social.rs:2202/2246 image bombs,
  2360 `unsigned_support_creds_is_refused_and_preserved`.

### A-41 MessageEnvelope::ProfileUpdate (MLS)
- Dispatch: MLS arm swarm.rs:11188 -> social.rs:1834 `handle_envelope_profile_update`; sender =
  MLS leaf credential (swarm.rs:10966). Olm arm ignores it (swarm.rs:9161).
- Same chain as A-40 via social.rs:1874 ingest, 1908 verified_profile_proof, 1917 save,
  1940-1944 display name gated on `saved`. Blob pre-filter 2 MB for avatar (social.rs:1887) vs
  1 MB on plaintext (swarm.rs:13498). No text truncation.

### A-42 HavenMessage::ProfileRequest
- swarm.rs:13994; no gate; replies with our FULL profile incl. blobs and device list in plaintext
  (social.rs:1645 `send_own_profile_full_to_peer`). Any peer can pull MB-sized blobs repeatedly
  (per-peer message rate limiter only, swarm.rs:4576-4596).

### A-43 HavenMessage::ProfileRequestFor
- swarm.rs:14020 -> social.rs:1955; no gate; relays the stored SIGNED profile of any
  `target_peer_id` we hold (social.rs:1966-1996). Leaks who we know. No write.

### A-44 HavenMessage::ProfileRelay
- swarm.rs:14029 -> social.rs:2006. Checks: 2031-2036 over-long fields REJECTED; 2037
  `verify_profile_signature(&source_peer_id, ...)` (key must derive to `source_peer_id`);
  2058-2064 avatar bytes must hash to the signed hash; 2069-2073 strictly newer only.
- Writes: 2094 `store.save_profile(&source_peer_id, ...)` (stored under the RAW source id, not
  resolved); 2107-2113 member display name under `resolve(&source_peer_id)`; ProfileUpdated.
- Binding: source_peer_id <-> signing key (verify_message_signature). Good.

### A-45 FriendRequest.carried_profile
- swarm.rs:12261-12270 -> social.rs:197 `store_carried_profile(profile, &req_master_early, ...)`.
- Checks: social.rs:205-206 `let source_master = super::resolver::resolve(&profile.source_peer_id);`
  `if source_master != sender_master {` (sender_master = resolve(peer_str) after the carried-list
  ingest); 215-218 over-long -> reject; 226 signature by `source_master`; 253 save_profile under
  `source_master` with no blobs. Only the subject's own signature can write the subject's row.
- Test: test_harness.rs:16736 `friend_request_carries_sender_profile` (positive).

## 7. Security alert writes (node/security_alerts.rs)

`record` (security_alerts.rs:44) -> storage/messages.rs:5037-5044 `INSERT OR IGNORE` keyed
`"{kind}:{peer_id}:{detail}"`. Remote frames that create alerts:
- KIND_NEW_DEVICE (24): only crypto_handler.rs:1548 (A-01 changed path), subject =
  `stored.master_peer_id` (the SIGNER's own identity), skipped on first contact
  (security_alerts.rs:98-100) and for our master (95-97). A stranger can only raise alerts about
  itself. Devices filtered out by `speaks_for` never alert (so S1/S13 claims of someone else's ids
  alert only under the attacker's name, and only when the attacker had a prior list).
- KIND_IDENTITY_REAPPEARED (27): destroy.rs:200 via crypto_handler.rs:1397; fires for ANY bound list
  of a master marked destroyed, including a replayed old list (S10). Dedup id is constant per
  master, so after acknowledgement it does not re-raise (INSERT OR IGNORE).
- KIND_KEY_CHANGED (30): security_alerts.rs:137 `note_olm_identity_key`, called from swarm.rs:6612
  (KeyBundle, after verify_key_exchange + key_exchange_device_unauthorized), 6748, 6818 (PreKey paths);
  subject = `resolve(peer_str)`, so under S1 a key change of a re-homed id files under the wrong master.
- Clearing: only local FFI `acknowledge_security_alerts_for_peer` (api/verification.rs:151) and
  `acknowledge_security_alert`; no remote frame clears an alert (grep). `remove_peer_verified` IS
  remote-triggerable via A-31 (destroy.rs:179).

## 8. Notes for design ID-1

Who can add a device to an identity:
- Any holder of the master key signs a list (build_signed_device_list crypto_handler.rs:803);
  every device holds it (swarm.rs:569). Friends union any listed device at ANY version
  (crypto_handler.rs:1451-1460) and warn only if they already had a baseline (security_alerts.rs:98).
- Our own node adds any device that proves master-key possession (A-11, merge_sibling_device_id
  crypto_handler.rs:1278) or appears in any our-master-signed list (crypto_handler.rs:1646-1652,
  no speaks_for filter).
- No device-side consent: a list can name ids whose keys the signer does not hold (S1, S13).
  Nothing in `SignedDeviceList` (types.rs:67-81) carries a per-device signature.
What happens when a device is removed:
- Tombstone in `revoked`, max-version-wins (crypto_handler.rs:1419-1420, 1624-1629); friends
  `forget` + RAM `mark_revoked`; siblings SelfRevoke the named device (1618-1620).
- The removed device keeps the master key: it can un-revoke itself at friends and wipe or revoke
  the remaining devices (S3), and re-enter via the sibling proof (S4). The only persisted memory
  of the revocation is our own stored list's `revoked` array, which neither the binding rule nor
  the sibling-proof path consults (merge_sibling_device_id does, crypto_handler.rs:1299, but only
  after swarm.rs:199 already re-bound the device).
- A sole device's self-revocation list has empty `devices` and is ignored by every receiver
  (crypto_handler.rs:1357 `|| list.devices.is_empty()`).
Can a device list expire:
- NOT FOUND. No timestamp/expiry field in SignedDeviceList (types.rs:67-81); `version` is a bare
  u64 compared only for tombstones and SelfRevoked; device_lists rows have `updated_at` (storage
  schema storage/messages.rs:1070-1076) but no reader uses it for expiry (grep of load_device_list
  callers shows none).
