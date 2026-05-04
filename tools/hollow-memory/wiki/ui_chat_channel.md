# ChannelChatPane -- Server Channel Chat View

Primary chat view for server text channels. Located at `lib/src/ui/chat/channel_chat_pane.dart` (~2500 lines). Handles message display, input, file attachments, voice messages, @mention autocomplete, in-channel search, pinned messages, link previews, reply threading, reactions, permission-gated posting, sync/connection status, vault file downloads, and unread tracking.

## Widget Class Hierarchy

- `ChannelChatPane` -- `ConsumerStatefulWidget`, the top-level widget. Constructor params: `serverId`, `channelId`, `channelName`, `splitPaneIndex` (nullable int for split view: null=not split, 0=left, 1=right).
- `_ChannelChatPaneState` -- main state class (~1200 lines of logic + ~800 lines of build).
- `_ChannelConnectionStatus` -- `ConsumerWidget`, inline connection/encryption status in the header bar.
- `_SyncIndicator` -- `ConsumerStatefulWidget`, sync progress display (Syncing/Synced/Failed/Retrying).
- `_SpinningRefreshIcon` -- `StatefulWidget`, continuously rotating `LucideIcons.refreshCw` for sync-in-progress.
- `_VaultHealthIndicator` -- `ConsumerWidget`, vault upload/download activity icon (only for 6+ member servers).
- `_UnreadPill` -- `StatelessWidget`, floating "N new messages" pill at bottom when scrolled up.
- `_MentionCandidate` -- data class holding `peerId`, `displayName`, `subtitle`, `avatarBytes` for autocomplete entries.

## How ChannelChatPane Differs from ChatPane (DM)

ChatPane (`lib/src/ui/chat/chat_pane.dart`) handles 1:1 DMs with Olm encryption. ChannelChatPane handles server channels with MLS group encryption. Key differences:

- **Server context**: ChannelChatPane takes `serverId` + `channelId` + `channelName`; ChatPane takes `peerId` + `peerDisplayName`.
- **Provider**: ChannelChatPane uses `channelChatProvider` (keyed by `serverId:channelId`); ChatPane uses `chatProvider` (keyed by peer ID).
- **Nicknames**: ChannelChatPane resolves display names via `serverNicknamesProvider(serverId)` + `serverDisplayNameFor()` which prefers server nicknames over profile display names. ChatPane uses `displayNameFor()` directly.
- **@mention autocomplete**: Only in ChannelChatPane. Scans server members, supports `@everyone`, shows overlay with avatars and names.
- **@mention highlighting**: ChannelChatPane checks if message text contains `@everyone`, `@localName`, or `@localNick` and passes `isMentioned` to `ChannelMessageBubble` for highlight styling. ChatPane has no mention highlighting.
- **Permission gating**: ChannelChatPane checks `canPostInChannelProvider` and `myPermissionsProvider` to hide input or show "no permission" message. ChatPane has no permission checks.
- **Pinned messages**: ChannelChatPane has a pin icon in the header showing count, opening a pinned messages dialog. ChatPane has no pins.
- **In-channel search**: ChannelChatPane has a search bar (Ctrl+K toggle) that queries `storage_api.searchChannelMessages()`. ChatPane has no search.
- **Sync status**: ChannelChatPane shows `_ChannelConnectionStatus` + `_SyncIndicator` + `_VaultHealthIndicator` in the header. ChatPane shows simpler connection status.
- **Split view**: ChannelChatPane supports `splitPaneIndex` for dock-mode split view; ChatPane does not.
- **Message bubble**: Uses `ChannelMessageBubble` (server-oriented, with mention highlight) vs `MessageBubble` (DM-oriented).
- **Member panel toggle**: ChannelChatPane header has users icon toggling `memberPanelProvider`. ChatPane has no member panel.

## State Variables in _ChannelChatPaneState

