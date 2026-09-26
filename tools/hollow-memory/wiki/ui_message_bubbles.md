# Message Bubbles and Chat Widgets

Covers every message rendering widget, action bar, text parser, link preview card, emoji picker, and voice recorder. All widgets live under `lib/src/ui/chat/`.

---

## MessageRow (the one message row, 2026-09-24)

**File:** `lib/src/ui/chat/message_row.dart`
**Class:** `MessageRow extends ConsumerWidget`

The only message row: DMs, channels, meetings, the guest view, the archive viewers and the phone all render through it. `MessageBubble` (`message_bubble.dart`, DM) and `ChannelMessageBubble` (`channel_message_bubble.dart`) are thin adapters that map their model's fields onto it and keep every call site unchanged. Before 2026-09-24 they were two ~90%-identical copies that had already drifted.

**Inputs:** `messageId`, `senderId` (raw, device or master), `isMe`, `text`, `timestamp`, `editedAt`, `replyToMid`, `reactions`, `fileAttachment`, `linkPreview`, `showHeader`; `serverId` (non-null makes it a channel row: sender resolved with the server nickname via `serverDisplayNameForPeer`, mentions against `serverMemberNamesProvider`, `ProfileTapTarget` gets the nickname + server); `replyToSenderId/Name/Text/ImagePath`, `isHighlighted`, `isMentioned` (both paint the 8% accent wash), `onReplyTap`, `onToggleReaction`, `tileWithPrev/Next` (sticker tiling), `album`.

**Sender:** always collapsed to the MASTER through `deviceLinkProvider.identityOf` (public channels store raw frame authors; old rows predate the Rust resolve).

**Name colour:** `nameColorFor(master, hollow)` (`core/color_utils.dart`): FNV-1a hash of the master id onto the hue circle minus 35 degrees either side of the CURRENT accent, tone raised to 7:1 on every dark surface / 5:1 on every light one. Your own name is `accentText`. No own-message strip any more (`OwnMessageMarker` and its test were deleted): the accent name is the mark.

**Cozy (default):** 36 px avatar, `md` 12 gap (`kMessageIndent` 48), name `body` 600 (`bodyTouch` on a phone), time `monoSmall` + tabular figures at `textTertiary`. A grouped continuation (`showHeader == false`) keeps the avatar column empty and shows its time there only while the row is hovered (`_HoverTime` reads `HoverScope`). Padding is on the ramp: header row `xs` top, `xxs` bottom; continuations `xxs`; tiled seams drop to 0.

**Compact** (`messageDisplayProvider == MessageDisplay.compact`, `core/providers/layout_provider.dart`, loaded in `_bootstrap`, set in Appearance on both platforms): one baseline-aligned row of time (40 wide, right-aligned mono), name (max 160, ellipsis) and the body column; every row repeats time and name; no avatars.

