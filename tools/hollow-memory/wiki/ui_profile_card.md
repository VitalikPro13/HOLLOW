# ProfileCardPopup and UserBar

## ProfileCardPopup Overview

Source: `lib/src/ui/components/profile_card_popup.dart` (810 lines)

The profile card is a floating overlay that shows detailed information about a user. It is the primary inspection surface for both peers and server members across the entire app.

## showProfileCardPopup() — Entry Point

`showProfileCardPopup()` is the top-level function that creates and inserts an `OverlayEntry` containing a `_ProfileCardOverlay`.

### Parameters
- `context` (BuildContext) — for accessing `Overlay.of(context)`
- `ref` (WidgetRef) — passed through to the overlay widget
- `peerId` (String, required) — the user to display
- `nickname` (String?) — server nickname, if applicable
- `role` (String?) — server power role ("owner", "admin", "moderator", "member")
- `twitchUsername` (String?) — Twitch username from OAuth verification
- `labels` (List<crdt_api.LabelFfi>?) — cosmetic label badges
- `anchor` (Offset, required) — screen position to anchor the card near
- `anchorBottom` (bool, default false) — when true, `anchor.dy` represents where the card's bottom edge should be (used by UserBar to show card above itself)

### Dismiss Mechanism
The `OverlayEntry` captures a `late final` reference to itself. The `onDismiss` callback calls `entry.remove()` then `entry.dispose()`.

## Trigger Sources

The profile card is shown from three locations:
1. **`_ServerMemberTile` (member_panel.dart):** On tap. Anchor is `Offset(pos.dx - 290, pos.dy - 100)` — positions card ~290px to the left and ~100px above the tap point. Passes `nickname`, `role`, `twitchUsername`, `labels`.
2. **`_MemberTile` (member_panel.dart):** On tap. Same anchor offset. No server-specific fields passed.
3. **`UserBar` (user_bar.dart):** On tap of the user identity area. Anchor is `Offset(pos.dx, pos.dy - 8)` with `anchorBottom: true` — card bottom aligns just above the user bar.

## _ProfileCardOverlay — Overlay Container

`_ProfileCardOverlay` is a `ConsumerStatefulWidget` with `SingleTickerProviderStateMixin`.

### Parameters (from showProfileCardPopup)
- `peerId`, `nickname`, `role`, `twitchUsername`, `labels`, `anchor`, `anchorBottom`, `onDismiss`

### Animation
`AnimationController` with 180ms duration (or `Duration.zero` when animations disabled).
- `_scaleAnim`: 0.92 -> 1.0, `Curves.easeOutCubic`
- `_fadeAnim`: 0.0 -> 1.0, `Curves.easeOut`

Card enters with simultaneous scale-up and fade-in. Dismissal reverses both animations before removing the overlay.

### Twitch Username Resolution
On `initState`, `_resolvedTwitchUsername` is initialized from `widget.twitchUsername` (passed from caller). If still null/empty, `_resolveTwitchUsername()` runs asynchronously with two fallback tiers: (1) if the card is for the local user, calls `twitchGetUsername()` (Rust FFI) to fetch the locally-authenticated Twitch username; (2) for any peer, checks `profileProvider` for the peer's stored `twitchUsername` from the profile DB (synced via `HavenMessage::ProfileUpdate`). This ensures the badge appears even when CRDT member data hasn't synced.

### Providers Read
- `profileProvider` — all user profiles (avatar, banner, displayName, status, aboutMe)
- `identityProvider` — local peer ID (to determine if card is for self)
- `localNicknameProvider` — local nicknames map (for name priority resolution)
- `friendsProvider` (via `_FriendActionButton`) — friend relationship state

## Screen Positioning Logic

Card width is fixed at 280px.

### Horizontal Clamping
- `left = anchor.dx`, clamped to `[8, screenWidth - cardWidth - 8]` to prevent overflow off either screen edge.

### Vertical Positioning
- **`anchorBottom == false` (default):** `top = anchor.dy`, clamped to minimum 8px from top edge. Card grows downward.
- **`anchorBottom == true`:** `bottom = screenHeight - anchor.dy`, clamped to minimum 8px from bottom edge. Card grows upward. Used by UserBar.

## Dismiss Barrier

A `Positioned.fill` `GestureDetector` with `HitTestBehavior.opaque` covers the entire screen behind the card. Tapping anywhere outside the card triggers `_dismiss()`.

`_dismiss()` reverses the animation controller, then calls `widget.onDismiss()` (which removes and disposes the overlay entry) in the `.then()` callback.

## Profile Card Content Layout

