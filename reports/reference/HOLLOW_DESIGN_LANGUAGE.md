# The Hollow design language, version 1

**Status:** LIVE. This document is the rule set. When it and the code disagree, the code is wrong.
**Written:** 2026-09-18, from `reports/planned/ui-and-accessibility/HOLLOW_DESIGN_LANGUAGE_PLAN.md` section 3, with every number re-measured against the tree on the same day.
**Enforced by:** the `hollow-ui` skill (loaded before any widget work) and `test/design_language_guard_test.dart` (a source-scan ratchet).
**Owner:** Vitalik. Every debatable visual choice is decided by a render, never by a paragraph.

---

## 0. What this document is for

Hollow's layout is its own and is not in question: Dock mode, the server strip at the bottom, pinned friends in the header. What makes the app read as generated is everything inside that layout, and the cause is not taste. It is that nothing ever told the person or the agent writing a screen which chip to use, which button variant a toolbar takes, or how wide the gap between two buttons is. So each screen invented its own answer, 46 times for chips alone.

This document is that missing answer. It is written to be checkable: every rule is either mechanically guarded or stated precisely enough that a reviewer can point at a line and say it breaks rule 4.2.

Three things it is not. It is not a redesign: the layout, the providers and the behaviour stay. It is not minimalism: Hollow is dense and intentional, character over chrome. It is not a style copied from anywhere: Apple's HIG, Material 3 and Fluent 2 are checklists and sources of principle, never the look.

---

## 1. Principles

These decide the cases the rules do not cover.

1. **Content first, chrome recedes.** Messages get the brightest surface. Dock, sidebar and title bar sit below it.
2. **Hierarchy by lightness and weight, not by size, borders or shadows.** Two to three text colours, two weights, in any one view.
3. **One colour, one meaning.** The accent means interactive or primary. It never tints a card, never glows, never lands on a heading. Never colour alone: pair it with shape, text or an icon.
4. **Separation by tone and spacing before lines.** A border only where the boundary is genuinely ambiguous.
5. **Deprioritise instead of deleting.** Smaller and quieter, still visible. Simplicity is not the absence of things.
6. **Familiarity over novelty.** Do not rebrand a known pattern. A menu looks like a menu.
7. **One visual winner per screen.** Decide the most important thing; everything else steps back.
8. **Every action visibly succeeds, fails or shows busy.** Every list has its empty, loading and error state designed.
9. **Delight through craft, not decoration.** Motion on rare moments. Nothing animates that a person sees a hundred times a day.
10. **Same tokens, different density per platform.** Pointer, hover and shortcuts on desktop; thumb zone and 44 to 48 targets on mobile.
11. **Opinionated defaults over settings.** The same person should look like they made every screen.

---

## 2. Identity

Three signature elements, and nothing else is a signature.

1. **The Dock.** The bottom server strip and the pinned-friends header. This document polishes it and never redesigns it.
2. **The console voice.** A mono face for the things the protocol produces: identities, hashes, safety numbers, relay names, versions, timestamps, counters. Used on purpose, never for body copy. This is the one place the app is allowed to look like the protocol it runs.
3. **One accent, sparingly.** Teal `0xFF00BFA6`, with the user's hue variants, on interactive and primary elements only.

Holly, the mascot, arrives when the art exists. She will appear in moments (empty states, onboarding, errors, the Shop) and never in chrome. Until then there is no placeholder: `HollowEmptyState` leaves a slot and ships without her.

---

## 3. Tokens

The token files are `lib/src/theme/`. **Nothing outside that directory may define a colour, a size, a radius, a duration or a letter-spacing.**

### 3.1 Surfaces

Five colour-only levels per theme, in `lib/src/theme/surface_ladder.dart`, plus one hairline `border` at 8 percent. Chosen by eye on 2026-09-18.

| Token | Level | Dark | Light | Carries |
|---|---|---|---|---|
| `surface` | chrome | `0B0C10` | `F1F2F4` | The persistent frame: title bar, dock, friends header, server strip, sidebars, member panel, home side columns, the Settings rail. Full bleed, no radius. **One step below the canvas**, so content is the brightest thing on screen. |
| `background` | canvas | `111318` | `FFFFFF` | The content: chat, the main pane of any screen. |
| `elevated` | raised | `181A20` | `F5F6F8` | Cards, boxed sections, settings cards, inputs, tiles, and the hover fill of a control on the canvas. |
| `overlay` | floating | `1E2127` | `FFFFFF` | Everything above the app: menus, popovers, pickers, dialogs, sheets, toasts, tooltips, hover cards. Opaque, never glass. |
| `hover` | state | `262930` | `EBEDF0` | The hover fill of a row inside an `overlay`. |
| `border` | | 8% white | 8% black | The one hairline. One weight, one colour, no second border token. |

