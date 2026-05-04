# HollowShell — Application Layout Container

Primary source: `lib/src/ui/shell/hollow_shell.dart` (~1918 lines). Supporting files: `lib/src/ui/shell/window_title_bar.dart`, `lib/src/ui/shell/mobile_nav.dart`, `lib/src/ui/app.dart`.

HollowShell is the root layout widget for the entire Hollow app. It sits inside `MaterialApp.home`, manages the bootstrap sequence (identity, license, node startup), owns the startup reveal animation, dispatches to one of three layout modes (dock, classic, mobile), handles global keyboard shortcuts, and orchestrates the split view system.

## Widget Classes Defined in hollow_shell.dart

The file defines the following widget classes:

- **`HollowShell`** — `ConsumerStatefulWidget`. The root layout. Owns the master reveal animation controller, bootstrap logic, keyboard handler, and the top-level `build()` that dispatches to dock/classic/mobile.
- **`_MemberPanelSlider`** — `StatefulWidget`. Animates the member panel sliding in/out from the right edge. Uses `ClipRect` + `Align(widthFactor)` + `FadeTransition`. Freezes content during close animation via `ProviderScope` override of `selectedServerProvider` to prevent "No peers online" flash.
- **`_DockSidebarSlider`** — `StatefulWidget`. Animates the channel sidebar sliding in/out from the left edge in dock mode. Same clip+align+fade pattern. Freezes the child widget during close so content does not collapse before the slide-out finishes.
- **`_SplitChatArea`** — `ConsumerStatefulWidget`. Renders two chat panes side by side with a draggable divider. The right pane gets its own `ProviderScope` overriding `selectedServerProvider`, `selectedChannelProvider`, and `selectedPeerProvider`.
- **`_RightPaneSidebar`** — `ConsumerStatefulWidget`. Channel sidebar for the right split pane. Loads channels from FFI (`crdt_api.getServerChannels`) independently of the global `channelListProvider`. Fixed width 200px.
- **`_RightPaneChatContent`** — `ConsumerWidget`. Chat content for the right split pane. Reads from the overridden providers to show either a channel chat, DM chat, or empty state.
- **`_RightChannelChat`** — `StatefulWidget`. Loads channel name from FFI and renders `ChannelChatPane` for the right split pane. Maintains a `_nameCache` map to avoid redundant FFI calls.
- **`_SplitDivider`** — `StatefulWidget`. Draggable vertical divider between split panes. 6px wide hit area, accent-colored when hovered or dragged, transparent otherwise. Uses `SystemMouseCursors.resizeColumn`.

Top-level function:
- **`_showServerSettingsDialog()`** — Shows `ServerSettingsPanel` as a dialog popup (800x600) using `showGeneralDialog`. Used during split view because inline settings would only replace one pane.

## Bootstrap Sequence

`_HollowShellState._bootstrap()` runs once from `initState()`. The sequence is:

1. **Check existing identity** — `storage_api.hasIdentity()`. If no identity exists, show `WelcomeDialog` (first launch). Result can be `'restored_mnemonic'`, `'restored_backup'`, `'create_new'`, or `null`.
2. **Load identity** — `identityProvider.notifier.load()`. If error, return early.
3. **Restore animation toggle** — `storage_api.loadSetting(key: 'disable_animations')`. If `'true'`, sets `HollowDurations.animationsDisabled = true`, pauses `SharedTickers`, and jumps the reveal controller to completion (`value = 1.0`).
4. **Show mnemonic dialog** — If `identity.mnemonic != null` (newly generated identity), saves it to DB and shows `MnemonicDialog`.
5. **License key gate** — Loads cached key from DB. Calls `fetchRelayStatus()`. If `licenseRequired` and no cached key, shows `LicenseKeyDialog`. Sets key via `network_api.setLicenseKey()`.
6. **Load servers** — `serverListProvider.notifier.loadFromDb()`.
7. **Load unread state** — Iterates all servers, fetches their channels via `crdt_api.getServerChannels`, fetches DM peer IDs via `storage_api.getDmPeerIds()`, then calls `unreadProvider.notifier.loadAll()`. This happens BEFORE node startup so sync events don't race.
8. **Start node** — `nodeProvider.notifier.start()`.
9. **Post-start loads** (non-blocking after node):
   - `invisibleModeProvider.notifier.load()` — UI-only sync of invisible mode toggle.
   - `serverStripLayoutProvider.notifier.loadLayout()` — folders + ordering.
   - `serverAvatarProvider.notifier.loadAll(serverIds)` — server avatar images.
   - `profileProvider.notifier.loadAll()` — cached user profiles.
   - `accentHueProvider.notifier.load()` — accent color.
   - `backgroundProvider.notifier.load()` — custom background image.
   - `accentPresetsProvider.notifier.load()` — accent presets.
   - `localNicknameProvider.notifier.loadAll()` — per-user local nicknames.
   - `friendsProvider.notifier.loadAll()` — friends list.
   - `shareTabProvider.notifier.loadAll()` — share entries for `hollow://share` cards.
   - `chatProvider.notifier.loadLastMessagePreviews(acceptedPeerIds)` — DM preview messages for home dashboard.
   - `favouriteFriendsProvider.notifier.load()` — favourite friends ordering.
   - `hiddenArchiveDmsProvider.notifier.load()` — hidden archive DMs.
   - `verifiedPeersProvider.notifier.load()` — verified peers list.
   - `systemNotificationProvider.notifier.init()` — native notifications (for tray mode).

