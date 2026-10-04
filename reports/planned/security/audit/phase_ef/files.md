# Phase E+F slice: files, at-rest, asset rail, hollowpack, support credentials, link previews (WP7)

Session 34. Worktree D:/dev/wt/s34-ef @ aa104d48. This slice walks the STRIDE cells
phase B did not cover (information disclosure, one-frame DoS/panic, tampering at rest,
parsing of peer bytes) over F-80..F-86, E-12, X-7, plus the sender-side link preview
SSRF surface and the Ko-fi/shop code path. Phase B already closed the authorisation
side of files (HOL-SEC-022..027, 060, 102..107, 116, 117, 122; AR-13, AR-20); those
rows were read, not redone.

## Scope

- Elements: E-02 Rust core (file/vault/share/asset/preview/credential handlers), E-12
  content files at rest (HFE1), E-03 helpers (ffmpeg), the Dart render layer (Skia
  image codec), X-7 third-party web (link targets, FxEmbed/TikTok/Klipy/FFZ/IGDB
  proxies), the shop (Ko-fi webhook, redeem).
- Flows: F-80 FileHeader + bytes, F-81 file pulls / unavail / expiry, F-82 asset rail,
  F-83 hollowpack + support/Twitch credentials, F-84 link previews, F-85 Klipy/FFZ/IGDB
  proxies, F-86 Share + vault keys. Plus X-7 under AT-5 (a parser of peer bytes).
