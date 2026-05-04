# Message Bubbles and Chat Widgets

Covers every message rendering widget, action bar, text parser, link preview card, emoji picker, and voice recorder. All widgets live under `lib/src/ui/chat/`.

---

## MessageBubble (DM)

**File:** `lib/src/ui/chat/message_bubble.dart`
**Class:** `MessageBubble extends ConsumerWidget`
**Purpose:** Flat message row for DM conversations. No chat-bubble wrapper -- content is laid out horizontally with an avatar on the left.

### Constructor Parameters

| Parameter | Type | Description |
|---|---|---|
| `message` | `ChatMessage` | The DM message model |
| `peerId` | `String` | Peer ID of the conversation partner |
| `showHeader` | `bool` | Whether to show avatar + name + timestamp (group leader) or just indented text (continuation) |
| `replyToSenderName` | `String?` | Display name of the person being replied to |
| `replyToText` | `String?` | Quoted text of the message being replied to |
| `replyToImagePath` | `String?` | Disk path to a thumbnail if the replied-to message had an image |
| `isHighlighted` | `bool` | Amber-tinted background when this message is scroll-targeted |
| `onReplyTap` | `VoidCallback?` | Callback to scroll to the original replied-to message |
| `onToggleReaction` | `void Function(String emoji)?` | Callback to toggle an emoji reaction |

### Layout — Header Mode (`showHeader == true`)

```
AnimatedContainer (400ms easeOut)
  Row (crossAxisAlignment: start)
    HollowAvatar (32px, paddingTop 5)
    SizedBox(width: 10)
    Expanded Column:
      Row: senderName (bold 13px) + SizedBox(8) + time (10px muted)
      SizedBox(height: 3)
      ?replyWidget
      ?messageTextWidget
      ?linkPreviewWidget
      ?hollowLinkWidgets
      ?fileWidget
      ?reactionBarWidget
```

Padding: `top: 4, bottom: 4, left: HollowSpacing.md, right: HollowSpacing.md`.

### Layout — Continuation Mode (`showHeader == false`)