- `_controller` -- `TextEditingController` for the message input field.
- `_itemScrollController` -- `ItemScrollController` for `ScrollablePositionedList` programmatic scrolling.
- `_itemPositionsListener` -- `ItemPositionsListener` tracking which items are visible.
- `_scrollOffsetController` -- `ScrollOffsetController` for animated scroll offset changes.
- `_focusNode` -- `FocusNode` for the input text field.
- `_historyLoaded` -- bool, true after initial DB history load completes.
- `_loadingHistory` -- bool, prevents concurrent history loads.
- `_isPicking` -- bool, prevents concurrent file picker dialogs.
- `_editingMessageId` -- nullable String, ID of message currently being edited inline.
- `_replyToMessageId` -- nullable String, ID of message being replied to.
- `_replyToText` -- nullable String, preview text of the reply target.
- `_replyToSenderName` -- nullable String, display name of reply target sender.
- `_replyToImagePath` -- nullable String, image disk path for reply preview thumbnail.
- `_lastTypingSent` -- nullable DateTime, throttles typing indicators to 3-second intervals.
- `_highlightIndex` -- nullable int, index of message currently highlighted (search jump or reply tap).
- `_searchController` -- `TextEditingController` for the search bar input.
- `_searchResults` -- `List<dynamic>`, results from `searchChannelMessages()`.
- `_searchFocusNode` -- `FocusNode` for the search bar.
- `_showScrollPill` -- bool, true when user is scrolled away from bottom.
- `_stagedFilePath` -- nullable String, path of file picked but not yet sent.
- `_stagedFileName` -- nullable String, name of staged file.
- `_stagedFileIsImage` -- bool, whether staged file is an image (png/jpg/jpeg/gif/bmp/webp).
- `_isRecordingVoice` -- bool, true while voice message recording is active (swaps input row for `VoiceRecorderBar`).
- `_stagedPreviewUrl` -- nullable String, URL detected in input for link preview.
- `_stagedPreview` -- nullable `network_api.LinkPreviewRef`, fetched OG metadata for staged URL.
- `_stagedPreviewLoading` -- bool, true while link preview is being fetched.
- `_stagedHollowLink` -- nullable `HollowLink`, parsed `hollow://` protocol link from input.
- `_urlDebounce` -- nullable `Timer`, 600ms debounce for URL detection in input text.
- `_urlRegex` -- static `RegExp` matching `https?://` and `hollow://` URLs.
- `_mentionOverlay` -- nullable `OverlayEntry`, the @mention autocomplete popup.
- `_mentionLayerLink` -- `LayerLink` connecting the text field to the overlay position.
- `_mentionCandidates` -- `List<_MentionCandidate>`, filtered member list for current @mention query.
- `_mentionSelectedIndex` -- int, currently highlighted candidate in the overlay.
- `_mentionAtPosition` -- int, cursor position of the `@` character triggering autocomplete.
- `_stateKey` -- computed getter returning `'$serverId:$channelId'` used as map key for providers.

## Lifecycle: initState, dispose, didUpdateWidget

**initState**: (1) Posts a frame callback to close the search bar (`channelSearchOpenProvider = false`) on entering a new channel. (2) Calls `_loadHistory()` to load messages from SQLCipher DB. (3) Registers `_onScrollPositionChanged` listener on `_itemPositionsListener`.

**dispose**: (1) Dismisses @mention overlay. (2) Cancels URL debounce timer. (3) Removes scroll position listener. (4) Disposes all controllers and focus nodes.

Note: Riverpod `ref` usage is forbidden in `dispose()`, which is why search bar close is done in `initState` via post-frame callback.

## History Loading and Cache Invalidation

`_loadHistory()`: Guarded by `_loadingHistory` and `_historyLoaded` flags. Always loads from DB on first open because the in-memory cache may contain only late-arriving network messages. Calls `channelChatProvider.notifier.loadHistory(serverId, channelId)` which merges DB results with in-memory messages. Then loads pinned messages via `pinnedProvider.notifier.loadPins()`. After load, jumps scroll to bottom and marks channel as read via `unreadProvider.notifier.markChannelSeen()`.

