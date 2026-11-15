# Redesign "before" brief: five dialogs

One brief per dialog: the renders, what the current layout is, what breaks the design language (HOLLOW_DESIGN_LANGUAGE.md 4.4 and 5.3), and the audit findings from `audit_dialogs_1.md` / `audit_dialogs_2.md` folded in.

**How these were made.** `test/screenshots/redesign_before_screenshot_test.dart` (46 tests; deleted in session 25 once the redesigns replaced these screens, recover it from commit f3ae76de). The after renders come from `test/screenshots/redesign_after_*_screenshot_test.dart` into `build/ui_screenshots/redesign_after/`. All PNGs are in
`C:\Users\Jabun\Documents\Coding\HOLLOW\build\ui_screenshots\redesign_before\` (below: just the file names). Desktop runs as `TargetPlatform.windows` (desktop scroll behaviour), phone as `android`. Fonts: Onest, Geist Mono, Lucide, SimpleIcons, MaterialIcons. FFI is mocked with `RustLib.initMock`; people are invented (Mira, Juno, Sam).

**Reading the test art.** Every generated image has coloured EDGE BANDS: orange = left edge, lime = right edge, cyan = top edge, pink = bottom edge, plus a red centre crosshair. If a band is missing in a render, that edge of the art was cropped off. The banner is 1200x480 (2.5:1), covers 264x352 (3:4), key art 1280x720 (16:9), the avatar 256 square with the built-in teal frame `b:168`.

Harness caveats: the "free" disk figure in the storage dashboard is a live PowerShell read of THIS machine's drive C: (62.8 / 64.3 GB), not fake data. "Find a game" thumbnails show the placeholder because real ones come over the network. The device-link "Device linked" (done) view is NOT rendered: it schedules `relaunchApp()` after 1.5 s, which calls `exit(0)` and would kill the test process; it is described from code below.

---

## 1. Profile popup (full `ProfileDialog`), compact card, phone sheet

Files: `lib/src/ui/dialogs/profile_dialog.dart`, `lib/src/ui/components/profile_card_body.dart`, `lib/src/ui/components/profile_card_popup.dart`, `lib/src/ui/mobile/mobile_profile_sheet.dart`.

### Renders
| What | File |
|---|---|
| No board, 1440x900, dark / light | `profile_full_noboard_dark.png`, `profile_full_noboard_light.png` |
| Left wing only, 1440 | `profile_full_leftwing_dark.png` |
| Both wings, 1440 dark / light | `profile_full_bothwings_dark.png`, `profile_full_bothwings_light.png` |
| Both wings, tall window (whole ensemble, no scroll) | `profile_full_bothwings_tall_dark.png` |
| Both wings, 1100 wide (scaled) | `profile_full_bothwings_scaled_1100.png` |
| Both wings, 800 wide (stacked) | `profile_full_bothwings_stacked_800.png` |
| Stranger with no banner, no avatar (fallbacks, "Add Friend") | `profile_full_stranger_nobanner_dark.png` |
| Your own profile (Edit Showcase / Edit Profile) | `profile_full_self_dark.png` |
| Compact card (name click), friend dark / light, stranger | `profile_compact_friend_dark.png`, `profile_compact_friend_light.png`, `profile_compact_stranger_dark.png` |
| Phone sheet 390x844: top, middle, bottom | `profile_phone_sheet_top.png`, `profile_phone_sheet_mid.png`, `profile_phone_sheet_bottom.png` |

### Current layout
- **One `HollowDialogSurface(padded: false)`** holds everything. With no board it is just the 560 centre card. Each filled side adds a 340 wing, a 1 px `HollowVerticalDivider`, and 12 px of "gap" that the centre's `Expanded` actually absorbs. `IntrinsicHeight` + `CrossAxisAlignment.stretch`, min height 560, so every column is as tall as the tallest one.
- **Centre card, top to bottom:** banner (fixed 224 tall), a 110 avatar with a 4 px `overlay` ring overhanging the banner by 48, the frame art in front, a 26 px black-alpha circle close control with a `minimize2` glyph in the banner's top-right corner; then name (22/w700), "Online · Friends" in green, italic status, role + label chips (local `_ProfileChip`), a hand-drawn 1 px line, "About me" header + 13 px body, a full-width filled **Message** (or outline Add Friend), a row of five equal 34 px bordered icon squares (nickname, verify, manage member, **Block in red, Report in red**), and a centred mono peer-id footer at 10 px in faded alpha.
- **Wings:** `ShowcaseBoardColumn` with 12 px padding; each block is a `_BlockCard` (`surface` at 0.6 alpha, hairline border, radiusMd) with a dense section header: "Now playing" row (64 cover, title, year, chevron), text block, "Favorite game" (140 cover, title, italic blurb), "Backlog" shelf grid (3 per row at 1440), artwork (full-width image, italic caption).
- **What draws the eye:** in wing mode the banner, the big favourite-game cover, the artwork and the teal Message bar all compete; the person's name is not the winner.
- **Compact card (300 wide):** banner 300x120, 64 avatar, same sections at compact sizes, an accent "✦ View showcase" text link when a board exists, filled Message, five icon squares (Block/Report red), 8 px peer-id tail. Opens anchored, `overlay` fill, hairline, float shadow; expand glyph `maximize2` on the banner.
- **Phone sheet:** `showHollowSheet` at 0.9 height. A ~20 px handle strip, then the banner at full width 2.5:1 (390x156), a 72 avatar CENTRED, centred name, "Online", role chip on its own line, labels on the next line, status, centred About text (4 lines max), then the whole showcase stacked (left side then right side, same `_BlockCard`s), and only then **Message**, a green "Friends" line, and a 3-icon strip (nickname, verify, More). On a full board the Message button sits roughly 900 px down, below every block (see `profile_phone_sheet_bottom.png`).

### What happens to the banner at the sides (measured on the renders)
The banner is `height: 224` fixed, `width: double.infinity` inside the centre column, `BoxFit.cover`. The code comment says both heights are "their host's width / 2.5", which is only true when the centre is exactly 560.

| Case | Dialog | Centre column | Banner box | Ratio | Crop |
|---|---|---|---|---|---|
| No board, 1440 | 560 (x 440 to 999) | 560 | 560x224 | 2.50 | none, all four bands visible |
| Left wing, 1440 | 912 (x 264 to 1175) | 570 (x 605 to 1175) | 570x224 | 2.54 | ~2 px shaved top and bottom |
| Both wings, 1440 | 1264 (x 88 to 1351) | 582 (x 429 to 1010) | 582x224 | 2.60 | ~4 px top and bottom: the cyan/pink bands shrink from ~7 px to ~1 px |
| Both wings, 1100 (scale 0.83) | 1052 (x 24 to 1075) | 486 (x 307 to 792) | 486x224 | 2.17 | **the SIDES are cut**: ~37 px each side on screen (~79 source px of 1200 per side); the orange and lime bands are gone |
| Stacked, 800 | 560 (x 120 to 679) | 560 | 560x224 | 2.50 | none |
| Compact | 300 | 300 | 300x120 | 2.50 | none |
| Phone sheet | 390 | 390 | 390x156 | 2.50 | none |

So the banner is only ever correct at exactly 560. Every wing layout changes its aspect, and the scaled layout (any window between ~841 and ~1336 wide with two wings) crops the art's left and right edges, because only widths scale while the 224 height, the 110 avatar and the type stay fixed.

**How the wings meet the banner (both-wings render, `profile_full_bothwings_dark.png`):**
- The banner spans the **centre column only**. The wings start at the dialog's top edge beside it, on the plain `overlay` fill, so the dialog reads as a dark slab with a bright strip set into the middle of its top edge.
- The two hairlines (x 428 and 1011) run all the way up **beside the banner** to the dialog's top edge, so the banner is fenced off from the wings rather than being the ensemble's header.
- **Square top corners on the banner** in wing mode: the dialog's rounded corners belong to the wings (with the left wing only, the banner's right corner is rounded and its left is square, so it is lopsided).
- **Mismatched tops:** the banner starts at y 0 of the dialog, the first wing card at y 12 (wing padding). **Mismatched bottoms:** the banner ends at y 224; nothing in either wing lines up with that (left: "Now playing" card ends ~149, "Currently" ~271; right: "Favorite game" card ends ~299).
- **Dead space from `stretch`:** the right wing is 834 px tall, so the left wing is empty from ~271 to 834 (~560 px of blank panel) and the centre is empty below its footer (~620 to 834, ~210 px).
- The close control sits on the **centre column's** corner, not the dialog's, so in wing mode it floats mid-top.
- The avatar's 4 px `overlay` ring cuts into the banner's bottom-left; the wing to its left has no matching element, so the avatar reads as hanging at a seam.
- The wing cards (`surface` at 0.6 on `overlay`) are DARKER than the panel they sit on in dark mode: they read as holes, and in light mode as grey slabs with borders.

### Against the design language
- **5.3.1 squint:** fails in wing mode (banner, favourite cover, artwork and the teal Message bar tie). With no board it passes (banner, then name).
- **5.3.2 nothing twice:** "Friends" is a green label in the status row AND the reason Message shows; on the phone "Friends" is a second line under Message. Role and label chips repeat what the member list already says (acceptable, but loud).
- **5.3.3 status by exception:** "Online" in green is always shown (healthy state speaking); the peer-id footer is an operator figure on a person's screen.
- **5.3.5 destructive out of reach:** FAILS on desktop full and compact: Block and Report sit at rest in red in the strip right under Message. The phone sheet does it right (More menu).
- **5.3.6 accent:** fine on Message; the owner/moderator role chips use warning colours as decoration; the Twitch chip is a hardcoded `Color(0xFF9146FF)`.
- **5.3.8 one row per kind:** wing blocks are a local `_BlockCard` (card on overlay with a hairline, which 4.3 "Cards" forbids: background step only, no hairline); role/label chips are a local `_ProfileChip` (should be `HollowBadge`; the Twitch one is clickable, so a `HollowChip`).
- **5.2 layout:** three equal-weight regions (wing, card, wing) with no winner, which 5.2 caps at one main region plus at most one side panel; narrow windows SQUEEZE the side panels instead of dropping them.
- **5.3.12 targets:** 26 px close; phone strip icons fine.
- **4.4:** frame is correct (`HollowDialogSurface`), but the close control is not `HollowDialogCloseButton`, uses `Colors.black`/`Colors.white`, `BorderRadius.circular(13)`, a 13 px icon (off the 14/16/20/24 ramp) and says "collapse" (`minimize2`), not "close".
- **Type/tokens:** `fontSize:` 22, 15, 13, 12, 11, 10, 8 across the card; `w700`; the peer id at 8 px (compact) and 10 px, faded with alpha (below the 10 px floor, and alpha-faded text is forbidden); numeric gaps `xs + 2`, `sm + 4`, `md + 2`, `SizedBox(height: 20)`; `Container(height: 1)` instead of `HollowDivider`; the no-banner fallback is a `LinearGradient` (gradients are forbidden; visible in `profile_full_stranger_nobanner_dark.png`).
- **Self view:** "Edit Showcase" ghost + "Edit Profile" outline in Title Case; the outline is in accent with no filled beside it (4.2 says outline only beside a filled).

### Audit findings pulled in (`audit_dialogs_1.md`, Profile (full), POLISH)
- C11/D21: the only close control is the hand-built 26 px circle in `profile_card_body.dart:181-200` (black 0.4 alpha, `circular(13)`, 13 px `minimize2` in white, no tooltip). Fix: `HollowIconButton` / `HollowDialogCloseButton` over media (a design-ignore for the scrim over the banner), 16 px icon.
- A2: own layout on `HollowDialogSurface(padded: false)` is allowed; widths computed from constants (`profile_dialog.dart:50-62`).
- Cross-cutting P2: nothing is 44 px on a phone (not relevant to the sheet, which is its own surface).
- Vitalik: "a weird thing with the sides on banner" = the table and the seam notes above.

---

## 2. Game card (`game_card_dialog.dart`)

### Renders
| What | File |
|---|---|
| Desktop 1440x900 | `gamecard_desktop_dark.png` |
| System requirements opened, Minimum / Recommended | `gamecard_desktop_requirements_min.png`, `gamecard_desktop_requirements_rec.png` |
| Tall window (whole card) | `gamecard_desktop_tall_dark.png` |
| No key art (blurred-cover hero fallback) | `gamecard_desktop_noart_dark.png` |
| 800 wide (still side by side) | `gamecard_narrow_800_dark.png` |
| Phone 390x844 (stacked) | `gamecard_phone_dark.png` |

### Current layout
- `HollowDialogSurface(padded: false)`, 872 wide at 1440 (x 284 to 1155): a 570 centre pane, a hairline, a 300 details pane. Same scale-then-stack rule as the profile (stacks only below 0.62 scale, so 800 wide is still two panes; the phone stacks).
- **Centre pane:** a hero of the 16:9 key art at 570x235 (y 166 to 401) with a gradient scrim fading into the panel and a 26 px black circle X (white glyph) in its corner; a 90x120 cover overlapping the hero's bottom-left; title "Outer Wilds" (19/w700) + date beside the cover; three stat tiles in a row (Metacritic "85" in green, Steam reviews "Overwhelmingly Positive · 96% of 103k", Time to beat "~22h · 100%: ~30h"), each a box washed in the game's probed colour with a tinted border; the blurb as an italic pull quote with big decorative quote marks; "About" + description; genre/theme/mode tags as small grey badges.
- **Details pane:** "Platforms" (Windows as a larger linked chip with ↗, PlayStation/Xbox/Nintendo as smaller badges); "Info" (Achievements 31); "Credits" (company logo plates, name, role, globe/X link icons); "System requirements" collapsible with a local Minimum/Recommended pill tab and the spec text in an `elevated` well; a legal line and "Game data from IGDB & Steam".
- **Eye goes to:** the hero art and the tinted stat tiles; the title is small next to them.

### What the renders show
- **Hero crop:** 16:9 art in a 570x235 box (2.43:1): ~85 px of the art's height is lost top and bottom at display scale (the cyan and pink bands never appear); on the phone the hero is ~342 wide and the SIDES go instead (orange/lime missing).
- **Nondeterministic tint:** the stat tiles are brown in `gamecard_desktop_dark.png` (probed from the cover) and accent teal in `gamecard_desktop_tall_dark.png`: the probe is async, so the card first paints in accent and then re-tints.
- The no-art fallback is a heavily blurred, scaled-up cover (`ImageFiltered`) under the same gradient: a muddy colour field.
- The details pane is two-thirds empty on desktop (everything above y ~530 of 735).
- Phone: tiles squeeze to ~100 px: "Steam revi…" truncates and "Overwhelmingly Positive" auto-shrinks to about 7 px; the quote wraps with orphaned quote marks; platforms fall below the fold.
- Windows chip is a different size and style from the other platforms (it is the only link).

### Against the design language
- **5.3.1 squint:** hero + tiles + cover tie; the game's name loses.
- **5.3.6 accent / 4.3 cards:** probed colour or accent tints decoration (tiles, Recommended pill); Metacritic green is a data colour with no pairing.
- **5.3.7 icons:** an icon on every tile label and every fact row.
- **5.3.8 / 4.1:** `_ReqTab` is a local pill (radius 999, accent tint) where `HollowChip` exists; platform chips mix a clickable chip and badges in one row.
- **5.3.10 numbers:** "28 May, 2019" is Steam's string, not `conversationTimeLabel`-style words; fine as a written date but in body type.
- **5.3.12 targets:** 26 px X, icon-only credit links with no tooltip.
- **4.4:** frame right; "wider only for a real layout (the game card)" is the one sanctioned wide dialog; close control hand-drawn.
- **7 forbidden:** gradient scrim, blur, `Colors.black/white`, `Color(0x` ×5, numeric radii, `fontSize:` ×13 incl. half steps.

### Audit findings pulled in (`audit_dialogs_2.md`, Game card, REWORK)
- D15: 13 `fontSize:` (`:367, 377, 387, 406, 535, 550, 560, 725, 942, 955, 1072, 1107, 1214`) incl. half steps 10.5/11.5/12.5/13.5 and `w700` (`:368, 388, 534, 724`); title should be `heading`, blurb `body`, facts `caption`/`label`.
- D15: `Colors.black`/`Colors.white` (`:279, 321, 325`), `Color(0x` ×5 (score bands `:574-577`, logo plates `:1168-1170`).
- D15: `LinearGradient` scrim (`:488-500`) and `ImageFiltered` blur (`:455-464`), both forbidden; decide a flat `overlay` band under the title, or no fallback hero.
- D15: numeric radius 13/999/4/4 (`:316, 1099, 1132, 1170`); numeric insets and gaps (`:300, 311-312, 684, 991, 1063, 1101, 1165`, `:539, 699, 713, 729`, `xs+2`/`sm+2` `:804, 819`); alpha-faded text (`:366, 376, 386, 474, 859`).
- D17: `_StatTile` (`:682-691`) is decoration; make plain label/value columns.
- D18: icon sizes 13, 34, 10.5, 13, 13, 18 (`:325, 473, 698, 936, 1005, 1198`).
- D16: `_ReqTab` (`:1082-1111`) should be `HollowChip`.
- D21/F25: hand-drawn 26 px close (`:310-328`) with no tooltip; credit links (`:1254-1264`) icon-only without tooltip; use `HollowIconButton` 32/44.
- D19: `_gameAccent ?? hollow.accent` tints the tiles (`:159`, `:688-690`).

---

## 3. Showcase editor (`showcase_editor.dart`) and its sub-dialogs

### Renders
| What | File |
|---|---|
| Editor, empty board | `showcase_editor_empty.png` |
| Editor, filled board (2 left, 3 right) | `showcase_editor_filled.png` |
| Add block picker | `showcase_sub_block_picker.png` |
| Add text block (new) | `showcase_sub_text_new.png` |
| Edit text block (existing, with markup) | `showcase_sub_text_edit.png` |
| Find a game: empty, results, no results | `showcase_sub_find_game_empty.png`, `showcase_sub_find_game_results.png`, `showcase_sub_find_game_none.png` |
| "Why this game?" blurb prompt (after picking a favourite) | `showcase_sub_why_this_game.png` |
| Game shelf, new / editing an existing shelf | `showcase_sub_shelf_new.png`, `showcase_sub_shelf_edit.png` |
| Artwork caption prompt (after the file picker) | `showcase_sub_artwork_caption.png` |

Not rendered: a phone variant (it is the same dialog, compact frame), the drag-to-reorder proxy.

### Current layout
- `HollowDialog` "Edit showcase", default width (600 at 1440). One prose line ("Compose blocks on either side of your profile…"), then **"Left board 2/4"** and **"Right board 3/4"** as two dense section headers STACKED VERTICALLY, each followed by its block rows and a ghost "+ Add block". Actions: ghost Cancel, filled Save.
- A block row: an `elevated` rounded strip with a grip handle, a 14 px type icon, a one-line summary at 12 px ("Now Playing: Hollow Knight: Silksong", "Favorite: Outer Wilds", "Backlog (4 games)", "Artwork: Frame sketch, night shift", or a text block's title), then a 13 px pencil and a 13 px x.
- Empty side: italic faded caption "Empty. This side isn't shown."
- **No preview**: nothing shows what the board will look like, and "left/right" are words in a vertical list, not places.
- **Sub-dialogs stack on top of the editor**, each with its own scrim, so the editor behind goes darker with each level (text edit, why-this-game, shelf and caption renders show two levels):
  - *Add block* (600, `showClose` X): five hand-built rows, 18 px icon, Title Case title + one-line description ("Now Playing", "Favorite Game", "Game Shelf", "Artwork / GIF", "Text").
  - *Add/Edit text block* (420): title field with a 0/64 counter, a 6-line body with a 0/1000 counter, a 10 px hint "Supports **bold**, *italic*, `code`, ||spoilers|| and links." The body shows raw markup; no preview.
  - *Find a game* (600, X): search field, then results as hand-built rows (32x43 thumb, name, a local "Main Game"/"DLC" pill, year), "Game data from IGDB" micro text faded with alpha. The dialog re-centres and changes height between empty, results and no-results (the "no results" dialog sits ~70 px lower than the results one).
  - *Why this game?* (420): one field, ghost **Skip**, filled Save.
  - *Game shelf* (420): a label field whose hint is its label ("Shelf label (e.g. "Backlog", optional)"), a plain list of names with a gamepad icon and an x (no covers, no reorder), ghost "+ Add game (4/8)", Cancel/Save.
  - *Caption* (420): one field, Skip/Save, and **no preview of the image just picked**.
- Adding a favourite game is three dialogs deep (picker, Find a game, Why this game?); adding artwork is the OS file picker then Caption.

### Against the design language
- **5.3.1 squint / 5.1 focal point:** nothing wins; the job ("make my profile's sides look like this") has no picture of the result.
- **5.3.4 progressive disclosure:** the opposite: every block type is a chain of modals.
- **5.3.8 one row per kind:** picker rows and search rows are hand-built where `HollowListRow` exists; the type pill is a local badge.
- **5.3.9 next step:** empty sides are italic faded captions, not `HollowEmptyState(dense: true)`.
- **5.3.12 targets:** 13 px pencil/x icon buttons (~21 px), no tooltips.
- **5.3.14 states:** no discard guard; Save on an empty text body silently does nothing.
- **4.4:** titles fine and sentence case; prompts should be `promptForName()`; "Skip" is the ghost where the rule expects Cancel, and on edit it erases.
- **3.4 case:** Title Case picker titles and row summaries ("Now Playing:", "Favorite:", "Game Shelf"); US "Favorite" vs "Favourites" elsewhere.

### Audit findings pulled in (`audit_dialogs_2.md`, Showcase editor, REWORK)
- Bug: reorder off by one: `onReorderItem` already hands a post-removal index and the code subtracts again (`:480-486`); moving down one place does nothing, N places lands at N-1.
- Honesty: `_promptText`'s Skip returns `''` (`:1228-1231`); when EDITING an artwork caption (`:346-357`) or a favourite's blurb (`:318-325`) Skip ERASES the existing text.
- Structure: favourite game = 3 stacked dialogs; artwork = file picker + caption; no preview while composing. Needs a design decision (inline editor, or one dialog per block type).
- No confirm on Cancel / Escape / click-outside discarding a composed board (`:29-32`, `:409-412`).
- D20: picker options (`:639-678`) and search results (`:928-996`) hand-built, icon 18, fontSize 13/11; Title Case in picker (`:623-631`) and summaries (`:550-557`).
- D16/D15: game-type pill is a local badge (`:966-982`, padding 5/1): use `HollowBadge`.
- D21/F25: Edit/Remove and shelf Remove are icon-only `HollowPressable`s, 13 px, no tooltip (`:591-606`, `:1169-1176`).
- D15: 9 `fontSize:` (`:457, 586, 661, 668, 907, 960, 990, 1165, 1324`); raw `Material(` + `Colors.black26` + elevation in the drag proxy (`:470-476`, use the Friends Manager `_DragLift`); `sm + 2` (`:562`); alpha-faded text (`:456, 1004, 1019, 1323`).
- D22/E23: empty side as italic caption (`:453-460`); empty text body Save no-ops (`:1284`); shelf label hint-as-label (`:1146`); text fields unlabeled (`:1305-1318`).
- A2: a `ListView` capped at 320 inside `HollowDialog`'s own scroll (`:921-923`).
- C13: artwork failure toasts the raw exception (`:272`); `_busy` puts BOTH sides' Add block into loading and disables Save during an upload (`:512`).
- A3: `_promptText` (`:1206`) duplicates `promptForName` (`shell/server_context_menus.dart:333`).
- Misc: unused `ref` parameter (`:28`); prompt controller never disposed (`:1213`).

---

## 4. Storage dashboard (desktop dialog + phone route)

Files: `lib/src/ui/dialogs/storage_dashboard_dialog.dart`, `lib/src/ui/mobile/mobile_storage_route.dart`.

### Renders
| What | File |
|---|---|
| Desktop, first frame before data (no loading state) | `storage_desktop_loading.png` |
| Desktop, 3-member server (full replication) | `storage_desktop_small_dark.png` |
| Desktop, 12-member server (erasure coding) | `storage_desktop_large_dark.png` |
| Desktop retention picker (chips) | `storage_desktop_retention_picker.png` |
| Desktop pledge dialog | `storage_desktop_pledge_dialog.png` |
| Phone route, 3 members / 12 members | `storage_phone_small_dark.png`, `storage_phone_large_dark.png` |
| Phone retention picker (radio rows) | `storage_phone_retention_picker.png` |
| Phone pledge dialog | `storage_phone_pledge_dialog.png` |

### Current layout
- **Desktop:** `HollowDialog` "Storage dashboard", 600 wide, `showClose` X, no actions. Content is a grid of `HollowCard`s with dense Title Case headers:
  - under 6 members: "Server Storage" full width (mode "Full Replication", an 8 px accent bar of server data against the whole disk, "1.8 GB" left, "⛁ 62.8 GB free" right, "3 members"), then "Retention Policy" + "Vault Health" side by side;
  - 6 or more: "Server Storage" ("Erasure Coding (k=5/m=3)", bar, "14.2 GB / 37.5 GB", "1.6x overhead", "12 members · 60.0 GB raw capacity") beside "Your Storage" ("Pledge: 5.0 GB ✎", bar, "3.1 GB used", "⛁ 64.3 GB free"), then Retention + Vault Health, then a full-width "Member Pledges" ("12 members contributing … Avg: 5.0 GB each").
  - Retention rows: a fixed 72 px label with a colon ("Messages:", "Files:") then the value in w500 and an 11 px pencil; "Changes affect new content only." Vault health: a status dot + "Full replication" / "All shards healthy", "214 shards stored locally".
  - Retention picker: `HollowDialog` with an X and five `HollowChip`s (correct pattern). Pledge: 420 dialog, `SettingsFieldLabel` "Pledge in MB", raw MB number (5120), Cancel/Save.
- **Loading:** there is none: the first frame (`storage_desktop_loading.png`) states "0 B" and an empty bar as facts, plus default retention values, and the layout switches from one column to the grid once members load.
- **Phone:** a `Scaffold` with a Material `IconButton` back arrow and "Storage" in `subheading`, then a `ListView` of local `_SectionCard`s (elevated, radiusMd) in one column: Server Storage, Your Storage (6+ only), Retention Policy, Vault Health, Member Pledges. The small-server bar is hardcoded EMPTY while 1.8 GB is used; no free-disk line. Retention picker = radio rows with an accent circle-check plus a Cancel; the pledge dialog has no label, no width, and Save is on a phone-sized dialog (Android selection handle visible because the field autofocuses).
- **Eye goes to:** the accent bars; everything else is equal-weight card text.

### Against the design language
- **5.3.1 squint:** five same-weight cards; no answer to "am I OK?" wins.
- **5.3.2 nothing twice:** the mode appears twice ("Full Replication" in Server Storage, "Full replication" in Vault Health; "Erasure Coding (k=5/m=3)" plus the shard line).
- **5.3.3 status by exception:** "All shards healthy" and a green dot speak while healthy; k/m, overhead, raw capacity and shard counts are operator figures.
- **5.3.10 honest numbers:** "free" is always drive C:, wherever the data lives; the phone bar is a fake 0; "0 B" before load.
- **4.3 cards:** settings groups drawn as cards (a section is not a card), in a 2x2 grid (5.2: one region plus at most one side panel).
- **3.4 case:** Title Case headers and values.
- **5.3.12 targets / 4.2 buttons:** edit affordances are text with an 11 px pencil, no semantic label; should be a row with a compact outline "Change".
- **4.4:** desktop OK frame; phone pickers diverge (radio rows + Cancel vs chips).

### Audit findings pulled in (`audit_dialogs_2.md`, Storage dashboard, REWORK)
- D17: five `HollowCard` sections in a 2x2 grid (`:247`, `:171-235`): make them sections with hairlines, one column.
- B8 honesty: "free" is always drive C: (`:98-101`, `Get-PSDrive C`); `df --output` (`:104`) is GNU-only, so macOS gets 0 and hides the line.
- B8 jargon: "Erasure Coding (k=3/m=2)" (`:133-140`), "1.5x overhead" (`:345`), "raw capacity" (`:352`), "shards" (`:663, 683`); Title Case "Full Replication" (`:133`) vs "Full replication" (`:629`); same fact twice.
- C13: pledge and retention writes fail silently (`debugPrint`, `:409-412`, `:557-559`), no busy state, no toast; a pledge under 512 does nothing with no message (`:368`, E23).
- E23: no loading state; `_stats` null reads as "0 B" with 0 members; layout jumps (`:159`, `:174`); errors swallowed (`:92`). Use a skeleton plus an error line.
- Edit affordances: clickable text + 11 px pencil (`:427-444`, `:585-611`), no semantic label; label colons as columns ("Pledge:", "Avg:", "Messages:", `:434, 498, 594`).
- D15: icon 11 ×4 (`:296, 441, 458, 607`); `SizedBox(width: 4)` ×2, `height: 2` ×3; hand-built 8 px bar (`:692-725`) where `HollowProgressBar` (4 px) exists.
- Phone twin: (a) entry says "Storage on this phone" but shows server-wide stats; (b) small-server bar hardcoded 0.0 (`:198`); (c) raw `IconButton` + `Icons.arrow_back`, no tooltip, subheading title (`:120-126`), should be `MobileSettingsSubPage`; (d) radio-row retention picker with accent icon + Cancel (`:383-414`) vs desktop chips; (e) pledge dialog without width 420, label or Enter submit (`:279-304`); (f) `fontSize: 10` ×3, numeric radius ×4; (g) local `_SectionCard` (`:551`). Rebuild both on one shared body.
- Probe string at risk: "Storage on this phone" (`test/widget/server_settings_test.dart`).

---

## 5. Welcome (`welcome_dialog.dart`) and the link-a-device path

### Renders
| What | File |
|---|---|
| First run, dark / light | `welcome_firstrun_dark.png`, `welcome_firstrun_light.png` |
| Advanced opened (relay field) | `welcome_advanced_dark.png` |
| Phone 390x844 | `welcome_phone_dark.png` |
| Other profiles on this computer (faked: Mira current, Work, Juno test) | `welcome_profiles_dark.png` |
| Same, light, with Advanced open too | `welcome_profiles_advanced_light.png` |
| Restore from Backup: passphrase prompt, then "Restoring…" | `welcome_restore_passphrase.png`, `welcome_restoring.png` |
| Link path 1: "Connecting to link your device…" | `welcome_link_1_connecting.png` |
| Link path 2: enter code, dark / light | `welcome_link_2_entercode_dark.png`, `welcome_link_2_entercode_light.png` |
| Link path 3: enter code before the relay is up (Link disabled) | `welcome_link_3_entercode_offline.png` |
| Link path 4 to 7: waiting, receiving 41/66 MB, importing, failed | `welcome_link_4_waiting.png`, `welcome_link_5_receiving.png`, `welcome_link_6_importing.png`, `welcome_link_7_failed.png` |

Not rendered: "Device linked" (see caveat at the top). From code (`device_link_dialog.dart:492-519`): title "Device linked", "Your data was copied across. Restarting Hollow to finish…", a medium spinner, a centred caption about servers and history, one filled "Restart now" with a power icon; it restarts by itself after 1.5 s.

### Current layout
- `HollowDialogSurface`, 480 max / 360 min, everything centred: a 56 px rounded logo, "Welcome to Hollow" (`heading`), "Choose how to set up your identity" (`body`, secondary). With other profiles present, a folder icon + "Setting up the "Mira" profile" and the mono path under it.
- Three **option cards** of equal weight: a 40 px accent-tinted rounded box with an accent icon, a Title Case title ("Create New Identity", "Link a device", "Restore from Backup"), an 11 px subtitle, a faded chevron; `surface` at 0.4 alpha with a hairline border, accent border on hover.
- Optional "› Use a different profile (2)" disclosure (12 px caption text) that opens bordered profile rows (drive/usb icon, name, mono path, compact **outline "Switch"** in accent), and a note "Switching restarts Hollow. This folder stays as it is."
- "› Advanced" disclosure (12 px caption) opening a dense relay field with a server prefix icon and a centred caption "Self-hosters: enter your relay domain. Leave default for the official network." under a left-aligned field.
- **Restore:** the OS file picker, then a separate 420 `HollowDialog` "Enter backup passphrase" (one obscured field, Cancel / Decrypt) that does not say which file; on Decrypt the third card swaps to a static loader glyph and "Restoring… / Decrypting and importing your backup", while all three cards stay tappable.
- **Link path** (after Welcome closes and the node starts): a 320 "Connecting…" surface with a large spinner; then `DeviceLinkMode.enterCode` dialogs, all 420 `HollowDialog`s: "Link this device" (prose, a heading-size code field with "ABC123" placeholder, a caption, Cancel + filled Link; offline adds "Hollow is not connected to the relay yet." and dims Link); "Linking this device" with a Material `LinearProgressIndicator` (indeterminate while waiting/importing, determinate with "41.0 MB / 66.0 MB" while receiving) and a ghost Cancel; "Link failed" with the error sentence, ghost Back and filled Try again.
- **Eye goes to:** the logo and the three accent icon boxes; no option is the obvious one.

### Against the design language
- **5.3.1 squint / 5.1 primary action:** three equal cards tie; "Create a new identity" (the common case) is not the one filled action.
- **5.3.6 accent / 5.3.7 icons:** accent icons in accent-tinted boxes beside every option (the "icon in a tinted box beside a list item" the skill forbids); accent hover border.
- **4.3 cards / 3.1 surfaces:** option cards and profile rows are `surface`-alpha cards with hairlines inside an `overlay` dialog ("a card on surface is a bug").
- **3.4 case:** Title Case "Create New Identity", "Restore from Backup" beside "Link a device".
- **5.3.10 honesty:** "Sync from your other device with a 6-digit code", but the code is 6 characters, letters and digits.
- **5.3.12 targets:** Advanced and profile disclosures are 12 px text rows; phone renders (`welcome_phone_dark.png`) show the same small targets and subtitles wrapping mid-word ("6- / digit").
- **5.3.14 states:** Restoring is a text swap with a static glyph; an invalid relay is a toast, not a line at the field.
- **4.4 (link path):** titles, actions and widths are right; the progress bar is Material with `circular(99)`; "Link" with fewer than 6 characters silently does nothing; no `onSubmitted`.
- **5.2 alignment:** centred hero is allowed here, but the relay caption is centred under a left-aligned field, and the profile rows are left-aligned under a centred heading.

### Audit findings pulled in (`audit_dialogs_2.md`, Welcome, REWORK; Device link, POLISH)
Welcome:
- B8: "6-digit code" (`:285`) is wrong; the code is 6 characters (`device_link_dialog.dart:280`).
- B6: Title Case "Create New Identity" (`:264`), "Restore from Backup" (`:298`).
- D17/D18/D19: `_OptionCard` (`:484-585`) is a card on `surface` at alpha (`:524-526`), accent border on hover (`:529-531`), accent icon in an accent-tinted 40 px box (`:536-548`); profile rows repeat it (`:428-437`). Decision needed: three `HollowListRow`s, or three stacked buttons (one filled "Create a new identity", two outline).
- D15: 9 `fontSize:` (`:239, 332, 355, 390, 397, 419, 455, 559, 567`); `SizedBox(height: 2)` ×2 (`:246, 562`); icon 12 (`:232`); chevron faded with alpha (`:576`).
- C13: Restore swaps text/icon (`:297-301`) instead of a spinner, cards stay tappable; raw exceptions in toasts (`:86`, `:170`).
- E23: invalid relay = toast then Advanced expands (`:100-104`); the relay field has no label (`:342-347`); use `SettingsFieldLabel` + one line.
- Passphrase prompt (`:128-156`): Enter pops the UNTRIMMED value (`:139`), the button trims (`:148`); a passphrase should be trimmed by neither.
- F25: disclosures are 12 px caption text in a `GestureDetector` (`:318-337`, `:373-402`).
- Probe strings at risk: "Create New Identity" (`scripts/fleet.ps1`, `fleet_destroy.ps1`, `fleet_device_link.ps1`, `fleet_multidevice_dm_gap.ps1`), "Link a device" (same three + `test/widget/settings_devices_about_test.dart`), "Use a different profile" (`scripts/probe_scenarios/welcome_47.json`), "Decrypt" (`fleet_channel_file_catchup.ps1`, `fleet_file_card_states.ps1`, `fleet_relay_restart.ps1`).

Device link (the Welcome path's second half):
- C13: `acceptPush`/`declinePush` unawaited with no catch (`:376-378`, `:386-390`); "Send data" can strand on "Sending your data".
- D15/D22: Material `LinearProgressIndicator`, `circular(99)`, `minHeight: 8` (`:417-425`); use `HollowProgressBar` (determinate) and a spinner (waiting/importing).
- E24: code field has no `onSubmitted` (`:282-291`); Link under 6 characters silently no-ops (`:314-322`).
- C11: showing-side failed view ends in a lone ghost "Close" (`:549-555`).
- B8: "Include vault shard data" (`:338`) is jargon.
- D17: the code well (`:228-243`) is acceptable as a focal code block; share one component with the verify number well.
- Probe strings at risk: "Link this device", "Send data" (`fleet_destroy.ps1`, `fleet_device_link.ps1`, `fleet_multidevice_dm_gap.ps1`), "Include vault shard" (`test/widget/security_page_test.dart`).
