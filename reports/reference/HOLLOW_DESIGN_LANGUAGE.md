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
3. **One colour, one meaning.** The accent means interactive or primary. It never tints a card, never glows, never lands on a heading. Never colour alone: pair it with shape, text or an icon. A chart or split bar takes `hollow.categorical` in fixed order (blue, orange, aqua, then a neutral), never the accent or a semantic colour, and always beside a labelled legend.
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

**Shadows.** Only on `overlay` things and small: `blurRadius` at most 12, and the one shadow is `HollowShadows.float`. A shadow is never a substitute for a surface step, and never appears on a card or a row.

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

**People's names in a chat** take their own colour, `nameColorFor(master, hollow)` (`core/color_utils.dart`): a stable hash of the MASTER identity (the same on every platform, the web included) onto the whole hue circle, skipping 35 degrees either side of the accent, at the tone that clears 7:1 on every dark surface and 5:1 on every light one. Your own name is `accentText`, so the accent is you and nobody else is. Only in the conversation itself (message rows, reply lines, search results, pinned lists); panels and lists of people (the member panel, the friends strip, Home) stay neutral, because that is where people are named, not told apart.

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
| `bodyTouch` | 16 | 400 | Message text and sheet rows on a phone, one step up from `body` (5.4). |
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

`HollowDurations`, `HollowCurves` and `HollowMotion` in `lib/src/ui/animations/hollow_curves.dart`. Set in the animation pass (2026-09-24):

| Token | Duration | Use |
|---|---|---|
| `exit` | 100 ms | Something leaving: a popover, a menu, a tooltip. Also the press itself. |
| `fast` | 150 ms | Popover and menu entrance, press release, hover colour, toggles, collapses. |
| `normal` | 250 ms | Dialogs, toasts, notification cards, sheets, pushed pages. |
| `slow` | 400 ms | Progress bars filling. Nothing a person waits on. |

Curves: `HollowCurves.enter` (ease-out-cubic) brings something in, `subtle` (ease-in-out) moves something already on screen, `exit` (ease-in-cubic) is the REVERSE curve of an enter/exit pair (a reverse curve runs on t going 1 to 0, so ease-in there reads as leaving quickly and settling). **Nothing overshoots:** there is no spring, elastic or bounce curve, and adding one is a review failure.

**What moves and what does not**
- **Switching what a region shows is instant:** a conversation, a channel, a server, a tab inside a panel or a phone tab. No cross-fade.
- **Side panels toggle instantly** (member panel, DM profile, channel sidebar, help). Animating a width re-wraps the chat text on every frame.
- **Only what arrives on top moves:** popovers, menus, dialogs, toasts, notification cards, sheets, pushed pages.
- Frequent actions animate nothing beyond the hover colour and the press: send, react, hover a message, open the hover bar.

**How things arrive**
- **Travel is 8 px (`HollowMotion.rise`), whatever the size.** A small popover or menu grows from its trigger at `HollowMotion.popoverScale` (0.96), scaled around the click point, never a screen corner. A big panel (the pickers, anything over about 300 px) does not scale, because 0.94 on 440 px moves the far corner 25 px and reads as a stretchy slide: it fades and rises 8 px toward its place instead (`PopupAnimator(rise: true)`). Toasts rise 8 px, notification cards step 8 px in from the edge, the incoming call card drops 8 px.
- **The one exception is a surface attached to a screen edge and dismissed by a gesture** (bottom sheets, pushed phone pages, the phone's top banner): it travels its full size, because the finger follows it back.
- Exits are quicker than entrances and play the same motion in reverse; a popover's barrier stops taking clicks the moment its exit starts.
- Dialogs scale from 0.96 at the centre over a flat scrim.
- Transform and opacity only.

**Rules that stay**
- **Hover never moves layout and never changes font weight.** Selection never animates a font weight either.
- **Never animate a colour from `Colors.transparent`** (it lerps through black): animate from the target colour at zero alpha.
- Read durations when the animation starts (`controller.duration = HollowDurations.fast` before `forward()`), never once in `initState`, so a live Reduce motion change reaches widgets already on screen. `HollowDurations.animationsDisabled` turns every token to zero.
- Reduce motion drops movement and keeps state: a toggle still flips, a spinner still spins, an error still shows (its shake does not). Only through `ReduceMotionController` and `hollowMobileRoute()`.
- A running `Ticker` requests a frame every vsync. Decorative motion is a `Timer` plus a `GatedNotifier`, never an `AnimationController`. See `feedback_ticker_is_a_frame_request`.
- The phone's pushed pages take an edge swipe back on iOS (Android's system gesture owns the edge there).

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

