# ServerStrip, BottomBar, and Server Folders

The server navigation strip renders server icons, folders, and utility buttons across two layout modes: vertical (classic mode, `ServerStrip`) and horizontal (dock mode, `BottomBar`). Both share the same strip layout data model, drag-reorder system, folder creation/management, and the critical atomic server selection pattern. The folder popup (`ServerFolderPopup`) provides an overlay grid for navigating servers within a folder.

## StripItem Data Model and Persistence

File: `lib/src/core/models/strip_item.dart`

`StripItem` is a sealed Dart class with two concrete subtypes. All strip layout state is a `List<StripItem>`.

- `ServerStripItem` — wraps a single `serverId: String`. Serializes to `{'type': 'server', 'id': serverId}`.
- `FolderStripItem` — wraps `id: String` (hex timestamp), `name: String` (default `'Folder'`), and `serverIds: List<String>`. Serializes to `{'type': 'folder', 'id': id, 'name': name, 'servers': serverIds}`. Has `copyWith()` for immutable updates.

`StripItem.fromJson()` deserializes based on the `'type'` field. Folder names default to `'Folder'` if absent.

## ServerStripLayoutNotifier (Provider)

File: `lib/src/core/providers/server_strip_layout_provider.dart`

`serverStripLayoutProvider` is a `NotifierProvider<ServerStripLayoutNotifier, List<StripItem>>`. State is persisted as JSON in SQLCipher via `storage_api.saveSetting(key: 'server_strip_layout', ...)`.

### Lifecycle

- `build()` returns empty list. Actual data loaded via `loadLayout()`.
- `loadLayout()` reads JSON from storage, deserializes to `List<StripItem>`, then calls `_syncWithServers()`.
- `_syncWithServers()` reconciles layout against `serverListProvider`:
  - Removes top-level `ServerStripItem`s whose `serverId` no longer exists in `serverListProvider`.
  - Removes deleted server IDs from folders. Dissolves folders with 0 remaining servers (removed entirely) or 1 remaining server (replaced with a bare `ServerStripItem`).
  - Appends any server IDs present in `serverListProvider` but missing from the layout (new servers go to the end).
  - On first launch (empty state, non-empty server list), creates bare `ServerStripItem` entries for all servers.

### Mutation Methods

All mutations clone `state`, modify the clone, assign back to `state`, then call `_save()` (async JSON write to SQLCipher).

- `reorder(oldIndex, newIndex)` — moves a top-level item. Adjusts `newIndex` down by 1 if it follows `oldIndex` (standard reorder correction). Bounds-checked.
- `createFolder(serverId1, serverId2)` — finds both servers as top-level `ServerStripItem`s, removes both (higher index first to avoid shift), creates a `FolderStripItem` with hex-timestamp ID and `name: 'Folder'`, inserts at the lower of the two original indices.
- `addToFolder(folderId, serverId)` — removes `serverId` from top-level and from any other folder (dissolving source folder if it drops to 0 or 1 member), then appends to target folder's `serverIds`.
- `removeFromFolder(folderId, serverId, insertIndex)` — removes from folder (dissolving if needed), inserts as top-level `ServerStripItem` at clamped `insertIndex`.
- `renameFolder(folderId, name)` — updates the folder's name via `copyWith`.
- `reorderInsideFolder(folderId, oldIndex, newIndex)` — reorders `serverIds` within a folder.
- `onServerCreated(serverId)` — appends to layout if not already present (checks both top-level and folder contents).
- `onServerDeleted(serverId)` — removes from top-level and from any folder (dissolving if needed).
- `allServerIds()` — returns `Set<String>` of every server ID across all top-level items and folder contents. Used by `_initialServerIds` tracking for entrance animations.

## ServerStrip (Classic Mode Vertical Strip)

File: `lib/src/ui/shell/server_strip.dart`

`ServerStrip` is a `ConsumerStatefulWidget`. Renders a 72px-wide vertical column on the left edge of the classic layout. Background: vertical `LinearGradient` from `opaqueBackground` to a subtle 8% accent tint, with a `right: BorderSide` border.

### State

- `_initialServerIds: Set<String>?` — populated once on first build via `ref.read(serverStripLayoutProvider.notifier).allServerIds()`. Servers NOT in this set get the `_ScaleBounceEntry` entrance animation. Prevents startup bounce.

### Layout Structure (top to bottom)

