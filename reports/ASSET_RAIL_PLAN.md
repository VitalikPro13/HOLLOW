================================================================================
HOLLOW — ASSET RAIL / SERVER BANNERS / GIF PICKER / STICKERS
Implementation plan. Written 2026-07-28.
Covers GitHub issues #25 (server banners), #26 (GIF picker), #29 (stickers),
plus a retrofit of the existing FFZ + IGDB website endpoints.
================================================================================

STATUS (updated 2026-07-29, sixth session — PHASES 0-4 DONE, resume at PHASE 5)
--------------------------------------------------------------------------------
(This file was tmp2.txt in the repo root; moved here to be durable.)
* PHASE 0: DONE. Deployed to Hostinger, live-verified (cold FFZ search
  3-6s -> ~470ms; warm images ~36ms served by Apache). Commit b58ea7d.
  - ffz/ is now TRACKED IN THIS REPO (canonical); the copy in
    WholesomeStoryAday/!hollow-website/ffz is stale — Vitalik deletes it.
  - New read-through fetch.php in ffz/ AND igdb/ (validated against each
    endpoint's own SQLite db — never an open proxy; atomic tmp+rename;
    404 = Cache-Control max-age=120 negative cache). .htaccess `!-f`
    rewrite serves warm files with no PHP in the path.
  - igdb gained an `images` registry table (image_id, ext, IGDB size slug)
    — fetch.php reads the slug from it, never from the request.
  - SEARCH_VER: ffz 1->2, igdb 10->11; matching Rust consts synced
    (api/emotes.rs FFZ_SCHEMA_VER, api/showcase.rs ENDPOINT_SCHEMA_VER).
* PHASE 1: DONE (committed this session). Full map: wiki emotes.md
  > "Asset Rail"; epic memory project_asset_rail_epic. Deviations/extras
  vs the plan text below:
  - requested_emote_hashes -> requested_asset_kinds: HashMap<hash, AssetKind>
    exactly as planned (node/assets.rs, re-exported by emotes.rs).
  - HARDENING BEYOND PLAN: unsolicited EmoteAssets bundles are now DROPPED
    entirely (receiver only accepts hashes it requested); responder reply
    budget MAX_BUNDLE_REPLY_BYTES = 8 MB; a requested hash answered with
    invalid bytes frees its request slot (retry from another holder).
  - MAX_EMOTE_BYTES deleted — AssetKind::recv_cap is the single source.
  - FFI: new request_assets(hashes, kind, ...); request_emotes = emote
    shorthand. NodeCommand::RequestEmotes gained `kind`.
  - Render: ChatAssetImage in emote_image.dart; block assets follow the
    INTERFACE scale only (like attachments/avatars), inline assets ride the
    chat text scaler (like emotes). Block = alone on its own line.
  - Storage Manager: StorageBreakdown.asset_blob_bytes/count, "Emotes &
    GIFs" segment + clear_unreferenced_asset_blobs, asset_cache_cap_mb
    slider (default 512 MB, desktop + mobile), enforce_storage_caps gained
    asset_cap_mb and also runs on EmoteAssetsReceived.
  - referenced_asset_hashes() already keeps settings["server_banner"]
    hashes — Phase 2's eviction safety is pre-wired.
  - Tests: harness asset_cap_enforced_per_kind +
    asset_request_not_answered_for_unrequested_hash (new
    MockRelay::inject_direct hostile-frame helper); widget
    test/widget/asset_token_render_test.dart. Suite: 492 Rust / 152 Flutter
    green at session end.
* PHASE 2 (server banners, issue #25): DONE (this session). Full map: wiki
  emotes.md > "Server Banners". Deviations/extras vs the plan text below:
  - The FFI reader is get_server_banner -> Option<ServerBannerData{hash,
    animated, bytes: Option<Vec<u8>>}> (not bare bytes) so Dart knows the
    hash to pull + the hash keys header crossfades on re-upload.
  - set_server_banner writes server_banner_animated FIRST, then the hash
    (so the ServerUpdated that drives UI reloads lands complete).
  - AnimatedGifImage gained an `animate` flag (frame-0 pause) — the header
    gates it on windowFocusedProvider; reduce-motion stays internal.
  - Public-browse thumb rides PublicChannelListResponse as
    server_banner_thumb_b64 (400x133 still, receiver refuses >80 KB b64);
    rendered as a still 3:1 strip atop the EXPANDED guest section in
    guest_server_sidebar (browse_public_dialog has no card — it is a plain
    input dialog; the guest sidebar IS the browse surface).
  - 2.1's side fix shipped: process_avatar_image + profile
    process_banner_image now encode LOSSY Q80 (was lossless write_to →
    random cap failures on photos).
  - Animated picks (GIF + animated WebP) BYPASS the crop dialog in both
    authoring UIs (the cropper flattens to a still PNG); Rust center-crops
    3:1 per frame.
  - Tests: harness server_banner_hash_replicates_and_bytes_pull_on_demand
    (+ clear converges) + banner_write_rejected_without_manage_server
    (seed tags 85-88); widget test/widget/banner_header_test.dart.
* FOLLOW-UP: ANIMATED SERVER ICONS — DONE (2026-07-28, third session).
  The still b64 stays in settings["server_avatar"] (old clients + sync
  thumb unchanged); an animated pick ADDITIONALLY writes a
  settings["server_avatar_anim"] hash whose 128px animated WebP rides the
  asset rail at new AssetKind::Avatar (recv_cap 512 KB, 4 hashes/request,
  kind='avatar'). Rust: image_convert::process_server_avatar_anim (square
  per-frame crop, GIF branch + animated-WebP passthrough) +
  is_animated_image; set_server_avatar splits still/anim (anim hash
  written FIRST, still clears it); get_server_avatar_anim ->
  Option<ServerAvatarAnimData{hash, bytes}}; referenced_asset_hashes pins
  server_avatar_anim. Dart: server_avatar_anim_provider (banner-notifier
  clone, kind 'avatar'), shared ui/components/server_icon_image.dart
  ServerIconImage (anim > still > fallback; animate = (hover || selected)
  && windowFocused, reduce-motion internal to AnimatedGifImage) used by
  server_strip (44), bottom_bar dock (38), mobile chats row (44, expanded
  = watched), both authoring tiles (always-watched); folder cells + guest
  20px stay still. Authoring: animated picks bypass the crop dialog in
  overview_tab + mobile_server_settings_route (2 MB pre-check), both seed
  serverAvatarAnimProvider optimistically; clear wipes both. Tests:
  harness server_avatar_anim_hash_replicates_and_bytes_pull_on_demand
  (tags 89/95), widget test/widget/server_icon_anim_test.dart (6 cases).
