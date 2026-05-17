# Cryptography — Signing, Olm, MLS, Key Management

This document covers every cryptographic module in `rust/hollow_core/src/`. Hollow uses three layers of encryption: Ed25519 message signing for authenticity, vodozemac Olm (Double Ratchet) for DM encryption, and OpenMLS for server-wide group encryption. SFrame keys for voice/video are derived from MLS epoch secrets.

## Module Organization

File: `rust/hollow_core/src/crypto/mod.rs`

Re-exports three types from submodules:
- `MlsManager` from `mls_manager.rs` — OpenMLS group encryption
- `OlmManager` from `olm_manager.rs` — vodozemac Olm Double Ratchet
- `CryptoStore` from `store.rs` — SQLCipher persistence actor

All three are `pub(crate)` — internal to the Rust crate, not exposed via FFI.

---

## crypto_handler.rs — Signing, Encryption Dispatch, MLS Coordinator

File: `rust/hollow_core/src/node/crypto_handler.rs`

This module provides helper functions called from `swarm.rs` and other node modules. It does NOT own crypto state; it borrows `OlmManager`, `MlsManager`, `CryptoStore`, and `NativeKeypair` from the swarm's state variables.

### Message Signing Payload — Canonical Format

`crypto_handler:message_signing_payload(msg_type, context, sender, ts, text) -> String`

Constructs the canonical string that gets Ed25519-signed for every message. Format:

```
hollow-msg:{type}:{context}:{sender}:{ts}:{text}
```

Two message types:
- **Channel messages:** `msg_type = "ch"`, `context = "{server_id}:{channel_id}"`
- **DM messages:** `msg_type = "dm"`, `context = "{recipient_peer_id}"`

Critical rule: Dart timestamps MUST be hydrated from Rust's signed value, not `DateTime.now()`. The payload string must be identical on both signing and verification sides.

### Ed25519 Signing

`crypto_handler:sign_message(keypair, pub_key_b64, payload) -> (Option<String>, Option<String>)`

Signs the payload bytes with the local `NativeKeypair`. Returns `(signature_base64, public_key_base64)`. Both are `Some` on success. The keypair is the Ed25519 identity key from `native_identity.rs`.

### Ed25519 Verification

`crypto_handler:verify_message_signature(sender_peer_str, sig_b64, pk_b64, payload) -> bool`

Three-step verification:
1. **Decode public key** from base64. Returns `false` if decode fails.
2. **Derive PeerId from public key** and compare to `sender_peer_str`. The public key must be in protobuf encoding (first bytes `0x08 0x01`, length >= 36). PeerId is derived by wrapping the protobuf pubkey in an identity multihash (`0x00` code + length byte + pubkey bytes), then base58-encoding with the Bitcoin alphabet. Returns `false` if the derived PeerId does not match the claimed sender.
3. **Verify the Ed25519 signature** via `NativeKeypair::verify_peer_signature(&pk_bytes, &sig_bytes, payload_bytes)`.

This prevents spoofing: the signature proves the sender controls the private key corresponding to their PeerId.

### Olm Encrypted Message Send

`crypto_handler:send_encrypted_message(olm, crypto_store, peer_id_str, text, event_tx, ws_cmd_tx, ws_room_peers) -> bool`

Async function for sending Olm-encrypted DM messages. Flow:
1. Call `olm.encrypt(peer_id, text_bytes)` — returns `(msg_type, ciphertext)`.
2. Persist both account and session state via `persist_crypto_state()`.
3. If `msg_type == 0` (PreKey message), attach the sender's `identity_key` to the `HavenMessage::Encrypted` envelope so the receiver can create an inbound session.
4. Find a WS room containing the target peer via `ws_room_for_peer()`.
5. Send via `WsCommand::SendDirect { room_code, target_peer, data }`.
6. Returns `true` on success. On encryption failure, emits `NetworkEvent::MessageSendFailed` and returns `false`. If peer is unreachable (not in any WS room), logs but returns `false` silently.

