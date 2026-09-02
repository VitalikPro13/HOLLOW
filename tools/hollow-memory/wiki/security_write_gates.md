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
| `.hollowpack` import (`api::import_hollowpack`, LOCAL file picker / drag-drop; writes `save_asset_blob` kind `frame`/`profile` + the `owned_art` row) | `hollowpack::verify_pack_file` = the ONE trust boundary, shared with the `hollowpack inspect` CLI | A pack is remote-AUTHORED bytes even though the user picks it locally. Caps before any decode (8 files, 4 MB each, 16 MB total, 20 MB zip, 64 KB manifest); every file's sha256 RECOMPUTED and the whole pack refused on any mismatch; WebP decode with per-role ceilings (frame square and ≤512, avatar/still ≤512, banner/still ≤1200x480 at 2.5:1 (the 2026-09-01 ceilings; older packs at the old exact sizes stay valid because every bound is a ceiling)), animated roles must animate and still roles must not, frames re-pass `validate_frame_centre`; a manifest that disagrees with the bytes about size/dims/animation is REFUSED, never corrected; nothing is written by a manifest-supplied name (files are keyed by hash); bytes are stored AS-IS, never re-encoded (identity is the hash of the processed bytes; the phase-2 credential binds it). Import does not touch the profile |

## 3. Gated by owner identity

