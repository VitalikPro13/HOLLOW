# ChatPane -- DM Conversation View

Primary file: `lib/src/ui/chat/chat_pane.dart` (~4500 lines). The ChatPane is the main one-to-one direct message view. It handles the message list, input bar, file attachments, voice recording, inline call panel (audio/video/screen share), a DM profile panel, reply/quote flow, link previews, typing indicators, and unread tracking. Supporting files: `lib/src/ui/chat/chat_drop_zone.dart` (drag-and-drop file attachment wrapper), `lib/src/ui/chat/chat_input_shortcuts.dart` (keyboard shortcuts and clipboard image paste), and `lib/src/ui/chat/chat_pane_shared.dart` (see wiki ui_chat_pane_shared -- shared twins' building blocks, re-exported from this file).

**2026-07-15 S3776 decomposition:** every class in this file now follows the slim-build + section-builder shape (memory s3776-build-method-decomposition). `_ChatPaneState`: `build()` -> `_registerBuildListeners()` (chatProvider growth + windowFocused listeners as named methods) + `_buildHeader` (-> `_buildHeaderTitle`/`_buildConnectionStatus`/`_buildVoiceCallButton`/`_buildVideoCallButton`/`_buildProfileToggleButton`/`_buildMuteToggleButton`/`_buildSplitToggleButton`) + `_buildScreenShareLayout` (-> `_buildSourcePillOverlay`/`_buildChatOverlay`/`_buildControlsPillOverlay`) or `_InlineCallPanelSlider` + `_buildMessageArea`. Row actions are nullable callback factories (`_editStartFor`/`_deleteFor`/`_replyFor`/`_downloadFor`/`_copyFor`/`_copyImageFor`/`_infoFor`; `_toggleReaction` shared by wrapper + bubble). Top-level shared DM-call helpers in this file: `_countActiveDmSources`, `_dmActiveSources`, `_dmSourcePill` (pill shell used by the full-bleed pill AND the inline panel switcher), `_shareLabelChip`, `_toggleScreenShare`, `_muteCallButton`/`_cameraCallButton`/`_screenShareCallButton`/`_endCallButton` (used by `_InlineCallPanel` and `_ScreenShareControlsOverlay`).

## Top-Level Providers Defined in This File

- `dmProfilePanelProvider` -- `StateProvider<bool>`, defaults `true`. Controls visibility of the left-side DM profile panel. Toggled by the user icon button in the chat header.

## Top-Level Helper Functions

`shouldGroup()`, `shouldShowDateSeparator()`, and the `DateSeparator` widget MOVED to `chat_pane_shared.dart` (2026-07-15) and are re-exported from this file -- see wiki ui_chat_pane_shared for their behavior. `TypingIndicatorBar`, `TypingDots`, and the unread pill (`UnreadJumpPill`, was private `_UnreadPill`) moved there too.

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
| `_stagedFilePath` | `String?` | Path of staged file attachment awaiting send |
| `_stagedFileName` | `String?` | Display name of staged file |
| `_stagedFileIsImage` | `bool` | Whether the staged file is an image format |
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
Post-frame callback. Calls `_scrollOffsetController.animateScroll(offset: 100000, duration: 150ms, curve: easeOut)` for a smooth animated scroll to the bottom. Used after sending a text message and when auto-scroll triggers on new incoming messages.

### _scrollToMessage(int index)
Animated scroll to a specific message index (used for reply-tap navigation). Sets `_highlightIndex = index` to trigger a visual flash. Scrolls with 300ms duration, easeOutCubic curve, alignment 0.3 (message appears ~30% from top). After 1500ms, clears `_highlightIndex` to remove the highlight.

## Message History Loading

### _loadHistory()
Guarded by `_historyLoaded` flag (prevents double-load). Calls `chatProvider.notifier.loadHistory(peerId)` to fetch messages from SQLCipher DB. After load, calls `_jumpToBottom()` to pin to latest message, then marks the DM as read via `unreadProvider.notifier.markDmSeen()`. The initial scroll index is set in the list builder (`initialScrollIndex: messages.length`), but `_jumpToBottom()` is needed because `ScrollablePositionedList` only honors `initialScrollIndex` at first build -- when `loadHistory` grows the list after initial build, an explicit jump is required.

## Auto-Scroll on New Messages

In `build()`, a `ref.listen` on `chatProvider` compares previous and next message counts for this peerId. If `nextLen > prevLen` (new message arrived) AND `_isInAutoScrollZone` is true, calls `_scrollToBottom()`. Otherwise the unread pill handles notification.

## Overlay Timer (Screen Share Mode)

### _resetOverlayTimer()
Cancels any existing hide timer. Sets `_overlaysVisible = true`. If the text input is focused or chat is pinned open, does not start a new timer. Otherwise starts a 1-second timer that sets `_overlaysVisible = false` (hides all overlay controls).

### _pinOverlays()
Cancels hide timer and ensures `_overlaysVisible = true` without restarting any timer. Used on mouse hover enter events.

## Source Switcher (Screen Share)

### _countActiveDmSources(CallState)
Counts how many video sources are active: local camera, remote camera, local screen share, remote screen share. Returns 0-4.

### _buildScreenShareSourcePill()
Builds a floating pill with one tab per active source. Order: screens first, then cameras. Each tab shows an icon (monitor/video), avatar, and name ("You" for local). Tapping a tab sets `focusedDmSourceProvider` (defined in `lib/src/core/providers/call_provider.dart`) to that (peerId, type) pair. The focused tab gets `hollow.accentMuted` background and bold text.

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
1. If `_stagedFilePath != null`: delegates to `_sendStagedFile()`.
2. Otherwise: trims text, returns if empty. Clears controller, resets `_lastTypingSent`, requests focus. Captures `_replyToMessageId` and `_stagedPreview` before clearing reply and preview state. Calls `chatProvider.notifier.sendMessage(peerId, text, replyToMid, linkPreview)`. Scrolls to bottom.

### _sendStagedFile()
Captures staged file path and name. Generates a message ID via `generateMessageId()`. Clears staged file state and controller text. Adds the file message optimistically to the chat via `chatProvider.notifier.addFileMessage()` (with filename, size, extension, isImage, diskPath, and optional caption text). Jumps to bottom. Then initiates the actual file transfer via `fileTransferProvider.notifier.sendFile(peerId, filePath, messageId, messageText)`.

## File Staging

### _stageClipboardImage(String path, String name)
Called by the clipboard paste handler when an image is found. Sets `_stagedFilePath`, `_stagedFileName`, `_stagedFileIsImage = true`. Requests focus on the text input.

### _handleDroppedFile(String path, String name, int sizeBytes)
Called by `ChatDropZone` on file drop. Enforces 34 MB DM limit (`34 * 1024 * 1024` bytes). If too large, shows an error toast with the file size. Otherwise detects image extensions (png, jpg, jpeg, gif, bmp, webp) and sets staged file state. Requests focus.

### _pickAndStageFile()
Opens the system file picker via `FilePicker.platform.pickFiles()`. Guarded by `_isPicking` mutex. Enforces the same 34 MB DM limit. Detects image extensions and sets staged file state. Always runs in a try/finally to reset `_isPicking`.

## Voice Recording

### _stageVoiceMessage(VoiceRecordingResult result)
Callback from `VoiceRecorderBar` when the user finishes recording. Checks that the `.ogg` file exists and is under 34 MB. If too large, shows error toast and deletes the temp file. Otherwise sets staged file state with filename "Voice message.ogg" and immediately calls `_sendStagedFile()` -- voice messages auto-send without a confirmation step. Sets `_isRecordingVoice = false`.

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
1. Left: `_DmProfilePanelSlider` (animated, 240px, shown unless screen share is active)
2. Right: `Expanded` containing `ChatDropZone` wrapping a `Column`

The Column's children depend on whether screen share is active:

**If screen share active** (`isScreenShareActive`): Shows a `MouseRegion` + `Stack` with:
- Layer 0: `_ScreenShareFullView` (full-bleed background)
- Layer 0.5: Source switcher pill (top-center, `AnimatedOpacity`, only if 2+ sources)
- Layer 1: Chat overlay slider (right side) -- toggle button + `_ChatOverlaySlider` with 360px chat panel
- Layer 2: `_ScreenShareControlsOverlay` floating pill (bottom center, `AnimatedOpacity`). When the REMOTE side is sharing (`call.remoteScreenSharing`), the pill includes a `ShareVolumeButton` (`ui/components/share_volume_control.dart`) between the share toggle and end-call — popover with the received-share-audio volume slider (0–200%, `shareAudioVolumeProvider`) and the voice-activity duck toggle (`shareAudioDuckProvider`), applied via the `ShareAudioLevel` bus.

**If no screen share**: Standard column layout with:
- `_InlineCallPanelSlider` (slides down when in call with this peer)
- `..._buildMessageArea()` -- message list, typing, reply bar, input bar

## Chat Header Bar

Always shown at the top. `Container` with `hollow.surface` background and bottom border. Contains a `Row` with:

1. **Avatar**: `HollowAvatar(peerId, size: 28)` with avatar bytes from `profileProvider`
2. **Name column** (2026-06-21 rework — the redundant status dot was REMOVED, since the right-side `ConnectionProgress` already conveys online/offline): if a LOCAL nickname is set → local nickname (bold 13px) on top + the friend's real name (raw `profile.displayName`, fallback truncated peer ID) below in 10px caption; if NO local nickname → just the real name, NO subline (the old truncated-peer-ID subline is gone). Watches `localNicknameProvider` + `profileProvider.select`.
3. **Connection progress**: `ConnectionProgress` widget showing encryption stage. **Multi-device (fixed 2026-06-15):** stage is `encrypted` if ANY device of the friend's master has an encrypted session — `peers.entries.any((e) => links.identityOf(e.key) == widget.peerId && e.value.isEncrypted)` — not a direct `peersProvider[widget.peerId]` lookup (that's device-keyed → always null for a multi-device/keystone-rotated friend → falsely showed Offline while dots/call-buttons showed online). Same scan pattern as the Home network column. Else `customNetwork` (custom relay) / `offline`. Invisible peer → not encrypted.
4. **Voice call button**: `LucideIcons.phone` / `LucideIcons.phoneCall`. Enabled when peer is online and not already in a call. Tapping calls `callProvider.notifier.startCall(peerId)`. Green when in-call with this peer
5. **Video call button**: `LucideIcons.video`. Same enable logic. Calls `startCall(peerId, withVideo: true)`
6. **Profile toggle**: `LucideIcons.user`. Toggles `dmProfilePanelProvider`. Accent when panel visible
7. **Notification mute**: `LucideIcons.bell` / `LucideIcons.bellOff`. Reads/writes `notificationSettingsProvider` for per-DM mute. Uses `.select((s) => s.dmEnabled[peerId] ?? true)` for granular rebuilds
8. **Split view button** (dock mode only): `LucideIcons.columns`. Shown only when `layoutModeProvider` is `LayoutMode.dock`. Calls `_handleSplitToggle()` which either opens a split via `splitViewProvider.notifier.openSplit()` or closes this pane via `splitViewProvider.notifier.closePane(splitPaneIndex ?? 0)`. Accent when split is active