**Cache-cleared reload**: In `build()`, if `messages.isEmpty && _historyLoaded && !_loadingHistory`, the state resets `_historyLoaded = false` and schedules `_loadHistory()` in a post-frame callback. This handles the case where sync cleared the server cache (`clearServerCache`) while the channel was not being viewed.

## Scroll Management

Uses `scrollable_positioned_list` package with sentinel pattern: `itemCount: messages.length + 1` where the last item is `SizedBox.shrink()` used for bottom anchoring.

- `_isNearBottom` -- getter checking if any visible item has `index >= messages.length - 1`. Used for the unread pill.
- `_isInAutoScrollZone` -- getter checking if any visible item has `index >= messages.length - 3`. More forgiving than `_isNearBottom`; treats user as "following along" if within the last 3 messages.
- `_jumpToBottom()` -- post-frame callback, calls `_itemScrollController.jumpTo(index: messages.length, alignment: 1.0)`. Instant, no animation.
- `_scrollToBottom()` -- post-frame callback, calls `_scrollOffsetController.animateScroll(offset: 100000, duration: 150ms, curve: easeOut)`. Smooth animated scroll.
- `_scrollToMessage(index)` -- sets `_highlightIndex = index`, calls `_itemScrollController.scrollTo()` with 300ms duration, easeOutCubic curve, alignment 0.3. Clears highlight after 1500ms.
- `_onScrollPositionChanged()` -- updates `_showScrollPill`, sets `chatAtBottomProvider`, auto-marks channel as read when user scrolls back to bottom.

**Auto-scroll on new messages**: In `build()`, `ref.listen(channelChatProvider)` compares previous and next message counts. If new messages arrived and `_isInAutoScrollZone`, calls `_scrollToBottom()`.

## Channel Header Bar

48px height, surface background, bottom border. Contains left-to-right:

1. **Hash icon** -- `LucideIcons.hash`, 20px, textSecondary color.
2. **Channel name** -- `widget.channelName` in `HollowTypography.subheading`, bold.
3. **Connection status** -- `_ChannelConnectionStatus` widget (see below).
4. **Spacer**.
5. **Pinned messages button** -- only shown when `pinnedIds.isNotEmpty`. Shows pin icon + count. Tooltip shows count. Taps open `_showPinnedMessages()` dialog.
6. **Search button** -- toggles `channelSearchOpenProvider`. Icon tints accent when search is open.
7. **Member panel toggle** -- toggles `memberPanelProvider`. Icon tints accent when panel is open.
8. **Split view toggle** -- only shown in dock layout mode (`layoutModeProvider`). Shows columns icon. When split is active, closes this pane; when not split, opens split. Icon tints accent when split is active.

## Connection and Sync Status Display

`_ChannelConnectionStatus`: Watches `peersProvider` (connected peers map), `serverMembersProvider(serverId)`, `identityProvider`. Determines connection stage: if any other server members are in the connected peers map, stage is `ConnectionStage.encrypted` (MLS group = always encrypted). Otherwise `ConnectionStage.offline`. Renders `ConnectionProgress` widget + sync/vault indicators when encrypted.

`_SyncIndicator`: Watches `serverSyncStatusProvider(serverId)` and `syncProgressProvider[serverId]`. Four states:
- **syncing** -- accent color spinning refresh icon, label "Syncing N/M..." (or just "Syncing...").
- **synced** -- green success dot, label "Synced".
- **retrying** -- warning color spinning refresh icon, label "Retrying...".
- **failed** -- red error dot, label "Sync failed", plus a retry button that calls `network_api.requestChannelSync()` (throttled to 3s between taps).

