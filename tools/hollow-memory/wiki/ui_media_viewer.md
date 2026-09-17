# Media Viewer

**Files:** `lib/src/ui/media/` (route, `media_item.dart`, `media_viewer_scope.dart`, `media_zoom_math.dart`, `media_zoom_view.dart`, `media_video_page.dart`, `media_viewer_controls.dart`, `media_strip.dart`, `media_info_panel.dart`, `media_playback_session.dart`, `fullscreen_media_chrome.dart`).
**Rust:** `rust/hollow_core/src/storage/messages.rs` (`list_media_for_context`), `rust/hollow_core/src/api/storage.rs` (`MediaListItem`, FFI wrapper).
**Status:** Part B phase 1 shipped 2026-09-14; Part C (albums, `ui_chat_dm.md` / `ui_message_bubbles.md`) shipped 2026-09-17: an album tile opens this viewer like any attachment, and per-item delete stays here. Phase 3 (eyedropper, annotate-and-send-back, media tab, frame step, copy frame) and Part D (subtitles) are planned: `reports/planned/voice-and-media/MEDIA_VIEWER_ALBUMS_SUBTITLES_PLAN.md`.

One route replaces the old `_FullscreenImageView` dialog (`file_attachment_widget.dart`) and `_FullscreenVideoView` dialog (`video_message_bubble.dart`) for images, GIFs and video. `test/media_viewer_guard_test.dart` keeps both gone.

---

## The route

`openMediaViewer(context, item, {enterFullscreen})` (`media_viewer_route.dart`) is the one entry point every bubble calls. It reads `MediaViewerScope.maybeOf(context)` **before** pushing, then hands the scope's `mediaContext` and `actions` into `mediaViewerRoute(...)`. This has to happen at the call site rather than inside `MediaViewerView.build()`: the viewer is a pushed route, built under the Navigator, so it sits outside the `InheritedWidget` tree the bubble that opened it lives in.

`mediaViewerRoute({item, mediaContext, actions, enterFullscreen})` picks the transport: `hollowMobileRoute` (fade) on `isMobileMediaPlatform` (Android/iOS), otherwise an opaque, `fullscreenDialog: true` `PageRouteBuilder` with a 150 ms fade (skipped under `ReduceMotionController`). Opaque and full-bleed on purpose: a dialog's blur barrier and inset box are wrong for a viewer that needs to go edge to edge with nothing behind a video.

`MediaViewerView` (`ConsumerStatefulWidget`, mixes in `FullscreenMediaChrome`) owns:
- `_items: List<MediaItem>` and a `PageController`, starting as `[widget.item]` and filled out by `_loadAround()` after first frame.
- One shared `TransformationController` for zoom, read by the zoom view, the readout and the keyboard handler.
- The keyboard handler: a `HardwareKeyboard.instance` handler, not a `Shortcuts` binding, because an opaque page route has no barrier and focus may already sit on a child control. Guarded by `ModalRoute.of(context)?.isCurrent` and `keybindCaptureActiveProvider`.
- `OverlayHosts.register(this, _dismiss)` in `initState`, unregistered in `dispose`, so App Lock's cover clears the viewer before it covers the screen.
- A `[SENTINEL] media viewer open <ms>` emit at first frame (tap to first paint) and `[SENTINEL] media viewer preload n=<count> <ms>` from `_precacheNeighbours()`.

---

## MediaItem, MediaContext, MediaLibrary

`media_item.dart`:

