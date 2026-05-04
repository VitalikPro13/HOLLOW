# ChatPane -- DM Conversation View

Primary file: `lib/src/ui/chat/chat_pane.dart` (~3978 lines). The ChatPane is the main one-to-one direct message view. It handles the message list, input bar, file attachments, voice recording, inline call panel (audio/video/screen share), a DM profile panel, reply/quote flow, link previews, typing indicators, and unread tracking. Supporting files: `lib/src/ui/chat/chat_drop_zone.dart` (drag-and-drop file attachment wrapper) and `lib/src/ui/chat/chat_input_shortcuts.dart` (keyboard shortcuts and clipboard image paste).

## Top-Level Providers Defined in This File

- `dmProfilePanelProvider` -- `StateProvider<bool>`, defaults `true`. Controls visibility of the left-side DM profile panel. Toggled by the user icon button in the chat header.

## Top-Level Helper Functions

### shouldGroup()
Determines whether two consecutive messages should be visually grouped (same sender, within 5 minutes). For DMs it compares `isMe` flags; for channels it additionally checks `senderId`. Returns `true` if both messages are from the same sender and their timestamps differ by less than 5 minutes.

### shouldShowDateSeparator()
Returns `true` when a date separator should be rendered between two messages. Always shows for the first message. Shows when the calendar day changes between `current` and `previous` timestamps.

## DateSeparator Widget

`StatelessWidget`. Renders a horizontal rule with a centered date label: "Today", "Yesterday", or "Month Day, Year" (e.g., "February 16, 2026"). The line uses `hollow.border` color; the label uses `HollowTypography.caption` at font size 11, weight w600, 0.6 alpha. Padding: `md+2` top, `sm` bottom, `lg` horizontal.

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
Listener invoked whenever visible items change. Updates `_showScrollPill` (inverted from `_isNearBottom`). Writes to `chatAtBottomProvider` (shared `StateProvider<bool>` in `member_panel_provider.dart`). When `_isNearBottom` is true, marks the DM as read via `unreadProvider.notifier.markDmSeen()`.

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
- Layer 2: `_ScreenShareControlsOverlay` floating pill (bottom center, `AnimatedOpacity`)

**If no screen share**: Standard column layout with:
- `_InlineCallPanelSlider` (slides down when in call with this peer)
- `..._buildMessageArea()` -- message list, typing, reply bar, input bar

## Chat Header Bar

Always shown at the top. `Container` with `hollow.surface` background and bottom border. Contains a `Row` with:

1. **Avatar**: `HollowAvatar(peerId, size: 28)` with avatar bytes from `profileProvider`
2. **Status dot**: Reads `peersProvider` and `invisiblePeersProvider`. Green pulse if online, gray if offline
3. **Name column**: Display name (from `profileProvider`, via `displayNameFor()`) in bold 13px, truncated peer ID (first 16 chars) below in 10px caption
4. **Connection progress**: `ConnectionProgress` widget showing encryption stage. `encrypted` if peer exists and is encrypted and not invisible, `offline` otherwise
5. **Voice call button**: `LucideIcons.phone` / `LucideIcons.phoneCall`. Enabled when peer is online and not already in a call. Tapping calls `callProvider.notifier.startCall(peerId)`. Green when in-call with this peer
6. **Video call button**: `LucideIcons.video`. Same enable logic. Calls `startCall(peerId, withVideo: true)`
7. **Profile toggle**: `LucideIcons.user`. Toggles `dmProfilePanelProvider`. Accent when panel visible
8. **Notification mute**: `LucideIcons.bell` / `LucideIcons.bellOff`. Reads/writes `notificationSettingsProvider` for per-DM mute. Uses `.select((s) => s.dmEnabled[peerId] ?? true)` for granular rebuilds
9. **Split view button** (dock mode only): `LucideIcons.columns`. Shown only when `layoutModeProvider` is `LayoutMode.dock`. Calls `_handleSplitToggle()` which either opens a split via `splitViewProvider.notifier.openSplit()` or closes this pane via `splitViewProvider.notifier.closePane(splitPaneIndex ?? 0)`. Accent when split is active