`_VaultHealthIndicator`: Only renders for servers with 6+ members (erasure coding threshold). Watches `vaultStatusProvider[serverId]`. Only shows when there are active uploads or downloads (not complete/failed). Shows `LucideIcons.database` icon with tooltip describing activity count.

## Pinned Messages Dialog

`_showPinnedMessages()`: Opens a `showDialog` with the pinned messages list. Filters `pinnedIds` against current messages in memory, sorts by timestamp descending. Each entry shows sender name (via `serverDisplayNameFor`), time, and message content (text, image thumbnail via `Image.file` or `GifFileImage`, or file placeholder). Date separators between messages on different days via `shouldShowDateSeparator()`. Uses `DateSeparator` widget (imported from `chat_pane.dart`).

The dialog is a `Dialog` with `hollow.elevated` background, rounded rectangle shape with border. Constrained to 420x400. Header row has pin icon + "Pinned Messages" title + close button. If no pinned messages are found in the current view, shows "Pinned messages not loaded in current view."

## In-Channel Search

Activated by tapping the search icon in the header bar or via Ctrl+K shortcut (handled in `hollow_shell.dart` which toggles `channelSearchOpenProvider`).

**Provider listening**: `ref.listen(channelSearchOpenProvider)` in `build()`: when opened, focuses `_searchFocusNode` in post-frame callback. When closed, clears search controller and results.

**Search bar UI**: Conditionally rendered below the header when `channelSearchOpenProvider` is true. Contains a `HollowTextField` with search icon prefix, hint "Search in #channelName...", autofocus, dense mode. `onChanged` calls `_onSearch()`.

**`_onSearch(query)`**: If query is empty, clears results. Otherwise calls `storage_api.searchChannelMessages(serverId, channelId, query, limit: 20)`. Results stored in `_searchResults`. Each result rendered as a pressable row showing sender name (via `serverNicknamesProvider`), timestamp, and text snippet (max 2 lines). Tapping a result: finds the message index in the current message list, closes search, scrolls to that message via `_scrollToMessage(idx)`.

## @Mention Autocomplete System

Triggered by typing `@` preceded by a space, newline, or at position 0 in the input text.

**`_updateMentionAutocomplete(text)`**: Called from `_onTextChanged()`. Scans backward from cursor to find `@`. Extracts query string after `@`. Reads `serverMembersProvider(serverId)`, `profileProvider`, `serverNicknamesProvider(serverId)`. For each member, checks if display name, server nickname, or profile name starts with the query (case-insensitive). Also adds `@everyone` candidate (inserted at index 0) with subtitle "Notify all members". Limits to first 6 candidates. Calls `_showMentionOverlay()`.

**`_showMentionOverlay()`**: Removes any existing overlay, creates new `OverlayEntry` with `_buildMentionOverlay()`, inserts into `Overlay.of(context)`.

**Overlay UI (`_buildMentionOverlay()`)**: Uses `CompositedTransformFollower` linked to `_mentionLayerLink` (target anchored to the text field). Positioned above the input (followerAnchor: bottomLeft, targetAnchor: topLeft, offset (0, -4)). Width 260px, max height 220px. Elevated background with border and shadow. Contains a `ListView.builder` with candidates. Each candidate row: `HollowPressable` with avatar (or `@` icon for `@everyone`), display name in bold, optional subtitle. Selected candidate has accent background tint.

**Keyboard navigation**: The `Focus` widget wrapping the input field intercepts key events when `_mentionOverlay != null`:
- ArrowDown: increments `_mentionSelectedIndex`, rebuilds overlay.
- ArrowUp: decrements `_mentionSelectedIndex`, rebuilds overlay.
- Enter/Tab: accepts the selected candidate via `_acceptMention()`.
- Escape: dismisses overlay via `_dismissMentionOverlay()`.
- Other keys: fall through to `handleChatInputKey()`.