## License Error Handling

`_listenForLicenseErrors()` is called from `initState()`. It uses `ref.listenManual(licenseErrorProvider, ...)` to react to license errors pushed from the Rust event stream. On error:

1. Stops the node (`nodeProvider.notifier.stop()`).
2. Clears the cached key (`licenseKeyProvider.notifier.clearKey()`).
3. Resets the error provider to `null`.
4. Maps the reason string to a user-friendly message: `'invalid_license_key'` / `'license_key_in_use'` / `'license_key_required'` / fallback.
5. Shows `LicenseKeyDialog` with the error message.
6. If user enters a new key, saves it and restarts the node.

## Startup Reveal Animation

The master animation is a single `AnimationController` with 2500ms duration, started on the first post-frame callback. It drives multiple sub-animations via `CurvedAnimation` with `Interval`:

**Classic layout sub-animations:**
- `_chatReveal` — Interval 0.30 to 0.70, `easeOutCubic`. Wraps the main chat area in a `FadeTransition`.

**Dock layout sub-animations:**
- `_friendsBarReveal` — Interval 0.0 to 0.25, `easeOutCubic`. Drives both `Align(heightFactor)` (slide down from top) and `FadeTransition` on the `FriendsBar`.
- `_bottomBarReveal` — Interval 0.05 to 0.30, `easeOutCubic`. Drives both `Align(heightFactor)` (slide up from bottom) and `FadeTransition` on the `BottomBar`.
- `_dockChatReveal` — Interval 0.20 to 0.60, `easeOutCubic`. Fades in the dock mode chat area.

**Child widget animations (via StartupRevealScope InheritedWidget):**
The `StartupRevealScope` wraps the entire layout. Child widgets call `StartupRevealScope.of(context)` to get the controller (returns `null` after completion — they skip all animation wrapping). `StartupRevealScope.interval(context, begin, end)` creates sub-interval `CurvedAnimation` objects for stagger effects. The `ServerStrip`, `WindowTitleBar`, and other shell widgets use this to stagger their own entrance.

When the master controller completes, `_revealComplete` is set to `true` and passed to `StartupRevealScope.isComplete`. This causes `of(context)` to return `null`, letting all child widgets render without animation overhead.

**Animations disabled mode:** If `disable_animations` setting is `'true'` in DB, the controller is jumped to `value = 1.0` immediately (no animation plays), and `HollowDurations.animationsDisabled` + `SharedTickers` are set accordingly.

**Important implementation detail:** `_chatRevealWrap()` always keeps the `FadeTransition` in the tree (even after reveal completes) so the child's `State` (particularly `AmbientBackground`'s `AnimationController`) is preserved — avoids resetting the ambient blob positions.

## Providers Read by HollowShell build()

The `build()` method of `_HollowShellState` reads these providers every frame:

| Provider | Type | Purpose |
|---|---|---|
| `localNicknameProvider` | `watch` | Keeps static ref in sync for `displayNameFor()` |
| `nodeProvider` | `watch` | `nodeState.status` passed to sidebar |
| `peersProvider` | `watch` | Map of online peers |
| `selectedPeerProvider` | `watch` | Currently selected DM peer ID |
| `chatProvider` | `watch` | Chat history map |
| `memberPanelProvider` | `watch` | Boolean: member panel open/closed |
| `serverListProvider` | `watch` | Map of server ID to `ServerInfo` |
| `selectedServerProvider` | `watch` | Currently selected server ID |
| `visibleChannelsProvider` | `watch` | Channels filtered by visibility permissions |
| `selectedChannelProvider` | `watch` | Currently selected channel ID |
| `channelLayoutProvider` | `watch` | JSON string for channel ordering/categories |
| `serverSettingsOpenProvider` | `watch` | Boolean: server settings panel open |
| `layoutModeProvider` | `watch` | `LayoutMode.dock` or `LayoutMode.classic` (async, defaults to dock) |
| `backgroundProvider` | `watch` | Custom background image + opacity |

