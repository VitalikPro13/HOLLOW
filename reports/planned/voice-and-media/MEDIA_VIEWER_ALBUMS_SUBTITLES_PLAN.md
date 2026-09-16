# Media viewer, albums and subtitles

**Status:** Part A SHIPPED 2026-09-14 (3.6). Part B phase 1 SHIPPED 2026-09-14 (4.5, with section 11). Part B phase 3 extras, Parts C and D PLANNED. Design agreed 2026-09-14 (Vitalik + Fable session).
**Owner:** Vitalik (architect).
**Companion memory:** `feedback_annotation_window_management` (why `window_manager` fullscreen is off limits and what this replaces it with), `project_autodownload_gate` (every album item passes the same gate), `feedback_chat_clock_lamport` (album order comes from `order_us`), `project_ffmpeg_minimal_build` (the rebuild subtitles need), `feedback_mobile_parity_always`.
**Plan checklist:** HOLLOW_PLAN.md (add the bullets when this starts).

---

## 0. TL;DR

Four things, in shipping order:

1. **True fullscreen** on every platform, without a second window. On Windows the `window_manager` call is a silent no-op for a frameless window, so Hollow gets a forty-line native method of its own in the runner. macOS and Linux already work through `window_manager`. Mobile unlocks rotation for the media route only and stays portrait everywhere else.
2. **One media viewer** for images, GIFs and video, replacing the tap-to-close dialog and the letterboxed video modal. Zoom, pan, keyboard, prev and next through the album and then the whole conversation, plus the things other chat apps do not do: pixel-exact mode, eyedropper, annotate and send back, side-by-side compare, an info panel with the content hash.
3. **Albums**, Telegram style: up to ten files sent back to back sharing one album id, rendered as one grouped bubble. Every item stays an ordinary message with its own signature, file, dedup, delete and moderation path. The album id is signed (v3 canonical string, used only when an album id is present).
4. **Subtitles** as a player feature: sidecar SRT and VTT attached to a video, embedded tracks read on desktop, a small cue editor with import and export, and an "embed into the file" action that muxes the track into the mp4. No subtitle generator, no OCR.

Decision summary:

- Fullscreen: own native method on Windows, `window_manager` on macOS and Linux, immersive mode plus a per-route orientation unlock on mobile. The title bar hides through the same flag the annotation mode already uses.
- One route for all media, opaque, hero from the thumbnail, registered with `OverlayHosts`.
- Albums are N messages with a shared `album` field, never one message with N files. Cap 10.
- `album` goes into the signature: canonical `hollow-msg3` with an album slot, chosen by the presence of the field. Old clients reject album messages (they cannot verify v3) and show nothing for them; everyone upgrades.
- Subtitles are rendered by Flutter on every platform, never by the player library, so styling and parity hold. mdk's own subtitle rendering is disabled.
- The bundled ffmpeg is rebuilt with subtitle codecs. Every new flag is tested against the bundled binary.

---

## 1. Today, precisely

### 1.1 Image viewer

`lib/src/ui/chat/file_attachment_widget.dart` `_FullscreenImageView` (line 718) is a `StatelessWidget` inside `showHollowDialog`: a tap-to-pop `GestureDetector`, a centred `AttachmentImage` with `BoxFit.contain`, one close button. No zoom, no pan, no double tap, no rotate, no navigation, no keyboard beyond Escape, one code path for desktop and mobile. Save and copy live on the message hover bar, not in the viewer (`message_action_bar.dart` `onCopyImage`, `_saveFile` in the three panes, `attachment_export.dart` `exportAttachmentTo`). The only `InteractiveViewer` in the app is the mobile call screen-share zoom.

### 1.2 Video

`video_player` 2.11.1 with `fvp` 0.35.2 as the desktop backend (`video_backend.dart`); mobile uses the native `video_player` engines. `video_message_bubble.dart` has `InlineVideoPlayer` (public, reused by `link_preview_card.dart`) and `_FullscreenVideoView` (line 939), which builds a **second** controller and restarts from zero, inside a dialog inset by `HollowSpacing.xxl`. Nothing OS level happens. There is no `setFullScreen` call anywhere in `lib/`.

### 1.3 Why `window_manager` fullscreen never worked for us

`window_manager` 0.5.1 `windows/window_manager.cpp` `SetFullScreen`: the enter branch is `if (!is_frameless_) { ... }`, and Hollow's window is frameless (`setAsFrameless()`). So entering does nothing except set a flag, and leaving resets `is_frameless_ = false` and the title bar style, which is the "squished on restore" the annotation memory records. macOS goes through `NSWindow.toggleFullScreen` and Linux through `gtk_window_fullscreen`; both are fine for us.

### 1.4 Attachments

One file per message at every layer. `ChatMessage.fileAttachment` and `ChannelChatMessage.fileAttachment` are a single `FileAttachment?`. The three composers (`chat_pane.dart`, `channel_chat_pane.dart`, `mobile_chat_route.dart`) hold three scalars `_stagedFilePath`, `_stagedFileName`, `_stagedFileIsImage`, the picker never passes `allowMultiple`, `ChatDropZone` takes `details.files.first`, and `StagedFilePreviewBar` (`chat_pane_shared.dart` line 1103) is a one-row bar. `fileTransferProvider.sendFile` takes one path and one message id; Rust `handle_send_file` (`node/file_handler.rs` line 225) mints one file id, one signature and one row per call.

