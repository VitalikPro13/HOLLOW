# Phase E+F slice "mls": MLS groups, subgroups, meetings, KeyPackages, commits, Welcomes, persistence

Session 34, merged phase E (STRIDE, protocol checklist, 13 classes) and phase F (code review).
Code read in the detached worktree `D:/dev/wt/s34-ef` at `aa104d48`. OpenMLS read in the cargo
registry (`openmls-0.9.0`, `tls_codec-0.5.0`, `openmls_basic_credential-0.6.0`). Nothing was
built or run: every verdict below comes from reading code, and the tests named are the ones a
fix should add or the ones that already guard a requirement.

## Scope

- Elements: E-02's MLS parts.
  - P1 `crypto/mls_manager.rs` (MlsManager: leaf classification, staging, encrypt/decrypt, export, storage snapshot)
  - P2 `node/mls_authority.rs` (commit, Welcome and planning rules)
  - P3 the MLS ingress arms (`node/swarm.rs` 10747-11793) and their helpers in `node/crypto_handler.rs` (commit apply, epoch hints, probes, subgroup reconcile), `node/fetch.rs` MLS arm
  - P4 the committer (the batch timer, `node/swarm.rs` 5440-5742)
  - P5 the meeting MLS paths (`node/conference.rs`)
  - DS1 the CryptoStore actor and the `mls_identity` row (`crypto/store.rs`, `storage/messages.rs` 2885-2903)
  - DS2 the in-RAM state (OpenMLS MemoryStorage, commit cache, held commit/Welcome slots, pinned committers, leaf cache)
- Flows: F-32 (KeyPackages live, parked in the join box and in knocks; commits live and catch-up;
  Welcomes; KeyPackage requests; epoch probes), F-33 (MLS channel messages, subgroups
  `{server}#{channel}`, topic rings, push fetch), F-37 (meeting groups `conf:{id}`), F-31 only
  where MLS state is adopted after a join.
- External interactors: X-2 relay, X-3 peers (members, owner, meeting host and guests), X-4 own siblings.
- Specs: RFC 9420 and RFC 9750, every obligation that falls on the application (we are both
  the Authentication Service and the Delivery Service).
- Leads: L-03, L-08.

## Summary

- STRIDE cells walked: 63 (5 processes x 6, 2 stores x 3, 7 flows x 3, 3 interactors x 2).
- Candidates: 8. Medium 4 (C-MLS-01, -02, -04, -05), Low 4 (C-MLS-03, -06, -07, -08). Plus Info notes (end of the Candidates section).
- Requirements: 26 (R-MLS-01..26), of which 6 are NOT met today (R-MLS-08, -09, -20, -21, -22, -23).
- Leads: L-03 holds at every entry point, with the Welcome-tree gap C-MLS-03 and the repair-rule gap C-MLS-01. L-08 holds for atomicity (the whole OpenMLS store is one snapshot written in one statement); its residuals are rollback windows and unbounded growth (C-MLS-08), not torn state.
- Release-relevant: C-MLS-04 is a time bomb rather than an attack. If it is real (SUSPECTED, from OpenMLS source), servers start failing every Welcome roughly 84 days after 0.12's migration repairs re-key their leaves. The fix is one builder call.

## Candidates (most severe first)

### C-MLS-01: Any member can throw any other member out of the server's encryption group, as often as it likes, by replaying that member's old KeyPackage as a "repair"

- Severity: Medium (Impact M: the victim loses live server traffic and every member loses an epoch twice per cycle, voice included; Exploitability H: plain membership and a modified client, no race).
- Attacker: P-05 (any member holding a leaf); the replay material is in every member's hands.
- Confidence: CONFIRMED (receiver rule, victim path and OpenMLS validation traced).
- Code: the receiver's removal rule accepts any commit that re-adds the removed device, with no check that the KeyPackage is fresh or was minted for this repair:
  `rust/hollow_core/src/node/mls_authority.rs:46-52`
  ```
  fn removable(leaf: &LeafView, committer: &LeafIdentity, adds: &[LeafView], rules: &GroupRules) -> bool {
      let Some(target) = leaf.bound() else { return true };
      target.master == committer.master
          || refused(target)
          || rules.membership(&target.master, "") != Verdict::Accept
          || adds.iter().any(|a| a.bound().is_some_and(|b| b.device == target.device))
  }
  ```
  Every member holds a valid KeyPackage of every other member: an Add proposal carries the
  whole KeyPackage (`crypto/mls_manager.rs:1047-1050` `adds: staged.add_proposals().map(|p| leaf_node_view(&self.leaf_cache, p.add_proposal().key_package().leaf_node()))`),
  and a parked joiner's KeyPackage is opened by every member that holds the door and invite key
  (`node/swarm.rs:10291` `if parked && let Some(kp_b64) = key_package.as_ref() {`). OpenMLS
  re-checks only the signature and the lifetime (about 84 days, `openmls-0.9.0/src/key_packages/lifetime.rs:13`),
  and its key-uniqueness check drops the removed leaf's keys first
  (`openmls-0.9.0/src/group/public_group/validation.rs:206-226`), so the very KeyPackage that
  seated the victim passes again. The victim accepts the commit too and treats its own eviction
  as an honest repair, waiting for a Welcome it can never open (the KeyPackage's private half was
  deleted when it first joined):
  `node/crypto_handler.rs:2686-2694`
  ```
          // A repair. Its Welcome is on its way, so asking for a leaf here answers a
          // question already being answered and restarts the loop. Stamp the throttle
          // WITHOUT sending, which alone silences the opportunistic sends.
          mls_bootstrap_requested.insert(group_key.to_string(), std::time::Instant::now());
  ```
  The ghost leaf keeps the victim's device id, so other members also stop sending it the Olm copy
  meant for leafless devices. After the 6 s grace the victim asks again, the owner repairs it in
  one commit, and that commit hands the attacker the next fresh KeyPackage. One commit can do this
  to every member at once.
- Variants found:
  - (b) A member can also force a repair of ITSELF every batch tick (2 s) by sending fresh KeyPackages: the coordinator queues removal plus re-add for any sending device that already has a leaf, with no throttle (`node/swarm.rs:11546-11549` `if mls_mgr.group_members(&group_key).contains(&peer_str.to_string()) {`). An epoch, and an SFrame re-key for everyone in voice, every tick.
  - (c) One held-commit slot per group (`crypto/mls_manager.rs:1075-1078` `self.held_commits.insert(server_id.to_string(), HeldCommit { ... })`): a member's commit that Holds overwrites a genuine held commit whose bytes can never be processed again, which forces a repair of a member whose CRDT view lags.
