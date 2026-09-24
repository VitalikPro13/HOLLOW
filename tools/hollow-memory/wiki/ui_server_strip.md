# ServerStrip, BottomBar, and Server Folders

The server navigation strip renders server icons, folders, and utility buttons across two layout modes: vertical (classic mode, `ServerStrip`) and horizontal (dock mode, `BottomBar`). Both share the same strip layout data model, drag-reorder system, folder creation/management, and the critical atomic server selection pattern. The folder popup (`ServerFolderPopup`) provides an overlay grid for navigating servers within a folder.

## StripItem Data Model and Persistence

File: `lib/src/core/models/strip_item.dart`

`StripItem` is a sealed Dart class with three concrete subtypes. All strip layout state is a `List<StripItem>`.

- `ServerStripItem` — wraps a single `serverId: String`. Serializes to `{'type': 'server', 'id': serverId}`.
- `PendingStripItem` (pending joins rung 1, 2026-08-29): wraps a single `serverId: String`. Serializes to `{'type': 'pending', 'id': serverId}`. A parked join: we asked to join a server whose members were all offline and Rust is holding the request. Carries nothing but the id, deliberately, since there IS nothing else to carry until a member answers.
- `FolderStripItem` — wraps `id: String` (hex timestamp), `name: String` (default `'Folder'`), and `serverIds: List<String>`. Serializes to `{'type': 'folder', 'id': id, 'name': name, 'servers': serverIds}`. Has `copyWith()` for immutable updates.

`StripItem.fromJson()` returns `StripItem?` (nullable, since `PendingStripItem` landed) and deserializes based on the `'type'` field; an unrecognised type returns `null` and is skipped by the reader rather than being coerced into a `ServerStripItem`, so a layout written by a NEWER client's kind never gets pruned by an older client as a deleted server. Folder names default to `'Folder'` if absent.

## ServerStripLayoutNotifier (Provider)

File: `lib/src/core/providers/server_strip_layout_provider.dart`

`serverStripLayoutProvider` is a `NotifierProvider<ServerStripLayoutNotifier, List<StripItem>>`. State is persisted as JSON in SQLCipher via `storage_api.saveSetting(key: 'server_strip_layout', ...)`.

### Lifecycle

- `build()` returns empty list. Actual data loaded via `loadLayout()`.
- `loadLayout()` reads JSON from storage, deserializes to `List<StripItem>`, then calls `_syncWithServers()`.
- `_syncWithServers()` reconciles layout against `serverListProvider`:
  - Removes top-level `ServerStripItem`s whose `serverId` no longer exists in `serverListProvider`.
  - Removes deleted server IDs from folders. **Dissolves a folder only when it is EMPTY** (see the dissolution rule below).
  - Appends any server IDs present in `serverListProvider` but missing from the layout (new servers go to the end).
  - On first launch (empty state, non-empty server list), creates bare `ServerStripItem` entries for all servers.

### Mutation Methods

All mutations clone `state`, modify the clone, assign back to `state`, then call `_save()` (async JSON write to SQLCipher).

