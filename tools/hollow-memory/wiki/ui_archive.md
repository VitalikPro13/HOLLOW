# Archive UI — Message History and Data Management

The Archive system provides read-only access to the user's entire message history (DMs + channels), vault file management with erasure-coded shard status, imported archive verification/viewing, and recovery pool coordination. Desktop: accessed via the Archive dashboard in the shell. Mobile: bottom nav tab index 2 (`MobileArchiveTab`), with push navigation to `MobileArchiveViewerRoute` and `MobileImportedArchiveViewerRoute`. See `wiki/ui_mobile.md` for mobile-specific documentation.

---

## Layout (redesigned 2026-09-25, design session 20)

**`shell/archive_dashboard.dart` (ArchiveDashboard).** A `PlaceHeader` (`shell/place_header.dart`, fixed 52 px: title, tab chips, trailing actions) over one body. ONE row of `HollowChip`s, **Messages / Vault files / Imported**, driven by `archiveSectionProvider` (`ArchiveSection { messages, vault, imported }`; replaced `archiveSubTabProvider` + `myDataInnerTabProvider`, whose three levels of tabs truncated "Vault Fil..."). Header actions: Vault = ghost "Join a recovery pool" (hidden while a pool runs); Imported = filled `LoadArchiveButton`.

**Messages (`my_data_view.dart`):** `ArchiveSplit` = a 280 px list pane on `surface` with a hairline, plus the viewer. Shared by Imported.

**`archive_conversation_list.dart`:** ONE list in the sidebar's order: search ("Search conversations"), a "Direct messages" group (dense `HollowSectionHeader`), hidden DMs behind a "Hidden" toggle row with its count (auto-shown while searching), then one group per server (export = `HollowIconButton` 24 on the group header) with its channels. Rows are `HollowListRow` (avatar 24, or a `#` in a 24 box so names align), the message count quiet at the end (caption, textTertiary, tabular); selection = accentMuted fill, NO weight change. Hide/show and export sit in a right-click menu (`ContextMenuTarget` + `showHollowMenu`); no eye icon at rest. Loading = one spinner; error = "Your conversations didn't load" + Try again.

**Selection writes happen at the TAP:** `selectArchiveConversation(ref.read, dm:, channel:)` sets the selection and runs `resetArchiveViewerState` (sender filter, search, date jump). The old viewer did this in `build()`, which asserted (red screen in debug on opening a conversation). Opening the place (dock `_openPlace`, Classic strip) calls `selectArchiveConversation(ref.read)` to clear.

**`archive_message_viewer.dart`:** nothing picked = `HollowEmptyState` ("Pick a conversation to read it back"); DM and channel viewers under an `ArchiveToolbar`; load failures = `archiveLoadError(retry)`. Helpers shared with Imported and the phone: `jumpToArchiveDate`, `toggleArchiveSearch`, `archiveLoadError`.

**Vault files (`vault_files_view.dart`):** full width (the old left column held one placeholder sentence). One collapsible section per server (subheading name, "N of M recoverable", in success when all), open by default when it has files; inside, ghost Export shards / Import shards / Start a recovery pool, category groups (dense headers with counts), and file rows as `HollowListRow` (type icon, `calendarDateLabel` · size, `HollowBadge` "Recoverable" success / "N of K shards" warning / neutral). "Shards" stays the vocabulary (`.hollow-shards`).

**`recovery_pool_dashboard.dart`** (replaces the Vault body while a pool runs): section header "Recovery pool" + "Gathering shards for <server>"; the initiator's Stop = `outline(danger)` behind a confirm, a member's = ghost Leave; invite link in mono + copy; a 96 px gauge (design-ignore) and three stats in a `Wrap` (Recovered success / Partly here warning / Missing); "Helping" lists names and avatars via `identityOf` (never peer ids); recovered files by file name from `diskPath`.