## _buildMessageArea() -- Message List, Typing, Reply, Input

Returns a `List<Widget>` used by both the normal layout and the screen-share overlay chat panel.

### Message List

`Expanded` containing a `Stack` of `_buildMessageListLayer` + `_buildUnreadPillOverlay`.

**_buildMessageListLayer** -- `MessageActionBarScope` wrapping a `NotificationListener<ScrollNotification>` that dismisses all action bars on scroll. Contains either:
- `_buildEmptyDmState` (if `messages.isEmpty` after history loaded): centered `LucideIcons.messageCircle` (size 48, 0.3 alpha) + "No messages yet. Say hello!". Before history loaded: `SizedBox.shrink()`.
- `_buildMessageList`: precomputes `replyIndexById` (one pass per build), then calls the shared `reversedChatList()` shell (see wiki ui_chat_pane_shared) with `listKey: ValueKey('dm-list-${peerId}')`, the instance scroll controllers, and `itemBuilder: _buildMessageRow`. The shell owns `reverse: true`, index-0-bottom pinning, and `findChildIndexCallback` keyed-row reuse.

**_buildMessageRow(context, revIndex, messages, replyIndexById, profiles, localPeerId)** -- maps the reversed index back to chronological, determines `showHeader` via `shouldGroup()`, and builds a `MessageHoverWrapper` whose action callbacks come from nullable factories (null hides the affordance; tap-time reads use `ref.read` for freshness):

