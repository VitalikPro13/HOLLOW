# Hollow Protocol Whitepaper

**Version 0.12.0**\
**Author: Vitalii Rovinskyi**\
*This document was generated with the assistance of Claude (AI). All technical content reflects the author's architecture and design decisions. Some sections may not match the version number shown above until the next release.*

---

## Abstract

Hollow is a fully distributed, end-to-end encrypted communication platform. There are no central servers that store messages, files, or metadata. Members of a server collectively host it. The relay is a zero-knowledge signaling pipe that routes encrypted blobs between peers. It cannot read or alter them, and the ciphertext it holds for offline members lives only in its memory.

Hollow provides real-time text messaging, voice and video calls, screen sharing, file sharing, and distributed storage, all with end-to-end encryption. A single human identity can run on multiple devices (multi-device sync), and mobile clients receive push notifications without ever exposing message content to Apple or Google. The protocol is designed so that even a fully compromised relay operator learns only routing metadata: which device IDs are connected, which rooms they share, and when and how much they send (§12.7).

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
18. [Censorship Resistance](#18-censorship-resistance)
19. [Twitch Community Verification](#19-twitch-community-verification-optional)
20. [Support Credentials for Purchased Art](#20-support-credentials-for-purchased-art)
21. [Verification and Correctness Assurance](#21-verification-and-correctness-assurance)
22. [Summary of Cryptographic Primitives](#22-summary-of-cryptographic-primitives)
23. [Threat Model](#23-threat-model)
24. [Limitations and Future Work](#24-limitations-and-future-work)

---

## 1. Introduction

### 1.1 Design Goals

- **Zero-knowledge relay:** the relay sees routing metadata (peer IDs, room membership, timing and size). It cannot read message contents, encryption keys, file data, or any application-layer semantics.
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

The mnemonic is shown to the user once at account creation, checked by asking for three of its words back, and never stored or transmitted. It is the sole identity recovery mechanism and, since 0.12, the final word on which devices belong to the identity (§3.2).

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

- **Password with launch lock** (flags = `0x01`): The user's password is processed through **Argon2id** (65536 iterations, 3 parallelism, 32-byte output) with a random 16-byte salt to derive the AES-256-GCM key. Password is required on every application launch. A full-screen, non-dismissible unlock dialog blocks all interaction until unlocked.

- **Password with silent unlock** (flags = `0x03`): Same password-derived encryption as above, but the wrapping key is also cached in the OS credential store for silent unlock. The identity file is encrypted (protecting against file copying), but the app opens normally on the same device. A toggle in Settings ("Ask for password on launch") controls this behavior. If the OS credential store becomes unavailable, the app falls back to requesting the password.

- **Device protection only** (flags = `0x02`): A random 32-byte wrapping key is stored in the OS credential store: **Windows Credential Manager** (`CredWriteW`/`CredReadW`) as primary with a **DPAPI blob** (`identity.dpapi`) as fallback on Windows, **Keychain** (`security-framework` crate, service `com.hollow.identity`) on macOS. On mobile, the equivalent silent-unlock layer is provided by the App Lock subsystem (§2.6), which gates a copy of the wrapping secret behind the OS secure enclave (Android Keystore / iOS Keychain) and biometric authentication. Silent unlock on the same machine. The identity file is useless if copied to another device.

**Per-profile slots and verified retrieval:** Because one machine can host multiple identity profiles (each with its own data directory), the credential store is keyed per profile: the slot name carries a digest of the profile's data-directory path, alongside a legacy machine-global slot kept for backward compatibility (on Windows, a DPAPI-encrypted blob inside the profile's own data directory is a third, storage-failure fallback). Retrieval never trusts any single slot: unlock collects every stored candidate and accepts only one that actually decrypts the identity file at hand, then re-writes the verified key to all slots so they self-heal toward the active profile. This closes a lockout class where a second profile's key overwrote the first's in a shared slot and the unverified key was trusted, forcing the user into mnemonic recovery, which rotates the device key and discards its group memberships. The self-healing rewrite belongs to unlocking the profile the application is running as, and only to that. Where the application merely needs to ask whether a stored credential can open some *other* profile's identity file - to require proof of ownership before destroying it, for instance - the probe is strictly read-only: it reports whether a candidate decrypts and writes nothing back. Healing on a foreign file would reintroduce the very cross-profile overwrite the verified retrieval exists to prevent.

**Backward compatibility:** Plaintext identity files (68 bytes, protobuf header `0x08 0x01`) are auto-detected. Plaintext identities remain plaintext until the user explicitly enables protection; there is no silent auto-encryption.

**Session wrapping key:** After `unlock_identity()`, the 32-byte wrapping key is held in a Rust `OnceLock<Mutex<Option<[u8; 32]>>>` for the session lifetime. All identity operations use this in-memory key. Calling `lock_identity()` zeroes and clears the key, re-requiring authentication.

**Recovery:** The 24-word BIP-39 mnemonic bypasses identity encryption entirely: it deterministically regenerates the keypair from scratch, removing any existing HKEYV1 encryption.

**Duress code.** A password-protected identity that prompts at launch may carry a second secret, typed at the same prompt, that never unlocks and always destroys. It lives in a sibling slot with the same HKEYV1 layout and its own salt; the slot exists whenever password protection does, holding random bytes under a random key when no duress code is set, and its plaintext has a fixed size, so neither the disk nor the timing of an unlock attempt reveals whether a code is configured. Every typed secret is processed against both slots before any decision is made. The duress code must differ from the password, and a password change that would collide with it is refused. The person typing it sees no error and no confirmation: the data is destroyed and the application returns to its first-launch screen.

**Destruction.** One local routine erases an installation in a fixed order: a resume marker, then the identity key files and the OS keystore slot, then the database that holds every per-file key (§2.4), then the content directories and the call and screen recordings this profile made, which live outside the data folder (each profile keeps a list of its own, so recordings from other profiles in the same folder stay). On a desktop with several profiles a wipe touches only its own: the profile list forgets it, and Hollow restarts into another profile or first-time setup. It never waits on the network; an unreachable device still erases itself, and the marker finishes anything the platform refused to unlink at the next launch. Three scopes build on it. The device alone. The device plus its own removal: it signs a removal of itself into the person's roster (§3.2), so the person's other devices and friends stop routing to it, and a removal stays final within the roster's base even against a modified client that still holds the shared master key. And the whole identity: a destruction order (master, issue time, optional target devices, friend flag) signed with the recovery key, which only the recovery phrase produces, reaches online devices over the sibling lanes and offline devices through the relay, which parks the opaque signed order under each target device id and hands it over as the first frame after that device next authenticates, with no retention limit. The relay is a courier only: it cannot read, forge or retarget an order, and a receiving device verifies the recovery-key signature itself against the key it pinned for the identity, refuses an order issued before it was linked (so a device linked after a destruction is never wiped by a replay) or older than one it has already applied, and acknowledges both a completed wipe and a permanent rejection so the relay stops re-sending. An identity from before 0.12 gets its recovery key at the first 0.12 start of any device that kept the phrase 0.11 stored (§3.2); one with no such device has no recovery key until the phrase is typed, and keeps the earlier master-signed order until then. Friends may be told: the conversation is marked destroyed, the contact's verified status is dropped, and a later roster from the same master (the phrase recreating the identity, which nothing can prevent) raises a warning that the identity has come back and must be verified again. A duress code entered at a cold launch destroys the local device only, because with the wrong password nothing can be signed. A duress code set from a running node can destroy every device instead: the phrase, typed once when the code is set, signs a permission for that one device to issue the order, and the duress slot keeps the permission, never the phrase or the recovery key. Removing the device voids it.

### 2.4 Local Storage Encryption

All local data is stored in **SQLCipher** (AES-256-CBC encrypted SQLite). The database encryption key is derived from the first 32 bytes of the **master** keypair's protobuf encoding, hex-encoded as a passphrase. The database is inaccessible without the keypair. Because the passphrase is a deterministic function of the master identity, an encrypted database transferred to another of the same person's devices (device linking, §3.4) opens transparently under the transferred master key.

**Content files at rest.** Attachments, voice notes, videos, thumbnails, the vault cache and Hollow Share downloads are stored under the data root as ciphertext, never as the files a peer sent. Each file is encrypted under its own random 256-bit key with AES-256-GCM in independent chunks (1 MiB, or the transport's chunk size for out-of-order downloads); the nonce is a per-file random prefix concatenated with the chunk index, and the additional authenticated data binds the file's random identifier, the chunk index and a last-chunk flag, so a chunk cannot be moved, swapped between files or truncated away without failing authentication. The per-file keys live in a table of the SQLCipher database, so they inherit exactly the identity protection the person chose (§2.3) and deleting a file's row is a cryptographic erase: message deletion, cache limits and retention all remove the key with the bytes. File names are unchanged and a per-boot sweep converts what an older version left in plaintext. Media players that take only a URL read through a loopback HTTP server bound to 127.0.0.1 with a random port and a per-launch token that decrypts on the way out; taking a file out of the application (Save as) is an explicit decrypt-to-destination and the interface says the copy is unprotected. The guarantee is bounded: it protects the disk after the application is closed, uninstalled, stolen or browsed, and against a remote reader while the identity is locked. A running, unlocked session holds the keys in memory, and with no identity protection mode enabled the identity file itself is plaintext, so every key below it is derivable from the folder.

**iOS shared-database constraint.** On iOS, the SQLCipher database is migrated into a shared **App Group container** (`group.com.anonlisten.hollow`) so the push Notification Service Extension can open the same encrypted database to decrypt incoming messages on-device (§13.5). Because two processes (the app and the extension) may open the database, it uses **rollback-journal mode (`journal_mode=TRUNCATE`) on iOS rather than WAL**. WAL keeps a persistent shared-memory lock; an app suspended while holding a file lock in a shared container is killed by iOS (`EXC_CRASH 0xdead10cc`). Rollback-journal mode locks only during a transaction, and a 4-second busy timeout lets the two processes wait on each other. All other platforms use WAL.

Removing the *persistent* lock is necessary but not sufficient: **opening** the database also takes one. A newly opened connection holds no schema cache, so its first statement reads and parses the entire schema under a shared lock before any query runs, and a suspension landing inside that window is indistinguishable to the platform from holding a lock indefinitely. The constraint this imposes is architectural rather than incidental: on a shared-container platform, database access on a latency-sensitive path must go through a long-lived connection owned by a dedicated worker, never through a fresh connection opened per item on the event loop. Reads served that way answer from a warm connection outside any transaction, so the lock-holding window shrinks to the query itself.

### 2.5 Account Recovery

Two recovery methods are implemented:

**Phrase recovery:** The 24-word BIP-39 phrase regenerates the identity keypair and the recovery key (§3.2). Typed on a new install, it admits that device at once; typed on an existing device, it can start the identity over with only the devices the person picks. Server memberships and message history re-sync from peers.

**Encrypted backup:** Full account state (identity key + encrypted database + optional vault shards) is exported as a passphrase-protected `.hollow` file. The passphrase, at least 12 characters, is processed through Argon2id (64 MB memory cost, ~500ms per attempt) to derive an AES-256-GCM encryption key. A backup holds no recovery phrase and no device secrets (no Olm account or sessions, no MLS signing identity), and a device restored from one joins the identity only once another device approves it, the phrase is typed on it, or seven days pass with nobody refusing it, unless the person used the phrase to turn that wait off (§3.6).

### 2.6 App Lock (Mobile)

Mobile clients add an **App Lock** that gates application launch behind a PIN, password, or biometric authentication:

- **PIN / password lock:** a numeric PIN or a password is processed through the **same Argon2id + AES-256-GCM identity-at-rest pipeline** described in §2.3. A PIN is cryptographically identical to a password (it is simply numeric input), so there is no separate, weaker code path. A new PIN has at least six digits. Nothing limits attempts in hardware, so someone holding a copy of the app's data can try PINs offline at the cost of one Argon2id derivation each; a password closes that gap.
- **Biometric layer:** biometric unlock is a *layer on top of* a PIN/password, not an independent lock type. A copy of the PIN/password secret is stored in the OS secure enclave (Android Keystore / iOS Keychain) and released only after a successful `local_auth` biometric check. The underlying identity encryption is always the Argon2id path; biometrics gate retrieval of the secret.
- **Pre-unlock marker:** the lock-type marker and any biometric secret are stored in OS-backed secure storage (Keystore/Keychain), *not* in SQLCipher, because they must be readable *before* the encrypted database is unlocked at launch.
- **Self-heal:** a stored biometric secret that fails to unlock the identity is deleted to avoid a failing-biometric loop. Mnemonic recovery resets the identity to plaintext.

As with desktop at-rest protection, the database remains sealed until the Argon2id key derivation completes (typically 1.5–3 seconds), and protection is never silently enabled. The 24-word mnemonic is the sole universal recovery path.

Both platforms lock the same way over a running node: at launch, after a chosen idle span, after a short time in the background on a phone, or on demand, an opaque cover replaces the interface while presence, messages and calls continue underneath, and the same password prompt opens it again. Nothing navigates above the cover while it is up: a notification tapped then is held until the lock lifts, a link opened from outside waits for the unlock too, and a call answered from the lock screen runs without showing its screen or its conversation. While locked, notifications read only "New message", with no name, avatar, text or reply action, and toasts shown before the lock are withdrawn. The prompt offers only to end a running call. By default the unlock secret is held by the operating system's keystore so the application starts without a prompt and the lock is the only prompt; a duress code (§2.3) typed there runs with the keys in memory, so its identity-wide scopes fire. The person may instead require the password before the application starts, which keeps the key unreachable without it; a duress code typed at that prompt destroys that device only.

---

## 3. Multi-Device Identity and Synchronization

A single Hollow *person* (one master identity) can run on several physical devices simultaneously, with messages, friends, servers, and history kept in sync. This is achieved without any account server and without the relay ever learning that two connections belong to the same human.

### 3.1 Two-Tier Key Hierarchy

Each person is one **master identity**: the Ed25519 keypair derived from the BIP-39 mnemonic (§2). The master key governs everything durable and cross-device: profile, friendships, DM-room derivation, **message-content signatures**, server/MLS membership, and the SQLCipher database passphrase.

Each physical device *additionally* holds its own **independent, randomly generated Ed25519 device key** (not derived from the mnemonic). The device peer ID is produced by the same multihash encoding used for master IDs, so to the relay, to rooms, and to Olm it is byte-for-byte indistinguishable from any other peer ID.

The device key drives identity **only at the transport layer**: relay authentication (a distinct relay socket per device) and signaling. Everything else stays master-keyed. The rooms a device joins are all *master-derived* (`inbox:{master}`, the DM room code, the server ID), so a device authenticates as itself yet occupies its identity's rooms.

**What the relay can tell.** Each device presents its own random peer ID, but every device of a person joins that person's rooms, among them the inbox room that only the person's devices can prove they own, and the relay holds each identity's roster in memory to decide who may read that inbox (§3.2, §12.7). The relay can therefore tell which device IDs belong to one person. It reads nothing those devices send. Showing several devices as one person is done by the client of whoever is looking.

The device key shares the same at-rest protection as the master key (§2.3): both files are wrapped by the same session key, and a protection change rewrites both.

### 3.2 The Roster

A person's devices are not a list the master key signs. Since 0.12 they are a **roster**: a set of statements, each signed and each verifiable on its own, which every observer folds into the same answer. Holding the master key proves nothing about which devices are the person's.

| Statement | Signed by | Says |
|---|---|---|
| Consent | the device itself | this device agrees to belong to this master |
| Vouch | a current device | this device is one of ours |
| Pending join | the master | a device restored from a backup asks to join |
| Removal | a current device | this device is no longer ours, and which of the devices it added stay |
| Recovery | the recovery key and the master | start over: exactly these devices are ours |
| Phrase admission | the recovery key and the master | this device joins now |

Every signature covers an ASCII payload with its own `hollow-id1-*` tag and the master ID, so no statement passes as another type.

**The recovery key.** The recovery phrase (§2.1) also derives a second key: R, an Ed25519 key from HKDF-SHA256 over the whole 64-byte BIP-39 seed. The master key is the first half of that seed and does not determine R. No device stores R or the phrase; R exists only while the phrase is typed. The master signs R once to bind it to the identity, and every observer keeps the first R it sees for that identity.

**The fold.** The newest recovery starts a base. Its keep set, plus every phrase admission dated after it, are the roots. The members are the roots, every device a member vouched for in this base, and every pending join this observer first saw at least seven days ago, minus every device a rooted signer removed. Every member must have signed its own consent, so no roster can claim a device that never agreed. Removals are a plain union, so the fold needs no clock and no order. A removed device's vouches keep counting only for the devices that every removal of it keeps, so a device it adds afterwards cannot keep itself in. A vouch or removal counts only from a device with an admission path in the base, and when a roster is full the statements of devices nearer the phrase stay, so nobody can push a removal out by flooding a roster.

**Replay.** An older roster cannot bring back a removed device: removals are never withdrawn inside a base, and only the phrase starts a new one.

The roster travels with profile updates, friend requests and server join requests, encrypted like them. A device whose sessions its contacts still refuse (one waiting to join, or one the phrase just brought back) sends its roster in the clear to its own inbox, its friends' DM rooms and its servers' rooms.

Identities from before 0.12 run on a legacy base, where the master key still admits a device, until their owner confirms the phrase once; the app asks at the first 0.12 start.

### 3.3 Device-to-Master Resolver

Clients maintain a resolver mapping each known device peer ID to its master. Its core invariant is that an **unknown peer ID resolves to itself**. A stranger, a single-device user, or a friend whose device list has not yet arrived is treated as their own identity. Note that this invariant, not an absence of indirection, is what makes single-device use safe: every install mints a distinct device key, so a device peer ID never equals its master even for a sole device, and the device→master path is therefore *always* exercised. Correctness rests entirely on the resolver's self-mapping fallback (and on per-person attribution collapsing to the master), not on any device==master special case. Multi-device behavior beyond that fallback activates only once a roster is ingested.

Two rules govern every cross-device interaction:

1. **Outbound targeted sends resolve master → device.** The relay reports device peer IDs, and only a device authenticates as a socket. Anything addressed to the bare master is in no room and is silently dropped, so a targeted send must expand the master to a concrete *online* device. **Content sends fan out** to all of a recipient's online devices (plus the sender's own siblings); **negotiated, key-paired connections** (a call, a WebRTC channel, a file stream) target exactly one device to avoid competing connections and answer glare.
2. **Inbound per-person attribution collapses device → master.** A message arriving from a device ID is filed and displayed under the person. Message-content signatures are made with the master key, so a message verifies across all of a person's devices regardless of which device sent it.

### 3.4 Device Linking and Snapshot Sync

A new, empty device pulls the full identity and database from an online existing device.

- **The code.** The existing device shows a ten-character code over an unambiguous alphabet. The relay sees the first six, which bring the two devices together (a RAM-only, one-shot rendezvous with a five-minute lifetime), and never sees the last four.
- **The channel.** The two devices run SPAKE2, a password-authenticated key exchange, on the four secret characters, bound to the six. A relay that pretends to be one side gets a single guess per code: a wrong guess ends the attempt and burns the code. Everything afterwards is AES-256-GCM under keys derived from the exchange, one per direction.
- **The approval.** The new device sends the device ID it will run as, with its name and platform. The existing device asks "Add this device?", and approving signs a vouch for exactly that device ID (§3.2). Nothing leaves the existing device before that.
- **Transfer reuses the encrypted-backup pipeline.** The existing device exports the bytes of a `.hollow` backup under a fresh random key, which travels inside the channel, and streams it through the relay. The relay carries ciphertext whose key it never sees. A receiver acknowledgement confirms receipt before the source reports success.
- **Stash-and-reboot import:** the receiver writes the blob, the key and its new device key to disk and restarts. On next launch, *before* the identity is loaded, it imports the backup, the identical path as a manual "restore from backup", and installs the device key the vouch names. In-place import while the node runs was deliberately rejected: it fought the live SQLCipher connection and a protection-mismatched throwaway identity, producing an unrecoverable load state. The rule is general: never swap identity or database in place while the node runs. Stash, restart, and import in the pre-boot window.

The backup carries no Olm account, no Olm sessions and no MLS signing identity, and the import clears them too, so a linked device starts with its own (§5). Reusing the source's MLS signature key would violate MLS's one-leaf-per-signature-key rule.

### 3.5 Sibling Synchronization and Backfill

A snapshot is a point-in-time copy; ongoing changes are reconciled continuously:

- **DM backfill:** a device that sends a DM while a sibling is offline leaves that sibling a copy in the relay's offline buffer, like any other recipient device; the sibling's phone registers its own siblings on the relay's no-wake list, so its owner's own message never raises a push. Anything the buffer did not deliver, the sibling pulls per-conversation on reconnect (gated on same-identity, so a friend can never trigger a whole-database pull). A subtler case is also handled: a friend can re-serve *your own* sends that are stranded on the friend's device because the originating sibling went offline before the receiving sibling came online.
- **Direction re-orientation:** a message-direction field received from a *friend* is sender-relative and is inverted at the receiver (used for both database insertion and signature-context reconstruction); a field received from a *sibling* (same identity) is not inverted. Signatures never involve device IDs, so they verify intact across devices provided the direction context is correct.
- **Server announcements:** server lifecycle changes converge a person's own siblings as well as offline members. Server creation announces to online siblings (which run a same-identity join fast path); on reconnect, a node re-announces all of its non-deleted servers when a sibling appears, and a manual per-device sync control re-drives the same onboarding primitives on demand.
- **Personal emote set:** a person's own custom emotes (the "Mine" set, not tied to any server) converge between their devices as a per-name last-writer-wins set. Each row carries a version stamp; a removal is a tombstone that is never collected, so a device that was away still learns of it. A device shares a one-row delta after every add or removal and its whole set whenever a sibling is verified or a manual sync is requested, and the receiver applies rows only from a sender proven to be the same identity. The message carries names and hashes only: image bytes are pulled through the asset rail (§10.7) from the person's own online devices, which are the only holders it asks.
- **Read state:** where a person's reading stands converges between their devices as a set of per-conversation read markers (a message ID plus its timestamp), shared one marker at a time as a pointer moves and as a whole set whenever a sibling is verified or a manual sync is requested. A receiver applies a marker only from a sender proven to be the same identity and only if it is later than its own; it never moves a pointer backwards, and it keeps the reported timestamp so a marker that arrives before the messages it covers still counts. Independently of any sync, a device treats its own newest message in a conversation as read up to that point, since being the last to speak is itself evidence of having read what came before; that rule alone keeps one device's posts from surfacing as unread on another.
- **Gap-resistant watermarks:** all catch-up sync (friend DMs, sibling backfill, channel history) is watermark-based: requests carry per-conversation or per-sender high-water timestamps. A plain high-watermark can permanently skip a message that was missed while a newer one arrived (for example, a delivery lost inside a reconnect window advances the watermark past the hole). Every request therefore asks from a fixed lookback window *below* its watermark, and receivers deduplicate the overlap by message ID, making redelivery idempotent. The lookback alone is not enough: a hole can sit far below the watermark, for instance when a sibling is away for hours and a friend's reply reaches it before the catch-up for its own earlier send does. So every request also carries a digest of what the requester already holds in a bounded window behind its watermark, one entry per day (the row count and an order-independent XOR of the message ID hashes). The responder recomputes the same digest over its own rows and re-serves every day that differs. The digest names no content, the window is capped so a peer cannot make a responder scan a whole history, and older clients ignore the field. A history larger than one batch arrives in pages, and each next page continues from where the previous page ended, never from the requester's newest row: a message that arrives during the catch-up would otherwise move the request past rows not yet served.
- **Deterministic delivery room:** a direct message is always routed into the recipient's *master-derived* DM room, not whichever room the sender happens to observe the recipient's device in at that instant. Two people can be co-present in several rooms at once during connection churn; picking an arbitrary one risks addressing a room the recipient has already left, which the relay would then buffer indefinitely against a room the recipient never re-enters: a silent, one-directional delivery hole. Because every device of the recipient is, by construction, a member of the single master-derived DM room, routing there makes online delivery deterministic while the relay's offline buffer still covers a recipient who is away.
- **A DM room only its two parties can name:** the room name is a keyed hash of the two master identities, keyed by an X25519 agreement between the two master keys. Every device of either person can compute it; nobody else can, including someone who knows both public identities, so no outsider can find the room, read its roster or watch its members come and go. A small-order key, which would agree on a publicly known value, names no room at all.

### 3.6 Removing a Device

Any current device can remove another; there is no primary device. A removal is a statement signed by the remover's own device key (§3.2), never by the master key.

- **Contacts stop at once:** every observer that folds the removal drops and erases its Olm sessions to the removed device, and the MLS coordinator removes its leaf (advancing the epoch). The person's master stays a member; only that device is cut off.
- **The removed device locks:** on learning its removal it shows a full-screen lock with the time it will erase itself, three days later, unless the recovery phrase is typed on it. Typing the phrase there starts a new base keeping the devices the person picks, which is also how a person takes the identity back from a stolen device: everything the thief holds or vouched for stops counting.
- **A restored backup waits:** a `.hollow` backup restored onto a new machine is not a member. It asks to join, the person's devices ask "A device wants to join" (Approve vouches, Refuse removes), and with no answer it joins at each observer seven days after that observer first saw the request. Typing the phrase on it lets it in at once. The phrase can also turn the wait off for the identity: the choice is part of the phrase's signed statement, so every contact and the relay honour it and nobody without the phrase can turn it back on.
- **Remote destroy:** needs the recovery phrase, or the permission the phrase signed for one device (§2.3).
- **Liveness, not just session state:** a person's roster accumulates dead "ghost" device IDs across re-link cycles (each re-link mints a fresh device key). Targeted fan-out therefore uses **room presence**, not session existence, as the liveness test: a message is fanned only to devices *currently in a room*. A ghost is in no room and is skipped, preventing phantom deliveries and stuck notification counts. Live devices that are merely offline still receive their copy via reconnect backfill (§3.5).

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

- **Epoch hints:** a member advertises its current epoch for a group alongside the first-contact synchronization exchange, at voice-channel join, and from the media heal ladder. A hint is advisory and deliberately powerless: a member that learns it may itself be behind sends a throttled probe to the group authority; a hint can never cause a group to be dropped (that would hand any peer a remote group-reset primitive).
- **Commit catch-up:** every member retains a short ring of recently broadcast commit messages per group. When a member learns from a hint that another is behind, exactly one of them answers, and *which* one is elected with the member that is behind excluded from the candidate set. The authority cannot serve itself: the server-wide group prefers the owner as its committer (§5.3), so an owner that missed an epoch it did not author would otherwise be nominated as its own rescuer while the member actually holding the newer epoch stood down as non-authoritative, and neither would act. Excluding the lagging peer makes the asker and the answerer compute the same single responder. A probe addressed to a specific member is answered by that member directly, without a second election, because the asker chose it from a view of the membership the answerer may not share. The elected responder replays the missed commits, in order, directly to the member that is behind. The member applies them through the same validated path as live commits: each is accepted only if it advances the group by exactly one epoch, so a forged or gapped replay is refused before it can trigger any destructive recovery. Catch-up replays material that was already broadcast to the whole room, so it discloses nothing new; the requester must be a current member.

Catch-up converges a stale member in one round trip **without generating new commits**. This matters because the fallback repair, removing and re-adding the member's leaves, advances the epoch for everyone and re-keys all media, so under churn repair-by-re-add can cascade. Re-add remains the fallback when the cache cannot bridge the gap.

Preserving that distinction requires the cheap path to be given the chance to run. A member that reconnects receives the relay's buffered traffic for the interval it was away as a single burst, and every frame of it is undecryptable at the member's stale epoch. Counting those as independent evidence of a broken group would trip the destructive repair within milliseconds of reconnecting, before any hint had been exchanged, discarding the catch-up already in flight. Sustained decryption failure is therefore measured over a minimum interval rather than by a bare count, and a group is never discarded while a probe it issued is still outstanding. A burst is one event.

### 5.4 Epoch and Key Rotation

Every membership change advances the MLS **epoch**, and each epoch derives fresh encryption keys. Forward secrecy has a margin: so that late messages still decrypt, a member keeps the secrets of the three previous epochs and up to 512 skipped message keys per sender before deleting them.

Recovery after a compromise is weaker than MLS allows. Members do not yet refresh their own leaf keys on a schedule, and the commits that only add members carry no path update, so someone who copies one member's MLS state keeps reading that server's traffic until that member's leaf is replaced: by a repair, a rejoin, or a removal commit the member makes itself. Taking that copy needs the member's unlocked database or malware on the device, which could read the same traffic live anyway. Scheduled self-updates are planned.

### 5.4.1 State Persistence Invariants

The MLS group state persisted to SQLCipher comprises the signature keypair, the credential, and the serialized group (ratchet tree, secret tree, and epoch). Three invariants keep group membership self-consistent across restarts and reconnections:

- **Persist on encrypt:** encrypting a message advances the sender's secret-tree generation. The group state is persisted immediately after every encrypt, so a restart cannot reuse a stale generation (which the receiver would reject as secret reuse).
- **Sync requests ride Olm.** After a reconnection a peer's MLS epoch may be stale, so synchronization requests and other coordination probes travel in the pairwise Olm channel rather than under MLS (§5.6). Every server-state change also goes to the members' devices under Olm next to its MLS broadcast, so a member at a skewed epoch still receives it.
- **Decryption failure triggers resync.** A peer that cannot decrypt a message it should be able to read treats this as evidence of a missed epoch and immediately synchronizes from the sender.

### 5.5 Targeted Peer-to-Peer Encryption

Server-context operations that target a specific peer (shard requests/responses, sync payloads, file transfers, voice SDP/ICE signaling) use **Olm + direct send** instead of MLS broadcast. This is O(1) per operation instead of O(n) broadcast, and avoids churning the MLS group ratchet for peer-to-peer work. MLS broadcast is reserved for channel messages that all members need to see.

### 5.6 Reconnection Caveat

After a WebSocket reconnection, a peer's MLS epoch may be stale. Messages that must work right after a reconnection (sync requests, shard coordination, voice channel state changes) therefore travel in the pairwise Olm channel to each device instead of under MLS.

None of them crosses the relay in the clear. Since 0.12 every relay frame is signed by the sending device and bound to its room and route, and every message type has a fixed lane: the relay may read routing data only, while content and state changes ride Olm, MLS, or, for meeting lobbies and Hollow Share, a key carried in the link. Public channels (§11.6) stay readable by design.

### 5.7 Conferences (Ad-Hoc MLS Groups)

Conferences are meetings between peers who may share no server and no prior relationship. A conference is a *virtual server*: a single identifier (`conf:` followed by 40 hex characters of a hash over the host's master ID and a random nonce, so the identifier itself names its host; carried only in URL fragments, never in server-visible paths) is the relay room code, the MLS group key, and the voice-channel context. Because conferences have no CRDT state, none of the server synchronization machinery applies to them.

**Admission is the cryptography.** The host of a meeting creates a fresh MLS group per session, so attendees of a past meeting cannot decrypt a future one. A prospective joiner enters the relay room and broadcasts a join request, sealed under the key the meeting link carries, with a fresh KeyPackage, a display name, an avatar *hash* (never image bytes), and optionally a salted hash of an access code. Until the host commits an MLS `add` for that KeyPackage, the joiner observes only ciphertext: the waiting room is a key-distribution boundary, not a UI convention. Removal from a meeting is an MLS `remove` commit, and the SFrame media key rotates away from the removed member before any user-interface teardown occurs.

Membership checks for conference voice signaling substitute the missing CRDT membership test with an MLS one: a voice-channel announcement is accepted only if its sender's device identifier appears in the conference group's leaf credential set, which only an admitted member can achieve.

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

- **Voice** (1:1 DM calls and server voice channels)
- **Camera video** in server voice channels
- **Screen sharing video** (1:1 DM screen share and server voice channel screen share)
- **Screen sharing audio** (platform-dependent transport; see §6.8)

Two media paths carry no SFrame layer today: the camera video of a 1:1 DM call, and voice audio that a participant forwards along the gossip tree of a large voice channel (§6.5). Both are still DTLS-SRTP from one participant to another, with the DTLS fingerprints exchanged over Olm or MLS, so the relay and TURN see only ciphertext; what they lack is the second, end-to-end layer that SFrame adds on every other path.

Every SFrame-protected track in a session or epoch uses the same key.

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

All images are auto-converted to Balanced WebP on send (~95% smaller than PNG/JPEG; similar quality). Configurable quality tiers: Lossless (100%), Balanced (50%), Small (30%).

**Location and camera metadata.** Photos and videos lose their location, camera and capture-time metadata before they leave the device, on every send path including vault uploads and large files sent through Hollow Share. The stripping works in place on the container (MP4 and MOV, WebM and MKV, AVI, HEIF and AVIF, JPEG, PNG, WebP) without decoding the media, so a video keeps its exact streams. A file of one of these types that cannot be parsed is refused with a message rather than sent as it is. Three cases keep their metadata: timed GPS tracks inside fragmented MP4, subtitle tracks, and TIFF or RAW images sent as plain files.

Image sends additionally embed a tiny (≤32 px) placeholder thumbnail inside the encrypted `FileHeader`; video sends embed a size-bounded poster frame the same way. Receivers enforce an independent size cap on this field before storing or displaying it. Because the thumbnail rides the same encrypted envelope as the rest of the file metadata, it reveals nothing to the relay.

### 7.4 Receiver Download Consent

Automatic downloading is a receiver-side policy (a global size threshold with per-conversation overrides; zero disables it). Enforcement is local: a receiver whose policy rejects a transfer keeps the encrypted metadata (so the message still renders, with the embedded thumbnail as its preview) but never stores the file bytes; an explicit manual request always overrides the policy for exactly the requested file.

As an optimization, a device may advertise its effective threshold for a conversation to its DM peers so that a compliant sender skips transmitting bytes the receiver would discard. This advertisement is a single size value carried in a plaintext control message (comparable to a typing indicator); it contains no content and is advisory only: enforcement never depends on it, and a sender that ignores it merely wastes its own bandwidth against the receiver's local policy. Voice messages, being small and conversational, are exempt from the policy on both sides.

### 7.5 Re-requests and the Negative Answer

A message can arrive long before its bytes: the metadata travels through the encrypted channel and is buffered for offline members, while the bytes are only ever pulled from a device that holds them. A receiver that lacks the bytes asks one holder at a time (every holder re-encrypts its copy under a fresh per-transfer key, so parallel answers could not be decrypted against one another), and keeps the request queued across reconnects: a holder that was unreachable when the request was made is asked the moment it appears.

A holder that is entitled to answer but cannot serve the bytes (it evicted them under its storage cap, cleared its downloads, or its retention policy removed them) says so explicitly instead of staying silent, so the requester can move to the next holder or report the true state. This negative answer is sent only after the same entitlement check the bytes themselves require, and only for a file the responder knows: a blocked, unknown or non-entitled requester receives silence either way, because answering "unknown" would let an outsider distinguish a device that holds a reference to a file from one that does not.

On the requesting side a negative answer is accepted only from a device this request was actually sent to; an unsolicited one changes nothing. A claim that the file expired under retention is verified against the requester's own copy of the server's retention setting and the file's own age before the requester marks its own record; otherwise it is treated as an ordinary miss. A member therefore cannot expire another member's file by asserting it. The user-facing result is a card that states which case applies (a request in flight, no reachable holder, a holder that no longer has the file, or a retention removal) rather than a download control that silently does nothing.

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
- **Sealed swarm control:** anyone who knows the root hash can join the room, the relay included, so the swarm's control traffic (the manifest, the have-maps and chunk requests) is sealed under a key derived from the link key and bound to the root hash. A peer without the link reads nothing and is answered by nobody; the manifest's file name, size and chunk hashes stay with the link's holders.
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

Because the manifest reaches every member of the server, a file posted in a restricted channel (one with its own MLS subgroup) never enters the Vault; it is delivered only to the members who can read that channel. A manifest is accepted only from the member it names as its creator, and never replaces another creator's manifest.

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

This provides deduplication, integrity verification, and location-independent addressing. Every member holds a Vault file's key, so authenticated decryption alone cannot tell the real file from bytes a member encrypted under the same key: the ciphertext rebuilt from shards must hash to the content ID before it is decrypted. A shard slot, once filled, is never overwritten by another sender.

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
| Channel messages | Configurable via CRDT | Permanent (default); a server may set a window |

Message retention is forward-only: changing it only affects messages created after the change, which prevents retroactive destruction of the history. File retention applies to every file older than the window. Both are per-server CRDT settings that only the server Owner may change, and only to the values the app offers (30, 90, 180 or 365 days, or permanent); every member treats any other value as "keep everything", since every member's own sweep deletes by it.

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

1. **Pool formation:** the initiator creates a relay room keyed by a random pool ID and broadcasts a `RecoveryHello` message containing their local shard inventory (manifest IDs + shard indices). Pool messages count only when they arrive in that room, and a transfer plan only from the elected coordinator and only towards pool members.

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
    author: String,         // master peer ID of the originator
    payload: CrdtPayload,   // the actual mutation
    auth: CrdtAuth,         // Ed25519 signature + public key binding the op to its author
}
```

Every operation carries an Ed25519 signature over its canonical form (`server_id`, the HLC, `author`, and `payload`) together with the signer's public key. The `author` is bound to that key, not to whoever relays the operation, so a member can legitimately forward another member's signed operation and the receiver still attributes it correctly.

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

**State snapshot on join.** Because operation logs are compacted past a threshold and cannot be trusted as a complete reconstruction source, a join is preceded by a **server-state snapshot** sent ahead of the operation-log delta (the WebSocket transport is FIFO). A joiner adopts the snapshot only while its own join is still pending, and clamps any future-dated timestamps inside it to the local clock-skew window so a poisoned register cannot outrank later honest writes; an established member never lets a peer overwrite its state. The operation deltas that follow are each signature-verified and merged on top. The snapshot is a convenience for the joiner alone, trusted only during that peer's own pending join; other members validate the joiner's later operations against their own state.

**Replicable deletion.** Server deletion is a replicable `ServerDeleted` tombstone operation rather than a one-shot command. The deleting node retains the server shell and operation log so it can serve the tombstone to members who were offline at deletion time; those members reconcile on reconnect through the same grow-only synchronization path. The tombstone is honored only if authored by the server owner, checked against the receiver's own role map.

### 10.6 Security

CRDT operations are validated on receipt, in order, before any state change:
- **Signature.** The operation carries an Ed25519 signature over its canonical form and the signer's public key. The receiver rejects it unless that key derives the claimed `author` and the signature verifies. Authorship is thus bound to the key, not to the transport sender, so forwarding another member's signed operation is legitimate while forging one is not. An unsigned operation is refused; there is no tolerance path.
- **Clock bound.** An operation whose timestamp is beyond the clock-skew window ahead of the receiver's own clock is refused, so a far-future timestamp cannot lock a last-write-wins register against every later honest write.
- Permission checks ensure the author has the required role for the operation type (e.g., only admins+ can change roles); creating a server is accepted only for a server that has no owner yet.
- A member's *own* voluntary departure (`MemberRemoved` where the removed peer equals the author) is always allowed, bypassing the kick-permission check.
- Unauthorized operations are rejected and logged.

**Multi-device note.** Membership entries are keyed by **master** identity (§3), while MLS leaves and transport peer IDs are device-keyed. All role and membership checks resolve a device ID to its master before comparing, so one person is one member regardless of device count, and an authorization check against a device ID never silently fails to match.

### 10.7 Custom Emotes and the Asset Rail (Content-Addressed Asset Replication)

Custom emotes are small images usable inline in messages and as reactions. Their design extends the CRDT model with a content-addressed asset layer, the *asset rail*, that also carries the other media kinds built on it (server banners, animated server icons, stickers, GIFs, avatar frames, and animated profile media), which differ only in their size bounds:

- **Metadata and bytes are separated.** The replicated CRDT entry (`EmojiAdded`) carries only a name and the SHA-256 hash of the processed image. The image bytes never ride CRDT operations, message envelopes, or relay buffers.
- **Bytes replicate on demand, peer-to-peer.** A client that must render an unknown hash requests it from a single source: the message sender's devices (direct messages) or one online server member (channels). Any member holding the bytes can serve them: content addressing makes every copy equally trustworthy, because the receiver recomputes the hash (and enforces format and size bounds) before caching. A tampered or substituted image simply fails verification and is discarded.
- **Only requested bytes are accepted, at the requester's own bounds.** A receiver records, at request time, which hashes it asked for and what kind of asset each was requested *as*; an arriving bundle is accepted only for those hashes, with the size ceiling taken from the locally recorded kind. A peer can neither push unsolicited blobs into another client's store nor smuggle a large blob past a small kind's bound; the sender has no say in which limit applies. Reply bundles are additionally bounded in total size on the serving side. A missing asset remains a standing request until its bytes arrive: the requester re-asks reachable holders as they appear, one at a time under a per-connection bound, and a holder that lacks the bytes says so, so a token that arrived while its holder was away renders once any holder is online again. A negative answer, or refused bytes, moves the request to the next holder only when it comes from the holder that was asked.
- **Wire form degrades gracefully.** An emote appears in message text as a compact token containing its name and hash; a client that predates the feature renders the token as text, and reaction strings accept either a short Unicode emoji or a well-formed token, and nothing else.
- **Third-party catalogs are authoring-time only.** Assets may be imported from an external catalog (FrankerFaceZ for emotes, KLIPY for GIFs and stickers), but each catalog is browsed exclusively through a Hollow-operated caching proxy, and only by the person actively choosing an asset. Search text travels in the request body (never a URL, so it cannot appear in standard access logs), carries no Hollow identity, and is cached anonymously server-side; the proxy's requests to the catalog provider carry a random single-use identifier, so the provider observes an unlinkable query stream originating from the proxy, never a user's network address or search history. The proxy source is published in the public repository, making these properties auditable. At import the image is re-encoded and content-addressed; from then on it replicates purely peer-to-peer. **A message recipient never makes an HTTP request to render an emote or GIF.** The external service learns nothing about who views which assets, or that a conversation exists at all, and cannot alter an asset after import (the hash pins the bytes). The residual exposure sits at the proxy's own hosting layer rather than at the catalog provider: cached media is addressed by asset identifier in the request path, so a server-level access log can associate a network address with which assets it previewed or imported. Search text is not exposed this way, being carried in the request body. A user who considers that residue unacceptable can point the client at a proxy of their own: the endpoint is a single configurable base URL, and the proxy source is published. A second, distinct opt-in exists for GIF search: a user may supply their own catalog credential, after which the client queries the provider directly and the proxy is bypassed entirely. This is an exchange rather than an improvement, and the interface says so plainly: the provider then observes that user's own network address and every query they make under one durable credential, which is precisely the correlation the shared proxy prevents. It is off by default, and the invariant above is unaffected in either configuration: the catalog is still reached only at authoring time, by the person choosing the asset, and a message recipient still makes no HTTP request to render one. Media the client will fetch in this mode is constrained to an explicit, user-visible list of permitted hosts, so a compromised or altered catalog response cannot redirect the client to an arbitrary origin. The client holds browsed previews in memory for the session only and never writes them to disk, so a device retains no record of what was searched or previewed beyond the assets actually imported.

Server emote sets are capped and gated by a dedicated permission bit (§11.2); names and hashes are grammar-validated at every ingest path so the emote registry cannot be used to smuggle markup or oversized data into clients. Server sticker sets ride the same permission bit, the same caps-at-both-ends rule, and the same validation, including their pixel dimensions, since a sticker whose dimensions fall outside the token grammar could not be rendered by any client and therefore has no reason to replicate. A sticker's registry key is its content hash rather than a name: unlike an emote, which is typed as `:name:` and so requires a unique name, a sticker is only ever chosen visually, so its name is a non-unique label and its identity is its bytes.

**Server banners** follow the same separation: the replicated server state carries only the banner's hash (a `MANAGE_SERVER`-gated setting), and members pull the bytes over the rail like any other asset. The one place a banner is shown to non-members, the pre-join public-server browse, receives a small, still, size-bounded thumbnail generated from the banner, never the full asset, and the receiving client independently enforces that bound before display.

**Animated server icons** apply the split retroactively to a field that predates the rail: the small still icon remains inline in replicated server state (older clients and pre-join surfaces keep working unchanged), while an animated upload additionally publishes only the hash of a size-bounded animated variant, whose bytes ride the rail under the same requested-only, receiver-verified rules. Animation never rides state snapshots, sync frames, or pre-join wire paths.

**Avatar frames** extend the same separation to a *personal* profile, where the pressure runs the other way. A profile update is pushed to everyone who synchronises with its owner, so any decoration carried inline is paid for by every recipient whether or not they ever look at it. The profile therefore carries only a short identifier: either a procedurally drawn built-in, which costs nothing on the wire, or the hash of an uploaded image whose bytes travel the rail on demand and are the first thing evicted under a client's own cache bound. The identifier is validated on ingest against exactly three permitted shapes, and an unrecognised value is treated as absent rather than as a clear, so a malformed field from a future client cannot erase what a recipient already holds. That validation is not cosmetic: the field is whatever the sender put there, and it is used to key a network request, so an unconstrained string would let a sender direct a recipient's fetches.

**Animated avatars and banners follow the frame's reasoning to its conclusion.** They were the
last profile media whose bytes travelled inline, and they are the costliest case of the pressure
described above: an animation is an order of magnitude larger than the still it replaces, and it
was pushed in full to every peer on every reconnection, whether or not that peer ever rendered
it. The profile now carries a *still* image and, separately, the hash of an animated variant. The
still is what a recipient sees by default and what a client predating the split still receives, so
nothing degrades to a blank; the animation travels the rail on demand and is evictable like any
other asset, so a recipient who never opens a profile card never pays for its animation, and one
who evicts it loses motion rather than a face. The hash is validated on ingest exactly as the
frame identifier is, for the same reason: the sender chooses it and it keys a network request.
Since 0.12 the frame and both animation hashes sit inside the profile signature with every other
field, so nobody but the profile's owner can swap one decoration for another.

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
- Channel visibility (restricted text channels): a text channel with a restricted tier *or* a label gate is encrypted under its own MLS subgroup (see §5.2). Only members passing the full visibility predicate (tier, label gate, or unexpired grant) are subgroup members and hold the key; everyone else never receives a decryptable copy. This is a confidentiality boundary, not a UI filter. Subgroup membership is re-reconciled on every event that changes who qualifies, including label assignment/removal/deletion, grant issuance/revocation, and grant expiry. The same predicate gates every path that serves stored channel content or replicates its files (history sync and sync probes, file requests, small-server full replication): a peer asks the channel ladder, membership first, before answering, because the subgroup covers live frames and backfill is a separate path that used to answer any member of the server.
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
- **No byte quotas.** An earlier design metered a fixed daily volume per IP address and disconnected on exhaustion. It was removed: volume alone cannot distinguish a long screen share from abuse, a fixed cap punishes exactly the people who use the service most, and a shared address (a household, a campus) exhausted it collectively. What the relay protects against instead is contention, and it does so below the application: the host shapes its egress with a per-destination-host fair queue (CAKE, `dual-dsthost`, DSCP ignored). An idle line is free to whoever needs it; a saturated line is shared equally per client host, with the heaviest flows yielding first. No connection is ever closed for the amount of data it moves, and nothing is counted or recorded.
- **Fair-share offline-buffer eviction:** the store-and-forward buffer (§13) is capped per recipient, which bounds memory but not *who* consumes it: absent further structure, one peer could fill a stranger's buffer with junk until every genuine message waiting there had been evicted. When a cap is reached the relay therefore discards the oldest frame belonging to whichever sender currently occupies the most slots, rather than the globally oldest, so a flooder can only ever displace its own frames. This is deliberately a *reprioritisation* rather than a limit: a per-sender quota or a per-minute cap would silently discard legitimate traffic (a reconnection burst addresses every offline contact at once, and one channel post legitimately emits one frame per offline member), which is the same failure mode that caused application-level rate limiting to be removed.
- **Hard backpressure:** 64 MB per connection (uWebSockets built-in). Catches dead connections without interfering with legitimate traffic.
- **Text frame cap:** 1 MB. Oversized text frames are silently dropped.
- **Binary frame cap:** 64 MB (uWebSockets `maxPayloadLength`). Connections exceeding this are closed.
- **DoS protection:** Ed25519 authentication (plus key revocation on a relay that enables access keys, §12.8). Only authenticated peers can send messages. Per-IP connection caps (simultaneous + new-per-minute) use the same /64-aggregated IPv6 keying.
- **Room membership enforcement:** every routing handler verifies that the *sender* belongs to the room it addresses before forwarding, and rewrites the routing header to carry the authenticated peer ID, so a room code cannot be used as a capability to inject into or read from a room one has not joined. Non-members' frames are silently dropped. Peer discovery is likewise restricted to rooms the requester is in; otherwise a room code alone would yield a membership roster, which matters because DM room codes are a deterministic function of the two participants' identities.

### 12.6 TURN Credential Management

For peers behind symmetric NATs, the relay provides time-limited TURN credentials:

- HMAC-SHA1 credentials with 1-hour TTL.
- Delivered **only** over the client's authenticated relay WebSocket (a `get_turn_credentials` request on the live connection). Unauthenticated and guest connections are refused, so relay bandwidth cannot be farmed anonymously. The former unauthenticated HTTP endpoint has been removed outright rather than deprecated: an HTTP request carries no caller identity to bind a credential to, so any such endpoint is farmable by construction.
- The TURN server (coturn) validates credentials against the same shared secret.
- **Peer lock:** the TURN server may only exchange packets with the relay host's own addresses, i.e. with another authenticated client's allocation on the same server. A TURN allocation is otherwise a general-purpose UDP (and, per RFC 6062, TCP) proxy to any host on the internet; with the lock, `CreatePermission` and `ChannelBind` toward any other address fail with 403 and TCP relaying is disabled outright. Calls lose nothing: when one side needs TURN, ICE settles on the relay-to-relay candidate pair, which carries exactly the bytes a relay-to-reflexive pair would have. The only traffic the TURN server can carry is Hollow client to Hollow client.
- Clients request fresh credentials on every relay (re)connection and refresh every 50 minutes, so retries inherit the connection's own reconnect machinery.

### 12.7 What the Relay Sees

| Data | Visible to Relay |
|------|-----------------|
| Peer IDs (in memory) | Yes (not logged to disk) |
| Room membership (in memory) | Yes (not logged to disk). Room codes are opaque, but the relay sees which device IDs share a room, so it can group a person's devices and see which devices share a conversation |
| Topic subscriptions (in memory) | Yes: the relay knows which channel topics each peer subscribes to within a room (not logged to disk) |
| Rosters (in memory) | Yes: each identity's roster of signed device statements, which decides who may read its inbox (§3.2) |
| Push registrations and preferences (in memory) | Yes, for phones: the push token and the notification settings that differ from the default (server and channel levels, the device IDs of muted DM senders), §13.3 |
| Parked frames (in memory) | Ciphertext only: offline buffers and channel rings (§12.13), destruction orders waiting for a device (§2.3), join requests sealed to a server's join key |
| Session state (in memory) | Yes, per connected or recently dropped device: a random session identifier, two frame counters, the device's rooms and subscriptions, whether its app is on screen, and for up to 120 s after a drop the frames it has not acknowledged (ciphertext only, frames the relay forwards anyway), §12.15 |
| Connection timestamps | **No** (relay logging is disabled; volatile journal with 1h retention) |
| Message contents | **No** (encrypted) |
| Encryption keys | **No** |
| File contents | **No** (encrypted) |
| Message signatures | **No** (inside encrypted envelope) |
| User profiles | **No** (encrypted) |
| Voice/video media | **No**: direct by default; when TURN or the forwarder carries it, only ciphertext (§6.4) |
| File transfer bytes | Ciphertext only, when a transfer falls back to the relay stream (§7.2) |
| IP addresses | In memory only, for connection limits; never logged (TURN logging disabled) |
| User reports | Partially: per-target abuse-category **counts** are persisted (§12.14); the reporter's identity is never written in readable form, only inside a keyed fingerprint |

Everything the relay holds in memory is carried across a relay software update in memory and is gone after a reboot of the machine (§12.13).

### 12.8 Access Keys (Optional, for Self-Hosted Relays)

The relay supports optional access keys for an operator who wants to restrict who may connect to their own relay. The official public relay runs with them disabled and is open to everyone.

- Keys are stored in a `keys.json` file loaded at startup. The system can be enabled or disabled via a toggle.
- Keys are validated during WebSocket authentication. An unknown key is rejected; one key admits up to five sockets at once, so a person's linked devices can share it.
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
- **Custom relay:** Clients can select an alternative relay address at first launch or in settings. The address is a host name, a bare IP address, or either with a port; the WebSocket and STUN URLs are derived from it, and the TURN URIs are handed out by the relay itself, built from the address the relay was started with, so a self-hosted relay always points its clients at its own TURN server.
- **Persistence:** The selected relay address is stored in the local encrypted database. A saved relay list allows switching between known relays.
- **Capability advertisement:** A relay answers an unauthenticated `/relay-status` query with what it offers: whether an access key is required, its version, whether it can issue TURN credentials, and whether a media forwarder is configured. A client reads it before connecting and adapts: it labels a relay without TURN, refuses to start a relayed-only call on it, and names the cause when a call fails for lack of a relayed path. A relay too old to answer the newer fields is treated as unknown, never as absent.
- **Docker deployment:** The relay can be self-hosted via Docker with automated TLS (Let's Encrypt, including certificates for bare IP addresses and DNS-validated certificates for free dynamic-DNS names) and an optional coturn TURN server. The relay reloads a renewed certificate in place; renewal never restarts it. A relay requires a publicly trusted certificate: clients reject self-signed ones.

Each relay is an island. Two clients on different relays cannot reach each other, and relays never talk to each other. An invite therefore names its relay alongside the server, room or conference it points to, stamped by the inviter's client from the relay it is connected to. A client that receives an invite for a different relay asks the user whether to switch, states which relay it would move to, and never switches silently: a link that could move someone onto a stranger's relay unasked would be a phishing shape, since that relay observes IP addresses, timing and room membership even though it can read nothing. Older links carry no relay and are opened on the client's current one.

Since the relay is a zero-knowledge pipe, switching relays is transparent to the protocol: the same identity, encryption, and CRDT synchronization work identically regardless of which relay is used. A censorious or unavailable relay can be replaced without any protocol changes. What a self-hosted relay does not provide is documented rather than emulated: push wake-ups for mobile clients (they require platform push credentials held only by the official deployment), the media forwarder, and buffer persistence across a relay restart.

### 12.12 Temporary Nicknames

To allow users to send friend requests without sharing a 64-character peer ID, the relay supports **ephemeral, relay-scoped nicknames**:

- A nickname (lowercase `a-z`, `0-9`, `_`; 3–20 characters) is claimed via a relay text command and held in a RAM-only `nickname → peer_id` map. Multi-device identities authenticate to the relay as a per-device id while friend requests must reach the master's inbox, so the claim carries the claimer's **master identity** together with the master key's signature over the nickname, the claiming device, the master and a timestamp. The relay binds the nickname only when that signature verifies and the timestamp is within five minutes of its clock, and hands the signed claim back on resolve.
- The resolving client verifies the signature again and refuses a claim older than eleven minutes. It never feeds the result into its device-to-master mappings, and it shows the person the identity the nickname names before any request is sent, since a nickname changes hands.
- Nicknames are **never persisted**. The relay releases one when the claiming socket closes and ten minutes after the claim. The claiming client holds the nickname for the rest of its session and claims it again, freshly signed, on every reconnect and before the ten minutes end, until its user releases it, so a dropped connection does not silently take the handle away.
- A friend request resolves a nickname to the master identity in one step, then proceeds via the normal friend-request flow.

Because the mapping lives only in relay memory for the duration of a connection, the relay holds no long-term directory of human-readable handles. The underlying identity remains the Ed25519 peer ID; the nickname is a transient convenience layer.

### 12.13 Message-Availability Cache (Offline Delivery)

A fully peer-served history model has a structural gap: if Alice sends a message and disconnects before Bob comes online, no online party holds the message, and Bob waits until Alice (or another member) returns. To close this gap the relay may **retain, for a bounded time, the same end-to-end-encrypted frames it already routes**, and replay them to a returning recipient.

The design invariant is **availability, not authority**. The relay buffers only ciphertext bytes it would have forwarded anyway; the recipient verifies every Ed25519 signature, deduplicates by message ID, and merges through the same CRDT/sync logic as peer-served data. A replayed MLS frame the recipient already decrypted before reconnecting is refused by its own secret tree as a consumed generation and discarded silently; such a replay is never evidence of a broken group and triggers no recovery. The relay therefore cannot forge (signatures), cannot read (Olm/MLS encryption), and cannot become a source of truth. If it withholds or loses data, peer-to-peer synchronization remains the correctness floor. All buffers are RAM-only by design: a reboot or power-off leaves no recoverable artifact, and nothing about the cache is logged.

**Survival across a relay software update.** A restart of the relay *service* does not empty the buffers. On shutdown the relay serialises the offline queues, the channel rings with their retention state, the recipients' retention registrations, and the push tokens and preferences of §13 into an anonymous memory file, and hands the descriptor to the service manager, which holds it in its own memory across the restart and passes it back to the replacement process. The replacement rebuilds the buffers, releases the descriptor, expires whatever aged out during the gap, and only then accepts connections. No file system is involved at any point; a full stop of the service, a reboot, or a power loss discards everything. Two host properties keep "never on disk" literal rather than nominal: the relay host runs without swap, so buffer memory can never be paged out, and the relay process is forbidden from writing a core dump, so a crash cannot spill its heap. Registrations that only a *connected* client re-sends (nickname claims, link codes, room membership) are deliberately not carried; they belong to sockets that no longer exist.

**Containment on the relay host.** The relay runs under an account of its own that cannot become root, inside a systemd sandbox. It sees the file system read-only apart from its report counter, cannot see home directories or other processes, holds only the capability to listen on port 443, and is refused the system calls a network server never makes; `systemd-analyze security` rates its exposure 1.4 on a scale of 0 to 10, where lower is safer. Its secrets reach it from files only root can read, never through the service manager's environment settings, which every local account can query. The push sender, the media forwarder and the TURN server run the same way, each under its own account, so a memory-safety bug in one of them yields that one service's view of the host, never root and never another service's credentials. The memory-file handoff above works unchanged inside the sandbox. All four services log only to the in-memory journal, and neither the host's system logger nor its firewall writes a line of theirs to disk.

Two tiers exist:

- **Direct messages:** a per-device queue (enabled by default; the recipient controls an on/off toggle and a retention window of 1–7 days, registered per connection). Buffered entries are text and file *metadata* only, never file bytes, plus a small bounded set of inlined image previews. Delivered entries are deleted on replay.
- **Server channels:** one ciphertext ring per channel (bounded per-channel message and byte caps), populated from the channel's topic-routed frames and replayed on request to any member of the room. Public channels, whose messages are plaintext room broadcasts readable by guests, emit the same signed bytes as a topic frame as well, so they enter the ring like encrypted channels do; a member that receives both copies keeps one, deduplicating by message id. Deletion is by retention expiry, never by delivery, because "all members received it" is unknowable to a relay that refuses to learn server membership. Enabled per server via a CRDT-replicated setting (default on; the server owner can disable it).

A global byte budget bounds total buffer memory with oldest-first eviction. Because MLS enforces forward secrecy, replayed channel ciphertext is decryptable only within a bounded window: Hollow configures its MLS groups with an enlarged out-of-order tolerance and a small number of retained past-epoch secrets, deliberately trading a bounded amount of forward secrecy for offline deliverability. Frames outside that window are recovered through ordinary peer synchronization instead.

A third use of the same buffer closes the friend-request gap. A friend request to a stranger is addressed to a master identity, not a device, and no socket authenticates as a master; the relay therefore holds such a request in the recipient master's inbox buffer and replays it only to a device that **proves ownership of that identity**. The proof is the device's own roster (§3), presented when it joins its `inbox:{master}` room. The relay keeps one roster per identity, folds every roster shown for it into that one with the same rules every client uses, and lets a device own the inbox only while it is a member of the result. A removal or a newer recovery, once any device has shown it, therefore stays, the first recovery key the relay holds is pinned, and a change that drops a member closes the inbox to it at once. Holding the master key, from a backup or a stolen device, opens nothing once the phrase is the identity's root. Only for a member does the relay replay the buffered requests, and, unlike the delete-on-replay direct-message tier, it retains them until expiry so every device of the identity collects the request independently; the recipient deduplicates on its local friend record. The request itself carries the sender's single-use Olm prekey and master-signed profile as end-to-end material the relay cannot use, so a first friendship and its first messages can complete even when the two parties are never online at the same moment. As everywhere else the property is availability, not authority: the buffered request is signed and verified end to end, and its absence degrades only to the pre-existing behaviour of requiring both parties online at once.

While a request is pending, each side sees the other's name, signed by its master, and a small copy of its avatar (96 pixels, at most 8 KiB): the request carries the requester's, and the target leaves its own in the requester's inbox. Both are sealed under a key only the two identities can derive. The receiver re-encodes the thumbnail before showing it and keeps it only on the row of that request; the full profile follows once the request is accepted.

The answer travels the same road. A decline is deposited into the requester's own inbox buffer under the same ownership-proof replay, so the requester learns of it on its next boot with no overlap and stops re-presenting the request. Because that answer can arrive late, out of order, or replayed for the whole retention window, it is bound to the request it answers: it carries the request's timestamp and the decliner's master-signed device list, the requester verifies the list and attributes the answer to the master it names (never to a bare device id, which a peer that has never met the decliner cannot resolve), and it acts only on the still-pending request that timestamp identifies. A replayed answer can therefore never remove a friendship formed afterwards, nor a request made after the decline; and a decliner that sees the same request re-presented answers it again, so the outcome converges even when the relay's copy of the answer has expired.

An acceptance is bound the same way. It carries the timestamp of the request it answers, and the requester refuses an acceptance that names an older request than the one it currently holds, so a copy the relay parked for a room the requester had already left, or replayed from its inbox buffer, cannot turn a later request into a friendship nobody consented to. A removal leaves a local tombstone, and an acceptance that answers no open request is refused whether or not it carries a timestamp, which closes the window between two legitimate copies of the same acceptance and a removal that lands between them. Acceptances travel through the pair's deterministic direct-message room rather than whichever shared room the device was last seen in, so a copy for a device that is absent parks under that room alone. An acceptance without a timestamp comes from an older client and is honoured while a request is open. An acceptance can still be lost on the way, for instance into a connection that had already died while the relay still listed it. The request itself stays in the accepter's inbox buffer, and every time that buffer is replayed to the accepter after a reconnect, the accepter answers it again, once per connection, through the direct-message room, where the relay parks the fresh acceptance until the requester returns; the two never have to be online at the same moment for the friendship to complete.

A fourth use of the same buffer closes the empty-server join gap. Joining a server is a request that needs an answer, and a server whose members are all offline has no answerer; previously the request timed out and the user had to guess when to retry. Now the joiner's client parks the request instead: it persists the pending join locally, deposits the request into a dedicated topic ring on the server's own room (the same per-room ring mechanism that buffers channel ciphertext, so no new relay state or semantics exist), and keeps a "pending" tile until a member returns. The first member back reads the ring in its normal catch-up and serves the request through the identical admission path a live request takes, applying the server's rules as they stand at that moment (ban list, privacy, member cap, consent gates), never a verdict stored at request time. Its answer, the state snapshot and operation log for an admission or the reason for a refusal, is a targeted frame into the server room addressed to the joiner's device; the relay buffers it under that device, and the joiner collects it on its next boot because the persisted pending join rejoins the room. Every verdict is also written back into the join ring, bound to a per-request nonce, so a member who returns later reads the request together with its resolution and neither re-admits nor re-refuses it, and a late member converges on the new membership from the resolution itself.

Two properties bound what this changes. First, admission here is the CRDT membership; the MLS leaf that lets the new member read channel ciphertext still forms on first co-presence through the ordinary KeyPackage exchange, and the client states that plainly ("waiting for a member to finish setup") rather than pretending otherwise. Second, the ring holds only what the relay already routed in plaintext for a live join (the joiner's identifiers and its master-signed device list, which is also how a member that never met the joiner attributes the request cryptographically rather than by presence), and the resolution carries no more than the admission snapshot already reveals. Anyone holding the room's invite can read the ring for its retention window and learn who asked to join and the outcome, as opaque identifiers; the member list itself never enters it. The one identity link a join can carry, a Twitch verification proof, is stripped from the parked copy, so a parked join to a Twitch-gated server waits for co-presence rather than publishing an account name into a shared ring.

### 12.14 User Blocking and Reporting

Abuse handling follows Hollow's self-protection model: users defend themselves locally, and the network learns as little as possible in the process.

**Blocking is a purely local, receiver-side decision.** A block is keyed on the offender's *master* identity (so switching devices does not evade it) and enforced at message ingest, before anything is stored, displayed, or notified: friend requests, direct messages (live, sync backfill, and offline-cache replay), file transfers, call invitations, and data-channel offers from a blocked identity are dropped. The blocked party receives no signal that they are blocked, and no other party, including the relay, learns that a block exists. Server channel messages from a blocked member remain in the local store but are hidden from display, so unblocking restores history losslessly.

**Reporting is the single deliberate exception to the relay's persist-nothing rule.** A client may file a report against a peer under a fixed category set (spam, harassment, illegal content, impersonation) over its authenticated relay connection. The relay persists exactly two things: per-target **counts** per category, and a keyed one-way fingerprint of (reporter, target, category) used solely to enforce one report per reporter per target per category. The fingerprint is BLAKE2b keyed with a 32-byte secret the relay generates on first start and keeps in its own owner-only file, so the reports file alone cannot confirm a guessed "A reported B" (an unkeyed hash of public peer IDs could); only the relay holding the key can test such a guess. The relay necessarily sees a report arrive on the reporter's authenticated connection, but the reporter's identity never appears on disk in readable form or in logs, no message content is attached (the relay could not read it anyway), and the resulting file supports exactly one operator action: identifying identities with abnormal report volumes for possible relay-access restriction. Reports carry no in-protocol authority: they cannot delete content, remove members, or affect any server's CRDT state.

### 12.15 Resumable Sessions

A WebSocket connection to the relay is fragile on real networks: a phone's operating system closes it shortly after the app leaves the screen, a laptop sleeps, a train enters a tunnel, Wi-Fi hands over to cellular. When the connection was the session, every such moment lost the frames written into the dying socket in either direction and made the device rejoin every room from scratch. Hollow separates the two, following the pattern of Discord's gateway resume and XMPP stream management (XEP-0198): **a session outlives its socket.**

**What a session is.** On login a device may ask for a session. The relay then mints a random 128-bit session identifier and keeps, beside the device's rooms and topic subscriptions, two counters: the stream frames it has sent to the device and those it has received from it. Each side acknowledges the other's count in batches, and the relay keeps every frame it sent until the device acknowledges it. When the socket dies, the session enters a **grace period of 120 seconds** (30 to 600 on a self-hosted relay): frames addressed to the device keep arriving in its session and are kept there. A device that reconnects within the window resumes: it signs in again and names its session and how many frames it received, the relay replays exactly what the device did not get, in order, and the device resends what the relay did not acknowledge. Nothing is rejoined and nothing is resubscribed. A receiver that already holds a resent frame drops it by its nonce or message identifier, so a replay is never a duplicate. When resume is impossible (the window passed, or the relay restarted without its state), the relay hands the session's undelivered direct messages to the message-availability cache (§12.13) and the device runs its ordinary catch-up synchronization; the device itself re-asks any frame its own per-sender rate limit had to drop.

**What the relay learns.** Nothing it did not hold already: which device is connected and which rooms it is in. The frames kept for a session are the same sealed frames the relay forwards, readable by nobody but their recipients. The session identifier, the counters and the kept frames live only in memory, ride a relay software update the same way as the buffers of §12.13 (in which case every device resumes rather than reconnects, after a short spread-out hint to come back), and nothing about sessions is ever logged.

**Why a stolen session identifier is useless.** A resume always repeats the full login: the device signs, with its own device key, the relay's domain, a fresh challenge, every login option, the session identifier and its count. A relay answers an unknown identifier and another device's identifier identically, so the reply reveals nothing about which sessions exist. What may have changed while a device was away is checked again on resume rather than carried over: a destruction order waiting for the device is delivered first, a server room whose admission proof changed meanwhile (after a kick, ban or demotion) is dropped until the device proves itself again, and an inbox the relay's roster fold no longer lets the device own is refused.

**Bounded and fair.** Each session keeps at most 8 MiB and 4,096 frames; all sessions share a fixed pool apart from the offline buffers. When a session's store is full, the frames of the sender holding the most are dropped first and replaced by a counted gap marker, so a flood of one sender cannot push out anyone else's frames, and the device repairs a gap by synchronization. A session in grace keeps its connection slot under the per-address limits, and the session table is capped with the same heaviest-share eviction as every other table a stranger can fill (§12.5).

**Liveness and recovery.** Each client sends a heartbeat every 15 seconds and treats a connection as dead after 10 seconds with no traffic, rather than the minute or two a silent TCP connection can otherwise linger. Returning to the app, a network change and waking from sleep all probe the connection at once; a probe that goes unanswered within a second opens a new socket beside the old one and resumes on whichever answers first. When a better network appears while the old one still works, the session moves to a socket on the new network before the old path breaks.

**Phones.** A phone closes its connection about ten seconds after the app leaves the screen and lets push notifications (§13) wake it; returning to the app resumes the session in about one round trip. **Presence follows the screen, delivery follows the session:** a phone that leaves the screen tells the relay so, and the relay shows it offline to everyone at once, while every frame still reaches its session and a push still wakes it. A phone in a call, a voice channel or a meeting stays visible until that ends. The phone itself makes no MLS commit while it is away or disconnected (§5), because the other devices already count it offline and choose another committer.

---

## 13. Push Notifications (Mobile)

Mobile operating systems terminate background processes, so a Hollow client cannot hold a persistent WebSocket while the app is closed. Something the operating system keeps alive must therefore carry a wake signal: Firebase Cloud Messaging on Android, the Apple Push Notification service on iOS, or, on Android, a UnifiedPush distributor the user installed and chose (§13.7). Each of these is a party Hollow does not trust. The entire push design exists to route a wake through them **without ever exposing message content to those parties.**

### 13.1 The Core Privacy Guarantee

**The push payload carries zero message content.** It is exactly `{type: "wake", sender: <peer_id>}` for a DM, or `{type: "channel_wake", sender, server, channel, mention}` for a channel message. Message ciphertext never rides the push: the message is fetched from Hollow's relay after the wake.

Consequently:

- **What Apple/Google learn:** that *some* message arrived for a device token, plus the sender's device peer ID (a `12D3KooW…` identifier, not a human name) and, for channels, the server and channel IDs and a single mention bit. They never see message text or size. These IDs are random, but they are stable: a provider that sees the same server ID arrive at many phones learns that those phones share a server, and the same sender ID together with reply timing lets it connect device IDs to the accounts it already knows. Push timing is coarsened by debouncing (§13.3). UnifiedPush already encrypts this block to the device (§13.7); doing the same for Firebase and APNs is planned.
- **How E2EE is preserved:** the message *content* travels exclusively over Hollow's own existing E2EE channels (Olm for DMs, MLS for channels) between the client and Hollow's own relay, and is decrypted **on-device**. Apple and Google are pure wake-up couriers, categorically outside the content path.

A small push-relay sidecar service holds the Firebase/APNs credentials and emits only this wake payload; the relay itself never contacts a push service with content.

### 13.2 Direct Message Push Flow

The relay is normally stateless. Push delivery requires one concession: when a DM's recipient is **offline**, the relay briefly buffers the **ciphertext** in RAM (a per-peer cap of 100 text messages and 1 image, 24-hour TTL, swept periodically) so the woken client can fetch the *triggering* message: the relay is a dumb pipe, and without buffering the message would already be gone by the time the client wakes seconds later. This buffer is latency glue, not durability; the distributed sync layer (§3.5, §10) owns durability. The buffered bytes are ciphertext only. The same mechanism, with larger user-controlled caps and retention, backs the message-availability cache (§12.13).

When the woken client later joins the DM room, the relay replays all buffered frames. The client runs a minimal **fetch node** that connects in a special fetch mode (excluded from member lists, emits no presence; *waking via push does not show the user as online*), pulls the replayed ciphertext, decrypts it with the existing Olm session, persists it, and posts a populated notification. A phone that left the screen only moments ago may still hold a resumable session (§12.15); its direct messages then wait in that session rather than in the buffer, so the fetch connection is handed the ones for the room it joins, once per connection, and they stay in the session for the resume. Each frame is the same sealed ciphertext either way.

**Offline images.** An image DM is normally two messages plus a separate byte stream, and the byte stream is never sent to an offline peer. For offline delivery, the sender inlines the AES-encrypted image bytes into the (Olm-encrypted) file header and sends it as a dedicated direct-image frame to the DM room; the fetch node decrypts the bytes, writes the file, and inserts the message row. A caption is sent exactly once as a separate encrypted text frame, never via the normal send path (which would advance and persist the Olm ratchet for a message the offline peer never receives, creating a permanent decryption gap).

### 13.3 Channel Message Push Flow

The same privacy invariants extend to server channels. After the normal room broadcast, the **sender**, the only party holding the plaintext and the membership list, selects the offline members from its own CRDT state and sends each one a `0x09` channel-direct frame whose payload is **the same MLS (or public-channel) ciphertext the room broadcast carried**. The relay never learns server membership; it only buffers and forwards. The sender also computes a per-target mention bit (an `@everyone`, a name/nickname mention, or a reply to that member) so mentions can be prioritized.

The relay buffers offline channel messages under a separate per-peer cap and applies two filters before contacting the push sidecar:

- **Push preferences:** a RAM-only per-peer registry, re-sent by the client on every reconnect and carried across relay software updates in memory like the offline buffers (§12.13), lets the relay suppress unwanted pushes. The client sends only what differs from the default: a server set to mentions-only or muted, a channel with a level of its own, and the device identifiers of muted direct-message senders; a server the relay holds no entry for gets every push. Filtering must happen relay-side because an iOS alert push cannot be suppressed after delivery. In exchange, Hollow's own relay (never Apple or Google) learns which servers and channels a phone has muted and whose DMs it silenced.
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

### 13.7 Provider Independence (UnifiedPush)

Depending on Google to wake an Android phone is a dependency Hollow does not otherwise have, and it is one a self-hosted relay cannot satisfy at all: Firebase and APNs accept a push only from whoever holds the application's credentials, which is the official deployment. Android therefore supports **UnifiedPush**, in which the wake is carried by a distributor application the user installed and a push server the user (or their relay operator) chose.

The registration a device gives the relay is an opaque string either way. For UnifiedPush it is the device's push **endpoint URL** together with a Web Push public key set (`p256dh`, `auth`) that the distributor's connector generated **on the device**. The relay keeps exactly one registration per device, so choosing a distributor replaces the Firebase registration and the two can never both be live for one device.

The wake itself is encrypted **to the device** under RFC 8291 (`aes128gcm`) before it leaves the sidecar. This is a stronger position than the Firebase path rather than a weaker one: where Google sees the opaque sender ID in the payload (§13.1), the push server and the distributor see only ciphertext of fixed shape, and learn nothing beyond the fact and timing of a wake for one endpoint. The receiving connector decrypts on-device, and a message that does not decrypt is discarded, so an endpoint address leaked to a third party buys the ability to make a phone check its relay, nothing more.

Two consequences follow for the deployment. A self-hosted relay can send its own wake-ups with no Google or Apple account, because the sidecar needs no credentials for this path, only the ability to make an HTTPS request. And because the endpoint is a URL chosen by the client, the sender treats it as untrusted input: it must be `https`, and its host must resolve to a public address, checked at the moment of connection rather than earlier, so that no client can aim the sidecar at a service inside the relay's own network.

iOS has no equivalent. Apple wakes a terminated application only through APNs, under the application's own credentials, so the iOS path is unchanged.

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

**Albums (payload v3).** Several attachments sent together remain separate messages, each with its own identifier, file, ordering stamp and signature; what groups them is a shared album identifier, and that identifier is signed so that no party re-serving the messages later (a sync responder, a backfill peer, a relay on the plaintext public-channel path) can regroup or split a sender's items. A message that carries an album is signed over a distinct payload with one extra slot:

```
hollow-msg3:{type}:{context}:{sender}:{timestamp_ms}:{message_id}:{reply_to}:{file_id}:{order_us}:{lp_digest}:{album}:{text}
```

The version is selected by the presence of the album field in the received message, never by a separate version marker. Because the two payloads carry different prefixes, no byte string is valid under both: stripping the album from a v3-signed message makes the verifier rebuild a v2 payload the sender never signed, and adding one to a v2-signed message does the reverse, so both fail. The album identifier must be a hyphenated UUID; anything else, in particular a value containing a colon, is rejected before verification, since it would let the album slot and the text boundary shift. Messages without an album are signed exactly as before, so ordinary traffic is unchanged. Grouping trusts the signed identifier only together with the verified sender: items carrying the same album from different senders never merge.

**Re-signing a preview without editing the message.** A link preview is fetched by the sender while they type, and a fast sender can dispatch the message before that fetch returns. The card is therefore allowed to arrive afterwards, as a separate signed operation naming the original message. Because `lp_digest` is inside the signed payload, such an operation cannot simply amend the stored row: it carries a fresh signature over the *unchanged* text, timestamp, reply target, attachment and ordering stamp, with only the digest differing. Receivers reconstruct that payload from the row they already hold and reject the operation unless it verifies against the row's author, so a relay cannot use it to paste a card of its choosing onto a plaintext public-channel message. The row's edit stamp is deliberately untouched: a preview landing late is not an authorship event, and presenting it as one would train users to ignore the edited marker. The same operation with an empty preview clears a card, which is what an edit that removes the URL performs.

**Backfilled history carries what its signature covers.** Catch-up sync is how an absent peer obtains history, and a signed field is only as replicable as the data behind it. A batch carrying `lp_digest` without the preview it hashes would hand the receiver a row it can verify but cannot reproduce: the next peer syncing *from* that receiver would derive a different digest and reject the message as forged, so a message would survive exactly one hop past the peer that missed it. Backfill therefore ships the preview alongside its digest, and a receiver **recomputes** the digest from the shipped card rather than trusting the one on the wire. That ordering is what keeps the card inside the signature end to end: a responder, or on the plaintext public-channel path a relay, that substitutes a card produces a digest the author never signed, and the item is dropped rather than rendered. A digest arriving alone remains valid for a responder that holds no copy of the card; such an item verifies and is stored without one. The general property: whenever a signature binds a hash, the hashed object must travel every path the signature does, or replication silently terminates at the first peer that lacks it.

**A backfilled item speaks only for its own row.** Each item's signature proves who wrote that item; it says nothing about the stored message its identifier points at. A receiver therefore lets an item change an existing message (its text, attribution, card, deletion state or file card) only when that message sits in the channel or conversation the item names and its author is the item's signer, judged from the stored row: the author's identity with devices collapsed to the master, or the key the stored signature names. A file card must describe exactly the file the item signed, and its ownership is judged against the item's verified author rather than a name the card carries. Channel history is accepted only from a current member entitled to read that channel, the same predicate that governs serving it.

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

## 18. Censorship Resistance

Hollow reaches its relay over a WebSocket inside TLS on port 443, the same port and handshake as ordinary HTTPS. It ships no special transport for censored networks.

### 18.1 What Was Tried

Testing in 2026 against Russia's TSPU deep packet inspection covered three approaches:

- **Shadowsocks-2022** (`2022-blake3-aes-256-gcm`) worked on many ISPs, but TSPU recognised its traffic pattern on some and cut connections after about 20 seconds. It was removed.
- **Plain VPN protocols** (WireGuard, OpenVPN, IKEv2) were blocked outright.
- **A VLESS + REALITY (XTLS-Vision) tunnel**, which presents the relay connection as an HTTPS session to a well-known website, was built for the desktop client with a matching endpoint on the relay server. On the tester's network TSPU dropped every handshake that borrowed a well-known site's name.

The same field test showed that the direct connection to the relay was never blocked. The relay's own TLS on port 443 and the STUN and TURN ports all passed. The tester could not connect because of client bugs in how two people first become friends and open their direct-message room. Once those were fixed, Hollow worked over its standard transport with no tunnel at all.

The REALITY tunnel was removed from the client and from the official relay in version 0.12. A disguise the censor spots more easily than the plain connection it hides only adds code and attack surface.

### 18.2 Limits

The official relay is one known address, and a censor can block an address outright whatever the traffic looks like. Because the relay is a zero-knowledge pipe, anyone can run one at another address and members can move to it without any protocol change (§12.11). If a measured block of the standard transport appears, the candidates are CDN fronting and rotating relay addresses, chosen against that block rather than in advance.

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
- The server owner's Twitch channel name and its public numeric ID are the only Twitch-related data shared among members. The owner's client resolves the ID from the name directly against Twitch with the owner's own token; no Hollow infrastructure is involved.

---

## 20. Support Credentials for Purchased Art

Hollow's artist shop sells profile art (frames, avatars, banners and bundles of them) through each artist's own storefront (Ko-fi today), entirely outside the protocol: the artist's store takes the payment and delivers the files, its webhook tells the shop an order was paid, and the shop mints the one-time code and mails it to the buyer. What the protocol adds is a **support credential**: a proof, carried on the buyer's profile, that this identity bought a given piece, verifiable offline by any viewer and unlinkable by the shop to any purchase. The art itself is not protected (there is no DRM; the files are content-addressed and travel peer to peer like every other asset), so the credential is the only thing a purchase produces that cannot be copied.

### 20.1 Blind Issuance

Each listing has its own **RSA-3072 issuing key**. A purchase yields a one-time code. To redeem it the client builds a message binding its own **master identity** to the listing:

```
"hollow-support-cred/v1" || type:u8 || len(master_peer_id):u16 || master_peer_id || item:32 || period:u32
```

where `item` is the SHA-256 over the listing's file hashes sorted ascending (so a bundle is one credential naming every file it carries, and a single piece is the same construction over one file), and `period` is reserved for the monthly supporter credential (zero for items). The client blinds the message under the listing's key (RSABSSA-SHA384-PSS-Deterministic, RFC 9474) and sends the code with the blinded value, without authentication, cookies or identity. The shop checks that the code is unspent and unrefunded, signs the blinded value with the listing's key, burns the code, and returns the blind signature. The client unblinds it and holds a signature it can verify locally.

The shop therefore learns that a code was redeemed and when, and nothing else: not which identity, not what the signature it produced looks like once unblinded. Because signatures are fully blind, the key is scoped per listing, so a code for one piece can only ever produce a credential for that piece.

### 20.2 The Trust Chain

A viewer must verify a credential with nothing but the client. Three tiers make that possible while keeping the root key offline:

- The **root** Ed25519 key, kept offline, whose public half is pinned in the client. It signs exactly one thing: the shop's issuer key.
- The **issuer** Ed25519 key, held by the shop, which signs each listing's RSA public key together with the listing's `item` hash under a domain-separated message.
- The **issuing** RSA key of the listing, which signs the blinded credential.

Every credential entry carries the whole chain (the issuing public key, the issuer's signature over it, the issuer public key, the root's signature over that, and the credential signature), so verification needs no fetch. Rotating the issuer never touches the client; only a root rotation would.

### 20.3 What Rides the Profile

Credentials ride the profile as a JSON array field, about 1.4 KB per entry, capped at three item credentials and one supporter credential inline (the light announce is the budget). The field follows the rules every other profile field follows (absent on the wire preserves, empty clears) and is **not** part of the profile signature: the credential already binds the master identity, and a viewer verifies it independently. On ingest, every receiver runs one validator: the root-to-issuer signature, the issuer-to-key signature, the key's size and shape, the recomputation of `item` from the listed parts, and the RSA signature over the message rebuilt from *that* profile's master identity. An entry that fails any link is dropped silently; one that verifies is stored exactly as it verified, re-serialized, so nothing a sender appended reaches the row. Entries are deduplicated by `item`, which is what keeps a second redemption of the same piece from meaning anything (PSS salts each signature, so the bytes differ; the claim does not).

A credential is bound to a master identity, so it replicates to that person's linked devices with their profile and survives reinstalls through the identity backup. Copying one onto another identity produces a signature over the wrong message and fails everywhere. Editing one into a local database has the same result on every other machine: before every announce the announcing client rebuilds the field from its own verified redemption records together with the entries its master identity already publishes, keeps only what verifies for that identity, and drops what the holder has removed, so a forged entry never leaves the machine it was typed on and a linked device that redeemed nothing still announces what its identity holds.

The holder controls the field. Hiding the marks publishes the same explicit clear that an identity with no credentials publishes, so a holder who hides is indistinguishable from one who never bought; the records stay on the device and unhiding republishes them. Removing a credential is final, because the code that produced it is spent and the shop signs no second credential for the same purchase.

The signature on each entry prevents forgery, not deletion, so the field itself carries a second signature by the holder's master key over the identity, the profile's timestamp and the field's bytes. A receiver that has once seen a valid field signature from an identity requires it from then on: a copy of that identity's profile whose field arrives unsigned or with a bad signature leaves the stored field untouched rather than clearing it, and so does a genuine but older announce replayed later. Before the first signed announce a receiver applies the field the old way, which is the one window a party able to rewrite an unencrypted announce in flight can use to make marks disappear, and only until the holder's next announce.

### 20.4 Twitch Identity as a Credential

The same construction vouches for a Twitch account. A Twitch handle on a profile used to be a claim signed by its own author, so a modified client could wear any streamer's name. Now a **Twitch owner credential** carries the account's numeric id and login as its parts, hashed under a domain of its own into `item`, and a `period` that for this type means time: a 90-day window, checked by every verifier against the clock with one window of grace, so a renamed or lost account stops being vouched for without any revocation traffic. The verifier is the shop host. It receives the user's own Twitch access token, asks Twitch who the token belongs to, and blind-signs under a key made for that login and window and chained to the same offline root. It learns that a login verified in a window and never which Hollow identity asked, because the message is blinded. The client verifies the key chain against the pinned root before it blinds anything, and the finished credential as any viewer would before storing it. The purple Twitch chip renders only from such a credential; an unverified handle renders nothing.

Server admission gated on a Twitch follow uses a second type that never rides a profile. A **follow credential** names the channel's id, a follow-age step from a fixed ladder of ten (any, 1, 3, 7, 14, 30, 60, 90, 180 and 365 days) and a subscription tier, each combination signed under its own key, so the only way to hold a credential for a step is for Twitch to have told the verifier that the follow is at least that old. The server owner's gate verifies the chain, the channel, the window and the joiner's master identity offline, then compares the step and the tier to the server's settings. A join that must wait for the owner to come online can carry the credential on the shared join ring, because it names the channel and a step, never the joiner's Twitch identity. Owners on this version refuse the previous self-reported proof outright.

### 20.5 Privacy Properties

- The shop never sees the buyer's identity at redemption and cannot recognise the unblinded signature later; a credential cannot be mapped back to an order.
- Redemption carries no authentication and the shop stores only the hash of the spent code and the moment it burned.
- Viewers verify offline against the pinned root; rendering a mark requires no network request and reveals nothing to the shop.
- The mark is a badge, shown whether or not the art is currently worn; it says the piece was bought by this identity, and the parts it names say exactly which bytes.

---

## 21. Verification and Correctness Assurance

Distributed, multi-device cryptographic logic is difficult to verify by manual testing alone, because many failure modes appear only with specific timing across several devices. Hollow's correctness rests on a **multi-node integration harness** that exercises the real protocol code deterministically.

### 21.1 Multi-Node Harness

The harness spins up *N* real node event loops in a single test process, each with its own Ed25519 keypairs and its own temporary SQLCipher database, wired together through an **in-process mock relay** rather than real sockets or TLS. The same Rust core that ships in the client runs in the harness, so the encryption, ratcheting, CRDT merge, and synchronization logic under test is the production logic, not a model of it. The mock relay reproduces the load-bearing, protocol-visible behaviors of the real relay (authentication, room join/leave, broadcast and direct routing, topic frames, offline buffering and replay, and disconnect events) so that reconnection and offline/online transitions are exercised faithfully.

### 21.2 Two-Layer Inspection

Multi-device bugs hide in the gap between the *master-collapsed* view that the UI presents and the *device-keyed* truth underneath. The harness exposes both layers: a UI-layer inspector that reads through the same resolver and CRDT accessors the application uses, and a raw-layer inspector that exposes per-device state (per-device MLS leaf membership, per-device Olm session status, raw device-keyed CRDT keys). A test can therefore assert precisely where the master-keyed and device-keyed layers should and should not diverge, the central invariant of the multi-device design (§3, §5).

### 21.3 Coverage and Scope

The harness self-verifies the **distributed-logic core**: DM messaging and sync/backfill (direction, signatures, deduplication, edits/deletes/reactions), friends and profiles, presence and typing, CRDT servers/channels/roles/permissions/bans, MLS group formation across per-device leaves at a shared epoch with cross-device channel decryption, public channels, device revocation (tombstone propagation, Olm/MLS cutoff, and the ghost-device liveness guard), and Olm key exchange and glare. It also covers the **control and signaling plane** for calls, voice channels, recovery pools, and file transfer (including the actual bytes over the relay fallback path). The harness runs in continuous integration as a required check, gating merges.

It deliberately does **not** cover the WebRTC media plane (audio/video pixels, SFrame on live tracks, ICE/TURN/DTLS), the Flutter UI, the FFI bridge, native push delivery (FCM/APNs and the iOS extension), identity at-rest unlock, or the real relay's C++ implementation. The application layer is addressed separately (§21.4); the remainder stays the subject of manual platform testing. The honest claim when the harness is green is therefore precise: *the distributed-logic core and the control/signaling plane behave correctly across many devices*, not that the entire application is verified.

### 21.4 Application-Layer Probes

A second harness closes part of the gap the first one leaves. An instrumented build of the real client, running the production interface code, foreign-function bridge, encrypted local database and node against the real relay, is driven through its own widget tree by a scripted command stream. It can address any control, read the application's own state, and assert on what is actually rendered rather than on what the protocol layer believes.

Several such instances run side by side on one machine, each with a separate identity and data directory, so a journey that spans peers (a friend request accepted, an invitation joined, a message delivered, a member removed) is asserted from both sides at once. This answers a class of question the multi-node harness cannot: not whether an operation converged, but whether the interface agrees with it once it has.

The layer stops short of the media plane. Video surfaces are composited outside the widget tree, so no capture of a rendered frame can demonstrate that video is flowing; only decoder and renderer statistics can, and that remains future work.

---

## 22. Summary of Cryptographic Primitives

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
| Content files | AES-256-GCM, chunked, per-file random key held in SQLCipher | 256-bit key, 96-bit nonce (64-bit file prefix + chunk index) | Attachment, media and cache encryption at rest; row deletion is the erase |
| Backup encryption | Argon2id + AES-256-GCM | 256-bit (64 MB memory cost) | Brute-force resistant account backup |
| Roster | Ed25519 statements by devices; recoveries signed by the recovery key and the master | 256-bit | Which devices belong to a person; the recovery phrase is the root (§3.2) |
| Duress slot | Argon2id + AES-256-GCM (own salt, fixed-size plaintext) | 256-bit key, 128-bit salt | A second secret that destroys instead of unlocking; indistinguishable on disk and in timing |
| Destruction order | Ed25519, signed by the recovery key (or by a device holding the phrase's permission), issue-time bound | 256-bit | Identity-wide wipe delivered by siblings or parked on the relay for offline devices |
| Per-device transport key | Ed25519 (random per device) | 256-bit | Per-device relay authentication; decouples device ID from identity |
| Device-link transfer | SPAKE2 on a 10-character code, then AES-256-GCM (`.hollow` backup under a random key) | 256-bit | Identity + DB transfer to a new device; the relay never sees the code's secret part (§3.4) |
| Mobile app lock | Argon2id + AES-256-GCM (+ OS secure enclave for biometric) | 256-bit | PIN/password/biometric launch lock over the identity-at-rest key |
| Twitch verification | Ed25519-signed proof | 256-bit | Verifiable community membership proof |
| Support credential | RSABSSA-SHA384-PSS-Deterministic (RFC 9474) blind signature, Ed25519 chain to a pinned root | RSA-3072 per listing, Ed25519 256-bit | Unlinkable, offline-verifiable proof that an identity bought a piece of art |

---

## 23. Threat Model

### 23.1 What Hollow Protects Against

| Threat | Protection |
|--------|------------|
| Message content interception | E2EE (Olm for DMs, MLS for servers). Only intended recipients hold decryption keys. |
| Relay compromise | The relay reads no content. A fully compromised relay learns routing metadata: peer IDs, which rooms they share, timing and size, each identity's roster, and a phone's push token and non-default notification settings, all held in memory and never logged to disk (§12.7). Every frame it forwards is signed by the sending device, so it cannot forge one in a device's name. |
| Push-provider metadata harvesting | Wake-up pushes carry no content: a sender device ID and, for channels, server and channel IDs and a mention bit (§13.1). Apple/Google never receive message text, size, or content; all content is fetched from Hollow's relay and decrypted on-device. The stable IDs let them link phones that share a server or a conversation until those fields are encrypted for them as UnifiedPush already does. |
| Link-preview IP harvesting | Previews are fetched once, by the sender, and travel inside the encrypted message. A recipient's device makes no request to the previewed site to render the card, so posting a link into a large room reveals nothing about who read it. Without this, a link in a busy channel would enumerate its readers to whoever controls the URL. Playing an embedded video is the sole exception and requires an explicit tap, on a target the signature already covers. |
| Device-list tampering | A person's devices are a roster of statements, each signed by a device or by the recovery key (§3.2). The master key alone admits no device, every device signs its own consent, and an older roster cannot bring back a removed device. |
| Stolen/lost device | Remove it from any other device: contacts drop its sessions and MLS leaf at once, and it locks and erases itself after three days. A stolen device cannot keep the identity: the recovery phrase, typed on any device, starts over with only the devices you pick. A backup file restored elsewhere waits until one of your devices approves it. |
| Voice/video eavesdropping | DTLS-SRTP between participants, plus SFrame per-frame E2EE on voice, voice-channel video and screen shares (§6.3). TURN servers and the forwarder see only ciphertext. |
| File content interception | AES-256-GCM per file. Relay and TURN see only encrypted bytes. |
| Man-in-the-middle on key exchange | Authenticated Olm key exchange + Ed25519 identity binding. |
| Storage shard snooping | Encrypt-then-erasure-code. Shards are encrypted; reconstructing all shards yields only ciphertext. |
| Removed member accessing new content | MLS epoch rotation on removal. New epoch derives fresh keys from randomness the removed member doesn't have. |
| Message forgery | Ed25519 signatures on every message. Invalid signatures are rejected. |
| Harassment by a specific peer | Master-keyed local blocking enforced at ingest (§12.14): DMs, friend requests, calls, and files from a blocked identity are dropped before storage or notification, from any of their devices. |
| Evidence destruction | Decentralized storage + cryptographic signatures. No central authority can delete data from other users' devices. |
| CRDT state manipulation | Author verification + role-based permission checks. Unauthorized operations rejected. |
| Clock manipulation attacks | HLC drift bound (5 minutes). Far-future timestamps rejected to prevent LWW conflict gaming. |
| Resource exhaustion | Ed25519 authentication, access-key revocation where a relay enables it, message size limits (64 MB binary / 1 MB text), 64 MB hard backpressure, connection limits. |
| Privilege escalation | Permission checks on all state-changing operations. CRDT author ≠ self-reported field; it is verified against the actual sender. |
| Identity file theft | HKEYV1 at-rest protection. Identity file encrypted via DPAPI/Keychain (machine-bound) or Argon2id + AES-256-GCM (password). Stolen files are useless without the original machine or password. |
| Data folder browsed, copied or stolen | Content files are per-file AES-256-GCM ciphertext whose keys live in the SQLCipher database, so a copied folder yields nothing without the identity; uninstalling or wiping leaves only dead ciphertext. Not a defence for a running, unlocked session or for the "no protection" identity mode, where the identity file is plaintext. |
| Coercion at the unlock prompt | A duress code destroys the local data (and, from a running node, the whole identity) while showing nothing; both secrets cost the same to check. A forged or replayed destruction order fails the recovery-key signature, the link-time rule, or the applied-order rule; a malicious relay can only delay delivery. |

### 23.2 What Hollow Does Not Currently Defend Against

- **Traffic analysis:** message timing and size patterns are visible to the relay and network observers. Constant-rate padding is not implemented.
- **Local device compromise:** if an attacker has access to an unlocked device with the decrypted database open, they can read everything. This is true of any E2EE system. Identity at-rest protection (§2.3) mitigates offline attacks: the identity file is encrypted via DPAPI/Keychain (machine-bound) or a user password (Argon2id), so a stolen identity file is useless without the original machine or password. However, a live session with the wrapping key in memory remains vulnerable.
- **Relay availability attacks:** a malicious relay can selectively drop or delay messages. The current single-relay architecture has no failover. Multi-relay support is designed but not yet deployed.
- **Quantum computing:** all key exchanges use Curve25519. Migration to ML-KEM (Kyber) is planned but not prioritized for the beta.
- **Trust-on-first-use (TOFU):** peer identity verification relies on out-of-band fingerprint comparison. There is no certificate authority or web of trust. The recovery key is trusted on first sight too: someone who first meets an identity after a thief with its master key published a forged one keeps the forged one, while everyone who already knew the identity keeps the real one. An identity from before 0.12 publishes its real key at the first 0.12 start of a device that kept the phrase, so a forger has to act before that.
- **Someone who has your recovery phrase** is you to Hollow: they can recover the identity and remove your devices. Hollow never stores the phrase; keep your copy offline.

### 23.3 Relay Operator Trust Assumptions

The design assumes the relay may be **actively malicious**, not merely curious: anyone can run a relay, and the published attacks on federated messengers came from hostile servers. Such a relay learns routing metadata (§12.7) and can drop or delay what it carries. It cannot forge a message, a server change, a roster statement, a friend accept or a destruction order, because each is signed by a device or key the relay does not hold. Withholding is its real power: a relay that keeps a device removal from one contact leaves that contact sending to the removed device until it hears of the removal another way.

The relay is also assumed to be **unreliable**: it may go offline, and clients auto-reconnect with exponential backoff.

The relay operator is **not trusted** with: message contents, encryption keys, file data, user profiles, message signatures, or any application-layer semantics.

### 23.4 Software Distribution and Update Integrity

The host that serves release archives and the version manifest is assumed to be **untrusted**. A hosting account is not part of the trust model, so the update channel carries its own integrity rather than borrowing the host's:

- **Signed manifest.** The version manifest is published together with a detached Ed25519 signature over its exact bytes. Clients embed the corresponding public key and reject a manifest whose signature does not verify. The host can serve bytes; it cannot produce a signature.
- **Pinned archives.** Each release entry names the SHA-256 digest of every platform's archive. A client hashes the download as it streams and discards any file whose digest differs from the signed manifest before anything is extracted or installed. An entry without a digest for the client's platform is not installable through the updater.
- **No downgrade prompt.** Only a manifest whose latest version is strictly newer than the running build is presented as an update, so a replayed older manifest, still validly signed, cannot walk installs back to a build with known defects.
- **Transport.** Update downloads are accepted over HTTPS only.

What the manifest does not give is freshness. It carries no expiry and the client keeps no record of the newest version it has seen, so whoever controls the host can keep serving an older, validly signed manifest and hold back a newer release; it can withhold an update, never install one. The desktop updater checks the downloaded archive against the signed digest only, not against the operating system's code signature. On Android, releases are signed with a certificate generated on the release machine and kept off the repository; holding that file is holding the signing key.

Auxiliary feeds served from the same location (release notes, service status) are display-only and unsigned; nothing fetched through them is executed or installed, and news posts render no remote images. Outside this mechanism sit the signing key itself, which lives with the release engineer and never in the repository, and the installers distributed through the website, which rely on platform code signing rather than the manifest.

**Linux.** A Linux client is installed either as a portable directory or as a Flatpak, and the manifest carries a separate pinned archive for each, so an install can only ever fetch the artifact its own kind can apply. The portable kind replaces its own directory in place once the running process has exited and restores the previous build if the new one does not stay up. The Flatpak kind cannot modify its own read-only deployment at all: it hands the verified bundle to the host's Flatpak installer through the sandbox's host-command interface, and the restart is likewise performed from the host, since nothing started inside the sandbox outlives the application. The same bundles are also published in a self-hosted repository whose commits and summaries carry a GPG signature under a key embedded in every bundle and repository description, so the system-level update path verifies the publisher independently of the transport; an unsigned bundle is refused over an installation that originates from that repository.

---

## 24. Limitations and Future Work

- **No post-quantum cryptography:** all key exchanges use Curve25519. If quantum computers eventually break elliptic curve crypto, intercepted ciphertext could theoretically be decrypted retroactively. A future migration to ML-KEM (Kyber) is a consideration but not a priority; no consumer chat app has shipped this yet.
- **No traffic analysis protection:** the relay uses native TLS via uWebSockets C++ with OpenSSL (direct TLS termination, no reverse proxy), which protects message *content* from network eavesdroppers. However, message *timing and size patterns* remain visible: an observer can infer who is chatting with whom based on when messages are sent, even without reading them. Defeating this would require constant-rate padding (sending dummy traffic to hide real messages), which is impractical for a chat app.
- **Single relay dependency:** multi-relay support with cross-relay room gossip is designed but not yet deployed. Horizontal scaling to millions of users via a swarm of relay nodes is the planned architecture.
- **No social recovery:** Shamir's Secret Sharing for key recovery via trusted contacts is designed but not implemented.
- **No web client:** Windows, macOS, Linux, Android, and iOS are supported. A Flutter Web build is a future target with no working build today.
- **Mobile media constraints:** voice and video calls (with SFrame E2EE), file transfer, DMs, MLS servers, vault, archive, and screen sharing with system audio (§6.8) all work on mobile. The remaining gap: the large-file Share transport (>34 MB, STUN-only) is excluded on mobile because it does not survive carrier-grade NAT. macOS below 13.0 cannot send screen-share audio (no capture API).
- **MLS post-compromise recovery:** members do not refresh their own leaf keys on a schedule yet (§5.4). Periodic self-update commits are planned.
- **Push metadata at Apple and Google:** Firebase and APNs wakes carry stable IDs in the clear (§13.1). Encrypting them to the device, as the UnifiedPush path already does, is planned.

---

*This document describes the Hollow protocol as implemented in the Beta release. The protocol is subject to change. Check the GitHub repository for the latest updates. The relay server is open-source under the MIT License. The client application is open-source under the GNU Affero General Public License v3.0 (AGPL-3.0).*
