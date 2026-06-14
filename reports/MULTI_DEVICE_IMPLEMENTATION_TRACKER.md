# Multi-Device Identity & Sync — Implementation Tracker

**Status:** In progress. Foundation not yet started; one quick-win bug fix landed.
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

### Step 1 — Device identity foundation  ◐ in progress
*Goal: each install has a distinct per-device peer_id, plus a master-signed device list. Fixes self-request
and mutual crypto-corruption for good. No fan-out yet.*
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
- [ ] Master identity pubkey retained as the cross-device link (the "who you are") — exposed via device list.
- [ ] Publish (attach to both ProfileUpdate variants) + ingest (verify + persist + resolver update). [#6]
- [ ] Key routing: device key → WS auth/signaling/local_peer; master key → message signing/device-list sig.
- [ ] Wire resolver into ALL self/attribution sites (dm_room_code ×8, self-checks, is_mine, verify-sig R1).
- [ ] Dart attribution via `identityFor()` + `device_link_provider`.
- [ ] **Test (Vitalik, main + VM):** same mnemonic on two devices → *distinct* peer_ids, both connect to
      the relay simultaneously without overwriting; no "self friend request"; no crypto corruption; existing
      single-device install unchanged (migration keystone: device_peer_id == legacy peer_id).

### Step 2 — Device list propagation (profile-attached)  ▢ not started
*Goal: friends learn your device list in a tamper-proof way.*

- [ ] Attach the signed device list to the existing profile sync (`ProfileUpdated` flow, `social.rs`).
- [ ] Clients accept a device list only if `version` ≥ highest seen for that identity (replay protection).
- [ ] Friend UI collapses multiple device peer_ids of one identity into one person (fixes the cosmetic
      "two online dots for you" from fact #10).
- [ ] **Test:** add/remove a device → friends' clients see the updated list; old (lower-version) lists are
      rejected.

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
