# Hollow — A Fully Distributed, Encrypted Discord Alternative

> **Status:** Active Development — Phases 1-4 Complete. Phase 5 (WebSocket Relay) & Phase 6 (Pure MLS) Complete. Vault health system & libp2p removal next.
> **Author:** Designed through technical discussion, February 2026.
> **Philosophy:** No central servers. No Electron. No Node.js hosting. The members ARE the server.

---

## Table of Contents

1. [Vision & Core Principles](#1-vision--core-principles)
2. [Architecture Overview](#2-architecture-overview)
3. [Technology Stack](#3-technology-stack)
4. [Distributed Storage System — "Shared Vault"](#4-distributed-storage-system--shared-vault)
5. [Networking Layer — Peer-to-Peer](#5-networking-layer--peer-to-peer)
6. [Data Synchronization — CRDTs](#6-data-synchronization--crdts)
7. [End-to-End Encryption](#7-end-to-end-encryption)
8. [Identity & Authentication](#8-identity--authentication)
9. [Real-Time Communication (Voice/Video/Screen Share)](#9-real-time-communication-voicevideoscreenscreen-share)
10. [Discord Import System](#10-discord-import-system)
11. [Desktop & Mobile Distribution](#11-desktop--mobile-distribution)
12. [UI/UX Design Approach](#12-uiux-design-approach)
13. [Development Phases & Milestones](#13-development-phases--milestones)
14. [Threat Model & Security](#14-threat-model--security)
15. [Known Challenges & Mitigations](#15-known-challenges--mitigations)
16. [Comparison With Existing Alternatives](#16-comparison-with-existing-alternatives)
17. [Server Lifecycle & Data Sovereignty](#17-server-lifecycle--data-sovereignty)
18. [Sustainability & Monetization](#18-sustainability--monetization)
- [Appendix A: Key Technical References](#appendix-a-key-technical-references)
- [Appendix B: Glossary](#appendix-b-glossary)
- [Appendix C: FAQ](#appendix-c-faq--questions--answers-from-the-design-process)

---

## 1. Vision & Core Principles

### What Hollow Is

A communication platform where **every member collectively hosts the server they belong to**. There is no data center, no cloud subscription, no single point of failure. When you join a Hollow server, you donate a small amount of your disk space and bandwidth. In return, the server exists — distributed across everyone's devices — as long as at least one member is online.

### Core Principles

1. **Zero Central Infrastructure** — The server IS its members. No company to shut down, no hosting bill, no terms of service changes. A lightweight signaling service exists only for initial peer discovery (like DNS for the internet — tiny, stateless, replaceable).

2. **Native Performance** — Flutter compiles to native binaries. No Electron, no embedded Chromium, no Node.js runtime. A 50-80 MB installer that runs as fast as any native app.

3. **Dead-Simple Installation** — Download EXE/DMG/APK. Install. Open. Done. No `npm install`, no Docker, no command line, no GitHub clone instructions. Your grandma should be able to install it.

4. **End-to-End Encrypted Everything** — Messages, files, voice calls, video calls, screen shares. The infrastructure (relay nodes, storage chunks on other members' devices) sees only encrypted noise.

5. **Shared Storage, Shared Responsibility** — Every member donates disk space. The server's capacity grows with its community. Data is erasure-coded and distributed so no single member's departure causes data loss.

6. **Discord-Level UX** — Servers, channels, roles, permissions, threads, reactions, embeds, rich presence. Users shouldn't have to sacrifice features for privacy and decentralization.

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         HOLLOW CLIENT                            │
│                     (Flutter Native App)                         │
│                                                                 │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌────────────────┐  │
│  │ UI Layer │  │  E2EE    │  │  CRDT    │  │  Storage       │  │
│  │ (Flutter │  │  Engine  │  │  Sync    │  │  Engine        │  │
│  │  Widgets)│  │          │  │  Engine  │  │  (Vault +      │  │
│  │          │  │ Olm(DM)/ │  │ (Custom) │  │   Erasure      │  │
│  │          │  │ MLS(Srv) │  │          │  │   Coding)      │  │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └───────┬────────┘  │
│       │              │             │                │            │
│  ┌────┴──────────────┴─────────────┴────────────────┴────────┐  │
│  │              Rust Backend (via flutter_rust_bridge FFI)    │  │
│  │  ┌──────────────┐  ┌──────────────┐  ┌─────────────────┐ │  │
│  │  │ WS Client    │  │ MLS Manager  │  │ Olm Manager     │ │  │
│  │  │ (WSS Relay)  │  │ (OpenMLS)    │  │ (vodozemac)     │ │  │
│  │  └──────────────┘  └──────────────┘  └─────────────────┘ │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
          │                    │                    │
          ▼                    ▼                    ▼
    ┌──────────┐  WSS   ┌──────────────┐  WSS   ┌──────────┐
    │ Member A │◄──────►│  WS Relay    │◄──────►│ Member C │
    │(stores   │        │  (VPS)       │        │(stores   │
    │shards    │        │ Room Router  │        │shards    │
    │1,3,5)    │        │ + Signaling  │        │1,4,5)    │
    └──────────┘        └──────────────┘        └──────────┘
                               ▲
                               │ WSS
                        ┌──────────┐
                        │ Member B │
                        │(stores   │
                        │shards    │
                        │2,3,6)    │
                        └──────────┘
```

**Data flow for sending a server channel message:**
1. User types message in Flutter UI
2. Message is signed with Ed25519 and wrapped in a `MessageEnvelope`
3. Envelope is MLS-encrypted (one encrypt operation for the entire server group)
4. Encrypted ciphertext is sent via `SendToRoom` to the WSS relay
5. Relay broadcasts to all room members (single WS send, relay fans out)
6. Each member decrypts via MLS, verifies signature, stores in SQLCipher
7. When offline members reconnect, they sync missing messages via MLS-encrypted channel probes

**Data flow for sending a DM:**
1. Message is signed and wrapped in a `MessageEnvelope`
2. Envelope is Olm-encrypted (Double Ratchet, per-session keys)
3. Sent to the peer via WS relay (direct message, not broadcast)
4. Peer decrypts via Olm, stores locally

---

## 3. Technology Stack

| Layer | Technology | Why |
|---|---|---|
| **Client Framework** | Flutter (Dart) | Single codebase → native Windows, macOS, Linux, Android, iOS, Web. No Electron. |
| **Transport** | WebSocket Relay (WSS) via `tokio-tungstenite` | Single persistent WSS connection per client to relay server. Room-based broadcast for servers, direct messages for DMs. Binary frames for file/shard streaming. 30s keepalive ping. |
| **Relay Server** | Axum (Rust) — HTTP signaling + WebSocket room router | Deployed on VPS (relay.anonlisten.com:443 via Nginx TLS). Stateless encrypted pipe — sees only ciphertext. Room join/leave, message broadcast, binary forwarding, presence notifications. |
| **Data Sync** | Custom CRDTs (Rust) | Custom CRDT types: LWW-Register (roles, settings), OR-Set-like (channels, members), op-log with HLC ordering. State vectors for delta sync. No Automerge dependency. |
| **Distributed Storage** | Adaptive Reed-Solomon erasure coding + full replication | <6 members: full replication (P2P streaming). 6+: adaptive erasure coding — k/m scale with member count (1.5x overhead). Files/media only. Vault shards distributed via MLS metadata + WS binary streaming. |
| **E2EE (Servers)** | OpenMLS 0.8 (MLS RFC 9420) via Rust FFI | ALL server messages: MLS group encrypt → `SendToRoom` broadcast. One encrypt, relay fans out. Target filtering for peer-specific messages (all decrypt for ratchet sync, only target processes). Scales O(log n) on member changes. |
| **E2EE (DMs)** | vodozemac (Olm/Double Ratchet) via Rust FFI | 1:1 DMs: Olm encryption with Double Ratchet. Key exchange via `KeyRequest`/`KeyBundle` over WS (no DHT). Forward secrecy + post-compromise security. |
| **E2EE (Calls)** | DTLS-SRTP + SFrame | WebRTC native encryption + inner E2EE layer via SFrame for group calls. (Planned — not yet implemented.) |
| **Voice/Video** | flutter_webrtc + LiveKit protocol | Mature WebRTC for Flutter. Mesh for small calls (2-4), SFU-like "super peer" for larger groups. (Planned — not yet implemented.) |
| **Local Database** | SQLite (encrypted via SQLCipher) | All local data encrypted at rest. Fast, embedded, no server needed. `rusqlite` with `bundled-sqlcipher` feature. |
| **Identity** | Ed25519 keypairs (via libp2p, migrating to ed25519-dalek) | Public key = identity. PeerId derived as `base58btc(multihash(sha256(protobuf(pubkey))))`. BIP-39 mnemonic backup. No phone numbers, no email. |
| **Legacy (being removed)** | libp2p 0.56 | Originally the core networking stack. Now fallback-only — all real traffic flows through WSS relay. Scheduled for full removal (see plan-libp2p-removal.md). |

### Why Rust FFI Instead of Pure Dart

The networking, crypto, and storage layers require battle-tested implementations that don't exist in Dart. `flutter_rust_bridge` v2.11.1 provides ergonomic, type-safe FFI between Dart and Rust with async support:

- **Dart** handles UI, app logic, state management (Riverpod)
- **Rust** handles networking (WS client), crypto (Olm, MLS, AES), storage engine (SQLCipher, vault), CRDTs
- **FFI bridge** connects them with minimal overhead — event streaming via `StreamSink`

This is the same pattern used by major apps (e.g., Signal uses Rust for its crypto library across all platforms).

---

## 4. Distributed Storage System — "Shared Vault"

This is the core innovation. Every member donates storage. The server's files live distributed across everyone's devices. The vault is **always on** — the storage mode adapts automatically based on server size. Vault handles **files and media only** — text messages, CRDTs, and server config use the existing sync system.

### Design Decisions

- **Vault scope:** Files/media only. Text messages and CRDTs already have their own sync+storage system and are negligible in size. Vault is not needed for them.
- **DMs stay direct P2P.** No vault involvement — DMs are 1:1, erasure coding has no benefit. Full sync between the two peers as-is.
- **Automatic mode selection:** Below 6 members → full replication (every member gets every file). 6+ members → erasure coding with adaptive k/m. No admin toggle needed — "just works."
- **Manifests broadcast to all members** (like CRDT ops). Manifests are tiny (~200 bytes), full replication is simpler and more reliable than erasure coding them.
- **Forward-only retention (Rat Files safe):** Retention settings only apply to files uploaded AFTER the setting is changed. Existing files stay permanent. This prevents malicious owners from retroactively deleting evidence. Default: permanent. If owner sets `retention_files: 90d`, only new uploads get the 90-day expiry. All existing data is untouched.

### How It Works

#### 4.1 Storage Pledge

When joining a server, each member automatically pledges a minimum amount of storage (set by the server admin, default 512 MB). Members can optionally donate more.

```
Server: "Cozy Community"
Members: 100
Minimum pledge: 512 MB
Total raw pool: 50 GB (minimum) + voluntary donations
Usable capacity: ~33 GB (after erasure coding overhead)
```

#### 4.2 Adaptive Storage Modes

**Small servers (<6 members) — Full Replication:**
- Every file is synced to every member (same as current P2P file sharing, but managed by the vault storage/cache layer)
- Simple, reliable, fast — everyone has everything
- Storage overhead: Nx (where N = member count), but for 3-5 people with small files this is negligible
- Retention is forward-only (Rat Files philosophy): setting changes only affect new uploads, existing files stay permanent

**Larger servers (6+ members) — Erasure Coding (Reed-Solomon):**

Instead of storing N full copies of everything, use erasure coding:

- Split each file into **k** data shards
- Generate **m** parity shards (using Reed-Solomon coding)
- Total **n = k + m** shards
- Any **k** of the **n** shards can reconstruct the original file

**Adaptive k/m based on member count** — computed automatically:

| Members | k | m | n (total shards) | Tolerance | Overhead |
|---|---|---|---|---|---|
| < 6 | — | — | — (full replication) | all but 1 | Nx |
| 6-8 | 3 | 2 | 5 | 2 offline | 1.67x |
| 9-15 | 5 | 3 | 8 | 3 offline | 1.60x |
| 16-30 | 8 | 4 | 12 | 4 offline | 1.50x |
| 31-60 | 10 | 5 | 15 | 5 offline | 1.50x |
| 61-150 | 12 | 6 | 18 | 6 offline | 1.50x |
| 151-500 | 16 | 8 | 24 | 8 offline | 1.50x |
| 500+ | 20 | 10 | 30 | 10 offline | 1.50x |

Pattern: k scales with log(member_count), m = ceil(k/2), overhead converges to 1.5x. Total shards n never exceeds 30 — distributing 30 shards across thousands of members is trivial. Pure function: `compute_adaptive_params(member_count) -> (k, m)`.

When members join/leave and cross a threshold, **new content uses the new k/m**. Existing content stays at its original k/m — re-encoding everything would be prohibitively expensive. The rebalancer only repairs missing shards, not re-encodes.

Storage tier multiplier adjusts m relative to the base: standard tier uses base m, higher tiers increase m proportionally.

#### 4.3 Content-Addressed Storage

Every piece of data is addressed by its cryptographic hash (SHA-256):

```
content_id = SHA-256(encrypted_data)
```

This provides:
- **Deduplication** — identical content stored once
- **Integrity verification** — detect corrupt or tampered shards
- **Location-independent addressing** — find data by hash, not by "which server it's on"

#### 4.4 Deterministic Shard Placement (XOR Distance)

Shard placement is deterministic — all peers compute the same placements independently using XOR distance:

1. Compute `content_id = SHA-256(encrypted_data)`
2. For each shard `i`, compute `shard_key = SHA-256(content_id || i_as_u16_be)`
3. For each peer, compute `distance = XOR(shard_key, SHA-256(peer_id))` (256-bit keyspace)
4. Sort peers by distance (ascending), assign shard to closest peer with available capacity
5. Weighted by storage pledge: `per_peer_cap = ceil(n * peer_pledge / total_pledge)`

**Key property:** Any peer can recompute placements using the same algorithm (content_id + member list + pledges from CRDT). Non-uploaders can determine where shards live without needing a central directory.

To retrieve: recompute placements → request missing shards from their assigned peers via MLS → reconstruct from any k of k+m shards.

#### 4.5 Rebalancing

When a member leaves (or goes permanently offline):

1. Other members detect the departure (no heartbeat for configured threshold, e.g., 7 days)
2. The system identifies which shards are now under-replicated
3. Surviving members that have the remaining shards generate the missing parity shards
4. New shards are placed on other members with available capacity

When a new member joins:

1. Some shards are migrated to the new member to balance load
2. This happens gradually in the background, not all at once
3. Priority: move shards from members who are over-capacity

#### 4.6 Storage Tiers

Tiers apply only to files/media in the vault. k/m values below are base values for a 31-60 member server — actual values are computed adaptively from member count, then scaled by tier multiplier.

| Data Type | Tier Multiplier (on m) | Retention | Priority |
|---|---|---|---|
| Images and files | 1.0x (standard) | Configurable (default: 1 year) | Standard |
| Voice message recordings | 0.6x (lower m) | Configurable (default: 90 days) | Low |

Note: Server config, roles, channel metadata, text messages, and CRDTs are **not vault-stored** — they use the existing CRDT sync system which already replicates to all connected members.

#### 4.7 Local Cache

Each member also maintains a local cache of recently accessed files (outside their pledge). This means:
- Files in channels you actively use are fast to load (local)
- Scrolling back loads files from the distributed network
- Going offline? You still have your recently viewed files locally
- Sender sees their uploaded file immediately from local cache while shards distribute in background

---

## 5. Networking Layer — WebSocket Relay

### 5.1 Architecture: Hub-and-Spoke via WSS Relay

Hollow uses a **WebSocket relay server** as the primary (and currently sole) transport. Every client maintains ONE persistent WSS connection to the relay. The relay is a stateless encrypted pipe — it routes messages between room members but cannot read any content (all payloads are MLS or Olm encrypted).

```
Client A ──WSS──► ┌─────────────────┐ ◄──WSS── Client B
                  │   WS Relay      │
                  │  (Axum/Rust)    │
                  │                 │
                  │  Room Router:   │
                  │  - Join/Leave   │
                  │  - Broadcast    │
                  │  - Direct msg   │
                  │  - Binary fwd   │
                  │  - Presence     │
Client C ──WSS──► │                 │ ◄──WSS── Client D
                  └─────────────────┘
```

**Why relay instead of direct P2P:**
- NAT traversal is unreliable (~80% success for hole punching, 0% behind symmetric NAT)
- libp2p connection churn caused sync failures, prekey storms, transport cycling
- Single WSS connection is simpler, faster to establish, works through any firewall
- TLS on port 443 looks like normal HTTPS traffic (harder to censor)
- Relay sees only encrypted ciphertext — zero trust compromise

### 5.2 Transport Details

**WSS Connection:**
- URL: `wss://relay.anonlisten.com/ws` (Nginx TLS termination on port 443)
- Authentication: Ed25519 signature (`hollow-ws-auth:{peer_id}:{timestamp}`)
- Auto-reconnect with exponential backoff (1s → 2s → 4s → ... → 30s max)
- 30-second keepalive ping prevents idle connection drops
- Re-joins all rooms on reconnect

**Message types (JSON text frames):**
- `Auth` — authenticate with peer_id + signature
- `Join/Leave` — room membership
- `Msg` — broadcast to room (base64-encoded MLS ciphertext)
- `Direct` — send to specific peer in room

**Binary frames (for file/shard streaming):**
- `0x02` prefix — `BinaryDirect` frame: `[0x02][room\0][target\0][payload]`
- 256KB chunk size for large transfers
- Relay swaps target→sender in header before forwarding
- Used for AES-encrypted file bytes and vault shard data

### 5.3 Room-Based Routing

Each server has a room (room_code = server_id). Each DM pair has a room (room_code = sorted hash of both peer IDs). The relay tracks room membership and routes accordingly:

- **`SendToRoom`** — broadcast to all room members except sender. Used for MLS-encrypted server messages.
- **`SendDirect`** — send to one specific peer in a room. Used for Olm DMs and targeted shard requests.
- **`BinaryDirect`** — binary frame forwarded to one peer. Used for file/shard streaming.
- **Presence** — relay emits `PeerJoined`/`PeerLeft` events when members join/leave rooms.

### 5.4 Signaling Service

A lightweight HTTP signaling service runs alongside the WS relay on the same VPS. It provides initial peer discovery:

- Peers register their addresses for each room they belong to
- New peers bootstrap by querying the signaling service for known peers in a room
- Heartbeat: 120-second keepalive, 3-minute stale cleanup
- NOT used for message routing — only for initial connection bootstrapping
- Ed25519 signed requests prevent impersonation

### 5.5 Connection Lifecycle

1. App starts → WS client connects to relay → authenticates
2. Joins rooms for all known servers + DM friends
3. Relay emits `PeerJoined` for each room member already present
4. Peer discovery triggers CRDT sync + MLS key exchange
5. All messages flow through WS relay from this point
6. On disconnect → relay notifies room members via `PeerLeft`
7. Client auto-reconnects and re-joins all rooms

### 5.6 Legacy: libp2p (Being Removed)

libp2p 0.56 still exists as a fallback transport but is scheduled for full removal. It was the original networking stack (QUIC, TCP, mDNS, Kademlia DHT, relay circuit, hole punching). All real traffic now flows through WSS. The libp2p components generate noise (failed dial attempts to stale peers) and add ~30-40% to binary size. See `plan-libp2p-removal.md` for the removal plan.

---

## 6. Data Synchronization — CRDTs

### 6.1 Why CRDTs

In a P2P system with no central server, two members can perform actions simultaneously (send messages, create channels, change roles). Without a central authority to decide ordering, you need data structures that **mathematically guarantee convergence** — all members end up with the same state regardless of the order they receive updates.

**CRDTs (Conflict-free Replicated Data Types)** provide exactly this.

### 6.2 CRDT Types Used

| Data | CRDT Type | Behavior |
|---|---|---|
| Message history | RGA (Replicated Growable Array) | Ordered list that handles concurrent inserts. Each message gets a unique, sortable ID (Hybrid Logical Clock). |
| Channel list | OR-Set (Observed-Remove Set) | Add/remove channels. Concurrent add + remove → add wins. |
| Members list | OR-Set | Add/remove members with conflict resolution. |
| Roles & permissions | LWW-Register (Last Writer Wins) per field | Permission changes resolve by timestamp. Admin actions have priority. |
| Reactions | PN-Counter per emoji per message | Increment/decrement counts that merge correctly. |
| Pins | OR-Set | Pinned messages set. |
| User profiles | LWW-Map | Per-field last-writer-wins for display name, avatar, status. |
| Server settings | LWW-Map with admin priority | Settings merge with admin writes always winning. |

### 6.3 Hybrid Logical Clocks (HLC)

For ordering messages, use Hybrid Logical Clocks instead of wall clocks:

```
HLC = (physical_time, logical_counter, peer_id)
```

- `physical_time` — system clock, synchronized loosely (NTP)
- `logical_counter` — increments when the physical clock hasn't advanced, ensuring unique timestamps
- `peer_id` — tiebreaker for identical timestamps

HLCs are monotonically increasing per peer and establish a causal ordering. Two messages from different peers with close timestamps are ordered deterministically, and all peers agree on the order.

### 6.4 Sync Protocol

When two peers connect (or reconnect after being offline):

1. **Exchange state vectors** — each peer sends a compact summary of what it has: `{peer_A: hlc_42, peer_B: hlc_37, ...}` (the latest HLC seen from each originating peer)
2. **Compute delta** — each peer determines what the other is missing
3. **Send missing operations** — only the operations the other peer hasn't seen
4. **Apply operations** — CRDT merge is commutative and idempotent, so order doesn't matter and duplicates are harmless

This is efficient — after initial sync, only new operations are exchanged. A member returning after a week offline receives only the operations that happened during that week, not the entire history.

### 6.5 Custom CRDT Implementation

Hollow uses custom CRDT types (not Automerge) implemented in Rust:

- **ServerState** — the root CRDT document per server, containing all sub-CRDTs
- **op_log** — append-only log of `CrdtOp` operations, each with HLC timestamp + author + payload
- **StateVector** — compact summary `{peer_id: latest_hlc}` for delta sync
- **AdminLwwReg<T>** — LWW-Register where admin/owner writes always win conflicts

**CRDT operations are broadcast via MLS** (for servers) or plaintext (during join bootstrap):
```rust
// Rust side — creating and broadcasting a CRDT op
let op = state.create_op(CrdtPayload::ChannelAdded { channel_id, name });
let _ = state.apply_op(&op);

// Broadcast via MLS (single encrypt → SendToRoom → relay fans out)
let envelope = MessageEnvelope::CrdtOp { sid: server_id, op_json };
send_mls_broadcast(mls, ws_cmd_tx, &server_id, &envelope, keypair);
```

**Sync protocol:**
1. On peer connect: exchange `StateVector` (latest HLC per author)
2. Compute delta: `compute_delta(our_op_log, their_state_vector) → Vec<CrdtOp>`
3. Send missing ops via MLS `SyncResp` envelope
4. Receiver merges: `merge_ops(state, incoming_ops)` — commutative, idempotent
5. Fan-out sync coordinator: distributes channel sync probes across available peers with 5-second dedup

---

## 7. End-to-End Encryption

### 7.1 Encryption Architecture — Layers

```
┌──────────────────────────────────────────────────┐
│ Layer 3: Application Encryption                   │
│ (E2EE — only participants can decrypt)            │
│ Messages: Signal Protocol / MLS                   │
│ Files: AES-256-GCM with per-file keys             │
│ Calls: SFrame inner encryption                    │
├──────────────────────────────────────────────────┤
│ Layer 2: Storage Encryption                       │
│ (Data at rest on member devices)                  │
│ Local DB: SQLCipher (AES-256-CBC)                 │
│ Shard storage: Encrypted before erasure coding    │
├──────────────────────────────────────────────────┤
│ Layer 1: Transport Encryption                     │
│ (Data in transit between peers)                   │
│ QUIC: TLS 1.3 built-in                           │
│ TCP: Noise Protocol Framework                     │
└──────────────────────────────────────────────────┘
```

**Layer 1** protects against network eavesdroppers.
**Layer 2** protects against device theft / storage compromise.
**Layer 3** protects against EVERYONE except intended recipients — including relay nodes, storage nodes, and compromised peers.

### 7.2 Direct Messages (1:1) — Olm (Double Ratchet)

Uses vodozemac (Matrix's audited Olm implementation) for the Double Ratchet:

**Key Exchange (via WS relay — no DHT):**
- When Peer A wants to message Peer B for the first time:
  1. A sends `KeyRequest` to B via WS relay (plaintext `HavenMessage`)
  2. B generates a one-time key, responds with `KeyBundle { identity_key, one_time_key }`
  3. A creates an outbound Olm session using B's keys
  4. First message is a "PreKey message" (type 0) — B creates an inbound session from it
  5. `SessionAck` handshake upgrades both sides to Normal (type 1) ratchet
- Key exchange is nearly instant (one WS round-trip vs seconds for DHT lookup)
- Works even if B is online but not yet in the same WS room (routed via any shared room or direct connection)

**Double Ratchet (ongoing messages):**
- Every message uses a unique encryption key
- Keys are derived via a ratchet: `new_key = KDF(previous_key, new_DH_exchange)`
- Forward secrecy: compromising current keys doesn't reveal past messages
- Post-compromise security: a new DH exchange heals the session after a compromise
- Message keys are deleted after use

### 7.3 Group Channels — MLS (Messaging Layer Security)

For group channels (the "server channels" feature), use MLS (RFC 9420) instead of Signal's Sender Keys:

**Why MLS over Sender Keys:**
- Sender Keys: When a member leaves, all remaining members must re-key — O(n) cost
- MLS: Uses a binary tree (ratchet tree) of DH keys. Member changes are O(log n)
- For a 1000-member channel, that's ~10 operations instead of 1000

**How MLS works:**
1. Each channel is an MLS "group" with a ratchet tree
2. Each member is a leaf in the tree
3. Internal nodes hold DH key pairs derived from their children
4. The root holds the group secret, from which message encryption keys are derived
5. When a member joins/leaves, only the path from their leaf to the root is updated
6. A "Commit" message broadcasts the tree update to all members
7. All members can derive the new group secret from the updated tree

**Key rotation on member removal:**
1. Admin issues a Remove proposal + Commit
2. The removed member's leaf is blanked in the tree
3. Fresh randomness is injected into the path to the root
4. New epoch begins — removed member cannot derive the new group secret
5. Cost: O(log n) — only the path from the removed leaf to the root changes

### 7.4 File Encryption

```
1. Generate random File Encryption Key (FEK) — AES-256-GCM
2. Encrypt file: ciphertext = AES-256-GCM(FEK, file_data)
3. Wrap FEK with channel's current MLS epoch key
4. Erasure-code the ciphertext and distribute shards
5. Store wrapped FEK in the message metadata (within the E2EE message)
```

Peers storing the file shards hold only encrypted data. They can't decrypt without the FEK, which is only available to channel members.

### 7.5 Voice/Video Call Encryption

- **Small calls (2-4 people):** Direct peer-to-peer WebRTC with DTLS-SRTP. E2EE is built into WebRTC itself. No relay needed.

- **Larger calls (5+ people):** A "super peer" (member with best bandwidth) acts as an SFU (Selective Forwarding Unit):
  - Each participant sends their media stream once to the super peer
  - The super peer forwards streams to all participants
  - **SFrame encryption** provides inner E2EE: each participant encrypts their media frames with a per-sender key before sending to the SFU
  - The SFU forwards encrypted frames — it cannot see or hear the content
  - Recipients decrypt using the sender's key (distributed via the MLS group)

### 7.6 Crypto Libraries (Actual Implementation)

**DM E2EE:** `vodozemac` v0.9 (Rust, via FFI) — Matrix's audited Olm implementation. Double Ratchet for DMs. Key exchange via `KeyRequest`/`KeyBundle` over WS relay (no DHT). Two identity systems coexist: Ed25519 (transport/signing) and vodozemac Curve25519 (Olm sessions).

**Server E2EE:** OpenMLS 0.8 (Rust, via FFI) — MLS (RFC 9420) group encryption for ALL server messages. Single-committer model (server owner processes KeyPackages). Batch member addition (2-second timer, dedup by peer_id). `send_mls_broadcast()` → one encrypt → `SendToRoom` → relay fans out. `send_mls_to_peer()` → targeted messages with `target` field (all decrypt for ratchet sync, only target processes). 183 tests passing.

**File encryption:** AES-256-GCM (via `aes-gcm` crate) — per-file random key. Key transmitted in MLS-encrypted `FileHeader` envelope. File bytes streamed separately via WS binary frames.

**Local storage encryption:** SQLCipher (AES-256-CBC) — via `rusqlite` with `bundled-sqlcipher` feature.

**Identity:** `ed25519-dalek` v2.2 (currently via libp2p, migrating to direct dependency) — Ed25519 keypair generation, message signing, peer ID derivation. BIP-39 mnemonic for backup/restore.

**Flutter Web (future):** Web Crypto API via `webcrypto` package + WASM-compiled crypto primitives.

---

## 8. Identity & Authentication

### 8.1 Public Key as Identity

No phone numbers. No email addresses. No usernames registered on a central server.

```
Identity = Ed25519 public key
Display: Base58-encoded short form (e.g., "hVn8xR...3kQp")
Human-readable: Self-chosen display name (not unique, signed by identity key)
```

**Account creation:**
1. App generates Ed25519 keypair + X25519 keypair (or derives both from a single seed)
2. User chooses a display name
3. App prompts user to set up at least one recovery method (see 8.4)
4. That's it. No server registration, no verification, no waiting.

### 8.2 Multi-Device Sync (Device Linking)

Adding a new device is done directly from an existing device — no server involved.

**Linking flow:**
1. Open Hollow on the existing device (e.g., PC)
2. Go to Settings → Link New Device
3. PC displays a QR code containing:
   - A one-time session token
   - A temporary X25519 public key for establishing an encrypted channel
   - The PC's local network address (for LAN transfer) + libp2p peer ID
4. New device (e.g., phone) scans the QR code
5. Devices establish a direct encrypted channel (using the ephemeral key from the QR)
6. PC transfers to the phone:
   - Identity keypair (encrypted with the session token)
   - Server membership list + channel keys
   - Recovery guardian configuration
   - Account settings and contacts
7. Phone is now a fully linked device with the same identity

**Ongoing sync between linked devices:**
- Both devices share the same identity key → peers route messages to the identity, not a specific device
- When both devices are online, they sync directly via P2P (CRDT merge, same as server sync)
- When only one device is online, it collects everything — the other catches up later
- Critical account metadata (server list, roles, contacts) is stored at the **highest redundancy tier** in the Shared Vault, so the network remembers the user even if all their devices are offline

### 8.3 Account Recovery — Layered Approach

No single recovery method. Multiple options, layered by convenience and security. Users are encouraged to set up at least two.

#### Method 1: Device Linking (Primary — Most Common)

As described in 8.2. User has an existing device → scans QR → new device is set up in seconds. This handles the vast majority of cases (new phone, new computer, reinstalling the app).

#### Method 2: Social Recovery via Guardians (For Total Device Loss)

Inspired by Argent wallet's social recovery. Perfect for a community chat app — your backup IS your community.

**Setup:**
1. User designates 3-5 trusted contacts as **Recovery Guardians**
2. The identity key is split into shares using **Shamir's Secret Sharing** (k-of-n threshold scheme)
3. Each guardian receives one encrypted share via their pairwise E2EE channel
4. Guardians store the share automatically — no action needed from them
5. The threshold is configurable (e.g., 3-of-5, 2-of-3)

**Recovery flow:**
1. User loses ALL devices
2. Installs Hollow fresh on a new device
3. Enters their Hollow display name or public key fingerprint (short string they might remember, or have written down, or a friend can tell them)
4. App locates the guardians via DHT
5. User contacts guardians through any out-of-band channel ("Hey, I lost my phone, can you approve my recovery in Hollow?")
6. Each guardian receives a recovery request in-app and approves it
7. Once threshold is met (e.g., 3 of 5 approve), shares are sent to the new device via E2EE
8. Shares are recombined → identity key restored
9. Account data syncs from the Shared Vault (server memberships, channel keys via MLS re-welcome)

**Why this works for Hollow:** It's a social platform. Users inherently have trusted contacts. The "backup" is your friends — not a piece of paper in a drawer.

#### Method 3: Encrypted Vault Backup (For Solo Recovery)

For users who want self-reliant recovery without depending on others.

**Setup:**
1. User chooses a strong **recovery password** (or PIN + biometric on mobile)
2. Identity key + account data is encrypted with a key derived from the password (Argon2id KDF, high memory cost)
3. The encrypted backup blob is stored as a special shard in the Shared Vault, tagged to the user's public key
4. Redundancy: highest tier (same as server config — survives up to 50% of members going offline)

**Recovery flow:**
1. Install Hollow on new device
2. Enter Hollow ID (public key fingerprint — a short string like "hVn8-xR3k-Qp7z")
3. Network locates the encrypted backup shards, reconstructs the blob
4. Enter recovery password → decrypt → identity restored

**Brute-force protection:**
- Argon2id with high memory/time cost makes offline brute-force extremely slow
- Peers serving the backup shard enforce rate-limiting on retrieval requests (max 5 attempts per hour per IP)
- After 20 failed attempts, the backup is locked for 24 hours

#### Method 4: 24-Word Mnemonic (Optional — Power Users)

The traditional crypto-wallet approach. Available as an opt-in advanced feature in Settings → Security → Export Recovery Phrase.

- Deterministically regenerates the identity keypair from the mnemonic (BIP-39)
- For technically savvy users who want a completely self-sovereign backup
- Hollow does NOT show this by default during onboarding — it's buried in settings for those who want it

#### Recovery Method Comparison

| Method | User effort | Requires existing device | Requires other people | Requires remembering something |
|---|---|---|---|---|
| **Device Linking** | Scan QR code | Yes | No | No |
| **Social Recovery** | Ask 3 friends | No | Yes (guardians) | Hollow ID (short string) |
| **Vault Backup** | Enter password | No | No | Hollow ID + password |
| **24-Word Phrase** | Enter 24 words | No | No | 24 words (hard) |

### 8.5 Invite Links (No Central Server)

Invite links are cryptographically signed tokens, not URLs pointing to a server:

```
hollow://join?token=<base64-encoded signed blob>
```

The token contains:
- Server public key (identifies which server)
- Inviter's identity key + signature (proves who invited)
- Bootstrap peer list (2-3 IP:port of currently online members)
- DHT rendezvous key (hash of server key, for finding peers via DHT)
- Optional: expiry time, max uses, required role

**Flow:**
1. Inviter generates token, signs it with their identity key
2. Token is shared via any channel (copy-paste, QR code, email, another chat)
3. Joiner's app decodes token, verifies signature
4. App connects to bootstrap peers (or queries DHT with rendezvous key)
5. App authenticates with the server's member list (existing members verify the invite)
6. New member is added to the CRDT member list, receives the MLS welcome message
7. Member's device begins receiving and storing data shards

### 8.6 Server Roles & Permissions

Modeled after Discord but enforced via CRDTs with admin priority:

```
Role hierarchy (highest to lowest):
├── Owner (creator of the server, or transferred)
├── Admin (can manage roles, channels, members)
├── Moderator (can kick, mute, manage messages)
├── Custom roles (configured per server)
└── Member (default)
```

Permission changes are LWW-Register CRDTs with a twist: writes from higher-ranked roles always override lower-ranked roles in conflicts. The Owner's writes always win.

---

## 9. Real-Time Communication (Voice/Video/Screen Share)

### 9.1 Voice & Video Calls

**Technology:** flutter_webrtc package

**Topologies:**
- **1:1 calls:** Direct P2P connection via WebRTC. DTLS-SRTP encryption. Lowest latency.
- **Small group (2-5):** Mesh topology — each participant sends to all others. O(n^2) connections but minimal latency. Works well for small groups.
- **Medium group (6-15):** "Super peer" SFU — the member with the best upload bandwidth acts as the forwarding unit. Others send to the super peer, which forwards to all. SFrame E2EE ensures the super peer can't decode media.
- **Large group (16+):** Multiple super peers in a tree topology, or accept that one super peer with good bandwidth handles it. Simulcast support: senders encode at multiple quality levels, the SFU picks the right quality for each receiver.

**Super peer selection:**
1. Each member reports their available upload bandwidth (measured, not self-reported)
2. The member with the highest stable upload becomes the super peer
3. If the super peer disconnects, the next-best member takes over seamlessly
4. Super peer rotation to prevent single-member burden

### 9.2 Screen Sharing

Supported natively by flutter_webrtc:

| Platform | Method | Notes |
|---|---|---|
| Windows | DXGI Desktop Duplication / Windows.Graphics.Capture | Full screen or specific window |
| macOS | ScreenCaptureKit (macOS 12.3+) | Full screen or specific window |
| Linux | PipeWire (Wayland) / X11 capture | Varies by DE/display server |
| Android | MediaProjection API | Requires foreground service + permission |
| iOS | ReplayKit (Broadcast Upload Extension) | Separate target, 50 MB memory limit |

### 9.3 Audio Processing

- Echo cancellation, noise suppression, automatic gain control — handled by WebRTC's built-in audio processing
- Push-to-talk and voice activation modes
- Per-user volume control

---

## 10. Discord Import System

### 10.1 Data Sources

Discord provides data exports via GDPR request (Settings → Privacy → Request all of my Data). This produces a ZIP containing:

- `messages/` — JSON files for every DM and channel, including content, timestamps, authors, attachments (as URLs)
- `servers/` — Server metadata, channel lists, roles
- `account/` — User profile info

### 10.2 Import Flow

```
Step 1: User requests Discord data export (takes 24-48h from Discord)
Step 2: User provides the ZIP to Hollow's import tool
Step 3: Hollow parses the export:
        - Maps Discord servers → Hollow servers
        - Maps channels → channels (preserves names, descriptions, order)
        - Maps roles → roles (preserves hierarchy, permissions, colors)
        - Maps messages → messages (preserves content, timestamps, author IDs)
        - Downloads attachment URLs → stores as Hollow files
Step 4: Hollow creates the server structure
Step 5: Hollow generates invite links for each mapped Discord user
Step 6: Invited users join, confirm their identity, and gain their mapped roles
Step 7: Message history is attributed to "Discord Import: Username" until
        the user claims their account
```

### 10.3 Member Matching

- Import creates placeholder identities for each Discord user
- When a real user joins and claims a Discord username, their messages are re-attributed
- Claiming requires: joining via the correct invite link + providing their Discord user ID (from their own data export) as proof

---

## 11. Desktop & Mobile Distribution

### 11.1 Package Targets

| Platform | Format | Auto-Update | Distribution |
|---|---|---|---|
| **Windows** | MSIX (Store) + EXE (Inno Setup, direct) | MSIX: automatic. EXE: Squirrel.Windows or WinSparkle | Microsoft Store + direct download |
| **macOS** | DMG + notarized | Sparkle 2 (EdDSA signed appcast) | Direct download (App Store optional) |
| **Linux** | AppImage + Flatpak + Snap + deb/rpm | AppImage: AppImageUpdate. Snap/Flatpak: built-in. | Flathub + Snap Store + direct |
| **Android** | APK + AAB | Play Store: automatic. APK: in-app update check | Google Play + direct APK |
| **iOS** | IPA | App Store: automatic | App Store only |
| **Web** | Static PWA | Service worker cache | Any static host |

### 11.2 Binary Size Target

- Desktop: 50-80 MB installer (Flutter + Rust libs + libp2p + crypto)
- Mobile: 30-50 MB (ARM optimized)
- Compare: Discord Electron is ~300 MB on desktop

### 11.3 Auto-Update Strategy

Host a JSON manifest at a well-known URL (and in the DHT for redundancy):

```json
{
  "version": "1.2.0",
  "release_date": "2026-06-15",
  "channels": {
    "stable": {
      "windows": {"url": "...", "sha256": "..."},
      "macos": {"url": "...", "sha256": "..."},
      "linux": {"url": "...", "sha256": "..."}
    },
    "beta": { ... }
  },
  "release_notes": "..."
}
```

App checks on launch (or periodically). Downloads delta update if available, full installer otherwise. User prompted before applying.

---

## 12. UI/UX Design Approach

### 12.1 Design Philosophy

Built entirely with Flutter widgets. No web embedding, no WebView. The UI should feel native to each platform while maintaining a consistent Hollow identity.

**Design language:**
- Clean, modern, slightly rounded aesthetic (inspired by Discord's readability but with its own identity)
- Dark mode default with light mode option
- Adaptive layout: sidebar navigation on desktop, bottom navigation on mobile
- Smooth 60fps animations throughout

### 12.2 Core Screens

```
├── Server List (left sidebar on desktop, drawer on mobile)
│   ├── Server Icon + Name
│   ├── Unread indicators
│   └── Create/Join server buttons
│
├── Channel View (center panel)
│   ├── Channel header (name, topic, member count, call button)
│   ├── Message list (virtual scrolling for performance)
│   │   ├── Text messages with markdown rendering
│   │   ├── Embeds (links, images, files)
│   │   ├── Reactions
│   │   └── Thread indicators
│   ├── Message input (rich text, file attach, emoji picker)
│   └── Typing indicators
│
├── Member List (right sidebar, collapsible)
│   ├── Online members grouped by role
│   ├── Offline members (collapsed)
│   └── Member profile cards
│
├── Server Settings
│   ├── Overview (name, icon, description)
│   ├── Roles & permissions
│   ├── Channels management
│   ├── Member management
│   ├── Storage dashboard (see shared vault stats)
│   └── Import from Discord
│
├── Voice/Video Channel
│   ├── Grid view of participants
│   ├── Screen share viewer
│   ├── Controls (mute, deafen, video, screen share, disconnect)
│   └── Super peer indicator
│
├── User Settings
│   ├── Profile (display name, avatar, status)
│   ├── Privacy & security (key verification, linked devices)
│   ├── Storage (how much you're donating, what you're storing)
│   ├── Network (connection info, NAT status, relay usage)
│   └── Appearance (theme, font size, compact mode)
│
└── Storage Dashboard (unique to Hollow)
    ├── Server storage pool visualization
    ├── Your contribution (pledged vs used)
    ├── Network health (online members, shard distribution)
    ├── Redundancy status (per data type)
    └── Rebalancing status
```

### 12.3 Adaptive Scaling

Use a system similar to `AdaptiveScaleProvider` from WholesomeStoryADay — normalize UI dimensions based on physical screen size and pixel density. This ensures the UI looks correct on:
- 13" laptop (1080p)
- 27" monitor (4K)
- 6" phone (1080p)
- 10" tablet (2K)

---

## 13. Development Phases & Milestones

### Phase 1: Foundation — COMPLETE

**Goal:** Two users can send encrypted text messages to each other.

- [X] Flutter project setup with desktop + mobile targets
- [X] Rust FFI bridge setup (`flutter_rust_bridge`)
- [X] libp2p integration: TCP transport, mDNS peer discovery (LAN)
- [X] Ed25519 identity generation and mnemonic backup
- [X] Direct peer-to-peer connection (LAN only initially)
- [X] Basic SQLite local storage (SQLCipher encrypted)
- [X] Minimal UI: single chat view, message list, input box
- [X] X3DH key exchange + Double Ratchet (1:1 E2EE messaging)

**Deliverable:** Two devices on the same network can chat with E2E encryption.

### Phase 2: Internet Connectivity — COMPLETE

**Goal:** Two users anywhere in the world can find each other and chat 1:1 with E2EE.

- [X] libp2p: QUIC transport (for internet connectivity)
- [X] Kademlia DHT for peer discovery
- [X] NAT traversal: AutoNAT, DCUtR hole punching, circuit relay
- [X] Lightweight signaling service (Cloudflare Worker or equivalent)
- [X] Combined relay + signaling server on VPS (replaced Cloudflare Worker)
- [X] Cross-network peer discovery and relay circuit connectivity
- [X] Prekey bundle storage in DHT (for async key exchange)
- [X] Invite link generation and joining flow
- [X] Connection management (persistent connections, reconnection logic)
- [X] Room state cleanup (clear peers on room switch, deduplicate peer list)

**Deliverable:** Two users on different networks can find each other via invite link and chat with E2EE.

### Phase 2.5: UI Foundation

**Goal:** Establish Hollow's visual identity and UI architecture before building complex features on top. Replace Material Design defaults with a custom design system that feels native, premium, and distinctly Hollow.

**Design Direction:** Deep Dark + Teal Accent. Secure yet cozy — midnight backgrounds convey seriousness/trust, teal accent (#00BFA6) evokes calm/shelter (aligns with "Hollow" name). Distinct from Discord (purple), Signal (blue), WhatsApp (green). Multi-theme architecture from day one: default dark theme ships first, Frutiger Aero-inspired theme as a built-in alternate (glossy surfaces, vibrant gradients, bubble animations — leveraging Flutter's BackdropFilter, ShaderMask, CustomPainter).

**Color Palette (Default Dark Theme):**
- Background: #0D0F14 (deep midnight)
- Surface: #14161C (panels, slightly lighter)
- Elevated: #1A1D25 (cards, dialogs, popovers)
- Accent: #00BFA6 (teal — buttons, links, active states)
- Accent Hover: #00D9BB (lighter teal)
- Accent Muted: #00BFA633 (teal with alpha — subtle highlights)
- Text Primary: #F1F3F5 (near-white)
- Text Secondary: #8B919A (muted grey)
- Border: rgba(255,255,255,0.08) (subtle, 1px)
- Error/Danger: #EF4444
- Success: #10B981
- Warning: #F59E0B
- Border radius: 8-12px (medium rounded)

- [X] Custom theme system (HollowTheme: color palette, typography scale, spacing, elevation, border radii — no Material defaults. Multi-theme architecture supporting Default Dark + future Aero theme)
- [X] Dark mode primary, light mode secondary (both fully custom, not Material's ColorScheme)
- [X] Custom window chrome (remove native title bar, custom-drawn title bar with Hollow branding, window controls — via flutter_acrylic or bitsdojo_window)
- [X] State management architecture (Riverpod — chosen for auto-dispose, .family per-peer state, StreamProvider for Rust FFI streams, granular rebuilds)
- [X] Event streaming refactor (replace polling with Rust→Dart stream — real-time updates)
- [X] Navigation shell (server list sidebar, channel/chat view, member panel — responsive: sidebar on desktop, bottom nav on mobile)
- [X] Reusable component library (HollowButton, HollowTextField, HollowCard, HollowAvatar, HollowDialog, HollowToast — all custom-painted, no Material widgets)
- [X] Animation system (spring curves, page transitions, micro-interactions — buttery smooth 60fps, GPU-accelerated via Flutter's rendering pipeline)
- [X] Chat UI rebuild (message bubbles, timestamps, read indicators, typing indicator — custom widgets, not Material ListTiles)
- [X] Peer/contact list rebuild (online/offline status, avatars, encryption badge — integrated with new component library)
- [X] Adaptive layout system (responsive breakpoints for desktop/tablet/mobile — single codebase, three layouts)
- [X] Custom iconography (Hollow icon set or curated icon package — consistent visual language)

**Deliverable:** The app looks and feels like a real product — custom visual identity, smooth animations, responsive layout. All future UI work builds on this foundation.

### Phase 2.75: Hollow Design System v2 — COMPLETE

**Goal:** Replace all Material Design defaults with Hollow's own interaction system. Zero Material interaction widgets remain. Spring physics, no ripple, custom everything.

- [X] HollowPressable — universal interaction widget (press: opacity 0.85 + scale 0.98, spring physics)
- [X] HollowButton — 4 variants: filled, ghost, outline, danger (self-contained animations, hover glow)
- [X] HollowTextField — flat design, animated border color, focus glow, error shake
- [X] HollowDialog — showHollowDialog() with glassmorphism (BackdropFilter 12px blur, scale entrance)
- [X] HollowTooltip — overlay-based, 400ms delay, fade+slide entrance
- [X] HollowToggle — spring physics thumb, color crossfade track
- [X] HollowToast — slide-up + fade, 3 types (success/error/info), auto-dismiss, replaces SnackBar
- [X] HollowAvatar v2 — gradient background, status dot integration
- [X] StatusDot v2 — breathing pulse glow (3s cycle, BoxShadow)
- [X] PeerCard / ChannelTile — HollowPressable with smooth selection transitions
- [X] ServerStrip icons — HollowPressable, scale-bounce for new icons, selection indicator
- [X] Dialog migration — all 4 dialogs (CreateServer, CreateChannel, Invite, Mnemonic)
- [X] Global cleanup — zero InkWell, IconButton, SnackBar, Tooltip, AlertDialog, FilledButton, TextButton, OutlinedButton remaining
- [X] UI Polish Pass — glassmorphism, startup reveal (2500ms), ambient background, shader warmup, GPU-composited transitions

**Deliverable:** Every interactive element uses custom Hollow widgets. The app feels premium and distinctly Hollow.

### Phase 3: Servers & Channels

**Goal:** Multi-user servers with channels, roles, and MLS encryption.

- [X] Ghost peer fix
- [X] 10s disconnection delay fix
- [X] CRDT integration (`crdts` crate + custom AdminLwwReg) for server state — foundation for all distributed data
- [X] Hybrid Logical Clocks for message ordering
- [X] Sync protocol (state vectors, delta sync)
- [X] Server creation and management — uses CRDTs for distributed state. 🎞️ Animate: server icon appears in ServerStrip with scale-bounce, creation dialog entrance/exit
- [X] Channel system (text channels, categories) — uses CRDTs for channel list. 🎞️ Animate: channel switch crossfade in ChatPane, channel list reorder/add/remove with slide transitions
- [X] Channel messaging — Olm E2EE fan-out per member, JSON envelope (`{"t":"ch","sid":"...","cid":"...","text":"..."}`), separate `channel_messages` SQLCipher table, ChannelChatPane + ChannelMessageBubble UI
- [X] Server settings UI — full tabbed panel (Overview, Channels, Members, Danger Zone), rename server/channels, delete server/channels, server description, replaces chat pane
- [X] Server invite join flow — invite link adds joiner to CRDT member list, joiner receives server state + channel history, bootstrap peer list in invite token
- [X] Server/channel deletion broadcast — deleting a server or channel propagates to all connected members in real-time
- [X] Message deduplication — sender timestamp in envelope, UNIQUE DB constraint, Rust-side dedup before emitting events
- [X] Room gating — reject incoming CRDT state/ops for servers we hollow't explicitly joined, prevent auto-sync of unknown servers to non-members
- [X] Channel/server operation broadcast — channel creation, rename, and all CRDT mutations broadcast reliably to all server members (currently some operations only apply locally)
- [X] Message history sync on reconnection — pull-based catch-up: on peer reconnect, request missed channel messages since last-seen timestamp, peers respond from local DB. Prerequisite for reliable distributed messaging
- [X] Member presence (online/offline status)
  - Cross-reference `connected_peers` with server membership, emit presence events to UI
  - ASOT-style dividers: "Online ------------ 10" / "Offline -------- 5" with accent glow on Online only
  - Per-member sync icon: 12px spinning `refreshCw` on avatar bottom-right (Discord status dot position), replaces green/grey dot when syncing
  - Offline members: 0.5 opacity on whole row
  - Sync progress bar: `total_count` in ChannelSyncBatch envelope, "Syncing 47/120 messages..."
  - User bar: mirror channel pane status (Connecting.../Online), remove warning icon
  - DM peer list: spinning icon when peer discovered but Olm session not yet established (instead of no icon)
  - Remove duplicate connection info from member panel bottom (already in user bar)
  - Animate: member join/leave fade+slide, online->offline transitions, presence dot pulse
- [X] Roles and permissions system — uses CRDTs (LWW-Register with admin priority), UI for role assignment in server settings
- [X] Per-message signing
- [X] MLS group encryption for channels — standalone crypto task, can parallel with UI work
- [X] Offline message queuing (store-and-forward via online peers)
  - Peer B holds messages for offline peer A, delivers on reconnect. Builds on message history sync.
  - MESSAGE ORDERING DECISION: Don't insert by sender timestamp (abusable — clock manipulation, spam injection). Instead: append offline messages at bottom with visual separator ("3 messages from Peer B while offline"). Sender timestamp = display metadata only ("sent at 10:12"), not sort position. Receive order = authoritative sequence for live messages.
  - Animate: queued message shimmer/pending state, delivery confirmation tick

**Deliverable:** A functional group chat platform with servers, channels, roles, MLS encryption, and message sync.

### Phase 3.5: Daily Driver — Chat Features & Identity

**Goal:** Everything that makes Hollow a usable daily chat app. Core features that turn a working prototype into something people want to use every day.

**Identity & Profiles:**
- [X] User profiles (avatar, status message, about me). Display name (global, user-changeable) already exists — acts as the nickname. Peer ID shown under display name as the immutable identity tag. Avatar stored locally for now, synced to peers' encrypted DBs once basic file sharing is built. 🎞️ Animate: profile card pop-up with scale+fade, status change transitions
- [X] Server nicknames — per-server display name override via CRDT LWW-Register per member. Falls back to global display name when unset
- [X] Profile card popup on member click — shows avatar, display name, server nickname, role, peer ID snippet, status. 🎞️ Animate: scale+fade entrance from click origin

**Chat Essentials:**
- [X] Chat Redesign — flat stacked layout.
- [X] Message editing — CRDT op (EditMessage with original message ID + new text), broadcast to server members, update in local DB + UI. Edited messages show "(edited)" indicator. 🎞️ Animate: edit highlight flash
- [X] Multi-Peer Fan-out Sync — SyncCoordinator collects connected peers for 500ms, assigns channels round-robin across all available peers (primary + backup), sends lightweight ChannelSyncProbe (timestamp comparison) before full sync. Channels with no new messages are skipped entirely. Equal load distribution: the more peers online, the lighter the load per peer. On-demand RequestChannelSync (user opens channel) still fans out to all peers for immediacy
- [X] Message deletion — Channel: soft-delete (deleted_at timestamp, row stays in DB for Rat Files evidence preservation). DM: hard delete from local DB only (other peer keeps their copy). UI shows "Message deleted" placeholder. 🎞️ Animate: delete shrink+fade-out
- [X] Reply chains — reference parent message ID in envelope, render with quoted preview above reply. Clicking quote scrolls to original. 🎞️ Animate: reply chain indent slide
- [X] Emoji reactions — PN-Counter CRDT per emoji per message, broadcast to server members. 🎞️ Animate: reaction pop-in with spring bounce, count increment/decrement
- [X] Typing indicators — lightweight ephemeral signal (no persistence, no encryption needed). Broadcast to channel members, auto-expire after 5s. 🎞️ Animate: classic bouncing dots, smooth fade in/out
- [X] Rich text / markdown rendering in messages (bold, italic, code, code blocks, links). Link previews deferred to Phase 6
- [X] Pinned messages — CRDT OR-Set of pinned message IDs per channel, pin/unpin broadcast
- [X] Folder/Category system for channels

**Quality of Life:**
- [X] System Tray — App working in the background)
- [X] Friends system & DM overhaul — Rust: `friends` SQLCipher table (peer_id, display_name, added_at, status). Friend request flow: `FriendRequest` → `FriendAccepted`/`FriendDeclined` wire messages over Olm. Friends list persists offline (not just "who's online"). DM sidebar shows all friends (online/offline) with status dots, sorted online-first. DM history persists and loads from DB regardless of connection status. Unfriend removes from list but keeps DM history. No mutual server required — friends are independent of servers.
- [X] Friends plus other UI improvements
- [X] Notifications — system-level (Windows toast / macOS notification center), configurable per server and per channel (all / mentions only / none)
- [X] Search — local full-text search over decrypted messages in SQLCipher. 🎞️ Animate: search bar expand, results list staggered fade-in
- [X] Keyboard shortcuts (navigate channels, servers, quick-switch, mark as read)
- [X] Only one process instead of two apps being opened at the same time
- [X] Basic file sharing — direct P2P transfer via libp2p, encrypt with MLS/Olm before sending, store locally on receiver. Image/file preview in chat. No erasure coding yet (that's Phase 4). All images auto-converted to lossless WebP on send (25-35% smaller than PNG/JPEG, Flutter decodes natively, Rust `image` crate encodes). "Save as" option converts to user's chosen format (PNG/JPEG/WebP). 🎞️ Animate: upload progress, image shimmer placeholder → fade-in
- [X] Click reply context to scroll to original message

**Deliverable:** Hollow feels like a complete, polished chat app. Ready for daily use with friends.

### Phase 3.75: Security Hardening

**Goal:** Close all known security vulnerabilities before building the distributed storage layer. Every wire message from a peer is untrusted input — a malicious peer with basic programming knowledge can craft raw JSON messages to exploit any unvalidated handler. Fix all findings from the security audit (Mar 16, 2026).

**CRITICAL — privilege escalation & server destruction:**
- [X] **ServerDeleteBroadcast permission check** — currently ANY connected peer can send `ServerDeleteBroadcast { server_id }` and the receiver deletes the server immediately with zero verification. Fix: verify sender is the server Owner before processing. Reject and log all unauthorized attempts.
- [X] **MemberKickBroadcast permission check** — same issue: any peer can force you to leave any server. Fix: verify sender has `KICK_MEMBERS` permission and outranks the local user in the role hierarchy before processing.
- [X] **CRDT operation author verification** — `CrdtOpBroadcast` handler applies incoming ops with no permission checking. The `author` field in `CrdtOp` is self-reported and never verified against the actual sender's peer ID. A regular member can forge `RoleChanged { peer_id: self, role: Owner }` with the real owner's peer ID as author. Fix: (1) verify `op.author == actual_sender_peer_id`, (2) check that the author has permission for the specific operation type (e.g., only admins+ can `RoleChanged`, only owner can `MemberRemoved` for admins), (3) reject and log unauthorized ops.

**HIGH — resource exhaustion & validation:**
- [X] **Message size limit on HollowCodec** — `read_to_end` has no size cap. A peer can send a multi-GB message to cause OOM. Fix: use `io.take(MAX_MESSAGE_SIZE)` before `read_to_end` (e.g., 50MB max).
- [X] **Per-peer rate limiting** — no rate limits on any incoming message type. A peer can flood CRDT ops, messages, reactions, sync requests, file chunks. Fix: token-bucket rate limiter per peer (e.g., 100 messages/sec burst, 20/sec sustained). Excess messages dropped with log warning.
- [X] **Op log compaction** — `op_log: Vec<CrdtOp>` in ServerState grows without bound, serialized to JSON on every persist. Fix: implement periodic compaction — snapshot current state, prune ops older than the snapshot. Keep last N ops (e.g., 1000) for recent sync, discard the rest.
- [X] **Incoming FileHeader size validation** — receiver trusts declared `size` and `chunks` without checking server's max file size setting. Fix: validate `FileHeader.size <= max_file_size_mb` from ServerState settings before accepting. Reject oversized headers.

**MEDIUM — message integrity & access control:**
- [X] **Message deletion ownership check** — `DeleteMessage` handler doesn't verify the sender owns the message (unlike `EditMessage` which does). Any peer can hide any message. Fix: add same ownership check as edit handler (`get_channel_message_sender` / `get_dm_message_is_mine`).
- [X] **Enforce signature verification** — signature verification failures are logged but messages are still processed and stored. Fix: reject messages with invalid signatures. Accept unsigned messages for backward compatibility but mark them as `unverified` in the DB (new column). UI can optionally show unverified indicator.
- [X] **Cross-server channel message validation** — channel messages via Olm are not checked for server membership. A peer with an Olm session can inject messages into any server/channel on the victim. Fix: before storing a channel message, verify (1) server `sid` exists, (2) sender is a member of that server, (3) channel `cid` exists in the server.
- [X] **HLC drift bound** — `witness()` accepts any remote timestamp without bounding clock drift. A peer can send far-future timestamps to permanently win all LWW conflicts. Fix: reject timestamps more than 5 minutes ahead of local wall clock in `witness()`.
- [X] **File path sanitization** — `file_id` and `ext` from remote peers used directly in path construction (`files_dir/{file_id}.{ext}`). Path separators in these fields could write outside intended directory. Fix: sanitize both to alphanumeric + dots only: `chars().filter(|c| c.is_ascii_alphanumeric() || *c == '.').collect()`.
- [X] **Reaction removal ownership check** — `RemoveReaction` handler doesn't verify the sender originally added the reaction. Fix: verify `peer_id` matches sender before removing.

**LOW — defense in depth:**
- [X] **Chat message character limit** — no character limit on message text. A custom client could send a 100MB text message. Fix: enforce 4,000 character limit in both Dart (UI input maxLength) AND Rust receive handlers (reject/truncate messages exceeding limit). Applies to DMs and channel messages. Edit messages same limit.
- [X] **Profile update field size limits** — `ProfileUpdate` accepts unbounded strings for display_name/status/about_me. Fix: truncate on receive (100 chars name, 200 status, 500 about_me).
- [X] **Markdown parser recursion depth** — `_parseInline` in `message_text_parser.dart` is recursive with no depth limit. Deeply nested formatting (5000+ levels) could stack overflow. Fix: add `depth` parameter, cap at 10 levels, treat remainder as plain text.
- [X] **Reaction emoji validation** — modified clients can send arbitrary strings as emojis. Fix: reject emoji strings longer than 10 characters on receive.
- [X] **FileHeader height=0 division guard** — aspect ratio calculation divides by height. Fix: guard `height > 0` before division in `FileAttachmentWidget`.
- [X] **Event dispatch try-catch** — `_dispatch` in `event_provider.dart` not wrapped in try-catch. An exception in any handler could kill the event loop. Fix: wrap in `try { ... } catch (e) { debugPrint(...) }`.
- [X] **Profile card OverlayEntry disposal** — `entry.dispose()` never called after `entry.remove()` in `profile_card_popup.dart`. Fix: add `entry.dispose()` after remove.
- [X] **`getrandom::fill().unwrap()` panic** — extremely rare but would crash the app. Fix: handle error gracefully or use `expect` with descriptive message.

**INFRASTRUCTURE — relay server hardening:**
- [X] **Disable password SSH** — switch to SSH key-only authentication. Password SSH is the #1 attack vector for VPS servers (automated bots try common passwords 24/7). Edit `/etc/ssh/sshd_config`: `PasswordAuthentication no`, `PubkeyAuthentication yes`. Add your public key to `~/.ssh/authorized_keys` first.
- [X] **Firewall rules (UFW)** — allow only: 22/tcp (SSH), 443/tcp (WSS/Nginx), 4001/tcp (libp2p relay), 9001/tcp (internal only, Nginx→relay). Deny all other inbound. Currently unknown what ports are open.
- [X] **Fail2ban** — auto-ban IPs after 5 failed SSH attempts. Blocks brute-force attacks.
- [X] **Relay resource limits** — systemd `LimitNOFILE`, `MemoryMax`, `CPUQuota` on the hollow-relay service. Prevents a misbehaving relay from taking down the entire VPS.

**Deliverable:** All known security vulnerabilities patched. Wire protocol hardened against malicious peers. Relay server hardened against unauthorized access and DoS. Ready for distributed storage (Phase 4) where peers store shards on each other's devices — trust boundaries are enforced.

### Phase 4: Shared Vault — Distributed Storage

**Goal:** The core innovation — distributed file storage across members. Vault handles **files/media only** (not messages/CRDTs). Automatic mode: full replication for <6 members, erasure coding for 6+. DMs stay direct P2P. See section 4 for design details.

- [X] **Reed-Solomon erasure coding engine** — foundation for all distributed storage
  - [X] Add `reed-solomon-erasure` crate to Cargo.toml (pure Rust, no C deps, SIMD-accelerated)
  - [X] New module `vault/erasure.rs`: `encode(data, k, m) -> Vec<Vec<u8>>` (pad, split into k data shards, generate m parity shards), `decode(shards: &mut [Option<Vec<u8>>], k, m) -> Vec<u8>` (reconstruct from any k of n shards)
  - [X] `ShardMetadata` struct: shard_index, content_id, k, m, shard_size, total_data_size — self-describing header prepended to each stored shard
  - [X] Unit tests: encode+decode all shards, decode with exactly k shards (drop each combination of m), fewer than k fails, empty/single-byte/large (1MB+) inputs
  - [X] Benchmark: target >100MB/s encode/decode throughput for 1MB payload at k=10/m=5 — achieved 648 MB/s encode, 1085 MB/s decode

- [X] **Content-addressed storage layer** — local shard storage on disk
  - [X] New module `vault/content_store.rs`
  - [X] `content_id(data) -> String`: SHA-256 hash of encrypted data, hex-encoded (reuses existing `sha2` crate)
  - [X] `shard_key(content_id, shard_index) -> String`: SHA-256(content_id || shard_index as big-endian u16), hex-encoded — used as DHT key and local filename
  - [X] Local shard directory: `~/.hollow/vault/{server_id}/` with shards as `{shard_key}.shard` files
  - [X] CRUD operations: `store_shard()`, `read_shard()`, `delete_shard()`, `list_shards()`, `total_storage_used()` + extras (delete_content, list_content_shards, has_shard, get_shard_record, verify_server_shards, etc.)
  - [X] Integrity verification on read: `data_hash` column (SHA-256 of shard data at store time), verified on read — real tamper/corruption detection
  - [X] New SQLCipher table `vault_shards`: shard_key (PK), server_id, content_id, shard_index, k, m, shard_size, total_data_size, stored_at, last_verified, storage_tier, data_hash — own Connection to messages.db
  - [X] Indexes on (server_id, content_id) and (server_id, storage_tier)
  - [X] `StorageTier` enum (Standard, Low) — 26 unit tests passing

- [X] **Storage pledge system** — CRDT-backed per-member storage commitment
  - [X] New `CrdtPayload::StoragePledgeChanged { peer_id, pledge_bytes }` variant
  - [X] New field `storage_pledges: HashMap<String, AdminLwwReg<u64>>` on ServerState with `#[serde(default)]` (backward-compatible)
  - [X] LWW merge: members can change own pledge, admins can change anyone's (AdminLwwReg priority-based conflict resolution)
  - [X] CRDT server settings: `min_pledge_mb` (uses existing `update_server_setting("min_pledge_mb", "512")`, default 512MB via `min_pledge_mb()` helper)
  - [X] Auto-pledge on server join: new member automatically pledges `min_pledge_mb` (also auto-pledges on server creation for owner)
  - [X] FFI: `set_storage_pledge(server_id, pledge_bytes)`, `get_storage_stats(server_id) -> StorageStatsFfi { total_pledged_bytes, total_used_bytes, my_pledge_bytes, my_used_bytes, member_count, min_pledge_mb }` — lean struct, Dart computes online_members/vault_mode/health from its own providers
  - [X] `NodeCommand::SetStoragePledge` → creates CRDT op, broadcasts, applies locally
  - [X] Permission check in receive handler: self-change or Owner/Admin (same as NicknameChanged)
  - [X] MemberRemoved cleanup: pledge removed when member kicked
  - [X] 3 unit tests: pledge set/read, pledge removed with member, serde backward compat

- [X] **Adaptive k/m engine** — automatic erasure coding parameters based on server size
  - [X] New module `vault/adaptive.rs`
  - [X] `compute_adaptive_params(member_count) -> VaultMode`: returns `FullReplication` if <6, or `ErasureCoding { k, m }` using the adaptive table (6-8: k=3/m=2, 9-15: k=5/m=3, 16-30: k=8/m=4, 31-60: k=10/m=5, 61-150: k=12/m=6, 151-500: k=16/m=8, 500+: k=20/m=10)
  - [X] `apply_tier_multiplier(k, m, tier) -> (k, m)`: standard tier = 1.0x m, low tier = 0.6x m (rounded up, min m=1)
  - [X] `StorageTier` reused from `content_store.rs` (already has Standard/Low variants) — no duplication
  - [X] `determine_tier(mime_type) -> StorageTier`: audio/* → Low, everything else → Standard
  - [X] 15 unit tests: all member count brackets, tier multiplier rounding, edge cases, MIME type classification

- [X] **DHT-based shard placement** — deterministic mapping of shards to peers
  - [X] New module `vault/placement.rs`: XOR distance (SHA-256 normalized), `ShardPlacement` struct, `compute_shard_placements()`, `compute_full_replication_placements()`, `place()` unified entry, `local_placements()`/`remote_placements()` helpers
  - [X] XOR-distance placement: for each shard, hash peer_id with SHA-256 to normalize into 256-bit keyspace, XOR with shard_key, sort ascending, pick closest with capacity
  - [X] Weighted placement: per-member shard cap = ceil(n * peer_pledge / total_pledge), min 1. Members with larger pledges get proportionally more shards
  - [X] Self-placement: `local_placements()` filter identifies shards targeting our peer (no network transfer needed)
  - [X] Deterministic: members sorted alphabetically for tie-breaking, integer-only cap arithmetic (u128 ceiling division), CRDT-replicated pledges
  - [X] New SQLCipher table `vault_placement` in ContentStore: content_id, shard_index, target_peer, server_id, shard_key, stored_at, confirmed. 6 CRUD methods (save/load/confirm/delete/list_server/unconfirmed_count)
  - [X] Full-replication mode: returns all eligible members with shard_index=0
  - [X] 17 unit tests (placement) + 3 DB tests (content_store). 83 total vault tests passing

- [X] **Store protocol** — distributing shards (or full files) to target peers
  - [X] New MessageEnvelope variants: `ShardStore` (header + optional inline data), `ShardChunk` (for >256KB shards), `ShardStoreAck` (confirmation back to sender) — all Olm-encrypted via existing `HollowMessage::Encrypted` wrapper
  - [X] Full-replication mode: same wire messages, shard_index=0, data = full encrypted file
  - [X] Receive handler: verify server membership, check pledge capacity via ServerState + ContentStore, store via content_store, send ShardStoreAck back encrypted
  - [X] Send handler: `NodeCommand::StoreShardOnPeer` — inline data if <=256KB, else ShardStore header + ShardChunk loop. All via send_encrypted_message()
  - [X] Large shard chunking: shards >256KB split into 256KB pieces (reuses CHUNK_SIZE from file_transfer), `PendingShardAssembly` struct for reassembly on receiver
  - [X] 3 NetworkEvent variants: ShardStored, ShardStoreAckReceived, ShardStoreFailed — mirrored in api/network.rs FFI layer

- [X] **Storage tier configuration** — retention policies per data type
  - [X] Retention policies as CRDT settings: `retention_files` (default "365d"), `retention_voice` (default "90d") — uses existing `update_server_setting()`. `parse_retention_days()` + `retention_for_tier()` helpers in adaptive.rs. 5 tests.
  - [X] `determine_tier(mime_type) -> StorageTier` — already done in checkpoint 4 (adaptive.rs)
  - [X] New wire message: `ShardDelete { sid, cid }` MessageEnvelope variant — admin-only, MANAGE_SERVER permission-gated on receive. Receive handler deletes local shards + placements via ContentStore.
  - [X] `NodeCommand::DeleteVaultContent` + handler: permission check, delete local, broadcast ShardDelete to connected members. `delete_vault_content()` FFI function.
  - [X] `NetworkEvent::ShardDeleted` mirrored in api/network.rs FFI layer

- [X] **Retrieve protocol** — fetching shards from peers for reconstruction
  - [X] 5 new MessageEnvelope variants: `ShardRequest` (request shard by key), `ShardResponse` (inline or chunked data + found flag), `ShardResponseChunk` (for >256KB), `ShardProbe` (ask what shards peer has), `ShardProbeResponse` (list of shard indices)
  - [X] ShardRequest receive handler: membership check, ContentStore lookup, inline/chunked response via Olm
  - [X] ShardResponse receive handler: if found + inline → emit ShardReceived; if chunked → PendingShardAssembly; if not found → emit ShardRequestFailed
  - [X] ShardResponseChunk receive handler: assembly tracking, emit ShardReceived when complete
  - [X] ShardProbe receive handler: list_content_shards → ShardProbeResponse back encrypted
  - [X] `NodeCommand::RequestShardFromPeer` + send handler (connection + Olm check)
  - [X] 2 NetworkEvent variants (ShardReceived, ShardRequestFailed) mirrored in api/network.rs FFI

- [X] **File upload pipeline** — encrypt → erasure-code → distribute. 🎞️ Animate: upload progress with encrypt→split→distribute step visualization
  - [X] New module `vault/pipeline.rs` — AES-256-GCM encrypt/decrypt, `VaultManifest` struct, `prepare_upload()` orchestrator, `UploadPlan` struct, `mime_from_ext()` helper. 13 tests.
  - [X] Upload flow (erasure mode): AES encrypt → content_id → erasure-encode with tier-adjusted k/m → compute placements → store local shards → send remote shards via StoreShardOnPeer → broadcast manifest via Olm
  - [X] Upload flow (replication mode): AES encrypt → content_id → single shard to all members → broadcast manifest
  - [X] `VaultManifest` struct with all fields. Replication sentinels: k=0, m=0, shard_count=0.
  - [X] New SQLCipher table `vault_manifests` in ContentStore: content_id (PK), server_id, channel_id, manifest_json, k, m, original_size, storage_tier, created_at, creator_peer_id. 6 CRUD methods + 7 DB tests.
  - [X] FFI: `vault_upload_file(server_id, channel_id, file_path, message_id) -> content_id` — pre-computes AES encryption + content_id, returns content_id immediately to Dart
  - [X] `NodeCommand::VaultUploadFile` + handler: prepare_upload → store local shards → send remote shards → broadcast VaultManifestBroadcast to all connected members
  - [X] `MessageEnvelope::VaultManifestBroadcast` + receive handler: deserialize manifest → save to ContentStore
  - [X] 3 NetworkEvent variants (VaultUploadProgress, VaultUploadComplete, VaultUploadFailed) mirrored in api/network.rs FFI

- [X] **File download pipeline** — locate shards, retrieve k, reconstruct, decrypt. 🎞️ Animate: image load shimmer placeholder → fade-in, download progress reconstruction
  - [X] `reconstruct_file(manifest, packed_shards)` pure function in pipeline.rs — erasure decode + AES decrypt, handles both replication (k=0) and erasure modes. 3 tests.
  - [X] Local vault cache: `~/.hollow/vault_cache/{content_id}.{ext}` — `vault_cache_dir()`, `cache_path()`, `check_cache()`, `write_to_cache()` helpers. 2 tests.
  - [X] `ext_from_filename()` helper for extracting file extension from manifest
  - [X] `NodeCommand::VaultDownloadFile` + handler: load manifest → check cache → collect local shards → reconstruct if enough → write to cache → emit Complete
  - [X] Cache-first retrieval: FFI checks cache synchronously, returns path immediately on hit
  - [X] FFI: `vault_download_file(server_id, content_id)` — cache check + async command dispatch
  - [X] 3 NetworkEvent variants (VaultDownloadProgress, VaultDownloadComplete, VaultDownloadFailed) mirrored in api/network.rs FFI

- [X] **Vault status indicators** — rich UI feedback for vault operations. 🎞️ Animate: progress phases, health pulse
  - [X] Dart: `VaultStatusNotifier` provider (`vault_status_provider.dart`) — VaultServerStatus, VaultFileStatus, VaultHealth enum (healthy/degraded/critical), tracks uploads/downloads/shards per server
  - [X] Event dispatching: 12 new case branches in `event_provider.dart` for all vault NetworkEvent variants (ShardStored, ShardStoreAckReceived, ShardStoreFailed, ShardDeleted, ShardReceived, ShardRequestFailed, VaultUploadProgress/Complete/Failed, VaultDownloadProgress/Complete/Failed)
  - [X] **Channel header vault health dot**: `_VaultHealthIndicator` widget — green/yellow/red `StatusDot` with tooltip, positioned after sync indicator. Pulse animation on non-healthy states.

- [X] **Rebalancing on member join/leave**. 🎞️ Animate: rebalancing progress indicator, shard migration visualization
  - [X] New module `vault/rebalancer.rs`: `detect_departures()`, `scan_under_replicated()`, `compute_repair_plan()`, `compute_migration_plan()`. Structs: UnderReplicatedContent, RepairPlan, ShardMigration. 9 tests.
  - [X] Departure detection: `vault_member_status` SQLCipher table in ContentStore, `update_member_last_seen()`, `load_member_statuses()` CRUD. Updated every 30 min for connected peers.
  - [X] Under-replication scan: `scan_under_replicated()` checks confirmed placements vs online peers. Flags content where available < k.
  - [X] Repair plan: `compute_repair_plan()` identifies missing shards, computes new targets via placement algorithm. Returns None if not enough shards to reconstruct.
  - [X] Migration plan: `compute_migration_plan()` compares old vs new placements when membership changes. Returns list of shard moves.
  - [X] Mode transition: already works by design — `compute_adaptive_params(members.len())` called at upload time, existing content stays at original k/m.
  - [X] `ShardMigrate` MessageEnvelope variant + receive handler (verify membership, store shard).
  - [X] 3 NetworkEvent variants (RebalanceStarted/Progress/Completed) mirrored in api/network.rs FFI.
  - [X] Background retention enforcement: 30-min timer in swarm select loop. Checks each server's manifests against `retention_for_tier()` + `parse_retention_days()`. Deletes expired content + placements + manifests.
  - [X] LRU cache eviction: `evict_cache_if_needed(max_bytes)` in pipeline.rs. Sorts by modified time, deletes oldest until under 80% of limit. Called every 30 min (default 1GB cap).
  - [X] `count_confirmed_shards()` query in ContentStore.
  - [X] 122 total vault tests passing.

- [X] **Storage dashboard UI**. 🎞️ Animate: animated donut/bar charts, pool fill-up animation, health pulse indicators
  - [X] New `lib/src/ui/dialogs/storage_dashboard_dialog.dart` — standalone dialog opened via hard-drive icon in channel sidebar
  - [X] Overview: vault mode label ("Full Replication" / "Erasure Coding k/m"), storage usage bar (used/pledged), member count
  - [X] Your Storage: personal pledge, usage bar, disk space indicator (Windows PowerShell query) with low-space warning (<1GB = red)
  - [X] Member Pledges: aggregate pledge info (only shown for 6+ members, erasure coding active)
  - [X] Retention Policy: files + voice retention display, forward-only disclaimer ("Changes only affect new uploads")
  - [X] Vault Health: StatusDot (green/yellow/red) with health message from VaultStatusNotifier
  - [X] Channel sidebar button: `LucideIcons.hardDrive` icon between invite and settings buttons
  - [X] Rebalance event dispatch: 3 case branches (RebalanceStarted/Progress/Completed) in event_provider.dart
  - [X] Uses existing `getStorageStats()` FFI + `getServerSetting()` for data
  - [X] Dart UI integration for vault upload: wire vault_upload_file() into channel file send flow — deferred to follow-up
  - [X] Sync UI fixes: "Syncing..." indicator timeout (clear after 10s if no progress), CRDT server state changes (rename/delete) refresh Dart UI on SyncCompleted

- [X] Rebalancer

- [ ] **Multi-relay server support** — distribute load across multiple WSS relay servers for scale and redundancy. Moved to Phase 6.75 Scaling section with full checklist.

- [X] **Connection subset management + gossip relay tree** — limit persistent WebRTC connections for large servers, enable tree-spread broadcasting
  - [X] Target: 6-12 WebRTC data channel peers per server (not full mesh). Total across all servers capped at 50 (configurable)
  - [X] Peer scoring: `PeerScore { uptime_ratio, avg_latency_ms, bandwidth_score, shard_overlap }` — computed from data channel ping RTT, connection duration, shared shard count
  - [X] Rotation: every 5 minutes, drop lowest-scoring peer, connect to highest-scoring unconnected peer. Max 1 rotation per cycle for stability
  - [X] Priority connections: always maintain connections to peers holding shards of recently accessed content (shard_overlap weighted heavily)
  - [X] Gossip peer exchange: `HavenMessage::PeerExchange { server_id, peers }` — connected peers share known peer lists for the server via WSS relay
  - [X] Gossip relay tree (broadcast forwarding): when a peer receives data tagged as broadcast (images, files), automatically re-send to its connected WebRTC subset (minus source). Covers 1000+ members in ~3 hops (~600ms), 0 bytes through VPS
  - [X] Broadcast deduplication: each broadcast gets unique ID, peers track recent IDs and drop duplicates (mesh has cycles)
  - [X] TTL/hop limit: 4-5 hops max to prevent infinite propagation (covers millions of peers)
  - [X] Fallback: <6 reachable peers → connect to all available. 30s timeout on gossip delivery falls back to direct FileProbe

- [ ] **Channel-level CRDT sharding** — split monolithic ServerState for scale (defer until ServerState is too large). Moved to Phase 6.75 Scaling section with summary. Full design below for reference:
  - Split into `ServerCoreState` (name, members, roles, settings, pledges, channel_layout — small, synced by all) + per-channel `ChannelState` (pinned_messages, channel-specific settings — synced only by members who access the channel)
  - New SQLCipher table `channel_states`: server_id, channel_id, state_json, updated_at — PRIMARY KEY (server_id, channel_id)
  - Migration: on first load after upgrade, extract channel-specific data from existing ServerState into ChannelState objects
  - Scoped sync: SyncRequest/SyncResponse carry `scope` field ("core" or "channel:{id}") — peers only sync documents they need
  - Lazy loading: channel state loaded from DB on demand (user navigates to channel), not all at once
  - Memory budget: max 20 ChannelState objects in memory, LRU eviction to DB, active (open in UI) channels pinned

**Deliverable:** Server files live distributed across members. No single point of failure. Automatic mode selection — small groups get full sync, larger servers get space-efficient erasure coding. Rich status indicators keep users informed.

### Phase 4.5: Account Recovery & Backup — COMPLETE

**Goal:** Identity recovery and account portability.

- [X] **Security tab in User Settings** — recovery phrase viewer with spoiler toggle (numbered 4x6 grid), copy button, warning text
- [X] **First-launch Welcome dialog** — three paths: Create New Account, Restore from Recovery Phrase (24-word input + validation), Restore from Backup (.hollow file)
- [X] **Passphrase-encrypted backup export/import** — full account backup (identity.key + messages.db + optional vault shards) encrypted with Argon2id KDF + AES-256-GCM. `.hollow` file format with magic header. Wrong passphrase = clear error, brute-force protected by Argon2id cost (64MB memory, ~500ms per attempt)
- [X] **Mnemonic persistence** — 24-word phrase saved to SQLCipher DB on first generation, retrievable anytime from Security tab
- [X] **has_identity() FFI** — checks if identity.key exists on disk, drives Welcome dialog vs normal bootstrap flow
- [ ] Social Recovery (Shamir's Secret Sharing) — deferred, nice-to-have for users who lose backup + mnemonic
- [ ] Device Linking (QR code transfer) — deferred to multi-device/mobile phase

**Deliverable:** Users can recover their full account (identity + all data) via encrypted backup file, or identity-only via 24-word mnemonic. Backup is passphrase-protected with Argon2id brute-force resistance.

### Phase 5A: WebRTC Data Channels — P2P File & Shard Streaming

**Goal:** Establish direct peer-to-peer WebRTC connections for heavy data transfer (files, images, vault shards). WSS relay becomes signaling-only for data payloads. 85-90% of transfers bypass the relay entirely.

**Architecture:** WSS relay exchanges ICE candidates (tiny JSON messages). WebRTC `RTCDataChannel` carries file bytes directly between peers. TURN fallback on the same VPS for the ~10-15% behind symmetric NAT.

**How it works:**
1. Peer A wants to send file to Peer B
2. A creates RTCPeerConnection, generates ICE candidates (local + STUN + TURN)
3. A sends SDP offer + ICE candidates to B via WSS relay (tiny signaling messages)
4. B receives, creates its own RTCPeerConnection, sends SDP answer + ICE candidates back via WSS
5. ICE negotiation completes in ~200ms — direct P2P connection established (or TURN fallback)
6. File bytes flow over RTCDataChannel — zero relay bandwidth for direct connections

**Dependencies:** flutter_webrtc package (Dart), coturn (TURN server on VPS)

---

- [X] **ICE/STUN infrastructure** (TURN deferred to Phase 5B)
  - [X] Add `flutter_webrtc` package — upgraded to v1.4.1 (libwebrtc m144, `getBufferedAmount()` works on Windows)
  - [ ] Deploy coturn (TURN server) on VPS — deferred to Phase 5B (voice/video)
  - [X] STUN: use public Google STUN servers (`stun:stun.l.google.com:19302` + `stun1`)
  - [ ] TURN: own coturn server with time-limited credentials — deferred to Phase 5B
  - [X] ICE configuration in Dart `WebRtcService` (STUN URLs hardcoded)

- [X] **WebRTC signaling via WSS relay**
  - [X] New `HavenMessage` variants: `RtcOffer { sdp, conn_id }`, `RtcAnswer { sdp, conn_id }`, `RtcIceCandidate { candidate, sdp_mid, sdp_mline_index, conn_id }`
  - [X] Route signaling messages via `send_message_to_peer()` on WSS relay
  - [X] Signaling is peer-to-peer targeted (not broadcast)

- [X] **Peer connection manager (Dart-side, not Rust)**
  - [X] `WebRtcService` class in `lib/src/core/services/webrtc_service.dart` — manages RTCPeerConnection per peer
  - [X] `connectToPeer(peerId)` — creates offer, sends via FFI → Rust → WSS relay
  - [X] Connection pooling: reuse existing data channel if already connected
  - [X] Keepalive ping (30s, 0xFE byte) keeps data channel alive. Idle timeout 90s
  - [X] Auto-reconnect on unexpected close (2s delay). Intentional close (idle/manual) → no reconnect
  - [X] Connection state tracking via `WebRtcProvider` (connecting/connected/failed)
  - [X] Glare resolution: polite-peer protocol (lexicographically smaller peer_id drops own offer). ICE candidate queuing for early arrivals
  - [X] Proactive connection: triggers on `SessionEstablished` event

- [X] **Dart-side WebRTC integration**
  - [X] `WebRtcService` wrapping flutter_webrtc — handles RTCPeerConnection lifecycle
  - [X] Listen for signaling messages from Rust (offer/answer/ice) and forward to flutter_webrtc
  - [X] Send local ICE candidates back to Rust for relay forwarding
  - [X] Data channel message handler: receives file chunks, writes to temp file, notifies Rust on completion

- [X] **Rust-side WebRTC scaffolding**
  - [X] `NetworkEvent::WebRtcSignal` + `WebRtcSendFile` events (Rust → Dart)
  - [X] 6 `NodeCommand` variants for Dart → Rust control
  - [X] 6 FFI functions: `webrtcPeerConnected`, `webrtcPeerDisconnected`, `webrtcSendSignal`, `webrtcTransferComplete`, `webrtcSendComplete`, `webrtcTransferFailed`
  - [X] `webrtc_peers: HashSet<String>` tracks peers with active data channels
  - [X] `pending_webrtc_sends` for fallback on failure
  - [X] Incoming RtcOffer/RtcAnswer/RtcIceCandidate → forwarded as WebRtcSignal events

- [X] **File streaming over data channels**
  - [X] Modify `stream_to_peer()` in swarm.rs: if peer in `webrtc_peers` → emit `WebRtcSendFile` event; else WSS relay
  - [X] Chunking: 64KB chunks over RTCDataChannel (same frame format as `ws_stream_transfer.rs`)
  - [X] Progress tracking: Dart-to-Dart via `FileTransferNotifier.onFileProgress()`
  - [X] Both directions: sender reads from disk + chunks, receiver writes to temp file + notifies Rust
  - [X] Graceful fallback: `WebRtcTransferFailed` → sender retries via WSS, receiver sends `FileRequest` for DM fallback
  - [X] Early-arrival handling: `early_file_streams` HashMap stores WebRTC bytes that arrive before FileHeader (Olm/MLS via relay is slower than P2P)
  - [X] Stale transfer cleanup: new first-chunk for existing transfer_id discards old partial file (prevents AES key mismatch on re-request)
  - [X] `getBufferedAmount()` backpressure — prevents SCTP buffer overflow for large files (tested up to 131MB)
  - [X] Sender detects data channel death after send loop → triggers WSS fallback instead of false "Send complete"
  - [X] Download button shows "File is already downloading..." toast during active transfer (prevents duplicate requests)
  - [X] `logFromDart()` FFI function for Dart-side logging to hollow_debug.log (visible in release builds)
  - [X] All 8 `stream_to_peer()` call sites updated (vault shards, DM files, channel images, FileRequest responses)

- [X] **Vault shard distribution over data channels**
  - [X] `VaultUploadFile` handler: shards go via WebRTC where available, WSS fallback
  - [X] `ShardRequest`/`ShardResponse`: shard bytes via data channel, metadata via MLS (existing)
  - [X] No changes to placement algorithm or manifest format — only transport layer

- [ ] **Remove 34 MB default relay cap**
  - [X] Once data channels handle file bytes, relay carries only signaling — 34 MB cap becomes unnecessary
  - [X] Restore configurable file size limit (1–500 MB) for all servers regardless of relay
  - [ ] Keep a sensible default (50 MB?) to prevent abuse, configurable by server owner

- [X] **Connection quality indicators**
  - [X] Show in member panel: radio icon (accent color) for peers with active WebRTC data channel
  - [ ] Peer-to-peer latency measurement via data channel ping (simple round-trip timestamp)
  - [ ] Optional: show estimated transfer speed based on recent data channel throughput

- [X] **TURN credential management** — deferred to Phase 5B
  - [X] hollow-relay generates time-limited TURN credentials on WS auth (HMAC-SHA1, 1-hour TTL)
  - [X] Client refreshes credentials on reconnect
  - [X] coturn validates credentials against same shared secret as hollow-relay

- [ ] **Testing & verification**
  - [X] Test 1: Two peers on same LAN → should use local ICE candidate (fastest)
  - [X] Test 2: Two peers on different networks → should use STUN-mapped direct connection
  - [X] Test 3: Peer behind symmetric NAT (mobile hotspot) → should fall back to WSS relay
  - [X] Test 4: Transfer 100MB file over data channel → verify speed, progress, and completion
  - [X] Test 5: Disconnect mid-transfer → verify WSS relay fallback completes the transfer
  - [ ] Test 6: Vault shard upload with 6 peers → verify shards go P2P, not through relay

**Actual scope (completed Mar 29, 2026):**
- New Dart: ~600 lines (`webrtc_service.dart`, `webrtc_provider.dart`)
- New Rust: ~150 lines (HavenMessage variants, NodeCommand variants, FFI functions, `early_file_streams`)
- Modified: `swarm.rs` (signaling routing, `stream_to_peer()` with WebRTC preference, 8 call sites), `event_provider.dart`, `file_transfer_provider.dart`, `file_attachment_widget.dart`, `channel_chat_pane.dart`, `member_panel.dart`
- Infrastructure: none (STUN uses public Google servers, TURN deferred)
- **Throughput:** ~9 MB/s P2P, tested up to 131MB. flutter_webrtc 1.4.1 (libwebrtc m144)

**Key insight:** This is NOT replacing the WSS relay. The relay stays for signaling, text messages, MLS encrypted ops, CRDT sync, and FileHeaders (which carry AES keys — must stay encrypted via Olm/MLS). WebRTC data channels carry the heavy stuff (encrypted file bytes, shard bytes). The two systems complement each other — relay for reliability + security, WebRTC for bandwidth. WebRTC is faster than the relay, so bytes arrive before metadata — the `early_file_streams` system handles this race.

**Phase 5B (Voice & Video) becomes straightforward:**
- Same RTCPeerConnection already established for data channels
- Just add audio/video media tracks to the existing connection
- SFrame E2EE wraps the media tracks (flutter_webrtc 1.4.1 has DataPacketCryptor support on Windows/Linux)
- TURN server (coturn) needed for voice/video (can't fall back to WSS for real-time media)
- All ICE/STUN signaling infrastructure already working

### Phase 5B: Voice & Video

**Goal:** Real-time calls with E2EE. No central media server — peers forward audio/video to each other using the same WebRTC connections from Phase 5A.

**Dependencies:** flutter_webrtc 1.4.1 already integrated (Phase 5A). RTCPeerConnection already established per peer. Need coturn TURN server for ~10-15% behind symmetric NAT (can't fall back to WSS for real-time media).

**Architecture:** No traditional SFU. Instead, gossip-tree forwarding — each peer receives audio/video and forwards to their connected subset (~3-6 peers). This distributes the load across all participants rather than burdening a single "super peer" or the VPS. Same topology as Phase 6's connection subset management for file broadcast, but applied to real-time media.

**How it scales:**
- **1:1 calls:** Direct P2P (already have the connection from 5A). ~100 kbps audio, ~2.5 Mbps video.
- **Small group (2-5):** Full mesh — everyone connects to everyone. Each peer sends to 4 others. Trivial bandwidth.
- **Medium group (5-20):** Partial mesh via gossip — each peer connected to ~6 others. Audio forwarded through 1-2 hops (~100-200ms latency). Each peer: ~600 kbps in + ~1.8 Mbps out for 6 speakers. Fine for any home connection.
- **Large group (20-1000+):** Same gossip tree, 2-3 hops. Each peer still only handles ~6 connections. 1000 listeners covered in 3 hops with ~150-300ms latency. Perfect for "one speaker addressing an audience" or voice channels.
- **VPS involvement:** Zero for media. Only TURN relay for the ~10-15% who can't P2P.

---

- [X] flutter_webrtc integration (done in Phase 5A)
- [X] **TURN server deployment** *(Mar 30, 2026)*
  - [X] Deploy coturn on VPS — needed for ~10-15% behind symmetric NAT
  - [X] TURN credential management: hollow-relay `/turn-credentials` endpoint generates time-limited HMAC-SHA1 credentials, 1-hour TTL
  - [X] Client refreshes credentials every 50 minutes via `IceConfigProvider` (Dart)
  - [X] TURN + STUN (own coturn + Cloudflare + Google) in ICE config for both `WebRtcService` and `VoiceService`
- [X] **1:1 voice calls** *(Mar 30, 2026)*
  - [X] Separate RTCPeerConnection for voice (cleaner than reusing data channel connection — different lifecycle, no idle timeout)
  - [X] Microphone capture via flutter_webrtc `navigator.mediaDevices.getUserMedia()` with echo cancellation, noise suppression, AGC
  - [X] Mute/unmute toggle
  - [X] SFrame E2EE on audio tracks — `FrameCryptorService` (AES-128-GCM via flutter_webrtc `FrameCryptor`+`KeyProvider`). DM calls: random 32-byte key in Olm-encrypted `CallInvite`. Server voice channels: MLS `export_secret("sframe")` epoch key, auto-rotates on membership change via `MlsEpochChanged` event. Tested cross-internet, `FrameCryptorStateOk` confirmed.
  - [X] Call signaling: `HavenMessage::CallInvite/Accept/Reject/End/Busy` + `CallSdpOffer/SdpAnswer/IceCandidate` via WSS relay
  - [X] Incoming call overlay (slide-down card with accept/decline, 30s auto-reject)
  - [X] Active call bar (floating pill: peer name, MM:SS timer, mute toggle, end call)
  - [X] Call button in DM header (phone icon, disabled when offline/in-call)
  - [X] Glare handling (lexicographic peer ID, polite-peer protocol)
  - [X] Auto-end on peer disconnect, auto-busy when already in call, 30s ring timeout
- [X] **1:1 video calls**
  - [X] Add video track to RTCPeerConnection (pre-filled in initial SDP, no renegotiation needed)
  - [X] Camera capture + camera switch (front/back on mobile)
  - [X] Video mute (camera off via track.enabled, camera light turns off via _releaseCamera)
  - [X] CallVideoView: draggable floating panel with remote video + local PiP
  - [X] Video toggle + camera switch in ActiveCallBar
- [X] **Small group voice (2-5, mesh) — via voice channels**
  - [X] Multiple RTCPeerConnection with audio tracks (one per participant) — `VoiceChannelService`
  - [X] Participant list synced via MLS-encrypted `VoiceChannelJoin/Leave` broadcasts
  - [X] Mesh topology: everyone sends to everyone, glare prevention (lower peer_id offers)
  - [X] Per-peer audio state (mute/deafen) broadcast via MLS-targeted `VoiceChannelAudioState`
- [X] **Gossip-tree forwarding for larger voice channels (5+)**
  - [X] Each peer forwards received audio tracks to their gossip neighbor RTCPeerConnections (minus source) via onTrack + addTrack
  - [X] Audio deduplication via _forwardedSources set (peer ID tracking, prevents loops)
  - [X] Partial mesh audio PCs to gossip neighbors only (6-12 PCs, bounded regardless of participant count)
  - [X] Adaptive with hysteresis: below 6 participants → full mesh, 6+ → gossip, back to mesh at 4
  - [X] Same connection subset as gossip relay tree (peer scoring, rotation, 6-12 peers per server)
  - [X] Voice mode transition: Rust emits VoiceChannelModeChanged, Dart closes/creates audio PCs accordingly
- [X] **Screen sharing**
  - [X] `getDisplayMedia()` for screen/window capture + source picker (Screens/Windows tabs with thumbnails)
  - [X] Share as video track on existing RTCPeerConnection via `replaceTrack()` (no renegotiation)
  - [X] Viewer-only mode (screen share without camera — camera auto-disabled during share)
  - [X] Quality/FPS picker: Resolution — 360p, 480p, 720p, 1080p (default), 1440p, 4K. FPS — 5, 15, 30, 60 (default). Pill-style selector in picker dialog
  - [X] Both-sharing handled (stacked view: remote top, local banner bottom)
  - [X] Rust `CallScreenState` signal + 2s poll for shared window close detection
  - [X] Screen share layout redesign: fullscreen with overlay chat/controls on hover
- [X] **Voice channels (persistent, join/leave)** *(Apr 3, 2026)*
  - [X] `ChannelType` enum (Text/Voice) in CRDT + FFI + Dart. `#[serde(default)]` for backward compat
  - [X] Create channel dialog + server settings quick-add both support Text/Voice toggle
  - [X] Voice channel sidebar tiles: speaker icon, click-to-join, participant avatars+names below
  - [X] Vertical shimmer on connected voice channel (top-to-bottom vs text's left-to-right)
  - [X] Voice control panel at bottom of sidebar (mute/deafen/disconnect)
  - [X] Mute/deafen indicators on participant rows (stacked icons for both)
  - [X] Audio state broadcast to peers via MLS-targeted `VoiceChannelAudioState` signal
  - [X] Joining voice doesn't change chat pane (voice-only channels, no text)
  - [X] Cross-feature guard: blocks join when in 1:1 call
  - [X] 🎞️ Animate: join/leave transitions, voice activity ring pulse around avatar
- [X] **Custom ringtone for incoming calls**
  - [X] User selects a local audio file (mp3/wav/ogg/flac/m4a) in User Settings → Voice & Audio
  - [X] Stored as file path in SQLCipher (not the audio data — just the path)
  - [X] Played in loop during incoming call ring (30s timeout), stops on accept/reject/timeout
  - [X] `audioplayers` package for playback (not WebRTC — local UI audio)
  - [X] Volume slider with live preview (hold slider = plays, release = stops)
  - [X] 30s countdown timer on incoming call card (circular progress + number, turns red at 5s)
  - [X] Cached display info during exit animation (no flash of missing avatar/name on decline)
- [X] **Audio/video device & quality settings**
  - [X] Device selection: mic via `record` package + `sourceId` constraint, speaker via `win32audio` + `Helper.selectAudioOutput()`. Persisted in SQLCipher. Loaded via `_ensureDevicePreferences()` before each call
  - [X] Per-peer speaker volume — `Helper.setVolume()` on remote audio receiver track. Right-click popup on call panel with volume slider (0-200%). Per-call, resets on new call.
  - [X] Audio quality preset: Voice (32 kbps mono), Music (128 kbps stereo), Hi-Fi (256 kbps stereo). SDP munging on Opus fmtp line (`maxaveragebitrate`, `stereo`, `sprop-stereo`). Persisted in SQLCipher. Dropdown in User Settings → Voice & Audio
- [X] **Audio processing**
  - [X] Echo cancellation (built into WebRTC/libwebrtc — enabled via getUserMedia constraints)
  - [X] Noise suppression (built into WebRTC/libwebrtc — enabled via getUserMedia constraints)
  - [X] Voice activity detection (VAD) — local via `record` package amplitude monitoring (same as Settings mic test), remote via getStats `totalAudioEnergy`/`audioLevel` delta. Teal dot indicator on participant rows, fades in/out
- [X] **Call UI (voice channel video/screen share)**
  - [X] Screen sharing in voice channels — separate ScreenShareService (RTCPeerConnection) per direction per peer, `createOfferFromStream()` for shared capture. 4 new Rust MessageEnvelope variants (vc_screen_offer/answer/ice/state) via MLS. Full-bleed layout with chat overlay (360px right, toggleable) + floating controls pill (auto-fade 1s). Bidirectional sharing works. Role field in ICE routing critical for correct PC targeting.
  - [X] Voice channel selectable in sidebar — clicking joined VC sets selectedChannelProvider, auto-select on join, auto-revert to first text channel on leave
  - [X] Voice channel text chat — ChannelChatPane embedded for VC channelId, messages flow through existing channel messaging infrastructure
  - [X] Screen share button in sidebar voice control panel (VoiceChannelPanel)
  - [X] Late joiner screen share — sharer sends screen_state + screen_offer on onRemotePeerJoined, early ICE queue for candidates arriving before service creation
  - [X] Grid view for video participants (1-5 tiles: full/side-by-side/2+1/2x2/3+2, click-to-fullscreen with PiP, mixed mode switcher)
  - [X] Video (camera) in voice channels (renegotiation on existing audio PC, SFrame E2EE, 3 new Rust MessageEnvelope variants)
  - [X] Speaking indicator (teal dot on participant row, fades in/out)
  - [X] Per-peer volume (right-click compact overlay popup, 0-200%)
  - [X] Mute/deafen indicators (stacked icons on participant rows, broadcast via MLS)
  - [X] Join/leave animations (fade in/out on participant rows, AnimatedSize on container)
  - [X] 🎞️ Animate: participant grid rearrange, call connect/disconnect transitions

**Deliverable:** Full voice/video/screen-share with E2EE. No central media server. Gossip-tree forwarding scales to 1000+ participants with zero VPS bandwidth for media.

### Phase 6.25: Security & Optimization Audit

**Goal:** Comprehensive security audit + performance/memory optimization pass. Last security audit was Phase 3.75 (Mar 16) — significant new attack surface since then (WebRTC, voice channels, screen sharing, camera video, gossip relay, SFrame E2EE).

- [X] **Security audit** — scan all code for vulnerabilities (OWASP top 10, WebRTC-specific: OSDP injection, ICE candidate manipulation, MLS group key leaks, SFrame key exposure, relay message forgery, CRDT conflict exploitation)
- [X] **Memory/resource optimization** — Full audit of RTCVideoRenderer, MediaStream, RTCPeerConnection, and FrameCryptor lifecycle across all WebRTC services. 15 leak scenarios identified and fixed:
  - VoiceService: old video stream disposed before replacement in toggleVideo(), awaited renderer dispose in _initLocalRenderer(), old remote stream disposed on renegotiation onTrack, synthetic stream disposed on error path
  - VoiceChannelService: per-peer FrameCryptor cleanup in closePeer(), _forwardedSources pruned per-peer, _prevEnergy VAD stats pruned per-peer
  - CallProvider: _cleanup() now disposes screen share services (prevents GPU leak on call reject/timeout/disconnect), _handleScreenOffer() disposes old incoming before creating new, _renegotiationInProgress reset in cleanup
  - WebRtcService: _pendingIceCandidates cleared in dispose(), app shutdown calls disposeAll() before exit
  - main.dart: added webRtcProvider.disposeAll() to _quitApp() for clean shutdown
- [X] Enable Flutter crash dump logging to `hollow_crash.log` (FlutterError.onError + PlatformDispatcher.onError → file sink)
What was done - Crash logging (lib/main.dart):
  - FlutterError.onError catches widget build/rendering errors
  - PlatformDispatcher.onError catches async/platform errors
  - Both write to hollow_crash.log with timestamps and stack traces
  - 5MB rotation (renames to .old)
  - Respects HOLLOW_DATA_DIR env var (for multi-instance testing)

#### Security Audit Findings (Apr 4, 2026)

Full scan of all code added since Phase 3.75 (WebRTC, voice channels, screen sharing, camera video, gossip relay, SFrame E2EE, TURN, relay). 21 findings: 5 critical, 6 high, 8 medium, 2 low.

**CRITICAL — privilege escalation, eavesdropping, network abuse:**

- [X] **VC membership verification missing** — All 13 voice channel `MessageEnvelope` handlers in `swarm.rs` now check `voice_channel_participants["{sid}:{cid}"].contains(sender_peer_id)` before processing. Non-participants are rejected with `[HOLLOW-SECURITY] BLOCKED` log.

- [X] **VC join/leave not validated** — `VoiceChannelJoin` handler now verifies: (1) sender is a server member via `server_states[sid].members`, (2) channel exists and is `ChannelType::Voice`. Both checks reject + log.

- [X] **Unbounded SDP payload size** — Module-level `const MAX_SDP_SIZE: usize = 64 * 1024` (64 KB). Applied to all 10 SDP-carrying handlers: VC offers/answers (6), DM call offers/answers (2), screen share offers/answers (2), plus RtcOffer/RtcAnswer for data channels. Oversized SDPs rejected + logged.

- [X] **TURN credential endpoint reviewed** — Credentials are time-limited (1 hour TTL) and coturn enforces its own allocation limits per user. Global relay-side rate limiting removed — it would create an artificial bottleneck at scale. The endpoint requires no auth by design: credentials are useless without a valid TURN allocation, and coturn itself is the enforcement point.

- [X] **Gossip PeerExchange injection** — PeerExchange handler now: (1) rejects if peer list > `MAX_PEER_EXCHANGE_SIZE` (50), (2) rejects if sender is not a current gossip neighbor (`overlay.neighbors.contains()`). Both checks reject + log.

**HIGH — resource exhaustion, key exposure, state corruption:**

- [X] **MLS-path VC signal rate limiting** — Added per-peer VC signal sub-rate-limiter (30 burst, 10/sec) via `vc_signal_rate_tokens` HashMap. Match guard on all 13 VC `MessageEnvelope` variants drops excess signals before processing. Passed as parameter to `handle_incoming_request`.

- [X] **SFrame key log sanitization** — `CallInvite` log line now shows only `key_len=N` instead of the raw key. Key itself still transmitted via Olm-encrypted DM (required for call setup). Full HKDF derivation deferred to post-launch (requires Olm session shared secret access from both sides).

- [X] **Call glare SFrame key preserved** — `_handleInvite()` glare path now uses `state.sframeKey` (our own key) instead of the remote peer's `sframeKey`. Prevents key injection during simultaneous call setup.

- [X] **Relay room membership enforced on send** — `ClientMessage::Msg` and `ClientMessage::Direct` handlers in `ws_router.rs` now check `room_entry.peers.contains_key(peer_id)` before broadcasting/forwarding. Non-members get message dropped + warning logged.

- [X] **Gossip broadcast TTL in wire format** — Added `ttl: u8` field to `BroadcastMeta` envelope (`#[serde(default)]` for backward compat). Receive handler caps at `MAX_BROADCAST_TTL` (8), rejects TTL=0, decrements before relaying. Send path includes `DEFAULT_BROADCAST_TTL`.

- [X] **Concurrent renegotiation guard** — Added `_renegotiationInProgress` flag in `CallNotifier`. `_handleSdpOffer()` drops offers during active renegotiation. Flag cleared in `finally` block.

**MEDIUM — validation gaps, resource handling, defense in depth:**

- [X] **SFrame key memory clearing** — `FrameCryptorService.setKey()` and `setSharedKey()` now zero key bytes via `key.fillRange(0, key.length, 0)` in `finally` blocks. Same clearing applied at both `setSframeKey` callsites in `call_provider.dart`.

- [X] **ICE candidate rate limiting (Dart)** — `voice_channel_service.dart` `_handleIce()` now caps pending candidates at 100 per peer. Excess dropped with security log.

- [X] **Remote video track try-catch** — `voice_service.dart` `_handleRemoteVideoTrack()` wrapped in try-catch. On failure, partially-created renderer/stream cleaned up, error logged, call continues (audio-only fallback).

- [X] **Screen share getDisplayMedia track validation** — `screen_share_service.dart` now checks `videoTracks.isEmpty` before accessing `.first`. Empty stream disposed + `StateError` thrown (caught by caller).

- [X] **Relay WebSocket message size limit** — `ws_router.rs` checks `text.len()` / `data.len()` against `MAX_WS_MESSAGE_SIZE` (10 MB) before processing. Oversized messages disconnect the peer.

- [X] **Relay connection limits reviewed** — Hard caps removed. The relay is a lightweight message router (JSON text + CRDTs); heavy media/files go P2P via WebRTC. systemd `MemoryMax` and OS file descriptor limits are the real caps. Artificial hard caps would just block legitimate users before the hardware gives out. Scaling is via multi-relay deployment, not per-relay connection limits.

- [X] **Relay binary frame rate limiting** — Binary WS frames now go through per-peer token-bucket rate limiter (100 burst, 20/sec). Rate-limited frames dropped with warning log.

- [X] **Relay timestamp skew tightened** — Both `ws_router.rs` and `signaling_http.rs` `TIMESTAMP_SKEW_SECS` reduced from 300s (5 min) to 60s (1 min). Nonce cache deferred (low incremental value given the tight window).

**LOW — minor hardening:**

- [X] **Relay room code format validated** — `Join { room }` now enforces alphanumeric + colons + hyphens + underscores + dots via `chars().all()`. Rejects room codes with spaces, slashes, null bytes, or other unexpected characters.

- [X] **SDP logging already safe** — Audit confirmed: Rust-side `hollow_log!` calls only log signal type, peer ID, and SDP size — never SDP content. Dart-side `_dumpSdp()` in `voice_service.dart` filters to safe lines only (`m=`, `a=sendrecv`, `a=ssrc:`, `a=mid:`, `a=msid:`) — never logs `c=` (connection IP) or `a=candidate` (ICE with IP:port). No changes needed.

**Deliverable:** Hardened, leak-free app with documented security posture.

### Phase 6.75: Polish & Launch Prep

**Goal:** Final features, platform testing, and polish pass before distribution.

#### Completed
- [X] Rename HAVEN to HOLLOW
- [X] Add avatars for peers and servers / Server folder organizing
- [X] Change locally someone else's nickname (only for you to see)
- [X] Custom background for the app / Custom color picker chooser
- [X] GIF support for chats and as animated avatars/banners for Profiles
- [X] Fix tooltip freezing on the call buttons (HollowTooltip _dismiss() pattern)
- [X] Fix "Encrypting..." / "Connecting..." labels — simplified to "Offline" / "Encrypted" (Apr 5)
- [X] Fix server join double-click bug — `pending_server_joins` inside `is_new` guard + toast feedback (Apr 6)
- [X] Export/import friend profile data — full backup works, stale file recovery on startup (Apr 6)
- [X] Unread message indicator: floating pill above chat input
- [X] **Chat list rework** — reversed `ListView.builder`, 200-message cap, reply-tap-scroll via GlobalKey (Apr 5)
- [X] **DM sync fix** — 3 critical bugs in offline DM delivery (Apr 5)
- [X] **MLS recovery auto-cleanup** — stale member cleanup, group.delete, Welcome handler fix (Apr 5)
- [X] **Unread UI rework** — red numbered badges on friends bar + home dashboard (Apr 5)
- [X] **Distributed MLS committer** — `is_mls_coordinator()` replaces owner-only gate. Any MLS member can onboard new members (Apr 6)
- [X] **Vault self-healing** — fixed broken repair logic, event-driven rebalance, coordinator-gated, migration wired up. 217 tests (Apr 6)
- [X] **Channel sync fix** — MLS `ChannelProbe` silently failed after reconnection → plaintext `ChannelSyncRequest`. `mergeFromDb()` prevents data loss (Apr 6)

#### DONE — MLS/Encryption Audit (CRITICAL — silent failures after reconnection) — FIXED Apr 6
Audit (Apr 6) found 11 CRITICAL + 4 HIGH risk sites where MLS-encrypted coordination messages silently fail when receiver's MLS epoch is stale after reconnection. Pattern: sender encrypts OK → receiver can't decrypt → message vanishes → operation hangs. **All fixed** with 3 patterns: (A) plaintext HavenMessage for requests/coordination, (B) Olm fallback for responses/sensitive data, (C) plaintext broadcast for voice state.

- [x] **Vault shard operations — Olm fallback added (CRITICAL):**
  - [x] ShardRequest in rebalance handler — already had Olm fallback ✓
  - [x] ShardMigrate in rebalance handler — added Olm fallback
  - [x] ShardResponse in MLS handler (both found/not-found paths) — added Olm fallback
  - [x] ShardProbeResponse in MLS handler — added Olm fallback
- [x] **Sync responses — plaintext requests + Olm fallback responses (CRITICAL):**
  - [x] SyncResp in MLS handler — added Olm fallback
  - [x] ChannelSyncBatch in MLS handler — already had Olm fallback ✓
  - [x] ChannelProbeResp in MLS handler — added Olm fallback + Olm receive handler
  - [x] Post-Welcome ChannelSyncReq — switched to plaintext HavenMessage::ChannelSyncRequest
  - [x] ChannelSyncReq in ChannelProbeResp handler — switched to plaintext HavenMessage::ChannelSyncRequest
  - [x] SyncReq in RoomMembers handler — already had plaintext fallback ✓
- [x] **Voice channel state — plaintext broadcasts + Olm SDP/ICE (HIGH):**
  - [x] VoiceChannelJoin broadcast — MLS primary + plaintext HavenMessage::VoiceChannelJoin fallback
  - [x] VoiceChannelLeave broadcast — MLS primary + plaintext HavenMessage::VoiceChannelLeave fallback
  - [x] Voice SDP/ICE signaling — MLS primary + Olm fallback (IPs are sensitive)
  - [x] Voice audio/screen/camera state — MLS broadcast + plaintext HavenMessage fallback (5 new variants)
  - [x] Voice re-join after reconnect — switched to plaintext HavenMessage::VoiceChannelJoin
  - [x] Olm receive handlers added for 8 voice SDP/ICE MessageEnvelope variants + ChannelProbeResp
  - [x] Plaintext receive handlers added for 5 new HavenMessage voice variants (with security checks)
- [X] Server unread on startup — likely caused by the same MLS sync failure (sync never completes → unread count never recomputed). Should auto-fix when sync responses are fixed above
- [ ] Test distributed MLS committer: owner offline, member B processes new joiner's KeyPackage

#### DONE — Performance: Background CPU optimization (10-20% → near 0%)
DevTools profiling (Apr 6) confirmed: CPU usage in background is caused entirely by Flutter animations running at 60fps even when the app is in system tray. Not WebSocket, not Rust, not reconnection. **Fixed (Apr 6):** Created `SharedTickers` singleton (`shared_tickers.dart`) — one ticker drives all decorative animations. N per-widget AnimationControllers → 1 shared Ticker + ValueNotifiers. All animations auto-pause on window hide/minimize/tray and resume on restore/focus.
- [x] **Pause all repeating animations when window is hidden/tray'd** — `SharedTickers` implements `WidgetsBindingObserver` + `_HollowWindowListener` hooks (`onWindowMinimize`/`onWindowRestore`/`onWindowFocus`) + tray hide/show. Single `pause()`/`resume()` stops all animation tickers instantly
- [x] `ambient_background.dart` — converted to `SharedTickers.ambient` at ~15fps (`Timer.periodic(67ms)` instead of 60fps ticker). Wrapped in `RepaintBoundary`. ConsumerStatefulWidget → ConsumerWidget
- [x] `status_dot.dart` — all pulsing dots share `SharedTickers.pulse` (3s easeInOut ping-pong). N controllers → 1 ValueNotifier. StatefulWidget → StatelessWidget
- [x] `member_panel.dart` — `_SectionDivider` glow sweep uses `SharedTickers.shimmer` with local ping-pong + easeInOut transform. StatefulWidget → StatelessWidget, removed AnimationController + CurvedAnimation
- [x] `selection_shimmer.dart` — uses `SharedTickers.shimmer` (4s linear). StatefulWidget → StatelessWidget
- [x] `home_dashboard.dart` — `_ShimmerDivider` uses `SharedTickers.shimmer`. StatefulWidget → StatelessWidget
- [x] `chat_pane.dart` — `TypingDots` uses `SharedTickers.typingDots` (1.2s). StatefulWidget → StatelessWidget
- [x] `chat_pane.dart` + `channel_chat_pane.dart` — call overlay shimmer already uses SelectionShimmer (now shared). SpinningRefreshIcon uses RotationTransition (GPU-composited, negligible cost)

#### TODO — Features

- [X] Fix the camera turning on when calling with video call
- [X] Add pill for camera/screen switching in DMs, just like it is in voice channels
- [X] Copying messages / Paste + drag-and-drop images into the input bar
  - [x] Message text selection + copy (SelectionArea wrapper, right-click "Copy" context menu)
  - [X] Paste images from clipboard (Ctrl+V detect image data, stage as attachment)
  - [x] Attachment preview in input bar (thumbnail/filename card above input, X to remove)
  - [x] Text + file together (type message AND attach file in same send)
  - [X] Drag-and-drop files onto chat (desktop_drop package, drop zone on chat pane)
  - [ ] Multiple files per message (model change: FileAttachment? → List — touches Rust/DB/wire protocol)
- [X] **Video preview in chats — DONE (Apr 7, 2026).** Inline preview-in-place player with auto-fading control bar (play/pause + scrub + timestamps + fullscreen) and a fullscreen viewer overlay. Tested working in DMs and <6 member servers; vault path implemented but not user-tested (no 6+ peer testbed).
  - [X] **ffmpeg distribution** — Bundled BtbN/FFmpeg-Builds LGPL static binary at `vendor/ffmpeg/ffmpeg-win-x64.exe` (~164MB unstripped), fetched via `scripts/fetch_ffmpeg.ps1` (gitignored). Bundled into Windows builds via `windows/CMakeLists.txt` install rule + `windows/runner/CMakeLists.txt` POST_BUILD copy for `flutter run` dev mode. macOS/Linux fetch scripts + bundling deferred until those builds happen. **Binary minification deferred to Phase 7** — see Phase 7 line "Strip / minimize bundled ffmpeg binary" entry. Establishes the first native-binary-bundling pattern in Hollow.
  - [X] **`VideoThumbnailService` (Dart)** — `lib/src/core/services/video_thumbnail_service.dart`. `findFfmpegBinary()` locates the binary next to `Platform.resolvedExecutable`. `extractVideoThumbnail({videoPath, targetHeight=480})` invokes ffmpeg via `Process.run` with `-vf scale=-2:480 -c:v libwebp -lossless 1 -compression_level 6` → returns `VideoThumbnailResult(webpBytes, durationMs, sourceWidth, sourceHeight)`. 10s timeout. Stderr regex parser extracts `Duration:` and the first `Stream Video: WxH` for source dimensions. Never throws — all failures return null. `ensureCachedThumb(videoPath)` writes `{file_id}.thumb.webp` next to the source video for lazy receiver-side extraction.
  - [X] **WebP thumbnails (not JPEG)** — chosen because Hollow's existing image pipeline already converts everything to lossless WebP via `image_convert.rs`. WebP at the source bypasses the Rust re-encoding (`should_convert_to_webp` only triggers for png/jpg/bmp/tiff) and matches the canonical image format. Half the size of JPEG at the same quality.
  - [X] **Wire format: `vthumb: Option<VideoThumbRef>` on `MessageEnvelope::FileHeader`.** Struct fields: `cid` (vault content_id), `ext` (mp4/webm/mkv), `name` (original filename for Save As), `size` (bytes), `dur_ms`. `#[serde(default, skip_serializing_if = "Option::is_none")]` for backward compat. New `video_thumb_json TEXT` column on the `files` SQLCipher table with `ALTER TABLE files ADD COLUMN` migration wrapped in `unwrap_or(())`. Threaded through `NodeCommand::SendFile`, `NetworkEvent::FileHeaderReceived`, the FFI surface in `api/network.rs`, the Dart `FileAttachment` model, and `event_provider.dart:535`. Five `MessageEnvelope::FileHeader` construction sites updated, two destructure sites updated. Five `insert_file_metadata` callers updated. Six `FileHeaderReceived` event emit sites updated. Four `SyncFileMetaItem` initializations updated.
  - [X] **`override_width` / `override_height` parameters on `send_file` FFI** — Phase 6.75 video preview also needed source video dimensions in the FileHeader so receivers render the bubble at the correct aspect ratio before downloading the video itself. The existing `image_convert::get_image_dimensions` only handles raster images. Solution: Dart pre-extracts video dimensions via `VideoThumbnailService.extractVideoThumbnail` before `send_file`, passes the source video's `width`/`height` through new FFI parameters, Rust uses them for non-image files in the FileHeader. Same wire format as images — `attachment.width`/`height` is the single source of truth on the receiver.
  - [X] **`_sendVaultVideo` pipeline (Dart)** — `lib/src/core/providers/file_transfer_provider.dart`. Order: (1) extract thumbnail to get content + dimensions, (2) `vaultUploadFile()` first to get the vault `content_id` (sync return, fast — bounded by file-read + AES, ~200ms for 50MB), (3) write thumbnail to temp `.webp`, (4) `network_api.sendFile()` with the thumbnail path + `vthumb` linking field + source video dimensions in `overrideWidth`/`overrideHeight`. Order matters: vault upload must finish first because content_id is non-deterministic (random AES key/nonce per call). Vault upload does NOT trigger a competing FileHeader broadcast — only the thumbnail's sendFile emits one, so receivers see exactly one bubble per video.
  - [X] **`VideoMessageBubble` widget** — `lib/src/ui/chat/video_message_bubble.dart`. Three internal states: `thumbnail` (image + center play button + duration/size badges) → `preparing` (vault download in flight, dimmed scrim + spinner + phase text) → `playing` (inline `VideoPlayer` at the same dimensions as the thumbnail, preview-in-place). Auto-fading bottom control bar (play/pause + `mm:ss / mm:ss` timestamp + scrub + fullscreen toggle) shows on hover, fades 1s after mouse leaves, stays visible while paused. Click anywhere on video → toggle play/pause. Click fullscreen icon → opens `_FullscreenVideoView` via `showHollowDialog` with its own controller and the same control bar. `currentlyPlayingVideoProvider: StateProvider<String?>` enforces single-video-at-a-time. `VisibilityDetector` auto-pauses when scrolled out (>50% off-screen).
  - [X] **DM/<6 server videos** — same `VideoMessageBubble`, but `videoThumb == null` and `attachment.diskPath` points at the actual video file. Lazy thumbnail extraction in `VideoMessageBubble.initState`: if no `.thumb.webp` cache exists yet, runs `ensureCachedThumb` in the background and `setState`s when done. Both sender and receiver extract their own local thumbnail from the bytes they have — zero network round-trip, zero wire format changes.
  - [X] **Sender `FileCompleted` emit fix** — the sender's optimistic `addFileMessage` builds a `FileAttachment` without dimensions; the receive path emits `NetworkEvent::FileCompleted` after `mark_file_complete` which triggers `_reloadChatForFile` → DB reload → fresh attachment with correct dimensions. The send path was missing this emit — added at `swarm.rs:4805` so the sender's UI follows the same DB-reload pattern as receivers. Fixes a latent bug where the sender's optimistic message was also missing `videoThumb`/`mimeType`/etc.
  - [X] **Save button** — extended `channel_chat_pane.dart` `onDownload` callback. New branch: if `attachment.videoThumb != null`, call `_vaultDownloadAndSaveVideo` which uses `videoThumb.cid` directly (instead of `getContentIdForFile(attachment.fileId)` which would return the thumbnail's id, not the video's), polls `fileTransferProvider` for the cache path with 60s timeout, then opens Save As with `videoThumb.name`/`ext` so the user gets `cat_glasses.mp4` not `{messageId}.webp`. Existing `_vaultDownloadAndSave` flow preserved for non-video vault files. DMs unchanged — they always use full-replication direct P2P, never have `videoThumb`.
  - [X] **Bubble dimensions** — `_resolveDisplaySize()` reads `widget.attachment.width`/`height` directly (single source of truth via FileHeader), max 320×260, falls back to 16:9 if dimensions unknown. Same code path as images.
  - [X] **Packages** — `fvp ^0.35.2` (drop-in `video_player` backend for Windows/Linux desktop, registered via `fvp.registerWith()` in `main.dart` after `RustLib.init()`), `video_player ^2.11.1`, `visibility_detector ^0.4.0+2`, `path ^1.9.0` (was already a transitive dep, promoted to direct).
  - [X] **Backward compat** — `#[serde(default)]` on `vthumb` means old clients ignore the field. `ALTER TABLE ... ADD COLUMN` migration in `unwrap_or(())` is safe to re-run. New videos sent before this build have `width: NULL, height: NULL` in the DB and render with default 16:9 — they'd need to be re-sent to get correct dimensions.
  - [X] **Test plan results** — (a) Send MP4 in DM → plays inline directly, dimensions correct on both sender and receiver, no vault. (b) Send MP4 in <6 server → same as DM, full P2P. (c) Inline player auto-fade controls + fullscreen + scrub + timestamps all working. (d) Thumbnails extracted lazily for old DM/server videos on first build. (e) **6+ server vault path NOT user-tested** — no 6-peer testbed available, code path implemented but unverified end-to-end.
  - **CRITICAL LESSONS:**
    - **Sender UI relies on the FileCompleted event to reload from DB.** Optimistic `addFileMessage` builds a stub `FileAttachment` with only `fileName`/`size`/`isComplete`/`diskPath`. Without a `FileCompleted` emit on the sender side, the stub never gets replaced by the real DB row → any field added to FileHeader (width/height/videoThumb/mime/etc.) won't show up on the sender side until they reload the chat manually. Always emit `FileCompleted` from BOTH the receive and send paths.
    - **`Resolve-Path` errors on missing paths.** Use `[System.IO.Path]::GetFullPath` for path normalization in PowerShell scripts when the target directory doesn't exist yet (like a fetch script that creates the destination).
    - **`flutter_rust_bridge` `dataSource` field uses `Uri.file().toString()` on Windows.** Don't try to recover the original file path from `controller.dataSource.replaceFirst('file://', '')` — that leaves a leading `/C:/...`. Stash the original path as state when initializing the controller.
    - **`Material` ancestor required in `showHollowDialog` overlays for `Text` widgets.** Otherwise text renders with the yellow debug double-underline. Wrap dialog content in `Material(type: MaterialType.transparency)`.
    - **`ffmpeg-next` Rust crate is brutal on Windows.** vcpkg ffmpeg port is famously broken. Bundled binary + `Process.run` is the right call for desktop. Mobile (when we get there) will need a different path — `video_thumbnail` Dart package for Android/iOS via native AVAssetImageGenerator/MediaMetadataRetriever, since iOS/Android sandboxes block executing arbitrary binaries.
- [X] Link previews (URL metadata fetch + embed card rendering)
- [X] Image quality tiers (user-configurable WebP Q: Lossless / Balanced 50% default / Small 30%, ~95% bandwidth + storage savings)
- [X] **Cryptographic message verification ("The RAT Files")** — prove message authenticity, defeat fake screenshots
  - [x] Message Info panel: shieldCheck icon in hover toolbar + right-click opens RAT Files dialog — sender peer ID, timestamp, Ed25519 signature, public key fingerprint, SIGNED/UNSIGNED badge
  - [x] "Export Proof" button: copies JSON proof with message text, timestamp, context (server/channel/DM), signature, sender public key, canonical payload, verification instructions — anyone can verify with standard Ed25519
  - [x] In-app proof verifier: "Verify a Proof" section in Security tab — paste JSON or import .json file, runs Ed25519 verification via Rust FFI, shows VERIFIED/INVALID with message text, sender, context, timestamp. Replaces standalone CLI/web tool
  - [X] Fix UI bug in Message Proof for new messages + edits — canonical edit/delete signing payload (was ad-hoc `"edit:..."` / `"delete:..."`), `edit_*_message` main-row sig/pk overwrite, sig/pk threaded through all receive/send/edit events + providers, Proof dialog uses `editedAt` timestamp for edited messages, optimistic-send timestamp now hydrated from Rust's signed value (fixes VM timer-drift verification failures).
- [X] Favourites for the Friends strip instead of the "dump-all-friends" approach
- [X] Use the same screen sharing for voice channels as in DMs (show your own screen; DONE - and we put the max bitrate capping)
- [X] Proper profiling for the high RAM usage during the call with screen sharing and afterwards
- [X] Full images metadata strip for WebP/GIF
- [X] Add floating pill about sender/receiver screen share quality
- [X] Shows the audio channel as the default selection on the server (should select first text channel)
- [X] Fix bugged dialog for "Set Passphrase" (double press needed somehow) / Data export system (messages, files, identity — verifiable with Ed25519 signatures)
- [X] Fix the crash error (reflect to second_debug.log)
- [X] Server template export/import (share server structures)
  - [ ] Roles copying - deferred to checkbox later
- [X] Add ability to choose your camera device in User Settings
  - [X] Add a package for camera device selection + test
- [X] Download manager UI — popup card showing manually-saved files (Save button) with thumbnails + save paths + click-to-reveal in Explorer (with Win32 foreground lock bypass), plus active shard rebalance status
- [x] **Archive tab — personal data viewer + signed `.hollow-archive` export/import (part of "The RAT Files" protocol)**
  - **Philosophy:** SQLCipher DB is fully encrypted — the only way to see your own historical data (left servers, DMs with ex-friends, kicked channels, deleted messages you still have copies of) is through an in-app viewer. Combined with a portable, cryptographically-verifiable export format, this turns "your data is yours" from a slogan into a testable property. No PDF/EPUB/TXT support — those formats can be trivially edited, and shipping "signed PDF" would be security theater that undermines Hollow's reputation for cryptographic seriousness. **One format, one truth.**
  - [x] **`.hollow-archive` format** — zip-based custom bundle (Rust backend: `archive/exporter.rs`, `archive/loader.rs`, `archive/types.rs`)
    - [x] `manifest.json` — archive metadata (type: dm/channel, participants, message count, export timestamp, file mode used)
    - [x] `messages/{message_id}.json` — per-message JSON files with full metadata (sender, timestamp, current text, `hidden_at` marker if soft-deleted, reactions, reply refs, file_id ref). Include hidden messages too — they're forensic evidence, not absent data.
    - [x] `edits/{message_id}.json` — full `message_edits` table rows per message (old_text, new_text, edited_at, per-edit signature). Serializes the entire edit chain so the POV viewer can show "edited 3 times — click to see history" with each version independently verifiable.
    - [x] `deletions/{message_id}.json` — full `message_deletions` table rows (deleted_text, deleted_at, per-delete signature). Each deletion is itself a signed event ("Alice signed a delete op for message X at time T"), not just a tombstone marker.
    - [x] `reaction_removals/{message_id}.json` — reaction removal evidence (emoji, peer_id, removed_at, signature).
    - [x] `pubkeys.json` — sender public keys for offline verification. Per-message Ed25519 signatures preserved from the DB (same canonical payload as Message Proof dialog).
    - [x] `files/{file_id}.meta.json` + `files/{file_id}.{ext}` — attached media honoring the three file modes, with SHA-256 hashes for included files.
    - [x] `archive_signature.json` — **archive-level Ed25519 signature** signed by the exporter over a deterministic SHA-256 hash of manifest + all message JSONs + edit/deletion/removal hashes + file hashes. Turns the archive from "bag of signed messages" into "a snapshot I, peer X, attest to as my complete record." Catches selective omission without requiring a neutral god-view.
  - [x] **File embedding modes** (chosen at export time)
    - [x] Full — every file referenced by the conversation is embedded (biggest, best fidelity, fully offline-usable)
    - [x] Images only — embed images, skip videos and large files (compromise — conversation reads visually but archive stays small)
    - [x] Placeholder — no files embedded, just references with original filenames/sizes/hashes (smallest — viewer shows grey placeholder cards with metadata)
  - [x] **`.hollow-archive` loader** — Rust-side (`archive/loader.rs`) takes a zip, validates manifest, verifies every per-message signature (canonical payload reconstruction with `edited_at` parity), verifies the archive-level signature, returns read-only `LoadedArchive` data. Tolerant of malformed entries (skips + logs). Zero DB writes.
  - [x] **FFI API** — 4 `#[frb]` functions exposed to Dart: `export_dm_archive`, `export_channel_archive`, `verify_archive`, `load_archive`. FFI-safe result structs for all archive data.
  - [x] **DB query methods for archive** — `load_all_dm_messages` (including hidden), `load_all_channel_messages` (including hidden), `load_edits_for_messages`, `load_deletions_for_messages`, `load_reaction_removals_for_messages` on `MessageStore`.
  - [x] **Archive tab UI** — new top-level tab with icon on server strip / bottom bar (left of Downloads icon), replaces main screen when active (like Home tab today). Shell integration done: `archiveTabOpenProvider`, fade animation, Home deselects when archive is open.
    - [x] **Sub-tab 1: "My Data"** — two inner tabs (DMs | Channels) in left panel (~280px) + read-only chat viewer in right panel (expanded)
      - [x] **DMs tab:** all peers you've ever messaged (including ex-friends), sorted by message count. Search bar at top. Each entry: avatar, display name (or truncated peer ID), message count badge.
      - [x] **Channels tab:** grouped by server (collapsible headers with server name). Under each server: channels with message history. Each entry: channel name, message count badge.
      - [x] **Chat viewer:** reuses `MessageBubble`/`ChannelMessageBubble` with read-only data source. Shows ALL messages including soft-deleted (greyed out with AnimatedOpacity 0.4, "Deleted at T" banner). Edited messages show "(edited)" indicator. Hover actions: Save file, Copy text, Copy image, Message Proof dialog (shield icon). `SelectionArea` for text selection. `NotificationListener` for scroll-dismiss of hover overlays. No input bar.
      - [x] Export button in chat viewer header → export dialog (file mode picker + save + sign)
    - [x] **Sub-tab 2: "Imported Archives"** — archive list in left panel + POV viewer in right panel
      - [x] Archive list: loaded `.hollow-archive` files with verification badges (green shield / yellow warning / red X). "Load Archive" button + drag-and-drop zone (`desktop_drop` DropTarget). Remove button (X) per entry.
      - [x] **Persisted archive paths** — archive file paths saved to `app_settings` DB via `ImportedArchivePathsNotifier`. On startup, filters out paths that no longer exist on disk. Remove entry clears selection.
      - [x] POV viewer: same chat renderer as "My Data" but with **verification banner** pinned at top ("Verified — N messages signed by original senders, exported on [date]" green / warning yellow / invalid red). Hover actions: Save, Copy, Copy Image, Message Proof. SelectionArea + scroll-dismiss.
      - [X] **Imported archive file viewing** — files/images embedded in the `.hollow-archive` are unpacked to `filesDir` temp directory by the loader. The POV viewer's `FileAttachmentWidget` must resolve `diskPath` from the extracted temp dir (not `~/.hollow/files/`) so the viewer can open/display images, videos, and other files from the archive. "My Data" tab uses the real `diskPath` from the live DB (already works).
    - [x] **Post-launch enhancements (shipped Apr 12 2026):**
      - [x] Export all server channels — `ArchiveTarget::Server` + `export_server_archive()` FFI + multi-channel manifest with `channels[]` + per-message `channel_id`. Export button on server group headers in conversation list. Imported Archives viewer handles `archive_type == "server"`.
      - [x] Jump-to-date — calendar icon in archive header, `showDatePicker` themed with Hollow colors, binary-search + `ScrollablePositionedList.scrollTo()` for precise navigation
      - [x] Peer filter — filter icon in channel archive headers, `PopupMenuButton` dropdown listing unique senders, message list filters by selected sender, reply lookups use full unfiltered list
      - [x] Search within archive — collapsible search bar below header, case-insensitive substring match, match count + up/down navigation with `ScrollablePositionedList.scrollTo()`, current match highlight
  - [x] **Export dialog** — accessible from archive message viewer header (export button) in "My Data" tab
    - [x] Choose file mode (full/images_only/placeholder) — three radio-style cards with icons and descriptions
    - [x] Choose save path — `FilePicker.platform.saveFile` filtered to `.hollow-archive` extension
    - [x] Archive is generated by hashing the DB slice + signing with the exporter's Ed25519 key
    - [x] Success toast: "Archive exported — {size}" + dialog auto-closes
  - [ ] **Web viewer — `archive.hollow.app` (deferred but architecturally committed)**
    - [ ] Flutter Web build of the same POV viewer code (~95% shared with the desktop app — `ChannelMessageBubble`, `MessageBubble`, theme system, proof dialog all reusable)
    - [ ] Pure client-side: drag-and-drop a `.hollow-archive` file → parse in browser → verify signatures in browser → render. **No data ever leaves the user's machine.** No Rust backend required — Ed25519 verification via `cryptography` / `@noble/ed25519` WASM or pure JS
    - [ ] Static hosting (Cloudflare Pages / Netlify / GitHub Pages) — no server state, no database, no telemetry
    - [ ] Open-source in a separate public repo so anyone can audit the verification code and self-host mirrors
    - [ ] Killer use case: journalists, researchers, legal contexts — "here's a link to a `.hollow-archive` and a URL where you can verify it without installing anything"
  - [X] **UI framing rules** — always use the shield icon + accent color for archive badges. Verification status is shown at the top of every imported archive. "Exported by" line with full peer_id always visible. Never hide cryptographic provenance behind "advanced" menus — it's the point of the feature.
  - [X] **Edit/delete propagation model.** Edits and deletes are NOT CRDT-synced — they travel as dedicated `MessageEnvelope::EditMessage` / `DeleteMessage` envelopes through the normal encrypted message channel (Olm for DMs, MLS for channels). Both sender and receiver call `edit_dm_message()`/`edit_channel_message()` on their respective DBs, which means the `message_edits` and `message_deletions` rows — *with signatures* — are written on both sides. Two peers' archives of the same DM should agree on all edit/delete state. Security: only the original sender can edit/delete their own message (verified server-side at `swarm.rs:8237` and `:8293` — rejected otherwise). Archive-level signature still matters, but for catching **selective omission at export time** (exporter chose to include only a slice), not for smoothing over propagation gaps.
  - [X] **POV viewer edit/delete rendering** — hovering a message with `message_edits` rows shows "Edited N times ⟶ view history" → expands a timeline of every prior version with its own timestamp + signature. Messages with a `hidden_at` timestamp render as greyed-out bubbles with a "deleted at T" banner and the original text still visible (sourced from `message_deletions`). Both states are independently verifiable via the same Message Proof dialog used today.
  - [X] **Follow-up cleanup (not part of this feature):** `hide_dm_message()` / `hide_channel_message()` in `storage/messages.rs` don't cascade `hidden_at` to the `files` table, so deleted messages' file references stay queryable. File this as a separate fix — not an archive blocker, but worth noting. The archive exporter should handle file references on hidden messages gracefully regardless.
  - [X] **DONE: Preserve original message signature through edits.** Added `prev_signature`/`prev_public_key`/`prev_timestamp` columns to `message_edits` table. `edit_channel_message()`/`edit_dm_message()` now capture the current main-row signature/public_key/timestamp before overwriting, storing them in the edit row. Threaded through the entire stack: `load_edits_for_messages()` → `StoredMessageEdit` FFI → `ArchiveEdit`/`ArchiveEditFfi` → Dart `ArchiveEditEntry` → `EditHistoryIndicator` (uses `prevSignature`/`prevPublicKey`/`prevTimestampMs` at index 0 to verify original message text). Old DB rows and old `.hollow-archive` files gracefully degrade (NULL prev_* → grey shield). New edits get full signature chain provenance.

- [x] **FIXED:** "Verify A Proof" in Security tab was trusting the embedded `canonical_payload` from the JSON instead of reconstructing it from the individual fields. Changing message text, timestamp, context, etc. in the pasted proof JSON wouldn't affect verification. Fix: reconstruct `hollow-msg:{type}:{ctx}:{sender}:{ts}:{text}` from the JSON fields and compare against the embedded canonical payload before verifying the signature. Payload mismatch → "tampered" error.
- [X] Fix the icon outline size on the server strip (Gear is bigger than Downloads/Archive) — Settings icon padding was `HollowSpacing.sm` (8px) vs `xs` (4px) for Archive/Downloads in `bottom_bar.dart`. Fixed to `xs`.
- [X] Count the chat messages sizes in the Server Storage inside servers — Added `total_message_storage_for_server()` (`SUM(LENGTH(text))` on `channel_messages`), wired into `get_storage_stats()` for both `total_used_bytes` and `my_used_bytes`.
- [X] Add "disable animations" toggle in User Settings — `disableAnimationsProvider` + `HollowDurations` mutable getters + `SharedTickers.disabled` flag. Toggle in System tab LAYOUT section. Covers core Hollow components, shell transitions, popups, notifications, channel sidebar.
- [X] Audio file preview (listening inside the app; same as already working video previews)
- [X] Look into the logic of GIFs in the chat/profile (comparison; fix the "speedups" bug if present)
- [X] Add .gif for Save / Conversion of GIF to animated WebP
- [X] Evidence Recovery Pool (cooperative shard gathering for ex-members of dead servers) — server-wide invite-link-based pool via WSS relay rooms + WSS binary shard transfer. Archive tab → Vault Files tab shows shard status per file (X/k badges). `.hollow-shards` export/import for offline fallback. Recovery Pool dashboard with progress ring, member tracking, live status. Coordinator (lowest peer_id) computes transfer plans. Reed-Solomon reconstruction when k shards gathered. Join validation with 10s timeout, pending state prevents premature dashboard switch.
  - [X] Phase A: Vault Files tab in Archive — `get_vault_file_statuses` FFI, shard count badges (green/yellow/red), grouped by type, sorted by date
  - [X] Phase B: Shard export/import — `.hollow-shards` ZIP bundle (manifests + packed shards), export/import dialogs with results summary
  - [X] Phase C: Recovery Pool backend — `recovery_pool.rs` coordinator module, HavenMessage variants (Hello/Welcome/ManifestSync/TransferPlan/ShardReceived/Status/Stop), NodeCommand handlers, WSS room join/leave, inventory exchange handshake, PeerJoined/PeerLeft tracking, 9 NetworkEvent variants + FFI functions
  - [X] Phase D: Recovery Pool UI — `recovery_pool_provider.dart`, initiate/join dialogs (with 10s join timeout validation + pending state), dashboard (progress ring, stats, members, invite link), Leave/Stop buttons, event dispatch wiring
  - [X] Phase E: Shard transfer execution — coordinator election (lowest peer_id) after handshake, transfer plan broadcast, `ws_stream_send` for shard bytes via WSS binary frames, `pending_shard_streams` + `pending_vault_downloads` registration for auto-reconstruction, `reconstruct_file()` + `write_to_cache()` via existing `handle_completed_stream`, `VaultDownloadComplete` → `RecoveryPoolFileRecovered` bridge in Dart
- [X] **swarm.rs modularization refactor** — split the 13,259-line monolith into focused modules (final: 6,234 lines; envelope dispatch fully extracted)
  - [~] ~~Create `SwarmContext` struct to hold the ~40 shared state variables~~ — **won't do**. Rust's borrow checker rejects this pattern: `ctx.server_states.get(...)` borrows ctx immutably while crypto helpers need `&mut ctx.olm` / `&mut ctx.mls` simultaneously (~16-18 call sites). Working around it would require restructuring control flow, risking logic drift bugs in the CRDT/MLS/WebRTC state machines. Individual field params are fine — the slight parameter verbosity is the correct trade-off for this codebase.
  - [X] Extract `types.rs` (1,797 lines) — `NetworkEvent`, `NodeCommand`, `HavenMessage`, `MessageEnvelope`, all helper structs, constants, `dm_room_code()`
  - [X] Extract `crypto_handler.rs` (345 lines) — signing helpers, Olm/MLS encryption, key exchange, coordinator election, `peer_is_reachable`, `ws_room_for_peer`, `send_message_to_peer`
  - [X] Extract `sync_handler.rs` (1,357 lines) — CRDT ops, server/channel CRUD, member management, sync request/response, `flush_pending_sync_requests`
    - Named `sync_handler.rs` instead of `crdt_sync.rs` to avoid collision with `use crate::crdt::sync::{self as crdt_sync, ...}` import alias
  - [X] Extract `message_ops.rs` (1,007 lines) — send/edit/delete messages, emoji reactions for both DMs and channels
  - [X] Extract `social.rs` (390 lines) — friends, profiles, typing indicators, `send_own_profile_to_peer`
  - [X] Extract `vault_ops.rs` (791 lines) — shard store/retrieve, upload/download pipeline, recovery pool commands
  - [X] Extract `file_handler.rs` (919 lines) — SendFile, WebRTC transfer handling, `handle_completed_stream`, `stream_to_peer`, `broadcast_to_gossip_neighbors`
    - Named `file_handler.rs` instead of merging into existing `file_transfer.rs` (125-line utility module unchanged)
  - [X] Extract `voice_handler.rs` (616 lines) — voice channels, 1:1 calls, WebRTC signaling, `check_voice_mode_transition`
  - [X] Extract `gossip_relay.rs` (129 lines) — broadcast relay, peer exchange, rotation/eviction/exchange timer handlers
  - [X] Clean up dead code: removed `chunk_file`/`chunk_count`/`CHUNK_SIZE`, `file_stream_request`/`shard_stream_request`, `CrdtStore` actor, `xor_distance`/`local_placements`/`remote_placements`/`detect_departures`, `generate_one_time_keys_batch`/`is_outbound_only`, signaling `Register`/`UpdateAddresses` variants
  - [X] Updated `mod.rs` re-exports, `cargo check` + `cargo clippy` + `cargo test` all pass (232 tests, 0 failures)
  - [X] **Final pass: extract `handle_incoming_request` inner envelope dispatch — DONE.** All 43 `MessageEnvelope` arms (Typing/ProfileUpdate, ChannelMessage/Edit/Delete/Reactions, FileHeader/Chunk/BroadcastMeta, ShardStore/Chunk/Ack/Delete/Request/Response/Probe/ProbeResp/Migrate + VaultManifestBroadcast, VoiceChannel{Join,Leave,SDP×2,ICE,AudioState,Screen×4,Reneg×2,CameraState}, CrdtOp/ServerDelete/MemberKick/SyncReq/SyncResp/ChannelSync{Req,Batch}/ChannelProbe{,Resp}) extracted into their target modules as `pub(crate) async fn handle_envelope_*()`. `handle_incoming_request` shrank ~978 lines (7,212 → 6,234). Catch-all (DirectMessage/DmSyncBatch/SessionAck) left inline as a no-op log. VC rate-limit guard moved into `voice_handler::vc_rate_check`. 232 tests pass, 8 fewer warnings than baseline (44 vs 52).
    - `MessageEnvelope::DirectMessage` / `ChannelMessage` → `message_ops.rs`
    - `MessageEnvelope::ChannelSyncBatch` / `DmSyncBatch` / `SyncReq` / `SyncResp` / `CrdtOp` / `ServerDelete` / `MemberKick` / `ChannelSyncReq` / `ChannelProbe` / `ChannelProbeResp` → `sync_handler.rs`
    - `MessageEnvelope::EditMessage` / `DeleteMessage` / `AddReaction` / `RemoveReaction` → `message_ops.rs`
    - `MessageEnvelope::FileHeader` / `FileChunk` / `BroadcastMeta` → `file_handler.rs`
    - `MessageEnvelope::ShardStore` / `ShardChunk` / `ShardStoreAck` / `ShardDelete` / `ShardRequest` / `ShardResponse` / `ShardResponseChunk` / `ShardProbe` / `ShardProbeResponse` / `VaultManifestBroadcast` / `ShardMigrate` → `vault_ops.rs`
    - `MessageEnvelope::Typing` / `ProfileUpdate` → `social.rs`
    - `MessageEnvelope::VoiceChannel*` (all ~11 variants) → `voice_handler.rs`
- [x] **System audio capture (screen share audio) — Windows done via flutter_webrtc fork**
  - [x] Windows: WASAPI loopback capture wired directly into `getDisplayMedia({audio: true})` via a fork of `flutter_webrtc` 1.4.1 at `../flutter-webrtc-1.4.1/`. Captures default render endpoint in loopback mode, feeds 10ms PCM frames into a kCustom `RTCAudioSource`. Audio track is returned via the `audioTracks` list and `addTrack`'d directly to the screen-share PC (NOT attached to the MediaStream — that crashes libwebrtc's sender iteration).
  - [x] Wire into ScreenShareService: "Share audio" toggle unlocked, audio track added to screen share PC
  - [ ] macOS: ScreenCaptureKit audio capture (Swift, macOS 13+) — deferred, no test hardware yet
  - [ ] Linux: PulseAudio/PipeWire monitor source capture — deferred, no test hardware yet
  - [ ] Upstream PR to flutter-webrtc — submit once Windows implementation has baked in Hollow for a couple weeks
  - Note: Windows path uses a forked `flutter_webrtc` (at `../flutter-webrtc-1.4.1/`, git-tracked, 1 commit on top of release baseline). Pubspec points at `path:` until the PR lands upstream.

- [x] **Hollow Share — Private P2P File Sharing (encrypted torrent)** — Zero-tracker, zero-IP-leak, encrypted file sharing built on existing WebRTC data channels. STUN-only (no TURN — relay bandwidth reserved for messaging). Zero file bytes ever touch the relay.
  - [x] **Core protocol:**
    - [x] Share manifest: SHA-256 root hash + file name + size + chunk count + per-chunk SHA-256 hashes (`ShareManifest` in `node/types.rs`)
    - [x] Share link: `hollow://share/<base64url(version:1 || root_hash:32 || key:32)>` — 65-byte payload, 87 base64url chars, QR-able. Manifest is fetched-by-hash from the swarm
    - [x] Chunk splitting: 256 KiB plaintext → AES-256-GCM encrypted on-the-fly (key from link, nonce = `[0;4] || chunk_index_be:8`) → SHA-256 of ciphertext stored in manifest. Receiver verifies hash *then* decrypts
    - [x] Multi-source parallel download: scheduler tick (50ms / 20 Hz) does rarest-first piece selection across `peer_have` bitmaps filtered by `webrtc_peers`, caps in-flight at 4 chunks per peer, retries on 8s timeout
    - [x] Chunk verification: SHA-256(ciphertext) == manifest.chunk_hashes[i] before decrypt; tampered chunks rejected and re-requested from a different peer
    - [x] Seeding: completed files remain available; auto-seed on completion; toggle per file; persisted via `seeding` column in SQLCipher
    - [x] Auto-rejoin on app start: `seeding=1` rows rebuild in-memory state, reopen source files, rejoin swarm rooms before main loop. Missing files → mark stale + disable seeding
    - [x] Bandwidth coexistence: process-wide `SeedBudget` token bucket (20 MiB/s refill, 40 MiB burst) caps share uploads. Scheduler pauses chunk requests for 200ms after any messaging/voice traffic
    - [x] Persistence: `shares` + `share_chunks` tables in SQLCipher. Have-bitmap snapshot on every chunk arrival → paused/restarted downloads resume without re-fetching
    - [x] Zero-copy seeding: sender stores original file path (no encrypted copy). Chunks encrypted on-the-fly with AES-256-GCM (~50μs per 256 KB chunk on AES-NI). Temp files auto-deleted after WebRTC send completes
    - [x] Speed: 3-second sliding window throughput measurement (replaced broken EWMA). Honest bytes/sec display
  - [x] **Discovery & peer finding:**
    - [x] `share_open_link` is a pure probe — decodes link, joins relay room, requests manifest. No DB entry until user explicitly presses Download
    - [x] Manifest timeout: 10s countdown in the paste dialog. No seeders → returns to input with error
    - [x] Relay room rendezvous: signaling only — no public DHT, no tracker. Zero file bytes over relay
    - [x] STUN-only: `shareIceConfigProvider` returns no-TURN config so share traffic never consumes relay bandwidth
    - [x] `PeerLeft` cleanup: dropped peer is removed from every share's `peer_have`, in-flight requests freed for rescheduling
  - [x] **Chunk transport — WebRTC-only binary path:**
    - [x] Control plane (manifest req/resp, Have bitmaps, chunk requests) rides `HavenMessage` over the relay — small signaling messages
    - [x] **Bulk chunk bytes ride direct WebRTC data channels only (STUN-only, no TURN, no relay fallback).** If no WebRTC connection exists, chunks are skipped (not sent over relay). Scheduler only requests from `webrtc_peers`-connected peers
    - [x] Wire format: `StreamKind::ShareChunk` + `TYPE_SHARE_CHUNK = 0x02` byte + 4-byte LE `chunk_index`. Identical in Rust `ws_stream_transfer.rs` and Dart `webrtc_service.dart`
    - [x] Receiver: Dart `_completeIncomingTransfer` branches on `kind == "share_chunk"` → calls `webrtcShareChunkComplete` FFI → Rust verify+decrypt+write+progress+complete
    - [x] **WebRTC auto-reconnection:** `ShareNeedWebRtc { peer_id }` event emitted when scheduler detects a peer in `peer_have` but not in `webrtc_peers`. Dart calls `ensureConnection()` to re-establish the data channel. Download resumes automatically
    - [x] Sender-side temp cleanup: `.send_*.tmp` files deleted after WebRTC send completes via `handle_webrtc_send_complete`
  - [x] **UI — Share tab in app:**
    - [x] **Shell integration:** Share icon on bottom bar (dock mode) + server strip (classic mode), follows Archive pattern. `hollow_shell.dart:_buildChatOrEmpty()` checks `shareTabOpenProvider` before `archiveTabOpenProvider`. All navigation paths (Home, Archive, server, peer selection) clear share state
    - [x] **ShareDashboard** — single-panel scrollable list, header with "Share a File" + "Paste Link" buttons. Two grouped sections: "Downloading" (progress bar, chunks, seeds, speed, cancel) and "Seeding" (uploaded, peers, copy link, show in folder, seeding toggle, remove)
    - [x] **Paste Link dialog** — 3-state flow: input (with validation) → loading (10s countdown, cancel cleans up) → confirm (file name, size, chunks, Download/Cancel). Download only starts when user presses Download — no auto-start
    - [x] **Progress:** 3-second sliding window throughput (honest bytes/sec, not inflated EWMA). Per-chunk from Rust — no Flutter-side byte counting
    - [x] **Share creation:** "Share a File" → FilePicker → `share_create_from_file` → stores original path (zero copy) → emits `ShareCreated` with link. Copy Link button on seeding card
    - [x] **Real-time seeder updates:** tick emits `ShareSeedingChanged` every 2s with live `bytes_uploaded` + `peers` count
    - [x] **Seeding survives restarts:** DB `seeding=1` set on download completion. `auto_rejoin_seeders` reopens source files on app start. Toggle off→on reopens file from DB `disk_path`
    - [x] **Stale entry cleanup:** missing files → mark stale + disable seeding on startup/tick. Orphan `(unknown)` DB entries cleaned on `shareList`. Orphan `.send_*.tmp` files pruned
    - [x] **Toggle state cached:** `handleShareList` preserves in-memory seeding/progress state when merging with DB, preventing OFF→ON flicker on tab switch
  - [x] **Privacy & security:**
    - [x] No tracker server — relay only does WebRTC signaling (SDP/ICE exchange), never touches file data
    - [x] No IP exposure — ICE candidates exchanged via encrypted relay, never published to a public DHT
    - [x] Encrypted in transit — WebRTC DTLS on data channels + every chunk independently AES-256-GCM encrypted with per-link key
    - [x] ISP-invisible — looks like normal WebRTC traffic, no protocol fingerprint to throttle
    - [x] Always-on per-chunk encryption — link IS access control, chunks unreadable without it
  - **Implementation files:**
    - `rust/hollow_core/src/node/share_handler.rs` (~1600 lines, NEW) — link codec, on-the-fly AES-256-GCM crypto, swarm registry, all command + envelope handlers, scheduler tick (20 Hz), `SeedBudget` (20 MiB/s), `auto_rejoin_seeders`, `finalize_completed_download`, `ChunkBitmap`, 9 unit tests
    - `rust/hollow_core/src/node/types.rs` — `ShareManifest`, 5 `HavenMessage` variants (share rides `HavenMessage`, NOT `MessageEnvelope`), 7 `NodeCommand`, 8 `NetworkEvent` (incl. `ShareNeedWebRtc`)
    - `rust/hollow_core/src/storage/messages.rs` — `shares` + `share_chunks` tables, `StoredShare`, 11 DB methods
    - `rust/hollow_core/src/api/share.rs` (NEW) + `api/network.rs` — 8 `#[frb]` functions, `ShareEntry`/`ShareLinkInfo` FFI structs, `to_ffi_event` arms
    - `rust/hollow_core/src/node/swarm.rs` — registry, `SeedBudget`, `last_message_traffic`, 50ms share tick timer, command dispatch, envelope intercept, `PeerLeft` cleanup, auto-rejoin
    - `rust/hollow_core/src/node/file_handler.rs` — sender-side `.send_*.tmp` cleanup in `handle_webrtc_send_complete`
    - `lib/src/core/providers/share_tab_provider.dart` (NEW) — `shareTabOpenProvider`, `ShareTabNotifier` with live list state, pending manifest tracking, toggle state caching
    - `lib/src/core/providers/event_provider.dart` — Share event dispatch + `ShareNeedWebRtc` → `ensureConnection`
    - `lib/src/core/providers/ice_config_provider.dart` — `shareIceConfigProvider` (STUN-only)
    - `lib/src/ui/share/share_dashboard.dart` (NEW) — main dashboard, header, empty state, grouped list
    - `lib/src/ui/share/share_card.dart` (NEW) — download/seeding/failed card modes, progress bar, speed, toggle, show in folder
    - `lib/src/ui/share/paste_link_dialog.dart` (NEW) — 3-state dialog with 10s countdown, cancel cleanup, no auto-start
    - `lib/src/ui/shell/bottom_bar.dart` — Share icon + `_openShare()` + mutual exclusion with Archive
    - `lib/src/ui/shell/server_strip.dart` — Share icon in classic layout
    - `lib/src/ui/shell/hollow_shell.dart` — `shareTabOpenProvider` check in `_buildChatOrEmpty`

- [X] Fix channel + DM history race on first open after receiving a message; auto-scroll to bottom when in capture zone, pill otherwise
- [X] Fix audio card preview update on download
- [X] Check if there is a Search bar in Incoming/Outgoing friend requests
- [X] Voice recordings in the chat — tap-to-record mic button beside the file picker in DM + channel inputs. Opus-in-Ogg @ 16 kHz mono 24 kbps (~90 KB per 30s, ~8-10× smaller than MP3 at equivalent voice quality). Live waveform + pulsing rec dot + timer. Reuses existing `sendFile()` pipeline so voice messages are E2EE + signed like any attachment. 34-hour hard cap to mirror the 34 MB DM vibe.
- [X] **Fix file transfer progress bar (DM/channel file sends).** WebRTC streaming transfers (`total_chunks = 0`) have broken progress: Dart WebRTC receives bytes and updates `onProgress` every 512 KB (`webrtc_service.dart:624`), but Rust only learns about the transfer when the entire file finishes via `webrtcTransferComplete`. Rust then decrypts the whole blob and emits a single `FileCompleted` — no intermediate `FileProgress` events. Result: progress bar sits at ~10% then jumps to 100%. Fix: either (a) bridge Dart's byte-level progress directly to `fileTransferProvider` without waiting for Rust (pure Dart fix — progress = bytes received / total, skip Rust events for streaming transfers), or (b) convert streaming transfers to chunked transfers so Rust can emit `FileProgress` per chunk like Share does. Option (a) is simpler but progress won't account for decryption time at the end; (b) is a deeper refactor but gives honest progress. Key files: `webrtc_service.dart:620-631`, `webrtc_provider.dart:40-49`, `file_handler.rs:560-630`, `file_transfer_provider.dart:394-427` ------ NO NEED TO! It's this problem and it can't be changed! Deferred into unknown.
- [X] 411 errors with -D warning on cargo clippy - wtf is that? — ~414 default-level warnings: 172 "ref immediately deref'd" + 104 "collapsible if" (auto-fixable), ~50 "too many args" (conscious SwarmContext-less design), misc. No bugs, no `-D` deny flags. Auto-fixable via `cargo clippy --fix` but noisy diff.
- [ ] Proper roles on the server and editing of permissions
- [ ] Security of the community servers. To prevent massive spam/abuse in terms of files and such - add for example OAuth for Twitch and allow the server joining if you're a follower for 1 day or something (use Twitch API like for getting the follow: https://dev.twitch.tv/docs/api/reference#get-followed-channels)
- [ ] Discord import system (full implementation — parse GDPR export ZIP, map servers/channels/roles/messages, placeholder identities, member claiming) == reflect to the discord_migration_plan.md
- [ ] Device linking via QR code (multi-device identity sync) — requires MLS + CRDTs. 🎞️ Animate: QR scan success celebration, device linked confirmation
- [ ] Mobile platform testing & platform-specific fixes (adaptive layout built in Phase 2.5)
- [ ] Accessibility (screen reader support, high contrast)

**Deliverable:** A polished, feature-complete communication platform ready for public release — with private, encrypted P2P file sharing that rivals torrent performance without any of the privacy/legal exposure.

### Phase 7: Distribution & Launch

**Goal:** Ship it.

- [ ] Windows installer (MSIX + Inno Setup EXE)
- [ ] macOS DMG (signed + notarized)
- [ ] Linux (AppImage + Flatpak + Snap)
- [ ] Android (Play Store + direct APK)
- [ ] iOS (App Store)
- [ ] Auto-update system
- [ ] Landing page / website
- [ ] Documentation (user guide, FAQ)
- [ ] Beta testing program
- [ ] Security audit (third-party review of E2EE implementation - OTF Security Lab funding)
- [ ] **Strip / minimize bundled ffmpeg binary** — Initial bundled binary (BtbN LGPL static, `vendor/ffmpeg/ffmpeg-win-x64.exe`) is ~164 MB unstripped and includes a huge codec/library zoo we don't actually use (libdav1d, libvpx, libsvtav1, libplacebo, vulkan, opencl, AMF, NVENC/NVDEC, libjxl, libwhisper, librav1e, libopenh264, all the audio codecs, etc.). After the video preview pipeline is shipped and stable, profile what ffmpeg arguments / codecs our actual usage requires (just thumbnail extraction via libwebp encoder + a small set of video demuxers/decoders for whichever container formats users actually upload), then either (a) strip the existing binary with `strip` to drop debug symbols (~15-20% reduction), or (b) build a custom minimal ffmpeg with only the required components (`--disable-everything --enable-encoder=libwebp --enable-decoder=h264,hevc,vp9,av1 --enable-demuxer=mov,matroska,webm` etc.) — target ~10 MB per arch. Same for macOS/Linux when those builds happen. No code changes needed when swapping the binary — just replace `vendor/ffmpeg/ffmpeg-{platform}` and rebuild.
- [ ] LRU-eviction (optimization for loading only what you can see on the screen such as friends profiles or avatars)
- [ ] **Theme system** — structured theme manifest (colors, fonts, spacing, radii, optional cosmetics like profile decorations/nickname accents), `.hollow-theme` bundle format (manifest + asset files, signed for integrity), in-app import/export UI with live preview, curated community gallery repo on GitHub. Per-user local only — themes never travel with messages. Data-only schema (no HTML/CSS/JS, no arbitrary code execution) so community-shared themes are provably safe to apply. Absorbs the old "hearts/sparkles on profiles + custom fonts" idea as one set of knobs among many. Build on existing `HollowTheme` ThemeExtension by making it loadable from a manifest instead of hardcoded.
- [ ] **Multi-relay support + scaling roadmap.** Load-tested current relay on 2026-04-15 (4 vCPU / 8 GB / 400 Mbps OVH VPS). Measured: **133 KB RSS per WebSocket connection** at the relay alone, **186 KB per connection through Nginx** (TLS terminator). Verified at 10,000 concurrent loopback connections — relay used 1.34 GB RSS, load avg 18.6 peak, 5.7 GB RAM still available. Bandwidth: ~50 B/sec per idle connection (heartbeat + occasional CRDT chatter), so even 100k users = ~5 MB/sec = 40 Mbps — well under any modern uplink. **Per-box capacity table (BASELINE — current code, no optimizations applied):**
    - Current OVH VPS (8 GB / $8.35/mo): ~38k conns through Nginx, ~53k native TLS
    - Future OVH VPS (12 GB / $12.75/mo): ~59k conns Nginx, ~83k native TLS
    - **Hetzner auction (256 GB Xeon E5-1650v3 / 1 Gbps unmetered / €74.90/mo with 0% Ukraine VAT ≈ $74.90): ~1.32M conns Nginx, ~1.85M native TLS**
    - Hetzner auction smaller (64 GB Ryzen 5 3600 / 1 Gbps / $43.90/mo): ~330k conns Nginx, ~470k native TLS
    - DataPacket dedicated 256 GB ($790/mo): same RAM as Hetzner, 11× the price, only meaningful if 50 Gbps port is needed
- [ ] **Per-box capacity table (POST-OPTIMIZATION — after TCP buffer tuning + native TLS + permessage-deflate + binary framing all applied):**
    - Current OVH VPS (8 GB / $8.35/mo): ~250k-350k conns (RAM-bound)
    - Future OVH VPS (12 GB / $12.75/mo): ~380k-550k conns (RAM-bound)
    - **Hetzner 256 GB auction ($74.90/mo): ~3-4M conns realistic with active chat (BANDWIDTH-bound at ~3.5M on 1 Gbps), ~7.5M idle-only ceiling, ~8-12M RAM-only ceiling**
    - Hetzner 64 GB Ryzen ($43.90/mo): ~2M-2.5M conns (likely bandwidth-bound before RAM)
    - **Per-user cost at scale: ~$0.000021/user/mo on Hetzner 256 GB at 3.5M users.** For comparison: Discord's per-user infra cost is widely estimated at $0.04-$0.17/user/mo — so Hollow's optimized stack runs at ~2,000-8,000× cheaper per user.
- [ ] **Scaling phases** (informed by load test):
    - **Phase A — current → ~25k concurrent users:** stay on the $8.35 VPS. Using <5% of capacity. Don't upgrade.
    - **Phase B — 25k → 100k concurrent:** add a second $8.35 VPS in a different OVH region for geo-redundancy + failover, OR jump straight to one Hetzner auction box ($75/mo) for 35× capacity at 10× cost.
    - **Phase C — 100k → 500k concurrent:** one Hetzner 256 GB box + 2-3 small OVH VPSes as edge relays in geo-distant regions (Asia, Americas) for latency. Total ~$110-150/mo.
    - **Phase D — 500k+:** migrate to a fleet of mixed Hetzner auction boxes (256 GB main + multiple 64 GB regional). After all optimizations applied, per-user cost drops to ~$0.000021/mo on Hetzner 256 GB at realistic scale — orders of magnitude cheaper than any commercial alternative. Single-box ceiling becomes bandwidth-bound, not RAM-bound: with permessage-deflate + binary framing reducing per-conn idle traffic from 50 B/sec → ~17 B/sec, 1 Gbps supports ~7.5M idle conns / ~3-4M with realistic chat activity. TURN traffic (voice/video for the ~5-10% of users behind symmetric NATs) competes for the same 1 Gbps — at 100 kbps per voice call and ~5% in-call rate, TURN budget caps simultaneous active calls at ~10k, which supports ~200k+ users on the call-mix angle. Beyond ~3M users per box, add boxes — don't try to scale a single one further.
- [ ] **TCP socket buffer tuning (HIGHEST-IMPACT relay optimization).** Verified 2026-04-15: Linux kernel default `tcp_rmem` is 128 KB and `tcp_wmem` starts at 16 KB and grows to ~85 KB on active sockets. **~213 KB per connection is kernel TCP buffers alone** — the dominant cost, far above anything in our Rust process (which is ~5-13 KB per conn). For a chat/signaling relay where messages are almost always <1 KB, these buffers are wildly oversized. Action: in the relay's accept loop, after each `TcpStream` is accepted, call `socket.set_recv_buffer_size(16384)` and `socket.set_send_buffer_size(16384)` to lock both at 16 KB. Expected effect: drops per-conn RAM from current ~133 KB measured (idle, before send buffer grew) → **~20-30 KB**. Capacity multipliers: OVH 8 GB VPS goes from 38k → ~250k-350k conns, Hetzner 256 GB auction goes from 1.32M → **~8M-12M conns per box**. Risks: smaller buffers → more aggressive TCP flow control → may add ms-scale latency on burst traffic (large MLS welcome packets, file shard signaling) and slightly reduce single-stream throughput. For chat traffic (~99% messages <500 bytes) this is a non-issue. Do this BEFORE the native TLS migration so the new capacity numbers apply from the start. **Effort: ~30 minutes. Risk: low. Payoff: 6-10× capacity per box.**
- [ ] **Bounded mpsc channels per connection (stability + worst-case RAM).** Current code uses `mpsc::unbounded_channel::<Message>` for each peer's outbound queue. If a client receives slowly (mobile on bad Wi-Fi, paused tab), broadcast traffic from active rooms piles up indefinitely — worst case MBs per stalled peer under fanout from a 50-person room. Switch to `mpsc::channel(64)`. When the channel fills, decide policy: either drop the slow peer's WS (forces resync via gossip on reconnect) or drop the queued message. Recommend the former — resync is cheap, lying to the client about delivered state isn't. Effort: ~2 hours. Wins: caps worst-case per-conn memory at ~32 KB even under broadcast storms; protects against malicious slow-loris-style buffer-bloat attacks. Pair with the TCP buffer tuning.
- [ ] **Native TLS migration (relay).** Drop Nginx, terminate TLS in the relay using `tokio-rustls` + `instant-acme` for cert rotation. Wins: +40% per-VPS connection density (no double-socket overhead), eliminates Nginx access-log privacy concerns, halves the trusted computing base (one binary vs. nginx+openssl+relay), simpler ops. Cost: ~half-day of work. Should be done before Phase B kicks in so the capacity numbers above hold.
- [ ] **WebSocket permessage-deflate compression (RFC 7692).** Negotiate compression during the WS handshake using tokio-tungstenite's built-in support. Critical implementation note: the relay should operate in **passthrough mode** — receive compressed frames from sender, forward them to all room members WITHOUT decompressing/recompressing (preserve `RSV1` bit unchanged). This puts ~all CPU cost on clients (~10-50 µs per message) and zero on the relay. Expected wins: ~50% bandwidth reduction on JSON envelopes, ~25% on already-encrypted base64 payloads, net ~50-60% wire reduction. RAM/conn unchanged (compression saves bytes-in-flight, not bytes-resident). Privacy: neutral in our threat model since payloads are E2EE ciphertext (compression ratio reveals nothing about content); fingerprinting concern is theoretical only with hostile relay+broken TLS combination. Pair this with the native TLS migration — natural rollout window since clients reconnect anyway.
- [ ] **Binary message framing for text/MLS.** Today the relay's `Msg`/`Direct` envelopes are JSON wrapping base64 ciphertext (~40% wire overhead before compression). Heartbeats are `{"type":"msg","room":"...","data":"hb"}` ~50 bytes when they could be a 1-byte tag. Migrate to a compact binary protocol (1-byte type tag + length-prefixed fields, or `postcard`/`bincode`). Already partially done — `0x01` (binary broadcast) and `0x02` (binary direct) prefixes exist in `ws_router.rs` for file/voice traffic; extend the same pattern to text/MLS/heartbeat. Wins: ~30% additional bandwidth reduction on top of compression, ~10% RAM/conn (smaller TCP send buffers fit more pending messages), eliminates JSON parse CPU on relay. Cost: requires coordinated client+relay rollout with version negotiation so old clients don't break. Plan as a 6.x → 7.0 wire-protocol bump.
- [ ] **Multi-relay client support.** Client must learn the list of relay endpoints from a config + DNS, fail over between them, and prefer geographically-closer ones. Coordinate room membership across relays via gossip (relays subscribe to each other's room broadcasts). Without this, scaling beyond one relay box is meaningless because users on relay A can't talk to users on relay B.
- [ ] **Coturn isolation.** When migrating to Hetzner, decide whether to co-locate Coturn (simpler, but TURN-bandwidth spikes can starve relay traffic) or keep Coturn on a separate small VPS (~$10/mo, isolates abuse-complaint blast radius and bandwidth contention). Recommend separating once on the big box — TURN servers are higher-value abuse targets and should be quarantined from signaling.
- [ ] **VPS tunable limits to remember for future scaling.** Current production relay VPS (OVH 8 GB) has the following resource ceilings — re-verify and raise these on any new box before putting it into service:
    - **Nginx `worker_connections`:** set to 16384 (was default 768). Default would cap the entire box at ~380 real WS connections through the TLS proxy. Each WS through Nginx uses 2 FDs (client socket + upstream socket).
    - **Nginx `worker_rlimit_nofile`:** set to 65535 (was unset, inheriting systemd's 1024 soft cap). Without this, workers run out of FDs long before they run out of connection slots.
    - **Nginx `events { multi_accept on; use epoll; }`:** enabled. Marginal throughput win for high-connection accept bursts.
    - **Nginx `/ws` location: `access_log off;`.** Privacy win — no per-connection logs of peer IDs or client IPs.
    - **systemd `hollow-relay.service` `LimitNOFILE`:** 65536 (default was fine). For native-TLS migration, may need to raise to 1048576 to comfortably hold ~500k FDs on the Hetzner box.
    - **systemd `hollow-relay.service` `MemoryMax`:** unset (infinity). Fine — no cap.
    - **Kernel `fs.file-max`:** 9223372036854775807 (effectively unlimited). Fine.
    - **Kernel `net.ipv4.ip_local_port_range`:** 32768-60999 (~28k ephemeral ports). Only matters for the relay as outbound client (e.g., if it ever connects to other relays for peering). Raise to 10000-65535 if multi-relay gossip between boxes is added.
    - **Kernel `net.core.somaxconn`:** 4096. Fine for expected ramp rates; raise to 65535 if we ever see TCP connect storms.
    - **Swap:** 0 (OVH default). If relay OOMs, it OOMs hard. Consider adding a small swapfile (~2 GB) on the Hetzner box purely as a safety net.
    - **Load-gen client side** (for future re-tests): set `ulimit -n 65536` before running the load-gen binary, or it caps at ~1000 connections (its inherited FD limit). Windows: `netsh int ipv4 set dynamicport tcp start=10000 num=55000` to raise ephemeral port range from default 16384 to 55000.


**Deliverable:** Public release across all platforms.

### Phase ???: Fight Government Censorship

**Goal:** Allow Hollow to work in countries with advanced DPI censorship (Russia, China, Iran).

**Explanation:**

Russia's TSPU (DPI system) is one of the most advanced censorship systems in the world. It doesn't just look at port numbers — it analyzes traffic patterns, packet sizes, and timing. Even though our WSS goes through TLS on port 443, the libp2p protocol fingerprint inside the WebSocket frames is detectable. This is the same reason Tor needed pluggable transports (obfs4, meek, snowflake) — plain TLS wrapping isn't enough against sophisticated DPI.

**Proven solutions exist (used by people in Russia/China/Iran right now):**
- **VLESS + Reality (XRay):** Makes traffic indistinguishable from a real TLS connection to a legitimate website (e.g., google.com). Gold standard for DPI bypass.
- **Shadowsocks (Outline):** Traffic looks like random noise. Simple to deploy, still effective against most DPI.
- **AmneziaWG:** Modified WireGuard with junk packets and header obfuscation.

**Implementation approaches (from easiest to hardest):**
1. **Documentation only** — Guide for users to set up their own VLESS/Shadowsocks proxy, Hollow connects through it normally. Zero code changes.
2. **Relay-side proxy** — Run XRay/Shadowsocks on our VPS alongside the relay. Censored users connect to the obfuscated proxy, which tunnels to the Hollow relay internally. Minimal Hollow code changes.
3. **Built-in transport** — Integrate a Shadowsocks or VLESS client directly into Hollow's Rust backend. Auto-detect censorship (connection failures on WSS) and fall back to obfuscated tunnel. Best UX, most work.

**Research findings:**
- WSS on port 443 — TSPU detects libp2p fingerprint inside TLS, kills connections in ~10-20 seconds
- VLESS+Reality over TCP — blocked by TSPU since Feb 2026 (~15-20KB payload threshold)
- VLESS+Reality over XHTTP — proxy worked for HTTP traffic but libp2p bypasses system proxy (raw sockets), TUN mode still killed by TSPU
- External proxy (SOCKS5/TUN mode) — doesn't work because libp2p opens raw TCP/UDP sockets, bypassing system proxies
- Regular VPN — works, confirming the issue is protocol fingerprinting, not IP blocking
- **Shadowsocks-2022 (AEAD) — works on many ISPs, but TSPU on some ISPs detects it via encapsulated traffic fingerprinting (packet size/timing patterns) and kills connections after ~20 seconds**
- Hysteria V2 — QUIC/UDP-based, Russia throttles UDP periodically, unreliable
- WireGuard/OpenVPN/IKEv2 — all dead in Russia
- AmneziaWG — UDP-based (same throttling issue), no embeddable Rust library
- Russian VPS — domestic traffic fine, but outbound international traffic still inspected by TSPU

**Solution implemented: Option 3 — Embedded Shadowsocks tunnel**

Architecture:
```
[Proxy OFF — normal users]
Hollow app → TCP/QUIC direct → relay:4001

[Proxy ON — censored users]
Hollow app → local TCP tunnel (127.0.0.1:14001) → SS encrypt → VPS:443 → ssserver decrypt → relay localhost:4001
Hollow app → local TCP tunnel (127.0.0.1:18080) → SS encrypt → VPS:443 → ssserver decrypt → signaling localhost:8080
```

**Checklist:**
- [x] Research: test VLESS+Reality from Russian network — BLOCKED by TSPU (TCP killed at ~15-20KB)
- [x] Research: test VLESS+Reality XHTTP — proxy works for HTTP but libp2p bypasses it, TUN mode still killed
- [x] Research: confirm external proxy won't work — libp2p bypasses SOCKS5/HTTP proxies
- [x] Research: test Shadowsocks-2022 from Russia — PARTIALLY BLOCKED (ISP-dependent, TSPU uses encapsulated traffic fingerprinting on some ISPs)
- [x] Research: evaluate Hysteria V2 — UDP-based, Russia throttles UDP, unreliable
- [x] Research: evaluate embedded VPN (WireGuard/OpenVPN) — requires OS-level TUN/TAP drivers + admin privileges, not suitable for a chat app
- [x] Research: evaluate Russian VPS — outbound international traffic still inspected by TSPU, doesn't solve the problem
- [ ] Option 1: Write user-facing guide for external proxy setup — SKIPPED (external proxy doesn't work with libp2p)
- [ ] Option 2: Deploy XRay/Shadowsocks proxy on relay VPS only — SKIPPED (went straight to Option 3)
- [x] Option 3: Integrate obfuscated transport into Rust backend
  - [x] Add `app_settings` key-value table to SQLCipher (`storage/messages.rs`)
  - [x] Add `save_setting()`/`load_setting()` FFI functions (`api/storage.rs`)
  - [x] Add `shadowsocks-service` crate dependency (`Cargo.toml`)
  - [x] Create tunnel module with dual-port local tunnels (`node/tunnel.rs`)
  - [x] Wire `proxy_enabled` through swarm startup — proxy-aware relay addresses, circuit building (`node/swarm.rs`)
  - [x] Wire `proxy_enabled` through signaling — tunneled signaling URL (`node/signaling.rs`)
  - [x] Load proxy setting in `start_node()` (`api/network.rs`)
  - [x] Regenerate FFI bindings (`flutter_rust_bridge_codegen generate`)
  - [x] Create Dart settings provider (`settings_provider.dart`)
  - [x] Add "Use Proxy" toggle to User Settings dialog with restart prompt
  - [x] Deploy ssserver on VPS (port 443, 2022-blake3-aes-256-gcm)
  - [x] Hardcode generated key in `tunnel.rs`
  - [x] Verify tunnels start and relay connects through localhost
  - [x] Test from Russia with friend — SS connections killed by TSPU after ~20s on friend's ISP (encapsulated traffic fingerprinting + active probing)

**UI changes:**
- [x] Toggles (Dark Mode, Proxy) now use local state — only applied on Save, reverted on Cancel
- [x] "Restart Required" prompt after saving proxy change (Restart Later / Restart Now)
- [x] Restart Now does graceful shutdown (notifyShutdown + 200ms) then relaunches hollow.exe

**Status: Shadowsocks tunnel IMPLEMENTED and FUNCTIONAL, but defeated by TSPU on some Russian ISPs.**
The proxy toggle remains in the app — Shadowsocks-2022 still works on many ISPs and in other censored countries. The toggle is not useless, it just doesn't beat the most aggressive DPI configurations.

**Next step: TLS camouflage tunnel (REALITY-style)**
DIY TLS camouflage using rustls — make tunnel traffic look like a real HTTPS connection to a popular domain (e.g., www.google.com). This is the approach that consistently beats TSPU with <5% detection rate. Requires implementing a custom TLS wrapper in Rust that generates browser-like ClientHello fingerprints. The existing proxy toggle UI and architecture (local tunnel → VPS → relay) would be reused — only the tunnel protocol changes from Shadowsocks to TLS camouflage.

---

## 14. Threat Model & Security

### 14.1 What We Protect Against

| Threat | Protection | How |
|---|---|---|
| **Message content interception** | E2EE (Double Ratchet / MLS) | Only intended recipients hold decryption keys |
| **Metadata leakage (who talks to whom)** | Sealed sender + minimal routing metadata | Sender identity encrypted in message envelope |
| **Man-in-the-middle on key exchange** | Authenticated X3DH + safety number verification | Users can verify fingerprints out-of-band |
| **Server data compromise (member device stolen)** | SQLCipher local encryption + key deletion | Local DB encrypted, keys tied to device auth |
| **Storage shard snooping (curious members)** | Encrypt-then-erasure-code | Shards are encrypted; even reconstructing all shards yields only ciphertext |
| **Sybil attacks (fake identities flooding)** | Invite-only servers + reputation weighting | New identities can only join via cryptographically signed invites |
| **Eclipse attacks (isolating a peer)** | Diverse peer selection + anchor peers | Connect to peers across network segments; maintain trusted peer list |
| **Removed member accessing new content** | MLS epoch rotation on member removal | New epoch key derived from fresh randomness that removed member doesn't have |
| **Traffic analysis (timing/volume correlation)** | Message padding + optional chaff traffic | Fixed-size messages; optional dummy traffic (configurable, bandwidth tradeoff) |

### 14.2 What We Accept as Residual Risk

- **Removed members retain access to data from BEFORE their removal** — they likely have local copies anyway. This is standard (same as Discord, Slack, Signal).
- **A sufficiently powerful global network adversary** could potentially perform traffic analysis even with padding. Full resistance would require constant-rate traffic, which is impractical.
- **Device compromise** — if an attacker has physical access to an unlocked device, they can read decrypted messages. This is true of any E2EE system. Hardware security modules (secure enclaves) are out of scope for v1.
- **Quantum computing** — current algorithms (X25519, Ed25519) are not post-quantum. Migration to post-quantum key exchange (ML-KEM / Kyber) is a future consideration, not a launch blocker.

### 14.3 Security Audit Plan

Before public launch:
1. **Internal code review** focused on crypto implementation
2. **Third-party security audit** by a reputable firm (NCC Group, Trail of Bits, Cure53, etc.)
3. **Bug bounty program** for ongoing vulnerability discovery
4. **Open source** the cryptographic and networking layers for community review

---

## 15. Known Challenges & Mitigations

### Challenge 1: "The Last Person Online" Problem

**Problem:** If only 1 member is online, they can only see data cached on their device. Messages sent while they were offline, stored as shards on other offline members' devices, are invisible until those members come back.

**Mitigation:**
- Aggressive local caching — cache all channels the user has visited
- **Storage Contributors** — members who voluntarily run Hollow 24/7 and donate above-minimum storage (e.g., a home NAS with 50 GB). They earn reputation and a visible role. Tiered recognition system:
  - **Storage Contributor** — donates above the server minimum
  - **Anchor Node** — consistently online 95%+ uptime, high storage donation
  - **Guardian Node** — verified high-uptime node, prioritized for critical data shards and relay duties
- These roles are tracked via CRDTs in the server state, visible in the member list, and purely opt-in. No cryptocurrency — just community reputation.
- Graceful UX — show "Waiting for network..." indicator rather than empty channels. Show locally cached messages immediately, mark gaps with "X messages may be unavailable until more members are online."

### Challenge 2: Bootstrap & First Member

**Problem:** When a server is created, only 1 member exists. There's no distributed storage yet.

**Mitigation:**
- First member stores everything locally (they ARE the server at this point)
- As members join, data gradually distributes to them
- Minimum member threshold for erasure coding to kick in (e.g., need at least k+m distinct members)
- Below the threshold, use simple replication (copies on each member)

### Challenge 3: Mobile Devices Going to Sleep

**Problem:** Mobile OSes kill background processes aggressively. A member on their phone might appear to be online but actually isn't receiving data.

**Mitigation:**
- Use FCM/APNs for push notifications to wake the app (for messages)
- Keep a lightweight background service for shard serving (may not be possible on iOS)
- Mobile members contribute less storage by default (e.g., 256 MB vs 1 GB on desktop)
- Prefer desktop members for shard storage and relay duties

### Challenge 4: Message Ordering in High-Traffic Channels

**Problem:** In a busy channel with many simultaneous senders, HLC ordering may feel "off" compared to a centralized server that assigns a strict order.

**Mitigation:**
- HLCs with NTP-synced clocks are accurate to ~10ms in practice
- For truly simultaneous messages (same millisecond), deterministic tiebreaker (peer ID) ensures consistent ordering
- Users are accustomed to slight reordering in group chats — this is not a dealbreaker
- Threads (reply chains) provide explicit causal ordering within a conversation

### Challenge 5: Storage Abuse (Member Pledges but Doesn't Actually Store)

**Problem:** A member pledges 5 GB but deletes the shard data to save space, or deliberately serves corrupt shards.

**Mitigation:**
- **Periodic shard verification:** Random spot-checks where peers request specific shards and verify integrity (hash matches content address)
- **Reputation scoring:** Members who consistently serve correct shards earn reputation. Members who fail checks lose reputation and may be deprioritized or warned.
- **Redundancy absorbs it:** With k=10, m=5, up to 5 members can be unreliable before data is at risk. Rebalancing creates new shards on reliable members.

---

## 16. Comparison With Existing Alternatives

| Feature | Hollow | Discord | Element/Matrix | Session | Briar | RetroShare |
|---|---|---|---|---|---|---|
| **Client** | Flutter native | Electron (web) | Electron/Web | Native (multi-platform) | Android only | Qt (desktop) |
| **Server model** | Distributed (members) | Centralized | Federated (homeservers) | Decentralized (Oxen nodes) | Pure P2P | Friend-to-friend |
| **Storage** | Shared across members | Company servers | Homeserver admin | Oxen swarm (14-day) | Local only | Local only |
| **E2EE** | All messages, calls, files | No (unless DM "Privacy Mode") | Optional (Megolm) | Yes (Signal Protocol) | Yes (Signal Protocol) | Yes (PGP + TLS) |
| **Identity** | Public key (no phone/email) | Email/phone | Email (or homeserver account) | Public key (no phone) | Public key (in-person exchange) | PGP key |
| **Group size** | Unlimited (MLS scaling) | 500K+ | Unlimited (federation) | 100 (closed groups) | Small (~10) | Medium |
| **Voice/Video** | Yes (WebRTC + E2EE) | Yes | Yes (Jitsi integration) | Yes (limited quality) | No | Yes (basic) |
| **Offline support** | Full (local cache + sync) | No (web client) | Partial (homeserver stores) | Yes (swarm stores 14 days) | Yes (local storage) | Yes (local storage) |
| **Installation** | Single native installer | Download + Chromium | Download + Chromium | Download native | Download APK | Download + Qt |
| **Resource usage** | Low (native binary) | High (Electron) | High (Electron) | Low | Low | Medium |
| **Open source** | Planned (crypto + network layers) | No | Yes (Apache 2.0) | Yes (GPL) | Yes (GPL) | Yes (GPL) |
| **Data sovereignty** | Full — your data, your device, unforgeable evidence | None — Discord owns it | Partial (homeserver admin) | Partial (14-day swarm) | Full (local only) | Full (local only) |

### Hollow's Unique Differentiators

1. **Shared Vault** — No other platform distributes storage across members. This eliminates hosting costs and single points of failure.
2. **Native performance** — Flutter compiles to native code. No Electron, no Chromium runtime.
3. **Zero infrastructure** — No homeservers to maintain (Matrix), no blockchain tokens (Session), no company servers (Discord).
4. **MLS encryption** — Most modern group encryption protocol, better scaling than Signal's Sender Keys.
5. **Discord import** — Lower the migration barrier. Bring your community with you.
6. **Data sovereignty & cryptographic evidence** — No one can delete your data remotely. Exported messages carry unforgeable digital signatures. Evidence of abuse survives even if the server owner tries to destroy everything.

---

## 17. Server Lifecycle & Data Sovereignty

This section addresses a critical question: what happens when members leave, get kicked, or the owner shuts down a server? In a decentralized system, the answer is fundamentally different from centralized platforms — and it's one of Hollow's most powerful features.

### 17.1 Core Principle: Local Data Is Sacred

**Nobody can remotely delete data from your device.** Not the server owner, not admins, not other members, not Hollow's developers. Once you've seen a message and it's in your local cache, it's yours. This is a direct consequence of decentralization — there is no central server to issue a "delete from all devices" command.

### 17.2 Message Signing & Cryptographic Proof

Every message in Hollow is **digitally signed** by the sender's Ed25519 identity key:

```
Message structure:
{
  content: "encrypted message payload",
  author: Ed25519_public_key,
  signature: Ed25519_sign(private_key, content + timestamp + channel_id),
  timestamp: HLC_timestamp,
  channel: channel_id
}
```

This means:
- **Authenticity:** You can mathematically prove that a specific identity key authored a specific message
- **Integrity:** Any modification to the message invalidates the signature
- **Non-repudiation:** The sender cannot deny having sent it (they — and only they — hold the private key that produced the signature)
- **Verifiable exports:** Exported message logs carry the original signatures. A third party (law enforcement, a court) can verify the signatures independently without needing access to Hollow's network

This is **stronger evidence than Discord screenshots**, which can be trivially fabricated. Hollow messages are cryptographically unforgeable.

### 17.3 When a Member Leaves Voluntarily

```
Member chooses "Leave Server"
├── Step 1: Member's device stops syncing with the server network
├── Step 2: MLS epoch advances — member loses access to NEW messages
├── Step 3: Member keeps:
│   ├── Local cache (all messages they previously viewed — decrypted)
│   ├── MLS keys from past epochs (can re-read historical messages)
│   └── Choice prompt: "Keep local archive?" or "Free up storage?"
├── Step 4: Shards on member's device are rebalanced to other members
│   (graceful transfer before disconnection)
└── Step 5: Member can export their archive at any time
```

### 17.4 When a Member Is Kicked / Banned

```
Admin kicks member
├── Step 1: CRDT operation removes member from the server's member list
├── Step 2: MLS epoch advances — kicked member loses access to NEW messages
├── Step 3: Kicked member's device receives the kick notification
├── Step 4: Kicked member KEEPS:
│   ├── Full local cache of everything they saw (their data, their device)
│   ├── Past MLS epoch keys (can still read historical messages)
│   └── Cryptographically signed message history (verifiable evidence)
├── Step 5: Shard data on kicked member's device:
│   ├── Default: kept until member manually reclaims storage
│   └── Option: automatic cleanup after 30 days
└── Step 6: Kicked member can export their entire archive
```

**Key point:** The admin can remove someone from the server's future, but they cannot erase the past. The kicked member retains everything they had access to.

### 17.5 When the Owner Shuts Down a Server

This is where Hollow's architecture truly shines.

```
Owner initiates "Delete Server"
├── Step 1: CRDT operation marks server as dissolved (tombstone)
├── Step 2: All online members receive dissolution notice:
│   "This server has been shut down by the owner."
├── Step 3: Members see prompt:
│   ├── "Export archive" — download full message history as verifiable export
│   ├── "Keep local archive" — messages stay in local cache (default)
│   └── "Delete local data" — remove everything (opt-in only)
├── Step 4: The owner CANNOT:
│   ├── Delete data from other members' devices
│   ├── Revoke past MLS epoch keys that members already hold
│   ├── Destroy encrypted shards stored on other members' devices
│   └── Invalidate message signatures
└── Step 5: The data persists, distributed across ex-members' devices
```

### 17.6 Evidence Recovery — "The Rat Files"

In a worst-case scenario — a malicious server owner running a harmful community tries to destroy evidence by kicking everyone and shutting down the server — Hollow's architecture provides a safety net that no centralized platform can match.

**Why evidence survives:**

1. **Local cache on every member's device** — every message a member viewed is stored locally in decrypted form. The owner can't reach into their devices to delete it.

2. **Cryptographic signatures** — every message is signed by the sender's identity key. Exported messages are mathematically verifiable. Not screenshots that could be Photoshopped — actual cryptographic proof.

3. **Encrypted shards persist on ex-members' devices** — even after the server is "deleted," the erasure-coded shards are still sitting on members' storage. These shards include data from channels the shard-holding member may not have had access to (they hold encrypted chunks, not decrypted content).

4. **Members who DID have access hold the decryption keys** — MLS epoch keys from when they were members. Combined with the shards from other ex-members, they can reconstruct and decrypt the full history of any channel they had access to.

**Recovery flow for a victim:**

```
Victim was in harmful server → Owner kicks everyone → Server "deleted"

Victim's device still has:
├── Local cache of all messages they viewed (decrypted, readable)
├── MLS epoch keys for channels they had access to
└── Shard data they were storing

To recover messages they DIDN'T have cached locally:
├── Step 1: Contact other ex-members (out of band)
├── Step 2: Gather encrypted shards from their devices
│   (ex-members don't need to decrypt — just share the raw shards)
├── Step 3: Reconstruct encrypted data from k-of-n shards
├── Step 4: Decrypt with victim's MLS epoch keys
└── Step 5: Full history recovered, with cryptographic signatures intact

Evidence package for law enforcement:
├── Message content (decrypted)
├── Sender identity keys (who sent what)
├── Digital signatures (mathematically verifiable, unforgeable)
├── Timestamps (HLC — causally ordered)
└── Channel/server metadata
```

**Hollow provides a cooperative "Evidence Recovery" UI tool:**
- Guides ex-members through the shard gathering process
- Handles reconstruction and decryption automatically
- Exports a verifiable evidence package (messages + signatures + metadata)
- Can be used by any ex-member, not just the victim
- No technical knowledge required — the UI handles the cryptography

### 17.7 Data Export (For Any Reason)

Any member can export their data at any time — while in the server or after leaving:

**Export options:**
- **Messages:** Full history of all channels you had access to (from local cache + reconstructible from shards)
- **Files:** All files you uploaded or downloaded (from local cache)
- **Server structure:** Channels, roles, permissions (CRDT state snapshot)
- **Identity data:** Your profile, contacts, server memberships
- **Format:** JSON + media files in a ZIP, with cryptographic signatures preserved

**Server template export (for owners):**
- Export the entire server structure as a template
- Channels, categories, roles, permissions, welcome messages — everything except member data
- Other users can import this template to create a new server with the same structure
- Useful for community templates ("Gaming Server Template," "Study Group Template," etc.)

### 17.8 Server Lifecycle Summary

| Event | Data on member devices | Access to new messages | Evidence integrity |
|---|---|---|---|
| **Member is active** | Full sync + local cache | Yes | Signatures verifiable |
| **Member leaves voluntarily** | Kept (user choice to delete) | No (MLS epoch advances) | Full — signatures + local cache |
| **Member is kicked** | Kept (cannot be remotely deleted) | No (MLS epoch advances) | Full — signatures + local cache |
| **Owner shuts down server** | Kept on ALL ex-members' devices | N/A (server dissolved) | Full — shards + keys + signatures persist |
| **Owner kicks everyone THEN shuts down** | Still kept — owner can't delete others' data | N/A | Full — decentralized architecture prevents evidence destruction |

---

## 18. Sustainability & Monetization

Hollow has no servers to pay for, no infrastructure bills, and no company overhead. The project sustains itself through community support, not paywalls.

### 18.1 Core Principle: No Features Behind Paywalls

Everything that makes Hollow work — E2EE, Shared Vault, voice/video, screen sharing, file sharing, unlimited servers — is free. Forever. No "Hollow Nitro."

### 18.2 Revenue Model: Donations + Optional Cosmetics

**Donations (primary):**
- Patreon / Ko-fi / Open Collective for recurring support
- In-app donation option (similar to WholesomeStoryADay's Wall of Kindness model)
- Transparent spending reports (community trusts where their money goes)

**Optional cosmetics (supplementary):**
- Custom profile themes / colors
- Animated avatars
- Exclusive badge frames
- Custom emoji packs (create and share your own)
- Profile effects / banners

**Critical constraint:** Cosmetic purchases must NOT compromise privacy or security:
- No telemetry, no tracking, no purchase history linked to identity
- Purchases are handled via anonymous payment methods where possible
- Cosmetic data is stored locally / in the user's encrypted profile, not on a central server
- Payment processing is the ONE external service — use privacy-respecting providers (Stripe with minimal data, or crypto payments)

### 18.3 What Keeps Costs Low

- No servers = no hosting bills
- No data storage = no cloud costs
- No moderation team = no staff costs (community self-moderates)
- Open source contributions reduce development burden
- The only real costs: developer time, code signing certificates, app store fees ($25 Google, $99/yr Apple), domain name

---

## Appendix A: Key Technical References

- **libp2p:** https://libp2p.io / https://github.com/libp2p/rust-libp2p
- **Automerge:** https://automerge.org / https://github.com/automerge/automerge
- **MLS RFC 9420:** https://www.rfc-editor.org/rfc/rfc9420
- **vodozemac (Olm):** https://github.com/matrix-org/vodozemac
- **Signal Protocol:** https://signal.org/docs/
- **X3DH:** https://signal.org/docs/specifications/x3dh/
- **Double Ratchet:** https://signal.org/docs/specifications/doubleratchet/
- **OpenMLS:** https://github.com/openmls/openmls
- **flutter_rust_bridge:** https://github.com/aspect-build/flutter_rust_bridge
- **flutter_webrtc:** https://github.com/flutter-webrtc/flutter-webrtc
- **Reed-Solomon coding:** https://en.wikipedia.org/wiki/Reed-Solomon_error_correction
- **Kademlia DHT:** https://en.wikipedia.org/wiki/Kademlia
- **SFrame:** https://datatracker.ietf.org/doc/draft-ietf-sframe-enc/
- **LiveKit:** https://livekit.io
- **Shamir's Secret Sharing:** https://en.wikipedia.org/wiki/Shamir%27s_secret_sharing
- **Argent Social Recovery:** https://www.argent.xyz/learn/what-is-social-recovery/
- **Storj (erasure coding reference):** https://www.storj.io/blog/what-is-erasure-coding

## Appendix B: Glossary

| Term | Definition |
|---|---|
| **CRDT** | Conflict-free Replicated Data Type — data structure that merges concurrent updates without conflicts |
| **DHT** | Distributed Hash Table — decentralized key-value lookup across peers (Kademlia) |
| **Double Ratchet** | Key derivation algorithm providing forward secrecy and self-healing after compromise |
| **E2EE** | End-to-End Encryption — only sender and recipient can read the content |
| **Erasure Coding** | Splitting data into n pieces where any k can reconstruct the original (Reed-Solomon) |
| **FFI** | Foreign Function Interface — calling Rust code from Dart |
| **HLC** | Hybrid Logical Clock — timestamp combining physical time + logical counter for ordering |
| **MLS** | Messaging Layer Security — efficient group encryption protocol (RFC 9420) |
| **NAT** | Network Address Translation — router feature that hides devices behind a single public IP |
| **SFrame** | Secure Frame — encryption format for individual media frames in WebRTC group calls |
| **SFU** | Selective Forwarding Unit — server/peer that forwards (but doesn't decode) media streams |
| **Super Peer** | A member with good bandwidth that acts as a relay/SFU for the group |
| **Non-repudiation** | Property where the sender cannot deny authorship — their digital signature proves they sent it |
| **Shamir's Secret Sharing** | Cryptographic scheme that splits a secret into n shares where any k can reconstruct it |
| **Social Recovery** | Account recovery via trusted contacts (guardians) who each hold a share of the identity key |
| **Storage Contributor** | A member who donates above-minimum storage and maintains high uptime, earning community reputation |
| **X3DH** | Extended Triple Diffie-Hellman — asynchronous key agreement protocol (Signal) |
| **Shared Vault** | Hollow's distributed storage system where members donate disk space |

## Appendix C: FAQ — Questions & Answers From the Design Process

These are real questions that came up during the design of Hollow, answered in full.

---

### Q: Will calls be high quality? Is this old-school VoIP?

**No, this is NOT old-school VoIP.** Hollow uses WebRTC — the exact same technology powering Discord, Google Meet, Zoom's web client, and Facebook Messenger calls.

- **Audio:** Opus codec — the best audio codec in existence. Adaptive bitrate from 6 kbps (bad internet) to 510 kbps (studio quality). Same codec Discord uses.
- **Video:** VP8/VP9/AV1 with hardware-accelerated encoding/decoding.
- **Adaptive bitrate:** Automatically adjusts quality in real-time based on network conditions.
- **Built-in processing:** Echo cancellation, noise suppression, jitter buffer, automatic gain control.

Hollow actually has a **quality advantage** for small calls — 1:1 and small groups are direct peer-to-peer with no server in the middle. Lower latency than Discord, which routes everything through their data centers.

---

### Q: Can screen sharing do 4K at 60fps or 120fps?

| Resolution | FPS | Bitrate Needed | Realistic? |
|---|---|---|---|
| 1080p | 30fps | ~3-5 Mbps | Easy, works for most people |
| 1080p | 60fps | ~6-8 Mbps | Good for most broadband |
| 1440p | 60fps | ~10-15 Mbps | Needs solid internet both ends |
| 4K | 30fps | ~15-20 Mbps | Doable with good connection |
| 4K | 60fps | ~25-40 Mbps | Needs excellent upload AND download |

**120fps:** WebRTC caps screen capture at 60fps in most platform implementations. Even Discord doesn't do 120fps. For screen sharing (not gaming), 60fps is already buttery smooth.

**The real bottleneck is upload speed.** With P2P, there's no server compression — what you send is what they get. Good internet = crystal clear. Bad internet = WebRTC gracefully degrades (lowers resolution/fps automatically rather than stuttering).

Game streaming at 1080p 60fps is very doable — Discord Nitro-level quality, for free.

---

### Q: Will 30,000+ member servers work?

**Yes.** The system is designed to get BETTER with scale, not worse:

- **Storage:** 30K members × 1 GB minimum = 30 TB raw pool (~18 TB usable). Massive.
- **Redundancy:** With 30K members, aggressive erasure coding (k=20, m=30) makes data essentially indestructible.
- **Availability:** Thousands of members online at any moment. The "last person online" problem disappears.
- **Relay:** Hundreds of publicly reachable members available as relays at all times.

**What scales well:**
- DHT peer discovery: O(log n) — 30K is ~15 hops vs ~7 for 100 members. Barely noticeable.
- MLS encryption: O(log 30000) ≈ 15 tree operations per membership change. Fine.
- Storage pool: linearly better with more members.

**What needs attention at scale:**
- CRDT operation volume in busy channels — solved by channel-level sharding (each channel is its own CRDT document).
- Peer connection management — you connect to a subset (6-12 peers), not all 30K.
- Super peer selection for large voice channels — more candidates = better quality.

**Bottom line:** If the system works well at 100 members (because it's properly designed with correct shard spreading, storage optimization, and efficient sync), it works at 30K. The architecture doesn't change — the numbers just get more favorable.

---

### Q: What about file transfer speeds?

Two paths depending on the situation:

- **Small files in chat** (images, short clips): Sent directly P2P to online members. Instant, same as any chat app.
- **Large files** (stored in Shared Vault): Encrypted → erasure coded → distributed. Upload takes longer due to coding + distribution overhead. For a 100 MB file with good peers online, roughly 5-15 seconds.
- **Cached files:** Download once from the network, it's instant after that. Frequently accessed files stay in local cache.

---

### Q: Will Hollow drain mobile data?

Hollow is configurable per-device:

- **Storage contribution:** Lower on mobile (256 MB default vs 1 GB desktop).
- **Shard serving:** Optional on mobile — can be disabled on cellular, enabled only on WiFi.
- **Sync scope:** Configurable — sync all channels vs only active channels on mobile.
- **Calls:** Audio ~1-3 MB/minute (same as any call app). Video varies with quality setting.
- **Background data:** Minimal if shard serving is disabled on cellular.

---

### Q: Is there a member limit?

No hard limit. Practical experience by scale:

| Size | Experience | Notes |
|---|---|---|
| 1-50 | Excellent | Everything smooth, full mesh for small calls |
| 50-200 | Great | MLS handles encryption efficiently |
| 200-1,000 | Great | Shared Vault becomes very robust, huge storage pool |
| 1,000-5,000 | Good | Need good anchor nodes for reliability |
| 5,000-30,000 | Good with tuning | Channel-level CRDT sharding recommended |
| 30,000+ | Workable | Sweet spot for the architecture, benefits from scale |

Discord's 500K+ servers work because they have massive infrastructure. Hollow trades that for decentralization — the sweet spot is communities up to tens of thousands, which covers 99.9% of real Discord servers.

---

### Q: What about bots and integrations?

Not in the initial plan, but the architecture supports it naturally:

- A "bot" is just another peer with a special role — it runs Hollow's protocol, receives messages, can respond.
- Self-hosted by anyone (run it on a Raspberry Pi, a VPS, whatever).
- No bot API server needed — the bot IS a member of the server.
- Integrations (GitHub webhooks, RSS feeds, etc.) would be bot-peers that bridge external services.
- This could be Phase 8 or a community-contributed feature.

---

### Q: What about privacy, criminals, and government requests?

This is the most important non-technical question for any E2EE platform.

**The reality:**
- Hollow's developer has ZERO access to any user data. By design. There are no servers to raid, no databases to subpoena, no logs to hand over.
- This is identical to Signal, Briar, Session, and Tor — all legal, all operating, all with the same answer to law enforcement: "We can't hand over data we don't have."

**Legal protection:**
- Building encryption is protected in most democratic countries. The legal fight was largely won in the 1990s "Crypto Wars."
- Section 230 (US) and equivalent laws elsewhere protect platform builders from liability for user-generated content.
- Precedent: Signal, Tor, Mullvad VPN, WireGuard — all zero-knowledge, all legal. When Mullvad was raided by police, officers left with nothing because there was nothing to take.

**What Hollow DOES do:**
1. **Clear legal terms** — Hollow is a communication tool. Users are responsible for their conduct.
2. **Client-side reporting** — members who witness illegal content can screenshot and report to law enforcement directly. Hollow can include a "Report to Authorities" button with guidance. The people who CAN see the content (members) are empowered to act.
3. **Community self-moderation** — server owners/admins have full moderation tools (kick, ban, delete messages, manage roles). The community polices itself.
4. **Invite-only servers** — no public server browser, no discovery tab. You can't stumble into a bad server. You must be explicitly invited.

**What Hollow does NOT do (and must never do):**
- No backdoors. A backdoor for law enforcement IS a backdoor for hackers and state actors.
- No client-side content scanning. Destroys the trust model, can be repurposed for censorship.
- No metadata collection "just in case." If you don't have it, you can't be forced to hand it over.
- No age verification. Requires central identity verification, destroys the decentralized model, and doesn't work anyway.

**The ethical position:**
> "We build tools that protect privacy. We don't control how people use them, just like a locksmith doesn't control what people put behind locked doors. The answer to bad actors having privacy is not to take privacy from everyone — it's better policing, better education, and communities that self-moderate."

**The practical reality:** People who would use Hollow for criminal purposes are ALREADY using encrypted tools. Hollow doesn't enable anything new. What it DOES do is give the 99.99% of normal people the privacy they deserve.

**Open source commitment:** The cryptographic and networking layers will be open-sourced for full transparency. Anyone can verify there are no backdoors.

---

### Q: What makes Hollow different from all the other "Discord alternatives"?

Most alternatives are just reskins of the same architecture:

| Alternative | What it really is |
|---|---|
| Revolt | Web client + centralized servers (just Discord with different branding) |
| Guilded | Was promising, got acquired by Roblox |
| Element/Matrix | Powerful protocol, but federated (homeservers), Electron client, designed-by-committee UX |
| Spacebar | Literally reimplements Discord's API |

**Hollow's actual differentiators:**
1. **Shared Vault** — No other platform distributes storage across members.
2. **Truly native** — Flutter, not Electron. 50-80 MB, not 300 MB.
3. **Zero infrastructure** — No servers to host, no cloud bills, no company that can shut down.
4. **The community IS the server** — members collectively host, store, and relay. The more members, the stronger and faster the server gets.
5. **E2EE everything** — not optional, not partial. Messages, files, calls, screen shares. All of it.

---

> *"The best server is no server at all — it's every member, together."*
