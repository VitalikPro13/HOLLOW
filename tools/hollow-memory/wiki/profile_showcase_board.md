# Profile Showcase Board

## Concept and Privacy Model

Self-curated blocks in a pane beside the profile (Steam-showcase model, NOT
Discord's auto-tracked activity feed). Everything on a board was PUT there
by the user — no process detection, ever. Display is pure P2P off replicated
profile data: viewers never contact IGDB, the website, or any third party.
RELATIONAL BLOCKS ARE VETOED (mutual servers/friends = Discovery-species
privacy leak — memory `feedback_no_relational_profile_blocks`). Design
report: `reports/shipped/profile-and-assets/PROFILE_SHOWCASE_BOARD.md`.

## Data Model (lib/src/core/models/showcase_board.dart)

`ShowcaseBoard { left, right, wide?, wideAtTop }` serializes to one JSON
string in the profile's `showcase_board` field. `wide` (2026-09-26) is ONE
artwork block spanning both board columns, `"wide": {...}` plus `"wideTop":
false` only when it sits below the boards; anything but an artwork there
decodes as absent, and clients from before the slot simply ignore the key
(Rust only size-checks the blob, so nothing else had to change).
`isEmpty` counts the wide slot and `referencedAssetHashes()` includes it. Block types (stable wire ids): `text`
(title?, body), `now_playing` (name, cover?, year?, details?),
`favorite_game` (+blurb?), `game_shelf` (label?, games[{name, cover?,
year?}], max 8), `artwork` (image, caption?). UNKNOWN types round-trip
untouched so an old client editing its board can't destroy newer blocks.
Caps: 4 blocks/side, encoded ≤14KB (`maxEncodedLength` — kept under Rust's
16KB `sanitize_incoming_showcase` absent-threshold so a valid board is never
dropped in transit), text body ≤1000, a favourite's "Why this game?" blurb
≤128 (`maxBlurbLength`: about four lines beside the 96x128 cover; a longer
review belongs in a text block; viewers clamp older, longer blurbs by lines). `referencedAssetHashes()` drives
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
asset-hash, links), and since v10 (2026-07-10, all optional/back-compat):
`steamReviews` (`SteamReviews {label, positive, total}` — Steam's own
verdict snapshot, percent derived), `timeToBeat` (`TimeToBeat` — IGDB
seconds; `storySeconds` = normally??hastily, `hoursLabel()` formats),
`themes[]`, `modes[]`, `franchise` (series name). ONLY time-stable stats
ride the bundle (it's an authoring-time snapshot) — player counts/prices
deliberately excluded. Company-logo hashes live INSIDE details assets, so
the editor expands pruning one level via `GameDetails.logoHashesFromBytes`.
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
Bump `SEARCH_VER` when the response schema grows (currently 11: images are
a READ-THROUGH cache, `cached_image` only registers the id in the `images`
table and returns the URL; `fetch.php` pulls the bytes from the IGDB CDN on the
first request and refuses any id `search.php` never handed out, and warm files
under `covers/` are served by Apache with no PHP, per `.htaccess`). Historical
note: the app used to send `v` as a GET query param because **Hostinger's
hCDN edge-cached old responses (`x-hcdn-cache-status: HIT`, forced
max-age=31536000)**; since 2026-07-10 the endpoint is **POST-ONLY** (GET →
405) — POST is never edge-cached, and body params keep search text out of
access logs. Also hardened: `display_errors` off, nosniff/no-referrer/
noindex headers. `config.php` (real credentials) is gitignored; `.htaccess`
denies config/token/db and hard-caches covers (.jpg AND .png). The published
source lives at `HOLLOW/igdb/` and the website repo keeps a copy at
`anonlisten-sites/hollow/igdb/`; deploys go over SSH into the docroot's
`hollow/igdb/`. DIFF THE LIVE FILE FIRST: on 2026-09-26 the live proxy was a
whole version ahead of `anonlisten-sites` (v11 plus `fetch.php`), and uploading
the repo copy would have rolled the image cache back.

**TWO MODES (SEARCH_VER 10).** `q=` = FAST search: ONE IGDB query returning
EXACTLY what the picker renders — {id, name, year, type, cover} and nothing
else (genres/rating/summary stripped in v8; v6 enriched all 12 results
inline = 12 sequential Steam calls ≈ 10-20s per fresh search — never
again). Live-measured 0.4-1.1s. `id=` = card details for ONE game
(~1-2s), fetched when the user PICKS it: one IGDB query
(external_games + involved_companies + websites + artworks expanded) + one
Steam appdetails (no API key; ~200 req/5min per IP → hence the cache) →
description / req_min+req_rec / metacritic / release_date / achievements /
`legal` (the ©-line via `clean_legal`: up to 300 characters, cut at a whole
word with an ellipsis; before 2026-09-26 it cut at exactly 160 mid-word, and
the app's `tidyCopyright()` repairs notices already baked into profiles) / platforms / companies
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
upstream traffic. Steam failure non-fatal. **v10 additions (all best-effort,
pure text ~150B/game)**: `steam_reviews` {label,pos,total} from
`store.steampowered.com/appreviews/{appid}?json=1&language=all&
purchase_type=all&num_per_page=0` (query_summary, no key); `ttb`
{hastily,normally,completely} SECONDS from IGDB `game_time_to_beats`
(separate endpoint, `where game_id =`); `themes[]`/`modes[]` (themes.name /
game_modes.name expanders, cap 4); `franchise` (franchises.name first,
collections.name fallback). Columns added via idempotent ALTERs. Tested
locally via portable PHP (scratchpad php.exe + cacert.pem; REAL config.php
at `WholesomeStoryAday/!hollow-website/igdb/`): v7-v9 = 33 checks; v10 =
live DS3 full payload + cache-hit path + Zelda TOTK no-Steam degrade.

## Dart UI

- Renderers: `ui/components/showcase_blocks.dart`: `ShowcaseBoardView(peerId,
  board, columns)` is THE pane content (two 340 columns 24 apart, or one column
  holding left then right; the wide artwork pinned to exactly 704 = both
  columns, above or below per `wideAtTop`), built from `ShowcaseBoardColumn`,
  `ShowcaseBlockView(block, assets, ownerPeerId)` (headers via
  `ShowcaseBlockView.headerOf`), `ShowcaseWideArtwork`, `ShowcaseArtwork`,
  `ShowcaseCover`, `ShowcaseGameRow`; constants `kShowcaseColumnWidth` 340,
  `kShowcaseGap` 24, `kShowcasePanePadding` 24, `kShowcaseWideWidth` 704. Blocks
  sit directly on the surface (no cards). Assets from
  `showcaseAssetsProvider(peerId)` (family FutureProvider hash to bytes,
  invalidated on ProfileUpdated in event_provider). Text renders via chat's
  `buildMessageText` (links open only on tap; no fetches). Tapping a game opens
  the game card with its owner (`ownerName`, `ownerPeerId`, `source`,
  `shelfLabel`).
- Editor (rebuilt 2026-09-26): `ui/dialogs/showcase_editor.dart`
  `showShowcaseEditorDialog(context, ref)` picks the surface itself. Desktop =
  `ShowcaseEditorDialog`, the PROFILE DIALOG IN EDIT MODE: your
  `ProfileIdentityColumn(showActions: false)` as context, both board columns
  always open ("Left board" / "Right board" + "2 of 4"), blocks drawn exactly as
  viewers see them with a hover/focus toolbar (a drag handle that also opens
  Move up / Move down / Move to the other board, Edit, Remove), "Add block" at
  each column's foot as a `showHollowMenu` (Now playing, Favourite game, Game
  shelf, Artwork, Text, and Wide artwork, greyed once used), and a footer
  across the dialog ("People see your showcase when you save", ghost Cancel +
  filled Save). The ONLY layer ever on top is a menu or game search. Phone =
  `showcase_editor_phone.dart`, a pushed page with the boards as sections, a 44
  More per block opening a sheet, and Save pinned at the bottom.
  `showcase_editor_draft.dart` (`ShowcaseDraft`, shared by both: stable block
  ids for keys, background game bakes that follow a block across edits, empty
  text blocks and shelves dropped, asset pruning incl. the wide artwork, save
  errors as `FriendlyException`), `showcase_editor_blocks.dart` (the editable
  block and the in-place editors: text title 0/64 + body 0/1000, a caption where
  Enter keeps and Escape restores, "Why this game?" with "Optional · 0/128",
  shelves up to 8), `showcase_editor_search.dart` (game search as one popover on
  `showHollowMenu`, a sheet on phones; DLC as a `HollowBadge`, "Game data from
  IGDB"). A full side reads "A side holds 4 blocks. Remove one to add
  another."; over `maxEncodedLength` the footer turns error and Save goes
  neutral-disabled. Cancel, Escape or click-outside with changes asks "Discard
  your changes?". Game picks stay NON-BLOCKING (`bakeGame()` fetches cover, key
  art, details and logos in the background; save awaits them).
- Game card: `ui/dialogs/game_card_dialog.dart` `showGameCardDialog(...,
  ownerName, ownerPeerId, source: GameCardSource.{favourite, nowPlaying,
  shelf}, shelfLabel)`, the SAME card from every game surface (rebuilt
  2026-09-26 to the approved mockup). Desktop: a 600 main column and a 360
  details pane (the one sanctioned wide dialog; the pane stacks under the main
  column when they do not fit). Key art at a TRUE 16:9 edge to edge, never
  cropped, NO scrim, NO blurred fallback (no art = no hero); the 96x128 cover
  overlaps it; title and "developer · date" on the surface. Then the reason
  line (a frameless 24 px avatar with "Mira's favourite" or "On Mira's shelf",
  the blurb as a quote below), facts as plain label/value (Metacritic, Steam
  reviews, Time to beat; no tiles, no tint), About, genre `HollowBadge`s. Pane:
  "Get it on" store `HollowChip`s with an arrow (they leave the app), Details
  rows, Made by (logo, name, role, a labelled website `HollowIconButton`),
  System requirements with Minimum / Recommended `HollowChipTabs`, then the
  publisher's copyright and, as its own paragraph, "Game details from IGDB and
  Steam, saved when Mira pinned it." Phone: a `showHollowSheet`, facts as ROWS
  so nothing shrinks. `showcase_image_stats.dart` keeps ONLY the logo
  legibility probe (tint a transparent monochrome mark, plate a low-contrast
  one); the pixel-probed accent tint is gone. Tests:
  `test/widget/game_card_dialog_test.dart` (incl. `tidyCopyright`), renders
  `test/screenshots/redesign_after_gamecard_screenshot_test.dart`. Brand glyphs
  in `core/brand_icons.dart` (SimpleIcons.ttf); Windows/Xbox/Nintendo are custom
  CustomPaint glyphs in `ui/components/platform_icons.dart` (`PlatformIcon`,
  `platformLabel`).
- Layout host: see wiki `ui_profile_card` (the profile column beside the
  showcase pane, the narrow-window fallbacks, the phone sheet).
