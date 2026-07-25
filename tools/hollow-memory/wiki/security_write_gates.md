# Security Write Gates — every remote-reachable store mutation

**What this is:** the complete enumeration performed for 0.8.5, of every write
to the local database that an attacker can reach by sending us a frame, and the
gate each one sits behind. It exists so "we have no known holes" is a checked
claim rather than an assertion, and so any NEW ingest path can be checked
against a list instead of a memory.

**How to use it:** when you add a handler that writes to `MessageStore`, find
its row here. If it has no row, it has no gate — add both.

Rule of thumb for the whole surface: **the transport tells you WHO sent a
frame; it never tells you who AUTHORED the content inside it.** Every hole in
this file's history came from conflating the two.

---

## 1. Gated by the message signature (v2, REQUIRED)

`crypto_handler::check_backfill_signature` → `BackfillSig::is_acceptable()`, or
a direct `verify_message_signature_v2` on the live paths. As of 0.8.5 `Valid` is
the only acceptable verdict — see `REQUIRE_SIGNED_BACKFILL`.

| Write | Sites | Gate |
|---|---|---|
| `insert` (DM row) | swarm live DM arm; DmSyncBatch; DmSiblingSyncBatch; `fetch.rs` push DM; FileHeader sentinel (swarm + fetch) | v2 signature over `dm` + recipient master |
| `insert_channel_message` | swarm live channel arm; ChannelSyncBatch; `sync_handler` MLS batch; `fetch.rs` push channel | v2 signature over `ch` + `{sid}:{cid}` |
| `edit_channel_message` / `edit_dm_message` / `set_*_message_edited_at` | swarm live edit arms; both sync batches; `fetch.rs` | edit signature over `edited_at` + new text + the row's FULL extras |
| `hide_channel_message` / `hide_dm_message` | swarm live DeleteMessage arm | `ch-delete` / `dm-delete` signature over the row's current text + extras |
| `set_*_message_hidden_verified` | `apply_verified_channel_deletion` / `apply_verified_dm_deletion`, 4 sync apply sites | author's deletion proof, REJECT-ABSENT (0.8.4). Author comes from the ROW, never the item |
| `repair_channel_message_sender` | swarm ChannelSyncBatch; `sync_handler::repair_wedged_sender` | only when `sig_verified` — the repair can only ever install a cryptographically authentic attribution |
| `update_link_preview` / `update_channel_link_preview` | swarm live arms; `message_ops`; `fetch.rs` | runs only on `is_new` after a verified insert; the preview itself is bound by `lp_digest` inside the v2 payload |
| `add_reaction` | live envelope + Olm arms; **3 sync batches + `sync_handler`** (0.8.5); guest preview (0.8.5) | `reaction:{mid}:{emoji}:{ts}` signed by the reactor's MASTER — `message_ops::sync_reaction_accepted` for sync/guest |
| `remove_reaction` | live envelope + Olm arms | `unreaction:{mid}:{emoji}:{ts}`, same rule |
| Guest public-channel preview (RAM, no DB) | `swarm.rs` PublicChannelSyncResponse | 0.8.5: `guest_item_accepted` drops unverified items; hidden flag via `verified_guest_hidden_at`; reactions per-item |

## 2. Gated by content addressing

Bytes are named by their own SHA-256, so tampering is self-detecting and the
sender needs no signature.

| Write | Site | Gate |
|---|---|---|
| `save_emote_blob` | `emotes::handle_emote_assets` | `decode_asset_bundle` drops any (hash, bytes) pair whose hash ≠ SHA-256(bytes); plus size cap + WebP container check |
| Showcase assets | same codec | same |
| Vault / Share chunks | `vault`, `share_handler` | manifest root hash |

## 3. Gated by owner identity

| Write | Sites | Gate |
|---|---|---|
| `insert_file_metadata` | 3 sync batches, `sync_handler`, Olm FileHeader, MLS FileHeader, `fetch.rs` | 0.8.5: `file_handler::file_meta_write_allowed` — the UPSERT may only be performed by the identity that owns the card (device→master collapsed). See below |