The `HavenMessage::Encrypted` envelope contains:
- `message_type`: 0 (PreKey) or 1 (Normal)
- `body`: base64-encoded ciphertext
- `identity_key`: `Some(base64)` only for PreKey messages, `None` for Normal

### Crypto State Persistence

`crypto_handler:persist_crypto_state(olm, crypto_store, peer_id)`

Fire-and-forget persistence of both account state and the specific peer session. Calls:
- `olm.account_pickle_json()` -> `crypto_store.save_account(json)`
- `olm.session_pickle_json(peer_id)` -> `crypto_store.save_session(peer_id, json)`

Called after every encrypt/decrypt operation to ensure the ratchet state survives crashes.

### MLS State Persistence

`crypto_handler:persist_mls_state(mls, keypair)`

Serializes three blobs (signer, credential, MemoryStorage) and writes them to SQLCipher via `MessageStore::save_mls_identity()`. The DB path is `~/.hollow/messages.db`, passphrase derived from the first 32 bytes of the keypair's protobuf encoding (hex-encoded).

Called after every MLS encrypt/decrypt operation.

### MLS Broadcast Encryption

`crypto_handler:send_mls_broadcast(mls, ws_cmd_tx, server_id, envelope, keypair) -> Result<(), String>`

Encrypts a `MessageEnvelope` for all server members and broadcasts it. Flow:
1. Serialize the `MessageEnvelope` to JSON.
2. `mls.encrypt(server_id, json_bytes)` — returns MLS ciphertext.
3. Base64-encode the ciphertext.
4. Persist MLS state.
5. Wrap in `HavenMessage::MlsChannelMessage { server_id, body }`.
6. Send via `WsCommand::SendToRoom { room_code: server_id, data }`.

The relay fans out the message to all room members. Each member decrypts with their own MLS group state, advancing the ratchet.

### Targeted Peer Sends (Olm + SendDirect)

All targeted peer-to-peer messages (shard requests, sync batches, file headers, voice signaling) use **Olm encryption + `SendDirect`** (relay frame 0x04) instead of MLS group broadcast. This sends only to the target peer — O(1) delivery instead of O(n).

The primary function is `send_encrypted_message(olm, crypto_store, peer_id, text, event_tx, ws_cmd_tx, ws_room_peers)` which Olm-encrypts the payload and sends via `WsCommand::SendDirect`. If Olm encryption fails (no session), the message is not delivered and `false` is returned.

Previously, `send_mls_to_peer()` was used for targeted sends — it MLS-encrypted and broadcast to ALL room members (O(n)), with every member decrypting to keep ratchets in sync. This was replaced in Phase 6.75 Tier 11 because the O(n) overhead was unnecessary for targeted messages. The function is retained with `#[allow(dead_code)]` for backward compatibility.

### Peer Reachability

`crypto_handler:peer_is_reachable(ws_room_peers, peer_str) -> bool`

Checks if any WS room contains the given peer. Iterates all values of the `ws_room_peers: HashMap<String, HashSet<String>>` map.

`crypto_handler:ws_room_for_peer(ws_room_peers, peer_str) -> Option<String>`

Returns the room code containing the peer, or `None`. Used by `send_encrypted_message` and `send_message_to_peer` to route messages.

### Plaintext Message Send

`crypto_handler:send_message_to_peer(ws_cmd_tx, ws_room_peers, peer_str, msg)`

Sends an unencrypted `HavenMessage` to a specific peer via WS relay direct send. Serializes the message to JSON internally. Silently drops if peer is unreachable. Used for single-peer sends (sync requests, shard coordination, voice channel state changes).

`crypto_handler:send_raw_to_peer(ws_cmd_tx, ws_room_peers, peer_str, data)`

Sends pre-serialized bytes to a specific peer via WS relay direct send. Used in broadcast loops to serialize once and send the same bytes to each peer, avoiding O(N) deep clones and re-serializations. All broadcast patterns (ProfileUpdate, TypingIndicator, StatusUpdate, PeerExchange, MlsCommit, MlsWelcome, CrdtOpBroadcast, VoiceChannel) use this function.

### MLS Coordinator Election