A card painted `surface` is a bug: with chrome below the canvas it reads as a hole. `opaqueSurface` and `opaqueBackground` are the same tokens at full alpha, for bars that stay solid over a wallpaper.

**Shadows.** Only on `overlay` things and small: `blurRadius` at most 12. A shadow is never a substitute for a surface step, and never appears on a card or a row.

**Ambient background.** Flat by default. The drifting blobs are an opt-in in Appearance (`ambientBackgroundProvider`) and stay off under reduce motion.

### 3.2 Text

Exactly three tiers, plus the accent pair. There is no fourth tier and no ad hoc alpha on text.

| Token | Use |
|---|---|
| `textPrimary` | Body and headings. Off-white, never pure white. |
| `textSecondary` | Supporting text, inactive labels. |
| `textTertiary` | Faded metadata: timestamps, "(edited)", counters. Guarded at 4.5:1. |
| `accentText` | The accent as a foreground. The only accent text colour there is. Raw `accent` is for fills. |
| `textOnAccent` | Text on an accent fill. |
| `textOnError` | Text on a solid error fill (the danger button). |

Every foreground token is validated against **all five** surfaces (`Contrast.ensureContrastOnAll`), because text on a hovered row or inside a menu sits on the worst of them. `test/contrast_test.dart` loops all five.

Fading text with `withOpacity` or `withValues(alpha:)` is forbidden. It was how `textTertiary` used to fail contrast at roughly 2:1. Pick a tier.

### 3.3 Type

**Onest** for the interface and **Geist Mono** for the console voice, bundled as static instances (`assets/fonts/`, 400/500/600 and 400/500), so the app reads the same on every OS and no weight is ever synthesised. ThemeData carries the family, so a raw `TextStyle` inherits it.

One role per size. Sizes are pinned to what the app already renders. The UI stays at today's sizes; message text defaults to 14 (still scaled by `ChatTextScale`).

Skia on Windows draws light text on a dark ground about 1.4 px heavier than dark text on light (measured stems at 600: 3.7 px against 2.3 px). The weights are right; the light theme simply reads a step thinner. If that needs correcting, the light roles go one weight up, never a size.

| Role | Size | Weight | Use |
|---|---|---|---|
| `display` | 28 | 600 | Welcome, the largest empty states. Rare. |
| `heading` | 20 | 600 | Screen title. |
| `subheading` | 16 | 600 | Section title. |
| `body` | 14 | 400 | Message text, prose, dialog body. |
| `label` | 13 | 500 | Control labels, list row titles, buttons. |
| `bodySmall` | 12 | 400 | Secondary row text, descriptions. |
| `caption` | 11 | 400 | Metadata, hints. |
| `micro` | 10 | 500 | Badge text, counters, the tightest chrome. |
| `mono` | 13 | 400 | The console voice at body size. |
| `monoSmall` | 11 | 400 | The console voice in metadata. |

Rules:

- **`fontSize:` is forbidden outside `lib/src/theme/`.** A size that has no role is not a new literal, it is a conversation. Below 10 there is no role on purpose: 9 and 8 fail the legibility floor, and every site using them is removed (decided).
- Weight and colour may be adjusted with `copyWith(fontWeight:)` and `copyWith(color:)`. Size may not.
- Weights are 400, 500 and 600. Nothing else ships.
- No half steps, ever. There is no 12.5.
- **Tabular numerals** wherever a number changes in place: timestamps, counts, sizes, stats, durations.

### 3.4 Case and copy

- **Sentence case everywhere.** Title Case only for card and section titles, permission names, doc titles and proper nouns.
- **No `toUpperCase()` on a label, and no tracked caps.** The all-caps eyebrow label is the single most recognisable generated-UI tell. Hierarchy comes from weight and colour. Guarded at 0 since sweep 3c: a `toUpperCase()` on data (avatar initials, a typed code, a hex fingerprint) carries a `design-ignore` reason.
- `letterSpacing:` is forbidden outside the theme, guarded at 0. Mono codes and safety numbers read fine untracked.
- No em dashes in any user-visible string. Never a colon in place of one: write the sentence naturally.
- Anything longer than a label goes through the `sepia` skill before Vitalik reads it.

