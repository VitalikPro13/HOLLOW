# Phase B re-check: authz_identity.md (devices, roster, linking, destroy, profiles)

Re-read 2026-10-02 against the current tree (HEAD d16deefe plus working tree), read-only.
Paths are relative to `rust/hollow_core/src/` unless they start with `relay-uws/` or `lib/`.
Every citation below was read in this session.

## Cross-cutting finding G1 (NEW, not in candidate_findings.md)

**A holder of the master key can act as the bare master id, and every "is this one of our
devices" gate and every contact's key-exchange gate accepts it.** That makes the master key
admit something again, which design ID-1 says it must not.

- `resolver.rs:43` `a == b || resolve(a) == resolve(b)`: `same_identity(M, local_master)` is
  true when `peer_str` IS the master id. `resolver.rs:96` `seed_self` maps
  `master -> master`, and at a contact an unknown master resolves to itself
  (`resolver.rs:35`).
- `crypto_handler.rs:639-642` `let master = super::resolver::resolve(sender_device); if master == sender_device { ... return false; }`:
  a KeyRequest/KeyBundle/PreKey from `M` is "first contact" and passes
  (`swarm.rs:7097`, `7176`, `7294-7296`).
- `frame_auth.rs:154-159` checks the seal against the key inside `from`. That key is M's
  public key, so an M-keyed seal opens. `swarm.rs:4820` drops only `from == device_peer_id`.
  The relay's comment "no socket ever authenticates as a master" (`relay-uws/src/ws_handler.cpp:410`)
  describes honest clients only. Nothing in the auth path enforces it: grep finds no refusal.
- `resolver.rs:58-60` `if device == master { return false; }`: `disowns(M, M)` is never true.
  So the MLS live gate (`swarm.rs:10565`) and `mls_authority.rs:41` `refused()` also accept a
  leaf whose device is M. That is the MLS area: UNSURE whether a commit would seat such a
  leaf. I did not read the KeyPackage/commit-add path.
- Effect at our own node: a protected identity's removed device or restored backup can
  authenticate to the relay with M's key as `M`, join `own_room` (`roster_book.rs:231-233`,
  derived from the master key it holds) or any DM room, open an Olm session, and then pass
  every sibling gate. It can pull the full DM history (`swarm.rs:10333`), friend list, server
  list, emotes and read markers (`12168`, `12249`), and DM files (`swarm.rs:13077`). It can
  also write friends, emotes, read markers and server joins (`12024`, `12108`, `12192`,
  `10395`) and self-authored DM rows (`7938`).
- Effect at contacts: `swarm.rs:7551` `is_own_device = same_identity(&peer_str, master_peer_str)`
  and `7570` `super::resolver::resolve(&peer_str)` file a DM from `M` under the owner, signed
  by the master key the attacker holds. This is the exact case
  `authz_a_stolen_backup_is_never_a_member_until_approved` asserts against
  (`test_harness.rs:29915-29918`), but that test only tries a fresh device id.
- `roster_book.rs:738-741` `carried_master`: `resolve(M) == roster.master` attributes a
  FriendRequest, Accept, Reject or ServerJoinRequest from `M` to `M` even when `M` is not a
  roster member.
- Guard test: none (no test authenticates a node as the bare master id).
- Relevant fix direction (one line): treat a bare master id as a device only when the
  master's roster names it as a member, in `same_identity`/`key_exchange_device_unauthorized`/`disowns`.
  The relay could also refuse auth as a master whose roster it holds.

## 1. Table

