# Multi-Device Identity & Sync — Design Plan

**Status:** Design only. Not scheduled for implementation yet (deferred — other DM/file fixes come first).
**Authored:** 2026-06-09 (session design discussion).
**Owner:** Vitalik (architect).
**Referenced from:** `HOLLOW_PLAN.md` Phase 6 — "proper syncing between identities" checkbox.

---

## 1. The Problem

The 24-word mnemonic **is the identity** (the master Ed25519 keypair). It is **not the data**. Importing the
mnemonic onto a new device correctly reconstructs *who you are* (same identity, same signing key) but yields an
**empty database** — no messages, no friends materialized, no server membership. There is no central server to
re-hydrate from (full decentralization: data is local and distributed between peers).

Concrete symptoms today:

- A fresh mobile import of an established desktop identity is empty → "full on desktop, empty on mobile."
- Because both installs are literally the same identity, a friend request sent from the empty mobile device
  arrives at the desktop and is rendered as **"your own friend sent you a friend request"** — the desktop has no
  notion that the request originated from *your own other device*.
- Two installs of the same identity both advance crypto state (Olm ratchets / MLS leaves) independently, which
  corrupts shared session state if they share one peer-facing key.

### Two distinct sub-problems (do not conflate)

- **Problem A — Identity vs. Data.** The keypair has never contained history. Getting the *data* to a new device
  is a transfer problem, not an identity problem.
- **Problem B — Two live devices under one identity.** Even after data is copied, two devices that are "the same
  person" connecting simultaneously must not corrupt each other's crypto sessions, and friends must recognize
  them as one person across multiple devices.

These have **different solutions**. The plan below addresses both.

---

## 2. Chosen Model — Signal-style (locked)

We are **not** Discord/Telegram (server is source of truth, devices are dumb terminals). We are closest to
**Signal/Matrix**: one identity, multiple device sessions, sender-side fan-out, history transferred once at link
time, and ongoing gaps reconciled via the same peer-sync machinery we already have.

> **Key principle:** We do **not** build a new "merge two divergent databases forever" engine. A device is just a
> peer that happens to share your identity. "Syncing my two devices" reduces to "two peers exchanging signed ops
> with message-id dedup" — machinery Hollow already has. We add **device identity**, not a new sync engine.

### Two layers of "who you are"

| Layer | What it is | Shared across devices? | Drives |
|---|---|---|---|
| **Identity** (master Ed25519, from mnemonic) | "This is Vitalik." Name, avatar, friend list, reputation. The peer-facing identity friends' UIs show. | **Yes** — same on every device | Display, friendships, profile, ownership/signatures of content |
| **Device session key** (per-device Ed25519, generated once) | "This is Vitalik's *phone*." | **No** — each device generates its own | One Olm ratchet / one MLS leaf per device |

A friend's client model after this change:

> *"Vitalik (identity M) is reachable via devices {M-desktop, M-phone}. I hold a separate Olm session with each.
> When I DM Vitalik, I encrypt once per device session. His UI shows one conversation; under the hood it's two
> ratchets."*

