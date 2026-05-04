# VoiceChannelPane -- Voice Channel View with Video, Screen Share, and Chat

Voice channel composite view located at `lib/src/ui/chat/voice_channel_pane.dart` (~1358 lines). Wraps `ChannelChatPane` and adds camera grid, screen share full-bleed, floating controls pill, chat overlay slider, and source switcher. Conditionally renders one of four layout modes based on voice channel state.

## Widget Class Hierarchy

- `VoiceChannelPane` -- `ConsumerStatefulWidget`, top-level widget. Constructor params: `serverId`, `channelId`, `channelName`.
- `_VoiceChannelPaneState` -- main state class (~1000 lines). Manages overlay visibility, chat overlay pin, focused video peer, and builds all layout modes.
- `_VoiceControlsPill` -- `ConsumerStatefulWidget`, the floating controls bar at bottom center during camera/screen share modes. Contains mute, deafen, camera, screen share, disconnect buttons plus call duration timer.
- `_VoiceControlsPillState` -- manages duration timer, screen share toggle.
- `_OverlaySlider` -- `StatefulWidget`, animated slide-in/out panel for the chat overlay during camera/screen share modes.
- `_OverlaySliderState` -- `SingleTickerProviderStateMixin`, manages `AnimationController` for slide animation.

## Four Layout Modes

The `build()` method of `_VoiceChannelPaneState` checks `voiceChannelProvider` state and renders one of four modes:

1. **Not in this channel**: If `vcState.currentServerId != widget.serverId` or `vcState.currentChannelId != widget.channelId`, renders a plain `ChannelChatPane` (no voice UI). This is the default when the user hasn't joined the voice channel.

2. **Audio-only (no video/screen share)**: If in the channel but neither `isScreenShareActive` nor `isCameraActive`, renders a plain `ChannelChatPane`. Voice participants are visible in the member sidebar instead.

3. **Camera grid view**: If `vcState.isCameraActive` (local or any peer has camera on) and no screen share, renders `_buildCameraGridView()`.

4. **Screen share view**: If `vcState.isScreenShareActive` (local or any peer sharing screen), renders `_buildScreenShareView()`. This takes priority over camera grid -- screen share can coexist with cameras in "mixed mode" via the source switcher.

## State Variables in _VoiceChannelPaneState

- `_overlayHideTimer` -- nullable `Timer`, auto-hides overlays (controls pill, chat toggle) after 1 second of no mouse activity.
- `_overlaysVisible` -- bool, controls opacity of floating controls and chat toggle. Managed by `_resetOverlayTimer()`.
- `_chatOverlayPinned` -- bool, whether the side chat panel is pinned open. When pinned, the overlay hide timer is suppressed.
- `_focusedVideoPeerId` -- nullable String, which peer's video tile is in fullscreen mode. Null means grid view. Only used in camera grid mode.

## Overlay Visibility System

**`_resetOverlayTimer()`**: Cancels existing timer, sets `_overlaysVisible = true` (shows overlays), then starts a 1-second timer to hide overlays. If `_chatOverlayPinned` is true, skips starting the timer (overlays stay visible).

**`_pinOverlays()`**: Cancels timer, sets `_overlaysVisible = true`. Does NOT start a new hide timer. Used when mouse enters interactive elements (controls pill, chat toggle, chat panel).

All floating overlays use `AnimatedOpacity` with `_overlaysVisible` controlling opacity 0/1, plus `IgnorePointer(ignoring: !_overlaysVisible)` to prevent interaction when hidden. Duration is `HollowDurations.normal`.

**Mouse tracking**: The camera grid and screen share views are wrapped in `MouseRegion` with `onHover` and `onEnter` calling `_resetOverlayTimer()`. This shows overlays on any mouse movement and starts the auto-hide countdown.

## Camera Grid View

`_buildCameraGridView()`: Builds list of peers with cameras on. Local peer added first (if `isCameraOn`), then peers from `vcState.peerCameraOn` where value is true. If `_focusedVideoPeerId` is set but that peer no longer has camera on, clears focus.

**Layout structure**: `Stack` with three layers:
- **Layer 0**: Video grid or fullscreen camera (black background, `Positioned.fill`).
- **Layer 1 (right)**: Chat overlay toggle + sliding chat panel.
- **Layer 2 (bottom center)**: Floating `_VoiceControlsPill`.

### Video Grid Layout (_buildVideoGrid)

Adaptive grid based on number of camera peers `n`:

| n | Layout |
|---|---|
| 0 | `SizedBox.shrink()` |
| 1 | Single tile, full area, tap disabled |
| 2 | Horizontal `Row` with two `Expanded` tiles |
| 3 | Top row: 2 tiles side by side. Bottom row: 1 tile centered at 50% width (`FractionallySizedBox(widthFactor: 0.5)`) |
| 4 | 2x2 grid: two `Row`s of two `Expanded` tiles in a `Column` |
| 5+ | Top row: 3 tiles. Bottom row: 2 tiles centered (using `Spacer` + `Expanded(flex: 2)` pattern) |

