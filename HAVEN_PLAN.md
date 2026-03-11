# Haven — A Fully Distributed, Encrypted Discord Alternative

> **Status:** Active Development — Phases 1-3 Complete. Phase 3.5 (Daily Driver — Chat Features & Identity) In Progress.
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

### What Haven Is

A communication platform where **every member collectively hosts the server they belong to**. There is no data center, no cloud subscription, no single point of failure. When you join a Haven server, you donate a small amount of your disk space and bandwidth. In return, the server exists — distributed across everyone's devices — as long as at least one member is online.

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
│                         HAVEN CLIENT                            │
│                     (Flutter Native App)                         │
│                                                                 │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌────────────────┐  │
│  │ UI Layer │  │  E2EE    │  │  CRDT    │  │  Storage       │  │
│  │ (Flutter │  │  Engine  │  │  Sync    │  │  Engine        │  │
│  │  Widgets)│  │          │  │  Engine  │  │  (Chunks +     │  │
│  │          │  │ Signal/  │  │          │  │   Erasure      │  │
│  │          │  │ MLS      │  │ Automerge│  │   Coding)      │  │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └───────┬────────┘  │
│       │              │             │                │            │
│  ┌────┴──────────────┴─────────────┴────────────────┴────────┐  │
│  │                    libp2p (via Rust FFI)                   │  │
│  │  ┌─────────┐  ┌──────────┐  ┌────────┐  ┌─────────────┐  │  │
│  │  │Transport│  │  NAT     │  │  DHT   │  │  Relay /    │  │  │
│  │  │(QUIC/   │  │ Traversal│  │(Kademlia│  │  Hole Punch │  │  │
│  │  │ TCP/WS) │  │ (DCUtR)  │  │        │  │  (DCUtR)    │  │  │
│  │  └─────────┘  └──────────┘  └────────┘  └─────────────┘  │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
          │                    │                    │
          ▼                    ▼                    ▼
    ┌──────────┐        ┌──────────┐        ┌──────────┐
    │ Member A │◄──────►│ Member B │◄──────►│ Member C │
    │(stores   │        │(stores   │        │(stores   │
    │chunks    │        │chunks    │        │chunks    │
    │1,3,5)    │        │2,3,6)    │        │1,4,5)    │
    └──────────┘        └──────────┘        └──────────┘
```

**Data flow for sending a message:**
1. User types message in Flutter UI
2. Message is encrypted with the channel's group key (E2EE Engine)
3. Encrypted message is wrapped in a CRDT operation (CRDT Sync Engine)
4. CRDT operation is broadcast to online peers via libp2p
5. Peers apply the CRDT operation to their local state
6. The encrypted message is also erasure-coded and stored across members (Storage Engine)
7. When offline members come back, they sync missing CRDT operations from peers

---

## 3. Technology Stack

| Layer | Technology | Why |
|---|---|---|
| **Client Framework** | Flutter (Dart) | Single codebase → native Windows, macOS, Linux, Android, iOS, Web. No Electron. |
| **P2P Networking** | rust-libp2p via `flutter_rust_bridge` FFI | Most mature P2P networking stack. No Dart implementation exists, but the Rust lib is excellent and FFI bridging is well-supported in Flutter. |
| **Data Sync** | Automerge (Rust) via FFI | Best CRDT library. Handles merging concurrent edits, message ordering, channel state. Rust implementation is fast. |
| **Distributed Storage** | Custom erasure coding (Reed-Solomon) | Split data into n shards, any k reconstruct the original. 1.5x overhead instead of 3x for triple replication. |
| **E2EE (Messages)** | vodozemac (Olm/Double Ratchet) via Rust FFI for 1:1, MLS for groups | vodozemac is Matrix's audited Olm implementation (X3DH-like + Double Ratchet). MLS (RFC 9420) for group channels — scales O(log n) on member changes. |
| **E2EE (Calls)** | DTLS-SRTP + SFrame | WebRTC native encryption + inner E2EE layer via SFrame for group calls through relay. |
| **Voice/Video** | flutter_webrtc + LiveKit protocol | Mature WebRTC for Flutter. Mesh for small calls (2-4), SFU-like "super peer" for larger groups. |
| **Cryptography** | `cryptography` (Dart) + libsodium (FFI) | `cryptography` for platform-accelerated primitives, libsodium for security-critical operations (constant-time, audited). |
| **Local Database** | SQLite (encrypted via SQLCipher) | All local data encrypted at rest. Fast, embedded, no server needed. |
| **DHT** | Kademlia (via libp2p) | Peer discovery, prekey bundle storage, content routing. O(log n) lookups. |
| **Identity** | Ed25519 keypairs | Public key = identity. No phone numbers, no email. Mnemonic phrase backup. |

### Why Rust FFI Instead of Pure Dart

libp2p and Automerge don't have Dart implementations. Writing them from scratch would take years. The Rust ecosystem has battle-tested implementations. `flutter_rust_bridge` provides ergonomic, type-safe FFI between Dart and Rust with async support, so:

- **Dart** handles UI, app logic, state management (what it's great at)
- **Rust** handles networking, crypto, storage engine, CRDTs (what it's great at)
- **FFI bridge** connects them with minimal overhead

This is the same pattern used by major apps (e.g., Signal uses Rust for its crypto library across all platforms).

---

## 4. Distributed Storage System — "Shared Vault"

This is the core innovation. Every member donates storage. The server's data lives across everyone's devices.

### How It Works

#### 4.1 Storage Pledge

When joining a server, each member pledges a minimum amount of storage (set by the server admin, e.g., 1 GB). Members can optionally donate more.

```
Server: "Cozy Community"
Members: 100
Minimum pledge: 1 GB
Total raw pool: 100 GB (minimum) + voluntary donations
Usable capacity: ~60 GB (after erasure coding overhead)
```

#### 4.2 Erasure Coding (Reed-Solomon)

Instead of storing 3 full copies of everything (3x overhead), use erasure coding:

- Split each piece of data into **k** data shards
- Generate **m** parity shards (using Reed-Solomon coding)
- Total **n = k + m** shards
- Any **k** of the **n** shards can reconstruct the original data

**Example configuration for a 100-member server:**
- k = 10 data shards, m = 5 parity shards (n = 15 total)
- Overhead: 1.5x (vs 3x for triple replication)
- Tolerance: up to 5 of the 15 shard-holders can be offline simultaneously
- Each shard is stored on a different member's device

For critical data (server config, role definitions, channel list), use higher redundancy: k = 10, m = 10 (2x overhead, tolerates 10 offline members).

#### 4.3 Content-Addressed Storage

Every piece of data is addressed by its cryptographic hash (SHA-256):

```
content_id = SHA-256(encrypted_data)
```

This provides:
- **Deduplication** — identical content stored once
- **Integrity verification** — detect corrupt or tampered shards
- **Location-independent addressing** — find data by hash, not by "which server it's on"

#### 4.4 Shard Placement via DHT

The Kademlia DHT determines which members store which shards:

1. Compute `content_id = SHA-256(encrypted_data)`
2. For each shard `i` of the content, compute `shard_key = SHA-256(content_id || i)`
3. Find the `k` closest peers to `shard_key` in the DHT
4. Store the shard on those peers

To retrieve: query the DHT for each `shard_key`, collect at least `k` shards, reconstruct.

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

Different data types have different importance and retention policies:

| Data Type | Redundancy | Retention | Priority |
|---|---|---|---|
| Server config, roles, permissions | Very high (k=10, m=10) | Permanent | Critical |
| Channel metadata, pinned messages | High (k=10, m=8) | Permanent | High |
| Text messages | Standard (k=10, m=5) | Configurable (default: permanent) | Medium |
| Images and files | Standard (k=10, m=5) | Configurable (default: 1 year) | Medium |
| Voice message recordings | Lower (k=10, m=3) | Configurable (default: 90 days) | Low |
| Temporary/ephemeral messages | Minimal (k=5, m=2) | Auto-delete after read/time | Low |

#### 4.7 Local Cache

Each member also maintains a local cache of recently accessed content (outside their pledge). This means:
- Channels you actively read are fast to load (local)
- Scrolling back loads from the distributed network
- Going offline? You still have your recent history locally

---

## 5. Networking Layer — Peer-to-Peer

### 5.1 Transport Protocols (via libp2p)

libp2p supports multiple transports, negotiated automatically:

- **QUIC** — Primary transport. UDP-based, built-in TLS 1.3, multiplexed streams, fast connection establishment. Handles NAT traversal better than TCP.
- **TCP + Noise** — Fallback for networks that block UDP. Noise Protocol Framework for encryption (faster than TLS handshake for P2P).
- **WebSocket** — For Flutter Web clients that can't use raw TCP/QUIC. Connects through a WebSocket relay.
- **WebTransport** — Modern alternative to WebSocket, based on QUIC. Better for web clients long-term.

### 5.2 NAT Traversal

Most users are behind home routers (NAT). Connecting two NATted peers directly is the biggest networking challenge.

**Strategy (layered):**

1. **UPnP/NAT-PMP** — Ask the router to open a port. Works on many home routers automatically. Try this first.

2. **STUN-like hole punching (libp2p AutoNAT + DCUtR):**
   - Each peer discovers its public IP and port mapping via AutoNAT (like STUN).
   - When two NATted peers want to connect, they coordinate through a relay node.
   - Both peers simultaneously send packets to each other's public endpoints (UDP hole punching).
   - If successful, they have a direct connection. ~80% success rate on typical home networks.

3. **Circuit Relay (TURN-like fallback):**
   - If hole punching fails, traffic relays through a member that IS publicly reachable.
   - Any member with a public IP (or successful UPnP) can volunteer as a relay.
   - Relayed traffic is still E2EE — the relay sees only encrypted bytes.
   - This is the fallback that ensures connectivity always works.

**Lightweight Signaling Service:**

The ONE piece of minimal infrastructure. A tiny, stateless signaling service helps with initial peer discovery:

- New peers need to find at least one existing member to bootstrap into the network
- The signaling service stores: `server_id → list of known peer addresses`
- It does NOT store messages, user data, or keys — only connection endpoints
- Can be hosted for free (Cloudflare Workers, a free-tier VM, or even embedded in the invite link as a static list)
- Multiple redundant signaling services can exist — anyone can run one
- Once connected to one peer, the DHT provides discovery of all other peers

### 5.3 Peer Discovery Within a Server

Once connected to the network:

1. **DHT lookup** — Query for peers belonging to the same `server_id`
2. **Gossip protocol** — Each peer shares its known peer list with connected peers
3. **mDNS** — Discover peers on the same local network (great for LAN parties, offices)
4. **Peer exchange (PEX)** — When connected to peer A, ask "who else do you know in this server?"

### 5.4 Connection Management

- Maintain persistent connections to a subset of server members (e.g., 6-12 peers)
- Prefer peers with: high uptime, low latency, good bandwidth
- Rotate connections periodically to maintain a diverse view of the network
- Prioritize connections to peers holding shards you frequently access

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

### 6.5 Automerge Integration

Automerge (Rust implementation) handles the CRDT complexity:

```dart
// Dart side (via FFI bridge)
final doc = await AutomergeDoc.create();

// Send a message (local operation)
await doc.change((d) {
  d.getList('messages').push({
    'id': hlc.now(),
    'author': myPeerId,
    'content': encryptedContent,  // Already E2EE
    'timestamp': DateTime.now().toUtc().toIso8601String(),
  });
});

// Sync with a peer
final syncMessage = await doc.generateSyncMessage(peerState);
// Send syncMessage to peer via libp2p
// Receive peer's sync message and apply it
await doc.receiveSyncMessage(peerSyncMessage);
```

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

### 7.2 Direct Messages (1:1) — Signal Protocol

Uses the gold-standard Double Ratchet algorithm:

**Initial Key Exchange (X3DH — Extended Triple Diffie-Hellman):**
- Each user publishes a "prekey bundle" to the DHT:
  - Identity Key (IK) — long-term Ed25519/X25519 keypair
  - Signed Prekey (SPK) — rotated weekly, signed by IK
  - One-Time Prekeys (OPKs) — batch of single-use keys
- Alice fetches Bob's bundle from DHT, computes shared secret via 3-4 DH operations
- Alice can send the first message even if Bob is offline

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

**1:1 E2EE:** `vodozemac` v0.9 (Rust, via FFI) — Matrix's audited Olm implementation. Handles X3DH-like key exchange + Double Ratchet for DMs. Two identity systems coexist: libp2p Ed25519 (transport) and vodozemac Curve25519 (E2EE).

**Group E2EE:** OpenMLS (Rust, via FFI) — for MLS group encryption in channels. To be integrated in Phase 3.

**Local storage encryption:** SQLCipher (AES-256-CBC) — via `rusqlite` with `bundled-sqlcipher` feature, using system OpenSSL on Windows.

**Identity:** `ed25519-dalek` v2.2 (via libp2p) — Ed25519 keypair generation and signing. BIP-39 mnemonic for backup/restore.

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
1. Open Haven on the existing device (e.g., PC)
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
2. Installs Haven fresh on a new device
3. Enters their Haven display name or public key fingerprint (short string they might remember, or have written down, or a friend can tell them)
4. App locates the guardians via DHT
5. User contacts guardians through any out-of-band channel ("Hey, I lost my phone, can you approve my recovery in Haven?")
6. Each guardian receives a recovery request in-app and approves it
7. Once threshold is met (e.g., 3 of 5 approve), shares are sent to the new device via E2EE
8. Shares are recombined → identity key restored
9. Account data syncs from the Shared Vault (server memberships, channel keys via MLS re-welcome)

**Why this works for Haven:** It's a social platform. Users inherently have trusted contacts. The "backup" is your friends — not a piece of paper in a drawer.

#### Method 3: Encrypted Vault Backup (For Solo Recovery)

For users who want self-reliant recovery without depending on others.

**Setup:**
1. User chooses a strong **recovery password** (or PIN + biometric on mobile)
2. Identity key + account data is encrypted with a key derived from the password (Argon2id KDF, high memory cost)
3. The encrypted backup blob is stored as a special shard in the Shared Vault, tagged to the user's public key
4. Redundancy: highest tier (same as server config — survives up to 50% of members going offline)

**Recovery flow:**
1. Install Haven on new device
2. Enter Haven ID (public key fingerprint — a short string like "hVn8-xR3k-Qp7z")
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
- Haven does NOT show this by default during onboarding — it's buried in settings for those who want it

#### Recovery Method Comparison

| Method | User effort | Requires existing device | Requires other people | Requires remembering something |
|---|---|---|---|---|
| **Device Linking** | Scan QR code | Yes | No | No |
| **Social Recovery** | Ask 3 friends | No | Yes (guardians) | Haven ID (short string) |
| **Vault Backup** | Enter password | No | No | Haven ID + password |
| **24-Word Phrase** | Enter 24 words | No | No | 24 words (hard) |

### 8.5 Invite Links (No Central Server)

Invite links are cryptographically signed tokens, not URLs pointing to a server:

```
haven://join?token=<base64-encoded signed blob>
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
Step 2: User provides the ZIP to Haven's import tool
Step 3: Haven parses the export:
        - Maps Discord servers → Haven servers
        - Maps channels → channels (preserves names, descriptions, order)
        - Maps roles → roles (preserves hierarchy, permissions, colors)
        - Maps messages → messages (preserves content, timestamps, author IDs)
        - Downloads attachment URLs → stores as Haven files
Step 4: Haven creates the server structure
Step 5: Haven generates invite links for each mapped Discord user
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

Built entirely with Flutter widgets. No web embedding, no WebView. The UI should feel native to each platform while maintaining a consistent Haven identity.

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
└── Storage Dashboard (unique to Haven)
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

**Goal:** Establish Haven's visual identity and UI architecture before building complex features on top. Replace Material Design defaults with a custom design system that feels native, premium, and distinctly Haven.

**Design Direction:** Deep Dark + Teal Accent. Secure yet cozy — midnight backgrounds convey seriousness/trust, teal accent (#00BFA6) evokes calm/shelter (aligns with "Haven" name). Distinct from Discord (purple), Signal (blue), WhatsApp (green). Multi-theme architecture from day one: default dark theme ships first, Frutiger Aero-inspired theme as a built-in alternate (glossy surfaces, vibrant gradients, bubble animations — leveraging Flutter's BackdropFilter, ShaderMask, CustomPainter).

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

- [X] Custom theme system (HavenTheme: color palette, typography scale, spacing, elevation, border radii — no Material defaults. Multi-theme architecture supporting Default Dark + future Aero theme)
- [X] Dark mode primary, light mode secondary (both fully custom, not Material's ColorScheme)
- [X] Custom window chrome (remove native title bar, custom-drawn title bar with Haven branding, window controls — via flutter_acrylic or bitsdojo_window)
- [X] State management architecture (Riverpod — chosen for auto-dispose, .family per-peer state, StreamProvider for Rust FFI streams, granular rebuilds)
- [X] Event streaming refactor (replace polling with Rust→Dart stream — real-time updates)
- [X] Navigation shell (server list sidebar, channel/chat view, member panel — responsive: sidebar on desktop, bottom nav on mobile)
- [X] Reusable component library (HavenButton, HavenTextField, HavenCard, HavenAvatar, HavenDialog, HavenToast — all custom-painted, no Material widgets)
- [X] Animation system (spring curves, page transitions, micro-interactions — buttery smooth 60fps, GPU-accelerated via Flutter's rendering pipeline)
- [X] Chat UI rebuild (message bubbles, timestamps, read indicators, typing indicator — custom widgets, not Material ListTiles)
- [X] Peer/contact list rebuild (online/offline status, avatars, encryption badge — integrated with new component library)
- [X] Adaptive layout system (responsive breakpoints for desktop/tablet/mobile — single codebase, three layouts)
- [X] Custom iconography (Haven icon set or curated icon package — consistent visual language)

**Deliverable:** The app looks and feels like a real product — custom visual identity, smooth animations, responsive layout. All future UI work builds on this foundation.

### Phase 2.75: Haven Design System v2 — COMPLETE

**Goal:** Replace all Material Design defaults with Haven's own interaction system. Zero Material interaction widgets remain. Spring physics, no ripple, custom everything.

- [X] HavenPressable — universal interaction widget (press: opacity 0.85 + scale 0.98, spring physics)
- [X] HavenButton — 4 variants: filled, ghost, outline, danger (self-contained animations, hover glow)
- [X] HavenTextField — flat design, animated border color, focus glow, error shake
- [X] HavenDialog — showHavenDialog() with glassmorphism (BackdropFilter 12px blur, scale entrance)
- [X] HavenTooltip — overlay-based, 400ms delay, fade+slide entrance
- [X] HavenToggle — spring physics thumb, color crossfade track
- [X] HavenToast — slide-up + fade, 3 types (success/error/info), auto-dismiss, replaces SnackBar
- [X] HavenAvatar v2 — gradient background, status dot integration
- [X] StatusDot v2 — breathing pulse glow (3s cycle, BoxShadow)
- [X] PeerCard / ChannelTile — HavenPressable with smooth selection transitions
- [X] ServerStrip icons — HavenPressable, scale-bounce for new icons, selection indicator
- [X] Dialog migration — all 4 dialogs (CreateServer, CreateChannel, Invite, Mnemonic)
- [X] Global cleanup — zero InkWell, IconButton, SnackBar, Tooltip, AlertDialog, FilledButton, TextButton, OutlinedButton remaining
- [X] UI Polish Pass — glassmorphism, startup reveal (2500ms), ambient background, shader warmup, GPU-composited transitions

**Deliverable:** Every interactive element uses custom Haven widgets. The app feels premium and distinctly Haven.

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
- [X] Room gating — reject incoming CRDT state/ops for servers we haven't explicitly joined, prevent auto-sync of unknown servers to non-members
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

**Goal:** Everything that makes Haven a usable daily chat app. Core features that turn a working prototype into something people want to use every day.

**Identity & Profiles:**
- [X] User profiles (avatar, status message, about me). Display name (global, user-changeable) already exists — acts as the nickname. Peer ID shown under display name as the immutable identity tag. Avatar stored locally for now, synced to peers' encrypted DBs once basic file sharing is built. 🎞️ Animate: profile card pop-up with scale+fade, status change transitions
- [X] Server nicknames — per-server display name override via CRDT LWW-Register per member. Falls back to global display name when unset
- [X] Profile card popup on member click — shows avatar, display name, server nickname, role, peer ID snippet, status. 🎞️ Animate: scale+fade entrance from click origin

**Chat Essentials:**
- [X] Chat Redesign — flat stacked layout.
- [X] Message editing — CRDT op (EditMessage with original message ID + new text), broadcast to server members, update in local DB + UI. Edited messages show "(edited)" indicator. 🎞️ Animate: edit highlight flash
- [X] Multi-Peer Fan-out Sync — SyncCoordinator collects connected peers for 500ms, assigns channels round-robin across all available peers (primary + backup), sends lightweight ChannelSyncProbe (timestamp comparison) before full sync. Channels with no new messages are skipped entirely. Equal load distribution: the more peers online, the lighter the load per peer. On-demand RequestChannelSync (user opens channel) still fans out to all peers for immediacy
- [ ] Message deletion — Channel: soft-delete (deleted_at timestamp, row stays in DB for Rat Files evidence preservation). DM: hard delete from local DB only (other peer keeps their copy). UI shows "Message deleted" placeholder. 🎞️ Animate: delete shrink+fade-out
- [ ] Reply chains — reference parent message ID in envelope, render with quoted preview above reply. Clicking quote scrolls to original. 🎞️ Animate: reply chain indent slide
- [ ] Emoji reactions — PN-Counter CRDT per emoji per message, broadcast to server members. 🎞️ Animate: reaction pop-in with spring bounce, count increment/decrement
- [ ] Typing indicators — lightweight ephemeral signal (no persistence, no encryption needed). Broadcast to channel members, auto-expire after 5s. 🎞️ Animate: classic bouncing dots, smooth fade in/out
- [ ] Rich text / markdown rendering in messages (bold, italic, code, code blocks, links). Link previews deferred to Phase 6
- [ ] Pinned messages — CRDT OR-Set of pinned message IDs per channel, pin/unpin broadcast

**Quality of Life:**
- [ ] Friends system & DM overhaul — Rust: `friends` SQLCipher table (peer_id, display_name, added_at, status). Friend request flow: `FriendRequest` → `FriendAccepted`/`FriendDeclined` wire messages over Olm. Friends list persists offline (not just "who's online"). DM sidebar shows all friends (online/offline) with status dots, sorted online-first. DM history persists and loads from DB regardless of connection status. Unfriend removes from list but keeps DM history. No mutual server required — friends are independent of servers.
- [ ] Notifications — system-level (Windows toast / macOS notification center), configurable per server and per channel (all / mentions only / none)
- [ ] Search — local full-text search over decrypted messages in SQLCipher. 🎞️ Animate: search bar expand, results list staggered fade-in
- [ ] Keyboard shortcuts (navigate channels, servers, quick-switch, mark as read)
- [ ] Basic file sharing — direct P2P transfer via libp2p, encrypt with MLS/Olm before sending, store locally on receiver. Image/file preview in chat. No erasure coding yet (that's Phase 4). All images auto-converted to lossless WebP on send (25-35% smaller than PNG/JPEG, Flutter decodes natively, Rust `image` crate encodes). "Save as" option converts to user's chosen format (PNG/JPEG/WebP). 🎞️ Animate: upload progress, image shimmer placeholder → fade-in

**Deliverable:** Haven feels like a complete, polished chat app. Ready for daily use with friends.

### Phase 4: Shared Vault — Distributed Storage

**Goal:** The core innovation — distributed storage across members.

- [ ] Storage pledge system (configurable minimum per server)
- [ ] Reed-Solomon erasure coding implementation
- [ ] Content-addressed storage (SHA-256 based)
- [ ] DHT-based shard placement
- [ ] Shard retrieval and content reconstruction
- [ ] Rebalancing on member join/leave. 🎞️ Animate: rebalancing progress indicator, shard migration visualization
- [ ] Storage dashboard UI (visualize pool, health, contributions). 🎞️ Animate: animated donut/bar charts, pool fill-up animation, health pulse indicators
- [ ] File upload → encrypt → erasure-code → distribute pipeline. 🎞️ Animate: upload progress with encrypt→split→distribute step visualization
- [ ] Image/file preview and download from distributed storage. 🎞️ Animate: image load shimmer placeholder → fade-in, download progress reconstruction
- [ ] Storage tier configuration (retention policies per data type)
- [ ] Connection subset management — limit persistent connections to 6-12 peers per server (not all members). Prefer peers with high uptime, low latency, good bandwidth. Rotate periodically for network diversity. Critical for 1,000+ member servers where full-mesh connections would overwhelm libp2p.
- [ ] Channel-level CRDT sharding — split server CRDT state into per-channel documents instead of one monolithic ServerState. Reduces sync payload and memory footprint for servers with 5,000+ members and many channels. Each peer only needs full CRDT state for channels they participate in.

**Deliverable:** Server data lives distributed across members. No single point of failure.

### Phase 4.5: Account Recovery & Backup

**Goal:** Identity recovery mechanisms that leverage the Shared Vault infrastructure.

- [ ] Social Recovery: guardian designation + Shamir's Secret Sharing (split identity key into k-of-n shares, distribute to trusted contacts via E2EE)
- [ ] Encrypted Vault Backup: password-based recovery (Argon2id KDF, encrypted blob stored as high-redundancy shard in the Shared Vault)
- [ ] Recovery UI flows (guardian approval, password entry, shard reconstruction). 🎞️ Animate: step-by-step wizard transitions, shard gathering progress, recovery success celebration

**Deliverable:** Users can recover their identity after total device loss via guardians or a recovery password.

### Phase 5: Voice & Video

**Goal:** Real-time calls with E2EE.

- [ ] flutter_webrtc integration
- [ ] 1:1 voice calls (direct P2P)
- [ ] 1:1 video calls
- [ ] Small group calls (mesh topology, 2-5 participants)
- [ ] Super peer SFU for larger groups
- [ ] SFrame E2EE for group calls
- [ ] Screen sharing
- [ ] Voice channels (persistent, join/leave). 🎞️ Animate: join/leave transitions, voice activity ring pulse around avatar
- [ ] Audio processing (echo cancellation, noise suppression)
- [ ] Call UI (grid view, controls, indicators). 🎞️ Animate: participant grid rearrange, mute/unmute feedback, speaking indicator glow, call connect/disconnect transitions

**Deliverable:** Full voice/video/screen-share with E2EE.

### Phase 6: Polish & Launch Prep

**Goal:** Final features, platform testing, and polish pass before distribution.

- [ ] Link previews (URL metadata fetch + embed card rendering)
- [ ] Discord import system (full implementation — parse GDPR export ZIP, map servers/channels/roles/messages, placeholder identities, member claiming)
- [ ] Data export system (messages, files, identity — verifiable with Ed25519 signatures)
- [ ] Server template export/import (share server structures)
- [ ] Evidence Recovery UI tool (cooperative shard gathering for ex-members) — depends on Phase 4 shard system
- [ ] Device linking via QR code (multi-device identity sync) — requires MLS + CRDTs. 🎞️ Animate: QR scan success celebration, device linked confirmation
- [ ] Mobile platform testing & platform-specific fixes (adaptive layout built in Phase 2.5)
- [ ] Accessibility (screen reader support, high contrast)

**Deliverable:** A polished, feature-complete communication platform ready for public release.

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
- [ ] Security audit (third-party review of E2EE implementation)

**Deliverable:** Public release across all platforms.

### Phase ???: Fight Government Censorship

**Goal:** Allow Haven to work in countries with advanced DPI censorship (Russia, China, Iran).

**Explanation:**

Russia's TSPU (DPI system) is one of the most advanced censorship systems in the world. It doesn't just look at port numbers — it analyzes traffic patterns, packet sizes, and timing. Even though our WSS goes through TLS on port 443, the libp2p protocol fingerprint inside the WebSocket frames is detectable. This is the same reason Tor needed pluggable transports (obfs4, meek, snowflake) — plain TLS wrapping isn't enough against sophisticated DPI.

**Proven solutions exist (used by people in Russia/China/Iran right now):**
- **VLESS + Reality (XRay):** Makes traffic indistinguishable from a real TLS connection to a legitimate website (e.g., google.com). Gold standard for DPI bypass.
- **Shadowsocks (Outline):** Traffic looks like random noise. Simple to deploy, still effective against most DPI.
- **AmneziaWG:** Modified WireGuard with junk packets and header obfuscation.

**Implementation approaches (from easiest to hardest):**
1. **Documentation only** — Guide for users to set up their own VLESS/Shadowsocks proxy, Haven connects through it normally. Zero code changes.
2. **Relay-side proxy** — Run XRay/Shadowsocks on our VPS alongside the relay. Censored users connect to the obfuscated proxy, which tunnels to the Haven relay internally. Minimal Haven code changes.
3. **Built-in transport** — Integrate a Shadowsocks or VLESS client directly into Haven's Rust backend. Auto-detect censorship (connection failures on WSS) and fall back to obfuscated tunnel. Best UX, most work.

**Checklist:**
- [ ] Research: test VLESS+Reality from Russian network to confirm it works
- [ ] Option 1: Write user-facing guide for external proxy setup
- [ ] Option 2: Deploy XRay/Shadowsocks proxy on relay VPS, add Haven config for proxy endpoint
- [ ] Option 3: Integrate obfuscated transport into Rust backend (long-term)

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
- **Storage Contributors** — members who voluntarily run Haven 24/7 and donate above-minimum storage (e.g., a home NAS with 50 GB). They earn reputation and a visible role. Tiered recognition system:
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

| Feature | Haven | Discord | Element/Matrix | Session | Briar | RetroShare |
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

### Haven's Unique Differentiators

1. **Shared Vault** — No other platform distributes storage across members. This eliminates hosting costs and single points of failure.
2. **Native performance** — Flutter compiles to native code. No Electron, no Chromium runtime.
3. **Zero infrastructure** — No homeservers to maintain (Matrix), no blockchain tokens (Session), no company servers (Discord).
4. **MLS encryption** — Most modern group encryption protocol, better scaling than Signal's Sender Keys.
5. **Discord import** — Lower the migration barrier. Bring your community with you.
6. **Data sovereignty & cryptographic evidence** — No one can delete your data remotely. Exported messages carry unforgeable digital signatures. Evidence of abuse survives even if the server owner tries to destroy everything.

---

## 17. Server Lifecycle & Data Sovereignty

This section addresses a critical question: what happens when members leave, get kicked, or the owner shuts down a server? In a decentralized system, the answer is fundamentally different from centralized platforms — and it's one of Haven's most powerful features.

### 17.1 Core Principle: Local Data Is Sacred

**Nobody can remotely delete data from your device.** Not the server owner, not admins, not other members, not Haven's developers. Once you've seen a message and it's in your local cache, it's yours. This is a direct consequence of decentralization — there is no central server to issue a "delete from all devices" command.

### 17.2 Message Signing & Cryptographic Proof

Every message in Haven is **digitally signed** by the sender's Ed25519 identity key:

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
- **Verifiable exports:** Exported message logs carry the original signatures. A third party (law enforcement, a court) can verify the signatures independently without needing access to Haven's network

This is **stronger evidence than Discord screenshots**, which can be trivially fabricated. Haven messages are cryptographically unforgeable.

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

This is where Haven's architecture truly shines.

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

In a worst-case scenario — a malicious server owner running a harmful community tries to destroy evidence by kicking everyone and shutting down the server — Haven's architecture provides a safety net that no centralized platform can match.

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

**Haven provides a cooperative "Evidence Recovery" UI tool:**
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

Haven has no servers to pay for, no infrastructure bills, and no company overhead. The project sustains itself through community support, not paywalls.

### 18.1 Core Principle: No Features Behind Paywalls

Everything that makes Haven work — E2EE, Shared Vault, voice/video, screen sharing, file sharing, unlimited servers — is free. Forever. No "Haven Nitro."

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
| **Shared Vault** | Haven's distributed storage system where members donate disk space |

## Appendix C: FAQ — Questions & Answers From the Design Process

These are real questions that came up during the design of Haven, answered in full.

---

### Q: Will calls be high quality? Is this old-school VoIP?

**No, this is NOT old-school VoIP.** Haven uses WebRTC — the exact same technology powering Discord, Google Meet, Zoom's web client, and Facebook Messenger calls.

- **Audio:** Opus codec — the best audio codec in existence. Adaptive bitrate from 6 kbps (bad internet) to 510 kbps (studio quality). Same codec Discord uses.
- **Video:** VP8/VP9/AV1 with hardware-accelerated encoding/decoding.
- **Adaptive bitrate:** Automatically adjusts quality in real-time based on network conditions.
- **Built-in processing:** Echo cancellation, noise suppression, jitter buffer, automatic gain control.

Haven actually has a **quality advantage** for small calls — 1:1 and small groups are direct peer-to-peer with no server in the middle. Lower latency than Discord, which routes everything through their data centers.

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

### Q: Will Haven drain mobile data?

Haven is configurable per-device:

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

Discord's 500K+ servers work because they have massive infrastructure. Haven trades that for decentralization — the sweet spot is communities up to tens of thousands, which covers 99.9% of real Discord servers.

---

### Q: What about bots and integrations?

Not in the initial plan, but the architecture supports it naturally:

- A "bot" is just another peer with a special role — it runs Haven's protocol, receives messages, can respond.
- Self-hosted by anyone (run it on a Raspberry Pi, a VPS, whatever).
- No bot API server needed — the bot IS a member of the server.
- Integrations (GitHub webhooks, RSS feeds, etc.) would be bot-peers that bridge external services.
- This could be Phase 8 or a community-contributed feature.

---

### Q: What about privacy, criminals, and government requests?

This is the most important non-technical question for any E2EE platform.

**The reality:**
- Haven's developer has ZERO access to any user data. By design. There are no servers to raid, no databases to subpoena, no logs to hand over.
- This is identical to Signal, Briar, Session, and Tor — all legal, all operating, all with the same answer to law enforcement: "We can't hand over data we don't have."

**Legal protection:**
- Building encryption is protected in most democratic countries. The legal fight was largely won in the 1990s "Crypto Wars."
- Section 230 (US) and equivalent laws elsewhere protect platform builders from liability for user-generated content.
- Precedent: Signal, Tor, Mullvad VPN, WireGuard — all zero-knowledge, all legal. When Mullvad was raided by police, officers left with nothing because there was nothing to take.

**What Haven DOES do:**
1. **Clear legal terms** — Haven is a communication tool. Users are responsible for their conduct.
2. **Client-side reporting** — members who witness illegal content can screenshot and report to law enforcement directly. Haven can include a "Report to Authorities" button with guidance. The people who CAN see the content (members) are empowered to act.
3. **Community self-moderation** — server owners/admins have full moderation tools (kick, ban, delete messages, manage roles). The community polices itself.
4. **Invite-only servers** — no public server browser, no discovery tab. You can't stumble into a bad server. You must be explicitly invited.

**What Haven does NOT do (and must never do):**
- No backdoors. A backdoor for law enforcement IS a backdoor for hackers and state actors.
- No client-side content scanning. Destroys the trust model, can be repurposed for censorship.
- No metadata collection "just in case." If you don't have it, you can't be forced to hand it over.
- No age verification. Requires central identity verification, destroys the decentralized model, and doesn't work anyway.

**The ethical position:**
> "We build tools that protect privacy. We don't control how people use them, just like a locksmith doesn't control what people put behind locked doors. The answer to bad actors having privacy is not to take privacy from everyone — it's better policing, better education, and communities that self-moderate."

**The practical reality:** People who would use Haven for criminal purposes are ALREADY using encrypted tools. Haven doesn't enable anything new. What it DOES do is give the 99.99% of normal people the privacy they deserve.

**Open source commitment:** The cryptographic and networking layers will be open-sourced for full transparency. Anyone can verify there are no backdoors.

---

### Q: What makes Haven different from all the other "Discord alternatives"?

Most alternatives are just reskins of the same architecture:

| Alternative | What it really is |
|---|---|
| Revolt | Web client + centralized servers (just Discord with different branding) |
| Guilded | Was promising, got acquired by Roblox |
| Element/Matrix | Powerful protocol, but federated (homeservers), Electron client, designed-by-committee UX |
| Spacebar | Literally reimplements Discord's API |

**Haven's actual differentiators:**
1. **Shared Vault** — No other platform distributes storage across members.
2. **Truly native** — Flutter, not Electron. 50-80 MB, not 300 MB.
3. **Zero infrastructure** — No servers to host, no cloud bills, no company that can shut down.
4. **The community IS the server** — members collectively host, store, and relay. The more members, the stronger and faster the server gets.
5. **E2EE everything** — not optional, not partial. Messages, files, calls, screen shares. All of it.

---

> *"The best server is no server at all — it's every member, together."*