- **`MediaKind`**: `image | gif | video`. `MediaItem.kind` checks `attachment.videoThumb != null` FIRST (a vault video's own row is its WebP poster, so the extension would say "image" otherwise), then `.gif` extension, then `kMediaVideoExtensions` (`mp4/webm/mov/mkv/avi/m4v`, mirrored in Rust as `MEDIA_VIDEO_EXTS`; keep both lists in sync).
- **`MediaContext`**: `{contextType, contextId}` (`dm` / peer master id, or `channel` / `{serverId}:{channelId}`), the conversation a viewer may walk. Absent for an archive, which has nothing to page through.
- **`MediaItem`**: `{attachment, messageId, senderId, timestampMs, contentId, isMine, session}`. `contentId` (the content hash) is only ever populated on a row that came back from `list_media_for_context`: the item the bubble handed over does not carry one until `_loadAround()` merges it in via `withContentId`. `session` is a live `MediaPlaybackSession` handed over by the bubble that opened the viewer (null for a walked item, which opens its own).
- **`MediaLibrary.page({contextType, contextId, beforeMs, afterMs, limit})`**: thin wrapper over `storage_api.listMediaForContext`, overridable via `MediaLibrary.debugLoader` for widget tests with no FFI. `beforeMs`/`afterMs` are exclusive bounds.

**Paging in the route:** `_loadAround()` fires two `MediaLibrary.page` calls in parallel (`beforeMs: ts + 1` and `afterMs: ts`), each capped at `_kPageSize = 40`, reverses both (rows arrive newest-first, the viewer reads left to right in time), and merges them around the opened item. If the opened item is not in either page (its own hash is absent from the merge match on `fileId`) it is inserted at the seam; otherwise the merged row's `contentId` is copied onto the live item so the bubble's handed-over `MediaItem` (which carries the session) keeps its position. `_loadMore({older})` fires when the page index comes within `_kPrefetchMargin = 3` of either end, tracked by `_endOlder`/`_endNewer` so an exhausted end never re-queries.

---

## MediaViewerScope

`media_viewer_scope.dart`: an `InheritedWidget` published by each pane (`chat_pane.dart`, `channel_chat_pane.dart`, `mobile_chat_route.dart`, and the four archive viewers) wrapping its message list. Carries a nullable `MediaContext` and a `MediaViewerActions` (`onReply`, `onJumpTo`, `onDelete`, `onReact`, `onSaveAs`: each nullable, so a host offers only what it can do). `maybeOf(context)` does **not** register a dependency: it is read once in a tap handler, not watched, because a dependency would rebuild every bubble whenever the host rebuilds.

The three chat panes wire all five actions (`_mediaActions()` in each). The four archive viewers wire only `onSaveAs`: archives are read-only, so reply/jump/delete/react are absent rather than disabled; the viewer's `_actionSpecs()` omits an action outright when its callback is null instead of rendering it greyed out.

`_delete()` is the one place that confirms a single media item's delete: none of the three panes ask on their own, since the viewer is the only surface reachable from all of them (an album BUBBLE's delete is the other confirm, `confirmDeleteAlbum`, and removes every item). On success with more than one item left, the viewer removes the deleted item from `_items` and advances rather than closing.

---

## The zoom view

`media_zoom_view.dart` wraps a `flutter` `InteractiveViewer`: no custom pan/zoom math. The mouse wheel already zooms about the pointer through `InteractiveViewer`'s own handling; only a **trackpad pan** needed help (below).

### Actual-size math and the pixel ratio trap

`media_zoom_math.dart::actualScale({imagePixelWidth, fitLogicalWidth, devicePixelRatio, uiScale})` is the scale at which one image pixel covers one **device** pixel. The route calls it with `uiScale: 1.0` always: inside `UiScale` (`project_display_scaling`), `MediaQuery.devicePixelRatioOf(context)` has **already** been multiplied by the interface zoom (`UiScaleBox` does that multiplication), so passing a separate `uiScale` factor on top would double-count the zoom. This was the plan's original design and was corrected during the build.

`minScaleFor(actualScale) = min(1.0, actualScale)`: not a flat `1.0` floor. On a display scaled past 100%, a small image is already drawn LARGER than its own pixels at fit, so a floor of exactly fit would put actual size (100%) out of reach of the `1` key going the other direction. `maxScaleFor(actualScale) = max(8.0, actualScale * 2)` so a thumbnail-sized image can still reach its own pixels. `zoomPercent()` is `currentScale / actualScale * 100`: the readout is honest about "100% = pixel-exact", not "100% = fit".

### Crisp pixels

A toolbar toggle (`mediaViewerCrispPixels`, `@visibleForTesting` top-level bool in `media_viewer_route.dart`), on by default, remembered for the **process only** (never persisted: it is a viewing preference, not a setting). `MediaZoomMath.filterQualityFor({currentScale, actualScale, crisp})` buckets into three `FilterQuality` values: `none` from twice actual size upward when crisp is on, `high` at and above actual, `medium` below actual. `_onTransform()` in the route only calls `setState` when the **bucket** changes, not on every transform tick, so the image rebuilds far less often than the readout updates.

