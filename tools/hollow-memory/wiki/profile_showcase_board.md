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
(title?, body), `now_playing` (name, cover?, year?), `favorite_game`
(+blurb?), `game_shelf` (label?, games[{name, cover?}], max 8), `artwork`
(image, caption?). UNKNOWN types round-trip untouched so an old client
editing its board can't destroy newer blocks. Caps: 4 blocks/side, encoded
≤8KB (`maxEncodedLength`), text body ≤1000. `referencedAssetHashes()` drives
save-time asset pruning. `cover`/`image` values are asset HASHES.

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

`showcase_game_search(query)` → website endpoint → `GameSearchResult {id,
name, year, game_type, cover_url}`. `showcase_fetch_cover(url)` REFUSES any
URL not under `https://hollow.anonlisten.com/igdb/covers/` (never a generic
fetcher); processes to ≤400px WebP. `process_showcase_artwork(bytes)` — GIF →
animated WebP (≤600KB) / stills ≤800px WebP (≤400KB). `get_showcase_assets
(peer_id)` decodes the stored bundle. `update_profile` gained
`showcase_board: Option<String>` + `showcase_assets: Option<Vec<ShowcaseAsset>>`
(None unchanged / empty clear).

## Website Endpoint (igdb/ in repo root; deployed to /public_html/hollow/igdb/)

`search.php`: Twitch client_credentials token (token.json cache) → IGDB
search → SQLite `games.db` metadata cache (games keyed by IGDB id; searches
keyed by normalized query with `ver` stamp + 30-day TTL) → covers cached to
`covers/{image_id}.jpg`. Repeat searches = zero IGDB traffic. Game type from
the `game_type.type` expander — IGDB's `category` is DEPRECATED and returns
nothing. Bump `SEARCH_VER` when the response schema grows. `config.php`
(real credentials) is gitignored; `.htaccess` denies config/token/db.
Manual upload only (Hostinger file manager).

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
  EVERY block type edits in place (artwork edit = caption only). Save prunes
  the asset bundle to board-referenced hashes and ships board + assets via
  `profileProvider.updateShowcaseBoard` (optimistic cache patch).
- Layout host: see wiki `ui_profile_card` (flanking panels, proportional
  scaling).

## Known Follow-ups

Game-card detail dialog (tap a game → replicated-data-only card with
genres/rating/summary embedded at authoring time; owner's blurb as
centerpiece — NO store links/join funnels). Vitalik has ideas queued.
