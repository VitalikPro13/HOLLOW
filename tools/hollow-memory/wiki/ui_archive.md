# Archive UI — Message History and Data Management

The Archive system provides read-only access to the user's entire message history (DMs + channels), vault file management with erasure-coded shard status, imported archive verification/viewing, and recovery pool coordination. Desktop: accessed via the Archive dashboard in the shell. Mobile: bottom nav tab index 2 (`MobileArchiveTab`), with push navigation to `MobileArchiveViewerRoute` and `MobileImportedArchiveViewerRoute`. See `wiki/ui_mobile.md` for mobile-specific documentation.

---

## ArchiveDashboard — Top-Level Tab Switcher

**File:** `lib/src/ui/shell/archive_dashboard.dart`

### ArchiveDashboard (ConsumerWidget)
Top-level container for the Archive section. Renders a tab bar at the top with two sub-tabs and switches the body between them.

**Provider reads:**
- `archiveSubTabProvider` (StateProvider\<ArchiveSubTab\>) — tracks which sub-tab is active; defaults to `ArchiveSubTab.myData`.

**Layout:**
- Container with `hollow.background` color.
- Column: top tab bar + Expanded body.
- Tab bar: Row with "Archive" heading on the left, two `_SubTabPill` widgets centered (flanked by Spacers), separated by `HollowSpacing.sm`.
- Body: conditionally renders `MyDataView` (when `myData`) or `ImportedArchivesView` (when `importedArchives`).

**Tab switching:** Tapping a pill writes to `archiveSubTabProvider.notifier`.

### _SubTabPill (StatelessWidget)
Pill-shaped toggle button. Props: `label`, `isSelected`, `onTap`.

**Visual states:**
- Selected: accent background at 15% alpha, accent border at 30% alpha, accent text with w600 weight.
- Unselected: transparent background, `hollow.border` border, `hollow.textSecondary` text with normal weight.
- Wrapped in `HollowPressable` with `radiusMd` border radius.

---

## MyDataView — Two-Panel Layout for User's Own Data

**File:** `lib/src/ui/archive/my_data_view.dart`

### MyDataView (ConsumerWidget)
Master layout for the "My Data" sub-tab. Fixed 280px left panel + flexible right panel.

**Provider reads:**
- `myDataInnerTabProvider` — which inner tab is active (dms / channels / vaultFiles).
- `recoveryPoolProvider` — current recovery pool state (or null).

**Right panel routing logic:**
1. If `innerTab == vaultFiles` AND `recoveryPool != null` AND `pool.isActive` AND `!pool.isPending` -> `RecoveryPoolDashboard`.
2. Else if `innerTab == vaultFiles` -> `VaultFilesView`.
3. Else -> `ArchiveMessageViewer`.

**Left panel:** Always `ArchiveConversationList` inside a 280px-wide container with `hollow.opaqueBackground` and a right border.

---

## ArchiveConversationList — Left Panel Conversation Browser

**File:** `lib/src/ui/archive/archive_conversation_list.dart`

### ArchiveConversationList (ConsumerWidget)
Left panel of "My Data." Contains inner tab pills (DMs / Channels / Vault Files), a search field, and a scrollable conversation list.

**Provider reads:**
- `myDataInnerTabProvider` — determines which list to show.

**Layout (Column):**
1. Inner tab bar: Row of three `_TabPill` widgets (DMs, Channels, Vault Files), each `Expanded` with `HollowSpacing.xs` gaps.
2. Search field: `HollowTextField` with search icon prefix, writes to `archiveSearchProvider`. Hidden when `innerTab == vaultFiles`.
3. Content list (Expanded): switches on `innerTab`:
   - `dms` -> `_DmList`
   - `channels` -> `_ChannelList`
   - `vaultFiles` -> `_VaultFilesPlaceholder`

### _TabPill (StatelessWidget)
Inner tab toggle. Same visual pattern as `_SubTabPill` but uses `radiusSm`, `HollowTypography.caption` at 12px, and center-aligned text.

### _DmList (ConsumerStatefulWidget)
Scrollable list of DM conversations with hidden/visible partitioning.

**State:** `_hiddenExpanded` (bool) — whether the hidden DM section is expanded.