1. `SizedBox(height: HollowSpacing.md)` — top padding.
2. **Home icon** — `_ServerIconWithIndicator` wrapping `_ServerIcon`. Selected when `selectedServerId == null && !archiveOpen && !shareOpen`. Shows DM unread count when a server is selected (not when already on home). Background: `hollow.accent`. Displays bold `'H'` text. Tap: clears `archiveTabOpenProvider`, `shareTabOpenProvider`, `selectedServerProvider`, `channelListProvider`, `selectedChannelProvider`, `serverSettingsOpenProvider`.
3. **Share icon** — `_ServerIconWithIndicator` + `_ServerIcon`. Selected when `shareOpen`. Background: `hollow.elevated`. Displays `LucideIcons.share2` (accent when selected, textSecondary otherwise). Tap: sets `shareTabOpenProvider` true, clears archive/server/channel/settings state.
4. **Archive icon** — same pattern. Selected when `archiveOpen`. Displays `LucideIcons.archive`. Tap: invalidates `archiveDmListProvider` and `archiveChannelListProvider`, resets archive selection providers, sets `archiveTabOpenProvider` true, clears server/channel/settings state.
5. **Divider** — 32px wide, 2px tall, `hollow.border` color, rounded.
6. **Server icon list** — `Expanded` containing `ListView.builder`. Items interleaved with reorder gaps: `gap0, item0, gap1, item1, ..., gapN`. `itemCount = stripLayout.length * 2 + 1`. Even raw indices are `_VerticalReorderGap` widgets; odd raw indices are server or folder icons. Each item gets `Padding(bottom: HollowSpacing.xs)`.
7. **Add button** — `_ServerIcon` with `LucideIcons.plus` in accent color, tooltip `'Create a server'`. Tap: calls `showCreateServerDialog(context)`. Has bottom padding `HollowSpacing.md`.

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

### _VerticalReorderGap

Thin drop zone between items in the vertical strip. `DragTarget<_StripDragData>` that accepts any drag where `sourceIndex` is not the same slot or immediately before it (no-op guard: `src != index && src != index - 1`).

Visual: `AnimatedContainer` — 36px wide, height transitions from `HollowSpacing.xs` (transparent, dormant) to 4px tall accent-colored bar when active. Margin animates 2px vertical when active.

Calls `serverStripLayoutProvider.notifier.reorder(data.sourceIndex, gapIndex)` on accept.

### _StripDragData (ServerStrip)

Private class carrying drag payload: `serverId: String?`, `folderId: String?`, `sourceIndex: int`. Only one of `serverId`/`folderId` is set per drag.

## CRITICAL: Atomic Server Selection Pattern

File: `lib/src/ui/shell/server_strip.dart`, method `_ServerStripState._selectServer()`
File: `lib/src/ui/shell/bottom_bar.dart`, method `_BottomBarState._selectServer()`

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

1. `archiveTabOpenProvider` = false
2. `shareTabOpenProvider` = false
3. `selectedPeerProvider` = null
4. `serverSettingsOpenProvider` = false
5. `channelListProvider.notifier.setChannels(channels)` — **CRITICAL**: must come before `selectedChannelProvider`
6. `channelLayoutProvider.notifier.setLayout(layout)` — **CRITICAL**: must come before `selectedChannelProvider`
7. `selectedChannelProvider` = channelToSelect
8. `selectedServerProvider` = serverId

### Step 4: Persist last channel

If a channel was selected, updates `lastChannelPerServerProvider` map with `{serverId: channelToSelect}`.

**The 4 CRITICAL providers that must be batched:** `channelListProvider`, `channelLayoutProvider`, `selectedServerProvider`, `selectedChannelProvider`. Writing them out of order or across async boundaries causes the channel sidebar to briefly show stale data or crash on missing channel IDs.

## BottomBar (Dock Mode Horizontal Strip)

File: `lib/src/ui/shell/bottom_bar.dart`

`BottomBar` is a `ConsumerStatefulWidget`. Renders a 59px-tall horizontal bar at the bottom of the dock layout. Background: `hollow.opaqueBackground` with a `top: BorderSide` border.

### State

- `_isDragging: bool` — tracks whether any icon is currently being dragged. Used to suppress tooltips during drag (prevents tooltip from obscuring drop targets).
- `_initialServerIds: Set<String>?` — same pattern as `ServerStrip` for entrance animation gating.

### Layout Structure (left to right)

Three sections in a `Row`:

#### Left: Compact User Panel (140px)

`HollowPressable` with zero border radius, full height. Contains:
- `HollowAvatar` (28px) of local peer, or a placeholder `Container` with `hollow.elevated` background.
- `StatusDot` (7px) showing connection status color (`success` = connected, `warning` = starting, `textSecondary` = loading, `error` = error). `pulse: true` when connected. If `invisibleModeProvider` is active, uses `textSecondary` with no pulse.
- Display name text (caption style, 12px, w600, ellipsis truncation).
- Tap: opens `showProfileCardPopup()` anchored at the bar's position, `anchorBottom: true`.

