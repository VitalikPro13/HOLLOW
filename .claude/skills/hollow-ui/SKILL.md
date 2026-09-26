---
name: hollow-ui
description: "Hollow's design language as a working checklist: type roles, surfaces, spacing and gap ramp, radius stops, the two label components (HollowBadge / HollowChip), the button-variant rule, motion and state layers, the forbidden list, and the screenshot proof step. Load BEFORE writing or editing any widget in lib/src/ui or lib/src/theme, before adding a dialog, chip, badge, button row, section header or empty state, and before any UI review. The full rule set is reports/reference/HOLLOW_DESIGN_LANGUAGE.md."
---

# hollow-ui

You are about to touch Hollow's UI. The full rule set is
`reports/reference/HOLLOW_DESIGN_LANGUAGE.md`; read it when a case here is
ambiguous. This file is the working checklist.

**The reason this exists:** nothing used to tell you which chip to use or which
button variant a toolbar takes, so every screen invented its own answer, 46
times for chips alone. Do not invent a 47th. Reach for the component.

---

## Before you write a line

1. **Does a component already exist?** `lib/src/ui/components/` is the only
   place a UI primitive lives. If you are about to write a class whose name
   ends in `Chip`, `Pill`, `Tag`, `Badge`, `Divider`, `SectionHeader` or
   `EmptyState`, stop: use the shared one.
2. **Which token?** Colours, sizes, radii, durations and spacing come from
   `lib/src/theme/`. If the value you want has no token, that is a decision to
   raise, not a literal to type.
3. **What are the empty, loading and error states?** Design them now, not after.
4. **What is the mobile counterpart?** Same change, same edit. Parity is checked
   per screen, never at the end.
5. **Redesigning a screen?** Write its brief first (design language 5.1): the
   job in one sentence, the focal point, the one primary action, and what
   leaves the screen. Then hold the render to the checks in 5.3: squint test,
   nothing twice, status by exception, destructive actions out of reach,
   accent only on what acts, icons earn their place, one row per kind of
   thing, locale-aware dates, one main region plus at most one side panel.
6. **Anchor panes to the window, never centre them.** A desktop screen's regions
   run to its edges (the main region takes the width, a side panel sits on the
   right edge at full height); a centred max-width column is a WEB layout and
   leaves dead gutters in the app. Max widths are for prose only. A web mockup's
   artboard frames its content; the real pane is 800 to 2500 px wide and framed
   by nothing, so the mockup decides what goes where, never widths or centring
   (design language 5.2 and 5.2.1).

---

## Type

`HollowTypography.<role>`. **`fontSize:` is forbidden outside the theme.**

| Role | Size / weight | Use |
|---|---|---|
| `display` | 28 / 600 | Welcome, largest empty states. Rare. |
| `heading` | 20 / 600 | Screen title |
| `subheading` | 16 / 600 | Section title |
| `body` | 14 / 400 | Message text, prose, dialog body |
| `bodyTouch` | 16 / 400 | Message text and sheet rows on a phone |
| `label` | 13 / 500 | Control labels, row titles, buttons |
| `bodySmall` | 12 / 400 | Secondary row text, descriptions |
| `caption` | 11 / 400 | Metadata, hints |
| `micro` | 10 / 500 | Badge text, counters, tightest chrome |
| `mono` | 13 / 400 | Console voice: ids, hashes, versions |
| `monoSmall` | 11 / 400 | Console voice in metadata |

- The faces are **Onest** (interface) and **Geist Mono** (the console voice),
  bundled static at 400 / 500 / 600. Never set `fontFamily:` at a call site.
- `copyWith(color:)` and `copyWith(fontWeight:)` are fine. `copyWith(fontSize:)`
  is not.
- Nothing below 10. No half steps. Weights 400 / 500 / 600.
- Tabular numerals wherever a number changes in place.
- **Sentence case.** No `toUpperCase()` on a label, no tracked caps, no
  `letterSpacing:`. The all-caps eyebrow label is the loudest generated-UI tell
  there is.