**Provider reads:**
- `archiveDmListProvider` (FutureProvider\<List\<ArchiveDmEntry\>\>) — async list of DM conversations with peer ID and message count. Loaded from `archive_api.listDmPeers()` + `archive_api.countDmMessages()`.
- `archiveSearchProvider` — current search text for filtering.
- `archiveSelectedDmProvider` — currently selected DM peer ID.
- `profileProvider` — display names and avatars for all peers.
- `hiddenArchiveDmsProvider` — set of peer IDs the user has hidden.

**Filtering:**
- If search is non-empty, filters entries by display name (case-insensitive contains).
- Partitions filtered entries into `visible` (not in hiddenSet) and `hidden` (in hiddenSet).

**Empty state:** Shows "No DM conversations" or "No matches" centered text.

**List structure (ListView):**
1. Visible DMs: `_DmRow` for each entry.
2. If hidden entries exist: `_HiddenHeader` (expandable) + `AnimatedSize` wrapping hidden `_DmRow` items.

**Selection:** Tapping a DM row sets `archiveSelectedDmProvider` to the peer ID and clears `archiveSelectedChannelProvider`.

### _DmRow (ConsumerWidget)
Single DM conversation entry. Props: `entry` (ArchiveDmEntry), `isSelected`, `isHidden`, `onTap`, `onToggleHidden`.

**Provider reads:** `profileProvider` for display name.

**Layout (Row inside HollowPressable):**
- `HollowAvatar` (28px) with peer avatar.
- Display name text (accent color when selected, w600 weight).
- Eye/EyeOff toggle button (13px icon) — calls `onToggleHidden` to hide/unhide the DM.
- Message count badge: pill with count text on `hollow.elevated` background.

**Selection highlight:** Container with accent background at 12% alpha when selected.

### _HiddenHeader (StatelessWidget)
Collapsible header for the hidden DMs section. Shows animated chevron (rotates 90deg when expanded), "Hidden" label, and count badge.

**Animation:** `AnimatedRotation` with `HollowDurations.fast` and `HollowCurves.subtle`.

### _ChannelList (ConsumerWidget)
Scrollable list of channel conversations grouped by server.

**Provider reads:**
- `archiveChannelListProvider` (FutureProvider\<List\<ArchiveChannelGroup\>\>) — groups of channels per server. Each group has `serverId`, `serverName`, and a list of `ArchiveChannelEntry` objects.
- `archiveSearchProvider` — filters channels by channel name or server name.
- `archiveSelectedChannelProvider` — currently selected channel key (`serverId:channelId`).

**Flattening:** Builds a flat list of `_ChannelListItem` objects, alternating between header items (server name) and channel items. Headers appear only if the group has matching channels after search filtering.

**Header row:** Server name in uppercase caption style + export button (fileOutput icon). The export button calls `showExportArchiveDialog()` with `isServer: true`, passing all channels in the group and a total message count.

**Channel row:** Hash `#` prefix, channel name text, message count badge. Selection sets `archiveSelectedChannelProvider` to `serverId:channelId` and clears `archiveSelectedDmProvider`.

### _ChannelListItem (helper class)
Union type for the flat list. Two named constructors:
- `_ChannelListItem.header(headerName, group)` — `isHeader = true`.
- `_ChannelListItem.channel(entry)` — `isHeader = false`.

### _VaultFilesPlaceholder (StatelessWidget)
Simple text message: "Vault file details are shown in the right panel."

---

## Archive Shared Viewer Core — lib/src/ui/archive/shared/

All four archive message viewers (desktop My Data, desktop Imported Archives, and the two mobile routes `mobile_archive_viewer_route.dart` / `mobile_imported_archive_viewer_route.dart`) render through one shared core (extracted 2026-07-14; removed the 34-52% duplication and the five worst complexity findings). Six files:

### archive_message_list.dart
- `ArchiveDmMessageList` / `ArchiveChannelMessageList` (public ConsumerWidgets) over a private generic `_ArchiveMessageListCore<T>`.
- The core owns: `ItemScrollController`/`ItemPositionsListener`, `_highlightIndex` (1500ms auto-clear), jump-to-date (listens `archiveJumpToDateProvider`; the `ref.listen` MUST be registered in `build()` — an initState registration is rejected by Riverpod and silently no-ops), binary-search `_jumpToDate` (scroll alignment 0.1), `_scrollToIndex` (alignment 0.3), search-match computation, and the per-item frame: `DateSeparator` → `shouldGroup` header → reply preview (emoji variant: 📷 Image / 📎 filename) → bubble → `ArchiveDeletedOverlay` → `EditHistoryIndicator` → action wrapper.
- Parameterized per surface: `ArchiveActionWrapper<T>` builder (desktop passes `MessageHoverWrapper` closures — copy/save/proof logic stays at call sites; mobile passes `ArchiveLongPressMessage` + `showMobileArchiveMessageActions`); `desktopChrome` bool (adds `MessageActionBarScope` → `NotificationListener` → `SelectionArea` + the inline search-bar row); `scrollDuration` callback (mobile: ReduceMotionController-aware, desktop: fixed 300ms); `editsMap` + `editProofContextOf` closures — proof context is direction- and source-dependent (live DM: `isMe ? peerId : localPeerId`; imported: exporter-relative) and is ALWAYS computed at call sites, never in the core.
- `ArchiveMessageListController` + `ArchiveListSearchBar`: mobile renders the search bar OUTSIDE the list (above loading/empty states) and drives scroll-to-match through the controller.

### archive_shared_widgets.dart
`ArchiveSearchBar` (find-in-page bar: text field, "N of M" counter, prev/next/close; the counter is a plain non-flex Row child — wrapping it in `Flexible` halves the `Expanded` text field), `EditHistoryIndicator` (expandable edit timeline; proof chain: edit i=0 verifies via `prevSignature`/original signature, i>0 via `edits[i-1].signature` since the previous edit signed the current oldText), `ArchiveDeletedOverlay` (40% opacity + "Deleted at HH:MM"), `ArchiveLongPressMessage` (mobile long-press accent-tint wrapper).

### archive_sender_filter.dart
Desktop: `ArchiveFilterButton` + `ArchiveFilterDialog` (top-right anchored, transparent-barrier dialog, searchable participant list, `_clear_` sentinel → null filter). Mobile: `ArchiveFilterSheet` via `showArchiveFilterSheet()` (modal bottom sheet). Presentation deliberately separate per form factor.

### archive_toolbar.dart
`ArchiveToolbar` (desktop header: leading/title/subtitle/count, optional export/jump-to-date/search/filter callbacks, "read-only" badge) and `ArchiveMobileToolbar` (back button, two-line title, smaller badge). Desktop/mobile deliberately NOT merged.

### archive_verification_banner.dart
`ArchiveVerificationBanner` (two-row archive-sig + per-message-sig status; strings passed in from prep; `dense` flag for mobile sizes) and `ArchiveChannelSelector` (horizontal chip row for multi-channel server archives).