## _buildMessageArea() -- Message List, Typing, Reply, Input

Returns a `List<Widget>` used by both the normal layout and the screen-share overlay chat panel.

### Message List

`Expanded` containing a `Stack`:

**Layer 0: The message list** -- `MessageActionBarScope` wrapping a `NotificationListener<ScrollNotification>` that dismisses all action bars on scroll. Contains either:
- Empty state (if `messages.isEmpty`): After history loaded, shows a centered `LucideIcons.messageCircle` (size 48, 0.3 alpha) + "No messages yet. Say hello!" text. Before history loaded, shows `SizedBox.shrink()`.
- Message list: `SelectionArea` with empty context menu, wrapped in `ScrollConfiguration` (scrollbars disabled), containing `ScrollablePositionedList.builder`.

**ScrollablePositionedList configuration**:
- `key: ValueKey('dm-list-${peerId}')` -- ensures list recreates when switching DM peers
- `itemScrollController`, `itemPositionsListener`, `scrollOffsetController` -- connected to instance variables
- `initialScrollIndex: messages.length` -- starts at the sentinel
- `initialAlignment: 1.0` -- bottom-aligned
- `padding: EdgeInsets.symmetric(vertical: sm)`
- `itemCount: messages.length + 1` -- sentinel pattern (extra invisible item at the end for bottom anchoring)

**Item builder** (for each index):
- If `index >= messages.length`: returns `SizedBox.shrink()` (sentinel)
- Determines `showHeader` via `shouldGroup()` (first message always shows header)
- Builds a `MessageHoverWrapper` with all action callbacks:
  - `onEditStart`: Only for own text messages (no file attachment). Sets `_editingMessageId`
  - `onEditSubmit`: Clears edit state, calls `chatProvider.notifier.editMessage()`
  - `onEditCancel`: Clears edit state
  - `onDelete`: Only for own messages. Calls `chatProvider.notifier.deleteMessage()`
  - `onReply`: Sets `_replyToMessageId`, `_replyToText` (image icon for image attachments, paperclip for files), `_replyToSenderName`, `_replyToImagePath`. Requests focus on input
  - `onReaction(emoji)`: Toggles reaction -- checks if local peer already reacted, calls `addReaction()` or `removeReaction()` on `chatProvider.notifier`
  - `onDownload`: If file has `diskPath`, opens save dialog via `_saveFile()`. Otherwise requests from peer via `_requestFileFromPeer()`. Guards against duplicate downloads by checking `fileTransferProvider`
  - `onCopy`: Copies message text to clipboard (excludes file-only messages starting with `[file:`)
  - `onCopyImage`: For image attachments with disk path, calls `copyImageToClipboard()` from `chat_input_shortcuts.dart`
  - `onInfo`: Opens `MessageProofDialog` with signature verification data (sender, text, timestamp, signature, public key, message ID, context)

**Reply resolution**: For messages with `replyToMid`, looks up the original message by scanning the messages list. Resolves `replySender`, `replyText` (image/file placeholder or text), `replyImagePath`, and `replyIndex`. The `MessageBubble` receives these plus an `onReplyTap` callback that calls `_scrollToMessage(replyIndex)` for navigation.

**Date separators**: After building the wrapper, checks `shouldShowDateSeparator()`. If true, wraps the message in a `Column` with a `DateSeparator` above it. Messages with `showHeader` get extra top padding (`sm + 2`).

**Layer 1: Unread pill** -- `Builder` reading `unreadProvider.dmUnreadCounts[peerId]`. Shown only when count > 0 AND `_showScrollPill` is true. Positioned at bottom center. Tapping calls `_scrollToBottom()` and `markDmSeen()`.

### Typing Indicator

`TypingIndicatorBar` shown when `typingPeers.isNotEmpty`. Displays peer names resolved via `displayNameFor()` from `profileProvider`.

