# Profile Card, Popup and Full Profile Dialog

## Architecture Overview (redesigned 2026-07-07)

ONE shared widget renders profile card content at two densities:
`ProfileCardBody` in `lib/src/ui/components/profile_card_body.dart` with
`ProfileCardDensity.compact` (anchored hover popup) and `.full` (the wide
profile dialog). Both render the same sections from the same data so the two
surfaces cannot drift. The HOST owns the outer container and passes
`dismissHost` (closes popup/dialog before opening another dialog) and, for
compact, `onExpand` (opens the full dialog).

Sections in order: banner Stack (avatar breaking its bottom edge at left,
corner chip top-right: compact = maximize2 expand, full = minimize2 CLOSE
via `dismissHost` — same fixed 26×26 scrimmed circle, borderRadius 13, NO
HollowPressable padding so hover paint stays inside; the game card's X
reuses this structure) → corner band (Twitch/integration chip
ALONE, right-aligned under the banner, both densities) → identity block
(name, secondary name, presence StatusDot row via `identityIsOnline`, italic
custom status) → ONE merged chip row (role incl. Member + cosmetic labels) →
divider → ABOUT ME → actions → peer-id copy footer. Compact shows a "View
showcase" hint (sparkles, accentText) when the person has a board. Full
density puts ALL action buttons in one row below About Me (Edit Showcase +
Edit Profile for self; Set Nickname + friend action for others).

Density metrics: compact banner 104 / avatar 64 / width 300
(`kProfileCardPopupWidth`); full banner 220 / avatar 110 / card width 560
(`kProfileDialogCenterWidth`), name 22px.

## showProfileCardPopup() — Compact Popup (desktop)