### Video Tile (_buildVideoTile)

Each tile is a `GestureDetector` (tap to focus/fullscreen, disabled for single-tile view). Contains a `Container` with 2px margin, `hollow.elevated` background, `radiusSm` border radius, anti-alias clipping.

**Speaking indicator**: If `vcState.isSpeaking(peerId)` returns true, the tile gets a 2px accent-color border.

**Content stack**:
- **Video layer**: If renderer exists (from `voiceChannelProvider.notifier.getCameraRenderer(peerId)`), renders `RTCVideoView` wrapped in `RepaintBoundary`. Local video is mirrored (`mirror: isLocal`). ObjectFit is `Contain`.
- **Avatar fallback**: If no renderer, shows `HollowAvatar` (48px) + name label below. Uses `profileProvider` for avatar bytes.
- **Name label overlay**: Only shown when renderer exists. Bottom-left positioned, black 60% alpha background with rounded corners, white text caption at 10px.

**Name resolution**: Local peer shows "You". Remote peers use `displayNameFor(profiles, peerId)`.

### Fullscreen Camera Mode (_buildFullscreenCamera)

Entered by tapping a tile in the grid. Shows one peer's video full-bleed (using `RTCVideoViewObjectFitCover` for full coverage) plus PiP thumbnails for other peers.

**Layout**: `GestureDetector` (tap anywhere to exit fullscreen, sets `_focusedVideoPeerId = null`). Stack with:
- **Main video**: `Positioned.fill`, RTCVideoView with Cover fit (or avatar fallback if no renderer).
- **"Click to exit" hint**: Top-left, semi-transparent black chip with "Click to exit" text, fixed at 70% opacity.
- **PiP thumbnails**: Bottom center (64px from bottom), horizontally centered `Row` of 120x90px thumbnails for other peers. Each thumbnail: `GestureDetector` to switch focused peer on tap, rounded 8px corners, border, shadow. Contains `RTCVideoView` with Cover fit (or avatar fallback).

## Screen Share View

`_buildScreenShareView()`: Full-bleed view activated when any screen share is active. Can coexist with cameras in "mixed mode" where the source switcher tabs allow switching between screen shares and camera feeds.

**Layout**: `Stack` with four layers:
- **Layer 0**: Full-bleed content -- either focused camera content or screen share content.
- **Layer 1 (top)**: Source switcher tabs (only when `_countActiveSources(vcState) > 1`).
- **Layer 2 (right)**: Chat overlay toggle + sliding chat panel (identical to camera grid view).
- **Layer 3 (bottom center)**: Floating `_VoiceControlsPill`.

### Screen Share Content (_buildScreenShareContent)

Three states based on who is focused:

1. **Local user is focused and sharing**: Shows self-preview with `localScreenShareRenderer`. If renderer available, renders `RTCVideoView` with Contain fit. Otherwise shows monitor icon + "You are sharing your screen" / "Others can see your screen" text. Top-right corner: quality label chip (if `screenShareLabel` is set, e.g. "1080p60") + red "Stop sharing" `HollowButton.danger` that calls `voiceChannelProvider.notifier.stopScreenShare()`.

2. **No focused peer**: Shows waiting state -- monitor icon at 30% opacity + "Waiting for screen share..." caption.

3. **Remote peer is focused**: Shows their screen via `getScreenShareRenderer(focusedPeerId)`. RTCVideoView with Contain fit, black background. If renderer not yet available, shows "Connecting to screen share..." with monitor icon. If `remoteLabel` exists (`peerScreenShareLabels[focusedPeerId]`), shows quality label chip in top-right.

### Focused Camera Content (_buildFocusedCameraContent)

Used in mixed mode when user selects a camera source from the switcher. Full-bleed black background. Uses `getCameraRenderer(focusedPeerId)`. RTCVideoView with Contain fit, mirrored for local. Avatar fallback with "Connecting to {name}'s camera..." text.

### Source Switcher (_buildSharerSwitcher)

Only shown when `_countActiveSources(vcState) > 1`. Centered at top of screen. Semi-transparent pill container (`surface.withValues(alpha: 0.9)`, pill radius, border, shadow).

**`_countActiveSources(vcState)`**: Counts: (1 if local screen sharing) + (count of peers screen sharing) + (1 if local camera on) + (count of peers with camera on).

**Source list**: Builds `(peerId, type)` tuples where type is `'screen'` or `'camera'`. Screen share sources listed first, then camera sources.

Each tab: `HollowPressable` with icon (monitor for screen, video for camera), avatar (18px), name ("You" for local, display name for remote). Focused tab gets `accentMuted` background, accent-colored icon and bold text. Non-focused tabs have transparent background, secondary text color.

