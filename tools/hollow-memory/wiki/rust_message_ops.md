# Message Operations — Send, Edit, Delete, React, Pin

Source: `rust/hollow_core/src/node/message_ops.rs` (~1235 lines). All handler functions are `pub(crate) async fn` called from `swarm.rs` match arms. Each takes individual state variables as parameters (no SwarmContext struct). Helper functions (`message_signing_payload`, `sign_message`, `verify_message_signature`, `send_encrypted_message`, `send_mls_broadcast`, `peer_is_reachable`, `send_message_to_peer`) are imported from `crypto_handler.rs`.

---

## Message Signing Payload Format

Defined in `crypto_handler.rs:message_signing_payload()`. Canonical format:

```
hollow-msg:{msg_type}:{context}:{sender}:{ts}:{text}
```

**msg_type values and their contexts:**

| msg_type | context | Used by |
|---|---|---|
| `"dm"` | peer_id (recipient for send, local_peer for receive) | DM send + DM receive verification |
| `"ch"` | `"{server_id}:{channel_id}"` | Channel send + channel receive verification |
| `"dm-delete"` | peer_id | DM delete (prevents replay as send) |
| `"ch-delete"` | `"{server_id}:{channel_id}"` | Channel delete (prevents replay as send) |

**Reaction signing uses a different format** (not `message_signing_payload`):
- Add: `"reaction:{mid}:{emoji}:{ts}"`
- Remove: `"unreaction:{mid}:{emoji}:{ts}"`

**Critical invariant:** Dart timestamps MUST be hydrated from Rust's signed value (the `ts` in the `MessageSent`/`ChannelMessageSent` event), not `DateTime.now()`. The signing payload embeds the timestamp, so any mismatch breaks verification.

---

## Signing and Verification Functions

### `crypto_handler.rs:sign_message()`

Parameters: `keypair: &NativeKeypair`, `pub_key_b64: &str`, `payload: &str`.

Returns `(Option<String>, Option<String>)` — `(sig_b64, pk_b64)`. Signs `payload.as_bytes()` with Ed25519 keypair, base64-encodes the signature. Always returns `Some` for both.

### `crypto_handler.rs:verify_message_signature()`

Parameters: `sender_peer_str`, `sig_b64: Option<&str>`, `pk_b64: Option<&str>`, `payload: &str`.

Returns `bool`. Three-step verification:
1. Base64-decode public key bytes.
2. **PeerId derivation check:** Reconstructs PeerId from the public key protobuf (identity multihash: `0x00` prefix + length byte + pk_bytes, then bs58 Bitcoin-alphabet encode). Compares derived PeerId to `sender_peer_str` — rejects if mismatch. This prevents spoofing (attacker cannot sign with their key and claim to be another peer).
3. Base64-decode signature, call `NativeKeypair::verify_peer_signature(&pk_bytes, &sig_bytes, payload.as_bytes())`.

---

## handle_send_message() — DM Send

`message_ops.rs:handle_send_message()`

Called from: `swarm.rs` on `NodeCommand::SendMessage`.

Parameters: `olm`, `crypto_store`, `event_tx`, `ws_cmd_tx`, `ws_room_peers`, `pending_messages`, `key_request_in_flight`, `bundle_keypair`, `pub_key_b64`, `local_peer_str`, `device_peer_id`, `peer_id_str`, `text`, `message_id`, `reply_to_mid`, `link_preview`.

`peer_id_str` is the recipient's **MASTER** identity (the friend-list/UI key). `local_peer_str` is our master; `device_peer_id` is THIS device's transport id.

### Flow

