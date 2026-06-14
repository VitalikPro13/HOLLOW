# Multi-Device Identity & Sync — Implementation Tracker

**Status:** In progress. Step 1 (device identity foundation) DONE and live-verified (host+phone+VM).
Step 2 (device-list propagation + friend-UI device collapse) + Step 2.5 (sibling friend-list sync, the
presence on-ramp the live test exposed as necessary) both code-complete, pending real-device test.
**Companion to:** `reports/MULTI_DEVICE_SYNC_PLAN.md` (the design doc — decisions, flows, rejected
alternatives). This file is the **execution tracker**: verified codebase facts, the real cost breakdown,
and a step-by-step checklist with checkboxes to follow during implementation.
**Authored:** 2026-06-14 (codebase feasibility verification session).
**Referenced from:** `HOLLOW_PLAN.md` Phase 6 — "Multi-device identity & sync (major epic)".

---

## 0. TL;DR Verdict

**Possible: yes. The design (`MULTI_DEVICE_SYNC_PLAN.md`) is architecturally correct.** Codebase
verification confirms the Signal-style model fits. Two surprises vs. the design doc's cost framing:

- **Easier than expected:** the **relay** barely needs to change, and the **sync engine** is already
  identity-agnostic. Because the plan gives each device its **own distinct peer_id**, the relay never has
  to learn that two peer_ids are the same human — it stays a dumb pipe. Backfill ("my phone syncs from my
  desktop") is *literally* "two peers syncing" on existing rails.
- **Harder than the doc weights:** **MLS per-device leaves** (real OpenMLS-integration surgery) and the
  **"is this peer me?" plumbing** spread across friend-request / profile / typing / message paths.

**The single root cause of every symptom today:** peer_id is derived deterministically from the mnemonic,
so two installs of one mnemonic share *one* peer_id and clobber each other everywhere.

---

## 1. Verified Codebase Facts (the ground truth)

Each row was confirmed by reading the code, not inferred.

| # | Fact | Evidence | Implication |
|---|---|---|---|
| 1 | **peer_id is deterministic from the mnemonic.** `mnemonic → seed → seed[..32] → Ed25519 → compute_peer_id()`. A known-good test pins it. | `identity/native_identity.rs:30-39`, `compute_peer_id` L16-26, test `peer_id_known_good` L173-178 | Two devices, same mnemonic = **same peer_id today**. This is the root cause. The fix (distinct per-device peer_id) is the load-bearing change. |
| 2 | **DB passphrase is deterministic from the key** (`keypair.to_protobuf_encoding()[..32]`). | `api/storage.rs` `derive_db_key()` ~L43-57 | Both devices share one passphrase → a transferred snapshot just opens. **No per-device DB crypto needed.** Confirms plan §3.1. |
| 3 | **Messages are signed by the master Ed25519 key** (signature payload includes `sender`=peer_id; verification re-derives peer_id from pubkey and requires a match). | `crypto_handler.rs` `message_signing_payload` L14-35, `sign_message`, `verify_message_signature` L39-77 | Any device's messages verify under the one identity → **peer-fallback backfill is safe** (a friend can re-serve your signed messages and your other device verifies "yes I sent these"). Confirms plan §5.2. |
| 4 | **Olm sessions are keyed by peer_id only** (`HashMap<String, Session>`). | `crypto/olm_manager.rs:15`, `create_outbound_session` L102, `encrypt` L140-144, `decrypt` L158 | Once devices have distinct peer_ids this mostly resolves itself (each device = its own map key for friends). Remaining work = **sender-side fan-out** (encrypt once per device) at every encrypt site. |
| 5 | **MLS credential = `BasicCredential::new(peer_id.as_bytes())`; member lookup is by that identity; `add_members_batch` rejects an already-present peer_id.** | `crypto/mls_manager.rs:40-45`, `remove_member` lookup ~L295-302, `add_members_batch` reject ~L228-251 | "Two leaves for one human" needs credential = `peer_id:device_id`. **This is the genuinely hard slice.** |
| 6 | **MLS coordinator election = lowest peer_id string.** | `crypto_handler.rs` `elect_coordinator` L154-182 | Two devices of one identity would tie. Election must move to `{peer_id}:{device_id}` with a deterministic tiebreaker once per-device leaves exist. |
| 7 | **The CRDT/op sync engine is identity-agnostic.** Delta = compare `author` + HLC; dedup by `(author, hlc)`. No friend-vs-self branch anywhere. | `crdt/sync.rs` `StateVector` L14-38, `compute_delta` L14-38; `crdt/server_state.rs` dedup L245-249 | **"My phone syncing from my desktop" is just "two peers syncing."** No new sync engine needed. Confirms plan §2 key principle. |
| 8 | **DM history sync is identity-agnostic** (`DmSyncRequest`/`DmSyncBatch`, `get_dm_messages_since`). Message storage dedups by `message_id` with `INSERT OR IGNORE`. | `swarm.rs` `DmSyncRequest` ~L6258-6329; `storage/messages.rs` UNIQUE+`INSERT OR IGNORE` ~L319-820 | Backfill double-delivery (from your device AND the peer) is harmless. Confirms plan §5.2. |
| 9 | **Archive exporter/loader is a self-contained, signed conversation snapshot** (manifest, messages, edits, deletions, reactions, files, per-message + archive signatures). | `archive/exporter.rs` L13-530, `archive/loader.rs`, `archive/types.rs` | The QR-link DB transfer reuses this **as-is**. Low risk. Confirms plan §3. |
| 10 | **Presence is per-peer_id and dedups correctly** (`RoomMembers` authoritative; `ws_room_peers`; Dart `sortedFriendsProvider` keys on `peerId`). | `swarm.rs` `RoomMembers` ~L1854, `PeerJoined` ~L1491, `PeerLeft` ~L1746; `friends_provider.dart` ~L105-141 | Distinct device peer_ids each show their own online dot. Won't crash. UI will show *two dots for you* until taught to collapse by identity — **cosmetic, not breaking.** |
| 11 | **Every relay `RelayState` map is keyed by peer_id with NO duplicate-connection handling** — a second auth with the same peer_id silently overwrites the socket. | `relay-uws/src/state.h:95-165`, `ws_handler.cpp` `handle_auth` L151/L177, room join L209-212, cleanup L1089-1112 | **Only breaks if two devices share a peer_id.** With distinct per-device peer_ids the relay is fine as-is. The earlier "2000+ lines of relay work" estimate assumed shared peer_id — the plan rejects that, so relay work is **minimal**. |
| 12 | **Friend-request receive path had NO self-guard** (send path did). | `social.rs` send-guard L26; `swarm.rs` `FriendRequest` receive handler (was) L7094 | This is the literal "your own friend friend-requested you" bug. **FIXED 2026-06-14** (see §2). |

### The crux, stated once

The relay and crypto layers all key on peer_id and assume **one peer_id = one device = one connection**.
The plan's decision to give each device its **own** peer_id (per-device sub-key, master-signed device
list) means the system never has to break that assumption — it just has *more* peer_ids, each behaving
like a normal peer. That's why the decentralized "no central account" model makes the **relay side easier,
not harder**: there's no account row to reconcile; there are just more peers.