Tapping a tab calls `voiceChannelProvider.notifier.setFocusedSource(peerId, sourceType)`.

## Chat Overlay (Side Panel)

Identical structure in both camera grid and screen share views. Right-aligned, full height. Consists of:

### Toggle Button
24px wide, 48px tall tab with chevron icon. Semi-transparent surface background (88% alpha), left-rounded corners (8px), left/top/bottom border. Shows `chevronLeft` when closed, `chevronRight` when open. Tapping toggles `_chatOverlayPinned`. Mouse enter/exit calls `_pinOverlays()` / `_resetOverlayTimer()`.

Wrapped in `AnimatedOpacity` + `IgnorePointer` controlled by `_overlaysVisible`.

### Sliding Chat Panel (_OverlaySlider)
360px wide panel that slides in from the right when `_chatOverlayPinned = true`. Contains a full `ChannelChatPane` instance with the same `serverId`, `channelId`, `channelName`.

**`_OverlaySlider`**: `StatefulWidget` with `SingleTickerProviderStateMixin`. Creates `AnimationController` with `HollowDurations.normal` duration. Uses `CurvedAnimation` with `HollowCurves.enter` forward curve and `HollowCurves.exit` reverse curve. `didUpdateWidget` triggers `_controller.forward()` or `_controller.reverse()` when visibility changes.

**Build**: `AnimatedBuilder` with the curved animation. When value is 0.0, renders nothing (`SizedBox.shrink()`). Otherwise renders `ClipRect` > `Align(widthFactor: _curved.value)` > `FadeTransition(opacity: _curved)` > `MouseRegion` (for hover enter/exit) > child. This creates a slide+fade effect where the panel clips from the right edge.

Container styling: 88% alpha surface background, left border at 50% alpha.

## Floating Controls Pill (_VoiceControlsPill)

`ConsumerStatefulWidget` positioned at bottom center of both camera grid and screen share views. Takes `serverId`, `channelId`, `onHoverEnter`, `onHoverExit` callbacks.

### Duration Timer
`_VoiceControlsPillState.initState()` starts a `Timer.periodic` every 1 second. Reads `voiceChannelProvider.joinedAt` and computes elapsed duration. Formats as `MM:SS` with `padLeft(2, '0')`. Disposed in `dispose()`.

### Pill UI
`MouseRegion` wrapping a `Container` with:
- Surface background at 90% alpha
- Pill radius (`HollowRadius.pill`)
- Border at 50% alpha
- Drop shadow (black 30% alpha, 16px blur, 4px Y offset)

Contents (left to right in a `Row`):

1. **Status dot** -- `StatusDot(color: hollow.success, size: 8, pulse: true)`. Green pulsing dot indicating active call.
2. **Duration** -- `MM:SS` text in caption style with tabular figures (`FontFeature.tabularFigures()`) for stable width.
3. **Mute button** -- `HollowTooltip("Unmute"/"Mute")` wrapping `HollowPressable`. Icon: `micOff` (red error color) when muted, `mic` (secondary) when unmuted. Calls `voiceChannelProvider.notifier.toggleMute()`.
4. **Deafen button** -- `HollowTooltip("Undeafen"/"Deafen")` wrapping `HollowPressable`. Icon: `headphones`. Red error color when deafened, secondary when not. Calls `voiceChannelProvider.notifier.toggleDeafen()`.
5. **Camera toggle** -- `HollowTooltip("Turn off camera"/"Turn on camera")` wrapping `HollowPressable`. Icon: `video` (accent) when on, `videoOff` (secondary) when off. Calls `voiceChannelProvider.notifier.toggleCamera()`.
6. **Screen share** -- Desktop only (`Platform.isWindows || Platform.isMacOS || Platform.isLinux`). `HollowTooltip("Stop sharing"/"Share screen")` wrapping `HollowPressable`. Icon: `monitor`, accent when sharing, secondary when not. Calls `_handleScreenShareToggle(vcState)`.
7. **Disconnect** -- `HollowTooltip("Disconnect")` wrapping `HollowPressable`. Icon: `phoneOff` in error color. Calls `voiceChannelProvider.notifier.leaveChannel()`.

### Screen Share Toggle
`_handleScreenShareToggle(vcState)`: If currently sharing, calls `stopScreenShare()`. If not, opens `showScreenShareDialog(context)` from `lib/src/ui/dialogs/screen_share_dialog.dart`. If user selects a source, calls `startScreenShare(sourceId, width, height, fps, shareAudio: selection.shareAudio)`.

## Speaking Indicators

Visual feedback for voice activity detection (VAD):