| Evidence id | Message / path | Verdict | Current binding (path:line + quote) | Transports checked | Guard test(s) | Notes |
|---|---|---|---|---|---|---|
| 1.0 | Call-site table of `ingest_device_list` and its helpers | GONE | `ingest_device_list`, `ingest_sibling_device_list`, `device_list_binds_sender`, `is_minimal_self_revocation`, `speaks_for` no longer exist (grep). Replaced by `roster_book::ingest` (`roster_book.rs:568`), called from ProfileUpdate `swarm.rs:12862`, MLS ProfileUpdate `social.rs:1948`, ProfileCard `swarm.rs:13526`, RosterNotice `swarm.rs:13556`, ServerJoinRequest `swarm.rs:9622`, FriendRequest `11561`, FriendAccept `11780`, FriendReject `11894`. Each carrier runs `carried_master` AFTER ingest (`swarm.rs:9630`, `11570`, `11788`, `11902`) and `enforce_device_revocations` | Olm Carried (ProfileUpdate, ProfileCard: `types.rs:4109`, `4113`), MLS, sealed plaintext Relay lane (RosterNotice, Friend*, Join lane), fetch.rs (no roster ingest found) | see A-01 | Parity gap F7 closed: all four carried arms now enforce revocations. ServerJoinRequest / FriendAccept / FriendReject still fall back to `resolve(peer_str)` when the roster is absent (`swarm.rs:9638`, `11796`, `11911`). Attribution then goes only through the resolver (members only), with G1 as the exception |
| A-01 | Foreign roster ingest | FIXED HOL-SEC-006 | Membership needs the device's own consent: `identity/roster.rs:432` `verify_by(&c.device, &consent_payload(m, &c.device), &c.sig)`, `689` `roots.retain(\|d\| consented.contains(d.as_str()));`, `694`/`699`. A removal counts only from a rooted signer, against a consented device: `roster.rs:730-733` `rooted.contains(&r.by)` / `if !rooted.contains(&r.device) && !asked.contains(...) { continue; }`. A stranger's roster is kept only when its deliverer is a member: `roster_book.rs:610-617` `if !alone.is_member(sender) {` | Olm Carried, MLS, Relay lane (RosterNotice, Friend*), Join lane | `roster_book.rs:842` `authz_a_foreign_roster_cannot_claim_or_remove_anyone_elses_devices`, `1026` `a_roster_for_a_stranger_needs_its_deliverer_as_a_member`, `roster.rs:1079` `statements_for_another_master_do_not_verify` | Unbound half (F2/F6) is HOL-SEC-077. The named HOL-SEC-006 test `a_foreign_device_list_cannot_claim_a_master_id_or_silence_a_legacy_contact` is gone; its replacement asserts `resolve(bob master)` is unchanged but never `!is_revoked(bob.peer_id())`, so the "silence a legacy contact" half has no direct assert. The code skips it anyway: Bm never consented, `roster.rs:731` |
| A-02 | Own-master roster ingest (was the sibling list, incl. SelfRevoked) | FIXED HOL-SEC-077 | Same fold: holding the master key admits nobody (`roster.rs:901` test, fold `689`). `SelfRevoked` no longer exists (grep: 0 refs). A removal now emits `DeviceRemoved` with a 3-day grace (`roster_book.rs:712-722`), and the phrase settles it (`recover`, `roster_book.rs:343`) | Olm Carried, MLS, Relay lane | `roster_book.rs:876` `authz_the_master_key_alone_makes_no_device_ours`, `1042` `authz_the_phrase_takes_the_identity_back_from_a_stolen_device`; harness `test_harness.rs:29825`, `30736` | A removed device stays "rooted" and still signs removals that count (`roster.rs:711-712` "who may sign a removal", tested by `roster.rs:980` `mutual_removal_removes_both_and_a_recovery_settles_it`). A removed thief can therefore force the owner to type the phrase within 3 days. This is the design ("the phrase is the last word") but AR-15 does not name it. Legacy base residual = AR-15 |
| A-10 | `SiblingProveRequest` (master-key signing oracle) | GONE | Variant does not exist (grep `SiblingProveRequest`: 0 refs) | n/a | n/a | Replaced by roster membership. A sibling is a device the roster names (`swarm.rs:263-285`) |
| A-11 | `SiblingProveResponse` -> `on_verified_sibling` | GONE | Proof variants gone. `on_verified_sibling` now gates on roster membership: `swarm.rs:282` `if !super::resolver::same_identity(peer_id, local_peer_str) \|\| super::resolver::is_revoked(peer_id) {`. Callers: `converge_new_siblings` for roster-`added` devices present in `inbox:{M}` (`swarm.rs:384-391`) | inbox presence (relay ID-1R gates the inbox to roster members) | `roster_book.rs:962` `authz_a_removed_device_stays_refused_after_a_restart`, harness `30679` `authz_a_removed_device_loses_the_inbox_at_once` | S4 = HOL-SEC-032 + 077. Named test `authz_a_revoked_sibling_is_not_re_bound_by_the_proof` is gone with the proof. G1 reaches this gate too, but its callers need inbox presence, which the relay ties to roster membership |
| A-12 | `SiblingServerAnnounce` | GAP | `swarm.rs:10395` `if !super::resolver::same_identity(&peer_str, local_peer_str) {`. A held server starts no join: `10408-10415`. Carried lane only (`types.rs:4100`), plaintext copy dropped at `swarm.rs:5181` `} else if msg.lane() != Lane::Relay {` | Olm Carried; plaintext refused | `test_harness.rs:29206` `authz_a_sibling_announce_for_a_held_server_starts_no_join`, `28891` `c24_the_sibling_lane_rides_olm` | S9 (relay forgery) FIXED HOL-SEC-053/056/062. GAP = G1: a master-key holder as `M` makes us start a join of a server it names, with its own owner pin (low impact) |
| A-13 | `FriendListSync` | GAP | `swarm.rs:12024` same_identity gate. Rows: `12055-12058` skip any held row except pending->accepted, then `12064` `.save_friend(&fmaster, "accepted", "", since)`, stamp capped `12062` | Olm Carried; plaintext refused (`5181`) | `test_harness.rs:29255` `c24_a_plaintext_copy_of_an_olm_only_message_is_dropped`, `28965` `authz_a_sibling_lane_stamp_never_runs_ahead_of_its_frame` | (1) G1: `M` writes accepted friends. (2) S14 still open: the removal tombstone `friend_removed:{master}` is written (`social.rs:763`, `swarm.rs:11985`) but has NO reader (grep `removed_key(`). After a removal deletes the row (`social.rs:764`), a stale genuine sibling's sync re-adds the friend as accepted |
| A-14 | `FriendListRequest` | GAP | `swarm.rs:12168` same_identity gate. Reply carried over Olm, `12180-12184` | Olm Carried | `c24_the_sibling_lane_rides_olm` | Relay exfil (P-01) closed (HOL-SEC-053/062). G1: `M` pulls the accepted friend list |
| A-15 | `SiblingStateSyncRequest` | GAP | `swarm.rs:12249` same_identity gate. Replies `12260-12284` (server announces with join keys, friends, emotes, read markers) | Olm Carried | `c24_the_sibling_lane_rides_olm` | G1: `M` pulls every server id with its join key, friends, emotes, read markers |
| A-16 | `ReadMarkers` | GAP | `swarm.rs:12192` same_identity gate. `12200-12203` stamp capped at frame time | Olm Carried | `read_markers_reach_siblings_on_verify_and_live` (`test_harness.rs:24985`), `authz_a_sibling_lane_stamp_never_runs_ahead_of_its_frame` | Relay forgery closed (053). G1 only: `M` can clear unread badges. Low |
| A-17 | `PersonalEmoteSync` | GAP | `swarm.rs:12108` same_identity gate. Validation `12122-12127` incl. `e.added_at > ceiling`, cap 512 `12114` | Olm Carried | `test_harness.rs:13920` `personal_emote_sync_from_non_sibling_is_dropped`, stamp test | G1 only: `M` plants emote rows. Low |
| A-18 | `DmSiblingSyncRequest` (serve full DM history) | GAP | `swarm.rs:10333` `if !super::resolver::same_identity(peer_str, local_peer_str) {`, then every conversation served `10343-10387` | Olm Carried | none for a refused requester | G1, High: a removed device or a never-approved restored backup authenticated as `M` receives every DM conversation, both directions |
| A-19 | `DmSiblingSyncBatch` (write sibling rows) | GAP | `swarm.rs:7938` same_identity gate. Per row `7977-7988` `check_backfill_signature(sender_m, "dm", recipient_m, ...)` + `7990` `change_may_touch_row`. MLS rejects DM envelopes (`swarm.rs:11008-11009`) | Olm only | (existing sibling backfill tests; none refusing a non-member) | Row binding holds. Through G1, a master-key holder injects `mine=true` rows it signed with the master key, so they verify as ours |
| A-20 | `LinkSnapshotRequest` | GONE | Variant does not exist (grep: 0 refs). Replaced by SPAKE2 `LinkPake`/`LinkPakeReply`/`LinkSealed` (`link_handler.rs:169-246`). A snapshot is sent only to the peer that finished the handshake: `link_handler.rs:356-361` `(p.peer.as_deref() == Some(target_peer) && key_ok)`, after the person approves (`SiblingLinkAvailable`, `288-296`) | Relay lane (sealed frame, link room) | `test_harness.rs:4102` `authz_link_frames_from_a_stranger_are_refused`, `31200` `authz_a_relay_that_answers_the_code_gets_one_guess`, `31097` `link_the_relay_cannot_open_the_snapshot` | S6 FIXED HOL-SEC-005, redesigned by HOL-SEC-002. The handshake answers once (`179` `p.peer.is_some()`), so a stranger in the code's room can burn a code (availability only) |
| A-21 | `LinkSnapshotKey` | GONE | Variant does not exist. A pending snapshot is registered only from an `Offer` that opens under the joiner's PAKE keys, from the presenter it resolved: `link_handler.rs:299` `.filter(\|j\| j.presenter.as_deref() == Some(sender))`, `304-317` | Relay lane | `authz_link_frames_from_a_stranger_are_refused` | Map is now one entry per accepted offer, no longer unbounded |
| A-22 | `StreamKind::LinkSnapshot` receive + next-launch import | FIXED HOL-SEC-005 | `file_handler.rs:2405-2408` `.is_some_and(\|state\| state.sender == sender_peer)`. Import decrypts before deleting anything: `api/storage.rs:1817-1822` "Open the blob BEFORE the identity it replaces is deleted" / `decrypt_backup_bytes(&blob, code.trim())?` / `snapshot_has_identity`, and the device key must parse (`1814-1815`) | WS binary stream | `authz_link_frames_from_a_stranger_are_refused`, `link_the_relay_cannot_open_the_snapshot` | Key = 32 random bytes sent inside the PAKE channel (`link_handler.rs:350-355`), so the old "empty code" case is gone |
| A-23/A-24 | `LinkDeclined` / `LinkSnapshotAck` | V | `link_handler.rs:415` `link.joiner.as_ref().is_some_and(\|j\| j.presenter.as_deref() == Some(sender))`, `406` `link.presenter.as_ref().is_some_and(\|p\| p.peer.as_deref() == Some(sender))`; arms `swarm.rs:12303-12320` | Relay lane | none specific (covered in spirit by `authz_link_frames_from_a_stranger_are_refused`, UNSURE whether it sends these two) | Fixed by the HOL-SEC-002 redesign. Not a numbered suspicion |
| A-30 | `MessageEnvelope::DestroyIdentityOrder` (Olm) | FIXED HOL-SEC-077 | `destroy.rs:128-151` (sig, `131` own master, `134` targets, `140` `if !authorised(&store, order) {`, `144` link time, `147` last applied) -> `crypto_handler.rs:1054-1073`: phrase signature under the pinned R, or a member device's phrase-signed permission (`1067` `members.is_member(&d.device)`). MLS refuses: `swarm.rs:11015-11016` | Olm (`swarm.rs:8858-8861`), MLS refused, relay kill list (A-32), fetch (A-33) | `roster_book.rs:1114` `authz_a_destroy_order_needs_the_phrase_once_protected`, `test_harness.rs:30860` `authz_a_destroy_order_needs_the_phrase`, `destroy.rs` `destroy_identity_signature_and_freshness_rules`, `25799` `destroy_refuses_signal_older_than_link_time`, `25862` `kill_signal_with_foreign_blob_is_dropped` | Legacy identity: the master alone suffices (`crypto_handler.rs:1054-1056`) = AR-15 |
| A-31 | `HavenMessage::IdentityDestroyed` (own + friend branch) | FIXED HOL-SEC-034 | Carried lane only (`types.rs:4114`), plaintext dropped (`swarm.rs:5181`). Own branch -> judge_own_order (`destroy.rs:258-259`). Friend branch: `destroy.rs:192` `authorised`, `197-198` known master, `203-207` floor never cleared `destroy_floor_key`. Reappearance only on a NEW member: `roster_book.rs:669-671` `if !added.is_empty() { ... note_identity_reappeared` | Olm Carried; plaintext refused | `destroy.rs:570` `authz_a_friend_destroy_order_applies_once_even_after_the_identity_returns`, `roster_book.rs:1003` `authz_only_a_new_member_means_a_destroyed_identity_returned`, harness `25921` | At a contact holding no roster for that master (`destroy.rs:97` `None => destroy_order_authorised(order, "", ...)`), the master key alone raises the banner and clears the verified flag. That is the first-contact/legacy residual of AR-15 |
| A-32 | Relay `kill_signal` (full node) | FIXED HOL-SEC-029 | Relay: one slot per issuer per target, `relay-uws/src/kill_list.h` `deposit`: `if (const Entry* own = slot(target, issuer); own && issued_at_ms <= own->issued_at_ms) return false;`, future stamps refused (`issued_at_ms > now_wall_ms + MAX_FUTURE_MS`). Client acks one signal: `destroy.rs:279` `KillAck { issued_at_ms: Some(issued_at_ms) }`, sent only on junk or a permanent reject (`280-290`) | relay kill list | `relay-uws/test/test_kill_list.cpp`, `kill_signal_with_foreign_blob_is_dropped` | Eviction fairness HOL-SEC-070. Minor note: `kill_list.h` `ack(target, issued_at_ms)` removes EVERY issuer's entry carrying that stamp, so a junk deposit with the exact millisecond of a genuine order is acked together with it. That needs the stamp, which only the relay sees. Negligible |
| A-33 | fetch.rs `handle_kill_frame` | FIXED HOL-SEC-059 | `fetch.rs:255-283`: a bare ack only after `destroy_data_root` (`273-275`), a per-signal ack for junk or a permanent reject (`261-264`, `278-282`). Same `judge_own_order` (`267-268`), roster read from the DB | push fetch socket | `fetch.rs:1502` `a_junk_kill_deposit_is_acked_alone` | |
| A-34 | Every path that ends in a wipe | V | `DestroyReceived` emitted only at `destroy.rs:167` (grep). `SelfRevoked` gone. New `DeviceRemoved` only from `roster_book.rs:431`, `718` (3-day grace, phrase lifts it). `destroy_data_root` callers: `fetch.rs:273`, FFI `api/wipe.rs:94`. Link import cannot delete before decrypt (A-22) | all | as A-30..A-33, A-22 | |
| A-40 | `HavenMessage::ProfileUpdate` | PARTIAL | Carried only (`types.rs:4109`). Text refused whole: `swarm.rs:12941` `social::profile_text_oversized(...)`, no byte slicing left in the arm. Audience: `12947`. Subject = `resolve(sender)`, signature required: `social.rs:1451-1459`, `1245` `let Some(proof) = proof else { return (master, false); };`. Every field signed: `crypto_handler.rs:368-373` `hollow-profile2` over frame/anim/showcase. Blobs must hash to the signed hash: `social.rs:1281-1283`. `saved` honest: `storage/messages.rs:3185-3187` `if written == 0 { return Ok(false); }` | Olm Carried; plaintext refused | `test_harness.rs:4169` `authz_a_remote_string_never_panics_the_node`, `social.rs:2397` `authz_an_incoming_profile_keeps_only_what_its_owner_signed`, `2448` `authz_profile_text_is_refused_whole_at_one_limit`, `27915` `c24_a_profile_never_rides_in_the_clear` | S7 HOL-SEC-007, S11/S12 HOL-SEC-038, lane HOL-SEC-062. Open sub-point = G1: a master-key holder sending as `M` publishes a master-signed profile as the owner. Stale comment `social.rs:1408-1410` says anim refs are "Deliberately NOT covered by the profile signature", but `crypto_handler.rs:370-371` covers them |
| A-41 | `MessageEnvelope::ProfileUpdate` (MLS) | PARTIAL | Sender = certified leaf, `swarm.rs:10560-10568` `if super::resolver::disowns(&sender.master, &sender.device) { ... return; }`. Same ingest/proof/save chain: `social.rs:1948-1951`, `1953`, `1999-2001`, `2010`, display name gated on `saved` `2034` | MLS; Olm arm ignores (`swarm.rs:8902`, `8910`) | as A-40 | Text now refused whole (parity with A-40 restored). Sub-point: `disowns(M, M)` is false (`resolver.rs:58-60`). A leaf with device == master is not refused here. UNSURE whether commit judging would ever seat one (MLS area) |
| A-42 | `ProfileRequest` | FIXED HOL-SEC-057 | `swarm.rs:13497` `if social::profile_audience(...) == social::Audience::None {`, else a certified co-member leaf only (`13500-13502`). Audience: `social.rs:1493-1504` (revoked -> None, data-channel peers Full, pending friend Card) | Olm Carried | `test_harness.rs:27800` `authz_a_full_profile_goes_only_to_someone_we_know` | G1: `M` resolves to us, so it gets Full (low, own profile) |
| A-43 | `ProfileRequestFor` | FIXED HOL-SEC-057 | `swarm.rs:13592-13597` `s.is_member(peer_str) && s.is_member(master_peer_str) && s.is_member(&target_peer_id)` + block check. Relays only an owner-signed profile (`social.rs:2061-2067`) | Olm Carried | `authz_a_full_profile_goes_only_to_someone_we_know` (UNSURE it exercises this arm) | |
| A-44 | `ProfileRelay` | V | `social.rs:2158-2165` signature by `source` required, `2175-2176` avatar bytes must hash to the signed hash, `2187` strictly newer only, stored under the raw `source` (`2203-2204`) | Olm Carried | `test_harness.rs:27944` `authz_a_card_or_a_relayed_profile_speaks_only_for_its_owner` | |
| A-45 | `FriendRequest.carried_profile` | GONE | Field gone. Replaced by `sealed_card`: `swarm.rs:11669-11671` `profile_card::open_from(sealed, master_peer_str, &req_master_early, requested_at)` -> `profile_card.rs:90` `(card.master == requester_master && card_holds(&card)).then_some(card)`. ProfileCard arm `swarm.rs:13535` `card.master != super::resolver::resolve(peer_str)` -> drop | Relay lane (sealed AES-GCM under the master pair key) | `authz_a_card_or_a_relayed_profile_speaks_only_for_its_owner`, `a_meeting_card_claiming_another_master_is_not_stored` | |
| (sup.) §2 | Every write to resolver state | V | Writers are now roster-only: `roster_book.rs:67-75` (forget non-members, `update_many` members), `86` `mark_revoked` + `record_revoked_devices` (persisted, warmed at start `resolver.rs:117-118`), `95` `unmark_revoked` for recovered members, `640-642`. `update` is `#[cfg(test)]` (`resolver.rs:68`) | n/a | `authz_a_removed_device_stays_refused_after_a_restart` | The "1659 row" (sibling list binds any id) is gone: every member needs consent to THIS master. The remaining weak spot is `seed_self`'s `master -> master` self-map (`resolver.rs:96`), i.e. G1 |
| (sup.) §7 | Security alert writes | V | `note_new_devices` for foreign masters from roster member diffs (`roster_book.rs:672-677`). Reappeared only on new members (`669-671`). KEY_CHANGED attributed via `resolve(peer_str)` after key-exchange checks (`swarm.rs:7186-7189`, `7314-7318`) | n/a | `authz_only_a_new_member_means_a_destroyed_identity_returned` | Under G1, a key change for `M` files under the owner |
| (sup.) §8 | ID-1 design notes | FIXED HOL-SEC-077 | consent + vouch/phrase/7-day admission (`roster.rs:684-771`), the R pin (`roster.rs:482-493`), removal union (`728-740`) | n/a | roster unit tests, mutation pass per finding | Residuals AR-15. Also G1 (master id as a device) and the removed-device-still-removes point (A-02) |

