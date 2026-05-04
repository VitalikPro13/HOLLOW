# ChannelSidebar -- Channel List and Navigation

Primary source: `lib/src/ui/shell/channel_sidebar.dart`

The ChannelSidebar is the 240px left-hand panel that shows either the server channel list (when a server is selected) or the DM friends list (home mode). It is the central navigation surface for selecting channels and peers.

## ChannelSidebar -- Top-Level StatelessWidget

`file:ChannelSidebar` extends `StatelessWidget`. It receives two complete sets of props: one for home/DM mode and one for server mode. The widget decides which content to display based on whether `selectedServer` is null.

**Home mode props:**
- `peers` -- `Map<String, PeerInfo>` of online peers
- `chatHistory` -- `Map<String, List<ChatMessage>>` for DM history
- `selectedPeerId` -- currently selected DM peer (nullable)
- `nodeStatus` -- `NodeStatus` enum (connected/disconnected)
- `onPeerSelected` -- `ValueChanged<String>` callback
- `lastMessage` -- `ChatMessage? Function(String)` for last message preview
- `formatTime` -- `String Function(DateTime)` for timestamp display

**Server mode props:**
- `selectedServer` -- `ServerInfo?` (null means home mode)
- `channels` -- `Map<String, ChannelInfo>` channel map
- `selectedChannelId` -- currently selected channel (nullable)
- `onChannelSelected` -- `ValueChanged<String>` callback
- `onCreateChannel` -- `VoidCallback` for channel creation
- `onOpenSettings` -- `VoidCallback` for server settings
- `canManageChannels` -- `bool` permission gate for create channel button
- `channelLayoutJson` -- `String` JSON array defining category/separator/channel ordering

**Layout props:**
- `width` -- `double?`, default `240`. Pass null on mobile to fill available space.
- `dockMode` -- `bool`, default `false`. When true and no server is selected, the entire sidebar renders as `SizedBox.shrink()` (invisible).
- `showUserBar` -- `bool`, default `true`. When false (dock layout), the `UserBar` at the bottom is hidden.

## Build Method -- Dual Mode and Startup Reveal

The `build()` method first checks `dockMode && selectedServer == null` -- if true, returns `SizedBox.shrink()` immediately. This is how the dock layout hides the sidebar when the user is on the home dashboard.

The sidebar uses two startup reveal animations from `StartupRevealScope`:
- `sidebarReveal` at interval `(0.12, 0.30)` -- wraps the entire sidebar in a `RevealClip` with `Axis.horizontal` + `Alignment.centerLeft` so it clips open from the left edge.
- `userBarReveal` at interval `(0.50, 0.60)` -- wraps the `UserBar` in a combined `FadeTransition` + `SlideTransition` (slides up from `Offset(0, 0.5)`).

The main container is a `Container` with `hollow.surface` background color, a right `BorderSide` (vertical divider), and a `Column` of:
1. Header (animated crossfade between server name and "Direct Messages")
2. Content area (animated crossfade between `_ServerContent` and `_HomeContent`)
3. `VoiceChannelPanel` (always present, self-hides when not in a voice channel)
4. Optional `UserBar` (null-aware `?userBar` insertion)

Both the header and the content use `AnimatedSwitcher` for crossfade transitions. The content switcher uses `HollowDurations.normal` with `HollowCurves.enter`/`HollowCurves.exit`. Each mode's content widget has a `ValueKey` so the switcher can detect changes: `ValueKey('server-${serverId}')` for server mode, `ValueKey('home')` for home mode.

## Header Area -- Server Name, Icons, and DM Label

`file:ChannelSidebar._buildHeader()` renders a 48px-high `Container` with a bottom border. Inside is a `Row` containing:

1. `TypewriterText` (from reveal_widgets) showing either the server name or "Direct Messages". Uses `HollowTypography.subheading`, `FontWeight.w600`, with `TextOverflow.ellipsis`. The typewriter animation is driven by `headerTextReveal` from `StartupRevealScope.interval(context, 0.25, 0.40)`.