**`_acceptMention(candidate)`**: Replaces text from `_mentionAtPosition` to current cursor with `@displayName ` (with trailing space). Updates `TextEditingValue` with correct selection offset. Dismisses overlay.

**`_dismissMentionOverlay()`**: Removes overlay entry, clears candidates list, resets selected index and at-position.

## Permission-Based Input Gating

Two permission checks gate what the user sees:

1. **Read permission**: `myPermissionsProvider(serverId)` bitwise AND with `Permission.readMessages`. If zero, the entire message list area is replaced with an `LucideIcons.eyeOff` icon and "You don't have permission to read messages in this channel" text.

2. **Post permission**: `canPostInChannelProvider((serverId, channelId))` combines `Permission.sendMessages` check with channel posting mode (`everyone`/`moderator`/`admin`) cross-referenced with the user's role priority. If false, the input bar is replaced with "You don't have permission to send messages in this channel" text.

These are UI-only restrictions. All members still receive all messages via the server-wide MLS group. Per-channel MLS subgroups (Option B) are needed for true enforcement.

## Message List Rendering

Wrapped in `ChatDropZone` (for drag-and-drop file attach). Main structure is a `Column` of: header, optional search bar, message list (Expanded), typing indicator, reply preview, staged file preview, staged link preview, input bar.

**Empty state**: If `messages.isEmpty` and `_historyLoaded`, shows welcome message: large hash icon, "Welcome to #channelName", "This is the beginning of the channel." If not loaded yet, shows nothing.

**Message list**: `SelectionArea` wrapping `ScrollablePositionedList.builder`. Context menu disabled (returns `SizedBox.shrink()`). Scrollbars disabled. Initial scroll index is `messages.length` with alignment 1.0 (pinned to bottom).

Each message item: checks `shouldGroup()` for grouping consecutive messages from same sender within time window. If not grouped, `showHeader = true`. Wraps each message in a `MessageHoverWrapper` which provides the action bar (edit, delete, reply, react, pin, download, copy, copy image, info).

**`MessageHoverWrapper` callbacks**:
- `onEditStart`: only for own messages without file attachment. Sets `_editingMessageId`.
- `onEditSubmit(newText)`: clears `_editingMessageId`, calls `channelChatProvider.notifier.editMessage()`.
- `onEditCancel`: clears `_editingMessageId`.
- `onDelete`: only for own messages. Calls `channelChatProvider.notifier.deleteMessage()`.
- `onReply`: sets `_replyToMessageId`, `_replyToText`, `_replyToSenderName`, `_replyToImagePath`. Focuses input.
- `onReaction(emoji)`: toggles reaction. Checks if user already reacted via `msg.reactions[emoji]?.contains(localPeerId)`. Calls `addReaction()` or `removeReaction()` on notifier.
- `onPin`: only if user has `Permission.manageChannels`. Toggles pin via `crdt_api.pinMessage()` / `crdt_api.unpinMessage()`.
- `onDownload`: complex logic depending on file state (see File Download section).
- `onCopy`: copies message text to clipboard via `Clipboard.setData()`.
- `onCopyImage`: calls `copyImageToClipboard()` for image attachments.
- `onInfo`: opens `showMessageProofDialog()` with sender info, signature, public key, timestamp.

**Message bubble**: Renders `ChannelMessageBubble` with `msg`, `serverId`, `showHeader`, reply info, highlight state, mention highlight, `onReplyTap` (scrolls to reply target), `onToggleReaction`.

**Date separators**: `shouldShowDateSeparator()` compares message date with previous message date. Inserts `DateSeparator` widget above the message when dates differ.

**Message grouping spacing**: Grouped messages (no header) have no extra top padding. Ungrouped messages (with header) get `top: HollowSpacing.sm + 2` padding.

## Mention Highlighting in Messages

For each message in the list, the code checks: `msg.text.contains('@everyone')` OR `msg.text.contains('@localName')` OR (localNick exists AND `msg.text.contains('@localNick')`). If any match, `isMentioned: true` is passed to `ChannelMessageBubble`, which applies a highlight background to the bubble.

