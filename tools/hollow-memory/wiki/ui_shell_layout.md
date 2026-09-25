# HollowShell — Application Layout Container

Primary source: `lib/src/ui/shell/hollow_shell.dart` (~1918 lines). Supporting files: `lib/src/ui/shell/window_title_bar.dart`, `lib/src/core/providers/window_chrome_provider.dart`, `lib/src/ui/shell/mobile_nav.dart`, `lib/src/ui/app.dart`.

HollowShell is the root layout widget for the entire Hollow app. It sits inside `MaterialApp.home`, manages the bootstrap sequence (identity, license, node startup), owns the one startup fade, dispatches to one of three layout modes (dock, classic, mobile), handles global keyboard shortcuts, and orchestrates the split view system.

## Widget Classes Defined in hollow_shell.dart

The file defines the following widget classes:

- **`HollowShell`** — `ConsumerStatefulWidget`. The root layout. Owns the startup fade controller (`_shellFade`), bootstrap logic, keyboard handler, and the top-level `build()` that dispatches to dock/classic/mobile.
- **`_MemberPanelSlot`** — `StatelessWidget`. The member panel's place in the row: `_MemberPanelWithSeam` when `visible`, else `SizedBox.shrink()`. It shows and hides instantly; a width animation would re-wrap the chat text on every frame.
- **`_SplitChatArea`** — `ConsumerStatefulWidget`. Renders two chat panes side by side with a draggable divider. The right pane gets its own `ProviderScope` overriding `selectedServerProvider`, `selectedChannelProvider`, and `selectedPeerProvider`.
- **`_RightPaneSidebar`** — `ConsumerStatefulWidget`. Channel sidebar for the right split pane. Loads channels from FFI (`crdt_api.getServerChannels`) independently of the global `channelListProvider`. Fixed width 200px.
- **`_RightPaneChatContent`** — `ConsumerWidget`. Chat content for the right split pane. Reads from the overridden providers to show either a channel chat, DM chat, or empty state.
- **`_RightChannelChat`** — `StatefulWidget`. Loads channel name from FFI and renders `ChannelChatPane` for the right split pane. Maintains a `_nameCache` map to avoid redundant FFI calls.
- **`_SplitDivider`** — `StatefulWidget`. Draggable vertical divider between split panes. 6px wide hit area, accent-colored when hovered or dragged, transparent otherwise. Uses `SystemMouseCursors.resizeColumn`.

Top-level function:
- **`_serverSettingsPlace()`** — The server settings place when `serverSettingsOpenProvider` is set: replaces the channel sidebar + chat pane (Classic keeps the server strip), covers split view too, and wraps a non-selected target in `ForeignServerSettingsScope`. See `ui_server_settings.md`.

## Bootstrap Sequence

`_HollowShellState._bootstrap()` runs once from `initState()`. The sequence is:

