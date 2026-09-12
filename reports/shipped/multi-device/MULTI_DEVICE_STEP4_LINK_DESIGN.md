# Multi-Device Step 4 — Device Linking & Snapshot Sync — Design

**Status:** Design for review. No code yet. Supersedes the QR-centric framing in
`MULTI_DEVICE_SYNC_PLAN.md` §3 (see §0 below for what changed and why).
**Authored:** 2026-06-15 (design session with Vitalik).
**Tracker:** `reports/MULTI_DEVICE_IMPLEMENTATION_TRACKER.md` — Step 4.
**Companion docs:** `MULTI_DEVICE_SYNC_PLAN.md` (epic design), the tracker (execution state).
**Prereqs (all DONE + live-verified):** Steps 1, 2, 2.5, 3 — per-device identity, presence
collapse, profile sync, sibling friend-list sync, Olm DM fan-out. Commit `bbf91aa`.

---

## 0. What changed vs. the original plan (and why)

The original `MULTI_DEVICE_SYNC_PLAN.md` §3 specified a **QR + one-time AES transfer-key**
ceremony ("desktop shows QR, phone scans, desktop encrypts a snapshot with a fresh key and
streams it"). Three design decisions in this session simplified that substantially:

1. **The mnemonic already IS the pairing channel.** Two installs of one mnemonic are the same
   identity; the resolver already links them as siblings, and today a fresh mnemonic import on
   the VM *already pulls friends + profiles from the master* (Steps 2.5/3, live-verified). So
   pairing does not need a new key-exchange ceremony — **possession of the mnemonic is the
   auth.** Step 4 only needs to extend "pull friends + profiles" → "pull the **full DB
   snapshot**."

2. **QR is dropped entirely.** QR only ever carried a small rendezvous blob; it added a camera
   dependency (`mobile_scanner`), camera-permission handling, and the "nobody connects a camera
   to a PC" awkwardness — for zero security benefit in a decentralized system (we are not
   Steam, where the QR is an instant-login leg of 2FA). Replaced by a **6-char relay code**
   (Steam-email-code style) for users who don't want to re-type 24 words. **No `qr_flutter`, no
   `mobile_scanner`.**

3. **Direction is decoupled from "who has a camera."** The original doc welded "data-holder" to
   "QR-shower." With codes, neither device cares who is the PC or phone. The system **auto-
   detects** which device is populated and pushes the right way (§5).

**Net effect:** Step 4 is materially smaller than the original plan implied. The heavy lifting
(snapshot build/encrypt/import, chunked transfer, real-time progress) already exists in the
codebase; the genuinely new work is the **short-code relay map**, the **full-snapshot pull
trigger**, the **Welcome-dialog redesign**, and the **honest progress/direction UI**.

---

## 1. The setup this serves (Vitalik's real topology)

- **Pixel** = a master identity (has all the data, has a camera, usually online).
- **VM** (VirtualBox on the Windows host) = a **subdevice of Pixel** (empty, a PC, no camera).
- **AL** (Windows host) = its **own separate identity** — not part of this sync.

The sync that must work: **Pixel (master, populated) → VM (new subdevice, empty)**. Critically,
it must **also work reversed** (a populated PC → an empty phone, or any combination), because we
will not hardcode a direction. The original "PC has data, phone scans" assumption was exactly the
trap that breaks the VM case.

---

## 2. Core model — the mnemonic is the identity, the code is a shortcut

### 2.1 Two ways to pair a new device

Both reduce to the **same** end state: the new device holds the master key (so it IS a sibling)
and the two devices meet in the shared `inbox:{master}` room, where Steps 1–3 already exchange
device lists, friends, and presence.

| Method | Flow | Auth |
|---|---|---|
| **A. Mnemonic import** (primary, works today) | New device: Welcome → "Import identity" → type 24 words → identity restored, fresh random device key (Step 1 restore semantics) → joins `inbox:{master}` → sibling-detected. | The 24 words. |
| **B. Short code** (convenience) | Populated device shows a 6-char code (claimed on relay, RAM-only). New device: Welcome → "Link a device" → type code → relay resolves code → new device receives the **master key material** from the populated device over the live relay channel, then proceeds exactly as (A). | The code proves you reached the master's live session; the master **confirms on-screen** before sending key material. |

