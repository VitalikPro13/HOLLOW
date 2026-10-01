# Area rules: file transfer mechanics, images, emotes, stickers, frames

Moved out of CLAUDE.md on 2026-09-29, when the file was split by area. CLAUDE.md sends
every session here BEFORE it touches file sending/receiving, storage caps, image
encoding, avatars/banners/frames, the showcase board, stickers, GIFs or emotes. The
file SECURITY rules (`file_header_refused`, `file_asks`, self-certifying ids, at-rest
encryption, the auto-download gate, `safe_file_name`) and the asset-rail privacy rules
stay in CLAUDE.md. Wiki `rust_file_handler`, `emotes`, `hollowpack`.

## File transfer mechanics

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
- Shop UI ONLY behind `shopAvailableProvider` (the store verdict AND
  `shopUnlockedProvider`). CLI for packs: `rust/hollow_art`. `project_shop_app_client`.