Same vertical stack of content widgets, but:
- No avatar, no name row, no timestamp.
- Left padding is `HollowSpacing.md + indent` where `indent = 32 + 10 = 42px` (aligns text under the header mode's text column).
- Vertical padding reduced to `top: 2, bottom: 2`.

### Decoration Rules

- **Own messages:** A 2px accent-colored right border (`meDecoration`).
- **Highlighted messages:** Accent background at 8% alpha. If also own message, combines with the right border.
- **Other messages:** No decoration.
- Decoration is applied via `AnimatedContainer.decoration` for smooth transition.

### Name Color Logic

`nameColorFromId(String id)` — top-level function. Deterministic hue from `id.hashCode % 360`, saturation 0.6, lightness 0.65. Own messages use the theme accent color instead.

### Sender Name Resolution

Reads `profileProvider` and `identityProvider`. For own messages, uses local peer ID; otherwise uses the conversation `peerId`. Display name comes from `displayNameFor(profiles, senderId)`.

### Timestamp Format

`HH:MM` (24-hour, zero-padded). Displayed at 10px font in muted secondary color.

### Edit Indicator

When `message.editedAt != null`, a `(edited)` suffix span is appended to the message text widget in 10px muted text at 50% alpha.

### File-Only Detection

`isFileOnly` is true when `message.fileAttachment != null` AND the text is empty or starts with `[file:`. In this case `messageTextWidget` is null -- only the file widget renders.

### Reply Widget

Built when `message.replyToMid != null && replyToText != null`. Structure:
- Thin 2px vertical bar (secondary at 30% alpha, 28px tall, 1px radius)
- Sender name in accent bold 10px
- Reply text in secondary 11px, maxLines 1, ellipsized
- If `replyToImagePath` exists and the file is present on disk: a 32x32 rounded thumbnail (GIF files use `GifFileImage`, others use `Image.file`)
- If `onReplyTap` is provided, the entire reply widget is wrapped in `MouseRegion(cursor: click)` + `GestureDetector(onTap: onReplyTap)`.

### Link Preview Widget

When `message.linkPreview != null`: renders a `LinkPreviewCard` below the text with `xs` top padding.

### Hollow Link Widgets

Extracts `hollow://` links from message text (code blocks stripped first via regex). Up to 3 links rendered as `HollowLinkCard` instances in a vertical column with `xs` top padding each.

### File Attachment Widget

When `message.fileAttachment != null`: renders `FileAttachmentWidget` with `xs` top padding.

### Reaction Bar Widget

When `message.reactions` is non-empty: renders `ReactionBar` passing `localPeerId` and `onToggleReaction`.

---

## ChannelMessageBubble

**File:** `lib/src/ui/chat/channel_message_bubble.dart`
**Class:** `ChannelMessageBubble extends ConsumerWidget`
**Purpose:** Flat message row for server channel messages. Structurally near-identical to `MessageBubble` with channel-specific additions.

### Differences from MessageBubble

1. **Model type:** Uses `ChannelChatMessage` instead of `ChatMessage`.
2. **Server nickname resolution:** Reads `serverNicknamesProvider(serverId)` and uses `serverDisplayNameFor(profiles, message.senderId, nickname:)` which prefers server nicknames over profile display names.
3. **`isMentioned` flag:** Extra boolean parameter. When true, the message gets the same accent-tinted background as `isHighlighted`. The highlight decoration condition is `isHighlighted || isMentioned`.
4. **@mention name resolution:** Watches `serverMembersProvider(serverId)` to build a `Set<String>` of all member names (display names, nicknames, profile names). Passes this as `memberNames:` to `buildMessageText()` so @mentions are rendered as highlighted pills.
5. **Avatar uses `message.senderId`** directly (not a `peerId` parameter) since channel messages carry their sender ID.
6. **`serverId` parameter:** Required, used for nickname and member lookups.

### Layout

Identical to `MessageBubble` -- same avatar size (32px), same gap (10px), same indent (42px), same padding, same decoration pattern.

### @Mention Highlighting

The `memberNames` set is built by iterating all server members and collecting:
- The formatted display name via `serverDisplayNameFor`
- The raw `m.nickname` if non-empty
- The profile's `displayName` if non-empty

This set is passed to `buildMessageText()` which forwards it to the `MessageText` widget for @mention pill rendering.

---

## AudioMessageBubble

**File:** `lib/src/ui/chat/audio_message_bubble.dart`
**Class:** `AudioMessageBubble extends ConsumerStatefulWidget`
**Purpose:** Inline audio playback card rendered inside a message when the file attachment is an audio format.

### Playback States

`_PlaybackState` enum: `idle`, `playing`.

### Constructor

Takes a single `FileAttachment attachment`.

### State Fields

- `_state` — current playback state
- `_player` — `AudioPlayer?` instance
- `_positionSub`, `_durationSub`, `_completeSub` — stream subscriptions for player events
- `_position`, `_duration` — current playback position and total duration
- `_isPlaying` — whether audio is actively playing (vs paused)
- `_isVisible` — tracked via `VisibilityDetector`; auto-pauses when scrolled out of view (< 50% visible)
- `_preparing` — true while Opus-to-WAV transcode is running
- `_probedDurationMs` — pre-play duration from ffmpeg probe
- `_probeStarted` — prevents duplicate probe attempts

### Duration Probe

`_maybeProbe()` runs on `initState` and `didUpdateWidget`. Uses `AudioProbeService.probeDurationMs(path)` to get duration before playback starts. Also prewarms the Opus transcode cache via `AudioTranscodeService.ensurePlayable(path)` (fire-and-forget).

### Disk Path Resolution

`_resolveDiskPath()` prefers `attachment.diskPath` (from DB hydrate) but falls back to the live `fileTransferProvider` state so the play button enables the moment an auto-download finishes.

### Play Flow

1. `_onPlayTapped()` checks `_canPlay()` (disk path exists and file is on disk).
2. Takes the audio playback slot via `currentlyPlayingAudioProvider.notifier.state = _playKey`.
3. Clears the video slot (`currentlyPlayingVideoProvider = null`) to stop any playing video.
4. On Windows, Opus-in-Ogg is transcoded to PCM WAV via `AudioTranscodeService.ensurePlayable(path)`. Shows `_preparing = true` during transcode.
5. Initializes `AudioPlayer`, subscribes to position/duration/completion events, calls `player.play(DeviceFileSource(audioPath))`.

### Single-Audio-at-a-Time

`ref.listen<String?>(currentlyPlayingAudioProvider, ...)` — when another audio bubble takes the slot, this one disposes its player and resets to idle.

`ref.listen<String?>(currentlyPlayingVideoProvider, ...)` — when a video starts playing, this audio bubble stops.

### Idle State Layout

```
Row:
  _PlayButton (36px circle, accent color, play icon; loader2 icon if preparing)
  SizedBox(width: md)
  Expanded Column:
    fileName (body 13px w500, ellipsized)
    SizedBox(height: xxs)
    Row: [durationText " · "] + statusText
```

Status text in idle mode varies:
- Vault phase text (e.g. "Collecting shards...") if available
- `"{bytesReceived} / {formattedSize}"` if downloading with progress
- `"Downloading... {formattedSize}"` if downloading without progress
- Just `formattedSize` otherwise

### Playing State Layout

```
Row:
  _PlayButton (pause/play icon, accent color)
  SizedBox(width: md)
  Expanded Column:
    fileName (body 13px w500)
    SizedBox(height: xxs)
    SliderTheme (trackHeight 3, thumb radius 5)
      Slider (position in ms, clamped)
    Row: position " / " duration " · " formattedSize
```

Timestamps use tabular figures for stable width. Format: `m:ss`.

### Download Progress Bar

When downloading or not-yet-complete with progress > 0: a 3px `LinearProgressIndicator` at the bottom of the card (determinate if progress > 0, indeterminate otherwise).

### Container Styling

`maxWidth: 280`, clipped with `Clip.antiAlias`, surface background, `radiusSm` corners, border.

### _PlayButton Widget

Circular 36x36 container with the accent color. Play icon is nudged 1.5px right for optical centering inside the circle. Uses `HollowPressable` for tap handling.

### Visibility Auto-Pause

`VisibilityDetector` with key `audio_bubble_{fileId}`. When visible fraction drops below 50%, pauses playback.

---

## VideoMessageBubble

**File:** `lib/src/ui/chat/video_message_bubble.dart`
**Class:** `VideoMessageBubble extends ConsumerStatefulWidget`
**Purpose:** Inline video preview and playback within message bubbles. Handles both vault-backed and direct P2P video files.

### Playback States

`_PlaybackState` enum: `thumbnail`, `preparing`, `playing`.

### Two Video Source Types

1. **Vault video** (`attachment.videoThumb != null`): `attachment.diskPath` points to the local `.webp` thumbnail image. The actual video bytes are in the vault and are reconstructed on first play via `vault_download_file`.
2. **Direct P2P video** (`videoThumb == null`): `attachment.diskPath` is the video file itself. A local thumbnail is extracted to `{file_id}.thumb.webp` next to the video file.

### Display Size Calculation

`_resolveDisplaySize()`:
- Max dimensions: 320x260 pixels.
- Uses `attachment.width` and `attachment.height` (populated by Rust for images, by Dart's `VideoThumbnailService.extractVideoThumbnail` for videos).
- Maintains aspect ratio within the max bounds.
- Falls back to 16:9 (320x180) if dimensions are unavailable (old clients).

### Thumbnail Mode

`_buildThumbnail(hollow)`:
- Background: thumbnail image via `Image.file` if `_resolveThumbnailImagePath()` returns a path; black container otherwise.
- **No seeders overlay:** When share-backed, not complete, seeders == 0, and no chunks received: dark overlay with `cloudOff` icon and "No seeders" text.
- **Play button:** 64x64 circle, black at 55% alpha, white border (2px, 85% alpha), white play icon (28px). Always visible unless no-seeders overlay is active.
- **Download progress bar:** When downloading: 3px `LinearProgressIndicator` at bottom, and a `_Badge` showing percentage at bottom-left.
- **Duration badge:** When not downloading and vault video has duration > 0: badge at bottom-left showing formatted duration.
- **Size badge:** Always at bottom-right showing formatted file size.
- **Keep & Seed button:** When the file is in `vault_cache/` and a share root hash exists: `_KeepAndSeedButton` at top-right.

### Preparing Mode

`_buildPreparing(hollow)`:
- Thumbnail image as background (or black).
- 50% black overlay.
- Centered 48px `CircularProgressIndicator` (accent color, 3px stroke, white24 background).
- Phase text below spinner (vault phase from transfer state, or "Preparing video..." for vault, "Loading..." for P2P).

### Playing Mode

Delegates to `_InlinePlayer` widget (see below). Passes the `VideoPlayerController`, hollow theme, and a fullscreen callback.

### Vault Video Resolution

`_resolveVaultVideoPath(vthumb)`:
1. Calls `crdt_api.vaultDownloadFile(serverId, contentId)`.
2. If the return is non-empty, the file is already cached -- returns the path.
3. If empty, reconstruction is in flight. Sets up a `ref.listenManual<Map<String, FileTransferState>>` listener watching for a matching `VaultDownloadComplete` event (matches by content ID).
4. Times out after 2 minutes.

### Single-Video-at-a-Time

Listens to `currentlyPlayingVideoProvider` -- if another bubble takes the slot, this one disposes its controller and returns to thumbnail.

Listens to `currentlyPlayingAudioProvider` -- if an audio bubble starts, this one stops.

### Visibility Auto-Pause

`VisibilityDetector` pauses the controller (but does not dispose it) when visible fraction drops below 50%.

### Local Thumbnail Extraction

`_maybeExtractLocalThumb()`:
- Skipped for vault videos (they already have a `.webp` thumbnail).
- Tries sync cache hit via `VideoThumbnailService.cachedThumbFor(videoPath)`.
- Falls back to async extraction via `VideoThumbnailService.ensureCachedThumb(videoPath)`.
- Sets `_localThumbPath` when complete.

### _InlinePlayer

**Class:** `_InlinePlayer extends StatefulWidget` (private, same file)

Stateful inline player wrapper. Owns the auto-fade timer for the control bar. Rebuilds on controller value changes (scrub bar + timestamps sync). The `VideoPlayerController` is owned by the parent `_VideoMessageBubbleState` -- this widget never disposes it.

**Control bar auto-fade:**
- `_controlsVisible` starts true.
- `_scheduleHide()` starts a 1-second timer that hides controls (only if not hovering and video is playing).
- Mouse enter/exit/hover events and play/pause toggling call `_showControlsAndReschedule()`.
- Controls fade via `AnimatedOpacity` (200ms). `IgnorePointer(ignoring: !_controlsVisible)` prevents interaction when hidden.

**Tap behavior:** Tapping the video area toggles play/pause.

**Layout:**
```
Stack:
  Container (black background)
    Center > AspectRatio > VideoPlayer
  Positioned (bottom)
    AnimatedOpacity
      _ControlBar
```

### _ControlBar

**Class:** `_ControlBar extends StatelessWidget` (private, shared by inline and fullscreen)

**Layout:**
```
Container (gradient: transparent -> black 75%)
  Column:
    SliderTheme (trackHeight 3, thumb 6px, accent color)
      Slider (position ms, clamped 0..duration)
    Padding Row:
      _IconBtn (play/pause)
      SizedBox(sm)
      Text "{position} / {duration}" (caption 11px, tabular figures, white)
      Spacer
      _IconBtn (maximize2 or minimize2, depending on isFullscreen)
```

Time format: `m:ss`.

### _FullscreenVideoView

**Class:** `_FullscreenVideoView extends StatefulWidget` (private)

Launched via `showHollowDialog()`. Owns its own `VideoPlayerController` initialized from the video path.

- Wrapped in `Material(type: transparency)` to prevent yellow debug underline on text widgets (the `showHollowDialog` + `Material` ancestor requirement).
- Tapping the dim background (outside the player) dismisses the dialog.
- Tapping inside the player toggles play/pause.
- Uses the same `_ControlBar` with `isFullscreen: true` (minimize icon, clicking it pops the dialog).
- Same auto-fade timer pattern as `_InlinePlayer`.
- Player is padded with `HollowSpacing.xxl` and clipped with `radiusMd`.
- Loading state shows a centered 48px `CircularProgressIndicator`.

### _KeepAndSeedButton

**Class:** `_KeepAndSeedButton extends ConsumerStatefulWidget` (private)

For share-backed videos cached in `vault_cache/`. Three-state toggle:
1. **Not kept:** Shows `hardDrive` icon + "Keep & Seed" label. Tapping calls `share_api.shareKeepAndSeed(rootHash:)`.
2. **Kept but paused:** Shows `pause` icon + "Paused". Tapping calls `share_api.shareSetSeeding(rootHash:, seeding: true)`.
3. **Seeding:** Shows `check` icon + "Seeding", accent background. Tapping calls `share_api.shareSetSeeding(rootHash:, seeding: false)`.

Loading state shows a small spinner. Watches `shareTabProvider` for reactive updates.

### _Badge

Small rounded container with black at 65% alpha background, white text at 11px w500. Used for duration and file size overlays on the thumbnail.

---

## FileAttachmentWidget

**File:** `lib/src/ui/chat/file_attachment_widget.dart`
**Class:** `FileAttachmentWidget extends ConsumerWidget`
**Purpose:** Router widget that inspects the attachment type and delegates to the appropriate specialized bubble or renders an image preview / generic file card.

### Delegation Logic

1. If `attachment.isExpired` -- renders expired card.
2. If share-backed with no seeders and no chunks received -- renders unavailable card.
3. If `_isVideoAttachment()` -- delegates to `VideoMessageBubble`.
4. If `_isAudioAttachment()` -- delegates to `AudioMessageBubble`.
5. If `attachment.isImage` -- renders inline image preview.
6. Otherwise -- renders generic file card.

### Video Detection

`_isVideoAttachment()`:
- True if `attachment.videoThumb != null` (vault video).
- True if extension matches: `mp4`, `webm`, `mov`, `mkv`, `avi`, `m4v`.
- False if `attachment.isImage` (prevents image files with matching extensions).

### Audio Detection

`_isAudioAttachment()`:
- True if extension matches: `mp3`, `ogg`, `wav`, `flac`, `m4a`, `aac`, `wma`.
- False if `attachment.isImage`.

### Transfer State Tracking

Watches `fileTransferProvider.select((s) => s[attachment.fileId])` for live download progress. Computes:
- `isComplete` — attachment's own flag OR transfer state's flag.
- `diskPath` — attachment's path OR transfer's path.
- `isDownloading` — not complete AND transfer says downloading.
- `vaultPhase` — vault reconstruction phase text (e.g. "Collecting shards...").
- `progress` — transfer progress or attachment progress (0..1 ratio).
- `bytesReceived` — `(progress * totalBytes).round()`.

### Expired Card

`_buildExpiredCard(hollow)`:
- `maxWidth: 280`, surface background, border, `radiusSm` corners.
- Row: `clock` icon (24px, secondary) + Column: fileName (secondary 13px, ellipsized) + "File expired . {formattedSize}" (italic caption).

### Unavailable Card (No Seeders)

`_buildUnavailableCard(hollow)`:
- Same layout as expired card but with `cloudOff` icon and "No seeders . {formattedSize}" text.

### Image Preview

`_buildImagePreview(...)`:
- Max dimensions: 300x250.
- Aspect-ratio-preserving size calculation from `attachment.width`/`attachment.height`.
- **Complete with file on disk:** `GestureDetector(onTap: showFullscreen)` wrapping `MouseRegion(cursor: click)` wrapping `ConstrainedBox` wrapping `ClipRRect(radiusSm)` containing either `GifFileImage` (for `.gif`) or `Image.file` with `BoxFit.contain`. Error builder falls back to placeholder.
- **Downloading:** Placeholder with `CircularProgressIndicator` (40px, determinate if progress > 0), status text below.
- **Partial progress (not downloading):** Placeholder with 80px `LinearProgressIndicator` and percentage text.
- **No progress:** Placeholder with `image` icon (32px) and formattedSize.

### Fullscreen Image Viewer

`_FullscreenImageView` (private class):
- Launched via `showHollowDialog()`.
- Tap outside to dismiss.
- `HollowSpacing.xxl` padding, `radiusMd` clip.
- GIF files use `GifFileImage`, others use `Image.file`.
- Close button at top-right: `HollowPressable` with `x` icon on elevated background at 80% alpha.

### Generic File Card

`_buildFileCard(...)`:
- `maxWidth: 280`, surface background, border, `radiusSm` corners.
- Row: file-type icon (28px, accent) + Column: fileName (body 13px w500, ellipsized) + status text (caption 11px, secondary).
- Status text priority: vault phase > downloading with bytes > downloading > formattedSize.
- 3px `LinearProgressIndicator` at bottom when downloading or partial progress.

### File Icon Mapping

`_fileIcon()` maps extensions:
- `pdf` -- `fileText`
- `zip/rar/7z/tar/gz` -- `fileArchive`
- `mp3/ogg/wav/flac/m4a/aac/wma` -- `fileAudio`
- `mp4/webm/avi/mkv` -- `fileVideo`
- `txt/md/log` -- `fileText`
- Everything else -- `file`

---

## ReactionBar

**File:** `lib/src/ui/chat/reaction_bar.dart`
**Class:** `ReactionBar extends StatelessWidget`
**Purpose:** Displays emoji reaction pills below a message.

### Parameters

- `reactions` — `Map<String, List<String>>`: emoji to list of peer IDs.
- `localPeerId` — current user's peer ID for highlighting own reactions.
- `onToggleReaction` — `void Function(String emoji)?`: called on tap. Null in read-only mode (pills render but are not tappable).

### Layout

Returns `SizedBox.shrink()` if reactions is empty.

`Wrap` with spacing 4, runSpacing 4. Reactions sorted by count descending (insertion order for ties).

Each pill is a `HollowPressable` wrapping a `Container`:
- **Own reaction:** accent at 15% alpha background, accent at 40% alpha border, accent-colored count text at w600.
- **Others' reaction:** elevated background, border color, secondary count text at normal weight.
- Content: Row with emoji (14px) + SizedBox(3) + count (caption 11px).
- Border radius: 12px (fully rounded pill shape).

---

## MessageActionBar

**File:** `lib/src/ui/chat/message_action_bar.dart`
**Purpose:** Hover-triggered action overlay that appears on messages, plus inline message editing.

### MessageActionBarController

`ChangeNotifier` that coordinates action bar visibility across all messages. Only one message can show its action bar at a time.

- `claim(key, forceClose)` — takes ownership, closing any previously active bar.
- `release(key)` — releases ownership if this key is active.
- `dismissAll()` — force-dismisses the active overlay (used on scroll).

### MessageActionBarScope

`StatefulWidget` that provides the shared controller to the widget tree. Accessed via `MessageActionBarScope.of(context)`.

### MessageHoverWrapper

**Class:** `MessageHoverWrapper extends StatefulWidget`
**Purpose:** Wraps a message widget with hover-triggered overlays.

**Parameters:**

| Parameter | Type | Description |
|---|---|---|
| `child` | `Widget` | The message bubble widget |
| `isMe` | `bool` | Whether this is the current user's message |
| `messageId` | `String?` | Message ID for edit/delete operations |
| `currentText` | `String` | Current message text (for edit prefill) |
| `isEditing` | `bool` | Whether inline edit mode is active |
| `onEditStart` | `VoidCallback?` | Start editing |
| `onEditSubmit` | `void Function(String)?` | Submit edited text |
| `onEditCancel` | `VoidCallback?` | Cancel editing |
| `onDelete` | `VoidCallback?` | Delete message |
| `onReply` | `VoidCallback?` | Reply to message |
| `onReaction` | `void Function(String emoji)?` | Add reaction |
| `onPin` | `VoidCallback?` | Pin message |
| `onDownload` | `VoidCallback?` | Download file attachment |
| `onCopy` | `VoidCallback?` | Copy message text |
| `onCopyImage` | `VoidCallback?` | Copy image to clipboard |
| `onInfo` | `VoidCallback?` | Show message proof/info |

**Hover Behavior:**

1. Mouse enters message area: `_onMessageEnter()` claims the controller slot, shows overlays.
2. Mouse exits message area: starts 60ms dismiss timer.
3. Mouse enters action bar: cancels dismiss timer.
4. Mouse exits action bar: starts 60ms dismiss timer.
5. If neither message nor bar are hovered after 60ms, overlays are removed.

**Right-click:** If `onInfo` is provided, `GestureDetector.onSecondaryTap` triggers it (message proof dialog).

**Overlay Entries (two separate OverlayEntry instances):**

1. **Highlight overlay:** Positioned exactly over the message. `IgnorePointer` container with `textPrimary` at 3% alpha. Gives a subtle hover tint.

2. **Action bar overlay:** Vertically centered on the right side of the message. A floating `_ActionBarContent` widget.

Position calculation:
- `barTop = offset.dy + (size.height / 2) - 14` (center vertically)
- `barRight = screenWidth - (offset.dx + size.width) + HollowSpacing.md`

The action bar is only created if at least one action callback is non-null.

Every action button calls `_dismissNow()` first (removes overlays) then invokes its callback. This prevents stale overlay state.

### _ActionBarContent

Floating bar with elevated background, border, drop shadow (black 15%, blur 6, offset 0,2). Row of `HollowPressable` icon buttons (14px icons, 6px padding each):

| Button | Icon | Color | Condition |
|---|---|---|---|
| Download | `download` | accent | `onDownload != null` |
| Copy text | `copy` | secondary | `onCopy != null` |
| Copy image | `image` | secondary | `onCopyImage != null` |
| Emoji reaction | `smile` | secondary | `onReaction != null` |
| Reply | `reply` | secondary | `onReply != null` |
| Message proof | `shieldCheck` | secondary | `onInfo != null` |
| Pin | `pin` | secondary | `onPin != null` |
| Edit | `pencil` | secondary | `onEdit != null` |
| Delete | `trash2` | error | `onDelete != null` |

Buttons are conditionally included -- only those with non-null callbacks appear.

### _EmojiButton

Special button that captures its `RenderBox` global position and passes it to the reaction callback. The position is used to anchor the emoji picker overlay.

### Inline Edit Mode

When `isEditing` is true, `MessageHoverWrapper.build()` returns `_buildEditView()` instead of the hover wrapper.

**Edit view layout:**
- Container with `textPrimary` at 3% alpha background, md horizontal / xs vertical padding.
- `TextField` with `_editController`, maxLines 5, minLines 1, elevated fill color, accent-colored border (1.5px on focus).
- Helper text below: "escape to cancel . enter to save . shift+enter for new line" (10px muted).

**Edit key handling via FocusNode.onKeyEvent:**
- Escape: calls `onEditCancel`.
- Enter (no shift): submits if text changed and non-empty, otherwise cancels.
- Shift+Enter: inserts newline at cursor position.
- Tap outside (`onTapOutside`): cancels editing.

When entering edit mode (`didUpdateWidget`): dismisses any hover overlay, updates controller text, requests focus, moves cursor to end.

---

## MessageTextParser

**File:** `lib/src/ui/chat/message_text_parser.dart`
**Purpose:** Parses message text with lightweight markup into styled `InlineSpan` trees.

### MessageText Widget

**Class:** `MessageText extends StatelessWidget`

Parameters:
- `text` — raw message text
- `baseStyle` — optional override for base text style (defaults to `HollowTypography.body` with `textPrimary`)
- `suffixSpans` — optional list of `InlineSpan` appended after parsed content (used for "(edited)" suffix)
- `memberNames` — optional `Set<String>` for @mention highlighting

### Top-Level Builder

`buildMessageText(text, context, {baseStyle, suffixSpans, memberNames})` — convenience function that creates a `MessageText` widget.

### Code Block Handling

Checked first via `RegExp(r'```(\w*)\n?([\s\S]*?)```)`. If code blocks are present, `_buildWithCodeBlocks()` splits the text into segments:
- Text before/after/between code blocks: parsed via `_parseInline()`, rendered as `Text.rich`.
- Code blocks: full-width container with `background` color, 6px radius, border, 8px padding. Content in `HollowTypography.mono` at 13px.
- If only one child results, returns it directly. Otherwise wraps in a `Column`.

### Inline Parsing

`_parseInline(text, style, hollow, {depth, memberNames})`:

Recursion depth capped at 10 (returns plain `TextSpan` if exceeded).

Processing order (each character is checked against these patterns):

1. **URL detection:** If character is `h` or `H` and `_looksLikeUrlStart()` matches, tries `_inlineUrlRegex.matchAsPrefix()`. Regex: `(?:https?|hollow)://[^\s<>"')\]}]+`. Renders as `WidgetSpan` containing `MouseRegion(cursor: click)` + `GestureDetector(onTap: _openUrl)` + `Text` styled with accent color and underline. **Uses WidgetSpan + GestureDetector (not TextSpan)** to avoid the SelectionArea gesture stealing issue.

2. **@mention detection:** If character is `@`, checks for `@everyone` first, then longest-match against `memberNames`. Renders as `WidgetSpan` containing a `Container` with accent at 15% alpha background, 3px radius, 4px horizontal / 1px vertical padding. Text in accent color at w600 weight. **Also uses WidgetSpan + GestureDetector pattern.**

3. **Bold:** `**text**` -- recursively parses inner content with `fontWeight: w700`.

4. **Strikethrough:** `~~text~~` -- recursively parses inner content with `TextDecoration.lineThrough`.

5. **Spoiler:** `||text||` -- renders as `WidgetSpan` containing `_SpoilerText` widget.

6. **Inline code:** `` `code` `` -- renders as `WidgetSpan` containing a container with `background` color, 3px radius, border. Text in `HollowTypography.mono` at 13px.

7. **Italic (asterisk):** `*text*` (but not `**`) -- recursively parses with `fontStyle: italic`.

8. **Italic (underscore):** `_text_` -- only when underscore is at word boundary (preceded by space or start of string, followed by space or end of string). Prevents false matches inside URLs. Recursively parses with `fontStyle: italic`.

Unmatched characters are accumulated in a buffer and flushed as plain `TextSpan`.

### _SpoilerText

**Class:** `_SpoilerText extends StatefulWidget` (private)

Tap-to-reveal spoiler text. State toggles `_revealed`:
- **Hidden:** Background is `textSecondary` solid (opaque bar), text color is `transparent`.
- **Revealed:** Background is `elevated`, text color is `textPrimary`.
- `AnimatedContainer` with 200ms transition.
- Padding: 4px horizontal, 1px vertical, 3px radius.
- Tapping toggles between hidden and revealed.

### URL Opening

`_openUrl(url)` — parses URI, launches via `launchUrl(uri, mode: LaunchMode.externalApplication)`. Silently catches errors.

---

## Link Preview Cards

### LinkPreviewCard

**File:** `lib/src/ui/chat/link_preview_card.dart`
**Class:** `LinkPreviewCard extends StatelessWidget`
**Purpose:** Rendered link preview card inside sent messages. Shows metadata fetched by the sender.

**Privacy model:** Sender fetches the preview; receivers only see the cached data. Receivers NEVER make HTTP requests to previewed URLs (only when the user explicitly taps the card).

Takes a `network_api.LinkPreviewRef preview` containing: `url`, `title`, `description`, `domain`, `siteName`, `thumbWebpB64`.

**Layout:**
- `maxWidth: 400`, `HollowPressable` wrapper (tappable).
- Container: elevated background, `radiusMd` corners, accent 3px left border, border on other sides.
- Padding: `HollowSpacing.sm` all sides.
- Row:
  - Thumbnail (80x80, `radiusSm` clip, `BoxFit.cover`): decoded from base64 WebP. Returns `SizedBox.shrink()` if no thumbnail or decode fails. Uses `gaplessPlayback: true`.
  - SizedBox(sm)
  - Flexible Column:
    - Header line: "Site Name . domain" or just "domain" (caption, secondary, ellipsized)
    - Title (body, w600, primary, maxLines 2, ellipsized)
    - Description (caption, secondary, height 1.3, maxLines 3, ellipsized)

**Tap handler:** Opens the URL in the default browser via `launchUrl(uri, mode: externalApplication)`.

### StagedLinkPreviewCard

**File:** `lib/src/ui/chat/staged_link_preview_card.dart`
**Class:** `StagedLinkPreviewCard extends StatelessWidget`
**Purpose:** Compose-box preview shown above the input bar while the user types a URL.

**Parameters:** `url`, `preview` (nullable), `loading`, `onDismiss`.

**States:**
1. **Loading** (`preview == null && loading`): 48x48 elevated box with 18px spinner + "Loading preview..." title + URL subtitle.
2. **Loaded** (`preview != null`): 48x48 thumbnail (from base64 WebP, or link icon fallback) + title (from preview.title/siteName/domain) + subtitle ("Site Name . domain" or domain).
3. **Failed** (`preview == null && !loading`): Caller should not render this widget.

**Layout:** Surface background, top border. Row: thumbnail + sm gap + Column (title bold + subtitle muted) + dismiss X button.

### HollowLinkCard

**File:** `lib/src/ui/chat/hollow_link_card.dart`
**Class:** `HollowLinkCard extends ConsumerWidget`
**Purpose:** Renders inline cards for `hollow://` protocol links detected in message text.

Delegates to three sub-cards based on `link.type`:

#### _ShareLinkCard

- Icon: `share2` (20px, accent)
- If share already exists in `shareTabProvider`: shows filename, size, chunk count, "In shares" badge (success green).
- If not: shows "Hollow Share" title, "Click to download" subtitle, "Open" outline button.
- Tap opens `PasteLinkDialog` with the share URL pre-filled.

#### _ServerInviteCard

- Icon: `server` (20px, accent)
- If already joined (server exists in `serverListProvider`): shows server name, member/channel count, "Joined" badge.
- If not: shows "Server Invite" title, server ID in mono, filled "Join" button.
- Join calls `crdt_api.joinServer(serverId:)` and shows info toast.

#### _RoomInviteCard

- Icon: `messageCircle` (20px, accent)
- Shows "Room Invite" title, room ID in mono, filled "Join" button.
- Join calls `ref.read(roomProvider.notifier).join(link.fullUrl)`.

**Shared card container:** `_cardContainer()` — maxWidth 400, `HollowPressable` wrapper, elevated background, `radiusMd` corners, 3px accent left border, standard border on other sides, `HollowSpacing.sm` padding.

### StagedHollowLinkCard

**File:** `lib/src/ui/chat/staged_hollow_link_card.dart`
**Class:** `StagedHollowLinkCard extends ConsumerStatefulWidget`
**Purpose:** Compose-box preview for `hollow://` links detected while typing.

**Share link validation:** On init (and when URL changes), calls `share_api.shareDecodeLink(link:)` to validate. Sets `_shareValid = false` on failure.

**Display per link type:**
- **Share (valid, existing):** filename + size/chunks + "In your shares" (success)
- **Share (valid, new):** "Hollow Share" + "Valid share link"
- **Share (invalid):** "Invalid Share Link" (error) + "This link could not be decoded"
- **Server invite (joined):** server name + member count + "Already joined" (success)
- **Server invite (not joined):** "Server Invite" + "You haven't joined this server"
- **Room invite:** "Room Invite" + "Room: {id}"

Layout: 48x48 icon box (accent or error colored) + title/subtitle + dismiss X button.

### HollowLink Model & Extraction

**File:** `lib/src/ui/chat/hollow_link_utils.dart`

`HollowLink` data class: `type` (share/serverInvite/roomInvite), `fullUrl`, `id`.

`extractHollowLinks(text)`:
- Regex: `hollow://[^\s<>"')\]}]+`
- Deduplicates by URL.
- Parses URI scheme: must be `hollow`.
- `hollow://share/{payload}` -- share link (payload is the root hash + encoded data).
- `hollow://join?server={id}` -- server invite.
- `hollow://join?room={code}` -- room invite.

---

## EmojiPicker

**File:** `lib/src/ui/chat/emoji_picker.dart`
**Purpose:** Small overlay grid of ~30 curated reaction emojis.

### showEmojiPicker()

Top-level function: `showEmojiPicker({context, anchorPosition, onSelect})`.

Creates an `OverlayEntry` containing `_EmojiPickerOverlay`. Selecting an emoji or tapping outside removes and disposes the entry.

### _EmojiPickerOverlay

**Positioning:**
- Picker size: 280x220 pixels.
- Tries to position above the anchor, left-aligned (offset by `pickerWidth - 30` to the left).
- Clamped to screen edges (8px margin).
- If above doesn't fit (top < 8), positions below the anchor (+30px down).

**Layout:**
- Full-screen `GestureDetector` dismiss barrier (translucent hit test).
- Positioned picker: `Material(transparent)` wrapping a container with surface background, `radiusMd` corners, border, drop shadow (black 25%, blur 12, offset 0,4).
- `GridView.builder` with 6 columns, `HollowSpacing.sm` padding, 2px spacing.
- Each emoji cell: `HollowPressable` with `radiusSm`, 4px padding, centered text at 22px.

### Curated Emoji Set

`kReactionEmojis` constant list (~30 emojis): thumbs up, red heart, tears of joy, fire, clapping hands, party popper, heart eyes, thinking face, sunglasses, crying face, angry face, screaming face, hundred points, eyes, folded hands, check mark, cross mark, rocket, glowing star, gem stone, purple/blue/green heart, smiling faces, exploding head, partying face, clown, skull, poo.

---

## VoiceRecorderBar

**File:** `lib/src/ui/chat/voice_recorder_bar.dart`
**Class:** `VoiceRecorderBar extends ConsumerStatefulWidget`
**Purpose:** Inline bar shown in place of the chat input row while recording a voice message.

### Parameters

- `onFinished(VoiceRecordingResult result)` — called with the recording result when sent.
- `onCancelled()` — called when recording is discarded or fails.

### Constants

`kVoiceMessageMaxDuration` — 34 hours hard ceiling. Auto-sends when reached.

### Recording Lifecycle

1. `initState()` creates a `VoiceMessageRecorder` and a pulsing `AnimationController` (900ms, repeating reverse).
2. Post-frame callback calls `_start()`.
3. `_start()` reads `audioInputDeviceProvider` for preferred device ID, calls `_recorder.start(preferredDeviceId:)`.
4. Subscribes to `_recorder.amplitudes` (feeds waveform visualization) and `_recorder.elapsed` (feeds timer display).
5. Error handling: `RecorderPermissionException` shows "Microphone permission denied" toast. `RecorderFfmpegMissingException` shows "Voice encoder unavailable" toast. Other errors show generic failure toast. All call `onCancelled()`.

### Cancel Flow

`_cancel()`:
- Sets `_stopping = true`.
- Cancels stream subscriptions.
- Calls `_recorder.cancel()` (discards the file).
- Calls `onCancelled()`.

### Send Flow

`_send()`:
- Sets `_stopping = true`.
- Cancels stream subscriptions.
- Calls `_recorder.stop()` to get `VoiceRecordingResult`.
- If result is null, calls `onCancelled()`. Otherwise calls `onFinished(result)`.

### Dispose Safety

If widget is torn down mid-recording (not stopping), cancels the recorder then disposes. Prevents orphaned recording processes.

### Waveform Visualization

- `Queue<double> _waveform` holds up to 48 amplitude samples.
- New samples from `_recorder.amplitudes` are pushed onto the queue (FIFO, capped at 48).
- Rendered by `_WaveformPainter` (custom `CustomPainter`).

### _WaveformPainter

- Draws vertical bars (2px wide, `StrokeCap.round`).
- Bars are right-aligned (newest sample at far right, scrolls leftward).
- Amplitude clamped 0..1, with a 0.05 minimum for visibility of quiet speech.
- Bar height: `scaled * size.height * 0.9`.
- Color: theme accent.

### Layout

```
Row:
  HollowPressable (trash2 icon, error color) -- Cancel
  SizedBox(xs)
  Expanded Container (40px height, elevated, radiusLg):
    Row:
      FadeTransition (pulsing 0.35..1.0):
        Red dot (10x10 circle, error color)
      SizedBox(sm)
      SizedBox(width: 48):
        Elapsed timer (mono 13px, "mm:ss" or "h:mm:ss")
      SizedBox(sm)
      Expanded CustomPaint (_WaveformPainter)
  SizedBox(sm)
  HollowPressable (send icon, accent background, textOnAccent color) -- Send
```

The red recording dot pulses between 35% and 100% opacity on a 900ms cycle.

---

## Message Grouping Logic

Message grouping is not handled inside the bubble widgets themselves. The `showHeader` parameter is determined by the parent chat pane (e.g., `ChatPane`, `ChannelChatPane`). The standard grouping rule is: consecutive messages from the same sender within a short time window share a group. The first message in a group gets `showHeader: true` (avatar + name + timestamp), subsequent messages get `showHeader: false` (indented text only, padding reduced from 4px to 2px vertical).

---

## Key Integration Points

- **fileTransferProvider** — reactive download progress for all file types (audio, video, image, generic). Drives progress bars, phase text, and download-complete state transitions.
- **currentlyPlayingAudioProvider / currentlyPlayingVideoProvider** — global playback coordination. Starting one type stops the other. Only one audio and one video can play at a time.
- **profileProvider + serverNicknamesProvider** — name resolution for sender display names, @mention matching.
- **serverMembersProvider** — member list for @mention name set construction in channel messages.
- **shareTabProvider** — share state for "Keep & Seed" buttons and `HollowLinkCard` share status.
- **MessageActionBarScope** — inherited controller ensuring only one message's action bar is visible at a time. Parent should call `controller.dismissAll()` on scroll.
