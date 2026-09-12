# Game Card Dialog — Steam-enriched, IGDB-credited

> **Status (2026-07-07, final):** shipped, redesigned twice same day, landed
> MINIMAL (SEARCH_VER 6). The rich two-panel version was scrapped after
> content-dependent silent failures (lossless-WebP cover cap busts, IGDB
> enum deprecations killing Steam data, duplicate credit rows). Final card =
> ONE panel: cover + title/date, centered blurb quote, About, clickable
> platform chips (desktop→Steam, consoles→their stores), developer name,
> copyright, attribution. Requirements/company logos+links/key art REMOVED.
> Windows/Xbox/Nintendo glyphs custom-painted (Simple Icons purged those
> marks). Wiki `profile_showcase_board` + memories
> `feedback_igdb_deprecated_enums_and_cdn_cache`,
> `feedback_lossless_webp_content_dependent_size` are current.

Plan for the tap-a-game "game card" detail dialog on profile showcase boards.
Extends the shipped showcase board (commit 45a6150). Follows every invariant in
`project_showcase_board_impl` and `feedback_no_relational_profile_blocks`.

## Guiding principle (unchanged)
- **Zero fetch at display.** A viewer opening a profile contacts NOTHING external.
  All card data is baked into the showcase block at AUTHORING time and replicates
  with the profile blob. Only the OWNER's client ever calls the website endpoint.
- **One image per game.** Cover / key art only — NO screenshots, NO trailers.
  Cached to our CDN exactly like today's cover playbook. 50 GB CDN stays safe.
- **Person-first, not a store listing.** Owner's blurb is the centerpiece. No
  price, no DLC lists, no join funnels, no "recommended by N players".

## Data sources & division of labor
- **IGDB = search/identity layer + developer credit.** Stays primary (covers
  non-Steam games; already integrated). IGDB's `involved_companies` +
  `company.websites` + `company.logo` give STRUCTURED, per-company social links
  and logos — richer dev credit than Steam can provide.
- **Steam appdetails = rich game metadata enrichment.** No API key, ~200 req/5min
  per IP → MUST go through our cached endpoint, never the client. Resolve the
  Steam appid from IGDB's `external_games` (category 1 = Steam) in the same
  authoring flow. No name-match guessing.

## Endpoint changes (`igdb/search.php`, enrich in place)
Extend the existing write-through cache. On a cache MISS (after the IGDB query):

1. **Expand IGDB fields** on the games query:
   - `involved_companies.developer, involved_companies.publisher,`
     `involved_companies.company.name, involved_companies.company.logo.image_id,`
     `involved_companies.company.websites.category,`
     `involved_companies.company.websites.url`
   - `external_games.category, external_games.uid` (to find the Steam appid;
     category 1 = Steam, uid = appid)
   - `screenshots` — NOT requested (dropped by design).
   - keep existing: name, cover.image_id, first_release_date, game_type.type,
     genres.name, total_rating, summary.
2. **Resolve Steam appid** from `external_games` where category == 1.
3. **If a Steam appid exists → one `store.steampowered.com/api/appdetails?appids=<id>`
   call.** Merge the richer fields:
   - `short_description` (prefer over IGDB summary when present)
   - `pc_requirements` / `mac_requirements` / `linux_requirements` → strip HTML to
     plain text, keep BOTH minimum + recommended (OS/CPU/RAM/GPU/storage lines)
   - `platforms {windows, mac, linux}` booleans
   - `metacritic.score`
   - `release_date.date`, `developers[]`, `publishers[]` (fallback/confirm vs IGDB)
   - `achievements.total` (count only — no icons)
   - `genres` (fallback to IGDB genres)
4. **Console/platform coverage** comes from IGDB `platforms` (Steam only has 3
   booleans; IGDB lists consoles too). Request `platforms.name` + a stable
   platform slug for icon mapping (PC/Mac/Linux/PS/Xbox/Switch/etc).
5. **Company logos**: cache each referenced `company.logo.image_id` to
   `covers/` (same image cache, `t_logo_med`). Bounded — a game has 1–3 companies.