### Reply Preview Bar

Shown when `_replyToMessageId != null`. A `Container` with accent left border (3px) and top border. Contains:
- Reply icon (`LucideIcons.reply`, accent color)
- "Replying to {name}" label in accent, bold
- Reply text preview (single line, ellipsis) with optional 32x32 image thumbnail (supports GIF via `GifFileImage`)
- Close button (X icon) that clears all reply state

### Staged File Preview

Shown when `_stagedFilePath != null`. A `Container` with top border. Contains:
- For images: 48x48 `ClipRRect` image preview (GIF-aware via `GifFileImage`)
- For non-images: 48x48 container with `LucideIcons.file` icon
- Filename text (single line, ellipsis)
- Close button that clears staged file state

### Staged Link Preview

Two variants, shown mutually exclusively when `_stagedPreviewUrl != null`:
1. `StagedHollowLinkCard` -- for `hollow://` protocol links. Shows when `_stagedHollowLink != null`. Has an `onDismiss` callback that clears staged URL and hollow link state.
2. `StagedLinkPreviewCard` -- for regular http/https URLs. Receives `url`, `preview` (nullable), and `loading` flag. Has an `onDismiss` callback that clears all staged preview state.

Both cancel `_urlDebounce` on dismiss.

### Input Bar

`Container` with `hollow.surface` background. Top border is `BorderSide.none` when reply bar, staged file, or staged preview is visible (prevents double borders), otherwise normal border.

When `_isRecordingVoice` is true: renders `VoiceRecorderBar(onFinished: _stageVoiceMessage, onCancelled: ...)` instead of the normal input row.

Normal input row is a `Row` containing:
1. **Paperclip button**: `LucideIcons.paperclip`, size 20. Tapping calls `_pickAndStageFile()`
2. **Microphone button**: `LucideIcons.mic`, size 20. Disabled (0.4 alpha) when a file is staged. Tapping sets `_isRecordingVoice = true`
3. **Text field**: `Expanded` with `Focus` wrapper for keyboard shortcuts. `HollowTextField` with:
   - Hint: "Type a message..."
   - `autofocus: true`
   - `maxLines: 5`, `minLines: 1` (expands up to 5 lines)
   - `maxLength: 4000`, `showCounter: false`
   - `borderRadius: hollow.radiusLg`
   - `onChanged: _onTextChanged`
   - The `Focus.onKeyEvent` delegates to `handleChatInputKey()` with `onPasteImage: _stageClipboardImage`
4. **Send button**: `LucideIcons.send` with `hollow.accent` background and `hollow.textOnAccent` icon color. Tapping calls `_handleSend()`

## Providers Read by ChatPane

| Provider | Purpose |
|---|---|
| `chatProvider` | Message list per peer. Watched for rendering + listened for auto-scroll |
| `typingProvider` | Typing indicator set per peer |
| `dmProfilePanelProvider` | Profile panel visibility |
| `callProvider` | Call state (status, video, screen share, mute) |
| `profileProvider` | Display names, avatars, banners for all peers |
| `identityProvider` | Local peer ID |
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
- Center (audio-only): Two 60px `HollowAvatar`s
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

When a DM call involves screen sharing (`isScreenShareActive`), the entire message area is replaced with a full-bleed screen share view. The chat becomes an overlay:

1. **Background**: `_ScreenShareFullView` renders the focused video source
2. **Source pill**: Top-center floating pill for switching between video sources (only if 2+ active)
3. **Chat overlay**: Right-side 360px panel that slides in/out via `_ChatOverlaySlider`. Toggle button (chevron left/right) is always visible when overlays are visible. The chat panel contains the same `_buildMessageArea()` content as normal mode
4. **Controls pill**: Bottom-center `_ScreenShareControlsOverlay` with all call controls

All overlays fade out after 1 second of inactivity via `_overlayHideTimer`. Mouse movement or hover over overlay elements pins them visible. The chat panel can be permanently pinned open via `_chatOverlayPinned`.