## Typing Indicator

Watches `typingProvider[stateKey]` which returns a `Set<String>` of peer IDs currently typing. Maps each peer ID to a display name via `serverNicknamesProvider` + `serverDisplayNameFor()`. Renders `TypingIndicatorBar(names: [...])` below the message list when set is non-empty.

## Reply Preview Bar

Shown when `_replyToMessageId != null`. Left accent border (3px) + surface background. Contains: reply icon, "Replying to {senderName}" in accent color, reply text preview (1 line, ellipsis), optional image thumbnail (32x32, supports GIF via `GifFileImage`), close button (X icon).

## Staged File Preview

Shown when `_stagedFilePath != null`. Surface background with top border. Contains: image thumbnail (48x48) or file icon, filename text, close button. Supports GIF preview via `GifFileImage`.

## Link Preview (Phase 6.75)

Two types of staged preview shown above the input bar:

1. **Hollow link**: `StagedHollowLinkCard` shown when `_stagedHollowLink != null`. For `hollow://` protocol links.
2. **Web link**: `StagedLinkPreviewCard` shown when `_stagedPreviewUrl != null` (and no hollow link). Shows fetched OG metadata or loading state.

**URL detection (`_detectUrl()`)**: Called after 600ms debounce from `_onTextChanged()`. Uses `_urlRegex` to find first URL in input. If URL matches `hollow://`, parses via `extractHollowLinks()` and stages as `_stagedHollowLink`. Otherwise, sets `_stagedPreviewLoading = true` and calls `_fetchPreview(url)`.

**`_fetchPreview(url)`**: Calls `network_api.fetchLinkPreview(url: url)`. On success, stores `_stagedPreview`. On failure, clears all staged preview state. Checks `mounted` and that `_stagedPreviewUrl` hasn't changed (stale-response guard).

## Unread Pill

`_UnreadPill`: Floating pill shown when `unreadCount > 0` AND `_showScrollPill` (user scrolled away from bottom). Shows "N new messages" text with arrow-down icon. Tapping scrolls to bottom and marks channel as read.

The unread count comes from `unreadProvider.channelUnreadCounts['serverId:channelId']`.

## Input Bar

Hidden entirely when `canPostInChannelProvider` returns false (replaced with "no permission" message).

When visible, surface background with top border (border suppressed when reply/staged file/link preview is showing above). Contains a `Row`:

1. **File attachment button** -- paperclip icon. Taps `_pickAndStageFile()` which opens `FilePicker.platform.pickFiles()`.
2. **Voice record button** -- mic icon. Disabled (dimmed) when a file is staged. Taps set `_isRecordingVoice = true`, which replaces the entire input row with `VoiceRecorderBar`.
3. **Text input** -- `CompositedTransformTarget` (for @mention overlay positioning) wrapping `Focus` (for keyboard interception) wrapping `HollowTextField`. Hint: "Message #channelName". Autofocus, max 5 lines, min 1 line, max 4000 characters, no counter. Border radius `hollow.radiusLg`. `onChanged` calls `_onTextChanged()`.
4. **Send button** -- accent background, send icon. Taps `_handleSend()`.

**Voice recording mode**: When `_isRecordingVoice` is true, the row is replaced with `VoiceRecorderBar(onFinished: _stageVoiceMessage, onCancelled: ...)`. The cancel callback sets `_isRecordingVoice = false`.

## Keyboard Input Handling

The `Focus` widget wrapping the text field has an `onKeyEvent` handler with two phases:

1. **@mention overlay active**: Intercepts ArrowDown/ArrowUp/Enter/Tab/Escape for mention navigation (see @Mention section).
2. **Default**: Falls through to `handleChatInputKey()` (from `chat_input_shortcuts.dart`) which handles Enter-to-send, Shift+Enter for newline, and Ctrl+V image paste (calls `_stageClipboardImage`).