Additional providers read within layout builders:
- `splitViewProvider` — read in dock layout for split view state
- `voiceChannelProvider` — read in both layouts for voice channel full-bleed detection
- `shareTabOpenProvider` — read for share dashboard display
- `archiveTabOpenProvider` — read for archive dashboard display

## Responsive Breakpoints and Layout Dispatch

Two constants define breakpoints:
- `_kDesktopBreakpoint = 1024.0`
- `_kTabletBreakpoint = 600.0`

In `build()`, a `LayoutBuilder` checks `constraints.maxWidth`:
- **width < 600** → Mobile layout (`_buildMobileLayout`)
- **width >= 600 and < 1024** → Tablet (uses dock or classic, with `isDesktop = false`)
- **width >= 1024** → Desktop (uses dock or classic, with `isDesktop = true`)

For non-mobile, the `layoutModeProvider` value determines which layout method is called:
- `LayoutMode.dock` → `_buildDockLayout()`
- `LayoutMode.classic` → `_buildClassicLayout()`

On desktop platforms (Windows/macOS/Linux), the body is wrapped in `DragToResizeArea` to restore edge/corner resize handles after `setAsFrameless()` removed them.

## Scaffold and Background Image Layer

After layout dispatch, the body is wrapped in a `Scaffold` with a `Stack` containing:
1. The layout body
2. `NotificationOverlay` — toast notifications
3. `ActiveCallBar` — active voice call indicator
4. `IncomingCallOverlay` — incoming call dialog

If `backgroundProvider.hasBackground` is true, the scaffold is further wrapped in a `Stack` with:
1. `Image.memory(bg.imageBytes!)` — full-bleed background image with `BoxFit.cover` on a black container
2. The scaffold on top (with transparent background so the image shows through)

The transparency levels for panels are NOT handled here — they're in `HollowApp.build()` (see below).

## Classic Layout Mode

`_buildClassicLayout()` renders the traditional Discord-like 4-panel layout:

```
StartupRevealScope
  └── Column
      └── Expanded Row
          ├── ServerStrip (RepaintBoundary, 72px implicit width)
          ├── ChannelSidebar (240px fixed width)
          ├── Expanded: chat area
          │   └── _chatRevealWrap → RepaintBoundary → AmbientBackground → AnimatedSwitcher → Container
          │       └── ServerSettingsPanel OR _buildChatOrEmpty()
          └── _MemberPanelSlider (if desktop or tablet, conditional on server selected + panel open + no VC full-bleed)
```

**Voice channel full-bleed detection:** When the selected channel is a voice channel AND the user is in that channel AND screen share or camera is active, the member panel is hidden (`vcScreenShareFullBleed = true`). This gives the video content maximum width.

**AnimatedSwitcher keying:** The chat area uses a `ValueKey` based on: `shareTabOpenProvider` → `'share'`, `archiveTabOpenProvider` → `'archive'`, `settingsOpen` → `'settings-{serverId}'`, else `selectedChannelId ?? selectedPeerId ?? 'empty'`. This drives cross-fade transitions when switching between views.

## Dock Layout Mode

`_buildDockLayout()` renders the modern Hollow layout with `FriendsBar` on top and `BottomBar` at the bottom:

```
StartupRevealScope
  └── Column
      ├── FriendsBar (ClipRect + AnimatedBuilder heightFactor + FadeTransition)
      ├── Expanded Row (ClipRect)
      │   ├── _DockSidebarSlider (visible when server selected)
      │   │   └── ChannelSidebar (240px, dockMode=true, no UserBar)
      │   ├── Expanded: chat area
      │   │   └── FadeTransition(_dockChatReveal) → AnimatedSwitcher
      │   │       └── _SplitChatArea OR single-pane (RepaintBoundary → AmbientBackground → AnimatedSwitcher → Container)
      │   └── _MemberPanelSlider (if desktop AND not in split view AND not VC full-bleed)
      └── BottomBar (ClipRect + AnimatedBuilder heightFactor + FadeTransition)
```