### Trackpad pinch re-anchoring

`_MediaZoomViewState` tracks `PointerPanZoomStartEvent`/`Update`/`End` alongside `InteractiveViewer`. Root cause (found with a fixed-point widget test across six DPR/interface-zoom combinations, reproduces at DPR 1.0 too): Flutter's `ScaleGestureRecognizer` reports a pan-zoom gesture's focal point as `position + pan`, and on Windows the reported pan grows with the pinch, so `InteractiveViewer`'s own anchoring lands at roughly twice the cursor position, and its own boundary clamp then pins the result into a corner.

Fix: once a pan-zoom gesture's scale leaves 1.0 (so a two-finger pan that turns into a pinch anchors where the fingers were **then**, not at gesture start), `_zoomAnchor`/`_zoomAnchorScene` capture the pointer and its scene-space point; `onInteractionUpdate` calls `_reanchorZoom`, which redoes **only the translation** after `InteractiveViewer` applies its own scale, so the scene point under the cursor stays put. A `_startSettle()`/`_armSettle()` timer (120 ms) keeps re-applying the anchor through InteractiveViewer's own post-release inertia, because the library keeps moving the matrix on its own after the fingers lift, toward the same wrong focal point.

`trackpadScrollCausesScale` (an `InteractiveViewer` flag) was rejected: it turns an ordinary two-finger scroll into a zoom. Note: on Windows a two-finger trackpad scroll already arrives as a synthetic mouse wheel event, so it zooms through the normal wheel path regardless.

---

## Video

`media_video_page.dart::MediaVideoPage` renders **only the texture** (`ColoredBox(black) > Center > AspectRatio > VideoPlayer`), tap toggles play/pause, double-click (via `DoubleClickListener`, a raw pointer-down listener outside the gesture arena since the video player already claims the tap) triggers `onFullscreen`. A page opened by walking the conversation opens its own `MediaPlaybackSession`; a page opened from a bubble receives the bubble's live session (`widget.item.session`) so position and play state survive the push, and never disposes it: only a session this page itself opened (`_owns`) is closed on leaving the page or disposing.

**Why the transport bar moved out of the page:** the viewer's own chrome (strip, chevrons, top bar) draws OVER the page in the `Stack`, so a control bar drawn inside `MediaVideoPage` ends up underneath them and unreachable. `MediaVideoControls` (`media_viewer_controls.dart`) is built by the **route**, one row placed ABOVE the strip in the same fading chrome layer: play/pause, elapsed/total time, a seek bar with hover-time tooltip, a speed cycle button (`kMediaSpeeds = [1.0, 1.25, 1.5, 2.0, 0.5, 0.75]`), loop toggle, `VerticalVolumePopover`, fullscreen. The route publishes the live `VideoPlayerController` up to itself via `MediaVideoPage.onController`, called only when `isCurrent`: that is how keyboard shortcuts (space/m/l) and `MediaVideoControls` reach the controller of whichever page is current.

The in-chat bubble's own control bar (`_ControlBar` in `video_message_bubble.dart`) was rebuilt into the same one-row shape for consistency: play, time, slider, `VerticalVolumePopover` (mute), fullscreen: time drops below `_timeFloor = 220` px width.

### VerticalVolumePopover

`media_viewer_controls.dart::VerticalVolumePopover`: shared by the viewer's transport AND the bubble's control bar (`InlineVideoPlayer`'s `_ControlBar`). A mute-icon button that, on hover, opens a vertical slider **above** it via a raw `OverlayEntry` (`HollowTooltip`'s shape) rather than a widget in the surface's own `Stack`: a popover positioned outside its parent's bounds still paints, but stops receiving pointer events once it extends past a clipped ancestor. Registers with `OverlayHosts` while open. Anchored via `overlayAnchorOf(context)`, never a bare `localToGlobal`. Hover on the icon and hover on the popover itself share one 250 ms hide grace period so moving from one to the other does not close it. Scroll over either the icon or the popover adjusts volume in 0.05 steps.

---

## The strip