## Sending Messages

**`_handleSend()`**: (1) Dismisses @mention overlay. (2) If file is staged, delegates to `_sendStagedFile()` and returns. (3) Trims text; if empty, returns. (4) Clears controller, resets typing state, requests focus. (5) Captures reply ID and staged preview. (6) Clears all staged state. (7) Calls `channelChatProvider.notifier.sendMessage(serverId, channelId, text, replyToMid, linkPreview)`. (8) Scrolls to bottom.

**`_sendStagedFile()`**: Reads staged file path/name, clears staged state + input. Adds optimistic file message via `channelChatProvider.notifier.addFileMessage()`. Jumps to bottom. Then calls `fileTransferProvider.notifier.sendFile()` with server/channel/file info and member count.

## Typing Indicators

`_onTextChanged(text)`: (1) Starts 600ms URL detection debounce. (2) Calls `_updateMentionAutocomplete(text)`. (3) If text empty, returns. (4) If invisible mode is on (`invisibleModeProvider`), skips typing indicator. (5) Throttles to 3-second intervals via `_lastTypingSent`. (6) Calls `network_api.sendTypingIndicator(serverId, channelId)`.

## File Download Logic

The `onDownload` callback in `MessageHoverWrapper` handles three scenarios:

1. **Video thumbnail (vault)**: If `fileAttachment.videoThumb != null`, calls `_vaultDownloadAndSaveVideo()` which triggers vault reconstruction via `crdt_api.vaultDownloadFile()`, polls `fileTransferProvider` for completion (up to 60s), then opens Save As dialog.
2. **File already on disk**: If `fileAttachment.diskPath != null`, calls `_saveFile()` which opens Save As dialog with appropriate extensions and optional WebP conversion for images.
3. **File not on disk**: Checks member count. For 6+ members, calls `_vaultDownloadAndSave()` (vault shard reconstruction). For <6 members, calls `_requestFileFromPeer()` (P2P stream request via `network_api.requestFileFromPeer()`).

**`_saveFile(attachment)`**: Opens `FilePicker.platform.saveFile()`. If saving WebP image as non-WebP, converts via `network_api.convertImageFormat()`. Records save in `downloadManagerStateProvider`. Shows toast on success/failure.

**`_vaultDownloadAndSave(attachment)`**: Looks up content ID via `storage_api.getContentIdForFile()`. Triggers vault download. If cache hit (immediate return), opens Save As. Otherwise polls `fileTransferProvider` every 500ms for up to 60 seconds waiting for `VaultDownloadComplete` event.

## File Dropping and Clipboard Paste

**ChatDropZone**: Wraps the entire pane. `onFileDropped` callback calls `_handleDroppedFile(path, name, sizeBytes)` which determines if the file is an image by extension and stages it.

**Clipboard image paste**: `_stageClipboardImage(path, name)` called from `handleChatInputKey()` when Ctrl+V contains an image. Sets staged file state and focuses input.

## Voice Messages

`_stageVoiceMessage(VoiceRecordingResult)`: Called by `VoiceRecorderBar.onFinished`. Validates file exists and is under 34 MB limit. On success, stages as `.ogg` file and immediately calls `_sendStagedFile()`. On failure (too large), shows error toast and deletes the file.

## Providers Read by This Widget