## 2. Suspicions -> candidate rows

| Suspicion | Candidate row | Row status | Current code agrees? |
|---|---|---|---|
| S1 foreign list claims a master id | F1 | FIXED HOL-SEC-006 | Yes: consent per device (`roster.rs:432`, `689`); test `roster_book.rs:842` |
| S2 foreign list revokes legacy/unbound device | F2 | FIXED HOL-SEC-006 (legacy) + HOL-SEC-077 (unbound) | Yes: removal needs a rooted or asked target that consented to that master (`roster.rs:730-733`) |
| S3 revoked device revokes the real ones | F3 | FIXED HOL-SEC-077 | Yes, as designed: no instant wipe (3-day `DeviceRemoved`), phrase settles. A removed device's removals still count (`roster.rs:711-712`, `730`): see A-02 note |
| S4 revoked sibling re-enters via proof | F4 | FIXED HOL-SEC-032 | Yes: proof path gone, sibling = roster member (`swarm.rs:282`). G1 is a different entry |
| S5 unsolicited link snapshot deletes identity | O1 | FIXED HOL-SEC-005 | Yes (`file_handler.rs:2405-2408`, `api/storage.rs:1817-1822`) |
| S6 one-click "send your data" | O2 | FIXED HOL-SEC-005 (+002) | Yes: only to the PAKE peer (`link_handler.rs:356-361`) |
| S7 ProfileUpdate byte-slice panic | G1 (class G) | FIXED HOL-SEC-007 | Yes: refused whole (`swarm.rs:12941`), no slicing |
| S8 relay kill list replace/pre-block | I2 | FIXED + DEPLOYED HOL-SEC-029 | Yes (`kill_list.h` per-issuer slot, future-stamp refusal). Minor same-stamp ack note in A-32 |
| S9 relay injects sibling lanes | A9 | FIXED HOL-SEC-053/056/062 | Relay half yes (sealed frames, Carried lane, `swarm.rs:5181`). NOT for a master-key holder acting as `M` (G1) |
| S10 destroy-notice replay loop | F8 | FIXED HOL-SEC-034 | Yes (`destroy.rs:203-208`, `roster_book.rs:669-671`) |
| S11 avatar bytes not checked; fields unsigned | N1 | FIXED HOL-SEC-038/053/062 | Yes (`social.rs:1281-1283`, `crypto_handler.rs:368-373`) |
| S12 `saved` true on refused stale row | N2 | FIXED HOL-SEC-038 | Yes (`storage/messages.rs:3185-3187`) |
| S13 first-come squatting | F6 | FIXED HOL-SEC-077 | Yes: consent per device |
| S14 FriendListSync ignores removal tombstone | NOT CARRIED | none | No: still open. `friend_removed:` tombstone is write-only (`social.rs:763`, `swarm.rs:11985`, no reader). `FriendListSync` re-adds a friend this device removed (`swarm.rs:12055-12064`). Needs a stale genuine sibling. Low |
| S15 link_handler byte-slices `target_peer` | G4 | FIXED HOL-SEC-007 | Yes: `link_handler.rs:353` char-boundary `tail` |
| A-10 observation: master-key signing oracle | none (observation) | n/a | Path GONE |
| A-14/A-15 note: relay-triggerable exfil (P-01) | A9 | FIXED HOL-SEC-053/062 | Relay half yes; G1 open |
| A-16 note: relay advances read pointers | A9 | FIXED HOL-SEC-053/062 | Relay half yes; G1 open (low) |
| A-23/A-24 note: any peer aborts or completes the link UI | NOT CARRIED (closed by HOL-SEC-002 redesign) | n/a | Yes: sender bound to the handshake peer (`link_handler.rs:406`, `415`) |
| A-42 note: anyone pulls MB blobs | A22 | FIXED HOL-SEC-057 | Yes (`swarm.rs:13497`) |
| A-43 note: who-we-know oracle | A22 | FIXED HOL-SEC-057 | Yes (`swarm.rs:13592-13597`) |
| Parity note: three carriers drop `newly_revoked`, attribute to `list.master` | F7 | FIXED HOL-SEC-033 | Yes (`carried_master` after ingest + `enforce_device_revocations` at `swarm.rs:9626-9634`, `11565-11573`, `11784-11791`, `11898-11905`). `carried_master` has the G1 hole for sender == master |
| §2 "1659 row": sibling list binds any id | (ID-1) F6/HOL-SEC-077 | FIXED | Yes |

