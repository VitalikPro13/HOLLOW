# HomeDashboard and FriendsBar

The home screen shown in Dock layout mode when no server or DM is selected. `HomeDashboard` is the main content area; `FriendsBar` is the 44px horizontal strip across the top of the Dock layout showing friend avatars with status dots.

Source files:
- `lib/src/ui/shell/home_dashboard.dart` — HomeDashboard and all sub-widgets
- `lib/src/ui/shell/friends_bar.dart` — FriendsBar, _FriendsManager dialog, _FriendChip

---

## HomeDashboard — Top-Level Layout

`home_dashboard.dart:HomeDashboard` is a `ConsumerWidget` rendering a three-column horizontal layout inside a `Container` with `hollow.background` color and `HollowSpacing.xl` padding on all sides.

**Three columns:**
- Left: `_ProfileColumn` — fixed width 240px
- Center: `_RecentConversationsColumn` — `Expanded`, fills remaining space
- Right: `_NetworkColumn` — fixed width 260px

Columns are separated by 1px vertical dividers (`hollow.border` color) with `HollowSpacing.lg` horizontal padding on each side.

**Startup reveal animations:** Each column gets a staggered fade + slide-up reveal via `StartupRevealScope.interval()`:
- Left column: interval `(0.30, 0.55)`
- Center column: interval `(0.35, 0.60)`
- Right column: interval `(0.40, 0.65)`

When `StartupRevealScope.interval()` returns non-null, each column is wrapped in `FadeTransition` + `SlideTransition` with `Offset(0, 0.08)` begin and `Offset.zero` end. When null (reveal already completed), columns render without animation wrappers.

**Providers read:** None directly in HomeDashboard build — provider reads happen in child column widgets.

---

## _ProfileColumn — Left Column (User Profile Card)

`home_dashboard.dart:_ProfileColumn` is a `ConsumerWidget` (width constrained to 240px by parent). Displays the local user's identity, profile, and recovery status.

**Providers read:**
- `identityProvider` — `identity.peerId`, `identity.mnemonic`
- `nodeProvider` — `nodeState.status` for online detection
- `profileProvider` — `profiles[localPeerId]` for display name, avatar, status text, about me
- `invisibleModeProvider` — `amInvisible` flag

**Layout (Column, center-aligned):**

1. **Avatar (72px):** `HollowAvatar(peerId: localPeerId, size: 72, imageBytes: profile.avatarBytes, animate: true)`. If `localPeerId` is null, shows a 72x72 placeholder container with `hollow.elevated` color and `radiusLg` corners.

2. **Display name:** `displayNameFor(profiles, localPeerId)` or `'Loading...'`. Styled as `HollowTypography.heading`, fontSize 18, single line with ellipsis.

3. **Online status row:** `StatusDot` (size 8) + text label. Three states:
   - Invisible mode (`amInvisible == true`): dot color `hollow.textSecondary`, no pulse, text "Invisible"
   - Online (`isOnline && !amInvisible`): dot color `hollow.success`, pulse enabled, text "Online"
   - Offline: dot color `hollow.textSecondary`, no pulse, text "Offline"