> **Why B is not "just the mnemonic again":** B avoids re-typing 24 words AND avoids the new
> device ever displaying the mnemonic. It is purely a UX shortcut over A. Underneath, once the new
> device has the master key, **both paths are identical** — same sibling rails, same snapshot
> pull.

### 2.2 The short code = temporary-nickname pattern, reused

The 6-char code is **not new infrastructure.** It clones the existing **temporary-nickname**
mechanism exactly (`feedback_relay_rules.md`, `project_temporary_nicknames.md`):

- **Relay (RAM only):** a `link_code → peer_id` map in `RelayState`, mirror of
  `nickname_to_peer`. Claimed via a `claim_link_code` text message, released on disconnect, TTL-
  swept. **No persistence, no new frame type beyond a text-message verb.**
- **Generation:** 6 chars, unambiguous alphabet (no `0/O`, `1/I/l`), e.g. `A–Z2–9` minus
  confusables. Generated client-side, claimed on the relay; on collision the relay rejects and the
  client regenerates (same as nickname claim).
- **Resolution:** the new device sends `resolve_link_code` → relay replies with the populated
  device's peer_id → the new device opens a direct relay channel to it (same two-step as the
  nickname → friend-request resolution).

**Security note for B:** because the code grants the master key, the code path MUST require the
**populated device to explicitly confirm** ("A new device wants to link — send your identity and
data to it?") before any key material leaves. The code alone is a rendezvous token, not an
authorization; the human tap is the authorization. Code is short-lived (e.g. 5 min TTL) and one-
shot (consumed on successful link).

---

## 3. The snapshot — reuse `export_backup` / `import_backup`

The data payload is the **full DB snapshot**, already implemented in `api/storage.rs`:

- `export_backup(output_path, include_vault, include_files, passphrase)` — builds a zip of
  `identity.key` + `messages.db` (+ optional `vault/`, `files/`), AES-256-GCM, `HOLLOW` magic
  header. **This already contains everything the progress dialog lists:** profiles, friends, DMs,
  server membership + history rows, settings.
- `import_backup(backup_path, passphrase)` — decrypts + extracts into the data dir.

### 3.1 Refactor (small)

Split the in-memory core out so the transfer doesn't round-trip to disk and can use a one-time key
instead of a user passphrase:

- `build_snapshot_bytes(include_vault, include_files) -> Vec<u8>` — the existing zip-build core
  (it already builds in a `Cursor<Vec<u8>>`), returning the **plaintext zip bytes**.
- `import_snapshot_bytes(bytes) -> Result<()>` — the existing extract core, from memory.
- The transfer wraps `build_snapshot_bytes` in AES-256-GCM with a **one-time random key** derived
  for this link session (not a user passphrase — both devices already share the master secret, but
  a fresh per-transfer key keeps the relay a dumb pipe carrying ciphertext). The on-disk passphrase
  backup keeps its existing Argon2id wrapper for the Settings export feature.

### 3.2 Scope toggles (mirror the Settings export dialog)

Per Vitalik: identical to the existing "export identity" options in
`user_settings_dialog.dart` — **DB always; `include_files` and `include_vault` are user
toggles, default off (DB-only).** Downloaded files/avatars re-sync lazily over existing peer
paths afterward if not bundled.

### 3.3 DB handling on the receiver = **replace**

The new device's DB is empty at first launch (or being reset by the link). Per Vitalik: **replace
it wholesale** — "the entire point of syncing is to SYNC the full data from the master to its
subdevice." `import_snapshot_bytes` overwrites `messages.db`. (The both-populated case in §5.3 is
the one exception, handled before the transfer even starts.)

---

## 4. The transfer — reuse `ws_stream_transfer.rs` + real progress

The chunked-binary-over-relay machinery already exists and **already tracks real byte progress**
via an `AtomicU64` in `stream_progress()`. Add one variant:

- New `StreamKind::LinkSnapshot` in `ws_stream_transfer.rs` (alongside `File`/`Shard`/
  `ShareChunk`). Same `[type][id:64][size:8][data...]` wire format, same 256 KB chunks, same
  reassemble-to-temp-file, same progress counter.
- Sender: `build_snapshot_bytes` → AES-GCM encrypt → `ws_stream_send_bytes(..., LinkSnapshot, ...)`
  into the link rendezvous (the shared `inbox:{master}` room, or a dedicated one-shot link room).
