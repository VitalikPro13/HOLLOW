# Server and Channel Providers — Server State Management

All server/channel state lives in Riverpod providers declared across four files. This document covers every provider, its type, data flow, invalidation triggers, and relationships to other providers.

Source files:
- `lib/src/core/providers/server_provider.dart`
- `lib/src/core/providers/channel_provider.dart`
- `lib/src/core/providers/server_strip_layout_provider.dart`
- `lib/src/core/providers/unread_provider.dart`
- `lib/src/core/providers/sync_progress_provider.dart`
- `lib/src/core/providers/server_avatar_provider.dart`
- `lib/src/core/models/server_info.dart`
- `lib/src/core/models/channel_info.dart`
- `lib/src/core/models/strip_item.dart`

---

## ServerInfo Model

File: `lib/src/core/models/server_info.dart`

Immutable Dart class with `copyWith`. Fields:

| Field | Type | Default | Description |
|---|---|---|---|
| `serverId` | `String` | required | Unique server identifier |
| `name` | `String` | required | Display name |
| `memberCount` | `int` | `0` | Total member count from CRDT state |
| `channelCount` | `int` | `0` | Total channel count from CRDT state |

No `toJson`/`fromJson` — this model is only used in-memory. Rust FFI returns `ServerFfi` from `crdt_api.getJoinedServers()` and the Dart layer maps fields manually.

---

## ChannelInfo Model

File: `lib/src/core/models/channel_info.dart`

Immutable Dart class with `copyWith`. Fields:

| Field | Type | Default | Description |
|---|---|---|---|
| `channelId` | `String` | required | Unique channel identifier |
| `name` | `String` | required | Display name (e.g. "general") |
| `category` | `String?` | `null` | Category grouping name (optional) |
| `channelType` | `ChannelType` | `ChannelType.text` | Enum: `text` or `voice` |
| `visibility` | `String` | `'everyone'` | Who can see the channel: `"everyone"`, `"moderator"`, `"admin"` |
| `posting` | `String` | `'everyone'` | Who can post in the channel: `"everyone"`, `"moderator"`, `"admin"` |

The `ChannelType` enum has two values: `text` and `voice`. The Rust FFI returns `channelType` as a raw string (`"voice"` or anything else defaults to text).

---

## StripItem Model (Sealed Class)

File: `lib/src/core/models/strip_item.dart`

Sealed class with two concrete subtypes for the server strip layout:

### ServerStripItem
- Single field: `serverId: String`
- JSON: `{"type": "server", "id": "<serverId>"}`
- Represents a standalone server icon in the strip

### FolderStripItem
- Fields: `id: String`, `name: String`, `serverIds: List<String>`
- JSON: `{"type": "folder", "id": "<hex-timestamp>", "name": "<name>", "servers": [...]}`
- `copyWith` supports `name` and `serverIds`
- Folder `id` is generated as `DateTime.now().millisecondsSinceEpoch.toRadixString(16)` at creation time
- Default folder name is `"Folder"`

Deserialization: `StripItem.fromJson()` checks `json['type']` — `"folder"` produces `FolderStripItem`, anything else produces `ServerStripItem`.

---

## serverListProvider

```
NotifierProvider<ServerListNotifier, Map<String, ServerInfo>>
```

File: `lib/src/core/providers/server_provider.dart`

The canonical source of truth for which servers the local user has joined. State is `Map<String, ServerInfo>` keyed by `serverId`.

### Initialization
- `build()` returns empty `{}`.
- `ServerListNotifier.loadFromDb()` calls `crdt_api.getJoinedServers()` (Rust FFI), iterates the returned list, maps each to `ServerInfo(serverId, name, memberCount, channelCount)`, and replaces the entire state map.

### Mutation Methods