4. **Twitch badge (conditional):** `FutureBuilder<String?>` calling `twitch_api.twitchGetUsername()`. If username is non-null and non-empty, shows a tappable badge with Twitch purple (#9146FF) background at 15% opacity, `SimpleIcons.twitch` icon (11px), and username text (10px, w600). Tap opens `https://twitch.tv/$username` in external browser via `launchUrl`.

5. **Custom status text (conditional):** If `profile.status` is non-empty, displays italic text (12px) in `hollow.textSecondary`, center-aligned, max 2 lines with ellipsis.

6. **About Me section (conditional):** If `profile.aboutMe` is non-empty:
   - Divider above and below (1px `hollow.border` with `HollowSpacing.md` vertical + `HollowSpacing.lg` horizontal padding)
   - Text wrapped in curly quotes: `"“$aboutMe”"`, italic, 12px, center-aligned, max 4 lines with ellipsis
   - If aboutMe is empty, renders `SizedBox(height: HollowSpacing.lg)` instead

7. **Recovery phrase status card:** Full-width container with `hollow.surface` background, `radiusMd` corners, `hollow.border` border. Two states based on `identity.mnemonic`:

   - **Not backed up (`identity.mnemonic != null`):** Wrapped in `HollowPressable` that calls `showMnemonicDialog(context, identity.mnemonic!)` on tap. Shows `LucideIcons.shieldAlert` (14px, `hollow.warning`), title "Recovery Phrase" (12px, w500), subtitle "Not backed up -- tap to view" (10px, `hollow.warning`).

   - **Secured (`identity.mnemonic == null`):** Static row (not tappable). Shows `LucideIcons.shieldCheck` (14px, `hollow.success`), title "Recovery Phrase" (12px, w500), subtitle "Secured" (10px, `hollow.success`).

8. **Spacer** pushes peer ID to bottom.

9. **Peer ID (copyable, bottom):** Only shown when `localPeerId != null`. `HollowPressable` with `hollow.elevated` hover color. On tap, copies full peer ID to clipboard and shows `HollowToast` "Peer ID copied" (success, 1s duration). Display text truncates to `first8...last6` if length > 16. Styled as `HollowTypography.mono`, 9px, `hollow.textSecondary`. Prefixed with `LucideIcons.copy` (10px).

---

## _RecentConversationsColumn — Center Column (DM History)

`home_dashboard.dart:_RecentConversationsColumn` is a `ConsumerWidget`. Shows all accepted friends sorted by most recent message.

**Providers read:**
- `friendsProvider` — filter to `status == 'accepted'`
- `chatProvider` — `chatHistory[peerId]` for message lists
- `profileProvider` — display names and avatars
- `peersProvider` — online detection
- `invisiblePeersProvider` — exclude invisible peers from online status
- `unreadProvider` — `unreadState.dmUnreadCounts[peerId]`

**Data model:** `_ConversationInfo` — holds `peerId`, `lastMessage` (nullable `ChatMessage`), `timestamp` (DateTime, defaults to `DateTime(2000)` if no messages), `isOnline` (bool), `unreadCount` (int).

**Sort order:** Conversations sorted by `timestamp` descending (most recent first). The timestamp comes from the last message in `chatHistory[peerId]`; if no messages exist, it falls back to `DateTime(2000)`, placing message-less friends at the bottom.

**Header:** Row with `LucideIcons.messageCircle` (18px) + "Recent Conversations" (`HollowTypography.subheading`, w600).

**Empty state:** Centered column with large `LucideIcons.messageCircle` (40px, 20% alpha), "No conversations yet" body text, "Add a friend to start chatting" caption.

**Conversation list:** `ListView.builder` with zero padding. Each item is a `HollowPressable` with `radiusMd` corners and `hollow.elevated` hover color.

**Conversation tile layout (Row):**
1. **Avatar stack:** `HollowAvatar(peerId, size: 36)` with `StatusDot` overlay at bottom-right (8px dot inside 12px background circle using `hollow.background`). Dot pulses when online.

2. **Name + last message (Expanded Column):**
   - Name: 13px, bold (w600) if unread, normal (w400) otherwise
   - Last message preview (if exists): `Text.rich` with optional "You: " prefix (w600) + message text. Caption style, 11px, single line ellipsis.

3. **Timestamp (right side):** Only shown when `lastMessage != null`. Formatted via `_formatTime()`:
   - Same day: `HH:mm` (24-hour, zero-padded)
   - Yesterday: literal "Yesterday"
   - Older: `M/D` format

4. **Unread badge (right side):** Only shown when `unreadCount > 0`. Red pill badge (`hollow.error`), 18px height, min-width 18px. Shows count or "99+" if over 99. White text, 10px, w700.

**Tap action:** Sets `selectedPeerProvider` to `conv.peerId`, clears `selectedServerProvider` to null, clears `channelListProvider` and `selectedChannelProvider`, then calls `unreadProvider.notifier.markDmSeen(conv.peerId, null)`.

---

## _ConversationInfo — Data Class

`home_dashboard.dart:_ConversationInfo` is an immutable data holder used internally by `_RecentConversationsColumn`.

Fields: `peerId` (String), `lastMessage` (ChatMessage?), `timestamp` (DateTime), `isOnline` (bool), `unreadCount` (int).

---

## _NetworkColumn — Right Column (Network Status)

`home_dashboard.dart:_NetworkColumn` is a `ConsumerWidget` (width constrained to 260px by parent). Shows connection status, friend categorization, relay stats, news, and online user count.

**Providers read:**
- `nodeProvider` — `nodeState.status` for connection state
- `peersProvider` — peer count, per-peer online detection
- `friendsProvider` — accepted friends list
- `profileProvider` — display names and avatars for connection rows
- `relayStatsProvider` — relay server metrics
- `connectionStatusProvider` — per-peer connection stage details

**Header:** Row with `LucideIcons.activity` (18px) + "Network" (`HollowTypography.subheading`, w600).

**Node status card:** Full-width container with `hollow.surface` background, `radiusMd` corners, `hollow.border` border. Contains:
- `StatusDot` (8px): green + pulse when online, `hollow.warning` when not
- Status label: "Connected" when online, otherwise maps `NodeStatus` via `_nodeLabel()`: starting -> "Starting...", loading -> "Loading...", error -> "Error"
- Peer count: `"N peer(s) reachable"` (pluralized)

**Friend categorization:** Accepted friends are split into three buckets using `connectionStatusProvider`:

1. **Encrypted friends** (`encryptedFriends`): `peers[peerId].isEncrypted == true`. Shown as a `_CounterRow` with `LucideIcons.shieldCheck`, label "Encrypted", `hollow.success` color.

2. **Active friends** (`activeFriends`): Either `connectionStatus.stage` is `connected`/`keyExchange`, OR peer exists in `peersProvider` but is not encrypted (treated as `keyExchange`). Each rendered as a `_ConnectionRow` with avatar, name, stage label, spinner (if not failed/encrypted), and status color (`hollow.error` for failed, `hollow.accent` otherwise).

3. **Offline friends** (`offlineFriends`): Not in peers map and no connection status. Shown as a `_CounterRow` with `LucideIcons.wifiOff`, label "Offline", `hollow.textSecondary` color.

If no accepted friends exist, shows "No friends added" caption.

**Relay Server section:** `_SectionLabel` "RELAY SERVER" followed by `_RelayStatsCard`.

**News section:** `_SectionLabel` "NEWS" followed by `Expanded` `_NewsPanel`.

**Online Users (bottom):** Row with `LucideIcons.users` (13px), "Online" text, `_ShimmerDivider` (fills center), and `relayStats.onlineUsers` count (12px, w600).

---

## _SectionLabel — Reusable Section Header

`home_dashboard.dart:_SectionLabel` is a `StatelessWidget`. Renders uppercase label text in `HollowTypography.caption`, `hollow.textSecondary`, w600, letterSpacing 0.8, fontSize 10.

Used for "FRIENDS", "RELAY SERVER", and "NEWS" section headers in `_NetworkColumn`.

---

## _RelayStatsCard — Relay Server Metrics

`home_dashboard.dart:_RelayStatsCard` is a `StatefulWidget` with `SingleTickerProviderStateMixin`. Displays RAM usage, bandwidth usage, and a poll cycle indicator.

**Props:** `hollow` (HollowTheme), `stats` (RelayStats).

**Animation:** `AnimationController` with 7-second duration, auto-forwards on init. Resets (`forward(from: 0.0)`) when `stats.fetchCount` changes (tracked via `_lastFetchCount`), indicating a new relay stats fetch completed.

**Layout:** Full-width container, `hollow.surface` background, `radiusMd` corners, `hollow.border` border, `HollowSpacing.sm + 2` padding.

Contains three elements:
1. **RAM bar:** `_StatBar(icon: LucideIcons.memoryStick, label: 'RAM', value: stats.memLabel, progress: stats.memUsagePercent)`
2. **Bandwidth bar:** `_StatBar(icon: LucideIcons.activity, label: 'Bandwidth', value: stats.bandwidthLabel, progress: stats.bandwidthUsagePercent)`
3. **Poll cycle bar:** `AnimatedBuilder` driven by the animation controller. 3px height `LinearProgressIndicator` with `hollow.border` background and `hollow.accent` at 40% opacity as value color. Value tracks `_controller.value` (0.0 to 1.0 over 7 seconds).

---

## _StatBar — Single Stat Row with Progress Bar

`home_dashboard.dart:_StatBar` is a `StatelessWidget`. Renders a labeled progress bar with color thresholds.

**Props:** `hollow`, `icon`, `label`, `value` (display string), `progress` (0.0-1.0).

**Color thresholds:**
- `progress < 0.60`: `hollow.accent` (normal/healthy)
- `progress < 0.85`: `hollow.warning` (elevated usage)
- `progress >= 0.85`: `hollow.error` (critical usage)

**Layout:**
- Top row: icon (12px) + label text (10px, w500, `hollow.textSecondary`) + spacer + value text (10px, `hollow.textPrimary`)
- Below: 4px height progress bar. Uses `TweenAnimationBuilder<double>` animating from 0 to clamped progress over `HollowDurations.slow` with `Curves.easeOutCubic`. Stack of border-colored background + `FractionallySizedBox` foreground with `barColor` and 2px border radius.

---

## _NewsPanel — Developer News and Version Info

`home_dashboard.dart:_NewsPanel` is a `ConsumerWidget`. Fetches and displays developer posts and version information.

**Providers read:**
- `newsProvider` — `news.posts` list of `NewsPost` objects
- `updaterProvider` — `updateState.currentVersion`, `updateState.manifest`
- `hasUpdateProvider` — boolean indicating available update

**Empty state:** Returns `SizedBox.shrink()` if `news.posts` is empty.

**Layout:** Column containing:
1. `_SectionLabel` "NEWS"
2. Expanded container with `hollow.surface` background, `radiusMd` corners, `hollow.border` border.

**Inside the container (Column):**
1. **Posts area (Expanded, scrollable):** Takes first 2 posts via `news.posts.take(2)`. Each rendered as `_NewsPostEntry`. Posts separated by a 1px divider at 20% border alpha with `HollowSpacing.sm` spacing.

2. **Divider:** 1px at 30% border alpha.

3. **Version row (bottom):** Contains:
   - "Installed" label (9px caption) + version badge (`v{currentVersion}`, 10px, w700, `hollow.textSecondary` with 10% alpha background, 25% alpha border)
   - If update available (`hasUpdate && manifest != null`): arrow icon (`LucideIcons.arrowRight`, 12px, `hollow.accent`) + tappable "Latest" label + version badge (`v{manifest.latest}`, 10px, w700, `hollow.accent` with 20% alpha background, 40% alpha border). Tap opens user settings dialog at updates tab via `showUserSettingsDialog(context, ref, openUpdatesTab: true)`.
   - Spacer + refresh button (`LucideIcons.refreshCw`, 12px). Tap runs `Future.wait` of `newsProvider.notifier.refresh()` and `updaterProvider.notifier.checkForUpdates()`. Shows error toast "Failed to fetch news -- check your connection" if news refresh returns false.

---

## _NewsPostEntry — Single News Post

`home_dashboard.dart:_NewsPostEntry` is a `StatelessWidget`. Renders a single `NewsPost` with title, date, and markdown body.

**Layout:**
- Title: `HollowTypography.body`, 12px, w600, `hollow.textPrimary`
- Date: `HollowTypography.caption`, 10px, `hollow.textSecondary`
- Body: `MarkdownBody` (from `flutter_markdown`) with `shrinkWrap: true`, `selectable: true`. Links open in external browser via `launchUrl`.

**Markdown style sheet:**
- Paragraph: 11px, line height 1.5
- h2: 13px heading
- h3: 12px heading
- List bullets: 11px, `hollow.textSecondary`
- Strong: 11px, w700
- Links: 11px, `hollow.accent`, underlined
- Block spacing: 8px
- Horizontal rule: top border at 50% border alpha

---

## _ShimmerDivider — Animated Teal Sweep Divider

`home_dashboard.dart:_ShimmerDivider` is a `StatelessWidget`. Renders a 1px horizontal divider with a looping shimmer effect.

Uses `SharedTickers.instance.shimmer` (`ValueListenable<double>`) for animation, avoiding per-instance `AnimationController`. The shimmer position is computed as `value * 4.0 - 1.5`, creating a sweep from left to right.

Gradient: `LinearGradient` from `hollow.border` through `hollow.accent` at 60% opacity back to `hollow.border`, positioned using the animated offset via `Alignment(pos - 0.5, 0)` to `Alignment(pos + 0.5, 0)`.

---

## _ConnectionRow — In-Progress Friend Connection

`home_dashboard.dart:_ConnectionRow` is a `StatelessWidget`. Shows a single friend whose connection is actively being established (key exchange, etc.).

**Props:** `hollow`, `peerId`, `name`, `status` (stage label string), `statusColor`, `showSpinner` (bool), `avatarBytes`.

**Layout:** Container with `hollow.surface` background, `radiusSm` corners, `hollow.border` border. Row containing:
- `HollowAvatar(peerId, size: 20)`
- Name text (11px caption, single line ellipsis)
- Spinner (conditional): 10x10 `CircularProgressIndicator` with 1.5 stroke width in `statusColor`
- Status label text (10px, w500, `statusColor`)

The spinner is shown when `showSpinner == true` (connection stage is not failed and not encrypted).

---

## _CounterRow — Summary Counter

`home_dashboard.dart:_CounterRow` is a `StatelessWidget`. Compact row showing an icon + label on the left and a count on the right.

**Props:** `hollow`, `icon`, `label`, `count`, `color`.

Used for "Encrypted" (success green, `LucideIcons.shieldCheck`) and "Offline" (textSecondary, `LucideIcons.wifiOff`) friend counts in `_NetworkColumn`.

---

## FriendsBar — Horizontal Friend Strip

`friends_bar.dart:FriendsBar` is a `ConsumerWidget`. Renders a 44px tall horizontal bar at the top of the Dock layout. Contains an "Add Friend" button, a vertical divider, and a horizontally scrolling list of friend chips.

**Providers read:**
- `friendsProvider` — all friend entries
- `peersProvider` — online peer detection
- `invisiblePeersProvider` — exclude invisible peers from online status
- `profileProvider` — display names and avatars
- `unreadProvider` — `unreadState.dmUnreadCounts[peerId]`
- `notificationSettingsProvider.notifier` — `isDmEnabled(peerId)` check for unread filtering
- `selectedPeerProvider` — highlight currently selected friend
- `favouriteFriendsProvider` — custom friend ordering

**Container:** Height 44px, `hollow.surface` background (alpha 1.0), bottom border in `hollow.border`.

**Sorting logic for accepted friends:** Online first (not invisible), then alphabetical by display name. Online detection: `peers.containsKey(peerId) && !invisiblePeers.contains(peerId)`.

**Favourites override:** If `favouriteFriendsProvider` returns a non-empty list, only those friends are displayed (in their custom order), filtered to valid accepted friends. Otherwise, all accepted friends are shown in the default online-first alphabetical order.

**Pending request badge:** Counts friends with `status == 'pending' && direction == 'incoming'`. If > 0, a red circle (14px, `hollow.error`, 2px `hollow.surface` border) overlays the top-right of the Add Friend button, showing the count in white 8px w700 text.

**Layout (Row):**
1. `HollowSpacing.sm` left padding
2. **Add Friend button:** `HollowTooltip(message: 'Add Friend')` wrapping `HollowPressable` with `LucideIcons.userPlus` (18px, `hollow.textSecondary`). Tap calls `_showAddFriendDialog()`.
3. Vertical divider: 1px wide, 24px tall, `hollow.border` color, `HollowSpacing.sm` horizontal margin.
4. **Friends list (Expanded):** If `displayList` is empty, shows "No friends yet" caption. Otherwise, horizontal `ListView.builder` rendering `_FriendChip` widgets with `HollowSpacing.xs` horizontal padding.

**Friend selection (`_selectFriend`):** Checks `splitViewProvider` — if split mode is active and focus is on pane 1 (right), calls `navigateRightToPeer(peerId)`. Otherwise:
- Sets `archiveTabOpenProvider` and `shareTabOpenProvider` to false
- Sets `selectedPeerProvider` to peerId
- Clears `selectedServerProvider`, `channelListProvider`, `selectedChannelProvider`, `serverSettingsOpenProvider`
- Calls `unreadProvider.notifier.markDmSeen(peerId, null)`

---

## _FriendChip — Individual Friend Avatar in Bar

`friends_bar.dart:_FriendChip` is a `StatelessWidget`. Renders a single friend as a compact chip in the horizontal FriendsBar.

**Props:** `peerId`, `name`, `isOnline`, `isSelected`, `unreadCount`, `avatarBytes`, `onTap`.

**Layout:** `HollowTooltip(message: name)` wrapping `HollowPressable` with `hollow.elevated` hover color. Selected state: `hollow.accent` at 15% alpha background. Padding: `HollowSpacing.sm` horizontal, 4px vertical. Horizontal margin: 3px.

**Contents (Row):**
1. **Avatar stack:**
   - `HollowAvatar(peerId, size: 24, imageBytes: avatarBytes)`
   - `StatusDot` overlay at bottom-right (-2, -2): 7px dot inside 10px `hollow.surface` circle. Green + pulse when online, `hollow.textSecondary` when offline.
   - **Unread indicator (conditional):** If `unreadCount > 0`, red pill badge at top-left (-4, -4). 16px height, min-width 16px, `hollow.error` color with 1.5px `hollow.surface` border. Count text (or "99+" if > 99) in white, 9px, w700.

2. **Name text:** `ConstrainedBox(maxWidth: 72)`. Caption style, 11px. `hollow.textPrimary` if selected, `hollow.textSecondary` if not. Bold (w600) if unread, normal (w400) otherwise. Single line ellipsis.

---

## _FriendsManager — Full Friends Dialog

`friends_bar.dart:_FriendsManager` is a `ConsumerStatefulWidget`. A modal dialog opened by the Add Friend button in FriendsBar. Contains 5 tabs for managing all friend relationships.

**Dialog opening:** `_showAddFriendDialog()` uses `showGeneralDialog` with:
- `barrierDismissible: true`, `barrierColor: Colors.black` at 50% alpha
- Transition: `HollowDurations.normal`, fade + scale from 0.95 to 1.0, `Curves.easeOut`

**State:** `_activeTab` (`_FriendsTab` enum: `friends`, `favourites`, `incoming`, `outgoing`, `add`). Default: `_FriendsTab.friends`. `_addController` (`TextEditingController`) for the Add Friend input, disposed in `dispose()`.

**Providers read:**
- `friendsProvider` — categorized into `accepted`, `incoming`, `outgoing`
- `peersProvider` + `invisiblePeersProvider` — online sorting for accepted list

**Sorting for accepted friends:** Online first (respecting invisible peers), then alphabetical by peer ID.

**Dialog container:** 520px wide, 480px tall, `hollow.background` color, `radiusLg` corners, `hollow.border` border, drop shadow (black 30% alpha, blur 24, offset (0,8)).

**Layout (Column):**
1. **Header (48px):** `LucideIcons.users` (18px) + "Friends" title (subheading, w600) + spacer + close button (`LucideIcons.x`, 18px, calls `Navigator.pop`).

2. **Tab bar (40px):** `hollow.surface` background with bottom border. Row of 5 `_TabButton` widgets:
   - "Friends" — shows `accepted.length` count
   - "Favourites" — shows `favouriteFriendsProvider.length` count, icon `LucideIcons.star`
   - "Incoming" — shows `incoming.length` count, `showBadge: incoming.isNotEmpty` (red badge)
   - "Outgoing" — shows `outgoing.length` count
   - "Add Friend" — no count, icon `LucideIcons.userPlus`

3. **Tab content (Expanded):** `AnimatedSwitcher` with `HollowDurations.fast`. Switch expression maps `_activeTab` to:
   - `_FriendsTab.friends` -> `_FriendsListTab(accepted: accepted)`
   - `_FriendsTab.favourites` -> `_FavouritesReorderTab(accepted: accepted)`
   - `_FriendsTab.incoming` -> `_RequestsTab(requests: incoming, direction: 'incoming')`
   - `_FriendsTab.outgoing` -> `_RequestsTab(requests: outgoing, direction: 'outgoing')`
   - `_FriendsTab.add` -> `_AddFriendTab(controller: _addController)`

---

## _TabButton — Tab Bar Button

`friends_bar.dart:_TabButton` is a `StatelessWidget`. A pressable tab in the `_FriendsManager` tab bar.

**Props:** `label`, `count` (nullable int), `isActive`, `showBadge` (default false), `icon` (nullable IconData), `onTap`.

**Rendering:** `HollowPressable` with `radiusSm` corners. Row containing:
- Optional icon (13px, accent if active, textSecondary if not)
- Label text (12px caption, accent + w600 if active, textSecondary + w400 if not)
- Optional count badge: pill container with count text. Background: `hollow.error` if `showBadge` is true, otherwise 15% alpha of active color. Text color: white if `showBadge`, otherwise active color. 10px, w600.

---

## _FriendsListTab — All Friends Tab

`friends_bar.dart:_FriendsListTab` is a `ConsumerWidget`. Shows all accepted friends with favourite toggle and remove buttons.

**Props:** `accepted` (List<FriendInfo>).

**Providers read:** `profileProvider`, `peersProvider`, `invisiblePeersProvider`, `favouriteFriendsProvider` (via Builder).

**Empty state:** Centered column with `LucideIcons.users` (40px, 30% alpha), "No friends yet", "Add a friend by their peer ID".

**List:** `ListView.builder` with `HollowSpacing.md` padding. Each item is a container with `hollow.elevated` background, `radiusMd` corners.

**Item layout (Row):**
1. **Avatar stack:** `HollowAvatar(peerId, size: 32)` with `StatusDot` overlay at bottom-right (7px dot inside 10px circle, `hollow.elevated` background).
2. **Name + status (Expanded Column):** Name (13px, w500), online status text (10px, green if online, textSecondary if offline).
3. **Favourite toggle button:** `HollowTooltip` ("Add to favourites" / "Remove from favourites"). `LucideIcons.star` (16px), `hollow.warning` if favourited, `hollow.textSecondary` at 40% alpha if not. Calls `favouriteFriendsProvider.notifier.toggle(peerId)`.
4. **Remove friend button:** `HollowTooltip` "Remove friend". `LucideIcons.userMinus` (16px, `hollow.error`). On tap:
   - Calls `friendsProvider.notifier.removeFriend(peerId)`
   - Calls `favouriteFriendsProvider.notifier.remove(peerId)`
   - If `selectedPeerProvider == peerId`, clears selection to null
   - If split view right pane shows this peer, calls `splitViewProvider.notifier.closeSplit()`

---

## _FavouritesReorderTab — Drag-to-Reorder Favourites

`friends_bar.dart:_FavouritesReorderTab` is a `ConsumerWidget`. Shows starred friends in a reorderable list.

**Props:** `accepted` (List<FriendInfo>).

**Providers read:** `favouriteFriendsProvider`, `profileProvider`, `peersProvider`, `invisiblePeersProvider`.

**Filtering:** `validFavs` = favourites list filtered to IDs present in accepted friends set (removes stale entries).

**Empty state:** Centered column with `LucideIcons.star` (40px, 30% alpha), "No favourites yet", "Star a friend in the Friends tab to add them here".

**List:** `ReorderableListView.builder` with `HollowSpacing.md` padding, `buildDefaultDragHandles: false`.

**Drag proxy:** `proxyDecorator` wraps child in `Material` with 4px elevation, `Colors.black26` shadow, `radiusMd` corners, transparent background.

**Reorder callback:** `favouriteFriendsProvider.notifier.reorder(oldIndex, newIndex)`.

**Item layout (Row):**
1. **Drag handle:** `ReorderableDragStartListener(index: index)` wrapping `LucideIcons.gripVertical` (16px, textSecondary).
2. **Avatar:** `HollowAvatar(peerId, size: 28)`.
3. **Name + status (Expanded Column):** Name (13px, w500), online status (10px).
4. **Remove button:** `HollowTooltip` "Remove from favourites". `LucideIcons.x` (14px, textSecondary). Calls `favouriteFriendsProvider.notifier.remove(peerId)`.

---

## _RequestsTab — Incoming/Outgoing Requests

`friends_bar.dart:_RequestsTab` is a `ConsumerStatefulWidget`. Shows pending friend requests with search filtering and accept/reject actions.

**Props:** `requests` (List<FriendInfo>), `direction` ('incoming' or 'outgoing').

**State:** `_searchController` (TextEditingController), `_query` (String, initialized empty).

**Providers read:** `profileProvider`.

**Empty state:** Centered column with direction-specific icon (`LucideIcons.inbox` for incoming, `LucideIcons.send` for outgoing, both 40px at 30% alpha), and direction-specific text ("No incoming requests" / "No outgoing requests").

**Search:** `HollowTextField` with direction-specific placeholder ("Search incoming requests..." / "Search outgoing requests..."), `LucideIcons.search` prefix, isDense. Filters by display name or peer ID (case-insensitive contains).

**No matches:** "No matches" body text centered.

**List:** `ListView.builder`. Each item: container with `hollow.elevated` background, `radiusMd` corners.

**Item layout (Row):**
1. **Avatar:** `HollowAvatar(peerId, size: 32)`.
2. **Name + subtitle (Expanded Column):** Name (13px, w500), subtitle ("Wants to be friends" for incoming, "Request sent" for outgoing, 10px caption).
3. **Action buttons:**
   - **Incoming:** Accept button (`LucideIcons.check`, 16px, `hollow.success`) calling `friendsProvider.notifier.acceptRequest(peerId)` + Reject button (`LucideIcons.x`, 16px, `hollow.error`) calling `friendsProvider.notifier.rejectRequest(peerId)`. Both wrapped in `HollowTooltip`.
   - **Outgoing:** Cancel button (`LucideIcons.x`, 16px, `hollow.error`) calling `friendsProvider.notifier.rejectRequest(peerId)`. Tooltip: "Cancel request".

---

## _AddFriendTab — Add Friend by Peer ID

`friends_bar.dart:_AddFriendTab` is a `ConsumerWidget`. Input form for sending a friend request by peer ID.

**Props:** `controller` (TextEditingController, managed by parent `_FriendsManagerState`).

**Layout:** Padded with `HollowSpacing.lg`. Column containing:
1. Instruction text: "Add a friend by their peer ID" (body, textSecondary)
2. Row with:
   - `HollowTextField` (Expanded): placeholder "Paste peer ID...", `autofocus: true`, mono style (12px), `onSubmitted` triggers `_send()`
   - `HollowButton.filled`: "Send Request", triggers `_send()`

**`_send()` method:** Trims controller text. If empty, returns. Calls `friendsProvider.notifier.sendRequest(peerId)`, clears controller, shows `HollowToast` "Friend request sent" (success type).

---

## Provider Dependency Summary

**HomeDashboard subtree reads:**
- `identityProvider`, `nodeProvider`, `profileProvider`, `invisibleModeProvider` — _ProfileColumn
- `friendsProvider`, `chatProvider`, `profileProvider`, `peersProvider`, `invisiblePeersProvider`, `unreadProvider` — _RecentConversationsColumn
- `nodeProvider`, `peersProvider`, `friendsProvider`, `profileProvider`, `relayStatsProvider`, `connectionStatusProvider` — _NetworkColumn
- `newsProvider`, `updaterProvider`, `hasUpdateProvider` — _NewsPanel

**FriendsBar subtree reads:**
- `friendsProvider`, `peersProvider`, `invisiblePeersProvider`, `profileProvider`, `unreadProvider`, `notificationSettingsProvider`, `selectedPeerProvider`, `favouriteFriendsProvider` — FriendsBar
- `friendsProvider`, `peersProvider`, `invisiblePeersProvider` — _FriendsManager
- `profileProvider`, `peersProvider`, `invisiblePeersProvider`, `favouriteFriendsProvider`, `splitViewProvider` — _FriendsListTab
- `favouriteFriendsProvider`, `profileProvider`, `peersProvider`, `invisiblePeersProvider` — _FavouritesReorderTab
- `profileProvider` — _RequestsTab
- `friendsProvider` — _AddFriendTab (via ref.read for sendRequest)

**State mutations triggered:**
- `selectedPeerProvider`, `selectedServerProvider`, `channelListProvider`, `selectedChannelProvider`, `serverSettingsOpenProvider` — conversation/friend selection
- `unreadProvider.notifier.markDmSeen()` — read receipts on selection
- `friendsProvider.notifier` — sendRequest, acceptRequest, rejectRequest, removeFriend
- `favouriteFriendsProvider.notifier` — toggle, remove, reorder
- `splitViewProvider.notifier` — navigateRightToPeer, closeSplit
- `archiveTabOpenProvider`, `shareTabOpenProvider` — closed on friend selection
- `newsProvider.notifier.refresh()`, `updaterProvider.notifier.checkForUpdates()` — manual refresh