`crypto_handler:elect_coordinator(mls_members, local_peer, ws_room_peers) -> Option<&str>`

Deterministic coordinator election algorithm:
1. Filter `mls_members` to only those that are **online** (present in any WS room, OR are the local peer — local peer is always considered online).
2. Sort the online members lexicographically.
3. Return the **lowest peer_id** — this is the coordinator.
4. Returns `None` if no members are online (empty members list).

Security property: only MLS group members participate — non-members cannot become coordinator even if they are in the WS room.

`crypto_handler:is_mls_coordinator(mls, server_id, local_peer, ws_room_peers) -> bool`

Convenience wrapper: checks if a group exists for `server_id`, gets the member list via `mls.group_members(server_id)`, then calls `elect_coordinator` and compares the result to `local_peer`.

The coordinator is responsible for processing MLS membership changes (adding/removing members via commits).

**KeyPackage handler exception:** When processing an incoming KeyPackage, the sender is excluded from coordinator election (they sent it because they lost their group). The handler builds a custom candidate list filtering out `peer_str` instead of using `is_mls_coordinator()`. Without this, the lowest-peer-ID member losing their group creates a permanent recovery deadlock.

### Unit Tests

Four tests verify coordinator election:
- `coordinator_election_lowest_wins` — with all 3 peers online, lowest wins regardless of caller
- `coordinator_election_single_member` — single member is always coordinator (even with empty room map, since local peer is always "online")
- `coordinator_election_offline_skipped` — offline peer skipped; but if offline peer IS the local caller, they consider themselves online
- `coordinator_election_empty_members` — empty list returns `None`

---

## olm_manager.rs — Olm Double Ratchet DM Encryption

File: `rust/hollow_core/src/crypto/olm_manager.rs`

### OlmManager Structure

```rust
pub(crate) struct OlmManager {
    account: Account,                    // vodozemac Olm Account (Curve25519 + Ed25519 keys)
    sessions: HashMap<String, Session>,  // peer_id -> Olm Session
    outbound_only: HashSet<String>,      // peers with outbound-only sessions (produce PreKey type 0)
}
```

The `account` holds the local Curve25519 identity key and one-time key generation. Each `Session` is a Double Ratchet session with a specific peer. The `outbound_only` set tracks peers whose session was created via `create_outbound_session` — these sessions produce PreKey (type 0) messages for ALL encryptions until replaced by an inbound session.

### Lifecycle

#### New Account

`OlmManager:new() -> Self`

Creates a fresh vodozemac `Account` with new Curve25519 + Ed25519 keys. Empty session map and outbound_only set.

#### Restore from Persistence

`OlmManager:from_pickles(account_json, sessions: Vec<(String, String)>) -> Result<Self, String>`

Restores from JSON pickles stored in SQLCipher. Steps:
1. Deserialize account pickle from JSON, restore via `Account::from_pickle()`.
2. For each `(peer_id, session_json)` pair, deserialize and restore via `Session::from_pickle()`.
3. `outbound_only` is initialized empty — conservatively assumes restored sessions might be outbound, but on first PreKey received from a peer the session gets replaced anyway.

### Key Management

`OlmManager:identity_key_base64() -> String`

Returns the local Curve25519 identity key as unpadded base64. Used in key exchange and included in PreKey messages.

`OlmManager:generate_one_time_key() -> String`

Generates exactly 1 one-time key, marks it as published, returns it as unpadded base64. One-time keys are consumed during outbound session creation — each is used exactly once, then discarded.

### Session Creation

#### Outbound Session (Initiator)

`OlmManager:create_outbound_session(peer_id, their_identity_key_b64, their_otk_b64) -> Result<(), String>`

Creates an outbound session using:
- The peer's Curve25519 identity key
- The peer's one-time key (consumed)

Uses `SessionConfig::version_2()` (latest vodozemac session protocol). Inserts the session into the `sessions` map and marks the peer in `outbound_only`.

**Outbound-only behavior:** All messages encrypted on this session produce PreKey (type 0) messages. This continues until the session is replaced by an inbound session (when the peer responds). This is vodozemac's behavior — the ratchet needs a response to advance past the PreKey stage.