## 3. Summary

Counts (31 rows: 28 evidence sections + 3 supplementary): V 5 (A-23/24, A-34, A-44, §2, §7),
FIXED 10 (A-01, A-02, A-22, A-30, A-31, A-32, A-33, A-42, A-43, §8), GONE 6 (1.0, A-10,
A-11, A-20, A-21, A-45), GAP 8 (A-12..A-19), PARTIAL 2 (A-40, A-41), ACCEPTED 0, UNSURE 0
as a row verdict (one UNSURE sub-point in A-41).

- GAP G1 (NEW, High): a holder of the master key (a removed device, or a restored backup the
  owner never approved) can authenticate as the bare master id. `same_identity`,
  `key_exchange_device_unauthorized` and `disowns` all accept device == master
  (`resolver.rs:43`, `96`, `58-60`; `crypto_handler.rs:639-642`). It then gets our full DM
  history, friends, servers and join keys, and DM files, and at contacts its DMs and profile
  count as the owner's. No guard test.
- GAP A-12..A-19: the sibling lanes gate on `same_identity(peer_str, local_master)` only, so
  G1 passes all of them. A-18 (full DM history) is the worst.
- GAP / NOT CARRIED S14: the `friend_removed:` tombstone is never read, so a stale sibling's
  `FriendListSync` re-adds a removed friend (`swarm.rs:12055-12064`). Low.