**`onServerCreated(serverId, name)`** — called when the Dart event handler receives a `ServerCreated` network event. Creates a new `ServerInfo` with `memberCount: 1` and `channelCount: 1` (assumes the #general channel). Adds to state via `Map.of(state)..` pattern (immutable copy).

**`onServerUpdated(serverId)`** — called on `ServerUpdated` network events. Performs a full DB reload via `crdt_api.getJoinedServers()`, finds the matching server by ID. If found, updates the entry. If NOT found (user was kicked or server deleted while offline), removes the entry from state. This is the only mutation path that handles implicit server removal.

**`onServerDeleted(serverId)`** — called on `ServerDeleted` network events. Removes the entry directly.

### Consumer Relationship
- Read by `serverStripLayoutProvider` during reconciliation (`_syncWithServers()` reads `ref.read(serverListProvider)`)
- Read by `channelListProvider` event handlers to check `selectedServerProvider`
- UI widgets (server strip, server settings, dashboard) watch this provider

---

## selectedServerProvider

```
StateProvider<String?>
```

File: `lib/src/core/providers/server_provider.dart`

Holds the currently selected server ID, or `null` when no server is selected (e.g. user is on the home dashboard or in DMs).

### Critical Batching Requirement
Server switching MUST batch four provider writes atomically in a single synchronous block:
1. `channelListProvider` — set new channels
2. `channelLayoutProvider` — set new layout
3. `selectedServerProvider` — set new server ID
4. `selectedChannelProvider` — set new channel ID

The canonical pattern is in `server_strip.dart:_selectServer`. If these are written across multiple frames, intermediate rebuilds see inconsistent state (e.g. old channels with new server ID).

### Downstream Watchers
- `channelListProvider` event handlers check `ref.read(selectedServerProvider)` to decide whether to apply channel mutations
- `visibleChannelsProvider` watches this
- `canPostInChannelProvider` uses the server ID argument (not this provider directly)

---

## serverSettingsOpenProvider

```
StateProvider<bool>
```

File: `lib/src/core/providers/server_provider.dart`

Boolean toggle for whether the server settings panel is open. When `true`, the settings panel replaces the chat pane in the shell layout. Defaults to `false`.

---

## syncStatusProvider / serverSyncStatusProvider

```
NotifierProvider<SyncStatusNotifier, Map<String, ServerSyncStatus>>
Provider.family<ServerSyncStatus, String>  (convenience)
```

File: `lib/src/core/providers/server_provider.dart`

### ServerSyncStatus Enum
Six states: `idle`, `connecting`, `syncing`, `synced`, `retrying`, `failed`.

### SyncStatusNotifier
State is `Map<String, ServerSyncStatus>` keyed by server ID. Single method:

**`setStatus(serverId, status)`** — immutable copy-and-update. Called by the event handler when Rust emits sync lifecycle events.

### serverSyncStatusProvider (Family)
Convenience `Provider.family<ServerSyncStatus, String>` that watches `syncStatusProvider` and returns the status for a single server, defaulting to `ServerSyncStatus.idle` if no entry exists.

### Transition Flow
Typical lifecycle: `idle` -> `connecting` -> `syncing` -> `synced`. On failure: `syncing` -> `retrying` -> `syncing` (retry succeeds) or `retrying` -> `failed`. The transitions are driven entirely by Rust network events processed in the Dart event handler.

---

## serverMembersProvider

```
FutureProvider.family<List<crdt_api.MemberFfi>, String>
```

File: `lib/src/core/providers/server_provider.dart`

Family provider keyed by server ID. Each invocation calls `crdt_api.getServerMembers(serverId:)` which returns `List<MemberFfi>` from the Rust CRDT store. `MemberFfi` contains fields like `peerId`, `nickname`, role data, and labels.

### Invalidation
This is a `FutureProvider.family` — it caches the result until explicitly invalidated. Invalidation triggers:
- `ServerUpdated` events (the Dart event handler calls `ref.invalidate(serverMembersProvider(serverId))`)
- `RoleChanged` events
- Any CRDT operation that modifies member data

### Downstream Dependents
- `onlineMembersProvider` watches this
- `serverNicknamesProvider` watches this
- `myRoleProvider` and `myPermissionsProvider` are separate FFI calls but are invalidated alongside this provider
- Member panel UI watches this for the member list display

---

## onlineMembersProvider

```
Provider.family<Set<String>, String>
```

File: `lib/src/core/providers/server_provider.dart`

Computes the set of online member peer IDs for a given server. Watches three sources:
1. `peersProvider` — the global map of connected peers
2. `invisiblePeersProvider` — set of peers with invisible status
3. `serverMembersProvider(serverId)` — the member list

Logic: filters members to those whose `peerId` exists in `connectedPeers` AND is NOT in `invisiblePeers`. Returns the resulting `Set<String>`. On `loading` or `error` from the members async, returns empty set `{}`.

---

## myRoleProvider

```
FutureProvider.family<String, String>
```

File: `lib/src/core/providers/server_provider.dart`

Returns the local user's role string for a server (e.g. `"owner"`, `"admin"`, `"moderator"`, `"member"`). Calls `crdt_api.getMyRole(serverId:)` which reads the CRDT store in Rust.

### Invalidation
Invalidated by the Dart event handler on:
- `ServerUpdated` events (the handler invalidates `myRoleProvider(serverId)`)
- `RoleChanged` events that affect the local user

### Downstream Dependents
- `visibleChannelsProvider` watches `myRoleProvider(selectedServer)` for channel visibility filtering
- `canPostInChannelProvider` watches `myRoleProvider(serverId)` for posting permission
- Server settings UI reads this to determine what settings tabs/actions to show

---

## myPermissionsProvider

```
FutureProvider.family<int, String>
```

File: `lib/src/core/providers/server_provider.dart`

Returns the local user's permissions bitmask for a server. Calls `crdt_api.getMyPermissions(serverId:)`.

### Permission Bitmask Constants
Defined in the `Permission` class (same file):

| Constant | Bit | Value |
|---|---|---|
| `manageServer` | `1 << 0` | 1 |
| `manageChannels` | `1 << 1` | 2 |
| `manageRoles` | `1 << 2` | 4 |
| (unused, was `manageInvites`) | `1 << 3` | 8 |
| `kickMembers` | `1 << 4` | 16 |
| `sendMessages` | `1 << 5` | 32 |
| `readMessages` | `1 << 6` | 64 |
| `all` | OR of all above | 119 (excludes bit 3) |

Note: bit 3 (`MANAGE_INVITES`) was removed but the bit position is skipped, not reused.

### Invalidation
Same as `myRoleProvider` — invalidated on `ServerUpdated` and `RoleChanged` events.

### Usage Pattern
Consumers do bitwise AND checks: `perms & Permission.sendMessages == 0` means no send permission.

---

## serverNicknamesProvider

```
Provider.family<Map<String, String>, String>
```

File: `lib/src/core/providers/server_provider.dart`

Extracts nicknames from server members. Watches `serverMembersProvider(serverId)`. Returns `Map<String, String>` mapping `peerId -> nickname` for members with non-empty nicknames only. On `loading`/`error`, returns empty map.

Reactivity: auto-updates whenever `serverMembersProvider` is invalidated/refetched since it uses `ref.watch`.

---

## channelListProvider

```
NotifierProvider<ChannelListNotifier, Map<String, ChannelInfo>>
```

File: `lib/src/core/providers/channel_provider.dart`

Holds the channel map for the currently selected server. State is `Map<String, ChannelInfo>` keyed by `channelId`.

### Loading

**`loadForServer(serverId)`** — calls the static `fetchChannels(serverId)` and replaces state. Used during normal server selection.

**`fetchChannels(serverId)`** — static method, callable without a notifier instance. Calls `crdt_api.getServerChannels(serverId:)`, maps each `ChannelFfi` to `ChannelInfo`. Channel type is determined by string comparison: `"voice"` -> `ChannelType.voice`, anything else -> `ChannelType.text`. Returns the map without updating state. This enables batched provider updates (caller can fetch channels and set them atomically with other provider writes).

**`setChannels(channels)`** — direct state setter for batched updates. Used by the server-switching code to avoid async gaps between provider writes.

### Event Handlers

**`onChannelAdded(serverId, channelId, name, {channelType})`** — guards with `ref.read(selectedServerProvider)` check — only applies if the event's server matches the currently selected server. Creates a new `ChannelInfo` and adds to state.

**`onChannelRemoved(serverId, channelId)`** — same server guard. Removes the channel from state.

**`onChannelRenamed(serverId, channelId, newName)`** — same server guard. Preserves `category` from the existing entry, creates a new `ChannelInfo` with the updated name.

**`clear()`** — resets state to `{}`. Called when switching away from a server.

### Server Guard Pattern
All three event handlers (`onChannelAdded`, `onChannelRemoved`, `onChannelRenamed`) read `selectedServerProvider` and early-return if the event's server ID does not match. This means channel events for non-selected servers are silently dropped at the provider level. The channel data is still persisted in Rust's CRDT store — it will be loaded when the user switches to that server.

---

## channelLayoutProvider

```
NotifierProvider<ChannelLayoutNotifier, String>
```

File: `lib/src/core/providers/channel_provider.dart`

Holds the channel layout JSON string for the currently selected server. The layout defines the visual ordering and grouping (categories) of channels in the sidebar.

### State Format
A JSON array string. Each element has a `"type"` field. Known types include `"channel"` (with `"channel_id"` field). Default: `"[]"`.

### Methods

**`loadForServer(serverId)`** — calls `fetchLayout(serverId)` and sets state. Falls back to `"[]"` on error.

**`fetchLayout(serverId)`** — static method. Calls `crdt_api.getChannelLayout(serverId:)`. Returns the raw JSON string.

**`setLayout(json)`** — direct state setter for batched updates.

**`clear()`** — resets to `"[]"`.

### Batching
Like `channelListProvider`, this provider has a static `fetchLayout` and a `setLayout` to support the atomic server-switching pattern. The server-switching code prefetches both channels and layout, then writes all four providers in one synchronous block.

---

## firstTextChannelInLayout()

```
String? firstTextChannelInLayout(Map<String, ChannelInfo> channels, String layoutJson)
```

File: `lib/src/core/providers/channel_provider.dart`

Standalone function (not a provider) that determines the first text channel in sidebar visual order. Used when auto-selecting a channel on server switch.

### Algorithm
1. Parse `layoutJson` as `List<dynamic>`.
2. Walk items in order. For each item with `type == "channel"`, check if the channel exists in `channels` map and is `ChannelType.text`. If yes, return its ID. Collect all placed IDs in a set.
3. Walk unplaced channels (those in `channels` but not in `placedIds`), sorted alphabetically by name. Return the first text channel found.
4. If no text channel exists at all, return `null`.

This mirrors the sidebar rendering logic: placed channels appear in layout order, then unplaced channels appear alphabetically.

---

## selectedChannelProvider

```
StateProvider<String?>
```

File: `lib/src/core/providers/channel_provider.dart`

Holds the currently selected channel ID, or `null`. Part of the atomic batch during server switching.

---

## lastChannelPerServerProvider

```
StateProvider<Map<String, String>>
```

File: `lib/src/core/providers/channel_provider.dart`

Remembers the last selected channel for each server so switching back restores the user's position. State is `Map<String, String>` mapping `serverId -> channelId`.

### Usage Pattern
When the user selects a channel, the server-switching code writes `lastChannelPerServerProvider[serverId] = channelId`. When switching back to a server, the code checks this map first. If a last-channel exists and is still valid (present in the channel list), it is selected. Otherwise, `firstTextChannelInLayout()` is used as the fallback.

This provider is in-memory only — not persisted to disk. It resets on app restart.

---

## visibleChannelsProvider

```
Provider<Map<String, ChannelInfo>>
```

File: `lib/src/core/providers/channel_provider.dart`

Filters the `channelListProvider` based on the user's role and each channel's `visibility` mode.

### Dependencies (watched)
1. `channelListProvider` — the full channel map
2. `selectedServerProvider` — current server ID
3. `myRoleProvider(selectedServer)` — the user's role string

### Role Priority Mapping
```
owner: 3, admin: 2, moderator: 1, member: 0
```

### Filtering Logic
For each channel entry:
- `visibility == "everyone"` -> always visible
- `visibility == "moderator"` -> visible if role priority >= 1 (moderator, admin, owner)
- `visibility == "admin"` -> visible if role priority >= 2 (admin, owner)
- Any other value -> visible (permissive default)

If `selectedServer` is `null`, returns the unfiltered channel map.

### Important Note
This is UI-only filtering. All members still receive all messages via the server-wide MLS group. Per-channel MLS subgroups are planned but not yet implemented.

---

## canPostInChannelProvider

```
Provider.family<bool, ({String serverId, String channelId})>
```

File: `lib/src/core/providers/channel_provider.dart`

Determines whether the local user can post in a specific channel. Takes a named record argument with `serverId` and `channelId`.

### Dependencies (watched)
1. `channelListProvider` — to look up the channel's `posting` mode
2. `myPermissionsProvider(serverId)` — the user's permission bitmask
3. `myRoleProvider(serverId)` — the user's role string

### Logic (ordered)
1. Look up channel in `channelListProvider`. If not found, return `true` (permissive).
2. Check `Permission.sendMessages` bit in permissions. If bit is NOT set, return `false` immediately (role-level block overrides channel mode).
3. Apply channel `posting` mode with same role priority as visibility:
   - `"everyone"` -> `true`
   - `"moderator"` -> priority >= 1
   - `"admin"` -> priority >= 2
   - Default -> `true`

### Usage
The chat input widget watches this provider to disable/enable the message input field and show a "you can't post here" message.

---

## serverStripLayoutProvider

```
NotifierProvider<ServerStripLayoutNotifier, List<StripItem>>
```

File: `lib/src/core/providers/server_strip_layout_provider.dart`

Manages the ordered list of servers and folders displayed in the server strip (the leftmost column in Classic mode, or the top bar in Dock mode).

### Persistence
Uses `storage_api.saveSetting(key: 'server_strip_layout', value: jsonString)` and `storage_api.loadSetting(key: 'server_strip_layout')`. The JSON is an array of `StripItem.toJson()` objects stored in the SQLCipher `app_settings` table.

### Initialization Flow

**`loadLayout()`**:
1. Loads the JSON string from `app_settings` via `storage_api.loadSetting`.
2. If non-null and non-empty, deserializes via `StripItem.fromJson()` and sets state.
3. Always calls `_syncWithServers()` after loading.

### Reconciliation: `_syncWithServers()`

Reads `serverListProvider` to get the set of valid server IDs, then:

1. **Collect layout IDs** — walks all items, collects server IDs from both `ServerStripItem` and `FolderStripItem`.
2. **Remove deleted servers from top-level** — any `ServerStripItem` whose `serverId` is not in `validIds` is removed.
3. **Remove deleted servers from folders** — for each `FolderStripItem`, filters `serverIds` to valid ones. If the folder becomes empty, remove it. If it has exactly one server, dissolve it into a `ServerStripItem`. Otherwise update with filtered list.
4. **Append new servers** — any server ID in `validIds` that is NOT in the layout is appended as a new `ServerStripItem` at the end.
5. **First launch fallback** — if state is empty but servers exist, creates a flat list of `ServerStripItem` for all servers.
6. Saves if any changes were made.

### Mutation Methods

**`reorder(oldIndex, newIndex)`** — standard list reorder with the `if (newIndex > oldIndex) newIndex--` adjustment. Bounds-checked. Saves after.

**`createFolder(serverId1, serverId2)`** — finds both servers as top-level `ServerStripItem`s, removes them, inserts a new `FolderStripItem` at the lower index. Folder ID is hex timestamp. Default name is `"Folder"`. Saves after.

**`addToFolder(folderId, serverId)`** — removes the server from any top-level position or other folders (dissolving folders that drop to 0-1 members), then appends the server ID to the target folder's `serverIds`. Saves after.

**`removeFromFolder(folderId, serverId, insertIndex)`** — removes the server from the folder (dissolving if needed), then inserts a new `ServerStripItem` at the clamped target index. Saves after.

**`renameFolder(folderId, name)`** — finds the folder by ID, calls `copyWith(name:)`. Saves after.

**`reorderInsideFolder(folderId, oldIndex, newIndex)`** — reorders `serverIds` within a folder. Same `newIndex > oldIndex` adjustment. Saves after.

**`onServerCreated(serverId)`** — checks if server already exists anywhere in layout (top-level or inside folders). If not, appends a new `ServerStripItem`. Saves after.

**`onServerDeleted(serverId)`** — removes from top-level, then removes from all folders (with dissolution logic). Saves after.

### Utility

**`allServerIds()`** — returns `Set<String>` of all server IDs across top-level items and folder contents. Used for reconciliation checks.

### Folder Dissolution Rule
Folders are automatically dissolved (converted back to standalone `ServerStripItem`) whenever their member count drops to 1 or 0. This happens in `_syncWithServers()`, `addToFolder()`, `removeFromFolder()`, and `onServerDeleted()`.

---

## unreadProvider

```
NotifierProvider<UnreadNotifier, UnreadState>
```

File: `lib/src/core/providers/unread_provider.dart`

Tracks unread message counts for both server channels and DMs. Uses a "last seen message ID" approach stored in SQLCipher `app_settings`.

### UnreadState (Immutable)

Seven maps:

| Field | Key Format | Description |
|---|---|---|
| `channelLastSeen` | `"serverId:channelId"` | Last seen message ID per channel |
| `dmLastSeen` | `"peerId"` | Last seen message ID per DM |
| `channelUnreadCounts` | `"serverId:channelId"` | Current unread count per channel |
| `dmUnreadCounts` | `"peerId"` | Current unread count per DM |
| `channelLatestId` | `"serverId:channelId"` | Latest message ID per channel (for live tracking) |
| `dmLatestId` | `"peerId"` | Latest message ID per DM (for live tracking) |
| `channelMentionCounts` | `"serverId:channelId"` | @mention count per channel (separate from unread) |

All default to empty `const {}`. The `copyWith` method supports all seven fields.

**Instance convenience methods** (for use with `ref.watch(unreadProvider.select(...))`):
- `isChannelUnread(serverId, channelId)` -- `channelUnreadCounts > 0`.
- `channelUnreadCount(serverId, channelId)` -- Raw count.
- `channelMentions(serverId, channelId)` -- Mention count.
- `isDmUnread(peerId)` -- `dmUnreadCounts > 0`.
- `dmUnreadCount(peerId)` -- Raw count.
- `serverUnreadCount(serverId)` -- Sum of all channel counts for a server.
- `serverMentionCount(serverId)` -- Sum of all channel mention counts for a server.

### Notification-Aware Unread Counting

`recomputeServerUnread()` respects notification levels via `countUnreadChannelWithMentions()` Rust FFI. For "Mentions Only" channels, only messages containing @mentions or replies count as unread. For "Nothing" channels, unread is always 0. The function takes `max(dbCount, existingInMemoryCount)` to preserve hint-based increments.

`onChannelMessage()` accepts `{bool isMention = false}` to track mentions separately. `markChannelSeen()` clears both unread and mention counts.

Helper methods: `channelMentionCount()`, `serverMentionCount()`, `isChannelMentioned()`.

### Persistence Format
`app_settings` keys:
- `seen:ch:{serverId}:{channelId}` -> last seen message ID for a channel
- `seen:dm:{peerId}` -> last seen message ID for a DM

Only the "last seen" IDs are persisted. Unread counts are computed from DB queries on load and tracked incrementally during runtime.

### Initialization: `loadAll(serverChannels, dmPeerIds)`

Takes a map of `serverId -> List<channelId>` and a list of DM peer IDs. For each:

1. Loads the persisted `seen:ch:` or `seen:dm:` value.
2. If a last-seen ID exists, calls `storage_api.countUnreadChannel(serverId, channelId, lastSeenMessageId)` to count messages after that ID.
3. If NO last-seen ID exists (channel/DM never opened), calls `storage_api.countAllUnreadChannel(serverId, channelId)` or `countAllUnreadDm(peerId)` to count all messages from others.
4. Stores counts > 0 in the state maps.

### Recomputation Methods

**`recomputeServerUnread(serverId, channelIds)`** — re-queries the DB for all channels of a server. Called after message sync completes to catch messages that arrived while offline. Updates `channelUnreadCounts` only (does not modify `channelLastSeen`).

**`recomputeDmUnread(peerId)`** — same pattern for a single DM peer. Called after DM sync completes.

### Live Message Handlers

**`onChannelMessage(serverId, channelId, messageId, isCurrentlyViewing)`**:
- If `isCurrentlyViewing` is `true`, immediately calls `markChannelSeen()` (user is looking at this channel).
- Otherwise, increments `channelUnreadCounts[key]` by 1 and updates `channelLatestId[key]`.

**`onDmMessage(peerId, messageId, isCurrentlyViewing)`**:
- Same pattern: auto-mark-seen if viewing, otherwise increment count.

### Mark-Seen Methods

**`markChannelSeen(serverId, channelId, latestMessageId)`**:
1. Returns early if `latestMessageId` is `null`.
2. Updates `channelLastSeen[key]` with the new ID.
3. Removes the key from `channelUnreadCounts` (clearing unread).
4. Persists via `storage_api.saveSetting(key: 'seen:ch:serverId:channelId', value: latestMessageId)`.

**`markDmSeen(peerId, latestMessageId)`**:
- Same pattern: update `dmLastSeen`, clear `dmUnreadCounts`, persist.

### Query Methods (synchronous, read current state)

| Method | Returns | Description |
|---|---|---|
| `channelUnreadCount(serverId, channelId)` | `int` | Unread count for a specific channel |
| `serverUnreadCount(serverId)` | `int` | Sum of all channel unread counts for a server (iterates keys starting with `serverId:`) |
| `isChannelUnread(serverId, channelId)` | `bool` | Whether count > 0 |
| `isServerUnread(serverId)` | `bool` | Whether any channel in server has unread |
| `dmUnreadCount(peerId)` | `int` | Unread count for a DM |
| `isDmUnread(peerId)` | `bool` | Whether DM has unread |
| `hasAnyDmUnread()` | `bool` | Whether ANY DM has unread (used for badge on Friends tab) |

### Server Unread Aggregation
`serverUnreadCount(serverId)` iterates ALL entries in `channelUnreadCounts` and sums those whose key starts with `"$serverId:"`. This is O(n) over total channels across all servers, but the number is always small.

---

## syncingPeersProvider

```
NotifierProvider<SyncingPeersNotifier, Map<String, Set<String>>>
```

File: `lib/src/core/providers/sync_progress_provider.dart`

Tracks which peer IDs are currently syncing, grouped by server. State is `Map<String, Set<String>>` keyed by server ID, value is set of syncing peer IDs.

### Methods

**`addPeer(serverId, peerId)`** — adds the peer to the server's syncing set. Creates the set if it does not exist.

**`clearServer(serverId)`** — removes the entire server entry (all peers done syncing for that server).

---

## isPeerSyncingProvider

```
Provider.family<bool, String>
```

File: `lib/src/core/providers/sync_progress_provider.dart`

Convenience provider that checks if a specific peer ID is currently syncing in ANY server. Watches `syncingPeersProvider` and returns `true` if any server's peer set contains the given peer ID. Used by the member panel to show sync indicators next to peer names.

---

## syncProgressProvider

```
NotifierProvider<SyncProgressNotifier, Map<String, SyncProgress>>
```

File: `lib/src/core/providers/sync_progress_provider.dart`

Accumulates sync progress per server. State is `Map<String, SyncProgress>`.

### SyncProgress Class
```
receivedCount: int (default 0)
totalCount: int (default 0)
```

### Methods

**`updateProgress(serverId, received, total)`** — ACCUMULATES onto existing progress. Adds `received` to current `receivedCount` and `total` to current `totalCount`. This means multiple sync batches from different peers are aggregated into a single running total per server.

**`clearServer(serverId)`** — removes the server entry. Called when sync completes or the server is deselected.

### Usage
The UI reads `syncProgressProvider[serverId]` to display a progress indicator (e.g. "Syncing 142/500 messages..."). The accumulation pattern means each batch notification adds to the running total rather than replacing it.

---

## serverAvatarProvider

```
NotifierProvider<ServerAvatarNotifier, Map<String, Uint8List>>
```

File: `lib/src/core/providers/server_avatar_provider.dart`

In-memory cache of server avatar bytes. State is `Map<String, Uint8List>` keyed by server ID.

### Methods

**`loadAvatar(serverId)`** — calls `crdt_api.getServerAvatar(serverId:)`. If bytes are non-null and non-empty, caches them in state. If null/empty (no avatar set), removes any existing cached entry for that server (handles avatar removal).

**`loadAll(serverIds)`** — iterates the list and calls `loadAvatar` for each server sequentially. Called on startup after server list is loaded.

### Caching Behavior
- Purely in-memory. No disk cache beyond the CRDT store itself.
- The avatar bytes come from the Rust CRDT store via FFI.
- Invalidation: call `loadAvatar(serverId)` again after a `ServerUpdated` event that includes an avatar change. The CRDT store is the source of truth.

---

## Provider Dependency Graph

```
serverListProvider
  |
  +-> serverStripLayoutProvider (_syncWithServers reads serverListProvider)
  +-> serverMembersProvider (family, per server)
  |     +-> onlineMembersProvider (watches members + peersProvider + invisiblePeersProvider)
  |     +-> serverNicknamesProvider (extracts nicknames from members)
  +-> myRoleProvider (family, per server, separate FFI call)
  |     +-> visibleChannelsProvider (watches role + channelListProvider + selectedServerProvider)
  |     +-> canPostInChannelProvider (watches role + permissions + channelListProvider)
  +-> myPermissionsProvider (family, per server, separate FFI call)
  |     +-> canPostInChannelProvider
  +-> serverAvatarProvider (separate, loaded alongside)

selectedServerProvider
  +-> channelListProvider (event handlers guard on selected server)
  +-> visibleChannelsProvider (watches selectedServerProvider)

channelListProvider
  +-> visibleChannelsProvider
  +-> canPostInChannelProvider

channelLayoutProvider (parallel to channelListProvider, both set during server switch)

selectedChannelProvider (set during server switch, used by chat pane)

lastChannelPerServerProvider (in-memory, read during server switch for restore)

unreadProvider (standalone, reads storage_api)

syncStatusProvider -> serverSyncStatusProvider (family convenience)
syncingPeersProvider -> isPeerSyncingProvider (family convenience)
syncProgressProvider (standalone accumulator)
```

---

## Event-Driven Invalidation Summary

The Dart event handler (in `event_provider.dart`) dispatches Rust `NetworkEvent` variants to these providers:

| Network Event | Provider Actions |
|---|---|
| `ServerCreated` | `serverListProvider.onServerCreated()`, `serverStripLayoutProvider.onServerCreated()` |
| `ServerUpdated` | `serverListProvider.onServerUpdated()`, invalidate `serverMembersProvider(id)`, `myRoleProvider(id)`, `myPermissionsProvider(id)`, `serverAvatarProvider.loadAvatar()` |
| `ServerDeleted` | `serverListProvider.onServerDeleted()`, `serverStripLayoutProvider.onServerDeleted()` |
| `ChannelAdded` | `channelListProvider.onChannelAdded()` |
| `ChannelRemoved` | `channelListProvider.onChannelRemoved()` |
| `ChannelRenamed` | `channelListProvider.onChannelRenamed()` |
| `SyncStatus` changes | `syncStatusProvider.setStatus()` |
| `SyncProgress` | `syncProgressProvider.updateProgress()`, `syncingPeersProvider.addPeer()` |
| `SyncCompleted` | `syncProgressProvider.clearServer()`, `syncingPeersProvider.clearServer()`, `unreadProvider.recomputeServerUnread()` |
| `MessageReceived` (channel) | `unreadProvider.onChannelMessage()` |
| `MessageReceived` (DM) | `unreadProvider.onDmMessage()` |
| `RoleChanged` | invalidate `myRoleProvider(id)`, `myPermissionsProvider(id)` |

---

## Atomic Server Switch Pattern

The canonical server-switching sequence (implemented in `server_strip.dart:_selectServer`):

1. **Prefetch** (async): `ChannelListNotifier.fetchChannels(serverId)` and `ChannelLayoutNotifier.fetchLayout(serverId)` — both are static methods that return data without touching provider state.
2. **Batch write** (synchronous, single frame):
   - `ref.read(channelListProvider.notifier).setChannels(channels)`
   - `ref.read(channelLayoutProvider.notifier).setLayout(layout)`
   - `ref.read(selectedServerProvider.notifier).state = serverId`
   - `ref.read(selectedChannelProvider.notifier).state = channelId`
3. **Channel selection**: check `lastChannelPerServerProvider` for a remembered channel. If valid, use it. Otherwise call `firstTextChannelInLayout(channels, layout)`.

This pattern prevents intermediate rebuilds where downstream widgets see mismatched state (e.g. old channels with new server ID).