> Since issue #61 `MessageHoverWrapper` also owns the message CONTEXT MENU: right-click builds a `showHollowMenu` from these same callbacks (quick reaction strip, Add reaction, Reply, Copy text, Copy image, Download, Pin/Unpin, Edit, Delete, Message proof, Copy message ID). Because it is built from props the wrapper already holds, all SEVEN surfaces that use it got the menu with no call-site changes: DM chat, channel chat, guest chat and the four archive viewers. A row can never offer an action the surface did not wire up. `isPinned` (passed by `channel_chat_pane`) only changes the wording between Pin and Unpin.
  - `_editStartFor(msg, revIndex)`: Only own text messages (no file attachment). Captures the item's current `itemLeadingEdge` from `_itemPositionsListener`, sets `_editingMessageId`, then in a post-frame callback uses `_itemScrollController.jumpTo()` at the same alignment to preserve scroll position
  - `onEditSubmit` (inline): Clears edit state, calls `chatProvider.notifier.editMessage()`; `onEditCancel` clears edit state
  - `_deleteFor(msg)`: Only own messages. Calls `chatProvider.notifier.deleteMessage()`
  - `_replyFor(msg)`: Sets `_replyToMessageId`, `_replyToText` via `_messagePreviewText()` (image/paperclip placeholders), `_replyToSenderName`, `_replyToImagePath`. Requests focus on input
  - `onReaction` / bubble `onToggleReaction`: both delegate to `_toggleReaction(msg, emoji)` -- checks if local peer already reacted, calls `addReaction()` or `removeReaction()`
  - `_downloadFor(context, msg)`: If file has `diskPath`, opens save dialog via `_saveFile()` (split into `_saveDialogFileName` + `_writeSavedFile`). Otherwise requests from peer via `_requestFileFromPeer()`. Guards against duplicate downloads by checking `fileTransferProvider`
  - `_copyFor(context, msg)`: Copies message text to clipboard (excludes `[file:` messages)
  - `_copyImageFor(context, msg)`: For image attachments with disk path, calls `copyImageToClipboard()`; guards the itemBuilder's own context
  - `_infoFor(context, msg)`: Opens `MessageProofDialog` with signature verification data

