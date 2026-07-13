# Conferences — Zoom-Style Rooms with Waiting Room

*Design agreed 2026-07-13 (Vitalik + Claude session). Authoritative design doc for the conference epic. Checklist lives in HOLLOW_PLAN.md (Phase 6 list).*

## What This Is

Ad-hoc meetings between people who share no server and no friendship — a host creates a **room**, shares a link, and admits joiners through a **waiting room**, Zoom-style. Built almost entirely from shipped machinery: deep links, relay WS rooms, ad-hoc MLS groups, SFrame, and the voice-channel media stack.

**The one-line security model:** admission *is* the cryptography. Being "let in" means the host commits an MLS add for you; until then you hold ciphertext. There is no server-side room state, no relay knowledge of membership, no plaintext fallback.

## Core Model: Durable Rooms

A conference room is a **persisted local object on the host** (SQLCipher table, host's device):

| Field | Notes |
|---|---|
| `conf_id` | random 32 bytes, unguessable; the link capability |
| `name` | host-chosen room name |
| `waiting_room` | bool (default ON) |
| `access_code` | optional; stored hashed |
| `co_hosts` | list of master identities with admission/moderation rights |
| `broadcast_mode` | bool (v2+; viewers receive-only) |
| `created_at` | |

Rooms survive meetings ("my personal meeting room"). "Start meeting" activates a room; ending a meeting deactivates it but keeps the room + link. Deleting a room retires the `conf_id` forever.

Links, both forms (existing deep-link machinery):
- `hollow://conference/<conf_id>`
- `https://hollow.anonlisten.com/join#conf=<conf_id>` — FRAGMENT, id never reaches server logs (same rule as server invites).

## Identity & Multi-Device

- **Device-only join.** Each device joins as its own participant: own MLS leaf, own PCs, own tile — exactly like voice channels (participants key on the routable WS sender). Someone joining from desktop + phone appears twice; that's fine and correct.
- **Display collapses device→master** via `identityOf`, per the iron rule. Transport stays device-keyed; per-person display never shows a bare device id.
- No sibling fan-out, no device-list exchange with strangers. A conference is live-only; siblings that want in just join.

## Admission Flow (Waiting Room = MLS Add)

1. Joiner opens the link → app joins relay WS room `conf:<conf_id>`.
2. Joiner sends `conference_join_request`: display name, avatar **hash** (light-announce rule — no blobs to strangers), their KeyPackage, and the access code if the link/UI collected one. Signed by the joiner's device key.
3. Host ingest: **`blocklist::is_blocked(sender)` drops the request BEFORE store+emit** (conference join is a stranger-facing inbound surface — the standard rule applies). Surviving requests emit to the host UI.
4. Host UI waiting-room panel shows: display name, avatar, peer ID, and a local friend/not-friend badge (computed from the host's own friend list — no graph queries, no mutuals; VETOED relational surfaces stay vetoed).
5. **Accept** = host commits an MLS add to the ad-hoc group `conf#{conf_id}` (per-channel-subgroup machinery, `"{server}#{channel}"` key pattern reused) and sends the Welcome to the joiner. **Decline** = `conference_join_denied` signal. Access code correct + waiting room OFF = auto-admit.
6. SFrame media keys derive from the conference group's `export_secret`, exactly like per-channel voice subgroups. **Kick = MLS remove + key rotation** — removal is cryptographic, not cosmetic.

Joiner-side lobby: "You're in the waiting room for **<host name>**'s meeting" — host display name + avatar hash ride the join handshake, signed by the host's key. Show minimal info; declined joiners get a plain "The host declined your request."

Access code semantics: an **admission check, not key material**. Mixing a password into key derivation buys nothing here (admission is already MLS-gated) and complicates rotation.

## Co-Hosts & Host-Offline

Co-hosting is a **policy permission enforced at ingest**, like server roles: any member can technically commit an MLS add, so every member validates "was this add/remove committed by the host or a listed co-host?" — the `op.author`-validation pattern. Co-host list rides the room settings, announced to the group when the meeting starts.

- Host offline, co-host present → meeting continues; co-host admits/kicks.
- Host offline, nobody privileged → waiting room queues; joiners see "waiting for host."
- Meeting *creation* still requires the host (the room lives on their device). v1 does not replicate rooms to co-host devices.

## New Signal Types (Rust)

Per the whitelist rule, each new signal needs the 3 touches (types.rs variant with `#[serde(default)]` fields, send match arm, swarm dispatch arm):

- `conference_join_request` (joiner → room): name, avatar_hash, key_package, code, timestamp
- `conference_join_response` (host → joiner): accepted + Welcome ref, or host profile-light for the lobby banner
- `conference_join_denied` (host → joiner)
- `conference_state` (host/co-host → room): meeting started/ended, co-host list, kicks

SDP/ICE/media signaling reuses the existing voice-channel targeted-message paths, keyed on the conference instead of `server#channel`.

## Call Surface (Dart)

Reuse the VC pane components wholesale: camera grid, screen-share view with source switcher, speaking indicators (vcSpeakingProvider pattern), right-side chat overlay, device switching, SFrame rebind rules. Media limits are inherited VC limits (mesh cap, audio gossip ≥6 participants, 5-viewer screen cap) — conferences don't add new ones, and the media-forwarding epic (plan line ~2020) lifts them for both surfaces at once.

**Conference chat:** MLS application messages under the conference group, rendered in the same chat overlay component. **RAM-only v1** — dies with the meeting, never persisted, never touches relay rings (conferences are live-only; no offline catch-up by design).

## Manager Tab (Dart)

- FriendsBar icon between Saved Messages and Help → switches the center to a dedicated **Conferences** tab (Archive/Share pattern, lives in the bottom_bar.dart world per the Dock rule).
- Tab: room list (name, copy-link, active state), Create room, per-room settings sheet (waiting room toggle, access code, co-hosts picker, broadcast preset when it lands), and a prominent **Start meeting**.
- Mobile parity: same surface reachable from MobileShell; call pushes a route like the mobile VC route (`hollowMobileRoute()`).

## Later Phases (explicitly deferred)

- **Media gossip forwarding** (plan line ~2020): cameras + screen share onto the voice gossip tree, multi-hop originator attribution. Prerequisite for broadcast at scale. Benefits regular VCs equally.
- **Broadcast mode:** a permission preset (host/co-hosts publish, everyone else receive-only + chat). Cheap once forwarding exists; without it a broadcaster's uplink caps out at ~5–15 direct viewers.
- **RTMP ingest (local only):** OBS → `rtmp://localhost` → bundled ffmpeg → injected as the screen-share track. Streamer tooling without server infra. NEVER server-side RTMP ingest/distribution — that's the centralized-bandwidth trap.
- **Web guest (Flutter Web / wasm subset):** conference-only browser client (vodozemac + OpenMLS are wasm-able; browser WS + WebRTC; ephemeral in-memory identity, no DB). Own epic, own design round. Until then the `/join#conf=` page is the bounce-to-app funnel.

## Invariants (do not violate)

1. Waiting-room admission = MLS add; kick = MLS remove + rotation. No UI-only gating.
2. `blocklist::is_blocked` at `conference_join_request` ingest, before store+emit.
3. Conference ids ride URL FRAGMENTS on the web form; never in paths/queries.
4. Join requests carry avatar hashes, never blobs (stranger surface = light announce).
5. Transport device-keyed, display master-collapsed (`identityOf`).
6. Conference chat/media never persist on the relay; RAM-only chat v1.
7. Access code = admission check, not key material.
8. New signal types = 3 Rust touches; unknown types silently drop (by design).
9. No relational info in waiting-room UI beyond the host's own friend flag.

## Build Order

1. **v1 (shippable):** room object + manager tab + waiting-room admission over MLS + call surface reusing VC machinery + deep links + RAM chat.
2. Co-hosts, access code, permission presets, meeting-state polish.
3. Media gossip forwarding epic (line ~2020).
4. Broadcast mode.
5. (Later) local RTMP ingest; Flutter-web guest.