- PARTIAL A-40: profile fixes all present. G1 lets a master-key holder publish the owner's
  profile as `M`. Stale comment `social.rs:1408-1410` contradicts the signed payload.
- PARTIAL A-41: as A-40. UNSURE whether an MLS leaf with device == master can be seated
  (`disowns(M, M)` is false). Route to the MLS re-check.
- Note A-02: a removed device still signs removals that count (mutual removal; the owner must
  type the phrase within the 3-day grace). This is the design, but AR-15 does not list it.
- Note A-01: the HOL-SEC-006 replacement test never asserts that a legacy contact's master id
  stays unrevoked.
- Note A-31: a contact that holds no roster for a master takes a master-only destroy notice
  (banner, verified flag cleared). This falls under the AR-15 first-contact residual.
- Note A-32: a relay per-signal ack removes every issuer's entry with the same stamp
  (negligible).
- Missing named tests: `a_foreign_device_list_cannot_claim_a_master_id_or_silence_a_legacy_contact`,
  `authz_a_revoked_sibling_is_not_re_bound_by_the_proof`,
  `authz_a_carried_list_attributes_only_a_bound_sender` and
  `authz_only_a_new_device_means_a_destroyed_identity_returned` are gone. Replacements
  `authz_a_foreign_roster_cannot_claim_or_remove_anyone_elses_devices`,
  `authz_a_removed_device_stays_refused_after_a_restart`,
  `authz_a_carried_roster_attributes_only_a_member` and
  `authz_only_a_new_member_means_a_destroyed_identity_returned` exist in `node/roster_book.rs`.
  The finding files still name the old ones.
