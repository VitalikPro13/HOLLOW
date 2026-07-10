# Profile Showcase Board

## Concept and Privacy Model

Self-curated blocks flanking the profile card (Steam-showcase model, NOT
Discord's auto-tracked activity feed). Everything on a board was PUT there
by the user — no process detection, ever. Display is pure P2P off replicated
profile data: viewers never contact IGDB, the website, or any third party.
RELATIONAL BLOCKS ARE VETOED (mutual servers/friends = Discovery-species
privacy leak — memory `feedback_no_relational_profile_blocks`). Design
report: `reports/PROFILE_SHOWCASE_BOARD.md`.

## Data Model (lib/src/core/models/showcase_board.dart)

`ShowcaseBoard { left, right }` serializes to one JSON string in the
profile's `showcase_board` field. Block types (stable wire ids): `text`
(title?, body), `now_playing` (name, cover?, year?, details?),
`favorite_game` (+blurb?), `game_shelf` (label?, games[{name, cover?,
year?}], max 8), `artwork` (image, caption?). UNKNOWN types round-trip
untouched so an old client editing its board can't destroy newer blocks.
Caps: 4 blocks/side, encoded ≤14KB (`maxEncodedLength` — kept under Rust's
16KB `sanitize_incoming_showcase` absent-threshold so a valid board is never
dropped in transit), text body ≤1000. `referencedAssetHashes()` drives
save-time asset pruning. `cover`/`image` values are asset HASHES.

**Game details (baked, zero-fetch at display) — BUNDLE-REF since v7.**
`data['details']` is a STRING = content-addressed asset hash; the details
JSON (UTF-8) lives in the asset bundle. Rationale: the board text rides
every profile announce, so it must stay tiny — the ~2-4KB per-game details
ride full profile pulls only, and game-SHELF entries can carry full metadata
too ({name, cover?, year?, details?} per shelf game). Legacy inline-Map
details (v3-v6) still parse — `GameDetails.resolve(field, assets)` handles
both. `GameDetails`: description, req_min/req_rec, release_date, copyright
(`legal`), metacritic, achievements, platforms[], stores{} (steam/
playstation/xbox/nintendo/gog/epicgames/itch → https URL, clickable chips),
companies[] (`GameCompany` — DEDUPED server-side, role dev|pub|devpub, logo
asset-hash, links). Company-logo hashes live INSIDE details assets, so the
editor expands pruning one level via `GameDetails.logoHashesFromBytes`.
Game blocks AND shelf entries carry `art` (key-art asset hash) — a shelf
tap opens the exact same card, hero included; the save-time 1.4MB bundle
check is the budget backstop for art-heavy shelves. Everything baked at
authoring; viewers fetch NOTHING.

## Replication (Rust)

Two profile fields, both LWW under `updated_at` via `save_profile`:
- `showcase_board` TEXT: wire `Option<String>` + `#[serde(default)]` on BOTH
  ProfileUpdate enums — absent (old client) PRESERVES the stored board
  (COALESCE); `Some("")` clears. Oversized (>16KB) incoming treated as
  absent (`sanitize_incoming_showcase`), never truncated.
- `showcase_assets` BLOB: the asset bundle, full avatar/banner playbook —
  wire b64 ""/"CLEAR"/data, hash on LIGHT announces, bytes ride only full
  sends; staleness pull via `maybe_request_full_profile` (compares
  avatar+banner+assets hashes). 2MB wire cap, 1.5MB authoring cap.

Bundle = JSON map hash→base64 (`api/showcase.rs` encode/decode);
`decode_asset_bundle` verifies content-addressing — entries whose bytes
don't hash to their key are DROPPED. Harness test:
`showcase_board_replicates_preserves_and_clears`.

## FFI (api/showcase.rs)

`showcase_game_search(query)` → FAST basics only: `GameSearchResult {id,
name, year, game_type, cover_url}`. `showcase_game_details(game_id)` →
`GameCardDetails {details_json, logo_urls, artwork_url}` — called ONCE on
pick (id= mode), never per search result. Both are **POST with form-body
params** (2026-07-10 hardening: search text never appears in the URL, so it
never lands in Hostinger access logs; POST also bypasses the hCDN edge cache
so the stale-URL trap can't bite). `v=ENDPOINT_SCHEMA_VER` still rides the
body (keep in sync with SEARCH_VER).
`showcase_fetch_cover(url)` (≤400px) / `showcase_fetch_key_art(url)`
(≤800px, hero) REFUSE any URL not under
`https://hollow.anonlisten.com/igdb/covers/` (never a generic fetcher);
both **LOSSY** WebP Q75 (alpha survives — logos stay transparent).
CRITICAL: never the `image` crate's lossless WebP for photos — lossless
size is content-dependent, so noisy covers randomly busted the 150KB cap
and failed SILENTLY at authoring ("some games have covers, some don't").
See `feedback_lossless_webp_content_dependent_size`. `process_showcase_artwork(bytes)` — GIF → animated WebP (≤600KB) /
stills ≤800px WebP (≤400KB). `get_showcase_assets(peer_id)` decodes the stored
bundle. `update_profile` has `showcase_board: Option<String>` +
`showcase_assets: Option<Vec<ShowcaseAsset>>` (None unchanged / empty clear).

## Website Endpoint (igdb/ in repo root; deployed to /public_html/hollow/igdb/)

`search.php`: Twitch client_credentials token (token.json cache) → IGDB
search → SQLite `games.db` metadata cache (games keyed by IGDB id; searches
keyed by normalized query with `ver` stamp + 30-day TTL) → covers cached to
`covers/{image_id}.jpg`, key art (`artworks.image_id`, first artwork) at
`t_720p` jpg, company logos at `t_logo_med` **as .png** — IGDB flattens
transparency onto white when serving JPG, so logos MUST be PNG (`cached_image`
has an $ext param). Repeat searches = zero IGDB traffic.
**IGDB DEPRECATION TRAP (hit three times):** deprecated enum fields silently
return NOTHING — `game.category` → `game_type.type`, `external_games.category`
→ `external_game_source` (Steam = id 1; broke ALL Steam enrichment),
`company_website.category` → `websites.type` (Website Type ref; broke all
credit links). Resolution helpers `is_steam_external()` / `website_kind()`
match the new expanded refs ({id, name/type}) with legacy-category fallback.
Bump `SEARCH_VER` when the response schema grows (currently 9). Historical
note: the app used to send `v` as a GET query param because **Hostinger's
hCDN edge-cached old responses (`x-hcdn-cache-status: HIT`, forced
max-age=31536000)**; since 2026-07-10 the endpoint is **POST-ONLY** (GET →
405) — POST is never edge-cached, and body params keep search text out of
access logs. Also hardened: `display_errors` off, nosniff/no-referrer/
noindex headers. `config.php` (real credentials) is gitignored; `.htaccess`
denies config/token/db and hard-caches covers (.jpg AND .png). Manual upload
only (Hostinger file manager, no shell). The canonical source lives at
`HOLLOW/igdb/`; the `!hollow-website/igdb/` copy is a synced mirror — sync
it after edits.

**TWO MODES (SEARCH_VER 9).** `q=` = FAST search: ONE IGDB query returning
EXACTLY what the picker renders — {id, name, year, type, cover} and nothing
else (genres/rating/summary stripped in v8; v6 enriched all 12 results
inline = 12 sequential Steam calls ≈ 10-20s per fresh search — never
again). Live-measured 0.4-1.1s. `id=` = card details for ONE game
(~1-2s), fetched when the user PICKS it: one IGDB query
(external_games + involved_companies + websites + artworks expanded) + one
Steam appdetails (no API key; ~200 req/5min per IP → hence the cache) →
description / req_min+req_rec / metacritic / release_date / achievements /
`legal` (©-line via `clean_legal`) / platforms / companies
(`extract_companies` — DEDUPED by name, dev+pub merges to role `devpub`;
logos PNG; links deduped by URL) / key art / stores. **Stores matched by
SOURCE NAME** (`store_slug` — steam/playstation/xbox|microsoft/
nintendo|eshop/gog/epic/itch substrings; numeric ids only as fallback): the
new external_game_sources ids are NOT guaranteed to mirror the legacy enum
and the legacy enum never had Nintendo at all. TRAP: check 'twitch' BEFORE
'itch' — "Twitch" contains "itch" and shipped Twitch directory links as
store URLs (live-data bug, v8). Steam URL composed from the appid when IGDB
lacks one; console chips (ps/xbox/nintendo) get the store's SEARCH page as
fallback when IGDB has no direct entry (`store_search_fallbacks` — IGDB's
eShop coverage is spotty; Zelda TOTK has NO eShop external). https only.
Cached in `game_details` (WAL,
write-through, `ver` column gates schema refresh) → repeat picks = ZERO
upstream traffic. Steam failure non-fatal. Tested locally via portable PHP
(scratchpad php.exe + cacert.pem): 33 checks incl. LIVE Steam fetches +
seeded ?id= dispatch + injection-shaped params.

## Dart UI

- Renderers: `ui/components/showcase_blocks.dart` — `ShowcaseBoardColumn
  (peerId, blocks)` watches `showcaseAssetsProvider(peerId)` (family
  FutureProvider hash→bytes, invalidated on ProfileUpdated in
  event_provider). Text renders via chat's `buildMessageText` (links open
  only on tap; no fetches). Covers/artwork via Image.memory /
  AnimatedGifImage; gamepad/image placeholders while assets replicate.
- Composer: `ui/dialogs/showcase_editor.dart` — per-side block list with
  drag reorder (`onReorderItem` pattern), block picker, game search dialog
  (450ms debounce, type tag chip + year, "Game data from IGDB" attribution),
  shelf editor (prefillable), artwork via FilePicker → Rust processing.
  **Game picks are NON-BLOCKING**: the picker pops instantly with basics
  (`PickedGame{id,name,year,coverUrl}`); `bakeGame()` fetches cover/key
  art/details/logos in the BACKGROUND (starts before the blurb prompt, so
  it downloads while the user types) and `_trackBake` patches the placed
  block IN PLACE by instance identity (reorder-safe; deleted block → patch
  dropped, assets pruned at save). BOTH saves (board + shelf) await
  `_pendingBakes` first so nothing ships half-baked. bakeGame never throws.
  EVERY block type edits in place (artwork edit = caption only). On game pick,
  `_bakeDetails` parses `details_json`, fetches each company logo via
  `showcase_fetch_cover`, and REWRITES `companies[].logo` URL→asset-hash (bytes
  stashed in the bundle) so the stored block references replicated assets. Save
  prunes the asset bundle to board-referenced hashes (incl. logo hashes) and
  ships board + assets via `profileProvider.updateShowcaseBoard` (optimistic
  cache patch).
- Game card dialog: `ui/dialogs/game_card_dialog.dart` — tap ANY game
  surface (now_playing / favorite_game via `_tappableGame`, game-shelf tiles
  directly) → `showGameCardDialog`, the SAME dialog everywhere (v7 final —
  the v6 minimal card was reverted once the data problems were fixed).
  Center+right panel ensemble (profile surface recipe, 0.62×
  scale-then-stack): center = key-art hero (235px, gradient; blurred-cover
  fallback) with the CORNER-CHIP dismiss (fixed 26×26 black circle,
  borderRadius 13, NO HollowPressable padding — padding made hover paint
  spill outside the circle; same structure as the profile popup's expand
  chip, and the FULL profile dialog banner now carries a minimize2 close
  chip of the same shape) + overlapping portrait cover (shadow only, NO
  border) + title/date/metacritic + centered pull-quote blurb (flanking
  “ ” spans, no box) + About; right panel (only when it has content) =
  Platforms as CLICKABLE chips (desktop → Steam/gog/epic fallback chain,
  playstation/xbox/nintendo → their store from `details.stores`; plain when
  no URL, ↗ when tappable), Info fact rows (label left / value
  right-aligned via Expanded — no ragged Spacer+Flexible), System
  Requirements behind Minimum|Recommended selection chips, Credits (DEDUPED
  companies, roleLabel "Developer · Publisher" for devpub, transparent
  logos, social-link buttons), copyright + "Game data from IGDB & Steam".
  PURE display, zero fetch. Brand glyphs in `core/brand_icons.dart`
  (SimpleIcons.ttf); Windows/Xbox/Nintendo were PURGED from Simple Icons →
  custom CustomPaint glyphs in `ui/components/platform_icons.dart`
  (`PlatformIcon`, `platformLabel`).
- Layout host: see wiki `ui_profile_card` (flanking panels, proportional
  scaling).