1. **Generate timestamp** — `SystemTime::now()` as millis-since-epoch `i64`.
2. **Sign** — `message_signing_payload("dm", &peer_id_str, &local_peer, dm_timestamp, &text)` then `sign_message()`.
3. **Build envelope** — `MessageEnvelope::DirectMessage { text, ts, sig, pk, mid, reply_to, file_id: None, link_preview, convo }`. Two variants built via `build_dm(convo)`: the recipient copy (`convo:None`) and the sibling self-echo copy (`convo:Some(recipient_master)`).
4. **Serialize** — both envelopes to JSON for Olm encryption input.
5. **Persist locally** — Opens `~/.hollow/messages.db` (SQLCipher). `store.insert()` keyed by the recipient **master** `peer_id_str`, `is_mine=true`, Rust timestamp, sig/pk, mid, reply_to. Link preview via `store.update_link_preview()`.
6. **Multi-device fan-out (Phase 6, Step 3)** — `fan_out_dm_envelope(...)` instead of a single send:
   - **Target set** = `collect_target_devices()`: the persisted device list (`resolver::devices_for(master)`) UNIONed with every peer CURRENTLY in `dm_room_code(local,recipient)` that resolves to that master (live presence is authoritative — handles stale/polluted device lists + rotated ids; a ghost id is harmless, it just queues and never connects). Empty → fall back to the master id as-is (single-device parity).
   - **Self fan-out** to our own OTHER devices (siblings), excluding `device_peer_id`. Siblings get the `convo`-tagged variant so they file the echo under the right conversation, not under ourselves.
   - Per device, `send_dm_to_device(..., is_sibling)` runs the branch keyed by the DEVICE id: **EXACT-device** online (`ws_room_for_peer(...).is_some()`, NOT identity-wide `peer_is_reachable` — else an offline sibling whose other device is online takes the online path and gets dropped) → `send_encrypted_message()` **AND** queue in `pending_messages[device]` (capped 20/device); offline-with-session → (recipient) encrypt to `dm_room_code` (push trigger) + queue, **(sibling) QUEUE ONLY, no push trigger**; no session → queue + KeyRequest. `pending_messages` is keyed PER DEVICE; the per-device drain on PeerJoined/RoomMembers/KeyBundle/re-key delivers it.
     - **`is_sibling` suppresses the push trigger for self-echoes (Step 5 fix).** The recipient loop passes `is_sibling=false`; the self-fan-out loop passes `is_sibling=true`. An OFFLINE sibling must NOT do the "encrypt to DM room (push trigger)" room-send — the relay would fire an FCM push and the sibling phone would buzz for OUR OWN outgoing message. A sibling mirror is never notification-worthy, so it queues silently (delivered on the sibling's reconnect + closed by Step 5 backfill).
     - **The online branch ALSO queues (retry-on-re-key self-heal).** A session we believe is confirmed bidirectional can be silently dead on the PEER's side ("KeyRequest while we hold a session — peer lost theirs"), acute right after a device link when the freshly-linked sibling and its source churn their ratchet. A DM encrypted on that doomed ratchet is undecryptable and, without the queue, lost forever (the relay never ACKs) — this was the "first sibling DM after a link never mirrors, every later one does" bug. The re-key/decrypt-fail drain (`swarm.rs`) re-delivers it on the FRESH session; receiver dedups by `message_id`, so a healthy-session duplicate is harmless. Cap bounds a long-lived session that never reconnects to drain.
7. **Emit event** — `NetworkEvent::MessageSent { to_peer, message_id, timestamp, signature, public_key }`, keyed on the master. Hydrates Dart's optimistic entry with sig/pk.

### Key details

- `file_id` is always `None` in the envelope — file attachments use separate `FileHeader` envelopes.
- The message_id is generated by Dart (UUID), passed to Rust, and round-tripped back via `MessageSent` event.
- Link previews are sender-side only; receivers never make HTTP requests for previewed URLs (privacy invariant).
- **All DM paths fan out the same way** via `fan_out_dm_envelope`: edit/delete/reaction (`handle_edit/delete_dm_message`, `handle_add/remove_dm_reaction`) and files/images (`file_handler::handle_send_file` DM branch, per-device loop). Edit/delete/reaction pass `sibling_envelope_json=None` (no `convo` field on those envelopes) — the sibling resolves the convo by `mid` on receive (`MessageStore::get_dm_message_peer` + `swarm::dm_event_convo`). Self-echo edit/delete authorization: the receive guard (`is_mine==false`) is relaxed to also allow `is_mine==true` WHEN `same_identity(sender, local_master)` (a verified sibling); genuine peers still rejected.
- **`DirectMessagePayload.convo`** (`#[serde(default)]`, types.rs): the OTHER party's master, set ONLY on the sibling self-echo copy. `None` on normal sends → receiver uses `resolve(sender)` (backward-compatible).
- **`resolver::devices_for(master)`** is the reverse of `resolve()`: all known device ids for a master, excluding the bare master. EMPTY for an unknown master. **Sender-link registration:** `crypto_handler::ingest_device_list` also registers (and persists to `device_links`, emitting `DeviceListUpdated`) the SENDER device→master link — a device that delivered a master-signed list provably belongs to that master even if absent from the (stale) signed `devices`. This is what lets the live-union match `resolve(sender)==master` AND lets Dart presence collapse the live device.

---

## handle_send_channel_message() — Channel Send

`message_ops.rs:handle_send_channel_message()`

Called from: `swarm.rs` on `NodeCommand::SendChannelMessage`.

Parameters: `olm`, `crypto_store`, `mls`, `server_states`, `event_tx`, `ws_cmd_tx`, `ws_room_peers`, `bundle_keypair`, `pub_key_b64`, `local_peer_str`, `server_id`, `channel_id`, `text`, `message_id`, `reply_to_mid`, `link_preview`.

### Flow

1. **Server lookup** — `server_states.get(&server_id)`. Emits `NetworkEvent::Error` if not found.
2. **Permission check** — `server.can_post_in_channel(local_peer_str, &channel_id)`. Emits error and returns early if denied.
3. **Generate timestamp** — millis-since-epoch `i64`.
4. **Sign** — `message_signing_payload("ch", &format!("{}:{}", server_id, channel_id), &local_peer, timestamp, &text)`.
5. **Build envelope** — `MessageEnvelope::ChannelMessage { sid, cid, text, ts, sig, pk, mid, reply_to, file_id: None, link_preview }`.
6. **Encrypt and broadcast:**
   - **MLS path (preferred):** If `mls.has_group(&server_id)`, calls `send_mls_broadcast()` — encrypts once for the MLS group, sends single WS message to the server room. All members decrypt.
   - **MLS fallback on error:** If MLS encrypt fails, falls back to Olm fan-out (logs warning).
   - **Legacy Olm fan-out:** Iterates `server.members.keys()`, skipping self, calls `send_encrypted_message()` to each reachable peer individually.
7. **Persist locally** — `store.insert_channel_message()` with `is_mine=true` and the Rust timestamp. Link preview persisted if present via `store.update_channel_link_preview()`.
8. **Emit event** — `NetworkEvent::ChannelMessageSent { server_id, channel_id, message_id, timestamp, signature, public_key }`.

### MLS vs Olm vs Public Channel broadcasting pattern

All 5 channel operations (send, edit, delete, add reaction, remove reaction) branch on `server.is_channel_public(&channel_id)` before choosing the transport path:

**Public channel path:** When `is_channel_public()` returns `true`, the handler builds a plaintext `HavenMessage` variant (e.g., `PublicChannelMessage`, `PublicChannelEdit`, `PublicChannelDelete`, `PublicChannelAddReaction`, `PublicChannelRemoveReaction`) and sends via `WsCommand::SendToRoom` broadcast. Messages are Ed25519-signed but NOT MLS-encrypted. All room participants (members and guests) receive the same plaintext broadcast — no per-peer fan-out, no duplication.

**Private channel path (default):** The existing dual-path MLS/Olm pattern. Try MLS, fall back to Olm fan-out:

```
let use_mls = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
if use_mls {
    match send_mls_broadcast(...) {
        Ok(()) => {}
        Err(e) => { /* Olm fan-out to all members */ }
    }
} else {
    /* Olm fan-out to all members */
}
```

The public/private branch happens BEFORE the MLS/Olm decision — public channels skip MLS entirely.

---

## handle_edit_channel_message() — Channel Edit

`message_ops.rs:handle_edit_channel_message()`

Called from: `swarm.rs` on `NodeCommand::EditChannelMessage`.

### Flow

1. **Server lookup** — errors if not found.
2. **Generate edit timestamp** — fresh `SystemTime::now()` millis.
3. **Sign the edit** — uses `message_signing_payload("ch", "sid:cid", &local_peer, edit_timestamp, &new_text)`. The payload uses the NEW text and NEW timestamp, so verifiers reconstruct from the current message state.
4. **Update local DB** — `store.edit_channel_message(&message_id, &new_text, edit_timestamp, sig, pk)`. Old text preserved in `message_edits` table.
5. **Build envelope** — `MessageEnvelope::EditMessage { mid, text: new_text, ts, sig, pk, sid: Some, cid: Some }`. The `sid`/`cid` being `Some` distinguishes channel edits from DM edits.
6. **MLS broadcast or Olm fan-out** — same dual-path pattern.
7. **Emit event** — `NetworkEvent::ChannelMessageEdited { server_id, channel_id, message_id, new_text, edited_at, signature, public_key }`.

---

## handle_edit_dm_message() — DM Edit

`message_ops.rs:handle_edit_dm_message()`

Called from: `swarm.rs` on `NodeCommand::EditDmMessage`.

### Flow

1. **Generate edit timestamp**.
2. **Sign the edit** — `message_signing_payload("dm", &peer_id_str, &local_peer, edit_timestamp, &new_text)`. Uses new text + new timestamp.
3. **Update local DB** — `store.edit_dm_message(&message_id, &new_text, edit_timestamp, sig, pk)`.
4. **Update pending_messages queue** — Scans `pending_messages` for the peer, finds any queued `DirectMessage` envelope with matching `message_id`, replaces the envelope in-place with edited text + edit signature + edit timestamp. Without this, `PeerJoined` drain would send the stale pre-edit text.
5. **Build envelope** — `MessageEnvelope::EditMessage { mid, text, ts, sig, pk, sid: None, cid: None }`. `sid=None` marks this as a DM edit.
6. **Send via Olm** — only sends if Olm session exists (no queuing for edits).
7. **Emit event** — `NetworkEvent::DmMessageEdited { peer_id, message_id, new_text, edited_at, signature, public_key }`.

### Key difference from channel edit

No server lookup or permission check needed. No MLS path. Takes `&mut pending_messages` to update queued messages for offline peers — DM sync will deliver the current edited version from the DB when the peer reconnects.

---

## handle_delete_channel_message() — Channel Delete

`message_ops.rs:handle_delete_channel_message()`

Called from: `swarm.rs` on `NodeCommand::DeleteChannelMessage`.

### Flow

1. **Server lookup** — errors if not found.
2. **Generate delete timestamp**.
3. **Fetch current text** — `store.get_channel_message_text(&message_id)`. Needed for signing payload (so archive viewer can verify the delete against the same state).
4. **Sign with "ch-delete"** — `message_signing_payload("ch-delete", "sid:cid", &local_peer, delete_timestamp, &current_text)`. The `"ch-delete"` type prevents replay as a send signature.
5. **Hide in local DB** — `store.hide_channel_message(&message_id, delete_timestamp, sig, pk)`. Text preserved in `message_deletions` table (soft delete).
6. **Build envelope** — `MessageEnvelope::DeleteMessage { mid, ts, sig, pk, sid: Some, cid: Some }`. Note: does NOT include the text (receivers don't need it to process the delete).
7. **MLS broadcast or Olm fan-out**.
8. **Emit event** — `NetworkEvent::ChannelMessageDeleted { server_id, channel_id, message_id, deleted_at }`.

---

## handle_delete_dm_message() — DM Delete

`message_ops.rs:handle_delete_dm_message()`

Called from: `swarm.rs` on `NodeCommand::DeleteDmMessage`.

### Flow

1. **Generate delete timestamp**.
2. **Fetch current text** — `store.get_dm_message_text(&message_id)`.
3. **Sign with "dm-delete"** — `message_signing_payload("dm-delete", &peer_id_str, &local_peer, delete_timestamp, &current_text)`.
4. **Hide in local DB** — `store.hide_dm_message(&message_id, delete_timestamp, sig, pk)`.
5. **Build envelope** — `MessageEnvelope::DeleteMessage { mid, ts, sig, pk, sid: None, cid: None }`.
6. **Send via Olm** — no queue if peer offline.
7. **Emit event** — `NetworkEvent::DmMessageDeleted { peer_id, message_id, deleted_at }`.

---

## handle_add_channel_reaction() — Channel Reaction Add

`message_ops.rs:handle_add_channel_reaction()`

Called from: `swarm.rs` on `NodeCommand::AddChannelReaction`.

### Flow

1. **Server lookup** — errors if not found.
2. **Generate reaction timestamp**.
3. **Sign** — `format!("reaction:{}:{}:{}", message_id, emoji, reaction_ts)`. Note: does NOT use `message_signing_payload()` — uses a separate format.
4. **Save to local DB** — `store.add_reaction(&message_id, &emoji, &local_peer, reaction_ts, sig, pk)`.
5. **Build envelope** — `MessageEnvelope::AddReaction { mid, emoji, ts, sig, pk, sid: Some, cid: Some }`.
6. **MLS broadcast or Olm fan-out**.
7. **Emit event** — `NetworkEvent::ChannelReactionAdded { server_id, channel_id, message_id, emoji, reactor: local_peer, added_at }`.

---

## handle_add_dm_reaction() — DM Reaction Add

`message_ops.rs:handle_add_dm_reaction()`

Called from: `swarm.rs` on `NodeCommand::AddDmReaction`.

### Flow

1. **Generate reaction timestamp**.
2. **Sign** — `format!("reaction:{}:{}:{}", message_id, emoji, reaction_ts)`.
3. **Save to local DB** — same `store.add_reaction()`.
4. **Build envelope** — `MessageEnvelope::AddReaction { mid, emoji, ts, sig, pk, sid: None, cid: None }`.
5. **Send via Olm** — no queue if peer offline.
6. **Emit event** — `NetworkEvent::DmReactionAdded { peer_id, message_id, emoji, reactor: local_peer, added_at }`.

---

## handle_remove_channel_reaction() — Channel Reaction Remove

`message_ops.rs:handle_remove_channel_reaction()`

Called from: `swarm.rs` on `NodeCommand::RemoveChannelReaction`.

### Flow

Identical structure to `handle_add_channel_reaction()` except:
- Signing payload: `format!("unreaction:{}:{}:{}", message_id, emoji, remove_ts)`.
- DB call: `store.remove_reaction()`.
- Envelope: `MessageEnvelope::RemoveReaction`.
- Event: `NetworkEvent::ChannelReactionRemoved { ..., removed_at }`.

---

## handle_remove_dm_reaction() — DM Reaction Remove

`message_ops.rs:handle_remove_dm_reaction()`

Called from: `swarm.rs` on `NodeCommand::RemoveDmReaction`.

Same pattern as DM reaction add with `"unreaction:..."` signing, `store.remove_reaction()`, `MessageEnvelope::RemoveReaction`, `NetworkEvent::DmReactionRemoved`.

---

## Incoming Envelope Handlers (MLS-decrypted and public channel path)

These handle envelopes received via MLS group decryption in `swarm.rs`. They are called from the MLS decrypt match block (around line 5414 in swarm.rs). DM envelopes via Olm are handled inline in swarm.rs (around line 3087).

**Public channel reuse:** The 5 `HavenMessage::PublicChannel*` variants received in `swarm.rs` are unpacked and delegated to the SAME `handle_envelope_*` functions below. No separate receive handlers exist for public channels — the existing handlers are transport-agnostic.

**Multi-device sender resolution (caller's responsibility):** A channel message is SIGNED by, and must be attributed to, the sender's MASTER (the send path signs `message_signing_payload(..., &local_peer, ...)` where `local_peer` is the master). But the transport author differs by path: the MLS leaf credential is the sender's DEVICE id, and the public-channel relay frame's `from` is also the DEVICE id. So BOTH callers in `swarm.rs` resolve `sender_master = resolver::resolve(<device>)` and pass the MASTER as `sender_peer_id`/`peer_str` to the handlers below (the MLS decrypt arm and each `HavenMessage::PublicChannel*` arm). The push-fetch node does the same in `fetch.rs::try_process_channel_msg` (both the public branch and the MLS-leaf `sender` branch). Without this, the row is stored + the event emitted under the DEVICE id (raw `12D3KooW…` in the bubble) AND the signature fails verification (signed against master, verified against device). Single-device senders resolve to themselves (no-op).

### handle_envelope_channel_message()

`message_ops.rs:handle_envelope_channel_message()`

Called when: `MessageEnvelope::ChannelMessage` is decrypted from an MLS group message.

Parameters: `event_tx`, `bundle_keypair`, `local_peer`, `sender_peer_id`, `sid`, `cid`, `text`, `ts`, `sig`, `pk`, `mid`, `reply_to`, `file_id`, `link_preview`.

Flow:
1. **Verify signature** — Reconstructs `message_signing_payload("ch", "sid:cid", &sender_peer_id, ts, &text)` and calls `verify_message_signature()`. Logs failure but does NOT reject the message (verification is informational, not gating).
2. **Determine authorship** — `is_mine = resolver::same_identity(&sender_peer_id, local_peer)` (multi-device: a message from ANY of our own devices is ours). `sender_peer_id` here is the already-resolved MASTER (see "Multi-device sender resolution" above).
3. **Persist** — `store.insert_channel_message()`. Returns row count; `is_new = rows > 0` for deduplication. Link preview stored only for new messages.
4. **Emit event** (only if new) — `NetworkEvent::ChannelMessageReceived { server_id, channel_id, from_peer, text, timestamp, message_id, reply_to_mid, link_preview, signature, public_key }`.

### handle_envelope_edit_message()

`message_ops.rs:handle_envelope_edit_message()`

Called when: `MessageEnvelope::EditMessage` is decrypted from MLS.

Flow:
1. **Ownership check** — `store.get_channel_message_sender(&mid)` must equal `peer_str`. Rejects with log only if sender exists but doesn't match (prevents editing others' messages). If sender is `None` (message not yet synced — timing race where edit arrives before sync batch), silently skips — the sync batch will deliver the already-edited version.
2. **Persist** — `store.edit_channel_message()`.
3. **Emit event** (only if edit applied AND sid/cid present) — `NetworkEvent::ChannelMessageEdited`.

Note: No signature verification on the MLS path here (MLS group membership already authenticates the sender). Ownership is verified via DB lookup. The same "sender is None → skip" logic applies to the plaintext edit handler in swarm.rs.

### handle_envelope_delete_message()

`message_ops.rs:handle_envelope_delete_message()`

Called when: `MessageEnvelope::DeleteMessage` is decrypted from MLS.

Flow:
1. **Ownership check** — `store.get_channel_message_sender(&mid)` must equal `sender_peer_id`. Logs `[HOLLOW-SECURITY] REJECTED MLS DeleteMessage` and returns early if mismatch.
2. **Persist** — `store.hide_channel_message()`.
3. **Emit event** (if sid/cid present) — `NetworkEvent::ChannelMessageDeleted`.

### handle_envelope_add_reaction()

`message_ops.rs:handle_envelope_add_reaction()`

Called when: `MessageEnvelope::AddReaction` is decrypted from MLS.

Flow:
1. **Persist** — `store.add_reaction(&mid, &emoji, peer_str, ts, sig, pk)`.
2. **Emit event** (if sid/cid present) — `NetworkEvent::ChannelReactionAdded { ..., reactor: peer_str }`.

No ownership check needed (any member can react).

### handle_envelope_remove_reaction()

`message_ops.rs:handle_envelope_remove_reaction()`

Called when: `MessageEnvelope::RemoveReaction` is decrypted from MLS.

Flow:
1. **Persist** — `store.remove_reaction()`.
2. **Emit event** (if sid/cid present) — `NetworkEvent::ChannelReactionRemoved`.

---

## Incoming DM Envelopes (Olm path, inline in swarm.rs)

DM messages do not use MLS. They are decrypted via Olm in `swarm.rs` and handled inline (not via message_ops handlers).

### DirectMessage receive (swarm.rs ~line 3087)

1. **Text truncation** — Enforced 4,000 character limit: `if msg_text.len() > 4000 { msg_text[..4000].to_string() }`.
2. **Signature verification** — If `sig.is_some()`, reconstructs `message_signing_payload("dm", &local_peer, &peer_str, ts, &msg_text)`. NOTE: context for receive is `local_peer` (recipient), but sender built it with `peer_id_str` (also the recipient). Both resolve to the same value — the recipient's peer_id. Logs failure but does not reject.
3. **Persist** — `store.insert(&peer_str, &msg_text, false, ts, sig, pk, mid, reply_to, file_id)`. `is_mine=false`. Deduplication via row count (`Ok(0)` = duplicate). Link preview stored if new.
4. **Emit event** — `NetworkEvent::MessageReceived` (only if new, not duplicate).

### EditMessage receive via Olm (swarm.rs ~line 3254)

1. Determine channel vs DM by presence of `sid`:
   - **Channel edit:** `store.get_channel_message_sender(&mid)` must equal `peer_str`. Calls `store.edit_channel_message()`.
   - **DM edit:** `store.get_dm_message_is_mine(&mid)` must be `Some(false)` (the message must be from the remote peer, not ours). Calls `store.edit_dm_message()`.
2. Emits `ChannelMessageEdited` or `DmMessageEdited` depending on sid presence.

### DeleteMessage receive via Olm (swarm.rs ~line 3318)

1. Determine channel vs DM by presence of `sid`:
   - **Channel delete:** `store.get_channel_message_sender(&mid)` must equal `peer_str`.
   - **DM delete:** `store.get_dm_message_is_mine(&mid)` must be `Some(false)`.
2. Calls `store.hide_channel_message()` or `store.hide_dm_message()`.
3. Emits `ChannelMessageDeleted` or `DmMessageDeleted`.

### AddReaction receive via Olm (swarm.rs ~line 3371)

1. **Emoji length check** — Rejects emoji strings > 10 characters with security log.
2. `store.add_reaction()`.
3. Emits `ChannelReactionAdded` or `DmReactionAdded` depending on sid presence.

### RemoveReaction receive via Olm (swarm.rs ~line 3410)

1. `store.remove_reaction()`.
2. Emits `ChannelReactionRemoved` or `DmReactionRemoved`.

---

## MessageEnvelope Variants (types.rs)

All variants are `#[serde(rename = "...")]` for compact wire format.

| Variant | serde name | Key fields | sid/cid meaning |
|---|---|---|---|
| `DirectMessage` | `"dm"` | text, ts, sig, pk, mid, reply_to, file_id, link_preview | N/A (DM only) |
| `ChannelMessage` | `"ch"` | sid, cid, text, ts, sig, pk, mid, reply_to, file_id, link_preview | Identifies server + channel |
| `EditMessage` | `"edit"` | mid, text, ts, sig, pk, sid, cid | `Some` = channel, `None` = DM |
| `DeleteMessage` | `"del"` | mid, ts, sig, pk, sid, cid | `Some` = channel, `None` = DM |
| `AddReaction` | `"react"` | mid, emoji, ts, sig, pk, sid, cid | `Some` = channel, `None` = DM |
| `RemoveReaction` | `"unreact"` | mid, emoji, ts, sig, pk, sid, cid | `Some` = channel, `None` = DM |

The `sid`/`cid` Option pattern is used by EditMessage, DeleteMessage, AddReaction, and RemoveReaction to multiplex between channel and DM contexts in a single envelope variant.

---

## NetworkEvent Emissions Summary

| Handler | Event emitted | Key fields for Dart |
|---|---|---|
| `handle_send_message` | `MessageSent` | to_peer, message_id, timestamp, signature, public_key |
| `handle_send_channel_message` | `ChannelMessageSent` | server_id, channel_id, message_id, timestamp, signature, public_key |
| `handle_edit_channel_message` | `ChannelMessageEdited` | server_id, channel_id, message_id, new_text, edited_at, signature, public_key |
| `handle_edit_dm_message` | `DmMessageEdited` | peer_id, message_id, new_text, edited_at, signature, public_key |
| `handle_delete_channel_message` | `ChannelMessageDeleted` | server_id, channel_id, message_id, deleted_at |
| `handle_delete_dm_message` | `DmMessageDeleted` | peer_id, message_id, deleted_at |
| `handle_add_channel_reaction` | `ChannelReactionAdded` | server_id, channel_id, message_id, emoji, reactor, added_at |
| `handle_add_dm_reaction` | `DmReactionAdded` | peer_id, message_id, emoji, reactor, added_at |
| `handle_remove_channel_reaction` | `ChannelReactionRemoved` | server_id, channel_id, message_id, emoji, reactor, removed_at |
| `handle_remove_dm_reaction` | `DmReactionRemoved` | peer_id, message_id, emoji, reactor, removed_at |
| `handle_envelope_channel_message` | `ChannelMessageReceived` | server_id, channel_id, from_peer, text, timestamp, message_id, reply_to_mid, link_preview, signature, public_key |

---

## DB Passphrase Derivation

Every handler opens SQLCipher the same way:
```
let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
let passphrase = hex::encode(&proto[..32.min(proto.len())]);
```
DB path: `~/.hollow/messages.db`.

---

## Security Invariants

1. **Delete signing uses distinct msg_type** — `"ch-delete"` / `"dm-delete"` prevents replaying a delete signature as a send.
2. **Ownership verification on receive** — Edits and deletes are rejected if the sender does not match the original message author. Channel: `store.get_channel_message_sender(&mid)`. DM: `store.get_dm_message_is_mine(&mid)` must be `Some(false)`.
3. **Emoji length limit** — Olm path rejects AddReaction emoji > 10 chars (MLS path via handle_envelope_add_reaction does NOT enforce this limit separately — it relies on the Olm path limit for DMs and trusts MLS group membership for channels).
4. **Text truncation** — DM text capped at 4,000 chars on receive (Olm path in swarm.rs). Channel messages are NOT truncated on receive.
5. **Soft deletes** — `hide_channel_message()` / `hide_dm_message()` preserve text in `message_deletions` table. Messages are hidden, not erased.
6. **Edit history** — `edit_channel_message()` / `edit_dm_message()` preserve old text in `message_edits` table.
7. **Deduplication** — `insert()` and `insert_channel_message()` return row count; 0 = duplicate, event only emitted for new messages.
8. **DM edits/deletes have no offline queue** — If peer has no Olm session or is unreachable, the edit/delete is persisted locally but never transmitted. Only `handle_send_message()` queues into `pending_messages`.
9. **Channel permission check** — Only `handle_send_channel_message()` checks `server.can_post_in_channel()`. Edit/delete/reaction handlers do NOT re-check permissions (they verify ownership instead).
10. **PeerId-pubkey binding** — `verify_message_signature()` derives PeerId from the public key protobuf and checks it matches the claimed sender, preventing key substitution attacks.

---

## Pin/Unpin (in sync_handler.rs, not message_ops.rs)

Pin and unpin are CRDT operations, not message envelopes. They live in `sync_handler.rs:handle_pin_message()` and `sync_handler.rs:handle_unpin_message()`. Dispatched from `swarm.rs` on `NodeCommand::PinMessage` / `NodeCommand::UnpinMessage`. They modify the `ServerState` CRDT and broadcast via the standard CRDT sync path.

## RequestFile (in file_handler.rs, not message_ops.rs)

File requests are handled by `file_handler.rs:handle_request_file()`. Dispatched from `swarm.rs` on `NodeCommand::RequestFile`.
