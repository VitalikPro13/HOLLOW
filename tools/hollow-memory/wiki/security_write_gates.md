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
| `save_asset_blob` (all asset kinds: emote/banner/sticker/gif/avatar; `save_emote_blob` = the emote-kind shorthand) | `emotes::handle_emote_assets` | REQUESTED-ONLY: the hash must be in swarm's `requested_asset_kinds` map (recorded when WE sent the request, cleared on WS Disconnected) — unsolicited blobs are dropped, so no peer can stuff our DB. The per-blob size cap comes from the RECORDED kind (`AssetKind::recv_cap`), never from anything the sender supplies. Then `decode_asset_bundle` drops any (hash, bytes) pair whose hash ≠ SHA-256(bytes), plus the WebP container check. A requested hash answered with invalid bytes frees its request slot (retry from another holder) |
| Showcase assets | same codec | same |
| Server banner blob (`kind='banner'`, asset-rail Phase 2) | same `handle_emote_assets` path | same requested-only gate (1 MB cap from the recorded kind). The CRDT carries ONLY the hash — `settings["server_banner"]` rides `ServerSettingChanged`, MANAGE_SERVER-gated at author AND ingest (`op_allowed`). The pre-join `server_banner_thumb_b64` on `PublicChannelListResponse` is RAM-only (never a store write), decode-refused over 80 KB |
| Animated server icon blob (`kind='avatar'`, asset-rail follow-up) | same `handle_emote_assets` path | same requested-only gate (512 KB cap from the recorded kind). The CRDT carries ONLY the hash — `settings["server_avatar_anim"]` rides `ServerSettingChanged`, MANAGE_SERVER-gated at author AND ingest. The still icon stays base64 in `settings["server_avatar"]` (unchanged pre-existing path); nothing animated rides pre-join wire paths |
| Server sticker blob (`kind='sticker'`, asset-rail Phase 5) | same `handle_emote_assets` path | same requested-only gate (512 KB cap from the recorded kind). The CRDT carries ONLY the hash — `CrdtPayload::StickerAdded/StickerRemoved`, `MANAGE_EMOTES`-gated at author AND ingest (`op_allowed` validates `op.author`, the 64-hex hash, both ≤32-char control-free labels, and 1..=4096 dims). `MAX_SERVER_STICKERS = 50` enforced at authoring AND apply so replicas converge on the same refusal. No pre-join wire path carries stickers |
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
| `ChannelVisibilityLabelsChanged` / `ChannelPostingLabelsChanged` / `ChannelGrantSet` / `ChannelGrantRevoked` (issue #32) | `MANAGE_CHANNELS` on `op.author` at author AND ingest — same arm as the other channel-property ops |
| `LabelAssigned` / `LabelUnassigned` | self-toggle allowed ONLY for an EXISTING label with `access == false` (`ServerState::can_self_toggle_label`, shared by `handle_label_op` and `op_allowed` so the gates cannot drift); ACCESS labels gate channels, so self-assign would be privilege escalation — they require `MANAGE_ROLES`, and an UNKNOWN label_id fails closed. `LabelUpdated.access` is `Option<bool>` on the wire: `None` (a client that predates the field) PRESERVES the stored flag, so an old client's recolor can never silently demote an access label back to self-service |

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
- `ProfileUpdate` ingest: the signature is **REQUIRED there too**, and the
  profile fields are not stored without it. The tempting argument is that the
  sender IS the subject on that path (no `source_peer_id` to lie about), so an
  absent signature cannot spoof anyone. That covers a malicious PEER and misses
  a malicious RELAY: the plaintext `ProfileUpdate` fallback used for DM peers
  and pre-MLS servers is an unencrypted JSON body the relay can rewrite in
  flight. The gate covers the profile FIELDS only — the sender's device list is
  ingested first and unconditionally, since it carries its own master signature
  and a profile-less node's announce is what collapses its devices into one
  online identity. `saved` also gates the member-list display-name write, or the
  spoof just lands one layer up.
- Announces sign on the fly when the stored row predates 0.8.5
  (`own_profile_proof`) — without that, requiring the signature would blank
  every upgraded user at their peers until they happened to edit their profile.

## 6. Local-only — not reachable from a remote frame

Listed so a future sweep does not have to re-derive that they are safe:
`set_peer_verified` / `remove_peer_verified` (`api/verification.rs`, user
action), `add_personal_emote` / `remove_personal_emote` (`api/emotes.rs`),
`add_personal_sticker` / `remove_personal_sticker` /
`remove_personal_sticker_pack` / `rename_personal_sticker_pack`
(`api/stickers.rs`, user action on a local-only vault),
`upsert_conference` / `delete_conference` (`api/conference.rs`),
`set_olm_key_pin` (`security_alerts`, local bookkeeping), `mark_file_complete` /
`mark_chunk_received` (local download path), `prune_*` (local retention).

**`save_channel_message` (`api/storage.rs`) is dead code** — a Dart-callable FFI
with a wrapper in `storage_service.dart` and no UI call site. It inserts a
channel row with no signature. Harmless today (Dart can only write to its own
DB), but it is the one path that could reintroduce unsigned rows, so it should
be deleted rather than left as a loaded gun.

## 7. File SERVING gate + guest file ingest (0.9.1)

Serving is a READ, but it belongs in this enumeration: it was the one
remote-reachable disclosure path with **no gate at all** — any authenticated
peer that learned a `file_id` (guests see them in plaintext public messages)
could pull ANY file we hold, DM attachments included.

| Path | Gate |
|---|---|
| `HavenMessage::FileRequest` serving (`swarm.rs`, before the disk read) | Blocklist refused. Then by the stored row's context: `dm` → requester must be the conversation counterparty or our own sibling (`same_identity`); `channel` → `is_member(resolved master)` OR `is_channel_public(cid)` (effective — voice never public); unknown context / missing server state fails CLOSED. `requester_is_member` also picks the header transport: Olm `FileHeader` for members/DM parties, plaintext `HavenMessage::PublicFileHeader` for non-members on public channels (they may hold no Olm session; the content is public — the relay already sees it) |
| `PublicFileHeader` ingest (registers the stream decrypt key → bytes land on disk → `insert_file_metadata`) | REQUESTED-ONLY, mirroring the asset rail: accepted only when `pending_public_file_requests` holds the file_id with a matching server, < 120 s old, and the server is in `guest_rooms` (entry removed on receipt; map cleared on WS disconnect). An unsolicited plaintext header would otherwise register a decrypt key and let a stranger stream arbitrary bytes onto our disk. Armed exclusively by `NodeCommand::RequestPublicFile` |

Guest-side sync/live `file_meta` blobs are display-only and never DB writes; the
v2 item signature binds `file_id`, not the blob, so receivers require
`fm.fid == item.file_id` (same reasoning as the §3 owner guard). Harness
coverage: `file_request_gate_refuses_stranger_and_serves_guest_public`.

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
