# Area rules: Flutter UI, widgets, state

Moved out of CLAUDE.md on 2026-09-29, when the file was split by area. CLAUDE.md sends
every session here (and to the `hollow-ui` skill) BEFORE it writes or edits anything in
`lib/src/ui`, `lib/src/theme` or a UI-facing provider. Many of these are CI-guarded; the
guard catches the breakage, this page says why. Mobile-only UI rules are in
`rules_mobile_push.md`.

## Hover, dialogs, menus, toasts

- Hover/dialog patterns: NEVER animate a color from `Colors.transparent` (it lerps via
  black; pass `backgroundColor: null`); hover never paints outside its control. Dialogs =
  `HollowDialog`/`HollowDialogSurface` on a flat scrim (NO blur), ghost Cancel + ONE
  filled, `.danger` ONLY for destructive, yes/no = `showHollowConfirm`, actions run
  INSIDE (`onConfirm`/`onSubmit`, never pop-then-await), errors via `friendlyError`;
  selection = chips. `feedback_hover_state_patterns`.
- `showHollowDialog` pads by `viewInsets`; NEVER add them inside a builder (double pad).
  `feedback_dialog_keyboard_insets`.
- A wrapper that comes and goes with a flag (`if (busy) child = PopScope(...)`) REMOUNTS the
  subtree: scroll resets, `autofocus` refires, an error on a lower field ends up out of view.
  Keep wrappers unconditional and vary their parameters (`HollowDialog`, fixed 2026-10-01,
  `hollow_dialog_busy_test`). A dialog that returns from `runDialogAction` WITHOUT popping
  (a validation miss) clears `actionRunning` itself, or its confirm spins forever.
  `feedback_dart_patterns`.
- Context menus = ONE surface, `showHollowMenu`, opened via `ContextMenuTarget`
  (`hollow_menu.dart`, both CI-guarded): a dialog route, NOT an OverlayEntry; anchor via
  `overlayPositionOf`; the builder's ref = `menuRef`; dismiss by route IDENTITY.
  `project_issue61_context_menus`.
- `HollowToast` from non-widget code passes `overlayState:`
  (`hollowNavigatorKey.currentState?.overlay`); `Overlay.of(navKey.currentContext)`
  throws; run teardown BEFORE the toast. `feedback_toast_from_nonwidget_overlaystate`.
- A raw `OverlayEntry` host (emoji/sticker/GIF pickers) sits ABOVE every pushed route, so
  its dialogs render BEHIND it (#76): the host steps aside (`EmojiPickerBody.onModalFlow`
  -> `Offstage`). `feedback_overlay_entry_dialog_behind_host`.
- No raw `OverlayEntry` inside `SelectionArea`; use `showDialog` with
  `barrierColor: Colors.transparent`.
- Never construct `TextSelectionControls` in `build()` (identity churn = an app-wide
  selection-overlay crash); a raw-OverlayEntry teardown needs a `removed` guard.
  `feedback_textfield_overlay_selectioncontrols`.
- Per-item opacity: `AnimatedOpacity` (GPU-composited), never the `Opacity` widget.

## Shell, window, scale, theme

- Navigation shell: `layoutModeProvider` (a sync Notifier from `_bootstrap`, NEVER an
  AsyncNotifier-in-build, #58): Dock (default, `bottom_bar.dart`) / Classic (4-panel,
  never inherits Dock surfaces). Centre tabs = ONE via `setShellTab()` (CI-guarded);
  Settings = `openSettings()`, pages ONLY via `settings_kit.dart`; server settings ONLY
  via `openServerSettings(read, id)`, never the bare flag.
  `feedback_shell_centre_tabs_exclusive`, `feedback_settings_sections_dividers_explanations`.
- Window chrome: `window_manager` + `setAsFrameless()`; `DesktopWindowFrame` ABOVE the
  Navigator: a 32px `WindowTitleBar`, or the Dock's header IS it (`WindowControls` float
  UNSCALED; macOS: `hollow/traffic_lights`). Fullscreen ONLY via `fullscreenProvider`
  (Windows = runner `hollow/window`; `setFullScreen` no-ops frameless; CI-guarded).
  Dialogs NEVER enter the 44 px Dock header (`DialogChromeSlot` pads + shrinks
  `MediaQuery.size`). `feedback_annotation_window_management`.
- The window's outer 8px are pointer-DEAD (frameless resize border): controls hugging an
  edge never fire; inset by `kWindowEdgeDeadStrip`. Scrollbars = ONE app-wide gutter
  (`HollowScrollBehavior`), never a manual `Scrollbar` (double thumb).
  `feedback_window_edge_dead_strip`.
- Interface scale = ONE root scaled viewport (`UiScale`, `app.dart`): window coords are
  NOT overlay coords, so anchor via `overlayAnchorOf`/`overlayPositionOf`, never a bare
  `localToGlobal`; `MediaQuery.size` is the SLOT; zoom SHRINKS the viewport. Chat text =
  `ChatTextScale`. `project_display_scaling`.
- Theme: 5 surfaces: `surface` = chrome BELOW the canvas, NEVER a card; `background`
  canvas, `elevated` cards/inputs, `overlay` floating + opaque, `hover`. `accentText` =
  accent TEXT (`accent` fills), `textTertiary` faded; 4.5:1 everywhere (CI).