---

## 2. Quick-Win Fixes (independent of the epic)

- [x] **Self friend-request guard** — `swarm.rs` `HavenMessage::FriendRequest` now returns early when
  `peer_str == local_peer_str`, logging "Ignored self friend request (own device)". Fixes the "your own
  friend friend-requested you" symptom regardless of the rest of the epic. Landed 2026-06-14, `cargo check`
  clean. *(Note: this is a defensive guard; the symptom's real driver — both devices sharing one peer_id —
  is removed for good by Step 1's per-device peer_id.)*

---

## 3. Design Decisions — LOCKED (2026-06-14)

The plan said each device "generates its own device key" without specifying how it relates to the master or
what id format it uses. Both resolved:

### Decision 1 — key derivation: **Option A (locked)**
Each device generates an **independent random per-device Ed25519 key** on first launch. The master key
(from the mnemonic) signs the device's pubkey into the device list. Rejected the deterministic-derivation
alternative (HKDF from master seed + index): it buys nothing — the list is master-signed either way and
devices are created interactively, so reproducibility has no use — while adding index-collision questions
and enlarging the master seed's use surface.

### Decision 2 — id format: **reuse the existing format unchanged (locked)**
**The crux: do NOT invent a new id format.** A device's peer_id = `compute_peer_id(device_key)` — the
**same `native_identity.rs:16-26` function**, just fed the per-device key instead of the master key.
Result: a device peer_id is byte-for-byte the same `12D3KooW...` shape and is **indistinguishable from any
other peer_id** to the relay, rooms, `dm_room_code()`, and Olm's `HashMap<String, Session>`. **Zero changes
to any peer_id-keyed code.** This is cheaper *and* better — not a tradeoff.

The **master pubkey** stops generating the peer_id and instead becomes purely the **cross-device link**:
it lives only in the signed device list and in the "is this peer me?" resolver.

| Layer | Drives | Key used |
|---|---|---|
| **Device** (peer_id, `12D3KooW...`) | relay routing, rooms, Olm/MLS keying — all existing code untouched | per-device random Ed25519, via the **same `compute_peer_id()`** |
| **Identity** (master pubkey) | display, friendships, the signed device list, "is this peer me?" | master key from mnemonic |

**Consequence for Step 6 (MLS):** because each device's peer_id is already distinct, each device's
credential `BasicCredential::new(peer_id.as_bytes())` is **already unique** — so the `peer_id:device_id`
composite credential floated earlier is likely **unnecessary**. The bare device peer_id may suffice as the
MLS credential, simplifying the hardest slice. Verify during Step 6; keep the composite only as a fallback.

**Device key storage — RESOLVED (2026-06-14):** the per-device key lives in a sibling file
`identity.device` next to `identity.key`, encrypted with the **same `SESSION_KEY`** (same password/keychain
unlock). NOT in the SQLCipher DB (the DB passphrase is master-derived, so a DB-resident device key would be
fine for ordering but the sibling-file approach is simpler and matches the existing `identity.key` pattern).
Protection-change FFIs re-encrypt both files together (`device_key::rewrite_device_key_protection`). The
master mnemonic remains the sole recovery secret; a lost device key just means re-linking that device.

**Restore semantics — RESOLVED:** `restore_identity_from_mnemonic` ("import my identity here") generates a
**fresh random** device key (distinct peer_id) — it IS the multi-device case. Only `load_or_create` /
background-load on an existing install seed the device key from the master (migration keystone).

---

## 4. Implementation Steps (the tracker)

Ordered so each step is independently testable and delivers value before the next. **Do not start a step
until the prior one is verified working on real devices.** Plan mode + live test between every step.

### Step 1 — Device identity foundation  ✅ code-complete (pending real-device test)
*Goal: each install has a distinct per-device peer_id, plus a master-signed device list. Fixes self-request
and mutual crypto-corruption for good. No fan-out yet.*
*All sub-tasks (foundation + publish/ingest + key routing + resolver wiring + Dart) landed. 315 Rust lib
tests + 16 Flutter widget tests pass. Behavior-neutral for single-device installs (migration keystone keeps
device==master). Awaiting the two-device live test below before declaring Step 1 done.*
*Full plan: `~/.claude/plans/steady-sleeping-sun.md`. Detailed sub-tasks tracked in the session task list.*

- [x] Decide §3 (key derivation + id format) — LOCKED: Option A (random per-device key) + reuse existing
      `compute_peer_id()` format unchanged. See §3.
- [x] Per-device key generation (distinct random Ed25519, NOT from the mnemonic) — `identity/device_key.rs`
      `load_or_create_device_keypair`; brand-new + restore = fresh random, existing install = seed from
      master (migration keystone). Unit tests pass.
- [x] Device peer_id = `compute_peer_id(device_key)` via existing `from_secret_bytes` — format unchanged.
      `IdentityData`/`IdentityInfo` extended with `device_peer_id`; codegen run (`devicePeerId` in Dart).
- [x] Device key storage = `identity.device` sibling file, same SESSION_KEY; protection-change parity wired
      into all 6 protection FFIs (`rewrite_device_key_protection`). See §3 resolved note.
- [x] Device list structure `SignedDeviceList` (master-signed, monotonic version) + signing/verify
      (`crypto_handler::{device_list_signing_payload,build_signed_device_list,verify_device_list}`,
      `native_identity::peer_id_from_pubkey_protobuf`). 5 crypto tests incl. tamper/wrong-identity reject.
      Field added to both ProfileUpdate wire variants (`#[serde(default)]`) + `DeviceListUpdated` event.
- [x] DB tables `device_lists` + `device_links` + methods (`device_list_version`, `save_device_list`
      version-gated upsert + reverse-index rebuild, `get_all_device_links`).
- [x] Resolver `node/resolver.rs`: `resolve(peer_id)→master` (unknown→self), `same_identity`, `update`/
      `update_many`/`seed_self`/`warm_from_links`. 5 tests. Process-global, lock-poison-safe.
- [x] Master identity pubkey retained as the cross-device link (the "who you are") — exposed via device list.
- [x] Publish (attach to both ProfileUpdate variants + `send_own_profile_to_peer`) + ingest (verify + monotonic
      version + persist + resolver update + `DeviceListUpdated`). [#6] — `crypto_handler::{build_local_device_list,
      ingest_device_list}`, `storage::load_device_list`, threaded via `handle_update_profile`/`handle_envelope_profile_update`/
      bare `ProfileUpdate` handler. Self-list persisted version-monotonically; own master never overwritten by a peer.
- [x] Key routing: **device key → WS auth + signaling register ONLY**; `local_peer_str`/`bundle_keypair`/MLS/
      signing/DB stay MASTER. [#7] — `spawn_node(native_keypair, device_keypair, …)`, rooms are master-derived so a
      device authenticates as itself yet sits in its identity's rooms. `peer_is_reachable` made resolver-aware (a master
      is reachable if any of its devices is in a room). Single-device fully preserved (keystone device==master).
      *DM/server-member SENDS to a true 2nd device need Olm fan-out (Step 3) — single-device + fresh-device-talking-to-
      single-device friends already work.*
- [x] Wire resolver into self/attribution sites. [#8] — `dm_room_code` resolves BOTH ends to masters (covers all 8
      call sites at once); DM receive attributes to sender's master (`convo_peer`) for thread key + DB key + sig context;
      `is_mine` ×3 via `same_identity`; friend-request self-guards (send + receive) via `same_identity`; DM
      edit/delete/reaction convo-key + reactor resolved to master. Bulk `member == local_peer` self-skips need NO change
      (both masters — see resolver header architecture note).
- [x] Dart attribution. [#9] — FFI `identity_for(peer_id)` + `get_device_links()` (+ `DeviceLink` struct);
      `device_link_provider` mirrors the resolver, warmed on node start + refreshed on `DeviceListUpdated`. Codegen run.
- [x] **Test (Vitalik, main + VM):** same mnemonic on two devices → *distinct* peer_ids, both connect to
      the relay simultaneously without overwriting; no "self friend request"; no crypto corruption; existing
      single-device install unchanged (migration keystone: device_peer_id == legacy peer_id).
      **Live-verified on host + phone + VM (2026-06-14, commit 2c0920d).** Step 1 DONE.

### Step 2 — Device list propagation (profile-attached)  ✅ code-complete (pending real-device test)
*Goal: friends learn your device list in a tamper-proof way.*

- [x] Attach the signed device list to the existing profile sync (`ProfileUpdated` flow, `social.rs`).
      **Done in Step 1** (commit 2c0920d): `build_local_device_list` re-signs with the master key and rides
      on all profile-broadcast paths (`handle_update_profile`, `ProfileUpdate` variants, `send_own_profile_to_peer`).
- [x] Clients accept a device list only if `version` ≥ highest seen for that identity (replay protection).
      **Done in Step 1**: `ingest_device_list` verifies the signature and enforces a strictly-increasing
      version before persisting; our own master's list is never overwritten by a peer.
- [x] Friend UI collapses multiple device peer_ids of one identity into one person (fixes the cosmetic
      "two online dots for you" from fact #10). **Done 2026-06-14 (Dart-side):** new
      `onlineIdentitiesProvider` + `identityIsOnline(ref, masterId)` in `device_link_provider.dart` fold every
      visible online *device* into its *master* identity (mirrors the Rust `peer_is_reachable`). All
      friend/DM/profile online checks now route through it — desktop (`friends_bar`, `channel_sidebar`,
      `home_dashboard` incl. the connection-health summary, `chat_pane` header/call-buttons/profile-panel) and
      mobile (`mobile_chats_tab`, `mobile_friends_tab`, `mobile_profile_sheet`, `mobile_chat_route`
      header/call-buttons). Single-device installs resolve each peer to itself → perfect no-op. `flutter
      analyze` clean (only pre-existing info lints); 16 widget tests pass.
      *Note: server-member panels (`member_panel`, `user_bar`, `mobile_member_panel/route`, `server_provider`,
      `channel_chat_pane`) deliberately NOT collapsed — server membership stays one-leaf-per-human until Step 6
      (MLS per-device leaves). A multi-device friend who is also a server member will show offline in the member
      list while online via a non-master device; fix lands with Step 6.*
- [ ] **Test (Vitalik):** with two devices of one identity online, a friend sees ONE online dot per person
      (not two), online-first sorting is correct, and DM header/call buttons reflect online-via-any-device.
      Single-device friends list behaves exactly as before. Add/remove a device → friends' clients update;
      old (lower-version) lists are rejected (Rust replay guard, already live).

### Step 2.5 — Sibling friend-list sync (presence on-ramp)  ✅ code-complete (pending real-device test)
*Goal: a freshly-linked device learns who its identity's friends are, so it joins their DM rooms and presence
flows both ways. Discovered necessary during the Step 2 live test: a fresh device (e.g. an imported mnemonic
on a VM) has an EMPTY friends table, so the `WsEvent::Connected` DM-room auto-join loop (`swarm.rs` ~L1446,
keyed on `load_friends()`) joins ZERO DM rooms → the new device is never in any friend's DM room → that friend
shows OFFLINE even when the new device is online. The Step 2 UI collapse was correct but had nothing to
collapse. This is the minimal fix (identity metadata only, no history — that stays Step 4/5) and is the
on-ramp to backfill.*

- [x] New wire type `HavenMessage::FriendListSync { friends: Vec<FriendListEntry> }` + `FriendListEntry`
      (peer_id/status/direction/requested_at), all `#[serde(default)]` (`types.rs`).
- [x] Send on sibling detect: in `PeerJoined`, when `peer_id != device_peer_id && same_identity(peer_id,
      local_peer_str)`, send our accepted friends DIRECTLY to the sibling (`swarm.rs`, plaintext `SendDirect`
      via `send_message_to_peer` — same path as `FriendRequest`/`FriendRemove`; siblings meet in the shared
      `inbox:{master}` room). Verified-self only.
- [x] Receive handler (`handle_incoming_request`): accept ONLY from a `same_identity` sender (drop injection
      attempts); per entry `save_friend` (idempotent — skips friends already present, never re-adds self),
      then `JoinRoom dm_room_code(local, friend)` so presence flows + future live DMs arrive; emit
      `NetworkEvent::FriendsBackfilled { count }`.
- [x] Dart: `event_provider` handles `FriendsBackfilled` → `friendsProvider.loadAll()` (friend appears, then
      the Step 2 collapse resolves its online status). Codegen run; `cargo check` clean; analyze clean; 16
      widget tests pass.
- [x] **CRITICAL FOLLOW-UP #2 — dropped the migration keystone (THE root collision).** Second log dive
      (VM `third_debug.txt` + Pixel via adb + AL Release log) found the actual blocker. Pixel was an existing
      install so its DEVICE id == MASTER id (`A9nW…`) via the keystone. But VM's MASTER is also `A9nW…`, so
      Pixel's transport id collided with VM's `local_peer_str` → VM filtered Pixel out as "self" and they never
      exchanged. Also, the per-node self-filter used ONLY `local_peer_str` (master), but the relay reports a
      node by its DEVICE id, so VM saw its OWN `VM-dev` in the room and key-exchanged/WebRTC'd with ITSELF
      (endless MAC-mismatch re-key — visible in the VM log). **Fixes:** (1) `device_key.rs` — NO MORE keystone;
      every device (even an upgrading single-device install) gets a FRESH random device id ≠ master. Master-keyed
      data (friendships, DMs, rooms, signing, DB passphrase) is unchanged; only the transport id rotates once.
      **FOLLOW-UP #2b (the last collision): existing installs already HAVE a keystone `identity.device` file
      (device==master), and #2 only affects NEW files — so Pixel/AL kept `device==master` after the rebuild and
      still collided.** Verified in the 3rd log set: VM(fresh, distinct) + AL(union-merged, saw 2 devices, all
      sessions OK) worked, but Pixel's `local=A9nW`==master persisted, so VM filtered Pixel as "self" and AL had
      an ambiguous `A9nW` (is it Pixel-device or VM-master?). Fix: `load_or_create_device_keypair` now ROTATES a
      legacy keystone file (device id == master id) to a fresh random id IN PLACE on next load (preserving
      at-rest protection via `save_keypair_to`); one-time, then stable. Unit test `legacy_keystone_file_is_rotated`.
      After this, every device — fresh import, brand-new, OR upgraded existing — has a distinct transport id ≠
      master. (2)
      swarm.rs — every presence/room self-filter now excludes BOTH `local_peer_str` AND `device_peer_id`
      (PeerJoined gossip+sync, RoomMembers room_set/profile/overlay/per-member loop, DiscoveredPeers, bootstrap,
      reconciliation sweep). (3) `ingest_device_list` non-self path now UNION-merges instead of reject-on-stale
      (the AL log literally showed `Ignored stale device list … v1<=v1` — two devices both at v1, so AL only ever
      learned one). `cargo check` clean, 16 widget tests pass. **NOTE: AL/Pixel transport ids change on next
      launch — expected.** Awaiting re-test.
- [x] **CRITICAL FOLLOW-UP #4 — inbox-room = sibling proof; pull+push friend sync; + isolated the DM-send gap.**
      5th log set (post device-list reset, all 3 rebuilt): device lists clean (2 devices), keystone rotation
      confirmed on Pixel(`JQcW`)+AL(`BVoC`). But VM still never got friends and never saw AL. Root: the friend
      share was gated on `same_identity`/list-diff, which needs the device-list already exchanged BOTH ways — a
      join-timing chicken-and-egg (VM's profile reached Pixel before Pixel was listening; Pixel never merged VM,
      never shared). **Fix:** a peer joining OUR OWN `inbox:{master}` room is BY DEFINITION our sibling (only our
      devices join our master inbox) — use that as the proof directly in PeerJoined: seed the resolver
      (`resolver::update(peer,master)`), PUSH our friend list, and PULL theirs via a new `HavenMessage::
      FriendListRequest` (responder replies `FriendListSync`; both verified-self). Covers either side being the
      empty device, independent of timing/resolver-warm order. `cargo check` clean, 16 widget tests pass.
      **ISOLATED THE REAL "messages don't send" CAUSE → it's Step 3, not a bug.** AL log: `SendMessage for A9nW
      (Pixel's MASTER) … Sent encrypted DM to OFFLINE A9nW` — even though Pixel is online as device `JQcW` and
      `JQcW` is in the DM room. The DM send resolves the recipient to their MASTER id, then targets it directly —
      but no device authenticates as the master, so the relay has no such room member → it falls to the offline
      buffer. **Delivery needs master→device reverse resolution + per-device fan-out = Step 3.** dm_room_code
      already shares a room; only the final per-device send is missing. The "feels worse" is exactly this: both
      ends are now master-aware, so sends address the master (nobody's transport id) instead of the live device.
- [x] **CRITICAL FOLLOW-UP #3 — friend-list send must target the LIVE sender, not the list-diff.** 4th log
      set: keystone rotation CONFIRMED working (Pixel's device id rotated `A9nW`→`JQcW…`, distinct from master).
      But VM stopped getting the friend backfill. Cause: the friend-list send was gated on `new_siblings` (device
      ids absent from our stored list), and across repeated wipe+reimport tests the stored device list accumulated
      DEAD ids (log showed "device set now 4 (v5)"). A reconnecting/fresh sibling whose id was already in the
      bloated list → `new_siblings` empty → no friend send. Fix: `ingest_sibling_device_list` now sends the friend
      list to **`sender_peer_id`** (the sibling that JUST contacted us, live, in-room) unconditionally — decoupled
      from device-list diff and from the `changed` block. Receiver is idempotent (skips known friends), so a
      redundant send is harmless. `cargo check` clean, 16 widget tests pass.
      **KNOWN LIMITATION (not blocking): device-list pollution.** Union-merge never removes ids, so each
      wipe+reimport leaves a permanent ghost device on AL/Pixel (4 accumulated in testing). Harmless to presence
      (P is online if ANY device is up) and to the friend-fetch (now sender-targeted), but unbounded. Proper
      cleanup = **Step 7 revocation** (master-signed remove). For a clean test slate, added a manual reset:
      FFI `reset_device_lists()` (clears `device_lists` + `device_links` + the in-memory resolver) +
      `MessageStore::clear_all_device_lists` + `resolver::clear_all`, surfaced as a "Reset Device List" button
      under User Settings → Security → MULTI-DEVICE. Run it on the devices that accumulated ghosts (AL + Pixel),
      then restart so live siblings re-merge a clean set. Codegen run; analyze clean; 16 widget tests pass.
- [x] **CRITICAL FOLLOW-UP #1 — sibling device-list MERGE (found via first Pixel/VM log dive).**
      First live attempt failed: NO `[HOLLOW-MULTIDEV]` logs on any device, AL still saw P offline when only VM
      up. Root cause: `ingest_device_list` had `if list.master_peer_id == local_master { return; }` ("a peer
      can't rewrite our own list" — correct for security) which ALSO threw away a **sibling's** list. So Pixel
      never learned VM-dev→P → resolver never mapped it → `same_identity(VM-dev, P-master)` stayed false → the
      sibling-sync branch never fired. Second latent bug: each device published its OWN list `[self-dev]` at
      version 1, so a friend (AL) hit the v1≤v1 replay guard on the second device and only ever learned ONE.
      **Fix (`crypto_handler::ingest_sibling_device_list`):** when a validly-master-signed list arrives for our
      OWN master, take the UNION of device ids, re-sign with `max(ours,theirs)+1`, persist, update resolver
      (`seed_self`), emit `DeviceListUpdated`; the merged list rides the next `send_own_profile_to_peer` (fires
      every PeerJoined) so friends converge on both devices. On discovering a brand-new sibling, send it our
      friend list right there (reliable trigger, not dependent on PeerJoined/resolver ordering). Both ingest
      sites (plaintext inbox `ProfileUpdate` @ swarm.rs ~7645 AND MLS-envelope @ ~6621) pass the master keypair
      + device id + ws ctx through now. `cargo check` clean, 16 widget tests pass. **Awaiting re-test.**
- [x] **CRITICAL FOLLOW-UP #5 — inbox-proof must MERGE device lists, not just share friends (THE presence
      fix).** Live-verified the gap: sibling detection (inbox-proof) and device-list merge were on two
      different rails. The inbox-proof shared friends + seeded the resolver but never merged device LISTS;
      the merge only fired via a `ProfileUpdate` carrying a `device_list`. A fresh-imported VM has NO profile
      row → never sends a ProfileUpdate → the profile-HOLDING device (Pixel) never learned VM's id → Pixel's
      list stayed 1 device → AL only ever ingested ONE device and P went offline when Pixel quit. **Fix:**
      (1) new `crypto_handler::merge_sibling_device_id` (union the proven sibling id into our own
      master-signed list, re-sign+bump+persist+`seed_self`, returns "grew") called from the PeerJoined
      inbox-proof block; (2) on a grow, re-announce our profile (carrying BOTH devices) to all room peers, so
      Pixel (already in AL's DM room) pushes the 2-device list to AL while online — `ingest_device_list` /
      `ingest_sibling_device_list` now return `bool` consumed by the plaintext `ProfileUpdate` handler; (3)
      de-gated the backfill announce from `load_profile` being Some (a profile-less device still sends its
      device list — empty profile fields + populated `device_list`). `cargo check` clean, 316 lib tests pass.
- [x] **Test (Vitalik, Pixel+VM+AnonListen): ✅ LIVE-VERIFIED 2026-06-14.** AL log:
      `[HOLLOW-DEVICES] Ingested device list for <master> (v2, 2 devices, +2 new)`; Pixel:
      `Merged inbox sibling … → own device set now 2`, `re-announcing to N room peer(s)`. **P STAYS ONLINE
      when only VM is up** (the real proof — confirmed by Vitalik). Friend list on VM populated. Olm sessions
      all confirmed bidirectional.
- [x] **CRITICAL FOLLOW-UP #6 — profile (name/avatar) attribution: key by MASTER, not device id. ✅
      LIVE-VERIFIED both sides, real-time.** Same attribution shape as the device-list bug, one layer up.
      Profiles were saved via `save_profile(&peer_str,…)` (the sender DEVICE id) while presence/UI collapse
      the identity to its MASTER — so a friend read "P's profile" under the master while the data lived under
      whichever device last wrote it, and a profile-less fresh device wrote a BLANK under its own device id.
      **Fix (3 parts):** (a) `social::save_incoming_profile(sender,…)` persists under `resolver::resolve(sender)`
      = master (used by BOTH ProfileUpdate handlers); `ProfileUpdated` event + server-member rename + Dart
      cache invalidation all key on the master. (b) **empty-profile guard** (skip the write if incoming
      display_name is empty AND a populated master profile already exists). (c) **sibling profile sync** in
      the inbox-proof block (a profile-less device `ProfileRequest`s its sibling; the reply resolves to its
      own master so it adopts the real name/avatar). Single-device unaffected (master == sender). `cargo
      check` clean, 316 lib tests pass. **The substitute device now shows the correct name/avatar AND a
      friend sees the right profile via either device, syncing in real time.** Remaining multi-device gap:
      DM DELIVERY between devices = Step 3 (Olm send-side fan-out). NOT Olm sessions (all confirmed bidi).

### Step 3 — Olm sender-side fan-out  ▢ not started
*Goal: a new DM reaches all of the recipient's devices.*

- [ ] Every encrypt-to-peer site encrypts once per recipient device session (N = 2-3).
- [ ] Audit ALL Olm encrypt call sites (see CLAUDE.md offline-image/caption ratchet rules — they get N×
      more delicate; do NOT burn ratchet slots).
- [ ] **Test:** desktop sends DM → both of friend's devices receive it; your own second device also receives
      your sent message (self-fan-out for sent-message sync).

### Step 4 — QR link + standalone snapshot transfer  ▢ not started
*Goal: a freshly-linked device feels full immediately.*

- [ ] Desktop shows QR (transfer key + relay rendezvous + expiry/nonce); phone scans (camera).
- [ ] One-time AES-256-GCM transfer key; standalone-encrypted snapshot streamed via relay (dumb pipe).
- [ ] Reuse `archive/exporter.rs` + `loader.rs` for the snapshot; chunk + resume for large DBs.
- [ ] New device generates its own device key, announces it (master-signed) on its profile (Step 2).
- [ ] **Test:** scan → phone populated with history; new device appears in friends' device lists.

### Step 5 — Backfill (device-first, peer-fallback)  ▢ not started
*Goal: close the offline gap. Nearly free — sync engine already does it.*

- [ ] On reconnect, pull gap from your other device first; conversation peer (signature-verified) as fallback.
- [ ] Wire onto existing signed-op + message-id-dedup sync (`DmSyncRequest`, `compute_delta`, `merge_ops`).
- [ ] **Test:** device #1 sends 10 msgs while #2 offline → #2 comes online → ends up with all 10 (via #1,
      and again via the peer with #1 offline; dedup makes double-delivery harmless).

### Step 6 — MLS per-device leaves  ▢ not started  ⚠ hardest slice
*Goal: server messages reach all your devices. Do this LAST of the functional steps — servers limp along
without it (a second device just won't see server messages until done).*

- [ ] Credential becomes `peer_id:device_id` (was bare `peer_id`) so one human can hold multiple leaves.
- [ ] Each device generates its own KeyPackage / leaf; a new device joining = Remove/Add via coordinator.
- [ ] Coordinator election moves to `{peer_id}:{device_id}` deterministic tiebreaker (fact #6).
- [ ] Re-audit all 8 MLS rules in `feedback_mls_patterns.md` against multi-leaf-per-human.
- [ ] **Test:** both your devices in a server → both decrypt channel messages; epoch/SFrame keys correct.

### Step 7 — Revocation (the sharp edge)  ▢ not started
*Goal: a lost/stolen device can be cut off everywhere.*

- [ ] Master-signed revocation `{ revoke device_pubkey, effective_at, version=N+1, sig }`, propagated on the
      profile channel with bumped monotonic version.
- [ ] On receipt: drop Olm session to revoked device + MLS Remove its leaf (coordinator).
- [ ] **Test:** revoke device → friends stop encrypting to it; its MLS leaf removed; old device list rejected.

### Step 8 — Sync Health / Devices panel (Settings)  ▢ not started
*Goal: honest visibility + management.*

- [ ] Linked devices list (label, last-seen, online/offline).
- [ ] Per-conversation DB-health comparison across devices (counts / latest-op timestamps; in-sync/behind/unreachable).
- [ ] Manual "Sync" button (drives Step 5 on demand).
- [ ] "Remove device" → triggers Step 7 revocation.

---

## 5. Risk Register

| Risk | Where | Mitigation |
|---|---|---|
| **MLS multi-leaf-per-human** breaks coordinator/epoch/SFrame assumptions | Step 6 | Do it last; re-audit `feedback_mls_patterns.md`; test epoch + SFrame key export with two same-identity leaves |
| **"Is this peer me?" miss** anywhere re-opens the self-request / mis-attribution bug | Step 1 (cross-cutting) | One central resolution helper; route ALL friend/profile/typing/message paths through it; the §2 guard is a backstop |
| **Olm fan-out burns ratchet slots** (offline-image/caption rules) | Step 3 | Honor existing CLAUDE.md ratchet rules per device; test offline captioned-image path with 2 devices |
| **Master key on every device** = larger attack surface | Step 4 | At-rest protection (`project_identity_protection_v2.md`); revocation (Step 7) limits blast radius |
| **Relay assumed single connection per peer_id** | n/a if distinct peer_ids | Plan's distinct-per-device peer_id sidesteps it entirely; do NOT let two devices share a peer_id |

---

## 6. Cross-references

- `reports/MULTI_DEVICE_SYNC_PLAN.md` — the design (decisions, flows, rejected alternatives).
- `HOLLOW_PLAN.md` Phase 6 — "Multi-device identity & sync (major epic)".
- `project_identity_protection_v2.md` — at-rest master-key protection.
- `feedback_mls_patterns.md` — MLS correctness rules (re-audit for Step 6).
- `feedback_sync_patterns.md`, `feedback_ui_dedup_by_message_id.md` — the signed-op + message-id-dedup sync
  that backfill reuses.
- `archive/exporter.rs`, `archive/loader.rs` — snapshot machinery reused at link time.