#### Inbound Session (Responder)

`OlmManager:create_inbound_session(peer_id, their_identity_key_b64, pre_key_message_bytes) -> Result<Vec<u8>, String>`

Creates an inbound session from a received PreKey message. Steps:
1. Decode the peer's identity key from base64.
2. Parse `pre_key_message_bytes` as `OlmMessage::PreKey` (type 0). Errors if it's a Normal message.
3. Call `account.create_inbound_session(their_identity_key, &pre_key_msg)` — returns the new session plus the decrypted plaintext.
4. Insert the session (replaces any existing session for this peer).
5. Remove peer from `outbound_only` — inbound-derived sessions produce Normal (type 1) messages.

Returns the decrypted plaintext bytes.

### Encrypt / Decrypt

`OlmManager:encrypt(peer_id, plaintext) -> Result<(usize, Vec<u8>), String>`

Encrypts plaintext for a peer. Returns `(message_type, ciphertext_bytes)`:
- `message_type = 0` — PreKey message (contains session establishment data)
- `message_type = 1` — Normal message (Double Ratchet)

Fails with error if no session exists for the peer.

`OlmManager:decrypt(peer_id, message_type, ciphertext_bytes) -> Result<Vec<u8>, String>`

Decrypts a message from a peer. Reconstructs the `OlmMessage` from type + bytes, then decrypts via the session. Returns plaintext bytes.

### PreKey Race Handling

`OlmManager:try_decrypt_prekey_with_existing(peer_id, ciphertext_bytes) -> Result<Vec<u8>, String>`

Handles the case where two PreKey messages arrive from the same outbound session. After the first PreKey creates an inbound session, a second PreKey from the same batch can be decrypted using the existing session. This avoids the need to create a new inbound session for every PreKey.

The race scenario: Alice sends multiple messages before Bob responds. All are PreKey (type 0) because vodozemac's outbound session always produces PreKey until the ratchet advances. Bob processes the first PreKey with `create_inbound_session`, then subsequent PreKeys from the same session use `try_decrypt_prekey_with_existing`.

### Dual-PreKey Race

When both peers simultaneously create outbound sessions to each other (e.g., both come online and exchange keys at the same time), they end up with incompatible sessions after processing each other's PreKeys. The test `test_dual_prekey_creates_incompatible_sessions` verifies this. The swarm code handles this via re-keying (`KeyRequest` flow).

### Session Management

`OlmManager:has_session(peer_id) -> bool` — checks session existence.

`OlmManager:remove_session(peer_id)` — removes session and clears `outbound_only` flag. Used before replacing with a new inbound session during dual-PreKey resolution.

`OlmManager:mark_session_bidirectional(peer_id)` — removes from `outbound_only` set. Called when a `SessionAck` is received from the peer, confirming they created an inbound session and the ratchet has advanced. After this, the outbound session produces Normal (type 1) messages.

### Serialization for Persistence

`OlmManager:account_pickle_json() -> Result<String, String>` — serializes the account to JSON via vodozemac's pickle format.

`OlmManager:session_pickle_json(peer_id) -> Result<Option<String>, String>` — serializes a specific session to JSON. Returns `None` if no session exists.

### Base64 Utilities

`OlmManager:encode_base64(data) -> String` — standard base64 encoding.

`OlmManager:decode_base64(data) -> Result<Vec<u8>, String>` — standard base64 decoding.

### Session Lifecycle Summary

The complete DM handshake:
1. **Key exchange:** Alice obtains Bob's identity key + one-time key (via `KeyBundle` message).
2. **Outbound session:** Alice calls `create_outbound_session("bob", bob_identity, bob_otk)`.
3. **First message:** Alice encrypts — produces PreKey (type 0) with embedded session establishment data. Identity key is attached to the `HavenMessage::Encrypted` envelope.
4. **Inbound session:** Bob receives PreKey, calls `create_inbound_session("alice", alice_identity, prekey_bytes)` — decrypts and establishes session.
5. **Reply:** Bob encrypts — produces Normal (type 1) because inbound-derived sessions always produce Normal.
6. **Ratchet advance:** Alice decrypts Bob's Normal reply — her ratchet advances. All subsequent Alice encrypts produce Normal (type 1).