The storage side is already one-to-many: `files.message_id` with `idx_files_message`, and `get_files_for_message` exists (`storage/messages.rs` line 5013, FFI `api/storage.rs` line 876). The blockers to a true multi-file message are the signature (`SignedExtras.file_id` is one slot), the wire (`DirectMessagePayload.file_id`, `ChannelMessagePayload.file_id`, `FileHeaderPayload.fid` and `mid`, `PublicFileHeader`, `SyncFileMetaItem` are all singular) and message-id dedup on receive, which would drop rows two to N. That is why albums are N messages.

### 1.5 Mobile orientation

`lib/main.dart` line 106 locks `portraitUp` at start, `AndroidManifest.xml` line 44 sets `screenOrientation="portrait"`, and `ios/Runner/Info.plist` lists only `UIInterfaceOrientationPortrait` for iPhone and iPad with `UIRequiresFullScreen`. On iOS the plist is the app-level whitelist; a runtime request for landscape is ignored unless the plist allows it. `mobile_image_crop_route.dart` already shows the pattern of restoring `portraitUp` on pop.

### 1.6 Signing

`node/crypto_handler.rs` `message_signing_payload_v2`:

```
hollow-msg2:{type}:{context}:{sender}:{ts}:{mid}:{reply_to}:{file_id}:{order_us}:{lp}:{text}
```

Every slot before `text` is colon-free, `text` is last. `SignedExtras` is the one struct every sign and verify site uses, including edit and delete signatures and `sign_file_message`. There is no v1 fallback and no version byte on the wire; the verifier computes v2 unconditionally.

### 1.7 ffmpeg

`vendor/ffmpeg/ffmpeg-win-x64.exe` (minimal build, 5.9 MB) has **no** subtitle encoder, decoder, demuxer or muxer. It can demux mov, mp4 and matroska and mux mov and mp4. Subtitles need a rebuild through `.github/workflows/build-ffmpeg.yml`. ffmpeg is desktop only; mobile has none.

---

## 2. Non-goals

- No second window. Desktop picture-in-picture is out for the same reason.
- No true multi-file message (one row, N files). Albums are the answer; see 1.4.
- No OCR, no text selection inside images.
- No subtitle generator, no speech recognition, no cloud call of any kind.
- No player-library subtitle rendering (mdk on desktop, ExoPlayer or AVPlayer on mobile). Flutter draws every cue.
- No slideshow, no image editing beyond crop and annotate.
- No change to the relay. Every new field rides inside encrypted payloads the relay never reads.

---

## 3. Part A: true fullscreen

### 3.1 Windows

A method channel `hollow/window` in `windows/runner/flutter_window.cpp` (the runner has no channel yet; this is the first) with two methods, `enterFullscreen` and `exitFullscreen`.

Enter, once, guarded by an `is_fullscreen_` flag:

1. Save `GetWindowLongPtr(GWL_STYLE)`, `GetWindowRect`, and `IsZoomed`.
2. `MonitorFromWindow(MONITOR_DEFAULTTONEAREST)` + `GetMonitorInfo` for the monitor rect.
3. `SetWindowLongPtr(GWL_STYLE, style & ~(WS_THICKFRAME | WS_MAXIMIZEBOX))`.
4. `SetWindowPos(HWND_TOP, monitor.left, monitor.top, width, height, SWP_NOOWNERZORDER | SWP_FRAMECHANGED)`.

A window whose rect equals the monitor rect and has no thick frame is what the shell treats as fullscreen: the taskbar drops behind it on its own. No `HWND_TOPMOST` (that is what steals focus from other apps and fights notifications).

Exit: restore the saved style, then `SetWindowPos` to the saved rect with `SWP_FRAMECHANGED`; if the window was zoomed before, `PostMessage(WM_SYSCOMMAND, SC_MAXIMIZE)` instead of the rect. The `DwmExtendFrameIntoClientArea` margins are not touched (that is the `window_manager` bug), so the frameless title bar, the resize border and `DragToResizeArea` come back exactly as they were.

Never call `windowManager.setFullScreen` on Windows. Add a CI source scan for it, the same shape as the `mint_key_package` guard.

### 3.2 macOS and Linux

`windowManager.setFullScreen(true|false)`. macOS keeps its native title bar (`feedback_macos_window_chrome`), so `toggleFullScreen` gives a proper Space with the traffic lights hidden. Linux is `gtk_window_fullscreen`, which handles a frameless window; verify on Vitalik's laptop under both X11 and the Hyprland wlroots session (no minimize there, but fullscreen is a separate request and works).

### 3.3 Dart side

- `fullscreenProvider` (sync `Notifier<bool>`), toggled by one service `WindowFullscreen.enter()/exit()` that branches per platform and always restores on failure.
- `app.dart` builder: the `WindowTitleBar` hides on `fullscreen || annotation`, the same slot the annotation flag uses today.
- The 8px pointer-dead strip (`kWindowEdgeDeadStrip`) exists because of the resize border; with `WS_THICKFRAME` gone it disappears, so the viewer's edge controls may hug the edge in this state only. Simplest: the viewer keeps its insets and does not care.
- Exit paths: Escape, F11, double click on the media, the viewer's own button, app lock (`OverlayHosts` dismissal already runs on lock; the fullscreen service listens to `appLockedProvider` and exits), route pop for any reason (`dispose` of the viewer always calls exit; idempotent).
- Rebindable: F11 and the viewer shortcuts go through `appShortcutsProvider` like every other app shortcut.
- The viewer opens boxed (the window as it is) and fullscreen is a toggle inside it; a setting "Open videos fullscreen" is not needed in v1.

### 3.4 Mobile: rotation only where it makes sense

The app stays portrait. Only the media route may rotate, and only when the content is landscape.

