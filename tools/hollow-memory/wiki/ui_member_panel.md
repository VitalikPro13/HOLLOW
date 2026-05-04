# MemberPanel — Right-Side Member List

Source: `lib/src/ui/shell/member_panel.dart` (706 lines)

## MemberPanel Widget Overview

`MemberPanel` is a `ConsumerWidget` that renders the right-side panel (fixed 240px width by default, or null for mobile fill). It sits at the rightmost edge of the shell layout in both Dock and Classic modes.

The panel watches `selectedServerProvider` to determine which content mode to display:
- **Server selected (`selectedServerId != null`):** Shows `_ServerMemberContent` keyed by `server-members-$serverId`.
- **No server selected (DM/home mode):** Shows `_PeerMemberContent` keyed by `peer-members`.

Content switches use `AnimatedSwitcher` with `HollowDurations.normal` duration, `HollowCurves.enter`/`HollowCurves.exit` curves.

The entire panel is wrapped in a `RevealClip` startup animation that clips horizontally from `Alignment.centerRight`, using `StartupRevealScope.interval(context, 0.45, 0.60)` for staggered reveal during app startup.

Container styling: `hollow.surface` background, left `BorderSide` using `hollow.border`.

### Providers Read
- `selectedServerProvider` — determines server vs peer content mode

## _SectionDivider — ASOT-Style Section Headers

`_SectionDivider` is a `StatelessWidget` that renders section headers in the format: `Label ———— Count`. Used for Online, Offline, and role-grouped sections.

### Parameters
- `label` (String) — section text (e.g., "Online", "Offline", "Owner", "Admin")
- `count` (int) — member count shown at right end
- `isOnline` (bool) — when true, the divider line has an animated glow sweep; when false, it is a static `hollow.border` line
- `glowColor` (Color?) — optional override for the glow color; defaults to `hollow.accent`

### Glow Animation (Online Sections)
Uses `SharedTickers.instance.shimmer` (a global `ValueNotifier<double>` running a 4-second cycle) via `ValueListenableBuilder`. No per-instance `AnimationController` is created.

The animation logic:
1. `shimmer` value (0..1) is converted to ping-pong (0->1->0) with `Curves.easeInOut`.
2. Mapped to range -0.2..1.2 so the glow fully exits both edges.
3. A `LinearGradient` with 3 stops creates a 0.15-width glow spot that sweeps left-to-right-to-left.
4. A `BoxShadow` at 0.2 alpha adds subtle bloom beneath the glow.

### Typography
`HollowTypography.caption` at 11px, `hollow.textSecondary` color, weight w600, letter-spacing 0.8.

## _SpinningRefreshIcon — Sync Activity Indicator

`_SpinningRefreshIcon` is a `StatefulWidget` with `SingleTickerProviderStateMixin` that renders a continuously spinning `LucideIcons.refreshCw` icon.

### Parameters
- `size` (double) — icon size
- `color` (Color) — icon color

### Animation
`AnimationController` with 1500ms duration, repeating indefinitely. Uses `RotationTransition`. Respects `HollowDurations.animationsDisabled` — sets duration to `Duration.zero` and skips `_controller.repeat()` when animations are disabled.

Used in two contexts:
- `_ServerMemberTile`: size 9, `hollow.accent` color — shown instead of `StatusDot` when `isPeerSyncingProvider(peerId)` is true
- `_MemberTile`: size 12, `hollow.textSecondary` color — shown when the peer connection is not yet encrypted

## Role Color and Label Helpers

Three private functions map role strings to visual properties:

### `_roleGlowColor(String role, HollowTheme hollow)`
Returns the glow color for role-grouped ASOT dividers:
- `owner` -> `hollow.warning` (gold)
- `admin` -> `Color(0xFFA78BFA)` (purple)
- `moderator` -> `Color.lerp(hollow.warning, hollow.error, 0.5)` (orange)
- `member` / default -> `hollow.accent` (teal)

### `_roleDividerLabel(String role)`
Returns the display label:
- `owner` -> "Owner"
- `admin` -> "Admin"
- `moderator` -> "Moderator"
- default -> "Members"

### `_roleLabelColor(String role, HollowTheme hollow)`
Returns the color for role label text in member tiles. Same mapping as `_roleGlowColor` except the default/member case returns `hollow.textSecondary` instead of `hollow.accent`.

## _ServerMemberContent — Server Member List