**Imported (`imported_archives_view.dart`):** `loadImportedArchive` / `pickAndLoadImportedArchive` (verify, add, select; `importedArchiveBusyProvider` gates the button AND drag and drop). With NO archives loaded, the list's empty state + drop target takes the whole pane (never two empty states side by side). Rows: kind icon, name, "Direct messages · 120 messages · Sep 25"; a shield icon only when something failed; remove = `HollowIconButton` x. Viewer: `ArchiveToolbar` with `archiveVerdictBadge` (Verified success / Partly verified warning / Signature invalid error; NO tooltip, it repeated the banner, Vitalik) + `ArchiveVerificationBanner` (a warning strip on a problem, one quiet "Signed by X on Sep 25. N messages verified..." line otherwise) + `ArchiveChannelSelector` (HollowChips in an `EdgeScrollRow`) for multi-channel server archives.

---

## Archive Shared Viewer Core — lib/src/ui/archive/shared/

All four archive message viewers (desktop My Data, desktop Imported Archives, and the two mobile routes `mobile_archive_viewer_route.dart` / `mobile_imported_archive_viewer_route.dart`) render through one shared core (extracted 2026-07-14; removed the 34-52% duplication and the five worst complexity findings). Six files:

### archive_message_list.dart
- `ArchiveDmMessageList` / `ArchiveChannelMessageList` (public ConsumerWidgets) over a private generic `_ArchiveMessageListCore<T>`.
- The core owns: `ItemScrollController`/`ItemPositionsListener`, `_highlightIndex` (1500ms auto-clear), jump-to-date (listens `archiveJumpToDateProvider`; the `ref.listen` MUST be registered in `build()` — an initState registration is rejected by Riverpod and silently no-ops), binary-search `_jumpToDate` (scroll alignment 0.1), `_scrollToIndex` (alignment 0.3), search-match computation, and the per-item frame: `DateSeparator` → `shouldGroup` header → reply preview → bubble → `ArchiveDeletedOverlay` → `EditHistoryIndicator` → action wrapper.
- **Reply preview text (2026-09-14):** `replyPreviewFor` in each public widget calls `messagePreviewText(replyMsg.text, attachment: replyMsg.fileAttachment)` (`lib/src/core/message_preview.dart`), not the raw text: a photo replies as "Photo", a video as "Video", a voice note as "Voice message", an unknown attachment as its file name, an emote token as `:name:`. Never an emoji glyph.
- Parameterized per surface: `ArchiveActionWrapper<T>` builder (desktop passes `MessageHoverWrapper` closures — copy/save/proof logic stays at call sites; mobile passes `LongPressMessage` + `showMobileArchiveMessageActions`); `desktopChrome` bool (adds `MessageActionBarScope` → `NotificationListener` → `SelectionArea` + the inline search-bar row); `scrollDuration` callback (mobile: ReduceMotionController-aware, desktop: fixed 300ms); `editsMap` + `editProofContextOf` closures — proof context is direction- and source-dependent (live DM: `isMe ? peerId : localPeerId`; imported: exporter-relative) and is ALWAYS computed at call sites, never in the core.
- `ArchiveMessageListController` + `ArchiveListSearchBar`: mobile renders the search bar OUTSIDE the list (above loading/empty states) and drives scroll-to-match through the controller.

### archive_shared_widgets.dart
`ArchiveSearchBar` (find-in-page bar: text field, "N of M" counter, prev/next/close; the counter is a plain non-flex Row child — wrapping it in `Flexible` halves the `Expanded` text field), `EditHistoryIndicator` (expandable edit timeline; proof chain: edit i=0 verifies via `prevSignature`/original signature, i>0 via `edits[i-1].signature` since the previous edit signed the current oldText), `ArchiveDeletedOverlay` (message at 50% opacity, "Deleted at HH:MM" in `error` beneath), `LongPressMessage` moved to `lib/src/ui/components/long_press_message.dart` (shared with mobile_chat_route).