- `Info.plist`: list all four orientations for iPhone and iPad, keep `UIRequiresFullScreen` (the reason it is there is the iPad lock; it also keeps the Space semantics simple). The runtime lock in `main.dart` is what holds portrait from then on.
- `AndroidManifest.xml`: keep `screenOrientation="portrait"`; `SystemChrome.setPreferredOrientations` calls `setRequestedOrientation` at runtime, which overrides the manifest. Verify on a device that the unlock takes effect without a manifest change; if it does not, set the manifest to `unspecified` and rely on the runtime lock alone.
- The media route on enter: `SystemChrome.setEnabledSystemUIMode(immersiveSticky)`; if the current item is a landscape video or image (width > height), `setPreferredOrientations([portraitUp, landscapeLeft, landscapeRight])` so the sensor decides; portrait media keeps `[portraitUp]`. A rotate button in the controls forces landscape for people with rotation lock on. On pop: `[portraitUp]` and `edgeToEdge`, in `dispose` and in the `.then()` of the push, the way `mobile_image_crop_route.dart` does it.
- Swiping between items re-evaluates the allowed set; changing from a landscape video to a portrait photo relocks portrait.
- Verify on the iOS Simulator through the Mac mini scripts (`project_ios_simulator_probe`); rotation is a matrix row.

### 3.5 Video controller handoff

Fix the restart-from-zero. A `MediaPlaybackSession` object owns the `VideoPlayerController`; the inline bubble and the viewer both render from it. Opening the viewer passes the session; the bubble stops rendering its texture while the viewer holds it and resumes on return, position and play state intact. Only one texture is attached at a time (two `VideoPlayer` widgets on one controller on Windows double-renders through fvp). Disposal stays awaited and single-owner (`feedback_linux_thread_leak_heap_corruption`).

### 3.6 What shipped (2026-09-14)

Built as written in 3.1 to 3.5, with these decisions made during the build and Vitalik's review in the real app:

- **Windows native method.** `hollow/window` in `windows/runner/flutter_window.cpp`: `enterFullscreen`, `exitFullscreen`, `isFullscreen`, `queryWindow`. Enter also clears `WS_MAXIMIZE` from the style, because window_manager's `WM_NCCALCSIZE` handler insets a zoomed frameless window by 8px. Exit restores the style and the saved `WINDOWPLACEMENT` (so a window that was maximized comes back maximized through the normal path) and never touches the DWM margins. `queryWindow` also reports native focus and foreground state for the probe.
- **Service.** `lib/src/core/services/window_fullscreen.dart`: `fullscreenProvider` + `FullscreenNotifier` (enter, exit, toggle, serialized, fails closed, exits on `appLockedProvider`). `windowManager.setFullScreen` and the channel name are confined to that file by `test/window_fullscreen_test.dart`.
- **F11 is app-wide**, a rebindable `AppShortcut.toggleFullscreen`, not only inside a media surface. The title bar hides on `annotation || fullscreen`. `DragToResizeArea` stays MOUNTED with its edges disabled while fullscreen: swapping it out re-inflated the whole shell, the composer's autofocus stole focus from the open dialog and Escape died.
- **Video fullscreen IS the OS fullscreen.** The inline control bar's fullscreen button pushes `FullscreenVideoView` as an opaque black full-bleed route (`fullscreenVideoRoute`, fade, reduce-motion aware) and enters OS fullscreen on desktop; contain fit, so landscape touches left and right and vertical touches top and bottom. The control bar button, Escape, double-click, F11 and the app lock all leave the view and the fullscreen together (the view listens for the provider's true to false transition and removes its OWN route, never a bare pop, because the lock cover is pushed above it first). There is no separate "window fullscreen" button on any media surface: Vitalik vetoed it as redundant.
- **Controller handoff.** `lib/src/ui/media/media_playback_session.dart`: one `VideoPlayerController` in a holder set (bubble + viewer), last release disposes, only one `VideoPlayer` attached at a time (the bubble draws its poster while the viewer holds). Probe-verified: position 3280 to 8480 to 10000 ms across the round trip, never back to zero.
- **Image dialog** is unchanged on desktop (tap anywhere closes). Both surfaces got the mobile rotation unlock (3.4) and a rotate button through the `FullscreenMediaChrome` mixin in `lib/src/ui/media/fullscreen_media_chrome.dart`; `Info.plist` lists all four orientations, `AndroidManifest.xml` untouched (open point 10.1 still decided by a device test).
- **Probe.** New ops `window_state`, `expect_window_same`, `focus_state`, key `f11`; scenarios `fullscreen.json` and `media_fullscreen.json` (the latter needs `UI_PROBE_FIXTURES` pointing at a folder with a plaintext `probe_video.mp4` and `probe_image.png`, because the probe data's own files are at-rest ciphertext). The probe window is not frameless, so the frameless restore was checked by hand in the real app.
- **Not yet verified:** macOS and Linux (one `window_manager` line each), the mobile route, rotation and immersive mode on a device or simulator.

---

## 4. Part B: the media viewer

### 4.1 Shape

One route, `lib/src/ui/media/media_viewer_route.dart`, pushed with `hollowMobileRoute()` on mobile and an opaque black `PageRoute` on desktop (the current `showHollowDialog` with its blur barrier is wrong for this: fullscreen needs an opaque surface and a video needs no blur behind it). Hero from the thumbnail, disabled under `ReduceMotionController`. Registered with `OverlayHosts` so lock dismisses it. Context menus through `showHollowMenu`.

Input: a `MediaItem` list plus a start index. A `MediaItem` is `{fileId, messageId, kind: image|gif|video, diskPath, width, height, senderMaster, ts, contextType, contextId, albumId?, contentHash}`; the list is built by the caller from the album (Part C) and extended lazily with the conversation's media through a new FFI `list_media_for_context(context_type, context_id, before_ts, limit)` over the existing `idx_files_context` index (files with `is_image` or a video mime, completed, not hidden or expired). Navigation past the album's edge walks the conversation; the strip at the bottom shows where you are.

Every file read goes through `AtRest` (`attachment_image.dart` already does), never `dart:io`.

### 4.2 Table stakes

| Feature | Detail |
|---|---|
| Zoom | Scroll wheel and pinch, anchored at the pointer or the pinch centre. Range fit to 8x. Ctrl+scroll and plain scroll both zoom (nothing else to scroll). |
| Pan | Drag when zoomed; bounded to the image with a small overscroll and rubber band on mobile. |
| Double tap | Cycles fit, 100 percent, 2x at the tap point. |
| Fit modes | Fit, fill, 100 percent (`1` key), fit width. |
| Rotate | 90 degree steps, view only, `R`. |
| Navigation | Arrow keys, on-screen chevrons that fade with the controls, swipe on mobile, a thumbnail strip at the bottom (album items, then conversation media). Neighbours preloaded. |
| Dismiss | Escape, close button, swipe down on mobile (with the image following the finger), click on the black outside the image on desktop. |
| Controls | Fade after 2 s idle, return on pointer move or tap, always visible with reduce motion. |
| Shortcuts | All through `appShortcutsProvider`. Defaults: Esc close, F11 fullscreen, +/- zoom, 0 fit, 1 actual size, R rotate, S save as, Ctrl+C copy image, I info, arrows navigate, Space play or pause, comma and period frame step, M mute, L loop, C subtitles. |
| Actions | Save as (`exportAttachmentTo`), copy image, open with the default app, show in folder (desktop), share sheet (mobile), reply, react, jump to message, delete own. Reply and react run without closing the viewer. |
| GIF | Animated through `AttachmentImage(animated:)` as today, with play and pause. |
| Accessibility | Purpose labels on every icon control, `HollowFocusRing`, live region announcing "3 of 12", StatusDot rules do not apply here. |

### 4.3 What sets Hollow apart

In build order.

1. **Pixel-exact mode.** A 1:1 button, a live zoom readout, and a toggle that switches `FilterQuality` to `none` past 100 percent so pixel art, screenshots and emotes stay crisp. Default on above 300 percent, remembered per session.
2. **Eyedropper.** Hover shows a swatch and the hex under the cursor; click copies it. Decode once to `ui.Image`, `toByteData` lazily on first eyedropper use, cache per item, dispose on leave. Mobile: long press.
3. **Annotate and send back.** Reuse the drawing controller behind `annotation_overlay.dart` (pen, arrow, rectangle, text, colours). "Mark up" opens the tools over the image; "Send" composites through a `PictureRecorder` into a WebP still via the Rust `encode_still` path (never the anim encoder) and stages it in the same conversation's composer with the source as the reply target. The original is never modified.
4. **Info panel.** Dimensions, size, format, sender, time, message link, and the content hash (`files.content_id`) with a copy button. Encrypted at rest is stated once as a line, not a badge.
5. **Compare.** Pin the current item, pick a second from the strip; side by side (or over and under on portrait screens) with linked zoom and pan, a swap button, and a slider wipe. Two `ui.Image` in memory, nothing more.
6. **Media tab.** The conversation's media as a grid (desktop right panel or a dialog, mobile a sheet from the header), backed by the same `list_media_for_context`, paging by `before_ts`. Tapping opens the viewer at that item.
7. **Video, in the same viewer.** Play or pause on click, seek bar with hover time and a thumbnail on hover later (not v1), speed 0.5 to 2x (`setPlaybackSpeed`), loop (`setLooping`), volume with mute, frame step by one over the stream's fps (fvp `mediaInfo` on desktop, 1/30 s fallback on mobile), copy the current frame (desktop, fvp snapshot), keep-awake while playing, and subtitles (Part D).

### 4.4 Performance rules

- Decode off the UI thread (`instantiateImageCodec` already is), capped to 8192 on the long edge with `targetWidth` (GPU texture ceiling), full quality otherwise. The inline `cacheWidth` downscale stays for bubbles.
- Two neighbours preloaded, everything else evicted. One `ui.Image` per live item, disposed on leave; the `Image` widget's cache is not the store for this.
- No `Ticker` anywhere in the viewer that is not the video itself (`feedback_ticker_is_a_frame_request`); control fades are `Timer` + `GatedNotifier`.
- A `[SENTINEL]` on viewer open time (tap to first paint) and on neighbour preload.
- Zoom and pan are a single `Matrix4` on a `Transform` over a `RawImage`; no per-frame relayout.

### 4.5 What shipped (2026-09-14, phase 1)

Built as written in 4.1, 4.2, items 1 and 4 of 4.3, the video basics of item 7, and section 11, with these decisions made with Vitalik before the build and during his review:

- **One route, `lib/src/ui/media/media_viewer_route.dart`** (`openMediaViewer`, `mediaViewerRoute`, `MediaViewerView`), an opaque black fade route on desktop and `hollowMobileRoute` on mobile, registered with `OverlayHosts`, keys through a `HardwareKeyboard` handler guarded by route currency and the keybind capture flag. Pages are `media_zoom_view.dart` (images and GIFs) or `media_video_page.dart` (video). `_FullscreenImageView` and `FullscreenVideoView` are gone; `test/media_viewer_guard_test.dart` keeps them gone.
- **An image opens IN THE WINDOW.** Vitalik: OS fullscreen "makes sense only for video". F11 (the app-wide shortcut) still toggles it while the viewer is up and the viewer survives the toggle. A video keeps the Part A rule: the bubble's fullscreen button pushes the viewer with `enterFullscreen: true`, and leaving the fullscreen by any path leaves the viewer too. Reached by walking from an image, a video's fullscreen button only toggles the window. The rule: the fullscreen toggle returns you to where you came from.
- **Zoom is `InteractiveViewer` + `TransformationController`.** The mouse wheel already zooms about the pointer (only a trackpad pan translates), so there is no custom wheel code. Double tap cycles fit, actual size, twice actual. Rotate is a `RotatedBox` around the child.
- **Actual size is one image pixel per DEVICE pixel**, `media_zoom_math.dart`. Inside `UiScale` the `MediaQuery` pixel ratio already carries the interface zoom (`UiScaleBox` multiplies it in), so the formula takes the reported ratio as is; the plan's separate `uiScale` factor would have double-counted. The floor is `min(1.0, actual)`: on a 125 percent display a small image fits ABOVE actual size, and a floor of 1.0 made the `1` key a no-op. The readout shows percent of actual, so 100 means pixel-exact.
- **Crisp pixels** is a toolbar toggle, on by default, remembered for the process: `FilterQuality.none` from twice actual size upward, `high` at and above actual, `medium` below. The image rebuilds only when the bucket changes.
- **The host talks to the viewer through `MediaViewerScope`** (`media_viewer_scope.dart`): a `MediaContext` (dm or channel and its id) plus `MediaViewerActions` (reply, jump to message, delete, react, save as). It is captured at OPEN time by the bubble, because a pushed route sits under the Navigator and cannot see the bubble's inherited widgets. The three panes provide everything; the four archive viewers provide only save as. Reply and jump close the viewer and hand the message id to the host; react opens the existing emoji picker in place; delete is confirmed by the viewer (no pane confirms today) and then advances; save as is the host's own `_saveFile`; copy image calls `copyImageToClipboard` directly. Actions the host cannot perform are omitted, not disabled.
- **Walking the conversation** rides the new Rust FFI `list_media_for_context(context_type, context_id, before_ts, after_ts, limit)` over `idx_files_context`, ordered by the owning MESSAGE's millisecond timestamp (falls back to `files.created_at`), excluding incomplete, hidden, expired files and files whose message is hidden; forty each way from the opened item, then more at the edges. `files.hidden_at` has no writer anywhere today, and `files.content_id` is set only for vault-backed videos, so the info panel's hash row appears only for those.
- **No "open with" and no "show in folder."** The file on disk is at-rest ciphertext, so both would hand the OS an unreadable file. Save as covers it.
- **The viewer OWNS the video transport.** Vitalik's first test found the inline player's control bar buried under the viewer's chrome (strip, chevrons, hover layers), so nothing on a video could be pressed. The video page now renders only the `VideoPlayer` texture (tap = play or pause, double click = leave the fullscreen) and `MediaVideoControls` (`media_viewer_controls.dart`) draws one even row ABOVE the strip in the same fading layer: play, elapsed / total, seek with hover time, speed, loop, volume with a hover slider, fullscreen. The in-chat bubble bar became one even row too (play, time, slider, mute, fullscreen; the time drops under 220 px). Frame step and copy frame wait for phase 3.
- **Touchpad pinch anchors at the cursor** (`media_zoom_view.dart`). Root cause, found with a fixed-point widget test across six DPR and interface-zoom geometries: Flutter's `ScaleGestureRecognizer` reports a pan-zoom focal point as `position + pan`, and Windows reports a pan that grows with the pinch, so `InteractiveViewer` anchored at about twice the cursor and the boundary clamp pinned it to a corner. Not geometry-dependent (reproduces at DPR 1.0). Fix: a `Listener` tracks the pointer and the pan-zoom lifecycle, and `onInteractionUpdate` re-does only the translation so the scene point under the cursor stays put, including through the post-release scale inertia. `trackpadScrollCausesScale` was rejected because it turns two-finger scroll into zoom. Note: on Windows a two-finger scroll already arrives as a mouse wheel, so it zooms.
- Details has no Format row: every sent image is WebP by construction and save as converts on the way out.
- **A fullscreen the viewer entered is left when the viewer leaves, and Escape always leaves it first.** Vitalik's second test: walk to a video, enter fullscreen from the transport, Escape closed the viewer and left the window fullscreen with no visible way out. Every enter and exit now goes through the mixin's pair (`enterWindowFullscreen`/`exitWindowFullscreen`); in the walked mode Escape leaves the fullscreen and stays in the viewer, a second Escape closes; from a bubble both go at once as in Part A; a user already in F11 before opening keeps it.
- **Volume is a VERTICAL popover on hover** over the mute icon, one shared `VerticalVolumePopover` in both the viewer transport and the bubble bar. It rides an `OverlayEntry` in the `HollowTooltip` shape (registered with `OverlayHosts`, anchored via `overlayAnchorOf`), because a popover that overflows the bubble paints but cannot be hit inside a clipped parent.
- **Ten viewer shortcuts** in `AppShortcut` (`=`, `-`, `0`, `1`, `r`, `s`, `i`, space, `m`, `l`), `surfaceScoped` so a bare key is allowed for a shortcut that only lives while the viewer is open; a "Media viewer" card in Settings > Shortcuts. Escape, arrows and Ctrl+C are fixed.
- **Section 11 shipped alongside:** `messagePreviewText` in `lib/src/core/message_preview.dart` (tokens moved down to `core/message_tokens.dart`, `isVoiceMessageFile` to `core/voice_note_name.dart`), applied at every preview surface including the push, desktop and in-app notification bodies, the archive reply quotes and the mobile action sheets; pinned lists keep their line breaks (`singleLine: false`). `test/message_preview_guard_test.dart` forbids raw `lastMessage.text` in the UI. Previews never carry an emoji glyph, so a captioned photo previews as its caption alone.
- **Probe:** `scripts/probe_scenarios/media_viewer.json` (open, details, wheel to 924 percent, `1` to 100, `0` back, Escape, window unchanged) and `media_fullscreen.json` updated for the route; new probe op `wheel` and the viewer's key spellings. Sentinels `media viewer open` and `media viewer preload`.
- **Not yet verified:** mobile (swipe down, the bottom bar, per-page rotation re-evaluation), macOS and Linux, the right-click menu. Deferred to phase 3: eyedropper, annotate and send back, media tab, frame step, copy frame; Hero from the thumbnail is polish for later; compare moved to the backlog (Vitalik: a designer's feature, painful for what it gives).

---

## 5. Part C: albums

### 5.1 Model

An album is one to ten messages from the same sender, sent back to back, each carrying the same `album` id (a UUID, colon-free). Each message is what it is today: its own `mid`, its own file, its own `order_us`, its own signature. Rendering groups them. Nothing else in the system knows albums exist.

Why this and not one message with N files: see 1.4. Every sync, backfill, dedup, moderation, delete, archive, public-channel and file-ask path keeps working unchanged, and old clients render an album as the consecutive messages they already render today.

### 5.2 Wire

`#[serde(default)] pub album: Option<String>` on:

- `FileHeaderPayload` (the receiver creates the message row from the header, so this is the one that matters for files)
- `DirectMessagePayload` and `ChannelMessagePayload` (a text item inside an album is not v1, but the field is there so the signature helper is uniform)
- `PublicFileHeader` and `PublicChannelMessage` (public channels)
- `SyncFileMetaItem` and the sync message items (backfill carries it)
- `ArchiveMessage`

Ingest validation on every path: `album` is at most 36 chars, matches the UUID shape, else the field is dropped before any store write (never the message). No new ingest path, so no new row in wiki `security_write_gates.md`; the existing rows note the field.

### 5.3 Storage

`ALTER TABLE messages ADD COLUMN album_id TEXT;` and the same on `channel_messages`, additive migrations in the existing `migrate(conn, ...)` style. `StoredMessage`, `StoredChannelMessage`, `MessageSigRow` and the FFI `StoredMessage` gain `album_id: Option<String>` with `#[serde(default)]`. Dart `ChatMessage.albumId` and `ChannelChatMessage.albumId`. The files table does not change.

### 5.4 Signing (decided: signed)

The album id is bound so nobody who later serves the message (a sync responder, a backfill peer) can regroup or split a sender's items. A v3 canonical payload:

```
hollow-msg3:{type}:{context}:{sender}:{ts}:{mid}:{reply_to}:{file_id}:{order_us}:{lp}:{album}:{text}
```

`SignedExtras` gains `album: Option<&str>`. `sign_message_versioned` signs v3 **iff** `album` is present, v2 otherwise. `verify_message_signature_v2` becomes `verify_message_signature`: it computes v3 when the received payload carries `album`, v2 when it does not. The version is decided by the payload, not by an attacker-controlled byte.

Downgrade check. Stripping `album` from a v3-signed message makes the verifier compute v2 bytes against a signature over `hollow-msg3...` bytes: reject. Adding `album` to a v2-signed message makes it compute v3 bytes: reject. Two different prefixes, so no byte string is valid under both. Non-album traffic is byte-identical to today, so nothing changes for old clients until they receive an album, which they reject and do not show. Edit and delete signatures bind the full extras already, so `album` rides into them for free. `feedback_signature_enforcement_not_logging` holds: reject, never log-and-accept.

Harness: a v3 round trip, the two downgrade cases, and `parse_ops_tolerant` style tolerance for the new field on an old-peer parse.

### 5.5 Sending

- The staging slot becomes a list (max 10, mixed kinds). `allowMultiple: true` on every picker; `ChatDropZone` hands over every dropped file; paste appends. One shared widget `StagedAttachmentStrip` replaces `StagedFilePreviewBar` on all three composers: thumbnails (images, video posters, file icons), remove per item, drag to reorder on desktop, long press on mobile, a counter "4 of 10".
- Send mints one album id when the list has two or more items, then calls `sendFile` per item **sequentially**, awaiting each, so `order_us` and relay arrival keep the strip's order. The composer text is the caption of the first item; the rest send with an empty caption (the `[file:{fid}]` sentinel path, unchanged).
- Optimistic rows are added per item before each FFI call, with the album id, so the bubble groups immediately (`feedback_mobile_send_optimistic_parity`).
- Large files: one `confirmLargeFileShare` dialog per album listing the offenders; accepted ones go as Hollow Shares inside the same album (`share_ref` rides per header as today).
- Media-only channels keep their extension filter per item.
- A failed item shows its state in the group; the others are unaffected. Retry is per item.

### 5.6 Receiving and rendering

- Grouping rule (Dart, in `chat_provider` and `channel_chat_provider` after dedup by message id): items with the same `(senderMaster, albumId)` in the loaded window form one group anchored at the earliest item's position, ordered by `order_us`. Items beyond ten render as a second group. A group with one loaded item renders as a plain message until its siblings arrive (they normally arrive within the same second).
- `AlbumBubble` layout: 1 full width, 2 side by side, 3 one large plus two stacked, 4 a 2x2 grid, 5 to 10 two rows with a "+N" overlay on the last visible tile that opens the viewer at that item. Tiles keep aspect through a fixed mosaic height, cropped with `BoxFit.cover`; the viewer shows the full image. Non-media items render as stacked file cards under the mosaic, each with its own honest state (`file_card_status.dart`).
- Per-item progress overlays; the auto-download gate applies per item, so a gated album shows N "Download" tiles and a "Download all" chip.
- Reactions, replies and pins target the anchor message from the bubble; the viewer offers them per item. Editing the caption edits the anchor. Deleting from the bubble asks "Delete this item" or "Delete all N"; a deleted item leaves the group and the layout reflows. Old clients see the individual deletes.
- Reply preview of an album shows the anchor's thumbnail plus "+N".
- Notifications: one local surface per album, "sent 4 photos" (`project_local_notifications_desktop_mobile` says one surface per message; the album is the message here). Channel push: one `0x09` frame per album, sent for the anchor only. Unread counts stay per message (they are ms-timestamp based and must not change).
- Old clients: N consecutive messages, one with the caption. That is today's behaviour.

### 5.7 Everything else that touches a message

Archive export and import carry `album_id`; the web public viewer ignores it (no previews there anyway); moderation acts per message; the Saved messages self-DM works unchanged; multi-device siblings see the same rows and group the same way.

---

## 6. Part D: subtitles

### 6.1 Model

`SubtitleTrack { id, label, language, source: sidecar|embedded|local, cues: List<Cue{start, end, text}> }`. Cue text keeps only `b`, `i`, `u` and line breaks; every other tag is stripped. ASS and SSA are read as plain cues with styling discarded. Parsers: `video_player` already ships `SubRipCaptionFile` and `WebVTTCaptionFile`; a tolerant wrapper handles BOMs, CRLF, missing indices and overlapping cues. Subtitle files are capped at 2 MB.

### 6.2 Sources, in priority order

1. **Sidecar sent with the video.** An `.srt` or `.vtt` in the same album as the video with `#[serde(default)] sub_for: Option<String>` on its `FileHeaderPayload` (and `SyncFileMetaItem`, `PublicFileHeader`) naming the video's file id. The receiver binds it only when the sender's master matches the video's and the video is in the same context; otherwise it is an ordinary file card. Subtitle bytes ride the file rail like any file, never a new channel.
2. **Embedded tracks.** Desktop only: on first open, ffmpeg extracts each text track to WebVTT (`-map 0:s:N -f webvtt`) into a `subs_cache/` folder keyed by the file's content hash, written through `at_rest::Writer` and read through `at_rest::read_all`. mdk could play these itself, but its rendering is inside the video texture, not ours, and mobile has no equivalent, so we do not use it. The viewer calls `setSubtitleTracks([])` on fvp so mdk never draws. Mobile cannot read embedded tracks in v1 (the native `video_player` engines expose no track API); the track picker says so.
3. **Local import.** "Open subtitles" picks a file, stored under `subs_cache/` keyed by content hash, local only, never sent. "Share subtitles" sends it as a sidecar with `sub_for` in the same conversation. A sidecar from a different sender than the video shows as "Subtitles for `<video>` from `<name>`" with a "Use" button, never auto-bound.

### 6.3 Rendering

A `SubtitleOverlay` widget in both the inline player and the viewer, bottom centred, white with a dark outline, `ChatTextScale` aware, a size setting (small, medium, large) and a vertical offset, remembered globally. A CC button toggles; a track picker lists sources with their origin. Fades only when reduce motion is off. Cue lookup is a binary search on `start` driven by the controller's position listener, no `Ticker`.

### 6.4 Editor

`subtitle_editor_route.dart`, desktop first, mobile after (it fits a sheet). Video on top, cue list below: start, end, text; click a cue to seek; add a cue at the playhead; split, merge, delete; nudge selected or all by ±100 ms; shift and stretch for drift (two anchor cues); undo. Actions: Save (local), Export SRT or VTT, "Attach to video" (sends a sidecar with `sub_for`), and "Embed into file" (6.5).

### 6.5 Embed into the file

Desktop only, mp4 and mov inputs only. ffmpeg:

```
ffmpeg -i video.mp4 -i track.srt -map 0 -map 1 -c copy -c:s mov_text -metadata:s:s:0 language=eng out.mp4
```

The output is a **new** file with a new hash, sent as a new message (or album with the sidecar); the original is never modified in place, which keeps every hash-based identity honest. The plaintext path in and out is a temp file removed after the send, the same rule as `.stream_send_*.tmp`.

### 6.6 ffmpeg rebuild

Add to the workflow configure: decoders `subrip`, `webvtt`, `mov_text`, `ass`, `ssa`, `text`; encoders `mov_text`, `subrip`, `webvtt`; demuxers `srt`, `webvtt`, `ass`; muxers `srt`, `webvtt`. Keep the mp4 muxer. Then run every command in 6.2 and 6.5 against the new bundled binary before anything ships, logging the stderr tail on failure (`project_ffmpeg_minimal_build`, gotcha 2). Release `ffmpeg-minimal-v2`; `scripts/fetch_ffmpeg.ps1` follows.

---

## 7. Phasing

| Phase | Scope | Ships alone |
|---|---|---|
| 1 | Part A (fullscreen on all platforms, mobile rotation, controller handoff) + Part B table stakes (4.2) + pixel-exact + info panel | Yes. The biggest felt win. |
| 2 | Part C albums end to end, desktop and mobile, with the viewer walking the album | Yes. |
| 3 | Eyedropper, annotate and send back, compare, media tab, video extras (4.3) | Each item alone. |
| 4 | Part D subtitles: ffmpeg rebuild, sidecar, embedded on desktop, overlay, editor, embed | Sidecar plus overlay first, editor second, embed last. |

Mobile parity holds within each phase (`feedback_mobile_parity_always`); the two exceptions are stated: embedded tracks and embed-into-file are desktop only in v1 because there is no ffmpeg on mobile.

---

## 8. Verification

- Harness: v3 signing round trip and both downgrade cases; album field tolerance on an old-peer parse; `sub_for` binding refused across senders.
- `scripts/ui_probe.ps1`: viewer open, zoom, navigate, fullscreen enter and exit with the title bar and resize border intact afterwards (window rect and style compared before and after), album send of 1, 2, 4 and 10 items, mosaic screenshots.
- `scripts/fleet.ps1`: an album across two peers and a sibling, arrival order, delete one, delete all, old-client rendering (one peer pinned to the previous build).
- iOS Simulator on the Mac mini: rotation unlock in the viewer and the portrait relock on pop; Android device: the same plus the manifest check in 3.4.
- Linux laptop: fullscreen under X11 and Hyprland, and that a stopped fullscreen restore never leaves the window without its resize border.
- `reports/reference/FEATURE_MATRIX.md` gains rows for viewer, fullscreen, albums, subtitles.

---

## 9. File touch list

**Native**
- `windows/runner/flutter_window.cpp` (+ `.h`): `hollow/window` channel, enter and exit fullscreen.
- `ios/Runner/Info.plist`: all orientations, keep `UIRequiresFullScreen`.
- `.github/workflows/build-ffmpeg.yml`: subtitle flags; `scripts/fetch_ffmpeg.ps1`: new release tag.

**Rust**
- `node/types.rs`: `album` on the six payloads, `sub_for` on the three file payloads.
- `node/crypto_handler.rs`: `SignedExtras.album`, `message_signing_payload_v3`, verifier chooses by presence.
- `node/file_handler.rs`: `album` and `sub_for` through `handle_send_file` and the header ingest; ingest validation.
- `storage/messages.rs`: two migrations, the row structs, `list_media_for_context`.
- `api/storage.rs`, `api/network.rs`: FFI mirrors; `send_file` gains `album` and `sub_for`.
- `archive/types.rs`, `exporter.rs`, `importer.rs`: `album_id`.
- `node/test_harness.rs`: the tests in section 8.

**Dart**
- `lib/src/core/services/window_fullscreen.dart` (new), `fullscreenProvider`, `app.dart` title bar slot.
- `lib/src/ui/media/` (new): `media_viewer_route.dart`, `media_item.dart`, `zoom_view.dart`, `viewer_controls.dart`, `info_panel.dart`, `eyedropper.dart`, `compare_view.dart`, `media_tab.dart`, `subtitle_overlay.dart`, `subtitle_editor_route.dart`, `subtitle_parsers.dart`.
- `lib/src/ui/chat/file_attachment_widget.dart`: open the viewer; remove `_FullscreenImageView`.
- `lib/src/ui/chat/video_message_bubble.dart`: `MediaPlaybackSession`, remove `_FullscreenVideoView`.
- `lib/src/ui/chat/album_bubble.dart` (new), `message_bubble.dart`, `channel_message_bubble.dart`.
- `lib/src/ui/chat/chat_pane_shared.dart`: `StagedAttachmentStrip` replaces `StagedFilePreviewBar`; `chat_drop_zone.dart`: all files.
- `chat_pane.dart`, `channel_chat_pane.dart`, `mobile_chat_route.dart`: staging list, sequential album send.
- `lib/src/core/models/chat_message.dart`, `channel_chat_message.dart`, `file_attachment.dart`: `albumId`, `subFor`.
- `chat_provider.dart`, `channel_chat_provider.dart`: grouping after dedup.
- `file_transfer_provider.dart`: `album`, `subFor` through `sendFile`.
- Notifications: album collapse in the local notification path and the channel push sender.
- `lib/src/core/services/video_thumbnail_service.dart` sibling: `subtitle_extract_service.dart` (desktop).

**Docs and guards**
- `reports/README.md` row (added with this document), `HOLLOW_PLAN.md` bullets when phase 1 starts, wiki `security_write_gates.md` field notes, `FEATURE_MATRIX.md` rows, a CI source scan forbidding `setFullScreen` on the Windows path.

---

## 10. Open points

- Whether the Android manifest lock needs to become `unspecified` (3.4). Decided by the first device test, not by design.
- Caption placement for albums: on the anchor only (decided) versus per item later. Per item is a viewer feature if ever wanted.
- Mobile embedded subtitle tracks: only if the fork or a native track API becomes available; not planned.

---

## 11. Conversation preview line bug (fix with phase 1)

The last-message preview on the home dashboard, the mobile chats tab and the sidebar peer card prints the raw message text, so asset and file tokens leak as `[e:poggies:b816...]`, `[file:36517...]`, `[a:g:2446...]` and `[a:s:dbb4...]`. Three render sites read `.text` directly (`home_dashboard.dart` line 799, `mobile_chats_tab.dart` line 735, `peer_card.dart` line 126) and the push preview helper `_channelWakePreviewText` in `push_notification_service.dart` only knows the `[file:` case.

Fix: ONE helper `messagePreviewText(message)` in `lib/src/core/utils/` that every preview surface calls (the three sites, the push previews, reply bars if they show raw text, and later the album "sent 4 photos" line). Rules: `[file:...]` becomes "Photo", "Video", "Voice message" or the file name from the attachment when known; `[e:name:hash]` becomes `:name:`; `[a:g:...]` becomes "GIF"; `[a:s:...]` becomes "Sticker"; mixed text keeps its words with the tokens replaced in place; the result is trimmed to one line. Add a CI source scan that forbids `lastMessage!.text` and `lastMessage.text` in `lib/src/ui/`, the same shape as the `expandedText()` send-site rule. Mobile and desktop both.
