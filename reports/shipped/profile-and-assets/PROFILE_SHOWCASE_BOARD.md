# Profile Showcase Board — Design & Decision Report (2026-07)

**Status:** Concept explored, direction agreed, implementation not started (multi-session epic).
**Author:** Design session with Vitalik (2026-07-06), grounded in IGDB API facts + Steam-profile research + Hollow's existing profile-card data model.
**Scope:** Turn the profile card into a wide, self-curated "showcase board" (IGDB game shelf + Steam-style composable blocks), and how the game metadata reaches clients without breaking Hollow's privacy model.
**Trigger:** "Should we implement IGDB like Discord does for game detection?" → reframed away from Discord's auto-tracked activity feed toward Steam-style self-curation.

---

## 0. TL;DR (the decision)

- **We are NOT building Discord-style rich presence.** Auto-detecting the running process and broadcasting "Vitalik is playing X" is exactly the ambient surveillance Hollow exists to reject (it's the same family as `link previews are sender-side only` and `the relay logs nothing that fingerprints who talks to whom`). Everything on the board is there because the user **put it there** — that curation-not-telemetry distinction is the whole reason it reads as precision rather than "Discord slop."
- **The model is Steam's showcase system, not Discord's activity feed.** What people love about Steam profiles is a stack of **modular blocks they choose, order, and fill** — a canvas, not a form. Discord's own "Board" tab (Want to play / Games I like / Favorite game) is a clumsy copy of exactly that.
- **The profile becomes a wide dialog with an adaptive layout:**
  - **Center** = the person, exactly as today (avatar, banner, name, bio, roles, connections, member-since). Already built.
  - **LEFT and RIGHT** = optional showcase boards the user composes from block types.
  - **The user chooses how many sides to fill:** neither → just the center card (today's behavior, no regression); right only → Discord-Board-style two-column; both → full three-column. Hollow simply renders whatever the person composed.
- **Block types (v-set):** Now Playing · Favorite Game · Game Shelf/Collection · Artwork/GIF · Text/Markdown · Mutuals.
- **IGDB is a metadata tool, not a presence tool.** It's only touched at *authoring* time (searching for a game to add). Display is pure P2P off already-replicated profile data.
- **Data path (Vitalik's design, and it's the right one):** client → Hollow website endpoint (holds the single Twitch app Client ID/Secret) → write-through cache into the Hostinger CDN directory → serve everyone thereafter. ~1 IGDB call per game *ever*. Then the chosen game rides the existing `ProfileUpdate`/Profile-blob replication like avatars and banners — so peers render it with zero IGDB and zero website call.
- **Give everyone all blocks from day one.** Steam gates showcases behind levels to drive engagement; that's a manipulation lever Hollow doesn't need. The joy is the composition, not the grind.

---

## 1. IGDB — the facts that shape the design

**What it is.** Internet Game Database, owned by Twitch/Amazon. REST API at `api.igdb.com/v4/`. ~300k games with covers, screenshots, genres, platforms, release dates, ratings, franchises, companies, videos, similar-games. Free for **non-commercial** use under the Twitch Developer Service Agreement.

**Auth — the part that confused us, resolved.** Two totally separate things people conflate:
1. **Twitch user login** (what a user connects in Settings → Connections; Hollow's existing `twitch.rs`). Proves "I am this Twitch person," gives access to *that user's* data. Does **NOT** grant IGDB access. IGDB has no per-user mode at all.
2. **Twitch app credentials** (one Client ID + Client Secret, created once by AnonListen). `client_credentials` grant → app token → queries IGDB. **Same for every user of the app.** It's a developer key, not a personal one.

So: a user connecting their Twitch does **not** let them fetch IGDB. There is exactly one app credential, owned by us. And the Client **Secret can never ship in the client binary** (extractable → rate-limit burn / ban). This is the load-bearing reason the metadata must go through a server we control.

**Rate limit:** 4 requests/second, 8 concurrent, per Client ID. A shared client-side key would be instantly throttled at any real user count — which the CDN cache (below) makes a non-issue.

**Commercial licensing caveat:** free tier is non-commercial. Hollow heads toward a real product/launch. Flag for later: a commercial IGDB agreement may be needed. The on-demand, cache-per-game approach (vs. mirroring their DB) keeps us on the light-touch side of their ToS and reduces this pressure, but it doesn't erase the licensing question.

---

## 2. Why the Discord approach is the wrong one

Discord's profile right-column is a machine-generated **"Recent activity" feed** — "Forza · 1d ago · 4x Streak", "Trending" badges. Three problems, all antithetical to Hollow:

1. **It's auto-tracked.** The client watches your running processes and reports them. That is precisely the phone-home surveillance Hollow's architecture is built to *not* do.
2. **It's gamified engagement bait.** Streaks and "Trending" exist to pull you back and funnel toward Nitro.
3. **It's the log of you being watched, dressed up as personality.** It isn't *you*; it's telemetry.

The distilled principle: **what makes Discord's profile feel like slop is that the machine populated it; what makes Hollow's feel like precision is that the human curated it.** Hold that rule and you literally cannot build the slop version.

---

## 3. Why Steam is the right model

Steam-profile research (see Sources) shows the beloved thing isn't any single feature — it's the **showcase system**: ~15 showcase types (Favorite Game, Artwork, Screenshots, Game Collector, Review, Workshop, Custom Info Box, …) where the user **picks which blocks appear, in what order, and what fills them**, and coordinates them into a theme. It's self-expression as composition. People sink hours into it precisely because it's a canvas.

That maps cleanly onto a block system, and it absorbs every idea this session circled — Now, Favorites, markdown, custom art — as *block types* rather than competing whole-layout proposals.

**The one thing NOT to copy:** Steam gates showcases behind account levels (one slot per 10 levels) to manufacture "earned" feeling and drive engagement. Hollow gives everyone every block immediately.

---

## 4. The adaptive-layout rule (the keystone decision)

The profile card widens into a dialog. The user composes an optional board on the left and/or the right. **Hollow renders exactly what they built:**

| User fills | Result |
|---|---|
| Neither side | Center card only — identical to today's profile card. No regression, no empty columns. |
| Right only | Two-column (center + right) — the Discord-"Board" shape, but self-curated. |
| Both sides | Full three-column — center flanked by two boards. |

This resolves the entire "what goes in the right column?" question that stalled the earlier three-column mock: the answer is *whatever the person chose to put there* (or nothing). The layout itself is an act of curation.

---

## 5. Block types (v1 set)

Each is a self-contained block the user can add, fill, and order:

- **Now Playing** — one manually-set, present-tense game (big cover + optional "since…"). **Never auto-detected.** Rides the existing `StatusUpdate` path. This is the tasteful descendant of Discord's activity feed — present tense and intent, not a tracked history.
- **Favorite Game** — one large cover + a quote/blurb (the single nicest element in Discord's Board screenshot; a direct Steam "Favorite Game" showcase analog).
- **Game Shelf / Collection** — the cover-art grid (search IGDB → pin). Optional sub-labels ("Backlog", "All-time favorites").
- **Artwork / GIF** — a user-uploaded image or GIF. The most-loved Steam feature; the "custom artwork" Vitalik wanted. Must reuse an existing/cached blob (see §7 privacy).
- **Text / Markdown** — free-form, fully customizable. Sanitized (see §7). Steam's "Custom Info Box" analog. The power-user escape hatch.
- ~~**Mutuals**~~ — **VETOED by Vitalik 2026-07-07, do not build.** Mutual servers/friends is the same privacy species as Discovery: it turns membership into something another person's client enumerates, even when computed locally. No relational/shared-graph block goes in without his explicit approval. (Mutual friends was additionally never computable P2P — no one exposes their friend list.)

---

## 6. Data path & replication

**Authoring (rare, server-touched):**
1. User searches a game in the block editor.
2. Client hits the **Hollow website endpoint** (holds the single Client ID/Secret) → IGDB → returns card metadata + cover.
3. Website **writes the cover into its own CDN directory** on first fetch (write-through cache). Next person wanting that same game is served from CDN, never touching IGDB.
4. Because IGDB metadata is effectively static (a cover doesn't change), we hit IGDB **~once per game, ever** → trivially under 4 req/s at any user count, and light-touch on the ToS.

**Display (constant, pure P2P):**
- The chosen game (cover ref + metadata) is saved into the user's profile and rides the **existing `ProfileUpdate` / Profile-blob replication** — the same machinery as avatars and banners. `ProfileUpdated` already invalidates the relevant caches.
- Peers render the board entirely from replicated profile data. **Zero IGDB call, zero website call at display time.** Content-addressed, lazily replicated — very Hollow.
- Follow the existing light-announce discipline (`send_own_profile_to_peer` sends hashes, blobs pulled on demand) so board art doesn't become a bandwidth leak on reconnect. Cover images are new blob types on that path — they must NOT ride the light announce.

---

## 7. Privacy & security constraints (non-negotiable)

- **No auto process-detection, ever.** "Now Playing" is a button the user presses. No scanning of running games.
- **Receivers never phone home.** This is the iron rule the whole board must respect:
  - Game covers are served from **our CDN** (already-cached blobs), never fetched by the receiver from IGDB or any third party.
  - The **Text/Markdown block must be sanitized.** Raw markdown as a whole profile is a footgun: a `![](http://tracker/…)` image reference would make every profile-viewer's client hit an attacker URL — an IP-leak that breaks "receivers never phone home." Images in the markdown block are **restricted to already-uploaded/cached blobs**; arbitrary remote image/URL fetches are disallowed. (Vitalik's instinct here was right; markdown belongs as *one sanitized block*, not the whole surface. Cf. real-world markdown-renderer CVEs.)
  - **Artwork/GIF blocks** are user-uploaded blobs replicated like avatars — not remote hotlinks.
- **No Twitch-secret in the client.** The Client Secret lives only on the website backend.
- **No relay involvement.** The board is profile data; it replicates peer-to-peer and via the existing profile paths. The relay never learns anyone's game library.

---

## 8. Scope & honest cost

This is a **multi-session epic**, not an afternoon. Each block type is a full vertical slice:
- Rust: a persisted profile field (remember `#[serde(default)]` on every new field or old profiles vanish), FFI, replication wiring on the profile-blob path.
- Website: one small cached IGDB endpoint + CDN write-through.
- Dart: a block editor, a display widget, drag-to-reorder, a block-picker, the adaptive-layout host, and IGDB search UI — all in Hollow's design system (HollowPressable cards, hover that never flashes dark, no glows).

The genuinely unglamorous majority of the work is the **UI** (the composer, the reorder, the cover grid), not the IGDB API. The API is a small backend endpoint; the cache idea makes it robust.

**Recommended slicing when we build:**
1. Read-only Game Shelf block + IGDB search + CDN cache endpoint (proves the whole data path end-to-end).
2. Favorite Game + Now Playing blocks (highest emotional payoff, small surface).
3. Adaptive left/right layout host + block picker + reorder.
4. Artwork/GIF and sanitized Text/Markdown blocks.
5. Mutuals block (pure CRDT data, no IGDB dependency).

---

## 9. Open questions to settle before building

- **Commercial IGDB licensing** — resolve before public launch traffic.
- **Cover image format/size on the CDN** — WebP thumbnail sizing to match the existing avatar/banner blob discipline and keep the profile-blob path light.
- **How much IGDB metadata to persist/re-serve** — cache-for-display (safe) vs. anything resembling rehosting their dataset (ToS-risky). Stay strictly on-demand; never pre-scrape.
- **Board ordering/limits** — max blocks per side, to keep the dialog sane and the profile blob bounded.

---

## Sources

- IGDB API docs — https://api-docs.igdb.com/
- IGDB API V4 announcement — https://medium.com/igdb/igdb-api-v4-is-coming-6ba97874edbc
- Twitch dev forum, IGDB auth (app vs. user token) — https://discuss.dev.twitch.com/t/igdb-authentication-and-tokens-need-server-app/28394
- Steam profile showcase guide (cs.money) — https://cs.money/blog/news/how-to-set-up-your-steam-profile-showcase/
- Steam Community — Ultimate Profile Customization & Showcase Guide — https://steamcommunity.com/sharedfiles/filedetails/?id=2035019938
- Steam profile customization guide (Steam Navigator) — https://www.steamnavigator.com/guides/profile-customization
