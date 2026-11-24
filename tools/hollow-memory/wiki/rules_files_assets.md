# Area rules: file transfer mechanics, images, emotes, stickers, frames

Moved out of CLAUDE.md on 2026-09-29, when the file was split by area. CLAUDE.md sends
every session here BEFORE it touches file sending/receiving, storage caps, image
encoding, avatars/banners/frames, the showcase board, stickers, GIFs or emotes. The
file SECURITY rules (`file_header_refused`, `file_asks`, self-certifying ids, at-rest
encryption, the auto-download gate, `safe_file_name`) and the asset-rail privacy rules
stay in CLAUDE.md. Wiki `rust_file_handler`, `emotes`, `hollowpack`.

## At-rest writes and zips from others (0.14)

- Every at-rest byte change (replace, chunked create, remove, move, the boot sweep's swap)
  runs under `at_rest::swap_lock` together with the read of the key it retires; each write
  seals into a temp named by its own key; a read takes the header and the bytes from ONE
  handle. Two writers sharing one temp lost a file's key and a member was told "gone" for a
  file the poster held (9dca9022).
- A zip from someone else goes through `zip_budget.rs`: a per-entry cap plus a whole-file
  budget counted in the bytes entries YIELD, and the index walked from the tail and refused
  before `ZipArchive::new` (HOL-SEC-205). A shards bundle names no sender: manifests only
  fill where none is held, shards land only through the vault's shard-write checks
  (HOL-SEC-206). Wiki `security_write_gates` §73.

## Packs, support credentials, shop codes (moved from CLAUDE.md, 0.14)

- `.hollowpack`: identity = sha256 of the PROCESSED bytes; `import_hollowpack` verifies,
  NEVER re-encodes. `support_creds`: ONE validator `sanitize_incoming_support_creds`
  (OFFLINE against the PINNED root, chain + THIS master, BEFORE spending) and a master
  signature REQUIRED, unsigned = REFUSE and preserve; `support_creds_own` is PER DEVICE
  (UNION minus tombstones). Twitch = the SAME credential: chip t=3, join gate t=4 against
  the joiner's MASTER; one CREDENTIAL per listing. Shop codes are minted by the artist's
  Ko-fi webhook (`kofi.js`): `redeem_codes` = the authority, `burnKey` = ONE lock; a live
  listing needs `kofi_code`. `project_shop_kofi_code_model`,
  `project_support_credentials_phase2`, `project_twitch_signed_credential`; wiki
  `hollowpack`, `support_credentials`.

## File transfer mechanics

- A pushed SERVER-CHANNEL file registers its stream only for a channel ON SCREEN on this
  device (0.14.1, Vitalik: nothing a peer posts lands on disk unseen): Rust
  `file_handler::channel_push_allows` (MLS arm + Olm arm), fed by FFI
  `set_channels_on_screen` from Dart `channelsOnScreenProvider` (desktop selection + split
  pane, the phone chat route whose page is on top; nothing while hidden, minimized,
  backgrounded or locked, or under any centre tab incl. Settings; meetings and guest views
  never). Otherwise it is declined like #41 (card kept, bytes
  deleted, `auto_download_off` pin); the viewport sweep (`requestVisibleFiles`, desktop pane
  AND phone route) pulls on view within the limit and re-runs when the channel comes back
  on screen; share auto-start asks the same; a cut push is re-asked only while on screen;
  the post-link `recent_files_sweep` takes DM files only. The push fetch node keeps no channel bytes. A
  new path that writes peer content from a server to disk asks the same question. The set
  (`node/on_screen.rs`) is process-global and defaults to "nothing" in builds, "everything" under `cfg(test)`
  (tests that predate it); its own tests set channels under `OnScreenReset`. Wiki
  `security_write_gates` §77.
- The sender side needs the `FileCompleted` emit too: a new `FileHeader`/`StoredFile`
  field misses the sender's UI unless the send path emits it. `feedback_sender_file_completed`.
- Share-backed large files (>34 MB): `FileHeader.share_ref` bypasses the size checks in 3
  places; skip `PendingFileStream` when `share_ref.is_some()`; >34 MB prompts
  `confirmLargeFileShare`. `feedback_share_backed_files`.
  DM headers carry it too (`DmFileMsg.share_ref`; a share-backed DM file sends the caption
  and a metadata-only header, never bytes): until 2026-10-01 `build_dm_file_header` dropped it,
  so a DM file over 34 MB was refused for its size. Harness
  `a_share_backed_dm_file_reaches_the_friend_as_a_share`; fleet `regress_media`.