The wrapper's child is `_buildBubble(...)`: resolves reply preview via `replyIndexById` + `_messagePreviewText`, then returns `MessageBubble` with `onReplyTap: _scrollToMessage(replyIndex)`. The row returns through the shared `dateSeparatedChatRow()` (keyed subtree, optional DateSeparator, group-header padding).

**_buildUnreadPillOverlay** -- reads `unreadProvider.dmUnreadCounts[peerId]`. Shown only when count > 0 AND `_showScrollPill`. Bottom-center `UnreadJumpPill`; tapping calls `_scrollToBottom()` and `markDmSeen()` against the TRUE newest message.

### Typing Indicator

`_buildTypingBar` -> shared `TypingIndicatorBar` when `typingPeers.isNotEmpty`. Names resolved via `displayNameForPeer()` per-pid profile selects.

### Reply Preview Bar

Shown when `_replyToMessageId != null` -- the shared `ChatReplyPreviewBar` widget (accent left border, "Replying to {name}", single-line preview, optional 32x32 gif-aware thumb, cancel X -> `_cancelReply()`).

### Staged File Preview

Shown when `_stagedFilePath != null` -- the shared `StagedFilePreviewBar` (48x48 gif-aware thumb or file icon, filename, remove X -> `_removeStagedFile()`).