### imported_archive_prep.dart
Pure helper `prepareImportedArchive({data, localPeerId, filterSender, selectedChannelId, displayNameOf, avatarOf, mobile})` — no Flutter/Riverpod imports; callers pass display-name closures. Converts + filters an FFI `ArchiveData` into everything the imported viewers render: dm/channel messages (sender-filtered), `unfilteredChannelMessages` (for reply lookups), `uniqueSenders`, `senderNames`/`senderAvatars`, `editsMap`, `proofContext`/`proofMsgType`, `headerTitle`/`headerSubtitle` (channel subtitle uses `serverName` on both form factors), and banner data (`mobile` flag keeps each form factor's existing wording).

---

## ArchiveMessageViewer — Read-Only Message Viewer

**File:** `lib/src/ui/archive/archive_message_viewer.dart`

### ArchiveMessageViewer (ConsumerStatefulWidget)
Right panel of "My Data" for DM and channel message viewing. Routes to the appropriate sub-viewer based on selection state.

**State:** `_prevDm`, `_prevChannel` — track previous selection to detect conversation changes.

**Provider reads:**
- `archiveSelectedDmProvider` — selected DM peer ID (or null).
- `archiveSelectedChannelProvider` — selected channel key (or null).

**Conversation change reset (`_resetOnConversationChange`):** When either selection changes, resets:
- `archiveFilterSenderProvider` -> null
- `archiveMessageSearchOpenProvider` -> false
- `archiveMessageSearchQueryProvider` -> ''
- `archiveSearchMatchIndexProvider` -> 0
- `archiveJumpToDateProvider` -> null

**Routing:**
1. Both null -> empty state: archive icon (64px, 30% alpha) + "Select a conversation" text.
2. DM selected -> `_ArchiveDmViewer(peerId: selectedDm)` with `ValueKey('dm:$selectedDm')`.
3. Channel selected -> `_ArchiveChannelViewer(serverId, channelId)` with `ValueKey('ch:$selectedChannel')`. Channel key is split on `:` (first segment is serverId, rest is channelId joined back).

### _ArchiveDmViewer (ConsumerWidget)
Renders a DM conversation in read-only mode.

**Props:** `peerId`.

**Provider reads:**
- `archiveDmMessagesProvider(peerId)` — async list of `ChatMessage` objects.
- `profileProvider` — display name and avatar for the peer.
- `archiveMessageSearchOpenProvider` — whether search bar is visible.

**Layout (Column):**
1. `ArchiveToolbar` (shared) — shows avatar, display name, message count, jump-to-date button, search toggle, export button.
2. Expanded async content: loading spinner, error text, or `_DmMessageList`.

**Export:** Calls `showExportArchiveDialog()` with `isDm: true`.

### _DmMessageList (ConsumerStatefulWidget)
Thin wrapper: watches `archiveDmEditsProvider(peerId)` and renders `ArchiveDmMessageList` (shared core, `desktopChrome: true`) with a `MessageHoverWrapper` action wrapper. Keeps in this file:
- `_isPicking` (bool) — guards concurrent file save dialogs.
- Hover callbacks: **Save** (`_saveFile()` when `fileAttachment.diskPath != null`), **Copy** (non-empty non-placeholder text), **Copy Image** (`copyImageToClipboard()`), **Message Proof** (`showMessageProofDialog()` with context = peerId for received / localPeerId for own, msgType "dm").
- `proofContextFor: (msg) => msg.isMe ? peerId : localPeerId` (direction-dependent — never simplify).

**_saveFile() method (desktop):**
- Guards with `_isPicking` flag.
- Opens `FilePicker.platform.saveFile()` with type-appropriate extensions.
- For WebP images saved as non-WebP: calls `network_api.convertImageFormat()` FFI.
- Otherwise: copies file directly.
- Records in `downloadManagerStateProvider`.
- Shows success/error toast.

### _ArchiveChannelViewer (ConsumerWidget)
Renders a channel conversation in read-only mode with sender filtering.

**Props:** `serverId`, `channelId`.

**Provider reads:**
- `archiveChannelMessagesProvider(key)` — async list of `ChannelChatMessage`.
- `archiveFilterSenderProvider` — currently filtered sender ID (or null for all).
- `archiveMessageSearchOpenProvider` — search bar visibility.
- `archiveChannelListProvider` — used to resolve channel/server display names.
- `profileProvider` — display names and avatars for all unique senders.

**Sender filter:** Collects unique sender IDs from all messages. When `filterSender != null`, filters messages to only that sender. Header shows "X of Y messages" when filtered.

**Layout:** Same as DM viewer but with `ArchiveToolbar` configured for channel mode: `#` leading, channel name, "in serverName" subtitle, sender filter controls (`ArchiveFilterButton`), export button.

### _ChannelMessageList (ConsumerStatefulWidget)
Thin wrapper over `ArchiveChannelMessageList` (shared core, `desktopChrome: true`), channel twin of `_DmMessageList`:
- Passes `allMessages` (unfiltered) so replies to filtered-out messages still resolve.
- Edit history from `archiveChannelEditsProvider('serverId:channelId')`.
- Proof context `serverId:channelId`, msgType "ch".
- Same `_isPicking` + hover callbacks + `_saveFile` as the DM wrapper.

The header (`ArchiveToolbar`), sender filter (`ArchiveFilterButton`/`ArchiveFilterDialog`), search bar, deleted overlay, and `EditHistoryIndicator` all live in `lib/src/ui/archive/shared/` — see the Shared Viewer Core section above.

---

## ImportedArchivesView — External Archive Viewer

**File:** `lib/src/ui/archive/imported_archives_view.dart`

### ImportedArchivesView (ConsumerWidget)
Two-panel layout for the "Imported Archives" sub-tab. 280px left panel + flexible right panel.

**Left panel:** `_ImportedArchiveList` — archive file list with import controls.
**Right panel:** `_ImportedArchiveViewer` — selected archive content viewer.

### _ImportedArchiveList (ConsumerStatefulWidget)
Left panel: file picker, drag-and-drop target, and list of loaded archives.

**State:** `_dragging` (bool) — whether a file is being dragged over the drop zone.

**Provider reads:**
- `importedArchivePathsProvider` (AsyncNotifierProvider) — persisted list of archive file paths (stored in SQLCipher via `archive_api.getImportedArchivePaths()` / `setImportedArchivePaths()`).
- `selectedImportedArchiveProvider` — currently selected archive path.

**Load button:** "Load Archive" pill button at top. Calls `_pickArchive()`.

**_pickArchive():** Opens `FilePicker.platform.pickFiles()` with `.hollow-archive` extension filter. On success, calls `_loadArchive(path)`.

**_loadArchive(path):**
1. Calls `archive_api.verifyArchive(archivePath: path)` — quick integrity check.
2. Adds path to `importedArchivePathsProvider`.
3. Invalidates `importedArchiveVerifyProvider(path)` for re-fetch.
4. Shows success/error toast.

**Drag-and-drop:** `DropTarget` widget (from `desktop_drop` package). On drag enter/exit toggles `_dragging`. On drop calls `_loadArchive()` with the first file's path.

**Drag overlay:** Semi-transparent background (85% alpha) with centered upload icon and "Drop .hollow-archive file" text, accent border.

**Empty state:** File archive icon (40px), "No imported archives", "Load or drag a .hollow-archive file" caption.

**Archive list:** `ListView.builder` with `_ArchiveEntryCard` per path.

### _ArchiveEntryCard (ConsumerWidget)
Card displaying a loaded archive with verification status, metadata, and remove button.

**Props:** `path`, `isSelected`.

**Provider reads:**
- `importedArchiveVerifyProvider(path)` (FutureProvider) — calls `archive_api.verifyArchive()` and returns verification result with signature validity, message counts, archive type, peer/channel/server info, export timestamp.
- `profileProvider` — display name resolution for DM peers.
- `serverListProvider` — server name resolution.

**Three async states:**
1. **Loading:** Spinner + filename.
2. **Error:** Alert icon (red) + filename + remove button.
3. **Data:** Full card with type icon, name, shield status, remove button, metadata row.

**Verification icons:**
- Valid (archive sig valid + 0 invalid msgs): `shieldCheck` (accent).
- Warning (some invalid msg sigs): `alertTriangle` (amber).
- Invalid (archive sig invalid): `shieldOff` (red).

**Type icons:** `messageSquare` (DM), `server` (server archive), `hash` (single channel).

**Name resolution:**
- DM: `displayNameFor(profiles, peerId)`.
- Server: `serverName` + "N channels" label.
- Channel: `channelName`, with server name from `serverListProvider` if available.

**Metadata row:** Message count ("N msgs"), export date ("YYYY-MM-DD").

**Remove button:** X icon, calls `importedArchivePathsProvider.notifier.removePath(path)`.

### _ImportedArchiveViewer (ConsumerWidget)
Right panel router. Shows empty state when no archive is selected, loading/error states, or `_ArchivePovViewer` with loaded data.

**Provider reads:**
- `selectedImportedArchiveProvider` — path (or null).
- `importedArchiveDataProvider(path)` (FutureProvider) — calls `archive_api.readArchiveData()` and returns `ArchiveData` with messages, edits, verification, channel list, type info.

### _ArchivePovViewer (ConsumerStatefulWidget)
Imported archive message viewer. All derivation now happens in one `prepareImportedArchive()` call (shared pure helper — see Shared Viewer Core); the widget only reads providers, calls prep, and renders.

**Props:** `data` (archive_api.ArchiveData).

**initState:** Resets all shared archive state (filter, search, jump-to-date, selected channel) on mount.

**Provider reads:**
- `identityProvider` — local peer ID.
- `profileProvider` — display names/avatars (passed to prep as closures).
- `archiveFilterSenderProvider` — sender filter.
- `archiveMessageSearchOpenProvider` — search bar visibility.
- `importedArchiveSelectedChannelProvider` — selected channel within server archives.

**Rendering (all shared widgets):** `ArchiveVerificationBanner` (banner strings from prep) → `ArchiveChannelSelector` (server archives with >1 channel; switching resets filter/search) → `ArchiveToolbar` (no export button) → `ArchiveDmMessageList` / `ArchiveChannelMessageList` (`desktopChrome: true`, edits map from prep, `MessageHoverWrapper` action wrapper).

**Proof context:** DM -> exporter-relative (from prep), channel -> `serverId:channelId`. `_isPicking` + `_saveFile` + hover callbacks stay in this file, same as the My Data viewer.

---

## VaultFilesView — Erasure-Coded File Browser

**File:** `lib/src/ui/archive/vault_files_view.dart`

### VaultFilesView (ConsumerWidget)
Right panel for the Vault Files tab. Shows all servers with per-server expandable vault file listings.

**Provider reads:**
- `serverListProvider` — map of serverId -> ServerInfo for all joined servers.

**Empty state:** Hard drive icon + "No servers" when server list is empty.

**Layout (Column):**
1. "Join Recovery Pool" action button at top (calls `showJoinRecoveryPoolDialog()`).
2. `ListView.builder` with `_ServerVaultSection` per server.

### _ServerVaultSection (ConsumerStatefulWidget)
Expandable section for one server showing its vault files grouped by file type.

**Props:** `serverId`, `server` (ServerInfo).

**State:** `_expanded` (bool?) — auto-set to true if server has vault files, false if empty. User toggle overrides afterward.

**Provider reads:**
- `vaultFileStatusProvider(serverId)` (FutureProvider\<List\<VaultFileStatus\>\>) — list of vault files with shard status. Each `VaultFileStatus` has: `fileName`, `originalSize`, `k` (required shards), `localShardCount`, `isReconstructable`, `createdAt`.

**Server header row (HollowPressable):**
- Chevron (down when expanded, right when collapsed).
- Server icon (accent color).
- Server name (w600).
- Summary badge: "No vault files" or "X/Y recoverable" (green when all recoverable).

**Expanded content:**
1. **Action buttons row** (three `_ActionButton` widgets):
   - "Export Shards" (download icon) -> `showExportShardsDialog()` with total shard count.
   - "Import Shards" (upload icon) -> `showImportShardsDialog()` with `onImported` callback that invalidates `vaultFileStatusProvider`.
   - "Start Recovery Pool" (shield icon) -> `showInitiateRecoveryPoolDialog()`.
2. **Grouped file list** via `_buildGroupedFileList()`.

**File grouping (`_buildGroupedFileList`):**
Files are categorized by extension into `_FileCategory` enum values (videos, audio, images, documents, other). Each group sorted by `createdAt` descending (newest first). Rendered in fixed enum order with category headers showing icon, label, and count.

### _FileCategory (enum)
Five categories with display labels and icons:
- `videos` — "Videos", `fileVideo`
- `audio` — "Audio", `fileAudio`
- `images` — "Images", `image`
- `documents` — "Documents", `fileText`
- `other` — "Other", `file`

Extension mapping in `_categorize()`:
- Videos: mp4, webm, mov, mkv, avi, m4v
- Audio: mp3, ogg, wav, flac, m4a, aac, wma
- Images: png, jpg, jpeg, gif, webp, bmp, svg
- Documents: pdf, doc, docx, xls, xlsx, txt, md

### _VaultFileRow (StatelessWidget)
Single vault file entry with shard status visualization.

**Props:** `file` (VaultFileStatus), `hollow`.

**Shard status colors:**
- Reconstructable (localShardCount >= k): green (#4CAF50).
- Partial (localShardCount > 0 but < k): orange (#FFA726).
- No shards: textSecondary.

**Layout (Container with surface background, border):**
- File type icon (resolved by extension).
- File name (w500, 13px) + metadata row: date ("Mon DD, YYYY") + size (B/KB/MB/GB) + shard progress bar (`LinearProgressIndicator`, 3px height).
- Shard count badge: "X/Y shards" in category-colored text on tinted background.

**Static helpers:**
- `_iconForFile()` — maps file extension to Lucide icon.
- `_formatDate()` — converts epoch seconds to "Mon DD, YYYY".
- `_formatSize()` — human-readable byte formatting.

### _ActionButton (StatelessWidget)
Small action button used throughout vault files view. Surface background, sm radius, icon + label in a row.

---

## RecoveryPoolDashboard — Live Recovery Coordination

**File:** `lib/src/ui/archive/recovery_pool_dashboard.dart`

### RecoveryPoolDashboard (ConsumerWidget)
Dashboard for an active recovery pool. Shows progress ring, statistics, member list, and recovered files.

**Provider reads:**
- `recoveryPoolProvider` — current `RecoveryPoolState` (or null). Contains: `serverId`, `isActive`, `isPending`, `isInitiator`, `inviteLink`, `totalFiles`, `reconstructable`, `partial`, `noShards`, `memberPeerIds`, `recoveredFiles`.
- `vaultFileStatusProvider(pool.serverId)` — fallback when pool status hasn't populated yet. Computes local file stats from vault file data.

**Null state:** "No active recovery pool" centered text.

**Fallback logic:** If `pool.totalFiles == 0` and local vault status is available, computes `totalFiles`, `reconstructable`, `partial`, `noShards` from local `VaultFileStatus` list.

**Layout (SingleChildScrollView, top-left aligned):**

1. **Header row:**
   - `StatusDot` with green pulse when active, grey when stopped.
   - "Recovery Pool" heading (18px).
   - Initiator gets "Stop Pool" danger button (calls `_stopPool()`).
   - Non-initiator gets "Leave Pool" ghost button (calls `_leavePool()`).
   - Status text: "Active -- exchanging shards" (green) or "Pool stopped" (grey).

2. **Invite link (if non-empty):**
   - Container with link icon, monospace invite link text (accent), copy button.
   - Copy button writes to clipboard and shows success toast.

3. **Progress ring (`_buildProgressRing`):**
   - 120x120 `CircularProgressIndicator` (8px stroke, green value color, border background).
   - Center overlay: "X/Y" heading + "files" caption.

4. **Stats row (three `_StatCard` widgets):**
   - "Recovered" (green) — reconstructable count.
   - "Partial" (orange) — partial count.
   - "Missing" (grey) — noShards count.

5. **Members section:**
   - "MEMBERS (N)" header in uppercase caption.
   - Empty: "Waiting for members to join..." text.
   - Each member: Container with user icon, truncated peer ID (6...6 format), green status dot.

6. **Recovered files section (if non-empty):**
   - "RECOVERED FILES (N)" header.
   - Each file: Green-tinted container with checkCircle icon, truncated content ID (8...8 format).

### _stopPool() / _leavePool()
Both call `crdt_api.stopRecoveryPool(serverId)` FFI, then `recoveryPoolProvider.notifier.clear()`. Show info/error toast.

### _StatCard (StatelessWidget)
Colored stat display. Expanded width, colored background at 8% alpha, value in heading style (20px), label in caption style.

---

## Provider Reference Summary

All archive state is managed through providers in `lib/src/core/providers/archive_provider.dart`:

| Provider | Type | Purpose |
|---|---|---|
| `archiveSubTabProvider` | StateProvider\<ArchiveSubTab\> | Top-level tab: myData / importedArchives |
| `myDataInnerTabProvider` | StateProvider\<MyDataInnerTab\> | Inner tab: dms / channels / vaultFiles |
| `archiveSelectedDmProvider` | StateProvider\<String?\> | Selected DM peer ID |
| `archiveSelectedChannelProvider` | StateProvider\<String?\> | Selected channel key (serverId:channelId) |
| `archiveSearchProvider` | StateProvider\<String\> | Conversation list search text |
| `archiveFilterSenderProvider` | StateProvider\<String?\> | Message sender filter (channel only) |
| `archiveMessageSearchOpenProvider` | StateProvider\<bool\> | Message search bar visibility |
| `archiveMessageSearchQueryProvider` | StateProvider\<String\> | Message search text |
| `archiveSearchMatchIndexProvider` | StateProvider\<int\> | Current search match index |
| `archiveJumpToDateProvider` | StateProvider\<DateTime?\> | Jump-to-date target (consumed then nulled) |
| `importedArchiveSelectedChannelProvider` | StateProvider\<String?\> | Channel within server archive |
| `archiveDmListProvider` | FutureProvider | DM conversation list (peer IDs + counts) |
| `archiveChannelListProvider` | FutureProvider | Channel groups per server |
| `archiveDmMessagesProvider` | FutureProvider.family\<..., String\> | DM messages by peer ID |
| `archiveChannelMessagesProvider` | FutureProvider.family\<..., String\> | Channel messages by key |
| `archiveDmEditsProvider` | FutureProvider.family\<..., String\> | DM edit history by peer ID |
| `archiveChannelEditsProvider` | FutureProvider.family\<..., String\> | Channel edit history by key |
| `importedArchivePathsProvider` | AsyncNotifierProvider | Persisted imported archive paths |
| `selectedImportedArchiveProvider` | StateProvider\<String?\> | Selected imported archive path |
| `importedArchiveVerifyProvider` | FutureProvider.family\<..., String\> | Verification result per path |
| `importedArchiveDataProvider` | FutureProvider.family\<..., String\> | Full archive data per path |

Additional providers from other files:
- `hiddenArchiveDmsProvider` (Notifier\<Set\<String\>\>) — persisted hidden DM set, in `lib/src/core/providers/hidden_archive_dm_provider.dart`.
- `recoveryPoolProvider` (StateNotifierProvider) — recovery pool state, in `lib/src/core/providers/recovery_pool_provider.dart`. Updated by network events (PoolCreated, PoolJoinedPending, MemberJoined, MemberLeft, PoolStatus, FileRecovered, PoolStopped).
- `vaultFileStatusProvider` (FutureProvider.family\<..., String\>) — vault file shard status per server, in `lib/src/core/providers/vault_file_status_provider.dart`.

---

## FFI Calls

| Call site | FFI function | Purpose |
|---|---|---|
| `archiveDmListProvider` | `archive_api.listDmPeers()`, `archive_api.countDmMessages()` | List DM conversations |
| `archiveDmMessagesProvider` | `archive_api.getDmMessages()` | Fetch DM messages |
| `archiveChannelListProvider` | `archive_api.listChannels()`, `archive_api.countChannelMessages()` | List server channels |
| `archiveChannelMessagesProvider` | `archive_api.getChannelMessages()` | Fetch channel messages |
| `archiveDmEditsProvider` | `archive_api.getDmEdits()` | Fetch DM edit history |
| `archiveChannelEditsProvider` | `archive_api.getChannelEdits()` | Fetch channel edit history |
| `_loadArchive` | `archive_api.verifyArchive()` | Verify imported archive |
| `importedArchiveDataProvider` | `archive_api.readArchiveData()` | Load full archive data |
| `_saveFile` | `network_api.convertImageFormat()` | WebP to PNG/JPG conversion |
| `_stopPool` / `_leavePool` | `crdt_api.stopRecoveryPool()` | Stop/leave recovery pool |
| `showExportArchiveDialog` | (dialog-internal) | Export conversation to .hollow-archive |

---

## Shared Patterns Across Archive Views

Since 2026-07-14 these are no longer copy-paste patterns — the rendering stack, bubble composition chain, search, jump-to-date, and scroll-highlight logic are LITERAL shared code in `lib/src/ui/archive/shared/` (see the Shared Viewer Core section). What each viewer still owns:

**Per-viewer:** data acquisition (live providers vs `importedArchiveDataProvider`), action callbacks (copy/save/proof), `_saveFile()` (desktop: FilePicker path + `downloadManagerStateProvider` record; mobile: bytes-based save, no download-manager record), and proof-context computation (direction/source-dependent — never centralize).

**Desktop vs mobile:** desktop passes `desktopChrome: true` (SelectionArea, hover actions, inline search bar); mobile uses `ArchiveListSearchBar` + `ArchiveMessageListController` outside the list, long-press actions, ReduceMotionController-aware scroll durations, and `ArchiveMobileToolbar`/`showArchiveFilterSheet` instead of the desktop toolbar/dialog.