`media_strip.dart::MediaStrip`: a horizontal `ListView.separated` of 56 px thumbnails (`_MediaThumb`), auto-scrolling to keep the current index centred (`_reveal()`, respects `ReduceMotionController`). Video thumbs get a small play-glyph overlay. Thumbnails resolve through `AttachmentImage`/`VideoThumbnailService.cachedThumbFor` the same way bubbles do; a thumbnail with neither a disk path nor decoded header bytes falls back to a bare kind icon.

---

## The info panel

`media_info_panel.dart::MediaInfoPanel`: a side panel on desktop (300 px wide, right edge), a bottom sheet on mobile. Rows: Name, Dimensions (only when `item.pixelSize` is known), Size, Sent by (resolved sender→master via `deviceLinkProvider`, then `displayNameFor`), Time, and a content-hash row **only when `item.contentId != null`**, which in practice means only a walked item (`list_media_for_context` populates `content_id`, and only for vault-backed videos in the data today; `files.content_id` is otherwise unset). The item the bubble handed over carries no hash until `_loadAround()` merges one in.

**No Format row.** Every image Hollow sends is WebP by construction, and Save As converts on the way out: a format row would always say the same thing.

An "Encrypted on this device" line (not a badge) appears once, below the rows, when `AtRest.isManaged(diskPath)`.

---

## Fullscreen ownership

Three rules, all enforced through the `FullscreenMediaChrome` mixin's `enterWindowFullscreen()`/`exitWindowFullscreen()` pair (`fullscreen_media_chrome.dart`) and `enteredFullscreen` (true only while THIS surface holds the window fullscreen; a user already in F11 before opening keeps it on close):

1. **An image opens IN THE WINDOW**, never OS fullscreen (Vitalik: OS fullscreen "makes sense only for video"). F11 (the app-wide shortcut) still toggles the window while the viewer is open, and the viewer survives the toggle either way.
2. **A video's fullscreen button, from a bubble,** calls `openMediaViewer(..., enterFullscreen: true)`. `widget.enterFullscreen` wires a `ref.listen<bool>(fullscreenProvider)` that dismisses the viewer the moment the window leaves fullscreen by ANY path (F11, the control bar, the app lock): entering and leaving the viewer and the window fullscreen are one action from this entry point, matching Part A's video-dialog rule.
3. **Walked to a video from inside the viewer** (arrived by paging, not by `enterFullscreen`): entering fullscreen from the transport does not carry that coupling. The first Escape leaves the window fullscreen and **stays** in the viewer; the second Escape closes the viewer. `_onKey`'s Escape branch checks `!widget.enterFullscreen && enteredFullscreen && ref.read(fullscreenProvider)` to pick between "exit the window" and "dismiss the viewer". A user already in F11 before any of this keeps it on close (`_dismiss` never touches a fullscreen this surface did not enter).

The rule Vitalik settled on, stated once: **the fullscreen toggle returns you to where you came from.**

`_videoFullscreenAction()` picks the button's behavior per mode: null on mobile or where `FullscreenNotifier` is unsupported; `_dismiss` when `widget.enterFullscreen` (leaving fullscreen = leaving the viewer); `_toggleWindowFullscreen` otherwise (a plain window toggle, walked mode).

---

## Shortcuts

Ten `AppShortcut` entries with `surfaceScoped: true` (`app_shortcuts_provider.dart`), rebindable in Settings > Shortcuts under the "Media Viewer" card (`shortcuts_section.dart`): `mediaZoomIn` (`=`), `mediaZoomOut` (`-`), `mediaZoomFit` (`0`), `mediaActualSize` (`1`), `mediaRotate` (`r`), `mediaSaveAs` (`s`), `mediaInfo` (`i`), `mediaPlayPause` (`space`), `mediaMute` (`m`), `mediaLoop` (`l`). `surfaceScoped` is what makes a bare, un-modified letter safe to bind here: the always-on shortcuts refuse a bare typable key because it would fire while typing a message; a surface-scoped one is live only while its surface (here, the viewer) is open. Escape, the arrow keys and Ctrl+C (copy image) are fixed, not rebindable, and handled directly in `_onKey` before the shortcut map is consulted.

---

## Rust: `list_media_for_context`