### Staged Link Preview

The shared `StagedLinkArea` widget: `StagedHollowLinkCard` for `hollow://` links, else `StagedLinkPreviewCard` for http/https while `_stagedPreviewUrl != null`, else nothing. Dismiss callbacks `_dismissStagedHollowLink()` / `_dismissStagedPreview()` cancel `_urlDebounce` and clear the staged state.

### Input Bar

`_buildInputBar` -> shared `chatInputBarShell(hollow, flushTop: reply/staged/preview visible, child: ...)` (flushTop drops the top border to prevent double borders). When `_isRecordingVoice`: `VoiceRecorderBar(onFinished: _stageVoiceMessage, ...)`; otherwise `_buildComposerRow`:
1. **Paperclip button**: `_pickAndStageFile()`
2. **Microphone button**: disabled (0.4 alpha) when a file is staged; sets `_isRecordingVoice = true`
3. **Text field**: `Expanded` > `CompositedTransformTarget(_composerLayerLink)` > `Focus` (emote autocomplete keys, then `handleChatInputKey()` with `onPasteImage: _stageClipboardImage`) > shared `chatComposerField(hollow, hintText: 'Type a message...', onChanged: _onTextChanged)`
4. **Emoji button**: shared `composerEmojiButton(hollow, onOpen: _openComposerEmojiPicker)`
5. **Send button**: `LucideIcons.send` on `hollow.accent`; calls `_handleSend()`

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

**Drag overlay**: When dragging over, displays a full-overlay with `hollow.background` at 0.85 alpha. Centered card with accent border (2px), accent glow shadow (0.3 alpha, blur 24, spread 4), `LucideIcons.upload` icon (size 48), and "Drop file to attach" text.

**Drop handling** (`_handleDrop`): Takes only the first file from `DropDoneDetails.files`. Gets file size from disk via `File(path).length()`. Calls `onFileDropped(path, name, sizeBytes)` callback. The callback is responsible for size validation and staging.

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

## _InlineCallPanelSlider

`ConsumerStatefulWidget` with `SingleTickerProviderStateMixin`. Animated wrapper that slides the `_InlineCallPanel` down from the header when a call is active with this DM peer.

Watches `callProvider`. Drives `AnimationController` forward when `call.peerId == peerId && (status == active || connecting)`, reverse otherwise. Uses `HollowDurations.normal` duration, `HollowCurves.enter`/`exit`. Renders with `ClipRect` + `Align(heightFactor)` + `FadeTransition`. At value 0.0, renders `SizedBox.shrink()`.

## _InlineCallPanel

`ConsumerStatefulWidget`. The actual call panel content -- shows below the DM header during a call.

### State Variables
- `_durationTimer` -- 1-second periodic timer updating `_duration`
- `_remoteVolume` -- remote audio volume (0.0 to 2.0, default 1.0)
- `_duration` -- current call duration
- `_videoHeight` -- height of the video area (default 200, min 80, max 500)
- `_expandedRenderer` -- `null` for side-by-side view, `'local'` or `'remote'` for fullscreen with PiP

### build()
Watches `callProvider`, `profileProvider`. Reads `identityProvider` for local peer ID. Starts duration timer when call is active with a `startedAt` timestamp.