### archive_sender_filter.dart
Desktop: `ArchiveFilterButton` = a `HollowIconButton` (selected while filtering) opening `showHollowMenu` hung off the button (`alignEnd`): "Everyone" + each sender, checked. The old unanchored dialog (fixed top:100/right:80) is gone. Mobile: `ArchiveFilterSheet` via `showArchiveFilterSheet()` (sheet, search field, `HollowListRow`s with a check).

### archive_toolbar.dart
`ArchiveToolbar` IS `ChatHeaderBar` (the live chat's header): leading, title, subtitle "<server> · N messages" (`archiveCountLabel`, "N of M" while filtered), badges `HollowBadge('Read only')` + extras, actions = filter / Jump to date / Search (selected while open) / Export as grey `HollowIconButton`s. `ArchiveMobileToolbar`: 44 px icon buttons, subtitle ends "· Read only".

### archive_verification_banner.dart
`archiveVerdictBadge(...)`, `ArchiveVerificationBanner` (see Imported above; no `dense`, no `quietWhenValid`), `ArchiveChannelSelector`.

### archive_file_actions.dart (2026-09-25)
`saveArchivedAttachment(context, ref, attachment)` (ONE desktop save routine, was four copies: OS save dialog, WebP conversion, download-manager record, one pick at a time), `pickArchiveDate` (date picker themed from the CURRENT theme; the old ones forced `ThemeData.dark()`), `archiveHoverActions(...)` (the read-only `MessageHoverWrapper`: save, copy text or image, signature details). The phone keeps `saveArchivedAttachmentMobile` (bytes-based save sheet).

### imported_archive_prep.dart
Pure helper `prepareImportedArchive({data, localPeerId, filterSender, selectedChannelId, displayNameOf, avatarOf})` — no Flutter/Riverpod imports; callers pass display-name closures. Converts + filters an FFI `ArchiveData` into everything the imported viewers render: dm/channel messages (sender-filtered), `unfilteredChannelMessages` (for reply lookups), `uniqueSenders`, `senderNames`/`senderAvatars`, `editsMap`, `proofContext`/`proofMsgType`, `headerTitle`/`headerSubtitle` (channel subtitle uses `serverName` on both form factors), and banner data (one wording on both form factors; dates via `calendarDateLabel`).

---

## Provider Reference Summary

All archive state is managed through providers in `lib/src/core/providers/archive_provider.dart`:

| Provider | Type | Purpose |
|---|---|---|
| `archiveSectionProvider` | StateProvider\<ArchiveSection\> | messages / vault / imported |
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
| `loadImportedArchive` | `archive_api.verifyArchive()` | Verify imported archive |
| `importedArchiveDataProvider` | `archive_api.readArchiveData()` | Load full archive data |
| `saveArchivedAttachment` | `network_api.convertImageFormat()` | WebP to PNG/JPG conversion |
| `RecoveryPoolDashboard._stop` | `crdt_api.stopRecoveryPool()` | Stop (confirm) / leave recovery pool |
| `showExportArchiveDialog` | (dialog-internal) | Export conversation to .hollow-archive |

---

## Shared Patterns Across Archive Views

Since 2026-07-14 these are no longer copy-paste patterns — the rendering stack, bubble composition chain, search, jump-to-date, and scroll-highlight logic are LITERAL shared code in `lib/src/ui/archive/shared/` (see the Shared Viewer Core section). What each viewer still owns:

**Per-viewer:** data acquisition (live providers vs `importedArchiveDataProvider`), proof callbacks; saving is shared (`saveArchivedAttachment` desktop, `saveArchivedAttachmentMobile` phone), and proof-context computation (direction/source-dependent — never centralize).

**Desktop vs mobile:** desktop passes `desktopChrome: true` (SelectionArea, hover actions, inline search bar); mobile uses `ArchiveListSearchBar` + `ArchiveMessageListController` outside the list, long-press actions, ReduceMotionController-aware scroll durations, and `ArchiveMobileToolbar`/`showArchiveFilterSheet` instead of the desktop toolbar/menu. Phone tab (`mobile_archive_tab.dart`): the same one chip row and one list at touch size (`HollowListRow(touch: true)`), long press for row actions.