Key differences from classic:
- No `ServerStrip` — servers are accessed through the `FriendsBar` and `BottomBar`.
- Channel sidebar slides in/out via `_DockSidebarSlider` when a server is selected (hidden at home/DM view).
- `dockMode=true` passed to `ChannelSidebar` (affects styling: no `UserBar` shown).
- Member panel is hidden during split view to save horizontal space.
- When no peer or channel is selected, shows `HomeDashboard` instead of the empty chat placeholder.

**Pending migration handling:** When split view's left pane is closed, the right pane's context is stored as `pendingMigration` in `SplitViewState`. The dock layout checks for this in a `addPostFrameCallback` and migrates the right pane's context (server/channel/peer) to the global providers atomically (batch all writes to avoid intermediate rebuilds), then calls `clearPendingMigration()`. The batch includes fetching channels and layout for the server before writing to providers — this follows the critical rule about atomic server switching.

**Effective server ID for member panel:** During split view, if the focused pane is the right pane (`focusedPane == 1`), the member panel shows the right pane's server. Otherwise it shows the global `selectedServerId`.

## Mobile Layout

`_buildMobileLayout()` renders a single-panel view with bottom navigation:

```
Scaffold
  └── Column
      ├── Expanded: active tab content
      └── MobileNav (56px bottom nav bar)
```

Tab content is selected by `mobileTabProvider` (StateProvider<int>, default 0):
- **Tab 0 (Home):** `ChannelSidebar` with `width: null` (full width).
- **Tab 1 (Chat):** `AmbientBackground` + `AnimatedSwitcher` + `_buildChatOrEmpty()`.
- **Tab 2 (Members):** `MemberPanel(width: null)` (full width).
- **Tab 3 (Settings):** `_buildSettingsPlaceholder()` (placeholder text).

The `MobileNav` widget renders 4 tabs: Home (house icon), Chat (message icon), Members (users icon), Settings (gear icon). Each tab uses `HollowPressable` for tap handling. Active tab gets accent color; inactive gets `textSecondary`.

When a peer or channel is selected via the sidebar, `mobileTabProvider` is automatically set to `1` (Chat tab) to navigate the user to the chat view.

## Split View System

Split view is dock-mode only. Activated by `Ctrl+Shift+\` or programmatically via `splitViewProvider.notifier.openSplit()`.

**State model** (`lib/src/core/providers/split_view_provider.dart`):
- `SplitViewState` has: `rightPane` (PaneContext?), `dividerPosition` (0.0-1.0, default 0.5), `focusedPane` (0 or 1), `pendingMigration` (PaneContext?).
- `PaneContext` has: `serverId`, `channelId`, `peerId`, `settingsOpen`.
- `isSplit` is true when `rightPane != null`.

**ProviderScope isolation:** The entire right section (sidebar + chat) is wrapped in a `ProviderScope` with overrides for `selectedServerProvider`, `selectedChannelProvider`, and `selectedPeerProvider`. This lets the right pane have completely independent navigation state. The `ProviderScope` key includes `rightPane.serverId:channelId:peerId` so it rebuilds when navigation changes.

**Visual layout:**
```
Row
  ├── Flexible(leftFlex): Left pane chat (uses global providers)
  │   └── GestureDetector(onTap: setFocus(0)) → AnimatedContainer(border) → RepaintBoundary → AmbientBackground → AnimatedSwitcher → content
  ├── _SplitDivider (6px, draggable)
  ├── _RightPaneSidebar (200px fixed, if server selected)
  └── Flexible(rightFlex): Right pane chat (uses overridden providers)
      └── GestureDetector(onTap: setFocus(1)) → AnimatedContainer(border) → RepaintBoundary → AmbientBackground → content