The card is a `Container` with:
- Width: 280px
- Background: `hollow.surface` at 0.96 alpha
- Border: `hollow.accent` at 0.15 alpha
- Border radius: `hollow.radiusLg`
- Shadow: black at 0.35 alpha, 28px blur, 8px Y offset
- `Clip.antiAlias` for rounded corners

### Banner Section (80px)

If `profile.bannerBytes` is non-null and non-empty, renders an `AnimatedGifImage` (supports animated GIF/WebP banners) at 80px height, `BoxFit.cover`, with a gradient fallback on error.

If no banner image, renders a `LinearGradient` container using `_bannerColorFromId(peerId)`:
- Hash-based deterministic hue: `(id.hashCode % 360).abs() + 40) % 360`
- HSL: saturation 0.45, lightness 0.35
- Gradient from `bannerColor` to `bannerColor.withAlpha(0.7)` (topLeft -> bottomRight)

### Content Section (overlaps banner by -32px via Transform.translate)

Padded with `HollowSpacing.md` horizontal.

#### Avatar
`HollowAvatar` at 64px size with `animate: true` (supports animated avatars). Wrapped in a `Container` with `hollow.surface` 3px border and `radiusMd + 2` border radius for the cutout ring effect.

#### Name Display
Priority resolution for the primary displayed name:
1. **Local nickname** (`localNicknames[peerId]`)
2. **Server nickname** (`widget.nickname`)
3. Falls through to `shownName`

`shownName` is: `displayName` from profile if non-empty, otherwise first 8 chars of peerId + "...".

**When local nick or server nick exists (hasSecondary):** Two lines:
- Primary: the nickname, `HollowTypography.subheading` at 15px, w700, `textPrimary`
- Secondary: the profile `shownName`, `HollowTypography.caption` at 11px, `textSecondary`

**When no nickname:** Single line showing `shownName` in the primary style.

Both are centered and single-line with ellipsis overflow.

#### Role Badge
Shown only when `role != null && role.isNotEmpty && role != 'member'`. Renders a pill badge:
- Background: role color at 0.15 alpha
- Text: capitalized role name, caption at 10px, w600, full role color
- Border radius: `HollowRadius.sm`

Role colors via `_roleColor()`:
- `owner` -> `hollow.warning` (gold)
- `admin` -> `Color(0xFFA78BFA)` (purple)
- `moderator` -> `Color.lerp(hollow.warning, hollow.error, 0.5)` (orange)
- default -> `hollow.textSecondary`

#### Label Badges
Shown only when `labels` list is non-null and non-empty. Uses `Wrap` with 4px spacing, center alignment. Each label is a pill badge:
- Color parsed from `l.color` hex string via `_parseLabelColor()` (strips "#", parses 6-digit hex; falls back to `Color(0xFF78909C)` / blue-grey)
- Background: parsed color at 0.15 alpha
- Text: `l.name`, caption at 10px, w600, full parsed color
- Border radius: `HollowRadius.sm`

#### Twitch Badge
Shown when `_resolvedTwitchUsername` is non-null and non-empty. Renders a clickable pill:
- Background: `Color(0xFF9146FF)` (Twitch purple) at 0.15 alpha
- Row: `SimpleIcons.twitch` (11px, Twitch purple) + username text (caption at 10px, w600, Twitch purple)
- On tap: opens `https://twitch.tv/$username` in external browser via `launchUrl()`

Note: Three resolution tiers — (1) passed from caller (CRDT member data via `_ServerMemberTile`), (2) local Twitch OAuth token for self, (3) profile DB fallback for any peer. Disconnecting Twitch clears the CRDT username on all servers AND the profile DB field.

#### Status Text
Shown when `profile.status` is non-empty. Italic caption at 11px, `textSecondary`, centered, single-line ellipsis.

#### Divider
1px `hollow.border` container, full width.

#### About Me Section
Shown when `profile.aboutMe` is non-empty:
- "ABOUT ME" header: caption at 9px, w700, letter-spacing 0.5, `textSecondary`
- Body: caption at 11px, `textSecondary`, centered, max 4 lines with ellipsis

## Self vs Non-Self Actions

### Self (isMe == true)
Shows an "Edit Profile" button:
- `HollowButton.outline()`, compact, with `LucideIcons.pencil` icon
- On tap: gets navigator context, dismisses the card, then calls `showUserSettingsDialog(navContext, ref)`

### Non-Self (isMe == false)
Shows two action buttons:

#### Set Nickname Button
`HollowButton.ghost()`, compact. Watches `localNicknameProvider` to determine icon and label:
- **Has existing nickname:** `LucideIcons.pencil` + "Edit Nickname"
- **No nickname:** `LucideIcons.tag` + "Set Nickname"

On tap: dismisses card, opens `showLocalNicknameDialog()` with current nickname.

#### _FriendActionButton
State-aware button that reads `friendsProvider`:

**Not a friend (`friendInfo == null`):**
- `HollowButton.outline()` with `LucideIcons.userPlus` + "Add Friend"
- On tap: `friendsProvider.notifier.sendRequest(peerId)`

**Pending outgoing (`status == 'pending', direction != 'incoming'`):**
- `HollowButton.ghost()` with `LucideIcons.clock` + "Request Sent"
- `onPressed: null` (disabled/non-interactive)
- Text and icon colored `textSecondary`

**Pending incoming (`status == 'pending', direction == 'incoming'`):**
- `HollowButton.filled()` with `LucideIcons.check` + "Accept Request"
- On tap: `friendsProvider.notifier.acceptRequest(peerId)`

**Accepted friend:**
- Not a button — renders a centered Row with `LucideIcons.userCheck` (14px, success) + "Friends" text (12px, w600, success)

## Peer ID Footer

A tappable footer at the card's very bottom (translated -28px upward to tuck into the content area):
- Shows last 8 characters of peerId in monospace (`HollowTypography.mono`, 8px, `textSecondary` at 0.35 alpha)
- Preceded by `LucideIcons.copy` (8px, same low-alpha color)
- On tap: copies full `widget.peerId` to clipboard, shows `HollowToast` "Peer ID copied" (success type, 1s duration)

## _LocalNicknameDialog — Set/Edit Local Nickname

Opened by `showLocalNicknameDialog()` via `showHollowDialog()`.

`_LocalNicknameDialog` is a `ConsumerStatefulWidget` with a `TextEditingController`.

### Parameters
- `peerId` (String) — target peer
- `currentNickname` (String) — pre-filled value

### Layout
300px wide container, `hollow.surface` background, `radiusLg` corners, border.
- Title: "Set Nickname" (subheading, w600)
- Subtitle: "Only visible to you" (caption, 11px, textSecondary)
- `HollowTextField`: hint "Nickname (leave empty to clear)", max 32 chars, autofocus, submit on enter
- Buttons: "Cancel" ghost + "Save" filled

### Save Logic
Trims the text, calls `localNicknameProvider.notifier.setNickname(peerId, nickname)`, then pops. Setting an empty string effectively clears the nickname.

## _bannerColorFromId() — Deterministic Banner Color

`Color _bannerColorFromId(String id)` generates a consistent banner gradient color from a peer ID:
- `hue = ((id.hashCode % 360).abs() + 40) % 360` — shifts by 40 degrees from the avatar hash hue
- Returns `HSLColor.fromAHSL(1.0, hue, 0.45, 0.35).toColor()` — muted, dark tone suitable for banner backgrounds

---

# UserBar — Bottom Identity Panel

Source: `lib/src/ui/shell/user_bar.dart` (293 lines)

## UserBar Widget Overview

`UserBar` is a `ConsumerWidget` that renders the local user's identity and connection status at the bottom of the channel sidebar. It mirrors Discord's bottom-left user panel.

### Providers Read
- `identityProvider` — local peer ID + mnemonic
- `nodeProvider` — node-level connection status (`NodeStatus`)
- `selectedServerProvider` — currently selected server (for server-specific sync status)
- `profileProvider` — all user profiles (for local user display name and avatar)
- `invisibleModeProvider` — whether local user is invisible
- `serverSyncStatusProvider(serverId)` (conditional) — per-server sync status
- `peersProvider` (conditional) — connected peers count
- `serverMembersProvider(serverId)` (conditional) — server member list for online count
- `roomBudgetProvider` — relay room budget usage

## Status Derivation Logic

The UserBar derives `statusText`, `statusColor`, and `statusPulse` through a three-tier priority:

### Tier 1: Invisible Mode
If `amInvisible` is true:
- Text: "Invisible"
- Color: `hollow.textSecondary`
- Pulse: false

### Tier 2: Server Selected
When `selectedServerId != null`, reads `serverSyncStatusProvider(selectedServerId)` and computes `onlineCount` (members that are connected peers, excluding local user).

Applies an adjustment: if `syncStatus == idle` and `onlineCount == 0`, overrides effective status to `connecting` (no peers means still finding the server).

Status mapping:
- `connecting` -> "Connecting...", `textSecondary`, pulse
- `syncing` -> "Syncing...", `accent`, pulse
- `synced` / `idle` -> "Online", `success`, pulse
- `retrying` -> "Retrying...", `warning`, pulse
- `failed` -> "Sync failed", `error`, no pulse

### Tier 3: No Server Selected
Falls back to node-level `NodeStatus`:
- `connected` -> "Online", `success`, pulse
- `starting` -> "Connecting...", `warning`, no pulse
- `loading` -> "Loading...", `textSecondary`, no pulse
- `error` -> "Error", `error`, no pulse

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