This is the only model that allows **both devices to be online simultaneously** (Vitalik's explicit requirement).
The fan-out cost is trivial (N = 2–3 devices).

### Decisions locked in this session

1. **Sync philosophy:** Signal-style (one identity, per-device sub-sessions, forward + one-time snapshot + backfill).
2. **First slice:** Full design doc only (this file). No code yet.
3. **QR direction:** **Desktop displays the QR, phone scans it.** (PCs have no camera; phones do. Matches WhatsApp
   Web / Signal desktop / Telegram.)
4. **Crypto identity:** Same mnemonic/identity for display + friendships, **per-device Olm/MLS sub-sessions** so both
   devices can be live at once without ratchet corruption.
5. **Device list propagation:** **Profile-attached** — the signed device list rides on the existing profile sync.
6. **Backfill scope:** **Device + peer fallback** — your other device first, conversation peer (signature-verified)
   as fallback. Reuses existing signed-op + message-id-dedup sync.
7. **Sync Health panel** in Settings — visible DB health across devices + manual Sync button + device management
   (incl. revocation). Honest visibility over fake seamlessness.

---

## 3. Device Linking (QR + standalone transfer)

**Direction:** Desktop (existing device, has the data) **shows** a QR. Phone (new device, empty) **scans** it.

**Why no Olm between your own devices:** Olm is a session between two *different* identities and requires a key
exchange. But two devices that share the mnemonic **already share a secret** — there is no need for a key exchange
to move data between them. So the link-time transfer uses **standalone symmetric encryption** (AES-256-GCM), not
Olm, not a ratchet.

### Link flow

1. **Desktop** generates a one-time, short-lived **transfer key** (random AES-256 key) and renders a QR containing:
   - the transfer key,
   - desktop routing info (peer_id / relay rendezvous code for this link session),
   - a short expiry / nonce.
2. **Phone** scans the QR → derives the same transfer key + learns where to reach the desktop.
3. Phone connects to the relay and signals readiness on the link rendezvous.
4. **Desktop** encrypts a **snapshot bundle** with the transfer key and streams it **through the relay** (dumb pipe;
   no new infra). Bundle contents:
   - **Master identity** (so the phone holds the master key — see §3.1 trade-off note),
   - **DB snapshot** (messages, friends, server membership, profiles) — reuse `archive/exporter.rs` machinery,
   - **Friend list + each friend's device info** (so the phone knows whom to establish sessions with).
5. Phone decrypts, loads the snapshot, then **generates its own device key** and announces it (master-signed) on its
   profile (§4). Friends learn "Vitalik has a new device" and begin including it in fan-out.
6. Phone establishes **fresh** Olm/MLS sessions with each friend (new sessions, not copied).

### 3.1 Trade-off note — master key on every device

Putting the master key on the phone (via the snapshot) means every device can authorize/revoke other devices and
sign as the master. This is simpler (no separate "device certificate signed by master, master stays put" ceremony)
and matches the user's "share the key like that" intent. The cost: larger attack surface per device. Mitigation:
the master key is protected at rest by the existing identity-protection layer (OS keychain / password — see
`project_identity_protection_v2.md`), and revocation (§6) limits blast radius of a compromised device.

> **Open sub-decision (defer to implementation):** whether to ship the alternate "master stays on the original
> device, signs a device cert" model later for higher-security users. Not required for v1.

### Transfer size / reliability

- The snapshot can be large (full message history + avatars). Use the existing chunked-transfer path. The relay
  already carries large payloads (`maxPayloadLength` = 64 MB). Consider chunking + resume for very large DBs.
- The transfer key is one-time and expires; a fresh QR is generated per link attempt.

---

## 4. Device List (profile-attached, signed)

Friends must learn, in a tamper-proof way, which devices belong to an identity.

- The **device list** = `{ identity = master pubkey, devices = [device_pubkey...], version = N, signature }`,
  **signed by the master key**.
- It **rides on the existing profile** data and propagates via the same profile fetch + `ProfileUpdated` flow
  (reuses existing plumbing; no new gossip system).
- **Monotonic `version` counter**, signed by the master, so an attacker cannot replay an *old* device list that
  still contains a revoked device (classic device-list replay attack). Clients accept a device list only if its
  `version` ≥ the highest they've seen for that identity.
- When a device is added/removed, the master bumps `version`, re-signs, and the new list propagates on next profile
  sync.

### "Is this peer me?" checks

Every friend-request / profile / typing-indicator / message path must learn the **identity-vs-device** distinction:

- A message/request from `device_pubkey` resolves to `identity = master`. If that identity is **your own**, render
  it as your own device, **not** a stranger (fixes the "your own friend friend-requested you" bug).
- If it's a friend's identity, attribute to that friend regardless of which of their devices sent it.

---

## 5. Messaging — fan-out + backfill

### 5.1 New messages — sender-side fan-out

Every send that encrypts to a peer must encrypt to **each of that peer's devices**:

- **Olm DMs:** encrypt N copies, one per device Olm session (Matrix-style). N is small (2–3).
- **MLS servers:** each device is its **own leaf** in the MLS group. A new device joining a server = a Remove/Add
  driven by the MLS coordinator (`is_mls_coordinator()`), exactly like any new member. Your own desktop will
  observe "a new device of mine joined." Group size grows by device count; MLS supports this natively.

Touch points (implementation, later): `message_ops.rs`, `crypto_handler.rs`, Olm session management, MLS
coordinator/add-leaf logic, and all "is this peer me?" checks (§4).

### 5.2 Backfill — the offline gap

**Scenario:** Device #1 sends 10 messages to Bob while Device #2 (phone) is offline. Phone comes online and must
end up with those 10.

There are exactly two sources, and **device + peer fallback** uses both:

1. **Your other device (#1)** — primary. When #2 comes online and #1 is reachable, #1 replays the gap. Common case
   (laptop usually on).
2. **The conversation peer (Bob)** — fallback. Bob received all 10; they are **Ed25519-signed by your master**, so
   the phone can verify "yes, I really sent these" — no trust hole. Used when #1 is unreachable but Bob is online.

**Honest limitation (inherent to no-central-storage):** if *all* sources are offline, the messages are unreachable
until one returns. This is the definition of "no servers," not a fixable flaw. Discord avoids it only by being the
always-on third copy — which Hollow deliberately removed.

**Mechanism is not new:** this is the same signed-op + **message-id dedup** sync already used between any two peers
(see `feedback_sync_patterns.md`, `feedback_ui_dedup_by_message_id.md`). A device is just a peer sharing your
identity. Double-delivery from both #1 and Bob is harmless because of message-id dedup.

---

## 6. Revocation (the sharp edge)

This is the one area where a mistake becomes a **security hole**, so it is specified explicitly.

**Scenario:** phone lost/stolen. Its device key still has live Olm/MLS sessions with all friends. Whoever holds the
phone can read incoming DMs until the device key is removed from every friend's device list.

Mechanism:

1. **Master-signed revocation**: `{ revoke device_pubkey, effective_at = T, version = N+1, signature }` — propagates
   via the same profile channel as the device list, with a bumped monotonic `version`.
2. On receipt, friends:
   - **Drop the Olm session** to the revoked device,
   - **Remove its MLS leaf** from shared groups (MLS Remove proposal, driven by the coordinator).
3. **Monotonic version** prevents replay of an older list that still includes the revoked device.

Revocation UI lives in the **Sync Health / Devices panel** (§7): list your devices → "Remove device" → triggers the
master-signed revocation.

---

## 7. Sync Health Panel (Settings)

Not just nice UX — **load-bearing** for a decentralized system. Sync *will* sometimes be incomplete; the principled
answer is to surface the truth and give the user a manual lever, not to fake seamlessness (the opposite of
Viber/Google-Drive "trust us, it's in the cloud").

Contents:

- **Linked devices list:** each device, label, last-seen, online/offline.
- **DB health comparison across devices:** per-conversation message counts and/or latest-op timestamps, so the user
  can see at a glance whether devices agree. Health indicators (in-sync / behind / can't-reach).
- **Manual "Sync" button:** pull the latest from whichever device (or peer) has more — drives the §5.2 backfill on
  demand when automatic sync didn't happen or was incomplete.
- **Device management:** rename a device, and **"Remove device"** → triggers revocation (§6). This is why the panel
  earns its keep twice (health + device management).

---

## 8. Scope / Cost (honest accounting)

This is the **Signal architecture**. It is correct, it is the only thing that gives true simultaneous multi-device,
and it is a **multi-week epic**, not a weekend. Major work items:

1. **Per-device key generation + identity/device split** across the codebase.
2. **Device list** data structure (signed, monotonic-versioned) + profile-attached propagation + replay protection.
3. **Sender-side fan-out** at every encrypt-to-peer site (Olm) — many call sites.
4. **MLS per-device leaves** + coordinator add/remove logic + "is this peer me?" awareness.
5. **"Is this peer me?" checks** across friend-request / profile / typing / message paths (fixes the self-request bug).
6. **QR link flow** (desktop shows / phone scans) + one-time symmetric transfer key + standalone-encrypted snapshot
   transfer through the relay (reuse `archive/exporter.rs` + chunked transfer).
7. **Backfill** (device-first, peer-fallback) wired onto existing signed-op + message-id-dedup sync.
8. **Revocation** (master-signed, MLS Remove, Olm session drop, replay protection).
9. **Sync Health / Devices panel** UI.

### Suggested implementation sequencing (when picked up)

1. Device key + identity/device split + device list (signed, versioned) — foundation; also fixes the self-request bug.
2. Sender-side Olm/MLS fan-out — new messages reach all devices.
3. QR link + standalone snapshot transfer — new device feels full.
4. Backfill (device + peer fallback) — closes the offline gap.
5. Revocation — security completeness.
6. Sync Health / Devices panel — visibility + management.

---

## 9. What we explicitly rejected and why

- **Full mirror sync (byte-identical forever):** fights the crypto, high bandwidth, perpetual conflict resolution.
  Rejected.
- **Identity-only, no data sync:** leaves the "empty mobile" UX problem unsolved. Rejected.
- **Single active device at a time (shared ratchet, handoff):** simpler but no true simultaneous use. Rejected in
  favor of per-device sub-sessions (user wants both devices live).
- **Olm session between your own devices for transfer:** unnecessary — shared mnemonic already means a shared
  secret; standalone symmetric encryption is simpler and correct.
- **Sharing one websocket / one crypto session across devices:** corrupts stateful ratchets. Rejected.

---

## 10. Cross-references

- `HOLLOW_PLAN.md` Phase 6 — "proper syncing between identities" (links here).
- `project_identity_protection_v2.md` — at-rest protection of the master key (relevant to §3.1).
- `feedback_mls_patterns.md` — MLS correctness rules (coordinator election, add/remove, plaintext sync fallback).
- `feedback_sync_patterns.md`, `feedback_ui_dedup_by_message_id.md` — the signed-op + message-id-dedup sync that
  backfill (§5.2) reuses.
- `archive/exporter.rs`, `archive/loader.rs` — snapshot export/import machinery reused for link-time transfer.
- `project_push_notification_implementation.md` — relay offline-buffer (potential future durable catch-up store;
  not used in v1 to keep the relay a dumb pipe).