Vertical 1px border divider (28px height) between left and center.

#### Center: Server Strip (Expanded)

Nested `Row` with:

1. **Home button** — `_BottomServerIcon` with `'H'` text, accent background. Selected when `selectedServerId == null && !archiveOpen && !shareOpen`. Unread count shows DM unreads when server is selected. Tap: `_goHome(ref)` — closes split view, clears all server/channel/archive/share/peer/settings state.

2. **Vertical divider** — 2px wide, 24px tall, `hollow.border`, `HollowSpacing.sm` horizontal margin.

3. **Server icons** — `Expanded` > `Center` > `SingleChildScrollView(horizontal)` > `Row(mainAxisSize: min)`. Interleaved with `_ReorderGap` widgets (one before first, one after each item). Uses `Builder` per item to get a local `BuildContext` for render object access. Pattern-matches `StripItem` to call `_buildServerIcon()` or `_buildFolderIcon()`.

4. **Vertical divider** — same as above.

5. **Add server button** — `_BottomServerIcon` with `LucideIcons.plus`, accent color, `hollow.elevated` background. Tap: `showCreateServerDialog(context)`.

#### Right: Utility Buttons (170px)

Centered `Row` of `HollowPressable` icon buttons, each wrapped in `HollowTooltip`:

- **Share** — `LucideIcons.share2`. Color: accent when `shareOpen`, textSecondary otherwise. Tap: `_openShare(ref)` — closes split, sets share tab open, clears other state.
- **Archive** — `LucideIcons.archive`. Color: accent when `archiveOpen`, textSecondary otherwise. Tap: `_openArchive(ref)` — closes split, invalidates archive lists, resets archive selection, sets archive tab open.
- **Download** — `DownloadIconButton(iconSize: 18)` (separate component).
- **Settings** — `LucideIcons.settings`, textSecondary. Tap: `showUserSettingsDialog(context, ref, openSystemTab: true)`.
- **Recovery phrase** — `LucideIcons.keyRound`, textSecondary. Only visible when `identity.mnemonic != null`. Tap: `showMnemonicDialog(context, identity.mnemonic!)`.

Vertical 1px divider between center and right sections.

### BottomBar Server Icon Rendering (_buildServerIcon)

Similar to `ServerStrip._buildServerIcon()` but with dock-specific differences:

- Icon/avatar size: 38px (vs 44px in ServerStrip). Initials font: 14px (vs 18px). Avatar border radius: 8px.
- **Split view awareness:** `isRightPaneServer = splitState.isSplit && splitState.rightPane?.serverId == serverId`. The icon shows as selected if `isSelected || isRightPaneServer`.
- `LongPressDraggable` callbacks also manage `_isDragging` state via `onDragStarted`, `onDragEnd`, `onDraggableCanceled` (all call `setState`).
- When `isMergeTarget` (server being dragged onto), an `AnimatedContainer` adds an accent-colored `boxShadow` glow (blurRadius: 8, alpha: 0.4).
- Tooltip suppressed during drag: `tooltip: _isDragging ? null : name`.
- Tap calls `_selectServer(ref, serverId)` which handles split view routing.

### BottomBar Folder Icon Rendering (_buildFolderIcon)

Similar to `ServerStrip._buildFolderIcon()` but:

- Uses `_BottomServerIcon` instead of `_ServerIcon` + `_ServerIconWithIndicator`.
- `ServerFolderIcon` size: 38 (vs 48 in ServerStrip).
- `isSelected || isRightPaneServer` for visual selection state.
- Folder popup anchor: `Offset(pos.dx + box.size.width / 2, pos.dy)` with `isDock: true` (popup appears above the bar).
- Right-click (`onSecondaryTapUp`) opens `showFolderRenameDialog()`.
- Tooltip suppressed during drag.

### BottomBar Split View Server Selection

In `_BottomBarState._selectServer()`, if `splitState.isSplit && splitState.focusedPane == 1` (right pane focused):

1. Calls `crdt_api.getServerChannels(serverId: serverId)` directly (FFI, not through provider) to avoid overwriting the global `channelListProvider` which belongs to the left pane.
2. Picks a channel: prefers `lastChannelPerServerProvider[serverId]`, then first text channel, then first channel.
3. Calls `splitViewProvider.notifier.navigateRightToServer(serverId, channelId: channelToSelect)`.
4. Returns early (does NOT touch the global channel/server providers).