- **Camera grid tiles**: `_buildVideoTile()` checks `vcState.isSpeaking(peerId)`. If speaking, the tile container gets a 2px accent-color border via `Border.all(color: hollow.accent, width: 2)`.
- **No other speaking indicators in VoiceChannelPane itself** -- the member sidebar shows speaking state for audio-only mode via the member panel provider.

## Providers Read by This Widget

| Provider | Widget | Usage |
|---|---|---|
| `voiceChannelProvider` | `_VoiceChannelPaneState`, `_VoiceControlsPill` | Central voice channel state (participants, muted, deafened, camera, screen share, speaking, joined time) |
| `identityProvider` | `_VoiceChannelPaneState`, `_buildCameraGridView`, `_buildScreenShareView` | Local peer ID for distinguishing self from remote |
| `profileProvider` | `_buildVideoTile`, `_buildFullscreenCamera`, `_buildFocusedCameraContent`, `_buildSharerSwitcher` | Display names and avatar bytes for all peers |

Note: `VoiceChannelPane` does not directly read chat-related providers -- it delegates all chat functionality to `ChannelChatPane` which handles its own provider subscriptions.

## Interaction Summary

| Action | Handler | Effect |
|---|---|---|
| Mouse move/enter in video area | `_resetOverlayTimer()` | Shows overlays, starts 1s hide timer |
| Mouse enters interactive overlay | `_pinOverlays()` | Keeps overlays visible, cancels timer |
| Tap chat toggle tab | `setState(() => _chatOverlayPinned = !_chatOverlayPinned)` | Slides chat panel in/out |
| Tap video tile in grid | `setState(() => _focusedVideoPeerId = peerId)` | Enters fullscreen for that peer |
| Tap anywhere in fullscreen | `setState(() => _focusedVideoPeerId = null)` | Returns to grid view |
| Tap PiP thumbnail in fullscreen | `setState(() => _focusedVideoPeerId = peerId)` | Switches fullscreen to that peer |
| Tap source switcher tab | `voiceChannelProvider.notifier.setFocusedSource(peerId, type)` | Switches full-bleed content to that source |
| Tap mute button | `voiceChannelProvider.notifier.toggleMute()` | Toggles local mic mute |
| Tap deafen button | `voiceChannelProvider.notifier.toggleDeafen()` | Toggles local deafen (mute + no audio) |
| Tap camera button | `voiceChannelProvider.notifier.toggleCamera()` | Toggles local camera on/off |
| Tap screen share button | `_handleScreenShareToggle()` | Opens source picker or stops sharing |
| Tap disconnect button | `voiceChannelProvider.notifier.leaveChannel()` | Leaves voice channel |
| Tap "Stop sharing" button | `voiceChannelProvider.notifier.stopScreenShare()` | Stops local screen share (in self-preview) |

## VoiceChannelState Fields Used by This Widget

From `lib/src/core/providers/voice_channel_provider.dart`:

- `currentServerId`, `currentChannelId` -- determines if user is in this voice channel.
- `isScreenShareActive` (computed) -- true if any local or remote screen share active.
- `isCameraActive` (computed) -- true if any local or remote camera active.
- `isCameraOn` -- local camera state.
- `peerCameraOn` -- `Map<String, bool>` of remote peer camera states.
- `isScreenSharing` -- local screen share state.
- `peerScreenSharing` -- `Map<String, bool>` of remote peer screen share states.
- `focusedScreenSharePeerId` -- which peer's content is shown full-bleed.
- `focusedSourceType` -- `'screen'` or `'camera'` for mixed mode.
- `screenShareLabel` -- quality label for local screen share.
- `peerScreenShareLabels` -- quality labels for remote screen shares.
- `isMuted`, `isDeafened` -- local audio state (for controls pill).
- `speakingPeers` -- `Set<String>` for speaking indicators.
- `joinedAt` -- `DateTime` for call duration calculation.

## External Widget Dependencies

- `ChannelChatPane` -- `lib/src/ui/chat/channel_chat_pane.dart` (used in all four modes for text chat)
- `HollowAvatar` -- `lib/src/ui/components/hollow_avatar.dart`
- `HollowButton` -- `lib/src/ui/components/hollow_button.dart` (danger variant for "Stop sharing")
- `HollowPressable` -- `lib/src/ui/components/hollow_pressable.dart`
- `HollowTooltip` -- `lib/src/ui/components/hollow_tooltip.dart`
- `StatusDot` -- `lib/src/ui/components/status_dot.dart` (green pulsing dot in controls pill)
- `showScreenShareDialog` -- `lib/src/ui/dialogs/screen_share_dialog.dart`
- `displayNameFor` -- `lib/src/ui/chat/chat_pane.dart`
- `HollowCurves`, `HollowDurations` -- `lib/src/ui/animations/hollow_curves.dart`
- `RTCVideoView`, `RTCVideoViewObjectFit` -- `flutter_webrtc` package