- No em dashes in user-visible strings, and never a colon in place of one.
  Anything longer than a label goes through the `sepia` skill.

## Colour

`hollow.<token>` from `HollowTheme.of(context)`. **`Colors.*` (except
`Colors.transparent`) and `Color(0x...)` are forbidden outside the theme.**

- Surfaces, five levels, dimmest to brightest on dark:
  `surface` = **chrome** (title bar, dock, header, sidebars, member panel:
  full bleed, below the canvas), `background` = **canvas** (the content),
  `elevated` = **raised** (cards, settings cards, inputs, tiles, hover on the
  canvas), `overlay` = **floating** (menus, pickers, dialogs, sheets, toasts,
  tooltips, popovers; opaque, never glass), `hover` = a row's hover INSIDE an
  overlay. One hairline, `border`. **A card on `surface` is a bug**: it reads
  as a hole below the canvas.
- Text: `textPrimary`, `textSecondary`, `textTertiary` (faded metadata). Three
  tiers, no fourth. **Never fade text with an alpha:** pick a tier.
- Accent: `accentText` for accent text and icons, raw `accent` for fills only.
  The accent means interactive or primary and nothing else. It never tints a
  card, never glows, never lands on a heading.
- Semantics: `success`, `warning`, `error`. `Colors.amber` where `hollow.warning`
  exists is exactly the bug this guards.
- Never colour alone: pair it with shape, an icon or a word.

## Spacing and gaps

`HollowSpacing`: 2, 4, 8, 12, 16, 24, 32, 48. **Numeric `EdgeInsets` and
`SizedBox` gaps are forbidden outside the theme.**

Gaps are the reason two tabs never look alike. One ramp:

| Between | Value |
|---|---|
| An icon and its label, inside one control | `xs` 4 |
| **Two buttons in an action row, two chips in a group** | `sm` 8 |
| Fields in a form, rows in a dense list | `md` 12 |
| Two groups inside a section | `lg` 16 |
| Two sections | `xl` 24 |
| Above a screen title | `xxl` 32 |

Padding: inside a control 4 to 8, inside a container 12 to 16, around a section
24 to 32. Tight inside a group, generous between groups.

## Radius

`hollow.radiusXs` 4 / `radiusMd` 8 / `radiusLg` 12 / `radiusXl` 16, plus
`HollowRadius.pill`. There is no 6. A radius nested inside another takes the
smaller stop.
**`BorderRadius.circular(<number>)` is forbidden outside the theme.**

- xs: badges, chips, keycaps. md:
  buttons, inputs, menus, popovers, tooltips, hoverable rows. lg: cards,
  dialogs, panels. xl: sheets and mobile dialogs.
- `pill` is for avatars, status dots and the unread jump pill. **A primary
  button is never a pill.**
- Read radii from the theme (`hollow.radiusMd`). Do not add new `HollowRadius.*`
  uses in `lib/src/ui`.

## Icons

Lucide, plus `brand_icons.dart` and `atlas_icons`. Sizes **14, 16, 20, 24 only**.

- An icon carries meaning or it is not there. **No icon beside a heading.** No
  icon in a tinted box beside a list item. No emoji as an icon or a bullet.
- Icon-only controls carry a `semanticLabel` and a tooltip. Both are CI-guarded.

## The two label components

The distinction is **interactivity**, not shape. Pill and tag are shapes and
words, not components.

- **`HollowBadge`** states a fact and is never clickable: kind, count, status,
  NSFW, owned, device role. Kinds: neutral, accent, success, warning, error,
  mono. Radius xs, type `micro` or `caption`.
- **`HollowChip`** takes an action: filter, sub-tab, selection, removable,
  access level. Selected is an accent-muted fill with `accentText`, **never a
  filled button**, and selection never changes the type's weight (that reflows
  the row under the pointer). Radius xs, type `label`, one size. For a row of
  equal-width sub-tabs pass `expand: true` inside an `Expanded`.
  Slots: `icon` or `leading` (a logo), `hint` (quiet text after the label),
  `trailingIcon` (chevron = opens a menu, arrow = leaves the app). A chip that
  opens a menu uses `showHollowMenu`, never `PopupMenuButton`
  (`settings/channel_access_pickers.dart`); at a trailing edge pass
  `alignEnd: true`. Key combos are `HollowKeyCombo`.