- Sender stream temps (`.stream_send_*.tmp`) are deleted after WS-relay sends unless
  `pending_webrtc_sends` owns them; a boot-time sweep mops orphans.
  `feedback_stream_send_temp_cleanup`.
- Storage Manager: caps ENFORCED via `enforce_storage_caps` on `FileCompleted`.
  `project_storage_manager`.
- `get_missing_file_ids()` checks DISK, not just the DB: files can exist without
  `completed_at`.
- File card wording = ONE helper `file_card_status.dart`, mirrored by the hover bar,
  menu and sheet via `fileBarAction` (stop = `cancel_file_request`).
  `project_file_card_honest_states`.
- A photo or video leaves WITHOUT its location (C-FILES-03): every read of a file being
  sent goes through `media_strip::read_for_send` (`handle_send_file` for videos and HEIF,
  `vault_upload_file`, `share_create_for_send`, which shares a cleaned copy from
  `shares/send_*/`); the image conversion's fallback arms strip the container too. A video
  keeps every byte position (metadata becomes `free`/Void/JUNK padding), so the file id,
  `vthumb.size` and the share manifest still match. A timed GPS track goes with its
  samples; in a fragmented file it keeps its `trak` and loses the samples its own tables
  list (ffmpeg's `frag_keyframe` first fragment) and its `moof` runs (HOL-SEC-305); a HEIF
  holding a movie has the movie walked too (HOL-SEC-307), and so is a HEIC motion photo's clip
  (top-level `mpvd`, offsets from the clip's start, one budget, unparseable = refused); a JPEG
  motion photo's clip after EOI never leaves (WebP decode, or `strip_jpeg` ends the file at the
  first EOI) (HOL-SEC-308); Samsung's `sefd` box (capture time, country code, path hash, embedded media) becomes `free` at a video's, a clip's or a HEIF's top level and inside `moov`, unread (HOL-SEC-309); `camm` tracks, `gps ` boxes and
  Matroska attached files that are not fonts go too, fonts and Chapters STAY (Vitalik,
  HOL-SEC-306). Residuals: subtitle tracks, dashcam GPS blocks inside `mdat`, chapter
  titles. Media that does not parse is REFUSED
  (`media_strip::REFUSED`), never sent raw; other files keep their bytes. Harness
  `dm_video_send_strips_location_before_it_leaves`. The strip parses a stranger's
  bytes (a received file sent on): it never panics, never recurses or walks a table
  without a bound, holds nothing per sample (HOL-SEC-267..269, 301, 302), and an honest file's output stays byte for byte
  what it was (`strip_answers_as_0_14_did` digests every answer; change it only with
  a reason).
- A received file reaches NO decoder before a tap (C-FILES-02): `VideoMessageBubble` cuts
  its own poster only for `isMine` or after the user opens it (the sender's header poster
  stands in); a voice note's duration comes from its Ogg pages in Dart
  (`AudioProbeService.oggDurationMs`), ffmpeg waits for play. `video_thumb_gate_test`,
  `audio_probe_gate_test`.
- A video's poster is the first sampled frame that is lit and past any fade-in (one Dart rule,
  `pickPosterMs`, for ffmpeg and the platform decoders). Phones and macOS cut it with
  AVFoundation / `MediaMetadataRetriever` (channel `hollow/video_poster`), and ONLY for a file
  outside the data root (`AtRest.isManaged`: resolved like `under_data_root`, unsure = managed):
  an attachment there is ciphertext, never copied out in plain, so it goes to ffmpeg's pipe or
  gets no local poster. Every native call has its own deadline on both sides; a hung decode never
  blocks the next poster. The minimal ffmpeg has only `scale`.
  `video_poster_pick_test`, `video_poster_ffmpeg_test`, wiki `services_media_storage`.

## Profile media, frames, showcase

