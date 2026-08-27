# Hollow Protocol Whitepaper

**Version 0.9.4**\
**Author: Vitalii Rovinskyi**\
*This document was generated with the assistance of Claude (AI). All technical content reflects the author's architecture and design decisions. Some sections may not match the version number shown above until the next release.*

---

## Abstract

Hollow is a fully distributed, end-to-end encrypted communication platform. There are no central servers that store messages, files, or metadata. Members of a server collectively host it. The relay is a zero-knowledge signaling pipe that routes encrypted blobs between peers without any ability to read, modify, or store them.

Hollow provides real-time text messaging, voice and video calls, screen sharing, file sharing, and distributed storage, all with end-to-end encryption. A single human identity can run on multiple devices (multi-device sync), and mobile clients receive push notifications without ever exposing message content to Apple or Google. The protocol is designed so that even a fully compromised relay operator learns nothing beyond which peer IDs are connected and which rooms they occupy.

This document describes the Hollow protocol as implemented in the Beta release. It covers the cryptographic architecture, networking model, synchronization protocol, multi-device identity model, push-notification privacy design, and security properties. It describes the system at the protocol level rather than as an implementation guide, so that its security properties can be evaluated independently of the source code.

The client is a native application for Windows, macOS, Linux, Android, and iOS (a single Rust core shared across all platforms, with a Flutter UI). All cryptographic operations are identical across platforms.

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [Identity](#2-identity)
3. [Multi-Device Identity and Synchronization](#3-multi-device-identity-and-synchronization)
4. [Direct Message Encryption (Olm / Double Ratchet)](#4-direct-message-encryption-olm--double-ratchet)
5. [Server Encryption (MLS)](#5-server-encryption-mls)
6. [Voice, Video, and Screen Share Encryption (SFrame)](#6-voice-video-and-screen-share-encryption-sframe)
7. [File Transfer Encryption](#7-file-transfer-encryption)
8. [Hollow Share (Private P2P File Distribution)](#8-hollow-share-private-p2p-file-distribution)
9. [Vault (Distributed Encrypted Storage)](#9-vault-distributed-encrypted-storage)
10. [CRDT Synchronization](#10-crdt-synchronization)
11. [Authorization and Permission Model](#11-authorization-and-permission-model)
12. [Relay Architecture](#12-relay-architecture)
13. [Push Notifications (Mobile)](#13-push-notifications-mobile)
14. [WebRTC Transport Layer](#14-webrtc-transport-layer)
15. [Message Signing and Verification](#15-message-signing-and-verification)
16. [The Rat Files (Cryptographic Evidence)](#16-the-rat-files-cryptographic-evidence)
17. [Gossip Overlay Network](#17-gossip-overlay-network)
18. [Anti-Censorship Transport](#18-anti-censorship-transport)
19. [Twitch Community Verification](#19-twitch-community-verification-optional)
20. [Verification and Correctness Assurance](#20-verification-and-correctness-assurance)
21. [Summary of Cryptographic Primitives](#21-summary-of-cryptographic-primitives)
22. [Threat Model](#22-threat-model)
23. [Limitations and Future Work](#23-limitations-and-future-work)

---

## 1. Introduction

### 1.1 Design Goals

- **Zero-knowledge relay:** the relay sees room membership and peer IDs. It cannot read message contents, encryption keys, file data, or any application-layer semantics.
- **No accounts:** identity is a cryptographic keypair derived from a BIP-39 mnemonic. There is no email, phone number, or username registration.
- **Forward secrecy:** DM sessions use the Double Ratchet algorithm. Server sessions use MLS epoch rotation. Compromising a long-term key does not reveal past messages.
- **Decentralized state:** server metadata (channels, members, roles, settings) is synchronized via CRDTs with no authoritative source. Any online member can act as a sync peer.
- **Verifiable authorship:** every message carries an Ed25519 signature over a canonical payload. Recipients verify that the claimed sender authored the message. Exported messages are cryptographically unforgeable; screenshots are not.
- **Distributed storage:** server files are distributed across members using adaptive erasure coding. No single member's departure causes data loss.
- **Multi-device without accounts:** one identity can run on several devices, kept in sync, without any account server, and without the relay ever learning that two connections belong to the same person.
- **Metadata-minimizing push:** mobile push notifications carry only an opaque wake-up signal; message content is fetched over the existing E2EE channels and decrypted on-device, never exposed to Apple or Google.
- **Near-zero VPS bandwidth for media:** voice, video, screen sharing, and file transfers flow over peer-to-peer WebRTC connections; the relay carries signaling, plus an encrypted TURN fallback for the minority of NAT situations where no direct path exists (§6).

### 1.2 Architecture Overview

Hollow consists of three components:

1. **The client application:** a native binary (not Electron) that handles UI, state management, and all cryptographic operations. The backend is written in Rust, the UI in Flutter (Dart), connected via FFI. The same Rust core runs on Windows, macOS, Linux, Android, and iOS, so cryptographic behavior is identical across platforms. A single person can run the client on several devices at once (§3).

2. **The relay server:** a lightweight WebSocket router that forwards encrypted messages between room members. It is a dumb pipe with no knowledge of application semantics. The relay is open-source.

3. **The WebRTC mesh:** direct peer-to-peer connections between clients for heavy data transfer (files, voice, video, screen share). Established via signaling through the relay.

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

The mnemonic is shown to the user once at account creation and never transmitted. It is the sole identity recovery mechanism.

### 2.2 Peer ID

The peer ID is a **base58-encoded identity multihash** of the public key:

```
PeerId = Base58( [0x00, length, public_key_protobuf] )
```

Public key protobuf encoding: `[0x08, 0x01, 0x12, 0x20, <32-byte Ed25519 public key>]` (36 bytes).

Peer IDs are deterministic: the same mnemonic always produces the same peer ID. This format begins with `12D3KooW...` and is used as the universal identifier throughout the protocol.

### 2.3 Identity At-Rest Protection

The identity keypair is stored in a file (`identity.key`) encrypted with the **HKEYV1 format**:

```
[magic: 6 bytes "HKEYV1"][flags: 1 byte][salt: 16 bytes][nonce: 12 bytes][ciphertext: 84 bytes]
```

Total: 119 bytes. The ciphertext contains the AES-256-GCM encrypted keypair (68-byte protobuf) plus a 16-byte authentication tag.

**Three encryption modes (all opt-in from Settings > Security):**

- **Password with launch lock** (flags = `0x01`): The user's password is processed through **Argon2id** (65536 iterations, 3 parallelism, 32-byte output) with a random 16-byte salt to derive the AES-256-GCM key. Password is required on every application launch. A full-screen blur lock dialog blocks all interaction until unlocked.

- **Password with silent unlock** (flags = `0x03`): Same password-derived encryption as above, but the wrapping key is also cached in the OS credential store for silent unlock. The identity file is encrypted (protecting against file copying), but the app opens normally on the same device. A toggle in Settings ("Ask for password on launch") controls this behavior. If the OS credential store becomes unavailable, the app falls back to requesting the password.

- **Device protection only** (flags = `0x02`): A random 32-byte wrapping key is stored in the OS credential store: **Windows Credential Manager** (`CredWriteW`/`CredReadW`) as primary with a **DPAPI blob** (`identity.dpapi`) as fallback on Windows, **Keychain** (`security-framework` crate, service `com.hollow.identity`) on macOS. On mobile, the equivalent silent-unlock layer is provided by the App Lock subsystem (§2.6), which gates a copy of the wrapping secret behind the OS secure enclave (Android Keystore / iOS Keychain) and biometric authentication. Silent unlock on the same machine. The identity file is useless if copied to another device.

**Per-profile slots and verified retrieval:** Because one machine can host multiple identity profiles (each with its own data directory), the credential store is keyed per profile: the slot name carries a digest of the profile's data-directory path, alongside a legacy machine-global slot kept for backward compatibility (on Windows, a DPAPI-encrypted blob inside the profile's own data directory is a third, storage-failure fallback). Retrieval never trusts any single slot: unlock collects every stored candidate and accepts only one that actually decrypts the identity file at hand, then re-writes the verified key to all slots so they self-heal toward the active profile. This closes a lockout class where a second profile's key overwrote the first's in a shared slot and the unverified key was trusted, forcing the user into mnemonic recovery, which rotates the device key and discards its group memberships. The self-healing rewrite belongs to unlocking the profile the application is running as, and only to that. Where the application merely needs to ask whether a stored credential can open some *other* profile's identity file - to require proof of ownership before destroying it, for instance - the probe is strictly read-only: it reports whether a candidate decrypts and writes nothing back. Healing on a foreign file would reintroduce the very cross-profile overwrite the verified retrieval exists to prevent.

**Backward compatibility:** Plaintext identity files (68 bytes, protobuf header `0x08 0x01`) are auto-detected. Plaintext identities remain plaintext until the user explicitly enables protection; there is no silent auto-encryption.

**Session wrapping key:** After `unlock_identity()`, the 32-byte wrapping key is held in a Rust `OnceLock<Mutex<Option<[u8; 32]>>>` for the session lifetime. All identity operations use this in-memory key. Calling `lock_identity()` zeroes and clears the key, re-requiring authentication.

**Recovery:** The 24-word BIP-39 mnemonic bypasses identity encryption entirely: it deterministically regenerates the keypair from scratch, removing any existing HKEYV1 encryption.

### 2.4 Local Storage Encryption

All local data is stored in **SQLCipher** (AES-256-CBC encrypted SQLite). The database encryption key is derived from the first 32 bytes of the **master** keypair's protobuf encoding, hex-encoded as a passphrase. The database is inaccessible without the keypair. Because the passphrase is a deterministic function of the master identity, an encrypted database transferred to another of the same person's devices (device linking, §3.4) opens transparently under the transferred master key.

**iOS shared-database constraint.** On iOS, the SQLCipher database is migrated into a shared **App Group container** (`group.com.anonlisten.hollow`) so the push Notification Service Extension can open the same encrypted database to decrypt incoming messages on-device (§13.5). Because two processes (the app and the extension) may open the database, it uses **rollback-journal mode (`journal_mode=TRUNCATE`) on iOS rather than WAL**. WAL keeps a persistent shared-memory lock; an app suspended while holding a file lock in a shared container is killed by iOS (`EXC_CRASH 0xdead10cc`). Rollback-journal mode locks only during a transaction, and a 4-second busy timeout lets the two processes wait on each other. All other platforms use WAL.

Removing the *persistent* lock is necessary but not sufficient: **opening** the database also takes one. A newly opened connection holds no schema cache, so its first statement reads and parses the entire schema under a shared lock before any query runs, and a suspension landing inside that window is indistinguishable to the platform from holding a lock indefinitely. The constraint this imposes is architectural rather than incidental: on a shared-container platform, database access on a latency-sensitive path must go through a long-lived connection owned by a dedicated worker, never through a fresh connection opened per item on the event loop. Reads served that way answer from a warm connection outside any transaction, so the lock-holding window shrinks to the query itself.

### 2.5 Account Recovery

Two recovery methods are implemented:

**Mnemonic recovery:** The 24-word BIP-39 phrase deterministically regenerates the identity keypair. Recovery is identity-only: server memberships and message history require re-sync from peers.

**Encrypted backup:** Full account state (identity key + encrypted database + optional vault shards) is exported as a passphrase-protected `.hollow` file. The passphrase is processed through Argon2id (64 MB memory cost, ~500ms per attempt) to derive an AES-256-GCM encryption key. Brute-force resistant by design.

### 2.6 App Lock (Mobile)

Mobile clients add an **App Lock** that gates application launch behind a PIN, password, or biometric authentication:

- **PIN / password lock:** a numeric PIN or a password is processed through the **same Argon2id + AES-256-GCM identity-at-rest pipeline** described in §2.3. A PIN is cryptographically identical to a password (it is simply numeric input), so there is no separate, weaker code path.
- **Biometric layer:** biometric unlock is a *layer on top of* a PIN/password, not an independent lock type. A copy of the PIN/password secret is stored in the OS secure enclave (Android Keystore / iOS Keychain) and released only after a successful `local_auth` biometric check. The underlying identity encryption is always the Argon2id path; biometrics gate retrieval of the secret.
- **Pre-unlock marker:** the lock-type marker and any biometric secret are stored in OS-backed secure storage (Keystore/Keychain), *not* in SQLCipher, because they must be readable *before* the encrypted database is unlocked at launch.
- **Self-heal:** a stored biometric secret that fails to unlock the identity is deleted to avoid a failing-biometric loop. Mnemonic recovery resets the identity to plaintext.

As with desktop at-rest protection, the database remains sealed until the Argon2id key derivation completes (typically 1.5–3 seconds), and protection is never silently enabled. The 24-word mnemonic is the sole universal recovery path.

---

## 3. Multi-Device Identity and Synchronization

A single Hollow *person* (one master identity) can run on several physical devices simultaneously, with messages, friends, servers, and history kept in sync. This is achieved without any account server and without the relay ever learning that two connections belong to the same human.

### 3.1 Two-Tier Key Hierarchy

Each person is one **master identity**: the Ed25519 keypair derived from the BIP-39 mnemonic (§2). The master key governs everything durable and cross-device: profile, friendships, DM-room derivation, **message-content signatures**, server/MLS membership, and the SQLCipher database passphrase.

Each physical device *additionally* holds its own **independent, randomly generated Ed25519 device key** (not derived from the mnemonic). The device peer ID is produced by the same multihash encoding used for master IDs, so to the relay, to rooms, and to Olm it is byte-for-byte indistinguishable from any other peer ID.

The device key drives identity **only at the transport layer**: relay authentication (a distinct relay socket per device) and signaling. Everything else stays master-keyed. The rooms a device joins are all *master-derived* (`inbox:{master}`, the DM room code, the server ID), so a device authenticates as itself yet occupies its identity's rooms.

**Security property.** Because each device presents a distinct random peer ID while joining master-derived rooms, **the relay never learns that two peer IDs belong to one person.** The device-to-person collapse happens entirely on the client side, on the observing peer. The relay requires zero multi-device awareness and remains a dumb pipe.

The device key shares the same at-rest protection as the master key (§2.3): both files are wrapped by the same session key, and a protection change rewrites both.

### 3.2 The Signed Device List

A person's set of active devices is published as a **master-signed device list**:

```
SignedDeviceList {
    master_pubkey_b64,   // master Ed25519 public key
    master_peer_id,      // MUST equal peer_id derived from the pubkey (binds key → identity)
    devices: [...],      // sorted, deduplicated active device peer IDs
    revoked: [...],      // sorted, deduplicated revoked device peer IDs (tombstones)
    version: u64,        // monotonic
    sig_b64,             // master's Ed25519 signature over the canonical payload
}
```

The canonical signing payload is:

```
hollow-devices:{master_peer_id}:{version}:{sorted_device_csv}:{sorted_revoked_csv}
```

Devices and revocations are sorted and deduplicated before signing, so the payload is deterministic regardless of insertion order. Verification re-derives the payload, confirms that the master peer ID matches the supplied public key, and checks the Ed25519 signature.

**Security property.** The device list is a self-authenticating capability: only the holder of the master private key can mint or amend it. A friend stores an incoming list verbatim (the signature travels with it) and never needs to re-verify, so additions and revocations are equally tamper-proof.

**Monotonic, replay-resistant merge.** The version is monotonic per master and is signed once per version, governing both the active and revoked sets together. A higher version is the latest word: it may both add devices and un-revoke them. A replay (lower-or-equal version) can never shrink the tombstone set, so it can never un-revoke a device. Because each device independently seeds its own list at version 1, receivers **union-merge** active sets (`union(devices) − revoked`, keeping the highest version) rather than rejecting a "stale" sibling list. Adding is monotonic and safe; removal happens only via the signed `revoked` set.

The signed list propagates as an attachment on profile sync, so friends converge on a person's full device set as their devices meet in shared rooms.

### 3.3 Device-to-Master Resolver

Clients maintain a resolver mapping each known device peer ID to its master. Its core invariant is that an **unknown peer ID resolves to itself**. A stranger, a single-device user, or a friend whose device list has not yet arrived is treated as their own identity. Note that this invariant, not an absence of indirection, is what makes single-device use safe: every install mints a distinct device key, so a device peer ID never equals its master even for a sole device, and the device→master path is therefore *always* exercised. Correctness rests entirely on the resolver's self-mapping fallback (and on per-person attribution collapsing to the master), not on any device==master special case. Multi-device behavior beyond that fallback activates only once a signed device list is ingested.

Two rules govern every cross-device interaction:

1. **Outbound targeted sends resolve master → device.** The relay reports device peer IDs, and only a device authenticates as a socket. Anything addressed to the bare master is in no room and is silently dropped, so a targeted send must expand the master to a concrete *online* device. **Content sends fan out** to all of a recipient's online devices (plus the sender's own siblings); **negotiated, key-paired connections** (a call, a WebRTC channel, a file stream) target exactly one device to avoid competing connections and answer glare.
2. **Inbound per-person attribution collapses device → master.** A message arriving from a device ID is filed and displayed under the person. Message-content signatures are made with the master key, so a message verifies across all of a person's devices regardless of which device sent it.

### 3.4 Device Linking and Snapshot Sync

A new, empty device pulls the full identity and database from an online existing device. There is no QR ceremony and no separate key exchange. The mnemonic *is* the pairing channel and the authorization: two installs of one mnemonic are already siblings.

- **Rendezvous:** linking uses a **6-character relay code** over an unambiguous alphabet, held in a RAM-only `code → peer_id` map on the relay with a 5-minute TTL, one-shot. The code is a rendezvous token only; the populated device's on-screen confirmation is the actual authorization before any key material leaves it.
- **Transfer reuses the encrypted-backup pipeline.** The transfer is *not* a parallel crypto path. The source produces exactly the bytes of an encrypted `.hollow` backup: `[magic][salt:16][nonce:12][AES-256-GCM]` with the key derived from the passphrase via Argon2id, where **the link code (or the shared master peer ID) is the passphrase**. The blob crossing the relay is therefore standard backup ciphertext; the relay carries ciphertext only. A receiver acknowledgement confirms receipt before the source reports success.
- **Stash-and-reboot import:** the receiver writes the blob to disk and restarts. On next launch, *before* the identity is loaded, it imports the backup, the identical path as a manual "restore from backup." In-place import while the node runs was deliberately rejected: it fought the live SQLCipher connection and a protection-mismatched throwaway identity, producing an unrecoverable load state. The rule is general: never swap identity or database in place while the node runs. Stash, restart, and import in the pre-boot window.

Because the snapshot copies the source's entire database, including its MLS signing material, a linked sibling **regenerates its own MLS signing identity** on import (§5). Reusing the source's MLS signature key would violate MLS's one-leaf-per-signature-key rule.

### 3.5 Sibling Synchronization and Backfill

A snapshot is a point-in-time copy; ongoing changes are reconciled continuously:

- **DM backfill:** when one device sends or receives DMs while a sibling is offline, the sibling pulls the missed history per-conversation on reconnect (gated on same-identity, so a friend can never trigger a whole-database pull). A subtler case is also handled: a friend can re-serve *your own* sends that are stranded on the friend's device because the originating sibling went offline before the receiving sibling came online.
- **Direction re-orientation:** a message-direction field received from a *friend* is sender-relative and is inverted at the receiver (used for both database insertion and signature-context reconstruction); a field received from a *sibling* (same identity) is not inverted. Signatures never involve device IDs, so they verify intact across devices provided the direction context is correct.
- **Server announcements:** server lifecycle changes converge a person's own siblings as well as offline members. Server creation announces to online siblings (which run a same-identity join fast path); on reconnect, a node re-announces all of its non-deleted servers when a sibling appears, and a manual per-device sync control re-drives the same onboarding primitives on demand.
- **Gap-resistant watermarks:** all catch-up sync (friend DMs, sibling backfill, channel history) is watermark-based: requests carry per-conversation or per-sender high-water timestamps. A plain high-watermark can permanently skip a message that was missed while a newer one arrived (for example, a delivery lost inside a reconnect window advances the watermark past the hole). Every request therefore asks from a fixed lookback window *below* its watermark, and receivers deduplicate the overlap by message ID, making redelivery idempotent. Holes near the watermark (the only place they can form) self-heal on the next sync, whenever it runs.
- **Deterministic delivery room:** a direct message is always routed into the recipient's *master-derived* DM room (a pure function of the two identities' master keys), not whichever room the sender happens to observe the recipient's device in at that instant. Two people can be co-present in several rooms at once during connection churn; picking an arbitrary one risks addressing a room the recipient has already left, which the relay would then buffer indefinitely against a room the recipient never re-enters: a silent, one-directional delivery hole. Because every device of the recipient is, by construction, a member of the single master-derived DM room, routing there makes online delivery deterministic while the relay's offline buffer still covers a recipient who is away.

### 3.6 Device Revocation

Revocation removes a device from a person's identity. It is **manual-only**: any device a person controls can revoke another, since all of a person's devices hold the master key (there is no privileged "primary" device). Revoking adds the target's device ID to the master-signed `revoked` array and bumps the version (§3.2), which is cryptographically binding and replay-resistant.

- **Self-teardown:** the new tombstoned list is sent **to the revoked device first**. On ingesting its own ID in the `revoked` set, that device wipes its local data directory and relaunches to a clean welcome screen. The cryptographic cutoff has already occurred for everyone else; this is the revoked device honestly tearing itself down.
- **Crypto enforcement on observers:** on ingesting a revocation, every other peer **drops and erases its Olm session** to the revoked device, and the MLS coordinator removes that device's single MLS leaf (advancing the epoch). The device's *master* remains a valid member; only that one device's leaf and sessions are torn down.
- **Liveness, not just session state:** a person's device list accumulates dead "ghost" device IDs across re-link cycles (each re-link mints a fresh device key; the union-merge never prunes, because pruning is what tombstones are for). Targeted fan-out therefore uses **room presence**, not session existence, as the liveness test: a message is fanned only to devices *currently in a room*. A ghost is in no room and is skipped, preventing phantom deliveries and stuck notification counts. Live devices that are merely offline still receive their copy via reconnect backfill (§3.5).

---

## 4. Direct Message Encryption (Olm / Double Ratchet)

DMs between two peers use the **Olm protocol** (Double Ratchet with Curve25519 key exchange) via the `vodozemac` library, the same cryptographic implementation used by Matrix/Element.

### 4.1 Session Establishment

1. **Key request:** peer A sends a `KeyRequest` to Peer B via the relay.
2. **Key bundle:** B generates a one-time Curve25519 key and responds with a `KeyBundle` containing its identity key and one-time key.
3. **Outbound session:** A creates an outbound Olm session using B's keys. The first message is a PreKey message (type 0).
4. **Inbound session:** B creates an inbound session from the PreKey message.
5. **Session acknowledgement:** a `SessionAck` handshake upgrades both sides to Normal (type 1) ratchet mode.

### 4.2 Double Ratchet Properties

- Every message uses a unique encryption key derived via the ratchet.
- Forward secrecy: compromising current keys does not reveal past messages.
- Post-compromise security: a new DH exchange heals the session after compromise.
- Message keys are deleted after use.

### 4.3 State Persistence

Olm session state is serialized ("pickled") to JSON and stored in SQLCipher. Sessions survive application restarts. Stale sessions (unused for 7+ days) are automatically pruned to limit storage growth.

### 4.4 Key Exchange via Relay

Key bundles travel as signed JSON messages through the relay. The relay sees base64-encoded key material but cannot derive session keys without the private Curve25519 keys, which never leave the device.

### 4.5 Self-Healing over an Unreliable Relay

The relay is a dumb pipe and **never acknowledges a direct message**: a successful TCP write is the only feedback the sender gets. A single dropped handshake frame (key request, key bundle, session acknowledgement, or pre-key message) must therefore not strand session establishment. Hollow makes Olm setup eventually self-healing:

- **Timestamped in-flight tracking:** outstanding key requests carry a timestamp and expire after a short timeout, so a lost request is retried rather than blocking forever.
- **Periodic reconciliation sweep:** a background sweep (every 30 seconds) re-initiates key exchange with online peers that lack a *confirmed* session and whose prior request has gone stale.
- **Confirmation is event-driven, never optimistic.** A session is reported "established" only on confirmation (a received session acknowledgement, or a successfully decrypted reply), never merely because an outbound session was created. This eliminates the class of failure where one side believes a session exists while the other never received it.

### 4.6 Glare Resolution (Multi-Device Aware)

When two peers send each other a key bundle simultaneously ("glare"), a deterministic tiebreaker decides which side keeps its outbound session. The comparison is made between two peer IDs **of the same kind** (each side's own **device** ID against the remote **device** ID), because Olm sessions live on transport sockets, which are device-keyed. Comparing a resolved master ID against a device ID would not be antisymmetric and could deadlock both sides into deferring; the device-versus-device comparison is consistent and always resolves.

---

## 5. Server Encryption (MLS)

Servers (group chats) use **Messaging Layer Security (MLS)**, RFC 9420.

### 5.1 Ciphersuite

```
MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519
```

- Key encapsulation: X25519 (Curve25519 DH)
- AEAD: AES-128-GCM
- Hash: SHA-256
- Signature: Ed25519

### 5.2 Group Lifecycle

**One MLS group per server, plus a subgroup per restricted channel.** By default all channels within a server share a single server-wide MLS group, with channel routing handled at the application layer. A channel with *restricted* visibility (a Moderator-and-above or Admin-and-above tier, or a non-empty access-label gate per §11.4, and not a public plaintext channel) is instead encrypted under its OWN dedicated MLS subgroup, whose membership is exactly the set of members passing the channel's visibility predicate (tier, label gate, or unexpired temporary grant). Because a non-qualifying member is never a member of that subgroup, it never holds the decryption key and never receives a decryptable copy of those messages. Channel visibility for restricted text channels is therefore a cryptographic boundary, not merely an application-layer filter. Subgroup membership is reconciled automatically on the events that change who qualifies (role change, visibility or label-gate change, label assignment/removal, grant issuance/revocation/expiry, join, kick, ban, leave): a deterministically elected subgroup coordinator (the lowest-id online member who both still qualifies and already holds the subgroup) issues the add/remove commits, advancing the subgroup epoch for forward secrecy. A member removed from a subgroup retains only the messages it already legitimately received.

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

**Commit distribution (large-server scaling):**
A Commit is byte-identical for every recipient, so it is distributed as a *single* room broadcast through the relay rather than one targeted send per member device. The coordinator's network work per membership change is constant, independent of server size. Welcomes remain targeted (each carries the group secrets for one joiner). Because a room broadcast also reaches members who do not need the commit (a fresh joiner whose Welcome already placed it at the post-commit epoch, or a duplicate delivery), every Commit carries its post-merge epoch number, and a receiver already at or past that epoch skips it silently instead of misclassifying its own state as stale. A receiver that does not hold the group at all ignores the commit. Recipients that do fall behind recover through commit catch-up (§5.3.2), falling back to the re-bootstrap path when the gap cannot be bridged, and a removed member attempting to re-bootstrap is refused by the membership check on incoming KeyPackages.

**Rejoining after removal (ban/unban cycle):**
A peer who was removed and later re-invited must drop its stale MLS group state and bootstrap from scratch. The rejoining peer sends a fresh KeyPackage to the coordinator. Without this, the rejoining peer's stale epoch causes one-way decryption failure.

### 5.2.1 Multi-Device Membership (Per-Device Leaves)

A person who is a server member with multiple devices holds **one MLS leaf per device**. Each leaf's credential is the bare device peer ID, and each device generates its own distinct MLS signature key, so the leaves are cryptographically independent.

The CRDT membership map (§10), by contrast, keys each member by their **master** identity: one human is one member entry, regardless of how many devices they run. This produces the system's central multi-device invariant:

> **Membership state is master-keyed; the MLS ratchet tree is device-keyed.** Every comparison that bridges the two (is this sender a member? what is their role?) collapses the device ID to its master through the resolver (§3.3). Membership and permission checks operate on the master; MLS encryption and decryption operate on per-device leaves.

Because the bare master is in no transport room, every targeted member send is fanned out master → online devices. Adding or removing a single device adjusts exactly that device's leaf (one epoch advance); the person's other devices and their membership entry are unaffected.

**Linked-sibling key regeneration.** A device linked via snapshot import (§3.4) inherits the source device's MLS signing material in the copied database. It deterministically clears and regenerates that material before joining any group, because two leaves sharing one signature key violate MLS and would prevent the sibling from adding to or decrypting in any group. A legacy sole-device install (no siblings) keeps its original leaf untouched, never re-keying it, since no peer could re-add it.

### 5.3 Distributed Coordinator Model

MLS operations (add/remove) require a single member to generate the Commit. Hollow uses **deterministic coordinator election**: the online member with the lexicographically lowest peer ID in the MLS group acts as coordinator. This avoids conflicts without requiring consensus, and ensures any member can onboard new joiners, not just the server owner.

**Sender exclusion:** When a peer sends a KeyPackage (indicating it lost its MLS group state), that peer is excluded from the coordinator election for processing that KeyPackage. Without this, the lowest-ID peer losing its group would create a permanent deadlock: it would be elected coordinator for its own recovery but cannot process its own KeyPackage.

### 5.3.1 MLS Auto-Recovery

Three recovery paths ensure MLS group membership self-heals after disruptions:

1. **Unknown group on message receipt:** when a peer receives an `MlsChannelMessage` for a group it doesn't have, it sends a KeyPackage to the coordinator (lowest online peer, excluding self). The coordinator adds it back to the group via a Welcome message.

2. **Peer join detection:** when a `PeerJoined` event fires for a shared server, each peer checks if it has the MLS group. If not, it sends a KeyPackage to the coordinator. If the local peer *is* the coordinator, it requests the joining peer's KeyPackage instead.

3. **Startup member enumeration:** when `RoomMembers` arrives (listing all connected peers on startup), each peer checks for missing MLS groups for all shared servers and sends KeyPackages as needed.

### 5.3.2 Stale-Epoch Detection and Commit Catch-Up

The recovery paths above key on a *missing* group. A group that is present but **stale**, where the member missed one or more commit broadcasts (a broadcast is fire-and-forget: a socket not in the room at that instant, or a dropped frame, loses it permanently), is a distinct failure mode: the member believes it is healthy, exports a stale media key (§6), and in a voice-only channel no MLS ciphertext ever arrives to fail a decrypt and trigger resync.

Two mechanisms close this gap:

- **Epoch hints:** a member advertises its current epoch for a group alongside the plaintext first-contact synchronization exchange, at voice-channel join, and from the media heal ladder. A hint is advisory and deliberately powerless: a member that learns it may itself be behind sends a throttled probe to the group authority; a hint can never cause a group to be dropped (that would hand any peer a remote group-reset primitive).
- **Commit catch-up:** every member retains a short ring of recently broadcast commit messages per group. When a member learns from a hint that another is behind, exactly one of them answers, and *which* one is elected with the member that is behind excluded from the candidate set. The authority cannot serve itself: the server-wide group prefers the owner as its committer (§5.3), so an owner that missed an epoch it did not author would otherwise be nominated as its own rescuer while the member actually holding the newer epoch stood down as non-authoritative, and neither would act. Excluding the lagging peer makes the asker and the answerer compute the same single responder. A probe addressed to a specific member is answered by that member directly, without a second election, because the asker chose it from a view of the membership the answerer may not share. The elected responder replays the missed commits, in order, directly to the member that is behind. The member applies them through the same validated path as live commits: each is accepted only if it advances the group by exactly one epoch, so a forged or gapped replay is refused before it can trigger any destructive recovery. Catch-up replays material that was already broadcast to the whole room, so it discloses nothing new; the requester must be a current member.

Catch-up converges a stale member in one round trip **without generating new commits**. This matters because the fallback repair, removing and re-adding the member's leaves, advances the epoch for everyone and re-keys all media, so under churn repair-by-re-add can cascade. Re-add remains the fallback when the cache cannot bridge the gap.

Preserving that distinction requires the cheap path to be given the chance to run. A member that reconnects receives the relay's buffered traffic for the interval it was away as a single burst, and every frame of it is undecryptable at the member's stale epoch. Counting those as independent evidence of a broken group would trip the destructive repair within milliseconds of reconnecting, before any hint had been exchanged, discarding the catch-up already in flight. Sustained decryption failure is therefore measured over a minimum interval rather than by a bare count, and a group is never discarded while a probe it issued is still outstanding. A burst is one event.

### 5.4 Epoch and Key Rotation

Every membership change advances the MLS **epoch**. Each epoch derives fresh encryption keys. An attacker who compromises keys from one epoch cannot decrypt messages from other epochs.

### 5.4.1 State Persistence Invariants

The MLS group state persisted to SQLCipher comprises the signature keypair, the credential, and the serialized group (ratchet tree, secret tree, and epoch). Three invariants keep group membership self-consistent across restarts and reconnections:

- **Persist on encrypt:** encrypting a message advances the sender's secret-tree generation. The group state is persisted immediately after every encrypt, so a restart cannot reuse a stale generation (which the receiver would reject as secret reuse).
- **Sync requests are plaintext.** After a reconnection a peer's MLS epoch may be stale, so synchronization requests and other idempotent coordination probes are sent as plaintext envelopes (§5.6) rather than MLS-encrypted. CRDT broadcasts fall back to plaintext if MLS encryption fails.
- **Decryption failure triggers resync.** A peer that cannot decrypt a message it should be able to read treats this as evidence of a missed epoch and immediately synchronizes from the sender.

### 5.5 Targeted Peer-to-Peer Encryption

Server-context operations that target a specific peer (shard requests/responses, sync payloads, file transfers, voice SDP/ICE signaling) use **Olm + direct send** instead of MLS broadcast. This is O(1) per operation instead of O(n) broadcast, and avoids churning the MLS group ratchet for peer-to-peer work. MLS broadcast is reserved for channel messages that all members need to see.

### 5.6 Reconnection Caveat

After a WebSocket reconnection, a peer's MLS epoch may be stale. Messages that must work immediately after reconnection (sync requests, shard coordination, voice channel state changes) are sent as plaintext `HavenMessage` envelopes. This is a deliberate design choice: these messages are idempotent probes that carry no sensitive content.

### 5.7 Conferences (Ad-Hoc MLS Groups)

Conferences are meetings between peers who may share no server and no prior relationship. A conference is a *virtual server*: a single identifier (`conf:` followed by a random 128-bit value carried only in URL fragments, never in server-visible paths) is the relay room code, the MLS group key, and the voice-channel context. Because conferences have no CRDT state, none of the server synchronization machinery applies to them.

**Admission is the cryptography.** The host of a meeting creates a fresh MLS group per session, so attendees of a past meeting cannot decrypt a future one. A prospective joiner enters the relay room and broadcasts a join request carrying a fresh KeyPackage, a display name, an avatar *hash* (never image bytes), and optionally a salted hash of an access code. Until the host commits an MLS `add` for that KeyPackage, the joiner observes only ciphertext: the waiting room is a key-distribution boundary, not a UI convention. Removal from a meeting is an MLS `remove` commit, and the SFrame media key rotates away from the removed member before any user-interface teardown occurs.

Membership checks for conference voice signaling substitute the missing CRDT membership test with an MLS one: a plaintext voice-channel announcement is accepted only if its sender's device identifier appears in the conference group's leaf credential set, which only an admitted member can achieve.

**Conference chat is ephemeral by construction.** Chat lines are MLS application messages attributed by the authenticated leaf credential (not the transport sender, which is unauthenticated framing). They are never written to the local database, never enter relay availability buffers, and receiving nodes drop any attempt to route persistent channel-message envelopes under a conference identifier. When the meeting ends, the group is discarded and no record of the conversation exists anywhere.

---

## 6. Voice, Video, and Screen Share Encryption (SFrame)

Real-time media streams are encrypted with **SFrame** (Secure Frames) using keys derived from the MLS epoch.

### 6.1 Key Derivation

**Server voice channels:** The SFrame key is derived from the MLS group's epoch:

```
SFrame key = MLS group.export_secret("sframe", context=[], key_length=32)
```

Each MLS epoch produces a unique 32-byte SFrame key. When the epoch advances (member join/leave), the SFrame key rotates automatically.

**Restricted voice channels** (visibility above the base tier, non-public) derive their SFrame key from the channel's *own* per-channel MLS subgroup rather than the server-wide group: the same Option B subgroup that encrypts the channel's text (see §5, Per-Channel Subgroups). Because only members passing the channel's visibility predicate (tier, label gate, or unexpired grant, per §11.4) hold the subgroup, a non-qualifying member cannot derive the channel's SFrame key and therefore cannot decode its audio/video/screen-share frames. Voice-channel access for a restricted channel is thus a cryptographic boundary, not merely a server-side authorization check: the key is the gate. A member who is demoted, removed, or loses access mid-call triggers a subgroup epoch advance (remove-commit), which re-keys the remaining participants for forward secrecy and the now-unauthorized member is dropped from the call.

**1:1 DM calls:** A random 32-byte key is generated per call and transmitted inside the Olm-encrypted `CallInvite` message.

The key is bound to the *call*, not to the transport carrying it. A call whose
media path is interrupted may have its peer connection rebuilt in place while
the call continues, and the same key is re-applied to the new connection: network
recovery is not a re-keying event and requires no further key exchange. This is
deliberate. Re-keying on every network interruption would mean a key exchange at
precisely the moment the network is least able to carry one, and it would buy
nothing: the participants are unchanged, so there is no membership change to
give forward secrecy against. Key rotation remains tied to the events that
change who can listen, which for a DM call is the call itself ending.

### 6.2 Encryption

- **Algorithm:** AES-128-GCM
- **Key:** Derived per the SFrame specification from the exported secret
- **Per-frame encryption:** Each audio and video frame is independently encrypted

### 6.3 Scope

SFrame E2EE is applied to:

- **Voice calls** (1:1 DM calls and server voice channels)
- **Video calls** (1:1 DM calls and server voice channels)
- **Screen sharing video** (1:1 DM screen share and server voice channel screen share)
- **Screen sharing audio** (platform-dependent transport; see §6.8)

All media types using WebRTC media tracks (audio tracks, video tracks, and screen share video tracks) are encrypted with the same SFrame key for a given session or epoch.

Voice and video calls are available on all platforms, including mobile (Android and iOS), with the same SFrame encryption. Screen-share sending and system-audio capture are likewise available on every platform: Windows, macOS, Linux, Android (MediaProjection + AudioPlaybackCapture), and iOS (a ReplayKit Broadcast Upload Extension). The platform-specific capture paths are described in §6.8.

### 6.4 Transport

Voice, video, and screen share video travel over **WebRTC peer-to-peer connections** (DTLS-SRTP as the base transport, SFrame as the application-layer encryption). In the default case the relay is not in the media path at all; it carries only WebRTC signaling (SDP offers/answers, ICE candidates). Two exceptions exist for peers that cannot establish a direct path, both carrying ciphertext only: the TURN relay and the packet-forwarder role described below.

**Screen shares are consent-based per viewer.** A sharer announces the share's existence with a lightweight state signal, but never negotiates a media connection to a participant until that participant explicitly requests it (a targeted watch signal; the request is revocable, and revocation tears the per-viewer connection down). Receivers symmetrically discard share offers they did not request. This is both a bandwidth property and a consent property. In a per-viewer mesh the sharer uploads one copy per *watching* peer, so participants who joined only to talk cost the sharer nothing; and no participant's client decodes another's screen content without an explicit local action.

**Streams are sized to their audience.** The watch request also carries the viewer's display resolution, and the sharer, which encodes independently per viewer, sends each watcher a stream no larger than that viewer can display. A 4K share watched from 1080p screens costs each viewer-connection 1080p, not 4K, cutting both the sharer's upload and encoding cost roughly in proportion to the pixel difference. The bound is the viewer's own display, so the sizing is automatic and carries no per-viewer override: a viewer already receives every pixel it can render. Where a single encoded stream is shared by several viewers (the forwarder role described below), it is sized to the largest display among them, a consequence of sharing one encode rather than a policy choice. Clients that predate the field simply receive the share at its chosen quality.

For peers behind symmetric NATs (~10-15% of users), a **TURN server** relays the encrypted media. The TURN server sees only SFrame ciphertext.

**Packet forwarding: a role, not a server.** TURN is a blind per-connection pipe with no concept of a *stream*, so it cannot share bytes between two viewers of the same screen share, and a sharer with k restricted-NAT viewers pays k separate encoded copies while the relay carries `2·B·k` (ingress plus egress per viewer). Hollow therefore defines a **forwarder role**: a participant that receives SFrame-encrypted RTP for one stream and fans the packets to downstream viewers. One ingest, k egresses: `B + B·k` at the relay, and exactly one encoded copy from the sharer regardless of audience size. Quality adaptation preserves the same boundary: the sharer may encode the stream as a small set of simulcast layers, each independently encrypted under the same sender key, and a forwarder serves each viewer the layer the sharer designated by *selecting which packets to forward*, never by transcoding, which would require keys it does not hold. A source that carries no layers passes through byte-identical.

The role's security properties follow from where the encryption boundary sits. The outer transport encryption (DTLS-SRTP) is hop-by-hop and terminates at each connection, but SFrame is bound to the **originator**: frames are encrypted once, by the sharer, under a key derived from the group's MLS epoch. A forwarder reads only RTP headers (stream identity and sequence) to route; it cannot read payloads, and it cannot alter them undetectably because the authentication tag would fail. It holds no group keys, is not a group member, and by construction cannot satisfy the membership predicates that gate group traffic; its control plane is a separate message namespace in its own relay room. This is the relay philosophy applied to live media: **availability helper, never authority.** If a forwarder refuses a stream, exhausts its bandwidth budget, or disappears mid-session, the affected viewers fall back to the direct or TURN path and the share survives.

Two invariants make forwarding safe rather than merely efficient. First, **attribution binds to the originator, not the deliverer**: a forwarded stream carries the originating peer, stream kind, and a per-session stream identifier, and receivers key display attribution, viewer consent, deduplication, and their decryption context on the *originator*, while transport state stays keyed on whichever neighbour delivered the packets. Because the group's media key is shared, an unchecked origin claim would let any member attribute their own pixels to a victim, so an inbound origin is accepted only when it names the authenticated sender, and any other combination causes the whole signal to be discarded. Second, **consent survives the extra hop**: a forwarder serves a viewer only if the sharer authorized that specific viewer for that specific stream, and the sharer authorizes only viewers who explicitly requested the share (§6.4, consent-based screen shares). Adding a hop therefore changes who *carries* the bytes, never who is permitted to decode them.

The role is deliberately specified independently of who plays it. An operator-run forwarder is the reliability floor and the answer for restricted-NAT viewers; a well-connected participant with spare upload can play the identical role, in which case the operator's infrastructure carries no media at all. Neither variant is a media server in the conventional sense: it is a blind, keyless, replaceable member of a forwarding mesh, and when every participant in a session can reach every other directly, the role simply never wakes up.

**Address visibility and the relay-only option.** A successful direct path means the two endpoints have exchanged and probed each other's candidate addresses, so co-participants in a session observe each other's IP addresses. Encryption protects content, not network addresses, and this is inherent to direct peer-to-peer media rather than a property of this system in particular. The exposure is bounded to *participants in a session the user joined*: there is no tracker, no DHT, and no mechanism by which a non-participant or passive observer obtains the address.

For users who prefer to trade latency and quality for address privacy, a per-account setting forces every real-time connection onto the TURN relay, so a co-participant sees only the relay's address. The setting is applied where the ICE configuration is produced rather than at each call site, so it cannot be omitted by one code path; it restricts candidate gathering to relay candidates only, and **fails closed**: if relay credentials are unavailable the connection is not established rather than silently falling back to a direct path. It is **off by default**: relaying all media would forfeit the latency advantage that motivates direct connections and would concentrate every session's bandwidth on relay infrastructure. Hollow Share is deliberately outside its scope (§8.4), and the setting's description states so.

The setting also constrains the forwarder role in both directions. A forced-relay participant never advertises forwarding capability, so their machine never carries another member's media; and their own media is never routed through a member-operated forwarder: their watch requests mark them relay-private, the sharer routes them only through operator-run infrastructure or TURN (the same trust domain the setting already accepts), and the viewer independently refuses any assignment to a member-operated forwarder, so a buggy or malicious sharer cannot re-route them. Enforcement is therefore mutual: the preference holds even against a counterparty that ignores it.

### 6.5 Call Topologies

- **1:1 calls:** Direct peer-to-peer WebRTC. Lowest latency, no intermediary.
- **Small group (2-5 participants):** Full mesh: every participant sends to every other participant.
- **Larger group (6+ participants):** Gossip-tree forwarding for *audio*. Each participant forwards received audio to their connected subset of peers (6-12 neighbors), covering large groups in 2-3 hops with no central media server and zero operator bandwidth. Note this tree re-attaches decoded tracks at each hop, which is nearly free for a 32 kbps voice codec; for video it would mean decode-and-re-encode per hop, i.e. compounding CPU cost and generational quality loss. Video is therefore forwarded at the *packet* level instead, by the forwarder role described in §6.4.
- **Transition:** Automatic with hysteresis: mesh below 6 participants, gossip at 6+, back to mesh at 4.

### 6.6 Key Index Synchronization

SFrame cryptors must be initialized with the correct key index corresponding to the current MLS epoch (`epoch % 16`). New keys are applied via key rotation (not replacement) to update all existing cryptor indices atomically. The key index is explicitly set per peer after every cryptor creation. Without this, cryptors default to key index 0 and silently fail to decrypt frames encrypted under a non-zero epoch index.

Cryptors are bound to individual RTP senders and receivers. When a renegotiation replaces a media sender mid-call (for example, a live input-device switch), the cryptor pair is re-established on both endpoints (the sender's at the point of the swap, the receiver's when the replacement track arrives), so the new track is encrypted under the same session key with no window in which media falls back to transport-only encryption.

**Failure recovery.** Because SFrame keys derive from MLS group state, two participants whose group states diverge (a missed commit, a delivery race, or an eviction) would otherwise decrypt nothing from each other for the remainder of the call. The media layer therefore treats sustained decryption failure as a signal, not a terminal state: the affected endpoint first re-applies its current key material and re-binds the failing cryptors, then re-derives and re-applies the key from its MLS group, and finally, if failures persist, converges the group itself: a non-authoritative member discards its group state and re-bootstraps from the group authority (the server owner, or the subgroup coordinator for a restricted channel), while the authority removes and re-adds the failing member's leaves, re-keying every participant in the process. Escalation to group surgery is rate-limited and bounded per peer, so a peer that can never converge cannot force unbounded epoch churn on the group. A member whose own leaf is removed by a commit detects the resulting inactive group state and, if it is still a legitimate member, re-bootstraps rather than retaining an unusable group. The ladder is complemented by a keyless watchdog: an endpoint that holds no key material at all (a fresh or recovered device whose group admission has not yet completed) periodically re-requests admission from the group authority until its first key arrives, since with no cryptors instantiated there are no decryption failures to trigger the ladder. Together these mean a key-material disagreement degrades to a few seconds of silence followed by convergence, never to indefinitely garbled or lost media.

### 6.7 SFrame Key Memory Handling

SFrame keys are zeroed in memory after use. Key bytes are cleared via `fillRange(0, length, 0)` in `finally` blocks at every site where keys are set or consumed.

### 6.8 Screen Share Audio Transport

Screen share audio never travels as a WebRTC audio track on any platform. Routing system audio through a voice track is not viable: libwebrtc's AudioDeviceModule (ADM) is a singleton that contaminates both the capture and render endpoints, and the voice pipeline's AGC/AEC processing audibly degrades music. The audio is instead encoded with **Opus** (48 kHz stereo) and forwarded as framed packets over the **WebRTC data channel** (type `0x03` prefix). On desktop the capture and codec run in a separate helper process; on mobile, where a child process is unavailable, the codec runs in-process in the Rust core while the capture uses the platform's sanctioned system-audio APIs.

**Capture path (sender):**

- **Windows:** the `screen_audio_capturer` helper captures system audio via WASAPI loopback (`--mode pipe`). Per-process window audio capture is supported on Windows 10 2004+ via process loopback INCLUDE mode, allowing capture of a single application's audio output. For a whole-screen share, the capture excludes the application's own audio output so the remote participants' voices are not re-broadcast into the share (the equivalent of the macOS self-exclusion). Because Windows can only filter loopback at the process-tree boundary, and the application's call-voice playback and its own legitimately-played media (e.g. a video opened in a chat) would otherwise share one process, the received call-voice audio is rendered in a separate child process during such a share, so that the call voices can be excluded from the capture while the application's own media is still captured for the viewers.
- **macOS 13.0+:** an audio-only **ScreenCaptureKit** stream captures system audio; the application excludes its own process output from the capture so the remote participants' voices are not re-broadcast into the share. The captured PCM is piped to the helper in `--mode encode`. macOS versions **below 13.0** expose no public system-audio capture API, so the audio toggle is locked off in the screen-share dialog with an explanatory notice.
- **Linux:** the helper captures per-application audio streams from the PulseAudio/PipeWire sound server (`--mode pipe`), one monitor stream per playback stream, mixed to a single feed. For a whole-screen share it captures every application's audio *except* the application's own (so remote participants' voices are not re-broadcast: the Windows/macOS self-exclusion equivalent, at the cost of the application's own played media). For a window share on an X11 session it captures *only* the shared application's streams, resolved from the shared window to its owning process tree; a window that cannot be resolved, or an application playing nothing, contributes silence; the capture never silently widens to the full system mix. This matters for privacy: sharing one application's window never leaks audio from other applications (a notification sound, a private call in another app). On a **Wayland** session this per-window resolution is not possible: the compositor's screen-sharing portal never reveals *which* window it granted, so there is no window-to-process mapping to resolve. Wayland shares therefore always use the whole-screen audio behavior (every application except Hollow's own), and the client discloses this in the share dialog before capture begins, so the capture still never *silently* widens beyond what the user was told.
- **Android (10+):** the client captures other applications' playback via **AudioPlaybackCapture** attached to the same MediaProjection session that captures the screen video, and Opus-encodes it in the Rust core. The microphone path is fully independent: the user talks over the shared audio. The application declares its own playback non-capturable (`allowAudioPlaybackCapture=false`), so remote participants' voices can never be re-captured into the share (and third-party apps cannot record Hollow's call audio via the same API). Applications that opt out of playback capture (some DRM media apps) contribute silence.
- **iOS:** a **ReplayKit Broadcast Upload Extension**, the system-sanctioned path that captures the whole screen and the foreground application's audio even while Hollow is backgrounded, runs in a separate process and streams video frames and app-audio PCM to the client over two unix sockets in the shared App Group container (video and audio deliberately use separate sockets with independent framing). The client Opus-encodes the audio in the Rust core. The microphone buffer type is ignored: the voice call carries the mic.

**Render path (receiver):** on desktop, a separate renderer process reads Opus packets from stdin, decodes, and outputs to platform audio (waveOut on Windows, AudioQueue on macOS, PulseAudio on Linux). On mobile (Android/iOS), the client decodes the Opus packets in-process and plays them through the platform's *media* output path, outside the voice call's audio session, so voice-call echo cancellation and gain control never process the shared audio. Playback level control (a loudness calibration relative to the voice target, a per-user volume, and automatic ducking while call participants speak) is applied by each receiver locally after decode; the transmitted stream itself is never re-leveled or re-encoded, so every receiver gets the full-fidelity source.

Because the reliable, ordered data channel force-closes if its SCTP send buffer reaches the 16 MB cap under sustained audio load (most likely over a TURN relay), the sender applies backpressure: it drops screen-audio packets while the buffered amount is backed up, trading a momentary gap for a live channel.

**Encryption:** Screen share audio over data channels is encrypted at the transport layer (DTLS) but does not use SFrame. The data channel's DTLS encryption provides confidentiality equivalent to DTLS-SRTP.

---

## 7. File Transfer Encryption

### 7.1 Direct File Transfer (P2P)

Files are encrypted before transmission:

- **Algorithm:** AES-256-GCM
- **Key:** 32 bytes, randomly generated per file
- **Nonce:** 12 bytes, randomly generated per file
- **Auth tag:** 16 bytes (implicit in GCM)

The entire file is encrypted as a single unit. The AES key and nonce are transmitted inside the `FileHeader` message, which is encrypted via Olm (DMs) or MLS (servers). File bytes are streamed separately over WebRTC data channels (peer-to-peer) with a fallback to WebSocket relay streaming.

### 7.2 Transport Priority

1. **WebRTC data channel** (direct P2P): preferred. ~9 MB/s throughput (depends on the Internet connection speed).
2. **WebSocket relay streaming:** fallback when WebRTC is unavailable. Relay forwards the encrypted bytes without reading them.

File metadata (name, size, AES key, nonce, and, for images and videos, a small preview thumbnail) always travels through the encrypted channel (Olm/MLS via relay). Only the encrypted file bytes use the WebRTC data channel. This separation ensures that even if the P2P connection is compromised, the encryption key is not exposed.

### 7.3 Image Processing

All images are auto-converted to Balanced WebP on send (~95% smaller than PNG/JPEG; similar quality). Metadata (EXIF, GPS, camera info) is stripped before transmission. Configurable quality tiers: Lossless (100%), Balanced (50%), Small (30%).

Image sends additionally embed a tiny (≤32 px) placeholder thumbnail inside the encrypted `FileHeader`; video sends embed a size-bounded poster frame the same way. Receivers enforce an independent size cap on this field before storing or displaying it. Because the thumbnail rides the same encrypted envelope as the rest of the file metadata, it reveals nothing to the relay.

### 7.4 Receiver Download Consent

Automatic downloading is a receiver-side policy (a global size threshold with per-conversation overrides; zero disables it). Enforcement is local: a receiver whose policy rejects a transfer keeps the encrypted metadata (so the message still renders, with the embedded thumbnail as its preview) but never stores the file bytes; an explicit manual request always overrides the policy for exactly the requested file.

As an optimization, a device may advertise its effective threshold for a conversation to its DM peers so that a compliant sender skips transmitting bytes the receiver would discard. This advertisement is a single size value carried in a plaintext control message (comparable to a typing indicator); it contains no content and is advisory only: enforcement never depends on it, and a sender that ignores it merely wastes its own bandwidth against the receiver's local policy. Voice messages, being small and conversational, are exempt from the policy on both sides.

---

## 8. Hollow Share (Private P2P File Distribution)

Share is a chunked, resumable, multi-source P2P file distribution system, conceptually similar to BitTorrent but with end-to-end encryption, no tracker, and no public DHT. Because transfers are peer-to-peer, the peers in a given swarm see each other's IP addresses; unlike a torrent there is no tracker or DHT from which a non-participant could enumerate them (§8.4).

### 8.1 Chunk Encryption

- **Algorithm:** AES-256-GCM
- **Key:** 32 bytes, randomly generated per share
- **Chunk size:** 262,144 bytes (256 KiB)
- **Nonce derivation:** `[0x00; 4] || chunk_index_big_endian_u64` (12 bytes)
  - Deterministic: same key + different chunk index = unique nonce
  - No nonce reuse within a share's lifetime

### 8.2 Manifest

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

**Root hash:** SHA-256 of the canonical JSON manifest. It is the content identifier.

### 8.3 Share Link

```
hollow://share/<base64url([version: 1 byte][root_hash: 32 bytes][key: 32 bytes])>
```

65-byte payload, 87 base64url characters, QR-code compatible. The link encodes everything needed to verify and decrypt the file. Anyone with the link can download; anyone without it cannot. The link IS the access control.

### 8.4 Peer Discovery and Chunk Transport

- **Relay rendezvous:** Peers join a relay room keyed by the root hash. The relay forwards only signaling; zero file bytes ever touch the relay.
- **STUN-only WebRTC on a dedicated connection:** Share negotiates its own peer connection to each swarm member, separate from the general-purpose data channel that carries messaging file transfers, screen-share audio and gossip. That separation is what makes the guarantee hold: the general connection is configured with a TURN relay for peers behind symmetric NATs, so a share sharing it would silently inherit a relayed path. The Share connection is offered, answered and re-established only from a STUN-only configuration, and relayed candidates proposed by the remote peer are refused locally rather than trusted not to appear. If no direct path can be established, chunks are skipped, never relayed.
- **Address visibility, stated precisely:** ICE candidates are exchanged through the encrypted relay and never published to a public DHT or tracker, so no third party can enumerate the participants in a share. The peers *within* a swarm do observe each other's addresses, which is inherent to any direct peer-to-peer transfer. This is a deliberate trade: the alternative is relaying multi-gigabyte payloads through infrastructure that is funded for messaging and voice.
- **ISP-invisible:** Looks like normal WebRTC traffic with no protocol fingerprint to throttle.

### 8.5 Download Protocol

- **Have-map exchange:** Compact bitmaps (MSB-first, 1 bit per chunk) broadcast every 10 seconds.
- **Rarest-first scheduling:** BitTorrent-style piece selection across all connected peers.
- **Chunk verification:** SHA-256 of each received ciphertext chunk is verified against the manifest before decryption. Tampered chunks are rejected and re-requested from a different peer.
- **Max 4 inflight chunks per peer** to avoid WebRTC data channel buffer overflow.
- **Receiver-initiated WebRTC reconnection** with 10-second stale-offer timeout.
- **Bandwidth management:** Process-wide token bucket (20 MiB/s refill, 40 MiB burst). Scheduler pauses for 200ms after any messaging or voice traffic to avoid interference. Two scheduling modes: rarest-first (default, optimizes swarm health) and sequential (optimizes single-file completion).

### 8.6 Share-Backed Large Files

Files larger than 34 MB sent in DMs or server channels transparently use Share as the transport layer instead of direct WebRTC data channel streaming. The sender creates a hidden Share, and the `FileHeader` message includes a `ShareRef` (root hash + AES key) instead of triggering a binary stream.

The receiver downloads via the Share protocol (chunked, resumable, multi-source) and the file appears in the UI identically to a direct transfer. This integration bypasses the normal file size check in three places: sender-side size validation, receiver-side MLS/Olm path size validation, and `PendingFileStream` registration (which is skipped entirely for share-backed files).

Share-backed transfers ride the same dedicated **STUN-only** Share connection as ordinary shares (§8.4), including to a peer the sender is already exchanging messages with over a TURN-capable connection, so large-file traffic never consumes relay bandwidth.

### 8.7 Persistence and Seeding

- Download state (have-bitmap, chunk progress) is persisted to the local database. Paused or interrupted downloads resume without re-fetching.
- Completed files automatically seed. Seeding state survives app restarts.
- Zero-copy seeding: the original file is read directly. Chunks are encrypted on-the-fly with AES-256-GCM (~50µs per 256 KiB chunk on AES-NI hardware).

---

## 9. Vault (Distributed Encrypted Storage)

The Vault provides persistent distributed storage for server files (doesn't include images) using adaptive erasure coding. Every member donates storage. Files are encrypted before erasure coding, so shard-holding members see only encrypted noise.

### 9.1 File Encryption

Files are encrypted **before** erasure coding:

- **Algorithm:** AES-256-GCM
- **Key/nonce:** Random per file, stored in the manifest (encrypted via MLS for the server)

### 9.2 Adaptive Storage Modes

**Small servers (<6 members): Full Replication**
Every file is synced to every member. Simple, reliable. Storage overhead: N× (where N = member count).

**Larger servers (6+ members): Reed-Solomon Erasure Coding**
Files are split into `k` data shards + `m` parity shards. Any `k` of `k+m` shards can reconstruct the original ciphertext.

| Members | k | m | Total shards | Tolerance | Overhead |
|---------|---|---|-------------|-----------|----------|
| < 6 | n/a | n/a | Full replication | All but 1 | N× |
| 6-8 | 3 | 2 | 5 | 2 offline | 1.67× |
| 9-15 | 5 | 3 | 8 | 3 offline | 1.60× |
| 16-30 | 8 | 4 | 12 | 4 offline | 1.50× |
| 31-60 | 10 | 5 | 15 | 5 offline | 1.50× |
| 61-150 | 12 | 6 | 18 | 6 offline | 1.50× |
| 151-500 | 16 | 8 | 24 | 8 offline | 1.50× |
| 500+ | 20 | 10 | 30 | 10 offline | 1.50× |

Parameters scale with `log(member_count)`, overhead converges to 1.5×. Computed automatically; no admin configuration needed.

### 9.3 Content-Addressed Storage

Every piece of data is addressed by its SHA-256 hash:

```
content_id = SHA-256(encrypted_data)
```

This provides deduplication, integrity verification, and location-independent addressing.

### 9.4 Deterministic Shard Placement (XOR Distance)

Shard placement is deterministic, so all peers compute the same placements independently:

1. `content_id = SHA-256(encrypted_data)`
2. For each shard `i`: `shard_key = SHA-256(content_id || i_as_u16_be)`
3. For each peer: `distance = XOR(shard_key, SHA-256(peer_id))`
4. Sort peers by distance (ascending), assign shard to closest peer with available capacity.
5. Weighted by storage pledge: peers with larger pledges get proportionally more shards.

Any peer can independently recompute placements using the content ID + member list + pledges (all available via CRDT). No central directory needed.

### 9.5 Shard Format

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

### 9.6 Storage Tiers and Retention

| Data Type | Tier | Default Retention |
|-----------|------|-------------------|
| All files | Standard (1.0× parity) | 365 days |
| Channel messages | Configurable via CRDT | 365 days (default) |

Retention is forward-only: changing the retention setting only affects content created after the change. Existing files and messages keep their original retention. This prevents retroactive evidence destruction. Message retention is a per-server CRDT setting; file retention is per-tier.

### 9.7 Self-Healing and Rebalancing

When a member departs:
1. Surviving members detect under-replicated content by comparing confirmed placements against online peers.
2. The vault coordinator (2nd-lowest online peer ID) computes a repair plan: which missing shards to regenerate and where to place them. The vault coordinator is intentionally separated from the MLS coordinator (lowest peer ID) to distribute work across peers.
3. Peers with sufficient shards reconstruct the missing ones via Reed-Solomon decoding and redistribute them.

When a new member joins:
1. Placements are recomputed with the new member included.
2. A migration plan moves shards from over-capacity peers to the new member.
3. Migration happens gradually in the background.

### 9.8 Recovery Pool Protocol

When a server is dissolved or members are ejected, ex-members can cooperatively reconstruct files using the shards they still hold locally:

1. **Pool formation:** the initiator creates a relay room keyed by a random pool ID and broadcasts a `RecoveryHello` message containing their local shard inventory (manifest IDs + shard indices).

2. **Inventory exchange:** each joining member sends their own `RecoveryHello` with their local inventory. The pool coordinator (lowest online peer ID) aggregates all inventories.

3. **Transfer planning:** the coordinator computes a transfer plan: for each file, the first member holding sufficient shards becomes the source. Missing shards are assigned as transfers to members who need them.

4. **Reconstruction:** once a member collects `k` shards for a file, Reed-Solomon decoding reconstructs the encrypted ciphertext. Members who were in the server hold the MLS epoch keys needed to decrypt.

5. **Status tracking:** the pool tracks per-file status: fully reconstructable, partially available, or no shards found. Progress is reported as a percentage across all files.

Shard inventories can also be exported/imported as `.hollow-shards` bundles for out-of-band exchange.

### 9.9 Storage Layout

- Shards: `~/.hollow/vault/{server_id}/{shard_key}.shard`
- Decrypted cache: `~/.hollow/vault_cache/{content_id}.{ext}` (LRU-evicted, 1 GB cap)
- Full-replication files: `~/.hollow/files/{file_id}.{ext}`

---

## 10. CRDT Synchronization

Server state (channels, members, roles, settings) is replicated across all members using **Conflict-free Replicated Data Types (CRDTs)**.

### 10.1 Hybrid Logical Clock (HLC)

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

### 10.2 Operation Format

```
CrdtOp {
    server_id: String,
    hlc: HlcTimestamp,
    author: String,         // peer ID of originator
    payload: CrdtPayload,  // the actual mutation
}
```

### 10.3 Payload Types

| Category | Operations |
|----------|-----------|
| Server | ServerCreated, ServerRenamed, ServerSettingChanged (includes retention settings), ServerDeleted |
| Channels | ChannelAdded, ChannelRemoved, ChannelRenamed, ChannelVisibilityChanged, ChannelPostingChanged, ChannelVisibilityLabelsChanged, ChannelPostingLabelsChanged, ChannelGrantSet, ChannelGrantRevoked, ChannelLayoutUpdated |
| Members | MemberAdded, MemberRemoved, MemberBanned, MemberUnbanned, NicknameChanged, TwitchUsernameChanged |
| Roles | RoleChanged (owner/admin/moderator/member), RolePermissionsChanged |
| Labels | LabelCreated, LabelDeleted, LabelUpdated, LabelAssigned, LabelUnassigned (cosmetic vs access labels, §11.1) |
| Emotes and stickers | EmojiAdded, EmojiRemoved, StickerAdded, StickerRemoved (metadata only; see Custom Emotes below) |
| Messages | MessagePinned, MessageUnpinned |
| Storage | StoragePledgeChanged |

### 10.4 Conflict Resolution

**Last-Write-Wins (LWW)** per key, ordered by HLC timestamp. The HLC ordering (physical time, logical counter, author id) is total, so any two distinct writes have a deterministic winner and every replica converges regardless of apply order.

Authorization and conflict resolution are deliberately separated: **whether** a write is accepted is decided by the permission gates that validate the operation's *author* at every ingesting node (Section 11); **which** accepted write survives a conflict is decided purely by the HLC. Author role does not influence the merge; the latest authorized write wins. (Earlier versions resolved register conflicts by author-role priority, which made any value written by a higher role permanently immutable to lower (but still authorized) roles, and made convergence depend on each replica's possibly-stale view of the role map. Role rank is still carried on the wire for compatibility, but is not a merge input.)

### 10.5 Synchronization Protocol

When two peers connect:
1. Each sends a **state vector**: a compact summary of the latest HLC timestamp seen from each author.
2. Each computes the delta: operations it has that the other lacks.
3. Deltas are transmitted as batches of `CrdtOp` values.
4. Both peers converge to the same state.

This is idempotent: applying the same operation twice has no effect. Peers can sync with any other online member; there is no single source of truth.

**Forward compatibility.** Synchronization batches are parsed tolerantly: each operation in a batch deserializes independently, and an operation whose payload type is unknown to the receiving client (introduced by a newer client version) is skipped rather than failing the batch. Without this, a single unrecognized operation would prevent an older client from ever converging with a server whose members use newer features.

**Operation-log persistence.** Every merged operation is persisted to the local encrypted database, not held only in memory. A member that joined purely by synchronizing must be able to serve the full operation history to future joiners after a restart.

**State snapshot on join.** Because operation logs are compacted past a threshold and cannot be trusted as a complete reconstruction source, a join is preceded by a signed **server-state snapshot** sent ahead of the operation-log delta (the WebSocket transport is FIFO). A joiner adopts the snapshot only while its own join is still pending; an established member never lets a peer overwrite its state. Operation deltas are then merged on top.

**Replicable deletion.** Server deletion is a replicable `ServerDeleted` tombstone operation rather than a one-shot command. The deleting node retains the server shell and operation log so it can serve the tombstone to members who were offline at deletion time; those members reconcile on reconnect through the same grow-only synchronization path. The tombstone is honored only if authored by the server owner, checked against the receiver's own role map.

### 10.6 Security

CRDT operations are validated on receipt:
- The `author` field is verified against the actual sender's peer ID (prevents forged authorship). Authorization is always checked against the operation's **author**, never the transport sender that relayed it.
- Permission checks ensure the author has the required role for the operation type (e.g., only admins+ can change roles).
- A member's *own* voluntary departure (`MemberRemoved` where the removed peer equals the author) is always allowed, bypassing the kick-permission check.
- Unauthorized operations are rejected and logged.

**Multi-device note.** Membership entries are keyed by **master** identity (§3), while MLS leaves and transport peer IDs are device-keyed. All role and membership checks resolve a device ID to its master before comparing, so one person is one member regardless of device count, and an authorization check against a device ID never silently fails to match.

### 10.7 Custom Emotes and the Asset Rail (Content-Addressed Asset Replication)

Custom emotes are small images usable inline in messages and as reactions. Their design extends the CRDT model with a content-addressed asset layer, the *asset rail*, that also carries the other media kinds built on it (server banners, animated server icons, stickers, GIFs, avatar frames, and animated profile media), which differ only in their size bounds:

- **Metadata and bytes are separated.** The replicated CRDT entry (`EmojiAdded`) carries only a name and the SHA-256 hash of the processed image. The image bytes never ride CRDT operations, message envelopes, or relay buffers.
- **Bytes replicate on demand, peer-to-peer.** A client that must render an unknown hash requests it from a single source: the message sender's devices (direct messages) or one online server member (channels). Any member holding the bytes can serve them: content addressing makes every copy equally trustworthy, because the receiver recomputes the hash (and enforces format and size bounds) before caching. A tampered or substituted image simply fails verification and is discarded.
- **Only requested bytes are accepted, at the requester's own bounds.** A receiver records, at request time, which hashes it asked for and what kind of asset each was requested *as*; an arriving bundle is accepted only for those hashes, with the size ceiling taken from the locally recorded kind. A peer can neither push unsolicited blobs into another client's store nor smuggle a large blob past a small kind's bound; the sender has no say in which limit applies. Reply bundles are additionally bounded in total size on the serving side.
- **Wire form degrades gracefully.** An emote appears in message text as a compact token containing its name and hash; a client that predates the feature renders the token as text, and reaction strings accept either a short Unicode emoji or a well-formed token, and nothing else.
- **Third-party catalogs are authoring-time only.** Assets may be imported from an external catalog (FrankerFaceZ for emotes, KLIPY for GIFs and stickers), but each catalog is browsed exclusively through a Hollow-operated caching proxy, and only by the person actively choosing an asset. Search text travels in the request body (never a URL, so it cannot appear in standard access logs), carries no Hollow identity, and is cached anonymously server-side; the proxy's requests to the catalog provider carry a random single-use identifier, so the provider observes an unlinkable query stream originating from the proxy, never a user's network address or search history. The proxy source is published in the public repository, making these properties auditable. At import the image is re-encoded and content-addressed; from then on it replicates purely peer-to-peer. **A message recipient never makes an HTTP request to render an emote or GIF.** The external service learns nothing about who views which assets, or that a conversation exists at all, and cannot alter an asset after import (the hash pins the bytes). The residual exposure sits at the proxy's own hosting layer rather than at the catalog provider: cached media is addressed by asset identifier in the request path, so a server-level access log can associate a network address with which assets it previewed or imported. Search text is not exposed this way, being carried in the request body. A user who considers that residue unacceptable can point the client at a proxy of their own: the endpoint is a single configurable base URL, and the proxy source is published. A second, distinct opt-in exists for GIF search: a user may supply their own catalog credential, after which the client queries the provider directly and the proxy is bypassed entirely. This is an exchange rather than an improvement, and the interface says so plainly: the provider then observes that user's own network address and every query they make under one durable credential, which is precisely the correlation the shared proxy prevents. It is off by default, and the invariant above is unaffected in either configuration: the catalog is still reached only at authoring time, by the person choosing the asset, and a message recipient still makes no HTTP request to render one. Media the client will fetch in this mode is constrained to an explicit, user-visible list of permitted hosts, so a compromised or altered catalog response cannot redirect the client to an arbitrary origin.

Server emote sets are capped and gated by a dedicated permission bit (§11.2); names and hashes are grammar-validated at every ingest path so the emote registry cannot be used to smuggle markup or oversized data into clients. Server sticker sets ride the same permission bit, the same caps-at-both-ends rule, and the same validation, including their pixel dimensions, since a sticker whose dimensions fall outside the token grammar could not be rendered by any client and therefore has no reason to replicate. A sticker's registry key is its content hash rather than a name: unlike an emote, which is typed as `:name:` and so requires a unique name, a sticker is only ever chosen visually, so its name is a non-unique label and its identity is its bytes.

**Server banners** follow the same separation: the replicated server state carries only the banner's hash (a `MANAGE_SERVER`-gated setting), and members pull the bytes over the rail like any other asset. The one place a banner is shown to non-members, the pre-join public-server browse, receives a small, still, size-bounded thumbnail generated from the banner, never the full asset, and the receiving client independently enforces that bound before display.

**Animated server icons** apply the split retroactively to a field that predates the rail: the small still icon remains inline in replicated server state (older clients and pre-join surfaces keep working unchanged), while an animated upload additionally publishes only the hash of a size-bounded animated variant, whose bytes ride the rail under the same requested-only, receiver-verified rules. Animation never rides state snapshots, sync frames, or pre-join wire paths.

**Avatar frames** extend the same separation to a *personal* profile, where the pressure runs the other way. A profile update is pushed to everyone who synchronises with its owner, so any decoration carried inline is paid for by every recipient whether or not they ever look at it. The profile therefore carries only a short identifier: either a procedurally drawn built-in, which costs nothing on the wire, or the hash of an uploaded image whose bytes travel the rail on demand and are the first thing evicted under a client's own cache bound. The identifier is validated on ingest against exactly three permitted shapes, and an unrecognised value is treated as absent rather than as a clear, so a malformed field from a future client cannot erase what a recipient already holds. That validation is not cosmetic: the field arrives in plaintext on the unencrypted profile path and is used to key a network request, so an unconstrained string would let a sender direct a recipient's fetches.

**Animated avatars and banners follow the frame's reasoning to its conclusion.** They were the
last profile media whose bytes travelled inline, and they are the costliest case of the pressure
described above: an animation is an order of magnitude larger than the still it replaces, and it
was pushed in full to every peer on every reconnection, whether or not that peer ever rendered
it. The profile now carries a *still* image and, separately, the hash of an animated variant. The
still is what a recipient sees by default and what a client predating the split still receives, so
nothing degrades to a blank; the animation travels the rail on demand and is evictable like any
other asset, so a recipient who never opens a profile card never pays for its animation, and one
who evicts it loses motion rather than a face. The hash is validated on ingest exactly as the
frame identifier is, for the same reason: it arrives in plaintext on the unencrypted profile path
and keys a network request. It is deliberately outside the profile signature, on the same
reasoning that excludes the frame: substituting one decoration hash for another swaps art the
substituter already possesses, while the still image that the signature does cover continues to
render beneath it.

A consequence worth stating plainly: because the still and the animation are separate objects
with separate lifetimes, a recipient's view of someone's avatar can be *behind* in motion while
being current in identity. That is the intended trade. Identity is what the signature covers and
what arrives with the push; motion is decoration, and decoration is what a bandwidth or storage
bound should be allowed to shed first.

**Sticker packs are distributed as files, and there is no directory.** A personal collection of stickers can be exported as a single signed archive and shared the way any other file is shared: sent into a conversation over the ordinary encrypted transfer path. There is deliberately no pack link, no catalog, and no discovery surface, and the reason is structural rather than stylistic: the network has nowhere to host bytes. A server invitation works because the link carries only an identifier and the join happens over the relay into a room the inviter already occupies; a pack has no such room behind it, so any URL form would require either serving arbitrary strangers from the author's own node (a discovery and reachability surface the design refuses) or a central content host, which the architecture does not have. Distributing a file is also the more private primitive of the two: a live subscription to someone's collection would tell its author who had adopted it and let them push new bytes to those people later, whereas a file is a one-time copy that establishes no ongoing relationship in either direction.

The archive is treated as wholly untrusted on import. Each image is keyed by the hash the importer computes rather than the one the manifest claims, and an entry whose bytes disagree is rejected; the displayed dimensions are re-derived from the decoded image rather than read from the manifest, since those values feed the message token that later lays the image out; and format, pixel and byte bounds are re-checked before any decode. Nothing is re-encoded: a sticker's identity is the hash of its bytes, so a transcode would mint a different identity and orphan every message already sent against the original. The author's signature covers the collection's name and every entry's hash and dimensions in order, but it is **attribution only**: it never gates the import, and its absence or failure withholds the byline rather than rejecting the pack. There is no authority that could say who may author a collection, and the format does not pretend otherwise.

---

## 11. Authorization and Permission Model

### 11.1 Role Hierarchy

Hollow implements a **two-layer role system**:

**Power roles** (4 functional tiers with immutable hierarchy):

| Role | Priority | Default Permissions |
|------|----------|-------------------|
| Owner | 3 | All permissions |
| Admin | 2 | Manage channels, manage roles, kick members, send messages, read messages |
| Moderator | 1 | Kick members, send messages, read messages |
| Member | 0 | Send messages, read messages |

**Labels** (unlimited) come in two kinds, distinguished by a per-label `access` flag:

- **Cosmetic labels**: decorative tags with a name and color, assigned to members for display. They never affect permissions, and any member may add or remove them on themselves.
- **Access labels**: labels that may be referenced by a channel's access gate (§11.4). Because holding one confers channel access, access labels are never self-assignable: assignment requires the `MANAGE_ROLES` permission, and this is enforced identically at the authoring node and at every ingesting node through one shared predicate, so the two gates cannot diverge. A label-update operation carries its access flag as an optional field where *absent means preserve*: a client predating the flag can recolor or rename a label but can never silently demote an access label back to self-service.

### 11.2 Permission Bits

Seven permission bits control access:

| Bit | Permission | Effect |
|-----|-----------|--------|
| 0 | `MANAGE_SERVER` | Server-level administration |
| 1 | `MANAGE_CHANNELS` | Create, rename, delete channels |
| 2 | `MANAGE_ROLES` | Edit role permissions, assign roles |
| 3 | (unused) | Reserved (formerly `MANAGE_INVITES`, removed) |
| 4 | `KICK_MEMBERS` | Kick and ban members |
| 5 | `SEND_MESSAGES` | Post messages in channels |
| 6 | `READ_MESSAGES` | View channel content |
| 7 | `MANAGE_EMOTES` | Add and remove custom server emotes |

Default permissions per role can be overridden via `RolePermissionsChanged` CRDT operations. Custom permission sets are stored as LWW registers; authorship of the override is validated by the permission gates at every ingesting node (`MANAGE_ROLES`), and conflicting overrides resolve by HLC timestamp (Section 10.4).

### 11.3 Tier-Gated Permission Editing

Permission editing follows strict hierarchy enforcement:

- A member can only modify permissions for roles **below** their own rank.
- A member cannot assign a role **equal to or above** their own rank.
- The Owner role's permissions are immutable.
- Kick/ban operations follow the same hierarchy: a member can only kick/ban members of lower rank.

### 11.4 Channel Access Control

Each channel has two independent access control settings, stored as CRDT values:

**Visibility** (who can see the channel):
- `Everyone`: all server members
- `ModeratorPlus`: Moderator rank and above
- `AdminPlus`: Admin rank and above
- **Label gate**: a set of access-label identifiers; when non-empty it replaces the tier ladder: the channel is visible to holders of *any* listed label, plus Admins and the Owner implicitly

**Posting** (who can post in the channel):
- `Everyone`: anyone with `SEND_MESSAGES` permission
- `ModeratorPlus`: Moderator rank and above
- `AdminPlus`: Admin rank and above
- **Label gate**: same semantics as the visibility label gate

For interoperability with clients that predate label gates, turning a gate on also stamps the corresponding legacy tier to `AdminPlus` in the same authoring sequence (the two operations share one node's hybrid logical clock, so every replica converges on the same combined state regardless of arrival order). An older client drops the unknown gate operation but honors the stamp, so a gated channel *fails closed* (hidden from non-admins) rather than open.

**Temporary access grants.** A holder of `MANAGE_CHANNELS` may grant an individual member time-boxed access to one channel (visibility and posting; server-wide mutes still apply). Each grant is a last-writer-wins register keyed by (channel, member) carrying an expiry timestamp, with a sentinel value meaning *until revoked*, the same replication shape as timed mutes. Expiry is evaluated lazily by the access predicate, so access ends the moment the deadline passes with no revocation message required; a periodic sweep then performs the cryptographic consequence, removing the member's leaf from the channel's MLS subgroup and re-keying the remaining members. Grants were chosen to be time-based rather than presence-based deliberately: in a distributed system presence is per-relay and transient, and keying access to it would churn group membership on every reconnect.

The full visibility predicate is therefore evaluated in order: Owner always; an unexpired grant; the label gate (Admin-and-above implicit, or any listed label held); otherwise the tier ladder. All evaluation collapses a device identifier to its master identity first.

### 11.5 Enforcement Model

**Cryptographically enforced** (Rust backend):
- Channel visibility (restricted text channels): a text channel with a restricted tier *or* a label gate is encrypted under its own MLS subgroup (see §5.2). Only members passing the full visibility predicate (tier, label gate, or unexpired grant) are subgroup members and hold the key; everyone else never receives a decryptable copy. This is a confidentiality boundary, not a UI filter. Subgroup membership is re-reconciled on every event that changes who qualifies, including label assignment/removal/deletion, grant issuance/revocation, and grant expiry.
- Message sending: `can_post_in_channel()` checked before broadcast. Unauthorized messages are rejected with an error.
- Role changes: hierarchy validation prevents privilege escalation.
- Kick/ban: rank check prevents members from kicking peers of equal or higher rank.
- CRDT author verification: the `author` field is verified against the actual sender's peer ID.

**UI-filtered / authorization-only** (not a confidentiality boundary):
- Channel posting restrictions: enforced server-side (`can_post_in_channel`) as an authorization gate and reflected by disabling the input bar, but posting is not a confidentiality property: a posting-locked member can still read a channel it can see.
- Sidebar filtering of `Everyone` channels: cosmetic ordering/grouping only; those channels carry no confidentiality restriction.

**Scope:** restricted *voice* channels derive their SFrame media key from the channel subgroup's `export_secret`, so non-qualifying members cannot decrypt restricted-channel media; joining a restricted voice channel is additionally rejected when the member's role fails `can_see_channel`.

### 11.6 Public Channels

Individual channels can be marked as **public** via a per-channel `is_public` boolean flag in the ChannelInfo CRDT (toggled by members with `MANAGE_CHANNELS` permission).

**Encryption model:** Public channels bypass MLS entirely. Messages are sent as plaintext `HavenMessage::PublicChannelMessage` variants (including Edit, Delete, AddReaction, RemoveReaction) broadcast via `SendToRoom`. All public channel messages are still **Ed25519-signed** by the sender, so authenticity is verifiable, but content is readable by anyone in the WebSocket room.

**Guest access protocol:** Non-members can browse public channels read-only via the **Public Channel Browser**:
- Guests connect to the server's WebSocket room with `"guest": true` authentication (invisible to members, rate-limited).
- `PublicChannelListRequest`/`PublicChannelListResponse` HavenMessage variants serve channel metadata, including the server avatar as base64.
- `PublicChannelSyncRequest`/`PublicChannelSyncResponse` serve paginated message history (50 messages per batch, latest first).
- `PublicChannelSyncResponse` includes `sender_profiles: HashMap<String, SyncSenderProfile>`: display name + 64×64 WebP avatar thumbnail per unique sender, resolved from the responding peer's local profile database.
- Real-time updates: `PublicChannelConfigChanged` HavenMessage broadcast via `SendToRoom` when a channel's public flag changes. Guests receive new messages in real time because `SendToRoom` delivers to all peers in the room, including guests.

**Scope:** Only text channels may be public. A voice channel's public flag is refused at authoring and at ingest, and ignored at every read; publishing one would expose its text sidebar to history sync and silently move the channel out of its per-channel media-encryption key domain.

**File attachments:** Public message history and live public messages carry attachment *metadata* only (name, size, type, dimensions), never bytes. Bytes are fetched on demand from a peer in the room, and the serving peer enforces an access predicate before reading anything from disk: direct-message files are served only to the two conversation parties (and the holder's own linked devices); channel files only to server members, or to anyone while the file's channel is public. Because the sender's identity on the transport never proves entitlement to a file identifier, this predicate is evaluated against the serving peer's own record of where the file belongs. For public-channel files the response's per-request transfer key travels in plaintext, consistent with the content itself being relay-readable; a receiver accepts such a response only for a file it explicitly requested from that server, so a third party cannot push unsolicited content onto a client's disk.

**Broadcast channels:** A public channel with posting set to `AdminPlus` functions as a broadcast/announcement channel: publicly readable, admin-only posting.

### 11.7 Moderation Primitives

Hollow provides three moderation controls, all carried as signed CRDT operations subject to the same author verification and rank checks as role changes (§11.3):

- **Member mute (timed or permanent):** a server-wide read-only state, keyed by the target's master identity so it covers all of their linked devices. The mute record stores an absolute expiry timestamp (a sentinel value denotes permanent); expiry is evaluated lazily at enforcement time, requiring no timers or follow-up operations. Issuing a mute requires kick permission and strictly higher rank than the target. A mute suppresses every content-authoring action: new messages, file posts, message edits, and reaction additions. Removing one's own content (deleting a message, retracting a reaction) is never blocked, so a mute cannot trap a member's content in place.
- **Per-channel slow mode:** a minimum interval between messages per member, evaluated against the sender's own signed message timestamps. Moderator-rank and above are exempt. Message edits are not rate-limited.
- **Media-only channels:** a per-channel flag restricting posts to image, GIF, and video attachments (optionally captioned); standalone text and other file types are rejected.

**Enforcement model:** because no server mediates message flow, these are authorization gates enforced twice: at the sender (cooperative clients fail fast with a local error) and independently by **every receiver**, which refuses to store live messages, edits, reactions, or file announcements that violate the rules in force per its replicated server state. A modified client can transmit, but compliant peers discard the traffic, which is the strongest guarantee available in a serverless topology (and equivalent in effect to a central server dropping it). Receive-side enforcement deliberately applies only to live traffic, not to historical sync: history may legitimately predate a rule change, and dropping it during backfill would permanently diverge replicas. These are authorization properties, not confidentiality boundaries.

---

## 12. Relay Architecture

### 12.1 Design Principle

The relay is a **zero-knowledge message router**. It routes encrypted blobs between peers based on room membership. It has no knowledge of message semantics, encryption keys, or application state. The relay source code is open-source.

**Implementation:** uWebSockets C++ with native OpenSSL TLS termination (no reverse proxy). Memory footprint: ~13.4 KB per connection (~572k connections on 8 GB VPS, verified with 44.6k simultaneous connections). TLS session resumption is enabled for fast reconnects.

**Privacy hardening (defense in depth):** The relay emits no metadata logging *in the source itself*: no log statement prints a peer ID, room code, push target or sender, channel, server, or push token. The only diagnostic output is aggregate counts (e.g. number of license keys loaded), configuration-file paths in parse errors, and the startup/shutdown banner, none of which can identify who is communicating with whom. This is enforced at the code level, not merely by deployment configuration, so that even a misconfigured or differently-deployed relay cannot record the social graph. On top of that, the deployment disables persistent logging entirely: the system journal uses volatile (RAM-only) storage with 1-hour maximum retention, the TURN server (coturn) is configured with `log-file=/dev/null` and `no-stdout-log`, and rsyslog filters discard any relay or TURN messages from on-disk log files. The result: the relay does not write connection events, peer IDs, IP addresses, or timestamps to disk, and the routing metadata it necessarily holds in memory (room membership) is never recorded.

### 12.2 Authentication

Peers authenticate to the relay via Ed25519 signature:

```
Signed payload: "hollow-ws-auth:{peer_id}:{unix_timestamp}"
```

The relay verifies the signature against the provided public key and checks that the timestamp is within ±60 seconds of server time (replay protection).

### 12.3 Room Model

- Peers join named rooms (alphanumeric + `:-_.`, max 128 characters).
- Each server has a room (room ID = server ID).
- Each DM pair has a room (room ID = deterministic hash of both peer IDs).
- Messages can be broadcast to all room members or sent directly to a specific peer.
- Max 10,000 rooms per peer.
- Max 64 MB per WebSocket binary message; 1 MB per text message (silently dropped if exceeded).

**Connection supersession.** When a client reconnects (a mobile resume, a network change, or a TLS re-handshake) it opens a new socket while the old half-open socket may not yet have closed. The relay supersedes: a newer authenticated socket for an existing peer ID evicts and closes the older one, and room teardown is socket-aware: a stale duplicate's delayed close can only tear down state that still points at *that* socket, never the live successor's. Messages directed at a peer that is connected but has not yet rejoined its target room are briefly buffered, so a fresh device's first handshake message is not lost in the gap between authentication and room join.

### 12.4 Binary Protocol

Binary frame types for efficient transport. Input types (client → relay) are transformed into output types (relay → client):

**Input frames (client sends):**
- **0x01 (Broadcast):** `[0x01][room_hash: 32 bytes][payload]`, forwarded to all room members as-is. Used for WebRTC signaling.
- **0x02 (Direct):** `[0x02][room\0][target_peer\0][payload]`, forwarded to a specific peer. Used for file streaming, shard transfers.
- **0x03 (Msg Broadcast):** `[0x03][room\0][payload]`, universal broadcast for non-channel messages (CRDT sync, key exchange, coordination). Forwarded as **0x05**.
- **0x04 (Direct Msg):** `[0x04][room\0][target\0][payload]`, direct message to a specific peer. Forwarded as **0x06**.
- **0x07 (Topic Broadcast):** `[0x07][room\0][topic\0][payload]`, topic-aware broadcast for channel messages. Only forwarded to peers subscribed to the topic (or wildcard subscribers). Forwarded as **0x08**.
- **0x09 (Channel Direct):** `[0x09][room\0][target\0][channel\0][flags:1][payload]`, a channel message addressed to a single *offline* member for push delivery (§13.3). The payload is the same group ciphertext the room broadcast carried; the sender (never the relay) selects offline targets from its own membership state.

**Output frames (relay sends):**
- **0x05 (Msg Broadcast, forwarded):** `[0x05][room\0][sender\0][payload]`. The relay prepends the sender's peer ID.
- **0x06 (Direct Msg, forwarded):** `[0x06][room\0][sender\0][payload]`. The relay replaces target with sender.
- **0x08 (Topic Broadcast, forwarded):** `[0x08][room\0][topic\0][sender\0][payload]`. The relay prepends sender, preserves topic.

A further direct frame type carries an Olm-encrypted file header with inlined, encrypted image bytes to a specific peer; it is used to deliver an image DM to an offline recipient who is in no room (§13.2).

**Topic subscription:** Clients send a `subscribe` JSON command to set per-room topic filters. Peers with no subscription entry for a room receive all messages (wildcard, backwards compatible). Peers with a subscription set receive only messages matching a subscribed topic. Channel messages use 0x07 with `channel_id` as the topic; non-channel messages (CRDT, sync, keys) use 0x03 universal broadcast.

### 12.5 Resource Protection

- **No application-level rate limiting:** soft backpressure and per-peer rate limits were removed because they silently dropped CRDT sync payloads and broke reconnection flows.
- **Daily byte budget (anti-drain backstop):** each IP address (IPv6 aggregated by /64 prefix, since a single host controls an entire /64) may relay a generous fixed volume of binary traffic per UTC day, counted in both directions. The ceiling sits orders of magnitude above organic use (text chat, signaling, and CRDT sync never approach it) and exists solely to bound a modified client streaming bulk data through the relay continuously. On exhaustion the relay **closes the connection with an explicit reason** (`bandwidth_limit`) that the client surfaces to the user; frames are never silently dropped. Counters live only in relay RAM (never logged or persisted, the same privacy model as the connection caps, §12.7) and vanish on relay restart. Clients can query their own counter over the authenticated WebSocket (`get_bandwidth`); the reply travels on the exact connection being counted, so attribution is correct even for dual-stack hosts.
- **Fair-share offline-buffer eviction:** the store-and-forward buffer (§13) is capped per recipient, which bounds memory but not *who* consumes it: absent further structure, one peer could fill a stranger's buffer with junk until every genuine message waiting there had been evicted. When a cap is reached the relay therefore discards the oldest frame belonging to whichever sender currently occupies the most slots, rather than the globally oldest, so a flooder can only ever displace its own frames. This is deliberately a *reprioritisation* rather than a limit: a per-sender quota or a per-minute cap would silently discard legitimate traffic (a reconnection burst addresses every offline contact at once, and one channel post legitimately emits one frame per offline member), which is the same failure mode that caused application-level rate limiting to be removed.
- **Hard backpressure:** 64 MB per connection (uWebSockets built-in). Catches dead connections without interfering with legitimate traffic.
- **Text frame cap:** 1 MB. Oversized text frames are silently dropped.
- **Binary frame cap:** 64 MB (uWebSockets `maxPayloadLength`). Connections exceeding this are closed.
- **DoS protection:** Ed25519 authentication + license key revocation. Only authenticated peers can send messages. Per-IP connection caps (simultaneous + new-per-minute) use the same /64-aggregated IPv6 keying.
- **Room membership enforcement:** every routing handler verifies that the *sender* belongs to the room it addresses before forwarding, and rewrites the routing header to carry the authenticated peer ID, so a room code cannot be used as a capability to inject into or read from a room one has not joined. Non-members' frames are silently dropped. Peer discovery is likewise restricted to rooms the requester is in; otherwise a room code alone would yield a membership roster, which matters because DM room codes are a deterministic function of the two participants' identities.

### 12.6 TURN Credential Management

For peers behind symmetric NATs, the relay provides time-limited TURN credentials:

- HMAC-SHA1 credentials with 1-hour TTL.
- Delivered **only** over the client's authenticated relay WebSocket (a `get_turn_credentials` request on the live connection). Unauthenticated and guest connections are refused, so relay bandwidth cannot be farmed anonymously. The former unauthenticated HTTP endpoint has been removed outright rather than deprecated: an HTTP request carries no caller identity to bind a credential to, so any such endpoint is farmable by construction.
- The TURN server (coturn) validates credentials against the same shared secret.
- Clients request fresh credentials on every relay (re)connection and refresh every 50 minutes, so retries inherit the connection's own reconnect machinery.

### 12.7 What the Relay Sees

| Data | Visible to Relay |
|------|-----------------|
| Peer IDs (in memory) | Yes (not logged to disk) |
| Room membership (in memory) | Yes (not logged to disk) |
| Topic subscriptions (in memory) | Yes: the relay knows which channel topics each peer subscribes to within a room (not logged to disk) |
| Connection timestamps | **No** (relay logging is disabled; volatile journal with 1h retention) |
| Message contents | **No** (encrypted) |
| Encryption keys | **No** |
| File contents | **No** (encrypted) |
| Message signatures | **No** (inside encrypted envelope) |
| User profiles | **No** (encrypted) |
| Voice/video media | **No** (P2P, not relayed) |
| File transfer bytes | **No** (P2P, not relayed) |
| IP addresses | **No** (relay does not log IPs; TURN logging disabled) |
| User reports | Partially: per-target abuse-category **counts** are persisted (§12.14); the reporter's identity is never written to disk |

### 12.8 License Key System

The relay supports an optional license key system for controlling access during alpha/beta phases:

- Keys are stored in a `keys.json` file loaded at startup. The system can be enabled or disabled via a toggle.
- Keys are validated during WebSocket authentication. Invalid or already-in-use keys are rejected.
- The key file is hot-reloaded every 30 seconds, allowing key revocation without relay restart.
- Active connections using a revoked key are terminated on the next reload cycle.
- License keys are cached client-side in the encrypted SQLCipher database.

### 12.9 Server Statistics Endpoint

The relay exposes a `/server-stats` endpoint returning real-time operational metrics:

- Memory usage (total/used from `/proc/meminfo`)
- Network throughput (Mbps, computed from `/proc/net/dev` deltas)
- Online user count (connected authenticated peers)
- Bandwidth cap

Statistics are cached for 5 seconds to avoid excessive filesystem reads. This endpoint is used by the client's home dashboard to display relay health.

### 12.10 Additional HTTP Endpoints

- **`/relay-status`**: returns `{"license_required": bool, "version": "..."}`. Clients query this on startup to determine whether a license key is required before attempting WebSocket authentication.
- **`/health`**: returns `{"status": "ok", "service": "hollow-signaling"}`. Used for uptime monitoring.
- **`/register`**, **`/unregister`**, **`/bootstrap/{room_code}`**: HTTP-based peer discovery for signaling. Stale entries are cleaned up every 180 seconds. Max 50 peers per signaling room, max 5 addresses per peer.

### 12.11 Self-Hosted Relay Configuration

The relay domain is fully configurable, enabling self-hosted, relay-independent operation:

- **Default relay:** `relay.anonlisten.com` (operated by AnonListen).
- **Custom relay:** Clients can select an alternative relay domain at first launch or in settings. All WebSocket, STUN, TURN, and signaling URLs are derived from the configured relay domain.
- **Persistence:** The selected relay domain is stored in the local encrypted database. A saved relay list allows switching between known relays.
- **Docker deployment:** The relay can be self-hosted via Docker with automated TLS (certbot) and an integrated coturn TURN server.

Since the relay is a zero-knowledge pipe, switching relays is transparent to the protocol: the same identity, encryption, and CRDT synchronization work identically regardless of which relay is used. A censorious or unavailable relay can be replaced without any protocol changes.

### 12.12 Temporary Nicknames

To allow users to send friend requests without sharing a 64-character peer ID, the relay supports **ephemeral, relay-scoped nicknames**:

- A nickname (lowercase `a-z`, `0-9`, `_`; 3–20 characters) is claimed via a relay text command and held in a RAM-only `nickname → peer_id` map. The claim also carries the claimer's self-reported **master identity** (multi-device identities authenticate to the relay as a per-device id, but friend requests must target the master's inbox), stored in the same RAM registry and handed back verbatim on resolve. The relay never verifies or routes on this value, and the resolver on the requesting client never trusts it as an identity mapping; it is used solely as the friend-request destination, with the same trust as a manually typed peer ID.
- Nicknames are **never persisted** and are released on disconnect. There is no durable mapping between a handle and an identity on the relay.
- A friend request resolves a nickname to a peer ID (and master, when present) in one step, then proceeds via the normal friend-request flow.

Because the mapping lives only in relay memory for the duration of a connection, the relay holds no long-term directory of human-readable handles. The underlying identity remains the Ed25519 peer ID; the nickname is a transient convenience layer.

### 12.13 Message-Availability Cache (Offline Delivery)

A fully peer-served history model has a structural gap: if Alice sends a message and disconnects before Bob comes online, no online party holds the message, and Bob waits until Alice (or another member) returns. To close this gap the relay may **retain, for a bounded time, the same end-to-end-encrypted frames it already routes**, and replay them to a returning recipient.

The design invariant is **availability, not authority**. The relay buffers only ciphertext bytes it would have forwarded anyway; the recipient verifies every Ed25519 signature, deduplicates by message ID, and merges through the same CRDT/sync logic as peer-served data. The relay therefore cannot forge (signatures), cannot read (Olm/MLS encryption), and cannot become a source of truth. If it withholds or loses data, peer-to-peer synchronization remains the correctness floor. All buffers are RAM-only by design: a relay restart or power-off leaves no recoverable artifact, and nothing about the cache is logged.

Two tiers exist:

- **Direct messages:** a per-device queue (enabled by default; the recipient controls an on/off toggle and a retention window of 1–7 days, registered per connection). Buffered entries are text and file *metadata* only, never file bytes, plus a small bounded set of inlined image previews. Delivered entries are deleted on replay.
- **Server channels:** one ciphertext ring per channel (bounded per-channel message and byte caps), populated from the channel's topic-routed frames and replayed on request to any member of the room. Deletion is by retention expiry, never by delivery, because "all members received it" is unknowable to a relay that refuses to learn server membership. Enabled per server via a CRDT-replicated setting (default on; the server owner can disable it).

A global byte budget bounds total buffer memory with oldest-first eviction. Because MLS enforces forward secrecy, replayed channel ciphertext is decryptable only within a bounded window: Hollow configures its MLS groups with an enlarged out-of-order tolerance and a small number of retained past-epoch secrets, deliberately trading a bounded amount of forward secrecy for offline deliverability. Frames outside that window are recovered through ordinary peer synchronization instead.

### 12.14 User Blocking and Reporting

Abuse handling follows Hollow's self-protection model: users defend themselves locally, and the network learns as little as possible in the process.

**Blocking is a purely local, receiver-side decision.** A block is keyed on the offender's *master* identity (so switching devices does not evade it) and enforced at message ingest, before anything is stored, displayed, or notified: friend requests, direct messages (live, sync backfill, and offline-cache replay), file transfers, call invitations, and data-channel offers from a blocked identity are dropped. The blocked party receives no signal that they are blocked, and no other party, including the relay, learns that a block exists. Server channel messages from a blocked member remain in the local store but are hidden from display, so unblocking restores history losslessly.

**Reporting is the single deliberate exception to the relay's persist-nothing rule.** A client may file a report against a peer under a fixed category set (spam, harassment, illegal content, impersonation) over its authenticated relay connection. The relay persists exactly two things: per-target **counts** per category, and a SHA-256 hash of (reporter, target, category) used solely to enforce one report per reporter per target per category. The reporter's identity never appears on disk or in logs, no message content is attached (the relay could not read it anyway), and the resulting file supports exactly one operator action: identifying identities with abnormal report volumes for possible relay-access restriction. Reports carry no in-protocol authority: they cannot delete content, remove members, or affect any server's CRDT state.

---

## 13. Push Notifications (Mobile)

Mobile operating systems terminate background processes, so a Hollow client cannot hold a persistent WebSocket while the app is closed. Firebase Cloud Messaging (Android) and the Apple Push Notification service (iOS) are the only OS-sanctioned way to wake a terminated app. Hollow must therefore route a wake signal through Google and Apple infrastructure, parties it does not trust. The entire push design exists to do this **without ever exposing message content to those parties.**

### 13.1 The Core Privacy Guarantee

**The push payload carries zero message content.** It is exactly `{type: "wake", sender: <peer_id>}` for a DM, or `{type: "channel_wake", sender, server, channel, mention}` for a channel message. Carrying ciphertext in the push, *even encrypted*, was deliberately rejected, because the push body's size, timing, and frequency would themselves leak metadata to Apple and Google.

Consequently:

- **What Apple/Google learn:** that *some* message arrived for a device token, plus an opaque sender peer ID (a `12D3KooW…` identifier, not a human name) and, for channels, opaque server/channel IDs and a single mention bit. They never see message text, message size, or who-is-who beyond opaque IDs. Push timing is coarsened by debouncing (§13.3).
- **How E2EE is preserved:** the message *content* travels exclusively over Hollow's own existing E2EE channels (Olm for DMs, MLS for channels) between the client and Hollow's own relay, and is decrypted **on-device**. Apple and Google are pure wake-up couriers, categorically outside the content path.

A small push-relay sidecar service holds the Firebase/APNs credentials and emits only the empty `{wake, sender}` payload; the relay itself never contacts Apple or Google with content.

### 13.2 Direct Message Push Flow

The relay is normally stateless. Push delivery requires one concession: when a DM's recipient is **offline**, the relay briefly buffers the **ciphertext** in RAM (a per-peer cap of 100 text messages and 1 image, 24-hour TTL, swept periodically) so the woken client can fetch the *triggering* message: the relay is a dumb pipe, and without buffering the message would already be gone by the time the client wakes seconds later. This buffer is latency glue, not durability; the distributed sync layer (§3.5, §10) owns durability. The buffered bytes are ciphertext only. The same mechanism, with larger user-controlled caps and retention, backs the message-availability cache (§12.13).

When the woken client later joins the DM room, the relay replays all buffered frames. The client runs a minimal **fetch node** that connects in a special fetch mode (excluded from member lists, emits no presence; *waking via push does not show the user as online*), pulls the replayed ciphertext, decrypts it with the existing Olm session, persists it, and posts a populated notification.

**Offline images.** An image DM is normally two messages plus a separate byte stream, and the byte stream is never sent to an offline peer. For offline delivery, the sender inlines the AES-encrypted image bytes into the (Olm-encrypted) file header and sends it as a dedicated direct-image frame to the DM room; the fetch node decrypts the bytes, writes the file, and inserts the message row. A caption is sent exactly once as a separate encrypted text frame, never via the normal send path (which would advance and persist the Olm ratchet for a message the offline peer never receives, creating a permanent decryption gap).

### 13.3 Channel Message Push Flow

The same privacy invariants extend to server channels. After the normal room broadcast, the **sender**, the only party holding the plaintext and the membership list, selects the offline members from its own CRDT state and sends each one a `0x09` channel-direct frame whose payload is **the same MLS (or public-channel) ciphertext the room broadcast carried**. The relay never learns server membership; it only buffers and forwards. The sender also computes a per-target mention bit (an `@everyone`, a name/nickname mention, or a reply to that member) so mentions can be prioritized.

The relay buffers offline channel messages under a separate per-peer cap and applies two filters before contacting the push sidecar:

- **Push preferences:** a RAM-only per-peer registry (server-level and per-channel mute levels), re-sent by the client on every reconnect, lets the relay suppress unwanted pushes. Filtering must happen relay-side because an iOS alert push cannot be suppressed after delivery. (This leaks a coarse "this peer wants pushes for this server" signal to Hollow's own relay, never to Apple/Google, in exchange for the suppression working at all.)
- **Anti-spam debounce:** non-mention pushes are debounced per server (and capped while continuously offline); mentions use a much shorter debounce; a small per-peer floor applies across all servers.

A channel wake causes the fetch node to join the **server** room and decrypt the buffered messages via the persisted MLS group state. If the device's MLS epoch is stale (it missed a commit while offline), decryption fails gracefully to a content-free banner, and the app self-heals via normal channel sync on next open.

### 13.4 Signature Integrity Through the Push Path

Push-fetched messages remain Ed25519-verifiable end to end. The message-row signature is persisted alongside the text it covers, so verification reconstructs the same canonical payload (§15). For offline images, the file header itself carries the signature and public key (for a captionless image it is the sole signature carrier, signed over the file sentinel). Authorization checks validate the cryptographic author, never the transport or fetch path, so a relay or fetch node cannot forge attribution.

### 13.5 iOS On-Device Decryption (Notification Service Extension)

iOS does not run the app's background handler when the app is force-killed: Apple will not relaunch a user-terminated app for a background push. The only iOS process that always runs for a `mutable-content` push is the **Notification Service Extension (NSE)**, a separate short-lived process. On iOS, therefore, *all* content resolution for a force-killed app happens in the NSE:

1. **Instant tier:** the NSE reads a shared App Group cache of sender names and avatars (written by the main app) to show the sender immediately.
2. **Fetch-and-decrypt tier:** if the live app is not already running (checked via a heartbeat file in the App Group), the NSE calls a dedicated Rust C-ABI entry point that runs the same fetch-node logic: connect to Hollow's relay in fetch mode, pull the buffered ciphertext, and decrypt it on-device with vodozemac (DMs) or OpenMLS (channels). The decrypted text is shown in the banner; **no plaintext or ciphertext ever passes through Apple.**

The NSE opens the same shared SQLCipher database as the app (§2.4), which is why that database uses rollback-journal mode on iOS. The NSE's measured memory footprint (~3 MB) sits comfortably within Apple's 24 MB extension limit even with the full networking and cryptography stack linked in. To keep the NSE outside the protocol's source of truth, its decryption is designed so that a buggy extension can at worst show a wrong or missing banner, never corrupt the canonical message ratchet.

The same logging discipline applied to the relay (§12) applies to the extension: its diagnostic log records only timings, memory footprint, and payload *lengths*; decrypted content is rendered into the notification banner and nowhere else. Client-side diagnostic logs across platforms follow the same rule for message bodies and secrets (device-link pairing codes are logged by length only).

### 13.6 Push Under Multi-Device

The push path is the most cross-cutting place where the device/master split (§3) surfaces, because every layer it touches is keyed differently: the relay's push token and offline buffer are keyed by the **device** peer ID a socket authenticated with, while a person's display identity, conversation key, and database rows are keyed by the **master**.

- **Waking the right device:** a push token is registered under the device that registered it, and the relay buffers a message under the **specific device** the sender addressed. So the sender's offline targeting must reach each *real* offline device, not only devices currently in a room. Targeting expands a recipient's master to its **known, real, offline devices** (those in the signed device list with which the sender holds a session), distinct from the live-presence fan-out used for online delivery; a never-contacted ghost ID (§3.4) is excluded so it can never trigger a phantom push. For channels, the same expansion turns each offline **master** member into its real devices before the per-target `0x09` frame is emitted.

- **The fetch node authenticates as its device.** A woken device runs the fetch node under **its own device key**, because the relay will replay a buffered frame only to a socket presenting the exact device ID the message was buffered under, and will only push to that device's registered token. The fetch node still derives the master-paired DM room and stores rows under the **master** (resolving its own device→master and the sender's device→master from the locally-persisted device links), so a message woken on one device lands in the single shared conversation rather than a per-device thread. The database passphrase remains master-derived; only the transport identity is the device key.

- **Per-person notification grouping:** a multi-device *sender* may send from any of its device IDs, so the receiving client collapses the push `sender` device→master before resolving the display name/avatar and choosing the notification's grouping key. One person yields one notification card regardless of which of their devices sent.

A fresh single-device install is unaffected throughout: every device→master resolution is the identity map, so the push path behaves byte-for-byte as it did before multi-device.

---

## 14. WebRTC Transport Layer

### 14.1 Architecture

The WebSocket relay handles signaling (SDP offers/answers, ICE candidates). WebRTC data channels and media tracks handle the heavy payload: file bytes, vault shard bytes, voice, video, and screen share. This separation means ~85-90% of data transfer bandwidth is direct peer-to-peer with zero relay involvement.

### 14.2 ICE Configuration

- **STUN servers:** Public STUN servers + self-hosted coturn for server-reflexive candidate discovery.
- **TURN server:** Self-hosted coturn on the VPS for peers behind symmetric NATs.
- **Dual-stack (IPv4 + IPv6):** The relay, STUN, and TURN infrastructure all listen on both address families, and clients gather IPv6 ICE candidates wherever the OS provides them. When both peers have IPv6 there is no NAT in the path, so connections that would fail IPv4 hole-punching (symmetric NAT, carrier-grade NAT, common on mobile networks) complete directly instead of falling back to TURN. This benefits exactly the peer pairs most likely to need relayed media otherwise.
- **Share exception:** Hollow Share runs on a separate peer connection per peer, configured STUN-only (no TURN), so share traffic never consumes relay bandwidth (§8.4). It is negotiated with its own signaling message types, which a peer running an older build cannot parse and therefore discards; a share with such a peer simply does not start, rather than degrading its existing general-purpose connection.
- **Optional relay-only mode:** an off-by-default per-account setting restricts candidate gathering to relay candidates for real-time connections, hiding the user's address from co-participants at the cost of latency and quality (§6.4). Share is outside its scope.

### 14.3 Signaling Flow

1. Peer A creates an `RTCPeerConnection` and generates ICE candidates.
2. A sends the SDP offer + ICE candidates to B via the relay (small signaling messages).
3. B creates its own `RTCPeerConnection`, sends the SDP answer + ICE candidates back.
4. ICE negotiation completes (~200ms). Direct P2P connection established (or TURN fallback).
5. Data/media flows over the WebRTC connection, with zero relay bandwidth.

### 14.4 Connection Types

| Service | Connection Type | Encryption |
|---------|----------------|------------|
| File transfer | RTCDataChannel | DTLS + AES-256-GCM file encryption |
| Vault shard transfer | RTCDataChannel | DTLS + AES-256-GCM shard encryption |
| Share chunks | RTCDataChannel | DTLS + AES-256-GCM chunk encryption |
| Voice calls | RTCPeerConnection audio tracks | DTLS-SRTP + SFrame |
| Video calls | RTCPeerConnection video tracks | DTLS-SRTP + SFrame |
| Screen share video | Separate RTCPeerConnection | DTLS-SRTP + SFrame |
| Screen share audio (all platforms) | RTCDataChannel (type 0x03) | DTLS (Opus, outside the voice pipeline) |

### 14.5 Glare Resolution

When two peers simultaneously attempt to establish a connection, the **polite-peer protocol** resolves the conflict: the peer with the lexicographically smaller peer ID drops its own offer and accepts the remote one. ICE candidates arriving before the connection is ready are queued.

### 14.6 Backpressure

`getBufferedAmount()` monitoring prevents WebRTC data channel SCTP buffer overflow. The sender pauses when the buffer exceeds the threshold and resumes when it drains. Max 4 inflight chunks per peer for Share.

---

## 15. Message Signing and Verification

### 15.1 Canonical Signing Payload

Every message carries an Ed25519 signature over a canonical string. Since 0.8.3 the signature covers the whole message structure (payload v2):

```
hollow-msg2:{type}:{context}:{sender}:{timestamp_ms}:{message_id}:{reply_to}:{file_id}:{order_us}:{lp_digest}:{text}
```

| Field | Value |
|-------|-------|
| type | `"ch"` (channel) or `"dm"` (direct message); edits reuse the base type, deletions use `"ch-delete"` / `"dm-delete"` |
| context | `"{server_id}:{channel_id}"` for channels; `"{recipient_peer_id}"` for DMs |
| sender | Sender's peer ID |
| timestamp_ms | Milliseconds since Unix epoch (i64) |
| message_id | The message's UUID (dedup key) |
| reply_to | message_id of the replied-to message, or empty |
| file_id | Attachment id, or empty |
| order_us | Microsecond Lamport send stamp (same-millisecond ordering), or empty |
| lp_digest | SHA-256 (hex) of the link preview's length-prefixed fields (url, title, description, domain, site name, thumbnail bytes, and, where present, the card kind, author line and video target), or empty |
| text | Message body: the only field that may contain `:`, so it is last |

Absent optional fields serialize as empty strings. Binding these fields closes the v1 gaps: an attacker who could replay an otherwise-valid signed message can no longer re-target its reply, swap or add an attachment, rewrite its link preview into a phishing card, reorder it within a millisecond burst, or manipulate its dedup key.

**Re-signing a preview without editing the message.** A link preview is fetched by the sender while they type, and a fast sender can dispatch the message before that fetch returns. The card is therefore allowed to arrive afterwards, as a separate signed operation naming the original message. Because `lp_digest` is inside the signed payload, such an operation cannot simply amend the stored row: it carries a fresh signature over the *unchanged* text, timestamp, reply target, attachment and ordering stamp, with only the digest differing. Receivers reconstruct that payload from the row they already hold and reject the operation unless it verifies against the row's author, so a relay cannot use it to paste a card of its choosing onto a plaintext public-channel message. The row's edit stamp is deliberately untouched: a preview landing late is not an authorship event, and presenting it as one would train users to ignore the edited marker. The same operation with an empty preview clears a card, which is what an edit that removes the URL performs.

**Backfilled history carries what its signature covers.** Catch-up sync is how an absent peer obtains history, and a signed field is only as replicable as the data behind it. A batch carrying `lp_digest` without the preview it hashes would hand the receiver a row it can verify but cannot reproduce: the next peer syncing *from* that receiver would derive a different digest and reject the message as forged, so a message would survive exactly one hop past the peer that missed it. Backfill therefore ships the preview alongside its digest, and a receiver **recomputes** the digest from the shipped card rather than trusting the one on the wire. That ordering is what keeps the card inside the signature end to end: a responder, or on the plaintext public-channel path a relay, that substitutes a card produces a digest the author never signed, and the item is dropped rather than rendered. A digest arriving alone remains valid for a responder that holds no copy of the card; such an item verifies and is stored without one. The general property: whenever a signature binds a hash, the hashed object must travel every path the signature does, or replication silently terminates at the first peer that lacks it.

The legacy v1 payload (`hollow-msg:{type}:{context}:{sender}:{timestamp_ms}:{text}`) covered the message text only, leaving the reply target, attachment, ordering stamp and link preview outside the signature. It was accepted alongside v2 during the 0.8.3–0.8.4 transition and removed in 0.8.5: a verifier that accepts a weaker payload lets the attacker, not the sender, choose which fields are covered. Signatures produced before 0.8.3 no longer verify; those messages display as unverified and are not replicated through sync.

### 15.2 Verification

1. Decode the sender's Ed25519 public key from the protobuf-encoded bytes.
2. Derive the peer ID from the public key (identity multihash → base58).
3. Verify that the derived peer ID matches the claimed sender.
4. Verify the Ed25519 signature over the canonical payload using strict verification (`verify_strict`), which rejects non-canonical signatures (small-order group elements, malleable S values).

If any step fails, the message is rejected. This prevents impersonation: even if an attacker can inject messages into the encrypted channel, they cannot forge a valid signature without the sender's private key.

Because the signed sender is the author's *master* identity (§3.3), verification doubles as an **attribution-convergence** mechanism. When a node holds a stored message whose locally-recorded sender disagrees with an incoming, signature-verified copy of the same message (delivered via channel synchronization from any member that holds the authentic copy), the node repairs the stored attribution to the verified sender. This is unforgeable by construction: the repair is gated on the same full verification above, so it can only ever replace an attribution with one that the master's key has signed, never introduce a forged one. The mechanism exists so that a record stored before per-person attribution was applied (for example, one keyed under a specific device rather than its master) self-corrects on the next sync rather than remaining permanently misattributed.

### 15.3 Timestamp Integrity and Causal Ordering

The timestamp in the signature payload is authoritative. The UI hydrates its display timestamp from the Rust-signed value, not from the local clock. This prevents timestamp manipulation on the receiver side.

**Causal ordering (Lamport stamping).** In a serverless system, message order is determined by sender-issued timestamps, and wall clocks on different machines are never perfectly synchronized. Naively stamping from the local clock lets a reply sort *before* the message it answers whenever the replier's clock runs behind. Each device therefore maintains a Lamport clock over chat messages: every message it stores (received live, via synchronization, or its own) advances the clock to at least that message's stamp, and every message it sends is stamped strictly greater than everything it has seen (`max(local clock, highest seen + 1)`). Since a reply can only be composed after its antecedent was received, replies always order after their antecedents, on every device, regardless of clock skew. The signed timestamp and the microsecond ordering key derive from the same stamp, so no two ordering keys can disagree. A clamp bounds how far a peer's future-dated stamp can advance the clock, so a device with a wildly wrong clock (or a malicious stamp) cannot drag other members' subsequent messages into the future. Concurrent messages (neither sender having seen the other's) have no canonical order by construction; devices converge on the deterministic stamp order.

### 15.4 Edit and Delete Signing

Message edits and deletions carry their own signatures over canonical payloads. An edit signs the edit timestamp and the new text; a deletion signs the deletion timestamp and the text at deletion time (evidence of what was removed). Under payload v2 both also bind the row's structural fields, message_id included, so an edit or delete signature cannot be replayed onto a different message, and a sync responder cannot graft forged attachments onto an edited row. The edit chain is preserved: each edit records the previous signature, public key, and timestamp, creating a verifiable history. Deletion operations are signed events, not tombstones.

Live ingest requires a valid signature on edits, deletions, and reactions on every surface (MLS channels, public channels, DMs). On plaintext public channels the signature is the only thing binding these actions to an identity, and an unauthenticated delete would otherwise be a censorship primitive available to a hostile relay.

---

## 16. The Rat Files (Cryptographic Evidence)

Hollow's architecture ensures that **nobody can remotely destroy evidence**. Messages are digitally signed, locally stored, and distributed; no central authority can issue a "delete from all devices" command.

### 16.1 Evidence Properties

- **Non-repudiation:** Every message carries an Ed25519 signature. The sender cannot deny authorship.
- **Integrity:** Any modification to a message invalidates its signature.
- **Unforgeable:** Unlike screenshots, Hollow message proofs are cryptographically verifiable by any third party with standard Ed25519 tools.
- **Survivable:** Even if the server owner kicks everyone and dissolves the server, evidence persists on ex-members' devices.

### 16.2 Message Proof Export

Any message can be exported as a JSON proof containing:
- Message text, timestamp, and context (server/channel or DM)
- Sender's Ed25519 public key
- The canonical signing payload
- The Ed25519 signature
- Verification instructions

Anyone can verify the proof independently using standard Ed25519 libraries, with no Hollow installation required.

### 16.3 Archive Format (.hollow-archive)

A portable, cryptographically verified export format for conversation history:

- **Per-message signatures** preserved from the live database.
- **Edit history** with per-edit signatures (old text, new text, timestamps, each independently verifiable).
- **Deletion records** with per-delete signatures (the deleted text is preserved, the delete operation itself is signed).
- **Reaction removal evidence** (who removed which reaction, when, signed).
- **File embedding** with SHA-256 integrity hashes (three modes: full, images-only, placeholder).
- **Archive-level signature:** The exporter's Ed25519 key signs a deterministic hash of the entire archive contents. This catches selective omission: it attests that the archive is the exporter's complete record.

### 16.4 Evidence Recovery (Cooperative Shard Gathering)

When a server is dissolved, ex-members can cooperatively reconstruct files they no longer have locally:

1. Ex-members who held vault shards still have them on their devices.
2. Shards can be exchanged via a relay-coordinated recovery pool or exported/imported as `.hollow-shards` bundles.
3. Once `k` shards are gathered for a file, Reed-Solomon decoding reconstructs the encrypted ciphertext.
4. Members who were in the server hold the MLS epoch keys to decrypt.
5. All original signatures remain intact and verifiable.

---

## 17. Gossip Overlay Network

### 17.1 Connection Subset Management

For large servers, maintaining a full mesh of WebRTC connections is impractical. Hollow limits persistent connections to 6-12 peers per server (50 total across all servers).

### 17.2 Peer Scoring

Peers are scored on five metrics:
- **Uptime ratio:** Connection duration relative to total time.
- **Average latency:** Round-trip time measured via data channel pings.
- **Bandwidth score:** Observed throughput on data transfers.
- **Shard overlap:** Number of shared vault shards (high overlap = high value for shard retrieval).
- **Reachability:** Whether the established connection runs peer-to-peer (host, server-reflexive, or LAN ICE route) or through a TURN relay. Directly-reachable peers score higher, because a mesh that leans on TURN still consumes relay-class bandwidth; neighbor rotation therefore drifts toward peers that offload the infrastructure.

Neighbor rotation runs every 300 seconds (5 minutes). The lowest-scoring peer is dropped and the highest-scoring unconnected peer is added. Max 1 rotation per cycle for stability. Separately, peer list exchange runs at adaptive intervals (120s/180s/240s, scaled by server member count) to share known peers with neighbors.

### 17.3 Gossip Broadcast

When a peer receives data tagged as broadcast (files, images), it re-forwards to its connected WebRTC subset (minus the source). This creates a gossip tree that covers 1000+ members in ~3 hops (~600ms), with zero relay bandwidth. Voice and video media flow over WebRTC media tracks (DTLS-SRTP, peer-to-peer) and are not gossip-relayed.

- **Broadcast deduplication:** Each broadcast carries a unique ID. Peers track recent IDs and drop duplicates.
- **TTL / hop limit:** 4 hops maximum to prevent infinite propagation. Default TTL is included in the broadcast metadata.
- **Fallback:** Fewer than 6 reachable peers → connect to all available.

**Server-state operation flooding.** Server-state (CRDT) operations also flood the overlay instead of transiting the relay. Because these operations are idempotent (an operation log deduplicates re-application) and self-validating (every receiver re-checks the *author's* permission before applying, regardless of who forwarded it), they are safe to flood by construction. A node re-forwards an operation to its neighbors only when that operation was *new* to its own log, so each node forwards a given operation at most once, propagation is bounded without global coordination, and only operations that passed validation spread. This removes both the relay's per-operation fan-out and the plaintext visibility the relay previously had into these operations; the relay path remains as an automatic fallback whenever a node's mesh links are not yet established, and offline members converge through normal state synchronization.

### 17.4 Peer Exchange

Connected peers share known peer lists for each server via `PeerExchange` messages sent directly to each neighbor (not broadcast). This enables peer discovery beyond the directly connected subset. Peer exchange is capped at 50 entries and only accepted from current gossip neighbors.

---

## 18. Anti-Censorship Transport

### 18.1 Baseline Protection

Hollow's standard transport (WebSocket over TLS on port 443) looks like normal HTTPS traffic to network observers. This is sufficient in most environments.

### 18.2 Research and Testing

Extensive testing was conducted against Russia's TSPU deep packet inspection system:

- **Shadowsocks-2022** (`2022-blake3-aes-256-gcm`) was implemented and tested. It works on many ISPs but Russia's TSPU detects the encapsulated traffic pattern on some ISPs, killing connections after ~20 seconds. The implementation was removed from the codebase after testing: it did not reliably defeat the most aggressive DPI configurations.
- **Plain VPN tunnels** (WireGuard, OpenVPN, IKEv2) are all blocked in Russia.
- **A commercial VPN** works, confirming the issue is protocol fingerprinting of the *inner* traffic, not IP blocking of the relay.

The refined threat model: TSPU does not block on the outer wrapper or the port, but on the *shape* of the traffic inside the tunnel: a real-time TLS-1.3-over-TCP flow to a foreign-datacenter IP whose volume freezes a connection after roughly 25 packets (~16 KB) in either direction. Plain WSS-on-443 is therefore fingerprintable as-is, and simply changing ports does not help.

### 18.3 REALITY Camouflage Tunnel

Hollow embeds an optional **VLESS + REALITY (XTLS-Vision)** transport that makes the relay connection indistinguishable from an ordinary HTTPS session to a real, popular, unblockable website. REALITY clones a genuine target site's TLS-1.3 ClientHello, so a middlebox inspecting the handshake sees legitimate traffic to that site; XTLS-Vision splits and pads the flow to defeat the packet-count freeze described above. Community measurements place its detection rate below 5% against the most advanced DPI as of early 2026.

**Architecture.** When a user enables the tunnel, the client runs a local proxy (the `shoes` Rust implementation) that performs the REALITY handshake outbound to a server-side REALITY endpoint; the endpoint authenticates the client and forwards the decrypted stream to the relay over loopback. The application layer is unchanged: the node still opens exactly the same relay WebSocket connection, but routes it through the local tunnel when the mode is on. The tunnel is single-destination (it dials one relay, with no routing tables), which keeps its footprint small enough to remain viable inside mobile network-extension memory limits in a future mobile port.

**Cryptographic note.** REALITY does not present the relay's own certificate. It borrows the target website's real certificate at handshake time and issues a temporary trusted certificate only to authenticated clients; to any probe or observer the endpoint indistinguishably resembles the borrowed site.

The desktop implementation is complete; validation against live TSPU conditions is in progress. A residual limitation is that a single, known server IP can in principle be blocked by destination-IP correlation or CIDR whitelisting regardless of how well the inner traffic is disguised; mitigations (CDN-fronting or rotating server IPs) are future work.

---

## 19. Twitch Community Verification (Optional)

Server owners can optionally gate membership behind Twitch follow or subscription verification. This provides community identity verification without requiring any personal information.

### 19.1 OAuth Flow

Verification uses the **Device Code Grant** flow (OAuth 2.0 RFC 8628):

1. The client requests a device code from Twitch via the Twitch API.
2. The user visits a Twitch URL in their browser and enters the code.
3. The client polls for completion. On success, it receives an OAuth access token.
4. The token is used once to verify follow/subscription status, then discarded.

The verification flow runs entirely client-side. The relay never sees or stores the user's OAuth token; only the Ed25519-signed verification proof is broadcast to the server.

### 19.2 Verification Proof

After verification, a cryptographic proof is generated and broadcast to the server:

- The proof contains the peer ID, Twitch username, verification type (follow/subscriber), and timestamp.
- The proof is signed with the peer's Ed25519 key.
- Server members verify the signature and store the proof locally.
- The proof is re-verified on each server join if the owner requires "owner must be online" verification mode.

### 19.3 Privacy Properties

- No Twitch data is stored on the relay or any server infrastructure.
- The OAuth token is ephemeral: used once and discarded.
- Verification status is stored only in each peer's local encrypted database.
- The server owner's Twitch channel name is the only Twitch-related data shared among members.

---

## 20. Verification and Correctness Assurance

Distributed, multi-device cryptographic logic is difficult to verify by manual testing alone, because many failure modes appear only with specific timing across several devices. Hollow's correctness rests on a **multi-node integration harness** that exercises the real protocol code deterministically.

### 20.1 Multi-Node Harness

The harness spins up *N* real node event loops in a single test process, each with its own Ed25519 keypairs and its own temporary SQLCipher database, wired together through an **in-process mock relay** rather than real sockets or TLS. The same Rust core that ships in the client runs in the harness, so the encryption, ratcheting, CRDT merge, and synchronization logic under test is the production logic, not a model of it. The mock relay reproduces the load-bearing, protocol-visible behaviors of the real relay (authentication, room join/leave, broadcast and direct routing, topic frames, offline buffering and replay, and disconnect events) so that reconnection and offline/online transitions are exercised faithfully.

### 20.2 Two-Layer Inspection

Multi-device bugs hide in the gap between the *master-collapsed* view that the UI presents and the *device-keyed* truth underneath. The harness exposes both layers: a UI-layer inspector that reads through the same resolver and CRDT accessors the application uses, and a raw-layer inspector that exposes per-device state (per-device MLS leaf membership, per-device Olm session status, raw device-keyed CRDT keys). A test can therefore assert precisely where the master-keyed and device-keyed layers should and should not diverge, the central invariant of the multi-device design (§3, §5).

### 20.3 Coverage and Scope

The harness self-verifies the **distributed-logic core**: DM messaging and sync/backfill (direction, signatures, deduplication, edits/deletes/reactions), friends and profiles, presence and typing, CRDT servers/channels/roles/permissions/bans, MLS group formation across per-device leaves at a shared epoch with cross-device channel decryption, public channels, device revocation (tombstone propagation, Olm/MLS cutoff, and the ghost-device liveness guard), and Olm key exchange and glare. It also covers the **control and signaling plane** for calls, voice channels, recovery pools, and file transfer (including the actual bytes over the relay fallback path). The harness runs in continuous integration as a required check, gating merges.

It deliberately does **not** cover the WebRTC media plane (audio/video pixels, SFrame on live tracks, ICE/TURN/DTLS), the Flutter UI, the FFI bridge, native push delivery (FCM/APNs and the iOS extension), identity at-rest unlock, or the real relay's C++ implementation. The application layer is addressed separately (§20.4); the remainder stays the subject of manual platform testing. The honest claim when the harness is green is therefore precise: *the distributed-logic core and the control/signaling plane behave correctly across many devices*, not that the entire application is verified.

### 20.4 Application-Layer Probes

A second harness closes part of the gap the first one leaves. An instrumented build of the real client, running the production interface code, foreign-function bridge, encrypted local database and node against the real relay, is driven through its own widget tree by a scripted command stream. It can address any control, read the application's own state, and assert on what is actually rendered rather than on what the protocol layer believes.

Several such instances run side by side on one machine, each with a separate identity and data directory, so a journey that spans peers (a friend request accepted, an invitation joined, a message delivered, a member removed) is asserted from both sides at once. This answers a class of question the multi-node harness cannot: not whether an operation converged, but whether the interface agrees with it once it has.

The layer stops short of the media plane. Video surfaces are composited outside the widget tree, so no capture of a rendered frame can demonstrate that video is flowing; only decoder and renderer statistics can, and that remains future work.

---

## 21. Summary of Cryptographic Primitives

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
| Identity wrapping (password) | Argon2id + AES-256-GCM | 256-bit key, 128-bit salt | Identity keypair encryption at rest (password-protected) |
| Identity wrapping (OS keychain) | DPAPI / Keychain + AES-256-GCM | 256-bit key | Identity keypair encryption at rest (OS-bound) |
| Local storage | SQLCipher (AES-256-CBC) | 256-bit | Database encryption at rest |
| Backup encryption | Argon2id + AES-256-GCM | 256-bit (64 MB memory cost) | Brute-force resistant account backup |
| Device list | Ed25519-signed, versioned | 256-bit | Master-signed binding of a person's devices and revocations |
| Per-device transport key | Ed25519 (random per device) | 256-bit | Per-device relay authentication; decouples device ID from identity |
| Device-link transfer | Argon2id + AES-256-GCM (`.hollow` backup) | 256-bit | Encrypted identity + DB transfer to a new device (code = passphrase) |
| Mobile app lock | Argon2id + AES-256-GCM (+ OS secure enclave for biometric) | 256-bit | PIN/password/biometric launch lock over the identity-at-rest key |
| Twitch verification | Ed25519-signed proof | 256-bit | Verifiable community membership proof |
| Anti-censorship | VLESS + REALITY (XTLS-Vision) | n/a | DPI-resistant tunnel; desktop implemented, live-network validation in progress |

---

## 22. Threat Model

### 22.1 What Hollow Protects Against

| Threat | Protection |
|--------|------------|
| Message content interception | E2EE (Olm for DMs, MLS for servers). Only intended recipients hold decryption keys. |
| Relay compromise | Zero-knowledge design. A fully compromised relay learns only peer IDs and room membership (both in memory, not logged to disk). |
| Push-provider metadata harvesting | Empty wake-up pushes (`{wake, sender}` only). Apple/Google never receive message text, size, or content; all content is fetched from Hollow's relay and decrypted on-device. |
| Link-preview IP harvesting | Previews are fetched once, by the sender, and travel inside the encrypted message. A recipient's device makes no request to the previewed site to render the card, so posting a link into a large room reveals nothing about who read it. Without this, a link in a busy channel would enumerate its readers to whoever controls the URL. Playing an embedded video is the sole exception and requires an explicit tap, on a target the signature already covers. |
| Device-list tampering | The device list is signed by the master key and versioned; only the master can add or revoke a device, and replays cannot un-revoke. |
| Stolen/lost device | Manual device revocation: a signed tombstone removes the device's MLS leaf and Olm sessions everywhere and causes the revoked device to wipe itself. |
| Voice/video eavesdropping | SFrame E2EE. Media is encrypted per-frame. TURN servers see only ciphertext. |
| File content interception | AES-256-GCM per file. Relay and TURN see only encrypted bytes. |
| Man-in-the-middle on key exchange | Authenticated Olm key exchange + Ed25519 identity binding. |
| Storage shard snooping | Encrypt-then-erasure-code. Shards are encrypted; reconstructing all shards yields only ciphertext. |
| Removed member accessing new content | MLS epoch rotation on removal. New epoch derives fresh keys from randomness the removed member doesn't have. |
| Message forgery | Ed25519 signatures on every message. Invalid signatures are rejected. |
| Harassment by a specific peer | Master-keyed local blocking enforced at ingest (§12.14): DMs, friend requests, calls, and files from a blocked identity are dropped before storage or notification, from any of their devices. |
| Evidence destruction | Decentralized storage + cryptographic signatures. No central authority can delete data from other users' devices. |
| CRDT state manipulation | Author verification + role-based permission checks. Unauthorized operations rejected. |
| Clock manipulation attacks | HLC drift bound (5 minutes). Far-future timestamps rejected to prevent LWW conflict gaming. |
| Resource exhaustion | Ed25519 authentication, license key revocation, message size limits (64 MB binary / 1 MB text), 64 MB hard backpressure, connection limits. |
| Privilege escalation | Permission checks on all state-changing operations. CRDT author ≠ self-reported field; it is verified against the actual sender. |
| Identity file theft | HKEYV1 at-rest protection. Identity file encrypted via DPAPI/Keychain (machine-bound) or Argon2id + AES-256-GCM (password). Stolen files are useless without the original machine or password. |

### 22.2 What Hollow Does Not Currently Defend Against

- **Traffic analysis:** message timing and size patterns are visible to the relay and network observers. Constant-rate padding is not implemented.
- **Local device compromise:** if an attacker has access to an unlocked device with the decrypted database open, they can read everything. This is true of any E2EE system. Identity at-rest protection (§2.3) mitigates offline attacks: the identity file is encrypted via DPAPI/Keychain (machine-bound) or a user password (Argon2id), so a stolen identity file is useless without the original machine or password. However, a live session with the wrapping key in memory remains vulnerable.
- **Relay availability attacks:** a malicious relay can selectively drop or delay messages. The current single-relay architecture has no failover. Multi-relay support is designed but not yet deployed.
- **Quantum computing:** all key exchanges use Curve25519. Migration to ML-KEM (Kyber) is planned but not prioritized for the beta.
- **Trust-on-first-use (TOFU):** peer identity verification relies on out-of-band fingerprint comparison. There is no certificate authority or web of trust.

### 22.3 Relay Operator Trust Assumptions

The relay operator is assumed to be **honest-but-curious**: the relay faithfully forwards messages but may attempt to read or log traffic. The protocol is designed so that curiosity yields nothing useful.

The relay operator is also assumed to be potentially **unreliable**: the relay may go offline, and clients auto-reconnect with exponential backoff.

The relay operator is **not trusted** with: message contents, encryption keys, file data, user profiles, message signatures, or any application-layer semantics.

---

## 23. Limitations and Future Work

- **No post-quantum cryptography:** all key exchanges use Curve25519. If quantum computers eventually break elliptic curve crypto, intercepted ciphertext could theoretically be decrypted retroactively. A future migration to ML-KEM (Kyber) is a consideration but not a priority; no consumer chat app has shipped this yet.
- **No traffic analysis protection:** the relay uses native TLS via uWebSockets C++ with OpenSSL (direct TLS termination, no reverse proxy), which protects message *content* from network eavesdroppers. However, message *timing and size patterns* remain visible: an observer can infer who is chatting with whom based on when messages are sent, even without reading them. Defeating this would require constant-rate padding (sending dummy traffic to hide real messages), which is impractical for a chat app.
- **Single relay dependency:** multi-relay support with cross-relay room gossip is designed but not yet deployed. Horizontal scaling to millions of users via a swarm of relay nodes is the planned architecture.
- **No social recovery:** Shamir's Secret Sharing for key recovery via trusted contacts is designed but not implemented.
- **No web client:** Windows, macOS, Linux, Android, and iOS are supported. A Flutter Web build is a future target with no working build today.
- **Mobile media constraints:** voice and video calls (with SFrame E2EE), file transfer, DMs, MLS servers, vault, archive, and screen sharing with system audio (§6.8) all work on mobile. The remaining gap: the large-file Share transport (>34 MB, STUN-only) is excluded on mobile because it does not survive carrier-grade NAT. macOS below 13.0 cannot send screen-share audio (no capture API).
- **Files are not encrypted at rest:** SQLCipher encrypts messages and metadata, but downloaded file attachments (`~/.hollow/files/`), vault shards, and vault cache are stored as plaintext on disk. AES-256-GCM at-rest file encryption keyed from the identity is planned.

---

*This document describes the Hollow protocol as implemented in the Beta release. The protocol is subject to change. Check the GitHub repository for the latest updates. The relay server is open-source under the MIT License. The client application is open-source under the GNU Affero General Public License v3.0 (AGPL-3.0).*