- Accessibility iron rules: PURPOSE labels on icon-only controls; focus rides
  `HollowFocusRing` (both CI-guarded); reduce motion ONLY via `ReduceMotionController` +
  `hollowMobileRoute()`; StatusDot = SHAPE (`filled:`); never `dart format` mid-edit.
  `project_accessibility_*`.

## Lists, chat, selection

- List rows with per-item loaded state need `ValueKey(item id)` + a `didUpdateWidget`
  reload; else Flutter re-parents State across different conversations.
  `feedback_listview_state_reuse_keys`.
- Chat lists are `reverse: true` via the shared `reversedChatList()`: newest = index 0,
  bottom-pinned, instant post-frame `jumpTo(0,0)` ONLY, scrolled-up reading FREEZES the
  display, `findChildIndexCallback` mandatory (CI-guarded). Extend the shared module,
  never copy it. `feedback_reverse_chat_lists`.
- Never wrap `SelectionArea` AROUND a scrolling message list: under `UiScale` the
  selection delegate mis-locates the drag edge, so clicks jump the viewport and
  autoscroll never stops (#35). Scope to ROWS via `selectionMustBeScopedToRows()`.
  `feedback_selection_area_scaled_viewport`.
- Media = ONE viewer route (`media_viewer_route.dart`): hosts act via `MediaViewerScope`
  captured at OPEN; the viewer OWNS the video transport; a fullscreen it entered is left
  on leave (Escape FIRST). Pinch focal = position+pan: keep `media_zoom_view.dart`'s
  re-anchor. `feedback_interactiveviewer_trackpad_focal_pan`.
- Unread counts compare MILLISECOND timestamps only (never rowid/order_us; seen comes
  from a ms-sorted `.last`); `recomputeServerUnread` gated on `newMessageCount > 0`. The
  floor = MAX(seen row, sibling `seen_ts:`, own newest) in SQL; read state crosses
  devices via `ReadMarkers` (live + on sibling verify), applied ONLY through
  `apply_remote_read_marker` (never `markSeen` = ping-pong); own posts carry `is_own`.
  `feedback_unread_ghost_ms_seen`, `project_issue80_read_state_sync`.

## Providers and state

- Server switching batches the 4 selection providers atomically in ONE synchronous
  block; canonical `server_strip.dart:_selectServer`. Wiki `couplings_gotchas`.
- Channel layout = ONE write path, ONE read shape: writes via
  `ChannelLayoutNotifier.mutate` ONLY (never `updateChannelLayout`); channel LISTS render
  `effectiveLayoutFrom`, never the stored layout. Both CI-guarded.
  `feedback_one_mutation_path_per_state`.
- CRDT property changes: optimistic UI update BEFORE the fire-and-forget FFI, and NEVER a
  read-back right after the write returns (set_* only queues; the read sees the PREVIOUS
  value; seed the cache via `applyLocalWrite`). `feedback_crdt_optimistic_update`,
  `feedback_crdt_read_after_write_race`.
- Channel visibility/posting UI reactivity: `_refreshServerState` reloads
  `channelListProvider` + invalidates `serverChannelsProvider(id)` on a retry ramp; the
  mobile chat route calls `loadForServer` on open. NEVER `ref.invalidate` in `initState`.
  `feedback_channel_visibility_posting_ui_reactivity`.
- Connection indicators read `overallConnectionProvider` ONLY (both user bars via
  `connectionVisual()`): never node status (green with no internet), never who ELSE is
  online; sync may refine "Online", never contradict it. Header `Offline` = OUR link
  down. `feedback_genuine_connection_status`.
- User actions visibly succeed, fail, or show busy: mutating wrappers RETHROW; call sites
  await + toast the failure (a bare call = zone crash); slow FFI behind a button =
  `_busy` + spinner; the success toast only AFTER the await.
  `feedback_ux_feedback_sweep_2026_07`.
- Profiles/avatars: profiles load light (`getAllProfilesLight()`, no blobs);
  `HollowAvatar` self-fetches, never pass `imageBytes:`; banners via `bannerProvider`; a
  reload MUST reuse the SAME `Uint8List` when unchanged (`reuseIfUnchanged`).
  `feedback_lazy_avatar_pattern`, `feedback_reload_unchanged_bytes_identity`.
- Event streaming: Rust->Dart `StreamSink`: `watch_network_events()` feeds
  `EventStreamNotifier`.
- Temp nicknames live in relay RAM and reset on `RelayDisconnected`.

## Input and shortcuts

- AltGr = Ctrl+Alt on Windows: a hand-rolled `isControlPressed` needs
  `&& !isAltPressed` (else AZERTY @/€ are swallowed); `SingleActivator` is immune.
  `feedback_altgr_ctrl_alt_shortcuts`.
- App shortcuts are REBINDABLE: no hardcoded key checks; match `appShortcutsProvider` via
  `matchesEvent`; the shell handler no-ops during keybind capture.
  `project_rebindable_shortcuts`.

## Frame budget

- A running `Ticker` requests a frame EVERY VSYNC even when idle: never a clock or a
  constantly restarted `AnimationController`; decorative motion = `Timer` +
  `GatedNotifier`. `feedback_ticker_is_a_frame_request`.
- Perf sentinels: `[SENTINEL]`, `timedChannelCall`, `FrameCensus`, `FrameScheduleProbe`
  (release too), `scripts/perf_*.ps1`.