- Specs / checklists: no RFC owns this slice. The applicable obligation set is the 13
  bug classes of plan 2.2 and the secure-coding rules of plan 5 (same check on every
  transport, absent-means-reject, verify-at-receipt, a stranger's bytes).

## Summary

- Cells walked: 31 (STRIDE grid below). Most T/I/D cells on the remote file/vault/share/
  asset flows are matrix rows already verified in phase B; they are cited, not redone.
- Candidates: 6. 0 Critical, 2 High, 3 Medium, 1 Low. Two of the High/Medium are
  latent-vuln surfaces (ffmpeg, Skia) that only bite if the bundled decoder has a bug;
  both are flagged because they decode a peer's bytes with NO user tap.
- Phase-G fuzz targets: 7, listed with priority.
- Requirements: 11 (R-FILES-01..11).
- Leads: none assigned to WP7 in plan section 7. L-12 (loopback media server) is WP8;
  the at-rest half (E-12) is covered here and holds.
- F-86 HOL-SEC-002 variant search: no finding. No file, share or vault decryption key
  is ever sent where the relay can read it (detail under Candidates / F-86).

## Candidates (most severe first)

### C-FILES-01 — A link a victim pastes makes the victim's own machine fetch an internal or LAN address (SSRF on the sender)

- Severity: Medium (Impact M, Exploitability M). Attacker: P-12 / P-03 (anyone who gets
  the victim to paste a URL; previews auto-fetch, so no send is needed).
- Confidence: CONFIRMED.
- Component: `node/link_preview.rs::fetch_link_preview` -> `fetch_bounded`; triggered
  from Dart `chat_pane.dart` (and the channel/mobile twins) on a 600 ms compose-box
  debounce.
- Evidence. The HTTP client is built with only a scheme check and a bounded redirect
  count, no address policy:
  - `node/link_preview.rs:80` `let client = reqwest::Client::builder()`
  - `node/link_preview.rs:83` `.redirect(reqwest::redirect::Policy::limited(3))`
  - `node/link_preview.rs:100` `if parsed.scheme() != "http" && parsed.scheme() != "https" {`
  - `node/link_preview.rs:631` `.get(url)` with no host/IP validation anywhere in the
    file; `fetch_bounded` only caps size and time.
  - Auto-fires on typing: `lib/src/ui/chat/chat_pane.dart:328`
    `_urlDebounce = Timer(const Duration(milliseconds: 600), _detectUrl);` ->
    `chat_pane.dart:392` `final preview = await network_api.fetchLinkPreview(url: url);`
    (previews default ON, `lib/src/core/providers/link_preview_settings_provider.dart:15`).
- Why it breaks a requirement. No claim promises the sender does not fetch (C-27 is only
  about readers), but this is an unlisted SSRF surface on E-02 across TB-7. There is no
  block on loopback (`127.0.0.0/8`, `::1`), private ranges (`10/8`, `172.16/12`,
  `192.168/16`, `fc00::/7`), link-local (`169.254/16`, the cloud metadata address
  `169.254.169.254`), or `0.0.0.0`; redirects are followed up to 3 hops with no re-check,
  so a public attacker URL can 302 into the victim's LAN. The scraped `og:title` /
  `og:description` of the internal page is then embedded in the preview card (shown to
  the sender before send, and to recipients if sent), so internal content is reflected
  back. On a desktop/phone the main value is LAN recon and router/admin-page probing;
  cloud-metadata theft is possible only where Hollow runs on a cloud VM.
- Test to prove it: no harness reaches this (it needs a live HTTP fetch). A unit test on
  a `host_allowed(ip)` helper plus an adversary HTTP server that 302-redirects to
  `127.0.0.1` would guard it. Today: no test.
- Fix idea: resolve the host, refuse the request when any resolved address is loopback /
  private / link-local / ULA / unspecified, and re-apply the same check on every
  redirect target (a custom redirect policy or a resolved-IP check before each hop).

### C-FILES-02 — A friend or server member's video under the auto-download threshold is fed to the bundled ffmpeg with no tap

- Severity: High (Impact H if the bundled ffmpeg has a memory-corruption bug -> RCE on
  the recipient's machine; Exploitability M: needs friendship or shared membership and a
  real ffmpeg bug). Attacker: P-04 / P-05. This is attack-tree leaf AT-5 ("memory
  corruption in a parser of peer bytes"), already named for fuzzing; recorded here as a
  candidate because it runs WITHOUT A TAP and the default trigger window is huge.
- Confidence: CONFIRMED (the path to the decoder; the vuln itself is latent).
- Component: `lib/src/core/services/video_thumbnail_service.dart` (bundled ffmpeg,
  `Process.start`), reached from `lib/src/ui/chat/video_message_bubble.dart`.
- Evidence.
  - `video_message_bubble.dart:121` `_maybeExtractLocalThumb();` runs from `initState`
    (and `didUpdateWidget`, line 131) whenever a video bubble builds.
  - `video_message_bubble.dart:200` `final extracted = await VideoThumbnailService.ensureCachedThumb(videoPath);`
    — `videoPath` is non-null only once the file is on disk, i.e. after download.
  - `video_thumbnail_service.dart:261` `final proc = await Process.start(ffmpeg, args);`
    with `-i pipe:0 ... -frames:v 1` — the bundled ffmpeg demuxes the container and
    decodes one frame from the attacker's bytes. The build enables mov/mp4/matroska/ogg/
    image2 demuxers and h264/hevc/vp8/vp9/mjpeg/png decoders
    (`.github/workflows/build-ffmpeg.yml:97-123`, ffmpeg `n7.1`).
  - The only gate is the auto-download threshold, and the default is 169 MB:
    `lib/src/core/providers/settings_provider.dart:617` and `settings_provider.dart:628`
    `return 169;`. A video at or under 169 MB from a DM counterparty or a channel we read
    lands on disk and is probed with no interaction.
- Why it matters. Content files are a declared peer-bytes parser surface (AT-5). ffmpeg
  is a large C/C++ attack surface and runs here on bytes the recipient never asked to
  open, in-process (no sandbox, no separate hardened process). The companion audio path
  (`lib/src/ui/chat/audio_message_bubble.dart:123` `_maybeProbe`) also runs ffmpeg on an
  unsolicited file, but only when it looks like a genuine voice note (ogg ext + name
  shape + <=8 MB + an actual `OggS` header, `audio_probe_service.dart:35`), so its window
  is narrow.
- Test: fuzzing (phase G); no functional test can assert "no RCE".
- Fix idea: lower the auto-*decode* trigger well below the auto-*download* threshold
  (probe only files the user opened, or small ones), and/or run ffmpeg under a restricted
  child (job object / seccomp / sandbox-exec) since it already runs as a separate process
  reading stdin.

### C-FILES-03 — A sent video (and any image format Hollow does not re-encode) carries the sender's EXIF/GPS metadata to recipients

- Severity: Medium (Impact M: sender location/time/device leak; Exploitability H: every
  send of such a file leaks). Attacker: the recipient (P-04/P-05) learns it. Privacy /
  LINDDUN disclosure.
- Confidence: CONFIRMED.
- Component: `node/file_handler.rs::convert_image_data` and the video send path in
  `handle_send_file`.
- Evidence.
  - Videos are sent byte-for-byte: `file_handler.rs:451` `let final_data = std::mem::take(&mut file_data);`
    then `finish_send_file(...)` with the original bytes — no `-map_metadata -1`, so mp4
    `moov`/`udta` GPS and creation-time tags travel to every recipient.
  - Only png/jpg/jpeg/bmp/tiff are re-encoded to WebP (`image_convert.rs:57`
    `should_convert_to_webp`), which strips EXIF; WebP and GIF go through
    `strip_webp_metadata` / `strip_gif_metadata`. Any other image extension (e.g. heic/
    heif, picked through `FileType.any` on mobile, `lib/src/ui/mobile/mobile_chat_route.dart:1072`)
    is `mime_from_ext` = `application/octet-stream` -> `is_image == false` -> sent raw
    with EXIF intact (`file_transfer.rs:54` has no heic mapping).
  - A conversion FAILURE also sends the original: `file_handler.rs:624-627` and `636-638`
    return `file_data` unchanged on the `Err`/`else` arms, EXIF included.
- Why it matters. No claim currently promises metadata stripping, so this is a gap in the
  promise set as much as the code: recipients routinely receive the sender's home GPS
  coordinates from a phone video or a HEIC photo.
- Test: a harness/unit test that sends a fixture mp4 with a GPS udta atom and a HEIC with
  GPS EXIF and asserts the delivered bytes carry neither. Today: no test.
- Fix idea: strip metadata on the send path for videos (ffmpeg `-map_metadata -1 -c copy`
  or a container rewrite) and for every image format, including the passthrough and the
  conversion-failure arms; or add an explicit "strip location data" default with a claim.

### C-FILES-04 — A peer's image bytes are decoded by the Flutter/Skia codec with no tap, through several unsolicited surfaces

- Severity: Medium-High (Impact H if the bundled Skia/libwebp has a decode bug;
  Exploitability M: needs a peer relationship and a real decoder bug). Attacker:
  P-04/P-05 (and P-12 for the sender-fetched preview image). The no-tap sibling of
  C-FILES-02 for the image side.
- Confidence: CONFIRMED (the paths; the vuln is latent).
- Component: Dart render layer — `AttachmentImage` / `AtRestImageProvider`
  (`lib/src/ui/components/attachment_image.dart:115` `decode(...)`), `AnimatedGifImage`
  (`animated_gif_image.dart:214` `ui.instantiateImageCodec`), `LinkPreviewCard`
  (`link_preview_card.dart:300`, `:467` `Image.memory`), the file-card blur thumb
  (`file_attachment_widget.dart:400` `Image.memory`).
- Evidence / why no-tap.
  - File-card blur thumb: the attacker-chosen `thumb` (<=48 KB base64 WebP,
    `file_handler.rs:524` `FILE_THUMB_MAX_B64_LEN`) is stored and rendered blurred under
    the card as soon as the message is visible, BEFORE any download
    (`file_attachment_widget.dart:375` "renders BLURRED under the content"). Skia decodes
    it with no tap and no download.
  - Link-preview thumb: a sending peer puts arbitrary WebP in `thumb_webp_b64` (it is
    signed by them, but they are the attacker); every recipient's `LinkPreviewCard`
    decodes it on render (`link_preview_card.dart:453` `base64Decode`, `:467`
    `Image.memory`). It rides inside the <=64 KB message body.
  - Auto-downloaded images (<= threshold) render through `AttachmentImage` on the next
    paint, decoded by Skia, no tap.
  - Asset-rail blobs (emote/sticker/GIF/banner/frame/avatar) are stored opaquely by Rust
    (only header dims + magic checked, `emotes.rs:558`, no Rust decode) and decoded by
    Skia/Flutter when rendered in the picker or a bubble.
- Mitigation already present. Rust never hands these to its own decoder unsolicited:
  `image_convert::validate_remote_image_header` (`image_convert.rs:1902`) refuses a canvas
  over 4096/side and non-PNG/JPEG/GIF/WebP before any Rust decode, and `load_bounded`
  (`image_convert.rs:1878`) caps a single allocation at 256 MiB. But those bounds do not
  reach the Dart/Skia codec, which is the one that actually paints these bytes. The blur
  thumb and the link-preview thumb are NOT passed through `validate_remote_image_header`
  on receipt at all.
- Why it matters. This is the classic "libwebp (CVE-2023-4863 class) through any WebP
  decoder" surface, reached here by Skia on a stranger's bytes with no interaction.
  Safety depends on the Flutter engine bundling a patched Skia/libwebp; Flutter pinned at
  3.47.0 (`.github/workflows/ci.yml:200`) is well past the 2023 fix, but this is a
  standing dependency obligation.
- Test: fuzzing the decoders (phase G) plus a guard that runs the blur/preview thumb
  through `validate_remote_image_header` on receipt. Today: no test on the Dart decode.
- Fix idea: run the blur thumb and the link-preview thumb through
  `validate_remote_image_header` on receipt (cheap, header-only), and keep the Flutter
  engine's Skia current as a release-gate check.

### C-FILES-05 — Ko-fi webhook has no delivery authenticity beyond a token in the body; a leaked verification token forges unlimited redeem codes

- Severity: Medium (Impact M: free shop codes / credential minting for one artist;
  Exploitability L-M: needs the artist's verification token OR webhook path, which are
  stored only as HMAC tags and shown once). Attacker: P-12 (anyone who reaches the public
  webhook URL) once they hold a token.
- Confidence: CONFIRMED (behaviour), SUSPECTED on real-world exploitability (depends on
  how exposed Ko-fi verification tokens are).
- Component: `anonlisten-sites/shop/src/routes/api/kofi/[hook]/+server.js`,
  `src/lib/server/kofi.js::ingestKofiEvent`.
- Evidence. Authenticity rests on two shared secrets in the request, both compared in
  constant time, which is correct as far as it goes:
  - path: `kofi.js:newHook` (32 random bytes) matched by HMAC tag, `+server.js` `artistIdByKofiHook(hmacSecret(params.hook, ...))`.
  - body token: `kofi.js:` `const given = hmacSecret(String(event?.verification_token ?? ''), ...)` then `digestsMatch(stored, given)`.
  There is no HMAC-of-body signature from Ko-fi (Ko-fi does not provide one), so the only
  thing standing between a stranger and `mintCodes` is knowledge of the verification token
  (printed on the artist's Ko-fi webhook page) plus the webhook path. Idempotency is by
  `message_id` (`kofi.js` `recordWebhookEvent(\`kofi:${messageId}\`, ...)`), so an attacker
  who holds a token can mint codes for distinct `message_id`s at will; the only ceilings
  are `MAX_QUANTITY` (10) and `MAX_ITEMS` (20) per delivery.
- Why it matters. C-32 (a credential was issued by the shop's pinned root for that
  identity) still holds — forged codes still have to pass the redeem path's blind-sign and
  the client-side `sanitize_incoming_support_creds` against the pinned root, so a forged
  Ko-fi order cannot mint a credential for someone else's identity. The exposure is
  economic (free codes, inflated artist payouts/counters), not a credential-transplant.
- Positives confirmed. `burnKey` is the single atomic lock (`db.js:2850`
  `INSERT OR IGNORE INTO keys_burned ... Number(info.changes) > 0`), the M4 order is
  refused-then-burned-before-sign-returns (`redeem.js` gate then `redeemOnce`), redeem is
  serialised per code hash (`redeem.js::serialised`) and the concurrency tests pass
  (`concurrent_redeems_of_one_code_mint_exactly_once`). `scrubKofiEvent` is a whitelist
  with a null-prototype object (no `__proto__` reach). `forwardCopy` refuses non-https,
  loopback, `.localhost` and IP-literal forward URLs (`kofi.js:forwardUrlProblem`,
  `redirect: 'manual'`), closing the one SSRF lever in the shop. Body capped at 64 KB
  before read.
- Test: `src/lib/server/kofi.test.js` covers token mismatch (401), idempotency, scrub,
  clamp, and the forward-URL refusals; `redeem.test.js` covers M4 order and the two
  concurrency cases.
- Fix idea: if Ko-fi ever offers a signed webhook, require it; otherwise accept this as a
  documented residual (the token is the shared secret by Ko-fi's design) and keep the
  mint ceilings. Consider an artist-scoped daily mint cap as defence in depth.

### C-FILES-06 — A link-key holder's share manifest sizes an in-memory bitmap and a sparse file from attacker fields

- Severity: Low (Impact L, Exploitability L). Attacker: P-04 or the share's own
  publisher (a link-key holder).
- Confidence: CONFIRMED-bounded.
- Component: `node/share_handler.rs::handle_envelope_share_manifest_response`,
  `node/at_rest.rs::Writer::create`.
- Evidence. `chunk_count` and `chunk_size` come from the manifest; `ChunkBitmap::empty`
  and `Writer::create -> set_len(cipher_len_for(total_size, chunk_size))` size allocations
  from them. The bound is real but worth stating: the manifest is refused unless
  `manifest.chunk_hashes.len() as u32 == manifest.chunk_count`
  (`share_handler.rs:1564`), and the manifest rides the 64 MB relay frame ceiling, so
  `chunk_count` is capped near 2M (32 bytes/hash) -> ~256 KB bitmap; and
  `Writer::create` refuses `chunk_size < MIN_CHUNK_SIZE` (`at_rest.rs:469`) to stop a
  huge sparse file. No unbounded allocation found. Recorded so a future edit that drops
  the `chunk_hashes.len() == chunk_count` tie does not reopen it.
- Test: none specific; the tie is a one-line invariant.
- Fix idea: add an explicit `chunk_count` ceiling independent of the hash-list tie.

## Leads

None assigned to WP7 in plan section 7. Related checks done in this slice:
- L-12 (loopback media server, WP8): the at-rest half (E-12) holds — see STRIDE E-12 and
  §12/§14 of the write-gates. The server itself is WP8.

## Protocol checklist

No RFC places obligations on this slice. The governing obligations are the 13 bug classes
(below) and secure-coding rules 5-6-8-9 of the plan, which the file-commit design (one
signed `file_id` binding author+mid+size+sha256+name+ext+vthumb, `node/file_commit.rs`)
and the Carried/MLS lane rule satisfy for the authorisation side.

## The 13 bug classes, asked of this slice

1. **Authenticated but not authorised.** Covered by phase B. File headers gate on
   `file_header_refused` + `header_claim_refused` (owner or asked holder; channel reader);
   vault/share/recovery on their matrix rows (A-V*, A-S*, A-R*). Nothing new found.
2. **Infrastructure controls membership/lists.** The relay never gates file/asset
   entitlement; membership comes from `ServerState`. File serving asks
   `channel_readable_by` on the requester's master (`swarm.rs:13224`). Holds.
3. **Split view.** A file's content id self-certifies (`file_commit.rs`), so two honest
   parties holding the "same" committed id hold the same bytes. Pre-0.12 ids commit to
   nothing (AR-13, accepted). Vault manifests are unsigned (AR-20, accepted) — a split
   view of one vault file's shard set is possible but the bytes still check against the
   content id. Nothing new.
4. **Withheld/rolled-back revocation.** N/A to file content (no revocable file state here).
5. **Identifier/key-type confusion.** Committed vs legacy file ids are told apart by
   length (64 hex vs 32), `file_commit.rs:72`; a legacy id can never be passed off as
   committed and vice-versa (`an_old_id_is_judged_by_the_delivery_gates_alone`). Content
   ids, share root hashes and file ids are distinct 64-hex namespaces but are only ever
   used in their own tables. Holds.
6. **Channel confusion (same type over multiple transports).** The lane rule is exhaustive
   (`types.rs:4157 lane()`): FileHeader/FileRequest/FileUnavailable/PublicFileHeader/
   EmoteRequest/EmoteAssets ride `Carried` (Olm) only; a plaintext copy is dropped at the
   lane gate (`swarm.rs:5251`). Share control rides the sealed Share lane; recovery the
   Recovery lane. The file-header GATE is the same helper on the Olm arm, the MLS arm, the
   push `fetch.rs` arm and the guest arm (`file_header_refused` + `header_claim_refused`
   each time). No transport skips the check.
7. **Unknown key-share / misbinding.** File AES keys ride inside the sealed FileHeader to
   the device the Olm session authenticated; no bare-key injection path. Vault shard
   writes bind to the content id and the manifest's per-shard hash. Holds.
8. **Replay/reorder/deletion.** `file_unavailable` only moves an ask from a device we
   asked, and "expired" is verified against our own retention locally (A-F4). A share
   takes its manifest once (A-S2). `FileUnavailable` and asset receipts are asked-set hard
   drops. Nothing new.
9. **Downgrade / length checks.** The file-commit length field tells committed from legacy
   so a new file cannot be downgraded to an uncommitted id (AR-13 reasoning). Header size
   is bounded before decode (`header_size_refused`), inline b64 before decode. Image
   canvas is read from the header before any decode (`validate_remote_image_header`,
   `blob_shape`, SHOP-2). Holds in Rust; the Dart/Skia decode is C-FILES-04.
10. **Unauthenticated metadata.** The file card's `file_meta`/`SyncFileMetaItem` blob is
    NOT bound by the message signature, so receivers require `file_meta.fid == file_id`
    and re-check the committed hash (`synced_file_meta`, `synced_card_claim_refused`); the
    guest `file_meta` on a `PublicChannelMessage` is display-only (write-gates §7). The
    blur `thumb` and the link-preview thumb ARE read by the renderer without being in the
    signature's security scope for decode-safety — that is C-FILES-04. The on-send EXIF
    is C-FILES-03 (sender metadata the sender did not intend to disclose).
11. **State/key lifecycle (crash mid-flow).** At-rest is crash-safe by construction: the
    key row is persisted BEFORE any ciphertext (`at_rest.rs:140 persist_key`, comment
    "a crash can only ever leave an orphan row, never an unreadable file"); writes are
    tmp+rename (`write_all`); a missing key row is a hard error, never a plaintext
    passthrough (`read_all` -> "File key missing"); `remove` deletes the row = crypto
    erase; the boot sweep deletes orphan `.hfe.tmp` and resumes
    (`at_rest_migration_resumes_from_every_crash_point`,
    `at_rest_remove_deletes_key_row_and_file`). Chunk rewrite with different bytes is
    refused (GCM nonce-reuse guard, `write_chunk`). Stream temps are per-device /
    per-nonce so a concurrent transfer never clobbers another's ciphertext
    (`swarm.rs:13393` unique `.stream_send_{id}_{nonce}.tmp`). A crash mid-download leaves
    a `.partial` the next boot sweeps. Nothing new. One note: `file_keys` uses
    `secure_delete` only in `scrub_device_secrets`; ordinary row deletes
    (`DELETE FROM file_keys`, `messages.rs:1366`) rely on the DB default — the key bytes
    are inside the SQLCipher-encrypted file, so a freed page is still ciphertext; not a
    finding.
12. **Device linking / cloning.** The link snapshot rides the Share-style stream, decrypts
    under a random key inside the SPAKE2 channel, imports pre-node-start. The import
    extraction (`api/storage.rs:1600` `data_dir.join(&name)`) joins the zip entry name
    onto the data dir with NO `safe_file_name`/zip-slip guard — but the snapshot is the
    device's OWN backup, produced by `scrubbed_db_copy` with a fixed entry set, decrypted
    under a key the presenter vouched for (HOL-SEC-002); a hostile snapshot requires
    breaking the PAKE first. Noted as a defence-in-depth gap, not a candidate: every entry
    name there is Hollow's own.
13. **What a stranger can make us download / decode / store.** This is the slice's core.
    - Store: asset rail is requested-only, capped per kind, unsolicited dropped
      (`emotes.rs:550,563`, A-E2); file bytes gated by `file_header_refused` and the
      content gate; public-file ingest requested-only within 120 s (write-gates §7). A
      stranger cannot park bytes on our disk unsolicited.
    - Download: the auto-download gate (default 169 MB) is the one thing that pulls a
      peer's bytes with no tap — see C-FILES-02.
    - Decode: ffmpeg on auto-downloaded video (C-FILES-02) and Skia on blur/preview/image
      bytes (C-FILES-04) both run on a peer's bytes with no tap. These are the flagged
      no-tap candidates.

## F-86 — HOL-SEC-002 variant search (is any file/share/vault key ever sent where the relay can read it)

No finding. Every decryption key stays inside a sealed/encrypted frame or on-device:
- File AES key + nonce ride inside `MessageEnvelope::FileHeader` (Olm `Carried`, or MLS),
  never a plaintext `HavenMessage` (`types.rs lane()` puts FileHeader on `Carried`; a
  plaintext copy is dropped at `swarm.rs:5251`). The guest `PublicFileHeader` for public
  channels carries a stream key, but the content is public (the relay already sees it),
  which is by design (write-gates §7).
- Share link key rides in the `hollow://share/<b64>` URL fragment only
  (`share_handler.rs:52 encode_link`), which per deep-linking never reaches the relay;
  share control (manifest/have/chunk requests) rides the sealed Share lane keyed by the
  link key (`seal_control`, `open_control`), and `ShareRef{root_hash,key}` rides inside the
  FileHeader (`Carried`/MLS), never plaintext. The guest `SyncFileMetaItem` carries NO
  key or share_ref (`types.rs:4635`), so guests get metadata, never a key.
- Vault: shards are content-addressed; no per-shard decryption key is transmitted. A
  restricted-channel file is never vaulted (HOL-SEC-025), so the server-group key is not
  put in a manifest.
- At-rest file keys live only in `file_keys` in messages.db and never ride any frame
  (write-gates §12).

## STRIDE grid (one line per cell; S/E on remote inputs are phase-B matrix rows)

E-02 Rust core — file/vault/share/asset/preview handlers (process: S T R I D E)
- S: covered — every remote file/vault/share/asset frame is device-sealed and its gate
  resolves the sender to a master (design A; `file_header_refused`, A-F*/A-V*/A-S*).
- T: covered — committed file ids + content gate (`completion_refused`); vault per-shard
  hash; share chunk hash; asset content-address. Pre-0.12 ids AR-13; vault manifest AR-20.
- R: n/a — no non-repudiation claim on file actions beyond the signed message row.
- I: C-FILES-01 (preview SSRF reflects internal content), C-FILES-03 (EXIF on send). File
  SERVING disclosure gated (write-gates §7); asset oracle AR-05.
- D: one-frame unbounded alloc checked — C-FILES-06 (bounded), share bitmap bounded,
  `load_bounded` 256 MiB cap, header canvas bound pre-decode. Relay floods AR-01/AR-06
  (phase G, out of scope). No remote panic found: `validate_remote_image_header` and
  `blob_shape` are header-only; `unpack_shard` bounds-checks (`erasure.rs:57`); slicing in
  `emotes.rs`/`support_creds.rs`/`share_handler.rs:1787` is on fixed-length or validated
  input.
- E: covered by phase B (the authorisation matrix).

E-03 helpers — ffmpeg (process)
- S/R: n/a (local child process).
- T: args are fixed strings; the only variable is the bytes on stdin — no arg injection
  (`video_thumbnail_service.dart:191`, `audio_*`).
- I: n/a.
- D/E: C-FILES-02 — decodes a peer's bytes with no tap; latent RCE surface, no sandbox.

E-12 content files at rest, HFE1 (data store: T I D)
- T: AES-256-GCM per chunk with uid+index+last AAD; tamper and truncation detected
  (`at_rest_tamper_in_any_chunk_is_detected`, `at_rest_truncation_is_detected`).
- I: requirement met — ciphertext at rest, key row inherits identity protection; the
  loopback server binds 127.0.0.1 + a per-process token + path confinement (write-gates
  §12, `at_rest_server_range_semantics`). Save-as/export produce a deliberate plaintext
  copy to a user-chosen path (`exportAttachmentTo` -> `AtRest.exportTo`), stated to the
  user ("unprotected copy").
- D: a missing key row is a hard error (no silent plaintext); crash-safe writes
  (class 11). Holds.

X-7 third-party web (external interactor: S R)
- S: the X/TikTok adapters match host SUFFIXES, not substrings
  (`link_preview.rs:283 host_matches`, `rejects_lookalike_hosts`), so `x.com.evil.tld`
  does not qualify. FFZ/IGDB/Klipy proxies pin the upstream host server-side.
- R: n/a. The proxies are not open proxies: FFZ (`ffz/fetch.php`) and IGDB
  (`igdb/fetch.php`) only fetch ids present in their own DB and build the upstream URL
  from a fixed host + an allowlisted id (`[0-9]{1,12}` / `[a-z0-9]{1,40}`); Klipy
  (`gifs/fetch.php`, `full.php`) fetches only URLs stored in its DB from a prior Klipy
  search, never a client-supplied URL. The Klipy key stays in server `config.php`
  (`gifs/config.php.example`), never in handed-out URLs. SSRF from the proxies: none
  found (no client-controlled URL reaches `curl`). The one client-side SSRF is
  C-FILES-01 (the link-preview fetch, which is the client, not a proxy).

Flows F-80..F-86: T/I/D as above; authorisation (the E/S columns) is the phase-B matrix,
cited, not redone.

## Requirements (R-FILES-NN: testable sentence | evidence | guard test)

- R-FILES-01: An attacker who gets a victim to paste a URL cannot make the victim fetch a
  loopback/private/link-local/metadata address, directly or via redirect. Evidence: GAP —
  `node/link_preview.rs:80-85` has no address policy. Test: none (C-FILES-01).
- R-FILES-02: A peer's video/audio bytes are not fed to ffmpeg without the user opening
  the file. Evidence: GAP — runs in `initState`/eager-probe below the 169 MB auto-download
  threshold (C-FILES-02). Test: none.
- R-FILES-03: A file a user sends does not carry EXIF/GPS or container location metadata.
  Evidence: PARTIAL — stripped for png/jpg/bmp/tiff/webp/gif (`convert_image_data`,
  `strip_webp_metadata`, `strip_gif_metadata`); NOT for video or unconverted image formats
  (C-FILES-03). Test: none.
- R-FILES-04: A peer's `thumb`/preview WebP is bounded in decoded dimensions before it is
  decoded. Evidence: PARTIAL — Rust remote image bytes go through
  `validate_remote_image_header` (`image_convert.rs:1902`), but the blur thumb and
  link-preview thumb are decoded only by Skia with no such check (C-FILES-04). Test:
  `incoming_profile_image_bomb_is_dropped` (profile path only).
- R-FILES-05: A peer cannot write a file outside Hollow's folders or choose its name.
  Evidence: `node/file_transfer.rs:31 final_file_path` (sanitises both parts),
  `is_wire_file_id`/`is_wire_ext` shape gate at both inline-header sites
  (`swarm.rs:8804`, `fetch.rs:1365`), `safe_file_name` at the one share download join
  (`share_handler.rs:1844`). Test: `final_file_path_stays_inside_files_dir`,
  `wire_file_id_and_ext_shapes`, `safe_file_name` tests (`share_handler.rs:2253+`).
- R-FILES-06: Bytes complete a committed file only if they hash to the id. Evidence:
  `file_commit.rs:124 content_refused`, `completion_refused_hashed`; every completion path
  (stream `file_handler.rs:2646`, inline `swarm.rs:8813`, FFI `storage.rs:1031`, share
  bridge via `markFileComplete`) runs it. Test: `an_old_id_is_judged_by_the_delivery_gates_alone`,
  the source-scan guard `file_commit.rs:318` (`.mark_file_complete(` count).
- R-FILES-07: A hollowpack cannot zip-slip, zip-bomb, or carry a canvas bomb. Evidence:
  entry name is `files/{sha256}.webp` built from the hash, never the zip path
  (`hollowpack.rs:592`); per-file read capped at `MAX_FILE_BYTES+1` via `.take`
  (`:615`); total capped (`:628`); 8 files max; `blob_shape` reads the canvas from the
  header and refuses >4096/side before decode (`:696`, SHOP-2). Re-hash, never re-encode
  (`verify_pack` recomputes every SHA-256). Test: `one_flipped_byte_refuses_the_pack`,
  `a_pack_with_too_many_files_is_refused`, `an_oversize_file_is_refused_before_it_is_decoded`,
  `blob_shape_rejects_oversized_canvas_before_decode`. Same for the sticker pack
  (`api/stickers.rs`, hash-named entries, `validate_sticker_blob`).
- R-FILES-08: Incoming support credentials verify against the pinned root for THIS
  identity and cannot be transplanted. Evidence: `node/support_creds.rs:sanitize_incoming_support_creds`
  -> `keep_verified` -> `verify_entry_at` (issuer sig under pinned root, key sig, blind
  sig over the credential message built from the resolved master), plus the field-level
  master signature (`social::gated_support_creds`, write-gates §9). Test:
  `support_credential_replicates_and_transplant_is_dropped`,
  `unsigned_support_creds_is_refused_and_preserved`, `stripped_support_creds_never_clears_a_pinned_mark`.
- R-FILES-09: A redeem spends a code at most once and never signs on a code it then fails
  to burn. Evidence: `redeem.js` M4 order (gate: refused-then-burned; `redeemOnce`:
  resolve, ensurePack, sign-in-memory, burnKey as the one lock via
  `db.js:2850 INSERT OR IGNORE ... changes>0`, then increment), serialised per code hash.
  Test: `concurrent_redeems_of_one_code_mint_exactly_once`, `a refunded code is refused and
  never burns`, `a signer failure spends nothing`.
- R-FILES-10: The Ko-fi webhook refuses an unauthenticated delivery and cannot be turned
  into an SSRF or a prototype-pollution sink. Evidence: constant-time token+path HMAC
  match, 64 KB body cap, whitelist null-proto scrub (`kofi.js`), forward-URL refuses
  https-only + no loopback/IP (`forwardUrlProblem`, `redirect:'manual'`). Residual: the
  token is the only authenticator (C-FILES-05). Test: `kofi.test.js` token-mismatch,
  scrub, `cannot be made to reach Object.prototype`, forward-URL refusals.
- R-FILES-11: No file/share/vault decryption key reaches the relay in the clear. Evidence:
  F-86 above (Carried/MLS/sealed lanes; link key in the URL fragment; at-rest keys never
  on the wire). Test: `c24_file_and_asset_traffic_rides_olm`,
  `c24_share_control_opens_only_with_the_link_key`.

## Phase-G fuzz targets (priority)

1. HIGH — bundled ffmpeg container/codec parsers (mov/mp4/matroska/ogg demuxers;
   h264/hevc/vp8/vp9/mjpeg decoders), fed the video-thumbnail and audio-probe stdin path.
   Runs on a peer's bytes with no tap (C-FILES-02). Native C/C++, highest RCE value.
2. HIGH — the Flutter/Skia image codec on attacker WebP/PNG/JPEG/GIF (blur thumb,
   link-preview thumb, asset-rail blobs, auto-downloaded images). No tap (C-FILES-04).
3. MEDIUM — `node/hollowpack.rs::verify_pack` + `blob_shape` and `api/stickers.rs`
   import over crafted zips (zip-slip is structurally prevented, but the zip reader and
   the per-entry decode are peer-reachable via a received `.hollowpack`).
4. MEDIUM — libwebp-sys2 (bundled libwebp 1.5.0) via `webp_animation::Decoder` in
   `process_avatar_frame` / `validate_frame_centre`. Native C; reached by pack import
   (local file) and frame authoring, not by unsolicited peer bytes, so lower urgency than
   (1)-(2) but a C decoder.
5. MEDIUM — the Rust `image` crate decoders (image-webp 0.2.4, zune-jpeg, png, gif)
   behind `load_bounded` / `process_sync_avatar`; pure-Rust but panic-prone. Reached by a
   guest's public-channel preview request and the send-side convert.
6. MEDIUM — `vault/erasure.rs::unpack_shard` and the vault shard stream completion on
   crafted packed-shard bytes (header-length field + JSON header).
7. LOW — `node/link_preview.rs::parse_og_metadata` (scraper/html5ever) on hostile HTML;
   sender-side, self-inflicted, but attacker-chosen content.

## Notes / non-findings worth recording

- The link-preview embed proxy and GIF proxy base are user-configured and validated
  https-only with a host (`api/network.rs:2063 set_embed_proxy_url`,
  `api/gifs.rs:167 set_gif_proxy_url`); not an attacker SSRF lever.
- `showcase_fetch_cover/key_art` fetch only URLs with the fixed `COVER_BASE` prefix
  (`api/showcase.rs:165`), host-pinned to the Hollow CDN; its `reqwest::Client::new()`
  follows the default 10 redirects (vs the preview client's 3), but the host is pinned, so
  no SSRF — noted only for hygiene.
- `vault/content_store.rs` sanitises server_id and shard_key to `[A-Za-z0-9_-]` before any
  path join (`sanitize_path_component`, `server_dir`, `shard_path`); the shard-bundle
  import (`api/archive.rs`) parses `shards/{cid}/{idx}.shard` and the cid flows into
  `shard_key` which is sanitised. No traversal.
- The link snapshot import (`api/storage.rs:1600`) and the `.hollow-archive` temp
  extraction (`archive/loader.rs:231`) join zip entry names onto a directory without a
  zip-slip guard. Both operate on Hollow's own produced archives (link snapshot: a
  scrubbed self-backup under a PAKE-vouched key; archive: the user's own exported file)
  with fixed entry sets, so no hostile-name vector exists today. Defence-in-depth: route
  both through `safe_file_name` or `enclosed_name()`. Not a candidate.