**Layout decisions**:
- `hasVideoArea` = any video or screen share active
- If screen share: video area uses `Expanded` (fills available space)
- If camera only: video area uses `SizedBox(height: _videoHeight)` with a drag-to-resize handle below
- Audio only: no video area, shows avatars (60px) side by side in the control bar

**Video views**:
- Side-by-side mode (`_expandedRenderer == null`): Two equal `Expanded` cells with `RTCVideoView` (local mirrored, remote not). Tapping a cell with active video sets `_expandedRenderer` to expand it
- Fullscreen mode (`_expandedRenderer != null`): Main video fills the area with `ObjectFitCover`. PiP (120x90) in bottom-right corner with border and shadow. "Click to exit" hint top-left. Tapping resets to side-by-side
- Source switcher pill shown when screen share active and 2+ sources

**Control bar**: Row with:
- Left: Green pulsing `StatusDot` + "Connecting..." or formatted duration (MM:SS with tabular figures)
- Center (audio-only): Two 60px `HollowAvatar`s wrapped in `SpeakingBorder(isSpeaking: call.isLocalSpeaking / call.isRemoteSpeaking)` — animated accent glow border on voice activity
- Right: `_buildControls()` -- Mute, Camera, Screen Share (desktop only), End Call buttons

### _showVolumePopup()
Right-click on the call panel shows an overlay popup with a volume slider (0-200%). Uses `OverlayEntry` with a dismiss-on-tap background. The slider adjusts `_remoteVolume` and calls `callProvider.notifier.setRemoteVolume(v)`.

### _buildControls()
Shared control row used by both the inline panel and the screen share overlay:
- **Mute**: `LucideIcons.mic` / `micOff`. Red when muted. Calls `toggleMute()`
- **Camera**: `LucideIcons.video` / `videoOff`. Accent when on. Calls `toggleVideo()`. Disabled when not active
- **Screen share** (desktop only): `LucideIcons.monitor` / `monitorOff`. Opens `showScreenShareDialog()`. Calls `startScreenShare()` with sourceId, width, height, fps, shareAudio. Or `stopScreenShare()` if already sharing
- **End call**: Red pill container with `LucideIcons.phoneOff`. Calls `endCall()`

### _buildScreenShareView()
Handles three cases:
1. **Both sharing**: Stacked layout -- remote screen on top (`Expanded flex: 3`) with quality label, local banner on bottom ("You are also sharing" + Stop button)
2. **Only local sharing**: Centered banner with monitor icon, "You are sharing your screen", optional quality label, Stop button
3. **Only remote sharing**: Full `RTCVideoView` (Contain, never mirrored) with optional quality label

### Source switcher helpers
`_countActiveDmSources()`, `_buildDmSources()`, `_onDmSourceTapped()`, and `_buildDmSourceSwitcher()` handle the source-switcher pill. For cameras, tapping sets `_expandedRenderer` for fullscreen. For screens, tapping is a no-op in the inline panel (the full-bleed view takes over automatically).

## _ChatOverlaySlider

`StatefulWidget` with `SingleTickerProviderStateMixin`. Animated horizontal slider for the chat panel during screen-share view. Slides in from the right when `visible` is true.

Uses `ClipRect` + `Align(widthFactor)` + `FadeTransition`. At value 0.0 returns `SizedBox.shrink()`. Wraps child in `MouseRegion` to relay hover events to `onHoverEnter`/`onHoverExit` callbacks (for overlay timer management).

## _ScreenShareFullView

`ConsumerWidget`. Full-bleed background view during screen share. Renders the focused video source as a large tile filling the entire area.

### _resolveBig()
Determines which `RTCVideoRenderer` to show based on `focusedDmSourceProvider` state. If the focused source is active, uses it. Otherwise falls back in priority order: remote screen -> local screen -> remote camera -> local camera. Returns a record with `renderer`, `isCamera`, and `isLocal` flags.

### _renderTile()
Helper that wraps `RTCVideoView` in a `RepaintBoundary`. Cameras are mirrored when local; screens are never mirrored. Uses Contain fit.