1. **Check existing identity** — `storage_api.hasIdentity()`. If no identity exists, show `WelcomeDialog` (first launch). Result can be `'restored_mnemonic'`, `'restored_backup'`, `'create_new'`, or `null`.
2. **Load identity** — `identityProvider.notifier.load()`. If error, return early.
3. **Restore Reduce motion** — `await ref.read(reduceMotionProvider.future)` right after the identity load opens the DB (building the provider applies the persisted mode to `ReduceMotionController`). If motion is reduced, the startup fade snaps to completion (`_shellFade.value = 1.0`).
4. **Show mnemonic dialog** — If `identity.mnemonic != null` (newly generated identity), saves it to DB and shows `MnemonicDialog`.
5. **License key gate** — Loads cached key from DB. Calls `fetchRelayStatus()`. If `licenseRequired` and no cached key, shows `LicenseKeyDialog`. Sets key via `network_api.setLicenseKey()`.
6. **Load servers** — `serverListProvider.notifier.loadFromDb()`.
7. **Load unread state** — Iterates all servers, fetches their channels via `crdt_api.getServerChannels`, fetches DM peer IDs via `storage_api.getDmPeerIds()`, then calls `unreadProvider.notifier.loadAll()`. This happens BEFORE node startup so sync events don't race.
8. **Local-first loads**: pure DB reads, all awaited BEFORE the node starts so the shell can render complete and correct while the network phase runs behind it. `fetchRelayStatus` alone can cost 5 seconds, and these used to sit after it: a slow relay meant seconds of wrong theme and no background image on an otherwise fully-local render.
   - `profileProvider.notifier.loadAll()` + `friendsProvider.notifier.loadAll()`: the DM/conversation list source.
   - `themeModeProvider.notifier.load()`, `accentHueProvider.notifier.load()`.
   - `layoutModeProvider.notifier.load()`: Dock vs Classic (issue #58). Same rule as the theme: the provider's `build()` returns the default and reads nothing, because the shell watches it during this render and `loadSetting` throws until the store is open.
   - `uiScaleProvider.notifier.load()` + `chatTextScaleProvider.notifier.load()`: display size (issue #20).
   - `backgroundProvider.notifier.load()`, `accentPresetsProvider.notifier.load()`.
   - `soundEffectsEnabledProvider.notifier.load()` + `soundEffectsVolumeProvider.notifier.load()`: the UI sound pack (issue #55). Load-bearing beyond the UI: the notifiers mirror their value into `SoundService`'s statics, which is the only way the ref-less service learns the user's setting.
   - `await ref.read(ringtoneVolumeProvider.future)` (in its own try/catch): building that provider is what publishes the volume to `SoundService`; without the preload the first outgoing call of a session rings at the default.
   - `localNicknameProvider.notifier.loadAll()` (+ `setLocalNicknamesRef`), `serverStripLayoutProvider.notifier.loadLayout()`.
   - `alwaysRelayCallsProvider.notifier.load()` + `peerForwardingProvider.notifier.load()`: both must be known BEFORE the node starts; the first TURN credentials land moments after, and `IceConfigNotifier` composes the ICE map from the flag.
   - The "Unlocking…" spinner is dropped here (`_unlocking = false`), then `chatProvider.notifier.loadLastMessagePreviews(acceptedPeerIds)` fills the home dashboard previews.
9. **Start node**: `fetchRelayStatus` / license gate, then `nodeProvider.notifier.start()`.
10. **Post-start loads** (non-blocking after node):
   - `invisibleModeProvider.notifier.load()` — UI-only sync of invisible mode toggle.
   - `offlineInboxRetentionProvider` → `offlineInboxProvider`: offline delivery inbox.
   - `serverAvatarProvider` / `serverAvatarAnimProvider` / `serverBannerProvider` `.loadAll(serverIds)`: server imagery.
   - `shareTabProvider.notifier.loadAll()` — share entries for `hollow://share` cards.
   - `favouriteFriendsProvider.notifier.load()` — favourite friends ordering.
   - `hiddenArchiveDmsProvider.notifier.load()` — hidden archive DMs.
   - `blockedUsersProvider.notifier.load()` / `verifiedPeersProvider.notifier.load()` / `securityAlertsProvider.notifier.load()`.
   - `statusProvider.notifier.loadDismissed()`: dismissed status banners.
   - `systemNotificationProvider.notifier.init()` — native notifications (for tray mode).

## License Error Handling

`_listenForLicenseErrors()` is called from `initState()`. It uses `ref.listenManual(licenseErrorProvider, ...)` to react to license errors pushed from the Rust event stream. On error:

0. `'license_key_in_use'` only: resets the error provider, shows an info toast ("Your license key is in use on another device. Hollow keeps retrying.") and returns. The node keeps retrying on its own and the stored key is kept; clearing it here turned a transient collision with our own ghost socket into a surprise key prompt (issue #86).
1. Stops the node (`nodeProvider.notifier.stop()`).
2. Clears the cached key (`licenseKeyProvider.notifier.clearKey()`).
3. Resets the error provider to `null`.
4. Maps the reason string to a user-friendly message: `'invalid_license_key'` / `'license_key_required'` / fallback.
5. Shows `LicenseKeyDialog` with the error message.
6. If user enters a new key, saves it and restarts the node.

## Startup Fade

The desktop shell fades in ONCE at startup and nothing inside it moves. `_shellFade` is an `AnimationController` (starting at 1.0 when `HollowDurations.animationsDisabled`, else 0.0) under a `HollowCurves.enter` curve. The first post-frame callback runs `animateTo(1.0, duration: HollowDurations.normal)` (or snaps to 1.0 under Reduce motion), so the window is visible before anything moves. `build()` wraps `_ShellScaffold` in a `FadeTransition` over it.

There are no per-panel startup intervals: the friends bar, bottom bar, sidebars, title bar, Home and member list all render in place under that one fade. The old `StartupRevealScope` stagger (with `RevealClip`, `TypewriterText` and `StaggeredListItem`) is deleted.

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
| `layoutModeProvider` | `watch` | `LayoutMode.dock` or `LayoutMode.classic` (synchronous `Notifier`, defaults to dock, restored by `_bootstrap`'s `load()`; read it bare, there is no `.valueOrNull` to unwrap) |
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

**This width is the SCALED width.** The shell sits under `UiScale`'s transform, so it is laid out at `windowSize / interfaceScale` — 1280px at 1.35x is 948 and already under the desktop breakpoint. Raising the zoom crosses these breakpoints exactly like shrinking the window.

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
Column
  ├── SystemStatusBanner
  └── Expanded Row
      ├── ServerStrip (RepaintBoundary, 72px implicit width)
      ├── (server settings open: Expanded ServerSettingsPlace, and nothing below)
      ├── ChannelSidebar (240px fixed width) + _ChannelSidebarSeam
      ├── Expanded: chat area
      │   └── RepaintBoundary → AmbientBackground → Container(key: _mainPaneKey)
      │       └── _buildChatOrEmpty()
      ├── _MemberPanelSlot (conditional on server selected + panel open + no VC full-bleed)
      └── HelpPanelSlider
```

**Reachability:** the `ServerStrip` is Classic's only permanent rail, so it carries Browse Public Channels, Conferences and Help alongside Home / Share / Archive / servers. Those three otherwise live only on the dock's `BottomBar`, which Classic never renders, so without them the features had no entry point at all in this layout (issue #58 sweep). Full rail order in `ui_server_strip.md`.

**Voice channel full-bleed detection:** When the selected channel is a voice channel AND the user is in that channel AND screen share or camera is active, the member panel is hidden (`vcScreenShareFullBleed = true`). This gives the video content maximum width.

**Main pane keying:** `_mainPaneKey()` names what the pane shows: `'guest'`, `'share'`, `'archive'`, `'conference'`, `'shop'`, `'settings-{serverId}'`, else `selectedChannelId ?? selectedPeerId ?? 'empty'`. The `Container`'s `ValueKey` resets the pane's state per view. Switching is instant, with no cross-fade.

## Dock Layout Mode

`_buildDockLayout()` renders the modern Hollow layout with `FriendsBar` on top and `BottomBar` at the bottom:

```
Column
  ├── _DockChromeClaim → FriendsBar (RepaintBoundary)
  ├── SystemStatusBanner
  ├── Expanded Row (ClipRect)
  │   ├── if server selected: Row(ChannelSidebar (240px, dockMode=true, no UserBar) + _ChannelSidebarSeam)
  │   ├── Expanded: chat area
  │   │   └── _SplitChatArea (key 'split') OR RepaintBoundary (key 'single') → AmbientBackground → Container(key: (singleKey, _mainPaneKey))
  │   ├── _MemberPanelSlot (if not in split view; + server selected, panel open, not VC full-bleed)
  │   └── HelpPanelSlider
  └── BottomBar (RepaintBoundary)
```

Key differences from classic:
- No `ServerStrip`: servers, places and tools are all on the `BottomBar` (wiki `ui_server_strip`); the `FriendsBar` header carries only friends and, in Dock mode, the window chrome (see WindowTitleBar below).
- Channel sidebar appears instantly when a server is selected (absent at home/DM view).
- `dockMode=true` passed to `ChannelSidebar` (no `UserBar`, and no `VoiceChannelPanel`: the dock's left end carries the call on every screen, Classic keeps the panel).
- `_DockChromeClaim` (in `hollow_shell.dart`) wraps the header: it sets `dockOwnsWindowChromeProvider` in a post-frame callback and clears it in a microtask on dispose, never during a build. That flag is what folds the 32 px title bar away.
- Member panel is hidden during split view to save horizontal space.
- When no peer or channel is selected, shows `HomeDashboard` instead of the empty chat placeholder.
- **Pending join tiles (rung 1, 2026-08-29) ride the same `BottomBar` strip as real servers.** A `PendingStripItem` renders alongside `ServerStripItem`s, same as in Classic's `ServerStrip`. The one visual difference is the awaiting-setup badge's corner (top-left here vs top-right in Classic, since the Dock's unread badge already owns top-right); full detail in `ui_server_strip.md` § Pending Join Tile.

**Pending migration handling:** When split view's left pane is closed, the right pane's context is stored as `pendingMigration` in `SplitViewState`. The dock layout checks for this in a `addPostFrameCallback` and migrates the right pane's context (server/channel/peer) to the global providers atomically (batch all writes to avoid intermediate rebuilds), then calls `clearPendingMigration()`. The batch includes fetching channels and layout for the server before writing to providers — this follows the critical rule about atomic server switching.

**Effective server ID for member panel:** During split view, if the focused pane is the right pane (`focusedPane == 1`), the member panel shows the right pane's server. Otherwise it shows the global `selectedServerId`.

## Mobile Layout

Mobile layout is fully decoupled from the desktop shell. When `width < 600px`, `HollowShell.build()` returns `const MobileShell()` — the old `_buildMobileLayout()` method has been deleted.

**Files:** `lib/src/ui/mobile/mobile_shell.dart`, `lib/src/ui/mobile/mobile_nav_bar.dart`, `lib/src/ui/mobile/mobile_chat_route.dart`, `lib/src/ui/mobile/tabs/*.dart`.

**MobileShell**: a `Stack` with one `Offstage` per tab. Switching tabs is instant; every tab stays mounted so its scroll and state survive the switch.

**MobileNavBar** (`ConsumerWidget`): 56px, `hollow.surface` bg, top border. 4 tabs:
- **Tab 0 (Chats):** `LucideIcons.messageCircle`. Badge: total DM + channel unread count.
- **Tab 1 (Friends):** `LucideIcons.users`. Badge: pending incoming friend request count.
- **Tab 2 (Archive):** `LucideIcons.archive`. No badge.
- **Tab 3 (Settings):** `LucideIcons.settings`. No badge.

Active tab: `hollow.accent` + w600. Inactive: `hollow.textSecondary` + w400. Badge: red pill (top-right of icon), shows count or "99+".

**MobileChatsTab** (`ConsumerStatefulWidget`): Telegram-style unified list mixing DMs and servers. DMs show avatar + status dot + name + last message preview + timestamp + unread dot. Servers show icon + name + member count + unread badge pill + expand chevron. Tap DM → push `MobileChatRoute`. Tap server → animated accordion with channels loaded on demand via `ChannelListNotifier.fetchChannels()`. The nav bar's centre "+" ("Add a server") opens `showCreateServerDialog`, the desktop Add a server dialog; add friend lives on the Friends tab. See `ui_mobile.md`.

**MobileFriendsTab**: search + Add friend button, then Received / Sent / Favourites / All friends sections (tap → push chat route, long press = the person sheet). See `ui_mobile.md`.

**MobileSettingsTab** (`ConsumerWidget`): the identity row, then the desktop rail's groups as rows, each pushing the SHARED page from `settingsPageFor()` under `SettingsDensity(touch: true)`; see `ui_user_settings.md`.

**Chat navigation:** `MobileChatRoute` pushes onto root navigator (`Navigator.of(context, rootNavigator: true).push()`), so the bottom nav disappears. System back pops the route.

**MobileChatRoute** (`ConsumerStatefulWidget`, `lib/src/ui/mobile/mobile_chat_route.dart`): Custom mobile chat — does NOT wrap desktop ChatPane. Reuses `MessageBubble`/`ChannelMessageBubble` widgets directly. Features:
- `_MobileChatHeader` (52px): back arrow + avatar with status dot + tappable name (opens profile bottom sheet) + online/offline subtitle.
- Message list: `ScrollablePositionedList` with same grouping logic as desktop (5-min window, same sender = continuation). Header messages get `Padding(top: sm+2)`, continuations have no extra padding. Auto-scrolls to bottom on open and new messages.
- Composer: the shared `ChatComposerRow` (2026-09-24; the old `_MobileInputBar` is gone), see wiki ui_chat_pane_shared.
- `_ReplyPreview`: teal accent line + sender name + text, shown above input bar. Long-press message to reply.
- `_TypingBar`: "X is typing..." indicator above input bar.
- `_ProfileSheet`: bottom sheet with 180px banner (AnimatedGifImage for GIFs, gradient fallback), avatar overlapping banner, name, online status, bio text.
- File sending via `network_api.sendFile()` with `file_picker` and 34MB DM limit.

**Provider:** `mobileTabProvider` (StateProvider<int>, default 0, defined in `mobile_nav.dart`) is reused.

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
  │   └── GestureDetector(onTap: setFocus(0)) → AnimatedContainer(border) → RepaintBoundary → AmbientBackground → Container(keyed) → content
  ├── _SplitDivider (6px, draggable)
  ├── _RightPaneSidebar (200px fixed, if server selected)
  └── Flexible(rightFlex): Right pane chat (uses overridden providers)
      └── GestureDetector(onTap: setFocus(1)) → AnimatedContainer(border) → RepaintBoundary → AmbientBackground → content
```

**Focus indicator:** The focused pane gets a 2px accent-colored top border. The unfocused pane's border is `accent` at alpha 0, never `Colors.transparent` (which lerps through black in the `AnimatedContainer`); the divider's rest colour follows the same rule.

**Divider position:** Stored as a 0.0-1.0 ratio, clamped to 0.3-0.7. Converted to flex values by multiplying by 1000 and rounding. Dragging uses delta-based computation (`details.delta.dx / totalWidth`) to avoid snap-to-center behavior.

**Right pane sidebar:** `_RightPaneSidebar` fetches channels independently from FFI (not from `channelListProvider`) because the global provider is overridden in the ProviderScope. It caches the loaded server ID and re-fetches when it changes. Width is 200px (narrower than the left sidebar's 240px).

**Right pane chat content:** `_RightPaneChatContent` reads from the overridden providers. For channel chats, it delegates to `_RightChannelChat` which loads the channel name from FFI and caches it.

**Pane closing:** `closePane(0)` (left) stores the right pane context as `pendingMigration`, then clears the split. The shell's dock layout migrates that context to global providers on the next frame. `closePane(1)` (right) simply clears the split, leaving the left pane (global providers) as-is.

**Server settings in split view:** Opens as a dialog popup (800x600) via `_showServerSettingsDialog()` instead of replacing a pane inline. This uses `showGeneralDialog` with scale 0.95->1.0 + fade transition, barrier dismissible.

## Panel Toggling

**Member panel:** Controlled by `memberPanelProvider` (StateProvider<bool>, default `true`). Toggle via `Ctrl+Shift+M` keyboard shortcut or the users icon button in channel headers. It is docked in BOTH layouts at every width the desktop shell runs at — the old `isDesktop &&` gate in the dock layout is gone (see "Responsive member panel" below). `_MemberPanelSlot` shows and hides the panel instantly: a width animation would re-wrap the chat text on every frame.

**Responsive member panel (2026-07-27, GitHub issue #20 follow-up):** `_syncMemberPanelToWidth(isDesktop)` is called from the shell's `LayoutBuilder` (after the mobile early-return, so it never runs for `MobileShell`). It fires **only on a breakpoint CROSSING** — guarded by `bool? _wideEnoughForMembers` — and writes `memberPanelProvider` from an `addPostFrameCallback` (never during build):

- Crossing DOWN: remember the current value in `_memberPanelWasOpen`, then close the panel. The chat keeps the full width by default.
- Crossing UP: re-open it only if `_memberPanelWasOpen` was true. It can force OPEN but never force closed, so a panel you opened yourself at a narrow width survives widening.

Because it only fires on a crossing, it never fights the header toggle: while narrow you can still open the panel, it just costs chat width. It previously did the opposite — the dock layout DROPPED the panel below 1024 while the header button kept toggling the provider, so the control did nothing visible. An overlay/floating variant was built and rejected: it covered the channel header, which is where the toggle that dismisses it lives.

**Channel sidebar (dock mode):** shown only while a server is selected (`selectedServerId != null`), appearing and leaving instantly.

**Message search:** `chatSearchOpenProvider` (StateProvider<bool>, default `false`). Toggled by the `quickSearch` shortcut (`Ctrl+K` by default). ONE flag for both chat panes -- it was `channelSearchOpenProvider` until 2026-08-21, which only the channel pane read, so the shortcut was a silent no-op in a DM.

**Server settings:** `serverSettingsOpenProvider` (StateProvider<bool>, default `false`). In non-split mode, toggles between settings panel and chat. In split mode, opens as a dialog instead.

**Help panel:** `helpPanelOpenProvider` (StateProvider<bool>, default `false`, in `core/providers/help_panel_provider.dart`). Toggled by the circled-`?` (`LucideIcons.circleHelp`) Help button in the `BottomBar`'s tools group (Dock) or on the `ServerStrip` (Classic). `helpPanelOpen` is watched in `build()` and threaded into both `_buildClassicLayout`/`_buildDockLayout` as a named param; each inserts `HelpPanelSlider(visible: helpPanelOpen)` as the right-most child after the member panel. `HelpPanelSlider` (in `lib/src/ui/guides/help_panel.dart`) is a `StatelessWidget` that shows or hides the panel instantly, like `_MemberPanelSlot`. See `wiki/ui_help.md` for the full Help resource center.

## Keyboard Shortcuts

Registered globally on `HardwareKeyboard.instance` (not focus-dependent). Registered in `initState()`, removed in `dispose()`. Only processes `KeyDownEvent`. **All bindings are REBINDABLE (2026-08-04):** `_handleGlobalKey` matches against the live map from `appShortcutsProvider` (`core/providers/app_shortcuts_provider.dart`, `AppShortcut` enum, overrides persisted as one `app_shortcuts` JSON setting) via `HotkeyBinding.matchesEvent` — which carries the AltGr guard. The handler NO-OPS while `keybindCaptureActiveProvider` is true (a capture in Settings > Shortcuts must not fire the shortcut being rebound). Defaults:

| Shortcut (default) | Action |
|---|---|
| `Ctrl+,` | Toggle the Settings place (`toggleSettings`) |
| `Ctrl+Shift+P` | Toggle member panel (moved off `Ctrl+Shift+M` 2026-08-03 — that combo is now the mute-toggle voice hotkey, handled by `HotkeyController` in hotkey_provider.dart, active only while in a call, rebindable in Settings > Audio & Video > Voice or Settings > Shortcuts) |
| `Ctrl+K` | Toggle channel search |
| `Ctrl+Shift+\` | Toggle split view (dock mode only) |
| `Ctrl+1` | Focus left pane (split view only) |
| `Ctrl+2` | Focus right pane (split view only) |
| `Ctrl+=` / `Ctrl++` | Interface zoom in (5% step, `uiScaleProvider.nudge(1)`) |
| `Ctrl+-` | Interface zoom out |
| `Ctrl+0` | Reset interface zoom to 100% |

The zoom trio ignores Shift on `+`/`-` (on most layouts `+` IS Shift+`=`) and accepts the numpad variants — but ONLY while the binding is still the default (`_matchZoom`); a custom binding matches exactly. It is registered here, on `HardwareKeyboard`, precisely so it still works when the user has zoomed the on-screen controls out of reach. The chat-formatting shortcuts (bold/italic/code/strikethrough/spoiler) live in the same registry and are matched in `handleChatInputKey` (`chat_input_shortcuts.dart`, `formatBindings:` param threaded from both desktop panes).

## Chat Area Content Resolution

`_buildChatOrEmpty()` determines what to show in the main chat area. Resolution order:

1. `guestTabOpenProvider == true` → `PublicChannelBrowser` (public channel browser panel)
2. `shareTabOpenProvider == true` → `ShareDashboard`
3. `archiveTabOpenProvider == true` → `ArchiveDashboard`
4. `conferenceTabOpenProvider == true` → `ConferenceDashboard`
5. `selectedChannelId != null`:
   - If `channel.channelType == ChannelType.voice` → `VoiceChannelPane` (keyed by `'vc:$channelId'`)
   - Otherwise → `ChannelChatPane` (keyed by `'ch:$channelId'`)
   - Fallback → `_buildChannelPlaceholder()` (shows `#channelName` header + placeholder text)
6. `selectedPeerId == null`:
   - Dock mode → `HomeDashboard`
   - Classic mode → a `HollowEmptyState` ("Select a peer to start chatting")

   **The Home dashboard is a DOCK surface and stays one.** Classic's centre pane is a blank slate that only ever shows what the left panels select; dropping the dock's Home tab into it makes the two layouts bleed into each other. The consequence is deliberate: everything that lives only on the dashboard, the Network column included, is Dock-only by design, and the answer for a Classic user who wants it is "switch to Dock", not "render the dock's Home tab inside Classic".
7. `selectedPeerId != null` → `ChatPane` (keyed by peer ID)

**Steps 1–4 (plus the Hollow Shop tab, `ShellTab.shop` / `shopTabOpenProvider`, checked after Conferences since 2026-09-02, and Settings, `ShellTab.settings` / `settingsTabOpenProvider` since 2026-09-24, which replaces the whole centre row and keeps the selection underneath) are ONE exclusive selection spread across six booleans.** Because the first open tab wins, a navigation site that clears three of them leaves the fourth covering whatever it just selected — that was issue #28 (Conferences over a freshly selected server channel). Switch them ONLY through `setShellTab(ref.read, ShellTab.x)` / `setShellTab(ref.read, null)` (`lib/src/core/providers/shell_tab.dart`), which is the one place that knows the full list; watch `anyShellTabOpenProvider` for "something is covering the chat" (the Home button's selected state). A source-scan guard in `test/shell_tab_test.dart` fails if any file outside `shell_tab.dart` writes a `*TabOpenProvider.notifier`.

## Channel Sidebar Builder

`_buildChannelSidebar()` constructs a `ChannelSidebar` with all necessary callbacks:

**onPeerSelected:** Clears share/archive tab state, sets `selectedPeerProvider`, marks DM as read via `unreadProvider`, switches to chat tab on mobile.

**onChannelSelected:** Sets `selectedChannelProvider`, remembers last channel for current server in `lastChannelPerServerProvider`, marks channel as read via `unreadProvider`, switches to chat tab on mobile.

**onCreateChannel:** Shows `CreateChannelDialog` for the current server.

**onOpenSettings:** In split view, opens server settings as a dialog. Otherwise toggles `serverSettingsOpenProvider`.

**canManageChannels:** Computed from `myPermissionsProvider(serverId)`, checking `Permission.manageChannels` bit.

**width:** `width ?? ref.watch(channelSidebarWidthProvider)` — the user's dragged width (issue #54). The split view's right-pane sidebar overrides it with a fixed 200.

## Resizable panels (issue #54)

`PanelResizeHandle` (`ui/components/panel_resize_handle.dart`) is a 6px seam that occupies its OWN strip in the shell Row, never an overlay on a panel's edge — that edge is the panel's scrollbar gutter since `HollowScrollBehavior`, and a handle sitting on it would swallow the thumb. Drag resizes, double-click (or Home) resets, left/right arrows nudge, and it is focusable, so the splitter is not mouse-only.

**It paints as an extension of the PANEL and owns the divider** (2026-08-21). Its first version painted nothing at rest, which left a 6px hole between panel and chat. Invisible across the message area (both sides are `hollow.background`) and glaring at the chat's HEADER BAR and COMPOSER BAR, which are opaque `hollow.surface` and stopped 6px short of the divider at both ends — four dark notches at the chat's corners, measured at the header's y as seam `13,15,20` against chat `20,22,28`. The seam now fills with `hollow.surface` and draws the 1px `hollow.border` on its CHAT side, so the panel simply reads 6px wider and the chat's chrome runs edge to edge. Because the seam owns the divider, the panel beside it must NOT draw its own: `ChannelSidebar.edgeBorder` / `MemberPanel.edgeBorder`, both defaulting TRUE — the split view's right sidebar has no seam and still draws its own. Its accent line on hover/focus is aligned to that divider, not centred in the strip; centred it lit up 2.5px away from the border and the two read as a double rule.

- `_ChannelSidebarSeam` sits directly after the channel sidebar in BOTH layouts. In Dock mode it sits in the same conditional Row as the sidebar, so it leaves with the panel it sizes instead of hanging in empty space.
- `_MemberPanelWithSeam` is what `_MemberPanelSlot` renders: the seam on the panel's LEFT edge (`panelOnRight: true`, so dragging left widens it) plus the panel.
- Widths live in `channelSidebarWidthProvider` / `memberPanelWidthProvider` (`core/providers/layout_prefs_provider.dart`), clamped in the notifier, persisted, and loaded from `_bootstrap` via `loadLayoutPrefs(ref)` — never from a provider's `build()`.
- `panelScaleProvider` zooms the CONTENTS of the server strip, channel sidebar and member panel through `PanelScale` (the same `_ScaledViewport` render object the interface zoom uses). The server strip is the one panel whose WIDTH scales too (`kServerStripWidth * panelScale`): its icon rows are sized for exactly 72px, so zooming the content inside a fixed-width rail just pushes them out of the column. `PanelScale.minContentHeight` caps the zoom for panels with unshrinkable chrome — a zoomed panel lays out at `slot / scale`, so raising the zoom SHRINKS the room its fixed stack of icons gets.

## WindowTitleBar — Placement and Rationale

**CRITICAL ARCHITECTURE:** The window chrome (the `WindowTitleBar` or the floating `WindowControls`) is NOT inside `HollowShell`. It lives in `DesktopWindowFrame`, which `MaterialApp.builder` in `lib/src/ui/app.dart` wraps around the app on desktop. This is documented as a critical rule in CLAUDE.md.

**Reason:** If the chrome were inside `HollowShell` (inside `MaterialApp.home`), then `showDialog`/`showGeneralDialog` calls would create overlays that cover it, making the window controls inaccessible during dialogs. By placing it in `MaterialApp.builder`, it sits ABOVE the Navigator in the widget tree, so dialog routes cannot occlude it.

**Two modes.** The 32 px `WindowTitleBar` shows for Classic, before an identity loads (Welcome and the password prompt are dialogs over the mounted dock, so the gate is `identityProvider.peerId != null`) and while app-locked (`appLockedProvider`: nothing on the lock cover can move the window). While any route sits above home (`routesAboveHome`, a navigator observer on `MaterialApp`), a translucent `DragToMoveArea` strip covers the header so a dialog's scrim never takes the window's drag away. In Dock mode the shell's `_DockChromeClaim` sets `dockOwnsWindowChromeProvider`; the title bar then collapses and `WindowControls` float unscaled at the top-right over the `FriendsBar`, at `kDockHeaderHeight` (44) x the effective `UiScale`, so they match the header's height in window pixels. They report their width (`windowControlsWidthProvider`) so the header keeps its trailing end clear. `dockHeaderCanOwnChrome` limits this to Windows, Linux and macOS.

**Implementation (`DesktopWindowFrame`, `lib/src/ui/app.dart`):**
```
chrome     = !annotation && !fullscreen
dockChrome = chrome && dockHeaderCanOwnChrome && dockOwnsWindowChrome && !appLocked
headerHeight = kDockHeaderHeight * effectiveUiScale(scale, constraints.biggest)

MacTrafficLights(height: dockChrome ? headerHeight : 0,
  child: Stack(
    Column(
      if (chrome && !dockChrome) WindowTitleBar(),
      Expanded(ClipRect(UiScale(child))),
    ),
    if (dockChrome) Positioned(top: 0, right: 0,
        WindowControls(height: headerHeight, reportWidth: true)),
  ))
```

The `ClipRect` around the navigator child prevents `BackdropFilter` blur from dialogs from bleeding up into the title bar area.

`UiScale` (interface zoom, issue #20) wraps the navigator child but NOT the window chrome (browser-chrome model). Two consequences worth knowing: (1) `UiScaleBox` must measure its own slot via `LayoutBuilder`, never `MediaQuery.size`, because its slot is 32px shorter than the window whenever the title bar shows; sizing from the window pushed exactly the bottom dock off screen at every scale but 1.0; (2) below the transform, window coordinates are NOT overlay coordinates, so popup anchors go through `overlay_anchor.dart`. See `project_display_scaling`.

**macOS traffic lights:** `MacTrafficLights` sends the header height (0 = hand them back to AppKit's title bar) after the frame, only on change, over the MethodChannel `hollow/traffic_lights` (`setHeaderHeight`); `macos/Runner/MainFlutterWindow.swift` centres the native traffic lights in it. The `FriendsBar` keeps `kMacTrafficLightGap` (78) clear at its leading end, and the `WindowTitleBar` does the same.

**WindowTitleBar widget** (`lib/src/ui/shell/window_title_bar.dart`): 32px tall container with `hollow.opaqueSurface` color. Layout: `[macOS gap] [DragToMoveArea ────] [WindowControls]`. No wordmark. It has no startup animation of its own.

Widget classes in window_title_bar.dart:
- **`WindowTitleBar`**: StatelessWidget, the 32px bar.
- **`WindowControls`**: `ConsumerWidget`, the same order everywhere: `AnnotationToggleButton`, `ZoomIndicator`, then off macOS minimise / maximise / close. With `reportWidth` it wraps in `_WidthReporter` (a `RenderProxyBox` that publishes its width after the frame, never during layout).
- **`MacTrafficLights`**: see above.
- **`_WindowButton`**: StatefulWidget base for window control buttons. No Material ripple, instant color change on hover. 46 px wide (`_kWindowButtonWidth`), as tall as the controls. Optional `hoverGlyph` for a fill the glyph would vanish into.
- **`_MinimizeButton`**: calls `windowManager.minimize()`.
- **`_MaximizeButton`**: StatefulWidget with `WindowListener` mixin. Tracks maximized state, shows `LucideIcons.square` or the restore glyph `LucideIcons.copy`, toggles between `windowManager.maximize()` and `unmaximize()`.
- **`_CloseButton`**: calls `windowManager.close()`. Hover color is red (#E81123) with a white glyph.
- **`ZoomIndicator`**: browser-style zoom readout, rendered only while `uiScaleProvider != 1.0`; shows e.g. "125%" and resets to 100% on tap. It lives in the controls because they are the one surface OUTSIDE the scale transform, so no zoom can put it out of reach. **It deliberately carries no `HollowTooltip`:** the controls sit ABOVE the Navigator and therefore have no `Overlay` ancestor, so `Overlay.of` there would throw. Same reason `_WindowButton` rolls its own hover instead of using a tooltip.
- The annotate button (`annotation_toggle_button.dart`) has the Semantics label "Annotate the screen" and a `HollowFocusRing`; its hover label floats to the LEFT, inside the window.

## HollowApp — Theme and Background Transparency

`lib/src/ui/app.dart` defines `HollowApp` (`ConsumerWidget`), the `MaterialApp` root.

`scrollBehavior: const HollowScrollBehavior()` (issue #54,
`ui/components/hollow_scroll_behavior.dart`): every VERTICAL scrollable on
desktop gets `Scrollbar(child: Padding(right: kScrollGutter))` — the gutter
sits INSIDE the scrollbar and OUTSIDE the viewport, so the thumb can never
paint over the last 10px of a row (checkbox columns, text fields, trailing
chevrons). Touch and horizontal axes are untouched, mirroring
`MaterialScrollBehavior` exactly, and `copyWith(scrollbars: false)` still opts
out (the chat panes and the 72px server strip do). Consequence to remember:
a manual `Scrollbar` widget now paints a SECOND thumb, so do not add one —
the one in `home_dashboard` was removed. Guarded by
`test/widget/scroll_gutter_test.dart`.

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

## Instant View Switches

Main pane, conversation, channel, server and shell-tab switches are instant in both layouts and in the split panes: there is no `AnimatedSwitcher`. Identity lives in the keyed `Container` (see Main pane keying), which resets the pane's state per view while the `AmbientBackground` layer around it stays put. Design language 3.8: things that arrive ON TOP of the app move, the app's own navigation does not.

## RepaintBoundary Usage

Performance optimization: `RepaintBoundary` wraps `ServerStrip`, `FriendsBar`, `BottomBar`, `MemberPanel`, the chat `AmbientBackground`, and each split pane's background. This isolates repaint regions so animations in one panel don't trigger repaints in others.

## DragToResizeArea

On desktop platforms (Windows/macOS/Linux), the entire layout body is wrapped in `DragToResizeArea` from the `window_manager` package. This restores edge and corner resize handles that were removed when `setAsFrameless()` was called to enable the custom title bar. Without this wrapper, the window cannot be resized from its edges.

While `fullscreenProvider` is true the wrapper STAYS MOUNTED with `enableResizeEdges: const []` (2026-09-14). Swapping it out of the tree changed the widget type at that slot, re-inflated the whole shell on every F11, and the composer's `autofocus` then stole primary focus from any open dialog, so Escape stopped closing it (memory `feedback_semantics_swap_remount_blink`).

## Fullscreen (2026-09-14)

`fullscreenProvider` (`lib/src/core/services/window_fullscreen.dart`, sync `Notifier<bool>`): `enter`/`exit`/`toggle`, serialized, fails closed, exits on `appLockedProvider`. Backend by platform: Windows = the runner's own `hollow/window` method channel (`windows/runner/flutter_window.cpp`; `windowManager.setFullScreen` is a silent no-op for a frameless window and its exit path is the squished restore, memory `feedback_annotation_window_management`), macOS/Linux = `windowManager.setFullScreen`, mobile = none. `test/window_fullscreen_test.dart` confines `setFullScreen(` and the channel name to that one file. F11 = `AppShortcut.toggleFullscreen`, app-wide and rebindable, handled in `_handleGlobalKey`. The window chrome (title bar or floating controls) hides on `annotation || fullscreen` in `DesktopWindowFrame` (`app.dart`). The video fullscreen view uses the same provider (wiki `ui_message_bubbles`, VideoMessageBubble).