`_ServerMemberContent` is a `ConsumerWidget` that displays all members of a server, split into online and offline groups, with role-based sub-grouping for online members.

### Parameters
- `serverId` (String) — the server to display members for

### Providers Read
- `serverMembersProvider(serverId)` — `AsyncValue` of member list from CRDT state
- `peersProvider` — map of currently connected peers
- `identityProvider` — local peer ID
- `invisiblePeersProvider` — set of peer IDs that have declared invisible status
- `invisibleModeProvider` — whether the local user is in invisible mode

### Layout Structure
Top-level `Column`:
1. **Header** (48px height) — bordered bottom, contains a `_SectionDivider` showing "Members N" (non-glowing). During loading shows "Members ...", on error shows "Members ?".
2. **Expanded member list** — `ListView.builder` for lazy rendering (Phase 6.25 optimization to prevent jank on first server entry).

### Online/Offline Split Logic
Members are partitioned based on connection status and invisible mode:

**Online** if:
- Local user: `!amInvisible`
- Remote peer: `connectedPeers.containsKey(peerId) && !invisiblePeers.contains(peerId)`

**Offline** if:
- Local user: `amInvisible` (invisible mode makes self appear offline)
- Remote peer: not connected OR is in invisible peers set

### Role-Grouped Sub-Sections (Online Only)
Role ordering: `['owner', 'admin', 'moderator', 'member']`.

Two rendering paths for online members:
1. **All same role (all `member`):** Simple "Online N" divider with default accent glow, followed by flat member tiles.
2. **Multiple roles present:** Uses `buildRoleGrouped()` which creates per-role sub-sections. Each role group gets its own `_SectionDivider` with a role-specific glow color and label (e.g., "Owner 1" with gold glow, "Admin 2" with purple glow).

**Offline members** always get a single "Offline N" divider (no glow, static line), with no role sub-grouping.

### Empty/Error States
- Empty members: centered "No members" text
- Loading: centered 24px `CircularProgressIndicator` (strokeWidth 2)
- Error: centered "Failed to load members" text

## _PeerMemberContent — DM/Home Peer List

`_PeerMemberContent` is a `ConsumerWidget` shown when no server is selected. Displays all online peers (excluding invisible peers).

### Providers Read
- `peersProvider` — all connected peers map
- `invisiblePeersProvider` — peers to filter out

### Filtering
Creates a filtered copy of the peers map by removing all peer IDs present in `invisiblePeers`.

### Layout
- **Empty state:** centered "No peers online" text
- **Non-empty:** `ListView.builder` with `peers.length + 1` items (first item is an "Online N" glowing `_SectionDivider`)

### Startup Animation
Uses `StartupRevealScope.interval(context, 0.60, 0.80)` for parent animation. Each `_MemberTile` is wrapped in a `StaggeredListItem` that animates with a slide from `Offset(0.3, 0)` (slight right-to-left slide-in), staggered by index.

## _ServerMemberTile — Server Member Row

`_ServerMemberTile` is a `ConsumerWidget` rendering a compact row for one server member.

### Parameters
- `peerId` (String) — member's peer ID
- `displayName` (String) — profile display name (from CRDT member data)
- `role` (String) — power role: "owner", "admin", "moderator", or "member"
- `nickname` (String) — server-specific nickname
- `twitchUsername` (String) — Twitch username from CRDT member data
- `isOnline` (bool) — online/offline status
- `serverId` (String?) — owning server ID
- `labels` (List<crdt_api.LabelFfi>) — cosmetic label badges, defaults to empty

### Providers Read
- `isPeerSyncingProvider(peerId)` — whether this peer is currently syncing with the local node
- `profileProvider` — all user profiles (for avatar, name resolution, AND Twitch username fallback)
- `localNicknameProvider` — triggers rebuild on local nickname changes

### Twitch Username Resolution
`effectiveTwitch` is resolved at the top of `build()`: if CRDT `twitchUsername` is non-empty, use it; otherwise fall back to `profiles[peerId]?.twitchUsername` from the profile DB. This ensures the Twitch badge appears even when the CRDT data hasn't synced yet (e.g., peer reconnected and sent profile update but CRDT hasn't caught up).

### Name Resolution
Uses `serverDisplayNameFor(profiles, peerId, nickname: nickname)`. Resolution order: local nickname -> server nickname -> profile display name -> short peer ID (first 8 chars + "...").