- `reorder(oldIndex, newIndex)` — moves a top-level item. Adjusts `newIndex` down by 1 if it follows `oldIndex` (standard reorder correction). Bounds-checked.
- `createFolder(serverId1, serverId2)` — finds both servers as top-level `ServerStripItem`s, removes both (higher index first to avoid shift), creates a `FolderStripItem` with hex-timestamp ID and `name: 'Folder'`, inserts at the lower of the two original indices.
- `addToFolder(folderId, serverId)` — removes `serverId` from top-level and from any other folder (dissolving the source folder only if it empties), then appends to target folder's `serverIds`.
- `removeFromFolder(folderId, serverId, insertIndex)` — removes from folder (dissolving only if it empties), inserts as top-level `ServerStripItem` at clamped `insertIndex`.
- `createFolderWith(serverId, name)` (issue #61) — wraps ONE server in a new folder, in place: at its top-level index, or immediately after the folder it was pulled out of. This is what "Move to folder > New folder" calls.
- `moveOutOfFolder(serverId)` (issue #61) — the menu's inverse of the drag-out. Inserts after the folder, or **into the folder's own slot when it was the last server**, so the icon does not appear to jump over its neighbour on the way out.
- `dissolveFolder(folderId)` (issue #61) — replaces a folder with the servers it held, in order, at its index.
- `folderIdOf(serverId)` / `folders()` (issue #61) — what the "Move to folder" submenu reads to check the current folder and list the rest.
- `renameFolder(folderId, name)` — updates the folder's name via `copyWith`.
- `reorderInsideFolder(folderId, oldIndex, newIndex)` — reorders `serverIds` within a folder.
- `onServerCreated(serverId)` — appends to layout if not already present (checks both top-level and folder contents). **Pending joins rung 1:** if a `PendingStripItem` for this id is already in the layout, swaps it IN PLACE for a `ServerStripItem` at the same index instead of appending: the tile the user has watched for days turns into the server rather than vanishing and reappearing at the end of the strip.
- `onServerDeleted(serverId)` — removes from top-level and from any folder (dissolving if needed).
- `setPendingJoins(Set<String> pendingIds)` (pending joins rung 1): reconciles the `PendingStripItem` tiles against the id set `PendingJoinsNotifier` hands it after every change: appends a tile for a new id, drops a tile whose id left the set, leaves an already-shown tile's slot alone. The ONE mutation path for pending tiles.
- `allServerIds()` — returns `Set<String>` of every server ID across all top-level items and folder contents. Used by `_initialServerIds` tracking for entrance animations. Deliberately does not count `PendingStripItem`s (a pending join is not a server we're in).

## ServerStrip (Classic Mode Vertical Strip)

File: `lib/src/ui/shell/server_strip.dart`

`ServerStrip` is a `ConsumerStatefulWidget`. Renders a 72px-wide vertical column on the left edge of the classic layout. Background: vertical `LinearGradient` from `opaqueBackground` to a subtle 8% accent tint, with a `right: BorderSide` border.

### State

- `_initialServerIds: Set<String>?` — populated once on first build via `ref.read(serverStripLayoutProvider.notifier).allServerIds()`. Servers NOT in this set get the `NewServerEntry` entrance animation, so existing servers never animate at startup.

### Layout Structure (top to bottom)

1. `SizedBox(height: HollowSpacing.md)` — top padding.
2. **Home icon** — `_ServerIconWithIndicator` wrapping `_ServerIcon`. Selected when `selectedServerId == null && !ref.watch(anyShellTabOpenProvider)` — ANY centre tab counts, including the guest/conference ones this strip has no button for. Shows DM unread count when a server is selected (not when already on home). Background: `hollow.accent`. Displays bold `'H'` text. Tap: `setShellTab(ref.read, null)` + clears `selectedServerProvider`, `channelListProvider`, `selectedChannelProvider`, `serverSettingsOpenProvider`.
3. **Browse Public Channels icon**: `_ServerIconWithIndicator` + `_ServerIcon`, `LucideIcons.globe`. Selected when `guestTabOpenProvider`. Tap TOGGLES: open → `setShellTab(null)`; closed → `setShellTab(ShellTab.guest)` + clears server/channel/peer/settings state.
4. **Share icon** — `_ServerIconWithIndicator` + `_ServerIcon`. Selected when `shareOpen`. Background: `hollow.elevated`. Displays `LucideIcons.share2` (accent when selected, textSecondary otherwise). Tap TOGGLES: open → `setShellTab(null)`; closed → `setShellTab(ShellTab.share)` + clears server/channel/settings state.
5. **Archive icon** — same pattern, and toggles the same way. Selected when `archiveOpen`. Displays `LucideIcons.archive`. When opening: invalidates `archiveDmListProvider` and `archiveChannelListProvider`, resets archive selection providers, `setShellTab(ShellTab.archive)`, clears server/channel/settings state.
6. **Conferences icon**: `LucideIcons.video`. Selected when `conferenceTabOpenProvider`. Tap TOGGLES: open → `setShellTab(null)`; closed → `conferenceProvider.notifier.openTab()`.
6b. **Hollow Shop icon** (2026-09-02): `LucideIcons.store`, right after Conferences, present ONLY when `shopAvailableProvider` (store builds have no shop surface). Selected when `shopTabOpenProvider`. Tap TOGGLES: open → `setShellTab(null)`; closed → `openShopTab(read)`. Wiki `hollowpack`.
7. **Divider** — 32px wide, 2px tall, `hollow.border` color, rounded.
8. **Server icon list** — `Expanded` containing `ListView.builder`. Items interleaved with reorder gaps: `gap0, item0, gap1, item1, ..., gapN`. `itemCount = stripLayout.length * 2 + 1`. Even raw indices are `_VerticalReorderGap` widgets; odd raw indices are server or folder icons. Each item gets `Padding(bottom: HollowSpacing.xs)`.
9. **Help icon**: `_ServerIcon` with `LucideIcons.circleHelp`, accent when `helpPanelOpenProvider`. Tap flips that provider. Not a shell tab, so no `_ServerIconWithIndicator` pill.
10. **Add button** — `_ServerIcon` with `LucideIcons.plus` in accent color, tooltip `'Create a server'`. Tap: calls `showCreateServerDialog(context)`. Has bottom padding `HollowSpacing.md`.

Items 3, 6 and 9 exist here because this strip is Classic mode's ONLY permanent rail: Browse Public Channels, Conferences and Help otherwise live only on the dock's `BottomBar`, which Classic does not render, so in Classic they were unreachable (issue #58 sweep). The two centre tabs among them go through `setShellTab`, same as Share and Archive.

### Server Icon Rendering (_buildServerIcon)

For each `ServerStripItem` at a given `index`:

1. Watches `serverListProvider[serverId]` for the server name.
2. Checks `notificationSettingsProvider.notifier.isServerMuted(serverId)`. If muted, `serverUnreads = 0`. Otherwise reads `unreadProvider.notifier.serverUnreadCount(serverId)`.
3. Watches `serverAvatarProvider[serverId]`. If non-null, renders `Image.memory` (44x44, `BoxFit.cover`, 8px border radius). Otherwise renders initials text (white, 18px, w600).
4. Wraps in `DragTarget<_StripDragData>`:
   - `onWillAcceptWithDetails`: accepts only if dragged data has a `serverId` that differs from this icon's `serverId` (folder creation target).
   - `onAcceptWithDetails`: calls `serverStripLayoutProvider.notifier.createFolder(data.serverId!, serverId)`.
5. Inside the drag target, wraps in `LongPressDraggable<_StripDragData>`:
   - `data`: `_StripDragData(serverId: serverId, sourceIndex: index)`.
   - `delay`: 300ms (prevents accidental drags on tap).
   - `feedback`: `Material(transparent)` > `AnimatedOpacity(0.8)` > `_ServerIcon` with the server's color and icon child.
   - `childWhenDragging`: `AnimatedOpacity(0.3)` — the original position fades to 30% opacity.
   - `child` (normal state): `AnimatedScale` (1.08 when `isMergeTarget`, 1.0 otherwise) wrapping `_ServerIconWithIndicator` + `_ServerIcon`. `isSelected` sets the pill indicator. `unreadCount` shown on badge. Tooltip shows server name. Tap calls `_selectServer(serverId)`.

### Folder Icon Rendering (_buildFolderIcon)

For each `FolderStripItem`:

1. `isSelected` is true if any `folder.serverIds` contains `selectedServerId`.
2. `folderUnreads` sums `serverUnreadCount()` for all non-muted servers in the folder.
3. `DragTarget<_StripDragData>`:
   - Accepts server drops (not already in this folder) via `addToFolder(folder.id, data.serverId!)`.
4. `LongPressDraggable<_StripDragData>`:
   - `data`: `_StripDragData(folderId: folder.id, sourceIndex: index)`.
   - Same feedback/childWhenDragging pattern as servers but uses `ServerFolderIcon(folder, size: 48)`.
5. Normal child: `AnimatedScale` (1.08 on drop target) > `_ServerIconWithIndicator` > `GestureDetector(onSecondaryTapUp)` for right-click rename > `_ServerIcon`:
   - `showBorder: false` (folders don't get the accent border on selection).
   - Tooltip: folder name.
   - Tap: calculates anchor position (`pos.dx + 72`, vertical center of icon) and calls `showServerFolderPopup()` with `isDock: false`.
   - Unread badge shows `folderUnreads` only when NOT selected (selected folders show 0 to avoid visual noise).

## Pending Join Tile (pending joins rung 1, 2026-08-29)

File: `lib/src/ui/components/pending_join_ui.dart` (widget + menu/sheet + action helpers, shared by both shells); rendered in `_buildPendingIcon()` (`server_strip.dart`) and `_buildPending()` (`bottom_bar.dart`), the Dock one as a dimmed `_DockTile` in `elevated`.

A `PendingStripItem` in the strip data renders as a tile deliberately unlike every other icon on the rail: dimmed (`AnimatedOpacity`, GPU-composited, never the `Opacity` widget; opacity is 0.55 pending / 0.4 rejected, crossfading when a rejection lands), carrying a glyph rather than initials (`LucideIcons.clock` pending, `LucideIcons.ban` rejected: an invite link gives us an id and nothing else, no name, no icon, no initial to draw), and **NOT selectable**, since there is no server behind it yet to open.

Both a LEFT click and a right click open the SAME menu (`showPendingJoinMenu` via `showHollowMenu`, the shared context-menu surface), because a tile that swallows a plain click reads as broken. The menu's header row is a `HollowMenuNote` carrying `pendingJoinExplanation()` (the long form, since the tile has no other real estate to explain itself), followed by "Request again" (rejected only, calls `retryPendingJoin` FFI → `markRequestedAgain`), "Copy invite link" (`webServerInviteLink(serverId)`), and "Discard request" / "Remove" (danger-styled, `discardPendingJoin` FFI → `pendingJoinsProvider.notifier.remove()`).

### AwaitingSetupBadge
A 16px (10px clock icon) badge, `HollowTooltip` wrapping a small ring the colour of the surface behind it, shown on a server tile (not a pending tile) whose CRDT admission landed but whose MLS leaf has not formed yet (`awaitingSetupProvider.contains(serverId)`). It is a BADGE, not a spinner: the wait is for another human to open their app, which can be tomorrow.

**Positioned differently per rail, and the reason is load-bearing:** `_ServerIconWithIndicator` (Classic, `server_strip.dart`) puts it top-RIGHT (`right: -4, top: -4`); `_DockTile` (Dock, `bottom_bar.dart`) puts it top-LEFT (`left: -xs, top: -xs`, size `lg`), because on the Dock the unread badge already owns the top-right corner, and two badges in one corner would overlap. `Clip.none` on the enclosing `Stack` is load-bearing here too (`feedback_badge_stack_clips_avatar_frame`): the same reason an avatar frame needs it.

### _VerticalReorderGap

Thin drop zone between items in the vertical strip. `DragTarget<_StripDragData>` that accepts any drag where `sourceIndex` is not the same slot or immediately before it (no-op guard: `src != index && src != index - 1`).

Visual: `AnimatedContainer` — 36px wide, height transitions from `HollowSpacing.xs` (transparent, dormant) to 4px tall accent-colored bar when active. Margin animates 2px vertical when active.

Calls `serverStripLayoutProvider.notifier.reorder(data.sourceIndex, gapIndex)` on accept.

### _StripDragData (ServerStrip)

Private class carrying drag payload: `serverId: String?`, `folderId: String?`, `sourceIndex: int`. Only one of `serverId`/`folderId` is set per drag.

## CRITICAL: Atomic Server Selection Pattern

File: `lib/src/ui/shell/server_strip.dart`, method `_ServerStripState._selectServer()`
File: `lib/src/ui/shell/bottom_bar.dart`, top-level `_selectServer(ref, serverId)`

This is the canonical pattern for switching servers. **All 4 core providers must be batched in a single synchronous block** to prevent intermediate rebuilds with inconsistent state (e.g., channel list from old server, selected server from new server).

### Step 1: Async data fetch (no provider writes)

```dart
final channels = await ChannelListNotifier.fetchChannels(serverId);
final layout = await ChannelLayoutNotifier.fetchLayout(serverId);
```

These are static async methods that read from SQLCipher. No provider writes happen here, so no UI rebuilds are triggered.

### Step 2: Determine channel to select

Reads `lastChannelPerServerProvider[serverId]`. If that channel still exists, uses it. Otherwise picks `firstTextChannelInLayout(channels, layout)` or falls back to `channels.keys.first`.

### Step 3: Synchronous provider batch

The following writes happen in one synchronous block (one microtask, one rebuild):

1. `setShellTab(ref.read, null)` — closes ALL four centre tabs (guest / share / archive / conference) in one call. Clearing them by hand is what caused issue #28: both `_selectServer`s missed `conferenceTabOpenProvider`, so the conference dashboard stayed on top of the server that had just been selected.
2. `selectedPeerProvider` = null
3. `serverSettingsOpenProvider` = false
4. `channelListProvider.notifier.setChannels(channels)` — **CRITICAL**: must come before `selectedChannelProvider`
5. `channelLayoutProvider.notifier.setLayout(layout)` — **CRITICAL**: must come before `selectedChannelProvider`
6. `selectedChannelProvider` = channelToSelect
7. `selectedServerProvider` = serverId

### Step 4: Persist last channel

If a channel was selected, updates `lastChannelPerServerProvider` map with `{serverId: channelToSelect}`.

**The 4 CRITICAL providers that must be batched:** `channelListProvider`, `channelLayoutProvider`, `selectedServerProvider`, `selectedChannelProvider`. Writing them out of order or across async boundaries causes the channel sidebar to briefly show stale data or crash on missing channel IDs.

## BottomBar (Dock Mode Horizontal Strip)

File: `lib/src/ui/shell/bottom_bar.dart`

`BottomBar` is a `ConsumerWidget`. Renders a `kDockHeight` (56) px bar plus a 1px top hairline at the bottom of the dock layout. Background: `hollow.opaqueSurface` with a `top: BorderSide` border. The label scale is clamped to 1.3 (fixed-height chrome). Left to right: you (identity, the call), where you are (Home, servers, places), then the tools, which open on top.

### Layout Structure (left to right)

One `Row` inside a `LayoutBuilder`:

1. **`DockIdentity`** (public `ConsumerWidget`): `HollowPressable` with `HollowTooltip` "Your profile and status". Avatar 28 px with a `StatusDot` cut into its corner (colour, fill and label from `connectionVisual()` over `overallConnectionProvider` + `invisibleModeProvider`, the same source as the Classic user bar; the cut-out follows the row's hover fill). Then the name (label style) and ONE status line by exception: the connection label in `warning` when not connected (and not invisible); `"<room> · <server>"` in `success` while in voice, tappable, opening that room via `openServerChannel`; else the profile's own status line in `textTertiary`; else nothing. Text column max 160 px. Tap: `showProfileCardPopup()` with `anchorBottom: true`.
2. **`VoiceQuickControls`** (`lib/src/ui/shell/voice_quick_controls.dart`), only while `isInVoiceChannel`: three `HollowIconButton`s, Mute/Unmute (`micButtonVisual`), Deafen/Undeafen, and "Disconnect" (`error`). Disconnect calls `leaveVoiceRoom()`, which toasts "Couldn't leave the voice room" on failure. Camera and screen share stay in the room's own pill.
3. `_DockDivider` (a `HollowVerticalDivider`, `xl` tall, `md` either side).
4. **Home tile**: `_DockTile`, 40 px, `hollow.elevated` fill (`hover` on hover), child `HollowMark` (`components/hollow_mark.dart`: the Hollow logo H with padlock and keyhole) at 22 px in `accentText`. No DM unread total. Tap: `_goHome(ref)`. Right click: `showHomeMenu`.
5. **Servers** (`Expanded` > `Row`): `Flexible(_ServerList)` then a ghost Add tile (`_DockTile`, `opaqueSurface` fill, `elevated` on hover, `LucideIcons.plus` in `textSecondary`, tooltip "Create a server", `showCreateServerDialog`). The list anchors LEFT and Add follows the last tile; the space after it is the flexible gap before the places, so a short list never floats in the middle.
6. **Places** (`_Places`): Conferences (`video`), Public channels (`globe`), Share (`share2`), Archive (`archive`), and Hollow Shop (`store`) ONLY when `shopAvailableProvider` (absent, not disabled, on store builds). Each is a `HollowIconButton` with `selected:` on its tab. Below `kDockPlacesFoldWidth` (1000 px of dock) they fold into ONE "Places" button (`LucideIcons.layoutGrid`) opening a `showHollowMenu` with check-marked rows.
7. `_DockDivider`, then the tools: **Downloads** (`DownloadIconButton`, a `HollowIconButton` with a `HollowCountBadge` of transfers in flight), **Help** (`_HelpButton`, toggles `helpPanelOpenProvider`, `selected` while open), **Settings** (`showUserSettingsDialog(context)`, which opens on Profile, same as Classic).

The recovery phrase key is not on the dock (the phrase lives on Home's Needs Attention and the setup checklist, wiki `ui_home_dashboard`).

### Places toggle

`_togglePlace(ref, tab)`: pressing the lit place calls `setShellTab(ref.read, null)` and drops back to what it covered (issue #28); otherwise `_openPlace`: Conferences via `conferenceProvider.notifier.openTab()`, the Shop via `openShopTab(read)`, Archive closes split, invalidates the archive lists, resets archive selection, then `setShellTab`; Public channels and Share close split and `setShellTab`. Every non-Conference/Shop open also clears server/channel/peer/settings selection (`_clearSelection`).

### The selection mark (`dockLocationProvider`)

ONE `NavSelectionMark` (`components/nav_selection_mark.dart`: a 2 x 20 accent bar; the phone's `MobileNavBar` uses the same widget) sits on the dock's TOP edge over the one active item. `dockLocationProvider` (sealed `DockLocation`: `_AtHome` (a DM included), `_AtServer(serverId)`, `_AtPlace(tab)`) decides: an open centre tab (`openShellTabProvider`, new in `shell_tab.dart`) wins, else the server (the right pane's in a split with `focusedPane == 1`, else `selectedServerProvider`), else Home. A folder is marked when it holds the active server. Hover never paints a bar or accent, so only the active item looks active.

`_DockSlot(marked:, child:)` gives each item the dock's full height and draws the mark at `top: 0`; badges sit inside that box.

### BottomBar Server Icon Rendering (`_ServerListState._buildServer`)

`_ServerList` is a `ConsumerStatefulWidget` over `serverStripLayoutProvider`, rendered as an `EdgeScrollRow(shrinkWrap: true, height: kDockHeight)`: the scroll viewport is the dock's full height, so badges and the mark are never clipped, and it hugs its tiles so Add follows the last one. Interleaved with `_ReorderGap`s (one before each item plus one at the end).

- Tile: `_DockTile`, 40 px, radius `lg`, filled with `colorFromId(serverId)` and showing `ServerAvatar(size: 40, animate: active)`. Hover lays a luminance lift (`textPrimary` at 10% alpha) over it.
- Badges: `HollowCountBadge` top-right (`right: -sm, top: -xs`, ring `opaqueSurface`): mentions (`@N`, error) when any, else unread (accent). Muted servers pass 0. `AwaitingSetupBadge` top-LEFT. `VoiceHereBadge` (`components/voice_here_badge.dart`, a `success` disc with `volume2`) bottom-right on the server holding your voice room (`_voiceServerProvider`).
- `LongPressDraggable` (300 ms) with `_setDragging` in `onDragStarted` / `onDragEnd` / `onDraggableCanceled`; drag feedback and `childWhenDragging` use a `plain` face (no badges, no tooltip).
- When a server is dragged onto it (`isMergeTarget`), the tile scales to 1.08x (`AnimatedScale`), with no glow.
- Tooltip suppressed during drag: `tooltip: _isDragging ? null : name`.
- Tap calls `_selectServer(ref, serverId)`, which handles split view routing. Right click: `showServerIconMenu`.
- New servers get `NewServerEntry`.

### BottomBar Folder Icon Rendering (`_buildFolder`)

- `_DockTile` with `elevated` fill (`hover` on hover) and `ServerFolderIcon(size: 40, filled: false)`.
- Sums unread AND mentions over the folder's non-muted servers and keeps the count when the folder is selected. `VoiceHereBadge` when it holds your voice room.
- Marked when it contains the active server (split right pane included, via `dockLocationProvider`).
- Folder popup anchor: `Offset(pos.dx + box.size.width / 2, pos.dy)` with `isDock: true` (popup appears above the bar).
- Right click opens `showFolderIconMenu` (Rename is a row in it).
- Tooltip suppressed during drag.

### BottomBar Split View Server Selection

In the top-level `_selectServer(ref, serverId)`, if `splitState.isSplit && splitState.focusedPane == 1` (right pane focused):

1. Calls `crdt_api.getServerChannels(serverId: serverId)` directly (FFI, not through provider) to avoid overwriting the global `channelListProvider` which belongs to the left pane, keeping only channels with `meCanSee`.
2. Picks a channel: prefers `lastChannelPerServerProvider[serverId]`, then first text channel, then first channel.
3. Calls `splitViewProvider.notifier.navigateRightToServer(serverId, channelId: channelToSelect)`.
4. Returns early (does NOT touch the global channel/server providers).

If not in split right-pane mode, falls through to the standard atomic selection pattern.

### _goHome and _openPlace

Both close the split view first (`_closeSplit`) where the place needs it, then `setShellTab` and `_clearSelection` (server, channel list, channel, peer, settings). `_openPlace(ShellTab.archive)` additionally invalidates the archive list providers and resets the archive selection providers.

## _ServerIcon (Vertical Strip Icon Widget)

File: `lib/src/ui/shell/server_strip.dart`

Private `StatefulWidget`. 48x48 rounded square. Tracks hover state.

- **Border radius animation:** `radiusLg` (default/square-ish) transitions to 16.0 (pill-ish) on hover or when selected. Uses `AnimatedContainer` with `HollowDurations.fast` and `Curves.easeOutCubic`.
- **Hover color:** `Color.lerp(backgroundColor, hollow.accent, 0.15)` when hovering and not selected.
- **Selection border:** 2px `hollow.accent` at 60% alpha, only when `isSelected && showBorder`.
- **Clip:** `Clip.antiAlias` for smooth rounded corners on avatar images.
- **Cursor:** `SystemMouseCursors.click` when `onTap` is non-null.
- **Tooltip:** wraps in `HollowTooltip` if `tooltip` is non-null.

## _ServerIconWithIndicator (Vertical Strip Selection + Badge)

File: `lib/src/ui/shell/server_strip.dart`

Private `StatefulWidget`. Wraps `_ServerIcon` with two overlays:

### Left-Edge Pill Indicator

Discord-style selection indicator. `AnimatedContainer`:
- Width: 3px constant.
- Height: 36px (selected), 20px (hovering), 0px (default).
- Color: `hollow.textPrimary`.
- Border radius: top-right and bottom-right 4px (pill shape on left edge).
- Duration: `HollowDurations.fast`, curve: `HollowCurves.enter`.

Layout: `SizedBox(72x48)` containing a `Row`: indicator | `Spacer` | `Stack(children)` | `SizedBox(width: 12)`.

### Unread Badge

`Positioned(right: -6, bottom: -4)` — overlaps the icon's bottom-right corner. Only shown when `unreadCount > 0`.

- Min width: 16px, height: 16px, horizontal padding: 4px.
- A `HollowCountBadge` (2026-09-23): accent for unread, `error` with `@N` for mentions (the dock now passes `mentionCount` too), `ring: hollow.surface`.
- Border: 2px `hollow.background` (creates an outline effect against the strip background).
- Text: white, 9px, w700, `height: 1`. Caps at `'99+'`.

Tracks `_hovering` via `MouseRegion` for the indicator height animation.

## _DockTile (Horizontal Strip Icon Widget)

File: `lib/src/ui/shell/bottom_bar.dart`

Private `StatelessWidget`: a 40 px square (Home, a server, a folder, Add, a parked join) with radius `lg`, built from `HollowPressable` > `_TileFace`. Takes `fill`, optional `hoverFill`, `tooltip`, `semanticLabel`, `menuLabel`, `onTap`, `onContextMenu`, `unreadCount`, `mentionCount`, `awaitingSetup`, `voiceHere`.

- **Hover:** with a `hoverFill` the fill steps up one surface; without one (identity colour or image) a `textPrimary` lift at 10% alpha fades in over it (same colour at both ends, so it never lerps via black). No bar, no accent, no radius change, no selection border.
- **Selection:** not drawn by the tile. The ONE `NavSelectionMark` on the dock's top edge (via `_DockSlot`) shows the active item.
- **Context menu:** `ContextMenuTarget` wraps the tile ABOVE its focus ring, so Menu and Shift+F10 reach it while keyboard-focused (issue #61).
- **Badges** in a `Stack(clipBehavior: Clip.none)`: `AwaitingSetupBadge` top-left (`left: -xs, top: -xs`, size `lg`); `HollowCountBadge` top-right (`right: -sm, top: -xs`, ring `opaqueSurface`), mention count when any, else unread; `VoiceHereBadge` bottom-right (`right: -xs, bottom: -xs`).

## _ReorderGap (Horizontal Strip Drop Zone)

File: `lib/src/ui/shell/bottom_bar.dart`

`DragTarget<_StripDragData>`. Same no-op guard as `_VerticalReorderGap` (`src != index && src != index - 1`).

Visual: a fixed `HollowSpacing.sm` wide, 40 px tall slot whose width never changes, so a drag never shoves the row. Inside it an `xs` wide accent bar fades from alpha 0 to 1 while a drag hovers. Duration: `HollowDurations.fast`.

## NewServerEntry (Entrance Animation)

File: `lib/src/ui/shell/new_server_entry.dart`, shared by `server_strip.dart` and `bottom_bar.dart`.

`StatefulWidget` with `SingleTickerProviderStateMixin`. Plays once on first build, for newly created/joined server icons (those not in `_initialServerIds`): the popover motion, a fade plus a scale from `HollowMotion.popoverScale` (0.96) to 1.0 over `HollowDurations.normal` with `HollowCurves.enter`. No overshoot. Keyed with `ValueKey('bounce-$serverId')` (the key name is historical).

Folders never get the entrance (both files check `isNew` and folders always return false).

## Drag-Reorder System

### How It Works

Both strips interleave `_ReorderGap`/`_VerticalReorderGap` widgets between every server/folder icon plus one at the start. This creates N+1 drop zones for N items.

1. **Initiate drag:** `LongPressDraggable` with 300ms delay. Creates `_StripDragData` with `sourceIndex` and either `serverId` or `folderId`.
2. **Feedback widget:** 80% opacity ghost of the icon floating under the cursor.
3. **Source position:** fades to 30% opacity (`childWhenDragging`).
4. **Drop on gap:** `_ReorderGap.onAcceptWithDetails` calls `serverStripLayoutProvider.notifier.reorder(data.sourceIndex, gapIndex)`. The no-op guard prevents dropping in the same position.
5. **Drop on server icon:** folder creation. `DragTarget` on each server icon accepts server drags (not self) and calls `createFolder(draggedServerId, targetServerId)`.
6. **Drop on folder icon:** `DragTarget` on each folder accepts server drags (not already in folder) and calls `addToFolder(folderId, draggedServerId)`.

### Visual Feedback

- **Gap active:** colored accent bar appears (4px tall vertical; in the dock an `xs` wide bar fades in inside the fixed-width gap).
- **Merge target (server-on-server):** `AnimatedScale` to 1.08x in both strips. No glow.
- **Drop target (server-on-folder):** `AnimatedScale` to 1.08x.
- **Drag source:** 30% opacity fade.

### BottomBar Drag State Tracking

`_ServerListState._isDragging` is set in `onDragStarted` and cleared in `onDragEnd`/`onDraggableCanceled`. While true, tooltips are suppressed (`tooltip: _isDragging ? null : name`) to prevent them from interfering with drop targets. The vertical `ServerStrip` does not track this state (tooltips always show).

## Folder System

### Folder Creation (Drag-to-Merge)

When a server icon is dropped onto another server icon:
1. `DragTarget.onAcceptWithDetails` fires on the target icon.
2. Calls `serverStripLayoutProvider.notifier.createFolder(draggedServerId, targetServerId)`.
3. Both `ServerStripItem`s are removed from the layout list.
4. A new `FolderStripItem` is created with:
   - `id`: `DateTime.now().millisecondsSinceEpoch.toRadixString(16)` (hex timestamp).
   - `name`: `'Folder'` (generic default).
   - `serverIds`: `[serverId1, serverId2]`.
5. Inserted at the minimum of the two original indices.

### Adding Servers to Folders

When a server icon is dropped onto a folder icon:
1. `DragTarget.onAcceptWithDetails` fires on the folder.
2. Calls `addToFolder(folderId, serverId)`.
3. The server is removed from any other folder or top-level position.
4. Source folder dissolves if it drops to 0 (removed) or 1 (becomes bare `ServerStripItem`) members.

### Removing Servers from Folders

Inside the folder popup, each `_FolderServerItem` has a small X button (top-left, 16px circle) when `onRemove` is non-null. `onRemove` is null when the folder has only 1 server (can't remove the last one — it would be dissolved by the notifier anyway).

On remove:
1. Finds the folder's index in the layout.
2. Calls `removeFromFolder(folderId, serverId, folderIdx + 1)` — inserts the server right after the folder's position.

### Folder Auto-Dissolution — ONE rule, everywhere

**A folder disappears when it is EMPTY. Never at one server.** Applied identically in `_syncWithServers()`,
`addToFolder()`, `removeFromFolder()` and `onServerDeleted()`.

This changed in issue #61 phase 4 and the reason matters: every one of those sites used to also collapse a
folder holding a SINGLE server. "Move to folder > New folder" creates exactly that, so the layout would have
silently undone the user's action on the next `loadLayout()`, in a place nothing would have shown it happening.
Making a one-server folder legal is also what lets a folder be a deliberate container you drop a second server
into later. `test/server_strip_folders_test.dart` guards it.

### Folder Rename

Two entry points:
1. **Right-click** on a folder icon in both `ServerStrip` and `BottomBar`, which opens the folder context menu
   (below); Rename is one row in it. It used to jump straight into the rename dialog with no menu around it and
   therefore no way to dissolve a folder at all.
2. **Pencil button** in the folder popup header.

Both call `showFolderRenameDialog()` which opens `showHollowDialog` containing `_FolderRenameDialog`.

`_FolderRenameDialog` is a `ConsumerStatefulWidget`:
- 280px wide container with `HollowSpacing.xl` padding.
- Title: `'Rename Folder'`.
- `HollowTextField` with `maxLength: 32`, autofocus, submit-on-enter.
- Cancel (ghost button) / Save (filled button) row.
- Save trims input, calls `serverStripLayoutProvider.notifier.renameFolder(folder.id, name)`, then pops.

## Context Menus (issue #61 phase 4)

Built in `lib/src/ui/shell/server_context_menus.dart` on the shared `showHollowMenu` primitive, and opened
through `ContextMenuTarget` so each one also answers Menu / Shift+F10 and a "Show menu" screen-reader action.
**Both shells call this file**, so a row that exists in Classic and not in Dock is impossible by construction.

**Server icon** — Mark as read, Mute/Unmute server, Invite people, Server settings, **Move to folder**, Leave
server. Before this the strip had no menu at all and folder membership was drag-only.
- `Mark as read` uses the shared `markServerRead(ref, serverId)` (also used by the channel sidebar's background
  menu): the watermark per channel is the LAST message of the in-memory list, the ms-timestamp rule.
- `Server settings` goes through each shell's `_openServerSettings`, which **selects the server first**. The
  settings panel reads the SELECTED server, so flipping `serverSettingsOpenProvider` alone would open the
  settings of whatever was already on screen.
- `Move to folder` is a drill-in submenu: every existing folder (check-marked if it is the current one), `New
  folder` (prompts for a name → `createFolderWith`), and `Remove from folder` when it is in one.
- `Leave server` uses `confirmAndLeaveServer`, the same flow as the Danger Zone tab, reachable without opening
  settings first.

**Folder icon** — Mark all as read, Rename folder, Dissolve folder. The rows read the folder LIVE out of
`serverStripLayoutProvider`, so a rename that lands while the menu is open shows.

**Home button** — one row, "Mark all DMs as read", with the current unread total as the trailing hint. It exists
because an unread badge on Home comes from the DM counts, and a conversation that is no longer reachable can
leave one behind with no tile to click. See `markAllDmsSeen` in `providers_server.md`.

**Where the right click is wired.** Server and folder icons carry their own `ContextMenuTarget` in
`_buildServerIcon` / `_buildFolderIcon`, because they also sit inside the `DragTarget` + `LongPressDraggable`
machinery. The Home button uses the `onContextMenu` prop on `_ServerIcon` / `_DockTile`, which wraps the
icon ABOVE its `HollowFocusRing` — the `Shortcuts` has to be an ancestor of the focus node or the key route
never fires.

## ServerFolderPopup (Overlay)

File: `lib/src/ui/components/server_folder_popup.dart`

### Entry Point: showServerFolderPopup()

Creates an `OverlayEntry` containing `_FolderPopupOverlay`. Parameters:
- `folder`: the `FolderStripItem` to display.
- `anchor`: screen position for popup placement.
- `isDock`: controls popup positioning direction (above for dock, right-side for classic).
- `onServerSelected(serverId)`: callback. Removes overlay entry then calls the selection callback.
- `onRenameRequested`: callback. Removes overlay then triggers rename dialog.

### _FolderPopupOverlay

`ConsumerStatefulWidget` with `SingleTickerProviderStateMixin`. Manages entrance/exit animation.

**Animation:** the shared popover motion (design language 3.8).
- `AnimationController` at `HollowDurations.fast`; one `CurvedAnimation` (`HollowCurves.enter`, reverse `HollowCurves.exit`) drives both.
- Scale: `HollowMotion.popoverScale` (0.96) -> 1.0. Fade: 0 -> 1.
- Scale alignment: `Alignment.bottomCenter` for dock mode, `Alignment.centerLeft` for classic mode.
- Dismiss (`_dismiss()`) sets `reverseDuration = HollowDurations.exit`, reverses, then calls `onDismiss`; a dismiss while already reversing is ignored.

**Auto-dismiss on folder dissolution:**
Watches `serverStripLayoutProvider` live. If `currentFolder` (found by `folder.id`) is null (folder was dissolved during drag-out), schedules `onDismiss` in a post-frame callback and renders `SizedBox.shrink`.

**Layout constants:**
- `iconSize`: 38px.
- `columns`: 5.
- `iconSpacing`: 6px.
- `itemWidth`: 46px (icon + 8px horizontal padding).
- `cardPadding`: `HollowSpacing.md`.
- `cardWidth`: `(46 * 5) + (6 * 4) + (cardPadding * 2)`.

**Positioning:**
- Horizontal: centered on `anchor.dx`, clamped to 8px from screen edges.
- Vertical (dock mode): `bottom = screenHeight - anchor.dy + 8` (popup appears above the bar).
- Vertical (classic mode): `top = anchor.dy`, clamped if popup would extend below screen (top = screenHeight - 208, min 8).

**Structure (Stack):**
1. Full-screen dismiss barrier (`GestureDetector(onTap: _dismiss)`, transparent).
2. Positioned popup card:
   - `Focus(autofocus: true)` with Escape key handler.
   - `ScaleTransition` (anchored `bottomCenter` in dock mode, `centerLeft` in classic) > `FadeTransition` > `Material(transparent)` > `Container`:
     - Background: `hollow.overlay`.
     - Border: `hollow.border`, `radiusLg` corners.
     - Shadow: `HollowShadows.float`.
   - Motion: the shared popover motion (design language 3.8). Scale from `HollowMotion.popoverScale` plus fade, `HollowDurations.fast` in with `HollowCurves.enter`, out in `HollowDurations.exit` with `HollowCurves.exit`; a second dismiss during the exit is ignored.

**Card contents:**
1. **Header row:** folder name (body text, 13px, w600, ellipsis) + pencil edit button (`HollowPressable` with `LucideIcons.pencil` 12px). Pencil tap calls `onRenameRequested`.
2. **Divider:** 1px `hollow.border`.
3. **Server grid:** `Wrap` with `spacing: 6` and `runSpacing: 10`. Contains `_FolderServerItem` for each server ID in `currentFolder.serverIds`.

### _FolderServerItem

`StatelessWidget` inside the folder popup grid. Each item is a column: icon + name label.

**Layout:**
- `HollowPressable(subtle: true)` with `radiusMd` corners, 4px padding.
- `SizedBox(width: iconSize + 8)` — column container.

**Icon (38px):**
- `Container` with deterministic `_colorFromId()` background and `radiusMd` corners, `Clip.antiAlias`.
- If `avatar` bytes exist: `Image.memory` cover fit.
- Otherwise: initials text (white, 13px, w600).

**Badges (Stack, Clip.none):**
- **Unread badge** (top: -4, right: -4): `HollowCountBadge` (accent, `ring: hollow.overlay`, caps at 99+). Only shown when `unreadCount > 0`. Mute-aware (muted servers pass 0).
- **Remove button** (top: -5, left: -5): 16px circle, `hollow.surface` background, `hollow.border` outline, `LucideIcons.x` (9px, textSecondary). Only shown when `onRemove` is non-null (folder has >1 server). `HollowPressable` with zero padding.

**Name label:** server name (or `'Server'` fallback), caption style, 9px, textSecondary, single line with ellipsis, centered.

**Tap:** calls `onServerSelected(serverId)` which dismisses popup and navigates.

## ServerFolderIcon (2x2 Mini-Grid)

File: `lib/src/ui/components/server_folder_popup.dart`

`ConsumerWidget`. Renders a 2x2 grid preview of up to 4 servers from the folder. Used as the icon content for folder items in both `ServerStrip` and `BottomBar`.

**Construction:**
- Takes `folder: FolderStripItem` and `size: double` (48 for ServerStrip, 40 for BottomBar), plus `filled` (default true; the dock passes false, so the tile's own fill shows through).
- Watches `serverListProvider` and `serverAvatarProvider`.
- Takes first 4 server IDs from `folder.serverIds`.

**Grid layout:**
Uses `LayoutBuilder` to handle cases where parent border eats into available space. Computes `actualCellSize = (actualSize - 8) / 2` (8px accounts for 2px padding all sides + 2px gap).

Each cell (`adaptiveCell(i)`):
- If index < folder server count: `ClipRRect` with 20% of cell size as border radius. If avatar exists, `Image.memory` cover fit. Otherwise `Container` with `_colorFromId()` background and initials text (38% of cell size font, white, w600).
- If index >= folder server count (fewer than 4 servers): placeholder `Container` with `hollow.border` at 30% alpha, same border radius.

The grid is: `Column(Row(cell0, gap, cell1), gap, Row(cell2, gap, cell3))` with 2px gaps.

Outer container: `actualSize` x `actualSize`, `hollow.elevated` background, 2px padding.

## Unread Badges — Computation and Mute-Awareness

### DM Unreads (Home Icon)

`ServerStrip` computes `dmUnreadTotal` by iterating `unreadState.dmUnreadCounts.entries` and summing values only where `notifSettings.isDmEnabled(entry.key)` returns true. The badge appears on the home icon only when a server is currently selected (`selectedServerId != null`), hiding it when already viewing DMs. The dock's Home tile carries no DM unread total (the friend chips and Home's list show DM unread).

### Server Unreads

Each server icon checks `notificationSettingsProvider.notifier.isServerMuted(serverId)`. If muted, `serverUnreads = 0`. Otherwise reads `unreadProvider.notifier.serverUnreadCount(serverId)`.

### Folder Unreads

Folder unread count is the sum of all non-muted server unreads within the folder. In `ServerStrip` the badge is hidden when the folder is selected (`isSelected ? 0 : folderUnreads`). The dock sums unread AND mentions (a mention shows `@N`) and keeps the count when the folder is selected.

### Folder Popup Item Unreads

Each `_FolderServerItem` receives `unreadCount` directly, computed as `notifSettings.isServerMuted(sid) ? 0 : ref.watch(unreadProvider.notifier).serverUnreadCount(sid)`.

### Badge Positioning

- **ServerStrip (vertical):** bottom-right (`right: -6, bottom: -4`), 16px height, 9px text.
- **BottomBar (horizontal):** top-right (`right: -sm, top: -xs`), ring `opaqueSurface`, inside the full-height `_DockSlot` so the scroll row never clips it.
- **Folder popup items:** top-right (`top: -4, right: -4`), no minimum width constraint, 9px text.

All badges: `HollowCountBadge` (accent unread, `error` with `@N` for mentions), a ring the colour of the surface behind, caps at `'99+'`, `Clip.none` on parent Stack.

## Shared Helper Functions

Shared by the strip, the bottom bar and the folder popup (one copy each, in `lib/src/core/`):

- `colorFromId(String id)` (`color_utils.dart`) — deterministic HSL color: `hue = (id.hashCode % 360).abs()`, saturation 0.5, lightness 0.45. Same algorithm as `HollowAvatar`.
- `initialsFromName(String name)` (`name_initials.dart`) — first letter of the first two words, uppercased; a single word gives its first 2 characters. Clamped to avoid an empty-string crash. Callers pass the server id when the name is empty.