### build()
Reads renderers from `callProvider.notifier.voiceService` (camera) and `callProvider.notifier.screenShareRenderer`/`localScreenShareRenderer` (screen share).

**Both sharing**: Big tile showing focused source, PiP (220x132) showing the other screen in bottom-right. Tapping PiP swaps focus. Quality label top-left for screens. "Stop sharing" danger button top-right.

**Single sharer**: Big tile showing the focused source. If local sharing: quality label + stop button top-right. If remote sharing: quality label top-right. Empty state shows centered monitor icon + status text.

## _ScreenShareControlsOverlay

`ConsumerStatefulWidget`. Floating pill at bottom center during screen share. Shows:
- Green pulsing `StatusDot`
- "Connecting..." or peer name + duration (tabular figures)
- Mute, Camera, Screen Share (desktop only), End Call buttons
- Pill shape with `HollowRadius.pill` border radius, semi-transparent surface background, border, drop shadow

Has its own `_durationTimer` and `_handleScreenShareToggle()` (same pattern as inline panel).

## _DmProfilePanelSlider

`StatefulWidget` with `SingleTickerProviderStateMixin`. Animated horizontal slider for the DM profile panel. Slides from the left. Uses `ClipRect` + `Align(widthFactor, centerLeft)` + `FadeTransition`. Contains `_DmProfilePanel`.

## _DmProfilePanel

`ConsumerWidget`. 240px wide panel shown on the left side of DM chats.

### Providers read
- `profileProvider` -- display name, status, aboutMe, avatar bytes, banner bytes, twitchUsername
- `localNicknameProvider` -- local nickname for this peer
- `peersProvider` + `invisiblePeersProvider` -- online status
- `friendsProvider` -- friend status

### Layout
1. **Banner**: 90px tall. If peer has banner bytes, renders `AnimatedGifImage`. Otherwise renders a gradient derived from `_bannerColorFromId()` (HSL hue from peer ID hash, saturation 0.45, lightness 0.35).
2. **Avatar section**: 64px `HollowAvatar` with 3px surface-colored border, overlapping the banner by -32px (Transform.translate). Status dot in bottom-right corner (10px, green pulsing if online).
3. **Names**: If local nickname is set, shows nickname in bold 15px + display name below in caption 11px. Otherwise just display name.
4. **Status**: Italic caption text if set.
5. **Twitch badge**: If `profile.twitchUsername` is non-empty, shows a clickable purple pill (Twitch icon + username). Tapping opens `https://twitch.tv/{username}` externally. Synced via global `HavenMessage::ProfileUpdate`.
6. **Scrollable content** (ListView):
   - **About Me**: Quoted italic text in a bordered section
   - **Set/Edit Nickname** button: Full-width outline button. Shows pencil icon if nickname exists, tag icon if not. Opens `showLocalNicknameDialog()`
   - **Friend status**: "Friends" badge with checkmark icon (green) if friend status is "accepted"
   - **Peer ID**: Mono-font, 8px, 0.5 alpha. Full ID in a pressable row with copy icon. Tapping copies to clipboard and shows success toast

## TypingIndicatorBar

`StatelessWidget`. 24px tall bar shown above the input area. Displays:
- 1 name: "{name} is typing"
- 2 names: "{name1} and {name2} are typing"
- 3 names: "{name1}, {name2}, and {name3} are typing"
- 4+ names: "Several people are typing"

Text in italic caption style 11px + `TypingDots` widget alongside.

## TypingDots

`StatelessWidget`. Three 4px circles with animated bounce opacity. Uses `SharedTickers.instance.typingDots` (`ValueListenable<double>`) instead of per-instance `AnimationController`. Each dot has a 0.2 offset delay, creating a wave effect. Opacity ranges from 0.4 to 1.0 based on bounce value.

## _UnreadPill