2. **Server-only action icons** (conditionally rendered when `selectedServer != null`):
   - **Invite people** -- `LucideIcons.userPlus` (16px). Tapping constructs a `hollow://join?server={serverId}` link and calls `showInviteDialog(context, link, serverId)`.
   - **Storage** -- `LucideIcons.hardDrive` (16px). Tapping calls `showStorageDashboardDialog(context, serverId)`.
   - **Server settings** -- `LucideIcons.settings` (16px). Tapping calls `onOpenSettings`.

Each icon is wrapped in `HollowTooltip` > `HollowPressable` with `borderRadius: hollow.radiusSm` and `padding: HollowSpacing.xs`. Icon color is `hollow.textSecondary`.

## _ServerContent -- Channel List Display

`file:_ServerContent` extends `StatefulWidget`. Props: `hollow`, `serverId`, `channels`, `selectedChannelId`, `onChannelSelected`, `onCreateChannel`, `canManageChannels`, `channelLayoutJson`.

The `_ServerContentState.build()` method calls `_buildLayoutItems()` to produce a `List<Widget>` of channel tiles, category headers, and separators. It then checks `hasCategories` (whether any `_CategoryHeader` was produced):

- **No categories:** Shows a fallback "TEXT CHANNELS" uppercase label row with an optional `+` button (gated by `canManageChannels`), then a `Divider`, then the items `ListView`.
- **Has categories:** Skips the fallback header and goes straight to the `ListView`.

If `items` is empty, shows a centered "No channels" text instead of the `ListView`.

The `ListView` has vertical padding of `HollowSpacing.xs`.

## Channel Layout JSON Parsing -- _buildLayoutItems()

`file:_ServerContentState._buildLayoutItems()` parses `channelLayoutJson` as a `List<dynamic>` via `jsonDecode`. Each element is a JSON object with a `type` field. The parser tracks `currentCategory` (nullable string) and a `placedChannels` set.

Three item types are recognized:

**`type: "category"`** -- reads `item['name']` as the category label. Adds a `_CategoryHeader` widget. Sets `currentCategory` to this name so subsequent channels know their parent.

**`type: "separator"`** -- resets `currentCategory` to null. Adds a horizontal `Divider` wrapped in `Padding` (horizontal `HollowSpacing.lg`, vertical `HollowSpacing.sm`).

**`type: "channel"`** -- reads `item['channel_id']`. Looks up the channel in the `channels` map. If found, adds it to `placedChannels` and checks whether it should be collapsed (its `currentCategory` is non-null and `_categoryCollapsedState[currentCategory]` is true). Renders either `_VoiceChannelTile` (for `ChannelType.voice`) or `_ChannelTile` (for text channels), then wraps in `_AnimatedChannelTile` with `visible: !collapsed` and a `ValueKey('ach-$channelId')`.

After processing the JSON layout, any channels in the `channels` map NOT present in `placedChannels` are appended as "unplaced" channels. These are sorted alphabetically by `name` and rendered as either voice or text tiles without animation wrappers. This ensures newly created channels appear immediately even before the layout is synced via CRDT.

The entire parse is wrapped in `try/catch` -- malformed JSON silently falls through to the unplaced-channels section.

## Category Folding -- Collapsible Headers

Category collapsed state is stored in a **module-level** `Map<String, bool>` called `_categoryCollapsedState`. This persists across widget rebuilds and even across server switches within the same app session, since it is keyed by category name string.

`file:_CategoryHeader` extends `StatefulWidget`. Props: `hollow`, `name`, `onToggle` (nullable `VoidCallback`).