- Receiver: reassemble → decrypt → `import_snapshot_bytes` → restart node / reload providers →
  generate + announce its own device key (Step 1/2, already live) so the master and friends learn
  the new device.

**Progress is genuinely real** — `bytes_received / total_bytes` from the existing counter feeds the
bar. No fabricated per-category percentages (per Vitalik's explicit rejection of fake bars).

### 4.1 Progress event

New network event `LinkProgress { phase, bytes_received, total_bytes }` (and `LinkFailed { reason
}`, `LinkComplete { summary }`). Phases are honest about what is actually happening:

```
Waiting for other device   (master must be online — labeled)
Receiving data             ████████░░  12.4 / 48.0 MB   ← the ONE real bar
Decrypting
Importing
Done                       ✓ profile · ✓ 28 friends · ✓ 142 DMs · ✓ 3 servers (history)
```

The end-of-flow summary counts are **measured from the imported DB** (real `count_*` FFIs), not
guessed mid-transfer.

---

## 5. Direction & conflicts — auto-detect, recommend, escape hatch

### 5.1 Direction logic (Vitalik-locked UX)

After the two devices are paired and in-room, they exchange a tiny **state summary** (message
count, friend count, has-profile). The system:

- **Auto-detects** which device is populated vs empty.
- Shows the **recommended action prominently**: e.g. on the empty device — *"This device is
  empty. Pull everything from your other device."* (and on the populated device — *"Send your data
  to the newly linked device?"* with a **Confirm**).
- **Tucks the reverse behind a dropdown** with a warning: *"Push from this device instead — this
  will overwrite the other device's data."* One tap to reveal, with the warning shown only then.

No "who's the source" thinking required in the common case; full control is one tap away.

### 5.2 "Your other device must be online" (Vitalik-locked)

Because the master pushes the snapshot, the source device must be reachable. The link UI **labels
this clearly** ("Your other device needs to be online to sync") and the empty device shows a
*Waiting for other device…* state until the source is in-room, rather than failing silently.

### 5.3 Both devices already have data (re-link / two independent masters)

Auto-detect catches this (both summaries non-empty). Per Vitalik, surface it **honestly** with the
same recommend-default + dropdown shape, plus an **export escape hatch**:

- **Recommended:** *Merge both* — safe via `message_id` dedup + signed-op merge (Step 5 rails).
  Default offer.
- **Behind dropdown (warned):** *Replace A with B* / *Replace B with A*.
- **Escape hatch:** a transplanted slice of the **Security tab** right in this screen — re-show the
  recovery phrase, or **export the full identity** (with the user's `files`/`vault` choice) — so if
  these turn out to be two *separate* identities (not siblings), the user isn't trapped and can back
  up / branch cleanly instead of destroying data.

> **Note:** if the two devices are NOT the same identity (different master), they can't be siblings
> at all — the link simply won't establish a sibling relationship, and the escape-hatch export is
> the correct off-ramp. The both-populated *same-identity* case (re-link after independent use) is
> the genuine merge case.

---

## 6. Welcome dialog redesign (in Step 4 scope, Vitalik-locked)

The link entry point belongs at identity setup, not bolted into Settings. Redesign the Welcome
dialog to offer three clear paths:

1. **Create new identity** — generates a fresh master (today's default).
2. **Import identity (24 words)** — restore from mnemonic; auto-pulls the snapshot from an online
   sibling (§7). The primary multi-device path.
3. **Link a device (code)** — enter a 6-char code shown on your other device; pull identity + data
   without re-typing the phrase. The convenience path.

The flow then lands in the **direction/progress screen** (§4.1, §5). The redesign should follow the
Hollow design system and the `feedback_ui_logic_checklist.md` / `reference_ux_named_laws.md`
(progressive disclosure for the dropdown, honest labels, no fake seamlessness).

A **"Link / sync a device"** affordance also lives in **Settings → Security → Multi-Device** (next
to the existing *Reset Device List* button) so an already-set-up device can show a code or trigger a
manual re-sync later (drives Step 5 / Step 8 too).

---

## 7. Auto-pull on first link (Vitalik-locked)

The first time a new sibling is detected (mnemonic import OR code link), the **master auto-offers**
to push the full snapshot:

- The empty device, on becoming a verified sibling, requests the snapshot; the master prompts
  **Confirm** (it already prompts conceptually for the code path; unify the prompt), then pushes.
- The empty device shows the progress dialog with the **"other device must be online"** label if the
  master isn't reachable yet.
- **After** the first full pull, ongoing gaps close via **Step 5 backfill** + a **manual Sync
  button** (Step 8). We do not re-push the whole DB on every reconnect.

---

## 8. The honest caveat — servers are copied, not live (Step 6 gap)

The snapshot copies **server membership + channel history rows** into the new device's DB, so the
servers and their past messages will **appear**. But **live server messaging and the MLS leaf are
still Step 6** — the new device won't receive *new* server messages or hold a live MLS leaf until
then.

**The progress summary and any server row in the UI must say this honestly** — label the line
*"Servers & history copied"*, not *"Servers synced."* Surfacing the truth (not faking server
readiness) is the same principle as the rest of this design.

---

## 9. Scope summary — reuse vs. new

| Piece | Status |
|---|---|
| Full-DB snapshot build / encrypt / import | **Reuse** — `export_backup`/`import_backup`, split out in-memory core (§3.1) |
| Chunked relay transfer + real-time byte progress | **Reuse** — `ws_stream_transfer.rs` + `StreamKind::LinkSnapshot` |
| Sibling detection / device-list / friends / presence | **Reuse** — Steps 1–3 (live) |
| Short-code relay RAM map + claim/resolve verbs | **New, small** — clone of temporary-nicknames |
| Master-key handoff over the code channel + confirm prompt | **New, small** |
| Full-snapshot pull trigger on sibling-detect (vs today's friends-only) | **New, small** |
| `LinkProgress`/`LinkComplete`/`LinkFailed` events + state-summary exchange | **New, small** |
| Direction UI (recommend + dropdown + warning) | **New — UI** |
| Both-populated prompt (merge / replace / export escape hatch) | **New — UI**, merge reuses Step 5 rails |
| Welcome dialog redesign (Create / Import / Link) | **New — UI** |
| Honest progress dialog (one real bar + staged checklist + counts) | **New — UI** |
| QR (`qr_flutter`, `mobile_scanner`, camera perms) | **CUT** — codes only |

**Explicitly out of scope for Step 4:** ongoing backfill (Step 5), MLS per-device leaves /
live server messaging (Step 6), revocation (Step 7), the full Sync Health panel (Step 8).

---

## 10. Resolved implementation decisions (Vitalik-locked 2026-06-15)

1. **Rendezvous room for the transfer = the shared `inbox:{master}` room.** No dedicated link room
   — siblings already meet in `inbox:{master}`; a separate room adds a join handshake for no gain.
2. **One-time transfer key = purely random per-session.** The relay carries ciphertext only; no
   derivation from the master secret. Fresh random AES-256 key per link.
3. **State-summary = minimal, direction-only.** The two devices trade a tiny summary — **message
   count + friend count + has-profile flag** — for the sole purpose of auto-detecting *empty vs
   populated* so §5.1 can recommend the data-flow direction without the user picking. **This is NOT
   a user-facing feature** and we do NOT surface counts as UI here. The detailed per-conversation
   comparison (which device is ahead on which thread) is deferred to the **Step 8 Sync Health
   panel** — that's where "where do my devices disagree" belongs.
4. **Code = 6 chars, 5-min TTL with an on-screen countdown.** The showing device displays the code
   with a **live countdown timer below it**; on expiry the code is **returned to the relay's
   available pool** (released from the RAM map, exactly like a nickname release on disconnect). Code
   is one-shot — consumed on a successful link. Sweep cadence matches the existing nickname path.

---

## 11. Cross-references

- `MULTI_DEVICE_SYNC_PLAN.md` §3 — original (now-superseded) QR ceremony.
- `reports/MULTI_DEVICE_IMPLEMENTATION_TRACKER.md` — Step 4 checklist (to be expanded from this).
- `project_temporary_nicknames.md`, `feedback_relay_rules.md` — the RAM-on-relay code pattern.
- `api/storage.rs` `export_backup`/`import_backup` — the snapshot core.
- `node/ws_stream_transfer.rs` — the chunked transfer + progress machinery.
- `project_multidevice_migration_state.md` — Step 6 deferral (the §8 caveat).
- `feedback_ui_logic_checklist.md`, `reference_ux_named_laws.md` — UX guardrails for the redesign.
