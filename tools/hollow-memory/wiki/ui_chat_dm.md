# ChatPane -- DM Conversation View

Primary file: `lib/src/ui/chat/chat_pane.dart` (~4500 lines). The ChatPane is the main one-to-one direct message view. It handles the message list, input bar, file attachments, voice recording, inline call panel (audio/video/screen share), a DM profile panel, reply/quote flow, link previews, typing indicators, and unread tracking. Supporting files: `lib/src/ui/chat/chat_drop_zone.dart` (drag-and-drop file attachment wrapper), `lib/src/ui/chat/chat_input_shortcuts.dart` (keyboard shortcuts and clipboard image paste), and `lib/src/ui/chat/chat_pane_shared.dart` (see wiki ui_chat_pane_shared -- shared twins' building blocks, re-exported from this file).

**2026-07-15 S3776 decomposition:** every class in this file now follows the slim-build + section-builder shape (memory s3776-build-method-decomposition). `_ChatPaneState`: `build()` -> `_registerBuildListeners()` (chatProvider growth + windowFocused listeners as named methods) + `_buildHeader` (-> `_buildHeaderTitle`/`_buildConnectionStatus`/`_buildVoiceCallButton`/`_buildVideoCallButton`/`_buildProfileToggleButton`/`_buildMuteToggleButton`/`_buildSplitToggleButton`) + `DmCallRow` + the call stage or `_buildMessageArea` (2026-09-25). Row actions are nullable callback factories (`_editStartFor`/`_deleteFor`/`_replyFor`/`_downloadFor`/`_copyFor`/`_copyImageFor`/`_infoFor`; `_toggleReaction` shared by wrapper + bubble). The DM-call helpers that lived here moved to `lib/src/ui/call/` (wiki ui_call_surfaces).

## Top-Level Providers Defined in This File

- `dmProfilePanelProvider` -- `StateProvider<bool>`, defaults `true`. Controls visibility of the DM profile panel on the right. Toggled by the `circleUser` button, the last action in the chat header.

## Top-Level Helper Functions

`shouldGroup()`, `shouldShowDateSeparator()`, and the `DateSeparator` widget MOVED to `chat_pane_shared.dart` (2026-07-15) and are re-exported from this file -- see wiki ui_chat_pane_shared for their behavior. `TypingIndicatorBar`, `TypingIndicatorHost`, `TypingDots`, the unread pill (`UnreadJumpPill`) and its fading wrapper `UnreadJumpFade` live there too.

## ChatPane Widget

`ConsumerStatefulWidget`. Constructor params:
- `peerId` (required `String`) -- the Ed25519 peer ID of the DM partner.
- `splitPaneIndex` (optional `int?`) -- which split view pane this instance occupies (0 or 1). Used for split-view close logic.

### _ChatPaneState -- Instance Variables

| Variable | Type | Purpose |
|---|---|---|
| `_controller` | `TextEditingController` | Text input for compose box |
| `_itemScrollController` | `ItemScrollController` | Programmatic scroll for `ScrollablePositionedList` |
| `_itemPositionsListener` | `ItemPositionsListener` | Tracks visible item indices for scroll position detection |
| `_scrollOffsetController` | `ScrollOffsetController` | Smooth animated scrolling (pixel offset) |
| `_focusNode` | `FocusNode` | Focus management for the text input |
| `_historyLoaded` | `bool` | Guards `_loadHistory()` from running twice |
| `_isPicking` | `bool` | Mutex preventing concurrent file picker dialogs |
| `_editingMessageId` | `String?` | Message ID currently being edited inline |
| `_replyToMessageId` | `String?` | Message ID the user is replying to |
| `_replyToText` | `String?` | Preview text of the reply target |
| `_replyToSenderName` | `String?` | Display name of the reply target sender |
| `_replyToImagePath` | `String?` | Disk path to image thumbnail for reply preview |
| `_lastTypingSent` | `DateTime?` | Throttle: last time a typing indicator was sent (3s cooldown) |
| `_highlightIndex` | `int?` | Index of the message to flash-highlight (reply scroll target) |
| `_showScrollPill` | `bool` | Whether the unread pill / scroll-to-bottom should be visible |
| `_staged` | `List<StagedAttachment>` | Files staged for send (0 to `kMaxAlbumItems` = 10); two or more go out as one album |
| `_albums` | `AlbumCollapse<ChatMessage>` | Album grouping of the list last displayed, rebuilt by `_displayMessages` for the row builders |
| `_isRecordingVoice` | `bool` | True while VoiceRecorderBar is shown instead of text input |
| `_stagedPreviewUrl` | `String?` | URL currently being previewed in the compose area |
| `_stagedPreview` | `network_api.LinkPreviewRef?` | Fetched OG metadata for the staged URL |
| `_stagedPreviewLoading` | `bool` | True while the OG metadata fetch is in progress |
| `_stagedHollowLink` | `HollowLink?` | Parsed Hollow-protocol link (hollow:// URLs) |
| `_urlDebounce` | `Timer?` | 600ms debounce timer for URL detection in compose text |
| `_overlayHideTimer` | `Timer?` | 1-second auto-hide timer for screen-share overlay controls |
| `_overlaysVisible` | `bool` | Whether overlay controls are visible during screen share |
| `_chatOverlayPinned` | `bool` | User explicitly toggled the chat sidebar open during screen share |

Static: `_urlRegex` -- `RegExp(r'(?:https?|hollow)://[^\s<>"' "'" r')\]}]+')` matches http, https, and hollow:// URLs in compose text.

### initState

Calls `_loadHistory()` to fetch message history from the DB. Registers `_onScrollPositionChanged` as a listener on `_itemPositionsListener.itemPositions`.

### dispose

Cancels `_overlayHideTimer` and `_urlDebounce` timers. Removes the scroll position listener. Disposes `_controller` and `_focusNode`.

## Scroll Management

### _isNearBottom (getter)
Checks if the sentinel item (index >= messages.length - 1) is visible. Returns `true` when the user is at or near the bottom of the message list. Used to control unread pill visibility.

### _isInAutoScrollZone (getter)
More forgiving than `_isNearBottom`. Returns `true` if any of the last 3 messages are visible (index >= messages.length - 3). Used to decide whether to auto-scroll on new incoming messages. Outside this zone, the unread pill takes over instead.

### _onScrollPositionChanged()
Listener invoked whenever visible items change. Updates `_showScrollPill` (inverted from `_isNearBottom`). Writes to `chatAtBottomProvider` (shared `StateProvider<bool>` in `member_panel_provider.dart`). When `_isNearBottom` is true, marks the DM as read via `unreadProvider.notifier.markDmSeen()` — but ONLY on a bottom re-ENTRY transition.

### Focus-return mark-seen (2026-07-10)
A `ref.listen(windowFocusedProvider)` in `build()` (next to the auto-scroll listener; mirrored in `channel_chat_pane.dart`): on the unfocused→focused edge, if `_isNearBottom && _frozenLen == null`, marks the newest message seen. Closes the ghost-unread: a message arriving while the window is unfocused counts as unread (event_provider's `isViewingDm` gate requires focus) and neither the scroll handler (needs a re-entry) nor chat-open (already open) ever cleared it. Scrolled-up readers keep the pill (`_frozenLen` guard). Mobile needs no equivalent — its arrival listener calls `_scrollToBottom()` which marks seen at arrival.

### _jumpToBottom()
Post-frame callback. Calls `_itemScrollController.jumpTo(index: messages.length, alignment: 1.0)` to instantly jump to the sentinel item at the end. Used after history load and after sending a file.

### _scrollToBottom()
Delegates to `_jumpToBottom()`: releases the display freeze, then a post-frame `jumpTo(index: 0, alignment: 0.0)`. Instant, never animated (see Reverse list below). Used after sending and when auto-scroll triggers on new incoming messages.

### _scrollToMessage(int index)
Scroll to a CHRONOLOGICAL message index (reply-tap and search navigation; the reversed builder index is computed here). Sets `_highlightIndex = index` to trigger a visual flash. Scrolls 300ms with `HollowCurves.enter` at alignment 0.6 (reversed alignment measures from the BOTTOM edge, so the target lands upper-middle); under Reduce motion it `jumpTo`s the same index and alignment instead. After 1500ms, clears `_highlightIndex`.

## Message History Loading

### _loadHistory()
Guarded by `_historyLoaded` flag (prevents double-load). Calls `chatProvider.notifier.loadHistory(peerId)` to fetch messages from SQLCipher DB. After load, calls `_jumpToBottom()` to pin to latest message, then marks the DM as read via `unreadProvider.notifier.markDmSeen()`. The initial scroll index is set in the list builder (`initialScrollIndex: messages.length`), but `_jumpToBottom()` is needed because `ScrollablePositionedList` only honors `initialScrollIndex` at first build -- when `loadHistory` grows the list after initial build, an explicit jump is required.

## Auto-Scroll on New Messages

In `build()`, a `ref.listen` on `chatProvider` compares previous and next message counts for this peerId. If `nextLen > prevLen` (new message arrived) AND `_isInAutoScrollZone` is true, calls `_scrollToBottom()`. Otherwise the unread pill handles notification.

## Text Input and Typing Indicators

### _onTextChanged(String text)
Called on every keystroke in the compose field. Actions:
1. Cancels any existing URL debounce timer, starts a new 600ms timer calling `_detectUrl()`.
2. If text is empty, returns early.
3. If invisible mode is active (`invisibleModeProvider`), skips typing indicator.
4. Throttles typing indicator sends to once per 3 seconds (`_lastTypingSent`). Calls `network_api.sendTypingIndicator(serverId: '', channelId: peerId)` (empty serverId signals DM context).

## Link Preview Detection (Phase 6.75)

### _detectUrl()
Runs after the 600ms debounce. Extracts the first URL from compose text using `_urlRegex`. If the URL matches what's already staged, no-op. If no URL found, clears all staged preview state. If URL is a `hollow://` link, parses it via `extractHollowLinks()` and stages as `_stagedHollowLink` (no HTTP fetch needed). Otherwise sets `_stagedPreviewLoading = true` and calls `_fetchPreview(url)`.

### _fetchPreview(String url)
Async. Calls `network_api.fetchLinkPreview(url: url)` (Rust FFI). On success, sets `_stagedPreview` to the result. If the user changed the URL while fetching (checked via `_stagedPreviewUrl != url`), discards the result. On failure, silently clears all staged preview state.

## Sending Messages

### _handleSend()
Entry point for the send button and Enter key. Two paths:
1. If `_staged` is non-empty: clears the staged link preview (`FileHeaderPayload` has no link_preview slot), takes and clears `_staged`, and calls `_sendFiles(items)`.
2. Otherwise: trims text, returns if empty. Clears controller, resets `_lastTypingSent`, requests focus. Captures `_replyToMessageId` and `_stagedPreview` before clearing reply and preview state. Calls `chatProvider.notifier.sendMessage(peerId, text, replyToMid, linkPreview)`. Scrolls to bottom.

### _sendFiles(List<StagedAttachment> items)
Takes the composer's `expandedText()` as the caption, clears the controller, and runs the shared `sendStagedAttachments()` (`staged_attachments.dart`): an album id (`generateAlbumId()`) when there are 2+ items, EVERY optimistic row first via `chatProvider.notifier.addFileMessage(..., text:, albumId:)` so the bubble groups at once, then the `fileTransferProvider.notifier.sendFile(peerId, filePath, messageId, messageText, isVoice, album)` calls ONE AT A TIME so send stamps follow the strip order. The caption rides item 0. Failed items toast ("A file failed to send" / "N files failed to send"); the rest still go out. Voice notes and "Share pack to this chat" (`_shareFileToChat`) also send through here as a one-item list.

## File Staging

### _stageFiles(List<StagedAttachment> incoming)
The one staging entry (paste, drop, picker). `admitStagedAttachments(context, current: _staged, incoming:)` applies the 10-item album cap (toast for the overflow) and asks ONE `confirmLargeFilesShare` for every file over `kLargeFileThresholdBytes` in the batch (declined ones drop out); then `appendStaged` re-applies the cap against whatever `_staged` became while the question was open. Requests focus.

### _stageClipboardImage(String path, String name)
Called by the clipboard paste handler when an image is found; stages it via `_stageFiles`.

### _pickAndStageFile()
Opens `FilePicker.platform.pickFiles(allowMultiple: true)` and stages every picked file via `_stageFiles`. Guarded by `_isPicking` mutex (try/finally); re-focus is deferred a frame so the OS has returned window focus from the native dialog.

## Voice Recording

### _stageVoiceMessage(VoiceRecordingResult result)
Callback from `VoiceRecorderBar` when the user finishes recording. Checks that the `.ogg` file exists; over the large-file threshold it asks `confirmLargeFileShare` (declined = delete the temp file). Otherwise sends it at once via `_sendFiles([...])` named "Voice message.ogg" (the name sets `isVoice`) -- voice messages auto-send without a confirmation step. Sets `_isRecordingVoice = false`.

Voice recording is toggled by tapping the microphone button in the input bar. When `_isRecordingVoice` is true, the entire text input row is replaced by `VoiceRecorderBar`. The mic button is disabled when a file is already staged.

## File Save/Download

### _saveFile(FileAttachment attachment)
Opens a save-file dialog via `FilePicker.platform.saveFile()`. For images, offers png/jpg/jpeg/webp/gif extensions. For non-images, offers the original extension. If saving an image and the source is webp but the target is not, calls `network_api.convertImageFormat()` to convert via Rust. Otherwise does a direct `File.copy()`. Records the save via `downloadManagerStateProvider.notifier.recordSavedFile()`. Shows success/error toast.

### _requestFileFromPeer(FileAttachment attachment, String senderId)
For files not yet on disk (not downloaded). Shows "Requesting file from peer..." toast, then calls `network_api.requestFileFromPeer(fileId, peerId, chunks: [])`.

## Build Method -- Overall Layout

The `build()` method reads:
- `chatProvider` -- message list keyed by peerId
- `typingProvider` -- set of peers currently typing in this DM
- `dmProfilePanelProvider` -- whether profile panel is visible
- `callProvider` -- current call state

Top-level structure is a `Row`:
1. `Expanded` containing `ChatDropZone` wrapping a `Column`
2. RIGHT (since 2026-09-24): `_DmProfilePanelSlider` (instant show/hide, shown unless screen share is active) holding `DmProfilePanel`

The Column's children: header, `DmCallRow`, search bar, banners, then either the call's stage (`watchDmStageShown`) or `_buildMessageArea()`. With the stage up the right slot is the stage panel (Chat or Profile) instead of `_DmProfilePanelSlider`. What follows is the pre-2026-09-25 shape, kept for history only:

**If screen share active** (`isScreenShareActive`): Shows a `MouseRegion` + `Stack` with:
- Layer 0: `_ScreenShareFullView` (full-bleed background)
- Layer 0.5: Source switcher pill (top-center, `AnimatedOpacity`, only if 2+ sources)
- Layer 1: Chat overlay slider (right side) -- toggle button + `_ChatOverlaySlider` with 360px chat panel
- Layer 2: `_ScreenShareControlsOverlay` floating pill (bottom center, `AnimatedOpacity`). When the REMOTE side is sharing (`call.remoteScreenSharing`), the pill includes a `ShareVolumeButton` (`ui/components/share_volume_control.dart`) between the share toggle and end-call — popover with the received-share-audio volume slider (0–200%, `shareAudioVolumeProvider`) and the voice-activity duck toggle (`shareAudioDuckProvider`), applied via the `ShareAudioLevel` bus.

**If no screen share**: Standard column layout with:
- `_InlineCallPanelSlider` (appears instantly when in call with this peer)
- `..._buildMessageArea()` -- message list, then the composer cluster (reply bar, staged strip, link area, input bar) under a `TypingIndicatorHost`

## Chat Header Bar

The shared `ChatHeaderBar` (`chat_pane_shared.dart`, 48 px, `surface`, bottom hairline), the same bar the channel pane uses:

1. **Leading:** `PresenceAvatar(size 28, online: identityIsOnline)` (Saved messages: `SavedMessagesAvatar`).
2. **Title** `subheading`: the local nickname if set, else the profile name; **subline**: the real name when a nickname is set, else the person's status line.
3. **No status while healthy.** The old `ConnectionProgress` ("Encrypted") is gone from the DM header; presence is the avatar's dot and verification lives in the panel.
4. **Actions** (`HollowIconButton`, 32 px, 4 apart): voice call (green `phoneCall` while in a call with them), video call, search (selected while open), split view (dock mode), then the profile panel toggle LAST, next to the panel it opens (`circleUser`, "Show profile" / "Hide profile", selected = grey fill, never accent). Mute moved into the panel.

## _buildMessageArea() -- Message List, Typing, Reply, Input

Returns a `List<Widget>` used by both the normal layout and the screen-share overlay chat panel: the message list, then ONE `TypingIndicatorHost(names: _typingNames(typingPeers))` whose child is a `Column` of the reply preview bar, the staged attachment strip, `StagedLinkArea` and `_buildInputBar`.

### Message List

`Expanded` containing a `Stack` of `_buildMessageListLayer` + `_buildUnreadPillOverlay`.

**_buildMessageListLayer** -- `MessageActionBarScope` (no scroll dismissal since 2026-09-24: the bar follows its row). Contains either:
- Empty: `_buildConversationStart()`: nothing until the first read returns (`_historyStarted` / `_historyLoaded` / `_historyFailed`; `chatProvider.loadHistory` returns false on a failed read), "These messages didn't load" + Try again on failure, "Nothing saved yet" for Saved messages, else "This is the start of your conversation with {name}". The old version set its loaded flag BEFORE the await and flashed "No messages yet".
- `_buildMessageList`: renders `_displayMessages(messages)` (the frozen prefix while scrolled up, every album folded into its earliest item via `collapseDmAlbums`, see `album_grouping.dart`); precomputes `replyIndexById` (one pass per build, every album item also mapped to its anchor row's index; `_jumpToMessageId` maps through `_albums.anchorIdByItemId` the same way) and the unread divider (entry seen id mapped to its album row via `_albumRowId`), then calls the shared `reversedChatList()` shell (see wiki ui_chat_pane_shared) with `listKey: ValueKey('dm-list-${peerId}')`, the instance scroll controllers, and `itemBuilder: _buildMessageRow`. The shell owns `reverse: true`, index-0-bottom pinning, and `findChildIndexCallback` keyed-row reuse.

**_buildMessageRow(context, revIndex, messages, replyIndexById, profiles, localPeerId)** -- maps the reversed index back to chronological, determines `showHeader` via `shouldGroup()`, and builds a `MessageHoverWrapper` whose action callbacks come from nullable factories (null hides the affordance; tap-time reads use `ref.read` for freshness):

> Since issue #61 `MessageHoverWrapper` also owns the message CONTEXT MENU: right-click builds a `showHollowMenu` from these same callbacks (quick reaction strip, Add reaction, Reply, Copy text, Copy image, Download, Pin/Unpin, Edit, Delete, Message proof, Copy message ID). Because it is built from props the wrapper already holds, all SEVEN surfaces that use it got the menu with no call-site changes: DM chat, channel chat, guest chat and the four archive viewers. A row can never offer an action the surface did not wire up. `isPinned` (passed by `channel_chat_pane`) only changes the wording between Pin and Unpin.
  - `_editStartFor(msg, revIndex)`: Only own text messages (no file attachment). Captures the item's current `itemLeadingEdge` from `_itemPositionsListener`, sets `_editingMessageId`, then in a post-frame callback uses `_itemScrollController.jumpTo()` at the same alignment to preserve scroll position
  - `onEditSubmit` (inline): Clears edit state, calls `chatProvider.notifier.editMessage()`; `onEditCancel` clears edit state
  - `_deleteFor(msg)`: Only own messages. Calls `chatProvider.notifier.deleteMessage()`; on an album row it first asks `confirmDeleteAlbum(context, n)` and then deletes every item (the viewer deletes one item at a time)
  - `_replyFor(msg)`: Sets `_replyToMessageId`, `_replyToText` via `_messagePreviewText()` (an album row previews via `albumPreviewText(attachments, caption: albumCaption(texts))`, anything else via `messagePreviewText()`, `lib/src/core/message_preview.dart`: a photo/video/voice-note/unknown attachment previews as "Photo"/"Video"/"Voice message"/its file name, an emote token as `:name:`, never an emoji glyph), `_replyToSenderName`, `_replyToImagePath`. Requests focus on input
  - `onReaction` / bubble `onToggleReaction`: both delegate to `_toggleReaction(msg, emoji)` -- checks if local peer already reacted, calls `addReaction()` or `removeReaction()`
  - Album rows (`_albums.itemsFor(msg.messageId) != null`) pass null for `onDownload`, `fileAttachment` and `onCopyImage`: those would act on the first item only; the album bubble's "Download all (N)" chip and the viewer cover them
  - `_downloadFor(context, msg)`: If file has `diskPath`, opens save dialog via `_saveFile()` (split into `_saveDialogFileName` + `_writeSavedFile`). Otherwise requests from peer via `_requestFileFromPeer()`. Guards against duplicate downloads by checking `fileTransferProvider`
  - `_copyFor(context, msg)`: Copies message text to clipboard (excludes `[file:` messages)
  - `_copyImageFor(context, msg)`: For image attachments with disk path, calls `copyImageToClipboard()`; guards the itemBuilder's own context
  - `_infoFor(context, msg)`: Opens `MessageProofDialog` with signature verification data

The wrapper's child is `_buildBubble(...)`: resolves reply preview via `replyIndexById` + `_messagePreviewText` (a reply to an album item reads that item via `_albumItemById`), then returns `MessageBubble` with `album: dmAlbumItems(...)` for an album anchor and `onReplyTap: _scrollToMessage(replyIndex)`. The row returns through the shared `dateSeparatedChatRow()` (keyed subtree, optional DateSeparator, group-header padding).

**_buildUnreadPillOverlay** -- reads `unreadProvider.dmUnreadCounts[peerId]`. Always mounted: a bottom-center `UnreadJumpFade(count: _showScrollPill ? unreadCount : 0)`, which fades the `UnreadJumpPill` in and out; tapping calls `_scrollToBottom()` and `markDmSeen()` against the TRUE newest message.

### Typing Indicator

`_typingNames(typingPeers)` resolves names via `displayNameForPeer()` per-pid profile selects and feeds the shared `TypingIndicatorHost` around the composer cluster (see wiki ui_chat_pane_shared). The label floats on the seam above the composer and reserves no space.

### Reply Preview Bar

Shown when `_replyToMessageId != null` -- the shared `ChatReplyPreviewBar`: a grey reply icon, one line of "Replying to **name**  snippet", an optional 24 px gif-aware thumb, and a `HollowIconButton` cancel (28, 44 on touch). No accent strip since 2026-09-24.

### Staged Attachments

Shown when `_staged` is non-empty -- the shared `StagedAttachmentStrip` (`staged_attachments.dart`): one row for a single file, a reorderable thumbnail strip for an album; remove X drops that index, reorder goes through `reorderStaged`.

### Staged Link Preview

The shared `StagedLinkArea` widget: `StagedHollowLinkCard` for `hollow://` links, else `StagedLinkPreviewCard` for http/https while `_stagedPreviewUrl != null`, else nothing. Dismiss callbacks `_dismissStagedHollowLink()` / `_dismissStagedPreview()` cancel `_urlDebounce` and clear the staged state.

### Input Bar

`_buildInputBar` -> shared `chatInputBarShell(hollow, flushTop: reply/staged/preview visible, child: ...)`. When `_isRecordingVoice`: `VoiceRecorderBar` (discard is a grey `HollowIconButton` at composer height, not red at rest); otherwise `_buildComposerRow` = the shared `ChatComposerRow` (`chat_pane_shared.dart`, all controls 44 tall, 8 apart):

1. **`+`** attach (`_pickAndStageFile`).
2. **The field** (`chatComposerField`, `quietFocus`: the composer always holds focus, so its border stays the hairline; hint "Message {name}", "Note to self" for Saved messages) with ONE smiley inside it that opens `showExpressionPicker` (`_openExpressions`): emoji inserts via `_insertEmojiAtCursor`, GIFs and stickers send via `_sendAsset`.
3. **Mic / Send:** the mic while nothing is typed or staged; once there is, the accent Send (the row's only accent). Keys go through the emote autocomplete then `handleChatInputKey`.

## Providers Read by ChatPane

| Provider | Purpose |
|---|---|
| `chatProvider` | Message list per peer. Watched for rendering + listened for auto-scroll |
| `typingProvider` | Typing indicator set per peer |
| `dmProfilePanelProvider` | Profile panel visibility |
| `callProvider` | Call state (status, video, screen share, mute) |
| `profileProvider` | Display names, avatars, banners for all peers. Hoisted to `build()` level — NOT inside `itemBuilder` (avoids cascade rebuilds) |
| `identityProvider` | Local peer ID. Hoisted to `build()` level — NOT inside `itemBuilder` |
| `peersProvider` | Online peer map (for status dot and button enable logic) |
| `invisiblePeersProvider` | Set of peers whose invisible status we know about |
| `invisibleModeProvider` | Whether local user is in invisible mode (suppresses typing) |
| `fileTransferProvider` | File transfer state (guards duplicate downloads) |
| `unreadProvider` | Unread DM counts |
| `notificationSettingsProvider` | Per-DM notification mute state |
| `layoutModeProvider` | Dock vs Classic mode (controls split view button visibility) |
| `splitViewProvider` | Split view state (isSplit, pane management) |
| `chatAtBottomProvider` | Shared state written by scroll listener, read by event_provider |
| `focusedDmSourceProvider` | Which video source is focused in screen share view |
| `localNicknameProvider` | Local nicknames for the profile panel |
| `friendsProvider` | Friend status for the profile panel |
| `downloadManagerStateProvider` | Records saved files for download history |

## ChatDropZone Widget

File: `lib/src/ui/chat/chat_drop_zone.dart`. `StatefulWidget` wrapping any child in a `DropTarget` (from `desktop_drop` package). State tracks `_dragging` bool.

**Drag overlay**: When dragging over, displays a full-overlay with `hollow.background` at 0.85 alpha. Centered card with accent border (2px), accent glow shadow (0.3 alpha, blur 24, spread 4), `LucideIcons.upload` icon (size 48), and "Drop files to attach" text.

**Drop handling** (`_handleDrop`): Builds a `StagedAttachment.fromPath` for EVERY dropped path that exists as a file (a dropped folder is skipped) and hands the list to `onFilesDropped(List<StagedAttachment>)`. The callback (each pane's `_stageFiles`) owns the album cap, the large-file question and the media-only filter.

**Events**: `onDragEntered` sets `_dragging = true`, `onDragExited` sets `_dragging = false`, `onDragDone` calls `_handleDrop`.

## ChatInputShortcuts

File: `lib/src/ui/chat/chat_input_shortcuts.dart`. Contains the `handleChatInputKey()` function and supporting utilities.

### handleChatInputKey()
Takes `KeyEvent`, `TextEditingController`, `FocusNode`, `onSend` callback, and optional `onPasteImage` callback. Handles only `KeyDownEvent` and `KeyRepeatEvent`.

| Shortcut | Action |
|---|---|
| Enter | Calls `onSend()` (send message) |
| Shift+Enter | Inserts newline at cursor position |
| Ctrl+V | Calls `_tryPasteImage()` then falls through to default paste (returns `ignored` so text paste still works) |
| Ctrl+B | Wraps selection in `**bold**` |
| Ctrl+I | Wraps selection in `*italic*` |
| Ctrl+E | Wraps selection in `` `code` `` |
| Ctrl+Shift+X | Wraps selection in `~~strikethrough~~` |
| Ctrl+Shift+S | Wraps selection in `\|\|spoiler\|\|` |

### _tryPasteImage()
Async. Reads system clipboard via `super_clipboard` package. Checks for image formats in priority order: PNG, JPEG, GIF, BMP, WebP. If found, reads bytes, saves to a temp file as `clipboard_{timestamp}.{ext}`, and calls `onPasteImage(path, name)`.

### copyImageToClipboard()
Async. Reads image bytes from disk, determines format from extension, writes to system clipboard via `DataWriterItem`. Returns `true` on success. Used by the "Copy Image" action in message context menus.

### _wrapSelection()
Takes controller, before string, and after string. If no text is selected, inserts `before + after` and places cursor between them. If text is selected, wraps the selection with the markers and preserves the selection within.

## The call in a DM (rebuilt 2026-09-25)

The call UI no longer lives in this file: see wiki `ui_call_surfaces`. Under the header sits `DmCallRow` (ringing out = "Calling X" + Cancel; in the call = both of you as compact tiles, "Voice call" + timer or "Weak connection", an inline share offer with Watch, camera / share / "Open the call" | mute / deafen | Leave). When `watchDmStageShown` is true the message list is replaced by `CallStage(source: DmCallStageSource(peerId))`, the header gets `_InCallMark` ("In a call" + timer) and two panel toggles (Chat, Profile) that swap the ONE right panel: `_StageChatPanel` (320 px, `surface`, the same `_buildMessageArea`) or `DmProfilePanel`. The header's call buttons hide during a call with this person and start through `startDmCallFlow`. Deleted: `_InlineCallPanel*`, `_ScreenShareFullView` (and its camera-promoting `_resolveBig`), `_ScreenShareControlsOverlay`, `_ChatOverlaySlider`, the source pill and helpers, the resizable video area, `components/active_call_bar.dart`, `components/call_video_view.dart`, `ChatOverlayToggleButton`.

## _DmProfilePanelSlider

`StatelessWidget`: `DmProfilePanel` when `visible`, else `SizedBox.shrink()`. Instant, like every side panel (design language 3.8).

## DmProfilePanel (2026-09-24)

**File:** `lib/src/ui/chat/dm_profile_panel.dart`. The person you are talking to, on the RIGHT, built and sized like a server's member panel: it uses `memberPanelWidthProvider` (default 280 since 2026-09-24, was 240) and a `PanelResizeHandle` seam on its left edge.

- **Banner** at 2.5:1 of the panel width: their banner (animated via `watchAnimatedBanner`, else `bannerProvider`), else a FLAT tone of their avatar colour (no gradient).
- **Avatar** in a 4 px `surface` ring overlapping the banner, left-aligned on the text edge, `StatusDot` corner. It scales with the banner: `_avatarSizeFor(width)` = `width * 0.26` clamped 48 to 88 (72 at the default 280), so a narrow panel never pushes it into the icon strip.
- **Icon strip** (`_Actions`, three 32 px buttons) under the banner's right edge while it fits beside the avatar (`actionsBeside`: avatar + ring + gaps + `_kActionsWidth` within the width); otherwise it moves UNDER the name block, left-aligned so its first glyph lines up with the name. Buttons: Set/Edit nickname, Mute notifications (selected when muted), More (Copy user ID; Remove friend with a confirm, through `removeFriendAndTidy` shared with the friends bar; then Block/Unblock and Report in the error tint). Hidden for Saved messages.
- **Names:** nickname or profile name in `heading`, the profile name as a caption when a nickname is set, the status line in `bodySmall`, the verified Twitch badge.
- **Sections** (`HollowSectionHeader` dense, 24 apart): About Me, Now Playing (the showcase board's `nowPlaying` block via `ShowcaseGameRow`), Encryption ("Not verified yet" / "Verified" over "End-to-end encrypted", with compact outline Verify or ghost View; `_Verification` stacks the button under its text when the row's content width is below `_kVerificationStackWidth` = 220). The raw peer id is no longer shown.
- **Footer:** ghost "View full profile" -> `showProfileDialog`.

## TypingIndicatorBar, TypingIndicatorHost, TypingDots

Shared, in `chat_pane_shared.dart`; see wiki ui_chat_pane_shared.

## Split View Integration

`ChatPane` supports being rendered in either pane of a split view via the `splitPaneIndex` parameter. The split view button in the header (dock mode only) calls `_handleSplitToggle()`:
- If already split: closes this pane via `splitViewProvider.notifier.closePane(splitPaneIndex ?? 0)`
- If not split: opens split via `splitViewProvider.notifier.openSplit()`

The `ScrollablePositionedList` uses a `ValueKey('dm-list-${peerId}')` so each pane gets its own independent scroll state even when both show the same DM.

## Mobile Call UI

**Files:** `lib/src/ui/mobile/mobile_call_video_view.dart`, `lib/src/ui/mobile/mobile_active_call_pill.dart`, `lib/src/ui/mobile/mobile_incoming_call.dart`

### MobileCallScreen

Full-screen call overlay pushed as a route with slide-up transition from `MobileChatRoute`. Handles all call states (ringing → connecting → active → idle). Auto-pops via `ref.listen` when call ends.

- **Audio mode:** Clustered avatar layout (`_ClusteredAvatars`) — 2: side-by-side, 3: triangle, 4: 2x2, 5: 2-1-2. Each avatar has animated teal rounded-square glow (`_SpeakingAvatar`) driven by `CallState.isLocalSpeaking`/`isRemoteSpeaking` (300ms ease-out animation). Mute badge overlay on muted avatars.
- **Video mode:** Remote camera full-screen, local PiP corner (90x120 portrait, draggable). If remote camera off, shows local camera full-screen. Uses `_hasRealVideo()` which checks `renderer.srcObject != null` in addition to `remoteVideoEnabled` to prevent black rectangles from stale transceivers.
- **Top bar:** Chevron-down to dismiss, peer name + status text ("Calling...", "Connecting...", "MM:SS", "Ended").
- **Controls bar:** Four circular buttons — volume (opens bottom sheet with 0-200% slider, icon changes with level), mute (red highlight), camera (accent highlight), hangup (red circle). Volume slider wired to `callProvider.notifier.setRemoteVolume()`. Disabled gracefully during ringing via `AnimatedOpacity`.
- **Status text:** Uses accent color for non-active states, secondary for duration.

### MobileCallStatusStrip

Thin green bar in `MobileChatRoute` (below header): "In call with X — Tap to return". Tapping pushes `MobileCallScreen` with slide-up. Hidden for incoming ringing calls (incoming overlay handles those). Shows for outgoing ringing, connecting, and active.

### MobileActiveCallPill

Floating draggable pill in `MobileShell` Stack. Shows during active/connecting calls. Positioned at `bottom: 80` (above nav bar). Mute, camera, hangup buttons + duration timer. Wrapped in `Material(color: transparent)` to prevent yellow underlines.

### IncomingCallOverlay (desktop widget reused; rewritten 2026-09-25 as the 340 px card, see wiki ui_call_surfaces)

The desktop `IncomingCallOverlay` (`lib/src/ui/dialogs/incoming_call_dialog.dart`) is reused on mobile. Placed in `MaterialApp.builder` in `app.dart` (above Navigator, so it renders over all pushed routes). Uses `MediaQuery.padding.top` for safe area positioning. Wrapped in `Material(color: transparent)` for yellow underline fix.

### DM Header Call Buttons

`_DmCallButtons` in `mobile_chat_route.dart` — phone + video icons next to the mute button. Gated on `isOnline && !isInCall`. Tapping starts call AND pushes `MobileCallScreen`. If call is already active with this peer, tapping the green phone icon opens the call screen.

### VAD (Voice Activity Detection)

`VoiceService` polls WebRTC stats every 200ms via `_vadTimer`. Local audio: checks `media-source` stats first (Android exposes `audioLevel` here), falls back to `outbound-rtp` (desktop). Remote audio: `inbound-rtp`. Speech threshold: `audioLevel > 0.01` or `totalAudioEnergy` delta > 0.0001. `CallNotifier` wires `onSpeakingChanged` callback on connect, updates `isLocalSpeaking`/`isRemoteSpeaking` in state.

## Reversed message list (2026-07-03 overhaul)

The DM list is `ScrollablePositionedList` with `reverse: true`: the NEWEST message is builder index 0, pinned to the bottom. No sentinel row; `initialScrollIndex: 0, initialAlignment: 0.0`. The builder maps `chronoIndex = messages.length - 1 - revIndex` and all row logic (grouping via shouldGroup, DateSeparator, highlight, replyIndexById) stays chronological; positions/jumpTo/scrollTo are in REVERSED space (converted at the boundary; reversed alignment measures from the bottom edge).

- At-bottom = `positions.any((p) => p.index <= 0)` (length-independent). `_onScrollPositionChanged` is edge-triggered: reaching bottom releases the freeze + marks seen; leaving freezes.
- **Freeze-while-reading:** `_frozenLen` caps `_displayMessages()` while scrolled up so arrivals never shift the reading position; the unread pill takes over (its onTap marks seen against `allMessages.last`, the TRUE newest). Release on bottom-reach/pill/send.
- **All list maintenance is instant post-frame `jumpTo(0, 0)`** (`_jumpToBottom`; `_scrollToBottom` delegates) — the old animated 150ms receive scroll caused the jump-then-glide artifact. Only reply-tap/search navigation keeps a short animated scrollTo.
- Growth listener (`ref.listen(chatProvider)`): growth while frozen → no-op (held back); not at bottom → freeze at prevLen; else jump to 0.
- **Element reuse (2026-07-03 blink fix):** `scrollable_positioned_list` is VENDORED at `packages/scrollable_positioned_list/` (0.3.8 + HOLLOW patch adding `findChildIndexCallback`). Every arrival shifts all revIndexes by one; rows are `KeyedSubtree(ValueKey(messageId))`, so without key-based slot matching every visible row REMOUNTED per message (whole-list blink: avatars/names/bubbles). The list now passes `findChildIndexCallback` mapping messageId (via `replyIndexById`) → `len-1-i`, so elements MOVE across slots. Any new chat list with keyed rows must pass the callback. Package patch details + constraints (duplicate-messageId keys now throw, null-messageId rows fall back to slot matching): memory `feedback_reverse_chat_lists`. Guard test: `test/widget/chat_list_element_reuse_test.dart`.

## Scrollbar rail (issue #54, 2026-08-21)

The list is built by `reversedChatList`, which since 2026-08-21 hangs `ChatScrollRail` in a column beside it on desktop (index scrollbar + a jump cap at each end). The pane's only job is to pass `onJumpToNewest: _scrollToBottom` — "jump to present" MUST go through the pane, because the display list is frozen while reading (`_frozenLen`) and index 0 is not the newest message until that freeze is released. Mechanics and the traps (reversed index maths, the window-edge dead strip, why it is a column and not an overlay) live in `wiki/ui_chat_pane_shared.md`.

## Message search and the unread line (issue #54, 2026-08-21)

**Search.** `search_dm_messages` had been in Rust and through FRB the whole time with NO caller, and the global quick-search shortcut flipped a CHANNEL-only flag, so Ctrl+K in a DM was a silent no-op. The flag is `chatSearchOpenProvider` now (one flag for both panes; each resets it in a post-frame callback on mount, never in `dispose`, where Riverpod forbids `ref`). The header carries `_buildSearchToggleButton` and the pane inserts `_buildSearchBar` directly under the header when it is open: a `HollowTextField` plus up to 20 tappable results capped at 200px, the same shape `ChannelChatPane` uses. A DM has exactly two sides, so the result's sender is a bool -- no device to master resolution, unlike a channel's list. `_jumpToSearchResult` indexes against the DISPLAY (possibly frozen) list, which is what `_scrollToMessage` takes.

**The unread line.** The pane reads `unreadMarkerProvider[dmMarkerKey(peerId)]` once per build, feeds `unreadDividerIndex` the display list, and hands the chronological index to `dateSeparatedChatRow(unreadDivider:)` and its REVERSED twin to `reversedChatList(unreadRevIndex:)`. One computation per build on purpose: the index the rail marks and the index the row draws cannot disagree. Placement, rendering and the rail mark live in `wiki/ui_chat_pane_shared.md`; the pointer itself in `wiki/providers_event_settings.md`.
