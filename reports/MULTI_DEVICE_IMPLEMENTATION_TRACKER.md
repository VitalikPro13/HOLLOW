# Multi-Device Identity & Sync — Implementation Tracker

**Status:** In progress. Steps 1, 2, 2.5, 3, 4, 5, **6 (MLS per-device leaves), 7 (revocation), 8 (Devices
panel) ALL DONE and live-verified** (latest 2026-06-18, Pixel↔VM↔AL). A revoked device is cut off
everywhere AND self-nukes (wipe + relaunch to Welcome) from any online path; the Devices panel lists/labels/
removes devices. 335 lib + 21 widget tests pass; clippy/analyze clean. Step 7's live test surfaced a chain of
multi-device send/attribution bugs (ghost-device fan-out → phantom chats + stuck pills; tombstone never
reaching the revoked device; self-nuke toast crashing the wipe) — all fixed, see [[feedback_ghost_device_fanout]].
Remaining: **Step 9 (epic closing point: multi-device push + app-wide test suite, done LAST)** + the minor
**9C server-UX polish** items. Step 5 detail in its section below;
earlier baseline:
Steps 1, 2, 2.5, **3 DONE and live-verified** (host+phone+VM, commit `bbf91aa`):
per-device identity, presence collapse, profile sync, sibling friend-list sync, and Olm sender-side DM
fan-out all work — a friend sees one online identity with the right name/avatar via any device, and DMs
(message/edit/delete/reaction/file/image) fan out to all the recipient's devices AND your own siblings
(real-time mirroring). **Step 4 (device linking + snapshot sync) DESIGN LOCKED, not yet started** — full
design in `reports/MULTI_DEVICE_STEP4_LINK_DESIGN.md` (QR cut; codes + mnemonic; reuse
`export_backup`/`ws_stream_transfer`; honest real-time progress). Next session implements it.
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

### Step 3 — Olm sender-side fan-out  ✅ code-complete (pending real-device test)
*Goal: a new DM reaches all of the recipient's devices, AND a DM typed on one of YOUR devices mirrors
live onto your other device (self fan-out — real-time mirroring, distinct from Step 5 history backfill).*

**Root cause (confirmed in code):** Dart sends DM commands targeting the recipient's MASTER id (that's
what the friend list / UI keys on). But Olm sessions, `pending_messages`, and `ws_room_peers` are all keyed
by DEVICE peer_ids — the master matches none of them, so `olm.has_session(master)` is false and
`ws_room_for_peer(master)` is None → the send silently drops ("peer unreachable — not delivered") or lands
in the offline buffer addressed to an id no device authenticates as. The entire receive/session/drain
machinery (key exchange, `pending_messages` drain on PeerJoined/RoomMembers/KeyBundle, DM-sync) was ALREADY
per-device; only the SEND entry point was master-keyed.

**The fix (all client-side, relay untouched):**
- [x] `resolver::devices_for(master) -> Vec<String>` — reverse lookup (inverse of `resolve()`), excludes the
      bare master (no device authenticates as it). EMPTY for an unknown master → caller falls back to the
      master id as-is = byte-for-byte pre-multi-device behavior. 2 new unit tests (318 lib tests pass).
- [x] **Fan-out helper** `message_ops::fan_out_dm_envelope` + per-device `send_dm_to_device`: expand the
      recipient master into `devices_for(recipient) ∪ devices_for(own_master)` (self fan-out, minus THIS
      device), then run the existing three-way branch (online / offline-buffer / no-session-KeyRequest) once
      per target device. **EXACT-device reachability** (`ws_room_for_peer(...).is_some()`, NOT the
      identity-wide `peer_is_reachable`): in a fan-out device A may be online while sibling B is offline; the
      identity-wide check would route B down the online path and `send_encrypted_message`'s own exact-membership
      lookup would then DROP B's copy with no offline buffering.
- [x] **Every DM send path fanned out** (real-time mirroring, per Vitalik): new message (`handle_send_message`),
      edit (`handle_edit_dm_message`), delete (`handle_delete_dm_message`), reaction add/remove
      (`handle_add/remove_dm_reaction`), AND files/images/video (`file_handler::handle_send_file` DM branch
      wrapped in a per-device loop). Local DB write + UI event stay keyed on the MASTER. `device_peer_id`
      threaded into all 6 handlers + their swarm call sites (internal node params — NO `api/` change, NO codegen).
- [x] **Offline-image/caption ratchet rules honored PER DEVICE** (CLAUDE.md): the "caption sent exactly once
      via `send_encrypted_text_to_peer`, never `send_encrypted_message`" rule generalizes to "exactly once PER
      DEVICE" — each device has its own Olm ratchet, so the per-device loop is the correct shape. Per-device
      stream temp file (`.stream_send_{file_id}_{device}.tmp`) so concurrent sibling streams don't collide.