| Write | Sites | Gate |
|---|---|---|
| `insert_file_metadata` | 3 sync batches, `sync_handler`, Olm FileHeader, MLS FileHeader, `fetch.rs` | 0.8.5: `file_handler::file_meta_write_allowed` — the UPSERT may only be performed by the identity that owns the card (device→master collapsed). See below. 0.9.4 added the `thumb_b64` column (blurred-placeholder thumbnail): remote-controlled bytes, so EVERY ingest site filters it to `img && len <= FILE_THUMB_MAX_B64_LEN` (32 KB b64) before the write, and the SQL COALESCEs so a thumb-less re-header can't blank a stored one |
| `peer_auto_dl` (RAM, not the store) | `HavenMessage::AutoDownloadPref` arm | advertised value clamped to 0..=2048 MB; worst case a peer lies about its own preference and we push/skip bytes to THAT peer — no cross-peer effect, cleared on disconnect |
| Media-forwarder stream state: register / allowlist / unregister (RAM, forwarder engine) | `forwarder::dispatch::admit_register` + `admit_owner_op` | `admit_register` pins `origin.peer == Olm-authenticated sender` (with a shared SFrame group key, a spoofed registration would attribute the registrant's pixels to a victim); `admit_owner_op` restricts allowlist changes and unregister to that same owner |
| Media-forwarder INGEST supply (`fwd_ingest_offer`) | `forwarder::dispatch::admit_ingest_offer` | The one place the owner≡ingest binding loosens (feeder election, §9.6): the owner, OR the single peer the owner delegated as `feeder` in its own owner-authored register. Grant is SUPPLY ONLY — auth/unregister stay on `admit_owner_op`, so a feeder can never change who may watch or tear the stream down. Empty `feeder` (every pre-feeder client) reduces to the original owner-only rule exactly. A malicious feeder can only degrade availability: SFrame auth tags make tampered frames undecodable rather than attacker-controlled, and it never holds group keys |
| Embedded (peer) forwarder: accepting a stream at all | `node::embedded_forwarder` expectation gate | A register is admitted ONLY for an `(originator, kind)` this client advertised `fwd_capable` for on a LIVE watch — a peer forwarder only ever forwards a stream its own user is watching |
| Friend DECLINE ingest: `remove_friend` on the requester (`HavenMessage::FriendReject`, async decline 2026-08-29) | `handle_incoming_request`'s `FriendReject` arm | **Attribution, then freshness.** ATTRIBUTION: the reject carries the decliner's OWN master-signed device list (same field, same shape and the same single verification path as `FriendRequest`'s carried list). When present it is REQUIRED to pass `verify_device_list` (signature plus the pubkey to peer_id binding, so the signer IS the master it claims) AND to name the relay-authenticated sender device in `devices` and not in `revoked`; any failure DROPS the frame, with no fallback to the resolver (`if list.is_some()` must not be the bypass). It is then ingested through `ingest_device_list`, so the resolver, the device store and the DM room key agree afterwards, and the master it names becomes the row key. A frame with NO list is a pre-carried-list client and falls back to `resolver::resolve`, which only works once the two have actually met. The list exists because they usually have not: an async decline answers a stranger who was never online with us, so a cold resolver returned the raw DEVICE id while the friend row is MASTER-keyed, and the reject was dropped with `row None` (field-verified on two fresh installs, 2026-08-29). FRESHNESS: the delete then runs only when the reject NAMES the request that row is made of, either `("pending","outgoing",stored)` with `requested_at` `0` or `>= stored`, or `("accepted",_,stored)` with `requested_at != 0` and `>= stored` (the mutual race: both sides auto-converged and the user then declined that same request, so honouring it keeps both sides symmetric instead of leaving one friended and one declined, re-sending `FriendAccept` forever; the mutual converge stamps both rows `MAX(ours, theirs)` so either side can name it). `save_friend` FREEZES `requested_at` on a non-pending row, so a reject replayed after a cancel and re-add carries the OLDER stamp and stays refused, and legacy `requested_at == 0` never reaches the accepted arm. A refused reject logs and returns WITHOUT emitting `FriendRequestRejected`. Companion gate on the same invariant: an inbound `FriendAccept` whose stored row is `declined` is refused, since `pending_friend_accepts` is re-seeded at every startup and would otherwise resurrect a tombstone. The reject stays plaintext on the relay exactly as before: the mailbox holds it for the TTL, which is retention of what the relay already sees, not new exposure. See `project_pending_joins_async_friending`. |

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
| `insert_crdt_op` + `MemberAdded` carried by `ServerJoinResolved` (parked joins, rung 1, 2026-08-29) | NOT a second ingest path: the arm parses ONE `CrdtOp` and hands it to `apply_remote_crdt_op`, the very function extracted from the plaintext `CrdtOpBroadcast` arm, so it inherits `op_allowed` on `op.author` (never the publisher), `insert_crdt_op`, the single re-flood and the payload's own event. Two gates run BEFORE it: we must already hold `server_states[server_id]` (a resolution for a server we are not in is nothing to us), and `resolver::resolve(sender)` must be a CURRENT CRDT member — a non-member cannot resolve anything, and anyone in the room can publish on a topic. `join_resolutions` is max-wins on `requested_at`, so an older copy replayed out of the three-day ring can never undo a newer answer |
| `LabelAssigned` / `LabelUnassigned` | self-toggle allowed ONLY for an EXISTING label with `access == false` (`ServerState::can_self_toggle_label`, shared by `handle_label_op` and `op_allowed` so the gates cannot drift); ACCESS labels gate channels, so self-assign would be privilege escalation — they require `MANAGE_ROLES`, and an UNKNOWN label_id fails closed. `LabelUpdated.access` is `Option<bool>` on the wire: `None` (a client that predates the field) PRESERVES the stored flag, so an old client's recolor can never silently demote an access label back to self-service |

## 5. Gated by a master signature

| Write | Gate |
|---|---|
| Device-list ingest | `verify_device_list` — master-signed, monotonic version, revocation tombstones |
| Olm key exchange | `REQUIRE_SIGNED_KEY_EXCHANGE` — device-signed bundle/request, recipient + freshness bound |
| Async friend request — carried bundle + device list (`FriendRequest` optional fields, 2026-08-28) | The carried `SignedDeviceList` rides the SAME `verify_device_list` gate as any device-list ingest (new SITE, unchanged master-signature/monotonic-version/revocation checks). The carried Olm bundle is gated by `verify_carried_bundle` — device signature over the DOMAIN-SEPARATED `hollow-carried-keybundle:` payload (distinct prefix + `to_master` third segment, so it can never verify as a live bundle or the reverse), sender device present and un-revoked in that master-signed list, `to_master == our master`, freshness by `MAX_CARRIED_BUNDLE_AGE_SECS` (7d) NOT the live 300 s rule; REJECT-on-fail, an absent signature is never a bypass. Only store write it gates is the `app_settings` KV record `friendreq_in:{master}` (no friends-table schema change). The outbound-session bootstrap re-runs `verify_carried_bundle` at USE time (the row sat on disk since receipt) and is additionally glare-gated: it builds a session only when the requester is offline AND session-less, else it defers to the live key exchange. The relay mailbox that carries the request holds ciphertext only and is read-gated by a master-signed ownership proof (`verify_signed_device_list`, C++ mirror KAT-pinned to the Rust payload) — availability, never authority. See `project_pending_joins_async_friending`. |
| Parked server join — carried device list (`ServerJoinRequest.device_list`, rung 1, 2026-08-29) | Same `verify_device_list` gate as any device-list ingest (a new SITE, unchanged master-signature / monotonic-version / revocation checks), plus the sender binding: the relay-stamped sender device must be IN `devices` and NOT in `revoked`. Only then does `member_master` come from `list.master_peer_id` and the list get ingested through `ingest_device_list`. PRESENT-but-BAD is a DROP (no reject, no event, no member row) — `if list.is_some()` must never be the bypass; ABSENT falls back to `resolver::resolve`, which is byte-for-byte the pre-2026-08-29 path. This is load-bearing rather than cosmetic because a request read out of the `~join` ring comes from somebody the member has NEVER been online with, so the resolver returns the raw DEVICE id: without the list the ban check, the private/cap gates and the `MemberAdded` key would all be computed against a device id that matches nothing. Ring exposure: the parked copy deliberately carries NO `twitch_proof_json` (any socket in the room can `topic_catchup` the ring, and a Twitch account tied to a peer id is exposure we do not accept), and a member reading a proofless request on a Twitch-gated server takes no action at all rather than writing a sticky `twitch_required` refusal into the ring |
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
`mark_chunk_received` (local download path), `prune_*` (local retention),
`upsert_pending_join` / `delete_pending_join` (parked joins, rung 1 — the row
records OUR OWN outgoing request and is written only by our own join /
timeout / discard paths and by `handle_join_refused`, which acts solely on the
in-memory entry we minted and is nonce-gated: a refusal naming an ask other
than the one we currently have pending is ignored, which matters because the
refusal is now BUFFERED by the relay and replays on our next join of that room
(normally the user asking again). A remote frame can flip an existing row to
`rejected`, or DELETE it when the reason is interactive (`nsfw_confirm:` /
`twitch_required:` are questions, and a persisted question would re-open its
dialog at every boot), but it can never CREATE one — so it cannot make us
join, rejoin a room, or store anything for a server we never asked about).

**`keep_redeem_code` (`api/shop.rs`, the `hollow://redeem/<code>` deep link,
2026-09-02)** is the one local write a REMOTE AUTHOR can trigger without a relay
frame: a link on a web page (the shop's thank-you page, or anybody's) opens the
app and hands it a string. It is a keep-only list for the phase-2 support
credential, so the gate is shape plus budget, nothing else: the code must match
`^[A-Za-z0-9_-]{8,128}$`, the table holds at most 64 rows (the 65th is refused
with a visible error, never silently dropped or rotated), a repeat is a no-op
(`INSERT OR IGNORE`), and nothing is fetched, sent or announced. Store builds
never reach it: the Dart handler treats the link as unrecognised when
`ShopAvailability.available` is false. The shop client's fetches
(`fetch_shop_catalog`, `fetch_shop_art`) are READS against a pinned origin and
write nothing: art bytes are refused unless their SHA-256 matches the requested
hash and they are never put on the asset rail (owned art enters ONLY through
`import_hollowpack` above).

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


## 8. Transport temp files + the update channel (0.10.2)

| Write | Site | Gate |
|---|---|---|
| Stream reassembly temp file (`.ws_recv_{id}.tmp`, `.webrtc_recv_{id}.tmp`) | `ws_stream_transfer::parse_id` (Rust, WS relay lane), `wire_transfer_id.dart::parseWireTransferId` (Dart, WebRTC lane) | The 64-byte wire id NAMES the file, so the parser is the gate: `[A-Za-z0-9:_-]` only (own ids are 32-hex, `hex:index`, `link_<code>`), anything else drops the frame before a path exists. Before 0.10.2 the raw id reached `format!` unchecked; on Windows a `/../` id walked out of the files dir (Win32 collapses `..` lexically), POSIX was safe only because `.ws_recv_` is not a directory. Precondition was an established peer, impact create/truncate/delete of any `*.tmp` path. Same family as `safe_file_name()` (section 6 of `feedback_sender_controlled_filename_sanitization`) |
| Update manifest (`fetch_version_manifest`) | `api/updater.rs::verify_manifest_signature` | `manifest.json.sig` (base64 Ed25519 over the manifest's EXACT bytes) must `verify_strict` against a key in `MANIFEST_SIGNING_PUBKEYS`; the sidecar rides the same URL + cache-buster. The download host can serve bytes, it cannot mint a signature. Dart then treats only a strictly NEWER `latest` as an update (`version_compare.dart`), so a replayed old signed manifest is not a downgrade lever. Signing: `rust/hollow_manifest` + `scripts/sign_manifest.ps1`, key outside the repo |
| Update zip on disk, then extracted into the app dir (`download_update` + `apply_update`) | `api/updater.rs::download_inner` | https only; SHA-256 accumulated while streaming and compared to the `sha256_<platform>` field of the SIGNED manifest before the file is kept (mismatch, cancel or any error deletes it and ends the stream with `DownloadProgress.error`). An entry without a checksum for the platform is refused in Dart before the first byte. `extract_zip_to` keeps its own path-traversal rejection |

## 9. Artist shop: packs and support credentials (2026-09-02)

| Write | Site | Gate |
|---|---|---|
| `.hollowpack` import: asset-rail blobs (`save_asset_blob`) + `owned_art` rows | `api/network.rs::import_hollowpack` / `import_hollowpack_bytes` → `hollowpack::verify_pack` | LOCAL-ONLY trigger (a file the person picked, dropped, or the redeem path fetched from the pinned shop origin), never a remote frame. The pack is verified WHOLE before a byte lands: caps (8 files, 4 MB each, 16 MB total, 64 KB manifest), every SHA-256 RECOMPUTED from the bytes (the manifest's claim is never trusted), decoded dimensions against the role's ceiling, animated/still against the role, the see-through-centre gate re-applied to frames. Bytes are stored AS-IS under the recomputed hash (content addressing, §2). Importing never touches the profile. Wiki `hollowpack.md`. |
| `user_profiles.support_creds` (a peer's support credentials) | `social::save_incoming_profile` → `support_creds::sanitize_incoming_support_creds(raw, master)` (both ingest paths: `handle_envelope_profile_update` and the plaintext `HavenMessage::ProfileUpdate` arm pass the RAW field) | The ONE validator. Raw field over 16 KB or not a JSON array = ABSENT (preserve). Each entry: shape (`t` known, `item` 64-hex, `parts` sorted/unique/1..32 and `item == sha256(parts)`), `issuer_sig` under the PINNED root (`verify_strict`), `key_sig` under the issuer over `t||item||period||key`, RSA-3072 key parses, then the blind signature verifies over the credential message built from THIS profile's RESOLVED master peer id. Invalid entries dropped in silence, deduped by item, capped (3 item + 1 supporter), survivors RE-SERIALIZED so nothing a sender appended reaches the row. A transplant (minted for another identity) fails the last link. NOT part of the profile signature by design (the entry binds the identity itself). Harness: `support_credential_replicates_and_transplant_is_dropped`. Wiki `support_credentials.md`. |
| `support_creds_own` rows + our own `support_creds` (redeem) | `api/shop.rs::redeem_code` | LOCAL-ONLY trigger (a code the person typed or a `hollow://redeem/<code>` link they clicked, behind `shopAvailableProvider`; the link only KEEPS a shape-checked code, 64-row cap). The shop's chain is verified against the pinned root BEFORE the code is spent; the finished entry is verified again exactly as a viewer will; only then stored and republished. The pinned `SHOP_ORIGIN`, no redirects, bounded bodies (256 KB JSON, 40 MB pack). |
| `redeem_codes` (kept codes) | `api/shop.rs::keep_redeem_code` from the deep link | Shape check (`valid_redeem_code`: 8..128 of `[A-Za-z0-9_-]`) + 64-row cap; nothing reads the code until the person presses Redeem. |

Shop side (Node, `anonlisten-sites/shop/src/lib/server/redeem.js`, the audit's M4 gate): `isKeyRefused` then `isKeyBurned` BEFORE `activateKey`; the blinded message is signed in memory first; `burnKey` + `incrementRedeemed` are the authority; the shop stores only the key's SHA-256 and the pack token's SHA-256. Rate buckets per code hash and shop-wide, never per IP.

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