`lib/src/ui/components/profile_card_popup.dart`. Keeps the OverlayEntry +
anchoring/flip/clamp shell (estimated height 400, flip-up when overflowing
the bottom, horizontal clamp) and the 180ms scale+fade animation; the card
interior is `ProfileCardBody(compact)`. Member panel anchors derive from
`kProfileCardPopupWidth`. `showLocalNicknameDialog` moved to
profile_card_body.dart and is RE-EXPORTED here (chat_pane imports it).
Expand affordance: scrimmed circle button on the banner (a11y label "View
full profile") → removes overlay instantly → `showProfileDialog`.

## showProfileDialog() — Full Profile (dialogs/profile_dialog.dart)

Desktop: `showHollowDialog` hosting the center card FLANKED by separate
showcase board panels (see wiki `profile_showcase_board`). The card is
self-contained; panels (`kShowcasePanelWidth` 340) are their own surfaces
(same elevated/border/shadow treatment) stretched to the card's height via
IntrinsicHeight (ConstrainedBox minHeight 560). Adaptive: no boards → card
only; when the window can't fit the ensemble, columns SCALE proportionally
(`scale = (available − gaps) / columnsWidth`, side-by-side down to 0.62×)
and only below that stack vertically. Watches
`profileProvider.select(showcaseBoard)` so composer saves update live.
Mobile: routes to `showMobileProfileSheet` (parity surface; boards stacked,
sheet is scrollable, self gets Edit Showcase).

## Chat popups + role enrichment

`showChatProfile` (`ui/chat/profile_tap.dart`) takes an optional `serverId`;
channel contexts (`channel_message_bubble` passes it) resolve the sender's
role/labels/nickname/twitch from `serverMembersProvider` AT TAP TIME so the
chat popup matches the member panel. DMs pass none — no roles. The Member
role renders as a chip like every other role (consistency rule).

## UserBar Widget Overview

`UserBar` is a `ConsumerWidget` that renders the local user's identity and connection status at the bottom of the channel sidebar. It mirrors Discord's bottom-left user panel.

### Providers Read
- `identityProvider` — local peer ID + mnemonic
- `overallConnectionProvider` — node + real relay-WS state; the ONLY source of the connection reading
- `selectedServerProvider` — currently selected server (for server-specific sync status)
- `profileProvider` — all user profiles (for local user display name and avatar)
- `invisibleModeProvider` — whether local user is invisible
- `serverSyncStatusProvider(serverId)` (conditional) — per-server sync status
- `roomBudgetProvider` — relay room budget usage

## Status Derivation Logic

Rewritten 2026-07-27 for GitHub issue #23. The bar used to read `nodeProvider` when no server was selected and, when one WAS, to synthesise `Connecting...` from `syncStatus == idle && onlineCount == 0` — so an empty server of your own read as a dropped connection, and the Dock bar (which read `nodeProvider.status`) disagreed with this one. Both bars now render from ONE helper.

`connectionVisual(hollow, OverallConnection, {invisible})` in `ui/components/connection_visual.dart` returns a `ConnectionVisual(label, color, pulse, filled)`:
- `connected` -> "Online", `success`, pulse, FILLED
- `connecting` / `reconnecting` / `loading` -> `OverallConnection.label`, `textSecondary`, pulse, hollow ring
- `offline` / `error` -> `.label`, `warning`, no pulse, hollow ring
- `invisible: true` -> "Invisible", `textSecondary`, no pulse, hollow ring (wins over everything)

Shape is the non-color cue: only a settled "connected" is a solid dot. `filled` is now independent of `pulse` (they used to be the same flag).

**Refinement tier (UserBar only).** When the reading is already online, not invisible, and a server is selected, `serverSyncStatusProvider` may REFINE it — never contradict it:
- `syncing` -> "Syncing...", `accentText`, pulse, ring
- `retrying` -> "Retrying...", `warning`, pulse, ring
- `failed` -> "Sync failed", `error`, no pulse, ring
- `idle` / `synced` / `connecting` -> keep "Online"

(`ServerSyncStatus.connecting` has no producer anywhere in the codebase — the deleted `onlineCount` mapping was its only one.)

The `BottomBar` (Dock) user chip uses the same helper for its `StatusDot` and carries `visual.label` in a `HollowTooltip`, since it has no room for the word. `test/connection_visual_test.dart` pins the mapping.

## Layout Structure

`Column` with two children:

### 1. _RoomBudgetBar (Conditional)
Only shown when `roomBudget.usage > 0.5` (more than 50% of the 2000-connection room budget used).

### 2. Main Bar Container
52px height, horizontal padding `HollowSpacing.sm + 2`, `hollow.opaqueBackground` background, top border.

Row contents (left to right):

#### Avatar
`HollowAvatar` at 32px size with local user's profile `avatarBytes`. Falls back to a 32px rounded container in `hollow.elevated` color if `localPeerId` is null.

#### Name + Status (Expanded)
Wrapped in `HollowTooltip` showing full `localPeerId`, inside a `HollowPressable`.

**On tap:** If `localPeerId != null`, gets global position, shows `showProfileCardPopup()` with `anchorBottom: true` and anchor at `Offset(pos.dx, pos.dy - 8)` — the card appears above the user bar.

Content column:
- **Display name:** `HollowTypography.body` at 13px, w600, `textPrimary`, single-line ellipsis
- **Status row:** `StatusDot` (7px, derived color, derived pulse) + status text (`HollowTypography.caption`, `textSecondary`)

#### Downloads Button
`DownloadIconButton(iconSize: 16)` — shows active file transfer count, opens download panel.

#### Settings Button
`HollowPressable` with `LucideIcons.settings` (16px, `textSecondary`). Wrapped in `HollowTooltip("Settings")`. On tap: `showUserSettingsDialog(context, ref)`.

#### Recovery Phrase Button (Conditional)
Only shown when `identity.mnemonic != null`. `HollowPressable` with `LucideIcons.keyRound` (16px, `textSecondary`). Wrapped in `HollowTooltip("Recovery phrase")`. On tap: `showMnemonicDialog(context, identity.mnemonic!)`.

## _RoomBudgetBar — Connection Usage Indicator

`_RoomBudgetBar` is a `StatelessWidget` that renders a thin (3px) progress bar showing relay room budget consumption.

### Parameters
- `budget` (RoomBudget) — contains `joined`, `limit` (default 2000), and computed properties

### Color Logic
- `budget.isAtLimit` (joined >= limit) -> `hollow.error` (red)
- `budget.isNearLimit` (usage >= 0.9) -> `hollow.warning` (yellow)
- Otherwise -> `hollow.accent` (teal)

### Visual
- Background: `hollow.border` (full width, 3px)
- Fill: `FractionallySizedBox` with `widthFactor = usage.clamp(0.0, 1.0)`, right-side `Radius.circular(2)`, color animated over 300ms via `AnimatedContainer`
- Tooltip: "{joined} / {limit} connections used"

### RoomBudget Data Model
`RoomBudget` class (from `lib/src/core/providers/room_budget_provider.dart`):
- `joined` (int, default 0) — current room connections
- `limit` (int, default 2000) — relay-enforced cap
- `usage` (double) — `joined / limit`
- `remaining` (int) — `(limit - joined).clamp(0, limit)`
- `isNearLimit` (bool) — `usage >= 0.9`
- `isAtLimit` (bool) — `joined >= limit`