### Visual Layout
Wrapped in `AnimatedOpacity`: 1.0 when online, 0.5 when offline (`HollowDurations.fast` transition).

Inside a `HollowPressable` (subtle mode, sm border radius):

**Left: Avatar stack (28px)**
- `HollowAvatar` with profile `avatarBytes`
- Positioned bottom-right overlay (inside `Container` with `hollow.surface` circular border for cutout effect):
  - If syncing: `_SpinningRefreshIcon` (size 9, accent color)
  - Else: `StatusDot` — green with pulse when online, `textSecondary` without pulse when offline

**Right: Name + badges column**
- **Display name:** `HollowTypography.bodySmall` at 12px, `textPrimary`, ellipsis overflow
- **Role badge** (only if `role != 'member'`): capitalized role name, colored per `_roleLabelColor()`, caption at 10px
- **Twitch badge** (only if `effectiveTwitch.isNotEmpty`): Row with `SimpleIcons.twitch` (10px, purple #9146FF) + username text (caption at 9px, same purple)

No label badges are shown inline in the tile itself — labels are only displayed in the `ProfileCardPopup` when clicked.

### Click Behavior
On tap: gets the tile's global position via `findRenderObject()`, then calls `showProfileCardPopup()` with:
- `anchor: Offset(pos.dx - 290, pos.dy - 100)` — positions card to the left of the member panel
- Passes `effectiveTwitch` (resolved, not raw CRDT), `nickname`, `role`, and `labels` for display in the profile card

## _MemberTile — Peer/DM Mode Member Row

`_MemberTile` is a `ConsumerWidget` for the simpler peer list (no server context).

### Parameters
- `peerId` (String) — peer's ID
- `isEncrypted` (bool) — whether the Olm session with this peer is established

### Providers Read
- `profileProvider` — user profiles for avatar and name
- `localNicknameProvider` — triggers rebuild on local nickname changes
- `webRtcProvider` (selective) — checks if `peers[peerId] == WebRtcPeerStatus.connected`

### Name Resolution
Uses `displayNameFor(profiles, peerId)`. Resolution order: local nickname -> profile display name -> short peer ID.

### Visual Layout
Inside a `HollowPressable` (subtle mode):

**Left: Avatar stack (28px)**
- `HollowAvatar` with profile `avatarBytes`
- Positioned bottom-right: `StatusDot` — always `hollow.success` (green) with pulse (these are online peers only)

**Center: Display name**
- `HollowTypography.bodySmall` at 12px, `textSecondary` color, ellipsis overflow

**Right: Status icons**
- **WebRTC direct connection indicator:** If the peer has a direct P2P WebRTC data channel (`WebRtcPeerStatus.connected`), shows `LucideIcons.radio` (11px, accent color)
- **Encryption indicator:** If `isEncrypted` is true, shows `LucideIcons.lock` (12px, success/green). If false, shows `_SpinningRefreshIcon` (12px, textSecondary) indicating key exchange is still in progress.

### Click Behavior
Same pattern as `_ServerMemberTile`: gets global position, calls `showProfileCardPopup()` with `anchor: Offset(pos.dx - 290, pos.dy - 100)`. No server-specific fields (nickname, role, labels) are passed.

## VoiceChannelPanel Integration

The `VoiceChannelPanel` (`lib/src/ui/shell/voice_channel_panel.dart`) is a separate widget that sits at the bottom of the channel sidebar (not inside MemberPanel). It appears when `vcState.isInVoiceChannel` is true and shows:

1. **Header row:** green connection dot + "Voice Connected" label + channel name from `channelListProvider`
2. **Controls row:** Mute toggle (`LucideIcons.mic`/`micOff`), Deafen toggle (`LucideIcons.headphones`), Camera toggle (`LucideIcons.video`/`videoOff`), Screen Share (desktop only, `LucideIcons.monitor`), Disconnect (`LucideIcons.phoneOff`, error color)

### Screen Share Handling
`_handleScreenShareToggle()`: If already sharing, calls `stopScreenShare()`. Otherwise opens `showScreenShareDialog(context)` to get source selection, then calls `startScreenShare()` with sourceId, dimensions, fps, and shareAudio.

### Providers Read by VoiceChannelPanel
- `voiceChannelProvider` — `VoiceChannelState` with all voice state
- `channelListProvider` — to resolve channel name from `currentChannelId`

### Platform Gate
Screen share button only shows on `Platform.isWindows || Platform.isMacOS || Platform.isLinux`.