```

**Focus indicator:** The focused pane gets a 2px accent-colored top border. The unfocused pane has a transparent top border.

**Divider position:** Stored as a 0.0-1.0 ratio, clamped to 0.3-0.7. Converted to flex values by multiplying by 1000 and rounding. Dragging uses delta-based computation (`details.delta.dx / totalWidth`) to avoid snap-to-center behavior.

**Right pane sidebar:** `_RightPaneSidebar` fetches channels independently from FFI (not from `channelListProvider`) because the global provider is overridden in the ProviderScope. It caches the loaded server ID and re-fetches when it changes. Width is 200px (narrower than the left sidebar's 240px).

**Right pane chat content:** `_RightPaneChatContent` reads from the overridden providers. For channel chats, it delegates to `_RightChannelChat` which loads the channel name from FFI and caches it.

**Pane closing:** `closePane(0)` (left) stores the right pane context as `pendingMigration`, then clears the split. The shell's dock layout migrates that context to global providers on the next frame. `closePane(1)` (right) simply clears the split, leaving the left pane (global providers) as-is.

**Server settings in split view:** Opens as a dialog popup (800x600) via `_showServerSettingsDialog()` instead of replacing a pane inline. This uses `showGeneralDialog` with scale 0.95->1.0 + fade transition, barrier dismissible.

## Panel Toggling

**Member panel:** Controlled by `memberPanelProvider` (StateProvider<bool>, default `true`). Toggle via `Ctrl+Shift+M` keyboard shortcut or the users icon button in channel headers. The `_MemberPanelSlider` animates the panel in/out with `HollowDurations.normal` duration. During close animation, it freezes the content by wrapping `MemberPanel` in a `ProviderScope` that overrides `selectedServerProvider` with the cached `_frozenServerId`. This prevents the panel from showing stale "No peers online" state while sliding out.

**Channel sidebar (dock mode):** The `_DockSidebarSlider` shows/hides the sidebar based on whether a server is selected (`selectedServerId != null`). Same clip+align+fade animation pattern. During close, it shows the frozen child widget to prevent content collapse.

**Channel search:** `channelSearchOpenProvider` (StateProvider<bool>, default `false`). Toggled by `Ctrl+K`.

**Server settings:** `serverSettingsOpenProvider` (StateProvider<bool>, default `false`). In non-split mode, toggles between settings panel and chat. In split mode, opens as a dialog instead.

## Keyboard Shortcuts

Registered globally on `HardwareKeyboard.instance` (not focus-dependent). Registered in `initState()`, removed in `dispose()`. Only processes `KeyDownEvent`.

| Shortcut | Action |
|---|---|
| `Ctrl+,` | Open `UserSettingsDialog` |
| `Ctrl+Shift+M` | Toggle member panel |
| `Ctrl+K` | Toggle channel search |
| `Ctrl+Shift+\` | Toggle split view (dock mode only) |
| `Ctrl+1` | Focus left pane (split view only) |
| `Ctrl+2` | Focus right pane (split view only) |

## Chat Area Content Resolution

`_buildChatOrEmpty()` determines what to show in the main chat area. Resolution order:

1. `shareTabOpenProvider == true` → `ShareDashboard`
2. `archiveTabOpenProvider == true` → `ArchiveDashboard`
3. `selectedChannelId != null`:
   - If `channel.channelType == ChannelType.voice` → `VoiceChannelPane` (keyed by `'vc:$channelId'`)
   - Otherwise → `ChannelChatPane` (keyed by `'ch:$channelId'`)
   - Fallback → `_buildChannelPlaceholder()` (shows `#channelName` header + placeholder text)
4. `selectedPeerId == null`:
   - Dock mode → `HomeDashboard`
   - Classic mode → `_buildEmptyChat()` (placeholder with message icon)
5. `selectedPeerId != null` → `ChatPane` (keyed by peer ID)

## Channel Sidebar Builder

`_buildChannelSidebar()` constructs a `ChannelSidebar` with all necessary callbacks:

**onPeerSelected:** Clears share/archive tab state, sets `selectedPeerProvider`, marks DM as read via `unreadProvider`, switches to chat tab on mobile.

**onChannelSelected:** Sets `selectedChannelProvider`, remembers last channel for current server in `lastChannelPerServerProvider`, marks channel as read via `unreadProvider`, switches to chat tab on mobile.

**onCreateChannel:** Shows `CreateChannelDialog` for the current server.

**onOpenSettings:** In split view, opens server settings as a dialog. Otherwise toggles `serverSettingsOpenProvider`.

**canManageChannels:** Computed from `myPermissionsProvider(serverId)`, checking `Permission.manageChannels` bit.

## WindowTitleBar — Placement and Rationale

**CRITICAL ARCHITECTURE:** The `WindowTitleBar` is NOT inside `HollowShell`. It lives in `MaterialApp.builder` in `lib/src/ui/app.dart`. This is documented as a critical rule in CLAUDE.md.

**Reason:** If the title bar were inside `HollowShell` (inside `MaterialApp.home`), then `showDialog`/`showGeneralDialog` calls would create overlays that cover the title bar, making the window controls inaccessible during dialogs. By placing it in `MaterialApp.builder`, it sits ABOVE the Navigator in the widget tree, so dialog routes cannot occlude it.

