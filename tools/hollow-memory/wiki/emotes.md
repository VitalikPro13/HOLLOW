# Custom Emotes and FFZ Integration

End-to-end map of the custom emote system (shipped 2026-07-10). Architecture rationale in memory `project_custom_emotes_ffz`. Generalized into the ASSET RAIL 2026-07-28 (see the section below) — banners/stickers/GIFs ride the same replication machinery.

## Asset Rail (generalized blob transport, 2026-07-28)

The emote byte-replication system is now the generic content-addressed asset rail (`node/assets.rs` + the emote wire path). Epic: memory `project-asset-rail-epic`.

- **Kinds** `AssetKind::{Emote, Banner, Sticker, Gif, Avatar, Frame}` — differ ONLY in receipt cap (`recv_cap`: 256 KB / 1 MB / 512 KB / 2 MB / 512 KB / 256 KB) and per-request hash bound (`max_request_hashes`: 20 / 2 / 8 / 4 / 4 / 4). `emote_blobs.kind` TEXT column (additive migration, default 'emote') records what a blob was pulled AS. `Avatar` = the ANIMATED server-icon variant (see "Animated Server Icons" below); `Frame` = a user's avatar frame (see "Avatar Frames" below) and deliberately takes the tight EMOTE ceiling, not the rail's 512 KB, because it is decoration on every avatar you have ever seen.
- **Kind never rides the wire.** Requesting side records hash→kind in swarm's `requested_asset_kinds: HashMap<String, AssetKind>` (replaced `requested_emote_hashes`; same lifecycle, cleared on `WsEvent::Disconnected`). `handle_emote_assets` accepts ONLY hashes present in that map and sizes the cap from the RECORDED kind — unsolicited bundles are dropped wholesale (cache-stuffing gate, new in this phase), and an invalid answer frees the slot for retry.
- **Responder reply budget** `MAX_BUNDLE_REPLY_BYTES` = 8 MB (with GIFs cached, the old 20-hash bound alone could balloon a bundle to ~40 MB).
- **Every animated blob on the rail is encoded by `node/webp_anim.rs`** (direct libwebp `WebPAnimEncoder`, `AnimParams::art()`), NOT `webp-animation` — that crate silently drops `method` and defaults `segments` to 1. See wiki `rust_file_handler` and memory `project_animated_avatar_encoding`.
- **PLANNED, not built:** user avatars and banners are still the only two paths storing SOURCE bytes untouched on the PUSHED profile blob. They get ONE new `AssetKind` covering both (same replication profile: one per person you have ever met), `recv_cap` 1 MB == the authoring limit, 4 hashes/request. Do NOT raise `AssetKind::Avatar` for this — that kind is the 128px animated SERVER icon and 512 KB is right for it. User-scoped requests pass `peerHint`, not `serverId` (avatar frames are the precedent).
- **Wire token** `[a:kind:hash:w:h]` (kind `s`|`g`, hash 64-hex, dims 1..=4096) — dual-defined: Rust `node/emotes.rs::parse_asset_token`, Dart `emote_image.dart::assetTokenRegex`/`parseAssetToken`. Emotes keep `[e:name:hash]` untouched. w/h let receivers reserve the EXACT box pre-pull (no reflow). `emote_tokens_to_shortcodes` (Rust + Dart) maps asset tokens → `[GIF]`/`[Sticker]` for plain-text notification surfaces.
- **Render** `message_text_parser.dart` `_TokenKind.asset` → `ChatAssetImage` (emote_image.dart): token alone on its own line = block (GIF ≤480px / sticker ≤160px wide, never upscaled past source, interface-scale only — NOT chat text scale, same rule as attachments); inline = 2 line-heights riding the text scaler. Missing blob = sized placeholder + `requestAssetOnce(hash, kind: ...)` (emote_provider.dart, shares the session dedup set + `EmoteAssetsReceived` invalidation).
- **FFI** `request_assets(hashes, kind, server_id, peer_hint)` beside `request_emotes` (which is now the emote-kind shorthand). `NodeCommand::RequestEmotes` gained a `kind` field.
- **Storage Manager**: `StorageBreakdown.asset_blob_bytes/count`; "Emotes & GIFs" segment + cleanup-menu action (`clear_unreferenced_asset_blobs`); cap slider (default 512 MB, key `asset_cache_cap_mb`, desktop + mobile) enforced via `enforce_storage_caps` (new `asset_cap_mb` arg) on FileCompleted AND EmoteAssetsReceived. LRU-evict by `added_at` (`evict_asset_blobs`, 0.8 hysteresis) — hashes referenced by personal_emotes / server CRDT emotes / `server_banner` settings / OUR OWN avatar frame are NEVER evicted (`referenced_asset_hashes`).
- **Harness tests**: `asset_cap_enforced_per_kind` (300 KB blob refused as emote, accepted as gif — proves the cap follows OUR recorded kind and failed receipts retry), `asset_request_not_answered_for_unrequested_hash` (unsolicited valid bundle dropped; uses `MockRelay::inject_direct`). Widget: `test/widget/asset_token_render_test.dart`.

## Server Banners (issue #25, asset-rail Phase 2, 2026-07-28)

First consumer of the generalized rail beyond emotes. The CRDT carries ONLY the hash: `settings["server_banner"]` = 64-hex SHA-256 (`""` = cleared), `settings["server_banner_animated"]` = `"1"|""` — plain `ServerSettingChanged` ops, MANAGE_SERVER-gated at author AND ingest, ZERO new swarm/sync_handler plumbing. Bytes live in `emote_blobs` with `kind='banner'` and pull on demand at `AssetKind::Banner` (1 MB cap).