### 3.5 Spacing

`HollowSpacing`: 2, 4, 8, 12, 16, 24, 32, 48. Numeric `EdgeInsets` and `SizedBox` gaps are forbidden outside the theme.

The scale of the problem is not padding, it is **gaps**, which is why two tabs never look alike. Today the gap between two adjacent controls is written as 2, 3, 4, 5, 6, 8, 12 and more, chosen per site. One ramp, no exceptions:

| Distance | Value | Between |
|---|---|---|
| Glued | `xs` 4 | An icon and its label, inside one control. |
| Adjacent | `sm` 8 | Two buttons in the same action row, two chips in a group. |
| Grouped | `md` 12 | Fields in a form, rows in a dense list. |
| Separated | `lg` 16 | Two groups inside one section. |
| Sectioned | `xl` 24 | Two sections. |
| Major | `xxl` 32 | Above a screen title, below a screen's last section. |

Padding: inside a control 4 to 8, inside a container 12 to 16, above and below a section 24 to 32. Tight inside a group, generous between groups. Perfectly even spacing everywhere is itself a tell.

### 3.6 Radius

`hollow.radiusXs` 4, `radiusMd` 8, `radiusLg` 12, `radiusXl` 16, and `HollowRadius.pill` 999. There is no 6: it was removed on 2026-09-18, every control moving to 8 and every chip, badge or keycap to 4. A radius nested inside another is the smaller stop (a segment inside a segmented control is 4 inside 8).

| Stop | Applies to |
|---|---|
| `radiusXs` 4 | Badges, chips, keycaps, the smallest controls. |
| `radiusMd` 8 | Buttons, inputs, menus, popovers, tooltips, list rows with a hover fill. |
| `radiusLg` 12 | Cards, dialogs, panels. |
| `radiusXl` 16 | Sheets and mobile dialogs. |
| `pill` | Avatars, status dots, the unread jump pill. Nothing else. |

**A primary button is never a pill.** A pill radius on a rectangular control is a tell.

One exposure path: **`hollow.radiusX`, read from the theme.** `HollowRadius.*` exists for const contexts inside the theme only; do not add new uses of it in `lib/src/ui`. `BorderRadius.circular(<number>)` is forbidden outside the theme.

### 3.7 Icons

Lucide (`lucide_icons_flutter`), plus `brand_icons.dart` and `atlas_icons`. Sizes **14, 16, 20, 24 only**. Stroke 1.75 at 20, 2 at 16.

- An icon is used when it carries meaning, never as decoration.
- **No icon beside a heading.** The icon-in-a-tinted-box beside every list item is forbidden outright.
- No emoji as a bullet or an icon.
- Icon-only controls carry a `semanticLabel` and a tooltip. Both are already CI-guarded.

### 3.8 Motion

`HollowDurations` and `HollowCurves` in `lib/src/ui/animations/hollow_curves.dart`. These are today's values, kept as they are so nothing moves differently than it does now:

| Token | Duration | Use |
|---|---|---|
| `fast` | 150 ms | Press, hover colour, state layers. |
| `normal` | 250 ms | Tooltip, dropdown, chip, toast, popover. |
| `slow` | 400 ms | Route and sheet transitions. |

Curves: `HollowCurves.enter` (ease-out-cubic) brings something in, `subtle` (ease-in-out) moves something already on screen, `exit` (ease-in-cubic) takes something away, `spring` is the press release only.

`HollowDurations.animationsDisabled` turns every token to zero, which is how reduce motion reaches widgets that never go through a route.

- Transform and opacity only. Enter from scale 0.96 plus a fade, never from zero.
- Popovers scale from their trigger, dialogs from centre.
- **Hover never moves layout and never changes font weight.** No bounce, ever.
- Things done a hundred times a day (send, switch channel, open a menu) animate nothing beyond the 120 ms colour.
- Reduce motion keeps fades and drops the rest, only through `ReduceMotionController` and `hollowMobileRoute()`.
- A running `Ticker` requests a frame every vsync. Decorative motion is a `Timer` plus a `GatedNotifier`, never an `AnimationController`. See `feedback_ticker_is_a_frame_request`.