If multiple PreKeys arrive before step 4, Bob uses `try_decrypt_prekey_with_existing` for the extras.

### Unit Tests

- `test_alice_bob_session` — full handshake: outbound -> PreKey -> inbound -> reply -> Normal
- `test_pickle_round_trip` — serialize/restore account + session, verify identity key preserved and encryption works
- `test_multiple_prekeys_from_same_session` — two PreKeys from same outbound session, second decrypted with existing
- `test_dual_prekey_creates_incompatible_sessions` — simultaneous outbound sessions produce incompatible sessions (expected, handled by re-keying)
- `test_inbound_session_produces_normal_messages` — 100 encrypts after inbound session, all type 1
- `test_outbound_session_upgrades_after_receiving_reply` — after receiving Normal reply, outbound session produces Normal (100 encrypts, all type 1)

---

## mls_manager.rs — MLS Group Encryption

File: `rust/hollow_core/src/crypto/mls_manager.rs`

### MlsManager Structure

```rust
pub(crate) struct MlsManager {
    provider: OpenMlsRustCrypto,                   // OpenMLS crypto provider
    signer: SignatureKeyPair,                       // Ed25519 signing keypair for MLS
    credential_with_key: CredentialWithKey,         // BasicCredential (peer_id bytes) + signature public key
    groups: HashMap<String, MlsGroup>,              // server_id -> MLS group
}
```

**Ciphersuite:** `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`
- Key exchange: X25519 Diffie-Hellman
- Encryption: AES-128-GCM
- Hash: SHA-256
- Signatures: Ed25519

One MLS group per server. DMs use Olm, not MLS. The credential identity is the raw `peer_id` bytes, so `group_members()` can extract peer IDs by reading credential content.

### Lifecycle

#### New MLS Identity

`MlsManager:new(peer_id) -> Result<Self, String>`

Creates a fresh MLS identity:
1. Create `OpenMlsRustCrypto` provider (default).
2. Generate Ed25519 `SignatureKeyPair` for the MLS ciphersuite.
3. Store the signer in the provider's storage (OpenMLS requires this).
4. Create `BasicCredential` with `peer_id.as_bytes()` as identity.
5. Combine into `CredentialWithKey` (credential + public signature key).

#### Restore from Persistence

`MlsManager:from_persisted(signer_bytes, credential_bytes, storage_blob, server_ids) -> Result<Self, String>`

Restores from SQLCipher-persisted state:
1. Create fresh `OpenMlsRustCrypto` provider.
2. If `storage_blob` is provided, deserialize the MemoryStorage HashMap into the provider. Format: `u64 count`, then for each entry: `u64 key_len, u64 value_len, key_bytes, value_bytes` (all big-endian).
3. Deserialize `signer` and `credential_with_key` from serde JSON.
4. Store the signer in the provider.
5. For each `server_id`, attempt to load the MLS group from the provider's storage via `MlsGroup::load()`. Groups that exist are inserted into the `groups` map; missing groups are silently skipped (pre-MLS servers).

### Serialization for Persistence

`MlsManager:signer_bytes() -> Result<Vec<u8>, String>` — serde JSON of the `SignatureKeyPair`.

`MlsManager:credential_bytes() -> Result<Vec<u8>, String>` — serde JSON of the `CredentialWithKey`.

`MlsManager:serialize_storage() -> Result<Vec<u8>, String>` — binary blob of the provider's MemoryStorage. Format: `u64 entry_count` followed by `(u64 key_len, u64 value_len, key_bytes, value_bytes)` for each entry. All integers big-endian.

### KeyPackage Generation

`MlsManager:generate_key_package() -> Result<Vec<u8>, String>`

Generates a KeyPackage for distribution to the server coordinator. The KeyPackage contains the member's public key material and credential. It is TLS-serialized for transmission. KeyPackages are single-use — each must be consumed by exactly one `add_member` call.

### Group Lifecycle