* PHASE 3: DONE (2026-07-29, fourth session) — DEPLOYED + LIVE-VERIFIED
  against real Klipy same day: 405 on GET; trending/search return real
  items; cold still generated in ~200ms (real RIFF/WEBP); warm re-serve
  ~100ms immutable via Apache; sm/full stream (269 KB / 752 KB webp);
  unknown-id 404; config.php/gifs.db/sweep.php all 403. ONE live bug
  found+fixed: real categories shape is data:{locale, categories:
  [{category,query,preview_url}]} — BOTH Klipy demo apps model an
  outdated flat string list; parser fixed (names only — preview_url
  points at Klipy's CDN and never leaves the server), SEARCH_VER 1→2
  flushes the poisoned cached row; re-uploaded + live-verified (35 real
  category names). Sweep cron: Vitalik's hPanel attempt never registered
  (API list came back empty) — created via Hostinger API instead, uid
  zj14IQFyxk, "0 * * * *", path verified against the subdomain docroot
  (/home/u388188406/domains/anonlisten.com/public_html/hollow/gifs/).
  Deviations/extras vs the plan text below:
  - gifs/ lives in THIS repo (canonical, like ffz/ + igdb/ after Phase 0),
    not !hollow-website. Files: search.php, fetch.php, full.php, sweep.php,
    .htaccess, config.php.example. .gitignore covers config.php / gifs.db* /
    m/. The no-log claim is auditable in the public repo per the plan.
  - Klipy shapes confirmed from their PUBLISHED CLIENT MODELS (KLIPY-com
    demo-app DTOs), not a live key: response = {result, data:{data:[],
    current_page, per_page, has_next}}; item = {slug, title, blur_preview,
    type, file:{hd|md|sm|xs × gif|webp|mp4 → {url,w,h,size}}}; ads arrive
    as type:"ad" (stripped); categories = flat string list. Params: q,
    page, per_page (8..50), rating (g|pg|pg-13|r). One live smoke test
    after deploy is still wanted to confirm nothing drifted.
  - Media URLs are flat + extensioned (Apache needs real filenames for the
    warm path): /gifs/m/<id>.still.webp, /gifs/m/<id>.sm.<ext> (ext is
    per-item — some items lack a webp variant; recorded in the registry,
    requests for any other ext are 404), /gifs/f/<id> = full.php (send-time
    source, never on disk, 1h shared-cache header, hd→xs best-first,
    25 MB cap with walk-down on oversize).
  - Klipy has NO still format — stills are GENERATED server-side:
    first frame via GD from the GIF variant (Imagick fallback for
    webp-only items), scaled to ≤150px, WebP Q80; degraded fallback =
    animated sm webp verbatim (never a broken image).
  - items registry gained sm_ext; queries table carries has_next + ver
    (SEARCH_VER=1). qkey embeds rating+per_page+page. mp4-only (clip)
    items and malformed slugs dropped at ingest.
  - Abuse valve: 150 req / 5 min fixed window keyed by
    sha256(random-daily-salt | ip) prefix; salt regenerated + table wiped
    on day rotation; inline prune keeps the table minutes-deep.
  - customer_id = random UUID per upstream request (per plan); no ad-*
    params; upstream failure sets 60s backoff (429 honors Retry-After,
    5..3600s clamp); stale-beats-nothing serving during backoff.
  - GIFS_BASE_URL comes from config.php, never the Host header
    (self-hosters change one constant; Host is client-controlled).
  - Single-flight releases its lock BEFORE emitting — PHP finally does NOT
    run on exit(), the plan's naive shape would leak the lock 20s.
  - sweep.php: CLI-only (+ .htaccess denied), 4 GB cap, hysteresis to 90%,
    LRU by max(atime,mtime) (degrades to FIFO on noatime — eviction cost is
    one CDN re-fetch), prunes ratelimit/inflight/queries/items rows,
    WAL-checkpoints.
  - VERIFIED locally end-to-end (portable PHP 8.3 + mock Klipy upstream):
    405 on GET; exact normalized contract; ad/clip/bad-slug stripping;
    " CAT " → "cat" cache collapse (1 upstream hit); trending; categories;
    empty-result negative cache; sm passthrough byte-identical; still is a
    real generated RIFF/WEBP; warm disk re-serve; ext-mismatch + unknown-id
    404s; full prefers hd webp; valve trips at exactly 150 then 429s with
    zero upstream leakage; dead upstream → empty + backoff_until stamped,
    cached queries still serve; sweep runs clean.
  - 3.4 legal: privacy policy gained "Emote and GIF search (optional)" in
    BOTH copies (repo legal/ + website Svelte route) + the third-party
    enumeration line now names FrankerFaceZ/KLIPY; Last updated bumped to
    2026-07-29. NOTE: the FFZ proxy was never disclosed before — this
    closes that gap too. Terms untouched (no proxy references there).
    Website deploy is Vitalik's manual step, same batch as the endpoint.
  - 3.3 attribution ("Search KLIPY" placeholder + "Powered by KLIPY" mark)
    is picker UI — moved to Phase 4 where that UI exists.
* PHASE 4 (GIF picker, issue #26): DONE (2026-07-29, fifth session).
  Deviations/extras vs the plan text below:
  - api/gifs.rs: gif_search(q,page) / gif_trending(page) / gif_categories()
    / gif_fetch_and_store(id) -> StoredGif{hash,w,h,animated}. Proxy base is
    CONFIGURABLE via set_gif_proxy_url (https-only, trailing-slash
    normalized — the slash IS the prefix-guard boundary); item still/sm URLs
    are prefix-checked at parse (foreign rows dropped, mirrors FFZ);
    gif_fetch_and_store takes an ID (validated ^[A-Za-z0-9_-]{1,100}$) and
    builds {base}f/{id} itself — structurally incapable of generic fetching.
    Rating param NOT sent (server defaults pg); no client rating UI yet.
  - image_convert::process_gif_for_send: NO animated-WebP passthrough —
    full.php prefers hd-slot animated WebP (live check: 752 KB webp), which
    breaks both the ≤480px and ≤2MB bounds, and re-encode IS sanitization.
    First use of webp_animation::Decoder (was dep-only); GIF via GifDecoder;
    frames resized DURING decode (never all source-res frames in RAM,
    MAX_FRAMES 300); quality-then-dimension walk-down (480/Q80 → 480/Q65 →
    400/Q55 → 320/Q45) until ≤2MB (== AssetKind::Gif.recv_cap()).
  - Composer: EmoteComposerController gained a parallel ComposerAsset map —
    placeholderForAsset(), displayTextFor() now maps [a:...] tokens too,
    expandedText() emits them, buildTextSpan renders inline ChatAssetImage
    at 36px. The 1-PUA-char ↔ 1-WidgetSpan invariant holds for assets.
  - Picker (gif_picker.dart): overlay clone of the emoji shell (360x440) +
    reusable GifPickerBody. Trending prefetched at BOOT (hollow_shell, +5s
    idle) into a session GifCatalog (gif_provider.dart) with a sync peek()
    — a warm open renders with literally zero spinner frames. Debounce
    250ms re-checks the seq BEFORE issuing the request (a superseded query
    never reaches the proxy's rate valve — the widget test caught the naive
    version leaking). Manual 2-col masonry from item w/h (aspect clamped
    0.6..2.5, cover-cropped); animation = sm variant via AnimatedGifImage,
    desktop on HOVER, mobile while in viewport ±1 row (cell positions are
    known from our own masonry math; reduce-motion internal to the widget).
    Category chips (tap = search) on the trending view; pagination ≤5 pages
    (bounds the non-lazy masonry). Pick = in-cell spinner (picking guard) →
    gif_fetch_and_store → [a:g:hash:w:h] via the panes' _insertEmojiAtCursor.
  - Thumb disk cache: core/services/gif_thumb_cache.dart — app-cache-dir
    disk LRU (200 MB by mtime, 90% hysteresis, atomic tmp+rename) + small
    RAM tier + inflight dedup; only ever fed Rust-guarded URLs. Storage
    Manager gained a Dart-computed 5th segment "GIF search" +
    "Clear GIF search cache" cleanup item (gifThumbCacheSizeProvider).
  - Settings: gifProxyUrlProvider (SQLCipher-persisted, pushed at boot like
    the relay URL) + GifProxySettingsCard (network_section.dart, collapsed
    "Advanced (self-hosting)") shared by desktop Network settings AND
    mobile settings tab. 4.2's per-user direct Klipy key: DEFERRED, not
    dropped — a user asked for it, so it stays on the list. Do NOT sell it as
    a privacy win: with your own key Klipy sees YOUR IP and every search under
    one stable key (a profile); through the shared proxy they see one server
    IP, an unsegmented firehose, and a random per-request customer_id. It is
    "who would you rather be seen by", and the setting copy must say plainly
    that enabling it sends your IP to Klipy. The genuinely private escape
    hatch — set_gif_proxy_url + the Advanced (self-hosting) card — shipped.
  - Buttons: composerGifButton = a "GIF" text badge (neither icon set has a
    GIF glyph) left of the emoji button in both desktop panes; mobile = a
    GIF row in the [+] attach sheet → 55%-height bottom sheet.
  - 4.5: the ONE real gap found was emotePreviewSpans (in-app notification
    cards rendered asset tokens as raw wire text) — now merged-scan renders
    ChatAssetImage inline; out-of-range-dims tokens degrade to raw text.
    Plain-text surfaces (emoteTokensToShortcodes, Dart+Rust incl.
    push_enrich) were already asset-aware since Phase 1 — verified, no
    change needed.
  - Tests: 9 new Rust (parse/URL-guard/base-normalization in gifs.rs + 5
    process_gif_for_send incl. an in-memory animated-WebP decoder round
    trip), 3 composer asset tests, 3 picker widget tests (fake catalog via
    gifCatalogProvider override). Suites at session end: 504 Rust / 177
    Flutter green; flutter analyze zero new warnings. Live-verified against
    the deployed proxy same day: trending/categories contract exact,
    f/<id> = 752 KB image/webp RIFF.
  - PERF FIX round 1 (same day, after Vitalik's first run: "popular slow,
    search never finishes") — client-side download hygiene: GifThumbCache
    = ONE shared keep-alive HttpClient + 4-slot FIFO download semaphore
    (was: 30+ unbounded parallel downloads, fresh TLS each; also protects
    Hostinger's PHP workers; on download exception the client is recreated
    so wedged keep-alive sockets can't brick future downloads); stills
    load viewport-gated (±1 screen); pagination requires
    maxScrollExtent > 0 (`pixels > maxScrollExtent - 300` is true on
    EVERY tick when content fits the viewport → silently pulled 5 pages);
    scroll setState throttled to 40px; GifCatalog page/categories get a
    25s hard timeout (a lost future can never pin the spinner + the
    inflight-dedup key forever); error state gained a Retry button; boot
    prefetch also warms the first 10 trending stills. Correct fixes, but
    NOT the root cause —
  - PERF FIX round 2 = THE ROOT CAUSE (still broken after round 1):
    `gif_query` did `get_runtime().block_on(reqwest…)` — reqwest resolves
    DNS via spawn_blocking ON ITS RUNTIME, and the node runtime caps
    max_blocking_threads(8), which SQLCipher bursts saturate in the live
    app. The HTTP request then waited the full 20s timeout WITHOUT EVER
    BEING SENT. Every layer was fast in isolation (empty pool) — only the
    running app failed. Reproduced deterministically: 8 pool sleepers →
    trending = 20s stall + "error sending request". FIX: dedicated
    `get_http_runtime()` (api/network.rs — 1 worker, own blocking pool,
    5s reap) for ALL website-proxy HTTP: gifs.rs, emotes.rs (FFZ had the
    same LATENT bug — its tab is just used at quiet moments), showcase.rs.
    Verified: saturation test now 282ms (kept as
    gifs::tests::live_saturated_blocking_pool_smoke, #[ignore] live-net);
    REAL-APP verified via instrumented release (boot prefetch 195ms,
    picker open WARM/instant, live typed search answered by Rust in
    113ms). Diagnostics kept in release builds: [HOLLOW-GIF] (Rust),
    [HOLLOW-GIF-UI]/[HOLLOW-GIF-THUMB] (Dart via logFromDart);
    hollow_debug.log lives NEXT TO THE EXE. Rule memory:
    feedback_http_runtime_isolation. Necessary fix (deterministic repro),
    but STILL not sufficient —
  - PERF FIX round 3 = THE ACTUAL RENDER BUG, FIXED (2026-07-29, sixth
    session). It was never FRB: it was a self-referential `whenComplete`
    in OUR Dart, in two places.

        // GifCatalog.page() and GifThumbCache.load(), both:
        final future = <work>.then(...).whenComplete(() => _inflight.remove(key));
        _inflight[key] = future;   // <-- the map now holds `future` ITSELF

    `Map.remove` RETURNS the removed value, the arrow body returns it, and
    `Future.whenComplete` defers its own completion until an
    action-returned Future completes. The action returns the very future
    being completed, so it waits on itself: PERMANENT DEADLOCK. The inner
    `.then` still runs — which is why `_pages` warmed and a REOPENED
    picker painted instantly — while every caller's `.then` (the picker's
    `_runQuery`, the boot prefetch, `_GifCellState._loadStill`) never
    fired. `.timeout(25s)` sits UPSTREAM of the deadlock and so could
    never fire either. Exactly matches the 15:49 log: 4 searches answered
    by Rust, zero "[HOLLOW-GIF-UI] ... done/ERROR" lines, thumbs
    downloaded but cells blank on first open.
    FIX = block bodies (`whenComplete(() { map.remove(k); })`) at
    gif_provider.dart:page() and gif_thumb_cache.dart:load(). Note
    `categories()` was ALWAYS fine: `() => _categoriesInflight = null` is
    an assignment expression, which evaluates to null, not to a Future —
    that one-character-class difference is the whole bug.
    Also fixed alongside: `GifThumbCache._cacheDir()` memoized a FAILED
    lookup forever (one transient miss disabled the disk tier for the
    session) — it now clears `_dirFuture` before rethrowing.
    WHY THE SUITE WAS GREEN THROUGH IT: all 3 picker widget tests fake
    `page()` wholesale, so the chain that contained the bug never ran.
    GifCatalog gained a `@protected fetchPage`/`fetchCategories` raw-FFI
    seam; tests now fake THAT and exercise the real cache/in-flight/
    timeout wrapper. New regression cover (10 tests, each verified to
    FAIL against the arrow form): test/gif_catalog_test.dart (7),
    test/gif_thumb_cache_test.dart (2), plus "picker: renders results
    through the REAL catalog chain" in test/widget/gif_picker_test.dart.
    The unit files MUST stay plain `test()` — under `testWidgets`'
    FakeAsync a permanent hang is indistinguishable from waiting, which
    is why the earlier isolate2 hang got written off as a FakeAsync
    artifact. It was this bug.
    Suite at session end: 187 Flutter green, flutter analyze clean. Pure
    Dart — no Rust change, no FFI codegen, no relay/endpoint deploy.
    Rule memory: feedback_whencomplete_self_wait.
* PHASE 4 FOLLOW-UP (same day, after Vitalik's first working run): SIZING +
  LIBRARY. Two complaints, both fixed.
  - SIZING. Block assets rendered up to 480px wide with NO height cap, so a
    portrait GIF filled the viewport; the same GIF with text on its line
    dropped to ~2 line-heights. Both are gone: an asset token now ALWAYS
    renders as a block at `assetChatBox()` (emote_image.dart) — GIFs fit
    300x250, the exact box image attachments use, stickers 160x160, never
    upscaled past the source pixels. Text sharing the line is a CAPTION:
    `_matchAssetToken` records atLineStart/atLineEnd (horizontal whitespace
    does not count as sharing) and the span builder injects a synthetic
    newline on whichever side needs one, trimming the leading spaces of the
    caption that follows. `ChatAssetImage` lost `maxWidth`/AspectRatio for an
    explicit width+height pair (width null = inline mode, used by
    notification previews + the composer).
  - PICKER TABS. The prefilled category chips are gone (`gif_categories()`
    FFI + `GifCatalog.categories()` stay — the proxy endpoint is fine, the
    picker just no longer uses them). Browse is now Popular (default) /
    Favourites / Recent, shown only while the search field is empty; typing
    still overrides everything. `_networkView` = search non-empty OR Popular;
    `_runQuery()` bumps the seq unconditionally so a Popular reply in flight
    can never land on a library tab.
  - LIBRARY (`core/providers/gif_library_provider.dart`): SavedGif +
    GifCollection + GifLibrary, one JSON blob in the encrypted settings store
    (`gif_library`), loaded in hollow_shell's boot sequence right AFTER the
    proxy URL. Recents cap 60 (newest first, deduped, written on pick),
    favourites cap 500, lists cap 20 / 32-char names. CRITICAL: SavedGif
    stores media paths RELATIVE to the proxy base and rebuilds them against
    the live base on read — a stored absolute URL is a stored fetch target,
    and this keeps the Rust-side origin guarantee true across the local
    store; it also means a self-hoster who moves proxies keeps favourites.
    Decode is tolerant per row (garbage never takes the library with it).
  - STAR + MENUS. Every cell has a corner star (hover-revealed on desktop,
    always shown once favourited so the grid reads at a glance; always shown
    on mobile). Right-click / long-press opens `showGifMenu` — a TOPMOST
    OverlayEntry, because the picker is itself a raw OverlayEntry and a
    dialog route renders BEHIND it — carrying favourite toggle, per-list
    membership, and "remove from recent". Lists sort FAVOURITES only;
    unfavouriting evicts from every list. Creating/renaming a list uses an
    INLINE field in the panel for the same z-order reason. Star icons are
    Material's filled/outline pair (neither Lucide nor Atlas ships a plain
    filled star, and fill IS the signal) — same precedent as the composer's
    "GIF" text badge. Mobile sheet 0.55 -> 0.62 height to pay for the tab row.
  - Tests: test/gif_library_test.dart (11), 6 new picker widget tests
    (tabs replaced the chips, star -> Favourites, empty hints, recents order,
    late Popular reply cannot land on a library tab, lists), and
    asset_token_render_test rewritten around the box maths (8). Suite 209
    Flutter green, analyze clean. Pure Dart again — no Rust, no codegen.
* PHASE 5: not started.
================================================================================

DECISIONS ALREADY LOCKED (from the design discussion — do not re-litigate)
--------------------------------------------------------------------------------
* Banner bytes NEVER ride the CRDT. The CRDT carries a hash; bytes are pulled
  on demand over the existing emote replication rail.
* Banner placement = channel sidebar header (Discord-style), plus the
  authoring surface in server settings. Public-browse card second. Invite
  card and server-strip hover are explicitly out of scope.
* Animated banners ARE allowed, but only animate while you are actually
  looking at that server (selected + mounted + window focused + not
  reduce-motion). Same gate reduce-motion already uses.
* Banner write permission = MANAGE_SERVER, same as the server icon. No new
  permission bit.
* GIFs travel as E2EE bytes, never as URLs. Receivers of a message make ZERO
  HTTP requests, ever. This is the load-bearing privacy rule
  (see node/link_preview.rs header comment).
* GIFs are built on the generalized asset rail (Option 2), not as one-off file
  attachments, because #29 asks for stickers on the same stack.
* GIF search proxy is server-side only. The Klipy API key never ships in the
  client (it lives in the URL path — a bundled key gets extracted day one).
* Proxy logs nothing. No IP+query association is ever written.
* Custom key = PER-USER only, stored on the user's own identity. No
  server-owner keys (they would leak the owner's key to every member).
* Proxy returns a NORMALIZED response shape; provider specifics stay
  server-side so swapping providers is a PHP change, not an app release.

================================================================================
PHASE 0 — FFZ + IGDB ENDPOINT RETROFIT  (website only, NO app release)
================================================================================
Ship this first. It is independent of everything else, it fixes a live UX
complaint, and it requires zero client changes.

THE BUG
--------------------------------------------------------------------------------
In WholesomeStoryAday/!hollow-website/ffz/search.php:

  ingest_emote()  ->  cached_emote_image()   (line ~283)

cached_emote_image() does a BLOCKING, SEQUENTIAL cURL download of the image
file, inside the search request, for every result. Worse,
emote_row_to_json() (line ~341) returns null when the file is not on disk —
so a result physically cannot be returned until its bytes have landed.

Cold search for 30 emotes = 30 sequential CDN downloads before one byte of
JSON reaches the user. 3-6 seconds of dead air. CURATED_FILL_CAP = 30 exists
only to bound that pain; it is a bandage, not a fix.

Root cause in one line: METADATA AND MEDIA TRAVEL IN THE SAME REQUEST.

THE FIX
--------------------------------------------------------------------------------
1. cached_emote_image() stops downloading. It computes and returns the URL
   unconditionally (still records `ext` from the db row or a sane default).
2. emote_row_to_json() drops the is_file() null-check. Results are returned
   whether or not bytes are warm.
3. New ffz/fetch.php — read-through media cache:
     - Accepts ONLY a strictly-validated filename (^[0-9]+\.(png|gif|webp)$)
       AND the id must exist in ffz.db. Refuse everything else — this must not
       become an open proxy.
     - Fetches from the FFZ CDN, writes atomically (tmp file + rename), streams
       to the client, sets Cache-Control: public, max-age=31536000, immutable.
     - On upstream failure: 404 with a short negative-cache header.
4. .htaccess rewrite so warm files never touch PHP:
     RewriteCond %{REQUEST_FILENAME} !-f
     RewriteRule ^emotes/([0-9]+\.(png|gif|webp))$ fetch.php?f=$1 [L,QSA]
   Keep the existing immutable Cache-Control block and the ffz.db deny block.
5. Delete CURATED_FILL_CAP and its call sites — no longer meaningful.
6. Bump the `ver` param on deploy (Hostinger hCDN edge-caches search.php
   responses — this is the trap from feedback_igdb_deprecated_enums_and_cdn_cache).

WHY NO APP CHANGE IS NEEDED
--------------------------------------------------------------------------------
lib/src/ui/chat/emoji_picker.dart:647 already renders FFZ results with
Image.network(). A read-through URL is transparent to it. The first viewer of
a cold emote waits ~150ms on that ONE image while 30 others load in parallel;
everyone after gets it from Apache with no PHP in the path.

SAME RETROFIT FOR IGDB
--------------------------------------------------------------------------------
igdb/search.php caches covers/artwork the same blocking way. Identical change:
return URLs immediately, add a read-through fetch endpoint + rewrite. The
showcase editor gets the same instant-search behaviour for free.

EXPECTED RESULT
--------------------------------------------------------------------------------
Cold FFZ search: ~3-6s  ->  ~250ms to grid layout, images streaming in.
Warm: unchanged (already fast).

================================================================================
PHASE 1 — GENERALIZED ASSET RAIL  (Rust)
================================================================================
Turn the shipped emote byte-replication system into a general content-addressed
asset store. Everything downstream (banners, GIFs, stickers) rides it.

WHY THIS IS CHEAP
--------------------------------------------------------------------------------
The token lives INSIDE existing message text (like `[e:name:hash]` does today).
So there is NO new message-row path: signing, order_us, lp_digest, sync items,
backfill, and every write gate stay untouched. That is the entire reason
Option 2 is affordable.

1.1  STORAGE  (rust/hollow_core/src/storage/messages.rs)
--------------------------------------------------------------------------------
Keep the `emote_blobs` table (it is already content-addressed and shared across
servers/DMs). Additive migration only:

    ALTER TABLE emote_blobs ADD COLUMN kind TEXT NOT NULL DEFAULT 'emote'

Kinds: 'emote' | 'banner' | 'sticker' | 'gif'.
CRUD: extend save_emote_blob() with a kind arg; add
load_asset_blobs_by_kind() and an LRU-eviction helper (delete by added_at,
skipping hashes still referenced by personal sets / CRDT state).

1.2  PER-KIND CAPS  (new rust/hollow_core/src/node/assets.rs, re-exported by emotes.rs)
--------------------------------------------------------------------------------
    emote    256 KB   (existing MAX_EMOTE_BYTES, unchanged)
    banner   256 KB still / 1 MB animated
    sticker  512 KB
    gif      2 MB

Also per-kind MAX_REQUEST_HASHES so one bundle stays bounded:
    emote 20 | sticker 8 | gif 4 | banner 2

1.3  WIRE  (no new HavenMessage variants)
--------------------------------------------------------------------------------
Reuse HavenMessage::EmoteRequest / EmoteAssets — they are already a generic
hash -> bytes pair with the showcase bundle codec (api/showcase.rs
encode/decode_asset_bundle) and receiver-side SHA-256 verification.

CRITICAL: the size cap applied on receipt must come from the kind WE ASKED
FOR, never from anything the sender supplies. Today swarm.rs keeps a
per-connection `requested_emote_hashes` set (cleared on WsEvent::Disconnected).
Replace it with `requested_asset_kinds: HashMap<String, AssetKind>` — same
lifecycle, same Disconnected clear. handle_emote_assets() then validates
bytes.len() against the cap for the recorded kind. Without this, raising the
cap to 2 MB globally lets anyone push 2 MB blobs claiming to be emotes.

1.4  TOKEN GRAMMAR  (dual-defined, keep in sync — this is a CLAUDE.md rule)
--------------------------------------------------------------------------------
Keep `[e:name:hash]` exactly as-is for compatibility.
Add ONE new generic token rather than two:

    [a:kind:hash:w:h]      kind = 's' (sticker) | 'g' (gif)

  Rust: node/emotes.rs parse_asset_token() beside parse_emote_token()
  Dart: lib/src/ui/chat/emote_image.dart assetTokenRegex / parseAssetToken()

Old clients render the raw token as text. Same graceful degradation emotes
shipped with. Acceptable and already precedented.

1.5  RENDER  (Dart)
--------------------------------------------------------------------------------
message_text_parser.dart: new _TokenKind.asset.
  - Token alone on its own line  -> block render, max 480px wide (GIF) /
    160px (sticker), aspect from w/h in the token so there is no reflow.
  - Token inline with other text -> capped to ~2 line-heights.
  - Missing blob -> sized placeholder + requestAssetOnce(), flips in when the
    pull lands (mirror EmoteImage's behaviour exactly).
  - Honour ChatTextScale + UiScale. WidgetSpan sizes scale by hand.

1.6  STORAGE MANAGER
--------------------------------------------------------------------------------
Add an "Assets (emotes, stickers, GIFs)" row to storage_section.dart /
storage_provider.dart / api/storage.rs, with a user-settable cap enforced by
enforce_storage_caps(). LRU-evict by added_at, never evicting hashes still
referenced by a personal set or a server CRDT.

1.7  SECURITY
--------------------------------------------------------------------------------
Update the emotes row in tools/hollow-memory/wiki/security_write_gates.md to
cover all asset kinds. The gate is unchanged in shape: only accept blobs we
requested, verify SHA-256 == hash, verify WebP container magic, enforce the
per-kind cap.

================================================================================
PHASE 2 — SERVER BANNERS  (issue #25)
================================================================================

2.1  IMAGE PROCESSING  (node/image_convert.rs)
--------------------------------------------------------------------------------
New process_server_banner_image(data) -> (webp_bytes, animated):
  - 3:1 centre crop -> 960x320
  - LOSSY WebP Q80 via the existing encode_lossy_webp_via_animation() helper
  - still cap 150 KB, animated cap 1 MB
  - GIF / animated WebP input -> frame-resized animated WebP (reuse the
    process_emote_image animation path)

WHILE IN THERE — FIX AN EXISTING BUG:
process_avatar_image() and process_banner_image() (profile banner) both encode
with write_to(ImageFormat::WebP), which in the `image` crate is LOSSLESS, then
reject the result over 100 KB / 200 KB. That is why photographic profile
banners sometimes just fail to upload. Switch both to the lossy encoder at
Q80. Sizes drop ~5x and the failure mode disappears.

2.2  CRDT  (no new op type, no new permission entry)
--------------------------------------------------------------------------------
Reuse ServerSettingChanged, which is already gated on MANAGE_SERVER at ingest
(crdt/server_state.rs:1069):

    settings["server_banner"]          = <64-hex sha256>  ("" = cleared)
    settings["server_banner_animated"] = "1" | ""

Bytes go to the asset store with kind='banner' and replicate via the Phase 1
rail. peer_hint for the pull = any online member of that server room.

2.3  FFI  (api/crdt.rs, beside set_server_avatar)
--------------------------------------------------------------------------------
    set_server_banner(server_id, raw_bytes)   -> process, store blob, set setting
    clear_server_banner(server_id)
    get_server_banner(server_id) -> Option<Vec<u8>>   (reads blob by hash)
Regenerate FFI bindings after (flutter_rust_bridge_codegen, from project root).

2.4  DART PROVIDER
--------------------------------------------------------------------------------
lib/src/core/providers/server_banner_provider.dart — a near-copy of
ServerAvatarNotifier, INCLUDING the applyLocalWrite() optimistic-seed +
_writeGen/_writePending bookkeeping. That pattern exists because a CRDT
read-back immediately after a write returns the PREVIOUS value (set_* only
queues). Do not skip it; it is the "second upload applies the first icon" bug.

Invalidate on ServerUpdated in event_provider.dart _refreshServerState
(alongside the existing loadAvatar calls at :568 and :638).

2.5  UI — CHANNEL SIDEBAR HEADER  (the main surface)
--------------------------------------------------------------------------------
lib/src/ui/shell/channel_sidebar.dart, _buildHeader():
  - No banner: unchanged 48px header.
  - Banner: header grows to ~120px. Banner as background (BoxFit.cover),
    bottom-up gradient scrim, server name + the three action icons
    (invite / storage / settings) overlaid on top.
  - MUST ride the same ValueKey('server-$serverId') the AnimatedSwitcher
    already uses, or the banner crossfades out of sync with the name.
  - Home / DM mode collapses back to 48px.
  - TypewriterText reveal interval stays as-is.
  - Animation gate: selected server AND mounted AND window focused AND
    !reduceMotion. Otherwise show frame 0. AnimatedGifImage already drives
    from a Ticker, so this is one condition, not new machinery.

2.6  UI — AUTHORING
--------------------------------------------------------------------------------
  - Desktop: lib/src/ui/settings/overview_tab.dart, directly under the
    existing "Server Icon" block (~line 489). Reuse
    lib/src/ui/dialogs/image_crop_dialog.dart with a 3:1 aspect
    ("Crop Server Banner").
  - Mobile: lib/src/ui/mobile/mobile_server_settings_route.dart, mirroring
    the icon block at ~:332 / :366 / :541.
  - Upload / Remove buttons gated on MANAGE_SERVER, same as the icon.
  - Busy state + toast on failure (mutating wrappers rethrow — call sites
    await and toast; bare calls become zone crashes).

2.7  UI — PUBLIC BROWSE  (second surface)
--------------------------------------------------------------------------------
node/types.rs PublicChannelListReceived already carries
`server_avatar: Option<Vec<u8>>`. Add:

    #[serde(default)]
    server_banner_thumb: Option<Vec<u8>>     // 400x133, <=40 KB

A THUMBNAIL, not the full banner — this is a pre-join wire path to strangers.
Same approach as the existing 64x64 avatar thumbnails in public sync.
Render in lib/src/ui/dialogs/browse_public_dialog.dart as the card header.

2.8  GUEST PARITY
--------------------------------------------------------------------------------
lib/src/ui/guest/guest_server_sidebar.dart:338 already watches
serverAvatarProvider — add the banner the same way.

================================================================================
PHASE 3 — GIF PROXY ENDPOINT  (website, new)
================================================================================
Deploy path: /public_html/hollow/gifs/  — repo path: !hollow-website/gifs/
PUBLISH THIS SOURCE IN THE PUBLIC REPO so the no-log claim is auditable.

3.1  search.php  (POST-only)
--------------------------------------------------------------------------------
Modes: q=<query> | trending=1 | categories=1
Params: page, per_page (cap 50), rating, ver

Normalized response — provider-agnostic, this is the contract the app codes to:

    { "result": true,
      "items": [ { "id":"...", "w":480, "h":270, "title":"...",
                   "still":"https://.../gifs/m/<id>/still",
                   "sm":   "https://.../gifs/m/<id>/sm",
                   "full": "https://.../gifs/m/<id>/full" } ],
      "page": 1, "has_next": true, "meta": { "backoff_until": 0 } }

Upstream: https://api.klipy.com/api/v1/{API_KEY}/gifs/search
(exact response field names to be confirmed against a live key at
implementation time — that is why we normalize.)

CACHING (SQLite gifs.db, write-through, .htaccess denies the db files):
    queries(qkey PK, ids TEXT, fetched_at)     TTL: search 24h, trending 1h,
                                                    categories 7d
    items(id PK, w, h, title, provider, src_json, fetched_at)
    inflight(qkey PK, started_at)              single-flight lock

  - Query normalization into qkey: lowercase, trim, collapse whitespace, strip
    trailing punctuation. "Cat " and "cat" must be one entry.
  - Negative caching: cache the empty result (1h) or every typo re-hits upstream.
  - Single-flight: 50 users hitting the same cold term in one second produce
    ONE upstream call; the rest wait on it or serve stale.
  - Serve-stale-on-error with meta.backoff_until (copy the FFZ backoff logic).

PRIVACY / ABUSE:
  - customer_id = random UUID generated per request, never stored, never
    derived from anything about the user.
  - No ad-* params sent. Strip any ad-flagged item from the response.
  - rating defaults to g/pg SERVER-SIDE. The client can raise it; NSFW-off
    servers force it back down.
  - Access logging OFF for this path. No IP+query pair is ever written.
  - Abuse valve: token bucket keyed by hash(ip + rotating daily salt) in a
    short-lived table, entries expire in minutes. No raw IPs, ever.

3.2  MEDIA — read-through, three variants
--------------------------------------------------------------------------------
    /gifs/m/<id>/still   first-frame WebP, ~150px wide   -> cached on disk
    /gifs/m/<id>/sm      animated WebP, ~150px wide      -> cached on disk
    /gifs/m/<id>/full    send-time source                -> NOT cached (or 1h)

Same Apache rewrite trick as Phase 0: warm files served directly by Apache,
cold ones fall through to PHP which fetches, writes atomically, and streams.
Cache-Control: public, max-age=31536000, immutable.

DISK BUDGET — this is the one place GIFs differ from FFZ. FFZ is ~110 curated
emotes at ~50 KB. GIF long-tail is unbounded at 50-300 KB each. A cron LRU
sweeper keeping the media dir under a hard cap (3-5 GB, delete by atime) is
MANDATORY, not optional.

BANDWIDTH: the "still" variant is the single biggest lever — grid shows stills,
animates only what is on screen / hovered. Cuts grid bytes 5-10x and removes
the cost of decoding 24 animated WebPs at once.

3.3  ATTRIBUTION
--------------------------------------------------------------------------------
Klipy asks for "Search KLIPY" as the search-field placeholder plus a
"Powered by KLIPY" mark. Honour both — we are proxying and caching, which is
outside their intended shape, so staying in good standing is cheap insurance.

3.4  LEGAL DOCS
--------------------------------------------------------------------------------
Add the GIF proxy to BOTH copies of the privacy policy (HOLLOW/legal/ and the
website Svelte route), alongside the existing FFZ / IGDB / Steam entries.
State the no-log commitment explicitly.

================================================================================
PHASE 4 — GIF PICKER  (app)
================================================================================

4.1  RUST FFI  (new rust/hollow_core/src/api/gifs.rs)
--------------------------------------------------------------------------------
    gif_trending(page)            -> Vec<GifItem>
    gif_search(q, page)           -> Vec<GifItem>
    gif_categories()              -> Vec<GifCategory>
    gif_fetch_and_store(id)       -> StoredAsset { hash, w, h, animated }
        downloads `full` through the proxy, transcodes to <=480px animated
        WebP <=2 MB, hashes, saves with kind='gif'. Re-encoding at authoring
        IS the sanitization step (same argument as emotes).

URL GUARD: generalize the ffz_import_emote() check. Today it hardcodes a
refusal for any URL not on https://hollow.anonlisten.com/ffz/emotes/ .
The asset fetchers must validate against the CONFIGURED proxy origin, or
self-hosting breaks on day one.

4.2  SETTINGS
--------------------------------------------------------------------------------
  - gifProxyUrl — defaults to the Hollow website, overridable for
    self-hosters (mirrors the relayDomainProvider pattern).
  - Per-user Klipy API key, stored on the user's own identity. When set, the
    client talks to api.klipy.com directly and skips our proxy entirely.
    Copy for the setting should be honest about the trade: with your own key
    Klipy sees your IP and can profile your searches over time; through the
    shared proxy they see an unsegmented firehose. It is "who would you rather
    be seen by", not "more private".

4.3  PICKER UI
--------------------------------------------------------------------------------
lib/src/ui/chat/gif_picker.dart, sharing chrome with emoji_picker.dart.
  - Default view = Trending, PREFETCHED at picker-open (and ideally at app
    idle). Opening the picker must never show a spinner.
  - Search debounced 250ms with an in-flight seq guard — the _ffzQuerySeq
    pattern in emoji_picker.dart is exactly right, copy it.
  - Staggered grid, aspect ratio from item w/h so nothing reflows.
  - Grid shows STILLS; animate only the visible viewport (+1 row) or on hover.
    Reduce-motion = stills only, animate on explicit tap/focus.
  - Client caches: results in RAM keyed by (query,page) + thumbnails to the app
    cache dir (~200 MB LRU) so a restart is still instant. Surfaces in the
    Storage Manager.
  - Placeholder text "Search KLIPY" (attribution).
  - Mobile: bottom-sheet variant. Search autofocus stays DESKTOP-ONLY —
    on mobile it summons the keyboard over the sheet.

4.4  SEND PATH
--------------------------------------------------------------------------------
pick -> gif_fetch_and_store() -> insert [a:g:hash:w:h] through
EmoteComposerController (1 PUA char <-> 1 WidgetSpan, the length match is
load-bearing) -> normal send.

EVERY send site must read expandedText(), never .text:
chat_pane _handleSend / _sendStagedFile, channel_chat_pane ditto,
mobile_chat_route _handleSend.

4.5  NOTIFICATION PREVIEWS
--------------------------------------------------------------------------------
A raw token in a toast reads as garbage. Extend the two existing helpers:
  - In-app (renders images): emotePreviewSpans() -> also handle asset tokens.
  - Plain text (OS toast / push): emoteTokensToShortcodes() -> "[GIF]" /
    "[Sticker]". Choke points: DesktopNotificationService.showDm/showChannel,
    mobile _showNotification/_showChannelNotification, and the Rust side
    node/emotes.rs::emote_tokens_to_shortcodes used by push_enrich.rs for the
    iOS killed-state NSE body.

================================================================================
PHASE 5 — STICKERS  (issue #29)  — later, mostly UI on the finished rail
================================================================================
Ask: 512x512 personal AND server sticker packs, Telegram-style. The requester
notes drag-and-drop posting already works, so the value is the vault + picker.

  - Processing: 512x512 max, lossy Q80, <=512 KB, animated allowed.
  - Personal: new `personal_stickers` table (name/pack/hash/added_at),
    mirroring personal_emotes. Local-only first, sibling sync later.
  - Server: ServerState.stickers HashMap<String, StickerInfo> with
    #[serde(default)], cap ~50, new CrdtPayload::StickerAdded/StickerRemoved.
    Reuse Permission::MANAGE_EMOTES rather than adding a bit.
      -> New CrdtPayload variants MUST emit ServerUpdated in BOTH match blocks
         (handle_envelope_crdt_op AND handle_incoming_request) and must never
         fall into the `_ =>` arm.
      -> CRDT sync batches must keep using parse_ops_tolerant so an older
         client does not wedge on the new variant.
  - Picker: third tab in the same chrome. Authoring reuses pickAndNameEmote().
  - Pack import/export is out of scope for v1.

================================================================================
CROSS-CUTTING RULES CHECKLIST  (project rules that WILL bite here)
================================================================================
[ ] #[serde(default)] on EVERY new field of a persisted struct or old data
    silently vanishes.
[ ] New CrdtPayload variants: ServerUpdated in BOTH match blocks, never `_ =>`.
[ ] parse_ops_tolerant for sync batches — never from_str::<Vec<CrdtOp>>.
[ ] Received CRDT ops persisted via insert_crdt_op at EVERY apply site.
[ ] Permission checks validate op.author, never the transport sender.
[ ] Optimistic UI update BEFORE the fire-and-forget FFI; never read back
    immediately after a CRDT write.
[ ] Fire-and-forget FFI needs .catchError((_) {}) — a sync try/catch around an
    un-awaited Future catches nothing.
[ ] Mutating provider wrappers rethrow; call sites await + toast.
[ ] Multi-device: sends target DEVICES (devices_for(master)), never a bare
    master. Per-person UI collapses device -> master via resolver::resolve.
[ ] Asset pulls target ONE online holder, never a broadcast.
[ ] requested_asset_kinds cleared on WsEvent::Disconnected, like the emote set.
[ ] Never animate a colour from Colors.transparent; pass backgroundColor: null.
[ ] Token grammar is dual-defined (Rust + Dart) — keep both in sync.
[ ] Regenerate FFI bindings from the PROJECT ROOT after Rust API changes.
[ ] Mobile parity in the same pass, not later.
[ ] Accessibility: purpose labels on icon-only controls, HollowFocusRing,
    reduce-motion via ReduceMotionController.
[ ] Bump ?ver= on every website endpoint deploy (hCDN edge cache).

================================================================================
TESTING
================================================================================
Harness (rust/hollow_core/src/node/test_harness.rs) — model on the existing
server_emote_replicates_and_bytes_pull_on_demand:
  [ ] server_banner_hash_replicates_and_bytes_pull_on_demand
  [ ] banner_write_rejected_without_manage_server
  [ ] asset_cap_enforced_per_kind (a 2 MB blob offered as an 'emote' is refused)
  [ ] asset_request_not_answered_for_unrequested_hash
  [ ] sticker_set_replicates_and_converges_on_removal   (Phase 5)

Widget tests (test/, ~1s, no device):
  [ ] gif picker: debounce + seq-guard cancels a stale search
  [ ] gif picker: teardown while a search is in flight does not crash
  [ ] banner header collapses to 48px in home mode, 120px with a banner
  [ ] asset token renders a placeholder then the image when bytes land

Rust: cargo check + cargo clippy + cargo test --lib.
Endpoints: curl cold and warm, confirm the cold search returns JSON in
<400ms with no media fetched inline.

================================================================================
SUGGESTED ORDER
================================================================================
1. Phase 0   — website only, no release, immediate visible win.
2. Phase 1   — asset rail (invisible, unblocks everything).
3. Phase 2   — server banners (#25). First user-visible feature.
4. Phase 3   — GIF endpoint (can be built in parallel with Phase 2).
5. Phase 4   — GIF picker (#26).
6. Phase 5   — stickers (#29).

================================================================================
OPEN QUESTIONS FOR IMPLEMENTATION TIME
================================================================================
- Exact Klipy response field names / variant keys — needs a live API key.
  The normalized shape insulates the app either way.
- Whether to put Cloudflare in front of the media path. It would absorb most
  egress for free, but adds an observer. Note hCDN is already in the path, so
  this is not a new category of exposure — still, it is your call.
- Sticker permission: reuse MANAGE_EMOTES (recommended) or add MANAGE_STICKERS.
- Whether animated server banners should be capped tighter than 1 MB after
  seeing real ones.
================================================================================