### 3.9 State layers

Hover, pressed, selected and focus are alphas over the surface below, luminance-aware (`_hoverLift` already does this).

- **Never animate a colour from `Colors.transparent`.** It lerps through black. Pass `backgroundColor: null`.
- Hover never paints outside its control.
- Hover belongs to the **row**, not to the artwork inside it.
- Selection is a chip state (accent-muted fill, accent text), never a filled button.
- The keyboard focus ring is `HollowFocusRing` and appears on keyboard or assistive focus only, never on hover or press.

---

## 4. Components

Every UI primitive lives in `lib/src/ui/components/`. A `Chip`, `Pill`, `Tag` or `Badge` class defined anywhere else is a bug.

### 4.1 The two labels

The 46 chip, pill, tag and badge classes plus 17 builder functions collapse into exactly two components. The distinction is **interactivity**, not shape. Pill and tag are shapes and words, not components.

| | `HollowBadge` | `HollowChip` |
|---|---|---|
| Purpose | States a fact | Takes an action |
| Interactive | Never | Always |
| Examples | Kind, count, status, NSFW, device role, owned | Filter, sub-tab, selection, removable, access level |
| Kinds | neutral, accent, success, warning, error, mono | default plus a selected state |
| Selected | n/a | Accent-muted fill, `accentText` text, accent edge at half strength |
| Radius | `radiusXs` | `radiusXs` |
| Type | `micro` or `caption` | `label`, one size, weight unchanged by selection |

If it is clickable it is a chip. If it is not, it is a badge. There is no third option and no local variant.

Optional slots, the same on every chip: `icon` (an `IconData` at 14) or `leading` (any glyph, such as a platform logo, sized 14 by the caller); `hint`, quiet `textTertiary` text after the label for the one fact that tells two choices apart; `trailingIcon`, a chevron when the chip opens a menu or an arrow when it leaves the app. A badge takes `icon` or `leading` too. A chip that opens a menu opens `showHollowMenu`, never a Material `PopupMenuButton`: `settings/channel_access_pickers.dart` is the pattern. A trigger at the trailing edge of its panel passes `alignEnd: true` with an anchor at its bottom-right, so the menu opens under it instead of across the next panel. An add action beside a scrolling row of chips sits outside the scroller, so it never scrolls out of reach. A key combination is `HollowKeyCombo`, one mono badge per key.

A chip's label is always `Flexible` and ellipsizes. A row of equal-width sub-tabs (`expand: true` inside `Expanded`) divides the width between them, and at a large text scale the longest label has to give somewhere; without this it overflows its own chip.

### 4.2 Buttons

`HollowButton` is healthy: four variants, one raw constructor in the tree. What was missing is which variant goes where, and it shows: 158 `.filled` uses against a rule of roughly one per screen.

| Variant | Where | Limit |
|---|---|---|
| `filled` | **The one primary action of a region.** | At most one per visible region, and rarely more than one per screen. |
| `outline` | A secondary alternative standing beside that primary. | At most two, and only when a `filled` is present. |
| `ghost` | Everything else: toolbars, icon buttons, Cancel, secondary actions inside rows and cards. **Grey**: `textSecondary`, `textPrimary` on hover, a neutral hover fill. The accent is for the primary, selected chips, links and focus. | No limit. |
| `danger` | The final destructive confirmation. | Nothing else. A cautionary action is `outline` with `danger: true`. |

Consequences worth stating, because these are the observed inconsistencies:

- **An action row with no primary is all ghost.** A toolbar does not mix outline and ghost. Whether a button is outlined is never a per-site decision: it is outlined only when it stands next to a filled primary.
- **A row that exists FOR one action** (wear a frame, unlink a device, a member card's action) carries it as a compact `outline`; the row's other actions stay ghost icons.
- Buttons in a row are `sm` 8 apart. Always.
- While a request runs the button shows **loading, not disabled** (`HollowButton(loading: true)`: same width, same colours, a spinner in the variant foreground, presses ignored), and the success toast fires after the await.
- An icon-only button carries a tooltip and a `semanticLabel`.

### 4.3 The rest

| Component | Replaces | Rule |
|---|---|---|
| `HollowSectionHeader` | every private section label (guarded at 0) | Title in `subheading` (a page section, a `SettingsCard` title) or `label` via `dense` (a sub-group, a list group). Optional trailing action, optional count in mono. Carries its own 8 px bottom gap. **No leading icon.** The label above ONE settings field is `SettingsFieldLabel`, not a header. |
| `HollowEmptyState` | 3 helpers and roughly 60 inline columns | One honest line about what is true now, one optional second line, at most one action. Optional glyph at 24. A slot for Holly, empty for now. A pane takes the default (centred); a list inside a card or a section takes `dense: true` (start-aligned, `bodySmall`, no glyph). |
| `HollowDivider` | every inline `Divider(` (guarded at 0) | The hairline. Nothing else. No colour parameter. |
| `HollowListRow` | ad hoc rows | Leading, title, subtitle, trailing. Hover on the whole row, no dead zone between rows. |
| `HollowSkeleton` | none | Keeps the final geometry. Used only for 2 to 10 second loads. |
| `HollowSpinner` | 127 raw `CircularProgressIndicator`s at six sizes (guarded) | Three sizes on the icon ramp: small 14 (a row, a button), medium 20 (a card or section), large 32 (a pane). `textSecondary` by default: a spinner reports a state, it is not an action, so it never takes the accent. Optional `value` for a determinate ring. |
| `HollowSlider` | about 30 Material `Slider`s under 8 hand-rolled themes (guarded) | One geometry (3 px track, 6 px thumb, 12 px press halo), the accent fill, `border` for the rest, no tick marks, the drag label on the `overlay` surface. `onMedia: true` over video or a scrim; `halo: false` in a tight box; `activeColor` only when the value IS a picked colour (the annotation pen). The hue picker keeps its own rainbow track with a `design-ignore`. |
| `HollowToggle` | 13 Material `Switch`es on mobile (guarded, with `Checkbox` and `Radio`) | The one on/off control, 36 x 20 on every platform. On a touch platform the hit area grows to 48 x 48 while the painted switch stays put. Always pass `semanticLabel` (the row's title). A choice among a few options is a row of `HollowChip`, never radios. |
| `showHollowSheet()` + `HollowSheetHandle` | 29 hand-styled `showModalBottomSheet`s, each drawing its own handle (guarded) | `overlay` surface, `radiusXl` on the top corners, one handle with 8 px above and below. `scrollControlled` for tall content; a `DraggableScrollableSheet` passes `handle: false` and places the handle itself. |
| `HollowCard` | itself | Only for a repeatable self-contained unit: a listing, a device, a news item. A settings group is not a card. A section is not a card. |

**Cards.** A card is a background step (`elevated`) and nothing else: no hairline, no shadow, in both themes. Cards do not nest. A coloured strip on a card edge is forbidden; status is a dot or a word. Anything repeated more than three times is a list of `HollowListRow`, not a grid of cards, unless the item **is** the art (the Shop, a gallery), in which case the art is the card: full bleed, title and price beneath it.

### 4.4 Surfaces that already have one law

These are settled and stay settled: dialogs through `showHollowDialog()` (ghost Cancel, filled confirm, danger only when destructive), context menus through `showHollowMenu` opened by `ContextMenuTarget`, toasts through `HollowToast`, scrollbars through `HollowScrollBehavior` (one app-wide gutter, never a manual `Scrollbar`).

---

## 5. Screens

- **Desktop:** body 14, list rows 32 to 36, message rows grouped by sender with the timestamp in mono at `textTertiary`.
- **Mobile:** body one step up, rows 48 and above, controls in the thumb zone. Parity is checked per screen, in the same change, not at the end.
- The chat surface is the brightest thing on screen.
- **The window's outer 8 px are pointer-dead** (frameless resize border). Controls hugging an edge inset by `kWindowEdgeDeadStrip`.
- Interface scale is one root scaled viewport. Window coordinates are not overlay coordinates: anchor with `overlayAnchorOf` and `overlayPositionOf`, never bare `localToGlobal`.

---

## 6. States

Nothing for under a second. A skeleton for 2 to 10 seconds, keeping the final geometry. A progress bar over 10 seconds. Uploads and transfers get progress, never skeletons.

**Empty:** say what is true now, teach what will fill the space, offer at most one action. **Error:** sit next to the trigger, name the cause, suggest a fix that exists, keep the person's input. No blame words, no jokes. **Offline and locked** are designed states too, not a blank pane.

Every list and every surface owes five answers: what shows in the first second, at three seconds, on failure, when empty, and when offline.

---

## 7. The forbidden list

Guarded by `test/design_language_guard_test.dart`. Each rule carries a **baseline count** which may fall and may never rise. New violations fail CI on the first one.

| # | Rule | Scope |
|---|---|---|
| 1 | `fontSize:` | outside `lib/src/theme/` |
| 2 | `Colors.<anything>` except `Colors.transparent` | outside the theme |
| 3 | `Color(0x...)` | outside the theme |
| 4 | `BorderRadius.circular(<number>)` | outside the theme |
| 5 | `letterSpacing:` | outside the theme |
| 6 | `toUpperCase()` on a label | `lib/src/ui` |
| 7 | `Divider(` | outside `components/` |
| 8 | A `Chip` / `Pill` / `Tag` / `Badge` class | outside `components/` |
| 9 | Numeric `EdgeInsets.*` and `SizedBox` gaps | outside the theme |
| 10 | `LinearGradient` / `RadialGradient` / `SweepGradient` | outside the theme's ambient background and the annotation overlay |
| 11 | `BoxShadow` with `blurRadius` above 12 | anywhere |
| 12 | Raw `Material(` | outside `components/` and the documented overlay hosts |
| 13 | Material `Slider` / `RangeSlider`; Material or Cupertino `Switch` / `Checkbox` / `Radio` | outside `hollow_slider.dart` |

Already law and unchanged: purpose labels on icon-only controls, `HollowFocusRing`, `showHollowMenu`, `setShellTab`, the hover rules, `Colors.transparent` never animated, the `accentText` and `textTertiary` contrast checks, `reversedChatList()`, one mutation path per state.

An exemption is `// design-ignore: <reason>` on the offending line. It is for a genuine one-off (a brand asset's exact colour, a platform-mandated metric), not for "I did not want to add a token".

---

## 8. How this is kept

- **This document** is the rule set, regenerated when a decision changes.
- **The `hollow-ui` skill** (`.claude/skills/hollow-ui/`) is loaded before any widget work, the way `sepia` gates copy. It carries the checklist and the component table.
- **The guard test** is the ratchet. Its baselines shrink as sweeps land.
- **The proof is a screenshot.** UI is verified by driving the app through `scripts/ui_probe.ps1`, never by reading the source. An agent reads its own PNGs and fixes what looks wrong before reporting done.
- **The design sheet** is `integration_test/probe/design_gallery.dart`, every primitive in every state with dark beside light, rendered by `scripts/ui_probe.ps1 -Widget design-gallery`. It needs no data directory, no identity and no relay, so a token edit can be judged by eye in the time it takes to rebuild. This is what the planned phase-0 toggle route became: instead of a route carrying typeface and surface switches, the tokens are edited in `lib/src/theme/` and this page is re-shot, which covers every screen rather than three.

---

## 9. Decisions

Taken by Vitalik on 2026-09-18, from recommendations and then from the rendered decision sheet. The rest of this document already reflects them.

| # | Decision | State |
|---|---|---|
| 1 | Ghost buttons grey | Applied |
| 2 | Onest + Geist Mono | Applied |
| 3 | Compact outline for a row's one action | Applied where it exists today (owned art Wear and Redeem, blocked users Unblock); new rows follow the rule |
| 4 | Five surface levels, chrome below the canvas (ladder A / L1) | Applied, with the role sweep across every site |
| 5 | Ambient background flat by default, opt-in in Appearance | Applied |
| 6 | Cards fill only, both themes | Applied |
| 7 | UI sizes unchanged, message text 14, no 8 or 9 px anywhere | Applied (message text was already `body` 14) |
| 8 | Compact message display, opt-in | After the chat screen work |
| 9 | Shop cards at each kind's own shape | With the Shop screen work |
| 10 | Light theme in the same pass as dark | Standing rule |
| 11 | `display` at 600 | Applied |
| 12 | Danger label is a token (`textOnError`) | Applied |
| 13 | The 6 px radius stop goes | Applied; the token is deleted |
| 14 | User GIF lists and sticker packs as one dropdown chip in the pickers | Applied (`PickerListDropdown` in `gif_picker.dart`; right-click or long-press on it acts on the list shown) |
