# Profile Card, Popup and Full Profile Dialog

## Architecture Overview (rebuilt 2026-09-26, dialogs session 25)

ONE widget renders who someone is on every surface:
`ProfileIdentityColumn` in `lib/src/ui/components/profile_identity_column.dart`,
at three densities (`ProfileCardDensity.compact` = the anchored popup, 300 wide,
`kProfileCompactWidth`; `.full` = the profile dialog's column, 400 wide,
`kProfileColumnWidth`; `.touch` = the phone sheet). The host owns the frame and
passes `dismissHost` (closes it before another surface opens), and optionally
`onClose` / `onExpand` (a button over the banner), `onMessage` /
`onEditProfile` / `onEditShowcase` (hosts that navigate differently) and
`showActions: false` (the showcase editor owns its own actions).
`profile_card_body.dart` is down to `ProfileFriendAction` (filled Add friend /
Accept request, ghost Request sent, busy + error toast), `profileRoleColor` and
`showLocalNicknameDialog`; `ProfileCardBody`, the peer-id footer, the local
`_ProfileChip` and the gradient no-banner fallback are gone.

Sections in order: banner at a TRUE 2.5:1 of the column width (edge to edge; a
missing banner is a flat `elevated` block) → avatar (96 full / 64 compact / 80
touch, overlapping the banner, zero-layout-cost frame per #54) with the badge
row at its right (`SupportMarksChip`, then the Twitch chip) → name (local
nickname > server nickname > display name) → "Online · Friend" / "Verified"
line → custom status → role + label `LabelBadge`s → hairline → "About me" →
actions. Compact adds a ghost "View showcase" when the person has a board.

**Buttons over the banner** go through one helper: `MediaScrimIconButton`
(= `HollowIconButton(onMedia: true)`, a round dark scrim that lifts on hover,
16 px white glyph) ONLY when a banner image is actually showing; over the flat
fallback it is a plain `HollowIconButton`, since a scrim on a flat surface reads
as a hole.

**Actions.** Someone else: ONE filled Message (accepted friend; providers are
written before `dismissHost`) or `ProfileFriendAction`, then grey
`HollowIconButton`s: Set a nickname / Edit nickname, Manage member (when
`_canManageMember()`), More. Desktop More = `showHollowMenu`: Verify contact /
View safety number, Copy user ID, then Block / Unblock and Report in red. On
the phone the row is Message + nickname + More, and More is a `showHollowSheet`
(Manage member, Verify contact, Copy user ID, then Block and Report in red).
Destructive actions never rest in the row. Self: filled Edit profile + ghost
Edit showcase (compact: Edit profile only).

`SupportMarksChip` (`components/support_glyph.dart`) is the icon alone on every
density, plus "×N" past one piece; the tooltip lists every piece
("VitalikPro13: Headphones").

`_canManageMember()` gates on `serverId != null` plus (role ladder via
shared `core/role_hierarchy.dart` `canManageRole`/`assignableRoles`) OR
`Permission.manageRoles` OR `Permission.manageChannels`: advisory only;
the dialog and Rust `op_allowed` re-check. Opens
`ui/settings/manage_member_dialog.dart` (host-dismiss pattern, passes the
MASTER id).

Renders: `test/screenshots/redesign_after_profile_screenshot_test.dart` (19
states into `build/ui_screenshots/redesign_after/`); widget tests
`test/widget/profile_redesign_test.dart`, `test/widget/support_marks_chip_test.dart`.

## showProfileCardPopup() — Compact Popup (desktop)

`lib/src/ui/components/profile_card_popup.dart`. Keeps the OverlayEntry +
anchoring/flip/clamp shell (estimated height 400, flip-up when overflowing
the bottom, horizontal clamp) and the shared popover motion (scale from
`HollowMotion.popoverScale` + fade, `HollowDurations.fast` in, `exit` out,
growing from the anchor corner: `topLeft` when it opens downward, else
`bottomLeft`; plain `hollow.border` hairline, `HollowShadows.float`). The
barrier stops taking clicks as the exit starts. The card
interior is `ProfileIdentityColumn(density: compact)`. Member panel anchors derive from
`kProfileCardPopupWidth`. `showLocalNicknameDialog` lives in
profile_card_body.dart and is RE-EXPORTED here (chat_pane imports it).
Expand affordance: "View full profile" over the banner (`onExpand`) → removes
the overlay instantly → `showProfileDialog`.

**Anchoring is a FUNCTION, not a point (issue #54).** The parameter is
`anchorOf: Offset Function()`, re-read after any viewport change: a point
captured at click time leaves the card stranded in the middle of the chat
when the window is maximized. The re-read runs POST-FRAME (during build the
source has not been laid out at the new size yet, so it would hand back the
pre-resize position) and TWICE (a resize can also start a panel animation;
the first read lands mid-slide, the second after it settles). `Offset.zero`
back from the closure means the source has no render box any more — the row
scrolled away, or the whole panel folded — and the card dismisses rather than
floating. Member-panel rows share one `memberCardAnchor(context)` helper;
call sites with nothing to follow (the "View profile" menu row) pass a
constant closure.

Also since issue #54: Escape closes it (a raw OverlayEntry is not a route, so
nothing else gave it a keyboard exit), `_dismissing` guards the double
teardown that would otherwise dispose an entry twice, and the upward-opening
branch is clamped so a short window cannot push the card off the top edge.

**Which surface opens (issue #54):** `profileCardStyleProvider`
(Settings > Appearance, "Open profiles expanded"). At
`ProfileCardStyle.expanded` `showProfileCardPopup` forwards straight to
`showProfileDialog` instead of inserting the compact overlay, so one click
lands on the full profile with the showcase board.

`serverId` (nullable, added issue #48) threads the whole chain:
`_ServerMemberTile` (member_panel) and `showChatProfile` pass it →
`showProfileCardPopup` → `_ProfileCardOverlay` → `ProfileIdentityColumn`, and
`_expand` forwards it to `showProfileDialog` → `ProfileDialog`. Null in
DM/self contexts (user_bar, bottom_bar, DM `_MemberTile`, DM bubbles) —
no server context, no Manage Member.

## showProfileDialog() — Full Profile (dialogs/profile_dialog.dart)

Desktop (option B, approved 2026-09-25): one `HollowDialogSurface(padded:
false)` holding the 400 identity column, a hairline, and the showcase pane (see
wiki `profile_showcase_board`): `ShowcaseBoardView` with the two 340 board
columns 24 apart, blocks directly on the surface, the close X in the pane's
corner (scrimmed only while a wide artwork sits under it). The dialog is only as
wide as the board needs (`showcasePaneWidth(columns)`,
`ShowcaseBoardView.columnsFor`: two when both sides hold something or a wide
artwork spans them). No board = the profile column alone with the close X over
the banner. Narrow windows never squeeze: two board columns drop to ONE (left,
then right), and a window too narrow for any pane stacks the showcase under the
profile in one 400 scroll. The identity column's scroll view draws no scrollbar
(`_WithoutScrollbar`), so the app-wide scroll gutter can never pull the banner
off the dialog's rounded edge. Watches `profileProvider.select(showcaseBoard)`
so an editor save updates it live.

Phone: `showMobileProfileSheet(context, peerId:, role:, labels:, serverId:)`
(`mobile/mobile_profile_sheet.dart`), `showHollowSheet` at 0.9 height with the
handle drawn over the banner: the touch column (Message right under the
identity, before About and the showcase, so it is reachable without scrolling),
then the boards stacked (and the wide artwork). Callers from chat
(`showChatProfile`), the member panel and Server settings > Members pass
`serverId`, which is what shows Manage member.

## Chat popups + role enrichment

`showChatProfile` (`ui/chat/profile_tap.dart`) takes an optional `serverId`;
channel contexts (`channel_message_bubble` passes it) resolve the sender's
role/labels/nickname/twitch from `serverMembersProvider` AT TAP TIME so the
chat popup matches the member panel. DMs pass none — no roles. The Member
role renders as a chip like every other role (consistency rule). Since
issue #48 the resolved `serverId` is forwarded into the popup, so channel
chat popups get Manage Member too.

## Manage Member dialog (ui/settings/manage_member_dialog.dart, issue #48)

`showManageMemberDialog(context, serverId:, peerId:)` — peerId MUST be the
MASTER identity (roles/labels/grants are master-keyed CRDT state). Member-
first inverse of the channel-centric `channel_grants_dialog` — same FFI,
same LWW model. Title "Manage <name>"; three permission-gated sections under
dense `HollowSectionHeader`s (no cards), each hidden without the capability:
- **Role**: `HollowChip`s in RANK order (owner, admin, moderator, member,
  so they never reorder between members): the current role plus
  `assignableRoles(myRole)` (shared `core/role_hierarchy.dart`, which also
  serves the Members page so the ladders can't drift). Tap →
  `showChangeRoleDialog(currentRole:)` (the ONE role confirm, below), and
  the dialog's own `_role` holds the result. Gated by `canManageRole` &&
  non-self.
- **Labels**: `LabelChip` toggles over `serverLabelsProvider`; selection
  state seeded ONCE from the member row (`_labelIds ??=`, labels-tab
  `_seeded` rule — a refetch right after a queued write returns the previous
  value), optimistic with revert + `friendlyError` toast on failure via
  assign/unassignLabel. Empty: "This server has no labels yet". Gated by
  MANAGE_ROLES.
- **Temporary channel access**: rows for channels with non-empty
  `visibilityLabels` from `serverChannelsProvider` (computing per-member
  visibility would re-implement the Rust predicate; redundant grants are
  harmless). An active grant's subtitle is `grantRemainingLabel` ("<time>
  left", or "Until someone removes it" for a permanent one: another admin
  may have given it) + a remove X (optimistic, back on failure); else an
  outline "Give access" → `_View.pickDuration` in the same dialog ("How long
  should <name> have access to #x?", `HollowDurationPicker`, Back + Give
  access). The grant runs inside the dialog (`HollowDialogAction`: loading
  confirm, error above the actions), then toasts "Access given for 1 hour"
  / "Access given until someone removes it". Own writes live in `_grants`
  (`optimisticGrant`), and `dispose` invalidates `channelGrantsProvider` for
  every channel it touched. Gated by MANAGE_CHANNELS.

Dart gates are advisory — Rust `op_allowed` re-validates every op.

## Moderation confirms (`ui/settings/moderation_dialogs.dart`)

ONE file for every surface (Members page, member menu, Manage member, phone
sheets). Each function confirms, runs the FFI INSIDE the confirm
(`showHollowConfirm(onConfirm:)`: a failure shows in the dialog with a
retry), then invalidates `serverMembersProvider` + `mutedMembersProvider`
and toasts. `showChangeRoleDialog` ("Make <name> an admin?", "They go from
Member to Admin, which changes what they can do here." when `currentRole`
is known, confirm "Make admin"), `showKickMemberDialog` / `showBanMemberDialog`
(danger), `showMuteMemberDialog` (the duration IS the confirm:
`showHollowDurationDialog` with the `HollowDurationPicker` chips 10 minutes /
15 minutes / 1 hour / 24 hours / 7 days / "Until I remove it"; toast "<name>
is muted for 1 hour" or "until someone unmutes them"), `unmuteMember` (no
confirm; "<name> can post again"). The four confirms return `Future<bool>`
(true once done).

## UserBar Widget Overview

`UserBar` is a `ConsumerWidget` that renders the local user's identity and connection status at the bottom of the channel sidebar. It mirrors Discord's bottom-left user panel.

### Layout and OS Text Scaling
The bar is `BoxConstraints(minHeight: 52)` — **min-height, not a fixed 52** (the a11y Phase 3 chrome-bar pattern). Its label stack is capped at `MediaQuery.withClampedTextScaling(maxScaleFactor: 1.3)`, and the status word sits in a `Flexible` with ellipsis.

Both of those were finished 2026-07-31. `app.dart` deliberately applies NO text-scale clamp on desktop ("full OS scaling already flows through"), so a Windows user with Accessibility > Text size at 125%+ was already running Hollow scaled with nothing verifying it — and this bar broke: 36px of horizontal overflow (the status word was a bare `Text` squeezed beside the avatar and three trailing icons in a 240px sidebar — it fired even at 1.0x with a long status like "Connecting…") and 2px vertical (name + status stacked in a hard `height: 52`). `FriendsBar`, `BottomBar` and `MemberPanel` were all measured clean at 2.0x. Pinned by `test/widget/desktop_text_scale_overflow_test.dart`.

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
`HollowPressable` with `LucideIcons.settings` (16px, `textSecondary`). Wrapped in `HollowTooltip("Settings")`. On tap: `toggleSettings(ref.read)` (the Settings place).

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