**Why this one needed a gate.** `insert_file_metadata` is an UPSERT keyed on
`file_id` that deliberately overwrites name/ext/mime/size/dimensions, so the FCM
background-fetch node's minimal placeholder gets filled in later. Without an
owner check, the same overwrite was reachable by any authenticated peer sending
a FileHeader carrying someone else's `file_id` — a display-spoofing primitive
(relabel an attachment). It was also reachable through sync: the item's v2
signature binds `file_id`, **not** the `file_meta` blob hanging off the item, so
a batch that passes the backfill check can still carry a forged file name, size
and sender.

## 4. Gated by the CRDT author (not the transport sender)

| Write | Gate |
|---|---|
| `insert_crdt_op`, server state mutations | `ServerState::op_allowed` validates `op.author`, never the peer that delivered it |
| `delete_server_state` | `ServerDeleted` tombstone, owner-author validated at EVERY ingest |

## 5. Gated by a master signature

| Write | Gate |
|---|---|
| Device-list ingest | `verify_device_list` — master-signed, monotonic version, revocation tombstones |
| Olm key exchange | `REQUIRE_SIGNED_KEY_EXCHANGE` — device-signed bundle/request, recipient + freshness bound |
| `save_profile` | 0.8.5: `profile_signing_payload` / `verify_profile_signature`. See below |

**Why profiles needed signing.** `ProfileUpdate` has no sender field, so
attribution came from the transport — sound. But `ProfileRelay` exists so a peer
can hand us a cached copy of a THIRD party's profile, and it carries its own
`source_peer_id`. That field was attacker-chosen, the frame is plaintext, and
the only gate was an `updated_at` comparison the same attacker controls: one
`ProfileRelay { source_peer_id: <victim>, display_name: "Admin", updated_at:
i64::MAX }` overwrote any identity's name and avatar permanently, and no genuine
update could ever beat that timestamp again.

Now the owner signs, relayers forward the signature, receivers verify:
- The payload binds exactly the fields `ProfileRelay` carries (subject peer_id,
  updated_at, display name, status, about me, twitch, avatar HASH). Binding
  anything a relayer does not forward (banner, showcase) would make every relay
  fail to verify.
- Fields are **length-prefixed into a digest**, not `:`-joined — display name /
  status / about-me are free text and would otherwise be able to impersonate the
  next field's boundary.
- The signed **avatar hash is stored** (`profile_avatar_hash`), not re-derived:
  announces are light (hash only, no bytes), so a relayer's cached blob can lag
  the owner's. The receiver verifies the signature over the carried hash, then
  separately checks the bytes against it and drops **only the avatar** on a
  mismatch — a stale relayer still relays valid text, a swapping relayer is
  caught.
- `ProfileRelay` ingest: REQUIRED signature, and over-long fields are REJECTED
  rather than truncated (verifying a clamped copy would check a string the
  signer never signed, and truncation would make our stored copy diverge from
  the signature we forward on the next hop).
- `ProfileUpdate` ingest: absent is TOLERATED (the sender IS the subject there —
  nothing to spoof), invalid is refused, and the proof is persisted **only when
  it verifies**, so we can never launder an unverified signature into a relay.

## 6. Local-only — not reachable from a remote frame

Listed so a future sweep does not have to re-derive that they are safe:
`set_peer_verified` / `remove_peer_verified` (`api/verification.rs`, user
action), `add_personal_emote` / `remove_personal_emote` (`api/emotes.rs`),
`upsert_conference` / `delete_conference` (`api/conference.rs`),
`set_olm_key_pin` (`security_alerts`, local bookkeeping), `mark_file_complete` /
`mark_chunk_received` (local download path), `prune_*` (local retention).

**`save_channel_message` (`api/storage.rs`) is dead code** — a Dart-callable FFI
with a wrapper in `storage_service.dart` and no UI call site. It inserts a
channel row with no signature. Harmless today (Dart can only write to its own
DB), but it is the one path that could reintroduce unsigned rows, so it should
be deleted rather than left as a loaded gun.

---

## Related

- `feedback_signature_enforcement_not_logging` — verify must REJECT; `if
  sig.is_some()` IS the bypass; verify RAW text before any clamp
- `project_second_report_sync_sig_fixes` — v2 payload, pk-cache poisoning,
  `hidden_at` deletion proofs
- `project_signed_key_exchange_root_of_trust` — the trust chain these all hang
  from
- `feedback_sender_controlled_filename_sanitization` — the same "hash-verified ≠
  trusted" mistake, in the file path