**Body column, in order:** reply line (one line: reply icon, the replied person's name in THEIR colour, the snippet, optional 16 px image; tappable to jump), message text via `buildMessageText` (" (edited)" suffix in caption/tertiary; file-only rows skip it), link preview card, up to three hollow-link cards, album or file card, `ReactionBar`.

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
- the honest-state caption from `fileCardStatus()` when the bytes are missing and Rust reported why (requesting / waiting / gone / expired); the play/download button then becomes a non-pressable circle (spinner when requesting, cloud-off otherwise)
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

`maxWidth: 280`, clipped with `Clip.antiAlias`, surface background, `radiusMd` corners, border.

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
- Centered `HollowSpinner.large(value:)` in white (over video).
- Phase text below spinner (vault phase from transfer state, or "Preparing video..." for vault, "Loading..." for P2P).

### Playing Mode

Delegates to `InlineVideoPlayer` (shared with `LinkPreviewCard`). The controller is owned by a `MediaPlaybackSession` (`lib/src/ui/media/media_playback_session.dart`, 2026-09-14): a holder SET (the bubble and the fullscreen view), the last release pauses and awaits `dispose()` exactly once, so the bubble can scroll out of the list and die while the view is still up. Only ONE `VideoPlayer` widget is attached to the controller at a time (two on one controller double-render through fvp on Windows): while `session.viewerHolds` the bubble draws its poster layer plus a 55% black dim instead of the player. The `currentlyPlaying*` listeners and the visibility auto-pause are both no-ops while the viewer holds.

### Fullscreen (2026-09-14, superseded by the media viewer)

`_FullscreenVideoView`/`fullscreenVideoRoute` are GONE (`test/media_viewer_guard_test.dart` keeps them gone). The inline control bar's "Enter fullscreen" button (and `_onPlayTapped(fullscreen: true)`) now calls `_openFullscreen(session)`, which hands the SAME live `MediaPlaybackSession` to `openMediaViewer(context, MediaItem(..., session: session), enterFullscreen: true)` (`lib/src/ui/media/media_viewer_route.dart`). `session.attachViewer()` is called before the push so the bubble draws its poster instead of a second `VideoPlayer` on the same controller while the viewer is up (two on one controller double-render through fvp on Windows); `session.releaseViewer()` + `restoreAppOrientation()` run in the push's `.then()`. Position and play state survive both ways because the controller itself is never disposed for the handoff. Full fullscreen-ownership rules (why `enterFullscreen: true` couples leaving the OS fullscreen to closing the viewer, and how a walked-to video differs) live in wiki `ui_media_viewer.md`.

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

### InlineVideoPlayer

**Class:** `InlineVideoPlayer extends StatefulWidget` (public, same file; state class `InlineVideoPlayerState`, un-privatised for `LinkPreviewCard` in #45)

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

**Class:** `_ControlBar extends StatelessWidget` (private to `video_message_bubble.dart`; shared with `LinkPreviewCard`'s inline video via `InlineVideoPlayer`, `onFullscreen` optional and null for a card)

One even row, rebuilt 2026-09-14 alongside the media viewer's own transport (Vitalik's first test of the viewer found a control bar buried under the viewer's chrome, so the bubble's own bar got the same treatment for consistency):

```
Container (gradient: transparent -> black 75%)
  LayoutBuilder > Row:
    _IconBtn (play/pause)
    SizedBox(xs)
    [only when width >= _timeFloor (220px): Text "{position} / {duration}" (caption 11px, tabular figures, white) + SizedBox(xs)]
    Expanded > SliderTheme (trackHeight 3, thumb 6px, accent color) > Slider (position ms, clamped 0..duration)
    SizedBox(xs)
    VerticalVolumePopover (mute icon, vertical slider on hover; shared with the media viewer's MediaVideoControls, `media_viewer_controls.dart`)
    [only when onFullscreen != null: SizedBox(xs) + _IconBtn (maximize2 or minimize2, depending on isFullscreen)]
```

Time format: `m:ss` via `formatMediaDuration` (`media_viewer_controls.dart`).

### Fullscreen dialog: gone

`_FullscreenVideoView` is gone (2026-09-14, see "Fullscreen" above). What used to be a `showHollowDialog()` video dialog is now the shared media viewer route; full detail (ownership rules, the transport, `VerticalVolumePopover`) lives in wiki `ui_media_viewer.md`.

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

## AlbumBubble

**File:** `lib/src/ui/chat/album_bubble.dart` (grouping itself lives in `lib/src/core/album_grouping.dart`)
**Class:** `AlbumBubble extends StatelessWidget`, built from `List<AlbumItem>` (`{attachment, messageId, senderId (master), timestampMs, isMine, text}`, via `dmAlbumItems` / `channelAlbumItems`, which skip rows that lost their file).

- **Album model:** 1 to 10 ordinary messages sharing a signed `album` id (hyphenated UUID); `collapseAlbums` groups by sender AND album id (nobody can graft into another sender's album), only live file rows group, a group with one loaded item stays a plain message, and a run past `kMaxAlbumItems` starts a second group. Panes fold each group into its EARLIEST item.
- **Mosaic** (max width 320, 2 px gap) for images and videos: 2 side by side, 3 = one large left plus two stacked, 4 = 2x2 grid, 5 = 2 over 3, 6+ = 3 over 3 with a "+N" overlay on the sixth cell. A single media item renders as a normal cell. Non-media items (files, sticker packs) stack underneath.
- **Cells** are the ordinary `FileAttachmentWidget(tileSize:)` (which forwards `tileSize` to `VideoMessageBubble`): tight box, `BoxFit.cover`, and each keeps its own honest download state, progress, and media-viewer open.
- **"Download all (N)" chip** (`_DownloadAllChip`): shown once two or more items are not complete, not expired and not already downloading; watches only the COUNT (the transfer map is replaced on every chunk) and calls the top-level `startManualAttachmentDownload(context, ref, attachment)` for each.
- **`confirmDeleteAlbum(context, count)`**: the bubble's delete confirmation, which deletes every item; per-item delete stays in the media viewer.

## FileAttachmentWidget

**File:** `lib/src/ui/chat/file_attachment_widget.dart`
**Class:** `FileAttachmentWidget extends ConsumerWidget`
**Purpose:** Router widget that inspects the attachment type and delegates to the appropriate specialized bubble or renders an image preview / generic file card.

### Constructor Parameters (2026-09-14)

`tileSize: Size?` (album mosaic cell: fixed box, cover fit, forwarded to `VideoMessageBubble`). Four optional params, all forwarded straight through to `VideoMessageBubble` and into the `MediaItem` the image preview opens: `messageId`, `senderId`, `timestampMs` (all `String?`/`int?`), `isMine` (`bool`, default false). Absent wherever an attachment has no owning message (a link-card thumbnail, for instance). This is what lets the media viewer act on the message (reply, jump to it, delete, react) and walk the conversation's other media from whichever bubble it was opened from; see wiki `ui_media_viewer.md`.

### Delegation Logic

1. If `attachment.isExpired` -- renders expired card.
2. If share-backed with no seeders and no chunks received -- renders unavailable card.
3. If `_isVideoAttachment()` -- delegates to `VideoMessageBubble`.
4. If `_isAudioAttachment()` -- delegates to `AudioMessageBubble`.

A manual download (placeholder tap, album chip) goes through the top-level `startManualAttachmentDownload(context, ref, attachment)` in the same file: share-backed files rejoin their swarm via the persisted share ref, a public-channel guest uses `RequestPublicFile`, everything else a FileRequest.
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
- `maxWidth: 280`, surface background, border, `radiusMd` corners.
- Row: `clock` icon (24px, secondary) + Column: fileName (secondary 13px, ellipsized) + "File expired . {formattedSize}" (italic caption).

### Manual Download (issue #41)

`_startManualDownload(context, ref)` — the pressable-placeholder twin of the hover-bar Download button. Self-contained: resolves the conversation from the file's own metadata row (`getFileMetadata`), calls `clearDeclined` first, then routes:
- share-backed (persisted `shareRootHash`/`shareKeyHex` on the attachment / metadata row) → `EventStreamNotifier.startManualShareDownload`;
- channel where we're NOT a member (guest public channel) → `crdt_api.requestPublicFile(peerHint: senderId)`;
- otherwise → `requestFileFromPeer` (DM: contextId master; channel: senderId — Rust reroutes to another holder when offline).
Toasts: info on request, error on failure.

### Unavailable Card (No Seeders)

`_buildUnavailableCard(hollow, onDownload)`:
- Same layout as expired card but with `cloudOff` icon and "No seeders . tap to retry . {formattedSize}" text; whole card is a `HollowPressable` that retries via `_startManualDownload`.

### Image Preview

`_buildImagePreview(...)`:
- Max dimensions: 300x250.
- Aspect-ratio-preserving size calculation from `attachment.width`/`attachment.height`.
- **Complete with file on disk (2026-09-14):** tap opens the media viewer. `open()` calls `openMediaViewer(context, _mediaItem().withDiskPath(diskPath))` (`lib/src/ui/media/media_viewer_route.dart`), where `_mediaItem()` builds a `MediaItem` from `attachment` plus the widget's `messageId`/`senderId`/`timestampMs`/`isMine`. `.withDiskPath(diskPath)` matters because the stored row may not carry a disk path yet, so the bubble opens on the path it just resolved. Wrapped in `HollowFocusRing` + `GestureDetector` + `MouseRegion(cursor: click)` around a `ConstrainedBox` > `ClipRRect(radiusMd)` > `AttachmentImage`.
- **Downloading:** Placeholder with `HollowSpinner.large(value:)` (determinate if progress > 0), status text below.
- **Partial progress (not downloading):** Placeholder with 80px `LinearProgressIndicator` and percentage text.
- **Idle / not downloaded (issue #41):** PRESSABLE placeholder — sized box with a circular download button (44px, `download` icon), plus a media-type icon (`image`/`video`, 12px) next to formattedSize. Tap = `_startManualDownload`. Falls back to the static icon-only box when no download hook (error-builder path).

### Fullscreen image dialog: gone

`_FullscreenImageView` is gone (2026-09-14, superseded by the media viewer route above; `test/media_viewer_guard_test.dart` keeps it gone). Full detail on the viewer this tap now opens (zoom, walking the conversation, info panel, shortcuts) lives in wiki `ui_media_viewer.md`.

### Generic File Card

`_buildFileCard(...)`:
- `maxWidth: 280`, surface background, border, `radiusMd` corners.
- Row: file-type icon (28px, accent) + Column: fileName (body 13px w500, ellipsized) + status text (caption 11px, secondary) + trailing download icon button (18px `HollowPressable`) when not complete/downloading (issue #41).
- Status text priority: vault phase > downloading with bytes > downloading > `"{formattedSize} · .{ext}"` (extension repeated because the name column ellipsizes).
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

**File:** `lib/src/ui/chat/reaction_bar.dart`. One `HollowChip` per reaction (emoji or emote as `leading`, the count as the label), sorted by count then insertion. Yours is the SELECTED chip (accent-muted fill, accent text, weight unchanged). `onToggleReaction == null` renders them inert (read-only surfaces). Since 2026-09-24; before that a hand-built pill with a pill radius and a weight change.

---

## MessageActionBar

**File:** `lib/src/ui/chat/message_action_bar.dart`. The hover highlight, the hover bar, the message menu and inline edit, for every surface that wraps rows in `MessageHoverWrapper` (DM, channel, guest, archive viewers).

### MessageActionBarController / MessageActionBarScope

Only one row shows its bar at a time: `claim(key, forceClose)` closes the previous owner, `release(key)`. `dismissAll()` still exists but the panes no longer call it on scroll (see below).

### Hover (rebuilt 2026-09-24)

The old version inserted a highlight OverlayEntry and a bar OverlayEntry at the row's position measured on hover, so any scroll stranded them over the wrong message, and each pane hid it by calling `dismissAll()` on every ScrollUpdate. Now:

- **Highlight:** painted by the row itself, a `DecoratedBox` behind the message driven by `_highlighted` (row hovered OR bar hovered), colour `hollow.rowHover` (half a step from canvas to `elevated`, so a card inside the row still shows). No layout change, scrolls with the row.
- **Bar:** an OverlayEntry of `Positioned.fromRect(list viewport, extended up by half the bar) > ClipRect > Stack > CompositedTransformFollower(link: the row's LayerLink, targetAnchor: centerRight, followerAnchor: centerRight, offset -16)`. It is centred vertically on its row, so the pointer reaches it without crossing into the row above and losing the hover; the compositor carries it with the row. The half-bar extension above the list keeps a compact top row's bar from being cut. The theme is read from the ENTRY's context so a theme switch repaints it.
- **Handoff:** row exit starts a 60 ms timer; entering the bar cancels it (overlay regions are opaque, so the row always sees the exit first). A scroll under a still pointer moves the hover to the next row by itself (MouseTracker re-hit-tests after frames).
- Pinned by `test/widget/message_hover_test.dart`.

### The bar (`_ActionBarContent`, 32 px, `overlay` + hairline + `HollowShadows.float`)

Three quick reactions (`kQuickReactionEmojis[0..2]`), a hairline, Add reaction (opens the full picker anchored to the button), Reply, Edit (own messages only), More. Each is a `_BarButton` (24 px square inside the 32 bar, 16 px icon, tooltip + semantic label). Download, copy, pin, proof and delete moved OFF the bar into the menu. More opens the menu leftward from the button (`alignEnd`).

### The message menu (right click or More)

Built from the wrapper's callbacks, so a row never offers an action its surface did not wire: quick-reaction strip + Add reaction | Reply | Copy text, Copy image, the file action (mirrors the card via `fileBarAction()`: Download / Try again / Stop waiting), Pin or Unpin, Edit | Message proof, Copy message ID | Delete (danger, LAST since 2026-09-24).

### Inline edit

`_buildEditView`: a TextField on `elevated` with the hairline border (accent when focused), caption hint "Enter to save, Escape to cancel, Shift+Enter for a new line" in `textTertiary`. Keys via the FocusNode: Escape cancels, Enter submits if changed, Shift+Enter inserts a newline; tap outside cancels.

### Focus

On desktop a click outside a TextField drops its focus (Flutter's default `onTapOutside`), so the panes' `_toggleReaction` hands focus back to the composer after a reaction (not while editing). See memory `feedback_desktop_tap_outside_unfocus`.

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

2. **Custom emote token:** If character is `[`, tries `emoteTokenRegex.matchAsPrefix()` (`\[e:([a-z0-9_]{2,24}):([0-9a-f]{64})\]` from `emote_image.dart`). Produces `_TokenKind.customEmote` (text = name, `extra` = hash), rendered as a middle-aligned `WidgetSpan` `EmoteImage` sized `fontSize * 1.45` with a `:name:` text fallback while bytes load. Unknown hashes trigger a network pull via the surrounding `EmoteScope` (serverId/peerHint).

3. **@mention detection:** If character is `@`, checks for `@everyone` first, then longest-match against `memberNames`. Renders as `WidgetSpan` containing a `Container` with accent at 15% alpha background, 3px radius, 4px horizontal / 1px vertical padding. Text in accent color at w600 weight. **Also uses WidgetSpan + GestureDetector pattern.**

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
**Class:** `LinkPreviewCard extends ConsumerStatefulWidget`
**Purpose:** Rendered link preview card inside sent messages. Shows metadata fetched by the sender.

Takes `preview` (`network_api.LinkPreviewRef`) plus an optional `messageId`, passed from `message_bubble.dart` / `channel_message_bubble.dart` and used only to key the single-playback slot.

**Privacy model:** Sender fetches the preview; receivers only see data that travelled with the message. Receivers NEVER make an HTTP request to RENDER a card. The one exception is tapping play on an inline video (below) — an explicit gesture, same trust as clicking through.

**Two layouts, chosen by the sender via `preview.kind` (issue #45):**

*Compact* (`kind == null`) — the original row. 80x80 thumb left, title maxLines 2, description maxLines 3.

*Large* (`kind == "large"`) — image on top, then header, then the **author** line as heading when present (falling back to title), then description at **maxLines 6** because a post's body is the point of the card. Emitted by the social adapters AND by any page that declares a big card — see `rust_networking.md` § link_preview.rs.

Both layouts always show the header line ("Site Name · domain"), so a card sourced from a post still states where a tap goes.

**Media is CONTAINED, not stretched (`_maxMediaHeight = 360`).** The image used to span the full card width at the sender's aspect, which reads fine at 16:9 (~225px tall) and made a 9:16 reel poster a ~670px monolith — aspect alone does not bound height once width is fixed. `_buildWideImage` now fits the poster into `cardWidth × _maxMediaHeight`: landscape still spans the card, portrait gives up WIDTH and is inset + rounded (square corners flush against the card's rounded top read as a clipping bug). Nothing is cropped — the `AspectRatio` box matches the source, so `BoxFit.cover` has nothing to cut, which matters for a widget whose job is to preview. Same fit rule as `video_message_bubble.dart::_resolveDisplaySize`. The `thumbW/thumbH` clamp (0.6–2.4) survives but now floors WIDTH: an unclamped 1:8 banner would contain down to a 45px sliver.

Verified visually by `test/screenshots/link_preview_card_screenshot_test.dart` — see `feedback_ui_screenshot_harness`.

**Inline video (issue #45):**
- `isDirectPlayableVideo(url)` (top-level, exported for tests) gates it: scheme must be http(s) AND the path must end in `.mp4/.webm/.m4v/.mov`. True → inline play; false → external-open glyph. This is what separates X (FxEmbed returns a real mp4) from YouTube (no direct URL exists — signed DASH segments).
- State machine mirrors `VideoMessageBubble`: poster → preparing → playing, `currentlyPlayingVideoProvider` for one-video-at-a-time, `currentlyPlayingAudioProvider` stand-down, `VisibilityDetector` pause on scroll-away, pause-then-null-then-dispose.
- Reuses `InlineVideoPlayer` from `video_message_bubble.dart` (un-privatised for this; `onFullscreen` is optional and cards pass null — the fullscreen viewer takes a disk path).
- **The whole poster is the tap target**, `HitTestBehavior.opaque`, so it swallows the tap before the card's open-in-browser handler sees it. The glyph is decoration. A small centred button meant missing it threw you out to the browser.
- Card taps are inert while playing. A failed `initialize()` falls back to opening the browser rather than leaving a spinner.

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
**Purpose:** Renders inline cards for `hollow://` protocol links (and web-form `https://hollow.anonlisten.com/join#server=` invites, normalized by the extractor) detected in message text.

Delegates to four sub-cards based on `link.type`:

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

#### _RecoveryLinkCard

- Icon: `lifeBuoy` (20px, accent)
- Shows "Recovery Pool Invite" title, server ID in mono, filled "Open" button.
- Tap opens `showJoinRecoveryPoolDialog(context, prefillLink: link.fullUrl)` (recovery links were paste-only before 2026-07-11).

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
- **Recovery:** "Recovery Pool Invite" + "Server: {id}"

Layout: 48x48 icon box (accent or error colored) + title/subtitle + dismiss X button.

### HollowLink Model & Extraction

**File:** `lib/src/ui/chat/hollow_link_utils.dart`

`HollowLink` data class: `type` (share/serverInvite/roomInvite/recovery), `fullUrl` (always the CANONICAL `hollow://` form — web-form https links are normalized), `id`.

`classifyHollowLink(url)` — single-URL classifier (also used by `DeepLinkService` for OS-delivered links):
- `hollow://share/{payload}` -- share link (payload is the root hash + encoded data).
- `hollow://join?server={id}` -- server invite.
- `hollow://join?room={code}` -- room invite.
- `hollow://recovery?server={id}&token={t}` -- recovery pool invite (both params required).
- `https://hollow.anonlisten.com/join#server={id}` (fragment canonical, `?server=` query tolerated; fragment wins) -- normalized to `hollow://join?server=` in `fullUrl`. Id validated `^[A-Za-z0-9_-]{1,128}$`. Same for `#room=`.

`extractHollowLinks(text)`:
- Two regexes: `hollow://[^\s<>"')\]}]+` + `https://hollow\.anonlisten\.com/join[^\s<>"')\]}]*`; each match through `classifyHollowLink`.
- Deduplicates by canonical `fullUrl` (same invite in both forms → one card).

`mightContainHollowLinks(text)` — cheap per-bubble gate (matches `hollow://` OR `hollow.anonlisten.com/join`); both message bubbles use it before running the extractor.

`webServerInviteLink(serverId)` → `https://hollow.anonlisten.com/join#server={id}` — what all Invite buttons copy since 2026-07-11 (fragment keeps the id out of web-server logs; old clients degrade to a clickable https link → browser → /join redirect page → app). Deep-link ingestion itself (OS `hollow://` launches, `app_links`, per-platform registration) lives in `DeepLinkService` — see memory `project_deep_linking`.

Unit tests: `test/hollow_link_utils_test.dart`.

---

## EmojiPicker (unified picker)

**File:** `lib/src/ui/chat/emoji_picker.dart`
**Purpose:** The unified emoji/emote picker — full Unicode set + custom emote tabs. Used for reactions AND composer insertion, desktop overlay + mobile bottom sheets.

### showEmojiPicker()

Top-level function: `showEmojiPicker({context, anchorPosition, onSelect, serverId})`.

Creates an `OverlayEntry` (360x440, anchor-clamped) with a dismiss barrier hosting `EmojiPickerBody` on a `radiusLg` card with `HollowShadows.float`. It enters through `PopupAnimator(rise: true)`: a fade and an 8 px rise toward its anchor, not a scale (the GIF and sticker pickers do the same). `onSelect` receives either a Unicode emoji OR a custom-emote wire token `[e:name:hash]` — callers treat both as opaque strings. Teardown goes through ONE `removed`-guarded closure: a rapid double-tap fires onSelect twice before the removal frame builds out, and a second `entry.remove()` crashes (see memory `feedback_textfield_overlay_selectioncontrols`; regression tests in `test/widget/emoji_picker_crash_test.dart`).

### EmojiPickerBody (public, reusable)

`EmojiPickerBody({serverId, onSelect})` — the tabbed body, embedded by the expression picker's Emoji tab (both platforms) and the mobile long-press sheet's reactions view.

- **Search field** (HollowTextField, isDense, autofocus) filters the active tab; on the FFZ tab it drives a 350ms-debounced endpoint search.
- **Tabs:** `Emoji` (Unicode; recents removable via right-click/long-press context menu) / `Server` (only when `serverId != null`; from `serverEmotesProvider`) / `Mine` (personal set + Upload emote button; remove via right-click/long-press context menu — a topmost OverlayEntry, NOT showDialog, which renders behind the picker) / `FFZ` (default = curated popular list via proxy `curated=1`, global-sets fallback; tap = `ffzImportEmote` → add to personal set → insert token).
- Every selection routes through `_select` → `_recordRecentEmoji` (persisted in app_settings key `recent_emojis`, cap 24, cached in-memory).

### Unicode data

`lib/src/ui/chat/emoji_data.dart` — GENERATED (1,907 fully-qualified emojis, skin-tone variants excluded) from Unicode emoji-test.txt v16 via a Dart script (never awk — `tolower()` corrupts multibyte names). `kUnicodeEmojiGroups: Map<String, List<UnicodeEmoji>>` in CLDR order. `_UnicodeGrid` renders lazily by ROW (8 columns, header entries between groups); search matches on lowercase CLDR names, capped at 160 results.

### Quick reactions

`kQuickReactionEmojis` (8 entries) — the mobile long-press quick row. The old ~30-emoji `kReactionEmojis` list is GONE.

---

## ExpressionPicker (2026-09-24)

**File:** `lib/src/ui/chat/expression_picker.dart`. The composer's ONE picker for emoji, GIFs and stickers, replacing three composer buttons. `showExpressionPicker()` (desktop Overlay host, 360 x 440, above its button, flips below when there is no room, steps aside via `hidden` while an emoji-tab dialog runs, #76; enters through `PopupAnimator(rise: true)`, fading and rising 8 px from its button side rather than scaling). The tabs themselves are the public `ExpressionPanel`, which the phone places in the keyboard's slot under its composer (`MobileKeyboardPanelDock`, wiki ui_mobile); there is no sheet. Tabs Emoji / GIFs / Stickers as the shared `HollowTabBar` (2 px accent bar under the open one, 48 tall on touch); each tab is the existing body (`EmojiPickerBody`, `GifPickerBody`, `StickerPickerBody`) and ONLY the open tab is built, so the GIF tab never calls the proxy unless opened. The last tab is remembered for the run. On desktop an emoji inserts and closes; on the phone the panel stays open for the next emoji. A GIF or sticker SENDS and the picker stays open (#36); sharing a pack closes it. The emoji body's first chip is "Standard" (was "Emoji", which repeated the tab).

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

The red recording dot pulses between 35% and 100% opacity on a 900ms cycle; under Reduce motion it holds solid, switching live with `ReduceMotionController.effective`.

---

## Message Grouping Logic

Message grouping is not handled inside the bubble widgets themselves. The `showHeader` parameter is determined by the parent chat pane (e.g., `ChatPane`, `ChannelChatPane`). The standard grouping rule is: consecutive messages from the same sender within a short time window share a group. The first message in a group gets `showHeader: true` (avatar + name + timestamp), subsequent messages get `showHeader: false` (indented text only, padding reduced from 4px to 2px vertical).

### Sticker tiling (`tileWithPrev` / `tileWithNext`, asset-rail Phase 5)

Both bubbles take two more flags from the pane, decided the same way `showHeader` is. When this row AND its neighbour are both nothing-but-a-sticker-run (`stickerTileCandidate` — and carrying no reply, reaction, file or edit marker that would sit in the seam) AND already grouped, the seam between them is drawn CONTINUOUS: the row padding goes to 0 on that side, the block asset drops its own padding to match, and `stickerRunRadius` squares the corners there. Three stickers sent one after another become one tall image — the point of a multi-part pack. Both flags default false, so every other message renders exactly as before. Decided by `stickerTilingFor` in `chat_pane_shared.dart`; full map in wiki `emotes.md` > "Sticker Mosaics".

---

## Key Integration Points

- **fileTransferProvider** — reactive download progress for all file types (audio, video, image, generic). Drives progress bars, phase text, and download-complete state transitions.
- **currentlyPlayingAudioProvider / currentlyPlayingVideoProvider** — global playback coordination. Starting one type stops the other. Only one audio and one video can play at a time.
- **profileProvider + serverNicknamesProvider** — name resolution for sender display names, @mention matching.
- **serverMembersProvider** — member list for @mention name set construction in channel messages.
- **shareTabProvider** — share state for "Keep & Seed" buttons and `HollowLinkCard` share status.
- **MessageActionBarScope** — inherited controller ensuring only one message's action bar is visible at a time. No dismissal on scroll: the bar follows its row through a LayerLink.