If not in split right-pane mode, falls through to the standard atomic selection pattern.

### _goHome, _openShare, _openArchive

All three close the split view first via `splitViewProvider.notifier.closeSplit()` if `split.isSplit`. Then clear/set the relevant tab providers and reset server/channel/peer/settings state. `_openArchive` additionally invalidates archive list providers and resets archive selection providers.

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
- Background: `hollow.error` (red).
- Border: 2px `hollow.background` (creates an outline effect against the strip background).
- Text: white, 9px, w700, `height: 1`. Caps at `'99+'`.

Tracks `_hovering` via `MouseRegion` for the indicator height animation.

## _BottomServerIcon (Horizontal Strip Icon Widget)

File: `lib/src/ui/shell/bottom_bar.dart`

Private `StatefulWidget`. 38x38 rounded square with a bottom-edge indicator. Combines the roles of both `_ServerIcon` and `_ServerIconWithIndicator` from the vertical strip.

- **Border radius animation:** `radiusLg` transitions to 12.0 (pill-ish) on hover or selected.
- **Hover color:** same `Color.lerp` pattern as `_ServerIcon`.
- **Selection border:** same 2px accent border pattern, gated by `isSelected && showBorder`.

### Bottom-Edge Indicator

Instead of a left-edge pill, uses a bottom-edge horizontal bar:
- `Positioned(bottom: -8)` — pinned below the icon via `Stack(clipBehavior: Clip.none)`.
- Width: 28px (selected), 16px (hovering), 0px (default). Height: 3px constant.
- Color: `hollow.textPrimary` when width > 0, transparent otherwise.
- `AnimatedContainer` with `HollowDurations.fast` and `HollowCurves.enter`.

### Unread Badge

`Positioned(right: -5, top: -4)` — overlaps top-right corner (vs bottom-right in vertical strip).
- Min width: 14px, height: 14px, horizontal padding: 3px.
- Background: `hollow.error`, border: 2px `hollow.background`.
- Text: white, 8px, w700. Caps at `'99+'`.

## _ReorderGap (Horizontal Strip Drop Zone)

File: `lib/src/ui/shell/bottom_bar.dart`

`DragTarget<_StripDragData>`. Same no-op guard as `_VerticalReorderGap` (`src != index && src != index - 1`).

Visual: `AnimatedContainer` — height: 38px (matches icon height), width transitions from `HollowSpacing.xs` (transparent, dormant) to 8px wide accent-colored bar when active. Margin: 2px horizontal when active. Duration: `HollowDurations.fast`.

## _ScaleBounceEntry (Entrance Animation)

File: both `server_strip.dart` and `bottom_bar.dart` (duplicated)

`StatefulWidget` with `SingleTickerProviderStateMixin`. Plays a scale bounce animation on first build. Used for newly created/joined server icons (those not in `_initialServerIds`).

- `AnimationController`: 400ms duration (or `Duration.zero` if `HollowDurations.animationsDisabled`).
- `TweenSequence<double>`: 0.0 -> 1.1 (60% weight, overshoot) -> 0.95 (20% weight, undershoot) -> 1.0 (20% weight, settle).
- Curve: `Curves.easeOut`.
- Wraps child in `ScaleTransition`.
- Keyed with `ValueKey('bounce-$serverId')` or `ValueKey('bounce-${folder.id}')`.

Folders never get the bounce (both files check `isNew` and folders always return false).

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

- **Gap active:** colored accent bar appears (4px tall vertical, 8px wide horizontal).
- **Merge target (server-on-server):** `AnimatedScale` to 1.08x. In BottomBar, also adds accent glow `boxShadow`.
- **Drop target (server-on-folder):** `AnimatedScale` to 1.08x.
- **Drag source:** 30% opacity fade.

### BottomBar Drag State Tracking

`_isDragging` boolean is set in `onDragStarted` and cleared in `onDragEnd`/`onDraggableCanceled`. While true, tooltips are suppressed (`tooltip: _isDragging ? null : name`) to prevent them from interfering with drop targets. The vertical `ServerStrip` does not track this state (tooltips always show).

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

### Folder Auto-Dissolution

The `ServerStripLayoutNotifier` automatically dissolves folders in multiple places:
- `_syncWithServers()`: during server list reconciliation.
- `addToFolder()`: when removing a server from its source folder.
- `removeFromFolder()`: when the removed server was the second-to-last.
- `onServerDeleted()`: when a deleted server was in a folder.

Dissolution rules: 0 remaining = remove folder entirely. 1 remaining = replace `FolderStripItem` with `ServerStripItem(serverId: remainingId)`.