#### Create Group (Server Owner)

`MlsManager:create_group(server_id) -> Result<(), String>`

Creates a new MLS group with:
- `GroupId` = `server_id.as_bytes()`
- Ratchet tree extension enabled (`use_ratchet_tree_extension(true)`)
- The creating member's credential

Only the server owner/coordinator calls this. The group starts with 1 member (the creator).

#### Add Single Member

`MlsManager:add_member(server_id, key_package_bytes) -> Result<(Vec<u8>, Vec<u8>), String>`

Adds one member to the MLS group. Steps:
1. Deserialize and validate the `KeyPackageIn` against the ciphersuite.
2. Call `group.add_members()` — returns `(commit, welcome, group_info)`.
3. TLS-serialize the commit and welcome.
4. Return `(commit_bytes, welcome_bytes)`.

**Critical:** The caller MUST call `merge_pending_commit()` after broadcasting the commit. The commit is pending until merged — the group epoch does not advance until merge.

#### Batch Add Members

`MlsManager:add_members_batch(server_id, key_packages: &[(String, Vec<u8>)]) -> Result<(Vec<u8>, Vec<u8>, Vec<String>), String>`

Adds multiple members in a single commit (single epoch advance). Steps:
1. Get current member list to check for duplicates.
2. For each `(peer_id, kp_bytes)`, skip if already a member, otherwise deserialize and validate.
3. If no valid new members remain, return error.
4. Call `group.add_members()` with all validated KeyPackages at once.
5. Return `(commit_bytes, welcome_bytes, added_peer_ids)`.

All added members join from the same Welcome message. Single epoch advance is more efficient than adding one-by-one (which would require N epoch advances and N commit broadcasts).

#### Remove Member

`MlsManager:remove_member(server_id, peer_id) -> Result<Vec<u8>, String>`

Removes a member from the MLS group. Steps:
1. Find the member's leaf index by matching `credential.serialized_content()` against `peer_id.as_bytes()`.
2. Call `group.remove_members()` with the leaf index.
3. TLS-serialize and return the commit.

Caller must call `merge_pending_commit()` after broadcasting. After removal, the epoch advances and the removed member's key material is excluded from future encryptions (forward secrecy).

`MlsManager:remove_members_batch(server_id, peer_ids: &[&str]) -> Result<Vec<u8>, String>`

Removes multiple members in a single commit (single epoch advance). Collects all leaf indices, calls `group.remove_members()` with the full slice. Skips peers not found in the group. Used by the batch timer for recovery removals and stale member cleanup.

#### Join from Welcome

`MlsManager:join_from_welcome(server_id, welcome_bytes) -> Result<(), String>`

Called by a new member to join a group from a received Welcome message. Steps:
1. TLS-deserialize the `MlsMessageIn` and extract the `Welcome` body.
2. Create a `StagedWelcome` from the Welcome (with ratchet tree extension enabled, no separate ratchet tree).
3. Convert the staged welcome into a full `MlsGroup`.
4. Insert into the `groups` map.

### Epoch Management

#### Merge Pending Commit (Committer)

`MlsManager:merge_pending_commit(server_id) -> Result<(), String>`

Called by the committer (coordinator) after broadcasting an add/remove commit. Advances the local group state to the new epoch. Must be called before any further group operations.

#### Process Commit (Other Members)

`MlsManager:process_commit(server_id, commit_bytes) -> Result<(), String>`

Called by non-committer members when they receive a commit message. Steps:
1. TLS-deserialize the `MlsMessageIn`.
2. Convert to protocol message.
3. `group.process_message()` — returns processed content.
4. Verify it's a `StagedCommitMessage`, then `group.merge_staged_commit()`.
5. Epoch advances to match the committer's epoch.

### Encrypt / Decrypt

`MlsManager:encrypt(server_id, plaintext) -> Result<Vec<u8>, String>`

Creates an MLS application message. Uses `group.create_message()` with the signer. Returns TLS-serialized ciphertext. All group members can decrypt this message.

`MlsManager:decrypt(server_id, ciphertext) -> Result<(Vec<u8>, String), String>`