If it is clickable it is a chip. If it is not, it is a badge. There is no third
option and no local variant.

- **Tab rows are `HollowChipTabs<T>`** (dialog bodies, pages, `PlaceHeader`):
  `hint` for a quiet total, `count` for something waiting, arrows move it,
  `expand` on a phone. **Exception:** a row that IS a surface's header and
  splits the whole surface into sections (expression picker, Friends manager)
  is `HollowTabBar<T>`: equal tabs, accent bar under the open one, on the
  divider. Never a local `_Tab`.
- Labels: `LabelChip` toggles, `LabelBadge` is worn. "For how long" is
  `HollowDurationPicker` (null = "Until I remove it", never red).

## Buttons

`HollowButton`. Which variant is **not** a per-site choice:

| Variant | Where | Limit |
|---|---|---|
| `filled` | The one primary action of a region | At most one per visible region, rarely more than one per screen |
| `outline` | A secondary alternative beside that primary | At most two, and only when a `filled` is present |
| `ghost` | Everything else: toolbars, icon buttons, Cancel, secondary actions in rows and cards. **Grey**, never accent | No limit |
| `danger` | The final destructive confirmation only | A cautionary action is `outline` with `danger: true` |

- **A row that exists FOR one action** (wear, unlink, a member card's
  action) carries it as a compact `outline`; its other actions stay ghost
  icons.
- **The same for a card, section or one field:** a Save beside one field or a
  section's own Save is `outline`, so a settings page has NO filled unless it
  has one commit for the whole page. **Anything repeated per item** (Join on an
  invite card, Start meeting on a room row, Admit, Watch, Install) is compact
  `outline`, never filled. A selection is a `HollowChip` row, never a filled
  button among ghosts.
- **An action row with no primary is all ghost.** A toolbar never mixes outline
  and ghost. Two actions with no primary (Export / Import) are both ghost.
  Two filled in one `children:`/`actions:` list fail CI.
- Buttons in a row are `sm` 8 apart. Always.
- Disabled is neutral at full opacity (`textTertiary`), never a faded accent.
- While a request runs: **loading, not disabled**, via `HollowButton(loading: true)`
  (never a child swapped for a spinner). Success toast after the await,
  failure toast on a rethrow. A bare fire-and-forget call is a zone crash.
- Dialogs: ghost Cancel, filled confirm, `danger` only when destructive.

## Dialogs

- Open with `showHollowDialog()` only (never `showDialog`, `showGeneralDialog`,
  `AlertDialog`, `Dialog(`; guarded). Frame with `HollowDialog` (title +
  content + actions) or, for a layout of its own, `HollowDialogSurface`
  (`padded: false` to run to the edge). **Never draw a dialog frame by hand**:
  no Container with overlay fill, radius, border or shadow, no tinted border.
- Title: `heading`, **sentence case**, no icon beside it. Body prose:
  `HollowDialogText`. A form of fields: `width: 420`.
- Actions trailing, 8 apart, primary LAST: ghost Cancel, then ONE `filled`
  (or `danger` for delete/leave/remove/wipe). Ghost extras go in
  `leadingActions`. Nothing to confirm = `showClose: true` and no Done button.
- A yes-or-no question is `showHollowConfirm()`; a one-field name prompt is
  `promptForName()` (`description`, `maxLength`, `validator`).
- **A confirm that acts passes `onConfirm`** (`onSubmit` for a prompt): the
  dialog stays open loading, closes on success, shows the error inside on a
  throw. Custom dialogs: `HollowDialogAction` + `HollowDialog(busy:, error:)`.
  Never pop, then await.
- Errors people read are `friendlyError(e)`; a raw `$e` in a toast is guarded.
- A value to copy is `HollowCopyField` (the one well). Phone touch sizing and
  `scrollable: false` belong to `HollowDialog`, never the call site.

## The rest of the components

