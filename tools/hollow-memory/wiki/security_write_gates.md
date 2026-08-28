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
| `update_link_preview_and_sig` / `update_channel_link_preview_and_sig` | `message_ops::handle_envelope_link_preview_set` (all 3 ingest paths: Olm DM/channel, MLS channel, plaintext `pub_lp_set`); the local-author `handle_attach_*_link_preview` | issue #45 late cards. Author comes from the ROW (channel: `get_channel_message_sender` resolved to master; DM: `is_mine` + sibling rule), never from the frame. Then a full `verify_message_signature_v2` over the row's text/extras with the NEW `lp_digest` — REJECT on failure. `kind`/`author`/`video_url` are inside that digest, so a relay cannot repaint a plaintext public-channel card |
| `add_reaction` | live envelope + Olm arms; **3 sync batches + `sync_handler`** (0.8.5); guest preview (0.8.5) | `reaction:{mid}:{emoji}:{ts}` signed by the reactor's MASTER — `message_ops::sync_reaction_accepted` for sync/guest |
| `remove_reaction` | live envelope + Olm arms | `unreaction:{mid}:{emoji}:{ts}`, same rule |
| Guest public-channel preview (RAM, no DB) | `swarm.rs` PublicChannelSyncResponse | 0.8.5: `guest_item_accepted` drops unverified items; hidden flag via `verified_guest_hidden_at`; reactions per-item |

## 2. Gated by content addressing

Bytes are named by their own SHA-256, so tampering is self-detecting and the
sender needs no signature.