**Every tab row is chips** (decided 2026-09-25, Vitalik), in a dialog, a page or a place header: `HollowChipTabs<T>` (`tabs`, `selected`, `onSelected`; a quiet total in `hint`, something waiting on the person in `count`, a count badge; arrow keys, Home and End move the selection; `expand: true` for equal widths on a phone). No underline tab, no local `_Tab`. A label is `LabelChip` when it toggles and `LabelBadge` when it is worn, both led by the label's colour (`LabelSwatch`); `HollowDurationPicker` is the one "for how long" choice, a chip row whose null is "Until I remove it", never a red "Permanent".

A chip's label is always `Flexible` and ellipsizes. A row of equal-width sub-tabs (`expand: true` inside `Expanded`) divides the width between them, and at a large text scale the longest label has to give somewhere; without this it overflows its own chip.

### 4.2 Buttons

`HollowButton` is healthy: four variants, one raw constructor in the tree. What was missing is which variant goes where: 158 `.filled` uses against a rule of roughly one per screen. Sweep 9 (2026-09-19) brought it to 115, each the one commit of its screen, pane, dialog or sheet.

| Variant | Where | Limit |
|---|---|---|
| `filled` | **The one primary action of a region.** | At most one per visible region, and rarely more than one per screen. |
| `outline` | A secondary alternative standing beside that primary. | At most two, and only when a `filled` is present. |
| `ghost` | Everything else: toolbars, icon buttons, Cancel, secondary actions inside rows and cards. **Grey**: `textSecondary`, `textPrimary` on hover, a neutral hover fill. The accent is for the primary, selected chips, links and focus. | No limit. |
| `danger` | The final destructive confirmation. | Nothing else. A cautionary action is `outline` with `danger: true`. |

Consequences worth stating, because these are the observed inconsistencies:

- **An action row with no primary is all ghost.** A toolbar does not mix outline and ghost. Whether a button is outlined is never a per-site decision: it is outlined only when it stands next to a filled primary.
- **A row that exists FOR one action** (wear a frame, unlink a device, a member card's action) carries it as a compact `outline`; the row's other actions stay ghost icons.
- **The same holds for a card, a section or one field.** A Save beside one field, a section's own Save, Export backup in its card: a compact `outline` (or a full one where it spans the card). A settings page therefore has no filled button unless it has ONE commit for the whole page (Save profile, Save layout, Apply & restart, Link a device). Two actions with no primary (Export and Import) are both ghost.
- **Anything repeated per item is never filled**: an invite card's Join, a meeting row's Start meeting, a waiting-room Admit, a stream row's Watch, a version row's Install. A list of ten would be ten primaries. They are compact `outline`.
- **A selection is a chip, never a pair of buttons.** Three day counts where the chosen one is filled and the rest ghost is a `HollowChip` row.
- **The primary can move.** When a later state owns the commit (an update ready to install), the earlier primary (Check for updates) steps down to ghost in the same build: `HollowButton(variant: ...)`.
- A missing permission is the region's primary (Request permission filled); once granted, the test and settings actions stay ghost.
- Buttons in a row are `sm` 8 apart. Always.
- A **disabled** button goes neutral at full opacity (label `textTertiary`, a faint neutral fill for filled and danger, a `textTertiary` hairline for outline), never a faded accent; say why it is disabled next to it when the reason is not obvious.
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
| `HollowCountBadge` | 10 hand-drawn unread pills (5 on desktop replaced so far) | The unread counter. **Unread is the accent, a mention is `error` with an `@`**, so red keeps meaning "someone needs you". One size (16), `ring:` the surface it sits on when it overlaps an avatar or icon corner. Distinct from `HollowBadge`, which states a fact in a wash. |
| `ConversationRow` + `PresenceAvatar` | Home's hand-built row (the sidebar, mobile Chats and Archive rows follow in their passes) | The ONE conversation row (check 8 in 5.3): leading, title plus quiet detail (a channel's server), one-line preview, mono time, count badge. Unread is weight 600 and a `textPrimary` preview; read is 500 and `textSecondary`. |
| `HollowTextLink` | a ghost button used as a link under prose | Accent text on the text's own edge, underline on hover, `HollowFocusRing`. For a link inside running content only; a standalone action stays a button. |
| `ServerAvatar` | per-site server initials | A server's icon at list size: its image, else initials on its identity colour. |
| `HollowIconButton` | a pressable, a tooltip and an 18 px icon built at every site | The icon-only button: headers, panel strips, toolbars. `label` is the tooltip and the screen-reader name at once. A square `size` (32 on desktop, 44 on a phone, the composer's 44), the icon 20 at 32 and up, 16 below. `selected` is a toggle that is on (a panel shown), a `hover` fill, **never the accent**. Siblings sit `xs` 4 apart; a header never spreads them. `count` carries a short number (pinned messages) in mono. |

**Cards.** A card is a background step (`elevated`) and nothing else: no hairline, no shadow, in both themes. Cards do not nest. A coloured strip on a card edge is forbidden; status is a dot or a word. Anything repeated more than three times is a list of `HollowListRow`, not a grid of cards, unless the item **is** the art (the Shop, a gallery), in which case the art is the card: full bleed, title and price beneath it.

### 4.4 Dialogs

One route, one frame, one action rule.

- **Open** every modal with `showHollowDialog()`. Never `showDialog`, `showGeneralDialog`, `AlertDialog`, `SimpleDialog` or `Dialog(` (guarded; `showHollowMenu` is the one documented exception).
- **Frame.** `HollowDialogSurface` is the only frame: `overlay` fill, the hairline, a 12 px shadow, `radiusLg` on desktop and `radiusXl` on a phone, where it spans the screen minus 24. A standard dialog is `HollowDialog` (title, scrolling content, action row). A dialog whose layout is its own (a hero, a crop canvas, a two-pane window) puts that layout inside `HollowDialogSurface` directly (`padded: false` for content that runs to the edge). A dialog never draws its own `Container` with a radius, fill, border or shadow, and never tints its frame (no red border on an error dialog: the danger button and the copy say it).
- **Behind it.** The flat `scrim` token (65% black on dark, 32% on light), shared with `showHollowSheet()`. **No backdrop blur** (decided 2026-09-19, Vitalik): the dimmed canvas against the `overlay` card is the depth step, the same everywhere, with or without Reduce Transparency.
- **Width.** Shrink-wrap between 300 and 600 by default; a form of fields takes `width: 420`; wider only for a real layout (the game card). Settings is not a dialog: it is a place (5.3.1).
- **Title.** `heading` in `textPrimary`, **sentence case** ("Leave server", "Crop banner", "Start a call?"). No icon beside it. A status belongs in the body, not a coloured glyph in the title row.
- **Body.** Prose is `HollowDialogText` (`body` in `textSecondary`); a field's label is `SettingsFieldLabel`; groups inside a big dialog are `HollowSectionHeader`.
- **Actions.** Trailing, 8 apart, primary LAST: ghost Cancel, then ONE `filled` confirm, or `danger` when the confirm destroys something (delete, leave, remove, wipe, revoke). `outline` only for a second alternative beside the filled. Ghost extras that are not the answer (Forgot password, Reset, Copy) go in `leadingActions`. A busy confirm is `loading: true`.
- **Close.** A dialog with a Cancel needs no X. A dialog with nothing to confirm (a viewer, a status, an info card) takes `showClose: true` (the ghost X at the title's edge, `HollowDialogCloseButton` in a custom layout) and no Done button; an acknowledgement the person must read (a recovery phrase, a warning) ends with ONE filled button instead ("I saved it", "Got it").
- **A yes-or-no question** is `showHollowConfirm()`, never a hand-built pair. A one-field name prompt is `promptForName()` (it owns its controller; `description`, `maxLength`, `validator`).
- **A confirm that runs an action runs it inside the dialog**: pass `onConfirm` (`onSubmit` for `promptForName`, `showHollowDurationDialog` for a length). The dialog stays open with the confirm loading and Cancel disabled, closes on success, and on a throw shows the reason inside it (a prompt's on its field, keeping the text) so the person can retry. A dialog of its own gets the same through `HollowDialogAction` plus `HollowDialog(busy:, error:)`. Never pop first and await after.
- **Errors people read** go through `friendlyError(e)` (`core/friendly_error.dart`): one sentence with a next step, the raw text to the log. A raw `$e` in a toast or dialog is guarded; throw `FriendlyException` for a specific sentence.
- **A value to copy** (a link, a code, an id) is `HollowCopyField`: the value in `textPrimary` on `elevated`, mono unless `mono: false`, a labelled copy button that toasts "Copied". It is the one legitimate well; never a card, never accent text.
- **On a phone** the action row and the close button grow to 44 on their own; a call site never passes `touch:` to a dialog's actions. A dialog that scrolls itself passes `scrollable: false`.
- Keyboard insets are handled by `showHollowDialog()`; a builder never pads by `viewInsets` itself.

### 4.5 Surfaces that already have one law

These are settled and stay settled: context menus through `showHollowMenu` opened by `ContextMenuTarget`, toasts through `HollowToast`, scrollbars through `HollowScrollBehavior` (one app-wide gutter, never a manual `Scrollbar`).

**The chat (session 12, 2026-09-24).** One of each, shared by DMs, channels, meetings, the archive, the guest view and the phone:

- **`MessageRow`** (`chat/message_row.dart`) is the one message row; `MessageBubble` and `ChannelMessageBubble` only adapt a model to it. Cozy: a 36 avatar, the name in its colour, the time in `monoSmall` at `textTertiary`; a grouped continuation shows its time in the avatar column on hover. Compact (`messageDisplayProvider`, Appearance): time, name and text on one line, no avatars. Your own rows carry no strip or tint: your name in the accent is the mark.
- **Hover** is painted by the row itself (`rowHover`, half a step from canvas to raised, so a card inside the row still stands out) and moves nothing. The action bar is an Overlay entry pinned to the row by a `LayerLink`, clipped to the list, straddling the row's top edge: three quick reactions, add reaction, reply, edit (yours), More. Everything else (copy, pin, proof, download, delete last) is the More menu, which is the right-click menu.
- **`ChatHeaderBar`**: one 48 px bar, the title in `subheading`, a subline for a status line, `HollowIconButton`s 4 apart at the right edge. **No status while healthy**: Encrypted and Synced are silent, Offline, "nobody else is here", syncing and a failed sync speak. A panel toggle that is on is a grey fill.
- **`ChatComposerRow`**: attach, the text field with ONE expression button inside it, then the microphone, which becomes Send (the row's one accent) once there is text or a staged file. 44 tall throughout. The field's focus is quiet (the composer always has it). The expression button opens one picker with Emoji, GIFs and Stickers tabs (`showExpressionPicker`, `showExpressionSheet` on a phone): an emoji inserts and closes, a GIF or sticker sends and stays open.
- **The DM side panel** (`DmProfilePanel`) sits on the right, built and sized like the member panel, sharing its width and seam: banner, avatar, name, an icon strip (nickname, mute, More), then About Me, Now Playing and Encryption (verify is the one action). Block and Report live in More.
- A text field shows focus with its accent border and nothing else: **no glow**, anywhere.

---

## 5. Screens

Sections 3 and 4 make the parts consistent. This section decides whether a screen built from those parts is any good. Tokens alone give a tidy screen that still has no point; most of what reads as amateur in a finished screen is a missing decision about what the screen is for. The checks below come from Apple's Human Interface Guidelines (clarity, deference, hierarchy, progressive disclosure), Nielsen Norman Group's research on scanning and states, and the research digest in the plan. Each one can be checked against a render.

### 5.1 The screen brief, before any widget

Every screen pass starts with four lines, written down and agreed before code:

1. **Job:** one sentence saying what a person comes to this screen to do. "Home is where I see what needs me and get back into my conversations." If it takes two sentences, the screen is two screens.
2. **Focal point:** the one element that wins. Everything else steps back in size, weight or tone.
3. **Primary action:** the one `filled` button, or "none" when the focal point is itself the action (a list you tap into).
4. **Left out:** what moves elsewhere, and where to. A screen improves more from what leaves it than from what is added.

### 5.2 Layout

- **One alignment edge.** Text and controls in a column share one left edge. Centred content is for empty states, the welcome screen and a dialog's hero art only; a centred profile block above left-aligned cards is two axes fighting.
- **An app pane is anchored to the window, not centred in it.** Every region of a screen runs to an edge of its pane: the main region takes the width, a side panel sits against the right edge at full height. Empty space belongs INSIDE a region (between groups, at the end of a list), never as gutters beside a centred block. A centred, max-width column is a web-page layout, and in a desktop app it reads as content floating in a hole (Home, 2026-09-23: a 720 px inbox and a rail centred together left about 120 px of dead band on each side of a 1280 window).
- **The one centred exception: a navigation rail and its page, as a pair.** A settings-style screen (a 240 rail plus a prose-width page column) keeps the page against the rail and, on a window wider than the pair, centres the PAIR, the rail's `surface` running out to the window's left edge and the page's scroll area to its right edge, so no region floats. Below the pair's width it simply hugs the left edge. Centring the page column alone is not allowed: it pulls the page away from the rail that opened it (Settings, 2026-09-24).
- **Max widths are for prose only:** a dialog body, a news post, a long description, 50 to 75 characters a line. Lists, grids and panes fill their region. When a wide row puts two related things far apart (a name and its time), move them together in the row; do not shrink the pane.
- **A main region plus at most one side panel.** Three regions of equal weight have no winner. The side panel holds secondary, glanceable things and never the screen's job. It is built like a server's member panel: `surface`, a hairline on its inner edge, 280 to 300 wide, full height. A navigation sidebar is 240.
- **Narrow widths drop the side panel, never squeeze it.** Below the width where the main region stops being readable (Home: 840 px of pane), the panel leaves or folds into the main region; nothing overflows.
- **Even proportions: move whole, never squeeze one side.** When chrome floats over a surface (the window controls over a full-window route, a notch, a docked bar), the row it would cover moves clear of it AS A WHOLE, usually down by the chrome's height (`windowChromeTop()`), keeping the same margin on every side and its pieces level with each other. Shifting only the end that collides leaves a lopsided row, one side hugging the edge and the other pulled in (the media viewer's bar under the window controls, 2026-09-25, Vitalik: "making it weird is not the best option"). Margins that face each other match: left equals right, top equals the gap between siblings.
- **Proximity carries the grouping** (the gap ramp in 3.5): items inside a group 4 to 8 apart, rows 4 to 12, groups 24 to 32. A line only where spacing cannot do it.

### 5.2.1 A mockup is not the screen

A web mockup is a fixed-size artboard: whatever sits inside it looks composed because the artboard's own edge frames it. The real screen is a resizable pane inside the app's chrome, from roughly 800 px (a small window, or 200% zoom) to 2500 px wide, and nothing frames it but the window. So a mockup decides **what** is on a screen and **which region wins**; it never decides widths, gutters or centring. Before a layout is built, answer for the real pane: what touches each edge, what grows when the window grows, and what leaves when it shrinks. Then judge the build in the running app at two or three widths, not against the artboard.

### 5.3 The checks

A screen is done when every one of these holds on a render, desktop and mobile, dark and light.

1. **Squint test.** Blur the screenshot. The focal point from the brief is what you see first. If three things tie, it fails.
2. **Nothing appears twice.** The same person, count or identity shown in two places on one screen weakens both. Your own name belongs in the user bar, not also in a profile column beside it.
3. **Status by exception, identity by design.** Healthy state is silent. Connection, sync and relay figures appear when they deviate, next to what they affect, and the full numbers live in System Status. A figure that only an operator can read (message totals, peer ids) is not on a person's screen. The exception is what makes Hollow itself: the relay a person lives on, named in the console voice with its live load, belongs on Home, because members host this network and a slow evening should have a visible reason. Personality comes from the product's own nature (the relay, the greeting), never from filler panels.
4. **Progressive disclosure.** The common case on the surface, the rest one step away (a menu, a detail pane, a settings page). Deprioritise before deleting (principle 5).
5. **Destructive actions rest out of reach.** Block, Report, Leave, Delete and Wipe live in an overflow menu or a final Danger section, never at rest beside the primary action, and never in red on a surface a person passes every day.
6. **The accent marks what you can act on.** Not a heading, not a name, not a decoration. A name painted in the accent reads as a link.
7. **Icons earn their place.** An icon stands for a control or tells two kinds of item apart. An icon on every row of a settings page, or beside every label, is noise.
8. **One row per kind of thing.** A conversation row, a person row and a settings row each look the same on every screen that shows one (Home, sidebar, mobile Chats, Archive). A second hand-built version of the same row is a bug.
9. **Every region has a clear next step.** An empty region says what fills it and offers the one action that does (section 6). A first run is a designed screen, not the populated screen with nothing in it.
10. **Numbers and dates are honest.** A numeric date is ambiguous across locales ("9/17" is American only), so list times go through `conversationTimeLabel()` (`core/time_labels.dart`): `14:05` today, Yesterday, a weekday within the week, `Sep 17`, then `Sep 17, 2025`. A status line's age ("Last checked 3 hours ago") goes through `relativeTimeLabel()` beside it. Changing numbers use tabular figures. A written date or a day name ("Sep 14", "Sat", "September 10, 2026") is words, so it takes the interface face at `textTertiary`; the console voice is for what the protocol produces (ids, hashes, versions, relay names).
11. **Reading width.** A block of prose runs 50 to 75 characters a line.
12. **Targets.** Desktop controls at least 28 px tall with the whole row as the hit area; touch targets at least 44 px (iOS) or 48 px (Android), whatever the painted size. A phone's text button takes `HollowButton(touch: true)` (44 tall); desktop leaves it off.
13. **Keyboard.** Every action reachable by keyboard, Escape leaves the innermost layer, focus is visible through `HollowFocusRing`.
14. **Five states.** Loaded, empty, loading, error, offline (section 6), each rendered once before the screen is called done.

### 5.3.1 Chrome: the header and the dock

The desktop Dock layout's two strips are chrome: they recede so the canvas wins, carry no focal point and no `filled` button.

- **The header holds people:** add friend (a request count in the accent, never red), then the friend chips in a stable name order (favourites in their drag order, then anyone unread, then "+N more"). Unread lifts a name's colour and adds a count after it; it never changes the weight.
- **The dock holds you, where you are, and tools.** Left: your identity with its connection dot and one line of status by exception (a link problem, the voice room you are in, your own status line), then mute, deafen and leave while in a call, on every screen. Middle: Home (the Hollow mark), your servers anchored straight after it, Add at the end of the list. Right: the places, then the tools, then the Settings gear.
- **Places swap the centre; tools open on top of it.** Places are the `ShellTab`s (Conferences, Public channels, Share, Archive, the Shop, Settings), exclusive through `setShellTab()`, each toggling back to what it covered; a narrow dock folds them into one Places menu. **Settings is a place with its own door:** the gear (and Ctrl+,) opens it through `openSettings()`, the gear carries its selection mark, it never folds into the Places menu, and unlike the other places it keeps the selection underneath, so closing it (gear, Escape, the X) returns to the conversation it covered. Tools (Downloads, Help) never take the centre.
- **ONE selection mark:** a 2 px x 20 accent bar on the bar's edge facing the content, over whichever of Home, a server, a folder or a place is active (a DM counts as Home), placed instantly. `NavSelectionMark` serves the phone's tab bar and the dock. Hover is a surface step and nothing else: no bar, no accent.
- **The title bar folds into the header in Dock mode.** The window controls float over the header's trailing end at OS size (outside the zoom), the empty middle drags the window, and macOS centres its traffic lights in the header. Classic, the welcome screens (no identity yet) and the lock cover keep the 32 px title bar; while a dialog or menu covers the dock, a drag strip over the header keeps the window movable.

### 5.4 Platform metrics

- **Desktop:** body 14, list rows 32 to 36 for one line and 48 to 56 for two, message rows grouped by sender with the timestamp in mono at `textTertiary`.
- **Mobile:** body one step up, rows 48 and above (64 to 72 for a two-line conversation row), controls in the thumb zone, a large title at the top of a tab. Parity is checked per screen, in the same change, not at the end.
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
| 14 | `showDialog` / `showGeneralDialog` / `AlertDialog` / `SimpleDialog` / `Dialog(` | outside `components/` |
| 15 | A hand-drawn dialog frame (`color: hollow.overlay` in a file that opens a dialog) | outside `components/` |
| 16 | Two `HollowButton.filled` in one list literal (a `children:` or `actions:` row); the else of a condition does not count | outside `components/` |

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
