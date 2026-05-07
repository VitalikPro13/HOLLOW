# Hollow Protocol Whitepaper

**Version 0.3.0**\
**Author: AnonListen**

---

## Abstract

Hollow is a fully distributed, end-to-end encrypted communication platform. There are no central servers that store messages, files, or metadata. Members of a server collectively host it — the relay is a zero-knowledge signaling pipe that routes encrypted blobs between peers without any ability to read, modify, or store them.

Hollow provides real-time text messaging, voice and video calls, screen sharing, file sharing, and distributed storage — all with end-to-end encryption. The protocol is designed so that even a fully compromised relay operator learns nothing beyond which peer IDs are connected and which rooms they occupy.

This document describes the Hollow protocol as implemented in the Alpha release. It covers the cryptographic architecture, networking model, synchronization protocol, and security properties. It is not an implementation guide — it describes the system at the protocol level so that its security properties can be evaluated independently of the source code.

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [Identity](#2-identity)
3. [Direct Message Encryption (Olm / Double Ratchet)](#3-direct-message-encryption-olm--double-ratchet)
4. [Server Encryption (MLS)](#4-server-encryption-mls)
5. [Voice, Video, and Screen Share Encryption (SFrame)](#5-voice-video-and-screen-share-encryption-sframe)
6. [File Transfer Encryption](#6-file-transfer-encryption)
7. [Hollow Share (Private P2P File Distribution)](#7-hollow-share-private-p2p-file-distribution)
8. [Vault (Distributed Encrypted Storage)](#8-vault-distributed-encrypted-storage)
9. [CRDT Synchronization](#9-crdt-synchronization)
10. [Relay Architecture](#10-relay-architecture)
11. [WebRTC Transport Layer](#11-webrtc-transport-layer)
12. [Message Signing and Verification](#12-message-signing-and-verification)
13. [The Rat Files (Cryptographic Evidence)](#13-the-rat-files-cryptographic-evidence)
14. [Gossip Overlay Network](#14-gossip-overlay-network)
15. [Anti-Censorship Transport](#15-anti-censorship-transport)
16. [Twitch Community Verification](#16-twitch-community-verification-optional)
17. [Summary of Cryptographic Primitives](#17-summary-of-cryptographic-primitives)
18. [Threat Model](#18-threat-model)
19. [Limitations and Future Work](#19-limitations-and-future-work)

---

## 1. Introduction

### 1.1 Design Goals

- **Zero-knowledge relay.** The relay sees room membership and peer IDs. It cannot read message contents, encryption keys, file data, or any application-layer semantics.
- **No accounts.** Identity is a cryptographic keypair derived from a BIP-39 mnemonic. There is no email, phone number, or username registration.
- **Forward secrecy.** DM sessions use the Double Ratchet algorithm. Server sessions use MLS epoch rotation. Compromising a long-term key does not reveal past messages.
- **Decentralized state.** Server metadata (channels, members, roles, settings) is synchronized via CRDTs with no authoritative source. Any online member can serve as a sync peer.
- **Verifiable authorship.** Every message carries an Ed25519 signature over a canonical payload. Recipients verify that the claimed sender actually authored the message. Exported messages are cryptographically unforgeable — stronger than screenshots.
- **Distributed storage.** Server files are distributed across members using adaptive erasure coding. No single member's departure causes data loss.
- **Zero VPS bandwidth for media.** Voice, video, screen sharing, and file transfers flow over peer-to-peer WebRTC connections. The relay carries only signaling.

### 1.2 Architecture Overview

Hollow consists of three components:

1. **The client application** — a native binary (not Electron) that handles UI, state management, and all cryptographic operations. The backend is written in Rust, the UI in Flutter (Dart), connected via FFI.

2. **The relay server** — a lightweight WebSocket router that forwards encrypted messages between room members. It is a dumb pipe with no knowledge of application semantics. The relay is open-source.

3. **The WebRTC mesh** — direct peer-to-peer connections between clients for heavy data transfer (files, voice, video, screen share). Established via signaling through the relay.

```
Client A ──WSS──► ┌─────────────────┐ ◄──WSS── Client B
                  │   WS Relay      │
                  │  (zero-knowledge│
                  │   message router)│
Client C ──WSS──► │                 │ ◄──WSS── Client D
                  └─────────────────┘
                         ▲
                     Signaling only
                         │
          Client A ◄── WebRTC P2P ──► Client B
                    (voice, video,
                     files, shards)
```

**Data flow for a server channel message:**
1. Message is signed with Ed25519 and wrapped in a `MessageEnvelope`.
2. Envelope is MLS-encrypted (one encrypt operation for the entire server group).
3. Encrypted ciphertext is sent via WebSocket to the relay.
4. Relay broadcasts to all room members (it cannot read the content).
5. Each member decrypts via MLS, verifies the Ed25519 signature, stores in the local encrypted database.

**Data flow for a DM:**
1. Message is signed and wrapped in a `MessageEnvelope`.
2. Envelope is Olm-encrypted (Double Ratchet, per-session keys).
3. Sent to the peer via the relay (direct message, not broadcast).
4. Peer decrypts via Olm, verifies the signature, stores locally.

---

## 2. Identity

### 2.1 Key Generation

Each Hollow identity is an **Ed25519 keypair** (256-bit secret, 256-bit public).

The keypair is derived from a **BIP-39 mnemonic** (24 words, 256 bits of entropy):

1. Generate 32 bytes of cryptographically secure randomness.
2. Encode as a BIP-39 mnemonic (24 words from the English wordlist).
3. Derive a 64-byte seed via PBKDF2-HMAC-SHA512 (2048 rounds, empty passphrase).
4. Use the first 32 bytes as the Ed25519 secret key.
5. Derive the public key from the secret key.

The mnemonic is shown to the user once at account creation and never transmitted. It serves as the sole identity recovery mechanism.

### 2.2 Peer ID

The peer ID is a **base58-encoded identity multihash** of the public key:

```
PeerId = Base58( [0x00, length, public_key_protobuf] )
```

Public key protobuf encoding: `[0x08, 0x01, 0x12, 0x20, <32-byte Ed25519 public key>]` (36 bytes).

Peer IDs are deterministic: the same mnemonic always produces the same peer ID. This format begins with `12D3KooW...` and is used as the universal identifier throughout the protocol.

### 2.3 Local Storage Encryption

All local data is stored in **SQLCipher** (AES-256-CBC encrypted SQLite). The database encryption key is derived from the first 32 bytes of the keypair's protobuf encoding, hex-encoded as a passphrase. The database is inaccessible without the keypair.

### 2.4 Account Recovery

Two recovery methods are implemented:

**Mnemonic recovery:** The 24-word BIP-39 phrase deterministically regenerates the identity keypair. Identity-only recovery — server memberships and message history require re-sync from peers.

**Encrypted backup:** Full account state (identity key + encrypted database + optional vault shards) is exported as a passphrase-protected `.hollow` file. The passphrase is processed through Argon2id (64 MB memory cost, ~500ms per attempt) to derive an AES-256-GCM encryption key. Brute-force resistant by design.

---

## 3. Direct Message Encryption (Olm / Double Ratchet)

DMs between two peers use the **Olm protocol** (Double Ratchet with Curve25519 key exchange) via the `vodozemac` library — the same cryptographic implementation used by Matrix/Element.

### 3.1 Session Establishment

1. **Key request.** Peer A sends a `KeyRequest` to Peer B via the relay.
2. **Key bundle.** B generates a one-time Curve25519 key and responds with a `KeyBundle` containing its identity key and one-time key.
3. **Outbound session.** A creates an outbound Olm session using B's keys. The first message is a PreKey message (type 0).
4. **Inbound session.** B creates an inbound session from the PreKey message.
5. **Session acknowledgement.** A `SessionAck` handshake upgrades both sides to Normal (type 1) ratchet mode.

### 3.2 Double Ratchet Properties

- Every message uses a unique encryption key derived via the ratchet.
- Forward secrecy: compromising current keys does not reveal past messages.
- Post-compromise security: a new DH exchange heals the session after compromise.
- Message keys are deleted after use.

### 3.3 State Persistence

Olm session state is serialized ("pickled") to JSON and stored in SQLCipher. Sessions survive application restarts. Stale sessions (unused for 7+ days) are automatically pruned to limit storage growth.

### 3.4 Key Exchange via Relay

Key bundles travel as signed JSON messages through the relay. The relay sees base64-encoded key material but cannot derive session keys without the private Curve25519 keys, which never leave the device.

---

## 4. Server Encryption (MLS)

Servers (group chats) use **Messaging Layer Security (MLS)**, RFC 9420.

### 4.1 Ciphersuite

```
MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519
```

- Key encapsulation: X25519 (Curve25519 DH)
- AEAD: AES-128-GCM
- Hash: SHA-256
- Signature: Ed25519

### 4.2 Group Lifecycle

**One MLS group per server.** All channels within a server share a single MLS group. Channel routing is handled at the application layer.

**Creating a server:**
1. Creator generates an MLS KeyPackage and creates a new MlsGroup.
2. The group's ratchet tree is initialized with the creator as the sole member.

**Adding members:**
1. The MLS coordinator generates a Commit + Welcome message via `group.add_members()`.
2. The Welcome is sent to the joining peer, containing the group secrets.
3. The joiner initializes their group state from the Welcome.
4. Batch processing: a 2-second timer collects concurrent join requests, deduplicating by peer ID.

**Removing members:**
1. Any authorized member generates a Commit via `group.remove_members()`.
2. The commit is broadcast to all remaining members.
3. The epoch advances, rotating all group keys. The removed member cannot derive the new group secret.
4. Batch removal: when multiple members are removed simultaneously (e.g., recovery after prolonged offline), removals are batched into a single Commit (2 epoch advances total instead of 2 per member).

**Rejoining after removal (ban/unban cycle):**
A peer who was removed and later re-invited must drop its stale MLS group state and bootstrap from scratch. The rejoining peer sends a fresh KeyPackage to the coordinator. Without this, the rejoining peer's stale epoch causes one-way decryption failure.

### 4.3 Distributed Coordinator Model

MLS operations (add/remove) require a single member to generate the Commit. Hollow uses **deterministic coordinator election**: the online member with the lexicographically lowest peer ID in the MLS group acts as coordinator. This avoids conflicts without requiring consensus, and ensures any member can onboard new joiners — not just the server owner.

### 4.4 Epoch and Key Rotation

Every membership change advances the MLS **epoch**. Each epoch derives fresh encryption keys. An attacker who compromises keys from one epoch cannot decrypt messages from other epochs.

### 4.5 Targeted Peer-to-Peer Encryption

Server-context operations that target a specific peer — shard requests/responses, sync payloads, file transfers, voice SDP/ICE signaling — use **Olm + direct send** instead of MLS broadcast. This is O(1) per operation instead of O(n) broadcast, and avoids churning the MLS group ratchet for peer-to-peer work. MLS broadcast is reserved for channel messages that all members need to see.

### 4.6 Reconnection Caveat

After a WebSocket reconnection, a peer's MLS epoch may be stale. Messages that must work immediately after reconnection — sync requests, shard coordination, voice channel state changes — are sent as plaintext `HavenMessage` envelopes. This is a deliberate design choice: these messages are idempotent probes that carry no sensitive content.

---

## 5. Voice, Video, and Screen Share Encryption (SFrame)

Real-time media streams are encrypted with **SFrame** (Secure Frames) using keys derived from the MLS epoch.

### 5.1 Key Derivation

**Server voice channels:** The SFrame key is derived from the MLS group's epoch:

```
SFrame key = MLS group.export_secret("sframe", context=[], key_length=32)
```

Each MLS epoch produces a unique 32-byte SFrame key. When the epoch advances (member join/leave), the SFrame key rotates automatically.

**1:1 DM calls:** A random 32-byte key is generated per call and transmitted inside the Olm-encrypted `CallInvite` message.

### 5.2 Encryption

- **Algorithm:** AES-128-GCM
- **Key:** Derived per the SFrame specification from the exported secret
- **Per-frame encryption:** Each audio and video frame is independently encrypted

### 5.3 Scope

SFrame E2EE is applied to:

- **Voice calls** (1:1 DM calls and server voice channels)
- **Video calls** (1:1 DM calls and server voice channels)
- **Screen sharing** (1:1 DM screen share and server voice channel screen share)
- **System audio capture** (screen share with audio on supported platforms)

All media types — audio tracks, video tracks, and screen share tracks — are encrypted with the same SFrame key for a given session or epoch.

### 5.4 Transport

Voice, video, and screen share travel over **WebRTC peer-to-peer connections** (DTLS-SRTP as the base transport, SFrame as the application-layer encryption). The relay is not in the media path — it carries only WebRTC signaling (SDP offers/answers, ICE candidates).

For peers behind symmetric NATs (~10-15% of users), a **TURN server** relays the encrypted media. The TURN server sees only SFrame ciphertext.

### 5.5 Call Topologies

- **1:1 calls:** Direct peer-to-peer WebRTC. Lowest latency, no intermediary.
- **Small group (2-5 participants):** Full mesh — every participant sends to every other participant.
- **Larger group (6+ participants):** Gossip-tree forwarding. Each participant forwards received audio/video to their connected subset of peers (6-12 neighbors). Covers large groups in 2-3 hops. No central media server. Zero VPS bandwidth for media.
- **Transition:** Automatic with hysteresis — mesh below 6 participants, gossip at 6+, back to mesh at 4.

### 5.6 Key Index Synchronization

SFrame cryptors must be initialized with the correct key index corresponding to the current MLS epoch (`epoch % 16`). New keys are applied via key rotation (not replacement) to update all existing cryptor indices atomically. The key index is explicitly set per peer after every cryptor creation. Without this, cryptors default to key index 0 and silently fail to decrypt frames encrypted under a non-zero epoch index.

### 5.7 SFrame Key Memory Handling

SFrame keys are zeroed in memory after use. Key bytes are cleared via `fillRange(0, length, 0)` in `finally` blocks at every site where keys are set or consumed.

---

## 6. File Transfer Encryption

### 6.1 Direct File Transfer (P2P)

Files are encrypted before transmission:

- **Algorithm:** AES-256-GCM
- **Key:** 32 bytes, randomly generated per file
- **Nonce:** 12 bytes, randomly generated per file
- **Auth tag:** 16 bytes (implicit in GCM)

The entire file is encrypted as a single unit. The AES key and nonce are transmitted inside the `FileHeader` message, which is encrypted via Olm (DMs) or MLS (servers). File bytes are streamed separately over WebRTC data channels (peer-to-peer) with a fallback to WebSocket relay streaming.

### 6.2 Transport Priority

1. **WebRTC data channel** (direct P2P) — preferred. ~9 MB/s throughput (depends on the Internet connection speed).
2. **WebSocket relay streaming** — fallback when WebRTC is unavailable. Relay forwards the encrypted bytes without reading them.

File metadata (name, size, AES key, nonce) always travels through the encrypted channel (Olm/MLS via relay). Only the encrypted file bytes use the WebRTC data channel. This separation ensures that even if the P2P connection is compromised, the encryption key is not exposed.

### 6.3 Image Processing

All images are auto-converted to Balanced WebP on send (~95% smaller than PNG/JPEG; similar quality). Metadata (EXIF, GPS, camera info) is stripped before transmission. Configurable quality tiers: Lossless (100%), Balanced (50%), Small (30%).

---

## 7. Hollow Share (Private P2P File Distribution)

Share is a chunked, resumable, multi-source P2P file distribution system — conceptually similar to BitTorrent but with end-to-end encryption, no tracker, no IP exposure, and no public DHT.

### 7.1 Chunk Encryption

- **Algorithm:** AES-256-GCM
- **Key:** 32 bytes, randomly generated per share
- **Chunk size:** 262,144 bytes (256 KiB)
- **Nonce derivation:** `[0x00; 4] || chunk_index_big_endian_u64` (12 bytes)
  - Deterministic: same key + different chunk index = unique nonce
  - No nonce reuse within a share's lifetime

### 7.2 Manifest

```json
{
  "version": 1,
  "file_name": "...",
  "mime": "...",
  "total_size": 123456789,
  "chunk_size": 262144,
  "chunk_count": 472,
  "chunk_hashes": ["<SHA-256 hex of each ciphertext chunk>", ...],
  "created_at": 1713456789
}
```

**Root hash:** SHA-256 of the canonical JSON manifest. Serves as the content identifier.

### 7.3 Share Link

```
hollow://share/<base64url([version: 1 byte][root_hash: 32 bytes][key: 32 bytes])>
```

65-byte payload, 87 base64url characters, QR-code compatible. The link encodes everything needed to verify and decrypt the file. Anyone with the link can download; anyone without it cannot. The link IS the access control.

### 7.4 Peer Discovery and Chunk Transport

- **Relay rendezvous:** Peers join a relay room keyed by the root hash. The relay forwards only signaling — zero file bytes ever touch the relay.
- **STUN-only WebRTC:** Share connections use STUN (no TURN) so share traffic never consumes relay bandwidth. If no peer-to-peer connection can be established, chunks are skipped (not relayed).
- **No IP exposure:** ICE candidates are exchanged via the encrypted relay, never published to a public DHT.
- **ISP-invisible:** Looks like normal WebRTC traffic with no protocol fingerprint to throttle.

### 7.5 Download Protocol

- **Have-map exchange:** Compact bitmaps (MSB-first, 1 bit per chunk) broadcast every 10 seconds.
- **Rarest-first scheduling:** BitTorrent-style piece selection across all connected peers.
- **Chunk verification:** SHA-256 of each received ciphertext chunk is verified against the manifest before decryption. Tampered chunks are rejected and re-requested from a different peer.
- **Max 4 inflight chunks per peer** to avoid WebRTC data channel buffer overflow.
- **Receiver-initiated WebRTC reconnection** with 10-second stale-offer timeout.
- **Bandwidth management:** Process-wide token bucket (20 MiB/s refill, 40 MiB burst). Scheduler pauses for 200ms after any messaging or voice traffic to avoid interference.

### 7.6 Persistence and Seeding

- Download state (have-bitmap, chunk progress) is persisted to the local database. Paused or interrupted downloads resume without re-fetching.
- Completed files automatically seed. Seeding state survives app restarts.
- Zero-copy seeding: the original file is read directly. Chunks are encrypted on-the-fly with AES-256-GCM (~50µs per 256 KiB chunk on AES-NI hardware).

---

## 8. Vault (Distributed Encrypted Storage)

The Vault provides persistent distributed storage for server files (doesn't include images) using adaptive erasure coding. Every member donates storage. Files are encrypted before erasure coding, so shard-holding members see only encrypted noise.

### 8.1 File Encryption

Files are encrypted **before** erasure coding:

- **Algorithm:** AES-256-GCM
- **Key/nonce:** Random per file, stored in the manifest (encrypted via MLS for the server)

### 8.2 Adaptive Storage Modes

**Small servers (<6 members) — Full Replication:**
Every file is synced to every member. Simple, reliable. Storage overhead: N× (where N = member count).

**Larger servers (6+ members) — Reed-Solomon Erasure Coding:**
Files are split into `k` data shards + `m` parity shards. Any `k` of `k+m` shards can reconstruct the original ciphertext.

| Members | k | m | Total shards | Tolerance | Overhead |
|---------|---|---|-------------|-----------|----------|
| < 6 | — | — | Full replication | All but 1 | N× |
| 6-8 | 3 | 2 | 5 | 2 offline | 1.67× |
| 9-15 | 5 | 3 | 8 | 3 offline | 1.60× |
| 16-30 | 8 | 4 | 12 | 4 offline | 1.50× |
| 31-60 | 10 | 5 | 15 | 5 offline | 1.50× |
| 61-150 | 12 | 6 | 18 | 6 offline | 1.50× |
| 151-500 | 16 | 8 | 24 | 8 offline | 1.50× |
| 500+ | 20 | 10 | 30 | 10 offline | 1.50× |

Parameters scale with `log(member_count)`, overhead converges to 1.5×. Computed automatically — no admin configuration needed.

### 8.3 Content-Addressed Storage

Every piece of data is addressed by its SHA-256 hash:

```
content_id = SHA-256(encrypted_data)
```

This provides deduplication, integrity verification, and location-independent addressing.

### 8.4 Deterministic Shard Placement (XOR Distance)

Shard placement is deterministic — all peers compute the same placements independently:

1. `content_id = SHA-256(encrypted_data)`
2. For each shard `i`: `shard_key = SHA-256(content_id || i_as_u16_be)`
3. For each peer: `distance = XOR(shard_key, SHA-256(peer_id))`
4. Sort peers by distance (ascending), assign shard to closest peer with available capacity.
5. Weighted by storage pledge: peers with larger pledges get proportionally more shards.

Any peer can independently recompute placements using the content ID + member list + pledges (all available via CRDT). No central directory needed.

### 8.5 Shard Format

```
[header_length: u32 LE][header JSON][shard data]
```

Header:
```json
{
  "shard_index": 0,
  "content_id": "<SHA-256 hex>",
  "k": 4,
  "m": 2,
  "shard_size": 65536,
  "total_data_size": 250000
}
```

### 8.6 Storage Tiers and Retention

| Data Type | Tier | Default Retention |
|-----------|------|-------------------|
| All files | Standard (1.0× parity) | 365 days |
| Channel messages | Configurable via CRDT | 365 days (default) |

Retention is forward-only: changing the retention setting only affects content created after the change. Existing files and messages keep their original retention. This prevents retroactive evidence destruction. Message retention is a per-server CRDT setting; file retention is per-tier.

### 8.7 Self-Healing and Rebalancing

When a member departs:
1. Surviving members detect under-replicated content by comparing confirmed placements against online peers.
2. The vault coordinator (2nd-lowest online peer ID) computes a repair plan: which missing shards to regenerate and where to place them. The vault coordinator is intentionally separated from the MLS coordinator (lowest peer ID) to distribute work across peers.
3. Peers with sufficient shards reconstruct the missing ones via Reed-Solomon decoding and redistribute them.

When a new member joins:
1. Placements are recomputed with the new member included.
2. A migration plan moves shards from over-capacity peers to the new member.
3. Migration happens gradually in the background.

### 8.8 Storage Layout

- Shards: `~/.hollow/vault/{server_id}/{shard_key}.shard`
- Decrypted cache: `~/.hollow/vault_cache/{content_id}.{ext}` (LRU-evicted, 1 GB cap)
- Full-replication files: `~/.hollow/files/{file_id}.{ext}`

---

## 9. CRDT Synchronization

Server state (channels, members, roles, settings) is replicated across all members using **Conflict-free Replicated Data Types (CRDTs)**.

### 9.1 Hybrid Logical Clock (HLC)

All CRDT operations are timestamped with a **Hybrid Logical Clock**:

```
HlcTimestamp {
    physical_ms: u64,   // wall clock (milliseconds since epoch)
    counter: u32,       // logical counter for same-millisecond ordering
    actor: String,      // peer ID (tiebreaker for simultaneous events)
}
```

Properties:
- Monotonically increasing per actor.
- Causally consistent: if event A happened before event B, A's HLC < B's HLC.
- **Clock drift protection:** Updates more than 5 minutes ahead of local time are rejected.
- Deterministic total order via `(physical_ms, counter, actor)` tuple.

### 9.2 Operation Format

```
CrdtOp {
    server_id: String,
    hlc: HlcTimestamp,
    author: String,         // peer ID of originator
    payload: CrdtPayload,  // the actual mutation
}
```

### 9.3 Payload Types

| Category | Operations |
|----------|-----------|
| Server | ServerCreated, ServerRenamed, ServerSettingChanged (includes retention settings) |
| Channels | ChannelAdded, ChannelRemoved, ChannelRenamed |
| Members | MemberAdded, MemberRemoved, MemberBanned, MemberUnbanned |
| Roles | RoleChanged (owner/admin/moderator/member) |
| Labels | LabelAdded, LabelRemoved, LabelUpdated, LabelAssigned, LabelUnassigned |
| Messages | MessagePinned, MessageUnpinned |
| Storage | StoragePledgeChanged |

### 9.4 Conflict Resolution

**Last-Write-Wins (LWW)** per key, ordered by HLC timestamp. For role conflicts, a priority system applies:

| Role | Priority |
|------|----------|
| Owner | 3 |
| Admin | 2 |
| Moderator | 1 |
| Member | 0 |

Higher-priority role changes always override lower-priority ones. Admin writes always win over member writes for server settings (AdminLwwReg).

### 9.5 Synchronization Protocol

When two peers connect:
1. Each sends a **state vector** — a compact summary of the latest HLC timestamp seen from each author.
2. Each computes the delta: operations it has that the other lacks.
3. Deltas are transmitted as batches of `CrdtOp` values.
4. Both peers converge to the same state.

This is idempotent: applying the same operation twice has no effect. Peers can sync with any other online member — there is no single source of truth.

### 9.6 Security

CRDT operations are validated on receipt:
- The `author` field is verified against the actual sender's peer ID (prevents forged authorship).
- Permission checks ensure the author has the required role for the operation type (e.g., only admins+ can change roles).
- Unauthorized operations are rejected and logged.

---

## 10. Relay Architecture

### 10.1 Design Principle

The relay is a **zero-knowledge message router**. It routes encrypted blobs between peers based on room membership. It has no knowledge of message semantics, encryption keys, or application state. The relay source code is open-source.

**Implementation:** uWebSockets C++ with native OpenSSL TLS termination (no reverse proxy). Memory footprint: ~13.4 KB per connection (~572k connections on 8 GB VPS, verified with 44.6k simultaneous connections). TLS session resumption is enabled for fast reconnects.

**Privacy hardening:** The relay is configured with all logging disabled. No connection events, peer IDs, IP addresses, or timestamps are written to disk. System journal uses volatile (RAM-only) storage with 1-hour maximum retention. The TURN server (coturn) is configured with `log-file=/dev/null` and `no-stdout-log`. Rsyslog filters discard any relay or TURN messages from system log files.

### 10.2 Authentication

Peers authenticate to the relay via Ed25519 signature:

```
Signed payload: "hollow-ws-auth:{peer_id}:{unix_timestamp}"
```

The relay verifies the signature against the provided public key and checks that the timestamp is within ±60 seconds of server time (replay protection).

### 10.3 Room Model

- Peers join named rooms (alphanumeric + `:-_.`, max 128 characters).
- Each server has a room (room ID = server ID).
- Each DM pair has a room (room ID = deterministic hash of both peer IDs).
- Messages can be broadcast to all room members or sent directly to a specific peer.
- Max 10,000 rooms per peer.
- Max 64 MB per WebSocket binary message; 1 MB per text message (silently dropped if exceeded).

### 10.4 Binary Protocol

Seven binary frame types for efficient transport. Input types (client → relay) are transformed into output types (relay → client):

**Input frames (client sends):**
- **0x01 (Broadcast):** `[0x01][room_hash: 32 bytes][payload]` — forwarded to all room members as-is. Used for WebRTC signaling.
- **0x02 (Direct):** `[0x02][room\0][target_peer\0][payload]` — forwarded to a specific peer. Used for file streaming, shard transfers.
- **0x03 (Msg Broadcast):** `[0x03][room\0][payload]` — universal broadcast for non-channel messages (CRDT sync, key exchange, coordination). Forwarded as **0x05**.
- **0x04 (Direct Msg):** `[0x04][room\0][target\0][payload]` — direct message to a specific peer. Forwarded as **0x06**.
- **0x07 (Topic Broadcast):** `[0x07][room\0][topic\0][payload]` — topic-aware broadcast for channel messages. Only forwarded to peers subscribed to the topic (or wildcard subscribers). Forwarded as **0x08**.

**Output frames (relay sends):**
- **0x05 (Msg Broadcast, forwarded):** `[0x05][room\0][sender\0][payload]` — relay prepends the sender's peer ID.
- **0x06 (Direct Msg, forwarded):** `[0x06][room\0][sender\0][payload]` — relay replaces target with sender.
- **0x08 (Topic Broadcast, forwarded):** `[0x08][room\0][topic\0][sender\0][payload]` — relay prepends sender, preserves topic.

**Topic subscription:** Clients send a `subscribe` JSON command to set per-room topic filters. Peers with no subscription entry for a room receive all messages (wildcard, backwards compatible). Peers with a subscription set receive only messages matching a subscribed topic. Channel messages use 0x07 with `channel_id` as the topic; non-channel messages (CRDT, sync, keys) use 0x03 universal broadcast.

### 10.5 Resource Protection

- **No application-level rate limiting.** Soft backpressure and per-peer rate limits were removed because they silently dropped CRDT sync payloads and broke reconnection flows. Authenticated peers are trusted.
- **Hard backpressure:** 64 MB per connection (uWebSockets built-in). Catches truly dead connections without interfering with legitimate traffic.
- **Text frame cap:** 1 MB. Oversized text frames are silently dropped.
- **Binary frame cap:** 64 MB (uWebSockets `maxPayloadLength`). Connections exceeding this are closed.
- **DoS protection:** Ed25519 authentication + license key revocation. Only authenticated peers can send messages.
- **Room membership enforcement:** Messages are only forwarded to peers in the same room. Non-members' messages are silently dropped.

### 10.6 TURN Credential Management

For peers behind symmetric NATs, the relay provides time-limited TURN credentials:

- HMAC-SHA1 credentials with 1-hour TTL.
- Generated via a `/turn-credentials` HTTP endpoint.
- The TURN server (coturn) validates credentials against the same shared secret.
- Clients auto-refresh credentials every 50 minutes.

### 10.7 What the Relay Sees

| Data | Visible to Relay |
|------|-----------------|
| Peer IDs (in memory) | Yes (not logged to disk) |
| Room membership (in memory) | Yes (not logged to disk) |
| Topic subscriptions (in memory) | Yes — the relay knows which channel topics each peer subscribes to within a room (not logged to disk) |
| Connection timestamps | **No** (relay logging is disabled; volatile journal with 1h retention) |
| Message contents | **No** (encrypted) |
| Encryption keys | **No** |
| File contents | **No** (encrypted) |
| Message signatures | **No** (inside encrypted envelope) |
| User profiles | **No** (encrypted) |
| Voice/video media | **No** (P2P, not relayed) |
| File transfer bytes | **No** (P2P, not relayed) |
| IP addresses | **No** (relay does not log IPs; TURN logging disabled) |

### 10.8 License Key System

The relay supports an optional license key system for controlling access during alpha/beta phases:

- Keys are stored in a `keys.json` file loaded at startup. The system can be enabled or disabled via a toggle.
- Keys are validated during WebSocket authentication. Invalid or already-in-use keys are rejected.
- The key file is hot-reloaded every 30 seconds, allowing key revocation without relay restart.
- Active connections using a revoked key are terminated on the next reload cycle.
- License keys are cached client-side in the encrypted SQLCipher database.

### 10.9 Server Statistics Endpoint

The relay exposes a `/server-stats` endpoint returning real-time operational metrics:

- Memory usage (total/used from `/proc/meminfo`)
- Network throughput (Mbps, computed from `/proc/net/dev` deltas)
- Online user count (connected authenticated peers)
- Bandwidth cap

Statistics are cached for 5 seconds to avoid excessive filesystem reads. This endpoint is used by the client's home dashboard to display relay health.

---

## 11. WebRTC Transport Layer

### 11.1 Architecture

The WebSocket relay handles signaling (SDP offers/answers, ICE candidates). WebRTC data channels and media tracks handle the heavy payload — file bytes, vault shard bytes, voice, video, and screen share. This separation means ~85-90% of data transfer bandwidth is direct peer-to-peer with zero relay involvement.

### 11.2 ICE Configuration

- **STUN servers:** Public STUN servers + self-hosted coturn for server-reflexive candidate discovery.
- **TURN server:** Self-hosted coturn on the VPS for peers behind symmetric NATs.
- **Share exception:** Hollow Share connections use STUN-only (no TURN) to ensure share traffic never consumes relay bandwidth.

### 11.3 Signaling Flow

1. Peer A creates an `RTCPeerConnection` and generates ICE candidates.
2. A sends the SDP offer + ICE candidates to B via the relay (small signaling messages).
3. B creates its own `RTCPeerConnection`, sends the SDP answer + ICE candidates back.
4. ICE negotiation completes (~200ms). Direct P2P connection established (or TURN fallback).
5. Data/media flows over the WebRTC connection — zero relay bandwidth.

### 11.4 Connection Types

| Service | Connection Type | Encryption |
|---------|----------------|------------|
| File transfer | RTCDataChannel | DTLS + AES-256-GCM file encryption |
| Vault shard transfer | RTCDataChannel | DTLS + AES-256-GCM shard encryption |
| Share chunks | RTCDataChannel | DTLS + AES-256-GCM chunk encryption |
| Voice calls | RTCPeerConnection audio tracks | DTLS-SRTP + SFrame |
| Video calls | RTCPeerConnection video tracks | DTLS-SRTP + SFrame |
| Screen share | Separate RTCPeerConnection | DTLS-SRTP + SFrame |

### 11.5 Glare Resolution

When two peers simultaneously attempt to establish a connection, the **polite-peer protocol** resolves the conflict: the peer with the lexicographically smaller peer ID drops its own offer and accepts the remote one. ICE candidates arriving before the connection is ready are queued.

### 11.6 Backpressure

`getBufferedAmount()` monitoring prevents WebRTC data channel SCTP buffer overflow. The sender pauses when the buffer exceeds the threshold and resumes when it drains. Max 4 inflight chunks per peer for Share.

---

## 12. Message Signing and Verification

### 12.1 Canonical Signing Payload

Every message carries an Ed25519 signature over a canonical string:

```
hollow-msg:{type}:{context}:{sender}:{timestamp_ms}:{text}
```

| Field | Value |
|-------|-------|
| type | `"ch"` (channel) or `"dm"` (direct message) |
| context | `"{server_id}:{channel_id}"` for channels; `"{recipient_peer_id}"` for DMs |
| sender | Sender's peer ID |
| timestamp_ms | Milliseconds since Unix epoch (i64) |
| text | Message body (may be empty for file-only messages) |

### 12.2 Verification

1. Decode the sender's Ed25519 public key from the protobuf-encoded bytes.
2. Derive the peer ID from the public key (identity multihash → base58).
3. Verify that the derived peer ID matches the claimed sender.
4. Verify the Ed25519 signature over the canonical payload using strict verification (`verify_strict`), which rejects non-canonical signatures (small-order group elements, malleable S values).

If any step fails, the message is rejected. This prevents impersonation: even if an attacker can inject messages into the encrypted channel, they cannot forge a valid signature without the sender's private key.

### 12.3 Timestamp Integrity

The timestamp in the signature payload is authoritative. The UI hydrates its display timestamp from the Rust-signed value, not from the local clock. This prevents timestamp manipulation on the receiver side.

### 12.4 Edit and Delete Signing

Message edits and deletions carry their own signatures over canonical payloads. The edit chain is preserved: each edit records the previous signature, public key, and timestamp, creating a verifiable history. Deletion operations are signed events, not tombstones.

---

## 13. The Rat Files (Cryptographic Evidence)

Hollow's architecture ensures that **nobody can remotely destroy evidence**. Messages are digitally signed, locally stored, and distributed — no central authority can issue a "delete from all devices" command.

### 13.1 Evidence Properties

- **Non-repudiation:** Every message carries an Ed25519 signature. The sender cannot deny authorship.
- **Integrity:** Any modification to a message invalidates its signature.
- **Unforgeable:** Unlike screenshots, Hollow message proofs are cryptographically verifiable by any third party with standard Ed25519 tools.
- **Survivable:** Even if the server owner kicks everyone and dissolves the server, evidence persists on ex-members' devices.

### 13.2 Message Proof Export

Any message can be exported as a JSON proof containing:
- Message text, timestamp, and context (server/channel or DM)
- Sender's Ed25519 public key
- The canonical signing payload
- The Ed25519 signature
- Verification instructions

Anyone can verify the proof independently using standard Ed25519 libraries — no Hollow installation required.

### 13.3 Archive Format (.hollow-archive)

A portable, cryptographically verified export format for conversation history:

- **Per-message signatures** preserved from the live database.
- **Edit history** with per-edit signatures (old text, new text, timestamps, each independently verifiable).
- **Deletion records** with per-delete signatures (the deleted text is preserved, the delete operation itself is signed).
- **Reaction removal evidence** (who removed which reaction, when, signed).
- **File embedding** with SHA-256 integrity hashes (three modes: full, images-only, placeholder).
- **Archive-level signature:** The exporter's Ed25519 key signs a deterministic hash of the entire archive contents. This catches selective omission — it attests that the archive is the exporter's complete record.

### 13.4 Evidence Recovery (Cooperative Shard Gathering)

When a server is dissolved, ex-members can cooperatively reconstruct files they no longer have locally:

1. Ex-members who held vault shards still have them on their devices.
2. Shards can be exchanged via a relay-coordinated recovery pool or exported/imported as `.hollow-shards` bundles.
3. Once `k` shards are gathered for a file, Reed-Solomon decoding reconstructs the encrypted ciphertext.
4. Members who were in the server hold the MLS epoch keys to decrypt.
5. All original signatures remain intact and verifiable.

---

## 14. Gossip Overlay Network

### 14.1 Connection Subset Management

For large servers, maintaining a full mesh of WebRTC connections is impractical. Hollow limits persistent connections to 6-12 peers per server (50 total across all servers).

### 14.2 Peer Scoring

Peers are scored on four metrics:
- **Uptime ratio:** Connection duration relative to total time.
- **Average latency:** Round-trip time measured via data channel pings.
- **Bandwidth score:** Observed throughput on data transfers.
- **Shard overlap:** Number of shared vault shards (high overlap = high value for shard retrieval).

At adaptive intervals (120s/180s/240s, scaled by server member count), the lowest-scoring peer is dropped and the highest-scoring unconnected peer is added. Max 1 rotation per cycle for stability.

### 14.3 Gossip Broadcast

When a peer receives data tagged as broadcast (files, images, voice media), it re-forwards to its connected WebRTC subset (minus the source). This creates a gossip tree that covers 1000+ members in ~3 hops (~600ms), with zero relay bandwidth.

- **Broadcast deduplication:** Each broadcast carries a unique ID. Peers track recent IDs and drop duplicates.
- **TTL / hop limit:** 4-5 hops maximum to prevent infinite propagation. Default TTL is included in the broadcast metadata.
- **Fallback:** Fewer than 6 reachable peers → connect to all available.

### 14.4 Peer Exchange

Connected peers share known peer lists for each server via `PeerExchange` messages sent directly to each neighbor (not broadcast). This enables peer discovery beyond the directly connected subset. Peer exchange is capped at 50 entries and only accepted from current gossip neighbors.

---

## 15. Anti-Censorship Transport

### 15.1 Baseline Protection

Hollow's standard transport (WebSocket over TLS on port 443) looks like normal HTTPS traffic to network observers. This is sufficient in most environments.

### 15.2 Research and Testing

Extensive testing was conducted against Russia's TSPU deep packet inspection system:

- **Shadowsocks-2022** (`2022-blake3-aes-256-gcm`) was implemented and tested. It works on many ISPs but Russia's TSPU detects the encapsulated traffic pattern on some ISPs, killing connections after ~20 seconds. The implementation was removed from the codebase after testing — it did not reliably defeat the most aggressive DPI configurations.
- **VLESS+Reality** was blocked by TSPU at a ~15-20 KB payload threshold.
- **VPN tunnels** (WireGuard, OpenVPN, IKEv2) are all blocked in Russia.
- **Regular VPN** works, confirming the issue is protocol fingerprinting, not IP blocking.

### 15.3 Future: TLS Camouflage

A TLS camouflage tunnel (REALITY-style) is planned to make tunnel traffic indistinguishable from a real HTTPS connection to a popular domain. This approach has <5% detection rate against the most advanced DPI systems. The architecture would reuse the same local-tunnel-to-VPS pattern that was tested with Shadowsocks — only the tunnel protocol would change.

---

## 16. Twitch Community Verification (Optional)

Server owners can optionally gate membership behind Twitch follow or subscription verification. This provides community identity verification without requiring any personal information.

### 16.1 OAuth Flow

Verification uses the **Device Code Grant** flow (OAuth 2.0 RFC 8628):

1. The client requests a device code from Twitch via the relay's `/twitch/device-code` proxy endpoint.
2. The user visits a Twitch URL in their browser and enters the code.
3. The client polls for completion. On success, it receives an OAuth access token.
4. The token is used once to verify follow/subscription status, then discarded.

The relay proxies Twitch API requests to avoid exposing the Twitch Client ID to clients. The relay never sees or stores the user's OAuth token — only the verification proof is retained.

### 16.2 Verification Proof

After verification, a cryptographic proof is generated and broadcast to the server:

- The proof contains the peer ID, Twitch username, verification type (follow/subscriber), and timestamp.
- The proof is signed with the peer's Ed25519 key.
- Server members verify the signature and store the proof locally.
- The proof is re-verified on each server join if the owner requires "owner must be online" verification mode.

### 16.3 Privacy Properties

- No Twitch data is stored on the relay or any server infrastructure.
- The OAuth token is ephemeral — used once and discarded.
- Verification status is stored only in each peer's local encrypted database.
- The server owner's Twitch channel name is the only Twitch-related data shared among members.

---

## 17. Summary of Cryptographic Primitives

| Component | Algorithm | Key Size | Purpose |
|-----------|-----------|----------|---------|
| Identity | Ed25519 | 256-bit | Keypair generation, peer ID derivation |
| Mnemonic | BIP-39 | 256-bit entropy (24 words) | Deterministic key recovery |
| DM encryption | Olm (Double Ratchet / Curve25519) | 256-bit | 1:1 message encryption with forward secrecy |
| Server encryption | MLS (X25519 + AES-128-GCM + SHA-256 + Ed25519) | 128-bit AEAD | Group message encryption with O(log n) member changes |
| Voice/video/screen share | SFrame (AES-128-GCM, MLS-derived keys) | 128-bit | Per-frame real-time media encryption |
| File encryption | AES-256-GCM | 256-bit key, 96-bit nonce | Per-file encryption before transfer/storage |
| Share chunks | AES-256-GCM (deterministic nonce per index) | 256-bit key, 96-bit nonce | Per-chunk encryption for P2P distribution |
| Vault shards | AES-256-GCM (pre-erasure-coding) | 256-bit key, 96-bit nonce | File encryption before shard distribution |
| Erasure coding | Reed-Solomon | Adaptive k/m | Fault-tolerant distributed storage |
| Message signing | Ed25519 | 256-bit | Non-repudiable authorship proof |
| Relay auth | Ed25519 (timestamp-bound, ±60s) | 256-bit | WebSocket authentication |
| TURN credentials | HMAC-SHA1 (1-hour TTL) | Shared secret | Time-limited TURN server access |
| CRDT ordering | Hybrid Logical Clock | 64-bit physical + 32-bit counter | Causal event ordering |
| Local storage | SQLCipher (AES-256-CBC) | 256-bit | Database encryption at rest |
| Backup encryption | Argon2id + AES-256-GCM | 256-bit (64 MB memory cost) | Brute-force resistant account backup |
| Twitch verification | Ed25519-signed proof | 256-bit | Verifiable community membership proof |
| Anti-censorship | Planned (TLS camouflage) | — | DPI-resistant transport tunnel (not yet implemented) |

---

## 18. Threat Model

### 18.1 What Hollow Protects Against

| Threat | Protection |
|--------|------------|
| Message content interception | E2EE (Olm for DMs, MLS for servers). Only intended recipients hold decryption keys. |
| Relay compromise | Zero-knowledge design. A fully compromised relay learns only peer IDs, room membership, and connection timestamps. |
| Voice/video eavesdropping | SFrame E2EE. Media is encrypted per-frame. TURN servers see only ciphertext. |
| File content interception | AES-256-GCM per file. Relay and TURN see only encrypted bytes. |
| Man-in-the-middle on key exchange | Authenticated Olm key exchange + Ed25519 identity binding. |
| Storage shard snooping | Encrypt-then-erasure-code. Shards are encrypted; reconstructing all shards yields only ciphertext. |
| Removed member accessing new content | MLS epoch rotation on removal. New epoch derives fresh keys from randomness the removed member doesn't have. |
| Message forgery | Ed25519 signatures on every message. Invalid signatures are rejected. |
| Evidence destruction | Decentralized storage + cryptographic signatures. No central authority can delete data from other users' devices. |
| CRDT state manipulation | Author verification + role-based permission checks. Unauthorized operations rejected. |
| Clock manipulation attacks | HLC drift bound (5 minutes). Far-future timestamps rejected to prevent LWW conflict gaming. |
| Resource exhaustion | Ed25519 authentication, license key revocation, message size limits (64 MB binary / 1 MB text), 64 MB hard backpressure, connection limits. |
| Privilege escalation | Permission checks on all state-changing operations. CRDT author ≠ self-reported field — verified against actual sender. |

### 18.2 What Hollow Does Not Currently Defend Against

- **Traffic analysis.** Message timing and size patterns are visible to the relay and network observers. Constant-rate padding is not implemented.
- **Local device compromise.** If an attacker has access to an unlocked device with the decrypted database open, they can read everything. This is true of any E2EE system.
- **Relay availability attacks.** A malicious relay can selectively drop or delay messages. The current single-relay architecture has no failover. Multi-relay support is designed but not yet deployed.
- **Quantum computing.** All key exchanges use Curve25519. Migration to ML-KEM (Kyber) is planned but not prioritized for the alpha.
- **Trust-on-first-use (TOFU).** Peer identity verification relies on out-of-band fingerprint comparison. There is no certificate authority or web of trust.

### 18.3 Relay Operator Trust Assumptions

The relay operator is assumed to be **honest-but-curious**: the relay faithfully forwards messages but may attempt to read or log traffic. The protocol is designed so that curiosity yields nothing useful.

The relay operator is also assumed to be potentially **unreliable**: the relay may go offline, and clients auto-reconnect with exponential backoff.

The relay operator is **not trusted** with: message contents, encryption keys, file data, user profiles, message signatures, or any application-layer semantics.

---

## 19. Limitations and Future Work

- **No post-quantum cryptography.** All key exchanges use Curve25519. If quantum computers eventually break elliptic curve crypto, intercepted ciphertext could theoretically be decrypted retroactively. A future migration to ML-KEM (Kyber) is a consideration but not a priority — no consumer chat app has shipped this yet.
- **No traffic analysis protection.** The relay uses native TLS via uWebSockets C++ with OpenSSL (direct TLS termination, no reverse proxy), which protects message *content* from network eavesdroppers. However, message *timing and size patterns* remain visible — an observer can infer who is chatting with whom based on when messages are sent, even without reading them. Defeating this would require constant-rate padding (sending dummy traffic to hide real messages), which is impractical for a chat app.
- **Single relay dependency.** Multi-relay support with cross-relay room gossip is designed but not yet deployed. Horizontal scaling to millions of users via a swarm of relay nodes is the planned architecture.
- **No device linking.** Each device has an independent identity. Multi-device sync (QR code linking) is planned.
- **No social recovery.** Shamir's Secret Sharing for key recovery via trusted contacts is designed but not implemented.

---

*This document describes the Hollow protocol as implemented in the Alpha release. The protocol is subject to change. The relay server source code is open-source. The client application source code is proprietary.*