Decrypts an MLS application message. Steps:
1. TLS-deserialize the `MlsMessageIn`.
2. Convert to protocol message.
3. `group.process_message()` — returns processed content with sender credential.
4. Extract sender's peer_id from `credential.serialized_content()` (the `BasicCredential` identity bytes).
5. Verify it's an `ApplicationMessage`, extract plaintext bytes.
6. Returns `(plaintext, sender_peer_id)`.

Errors on `ProposalMessage` or `StagedCommitMessage` — those are handled by `process_commit`.

### SFrame Key Derivation

`MlsManager:export_secret(server_id, label, context, key_length) -> Result<Vec<u8>, String>`

Exports an epoch secret for SFrame key derivation (voice/video encryption). Parameters:
- `label`: `"sframe"` for media encryption keys
- `context`: typically empty (`b""`)
- `key_length`: typically 32 bytes (AES-128-GCM key)

All group members at the same epoch derive the **same secret** — this is how SFrame keys are synchronized without explicit key exchange. When the epoch changes (membership add/remove), the exported secret changes, providing forward secrecy for media streams.

### Group Query Functions

`MlsManager:has_group(server_id) -> bool` — checks if a group exists.

`MlsManager:member_count(server_id) -> usize` — number of members in the group. Returns 0 if no group.

`MlsManager:epoch(server_id) -> Result<u64, String>` — current epoch number. Monotonically increasing.

`MlsManager:group_members(server_id) -> Vec<String>` — list of peer IDs extracted from member credentials.

`MlsManager:remove_group(server_id)` — removes the group from both the in-memory map and the OpenMLS provider storage. The provider storage deletion is important: without it, `join_from_welcome` would hit a `GroupAlreadyExists` error when re-joining a server.

### Helper Functions

`read_u64(cursor) -> Result<u64, String>` — reads big-endian u64 from a byte cursor. Used by `from_persisted` for storage deserialization.

`read_bytes(cursor, len) -> Result<Vec<u8>, String>` — reads `len` bytes from a cursor.

### Unit Tests

- `test_create_group_and_has_group` — create group, verify existence and member count (1)
- `test_two_members_encrypt_decrypt` — full cycle: create group, add member, join from welcome, bidirectional encrypt/decrypt with sender identity verification
- `test_remove_member_forward_secrecy` — three members, remove one, verify removed member cannot decrypt post-removal messages (forward secrecy)
- `test_storage_serialization_roundtrip` — serialize/restore MLS state, verify group survives and encryption works after restore
- `test_credential_maps_to_peer_id` — verify `group_members()` returns the correct peer_id from credential
- `test_generate_key_package` — verify KeyPackage generation and re-deserialization
- `test_batch_add_six_members` — batch add 6 members, verify all 7 can communicate, single epoch advance
- `test_batch_add_skips_duplicates` — existing member in batch is skipped, new member added
- `test_batch_add_empty_returns_error` — empty batch returns error
- `test_batch_add_single_member` — batch of 1 works identically to single add
- `test_six_members_all_communicate` — every member sends a message, every other member decrypts it (N x N communication)
- `test_export_sframe_secret` — both members derive the same 32-byte SFrame key, epochs match
- `test_sframe_key_rotates_on_membership_change` — SFrame key changes when membership changes (epoch advance), all members agree on new key

---

## store.rs — CryptoStore (Olm Persistence Actor)

File: `rust/hollow_core/src/crypto/store.rs`

### Architecture

The `CryptoStore` is a fire-and-forget persistence actor that runs on a `spawn_blocking` thread. It owns a `rusqlite::Connection` (which is `!Send`) and receives save commands via an unbounded mpsc channel. The in-memory `OlmManager` is the authoritative source of truth; the DB is only for restart persistence.

### CryptoStoreCmd Enum

```rust
pub(crate) enum CryptoStoreCmd {
    SaveAccount(String),                         // account pickle JSON
    SaveSession { peer_id: String, pickle: String },  // session pickle JSON
}
```

### CryptoStore Structure