| Write | Site | Gate |
|---|---|---|
| `save_asset_blob` (all asset kinds: emote/banner/sticker/gif/avatar/frame/profile; `save_emote_blob` = the emote-kind shorthand) | `emotes::handle_emote_assets` | REQUESTED-ONLY: the hash must be in swarm's `requested_asset_kinds` map (recorded when WE sent the request, cleared on WS Disconnected) — unsolicited blobs are dropped, so no peer can stuff our DB. The per-blob size cap comes from the RECORDED kind (`AssetKind::recv_cap`), never from anything the sender supplies. Then `decode_asset_bundle` drops any (hash, bytes) pair whose hash ≠ SHA-256(bytes), plus the WebP container check. A requested hash answered with invalid bytes frees its request slot (retry from another holder) |
| Showcase assets | same codec | same |
| Server banner blob (`kind='banner'`, asset-rail Phase 2) | same `handle_emote_assets` path | same requested-only gate (1 MB cap from the recorded kind). The CRDT carries ONLY the hash — `settings["server_banner"]` rides `ServerSettingChanged`, MANAGE_SERVER-gated at author AND ingest (`op_allowed`). The pre-join `server_banner_thumb_b64` on `PublicChannelListResponse` is RAM-only (never a store write), decode-refused over 80 KB |
| Animated server icon blob (`kind='avatar'`, asset-rail follow-up) | same `handle_emote_assets` path | same requested-only gate (512 KB cap from the recorded kind). The CRDT carries ONLY the hash — `settings["server_avatar_anim"]` rides `ServerSettingChanged`, MANAGE_SERVER-gated at author AND ingest. The still icon stays base64 in `settings["server_avatar"]` (unchanged pre-existing path); nothing animated rides pre-join wire paths |
| Server sticker blob (`kind='sticker'`, asset-rail Phase 5) | same `handle_emote_assets` path | same requested-only gate (512 KB cap from the recorded kind). The CRDT carries ONLY the hash — `CrdtPayload::StickerAdded/StickerRemoved`, `MANAGE_EMOTES`-gated at author AND ingest (`op_allowed` validates `op.author`, the 64-hex hash, both ≤32-char control-free labels, and 1..=4096 dims). `MAX_SERVER_STICKERS = 50` enforced at authoring AND apply so replicas converge on the same refusal. No pre-join wire path carries stickers |
| Avatar frame blob (`kind='frame'`, issue #54) | same `handle_emote_assets` path | same requested-only gate (256 KB cap from the recorded kind — the tight EMOTE ceiling, not the rail's 512 KB, because a frame is decoration on every avatar you have ever seen). The PROFILE carries only the ID: `UserProfile.avatar_frame` is `""` / `b:<hue>` / 64-hex, and `social::sanitize_incoming_frame` is the sole validator on ingest. That validator matters more than it looks — the field is plaintext on the `HavenMessage::ProfileUpdate` fallback AND it keys a network PULL, so an unvalidated string would be a request-anything primitive. Anything unrecognised is treated as ABSENT (preserve what we stored), never as a clear, so a malformed field from a future client cannot wipe somebody's frame |
| Animated avatar/banner blob (`kind='profile'`, asset-rail follow-up) | same `handle_emote_assets` path | same requested-only gate (1 MB cap from the recorded kind, which is `image_convert::MAX_PROFILE_ANIM_BYTES` by construction — a test pins the equality so the wire cap and the authoring limit cannot drift). ONE kind covers avatar and banner: they share a replication profile (one of each per person you have ever met) so they share a budget. The PROFILE carries only the hash: `UserProfile.avatar_anim` / `banner_anim` are `""` or 64-hex, and `social::sanitize_incoming_anim` is the sole validator on ingest — same reasoning as `sanitize_incoming_frame`, because the field is plaintext on the `HavenMessage::ProfileUpdate` fallback AND keys a network PULL. Anything unrecognised is ABSENT (preserve), never a clear. Deliberately OUTSIDE `profile_signing_payload`, matching `avatar_frame`: a rewritten hash swaps decoration a rewriter already holds, and the STILL companion the signature DOES cover keeps rendering underneath |
| Vault / Share chunks | `vault`, `share_handler` | manifest root hash |

## 3. Gated by owner identity

| Write | Sites | Gate |
|---|---|---|
| `insert_file_metadata` | 3 sync batches, `sync_handler`, Olm FileHeader, MLS FileHeader, `fetch.rs` | 0.8.5: `file_handler::file_meta_write_allowed` — the UPSERT may only be performed by the identity that owns the card (device→master collapsed). See below. 0.9.4 added the `thumb_b64` column (blurred-placeholder thumbnail): remote-controlled bytes, so EVERY ingest site filters it to `img && len <= FILE_THUMB_MAX_B64_LEN` (32 KB b64) before the write, and the SQL COALESCEs so a thumb-less re-header can't blank a stored one |
| `peer_auto_dl` (RAM, not the store) | `HavenMessage::AutoDownloadPref` arm | advertised value clamped to 0..=2048 MB; worst case a peer lies about its own preference and we push/skip bytes to THAT peer — no cross-peer effect, cleared on disconnect |
| Media-forwarder stream state: register / allowlist / unregister (RAM, forwarder engine) | `forwarder::dispatch::admit_register` + `admit_owner_op` | `admit_register` pins `origin.peer == Olm-authenticated sender` (with a shared SFrame group key, a spoofed registration would attribute the registrant's pixels to a victim); `admit_owner_op` restricts allowlist changes and unregister to that same owner |
| Media-forwarder INGEST supply (`fwd_ingest_offer`) | `forwarder::dispatch::admit_ingest_offer` | The one place the owner≡ingest binding loosens (feeder election, §9.6): the owner, OR the single peer the owner delegated as `feeder` in its own owner-authored register. Grant is SUPPLY ONLY — auth/unregister stay on `admit_owner_op`, so a feeder can never change who may watch or tear the stream down. Empty `feeder` (every pre-feeder client) reduces to the original owner-only rule exactly. A malicious feeder can only degrade availability: SFrame auth tags make tampered frames undecodable rather than attacker-controlled, and it never holds group keys |
| Embedded (peer) forwarder: accepting a stream at all | `node::embedded_forwarder` expectation gate | A register is admitted ONLY for an `(originator, kind)` this client advertised `fwd_capable` for on a LIVE watch — a peer forwarder only ever forwards a stream its own user is watching |

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
| Async friend request — carried bundle + device list (`FriendRequest` optional fields, 2026-08-28) | The carried `SignedDeviceList` rides the SAME `verify_device_list` gate as any device-list ingest (new SITE, unchanged master-signature/monotonic-version/revocation checks). The carried Olm bundle is gated by `verify_carried_bundle` — device signature over the DOMAIN-SEPARATED `hollow-carried-keybundle:` payload (distinct prefix + `to_master` third segment, so it can never verify as a live bundle or the reverse), sender device present and un-revoked in that master-signed list, `to_master == our master`, freshness by `MAX_CARRIED_BUNDLE_AGE_SECS` (7d) NOT the live 300 s rule; REJECT-on-fail, an absent signature is never a bypass. Only store write it gates is the `app_settings` KV record `friendreq_in:{master}` (no friends-table schema change). The outbound-session bootstrap re-runs `verify_carried_bundle` at USE time (the row sat on disk since receipt) and is additionally glare-gated: it builds a session only when the requester is offline AND session-less, else it defers to the live key exchange. The relay mailbox that carries the request holds ciphertext only and is read-gated by a master-signed ownership proof (`verify_signed_device_list`, C++ mirror KAT-pinned to the Rust payload) — availability, never authority. See `project_pending_joins_async_friending`. |
| `save_profile` | 0.8.5: `profile_signing_payload` / `verify_profile_signature`. See below |
| MLS commit catch-up ingest (`MlsCommitCatchup`, epoch-race fix 2026-08-07) | sender must be a server member; every frame revalidated by OpenMLS through the SAME `handle_mls_commit_frame` path as a live `MlsCommit` (epoch guard, group-member leaf signature, eviction check); additionally each frame must be exactly `own_epoch + 1` — a gapped/garbage frame is refused BEFORE it can reach the drop-group recovery, making catch-up strictly safer than the broadcast path it supplements; ≤16 frames per message |
| MLS epoch hints (`SyncRequest.mls_epoch` / `MlsEpochProbe`) | member-gated (`handle_epoch_hint`); a hint can NEVER drop a group (that would be a remote group-reset primitive) — a low hint only triggers authority-gated commit-replay/re-add service (10 s per-peer cooldown), a high hint only a throttled self-probe to the authority |

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
- **Carried profile on a friend request** (`FriendRequest.carried_profile`,
  2026-08-28) is a NEW SITE on this SAME gate, not a new gate: a stranger's
  request now carries the sender's own signed profile so the incoming card
  renders a real name instead of a raw peer id (a stranger has never sent us a
  `ProfileUpdate`, and in the offline case is gone before it can push one).
  `social::store_carried_profile` runs the identical rule as `ProfileRelay`
  ingest — REQUIRED `verify_profile_signature`, over-long fields REJECTED (not
  truncated), persisted via `save_profile` behind the verify — and ADDS a
  sender-binding check (`resolve(source_peer_id) == request sender's master`) so
  a sender can carry only its OWN identity's profile, never a captured third
  party's. LIGHT: the avatar HASH rides (in the proof), never the bytes. A bad
  or absent signature drops ONLY the profile; the friend request itself still
  lands (the sig is verified, never logged-and-stored — `if sig.is_some()` would
  be the bypass). Old senders omit the field; old receivers ignore it.

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