| Provider | Usage |
|---|---|
| `channelChatProvider` | Message list keyed by `serverId:channelId` |
| `channelSearchOpenProvider` | Whether search bar is visible (StateProvider<bool>) |
| `profileProvider` | Profile map for display names and avatars |
| `serverNicknamesProvider(serverId)` | Server nickname map for display name resolution |
| `serverMembersProvider(serverId)` | Async member list (for @mention candidates, member count) |
| `identityProvider` | Local peer ID |
| `typingProvider` | Typing peer set keyed by `serverId:channelId` |
| `pinnedProvider` | Pinned message IDs keyed by `serverId:channelId` |
| `unreadProvider` | Unread counts per channel |
| `myPermissionsProvider(serverId)` | Local user's permission bitfield |
| `myRoleProvider(serverId)` | Local user's role string (owner/admin/moderator/member) |
| `canPostInChannelProvider((serverId, channelId))` | Combined post permission check |
| `peersProvider` | Connected peers map (for connection status) |
| `fileTransferProvider` | Active file transfer states |
| `downloadManagerStateProvider` | Download/save tracking |
| `splitViewProvider` | Split view state (for toggle button) |
| `layoutModeProvider` | Layout mode (dock vs classic, for split button visibility) |
| `memberPanelProvider` | Member panel visibility toggle |
| `serverSyncStatusProvider(serverId)` | Sync status enum |
| `syncProgressProvider` | Sync progress (received/total counts) |
| `vaultStatusProvider` | Vault upload/download activity |
| `chatAtBottomProvider` | Whether chat is scrolled to bottom (written by this widget) |
| `invisibleModeProvider` | Whether user is in invisible mode (suppresses typing indicators) |
| `channelListProvider` | Channel definitions (for posting mode) |

## Rust FFI Calls

- `network_api.sendTypingIndicator(serverId, channelId)` -- sends typing indicator to channel.
- `network_api.requestChannelSync(serverId, channelId)` -- requests sync retry for a channel.
- `network_api.fetchLinkPreview(url)` -- fetches OG metadata for link preview.
- `network_api.convertImageFormat(sourcePath, targetFormat)` -- converts WebP to other formats for save.
- `network_api.requestFileFromPeer(fileId, peerId, chunks)` -- P2P file request.
- `storage_api.searchChannelMessages(serverId, channelId, query, limit)` -- full-text search in SQLCipher.
- `storage_api.getContentIdForFile(fileId)` -- looks up vault content ID for a file.
- `crdt_api.vaultDownloadFile(serverId, contentId)` -- triggers vault shard reconstruction.
- `crdt_api.pinMessage(serverId, channelId, messageId)` -- pins a message via CRDT op.
- `crdt_api.unpinMessage(serverId, channelId, messageId)` -- unpins a message via CRDT op.

## External Widget Dependencies

- `ChannelMessageBubble` -- `lib/src/ui/chat/channel_message_bubble.dart`
- `ChatDropZone` -- `lib/src/ui/chat/chat_drop_zone.dart`
- `MessageHoverWrapper`, `MessageActionBarScope` -- `lib/src/ui/chat/message_action_bar.dart`
- `handleChatInputKey` -- `lib/src/ui/chat/chat_input_shortcuts.dart`
- `VoiceRecorderBar` -- `lib/src/ui/chat/voice_recorder_bar.dart`
- `StagedLinkPreviewCard` -- `lib/src/ui/chat/staged_link_preview_card.dart`
- `StagedHollowLinkCard` -- `lib/src/ui/chat/staged_hollow_link_card.dart`
- `extractHollowLinks`, `HollowLink` -- `lib/src/ui/chat/hollow_link_utils.dart`
- `ConnectionProgress`, `ConnectionStage` -- `lib/src/ui/components/connection_progress.dart`
- `GifFileImage` -- `lib/src/ui/components/animated_gif_image.dart`
- `showMessageProofDialog`, `MessageProofData` -- `lib/src/ui/dialogs/message_proof_dialog.dart`
- `DateSeparator`, `shouldShowDateSeparator`, `shouldGroup`, `TypingIndicatorBar`, `displayNameFor`, `serverDisplayNameFor`, `copyImageToClipboard` -- `lib/src/ui/chat/chat_pane.dart`
- `generateMessageId` -- `lib/src/core/providers/chat_provider.dart`
- `Permission` -- `lib/src/core/providers/server_provider.dart`