- [x] **Self-echo conversation attribution (the subtle part).** A DM envelope carries no recipient/convo
      field, so the receiver historically resolved the conversation from the SENDER. That breaks self fan-out:
      the sibling echo's sender is US, so it would file our outgoing DM under a conversation with ourselves.
      **Fix:** new `#[serde(default)]` `convo` field on `DirectMessagePayload` (the OTHER party's master),
      populated ONLY on the sibling-echo copy (`build_dm(Some(recipient_master))` in message + file paths) and
      consumed in the receive path (`(is_own_device, convo) => file under convo`). Backward-compatible (None on
      every normal send → resolve(sender), exactly as before). For edit/delete/reaction the envelopes carry NO
      convo (no field added) — the message already exists on the sibling under the right thread, so the receive
      path looks the convo up by `mid` via new `MessageStore::get_dm_message_peer` + helper `dm_event_convo`.
- [x] **Self-echo edit/delete authorization.** The DM edit/delete receive guards required `is_mine==false`
      (only the sender may edit/delete). A sibling echoing OUR OWN edit/delete carries `is_mine==true`, so the
      guard now also allows it WHEN `same_identity(sender, local_master)` (a verified sibling) — the security
      guard against a genuine peer editing our messages is preserved (peer + is_mine=true still rejected).
- [x] **Pending-queue edit patch now scans all device queues** (was keyed only on the master): the original
      message is queued per-device now, so an edit-before-delivery must patch every device's queued copy.
- [x] **FIRST LIVE TEST (AL + Pixel) FAILED → root cause + 2 follow-up fixes.** Symptom: both showed each
      OTHER Offline (no "Encrypting…"), AL's first DM lost, messages eventually flowed ~1 min late. Log dive
      (AL `Sent encrypted DM to offline 12D3KooWBkiY…`; Pixel same to the SAME `BkiY`) found it was NOT a
      fan-out logic flaw but **device-list pollution**: many wipe+reimport cycles left a GHOST device id
      (`BkiY`) attached to each identity's master, while the LIVE device (`BVoC` for AL, `JQcW` for Pixel) was
      either absent from the stored list or lost the version race. So `devices_for(master)` returned the dead
      ghost and the fan-out skipped the connected device. Presence broke for the same reason (resolver never
      mapped the live device → master). **Two durable fixes (make the system robust to pollution, not just a
      one-off cleanup):**
      (1) **Live-room union for fan-out targets** — `message_ops::collect_target_devices` (+ the file path)
      now targets `devices_for(master)` UNIONED with every peer CURRENTLY in the DM room that resolves to that
      master. Live presence is authoritative: an online device is always reached even if the stored list is
      stale; a ghost id is harmless (queues + KeyRequests, never connects).
      (2) **Sender-device link registration** — `crypto_handler::ingest_device_list` now registers (and
      persists into `device_links`, emitting `DeviceListUpdated`) the SENDER device → master link, because a
      device that delivered a master-signed list provably belongs to that master EVEN IF absent from the
      signed `devices` (stale list / rotated id). This is what lets presence collapse the live device and the
      union match it by `resolve(sender)==master`. 318 lib tests pass, clippy clean, no codegen.
      *NOTE: union never removes the ghost (cleanup = Step 7 revocation), so for a clean re-test Vitalik resets
      the device list on AL + Pixel (Settings → Security → Multi-Device) then restarts → lists re-converge with
      only live device ids.*
- [x] **2ND LIVE TEST (AL + Pixel, then VM imported): DM FAN-OUT WORKS.** After the device-list reset +
      live-union + sender-link fixes: AL ingests P's list cleanly (`v1,1` → `v2,2 devices` = Pixel+VM), NO more
      "Sent to offline <ghost>", AL→DM reaches BOTH Pixel and VM live. First message to VM was missed only
      because VM joined the DM room ~990s AFTER that send (it was still importing) — expected, closes via
      Step 5 backfill, NOT a bug. Recipient fan-out + self fan-out confirmed working.
- [x] **UI follow-ups found in the 2nd test (multi-device attribution, both Dart-only, no codegen):**
      (1) **Typing indicator** — the `TypingStarted` event carries the sender's DEVICE id, but the chat view
      looks up typing by the friend's MASTER id, so they never matched → indicator never showed. Fixed:
      `event_provider._dispatch` resolves the typist via `deviceLinkProvider.identityOf` before `setTyping`
      (DM key + stored typist both collapse to master; single-device no-op).
      (2) **Home tab network-status column** (`home_dashboard._NetworkColumn`) — looked up `peers[f.peerId]`
      / `connStatus.peers[f.peerId]` by the friend's MASTER id, but those maps are DEVICE-keyed, so a
      multi-device friend never matched the encrypted/connected branches and showed stuck "connecting" forever.
      Fixed: scan for ANY device of the friend's master that's encrypted/connected (`links.identityOf(e.key)
      == f.peerId`). Single-device collapses to the old direct lookup. `flutter analyze` clean, 16 tests pass.
- [x] **ROOT-CAUSED + FIXED (relay-side) — the WS/relay presence flakiness was GHOST-CONNECTION EVICTION.**
      2nd test showed AL↔Pixel presence ASYMMETRIC (Pixel showed AL offline despite DMs flowing); AL saw Pixel
      LEAVE all shared rooms at t≈...095 and not rejoin until t≈...916 (~14 min) with NO Pixel `Connecting to
      wss` in that window. **Root cause (read in `relay-uws/src/ws_handler.cpp`):** the relay keys
      `peer_sockets` + every `ws_rooms[room].peers` slot by `peer_id` with NO duplicate-connection handling.
      When a client reconnects (mobile resume / blip / TLS re-handshake) it opens a NEW socket while its old
      TCP socket is still half-open — the relay doesn't notice the dead socket until its 120s `idleTimeout`
      fires. During that window the new socket takes over the rooms and works fine; then the OLD socket's
      delayed close runs `cleanup_peer` → `leave_room` for every room in the (stale) `peer_rooms[peer_id]`,
      **erasing the LIVE socket's room entries and broadcasting `peer_left`** to friends. The peer never
      reconnects (its socket is fine), so nothing rejoins until the 60s `check_peers` self-heal — the ~14-min
      phantom-offline. **Fix (deployed 2026-06-15):** (1) `handle_auth` now SUPERSEDES a stale duplicate — when
      a newer socket authenticates for a `peer_id` that already has a different socket, the old one is marked
      `superseded`, its rooms+socket entry are evicted immediately, and it's closed (`end(1000,"superseded")`);
      the new socket re-joins via the `WsEvent::Connected` loop so friends get a fresh `peer_joined`+members.
      (2) `cleanup_peer`/`leave_room` are now socket-aware (`expected_ws`): a closing socket only tears down the
      peer's shared state + a room slot if that slot STILL points at it, so a ghost can never unjoin the live
      successor. PURE relay change — no Rust/Dart/codegen. Client-side `RoomMembers`/`PeerLeft` reconciliation
      was already correct; it was being fed a lie. Built+deployed to VPS, relay active on :443.
- [x] **ALSO FIXED (relay-side) — first-DM-to-a-just-connected-peer was silently dropped (the "VM/peer doesn't
      get the FIRST message, only later ones" + "session can't establish with the other device" symptoms).**
      In `handle_direct` (text) and `handle_binary_direct_msg` (0x04/0x08), if the target was connected
      (`peer_sockets` had it) but NOT yet in the DM room — the race window between a recipient's WS auth and its
      DM-room join, also widened by the ghost-eviction flap — the message was dropped with no buffer, no
      delivery, no push. **Fix:** buffer the frame in that case too (replays the instant they join the room),
      pushing only when FULLY offline. This is what makes a fresh device's first plaintext KeyRequest /
      FriendRequest / SyncRequest / DM actually land, so the Olm session establishes. Buffer is per-(peer,room)
      capped + TTL-swept; receiver dedups by message_id, so a redundant buffered copy is harmless.
- [x] **DETERMINISTIC DM ROOMS — `dm_room_code` made PURE (no resolver). ✅ LIVE-VERIFIED.** The committed
      multi-device work had `dm_room_code` resolve BOTH ends through the device→master resolver, breaking the
      load-bearing invariant that two friends always compute the SAME room: the moment one side's resolver
      diverged (stale/polluted link, or one side ingested a device list the other hadn't) they computed
      DIFFERENT rooms, never met, and key exchange never landed → "keying error" for AL's OTHER plain friends.
      **Fix:** `dm_room_code(a,b)` is now a pure function of the two ids (no resolver) — room = f(my_master,
      friend_identity), both sides always agree, byte-for-byte pre-multi-device. Sub-devices still share the
      room because the event loop passes the MASTER for the local end. Per-device fan-out sends now target the
      MASTER-pair room (computed from `recipient_master`) with the device id only as the direct `target_peer`
      (message_ops `send_dm_to_device` takes `dm_room`; file_handler uses `dm_room_f`). 318 lib tests pass.
- [x] **DEVICE-LIST SELF-HEAL — stale-on-own-restart presence + typing. ✅ LIVE-VERIFIED.** Symptom (Vitalik):
      presence went stale across a plain restart and ONLY a manual Device List reset fixed it. Two parts:
      (1) `social::send_own_profile_to_peer` was GATED on `load_profile == Some`, so a friend never received
      our device list when we had no profile row — every `[HOLLOW-DEVICES]` ingest was missing. De-gated: ALWAYS
      send the device list (empty profile fields if none); receive-side empty-profile guard prevents clobber.
      (2) `crypto_handler::ingest_device_list`'s `nothing_new` early-return (redundant v1 re-ingest on reconnect)
      now ALSO emits `DeviceListUpdated`. Dart's `deviceLinkProvider` warms ONCE at startup, RACING the Rust
      resolver warm; if Dart won it cached an empty map and never refreshed (no event) → a keystone-rotated
      friend (device≠master, e.g. AL = device BVoC / master JJU9) showed OFFLINE until a reset forced a
      version-bumping ingest. A peer re-sends its list on every room join, so emitting on the redundant path
      makes Dart re-pull the warm map within seconds of every reconnect — the self-heal that removes the reset.
- [x] **SIBLING-ECHO DM DIRECTION — `MessageReceived.is_own`. ✅ LIVE-VERIFIED (needed codegen).** Symptom: when
      Pixel sent "123" to AL, the sibling echo to VM rendered as an INCOMING message from AL (Pixel→AL mirrored
      to VM looked like AL→VM). The DB row was correct (`is_mine=true` via `is_own_device`), but the live
      `MessageReceived` event had NO direction field so Dart always rendered incoming. **Fix:** added `is_own:
      bool` to the `MessageReceived` event (codegen); Dart `chatProvider.receiveMessage(isOwn:)` sets
      `isMe=true`; the own-echo event path skips unread/notification and marks the DM seen. Dedup-by-message_id
      still guards doubles.
- [x] **DM TYPING INDICATOR — master→device fan-out. ✅ LIVE-VERIFIED (no codegen).** DM typing sent
      `HavenMessage::TypingIndicator` to the recipient's MASTER id; `send_message_to_peer(master)` finds no room
      (no socket authenticates as the master) and silently drops → zero typing on receivers. **Fix:**
      `handle_send_typing_indicator` fans typing out to the recipient's DEVICES (`devices_for` UNION live DM-room
      peers resolving to that master), same pattern as DM message fan-out; single-device falls back to the master
      id. Receive side was already correct (resolves device→master, keys DM typing on master). Added
      `[HOLLOW-TYPING]` send+receive logs.
- [x] **CHAT-HEADER ENCRYPTED STATUS — scan-by-master. ✅ LIVE-VERIFIED (Dart-only).** The DM header status label
      (`chat_pane.dart`) looked up `peersProvider[widget.peerId]` (master) but `peersProvider` is DEVICE-keyed →
      always null for a multi-device/keystone-rotated friend → showed Offline while dots/call-buttons (which
      collapse by master) showed online. Fixed: scan for ANY device of the master with an encrypted session
      (`links.identityOf(e.key) == widget.peerId && e.value.isEncrypted`) — same pattern as the Home column.
- [x] **TEST (Vitalik): ✅ ALL LIVE-VERIFIED 2026-06-15.** Presence symmetric+stable across restarts (no reset
      needed); old-build device re-establishes Olm session; first DM lands; plain friends key fine; sibling DMs
      render outgoing; typing shows for a multi-device friend; chat header reads Encrypted. Single-device
      unaffected throughout. **Step 3 is DONE.** Remaining multi-device gap = servers/MLS (Step 6) — a second
      device won't see server messages and server member panels intentionally don't collapse (see
      `project_multidevice_migration_state` memory).

### Step 4 — Device linking + snapshot sync  ✅ LIVE-VERIFIED 2026-06-15 (one follow-up bug open)
*Built + live-verified in one session (Pixel master → VM subdevice). Full code-path link works
end-to-end: enter code on empty device → populated device confirms → encrypted `.hollow` blob
streams → receiver stashes + restarts → imports via the backup pipeline → fully synced with all
messages/friends/profile. 318 lib + 16 widget tests pass; relay deployed + active on VPS.*

**⚠ THE WINNING ARCHITECTURE PIVOT (after the in-place import kept corrupting the identity):** the
link transfer **REUSES the `.hollow` backup pipeline end-to-end**, with the link CODE as the
passphrase, and imports on the **NEXT LAUNCH (pre-node-start)** — NOT in-place. The in-place
`import_snapshot_bytes` fought the live SQLCipher connection + WAL + a protection-mismatched throwaway
`identity.device` → "Loading… forever". Stash-and-reboot sidesteps all of it. See
`feedback_link_import_identity_device` memory for the full why. **The description below documents the
ORIGINAL in-place design and is partially superseded** — the live code is the stash-and-reboot flow.

**What landed (live code):**
- **Snapshot/backup core** (`api/storage.rs`): `export_backup_bytes(code,…)` produces the exact
  `.hollow` bytes; receiver `stash_pending_link(blob, code)` writes `pending_link.hollow` +
  `pending_link.code`; next launch `has_pending_link()` → `import_pending_link()` (deletes throwaway
  identity, then `import_backup_bytes` — identical to a manual restore). `import_backup`/`export_backup`
  now delegate to these `_bytes` cores.
- **Transfer** (`ws_stream_transfer.rs`): `StreamKind::LinkSnapshot` (TYPE_LINK=3) reuses the chunked
  binary pipeline + the real-byte `stream_progress()` AtomicU64. Completion arm STASHES (no in-place
  import) → emits `LinkComplete` → UI auto-restarts.
- **Push-completion is RECEIVER-ACKED (2026-06-17 UI fix).** The sender used to emit `LinkPushComplete`
  the instant `ws_stream_send_bytes` returned — but that only means the chunks were QUEUED into the local
  WS channel, not received. So Pixel flashed "Data sent" while VM was only just starting its progress bar.
  Now: the sender stays on its "Sending your data" spinner; the receiver sends a new
  `HavenMessage::LinkSnapshotAck { link_id }` right after it successfully stashes the blob (before emitting
  its own `LinkComplete`, so it flushes well within the ~1.8s pre-restart window); the sender's dispatch
  arm for that ack emits `LinkPushComplete` → `pushDone` ("Data sent. Your other device received
  everything"). No codegen (internal wire variant + existing event). ALSO fixed: `onDisconnected()` no
  longer tears down an in-flight `waiting/receiving/importing/sending` phase on a transient relay blip
  (the link handshake churns the connection + the receiver restarts) — that was the "after entering the
  code the 'Linking this device' dialog vanished and reverted to the enter-code screen" symptom.
- **Enter-code error/back nav FIXED (2026-06-17).** Two more UI quirks: (a) a WRONG code then "Close"
  popped the dialog with `null` (not the `true` the shell's go-back path checks) → Welcome was gone and
  the user stuck on a blank screen. The `_failed` view on the enter-code flow now shows **"Try again"**
  (resets phase→idle so the dialog re-renders the enter-code view IN PLACE — recoverable, no pop/restart)
  + a **"Back"** ghost (pops `true` → Welcome). (b) Enter-code "Cancel"/"Back" discards the throwaway
  identity and returns to Welcome, but the shell did a bare `exit(0)` after `deleteIdentity()` — the app
  just DIED. Now it spawns a fresh process first (mirrors `_restartApp`), so the user lands back on
  Welcome.
- **Go-back must WIPE the data dir, not just delete identity.key (2026-06-17).** After (a)+(b), backing
  out STILL broke Welcome (infinite loading: couldn't create new / link / import). Cause: `delete_identity()`
  ran in-process while the live node held open SQLCipher handles (CrdtStore/CryptoStore actor threads +
  WAL/-shm); on Windows `remove_file` on an open `messages.db` fails silently, so it survived — encrypted
  with the throwaway passphrase — and the next identity's derived passphrase couldn't open it. **Fix
  (stash-and-reboot, same window as the link import):** 3 new FFIs in `api/storage.rs` —
  `stash_pending_wipe()` (writes `pending_wipe.marker`), `has_pending_wipe()`, `perform_pending_wipe()`
  (reads the data dir and removes EVERY entry — `identity.*`, `messages.db*`, `device_lists`, `vault/`,
  `files/`, stray `pending_link.*` — except the marker, removed last, + any `*.lock`). Go-back now calls
  `stashPendingWipe()` + relaunch; `_bootstrap` runs `performPendingWipe()` BEFORE the pending-link check
  and identity load (pre-node-start = no open handles). Codegen run, `cargo check` + `flutter analyze`
  clean. All Step 4 link UI quirks now resolved; awaiting Vitalik live re-test.
- **Orchestration** (`node/link_handler.rs`, NEW): rendezvous via `link:{code}` room; claim/resolve/
  push/pull. Code path: populated device claims code + joins room; empty device resolves + joins +
  `LinkSnapshotRequest`; populated device confirms → `AcceptLinkPush` exports `.hollow` (code as
  passphrase) + streams. Receiver's typed code held in a process-global (`set_my_link_code`/
  `my_link_code`) so the deep `LinkSnapshotKey` handler can read it. Mnemonic path (B6): empty device
  auto-requests from an online sibling (passphrase = shared master id).

- [x] **RESOLVED (2026-06-17) — first VM→friend DM doesn't mirror to the freshly-linked sibling.**
      Symptom: AL↔VM/Pixel all sync EXCEPT the very FIRST message VM sends to friend AL never echoes to
      sibling Pixel; every message after it does. **The earlier "fan-out targeting" / inbox-union
      hypothesis was WRONG** — that's why the first fix attempt (union `inbox:{master}` peers) didn't
      help; the targeting was already correct. **Actual root cause (proven from `third_debug.txt`):** an
      **Olm session race during the link handshake.** The freshly-linked device and its source sibling
      churn their Olm ratchet hard right after the snapshot transfer — `MAC mismatch — removing stale
      session`, then `KeyRequest … peer lost theirs, re-keying`. At the instant of the FIRST user DM the
      local side believes the sibling session is *confirmed bidirectional* (`has_confirmed_session` true,
      a SessionAck cleared it), but the PEER has silently lost its half. `send_dm_to_device` takes the
      **online branch** (`send_encrypted_message`) and encrypts on that doomed ratchet — undecryptable on
      the sibling. The online branch **never queued into `pending_messages`**, so (the relay never ACKs)
      that copy was lost forever. ~1s later the peer's `KeyRequest` re-keys cleanly, so message #2+ ride
      a good ratchet and arrive. **Fix (`message_ops::send_dm_to_device`):** the online branch now ALSO
      pushes the envelope into `pending_messages` (capped at 20/device). The existing re-key/decrypt-fail
      drain (`swarm.rs:~3765`), PeerJoined drain (`~1837`), and KeyBundle drain all `.remove()`-drain it
      on the FRESH session → the first echo self-heals; receiver dedups by `message_id` so the redundant
      copy on a healthy session is harmless. This generalizes the offline-branch self-heal and also hardens
      ALL DMs against the broader "peer silently lost session" desync (`feedback_olm_session_self_heal`),
      not just the link case. `cargo check` clean (no FFI/codegen). Approach Vitalik-picked 2026-06-17.
      **Observed-but-separate:** in the test log the freshly-linked device had `device_peer_id == master`
      (legacy keystone NOT rotated after `import_pending_link`) — the retry-queue fix resolves the reported
      symptom regardless, but the import path's keystone rotation should be re-verified (see memory).
      **Awaiting live re-test (VM→AL first DM mirrors to Pixel).**
- **Relay** (`relay-uws`): `linkcode_to_peer`/`peer_to_linkcode`/`linkcode_expiry` maps (clone of
  nicknames); `claim/resolve/release_link_code` verbs; `cleanup_peer` erasure; `sweep_link_codes`
  5-min TTL on the 300s timer; one-shot consume on resolve. **Deployed + active on VPS.**
- **Events/commands/FFI**: `LinkProgress`/`LinkComplete`/`LinkFailed`/`SiblingLinkAvailable`/
  `LinkCodeClaimed`/`LinkCodeError`; NodeCommands + 6 FFI fns (`claim/release/resolve_link_code`,
  `request_link_snapshot`, `accept/decline_link_push`); ws_client WsCommand/WsEvent/ServerMsg mirror
  the nickname pattern; HavenMessages `LinkSnapshotRequest`/`LinkSnapshotKey`/`LinkDeclined`. Codegen run.
- **Flutter**: `device_link_sync_provider.dart` (phase state machine + 6-char code gen, unambiguous
  alphabet); `device_link_dialog.dart` (show-code + countdown, enter-code + scope toggles, confirm-push,
  ONE real progress bar, honest "Servers & history copied" label, `exit(0)` restart on done);
  `event_provider` dispatch; Welcome "Link a device" card (throwaway identity → enter-code, skips
  mnemonic-backup nag); shell auto-opens enter-code after node start + a global `ref.listen` pops the
  confirm flow on the populated device; Settings → Security MULTI-DEVICE "Link a device" (show-code).

**KEY IMPLEMENTATION DECISIONS (made during build, beyond the design):**
- **Code-path bootstrap = THROWAWAY identity + one restart.** The empty device has no `identity.key`
  until the snapshot arrives, but needs an identity to connect/join `link:{code}`. So Welcome "Link a
  device" creates a normal (throwaway) identity, connects, pulls the snapshot which REPLACES
  identity.key + messages.db, then `exit(0)` → next launch re-derives the real DB passphrase from the
  real identity and opens the real DB. The restart is REQUIRED: the running node holds the throwaway
  DB connection (old passphrase) and can't read the newly-imported real DB (different passphrase).
  Mirrors the existing `import_backup` restart UX.
- **Snapshot IS the master-key handoff** (code path): the zip already contains `identity.key`, so no
  separate key-exchange. Authorization = the populated device's on-screen Confirm (it's not a verified
  sibling yet, so the `LinkSnapshotRequest` handler does NOT require `same_identity`).
- **Roles are unambiguous:** the POPULATED device always shows `SiblingLinkAvailable`→confirm (via the
  `LinkSnapshotRequest` handler); the EMPTY device never does (it requests). B6's empty-side path
  auto-*requests* rather than emitting a confirm event, so the provider's confirm-push is always correct.

**Deferred from v1 (design has them; build skipped for scope):** direction recommend+dropdown UI
(empty always pulls, populated always confirms — no manual reverse), both-populated merge/replace/export
escape hatch (replace-only for now), QR (cut by design). These are additive and don't block the core flow.

#### Original locked checklist (all items above satisfy these):


*Goal: a freshly-linked device feels full immediately.*
**Full design: `reports/MULTI_DEVICE_STEP4_LINK_DESIGN.md` (2026-06-15, all decisions Vitalik-
locked). The original QR ceremony in `MULTI_DEVICE_SYNC_PLAN.md` §3 is SUPERSEDED — read the new
design doc, not the plan §3.**

**Key design shifts (why this is smaller than the plan implied):**
- **QR is CUT entirely.** Pairing = type 24 words (works TODAY — Steps 2.5/3 already pull
  friends+profiles from an online sibling) OR a **6-char relay code**. No `qr_flutter`, no
  `mobile_scanner`, no camera. The mnemonic IS the auth; the code is convenience.
- **The 6-char code reuses the temporary-nickname RAM-on-relay pattern verbatim** (clone
  `nickname_to_peer` → `link_code → peer_id`, `claim_link_code`/`resolve_link_code` text verbs,
  released on disconnect/TTL). Nothing new on the relay beyond a text verb.
- **Snapshot = reuse `export_backup`/`import_backup` (`api/storage.rs`)** — already a full
  DB+identity AES-256-GCM blob with files/vault toggles. Split out in-memory
  `build_snapshot_bytes`/`import_snapshot_bytes`. NOT `archive/exporter.rs` (that's per-conversation).
- **Transfer = reuse `ws_stream_transfer.rs` + a new `StreamKind::LinkSnapshot`** — the
  `stream_progress()` AtomicU64 gives a GENUINELY REAL byte-progress bar (Vitalik rejected fake
  per-category bars).

**Locked decisions (design doc §10 + body):**
- [ ] Snapshot core refactor: `build_snapshot_bytes(include_vault, include_files)` +
      `import_snapshot_bytes(bytes)` (in-memory, one-time random AES-256 key — NOT a passphrase;
      relay carries ciphertext). Existing on-disk Settings export keeps its Argon2id wrapper.
- [ ] `StreamKind::LinkSnapshot` in `ws_stream_transfer.rs` + `LinkProgress{phase,bytes,total}` /
      `LinkComplete{summary}` / `LinkFailed{reason}` events. ONE real bar; end-summary counts from
      real `count_*` FFIs (no mid-transfer per-category fiction).
- [ ] Relay: `link_code → peer_id` RAM map (clone of nicknames) + claim/resolve verbs. 6 chars,
      unambiguous alphabet (no 0/O/1/I/l), **5-min TTL with on-screen countdown below the code**,
      released back to the pool on expiry, one-shot (consumed on link).
- [ ] Code path: master-key handoff over the live relay channel AFTER the **populated device
      confirms on-screen** ("a new device wants to link — send identity + data?"). Code = rendezvous
      token, the human tap = authorization.
- [ ] Rendezvous = the shared `inbox:{master}` room (no dedicated link room — siblings already meet
      there).
- [ ] Direction = auto-detect via a tiny state-summary exchange (**msg count + friend count +
      has-profile** — internal direction-pick only, NOT a UI feature; per-conversation comparison is
      Step 8). Recommended action shown prominently; reverse behind a warned dropdown ("overwrite the
      other device"). "Other device must be online" labeled.
- [ ] Receiver DB handling = **replace wholesale** (empty target; the point is to SYNC full data).
- [ ] Both-populated (re-link / two masters): honest prompt — **merge** (safe via message_id dedup,
      default) / replace (warned dropdown) / **export escape hatch** (transplanted Security-tab slice:
      re-show phrase / export identity with files/vault choice, so two separate identities aren't
      trapped).
- [ ] Auto-pull on FIRST sibling-detect (master auto-offers + confirms, then pushes). After first
      pull, gaps close via Step 5 backfill + manual Sync (Step 8). No whole-DB re-push per reconnect.
- [ ] **Welcome dialog redesign (IN Step 4 scope):** Create new identity / Import (24 words) / Link a
      device (code). Plus a "Link / sync a device" affordance in Settings → Security → Multi-Device.
- [ ] **Honest server caveat:** snapshot copies server membership + history ROWS (they appear), but
      live server messaging + MLS leaf are Step 6 — label UI "Servers & history copied", NOT "synced".
- [ ] New device generates its own device key + announces it (master-signed) — Steps 1/2, already live.
- [ ] **Test:** code/phrase link → empty device shows progress (real bar) → populated with history;
      direction auto-picked; both-online required; new device appears in friends' device lists.

**Open (decide when wiring, non-blocking):** none material — §10 of the design doc resolved all four
original open questions.

### Step 5 — Backfill (device-first, peer-fallback)  ✅ LIVE-VERIFIED 2026-06-17 (Pixel↔VM↔AL, "near-instant")
*Goal: close the offline gap. Done by extending the existing identity-agnostic DM-sync rails to siblings.*

**Scope (Vitalik-locked):** DMs only (servers/MLS = Step 6); trigger on every sibling-detect + reconnect,
incremental via per-conversation since-timestamps. Reuses the friend `DmSyncRequest`/`DmSyncBatch` pattern.

- [x] **New storage methods** (`storage/messages.rs`): `get_dm_messages_for_sibling(convo, since, limit)`
      (returns BOTH directions — friend path's `get_dm_messages_since` is `is_mine=1`-only; a sibling needs
      the friend's half too, carries `is_mine` through for render side) + `get_latest_dm_timestamp_any(convo)`
      (MAX timestamp, NO `is_mine` filter — so the requester's high-water mark spans both directions and we
      don't re-pull our own known sends).
- [x] **New wire types** (`node/types.rs`, all `#[serde(default)]`): `HavenMessage::DmSiblingSyncRequest
      { per_convo_since: Vec<(friend_master, latest_ts)> }` + `MessageEnvelope::DmSiblingSyncBatch
      { convo, messages: Vec<DmSyncItem>, has_more }`. Dedicated batch (not a flag on `DmSyncBatch`) keeps the
      hot friend path untouched + isolates the sibling sig-verify branch. Added `DmSiblingSyncBatch` to the
      "DM-only envelopes never arrive via MLS" exhaustive guard.
- [x] **Helper factored** (`swarm.rs` `build_dm_sync_items`): the `DmSyncItem` packing (reactions + file-meta
      batch joins) extracted from the friend `DmSyncRequest` handler, reused by both responders.
- [x] **Responder** (`swarm.rs` `DmSiblingSyncRequest`): `same_identity(peer_str, local)` guard (a FRIEND must
      never pull our whole DB), enumerate `get_dm_peer_ids()`, serve one `DmSiblingSyncBatch` per convo from
      the requester's per-convo high-water (omitted convo → from 0) via `send_encrypted_message` (Olm).
- [x] **Requester** (`swarm.rs` `DmSiblingSyncBatch`): file under `convo` (the FRIEND master — NOT
      `resolve(sender)`, which is our own master since the sender is our sibling); preserve `is_mine`
      direction; verify the ORIGINAL sig context per direction (`mine=true` → sender=our master/recipient=convo;
      `mine=false` → swapped — sigs never involve device ids, so the original sig validates intact); apply
      edits/deletes/reactions/file-meta keyed on convo; emit `MessageReceived { is_own: msg.mine }` (reuses the
      Step 3 `is_own` field) for fresh inserts + `DmMessageEdited/Deleted/FileHeaderReceived`; paginate by
      re-requesting that one convo. NO FFI/codegen (internal variants + existing events).
- [x] **Trigger fires from BOTH sibling-detection paths** (the bug that made it silently never run): (1) the
      `swarm.rs` inbox-proof block (`room == inbox:{master}`) AND (2) `crypto_handler::ingest_sibling_device_list`
      (fired by a ProfileUpdate carrying a device list). A sibling can be detected via EITHER; the first build
      only had the trigger in (1), so a session that detected via (2) logged `Sharing N friends with sibling`
      (from crypto_handler) but NEVER the DM-backfill request → looked like the log line "wasn't emitting."
      Root cause was code reachability, NOT the `hollow_log!` macro. Both paths now send `DmSiblingSyncRequest`
      with our per-convo high-water marks. Redundant double-fire is idempotent (message_id dedup).
- [x] **Two UI/UX fixes found in the first live test:**
      (1) **PUSH on sibling self-echo** (`message_ops::send_dm_to_device` gained `is_sibling: bool`): the DM
      fan-out mirrors every send to our own siblings; when a sibling was offline the offline branch did the
      "encrypt to DM room (push trigger)" room-send → relay fired an FCM push → the sibling phone buzzed for OUR
      OWN outgoing message. Now an offline SIBLING target only QUEUES silently (delivered on reconnect + Step 5
      backfill); only genuine recipient devices trigger pushes.
      (2) **Out-of-order render** (`chat_provider`/`channel_chat_provider` `_addMessage`): was a plain append; a
      backfilled message replaying an OLDER timestamp landed at the END of the in-memory list → wrong position.
      `_addMessage` now keeps the list timestamp-ordered (O(1) append for the newest-message common case;
      walk-back insert only for out-of-order arrivals).
- [x] **TEST: ✅ LIVE-VERIFIED 2026-06-17 (Vitalik, Pixel↔VM↔AL).** Backfill "literally almost instant."
      Logs show both detection paths firing, bidirectional serve, `0 new messages` on the dedup re-pull (correct),
      siblings converge. Step 5 DONE.
- [x] **PEER-FALLBACK (the second half of the step title) — built 2026-06-18, awaiting live test.** Step 5 only
      shipped the **device-first** half (sibling→sibling). The **peer-fallback** half was missing: when your other
      device sent DMs to a friend while you were offline, then that device goes OFFLINE before you come online, your
      OWN sends (stored on the friend as `is_mine=0`) were STRANDED — the sibling can't serve them (it's offline) and
      the friend `DmSyncRequest` responder filters `is_mine=1` only ("I never re-serve messages you sent me"). Scenario
      that exposed it (Vitalik): VM(subdevice)↔AL(outsider friend) exchange 6 msgs while Pixel(master) offline; Pixel
      online + VM offline → Pixel got only AL's 3, not its own 3 VM→AL sends. **Fix (4 DM touches, all internal wire —
      NO FFI/codegen):** (1) new `#[serde(default)] both_directions: bool` on `HavenMessage::DmSyncRequest`; (2) the
      `DmSyncRequest` responder serves `get_dm_messages_for_sibling` (both directions, the Step-5 fn) instead of
      `get_dm_messages_since` when the flag is set; (3) the `DmSyncBatch` receiver honors `msg.mine` (insert side +
      direction-aware sig-verify context mirrored from the sibling receiver — `mine=true`→signer=our master, else
      signer=convo); (4) all THREE DM-sync trigger sites (PeerJoined, RoomMembers, **pagination follow-up**) set the
      flag + use `get_latest_dm_timestamp_any` (both-way high-water) **iff WE are multi-device**
      (`!resolver::devices_for(local_master).is_empty()` — race-free, the resolver is warmed from `device_links` +
      `seed_self` BEFORE the event loop). Decision lives on the REQUESTER (always knows it's multi-device) not the
      responder (may not have ingested the requester's device list — cold-start race). **Single-device + normal
      single-device friends stay byte-for-byte** (flag never set → cheap one-directional path). 2 new storage unit
      tests lock the branch (`sibling_serve_returns_both_directions_unlike_friend_serve`,
      `latest_any_spans_both_directions`); 337 lib tests pass, clippy clean.
- [x] **FIRST LIVE TEST (2026-06-18) FOUND THE `mine`-INVERSION BUG → fixed.** Recovery WORKED but every
      backfilled message rendered on the WRONG SIDE and the conversation order looked inverted (AL appeared to
      have written first when VM actually did), plus a "Sig verify FAILED" flood on all items. **Root cause:**
      `DmSyncItem.mine` is **RESPONDER-relative** — it's `is_mine` as stored in the SENDER's (AL's) DB. A FRIEND's
      perspective is the OPPOSITE of ours: AL's `is_mine=1` (AL sent) = our `is_mine=false` (we received); AL's
      `is_mine=0` (AL received from us) = our `is_mine=true` (WE sent). The receiver inserted `msg.mine` verbatim,
      so our own VM→AL sends were stored as RECEIVED (and the sig context picked the wrong signer/recipient →
      verify failed on every item). The OLD one-directional path accidentally worked because it hardcoded the
      insert to `false` and AL only ever served its own sends (implicitly `!mine` for that single case). **Fix
      (`swarm.rs` DmSyncBatch receiver):** compute an effective `is_mine = if from_sibling { msg.mine } else
      { !msg.mine }` (invert on the friend path, keep as-is from a same_identity sibling — siblings share is_mine
      meaning) and use it for BOTH the insert AND the sig-verify direction context. Proven from the logs (Pixel got
      6 items: earliest 3 `mine=false`/latest 3 `mine=true`, but VM wrote the earliest — so they had to flip).
      Confirmed shared (VM↔Pixel both invert). Diag log gained `wire_mine=` vs `is_mine=`. cargo check + clippy
      clean; 338 lib tests pass.
- [x] **LIVE-VERIFIED 2026-06-18 (Pixel↔VM↔AL).** Fresh logs after the inversion fix: AL serves both directions
      (`both_directions=true`); Pixel's diag shows correct flip (`wire_mine=true→is_mine=false`,
      `wire_mine=false→is_mine=true`); **ZERO post-fix sig-verify failures** (all the FAILED lines are from
      pre-fix builds). Pixel recovers its own stranded VM→AL sends on the CORRECT sides + order. DM peer-fallback
      DONE.

**KNOWN LIMITATION → tracked in Step 9 (multi-device push):** when the phone is FULLY QUIT, the Tier 2
background-fetch DM push degrades to the generic banner (the message itself still arrives in full via live
delivery + Step 5 backfill — only the rich preview degrades). Not fixed here; rolled into the end-of-epic
push step. See **Step 9**.

### Step 5.1 / 5.2 — Multi-device targeting sweep (files, calls, sync sig)  ✅ LIVE-VERIFIED 2026-06-17
*Follow-up to Step 5: the live tests surfaced that the DM message/file SEND path got multi-device fan-out in
Step 3, but EVERY OTHER targeted-send path still addressed the bare MASTER id — which no socket authenticates
as, so the send was silently dropped. The unifying lesson: **the relay reports DEVICE ids; the UI keys on the
MASTER; an outbound targeted send must resolve master→device, and an inbound attribution must collapse
device→master.** See [[feedback_multidevice_targeting_sweep]].*

**Efficiency + completeness (Step 5.1):**
- [x] **Trigger cooldown** (`crypto_handler::request_sibling_dm_backfill`, 15s per-sibling): the two
      detection paths + reconnects fired the full-conversation `DmSiblingSyncRequest` 2-4× per detect. One
      shared throttled helper (both sites call it) collapses the burst. Logs went from 4 requests → 1.
- [x] **Exclusive-boundary serve** (`get_dm_messages_for_sibling`): `timestamp > since` (was `>=`) so the
      high-water-mark message isn't re-sent every reconnect; `updated_at >= since` still catches edits.
- [x] **Sibling-sourced file fetch** (`event_provider._onlineSiblingDevices` + `requestMissingDmFilesOnOpen`,
      wired into desktop `chat_pane` + mobile `mobile_chat_route` thread-open): missing file bytes are
      re-requested from the friend AND our own online sibling devices, so an image syncs even when the friend
      is offline + retries when you OPEN the thread (not only after a message-bearing `DmSyncCompleted`).

**The big file-transfer fix chain (all DM-file decrypt symptoms — "stuck loading 16.2/16.2KB forever",
4.5k-line loop, "only works after restart"):**
- [x] **File-request resolves master→ONE device** (`file_handler::handle_request_file` via
      `crypto_handler::online_devices_for`): the FileRequest was sent to the bare master (`JJU9`) → dropped →
      bytes never arrived. NOT a fan-out: a DM file is fanned out at send time to several devices, so requesting
      from all → multiple streams each with a DIFFERENT random AES key → only one header's key kept → decrypt
      fail loop. Request from exactly one online device.
- [x] **Retry counter preserved across re-registered FileHeader** (`swarm.rs` FileHeader handler): was
      hardcoded `retry_count: 0`, so a re-request's new header reset it → the bounded "3 retries then give up"
      NEVER fired → infinite loop (always "attempt 1/3"). Carry the count forward.
- [x] **THE ROOT CAUSE — header/stream ordering off-by-one** (`file_handler::handle_completed_stream`): the
      encrypted bytes (fast WebRTC P2P) routinely BEAT the FileHeader (slower Olm/relay) — logs show
      `FileHeader received` the line AFTER `decrypt failed`. The bytes got matched to a STALE pending stream
      (prior request's key) while their OWN header was still in flight. The old code deleted the bytes +
      immediately re-requested → spawned ANOTHER crossed header/stream pair → endless loop, "fixed" only by a
      restart (serializes one clean pair). **Fix:** on decrypt failure, PRESERVE the bytes as an early-arrival
      and DO NOT immediately re-request — the in-flight header lands a moment later and its early-arrival path
      reprocesses those exact bytes against the CORRECT key. Bounded safety re-request covers a genuinely-lost
      header. **Files now decrypt on first arrival, no restart.**
- [x] **DM file context_id keyed by MASTER** (3 receive sites: live FileHeader, friend `DmSyncBatch`, sibling
      backfill — `swarm.rs`): used the raw sender DEVICE id for the file's `context_id`/`channel_id` while the
      MESSAGE row is under the master → `_reloadChatForFile` reloaded the wrong/empty thread → `[file:<id>]`
      placeholder until a manual tab-switch. Resolve to master so file + message land under the same key.

**Signature / attribution fixes (the device-vs-master class):**
- [x] **DmSyncRequest device→master** (`swarm.rs` responder + both requester send sites): the friend sync
      lookup keyed on the requester's raw DEVICE id, but DM rows are under the master → `Sending 0` for a
      multi-device requester → the whole catch-up sync silently delivered nothing (text limped through on live
      fan-out; a file whose live transfer failed was lost). Resolve to master.
- [x] **DmSyncBatch sig-verify device→master** (`swarm.rs` receiver): verified signatures against the sender
      DEVICE id, but the sig was made by the MASTER key → EVERY synced message from a multi-device friend
      logged `Sig verify FAILED` (the flood Vitalik spotted). Verify against `convo_peer` (the master).
- [x] **Self-echo DM sig-verify context** (`swarm.rs` live DirectMessage): a sibling echoing OUR OWN sent
      message was verified with recipient=our-master/signer=friend, but we signed it recipient=friend/signer=us
      → cosmetic FAIL on every self-echo. Swap context/signer when `is_own_device`.
- [x] **Unread pill over-count** (`swarm.rs` sibling `DmSiblingSyncBatch`): removed the per-message
      `MessageReceived` emit — that event drives `onDmMessage` which INCREMENTS unread, so replaying a
      conversation's history inflated the Home "Recent" + friends-bar pills. The terminal `DmSyncCompleted` →
      Dart `loadHistory` + `recomputeDmUnread` (counts from the DB against the seen-pointer, idempotent) shows
      the messages AND computes unread correctly — mirrors the friend `DmSyncBatch` path.

**Calls / WebRTC signaling (Step 5.2):**
- [x] **Targeted call + WebRTC signaling resolve master→device** (`voice_handler::pick_online_device` for
      `handle_call_send_signal` + `handle_webrtc_send_signal`): a call/data-channel signal addressed to the
      friend's master was dropped → call never rang, data channel never formed. Pick ONE online device
      (deterministic lowest id) — NOT a fan-out (would ring every device / glare on the `conn_id`). **CRITICAL:**
      if `peer_id` is ALREADY a live device id, use it UNCHANGED — so an ANSWER/ICE flows back to the EXACT
      device that sent the offer (the master→device pick only kicks in for the outbound invite).
- [x] **Incoming call attribution device→master** (`event_provider` `NetworkEvent_CallSignal`): the receiver
      keyed call state on the caller's DEVICE id, but every UI `call.peerId == widget.peerId` check compares
      against the DM MASTER key → call showed under a "different DM" + the screen-share control gated OFF
      (`isCallWithThisPeer` false). Resolve to master at the single event boundary → all downstream
      comparisons (chat_pane ×3, mobile_chat_route, active_call_bar, pills) match. **The wrong-DM pill AND
      screen-share-disabled were the SAME bug.**
- [x] **TEST: ✅ ALL LIVE-VERIFIED 2026-06-17 (Vitalik, AL↔VM, both call directions).** Files transfer
      instantly over the WebRTC data channel; calls ring + connect + show under the correct DM on both sides;
      screen share enables on the receiver; no sig-verify flood; unread pills correct. The whole DM/file/call
      multi-device surface works.

### Step 6 — MLS per-device leaves  ✅ code-complete (pending real-device test)  ⚠ hardest slice
*Goal: server messages reach all your devices. Built 2026-06-17; 325 lib tests pass (incl. new multi-leaf
removal/SFrame/canonicalize tests), clippy clean. Awaiting two-device live test.*

**LOCKED DECISIONS (this session, both Vitalik-picked):**
- **MLS credential = the BARE `device_peer_id`** (NOT the `peer_id:device_id` composite floated below —
  the device id is already globally unique, so the composite buys nothing). Each device's own `MlsManager`
  seeds its credential with its device id → N devices = N distinct-credential leaves naturally.
- **CRDT `ServerState.members` key = MASTER** for every member (owner + joiners). The investigation found
  membership was already SPLIT-BRAIN (owner master-keyed, joiners device-keyed post-rotation); canonicalizing
  to master fixes that latent bug at the root. **One human = one member entry; N leaves live only in the MLS
  group.** The member↔leaf bridge is the resolver.
- **Migration = in-place, no re-key.** Existing persisted MLS identities keep their old (master) credential
  via `from_persisted`; only NEW identities (fresh installs / linked devices) seed with the device id. Live
  groups are never re-keyed.

**THE SPINE (one invariant):** `state.members` is master-keyed; `mls.group_members()` returns device ids;
every MLS↔CRDT comparison bridges through `resolver::resolve()`/`same_identity()`, and every targeted SEND to
a member fans master→online devices (the master has no socket — `send_raw_to_identity`).

**What landed:**
- [x] **Credential = device id** — `MlsManager::new(&device_peer_id)` (`swarm.rs:343`); `from_persisted`
      untouched (no-rekey). Single-device with no siblings stays self-consistent (`resolve(x)==x`).
- [x] **Identity-tolerant removal** (`mls_manager.rs`): new `remove_identity_leaves(server_id, &[ids])`
      removes EVERY leaf whose credential is in the id set; `remove_member`/`remove_members_batch` delegate
      to it. Kick/ban/leave pass `{master} ∪ devices_for(master)` so all of a human's leaves drop in one
      commit. 2 new unit tests.
- [x] **Coordinator election collapses device→master** (`crypto_handler.rs` `elect_coordinator`/
      `elect_vault_coordinator`/`is_*` now return the lowest online MASTER; sender-exclusion via
      `same_identity`; vault = 2nd master). Inline elections in the MlsKeyPackage handler + 3 recovery paths
      all route through it. New device-collapse unit test.
- [x] **CRDT member key → master** (`swarm.rs` ServerJoinRequest resolves joiner device→master for
      `MemberAdded`/`TwitchUsernameChanged`/`MemberJoined`) + `ServerState::canonicalize_members(resolve)`
      (folds legacy device-keyed members/roles/nicknames/twitch/pledges/bans/labels into the master, merging
      roles by priority) called after state load + snapshot adopt + sync-merge. 3 new unit tests.
- [x] **MlsKeyPackage gate/sweep/re-add identity-aware** (`swarm.rs:7588+`): gate accepts a SIBLING of an
      existing member (`same_identity`); stale-sweep is identity-based; sender-already-in-group re-add removes
      only the exact sender device (sibling-safe).
- [x] **3 recovery paths + decrypt-sender resolve** (`swarm.rs`): PeerJoined per-device leaf check (a sibling
      with no leaf triggers `MlsKeyPackageRequest`); RoomMembers + unknown-group + post-join + decrypt-fail
      recoveries elect a master coordinator and send to its DEVICES (`send_raw_to_identity`). Decrypted
      `sender_peer_id` (device credential) is resolved to `sender_master` for ALL attribution + signature
      verification (channel msg/edit/delete/reaction signed by master; kick/server-delete author perms;
      typing) while Olm-reply/file sites keep the device id.
- [x] **Per-device SEND fan-out** — new `crypto_handler::send_raw_to_identity` (fans bytes to every online
      device of a master). All MLS Commit / Welcome-peer / kick-ban-leave CRDT+notification / plaintext
      CRDT-gossip / pledge / Olm-bootstrap broadcasts over master-keyed members now fan per-device (the
      master authenticates as no socket — a bare `send_raw_to_peer(master)` was silently dropped). Commit
      skips are per-DEVICE (a member's already-joined sibling A still gets the Commit when sibling B is added).
- [x] **Re-audited the 8 MLS rules** (`feedback_mls_patterns.md`): rules 5 (rejoin cleanup), 6 (coordinator
      excludes sender), 7 (auto-recovery for any peer) became identity-aware; 3 (decrypt-fail sync) gained the
      sender resolve; 1/2/4/8 unaffected. R1 grep-audit of every `group_members()` consumer done — all are
      resolver-aware or count-only.
- [ ] **Test (Vitalik, two devices of one identity):** both devices in a server → both decrypt channel
      messages (coordinator `MlsKeyPackageRequest`→sibling `MlsKeyPackage`→batch add→Welcome to B, Commit to
      A); epoch + SFrame key identical on both (clear voice); kick/ban removes BOTH leaves (survivors decrypt,
      kicked devices cannot); single-device + existing live groups byte-for-byte unchanged.

**DEFERRED → tracked in Step 9 (multi-device push):** CHANNEL PUSH (0x09 offline fan-out) target-selection
is still master-keyed. The LIVE channel path (MLS room broadcast → both devices in the room decrypt) works
without it; only the offline push preview is affected. Rolled into the end-of-epic push step. See **Step 9**.

### Step 7 — Revocation (the sharp edge)  ✅ LIVE-VERIFIED 2026-06-18 (Pixel↔VM↔AL)
*Goal: a lost/stolen device can be cut off everywhere. Built WITH Step 8 as one unit (2026-06-18).*
*Live test took THREE rounds of fixes after the first build (all in [[feedback_ghost_device_fanout]]):
(1) DM/file fan-out was addressing dead GHOST device ids (stale session, offline) → relay offline-buffer
→ spurious "random peer id" notifications + a stuck mobile unread pill → fixed by filtering the fan-out
to devices CURRENTLY IN A ROOM + resolving fromPeer→master for unread/notif keys; (2) self-nuke never
fired because `handle_revoke_device` EXPLICITLY skipped sending the tombstone to the device being revoked
→ it never learned + kept running as a phantom standalone chat on the friend → fixed by sending the
tombstone TO THE REVOKED DEVICE FIRST + a `resolver::is_revoked` receive-path drop guard; (3) self-nuke
fired but CRASHED before the wipe because the toast used the plain `HollowToast.show(ctx)` form
(`Overlay.of` null-check throw from a navigator-key context) → fixed by stashing the wipe FIRST, toast
best-effort via `overlayState:`. After all three: nuke fires from any online path (revoker direct /
sibling / friend re-broadcast — decentralized, no relay), no phantom chats, no spurious notifications,
pill clears. Confirmed by Vitalik.*
*Locked design: **manual-only** (any device-you-control revokes another; all devices hold the master key,
so there is no "promotion" — a lost-only-device is recovered via the 24-word mnemonic). **Tombstones inside
the signed list**: one `version` + one `sig` govern adds AND removes; a revoked id never re-enters the union.
**Resurrection:** a reinstalled phone gets a FRESH peer_id → links cleanly (old tombstone stays dead); a
falsely-revoked SAME-peer_id device can be un-revoked ONLY by a future higher-version master list
(max-version-wins) — a replayed lower-version list can never un-revoke. Single-device installs byte-for-byte
unchanged (empty `revoked` = no-op).*

- [x] **Tombstones in `SignedDeviceList`** — new `#[serde(default)] revoked: Vec<String>` (`types.rs`). Folded
      into the canonical signing payload (`device_list_signing_payload` gains a `:{sorted_revoked_csv}` segment;
      `build_signed_device_list`/`verify_device_list` cover it; a revoked id is stripped from `devices`).
      `build_local_device_list`/`merge_sibling_device_id` thread `revoked` + never tombstone the running device.
- [x] **Tombstone-aware merge** (`crypto_handler::ingest_device_list` + `ingest_sibling_device_list`):
      max-version-wins revoked set, union MINUS tombstones, sender re-link guard skips a revoked sender, prunes
      the resolver. Returns `IngestOutcome { our_devices_grew, newly_revoked }` so the swarm caller enforces.
- [x] **`resolver::forget`/`forget_many`** (the map was insert-only; without this a revoked device kept
      resolving to its master until restart). 3 unit tests.
- [x] **Enforcement** (`swarm::enforce_device_revocations`, called at BOTH device-list ingest sites — plaintext
      inbox `swarm.rs:~8475` and MLS-envelope `social::handle_envelope_profile_update`→swarm `~7350`): drop the
      Olm session (`olm.remove_session` + `persist_crypto_state` + new `CryptoStore::delete_session` so the DB
      row is erased) AND, where we are the elected coordinator, enqueue the revoked device's SINGLE leaf into
      `pending_mls_removals` (the `mls_batch_timer` issues `remove_members_batch` + `MlsCommit`). Removes ONLY
      that leaf — the device's master stays a valid member (not the kick path's `identity_credential_ids`).
- [x] **`NodeCommand::RevokeDevice` + `handle_revoke_device`** (sync_handler, modeled on `handle_kick_member`):
      self-revoke guard, own-device-only guard (`crypto_handler::revoke_own_device` bumps the list + tombstones +
      re-signs + persists + `resolver::forget`), re-broadcasts the profile so friends converge, then the dispatch
      arm runs `enforce_device_revocations` on the revoking device too. FFI `revoke_device` (`api/network.rs`).
- [x] 5 new crypto-handler unit tests (sign/verify covers revoked, strip-on-build, tamper-fail, sig-differs);
      335 lib tests pass; clippy clean; analyze clean.
- [x] **SELF-NUKE (decentralized, 2026-06-18).** When a device ingests any signed list (sibling OR friend
      re-broadcast) where ITS OWN device id is in a HIGHER-version `revoked` set, Rust emits new
      `NetworkEvent::SelfRevoked` (both ingest paths in `crypto_handler`; sibling path checks the INCOMING
      `list.revoked` BEFORE the "never tombstone self" strip). Dart `event_provider._selfNuke()` mirrors the
      link "go back" flow — `stash_pending_wipe()` + `notifyShutdown` + relaunch → clean Welcome (guarded
      idempotent; toast "This device was removed…"). So a revoked-but-honest device tears itself down instead
      of lingering as a frozen-out zombie. (A stolen/offline device that never reconnects is still contained by
      the crypto cutoff above — self-nuke only fires when it comes online to a peer holding the tombstone.) No
      relay changes (rejected relay-ban — keeps the relay identity-agnostic). Codegen run.
- [ ] **Test (Vitalik, two devices A+B + friend AL):** revoke B from A → A panel drops B, version bumps
      `revoked=[B]`; AL ingests → B removed from devices, Olm session to B dropped, B no longer a DM fan-out
      target, coordinator issues a single-leaf MLS Remove for B only (A/master unaffected, A's channel messages
      keep flowing); B gets `MlsCommit` (can't decrypt new channel traffic) + sees itself revoked (can't re-add
      at equal/lower version); B replays its OLD list → AL rejects the un-revoke. Revoke-while-offline → tombstone
      persists, MLS removal when the coordinator next processes it. Single-device install unchanged.

### Step 8 — Devices panel (Settings)  ✅ LIVE-VERIFIED 2026-06-18
*Goal: honest visibility + management. Scope NOW = devices list + local label + Remove button; DB-health
comparison + manual Sync deferred to a later pass (need new health-query FFI + whole-account sync trigger).*

- [x] **Linked devices list** — `myDevicesProvider` (`device_link_provider.dart`) inverts the resolver mirror
      against the running device's master; per-device online via raw `peersProvider`/`invisiblePeersProvider`
      (NOT collapsed); "This device" marked via new FFI `get_local_device_peer_id`. Desktop `_DevicesSection`
      in `user_settings_dialog.dart` (Security tab, "YOUR DEVICES" above the existing Link/Reset controls) +
      mobile twin `_DevicesSectionMobile` in `mobile_settings_tab.dart`. Each row: shortened id (`12D3…JQcW`),
      online/offline, editable **local** label (new `device_labels` table + `set_device_label`/`get_device_labels`
      FFI + `deviceLabelProvider`, refreshed on `DeviceListUpdated`), "This device" badge.
- [x] **"Remove device" → Step 7 revocation** — `HollowButton.danger` (hidden on the running device) → confirm
      dialog → `revoke_device` FFI.
- [x] **GHOST-DEVICE filter (2026-06-18).** Repeated re-link test cycles legitimately mint a NEW device id each
      time (union-merge accumulates them — first live test showed **13 devices** on Pixel, all real but mostly
      dead). Light fix (chosen over schema+last-seen auto-prune): the panel shows only "active" devices by
      default (online / this device / labeled); offline+unlabeled ghosts fold behind a **"Show all (N offline)"**
      toggle and each is revocable from there (real tombstone). `_DevicesSection`/`_DevicesSectionMobile` are now
      stateful for the toggle. Diagnosed via adb pull of Pixel `hollow_debug.log` — confirmed NOT id-churn-per-
      reconnect and NOT a Step-7 bug; the device-key logic is correct (export omits `identity.device`, import
      mints a fresh stable one). Heavier last-seen auto-prune deferred.
- [ ] Per-conversation DB-health comparison across devices (counts / latest-op timestamps). **DEFERRED.**
- [ ] Manual "Sync" button (drives Step 5 on demand). **DEFERRED.**
- [ ] Cross-device device MODEL string (each device knows only its own; local-label-only for now). **DEFERRED.**
- [ ] True per-device last-seen (only the relay has it today; local approximation for now). **DEFERRED.**
- [ ] **Test (Vitalik):** panel lists both devices with correct online state + "This device" marker; rename a
      device (local label persists); Remove fires the revocation (see Step 7 test); single-device shows only
      "This device" with no Remove button.

### Step 9 — Epic closing point: multi-device push + app-wide test suite  ▢ not started  ⚠ do LAST

#### 9A — Multi-device push notifications
*Goal: make the FCM/APNs + relay-fetch push subsystem multi-device-aware for BOTH DMs and server channels.
Deliberately the FINAL step — push is the most fragile cross-cutting subsystem (FCM/APNs/NSE/App-Group/
Olm-ratchet-slot/MLS-epoch rules), single-device push works today, and every functional path (live delivery
+ backfill) already brings messages in FULL without it. Only the rich push PREVIEW degrades on a fully-quit
phone. Fixing it holistically at the end avoids regressing the single-device common case while the rest of
multi-device churns.*

**What's broken / missing today (both rolled here from Steps 5 & 6):**
- **DM push (fetch mode + background isolate).** When the phone is FULLY QUIT, the Tier 2 background-fetch
  push degrades to the generic "X sent you a message" banner. Cause: the relay-buffered ciphertext is sealed
  to ONE device's Olm ratchet; the background-fetch isolate (a sibling / rotated device id) can't line up
  that ratchet → decrypt fails → generic banner. Message itself is NOT lost (live + Step 5 backfill).
  The fetch isolate also predates the device→master model (`load_existing_identity`, ratchet selection).
- **Channel push (0x09 offline fan-out).** The sender picks OFFLINE-member targets from its CRDT and fires
  one 0x09 per target with a per-target mention flag. With members now MASTER-keyed (Step 6), target
  selection + offline detection must resolve master→device, and the NSE/fetch group-state decrypt must pick
  the right device leaf for the current MLS epoch.

**Scope when we get here:**
- [ ] DM fetch isolate: device→master aware identity load; pick a ratchet/device the buffered ciphertext was
      actually sealed to (or have the SENDER target a deterministic device for the offline buffer), so the
      background fetch can decrypt → rich preview restored on a fully-quit phone.
- [ ] Channel push 0x09: resolve member master→online/offline devices for target selection; per-target
      mention flag still computed sender-side; NSE/`hollow_push_fetch_and_decrypt` picks the correct device
      leaf + tolerates stale-epoch with the content-free fallback.
- [ ] Re-validate the whole push UX (per-peer/per-channel grouping, collapse-ids, App-Group cache, iOS NSE
      footprint) on multi-device — without regressing single-device, which is the common case.
- [ ] **Test:** fully-quit phone (sibling/rotated device) receives a DECRYPTED DM preview AND a decrypted
      "Server • #channel" channel preview; single-device push unchanged; no double-notify across siblings.

**Cross-refs:** `feedback_fcm_image_invisible_bubble.md`, `project_push_notification_implementation.md`,
`project_channel_push_notifications.md`, `project_ios_push_tier_b_disposable_nse.md`,
`feedback_app_group_path_match.md`, `feedback_ios_appgroup_sqlite_wal_crash.md`.

#### 9B — App-wide test suite (the harness we kept deferring)
*Goal: stop shipping regressions that only a human catches. The whole multi-device epic has been
"fix → live test on 3 devices → find a missed master-vs-device site → repeat." Each missed site
(e.g. `swarm.rs:1897` PeerJoined gate, the member-panel offline bug) was a one-line check that a
test would have caught instantly. Build the suite AT THE END so it pins the FINAL behavior, not a
moving target — but build it before declaring the epic done.*

**The three test layers (what we have, what each is for):**
1. **Widget tests — `test/`, run with `flutter test`.** No device, FFI mocked
   (`test/helpers/mock_rust_lib.dart` + `test_app.dart`). Fast (~6s for the whole suite), run on
   every change. Tests **Dart logic + UI in isolation**: given provider values, does the UI/render/
   selection behave? **This is the workhorse — 90% of useful tests live here.** Today: 21 tests
   (`widget/`, `widget_test.dart`, `multi_device_presence_test.dart`).
2. **Integration tests — `integration_test/`, real `RustLib.init()` + real `HollowApp`.** Runs the
   genuine node (SQLCipher, providers, FFI) on a device/emulator. Catches wiring/FFI/end-to-end
   breaks a mock can't. Today: just `integration_test/simple_test.dart` (an "App launches" smoke
   test). Worth a HANDFUL (launch, create-server, send-DM, restart-persists) — not hundreds.
3. **`test_driver/integration_test.dart` — NOT a third kind of test.** A 3-line `integrationDriver()`
   shim that runs the `integration_test/` tests via `flutter drive` (needed for screenshots, physical-
   device CI, perf traces). Test logic always lives in `integration_test/`; this is just the runner.

**The multi-device reality (be honest in scope):** a TRUE two-device test needs two running nodes +
a relay — beyond one in-process `integration_test`. So the split is:
   - **Deterministic logic** (device→master collapse, resolver, `is_member`/`get_role` resolution,
     coordinator election, canonicalize) → unit/widget tests (already started: Rust
     `accessors_resolve_device_to_master_via_hook`, `coordinator_election_collapses_devices_to_master`,
     `remove_identity_leaves_*`, `canonicalize_*`; Dart `multi_device_presence_test.dart`).
   - **Actual two-device mesh** → stays a documented MANUAL live-test checklist (Pixel↔VM↔AL) UNLESS
     we invest in a two-in-process-node harness (a stretch goal — spawn two `spawn_node`s against a
     local relay, assert a channel msg crosses). Decide cost/value when we get here.

**Scope when we build it:**
- [ ] **Rust:** keep growing `#[cfg(test)]` coverage for every cross-cutting invariant — the
      master↔device boundary rules ([[feedback_multidevice_targeting_sweep]]), MLS multi-leaf,
      CRDT merge/dedup, sig payload parity. These are pure + fast; aim them at the bug SHAPES that
      recurred (wrong-id routing, stale-state).
- [ ] **Dart widget:** a multi-device fixture in `test/helpers/` (master + N device peer_ids, a
      stub `deviceLinkProvider`, helpers to push peers online/offline) so any server/DM/friend UI
      can assert "shows one row per person / online via any device / right name" without FFI.
      Convert each past UI regression into a guard test (member panel, user bar, mobile panels,
      typing, chat-header Encrypted, Home network column).
- [ ] **Integration:** flesh out `integration_test/` with the real-node smoke flows (launch,
      create+join server, send/receive DM, channel message, restart-persists, app-lock unlock).
      Run them via `flutter test integration_test/` (headless) and document the `flutter drive`
      path for screenshots/CI.
- [ ] **CI:** wire `flutter test` + `cargo test` into the existing GitHub Actions
      (`project_ci_setup`) as a required gate; integration tests as a separate (manual or nightly)
      job since they need an emulator.
- [ ] **Manual checklist:** write the canonical two-device live-test runbook (the steps Vitalik
      already does by hand) into `reports/` so it's repeatable, not improvised each session.

**Why 9B is bundled with the epic (not skipped):** the suite's first real job is to lock the
multi-device behavior we just built so Step 7 (revocation) and future work can't silently re-break
it. A broader whole-app suite grows from this foundation afterward.

**Cross-refs:** `test/helpers/test_app.dart`, `test/helpers/mock_rust_lib.dart`,
`test/multi_device_presence_test.dart`, `integration_test/simple_test.dart`, `project_ci_setup.md`,
`feedback_use_agents.md` (parallel audit pattern that found the sweep).

#### 9C — Server multi-device UX polish (minor; deferred 2026-06-18)
*The Step 6 server MLS mesh is LIVE and working end-to-end (channel messages + typing + chat grouping all
flow real-time across master+sibling+friend). These are the two small cosmetic/edge quirks left when Vitalik
decided to stop and ship the working state — fix in a focused polish pass, NOT blocking.*

- [ ] **Subdevice sees its OWN identity "typing".** When a sibling device types in a channel, the typing
      event resolves to the shared master, and the OTHER sibling (e.g. master Pixel) displays "you are
      typing" — a self-leak. Added a self-filter in `channel_chat_pane.dart` (exclude `myMaster` from the
      typing names) but Vitalik confirmed Pixel STILL sees itself typing after that — so the filter isn't
      catching this path (likely the typist arrives as a DEVICE id that `identityOf` doesn't collapse to
      `myMaster` because the resolver link for the sibling's exact typing-sender id isn't warm, OR a second
      typing render path. Re-trace: log the raw typist id vs `myMaster` at the display site). Channel-typing
      plaintext-fallback fan-out (`social.rs`, was sending to bare master → dropped) and a `[HOLLOW-TYPING]
      Channel typing send` diag log already landed this session.
- [ ] **First channel message after a fresh device-link relaunch is lost** (the rest arrive fine; a
      tab-switch surfaces it). Same shape as the DM `feedback_dm_online_branch_retry_queue` race — right after
      `import_pending_link` + relaunch, the freshly-minted MLS leaf / Olm sessions are still settling, so the
      very first channel broadcast that lands races the group-join completion. Likely fix: queue/retry the
      first post-link channel message, or have the joiner request an immediate channel sync once its leaf is
      merged. Self-heals on next sync today, so low severity.
- [~] **Sibling↔sibling SERVER-message backfill** (the server analog of Step 5 DM backfill): **likely NO code
      needed — VERIFY BY TEST (2026-06-18).** Unlike DMs, the channel-sync responder (`ChannelSyncRequest` →
      `get_channel_messages_since_per_sender`, `storage/messages.rs`) has **NO `is_mine` filter** and serves ALL
      senders (an unknown sender → all their messages), and the reconnect trigger (`SyncCoordinator::collect_ready`,
      registered on PeerJoined + RoomMembers) already fires a `ChannelSyncRequest` per channel **unconditionally** —
      so a reconnecting device should already recover its OWN channel messages (sent from another device) from any
      present member, even when no sibling overlaps. This is the same "own data stranded" class as the DM
      peer-fallback above, but the server rails already cover it. **Test:** offline/online the same way as the DM
      scenario for a server channel; if Pixel recovers its own VM-sent channel messages from AL/coordinator after
      reconnect with VM offline, tick this. Only add code if the test shows a gap (e.g. the coordinator-side
      post-batch-add sync at swarm.rs:~3090 not covering a plain reconnect).

- [ ] Overall, proper syncing on kick/bans etc., make the master-subdevice relationship be fully synced between each ohter in terms of actions and features.
- [ ] Fix "sync-import" when using 24-wod phrase on Welcome dialog (either remove or change to reuse the same pipeline as Link Device)
- [ ] Fill the "Youre devices" list on the newly synced device.

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