- Why it breaks: design D principle 2 and section 3 ("a current member's leaf is removed only as part of a repair, when that device's FRESH KeyPackage is in the same commit"); RFC 9420 section 16.8 and RFC 9750 section 5.1 (a KeyPackage adds its client once). Variant of HOL-SEC-042.
- Test: harness `authz_a_member_cannot_evict_a_member_with_its_old_key_package`. `setup_epoch_race_trio`; record V's KeyPackage (`relay.set_recording` plus `recorded_key_packages`, or take it from the commit that added V); C builds `hostile_mls_copy(...).commit_membership(&server_id, &[v.device_id], &[(v.device_id, v_old_kp)])` and injects it to O and V; assert with `expect_group_unchanged` that V keeps its group and O's epoch does not move. Fails today.
- Fix idea: receivers count a re-add as a repair only when the KeyPackage is newer than the leaf it replaces (its lifetime `not_before` later than the removed leaf's, or its hash ref never seen in an Add of this group, kept per group), and the committer throttles self-repairs per device unless a probe showed a fork.

### C-MLS-02: A removed member keeps reading new server messages from any member that missed the one removal commit, which a hostile relay can arrange at will (withheld revocation)

- Severity: Medium (Impact H: C-14, a removed member reads content sent after its removal, including restricted channels (C-18) through the same subgroup path; Exploitability L/M: needs the removed member to still receive the room's frames (a hostile relay P-01, a legacy 32-hex server whose room stays open (AR-16), or the 60 s door grace) and a member that missed the commit, which the relay forces by dropping one 0x03 frame).
- Attacker: P-01 colluding with or run by P-06 (a self-hosted relay operator kicked from a server on their own relay is the plain case).
- Confidence: CONFIRMED for the missing gate (every send site traced); the delivery side depends on the relay or a legacy room, as stated.
- Code: the removal is ONE unbuffered room broadcast from the kicker (`node/sync_handler.rs:433` `match mls_mgr.remove_identity_leaves(server_id, &owned) {` then `node/crypto_handler.rs:2508-2511` `ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom { room_code: server_id.to_string(), data, })`). A member that misses it learns the kick from the carried CRDT op, but nothing on the send path compares the group's leaves with the CRDT:
  `node/crypto_handler.rs:2100-2105`
  ```
      let group_key = match channel {
          Some(cid) => crate::crypto::subgroup_id(server_id, cid),
          None => server_id.to_string(),
      };
      let json = serde_json::to_string(envelope).map_err(|e| format!("serialize: {e}"))?;
      let ciphertext = mls.encrypt(&group_key, json.as_bytes()).map_err(|e| format!("encrypt: {e}"))?;
  ```
  (the topic path is the same at `node/crypto_handler.rs:2181`). `stale_leaves` is called only by coordinators (`node/crypto_handler.rs:1962`, `node/swarm.rs:11536`). Nobody notices the stale sender either: receivers keep three past epochs (`crypto/mls_manager.rs:29` `const MAX_PAST_EPOCHS: usize = 3;`), so they read its old-epoch frames happily, and the stale member only probes when it receives a newer frame, which the same relay can withhold.
- Why it breaks: C-14, C-18, C-25; RFC 9750 section 8.4.2 and RFC 9420 section 16.9 (a malicious DS withholds commits); class 4. HOL-SEC-042's variants already note "a relay can still withhold commits" with no remedy and no accepted risk.
- Test: harness `authz_a_member_that_missed_a_removal_commit_never_encrypts_to_the_removed_leaf`. O, V, M; take `hostile_mls_copy` of M; `relay.set_broadcast_deaf(&v.device_id, true)` while O kicks M (V gets the op over Olm, not the commit); V posts in a channel; assert M's copy cannot decrypt V's post. It can today.
- Fix idea: before every MLS encrypt, refuse when the group holds a bound leaf whose certified master our CRDT no longer seats (`stale_leaves` minus legacy unbound leaves during migration): fall back to the Olm path to current members and send an epoch probe. Also, when we decrypt an application message sealed at a past epoch, send that sender an epoch hint so a stale member learns it is behind.

### C-MLS-04: Time alone, no attacker: once one member's leaf goes about 84 days without being replaced, no device can join or be repaired into that group

- Severity: Medium (Impact M: the group admits nobody, and every rejoin attempt costs the group an epoch; a joiner that is seated as a ghost leaf also gets no Olm fallback copies; Exploitability: not an attack, it happens by itself; 0.12's migration re-keys most leaves at once, so many servers would reach the mark together about three months after release).
- Confidence: SUSPECTED (traced through OpenMLS 0.9 source; not run).
- Code: we stage Welcomes with OpenMLS's default lifetime policy, which validates the lifetime of every never-updated leaf in the received tree:
  `crypto/mls_manager.rs:879-883`
  ```
          let staged = StagedWelcome::build_from_welcome(&self.provider, &hollow_join_config(), welcome)
              .map_err(|e| format!("Failed to process Welcome: {e:?}"))?
              .replace_old_group()
              .build()
              .map_err(|e| format!("Failed to stage Welcome: {e:?}"))?;
  ```
  OpenMLS: `group/mls_group/creation.rs:1293` `validate_lifetimes: LeafNodeLifetimePolicy::Verify,` (the opt-out is `skip_lifetime_validation()` at 1313); `group/public_group/mod.rs:308` `public_group.validate_leaf_node_inner(leaf_node, validate_lifetimes)` over every leaf; `group/public_group/validation.rs:882-886` rejects an expired lifetime. A leaf keeps its KeyPackage lifetime until its owner commits with a path, and Hollow never self-updates: add-only commits carry no path (`messages/proposals.rs:185-193`, Add is not path-required; `group/mls_group/commit_builder.rs:853-856`), and `commit_membership` never sets `force_self_update` (`crypto/mls_manager.rs:651-660`). Even the creator's leaf is KeyPackage-sourced (`treesync/mod.rs:441` `leaf_node_source: LeafNodeSource::KeyPackage(life_time),`). A member that is never repaired and never commits a removal keeps an expiring leaf.
- Why it breaks: RFC 9420 section 7.3 (lifetime checks on never-updated leaves, which the RFC itself warns about); RFC 9750 sections 6.5 and 7 (rotate credentials proactively; define the update policy); availability of C-14/C-19.
- Test: unit `a_welcome_still_installs_after_an_old_members_leaf_lifetime_ends` in `crypto/mls_manager.rs`. A member joins with a KeyPackage built with `key_package_lifetime(Lifetime::new(1))`; sleep 2 s; the owner adds a third member; the third member's Welcome must install.
- Fix idea: `.skip_lifetime_validation()` on the JoinBuilder (seats are judged by the roster and the CRDT, not by leaf lifetimes). C-MLS-07's periodic self-update would also refresh leaves.

### C-MLS-05: Anyone who has seen a KeyPackage can spend it with a Welcome that names it; in a meeting, any guest holding the link can keep another guest out for good

- Severity: Medium for meetings (Impact M: a targeted guest is never admitted; Exploitability H: any link holder sees every knock's KeyPackage, and with a waiting room there is no race). Low for servers (a parked joiner's or a bootstrap KeyPackage is spent, the join waits one bootstrap timeout, and the server KeyPackage arm repairs the ghost leaf).
- Attacker: P-05 (a meeting guest with the link, or a server member who opened the join box); P-01 sees every server KeyPackage (Lane::Relay, `node/types.rs:4256`) but can drop the Welcome anyway, so the relay gains nothing new.
- Confidence: CONFIRMED (traced through OpenMLS, our arm, the re-knock and the host's admit).
- Code: OpenMLS deletes our KeyPackage as soon as a Welcome names its hash ref, before it decrypts or validates anything (`openmls-0.9.0/src/group/mls_group/creation.rs:688` `fn keys_for_welcome`, `:709` `.delete_key_package(`). We stage every Welcome before judging its sender, with no frame-sender gate (`node/swarm.rs:11584` `let judged = mls_mgr.join_from_welcome_judged(&group_key, &welcome_bytes, |facts| {`). In a meeting every refused or unreadable Welcome makes the knocker mint and broadcast a new KeyPackage at once:
  `node/conference.rs:344-354`
  ```
  /// A Welcome for a meeting we knock on was refused or unreadable. Staging it spent
  /// the KeyPackage the host holds for us, so knock again at once with a fresh one, or
  /// a room member's bogus Welcome would leave the real host's admission unreadable.
  pub(crate) fn reknock_after_bad_welcome(
  ...
      reknock(mls_mgr, crypto_store, ws_cmd_tx, room_code, std::time::Duration::ZERO);
  ```
  The new knock is sealed to the whole room under the link key (`node/conference.rs:548-549`), so the rogue spends it again. When the host finally admits, the device already has a (ghost) leaf from the first admit, and every later admit is skipped:
  `crypto/mls_manager.rs:620-623`
  ```
              if staying.contains(device_id.as_str()) || added.contains(device_id) {
                  hollow_log!("[HOLLOW-MLS] Skipping {device_id}: already has a leaf in {group_key}");
                  continue;
              }
  ```
  Meetings have no repair path, so the guest stays out. The zero-gap re-knock also lets a link holder make a knocker mint and broadcast one KeyPackage per junk Welcome (an unparseable Welcome takes the same path), and each minted KeyPackage is persisted for good (C-MLS-08).
- Why it breaks: C-19 (admission rules decide who is seated, not a bystander); RFC 9750 section 5.1 (a KeyPackage is used once, by the group it was meant for); design D section 4.
- Test: harness `authz_a_guest_cannot_spend_another_guests_key_package`. Host H with a waiting room; guest G knocks; rogue R (holds the link key) opens G's knock and sends G a Welcome built from its own group around G's KeyPackage; H admits G; assert G is admitted and in the call within the budget.
- Fix idea: before staging, snapshot the KeyPackage bundles a Welcome names and restore them unless the Welcome is accepted; gate MlsWelcome on the frame sender before staging (a server member device; in a meeting, a device of the host master its id names); re-knock only when a KeyPackage was really spent, with the 2 s gap; the host replaces an existing leaf on a fresh knock, as the server KeyPackage arm does.

### C-MLS-03: A member can Welcome a leafless member into a group that seats non-members (or, for a restricted channel, members who cannot see it)

- Severity: Low (Impact M: C-19, an outsider the attacker chose reads the victim's posts until the next probe repairs the fork; Exploitability M: needs the victim leafless (a joiner, or after a drop) and its KeyPackage (join box, Add proposals); the inserting member could leak the plaintext itself, so the gain is small).
- Attacker: P-05.
- Confidence: CONFIRMED.
- Code: the Server branch holds for a non-member SENDER and for a banned leaf, never for a non-member leaf, and never checks a subgroup's channel for the leaves:
  `node/mls_authority.rs:146-153`
  ```
          GroupRules::Server { state, .. } => {
              if let hold @ Verdict::Hold(_) = rules.membership(&sender.master, "sender") {
                  return hold;
              }
              match facts.leaves.iter().filter_map(LeafView::bound).find(|l| state.is_banned(&l.master)) {
                  Some(leaf) => Verdict::Hold(format!("holds a leaf of banned {}", leaf.master)),
                  None => Verdict::Accept,
              }
  ```
  A Welcome into a group we do not hold needs no ask (`welcome_rules`: "no group held: asking is not needed"), and a pending join makes every Welcome asked (`node/mls_authority.rs:222-223`). The wiki already describes the stronger rule ("held for a non-member or banned sender or leaf", `tools/hollow-memory/wiki/security_write_gates.md:445`), so code and documentation disagree. Commits hold the same case (S2, `node/mls_authority.rs:110-114`).
- Why it breaks: C-19; RFC 9420 section 12.4.3.1 together with section 5.3.1 (the joiner validates every member it is Welcomed beside); RFC 9420 section 16.12 (fragmentation by insiders).
- Test: unit case in `welcome_rules` (a tree with a leaf whose master is not a member must Hold, and must Hold for a subgroup leaf that cannot see the channel); harness `authz_a_welcome_never_seats_a_non_member` (C builds a substitute group with an outsider's leaf around a parked joiner's KeyPackage).
- Fix idea: in the Server branch, Hold when any bound leaf fails `rules.membership(&leaf.master, "leaf")`, which covers subgroup visibility as well.

### C-MLS-06: Someone who later gets into a participant's unlocked database can recover the media key of meetings it left

- Severity: Low (Impact M: the SFrame key and chat secrets of the last epoch of meetings the device attended, so ciphertext recorded by the relay, TURN or a forwarder can be opened; Exploitability L: needs the identity unlocked or the DB passphrase (P-09) plus recorded ciphertext).
- Confidence: CONFIRMED.
- Code: a participant never drops a meeting's group. Leaving keeps it on purpose (`node/conference.rs:553-555` `/// Leave a conference ... Group state is left in place; /// a re-admission's Welcome replaces it`), and the host's end notice drops nothing (`node/swarm.rs:13690-13699`, no `remove_group`). Every `persist_mls_state` writes the whole OpenMLS store (`node/crypto_handler.rs:1333-1347`). After a restart only server and subgroup ids are loaded (`node/swarm.rs:940-948`), but every stored value is read back and written out again (`crypto/mls_manager.rs:390-401`), so the meeting's epoch secrets (exporter included) stay in the blob forever. The same goes for any group whose id is no longer listed (a subgroup of a channel that lost its restriction, if it was not dropped first).
- Why it breaks: the meetings promise (chat RAM-only, "never persisted"); RFC 9750 sections 8.2.2 and 8.3.4 (delete keys once used); WP 5.4's forward-secrecy wording.
- Test: harness `a_meeting_left_leaves_no_group_secret_on_disk`. Host and guest meet, the guest leaves (and separately: the host ends); restart the guest; assert the persisted storage holds no entry for the `conf:` group id.
- Fix idea: `remove_group` at participants on leave, end and kick; at startup, load-and-delete any stored group that is not in the loaded set.

### C-MLS-07: One copy of a member's MLS state keeps reading that server's traffic until that member is repaired, and WP 5.4 promises more than this

- Severity: Low (Impact H, with a relay that records ciphertext; Exploitability L: a one-time read of the member's MLS state, P-09 or malware; Overclaim category).
- Confidence: CONFIRMED (design property traced).
- Code: no Hollow commit asks for a path (`crypto/mls_manager.rs:651-658` `group.commit_builder().propose_removals(remove_indices).propose_adds(key_packages)...build(...)` with no `force_self_update`), add-only commits carry none (see C-MLS-04), and no member ever updates its own leaf. A copy of epoch E's secrets follows every add-only commit, and a copy of a member's leaf keys follows every commit until that member's leaf is replaced. Receivers also keep three past epochs and 512 skipped keys per sender (`crypto/mls_manager.rs:21-29`). WHITEPAPER.md 5.4: "An attacker who compromises keys from one epoch cannot decrypt messages from other epochs."
- Why it breaks: RFC 9420 section 16.6 (post-compromise security needs updates); RFC 9750 sections 7 and 8.2.2 ("mandate key updates from clients that are not otherwise sending messages"); WP 5.4.
- Test: unit `a_copied_member_state_stops_reading_after_that_member_updates` (needs the feature first).
- Fix idea: `force_self_update(true)` on membership commits, and each member self-updates its leaf on a schedule (a path-only commit from a bound member is already accepted by `commit_verdict`), throttled so it does not become churn; or reword WP 5.4.

### C-MLS-08: A crash, a burst or a long install loses or bloats MLS state (L-08 residuals)

- Severity: Low (availability and at-rest hygiene).
- Confidence: CONFIRMED for each item.
- Code and items:
  - Persistence is fire-and-forget into an unbounded queue (`crypto/store.rs:25` `let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<CryptoStoreCmd>();`), and every send queues a full copy of the store (`node/crypto_handler.rs:1342-1346`). A kill between `encrypt` and the actor's write restarts on a used generation; the random reuse guard prevents nonce reuse (`openmls-0.9.0/src/framing/private_message.rs:262-266`), but receivers that already used that generation drop the new frame as a replay with no sync request (`node/swarm.rs:10819` `Ok(crate::crypto::Decrypted::Replay) => return,`), so the message waits for the next catch-up.
  - Minted KeyPackages that never become a Welcome are never deleted: the only discard is a refused join (`node/sync_handler.rs:1343` `match mls_mgr.discard_key_package(&kp) {`). Every bootstrap ask (once per 60 s), every answered request (once per 10 s per group) and every re-knock (C-MLS-05) leaves a private init key and leaf key in the blob, which is rewritten on every send.
  - The live database does not run `secure_delete` (only the scrubbed copy does, `storage/messages.rs:2912`), so older blobs holding past epoch secrets survive in freed pages and the WAL (a pointer for the storage slice).
- Why it breaks: RFC 9750 section 5.1 (delete an init key after use), section 8.2.2 (delete keys once used); availability of F-33.
- Test: unit `unused_key_packages_are_dropped_when_stale` (mint, wait past a cutoff, persist, assert gone); a harness for the replay drop would need process kill, so a unit on `decrypt_fresh` returning `Replay` plus a check that the arm asks the sender for a sync.
- Fix idea: discard a minted KeyPackage once its ask times out or a newer one for that group goes out; on `Replay` from a member, send a throttled channel sync request like the Stale arm; a bounded queue that coalesces MLS snapshots (only the newest matters); `PRAGMA secure_delete = ON` on the live DB.

### Info (no candidate)

- I-1 Padding is 0 (OpenMLS default; `hollow_join_config` sets none), so the relay sees exact plaintext lengths of channel messages, typing and reactions. C-24 accepts sizes; a padding size of 32 or 64 would blur message kinds cheaply.
- I-2 The MLS signer IS the device's Ed25519 key, and `signer_bytes` persists it with its private half into the `mls_identity` row (`crypto/mls_manager.rs:471-475`, `openmls_basic_credential-0.6.0/src/lib.rs:30-34`), duplicating the identity file's secret under the (master-derived) DB passphrase. RFC 9750 section 8.3.3 asks for compartmentalised signature keys. Link snapshots and backups scrub it (`storage/messages.rs:2909-2921`).
- I-3 A past-epoch sender whose leaf left the tree is classified by its certificate alone (`crypto/mls_manager.rs:998-1001`, `classify_by_certificate`), not by the leaf key OpenMLS verified the signature with. Safe today because every entry point classifies with the real key (L-03 below); a new entry point that skips it would turn this into a misbinding.
- I-4 The MLS arm drops a sender only when `disowns`, while `refused` also asks `is_revoked` (`node/swarm.rs:10867` vs `node/mls_authority.rs:40-42`). A revoked device of a master whose roster we do not hold and of which we know no other device is not dropped there. Edge case; content gates still apply.
- I-5 The legacy rebind (an unbound committer may rebind as the device or master its old credential names, `node/mls_authority.rs:72-88`) is a "legacy, accept" path with no written expiry (secure-coding rule 6). Add it to the post-0.12 switch-off list.
- I-6 The probe's 16-byte digest of the epoch authenticator travels in a Relay-lane frame, so the relay learns when two members disagree (fork detection). Nothing derivable.
- I-7 For L-01 (WP9): the exporter gives ONE SFrame key per (group, epoch), label `"sframe"`, empty context, shared by every non-restricted voice channel of a server (`node/crypto_handler.rs:2699`). Nonce uniqueness must therefore hold across channels and calls of the same server, not only within one call.

## Leads

- **L-03 (credential validation at every RFC 9420 entry point): holds, with two gaps filed.** Every leaf that enters a tree we hold is classified from its own credential and signature key (`crypto/mls_manager.rs:113-144`; `pubkey_from_peer_id(device)` must equal the signature key, the master's `verify_strict` over `hollow-mls-leaf:{master}:{device}`). Entry points:
  - Add by KeyPackage frame: `node/swarm.rs:11405-11412` (bound to the sending device) and `:11422-11426` (member); the committer re-checks in `plan_membership` (`node/mls_authority.rs:170-178`) and validates fully in `commit_membership` (`crypto/mls_manager.rs:631-642`).
  - Add by parked join: `node/swarm.rs:10294-10298` (bound to the device and the joiner's master).
  - Add by meeting knock: `node/conference.rs:601-608`, `:647-650`, again at admit `:670`.
  - Adds in a received commit: `crypto/mls_manager.rs:1047-1050` -> `node/mls_authority.rs:62-64`, `:97-99`, `:110-114`.
  - Update (commit path): `crypto/mls_manager.rs:1046` -> `node/mls_authority.rs:65-93` (identity kept; legacy rebind only as itself).
  - Update proposals and every other proposal type: `crypto/mls_manager.rs:1052-1054` -> refused at `node/mls_authority.rs:59-61`.
  - External commits: no member sender -> `facts.committer` is `None` (`crypto/mls_manager.rs:1034-1037`) -> refused at `node/mls_authority.rs:56-58`. Note OpenMLS skips its wire-format check for external messages (`openmls-0.9.0/src/group/mls_group/processing.rs:302-311`), so this rule is the only thing refusing them.
  - Welcome tree, sender and own leaf: `crypto/mls_manager.rs:832-848` -> `node/mls_authority.rs:123-141` (every leaf bound and not refused, our leaf ours, sender bound). Gap: non-member leaves (C-MLS-03).
  - Application-message sender: `crypto/mls_manager.rs:990-1007`, then `disowns` at `node/swarm.rs:10867`.
  - Catch-up: same judged path (`node/swarm.rs:11705`).
  Uniform policy: the same code runs on every client, but its inputs (rosters held, CRDT lag) differ, so clients can disagree and fork; forks are repaired by the probe (design D section 5). The authorization side of "repair" is C-MLS-01.
- **L-08 (OpenMLS items left to the application):**
  - Non-atomic state vs storage: holds. OpenMLS writes many keys per operation, but into an in-RAM MemoryStorage that cannot fail mid-way; we persist the whole map as one blob in one upsert (`storage/messages.rs:2891-2900`), so disk never holds a torn group. The CryptoStore actor makes it a last-write-wins snapshot, which turns every crash window into a rollback, never an inconsistency. A rollback after our own commit is healed by catch-up from members who cached it; after a receive, by our probe; after a send, see C-MLS-08 (the reuse guard prevents nonce reuse; receivers drop silently). The push fetch writes the same blob, and it runs only while the full node does not (`node/fetch.rs:156-158` comment and the Android/iOS guards it names; not re-verified here). A staged Welcome replaces a held group only after it is accepted, and `install_welcome` deletes the old group before `into_group`, which can fail only on a storage error (`crypto/mls_manager.rs:850-858`).
  - Unbounded allocation from peer input: holds. There is no MLS-specific size cap; a frame is bounded by tungstenite's defaults (64 MiB message, no override in `node/ws_client.rs:979`) and the relay's 64 MB. `tls_codec` 0.5 caps every preallocation at 4096 bytes (`tls_codec-0.5.0/src/lib.rs:131`, `:152`), so parsing allocates in proportion to the input. A large Welcome tree reaches validation only after it decrypts under one of OUR KeyPackages (`keys_for_welcome` comes first). Sender ratchets are bounded (tolerance 512, forward 2000), catch-up takes at most 16 commits (`node/swarm.rs:11694`), the leaf cache 4096 entries (`crypto/mls_manager.rs:175`), the commit cache 8 per group (`:325`), one held commit and one held Welcome per group. CPU per frame is linear in its size (phase G for floods, AR-01). The unbounded pieces are local: the actor queue and KeyPackage accumulation (C-MLS-08).

## Protocol checklist

RFC 9420 section numbers are from memory of the RFC and should be re-checked against the text; RFC 9750's were checked against its table of contents.

| Obligation (application side) | Ours | Evidence |
|---|---|---|
| 9420 s5.3.1 validate every credential at Add, Welcome, Update, Commit | Met, except non-member leaves in a Welcome | L-03 above; C-MLS-03 |
| 9420 s5.3.2 credential expiry and revocation | Met through the roster (`refused`), the coordinator sweep removes revoked leaves; no time-based expiry | `node/mls_authority.rs:40-42`, `:304-316` |
| 9420 s5.3.3 uniquely identify clients | Met: a leaf is a device, its signature key is the device key, OpenMLS keeps signature keys unique | `crypto/mls_manager.rs:327-343`; `openmls .../validation.rs:197-226` |
| 9420 s6.3.1 reuse guard against nonce reuse after state loss | Met by the library (random guard) | `openmls .../framing/private_message.rs:262-266` |
| 9420 s7.3 leaf node validation (signature, capabilities, keys unique, lifetime) | OpenMLS does it; the lifetime check on never-updated tree leaves is C-MLS-04 | C-MLS-04 |
| 9420 s8.5 exporter labels unique per use | Met: one label `"sframe"`, empty context, 32 bytes | `node/crypto_handler.rs:2699` and every export site (grep: 11, all `"sframe"`); I-7 |
| 9420 s8.7 epoch authenticator | Used only as a 16-byte digest in probes | `crypto/mls_manager.rs:1179-1185`; I-6 |
| 9420 s10/s10.1 KeyPackage validation, one-time use, delete after use | Validation by OpenMLS; one-time use not enforced (C-MLS-01); spent by any Welcome naming it (C-MLS-05); unused ones never deleted (C-MLS-08); no last-resort packages | `crypto/mls_manager.rs:631-642`; mints only via `mint_key_package` (`key_package_mints_persist_mls_state`) |
| 9420 s12.1.2 Update proposals | Refused by policy (H2) | `node/mls_authority.rs:59-61` |
| 9420 s12.1.4-12.1.7 PSK, ReInit, ExternalInit, GroupContextExtensions | Refused (H2, H1); a Welcome naming a PSK fails (no PSK store, `number_of_resumption_psks` 0) | `node/mls_authority.rs:56-61` |
| 9420 s12.1.8 external proposals | Refused by OpenMLS (no `external_senders` extension is ever set) | GroupContextExtensions refused, so none can be added |
| 9420 s12.4.3.1 Welcome checks (GroupInfo signer, tree, confirmation tag, required capabilities, ciphersuite; group id unique among our groups) | OpenMLS for the cryptography; we check the group id equals the addressed key and replace a held group only when asked | `crypto/mls_manager.rs:842`, `node/mls_authority.rs:124-138` |
| 9420 s12.4.3.2 external joins | Refused (H1) | `node/mls_authority.rs:56-58` |
| 9420 s14 sequencing of commits (one per epoch) | No DS ordering; concurrent commits fork and are repaired after a probe | design D section 5; `node/crypto_handler.rs:2941-2990` |
| 9420 s15.1 padding | None (I-1) | `crypto/mls_manager.rs:33-42` |
| 9420 s15.2 application data only as PrivateMessage | Met (OpenMLS: `create_message` is always private; incoming handshake must be ciphertext, `PURE_CIPHERTEXT_WIRE_FORMAT_POLICY` default) | `openmls .../config.rs:642-679` |
| 9420 s15.3 delayed messages vs forward secrecy | Deliberate: 3 past epochs, 512 skipped keys, 2000 forward | `crypto/mls_manager.rs:21-29`; C-MLS-07 |
| 9420 s16.6 forward secrecy and PCS need updates | Not met (no self-updates, add-only commits carry no path) | C-MLS-07 |
| 9420 s16.8 KeyPackage reuse; rate-limit KeyPackage requests | Reuse not detected (C-MLS-01); rate limits AR-01; we answer requests once per 10 s per group | `node/swarm.rs:11769` |
| 9420 s16.9 DS compromise (drop, delay, withhold, fork) | Forks repaired; a withheld removal leaks content | C-MLS-02 |
| 9420 s16.12 group fragmentation by insiders | Accepted by design D (any member may Welcome a leafless member), repaired by the probe; outsiders in that tree are C-MLS-03 | matrix server_mls A-09 |
| 9420: application data never as PublicMessage, AAD | AAD unused; group id is bound by MLS (`WrongGroupId` is garbage), the envelope must name the group that decrypted it | `crypto/mls_manager.rs:984-986`; `node/crypto_handler.rs:2133-2151` |
| 9750 s4 AS binds identity to signature key; check revocation | Met (device key, master certificate, roster) | `crypto/mls_manager.rs:121-144`; `node/mls_authority.rs:40-42` |
| 9750 s5.1 each KeyPackage adds its client to one group; delete the init key after the Welcome | Partly (C-MLS-01, C-MLS-05, C-MLS-08) | |
| 9750 s5.2.2 eventually consistent DS needs a tie-break for same-epoch commits | Partly: no tie-break; the first applied wins, forks are repaired | |
| 9750 s5.2.3 process only Welcomes whose commit succeeded | Partly: a Welcome installs whether or not its commit reached the others; the probe repairs | |
| 9750 s5.3 recovery from invalid commits | Met: repair by KeyPackage, never an external join; nothing that fails drops a group | `node/swarm.rs:11309-11383`, `node/crypto_handler.rs:2640-2649` |
| 9750 s6.4 consistent access control; explicit external-join policy | Met (external joins refused); policy inputs differ per client (forks) | |
| 9750 s6.5 uniform credential validation and handling; rotate credentials proactively | Partly: uniform code, non-uniform inputs; no rotation (C-MLS-04, C-MLS-07) | |
| 9750 s6.6 recovery after state loss | Met (repair; rejoin drops the stale group) | |
| 9750 s7 operational parameters (KeyPackage lifetime, PSK retention, out-of-order tolerance, cipher suite, extensions, plaintext vs ciphertext handshakes, proposal policy, how long a member may go without updating) | All set except the last: no update policy (C-MLS-07); the KeyPackage lifetime is OpenMLS's default 84 days, never set by us | |
| 9750 s8.1 authenticate custom metadata (AAD) | Met by the device seal on every frame (design A) and the envelope-fits-group check; the `epoch` hint is unauthenticated but only lets a frame be skipped | `node/crypto_handler.rs:2575-2581` |
| 9750 s8.2.2 delete keys once used; mandate updates; evict idle clients | Partly (C-MLS-06, C-MLS-07, C-MLS-08) | |
| 9750 s8.3.3 compartmentalise signature keys | Info I-2 | |
| 9750 s8.3.4 full state compromise: encryption at rest, delete promptly | SQLCipher at rest; prompt deletion C-MLS-06, C-MLS-08 | |
| 9750 s8.4.2 DS compromise | C-MLS-02 | |
| 9750 s8.6 no protection against replay by insiders | Met at the envelope layer: message ids, op ids, voice frames only from their own leaf, live signals judged by the seal time | `node/swarm.rs:10839-10842`, `:11122-11142` |

## The 13 classes, asked of this slice

1. **Authenticated but not authorised.** Commits, Welcomes and KeyPackages are judged by the rules (matrix server_mls A-08..A-16). Two gaps: the repair exception accepts any re-add as a repair (C-MLS-01), and a Welcome may seat non-members (C-MLS-03).
2. **Infrastructure controls membership.** No. A relay cannot seat a leaf for a device whose key it lacks (bound leaves), and relay presence only picks who commits and where a KeyPackage goes (`node/crypto_handler.rs:1637-1681`, `:2793-2816`), never who is a member. The relay reads every server KeyPackage (Lane::Relay, `node/types.rs:4256`) and could spend it (C-MLS-05), which adds nothing to dropping the Welcome. Its withholding power does become a confidentiality problem in C-MLS-02.
3. **Split view.** Forks can arise by design (a Welcome into an unheld group, concurrent commits, members judging with different rosters). They are detected only when a probe fires (decrypt failure, voice join, SFrame heal, sync hint) by comparing epoch-authenticator digests, then repaired in one commit (`a_same_epoch_fork_heals_through_the_probe`). Keeping three past epochs hides a stale SENDER from everyone but itself (C-MLS-02).
4. **Withheld or rolled-back revocation.** A withheld removal commit is unbounded in time and leaks content (C-MLS-02). A removed member's frames from up to three epochs back still decrypt, attributed to its old leaf; the CRDT and roster gates on every envelope refuse them (`live_channel_post_refusal`, `disowns`), so nothing lands.
5. **Identifier or key-type confusion.** Nothing found. The leaf certificate has its own tag (`hollow-mls-leaf:`) and names both ids; MLS signs `SignContent` with RFC labels, never a `hollow-` string; a leaf whose device id is its master's is bound but refused once we hold that master's roster (HOL-SEC-083); group keys read one way only (A-23, `names_a_group`).
6. **Channel confusion.** Nothing found. MLS frames ride Lane::Relay (an Olm-carried copy is dropped by the lane rule), a meeting Welcome rides the meeting lane, a decrypted envelope must fit its group (`mls_envelope_fits_group`), DM-shaped envelopes never ride a group, and voice signals count only from their own leaf.
7. **Unknown key-share / misbinding.** Holds at every entry point (L-03). Past-epoch senders are classified by certificate only (I-3); safe as long as no entry point skips classification.
8. **Replay, reflection, reordering.** A replayed commit or application frame fails on the used ratchet key and only probes or drops (`Decrypted::Replay`); our own frames reflected back come out as `OwnPrivateMessage` and are ignored; catch-up applies only at exactly own+1. KeyPackages are replayable (C-MLS-01) and spendable (C-MLS-05). Insider re-encryption of another member's signed content (RFC 9750 s8.6) is stopped by the envelope layer's ids.
9. **Downgrade and length.** Every `Option` field read: `channel_id` absent means the server group, but restricted content cannot ride it (`fits_group`); `conf_nonce` absent proves no host; `epoch` absent only disables the skip; `epoch_auth` absent claims no fork and only the prober sends it. Unbound legacy leaves are ignored, except the in-place rebind with no written expiry (I-5).
10. **Unauthenticated metadata.** Outside MLS: `server_id`/`channel_id` choose the group and MLS checks the group id; `epoch` on a commit can only make us skip it; a catch-up entry's epoch only orders; everything else is inside the device seal. Inside MLS: the envelope's own `sid`/`cid` are checked against the decrypting group.
11. **State and key lifecycle.** L-08 above. Group ids: server ids are 32/40 lowercase hex, channel ids `[A-Za-z0-9_-]{1,64}`, meetings `conf:` plus 40 hex, so `S#c`, `conf:` and server ids never collide (HOL-SEC-098, HOL-SEC-099). Findings: C-MLS-04 (lifetime), C-MLS-05 (spending), C-MLS-06 (meeting secrets on disk), C-MLS-08 (rollback, accumulation).
12. **Device linking and cloning.** Link snapshots and backups carry no MLS identity (`storage/messages.rs:2909-2921`); an inherited credential is discarded at startup (`node/swarm.rs:964-988`); a clone could not hold a leaf beside its source anyway (one signature key per tree). Nothing found.
13. **What a stranger can trigger or observe.** A device that can reach a room (an open legacy room, or directs into a door room) can only make us probe (10 s cooldown), ask once per 60 s for a leaf in a group we lack (each ask leaves an undeleted KeyPackage, C-MLS-08), and stage Welcomes that name no KeyPackage of ours (harmless). It never sees KeyPackages, commits or Welcome contents. In a meeting the link holder is not a stranger (C-MLS-05).

## STRIDE grid

One line per cell. "Covered" cites the matrix row or finding; "met" cites the code; "cand" points to a candidate.

**P1 MlsManager (`crypto/mls_manager.rs`)**
- S: met. Leaves classified from credential plus their own key (`:113-144`, `:192-198`); our signer is the device key (`:327-343`).
- T: covered A-14, A-10 (stage, judge, merge: `:1014-1083`, `:867-897`); OpenMLS verifies signatures, tags, trees.
- R: n/a. MLS frames are not non-repudiable by design (RFC 9750 s8.2.3); content attribution rides the master-signed envelopes (C-09).
- I: met for wire secrecy (PrivateMessage only); cand C-MLS-06, C-MLS-07; Info I-1, I-2.
- D: cand C-MLS-04, C-MLS-05; covered HOL-SEC-044 (a failing frame never drops a group).
- E: covered A-09, A-10; cand C-MLS-01.

**P2 mls_authority (`node/mls_authority.rs`)**
- S: covered A-14 (bound leaves, `refused`).
- T: n/a (pure functions over facts staged by P1).
- R: n/a.
- I: n/a.
- D: met. Holds expire after 60 s (`crypto/mls_manager.rs:243`); one held slot per group (C-MLS-01 variant c).
- E: cand C-MLS-01, C-MLS-03; covered A-08..A-10, A-16.

**P3 MLS ingress arms (`node/swarm.rs` 10747-11793, `node/crypto_handler.rs` 2546-3045, `node/fetch.rs` MLS arm)**
- S: covered by design A (sealed frames, N-06 bare master) and A-15 (voice signals only from their own leaf).
- T: covered A-15 (`fits_group`), A-23 (shape check before dispatch).
- R: n/a.
- I: covered A-10, A-15 (sync requests only to member devices, HOL-SEC-089, HOL-SEC-124).
- D: met. Unknown-group bootstrap once per 60 s (`node/swarm.rs:10765`), catch-up at most 16 (`:11694`), probes 10 s (`node/crypto_handler.rs:2787`); cand C-MLS-05.
- E: covered A-11, A-12, A-13.

**P4 Committer (batch timer `node/swarm.rs` 5440-5742)**
- S: n/a (local).
- T: met. The planner applies the receivers' rules (`the_planner_keeps_only_what_receivers_accept`).
- R: n/a.
- I: met. A Welcome for an absent device is buffered by name, HPKE-sealed to its KeyPackage (`node/swarm.rs:5619-5627`).
- D: cand C-MLS-01 variant b (a member forces a repair every tick).
- E: n/a (receivers judge every commit).

**P5 Meeting MLS (`node/conference.rs`)**
- S: covered A-17..A-22 (host from the meeting id, roster asked).
- T: covered A-17 (knock KeyPackage bound to the knocker), A-09 (Welcome only from the host, with a pending knock).
- R: n/a.
- I: met for chat lines (never persisted, `:930-953`); cand C-MLS-06 for the group secrets.
- D: cand C-MLS-05 (lock-out, re-knock flood).
- E: covered A-17, A-23 (pinned meeting ids only).

**DS1 CryptoStore actor and `mls_identity` row**
- T: met. One upsert of the whole snapshot (`storage/messages.rs:2891-2900`), so nothing is torn; SQLCipher integrity is the storage slice's.
- I: SQLCipher at rest; Info I-2 (device key inside); cand C-MLS-06, C-MLS-08 (no `secure_delete`).
- D: cand C-MLS-08 (unbounded queue of full copies, rollback windows, KeyPackage accumulation).

**DS2 In-RAM MLS state**
- T: n/a beyond its inputs (held-slot overwrite is C-MLS-01 variant c).
- I: n/a (RAM).
- D: met. Bounded caches: commit cache 8 per group (`crypto/mls_manager.rs:325`), leaf cache 4096 (`:175`), one held commit and Welcome per group.

**F-32a KeyPackages (live, parked join, knock)**
- T: covered A-08, A-17 (bound to the sending device, sealed).
- I: KeyPackages are readable by the relay (Lane::Relay) and by every member (join box, Add proposals); that is what feeds cand C-MLS-01 and C-MLS-05; otherwise routing metadata (C-24).
- D: cand C-MLS-05; rate limits AR-01.

**F-32b Commits (live broadcast and catch-up)**
- T: covered A-10, A-12.
- I: met. Handshakes are PrivateMessages; the relay sees epoch and content type only.
- D: cand C-MLS-02 (withheld removal); covered A-10 (a garbage commit probes).

**F-32c Welcomes**
- T: covered A-09; cand C-MLS-03.
- I: met. HPKE to the KeyPackage's init key; the relay learns the KeyPackage ref (routing).
- D: cand C-MLS-04, C-MLS-05.

**F-32d KeyPackage requests and epoch probes**
- T: covered A-11, A-13.
- I: Info I-6.
- D: met. Answers once per 10 s per group (`node/swarm.rs:11769`), probes 10 s.

**F-33 MLS channel messages (server group, subgroups, rings, push fetch)**
- T: covered A-15, A-16.
- I: met for subgroups (`restricted_channel_subgroup_enforces_visibility`); cand C-MLS-02; Info I-1.
- D: covered A-15 (never drops a group).

**F-37 Meeting MLS**
- T: covered A-17..A-22.
- I: cand C-MLS-06.
- D: cand C-MLS-05.

**F-31 MLS adoption after a join**
- T: cand C-MLS-03 (a pending join treats every Welcome as asked, `node/mls_authority.rs:222-223`).
- I: n/a.
- D: met. A Welcome for a server whose state has not arrived is held (`node/mls_authority.rs:249`).

**X-2 Relay**
- S: covered by design A (device-sealed frames, N-06).
- R: n/a (the relay is never the author of an MLS change; what it can do is drop, delay, reorder, withhold: C-MLS-02).

**X-3 Peers (members, owner, host, guests)**
- S: covered A-14 (leaf = device key plus master certificate, roster).
- R: met for content (master-signed envelopes, C-09); MLS-level actions (who committed) are attributable in local logs only, n/a.

**X-4 Own siblings**
- S: covered A-08 (the sibling re-add path still needs a bound leaf the roster counts).
- R: n/a.

## Requirements

| ID | Requirement | Evidence | Test |
|---|---|---|---|
| R-MLS-01 | An attacker at any position cannot make us treat a leaf as device D of master M unless its signature key is D's key and M signed `hollow-mls-leaf:{M}:{D}`. | `crypto/mls_manager.rs:121-144` | `a_leaf_is_bound_only_by_its_device_key_and_its_masters_certificate`, `a_copied_certificate_never_becomes_a_leaf` |
| R-MLS-02 | A peer or the relay cannot seat a leaf in another device's name through a KeyPackage (live, parked or knock). | `node/swarm.rs:11405-11412`, `:10294-10298`; `node/conference.rs:647-650` | `authz_no_one_seats_a_leaf_in_another_devices_name`, `authz_key_package_must_name_its_sending_device` |
| R-MLS-03 | No received commit changes a group before `commit_verdict` accepts it. | `crypto/mls_manager.rs:1065-1081` | `commit_hard_rules_refuse`, `authz_a_member_cannot_evict_a_member_or_add_an_outsider` |
| R-MLS-04 | A commit from a non-member leaf, an external commit, or one carrying any proposal besides Add and Remove is refused. | `node/mls_authority.rs:56-61` | `commit_hard_rules_refuse` |
| R-MLS-05 | A committer cannot change its leaf's identity; a legacy leaf rebinds only as itself and with nothing else. | `node/mls_authority.rs:65-93` | `commit_hard_rules_refuse`, `a_legacy_leaf_rebinds_as_its_own_device_or_master` |
| R-MLS-06 | A revoked, disowned or bare-master device neither commits, nor is added, nor is in a Welcome we install. | `node/mls_authority.rs:94-99`, `:133-135` | `a_removed_disowned_or_bare_master_leaf_neither_commits_nor_is_added`, `disowned_devices_are_never_added_or_welcomed_and_always_removable` |
| R-MLS-07 | No one replaces a group we hold with a Welcome we did not ask for. | `node/mls_authority.rs:136-138`, `:212-230` | `authz_a_welcome_never_replaces_a_group_unasked`, `a_refused_welcome_replaces_nothing` |
| R-MLS-08 | A member cannot Welcome us into a group that seats a non-member, or for a subgroup someone who cannot see its channel. | NOT MET (C-MLS-03) | no test |
| R-MLS-09 | A member cannot remove another member's leaf except in a repair that re-adds it with a KeyPackage minted for that repair. | NOT MET (C-MLS-01) | no test |
| R-MLS-10 | No frame that fails (garbage, wrong epoch, failing commit or catch-up) drops a group. | `node/swarm.rs:11309-11383`; `node/crypto_handler.rs:2640-2649` | `authz_garbage_mls_frames_never_drop_a_group` |
| R-MLS-11 | Catch-up commits apply only from a member, only at exactly our epoch plus one, through the judged path. | `node/swarm.rs:11676-11724` | `stale_epoch_heal_probe_converges_via_commit_replay`, `authz_garbage_mls_frames_never_drop_a_group` |
| R-MLS-12 | An envelope decrypted from a group counts only if it names that group's server and channel, and restricted content only through its subgroup. | `node/crypto_handler.rs:2133-2151`, `node/swarm.rs:10855-10860` | `authz_mls_envelope_must_fit_the_group_that_decrypted_it` (unit; the callers by `channel_ingest_gates_stay_wired`) |
| R-MLS-13 | A member cannot put voice signaling in another member's name through a group. | `node/swarm.rs:11122-11142` | `authz_voice_frames_over_mls_come_from_their_leaf` |
| R-MLS-14 | An MLS frame names a group only by a server id, a subgroup of one, or a pinned meeting id. | `node/mls_authority.rs:274-299` | `an_mls_frame_names_a_group_only_by_real_ids`, `mls_frames_are_shape_checked_before_dispatch` |
| R-MLS-15 | Only a current member entitled to repair our leaf gets a KeyPackage from us, at most once per group per 10 s. | `node/swarm.rs:11741-11772` | `authz_key_package_requests_need_a_member_who_may_repair` |
| R-MLS-16 | Every KeyPackage we mint is persisted with its private half before it leaves. | `node/crypto_handler.rs:1361-1368` | `key_package_mints_persist_mls_state` |
| R-MLS-17 | Persisted MLS state is one atomic snapshot, never a torn group. | `storage/messages.rs:2891-2900`; `node/crypto_handler.rs:1333-1347` | no test (by construction) |
| R-MLS-18 | Our send ratchet is persisted after every encrypt. | `node/crypto_handler.rs:2112`, `:2185`; `node/conference.rs:946` | no test (a source scan like `key_package_mints_persist_mls_state` would guard it) |
| R-MLS-19 | In a meeting only the host its id names commits, and its Welcome counts only while we knock. | `node/mls_authority.rs:100-106`, `:143-145`, `:234-246` | `a_meeting_welcome_counts_only_from_the_host_its_id_names`, `only_the_host_commits_in_a_meeting` |
| R-MLS-20 | A removed member cannot read what a member sends after that member has learned of the removal, even if the removal commit was withheld from it. | NOT MET (C-MLS-02) | no test |
| R-MLS-21 | A Welcome installs whatever the age of the other members' leaves. | NOT MET, SUSPECTED (C-MLS-04) | no test |
| R-MLS-22 | A bystander cannot spend our KeyPackage; it is spent only by a Welcome we accept. | NOT MET (C-MLS-05) | no test |
| R-MLS-23 | A meeting we left or that ended leaves no group secret on disk. | NOT MET (C-MLS-06) | no test |
| R-MLS-24 | External commits and handshake PublicMessages are refused. | `node/mls_authority.rs:56-58`; OpenMLS `PURE_CIPHERTEXT` default | `commit_hard_rules_refuse` (facts level only) |
| R-MLS-25 | Two members at one epoch with different group states are detected and repaired. | `node/crypto_handler.rs:2941-2990` | `a_same_epoch_fork_heals_through_the_probe` |
| R-MLS-26 | A subgroup admits, keeps and serves only leaves whose certified master can see its channel. | `node/mls_authority.rs:27`; `node/crypto_handler.rs:1960-1965` | `a_subgroup_admits_only_who_can_see_its_channel`, `restricted_channel_subgroup_enforces_visibility` |

## What I could not check

- Nothing was run. C-MLS-04 rests on OpenMLS 0.9 source alone; the unit test named there settles it in a minute.
- RFC 9420 section numbers are cited from memory (RFC 9750's against its table of contents).
- The push-fetch single-writer guard (Android guard, iOS heartbeat) was taken from the comment in `node/fetch.rs`, not traced into the Dart/platform code.
- Relay-side behaviour for legacy rooms and ring subscriptions after a kick (C-MLS-02's delivery side) was taken from AR-16 and design D1, not re-read in `relay-uws/`.
