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

---

## Type

`HollowTypography.<role>`. **`fontSize:` is forbidden outside the theme.**

| Role | Size / weight | Use |
|---|---|---|
| `display` | 28 / 700 | Welcome, largest empty states. Rare. |
| `heading` | 20 / 600 | Screen title |
| `subheading` | 16 / 600 | Section title |
| `body` | 14 / 400 | Message text, prose, dialog body |
| `label` | 13 / 500 | Control labels, row titles, buttons |
| `bodySmall` | 12 / 400 | Secondary row text, descriptions |
| `caption` | 11 / 400 | Metadata, hints |
| `micro` | 10 / 500 | Badge text, counters, tightest chrome |
| `mono` | 13 / 400 | Console voice: ids, hashes, versions |
| `monoSmall` | 11 / 400 | Console voice in metadata |

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

- Surfaces: `background` is the content canvas, `surface` is chrome (dock,
  sidebars, title bar), `elevated` is raised (inputs, menus, dialogs, cards,
  hover). One hairline, `border`.
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

`hollow.radiusXs` 4 / `radiusSm` 6 / `radiusMd` 8 / `radiusLg` 12 /
`radiusXl` 16, plus `HollowRadius.pill`.
**`BorderRadius.circular(<number>)` is forbidden outside the theme.**

- xs: badges, chips, keycaps. sm: toggles and other small controls. md:
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

If it is clickable it is a chip. If it is not, it is a badge. There is no third
option and no local variant.

## Buttons

`HollowButton`. Which variant is **not** a per-site choice:

| Variant | Where | Limit |
|---|---|---|
| `filled` | The one primary action of a region | At most one per visible region, rarely more than one per screen |
| `outline` | A secondary alternative beside that primary | At most two, and only when a `filled` is present |
| `ghost` | Everything else: toolbars, icon buttons, Cancel, actions in rows and cards | No limit |
| `danger` | The final destructive confirmation only | A cautionary action is `outline` with `danger: true` |

- **An action row with no primary is all ghost.** A toolbar never mixes outline
  and ghost. A button is outlined only because it stands next to a filled one.
- Buttons in a row are `sm` 8 apart. Always.
- While a request runs: **loading, not disabled**. Success toast after the await,
  failure toast on a rethrow. A bare fire-and-forget call is a zone crash.
- Dialogs: ghost Cancel, filled confirm, `danger` only when destructive.

## The rest of the components

`HollowSectionHeader` (title in `subheading` or `label`, optional trailing
action, optional count in mono, **no leading icon**) · `HollowEmptyState` (one
honest line about what is true now, one optional second line, at most one
action) · `HollowDivider` (the hairline, nothing else) · `HollowListRow`
(leading / title / subtitle / trailing, hover on the whole row) ·
`HollowSkeleton` (2 to 10 second loads, keeps the final geometry) · `HollowCard`.

**Cards:** only for a repeatable self-contained unit (a listing, a device, a
news item). A settings group is not a card. A section is not a card. Cards do
not nest. A background step **or** a hairline, never both, never either plus a
shadow. No coloured strip on the edge; status is a dot or a word. Anything
repeated more than three times is a list of `HollowListRow`, not a grid of
cards, unless the item **is** the art (the Shop, a gallery), where the art is
the card: full bleed, title and price beneath.

Already-settled surfaces: `showHollowDialog()`, `showHollowMenu` via
`ContextMenuTarget`, `HollowToast`, `HollowScrollBehavior`.

## Motion and state

- `HollowDurations.fast` 150 ms (press, hover colour), `normal` 250 ms
  (tooltip, dropdown, chip, toast), `slow` 400 ms (route, sheet).
- `HollowCurves.enter` brings something in, `subtle` moves something already on
  screen, `exit` takes it away, `spring` is the press release only. Transform
  and opacity only, enter from scale 0.96 plus a fade.
- **Hover never moves layout and never changes font weight.** No bounce.
- Frequent actions (send, switch channel, open a menu) animate nothing beyond
  the 120 ms colour.
- **Never animate a colour from `Colors.transparent`** (it lerps through black):
  pass `backgroundColor: null`. Hover never paints outside its control, and
  hover belongs to the **row**, not the artwork inside it.
- A running `Ticker` requests a frame every vsync. Decorative motion is a
  `Timer` plus a `GatedNotifier`, never an `AnimationController`.
- Reduce motion only through `ReduceMotionController` and `hollowMobileRoute()`.
- Focus rings only through `HollowFocusRing`, on keyboard focus only.

## Shadows and decoration

Shadows only on things that float above the app (menus, popovers, dialogs,
toasts), `blurRadius` at most 12. Never on a card or a row, never as a
substitute for a surface step. **No gradients**, no glass, no blur, no glow, no
animated ambient decoration.

---

## Before you say it is done

1. **`flutter test test/design_language_guard_test.dart`** is green and no
   baseline went up. Run `test/widget/design_primitives_test.dart`,
   `test/contrast_test.dart` and `test/a11y_label_guard_test.dart` as well when
   you touched a component.
2. **`flutter analyze`** is clean.
3. **Screenshots.** Drive the app with `scripts\ui_probe.ps1` (peer-to-peer:
   `scripts\fleet.ps1`), **read your own PNGs**, and fix what looks wrong before
   reporting. Verifying UI from source does not count. Desktop and mobile both.
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
· raw `Material(` outside components.

Exemption is `// design-ignore: <reason>` on the offending line, for a genuine
one-off (a brand asset's exact colour, a platform-mandated metric). Not for "I
did not want to add a token".