### Folder Rename

Two entry points:
1. **Right-click** on folder icon (`onSecondaryTapUp`) in both `ServerStrip` and `BottomBar`.
2. **Pencil button** in the folder popup header.

Both call `showFolderRenameDialog()` which opens `showHollowDialog` containing `_FolderRenameDialog`.

`_FolderRenameDialog` is a `ConsumerStatefulWidget`:
- 280px wide container with `HollowSpacing.xl` padding.
- Title: `'Rename Folder'`.
- `HollowTextField` with `maxLength: 32`, autofocus, submit-on-enter.
- Cancel (ghost button) / Save (filled button) row.
- Save trims input, calls `serverStripLayoutProvider.notifier.renameFolder(folder.id, name)`, then pops.

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

**Animation:**
- `AnimationController`: 180ms duration (or zero if animations disabled).
- Scale: 0.92 -> 1.0 (`Curves.easeOutCubic`).
- Fade: 0.0 -> 1.0 (`Curves.easeOut`).
- Scale alignment: `Alignment.bottomCenter` for dock mode, `Alignment.centerLeft` for classic mode.
- Dismiss (`_dismiss()`) reverses the animation then calls `onDismiss`.

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
   - `ScaleTransition` > `FadeTransition` > `Material(transparent)` > `Container`:
     - Background: `hollow.surface`.
     - Border: `hollow.border`, `radiusLg` corners.
     - Shadow: black 30% alpha, 16px blur, 4px Y offset.

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
- **Unread badge** (top: -4, right: -4): `hollow.error` pill with count text (white, 9px, w700, caps at 99+). Only shown when `unreadCount > 0`. Mute-aware (muted servers pass 0).
- **Remove button** (top: -5, left: -5): 16px circle, `hollow.surface` background, `hollow.border` outline, `LucideIcons.x` (9px, textSecondary). Only shown when `onRemove` is non-null (folder has >1 server). `HollowPressable` with zero padding.

**Name label:** server name (or `'Server'` fallback), caption style, 9px, textSecondary, single line with ellipsis, centered.

**Tap:** calls `onServerSelected(serverId)` which dismisses popup and navigates.

## ServerFolderIcon (2x2 Mini-Grid)

File: `lib/src/ui/components/server_folder_popup.dart`

`ConsumerWidget`. Renders a 2x2 grid preview of up to 4 servers from the folder. Used as the icon content for folder items in both `ServerStrip` and `BottomBar`.

**Construction:**
- Takes `folder: FolderStripItem` and `size: double` (48 for ServerStrip, 38 for BottomBar).
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

Both `ServerStrip` and `BottomBar` compute `dmUnreadTotal` by iterating `unreadState.dmUnreadCounts.entries` and summing values only where `notifSettings.isDmEnabled(entry.key)` returns true. The badge appears on the home icon only when a server is currently selected (`selectedServerId != null`), hiding it when already viewing DMs.

### Server Unreads

Each server icon checks `notificationSettingsProvider.notifier.isServerMuted(serverId)`. If muted, `serverUnreads = 0`. Otherwise reads `unreadProvider.notifier.serverUnreadCount(serverId)`.

### Folder Unreads

Folder unread count is the sum of all non-muted server unreads within the folder. The badge is hidden when the folder is selected (`isSelected ? 0 : folderUnreads`) to avoid showing a badge for the server you're already viewing.

### Folder Popup Item Unreads

Each `_FolderServerItem` receives `unreadCount` directly, computed as `notifSettings.isServerMuted(sid) ? 0 : ref.watch(unreadProvider.notifier).serverUnreadCount(sid)`.

### Badge Positioning

- **ServerStrip (vertical):** bottom-right (`right: -6, bottom: -4`), 16px height, 9px text.
- **BottomBar (horizontal):** top-right (`right: -5, top: -4`), 14px height, 8px text.
- **Folder popup items:** top-right (`top: -4, right: -4`), no minimum width constraint, 9px text.

All badges: `hollow.error` background, `hollow.background` border (2px in strip icons, none in popup), white text, caps at `'99+'`, `Clip.none` on parent Stack.

## Shared Helper Functions

Duplicated in all three files:

- `_colorFromId(String id)` — deterministic HSL color: `hue = (id.hashCode % 360).abs()`, saturation 0.5, lightness 0.45. Same algorithm as `HollowAvatar`.
- `_initialsFromName(String name)` — splits on whitespace, takes first letter of first two words (uppercase). If single word, takes first 2 characters. Clamped to avoid empty string crash.