`file:_CategoryHeaderState` reads `_categoryCollapsedState[widget.name] ?? false` to determine the collapsed state. The widget renders a `HollowPressable` (subtle mode) containing:
- An `AnimatedRotation` chevron: `LucideIcons.chevronDown` (10px). When collapsed, rotates -0.25 turns (90 degrees clockwise, pointing right). When expanded, rotation is 0.
- The category name in uppercase, `HollowTypography.caption`, `FontWeight.w600`, `letterSpacing: 0.8`.

Tapping toggles `_categoryCollapsedState[widget.name]` and calls both `setState()` (to rebuild the header's chevron) and `widget.onToggle?.call()` (to trigger `setState()` on `_ServerContentState`, which rebuilds the channel list and updates visibility).

Padding: `fromLTRB(HollowSpacing.sm + 2, HollowSpacing.md, HollowSpacing.sm, HollowSpacing.xs)`.

## _AnimatedChannelTile -- Category Collapse Animation

`file:_AnimatedChannelTile` extends `StatelessWidget`. Props: `visible` (bool), `child` (Widget).

Uses `AnimatedSize` with `HollowDurations.fast` and `Curves.easeOutCubic`. When `visible` is true, the child renders at natural height. When false, forces `SizedBox(height: 0)` containing `SizedBox.shrink()`. The `AnimatedSize` smoothly transitions the height to zero, creating a folding animation.

Alignment is `Alignment.topCenter` so the collapse visually shrinks from the bottom.

## _ChannelTile -- Text Channel Rendering

`file:_ChannelTile` extends `ConsumerWidget`. Props: `channel` (ChannelInfo), `serverId`, `isSelected` (bool), `onTap` (VoidCallback).

**Unread and mute checks:**
- `isMuted` = `notificationSettingsProvider.notifier.isChannelMuted(serverId, channelId)` -- checks if the channel's effective notification level is `NotificationLevel.nothing`.
- `hasUnread` = `!isSelected && !isMuted && unreadProvider.notifier.isChannelUnread(serverId, channelId)` -- only shows unread indicator when the channel is NOT currently selected and NOT muted.

**Visual rendering:**
- Outer `Padding` with horizontal `HollowSpacing.sm`, vertical `HollowSpacing.xxs`.
- `HollowPressable` with `subtle: true`, `borderRadius: hollow.radiusMd`.
- Background: `hollow.accentMuted` when selected, `Colors.transparent` otherwise. Hover: `hollow.elevated`.
- `AnimatedDefaultTextStyle` transitions text color and weight: selected or unread channels use `hollow.textPrimary` + `FontWeight.w600`; otherwise `hollow.textSecondary` + `FontWeight.w400`.

**Row contents:**
- Channel icon: `LucideIcons.hash` for text channels, `LucideIcons.volume2` for voice (18px). Color follows the same selected/unread logic as text.
- Channel name with `TextOverflow.ellipsis`.
- Unread dot: 8x8 `Container` with `hollow.accent` color, `BoxShape.circle`. Only rendered when `hasUnread` is true.

**Selection shimmer:** When `isSelected` is true, the tile is wrapped in `SelectionShimmer` with `highlightColor: hollow.accent.withValues(alpha: 0.12)` and matching `borderRadius`.

## _VoiceChannelTile -- Voice Channel Rendering and Participants

`file:_VoiceChannelTile` extends `ConsumerStatefulWidget`. Props: `channel` (ChannelInfo), `serverId`, `onChannelSelected` (`ValueChanged<String>`).

This widget has significantly different behavior from text channel tiles:

**State management in `_VoiceChannelTileState`:**
- `_leavingPeers` -- `Set<String>` tracking peers currently animating out (kept in tree until animation finishes).
- `_prevParticipants` -- `Set<String>` of the previous frame's participant set, used for diffing to detect departures.

**Connection state:**
- `isConnected` -- true when `voiceChannelProvider.currentServerId` matches `serverId` AND `currentChannelId` matches the channel.
- `participants` -- `vcState.getParticipants(serverId, channelId)` returns the current set of peer IDs in this voice channel.

**Leave detection:**
Each build compares `_prevParticipants` with current `participants`. Any peer in `_prevParticipants` not in `participants` is added to `_leavingPeers`. The `visible` list is `[...participants, ..._leavingPeers]` so leaving peers remain in the tree during their fade-out animation.

**Tap behavior:**
- If already connected to this voice channel, tapping calls `onChannelSelected(channelId)` to select it in the main pane (for viewing voice channel text chat).
- If NOT connected, tapping calls `voiceChannelProvider.notifier.joinChannel(serverId, channelId)` to join the voice channel.

**Visual rendering:**
- Same outer padding as `_ChannelTile`.
- `HollowPressable` row with `LucideIcons.volume2` (18px, accent color when connected, textSecondary otherwise) + channel name.
- Selection shimmer wraps the row when connected, with `vertical: true`.

**Participant list:**
Below the channel row, an `AnimatedSize` container (duration: `HollowDurations.normal`, `Curves.easeOutCubic`) holds a `Column` of `_AnimatedParticipantRow` widgets. The column is left-padded by `HollowSpacing.sm + 2 + 18 + HollowSpacing.sm` to align under the channel name (past the volume icon).

Each participant row has `ValueKey('vp-$peerId')` and passes `leaving: _leavingPeers.contains(peerId)`. When a leave animation completes, `onLeaveComplete` removes the peer from `_leavingPeers` via `setState()` (guarded by `mounted` check).

## _AnimatedParticipantRow -- Fade In/Out for Voice Participants

`file:_AnimatedParticipantRow` extends `StatefulWidget` with `SingleTickerProviderStateMixin`. Props: `child`, `leaving` (bool), `onLeaveComplete` (nullable VoidCallback).

Uses a 180ms `AnimationController` (or `Duration.zero` when animations are disabled via `HollowDurations.animationsDisabled`).

**Init behavior:**
- If `leaving` is true at init, the controller starts at 1.0 and reverses. When reverse completes, calls `onLeaveComplete`.
- If not leaving, the controller forwards from 0.0 to 1.0 (fade in).

**Update behavior:**
When `leaving` transitions from false to true (via `didUpdateWidget`), starts reverse animation and calls `onLeaveComplete` when done.

Renders as `FadeTransition(opacity: _controller, child: child)`.

## _VoiceParticipantRow -- Individual Participant Display

`file:_VoiceParticipantRow` extends `ConsumerWidget`. Props: `peerId`, `serverId`, `channelId`.

**State reads:**
- Profile display name via `displayNameFor(profiles, peerId)` (resolution: local nickname > profile display name > short peer ID).
- `vcState` from `voiceChannelProvider`.
- `localPeerId` from `identityProvider`.

**Audio state detection:**
For the local peer, reads `vcState.isMuted` and `vcState.isDeafened` directly. For remote peers, reads `vcState.getPeerAudioState(peerId)`.

**Media state detection:**
- `speaking` -- `vcState.isSpeaking(peerId)`.
- `isScreenSharing` -- local: `vcState.isScreenSharing`; remote: `vcState.peerScreenSharing[peerId] ?? false`.
- `isCameraOn` -- local: `vcState.isCameraOn`; remote: `vcState.peerCameraOn[peerId] ?? false`.

**Row layout:**
- `HollowAvatar` (18px) with profile avatar bytes.
- Display name in `HollowTypography.caption`, `hollow.textSecondary`, with ellipsis overflow.
- Trailing status icons (all 12px, with 2px left padding each):
  - `_SpeakingDot` -- teal dot, fades in/out based on `speaking`.
  - Screen sharing icon -- `LucideIcons.monitor`, green. Conditionally rendered.
  - Camera icon -- `LucideIcons.video`, `hollow.accent`. Conditionally rendered.
  - Muted icon -- `LucideIcons.micOff`, `hollow.error`. Conditionally rendered.
  - Deafened icon -- `LucideIcons.headphones`, `hollow.error`. Conditionally rendered.

**Right-click volume popup:**
For remote peers (`isRemote`), `GestureDetector.onSecondaryTapUp` calls `_showVolumePopup()`.

## Volume Popup -- Per-Peer Volume Control

`file:_VoiceParticipantRow._showVolumePopup()` creates a raw `OverlayEntry` positioned at the right-click location. It includes:

1. A full-screen tap-away barrier (`GestureDetector` with `HitTestBehavior.opaque`).
2. A `Material` card at the click position with `hollow.elevated` background, `hollow.radiusSm` border radius, elevation 4.
3. Inside: a `StatefulBuilder` containing a `Row` with:
   - Volume icon (`LucideIcons.volume2`, 12px).
   - `Slider` (width 110, height 24) ranging 0.0 to 2.0 (200% max volume). Custom `SliderThemeData` with accent colors, 2px track height, 4px thumb radius, 8px overlay radius.
   - Percentage label (e.g., "150%") in a 28px-wide `Text`.

The slider's `onChanged` calls `voiceChannelProvider.notifier.setPeerVolume(peerId, v)` to apply the volume change immediately.

**Note:** This uses raw `OverlayEntry` which is flagged as problematic inside `SelectionArea` per project conventions. However, this popup appears on right-click within the sidebar (not inside a `SelectionArea`), so it is acceptable here.

## _SpeakingDot -- Voice Activity Indicator

`file:_SpeakingDot` extends `StatelessWidget`. Props: `visible` (bool).

Renders an `AnimatedOpacity` (opacity 1.0 when visible, 0.0 when not, duration `HollowDurations.fast`) containing a 7x7 teal circle (`Colors.teal`, `BoxShape.circle`). Left padding of 2px.

No pulsing animation -- the dot is steady while shown, and fades in/out on transitions.

## _HomeContent -- DM Friends List

`file:_HomeContent` extends `ConsumerWidget`. Props: `hollow`, `peers`, `selectedPeerId`, `nodeStatus`, `onPeerSelected`, `lastMessage`, `formatTime`.

**Friend categorization:**
Watches `friendsProvider` and splits friends into three lists:
- `accepted` -- `status == 'accepted'`.
- `pendingIncoming` -- `status == 'pending' && direction == 'incoming'`.
- `pendingOutgoing` -- `status == 'pending' && direction == 'outgoing'`.

**Accepted friends sorting:** Online first (present in `peers` map), then alphabetical by `peerId`.

**Layout structure (`Column`):**
1. "Add Friend" button -- `HollowButton.outline` with `LucideIcons.userPlus`, full width (`expand: true`). Tapping calls `_showAddFriendDialog()`.
2. Divider.
3. Pending section (conditional, only if `hasPending`):
   - "PENDING" uppercase label with count badge, flanked by divider lines.
   - `_PendingRequestTile` for each incoming request (with accept/reject buttons).
   - `_PendingRequestTile` for each outgoing request (with clock icon, no action buttons).
   - Bottom divider.
4. "FRIENDS" uppercase label with count badge, same flanked-divider pattern.
5. Friends list (`Expanded`):
   - If empty and no pending: empty state with `LucideIcons.users` (48px, 30% opacity), "No friends yet" heading, "Add a friend by their peer ID" caption.
   - Otherwise: `ListView.builder` rendering `PeerCard` for each accepted friend. Each `PeerCard` receives: `peerId`, `isSelected`, `isEncrypted` (from peer info, defaults false), `isOnline` (presence in peers map), `lastMessage`, `formatTime`, `onTap`.

## Add Friend Dialog

`file:_HomeContent._showAddFriendDialog()` opens a `showHollowDialog` with:
- Title: "Add Friend"
- Content: `HollowTextField` with hint "Paste peer ID...", autofocus, monospace font (12px). `onSubmitted` and the "Send Request" button both trim the input, call `friendsProvider.notifier.sendRequest(peerId)`, close the dialog, and show a success toast "Friend request sent".
- Actions: "Cancel" ghost button, "Send Request" filled button.

## _PendingRequestTile -- Friend Request Display

`file:_PendingRequestTile` extends `ConsumerWidget`. Props: `hollow`, `peerId`, `direction` ('incoming' or 'outgoing'), `onAccept` (nullable), `onReject` (nullable).

Watches `profileProvider` and resolves display name via `displayNameFor()`.

**Layout:** `Container` with `hollow.elevated` background, `hollow.radiusMd` border radius. Row contains:
- `HollowAvatar` (28px) with profile avatar.
- Name column: display name (13px body) + subtitle ("Wants to be friends" for incoming, "Request sent" for outgoing, 10px caption).
- **Incoming actions:** check icon (`LucideIcons.check`, `hollow.success`) and X icon (`LucideIcons.x`, `hollow.error`), each in `HollowPressable`. Tap calls `onAccept`/`onReject` which delegate to `friendsProvider.notifier.acceptRequest()`/`rejectRequest()`.
- **Outgoing display:** clock icon (`LucideIcons.clock`, 14px, `hollow.textSecondary`) with no interactive action.

## Unread Dot Indicators

Unread state is tracked per-channel via `unreadProvider`. The `_ChannelTile` watches `unreadProvider.notifier.isChannelUnread(serverId, channelId)` which returns true when the unread count is > 0. The unread dot is suppressed when:
- The channel is currently selected (`isSelected`).
- The channel is muted (`isMuted` via `notificationSettingsProvider`).

The dot itself is an 8x8 circle filled with `hollow.accent`. It appears at the right end of the channel tile row.

When a channel is selected (via `onChannelSelected`), the shell's callback calls `unreadProvider.notifier.markChannelSeen(serverId, channelId, latestId)` to clear the unread state.

## Channel Selection Logic

Text channel selection is straightforward: tapping a `_ChannelTile` calls `onTap`, which is wired by `_ServerContentState` to `onChannelSelected(channel.channelId)`. In the shell's `_buildChannelSidebar()`, this sets `selectedChannelProvider.notifier.state`, updates `lastChannelPerServerProvider` (remembers last channel per server), and marks the channel as read.

Voice channel selection differs: tapping a `_VoiceChannelTile` either joins the voice channel (if not already connected) or selects it as the active channel in the main pane (if already connected). Voice channels do NOT appear as "selected" in the text-channel sense -- their highlight comes from the `isConnected` state tied to `voiceChannelProvider`.

## Permission Gating -- Create Channel Button

The "+" button for creating channels is gated by `canManageChannels`. This prop is computed in the shell:
```
canManageChannels: selectedServer != null &&
    (ref.watch(myPermissionsProvider(selectedServer.serverId)).whenOrNull(
        data: (perms) => (perms & Permission.manageChannels) != 0) ?? false)
```
The button only appears when the fallback "TEXT CHANNELS" header is shown (no categories in layout). When categories are present, there is no create channel button in the sidebar -- channel creation is done through server settings.

## DockMode Behavior

When `dockMode` is `true`:
- If `selectedServer == null`, the entire sidebar returns `SizedBox.shrink()` -- it is completely invisible. The dock layout shows the home dashboard instead.
- If a server is selected, the sidebar renders normally but with `showUserBar: false` (the user bar lives in the dock's bottom bar instead).
- In the shell, the dock mode sidebar is wrapped in `_DockSidebarSlider` which animates the sidebar sliding in/out when `selectedServerId` changes between null and non-null.

## Right-Pane Sidebar for Split View

`file:_RightPaneSidebar` (in `hollow_shell.dart`) is a `ConsumerStatefulWidget` that creates a second `ChannelSidebar` instance for the right pane of the split view. Key differences from the primary sidebar:

- **Width:** 200px (narrower than the primary 240px).
- **dockMode:** `true`.
- **showUserBar:** `false`.
- **Channel loading:** Independently loads channels from FFI via `crdt_api.getServerChannels()` and `crdt_api.getChannelLayout()`, not from the global `channelListProvider`. Caches the loaded server ID in `_loadedServerId` to avoid redundant FFI calls.
- **Channel selection:** Calls `splitViewProvider.notifier.setRightChannel(channelId)` instead of the global `selectedChannelProvider`.
- **Settings:** Opens settings via `_showServerSettingsDialog()` dialog (not the panel toggle used in non-split mode).
- **Home mode props:** All zeroed out (`peers: const {}`, `chatHistory: const {}`, etc.) since the right pane is server-only.
- **Permission check:** Same `myPermissionsProvider` + `Permission.manageChannels` check as the primary sidebar.
- Hides entirely when no server is selected (`selectedServerId == null` returns `SizedBox.shrink()`).

## VoiceChannelPanel Integration

`const VoiceChannelPanel()` is placed between the content area and the user bar in the sidebar column. It is always in the tree but self-hides when the user is not in a voice channel. When active, it shows the current voice channel name, connection state, and control buttons (mute, deafen, camera, screen share, disconnect). See `lib/src/ui/shell/voice_channel_panel.dart` for details.

## ChannelInfo Model

Defined in `lib/src/core/models/channel_info.dart`. Fields:
- `channelId` -- unique ID string
- `name` -- display name
- `category` -- nullable string (not used directly for layout; layout JSON handles categorization)
- `channelType` -- `ChannelType.text` (default) or `ChannelType.voice`
- `visibility` -- string, default `'everyone'` (UI filtering for channel modes)
- `posting` -- string, default `'everyone'` (UI filtering for who can post)

## Shell Integration -- _buildChannelSidebar Helper

`file:HollowShellState._buildChannelSidebar()` is the factory method in `hollow_shell.dart` that wires all callbacks and provider reads into a `ChannelSidebar` instance. Key wiring:

- `onPeerSelected`: resets share/archive tab state, sets `selectedPeerProvider`, marks DM as read via `unreadProvider.notifier.markDmSeen()`, switches mobile tab to chat (tab 1).
- `onChannelSelected`: sets `selectedChannelProvider`, updates `lastChannelPerServerProvider`, marks channel as read, switches mobile tab to chat.
- `onCreateChannel`: calls `showCreateChannelDialog(context, serverId)`.
- `onOpenSettings`: in split view, opens a dialog; otherwise toggles `serverSettingsOpenProvider`.
- `canManageChannels`: computed from `myPermissionsProvider` watching `Permission.manageChannels` bit.

Used in three places:
1. Classic mode -- 240px width, `dockMode: false`.
2. Dock mode -- 240px width, `dockMode: true`, wrapped in `_DockSidebarSlider`.
3. Mobile mode -- `width: null` (fills available space), `dockMode: false`.

## Animation Summary

| Element | Animation | Duration | Curve |
|---|---|---|---|
| Sidebar reveal | `RevealClip` horizontal from left | interval 0.12-0.30 | startup |
| Header crossfade | `AnimatedSwitcher` | `HollowDurations.fast` | default |
| Content crossfade | `AnimatedSwitcher` | `HollowDurations.normal` | enter/exit |
| UserBar reveal | Fade + slide up | interval 0.50-0.60 | startup |
| Category chevron | `AnimatedRotation` | `HollowDurations.fast` | default |
| Channel fold | `AnimatedSize` | `HollowDurations.fast` | easeOutCubic |
| Participant fade | `FadeTransition` | 180ms | linear |
| Participant list resize | `AnimatedSize` | `HollowDurations.normal` | easeOutCubic |
| Speaking dot | `AnimatedOpacity` | `HollowDurations.fast` | default |
| Text style transitions | `AnimatedDefaultTextStyle` | `HollowDurations.fast` | HollowCurves.subtle |
| Selection shimmer | `SelectionShimmer` | continuous | -- |