`rust/hollow_core/src/storage/messages.rs::MessageStore::list_media_for_context(context_type, context_id, before_ts, after_ts, limit)` → `Vec<StoredMediaItem>` (`{file, content_id, ts, album_id}`); FFI mirror `rust/hollow_core/src/api/storage.rs::list_media_for_context` returns `MediaListItem { file: StoredFileInfo, ts: i64, content_id: Option<String>, album_id: Option<String> }`.

- **Ordering:** `ts DESC, ord DESC, file_id DESC`: newest first, ties within one millisecond broken by the owning row's `order_us` (`ord`, 0 when absent) then `file_id`, so an album's items walk in send order. `ts` is `COALESCE(messages.timestamp, channel_messages.timestamp, files.created_at)`, the OWNING MESSAGE's timestamp (a DM file can only match the `messages` table and a channel file only `channel_messages`, so one `COALESCE` over both is unambiguous), falling back to the file row's own `created_at` when no message row matches.
- **Matched rows:** `files` where `context_type`/`context_id` match, `completed_at IS NOT NULL`, `hidden_at IS NULL`, `expired_at IS NULL`, and either `is_image = 1` or the lowercased extension is in `MEDIA_VIDEO_EXTS` (`mp4/webm/mov/mkv/avi/m4v`, `pub(crate) const` in `messages.rs`, mirrored in Dart as `kMediaVideoExtensions`).
- **Exclusions:** a file whose owning row in `messages` OR `channel_messages` has `hidden_at IS NOT NULL` is dropped via `NOT EXISTS`. After `resolve_disk_path`, any row left with no disk path (`disk_path.is_none()`) is filtered out too: a completed row can still have no bytes on disk.
- **Both-way paging:** `before_ts`/`after_ts` are exclusive millisecond bounds on the wrapped `ts` expression (`ts < ?3`, `ts > ?4`, either side nullable): a caller pages both directions from the item it opened.
- **Limits:** `limit` is clamped `1..=200` server-side (`limit.clamp(1, 200)`); the Dart pager (`_kPageSize`) requests 40 at a time.
- **`files.hidden_at` has no writer anywhere in the codebase today**, and `files.content_id` is set only for vault-backed videos, which is why the info panel's hash row is rare in practice, not a bug.

---

## CI guards

`test/media_viewer_guard_test.dart`: source scans over `lib/src/ui/media` (and, for the two replaced surfaces, all of `lib`), because each rule fails silently at runtime rather than throwing: `_FullscreenImageView`, `FullscreenVideoView` and `fullscreenVideoRoute` stay absent from the whole of `lib`; no `localToGlobal(` (interface zoom sits between the window and the Navigator, so anchors go through `overlayAnchorOf`/`overlayPositionOf`); no `showHollowDialog(` outside `media_viewer_route.dart` itself, where only the delete confirmation uses one; no `.repeat(` (a repeating `AnimationController` requests a frame every vsync even when nothing changed); no bare `Opacity(` (costs a saveLayer per paint: `AnimatedOpacity` composites on the GPU); no `readAsBytes`/`openRead(`/`readAsString` (content files are at-rest ciphertext; reads go through `AtRest`).

## Not yet verified / not built

Per the plan's phase-1 note: mobile (swipe-down dismiss, the bottom control bar, per-page rotation re-evaluation), macOS, Linux, and the viewer's right-click menu have not been driven for real on those platforms. Deferred to a later phase: eyedropper, annotate-and-send-back, the media tab (grid view backed by the same `list_media_for_context`), frame step, copy frame. Hero-from-thumbnail transition and the compare view are backlog (Vitalik: compare is "a designer's feature, painful for what it gives").

## Related

`feedback_annotation_window_management` (why `window_manager`'s own fullscreen call is off limits on Windows and what `FullscreenNotifier`/`fullscreenProvider` replace it with), `project_display_scaling` (`UiScale`, the `MediaQuery` pixel-ratio trap), `feedback_ticker_is_a_frame_request` (why chrome fades use `Timer`, never an `AnimationController` restarted on a cadence), `feedback_overlay_entry_dialog_behind_host` / `project_issue61_context_menus` (the `showHollowMenu` pattern the overflow menu uses), `project_media_viewer_albums_subtitles_plan` (Parts C/D, phase 3).