```rust
pub(crate) struct CryptoStore {
    cmd_tx: mpsc::UnboundedSender<CryptoStoreCmd>,
}
```

Only holds the send half of the channel. The receive half lives in the blocking task.

### open()

`CryptoStore:open(db_path, passphrase) -> Result<Self, String>`

Spawns the persistence actor:
1. Create an unbounded mpsc channel.
2. `tokio::task::spawn_blocking` — this OS thread owns the `MessageStore` connection.
3. Inside the blocking thread: open `MessageStore` (SQLCipher DB), then loop with `cmd_rx.blocking_recv()`.
4. On `SaveAccount(pickle)` — calls `store.save_olm_account(&pickle)`.
5. On `SaveSession { peer_id, pickle }` — calls `store.save_olm_session(&peer_id, &pickle)`.
6. Loop exits when the channel is closed (all senders dropped).

### save_account() / save_session()

`CryptoStore:save_account(pickle_json)` — sends `SaveAccount` command. Fire-and-forget (unbounded send, error ignored).

`CryptoStore:save_session(peer_id, pickle_json)` — sends `SaveSession` command. Fire-and-forget.

Both are called from `crypto_handler:persist_crypto_state()` after every Olm encrypt/decrypt operation.

---

## MLS Persistence (via MessageStore)

MLS state is persisted differently from Olm. Instead of the CryptoStore actor, MLS uses direct calls to `MessageStore::save_mls_identity()` from `crypto_handler:persist_mls_state()`. This writes three blobs to SQLCipher:
- **signer_bytes** — serde JSON of the `SignatureKeyPair`
- **credential_bytes** — serde JSON of the `CredentialWithKey`
- **storage_blob** — binary serialization of the OpenMLS MemoryStorage HashMap

On startup, `MlsManager::from_persisted()` restores from these blobs and loads MLS groups from the provider storage by server_id.

---

## Encryption Layer Summary

| Layer | Scope | Algorithm | Key Exchange | Library |
|-------|-------|-----------|--------------|---------|
| Message signing | All messages | Ed25519 | N/A (identity keys) | ed25519-dalek (via NativeKeypair) |
| DM encryption | 1:1 DMs | Olm Double Ratchet (Curve25519) | PreKey bundle (identity + OTK) | vodozemac |
| Server encryption | Server channels | MLS (X25519 + AES-128-GCM) | KeyPackage + Welcome | OpenMLS 0.8 |
| Voice/video encryption | Media streams | SFrame (AES-128-GCM) | Derived from MLS epoch secret | Custom (export_secret) |

### Key Security Properties

- **Forward secrecy (DMs):** Olm Double Ratchet — compromising current keys does not reveal past messages.
- **Forward secrecy (servers):** MLS epoch advances on membership changes — removed members cannot decrypt future messages.
- **Post-compromise security (MLS):** New epochs generate fresh key material, recovering security after a key compromise.
- **Message authenticity:** Ed25519 signatures with PeerId derivation verification prevent sender spoofing.
- **SFrame key rotation:** SFrame keys rotate automatically on every MLS epoch change (membership add/remove), ensuring removed voice participants lose decryption ability.
- **MLS epoch staleness after reconnection:** Sync requests, shard coordination, and voice channel state changes use plaintext `HavenMessage` (not MLS `MessageEnvelope`) because MLS epochs may be stale after reconnection.

### Critical Implementation Notes

- `outbound_only` tracking in OlmManager: outbound sessions produce PreKey (type 0) for ALL messages until replaced by inbound session or marked bidirectional via `SessionAck`.
- `merge_pending_commit` MUST be called by the committer after broadcasting any add/remove commit. Without it, the committer's group state is inconsistent.
- `remove_group` MUST delete from OpenMLS provider storage (not just the HashMap) to avoid `GroupAlreadyExists` on re-join.
- All MLS encrypted messages in a server room are broadcast to ALL members — targeted messages still encrypt for the whole group to keep ratchets in sync, with a `target` field for selective processing.
- CryptoStore persistence is fire-and-forget — if the blocking thread crashes, crypto state is lost on restart but the in-memory OlmManager continues functioning.