**Implementation in HollowApp (`lib/src/ui/app.dart`):**
```
MaterialApp(
  builder: isDesktop
      ? (context, child) => Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                const WindowTitleBar(),
                Expanded(child: ClipRect(child: child)),
              ],
            ),
          )
      : null,
)
```

The `ClipRect` around the navigator child prevents `BackdropFilter` blur from dialogs from bleeding up into the title bar area.

**WindowTitleBar widget** (`lib/src/ui/shell/window_title_bar.dart`): 32px tall container with `hollow.opaqueBackground` color. Layout: `[Hollow branding] [DragToMoveArea ────] [─] [□] [✕]`. The branding and buttons have their own startup reveal intervals (0.0-0.15 for branding, 0.08-0.20 for buttons).

Widget classes in window_title_bar.dart:
- **`WindowTitleBar`** — StatelessWidget, the 32px bar.
- **`_WindowButton`** — StatefulWidget base for window control buttons. No Material ripple, instant color change on hover. 46x32px size.
- **`_MinimizeButton`** — calls `windowManager.minimize()`.
- **`_MaximizeButton`** — StatefulWidget with `WindowListener` mixin. Tracks maximized state, shows square or columns icon, toggles between `windowManager.maximize()` and `unmaximize()`.
- **`_CloseButton`** — calls `windowManager.close()`. Hover color is red (#E81123).

## HollowApp — Theme and Background Transparency

`lib/src/ui/app.dart` defines `HollowApp` (`ConsumerWidget`), the `MaterialApp` root.

Providers read:
- `themeModeProvider` — `ThemeMode.dark` or `.light`
- `accentHueProvider` — custom accent hue
- `backgroundProvider` — custom background image

When a background image is set (`bg.hasBackground`), theme colors get alpha-adjusted:
- `background` (chat area, home dashboard) → `base * 0.65`, clamped 0.15-0.8 (most transparent, see image through)
- `surface` (sidebars, member panel, channel header) → `base * 0.85`, clamped 0.4-0.92 (more opaque)
- `elevated` (cards, inputs) → `base * 0.95`, clamped 0.5-0.95 (most opaque)
- `scaffoldBackgroundColor` set to `Colors.transparent`

Global navigator key: `hollowNavigatorKey` — used for showing toasts from providers without `BuildContext`.

## MobileNav Widget

`lib/src/ui/shell/mobile_nav.dart` defines:

- **`mobileTabProvider`** — `StateProvider<int>`, default 0. Indexes: 0=Home, 1=Chat, 2=Members, 3=Settings.
- **`MobileNav`** — `ConsumerWidget`. 56px high container with top border. Contains a `Row` of 4 `_NavTab` widgets.
- **`_NavTab`** — `StatelessWidget`. `Expanded` + `HollowPressable` + `Column(icon, label)`. Active state: accent color + weight 600. Inactive: textSecondary + weight 400.

## Voice Channel Full-Bleed Mode

Both classic and dock layouts detect when the user is viewing a voice channel with active screen share or camera. The condition is:
```dart
selectedChannel?.channelType == ChannelType.voice
    && vcState.isInVoiceChannel
    && vcState.currentChannelId == selectedChannelId
    && (vcState.isScreenShareActive || vcState.isCameraActive)
```

When true (`vcScreenShareFullBleed`), the member panel is hidden to give the video/screen share content maximum horizontal space.

## AnimatedSwitcher Pattern

The chat area consistently uses `AnimatedSwitcher` with `HollowDurations.normal` for cross-fade transitions. The `layoutBuilder` uses a `Stack` with `Alignment.topCenter` to layer the outgoing and incoming children. The `switchInCurve` uses `HollowCurves.enter` and `switchOutCurve` uses `HollowCurves.exit`. View identity is driven by `ValueKey` based on the current view state (share/archive/settings/channel/peer/empty).

## RepaintBoundary Usage

Performance optimization: `RepaintBoundary` wraps `ServerStrip`, `FriendsBar`, `BottomBar`, `MemberPanel`, the chat `AmbientBackground`, and each split pane's background. This isolates repaint regions so animations in one panel don't trigger repaints in others.

## DragToResizeArea

On desktop platforms (Windows/macOS/Linux), the entire layout body is wrapped in `DragToResizeArea` from the `window_manager` package. This restores edge and corner resize handles that were removed when `setAsFrameless()` was called to enable the custom title bar. Without this wrapper, the window cannot be resized from its edges.