6. **Persist everything** in a new `game_details` table (or widen `games`),
   keyed by IGDB id, WAL, write-through. Repeat lookups = ZERO traffic to IGDB
   AND Steam. Rate limits only ever see brand-new games.
7. **Bump `SEARCH_VER`** so cached searches backfill the new fields.
8. **Steam failure is non-fatal** — game stays IGDB-only, card renders the subset.

### company_website category enum (IGDB, authoritative — from api.json)
Used to pick the right social icon per developer/publisher link:
`1 official · 2 wikia · 3 wikipedia · 4 facebook · 5 twitter/X · 6 twitch ·
8 instagram · 9 youtube · 13 steam · 14 reddit · 15 itch · 16 epicgames ·
17 gog · 18 discord · 19 bluesky` (10/11/12 = iphone/ipad/android — skip).

## Endpoint response shape (baked into the block at authoring)
```
{ id, name, year, type, cover, genres[], rating(metacritic or igdb),
  summary, release_date,
  requirements: { min: "...", rec: "..." }|null,
  platforms: ["pc","mac","linux","ps5","switch",...],
  achievements: <int>|null,
  companies: [ { name, role: "dev"|"pub", logo?: <cdn url>,
                 links: [ { kind: "twitter"|"discord"|..., url } ] } ] }
```
Text payload target: ~2–4 KB/game. Well under the 8 KB board cap; the card's
own metadata rides the block `data`, NOT the asset bundle (bundle = images only:
cover + company logos, content-addressed).

## Rust (`api/showcase.rs`)
- Extend `GameSearchResult` (or add `showcase_game_details(id)` if we want lazy
  detail fetch — but decision was ENRICH IN search.php, so the richer fields ride
  the existing search response). Parse the new fields; company logos become
  additional CDN cover-style fetches (reuse `showcase_fetch_cover`'s host
  allowlist — logos live under the same `covers/` CDN path so the allowlist
  already covers them).
- New block field on game blocks: `details` (the baked metadata map above).
- `referencedAssetHashes` must also yield company-logo hashes so bundle pruning
  keeps them.

## Dart
- **Model** (`showcase_board.dart`): game blocks carry an optional `details`
  map (description, requirements, platforms, companies, achievements, etc.).
  Unknown-field round-trip already protects old clients.
- **Game card dialog** (new `dialogs/game_card_dialog.dart`): big key art +
  owner's blurb centerpiece + baked metadata. Platform icon chips (brand_icons /
  atlas / lucide). Company credit row: logo + name + social icon buttons
  (tap = `launchUrl`, a USER action → invariant-safe, like link-out text blocks).
  Requirements in a collapsible min/rec section. NO screenshots/trailers/price.
- **Composer** (`showcase_editor.dart`): when picking a game, fetch + bake the
  details; owner writes the blurb. Tap-through wired from game blocks in
  `showcase_blocks.dart`.
- **Platform + social icons**: map enum kinds → icons. Reuse `brand_icons.dart`
  for platforms/socials; add any missing brand glyphs there.

## Testing
- Harness: extend `showcase_board_replicates_preserves_and_clears` to assert a
  game block WITH baked details (+ a company logo asset) replicates master-keyed,
  survives an untouched update, and clears. Company-logo bytes ride the bundle.
- Endpoint: manual — verify a Steam game (appid resolves, requirements/platforms
  populate) and a non-Steam IGDB-only game (graceful subset). Repeat search =
  zero upstream traffic (check no IGDB/Steam calls on 2nd identical query).

## Legal / ToS stance (carry forward)
- Steam appdetails: no key, public endpoint. Aggressive caching is community
  standard AND required by the rate limit. We cache only what the card displays
  (dev/pub, description, requirements, platforms, metacritic, achievement count,
  one image) — NOT a mirror of Steam's DB. Non-commercial (donations/AGPL).
- IGDB: unchanged non-commercial stance; "Game data from IGDB" attribution in the
  picker already present. Add nothing that mirrors their full DB.
- One image per game to our CDN; everything else is text. 50 GB safe.
```