`HollowSectionHeader` (title in `subheading`, or `label` with `dense: true`
for a sub-group; optional trailing action, optional count in mono, its own
8 px bottom gap, **no leading icon**; the label above ONE settings field is
`SettingsFieldLabel`) · `HollowEmptyState` (one
honest line about what is true now, one optional second line, at most one
action; a pane takes the default, a list inside a card or section takes
`dense: true`; never a local `*Empty*` helper, CI-guarded) · `HollowDivider` (the hairline, nothing else) · `HollowListRow`
(leading / title / subtitle / trailing, hover on the whole row; in a dialog
its content sits on the text edge and the hover bleeds past it, and a list
that clips wraps its scroll view in `HollowBleed`) ·
`HollowSkeleton` (2 to 10 second loads, keeps the final geometry) · `HollowSpinner`
(small 14 in a row or button, medium 20 in a card, large 32 for a pane; quiet
`textSecondary`, never the accent) · `showHollowSheet()` (the only bottom sheet:
overlay, `radiusXl`, one `HollowSheetHandle`) · `HollowSlider` (the only
slider; `onMedia: true` over video) · `HollowToggle` (the only switch, with a
`semanticLabel`; it grows its own 48 px hit area on touch) · `HollowCard` ·
`HollowCountBadge` (the unread counter: accent for unread, error plus `@` for a
mention, never hand-drawn) · `ConversationRow` + `PresenceAvatar` (the one
conversation row) · `HollowTextLink` (a link inside prose, on the text's edge) ·
`HollowProgressBar` (a determinate transfer, 4 px, never animates on its own) · `PlaceHeader` (`shell/place_header.dart`: a place's title strip, fixed 52 px, title, tab chips beside it, actions on the trailing edge; Archive, Share, Conferences) · `HollowListRow(touch: true)` on a phone · `ServerAvatar` · `HollowIconButton` (every icon-only control: `label` is
tooltip and screen-reader name, `size` 32 desktop / 44 touch, `selected` is a
grey fill never the accent, siblings `xs` apart). A person's name in a chat is
`nameColorFor(master, hollow)`, yours `accentText`; panels and people lists
stay neutral. Chat surfaces reuse `MessageRow`, `ChatHeaderBar`,
`ChatComposerRow`, `showExpressionPicker` (design language 4.5), never a copy.
List times go through `conversationTimeLabel()`, never `M/D`,
in the interface face (a written date in mono reads as a typewriter).

**Cards:** only for a repeatable self-contained unit (a listing, a device, a
news item). A settings group is not a card. A section is not a card. Cards do
not nest. A background step (`elevated`) only: no hairline, no
shadow. No coloured strip on the edge; status is a dot or a word. Anything
repeated more than three times is a list of `HollowListRow`, not a grid of
cards, unless the item **is** the art (the Shop, a gallery), where the art is
the card: full bleed, title and price beneath.

Already-settled surfaces: `showHollowMenu` via
`ContextMenuTarget`, `HollowToast`, `HollowScrollBehavior`.

## Motion and state

- `HollowDurations.exit` 100 ms (leaving, the press), `fast` 150 (popover and
  menu entrance, press release, hover colour, toggles), `normal` 250 (dialogs,
  toasts, sheets, pushed pages), `slow` 400 (progress bars only).
- `HollowCurves.enter` in, `exit` as the REVERSE curve of a pair, `subtle` for
  something already on screen. **Nothing overshoots: no spring, elastic,
  bounce.**
- **Switching what a region shows is instant** (conversation, channel, server,
  tabs). **Side panels toggle instantly.** Only what arrives on top moves.
- **Travel is 8 px (`HollowMotion.rise`), whatever the size.** Small popovers
  scale from 0.96 around the click point; big panels (pickers) fade and rise 8
  px (`PopupAnimator(rise: true)`). Only edge-attached, gesture-dismissed
  surfaces (sheets, phone pages, the phone banner) travel their full size.
- Exits are quicker than entrances; a popover's barrier stops taking clicks as
  its exit starts.
- **Hover never moves layout and never changes font weight.**
- Frequent actions (send, react, hover a message) animate nothing beyond the
  hover colour and the press.
- **Never animate a colour from `Colors.transparent`** (it lerps through black):
  pass `backgroundColor: null`. Hover never paints outside its control, and
  hover belongs to the **row**, not the artwork inside it.
- Read durations when the animation starts, never once in `initState`, so a
  live Reduce motion change applies.
- A running `Ticker` requests a frame every vsync. Decorative motion is a
  `Timer` plus a `GatedNotifier`, never an `AnimationController`.
- Reduce motion only through `ReduceMotionController` and `hollowMobileRoute()`;
  it drops movement, never state.
- Focus rings only through `HollowFocusRing`, on keyboard focus only.

## Chrome (Dock layout)

- **Even proportions.** Something floats over your row (the window controls over a
  full-window route)? Move the WHOLE row clear, down by `windowChromeTop()`, keeping
  equal margins on every side and its pieces level. Never squeeze just the colliding
  end sideways: a lopsided row reads as a bug. Facing margins match.

- The header holds **people**; the dock holds **you** (identity, connection,
  the call), **where you are** (Home, servers, places) and **tools**. Places
  swap the centre through `setShellTab()`; tools open on top. Settings is a
  place (`openSettings()`, the gear carries its mark) built from
  `settings/settings_kit.dart`: sections, not cards; rows carry no icon.
- **One** selection mark, `NavSelectionMark`, over whatever is active. Hover
  is a surface step only. Unread never changes a name's weight.
- In Dock mode the title bar folds into the header: the window controls float
  unscaled over its end (`WindowControls`), the middle drags the window.
  Classic, welcome and the lock cover keep the 32 px bar.

## Shadows and decoration

Shadows only on things that float above the app (menus, popovers, dialogs,
toasts), `blurRadius` at most 12: `HollowShadows.float`. A focused field shows
its accent border, never a glow. Never on a card or a row, never as a
substitute for a surface step. **No gradients**, no glass, no blur, no glow. The
ambient background is an Appearance opt-in, off by default and under reduce
motion; never add another.

---

## Before you say it is done

1. **`flutter test test/design_language_guard_test.dart`** is green and no
   baseline went up. Run `test/widget/design_primitives_test.dart`,
   `test/contrast_test.dart` and `test/a11y_label_guard_test.dart` as well when
   you touched a component.
2. **`flutter analyze`** is clean.
3. **Screenshots.** Drive the app with `scripts\fleet.ps1` on a THROWAWAY
   fixture peer (`-Onboard -Fresh`, then `-Scenario ... -Peers a`), never
   `ui_probe.ps1`'s default, which mirrors Vitalik's real identity. A scenario
   creates the server or channel it needs; a step that misses is driven by hand
   with `-Live`, never shot empty. **Read your own PNGs**, and fix what looks
   wrong before reporting. Verifying UI from source does not count. Desktop and mobile both.
   For a component rather than a screen, add it to the design sheet and shoot
   that: `ui_probe.ps1 -Widget design-gallery` renders every primitive in every
   state, dark beside light, needing no data directory.
4. Empty, loading, error, offline and locked states all exist for what you
   touched.
5. Never run `dart format` mid-edit.

## The forbidden list, in one place

`fontSize:` · `Colors.*` (except transparent) · `Color(0x` · numeric
`BorderRadius.circular` · `letterSpacing:` · `toUpperCase()` on a label ·
`Divider(` outside components · a Chip/Pill/Tag/Badge class outside components ·
numeric `EdgeInsets` and `SizedBox` gaps · gradients · `BoxShadow` blur above 12
· raw `Material(` outside components · `CircularProgressIndicator(` ·
`showModalBottomSheet` · Material `Slider` / `Switch` / `Checkbox` / `Radio` ·
`showDialog` / `showGeneralDialog` / `AlertDialog` · a hand-drawn dialog frame.

Exemption is `// design-ignore: <reason>` on the offending line, for a genuine
one-off (a brand asset's exact colour, a platform-mandated metric). Not for "I
did not want to add a token".