- **Processing** `image_convert::process_server_banner_image(data) -> (webp, animated)`: 3:1 center crop → 960x320 lossy Q80; GIF → per-frame crop/resize animated WebP ≤1MB; animated-WebP passthrough ≤1MB; still ≤150KB. Thumb helper `process_server_banner_thumb` → 400x133 ≤40KB still. SIDE FIX in the same pass: `process_avatar_image` + profile `process_banner_image` switched from LOSSLESS `write_to(WebP)` to lossy Q80 (`encode_lossy_webp_via_animation`) — lossless size is content-dependent, photographic uploads randomly blew the caps and failed at authoring.
- **FFI** (`api/crdt.rs` beside the avatar trio): `set_server_banner` (process → `save_asset_blob(kind='banner')` → two `update_server_setting` writes, animated flag FIRST so the hash write lands complete), `clear_server_banner`, `get_server_banner -> Option<ServerBannerData{hash, animated, bytes: Option}>` (`bytes: None` = pull needed).
- **Dart** `server_banner_provider.dart`: `ServerBannerNotifier` (Map serverId → `ServerBannerEntry{bytes, hash, animated}`) — avatar-notifier clone incl. `applyLocalWrite` optimistic seed + `_writeGen`/`_writePending`; on hash-without-blob it fires `requestAssetOnce(hash, kind:'banner')` and records hash→serverId in `_pendingPulls`; `onAssetsReceived` (wired in event_provider's `EmoteAssetsReceived` arm) reloads the matching server. Loads on ServerUpdated + SyncCompleted + boot `loadAll` (hollow_shell).
- **Header UI** `channel_sidebar.dart _buildHeader`: no banner = unchanged 48px; banner = 120px, `AnimatedGifImage` background under a bottom-up scrim toward `hollow.surface` (alpha-0 surface color, never `Colors.transparent`), name + 3 action icons overlaid. Switcher key = `'header-$label-${banner.hash}'` so re-uploads crossfade. Animation gate = `windowFocusedProvider` via the new `AnimatedGifImage.animate` flag (reduce-motion stays internal to the widget; selected+mounted implied — the sidebar renders only the selected server). Polish rules (2026-07-28 review): scrim is a 6-stop eased ramp ending at FULL alpha (coarse stops band on dark themes; <1.0 leaves a banner sliver reading as a line), NO bottom border in banner mode, banner+scrim bleed 1px right over the sidebar's border column via `Positioned(right:-1)`+`Clip.none` (Container insets children by its border), and BOTH header variants pad right=sm so the action icons column-align with the channel header's "+".
- **Authoring**: desktop `overview_tab.dart` "Server Banner" block under the icon block (crop 3:1; GIF/animated-WebP picks BYPASS the crop dialog — it flattens to a still — with a 2 MB pre-check); mobile `mobile_server_settings_route.dart` tap-to-upload/hold-to-clear tile. Both stage optimistically + spinner + toasts.
- **Public browse**: `PublicChannelListResponse` gained `#[serde(default)] server_banner_thumb_b64` — a 400x133 STILL thumb (never the full blob; pre-join wire path to strangers), built by `assets::public_banner_thumb` on the responder + the local RequestPublicChannels shortcut; requester refuses >80 KB b64. Dart: `guestServerBannerProvider` (RAM), rendered as a still 3:1 strip atop the expanded guest section in `guest_server_sidebar.dart` (guest thumb ?? member banner, `animate:false`).
- **Eviction safety**: `referenced_asset_hashes` already keeps `settings["server_banner"]` hashes (pre-wired in Phase 1).
- **Tests**: harness `server_banner_hash_replicates_and_bytes_pull_on_demand` (setting converges, bytes never ride the CRDT, rail pull byte-exact, clear converges; seed tags 85/86) + `banner_write_rejected_without_manage_server` (author-side Error + owner-state absence; tags 87/88). Widget: `test/widget/banner_header_test.dart` (48px home / 48px no-banner / 120px + hash key with banner).

## Animated Server Icons (asset-rail follow-up, 2026-07-28)

Same split as banners, applied to the server icon. The still 128px WebP stays base64 INSIDE `settings["server_avatar"]` (old clients + the public-sync thumb read only it — never bloat this with animation); an animated upload ADDITIONALLY writes `settings["server_avatar_anim"]` = 64-hex SHA-256 (`""` = still-only/cleared), blob in `emote_blobs` with `kind='avatar'`, pulled at `AssetKind::Avatar` (512 KB cap).

- **Processing** `image_convert::process_server_avatar_anim(data) -> Vec<u8>`: square per-frame center crop → 128x128 animated WebP Q80 ≤512KB (GIF branch); animated-WebP passthrough ≤512KB; errors on still input — the caller gates on `image_convert::is_animated_image` (GIF8 or RIFF/WEBP/VP8X+ANIM-flag).
- **FFI** (`api/crdt.rs`): `set_server_avatar` now splits still + anim — anim hash written FIRST so the still write (which drives ServerUpdated → UI reloads) lands with its companion in place; a STILL upload writes `server_avatar_anim=""` (replaces any previous animated icon). `clear_server_avatar` clears both. Reader `get_server_avatar_anim -> Option<ServerAvatarAnimData{hash, bytes: Option}>` (`bytes: None` = pull needed).
- **Eviction safety**: `referenced_asset_hashes` (api/storage.rs) pins BOTH `server_banner` and `server_avatar_anim` settings hashes.
- **Dart** `server_avatar_anim_provider.dart`: `ServerAvatarAnimNotifier` — banner-notifier clone (same `_writeGen`/`_writePending`/`_pendingPulls`, same-hash short-circuit, `requestAssetOnce(kind:'avatar')`, `onAssetsReceived` wired in event_provider's `EmoteAssetsReceived` arm; loads on ServerUpdated + SyncCompleted + boot `loadAll` in hollow_shell).
- **Render** — shared `ui/components/server_icon_image.dart` `ServerIconImage{serverId, size, isSelected, fallback, borderRadius}`: anim entry > still > fallback; `animate = (ownHover || isSelected) && windowFocusedProvider` (reduce-motion internal to AnimatedGifImage; frame 0 while gated). Sites: server_strip 44px (`isSelected`), bottom_bar dock 38px (`isSelected || isRightPaneServer`), mobile chats row 44px (`isExpanded` = watched, no hover on touch), authoring tiles desktop 48/mobile 80 (`isSelected:true` — the tile counts as watched; staged picks render via bare AnimatedGifImage). Folder cells + guest 20px sidebar avatar stay STILL (read `serverAvatarProvider` directly).
- **Authoring**: animated picks (GIF/animated WebP) BYPASS the crop dialog in BOTH `overview_tab._pickServerAvatar` and mobile `_pickAvatar` (2 MB pre-check; cropper flattens to a still PNG); both seed `serverAvatarProvider` AND `serverAvatarAnimProvider` optimistically (still pick seeds anim with null = clears).
- **Tests**: harness `server_avatar_anim_hash_replicates_and_bytes_pull_on_demand` (seed tags 89/95; in-memory 2-frame GIF via image::codecs::gif::GifEncoder → hash converges, rail pull byte-exact at AssetKind::Avatar, clear converges). Widget `test/widget/server_icon_anim_test.dart` (fallback / still-only / anim-wins-idle / selected-animates / unfocused-pauses / hover-gates).

## Wire Token

`[e:name:hash]` — inline in message text AND as reaction "emoji" strings. name = 2-24 of `[a-z0-9_]`, hash = full SHA-256 hex (64 lowercase) of the processed WebP bytes. Grammar in TWO places, keep in sync:
- Rust: `node/emotes.rs:parse_emote_token()` / `crdt/mod.rs:valid_emote_name()/valid_emote_hash()`
- Dart: `lib/src/ui/chat/emote_image.dart:emoteTokenRegex` / `parseEmoteToken()`

Old clients render the raw token as text (graceful degradation). Token built by FFI `emotes.rs:emote_token()` (sync).

## Rust: Processing and Storage

**`node/image_convert.rs:process_emote_image(data) -> (webp_bytes, animated)`** — stills ≤64px lossy WebP Q90 ≤32KB; GIF → frame-resized animated WebP Q75 ≤256KB; already-animated WebP passthrough under 256KB cap (container + first-frame verified; the image crate can't re-encode animation). Re-encoding at authoring = sanitization.

**SQLCipher tables** (`storage/messages.rs`):
- `emote_blobs (hash PK, bytes, animated, added_at)` — content-addressed cache, shared across servers/DMs. CRUD: `save_emote_blob` / `load_emote_blob` / `has_emote_blob`.
- `personal_emotes (name PK, hash, animated, source, added_at)` — the user's global set; `source` = `upload` | `ffz:<id>`. LOCAL only (no sibling sync yet). CRUD: `add/remove/list_personal_emotes`.

## Rust: Server Sets (CRDT)

`CrdtPayload::EmojiAdded { name, hash, animated }` / `EmojiRemoved { name }` → `ServerState.emotes: HashMap<name, EmoteInfo>` (`#[serde(default)]`, cap `MAX_SERVER_EMOTES = 50` at authoring AND apply). Gated by `Permission::MANAGE_EMOTES` (1<<7, Admin+ default). Authoring: `sync_handler.rs:handle_emote_op()` (mirror of handle_label_op: apply → CrdtStore persist → ServerUpdated → MLS broadcast + plaintext twin). Ingest arms in BOTH permission matrices (`handle_envelope_crdt_op` + swarm CrdtOpBroadcast) validate name/hash grammar too. Accessor: `ServerState::emotes_list()`.

## Rust: Byte Replication (pull-based)

Bytes NEVER ride the CRDT, message envelopes, or relay rings. Module **`node/emotes.rs`**:
- `NodeCommand::RequestEmotes { hashes, server_id, peer_hint }` → `handle_request_emotes()`: filters already-cached/already-requested (per-connection `requested_emote_hashes` set in swarm.rs, cleared on WS Disconnected), sends `HavenMessage::EmoteRequest { hashes }` to the DM sender's devices (`send_raw_to_identity`) or ONE online server-room member — never a broadcast.
- Inbound `EmoteRequest` → `handle_emote_request()`: answers with whatever subset is cached, as `EmoteAssets { bundle_json }` (the showcase bundle codec `api/showcase.rs:encode/decode_asset_bundle` — JSON map hash→base64, receiver-verified).
- Inbound `EmoteAssets` → `handle_emote_assets()`: verifies sha256 == hash (via bundle codec), RIFF/WEBP magic, ≤256KB cap → `save_emote_blob` → emits `NetworkEvent::EmoteAssetsReceived { hashes }`.
- Reactions: `valid_reaction_emoji()` (≤10-byte Unicode OR emote token) enforced at `message_ops.rs:handle_envelope_add_reaction` (choke point for MLS/Olm/public paths) + the swarm AddReaction arm.

Offline-only holder → token renders as `:name:` text until they return.

## FFI (`api/emotes.rs` → generated `lib/src/rust/api/emotes.dart`)

`process_and_store_emote(raw)` → ProcessedEmote{hash,animated}; `get_emote_bytes(hash)`; `request_emotes(...)`; personal CRUD (`add/remove/list_personal_emotes` — names normalized to lowercase, grammar-validated); server set (`get_server_emotes`, `add_server_emote` [requires blob cached locally], `remove_server_emote`); FFZ (`ffz_search(q)`, `ffz_curated()` [default view], `ffz_global()` [fallback], `ffz_import_emote(image_url)` — REFUSES any URL not on `https://hollow.anonlisten.com/ffz/emotes/`).

## Website Proxy (authoring-time only)

`ffz/` **in the HOLLOW repo** (canonical since 2026-07-28; deploy: `/public_html/hollow/ffz/` — the old WholesomeStoryAday copy is superseded). `search.php` POST-only, modes `q=` (search, 30d TTL) / `curated=1` (the picker's DEFAULT view: ~110 hardcoded popular emotes `[id,name,owner,animated,usage]` — zero FFZ API cost, ALL rows returned instantly) / `global=1` (FFZ global sets, 7d TTL — legacy, kept as client fallback for an old proxy that answers `[]` to curated). **Metadata and media are separate requests (v2, Phase 0 of the asset-rail epic):** search responses return image URLs unconditionally and never download inline; `fetch.php` is the read-through media cache (only ids in `ffz.db` are fetchable — never an open proxy; atomic tmp+rename; 404 = short negative cache), and the `.htaccess` `!-f` rewrite serves warm files straight from Apache with no PHP. `ext` column is OWNED by fetch.php after first insert (animated gif→webp CDN fallback learning) — search-side upserts never touch it. `SEARCH_VER=2` (sync with `FFZ_SCHEMA_VER` in api/emotes.rs). Same retrofit applied to `igdb/` (v11, plus an `images` registry table carrying the IGDB size slug). FFZ unauthenticated limit = 120 points/min per IP, shared by ALL users through the proxy → caching is load-bearing; on 429 stores a Retry-After backoff (`meta.backoff_until`) and serves stale (image CDN fetches don't spend points). `.htaccess` denies ffz.db + `.tmp.` files, hard-caches images. Users NEVER contact FFZ; viewers never contact even the proxy.

## GIF Proxy (`gifs/`, asset-rail Phase 3, 2026-07-29 — LIVE)

`gifs/` **in the HOLLOW repo** (canonical, published for no-log auditability; deploy `/public_html/hollow/gifs/`; Klipy key lives ONLY in server-side `config.php` — gitignored, never ships in the client, Klipy embeds it in the URL path which is exactly why the app must never talk to Klipy directly). Upstream `api.klipy.com/api/v1/{KEY}/gifs/{search|trending|categories}`.
- **`search.php`** POST-only (query text never in URLs/access logs). Modes `q=` (24h TTL) / `trending=1` (1h) / `categories=1` (7d); params `page`, `per_page` (8..50), `rating` (g|pg|pg-13|r, default pg server-side). **Normalized contract the app codes to** (provider-agnostic — swapping providers is a PHP change): `{result, items:[{id,w,h,title,still,sm,full}], page, has_next, meta:{backoff_until}}`; categories → `{result, categories:[names]}`. `gifs.db`: `queries` (qkey embeds rating+per_page+page; `ver`=SEARCH_VER, currently 2), `items` = the FETCH REGISTRY (id,w,h,title,sm_ext,src_json = raw Klipy `file` object — upstream URLs come from HERE, never the request), `inflight` single-flight (lock released BEFORE emit — PHP `finally` does NOT run on exit()), `ratelimit` valve 150 req/5min keyed sha256(random-daily-salt|ip) prefix (salt rotates+table wipes daily; raw IPs never on disk), `meta` backoff. Empty results negative-cached 1h (incl. categories). Upstream failure → 60s backoff (429 honors Retry-After 5..3600); stale-beats-nothing during backoff. `customer_id` = random UUID per request, never stored; no ad-* params; `type:"ad"` items, mp4-only clips, malformed slugs stripped at ingest.
- **Klipy LIVE shapes** (demo-app DTOs were right for items, OUTDATED for categories): item `{slug,title,blur_preview,type,file:{hd|md|sm|xs × gif|webp|mp4 → {url,width,height,size}}}`; categories `data:{locale,categories:[{category,query,preview_url}]}` — only NAMES leave the server (preview_url points at Klipy's CDN; clients talk ONLY to our proxy).
- **`fetch.php`** read-through media: `m/<id>.still.webp` + `m/<id>.sm.<ext>` (flat+extensioned so Apache serves warm files with no PHP; ext per-item from registry, mismatch = 404). **Klipy has NO still format** — stills GENERATED: GD first-frame from GIF variant (Imagick fallback), ≤150px WebP Q80, degraded fallback = animated sm verbatim. Grid-shows-stills is the #1 bandwidth lever.
- **`full.php`** `f/<id>` send-time source: hd→xs best-first, webp preferred, 25 MB cap w/ walk-down, NEVER on disk, `max-age=3600`. Phase-4 app path: download full → re-encode ≤480px animated WebP ≤2MB → content-addressed blob → P2P (re-encode IS the sanitization).
- **`sweep.php`** CLI-only + .htaccess-denied hourly cron (MANDATORY — GIF long-tail is unbounded): 4 GB cap, LRU by max(atime,mtime) w/ 90% hysteresis, prunes db tables. Cron uid `zj14IQFyxk` (created via Hostinger API — hPanel add silently didn't register; username u388188406).
- `GIFS_BASE_URL` from config.php, NEVER the Host header. `.htaccess` denies config/db/sweep/`.tmp.`; rewrites `m/…`→fetch.php, `f/…`→full.php.
- Live-verified 2026-07-29: trending/search/categories real data; cold still ~200ms, warm ~100ms Apache-direct immutable; denials 403; valve trips at exactly 150. Legal: privacy policy "Emote and GIF search (optional)" section BOTH copies (also first-ever FFZ disclosure); enumeration line names FrankerFaceZ/KLIPY.

## GIF Picker (issue #26, asset-rail Phase 4, 2026-07-29 — DONE)

The in-app picker over the GIF proxy. **STATUS: complete.** The "searches never render, UI spins forever" bug was NOT FRB losing future completions — it was `whenComplete(() => _inflight.remove(key))` in `GifCatalog.page` and `GifThumbCache.load`: `Map.remove` returns the removed value, the map holds that same whenComplete future, and `whenComplete` waits for an action-returned Future — so the future waited on itself. The inner `.then` still ran (caches warmed → a reopened picker painted instantly) while every caller's `.then` never fired, and the 25s `.timeout` sits upstream of the deadlock so it could never fire either. Fix = block bodies. Rule: `feedback-whencomplete-self-wait`.

- **Rust FFI `api/gifs.rs`** — TWO MODES behind one normalized `GifPage` contract: `gif_search(q,page,rating)` / `gif_trending(page,rating)` / `gif_categories()`; `gif_fetch_and_store(id, source_url) -> StoredGif{hash,w,h,animated}`. Base configurable via `set_gif_proxy_url` (https-only, trailing slash normalized — the slash IS the guard boundary; default `https://hollow.anonlisten.com/gifs/`).
  - **PROXY (default)**: per_page 30, `v`=2; item still/sm/full URLs prefix-checked against the configured base at parse (foreign rows dropped); the pick builds `{base}f/{id}` itself and IGNORES `source_url` — structurally not a fetcher.
  - **DIRECT (`set_gif_api_key`, 2026-07-29)**: a key present IS direct mode (one piece of state — no "enabled but no key"). Talks to `api.klipy.com` itself, so Rust owns a COPY of search.php's normalization (ad rows stripped, SIZE_SLOTS walk, mp4-only dropped) — the real cost: a provider swap stays a PHP change for proxy users, becomes an app release for direct-mode users. Klipy has no still format but its `jpg` variant IS a static frame → the stills-in-grid bandwidth model survives. `customer_id` random per request. Key validated as URL-path-safe (no `/?#%&\`, ≤200). **NOT a privacy win and the copy says so**: Klipy sees the user's IP + every search under one stable key.
  - **Media host allowlist** (direct only, `set_gif_media_hosts`, default `klipy.com` SUFFIX-matched → covers api./static./static2.). User-editable because a CDN move would otherwise need an app release; refused hosts are remembered (`gif_blocked_media_hosts`, cleared on any settings change) and offered in Settings with an Allow button. `url_host()` takes everything after the LAST `@` (`static.klipy.com@evil.example` resolves to evil.example) and refuses plaintext http.
  - **Pick-time resolution, direct**: a RAM registry (600 entries, FIFO, cleared on every source change) populated by OUR OWN parse maps id→variants. `source_url` applies ONLY on a registry miss — the one case it cannot cover, a favourite saved in an earlier session — and ONLY through the allowlist. `GifItem.full_url` exists for exactly this (the proxy always returned `full`; we were dropping it).
  - **Content rating is a per-CALL parameter, never a Rust global**: Dart owns policy (user setting → `clampGifRating` caps R at pg-13 inside servers not flagged NSFW; DMs/conferences pass through) and the rating is part of the `GifCatalog` cache key, so a rating change can never serve results fetched under the previous one. `gif_ratings()`/`default_gif_rating()` are read from Rust, never mirrored. **Default = `pg-13`** (Rust `DEFAULT_RATING`, mirrored as `kDefaultGifRating` for the synchronous Notifier seed) — deliberately ONE STEP ABOVE `gifs/search.php`'s own `DEFAULT_RATING` ('pg'), which now only applies to a request carrying no rating at all, i.e. a client older than this feature; loosening what THEY receive would be a change nobody opted into.
- **ALL website-proxy HTTP (gifs + FFZ + showcase) rides `get_http_runtime()`** (api/network.rs) — dedicated 1-worker runtime; on the node runtime reqwest's DNS starves behind SQLCipher bursts (blocking pool capped 8) and requests wait the full 20s timeout unsent. Rule: `feedback_http_runtime_isolation`.
- **Transcode `image_convert::process_gif_for_send`**: NO animated-WebP passthrough (full.php prefers hd webp — oversized; re-encode IS sanitization). GIF via GifDecoder, animated WebP via `webp_animation::Decoder` (first use); frames resized during decode (MAX_FRAMES 300); quality→dimension ladder (480/Q80 → 480/Q65 → 400/Q55 → 320/Q45) until ≤2MB (== `AssetKind::Gif.recv_cap()`).
- **Composer**: `EmoteComposerController` gained a parallel `ComposerAsset` map — `placeholderForAsset(kind,hash,w,h)`, `displayTextFor` maps `[a:...]` tokens, `expandedText()` emits them, buildTextSpan renders inline ChatAssetImage (36px). 1 PUA ↔ 1 WidgetSpan holds for assets.
- **UI `ui/chat/gif_picker.dart`**: `showGifPicker` overlay (emoji-picker shell clone, teardown guard) + reusable `GifPickerBody`. Browse tabs = **Popular (default) / Favourites / Recent**, ALWAYS rendered; typing overrides the tab and simply DESELECTS all three (a row that vanishes as you type shifts the grid and hides where you came from). Tapping a tab while searching clears the field — including the already-active tab, so `_selectTab` must not early-return on `_tab == tab` while `_search` is non-empty; the clear fires the controller listener, which runs the query, so `_selectTab` must NOT also call `_runQuery` (two requests, one superseded). `_networkView` = search non-empty OR Popular; `_runQuery()` bumps the seq UNCONDITIONALLY so a Popular reply still in flight can never land on a library tab. Boot prefetch (hollow_shell, +5s) + `GifCatalog.peek()` sync warm-read = zero-spinner open. Search debounced 250ms with the seq re-checked BEFORE issuing (a stale query must never hit the proxy valve). Manual 2-col masonry from item w/h (aspect clamped 0.6..2.5); stills viewport-gated (±1 screen); **animation AUTOPLAYS on every platform** (2026-07-29 — hover-to-play felt bland), behind `gifAutoplayProvider` (ON by default, persisted, toggle in the GIF Search card): `wantsAnim = focused && (autoplay ? widget.visible : _hovering)`. Bounded to cells actually in the viewport (NOT the ±1-screen still-preload margin), only while the window is focused, and AnimatedGifImage freezes itself under reduce-motion. OFF = hover-to-play, which on mobile means stills only — that IS the point: the setting's real cost is DATA (autoplay fetches the animated variant for everything on screen, hover fetches one), which lands in the `GifThumbCache` 200 MB disk LRU, NOT in the asset-blob cap. Positions come from our own masonry math. Cost: the sm variant downloads for everything on screen, which is why stills still paint first and the animation swaps in as it lands. Pagination ≤5 pages gated on `maxScrollExtent > 0` (short content otherwise auto-paged every scroll tick); library grids never paginate. Pick = in-cell spinner → `gif_fetch_and_store` → `noteUsed` → `[a:g:hash:w:h]` via the panes' `_insertEmojiAtCursor`. Error state has a Retry button. "Search KLIPY" placeholder + "Powered by KLIPY" footer (attribution). Buttons: `composerGifButton` "GIF" text badge (chat_pane_shared) in both desktop panes; mobile = GIF row in the [+] attach sheet → 0.62-height bottom sheet. **The prefilled category chips are GONE** — `gif_categories()` FFI and `GifCatalog.categories()` remain (the proxy endpoint is fine) but nothing in the picker calls them.
- **Favourites/recents (`core/providers/gif_library_provider.dart`)**: `SavedGif` + `GifCollection` + `GifLibrary`, one JSON blob in the encrypted settings store (`gif_library`), loaded from hollow_shell's boot sequence right AFTER the proxy URL. Recents 60 (newest first, deduped, written on pick), favourites 500, lists 20 with 32-char names. **CRITICAL — SavedGif stores media paths RELATIVE to the proxy base** (`m/<id>.(still|sm).<ext>`, `f/<id>`) and rebuilds absolute URLs against the live base on read: a stored absolute URL is a stored fetch target, so this keeps Rust's origin guarantee true through the local store, and a self-hoster who changes proxies keeps their favourites. **Direct-mode rows are the exception** — Klipy CDN paths are opaque and cannot be rebuilt from an id, so they store the absolute https URL. The guard MOVED rather than disappearing: `GifLibraryNotifier.revalidate()` asks Rust `gif_media_urls_permitted` (true under the active proxy base; in direct mode also for allowlisted hosts) on boot and on every source change, and refused rows go into `GifLibrary.hiddenLocations` — HIDDEN, never deleted, never persisted, so they return when you switch back. The case that matters: a CDN URL saved with your own key must not be fetched after you return to the proxy, which is the whole point of the proxy. Decode is tolerant per row. Star = corner button on every cell (hover-revealed on desktop, persistent once favourited, always on mobile). Right-click / long-press → `showGifMenu`, a TOPMOST OverlayEntry (the picker is itself a raw OverlayEntry, so a dialog route renders BEHIND it) with favourite toggle / per-list membership / remove-from-recent. Lists sort FAVOURITES only — unfavouriting evicts from every list; list create+rename use an INLINE field for the same z-order reason.
- **Chat sizing (`assetChatBox` in emote_image.dart)**: an asset token ALWAYS block-renders — GIFs fit 300x250 (the exact image-attachment box), stickers 160x160, never upscaled past the source pixels. Text sharing the token's line is a CAPTION: `_matchAssetToken` records atLineStart/atLineEnd (horizontal whitespace does not count as sharing) and the span builder injects a synthetic newline on whichever side needs it, trimming the caption's leading spaces. `ChatAssetImage` takes an explicit width+height; width null = inline mode (notification previews, composer). The old "480px wide alone / 2 line-heights with text" split is gone.
- **`GifCatalog`** (`core/providers/gif_provider.dart`): session RAM cache (trending 10min / search 1h TTLs, inflight dedup, 25s hard timeout so a lost future frees the key), `prefetchTrending()` also warms the first 10 stills. Overridable for widget tests via `gifCatalogProvider`. `gifProxyUrlProvider` / `gifApiKeyProvider` / `gifRatingProvider` / `gifMediaHostsProvider` all follow the relayDomain pattern (SQLCipher-persisted, boot-pushed in that order before the library loads); `gifDirectModeProvider` derives from the key. Any SOURCE change (proxy URL, key, hosts) calls `_onGifSourceChanged` → `GifCatalog.clear()` + blocked-host refresh, because the two modes hand out different URLs for the same GIF id. `GifProxySettingsCard` (network_section.dart, shared desktop + mobile) now carries: rating segment, own-key field (obscured + reveal), media-host editor with Allow buttons for blocked hosts, and the self-hosted proxy URL.
- **`GifThumbCache`** (`core/services/gif_thumb_cache.dart`): disk LRU 200MB by mtime (app cache dir/gif_thumbs, atomic tmp+rename, 90% hysteresis) + RAM tier + inflight dedup; ONE shared keep-alive HttpClient + 4-slot FIFO download semaphore (unbounded parallel thumbs saturated the link AND Hostinger's PHP workers); client recreated on download exception (wedged keep-alive sockets). Storage Manager: Dart-computed "GIF search" segment + cleanup item (`gifThumbCacheSizeProvider`).
- **Notifications**: `emotePreviewSpans` extended for `[a:...]` (was the one Phase-4.5 gap — in-app cards rendered raw tokens); plain-text `[GIF]`/`[Sticker]` mapping existed since Phase 1 (Dart + Rust push_enrich).
- **Diagnostics (release-safe, kept)**: Rust `[HOLLOW-GIF]` (mode + ms, never query text), Dart `[HOLLOW-GIF-UI]`/`[HOLLOW-GIF-THUMB]` via logFromDart. `hollow_debug.log` is NEXT TO THE EXE. Manual live checks: `test/manual/gif_live_ffi_check.dart` (real Release DLL), `gifs::tests::live_proxy_smoke` + `live_saturated_blocking_pool_smoke` (#[ignore], live net).
- **Tests**: 9 Rust (parse/guard/base + 5 transcode), 3 composer asset, 10 picker widget, 11 `test/gif_library_test.dart`, 8 `test/widget/asset_token_render_test.dart` (box maths + caption layout). `GifCatalog` exposes a `@protected fetchPage`/`fetchCategories` raw-FFI seam — **fake THAT, not `page()`**: the 3 original picker tests replaced `page()` wholesale, so the wrapper holding the whenComplete deadlock never ran and all stayed green. Regression cover = `test/gif_catalog_test.dart` (7) + `test/gif_thumb_cache_test.dart` (2) + "picker: renders results through the REAL catalog chain". The two unit files MUST stay plain `test()` — under `testWidgets`' FakeAsync a permanent hang is indistinguishable from waiting (that is how the first repro got written off as a FakeAsync artifact). 4.2's per-user direct Klipy key SHIPPED 2026-07-29 (see the Rust FFI bullet); its cover is 14 Rust tests in gifs.rs + `clampGifRating` and rating-cache-key cases in gif_catalog_test.dart. **ADS: researched, deliberately NOT built** — KLIPY ad revenue is priced on a durable per-user id + real client IP (the exact data the proxy refuses to hand over), and programmatic creatives are HTML/JS needing a webview inside an E2EE messenger. Full reasoning: ASSET_RAIL_PLAN.md §ADS.

## Dart Surfaces

- **`core/providers/emote_provider.dart`** — `emoteBytesProvider(hash)` (FutureProvider.family), `serverEmotesProvider(serverId)` (invalidated on ServerUpdated in event_provider `_refreshServerState`), `personalEmotesProvider`, `requestEmoteOnce()` (session-deduped fire-and-forget; sync try/catch AND .catchError). `EmoteAssetsReceived` event → `clearRequestedEmotes` + invalidate per-hash providers.
- **`ui/chat/emote_image.dart`** — `EmoteScope` InheritedWidget (serverId/peerHint pull context; wrapped around ChatPane, ChannelChatPane, MobileChatRoute body) + `EmoteImage` (renders cached bytes via Image.memory gaplessPlayback; missing → `:name:` fallback + requestEmoteOnce).
- **`ui/chat/emoji_picker.dart`** — unified picker (see ui_message_bubbles.md > EmojiPicker) + shared authoring helpers `pickAndNameEmote()` (pick → name dialog opens INSTANTLY with raw-bytes preview, WebP encode runs in a tracked background future, Save awaits it under a spinner, '' pop sentinel = processing failed → caller toasts) / `promptEmoteName()` (hash-preview variant, FFZ fallback). Removal UX = `_showEmoteContextMenu` (right-click OR long-press, anchored `showDialog` transparent-barrier menu — picker stays open behind it; NO confirm dialog): Mine tab → "Remove from my emotes"; Recently-used cells in the Emoji tab → "Remove from recents" (`_removeRecentEmoji` persists). FFZ tab empty-search default = `ffzCurated()` → falls back to `ffzGlobal()` on `[]` (old proxy).
- **Unicode tofu fix** — bundled `assets/fonts/NotoColorEmoji.ttf` (10.2MB, CBDT) as `kEmojiFontFallback` in `hollow_typography.dart` `_base`, active ONLY on Windows/Linux (Win10 Segoe UI Emoji stops at Emoji ~12; picker data is Unicode 16). Flows through ThemeData.textTheme → DefaultTextStyle everywhere (no `inherit: false` in lib/). macOS/iOS/Android keep native emoji fonts. **The committed font is SUBSET emoji-only** (`scripts/subset_emoji_font.py` drops codepoints < U+00A9): upstream Noto maps space/CR/#/*/digits with emoji-wide advances, and a fallback next to `fontFamily: null` serves them — unsubset it explodes word spacing app-wide. Rerun the script after any upstream font refresh.
- **Context menu z-order** — the picker is a raw OverlayEntry above navigator routes, so `showDialog` renders BEHIND it; `_showEmoteContextMenu` inserts its own topmost OverlayEntry (double-remove guarded) instead.
- **`ui/chat/message_text_parser.dart`** — `_TokenKind.customEmote` WidgetSpan; **`reaction_bar.dart`** renders token reactions as EmoteImage pills.
- **`ui/settings/emotes_tab.dart`** — server settings Emotes tab (view for all, add/remove gated on `Permission.manageEmotes`, 50 cap); registered in `server_settings_panel.dart`.
- Composer entry points: desktop emoji button in chat_pane + channel_chat_pane (`_openComposerEmojiPicker`/`_insertEmojiAtCursor`), mobile `_showEmojiSheet` (EmojiPickerBody bottom sheet).

## Tests

- Harness: `test_harness.rs:server_emote_replicates_and_bytes_pull_on_demand` (metadata replication, byte pull + verification, permission rejection, removal convergence).
- Widget: `test/widget/emoji_picker_crash_test.dart` (search typing, double-tap teardown guard, tab switching, HollowTextField-in-overlay component guard).

## Composer Integration (shipped 2026-07-11)

**`ui/chat/emote_composer.dart`** — three pieces:
- `EmoteComposerController extends TextEditingController`: emotes render INLINE in the input bar. Each inserted emote = ONE private-use char (U+E000+, allocated per instance) mapped to (name, hash); `buildTextSpan` swaps mapped chars for `WidgetSpan(EmoteImage)` — the 1-char ↔ 1-WidgetSpan LENGTH MATCH is load-bearing (a widget replacing the 70-char token desyncs caret/selection). `expandedText()` produces `[e:name:hash]` wire tokens; unmapped PUA chars (foreign paste) are stripped. `clear()` wipes the map. **EVERY send site must read `expandedText()`, never `.text`** — chat_pane `_handleSend`/`_sendStagedFile`, channel_chat_pane ditto, mobile_chat_route `_handleSend`. Picker insertion goes through `displayTextFor()` (token → placeholder).
- `scanEmoteShortcode()` / `acceptEmoteSuggestion()`: shared `:query` trigger logic (colon at start/after whitespace, 2+ `[a-zA-Z0-9_]` chars; custom emotes first, then Unicode by name, cap 8).
- `EmoteAutocomplete`: desktop overlay (mention-overlay pattern — CompositedTransformFollower; channel pane SHARES `_mentionLayerLink`, DM pane got its own `_composerLayerLink`). Key routing: pane `Focus.onKeyEvent` calls `handleKey` (arrows/Enter/Tab/Escape) BEFORE `handleChatInputKey`. Mobile = Column-child panel above the input bar (mention-panel pattern: `_emoteCandidates`/`_buildEmotePanel` in mobile_chat_route).

**Mobile server-emote management**: `ui/mobile/mobile_emotes_route.dart` (port of desktop EmotesTab), NavRow in mobile_server_settings_route Management block — visible to all, add/remove gated on MANAGE_EMOTES inside.

Tests: `test/emote_composer_test.dart` (expansion, placeholder mapping, trigger rules, acceptance).

## Notification Previews (2026-07-11)

Every notification surface must run message text through one of two `emote_image.dart` helpers — never print raw text (tokens show as `[e:name:<64-hex>]` garbage):
- **In-app (renders images):** `emotePreviewSpans(text, style)` → `TextSpan` pieces + `WidgetSpan(EmoteImage)` sized to the line. Used by desktop `NotificationOverlay._MessageRow` + `MobileInChatBanner`, each wrapped in `EmoteScope(serverId: card.serverId, peerHint: card.peerId)` — the message is from a chat the user does NOT have open, so bytes are usually uncached; shows `:name:` and flips to the image when the pull lands.
- **Plain text (OS toasts / push):** `emoteTokensToShortcodes(text)` → `:name:`. Choke points: `DesktopNotificationService.showDm/showChannel`; mobile `_showNotification`/`_showChannelNotification` in push_notification_service (covers lifecycle-background + FCM fetch paths). iOS killed-state NSE bodies come from Rust: `node/emotes.rs::emote_tokens_to_shortcodes` (manual scanner over `parse_emote_token`, unit-tested) applied in `push_enrich.rs` where the NSE JSON is built.

**Picker keyboard (mobile):** the search field's autofocus is DESKTOP-ONLY (`autofocus: !(Platform.isAndroid || Platform.isIOS)`) — on mobile it summoned the software keyboard over the sheet (and defeated the composer's pre-open `unfocus()` in `_showEmojiSheet`). Search focuses on tap.

## Stickers (issue #29, asset-rail Phase 5, 2026-07-30)

The last phase of the asset epic, and mostly plumbing — the rail already had
`AssetKind::Sticker` (512 KB receipt cap, 8 hashes/request) and the
`[a:s:hash:w:h]` token from Phase 1.

**Identity is the HASH, not the name.** An emote is TYPED as `:name:` so its
name has to be unique; a sticker is only ever picked visually, so its name is
a label two stickers may share, and packs group them. That decision drives the
whole schema: `ServerState.stickers: HashMap<hash, StickerInfo>` and
`personal_stickers PRIMARY KEY (pack, hash)`.

- **Processing** — `image_convert::process_sticker_for_send` → ≤512px, ≤512 KB
  (== the receipt cap), animation kept, ALPHA PRESERVED. Shares
  `process_asset_for_send` with `process_gif_for_send`; only the bounds,
  quality ladder and error label differ. TRAP when verifying alpha: every
  asset we emit is a WebP ANIMATION container (`ANMF`) even for a still, and
  `image::load_from_memory` reports alpha 255 for those — decode with
  `webp_animation::Decoder` (see `sticker_keeps_its_cut_out`).
- **Personal vault** — `personal_stickers (pack, hash, name, animated, w, h,
  source, added_at)`, free-form packs (`""` = ungrouped), caps 50 packs / 120
  per pack / 600 total. `api/stickers.rs` owns add/remove/list + pack
  rename (merges on collision) and delete. Local-only, like personal emotes.
- **Server packs** — `CrdtPayload::StickerAdded { hash, name, pack, animated,
  w, h }` / `StickerRemoved { hash }` → `ServerState.stickers`
  (`#[serde(default)]`, `MAX_SERVER_STICKERS = 50` at authoring AND apply).
  Reuses `Permission::MANAGE_EMOTES` — no new bit — and reuses
  `sync_handler::handle_emote_op`. Both ingest matrices validate hash/labels
  and the 1..=4096 dims (a row we could not build a token for has no business
  replicating). `ServerState::stickers_list()` sorts pack → name → hash so
  the order is TOTAL (two stickers can share a name).
- **KLIPY stickers** — `api/gifs.rs` is now generic over `MediaKind`
  (Gif | Sticker): same two modes, same URL guards, same allowlist and
  rating clamp. **ID NAMESPACE:** Klipy slugs are per-catalog, so a GIF and a
  sticker can carry the SAME slug while both registries key on id alone —
  sticker ids therefore carry a leading `~` everywhere (proxy `items` table,
  media URLs, the direct-mode variant registry). GIF ids stay BARE on
  purpose: the saved GIF library stores proxy-relative media paths, so
  re-namespacing GIFs would 404 every saved favourite. `~` is URL-unreserved
  and outside the slug charset. Proxy side: `search.php?kind=stickers`,
  `fetch.php`/`full.php`/`.htaccess` accept the optional prefix, GIF cache
  keys unchanged (`kns` is empty for gifs) so shipping stickers costs nobody
  a cold grid.
- **Picker** — `ui/chat/sticker_picker.dart`: `showStickerPicker` overlay +
  a host-agnostic `StickerPickerBody` (tabs Server / Mine / KLIPY / Recent).
  Placement behind its own composer button is PROVISIONAL — Vitalik wants to
  rethink the emoji/GIF/sticker button row, so the body is deliberately
  reusable and moving it later is a change of host, not of picker. A pick
  SENDS immediately and the panel STAYS OPEN (see "One Sticker Per Message").
  `StickerCatalog extends GifCatalog`, overriding only the raw-FFI seam — one
  copy of the cache/in-flight/timeout wrapper whose block-body `whenComplete`
  is load-bearing.
- **Recents** — `sticker_recents` setting, just `{hash, w, h}` rows. Unlike
  the GIF library there is NO media URL to store, rebuild against a proxy
  base, or re-authorize on a source change: a sticker's bytes are already a
  local content-addressed blob. The last tab is persisted alongside it
  (`sticker_last_tab`, stored as the enum NAME — an index silently re-points
  when the enum changes; `server` falls back to `mine` in a DM).
- **Token built in DART** at the picker (`'[a:s:$hash:$w:$h]'`), not through
  `stickers_api.stickerToken` — that is a SYNC FFI call and a sync bridge
  call throws outright when the bridge is not up. Same as the GIF picker.

## One Block Asset Per Message (issue #36, 0.9.3)

Horizontal mosaics are GONE. Nobody builds a horizontal mosaic out of
512px stickers — the shared-height run just read as "my stickers shrank when
I sent a few" — so stickers follow Telegram/Discord: one per message. **GIFs
follow the sticker**, not the other way round.

- **ONE budget, not one each.** `exceedsAssetLimit` counts stickers AND GIFs
  together (`countBlockAssetTokens`): they are the same visual class, and a
  per-kind cap would still let a sticker and a GIF stack. Inline emotes are
  not block assets and are never capped.
- **Send-on-click, both pickers**: `onSelect` reaches the host's `_sendAsset`,
  which inserts the token and immediately `_handleSend`s. Empty composer → the
  message is just the asset; text already typed rides along as a caption in
  the SAME message (the Discord half of the rule). Wired at all three hosts.
- **Both panels STAY OPEN.** `showGifPicker` used to `teardown()` before
  invoking `onSelect`; that is gone. Consequence: `_pick`'s `_pickingId` must
  now be cleared in a `finally` — it used to ride out on the teardown, and
  leaving it set freezes every later pick behind `if (_pickingId != null)`.
- **Focus never returns to the composer** on that path (`refocus: false`
  through `_insertEmojiAtCursor`/`_insertAtCursor` → `_handleSend`). On mobile
  the sheet sits over the composer, and refocusing raises the software
  keyboard on top of it on every single pick.
- **The cap is enforced at SEND, not at receive**, in `chat_pane_shared.dart`
  (one place, all three panes) over the EXPANDED wire text, so a hand-pasted
  `[a:s:…]`/`[a:g:…]` is caught too. It fails visibly with a toast and the
  composer intact — never silently trims what the user wrote.
- **Receive stays tolerant.** 0.9.0–0.9.2 shipped runs, so those messages
  exist: `_matchAssetToken` no longer absorbs neighbours, and multiple tokens
  render as consecutive FULL-SIZE blocks. `_endsWithNewline` stops the two
  adjacent blocks from each adding a break and opening a blank line.

## Sticker Mosaics (vertical, across messages)

The surviving form, and the popular one. Adjacency rule, no new data — works
for ANY sticker including KLIPY ones.

- `stickerTileCandidate` (sticker-only text, and no reply / reaction / file /
  edit marker to sit in the seam) + `stickerTilingFor` (both rows qualify AND
  are already grouped) → `tileWithPrev`/`tileWithNext` on both bubbles, which
  zero the row padding and the asset's own padding on that side and square the
  seam corners. Wired at all three panes.
- **Corners**: `stickerRunRadius(tileTop:, tileBottom:)` squares only the
  edges that sit against a tiled neighbour — a rounded corner there would
  notch the seam exactly where it must vanish.
- **CRITICAL — an asset-only message SKIPS the text paragraph.** Zeroed
  padding was not enough to close the seam: `Text.rich` gives the line holding
  a WidgetSpan the font's own ascent and descent, so a 160px sticker sat in a
  ~165px line box (measured: 3.6px above, 1.4px below) and two tiled halves of
  one drawing landed 1px apart — a visible line straight through the artwork.
  `blockAssetsOnlyMessage` detects a message with no text and
  `_assetOnlyBody` renders the widget directly. Gap is now exactly 0.0, pinned
  by a test.
  - Only for EXACTLY ONE asset and no `suffixSpans`. A pre-0.9.3 multi-asset
    message stays on the paragraph — stacking those in a Column reports an
    overflow inside any height-constrained box, which the paragraph does not.
    "(edited)" is real text, and an edited message never tiles anyway.
  - `Align(heightFactor: 1)` is load-bearing twice over: a message row hands
    down a TIGHT width, so without Align the media stretches across the pane;
    and without `heightFactor` Align fills the offered height and CENTRES the
    media in it, silently eating the very 4px difference tiling removes.
- **CRITICAL — touching exactly is STILL not enough; tiled media OVERLAPS by
  one device pixel** (`ChatAssetBlock._seamBleed`). Two abutting rounded clips
  are each antialiased, so the compositor gives their shared edge `1-αβ`
  coverage instead of 1 and up to 25% of the background shows through. Whether
  it shows depends on where the edge lands inside a device pixel, which is why
  the line appeared at 105%, shrank at 110%, vanished at 115% and returned at
  125%. The fix puts that antialiased edge INSIDE the neighbour's opaque body:
  `1.0 / MediaQuery.devicePixelRatioOf(context)` — correct at any zoom because
  `UiScaleBox` folds the zoom factor INTO the devicePixelRatio it publishes.
  Only the PAINT overruns (a `Stack` with a negatively-positioned child); the
  layout box is untouched, or every row below would shift. A zoom sweep test
  pins it. Never "fix" a seam by only zeroing padding — measure at 1.05x.

## Sticker Packs are FILES (`.hollow-pack`, issue #36)

**There is no pack link, and that is architectural, not stylistic.** Hollow
has nowhere to host bytes. A server invite works because the link carries only
an ID and the join happens over the relay into a room the inviter is already
in; a pack has no room behind it, so any URL would mean either serving
strangers from the author's node (a discovery surface we refuse to build) or a
CDN (a central server we refuse to run). Sending the file into a DM or channel
reuses the entire encrypted transfer path and adds zero discovery.

It is also the more private primitive: a live vault link would tell the author
who added them and let them push new bytes later; a file is a one-time copy
with no ongoing relationship. And it is the personal vault's ONLY backup story
— `personal_stickers` is local-only, so a reinstall loses it otherwise.

- **Container** (ZIP, modelled on `.hollow-shards`): `manifest.json`
  `{format_version, pack, author, author_pubkey_b64, created_at, items[],
  sig_b64}` + `blobs/<hash>.webp`, stored uncompressed (WebP already is).
- **Import re-derives everything** (`import_sticker_pack`): SHA-256 recomputed
  and required to match (the blob is keyed by the hash WE compute); `w`/`h`
  re-read from the decoded image and the manifest's ignored, because those two
  numbers go straight into the wire token; `validate_sticker_blob` checks WebP
  magic, the 512 KB receipt cap and 512px before any decode. Entry paths are
  never joined — the hash names the file. Caps are enforced per row, so a
  large pack fills to the limit and REPORTS the remainder (added / skipped /
  rejected) rather than failing whole.
- **Never re-encode on import.** A sticker's identity is the SHA-256 of its
  bytes, so a transcode would mint a new hash and orphan every token already
  sent against the original.
- **The signature is ATTRIBUTION ONLY.** It binds pubkey → claimed author the
  way `verify_device_list` does, and covers pack name, author, and every
  item's hash and dims in order. A missing or bad one means "no byline", never
  "refuse" — anyone may author a pack and no authority could say otherwise.
- **No pre-import thumbnail** — previewing would hand un-validated bytes to an
  image decoder before a single check has run.
- **UI**: import via "Add pack" on the Mine tab, a file picker filtered to
  `.hollow-pack` + `.zip` (a pack IS a zip, and one that has been through a
  mail client often comes back renamed). A received pack renders as
  `StickerPackCard` instead of a generic file row. Mobile export takes the
  temp-file detour — `saveFile` REQUIRES `bytes:` on Android/iOS.

## Making a Pack (issue #36)

Sharing packs was useless until you could BUILD one — before this the pack
column could only ever be set at upload time.

- **Packs behave like GIF favourite lists**, and the table already allowed it:
  `personal_stickers` is keyed on `(pack, hash)`, so one sticker can sit in
  several packs at once. Adding never moves it out of where it was.
- **Declared packs** (`sticker_packs` setting, `stickerPacksProvider`): a pack
  is a COLUMN on the rows, so an EMPTY one has nowhere to exist in the
  database and would vanish the moment it was created. This local name list is
  unioned with the packs derived from rows at render time. Rows are still the
  source of truth — imports and pre-0.9.3 data were never declared — so this
  only keeps an empty pack alive. Rename and delete must update BOTH, or an
  emptied pack returns under its old name.
- **Creating refuses a duplicate name** (case-insensitively) while RENAMING
  onto an existing pack still merges: merging is the only sane reading of a
  rename, but silently merging a *new* pack into an existing one destroys the
  distinction the user was drawing.
- **The "All" view dedupes by hash.** Two rows for one sticker in two packs
  reads as a duplicate rather than as membership.
- **Cell menu** — "Add to pack…" opens a SECOND `showGifMenu` listing every
  pack the sticker is not already in, plus "New pack…". That nesting works
  only because `showGifMenu` calls `dismiss()` BEFORE `item.onTap()`; the
  first menu's full-screen barrier would otherwise eat the next tap.
  Leaving one pack and deleting everywhere are separate items on purpose —
  conflating them is how people lose artwork.
- **"Share to this chat"** exports to a temp `.hollow-pack` and hands it to
  the host's `onSharePack`, which stages+sends it like a finished voice
  recording. The temp file is NOT deleted: our own bubble keeps reading its
  manifest from disk. The action hides itself when the host passes no
  callback. "Save pack to file…" remains the escape hatch.
- **One-tap save on KLIPY cells** (`onSave` badge) mirrors the GIF grid's
  star. Saving used to be buried in a right-click menu, which is not a
  gesture that exists on a phone.

## Known Follow-ups

Personal-emote and personal-sticker sibling sync; revisit the composer button
row (emoji / GIF / sticker is three buttons on a narrow phone).

## Avatar Frames (issue #54, 2026-08-22)

Decoration painted IN FRONT of a person's avatar, Steam/Discord style. The profile
carries an ID, never the art. Full design + iron rules: memory `project_avatar_frames`.

- **Wire** `UserProfile.avatar_frame` (`#[serde(default)]`, additive `user_profiles`
  column) on BOTH `HavenMessage::ProfileUpdate` and `MessageEnvelope::ProfileUpdate`.
  Three shapes and nothing else: `""` = cleared, `b:<hue>` = a built-in procedural ring
  (hue 0-359, canonical decimal — no leading zeros), 64-hex = an asset-rail blob hash.
  `None` = an old client, which PRESERVES what the receiver stored (COALESCE), exactly
  like `showcase_board`. It is a short string, so it rides the LIGHT announce.
- **Ingest** `social::sanitize_incoming_frame` is the ONLY validator, and anything
  unrecognised is treated as ABSENT (preserve), never as a clear. It matters because the
  field is plaintext on the `HavenMessage` fallback AND it keys a network PULL — an
  unvalidated string would be a request-anything primitive. `valid_avatar_frame_id` must
  stay 1:1 with Dart's `builtinFrameHue`/`isFrameHash`.
- **Bytes** ride the rail at `AssetKind::Frame`, pulled with `peer_hint` = the owner's
  MASTER (so `send_raw_to_identity` fans to their live devices). Never the profile blob:
  a profile update is PUSHED to everyone who syncs with you, the rail is PULLED and
  LRU-evicted. Only OUR OWN frame is pinned against eviction, mirrored into the
  `my_avatar_frame` app setting because `referenced_asset_hashes` has no identity to look
  a profile row up by.
- **Processing** `image_convert::process_avatar_frame(data) -> (webp, animated)`: square
  centre crop → 128x128, animated WebP Q80 for GIF, animated-WebP passthrough ≤256 KB,
  still lossy WebP ≤64 KB. Plus the AUTHORING GATE that makes a foreground frame work —
  `frame_centre_opacity` samples the middle 42% disc (mean across frames) and refuses over
  40% opaque, because a frame with a solid middle just hides the avatar it decorates.
- **FFI** `process_and_store_avatar_frame -> ProcessedFrame{hash, animated, bytes}` and a
  new `avatar_frame: Option<String>` on `update_profile` (validated there too, so a
  malformed ID is reported to its author instead of being dropped by every receiver).
- **Render** `AvatarFrame` (`ui/components/avatar_frame.dart`) inside `HollowAvatar`, so
  all 78 avatar call sites inherit it at once. ZERO layout cost: a `Stack(clipBehavior:
  none)` whose only non-positioned child is the avatar, with the art in a `Positioned`
  inset by `-frameOverhang` and `BoxFit.contain` into `size * kFrameScale` (1.33).
  Skipped under 24px. **Any ancestor that clips to the avatar's bounds eats it** — chiefly
  the badge `Stack` that hangs a status dot, which defaults to `Clip.hardEdge`
  (CI-guarded, `test/avatar_frame_clip_guard_test.dart`).
- **No frames on ANY voice or call surface** (`frameId: ''`): a built-in is a coloured
  ring in the accent family, which is the language the VAD cue speaks. Ringing screens
  keep theirs. CI-guarded, `test/avatar_frame_surface_guard_test.dart`.
- **Playback** frame 0 in lists, animated while the enclosing ROW is hovered (`HoverScope`,
  published by `HollowPressable` and `MessageHoverWrapper`), fully animated where
  `animate: true`. `AvatarFrameCache` is what makes it affordable: a shared frame-0 image
  per ID (LRU 48) for lists, and the full refcounted frame list only while something plays
  it. Decoding every frame per widget instance would be hundreds of MB on a member panel.