- Avatar frames (#54): the profile carries an ID (`""` / `b:<hue>` / 64-hex), the art
  rides the ASSET RAIL (`AssetKind::Frame`), NEVER the push. Zero layout cost, none on
  voice/call surfaces, hover = the ROW (3 CI guards). `project_avatar_frames`.
- User avatar/banner ANIMATION rides the rail (`AssetKind::Profile`), only the STILL
  rides the push: hash absent = PRESERVE, `""` = clear; the hash is signed with every
  other profile field (`hollow-profile2`, 0.12); ceilings
  (512; 1200x480 **2.5:1**, the SERVER banner stays 3:1; frames square ≤512) never
  upscale; render `imageBytes` > rail > still. `project_profile_media_asset_rail`.
- Lossy WebP = `node/webp_anim.rs` (`method` 4 everywhere; stills via `encode_still`,
  NEVER the anim encoder). Decide animation from BYTES via `is_animated_image`; a
  `GIF8`/extension branch silently FLATTENS APNG. `project_animated_avatar_encoding`.
- Profile Showcase Board: the wire field is `Option<String>` (absent = PRESERVE, `""` =
  clear); NO relational blocks (VETOED); IGDB authoring-only. `project_showcase_board_impl`.

## Stickers, GIFs, packs, shop UI

- Stickers/GIFs: identity = HASH, not name; Klipy sticker ids carry `~` EVERYWHERE, GIF
  ids are BARE. **ONE block asset per message**, gated at send (`exceedsAssetLimit`),
  never on receive. Pack import re-hashes, never re-encodes. `project_stickers_phase5`,
  `feedback_antialiased_seam_bleed`.
- Shop UI ONLY behind `shopAvailableProvider` (the store verdict, always on elsewhere
  since 0.12). CLI for packs: `rust/hollow_art`. `project_shop_app_client`.
- The item dialog mirrors the website's item sheet (same content, same order; change both).
  Buy on Ko-fi stays DISABLED until the right-to-cancel box is ticked, unticked on every
  open (EU consent before paying; the app's Buy skips the shop's own page). Artist links,
  face, name, bio come from Rust already cleaned (`sanitize_link`, `clean_line`/`clean_block`)
  and open only via `openUntrustedUrl`. Wiki `hollowpack`, `security_write_gates` §72.
- A thumbnail from a peer (file-card blur, video poster, link-card thumb) reaches Dart
  ONLY via `image_convert::peer_thumb_for_display` (pure-Rust decode + our own re-encode,
  or dropped); never change the stored bytes, they sit inside the author's signature.
  Since 0.13 every peer image that renders without a tap passes `node/image_gate.rs` (a pure-Rust full decode) before Skia sees it (AR-28 closed); HEIC and AVIF are never drawn as images, they go as plain file cards (convert on send = follow-up). HOL-SEC-151.
- Every place lib/ hands bytes to Skia (`Image.memory`, `MemoryImage`, `Image.network`,
  `FadeInImage.memory*`, `instantiateImageCodec*`, `decodeImageFromList`, `ImmutableBuffer.from*`,
  `ImageDescriptor`, the byte-taking widgets `AnimatedGifImage`, `HollowAvatar(imageBytes:)`,
  the showcase views, and the caches those widgets paint from: `setAvatar`, frame and profile
  animation `seed`, the server icon/banner `applyLocalWrite`, the `guestServer*Provider` writes;
  tear-offs and calls split across lines count too) is counted per file in
  `test/image_file_decode_guard_test.dart`, each file
  with where its bytes come from (gated, own, or a catalog our own search asked). A new site
  fails CI until it is listed; peer bytes get there only through a gated getter
  (`AttachmentImage`, `emoteBytesProvider`, `get_avatar`/`get_banner`, the server and showcase
  getters). Swept 2026-10-31 (track b14-images): no peer site bypassed the gate.
- No OS decoder parses a peer's image (#154): an OS notification gets only bytes or pixels we
  made. Message banners and desktop toasts take `get_push_profile`'s avatar, the iOS
  push hints `get_notification_avatar` (Rust `notification_icon`: our PNG of the checked
  still, rendered in the check's slots, cached by digest), the Android call face raw
  RGBA (`renderOsCallAvatar`). A new site is listed in `image_file_decode_guard_test.dart`.
- Sender-side link-preview fetches go through the `PublicResolver` client: no loopback,
  private, link-local or metadata address on any hop, no proxy. HOL-SEC-148.
- Vault shard streams ride `vault_ops::shard_stream_id(cid, si, from, to)`, never the
  content id (one id per transfer, both ends derive it).
- File streams likewise ride `file_handler::file_stream_id(fid, from_device, to_device)`
  (session 35, decision E): never the file id on the wire, a send temp per transfer
  (`.stream_send_{stream_id}.tmp`), bytes complete only the file whose pending header their
  own sender gave us (`file_of_stream`), early bytes wait under their stream id. Dart sends a
  file or shard only on that exact device's data channel, never a sibling's.
- Any zip we unpack names entries via `enclosed_name()` against an allowlist and a size
  budget (snapshot import, archive viewer, updater). HOL-SEC-129. The budget is a cap PER
  ENTRY plus one for the whole zip, counted in bytes actually inflated (`Read::take`,
  `zip_budget::UnpackBudget`), never the header's size: sticker packs (`open_pack`, which
  the chat card runs on every received pack unasked), shard bundles (`check_shard_bundle`),
  `.hollowpack`. A hostile fixture needs a VALID manifest, or the entry checks never run.
  HOL-SEC-205, wiki `security_write_gates` §73.