`StatelessWidget`. Floating accent-colored pill shown when scrolled away from bottom and there are unread messages. Shows "{count} new message(s)" with a down-arrow icon. Tapping calls `onTap` (scrolls to bottom and marks as read). Uses `HollowPressable` with `borderRadius: 20`, accent background, and bold caption text.

## Split View Integration

`ChatPane` supports being rendered in either pane of a split view via the `splitPaneIndex` parameter. The split view button in the header (dock mode only) calls `_handleSplitToggle()`:
- If already split: closes this pane via `splitViewProvider.notifier.closePane(splitPaneIndex ?? 0)`
- If not split: opens split via `splitViewProvider.notifier.openSplit()`

The `ScrollablePositionedList` uses a `ValueKey('dm-list-${peerId}')` so each pane gets its own independent scroll state even when both show the same DM.

## Screen Share Mode -- Two Layout Paths

When a DM call involves screen sharing (`isScreenShareActive` = the call peer's DM and ANY share, ours or theirs), the entire message area is replaced with a full-bleed screen share view. The chat becomes an overlay:

1. **Background**: `_ScreenShareFullView` renders the focused video source
2. **Source pill**: Top-center floating pill for switching between video sources (only if 2+ active). Unwatched remote-share tabs show an EYE icon and tapping them opts in (`watchRemoteScreenShare()`); a trailing grid toggle flips `dmShareGridViewProvider`
3. **Chat overlay**: Right-side 360px panel that slides in/out via `_ChatOverlaySlider`. Toggle button (chevron left/right) is always visible when overlays are visible. The chat panel contains the same `_buildMessageArea()` content as normal mode
4. **Controls pill**: Bottom-center `_ScreenShareControlsOverlay` with all call controls

All overlays fade out after 1 second of inactivity via `_overlayHideTimer`. Mouse movement or hover over overlay elements pins them visible. The chat panel can be permanently pinned open via `_chatOverlayPinned`.

### Opt-in watching (issue #38)

The remote share is media-gated: the sharer captures + self-previews immediately (provider-owned `_dmScreenStream` + preview renderer in call_provider, VC-style) but only sends the `screen_offer` after the peer's `call_screen_watch{want:true}` (`_sendDmScreenOffer` — SFrame + per-watch screen-audio capture ride along). `CallState.watchingRemoteShare` gates the receive side; unsolicited offers are dropped. **Receiver-driven resolution capping (media forwarding step 1, 2026-08-05):** the watch payload also carries `viewer_width/viewer_height`; the sharer clamps the peer's encoder via `_dmEffectiveCap()` (`ScreenShareService.effectiveViewerCap`); a re-sent watch on a live share tries `updateResolutionCap` and renegotiates via `_sendDmScreenOffer` when rejected. **The "Source quality" opt-out was REMOVED 2026-08-15** (the clamp is keyed to the viewer's MONITOR, so it already delivers everything they can display) — `setRemoteShareSourceQuality`, `CallState.watchingSourceQuality` and the toggle chip are gone; an older client's `source_quality` key is ignored. The quality chip is `ShareQualityChip` showing the RECEIVED resolution live (falls back to `remoteScreenShareLabel`; our own share keeps its source label). **Unwatched UX (owner decision — never a banner over chat, that broke the Column):** `_ScreenShareFullView` renders `_buildUnwatchedShareStack` — a clean avatar + "X is sharing their screen" + Watch placeholder, side-by-side with our own share tile when both share (matches the VC grid's placeholder tile). Stop watching (button top-right of the single-source stack) returns to that placeholder. 20s watch timeout reverts with a toast.

### DM grid view (issue #38)

`dmShareGridViewProvider` (StateProvider, session-sticky) → `_buildDmGridView`: own share, their share (live or Watch placeholder), and both cameras as tiles (1-2 side by side, 3-4 as 2×2 with the underfull row centered); tap a live tile to focus + exit grid; Stop sharing stays reachable top-right.

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

### IncomingCallOverlay (desktop widget reused)

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
