# Mobile UI — Shell, Chat Route, and Actions

Covers all mobile-specific UI: the shell layout, chat route, message actions bottom sheet, and navigation. All files under `lib/src/ui/mobile/`.

---

## MobileShell

**File:** `lib/src/ui/mobile/mobile_shell.dart`
**Class:** `MobileShell extends ConsumerWidget`
**Purpose:** 4-tab mobile layout replacing desktop HollowShell below 600px breakpoint.

### Tabs (indexed 0-3)
| Index | Tab | Widget | Icon |
|-------|-----|--------|------|
| 0 | Chats | `MobileChatsTab` | `LucideIcons.messageCircle` |
| 1 | Friends | `MobileFriendsTab` | `LucideIcons.users` |
| 2 | Archive | `MobileArchiveTab` | `LucideIcons.archive` |
| 3 | Settings | `MobileSettingsTab` | `LucideIcons.settings` |

Tab state: `mobileTabProvider` (`StateProvider<int>`, default 0) in `lib/src/ui/shell/mobile_nav.dart`.

### MobileNavBar
**File:** `lib/src/ui/mobile/mobile_nav_bar.dart`
Bottom bar (56px) with 4 `_NavTab` widgets + center `_AddButton`. Uses `LayoutBuilder` + `Stack` for animated glow.
- **Animated glow:** `AnimatedPositioned` radial gradient circle (accent 0.3→0.1→0.0, `RadialGradient`, 84×76) follows active tab with 300ms `easeOutCubic`. Wrapped in `ClipRect` to prevent bleed outside bar. Maps tab indices 0,1 to slots 0,1 and 2,3 to slots 3,4 (skipping center button slot).
- Chats tab: total unread count (DM + channel)
- Friends tab: pending incoming friend request count
- **Center "+" button** (`_AddButton`): 40×40 accent-colored rounded container with plus icon. Opens `NewConversationDialog` (Create/Join Server, Add Friend). Passed via `onAdd` callback from `MobileShell`.
- Archive tab
- Settings tab

### MobileChatsTab — Ambient Background & Header
**File:** `lib/src/ui/mobile/tabs/mobile_chats_tab.dart`
- **Ambient blob:** Wraps tab in `AmbientBackground(color1: accent, color2: accent, opacity: 0.12)`. Both blobs teal (no purple like desktop). Uses `SharedTickers.instance.ambient` (45s figure-8 at ~15fps). Same `_AmbientPainter` radial gradients as desktop.
- **Header:** Row with teal "Hollow" text (24px, w700) + `_HeaderShimmerLine` — ping-pong shimmer using `SharedTickers.instance.ambient` at ~10s cycle. Gradient: border→accent(0.5)→border with ±0.15 glow width + subtle boxShadow.

### Channel Tree Connectors
**File:** `lib/src/ui/mobile/tabs/mobile_chats_tab.dart` (`_TreeChannelRow`)
Expanded server channel list shows tree-style connectors (├── / └──). `_TreeChannelRow` wraps `_ChannelRow` in a `Stack` with vertical + horizontal `ColoredBox` lines. Vertical line aligned under server avatar center (`HollowSpacing.lg + 22`). Last channel uses `└──` (line stops at branch), others use `├──` (line continues). Line color: `hollow.textSecondary` at 0.7 alpha.

### Server Long-Press Context Sheet
**File:** `lib/src/ui/mobile/tabs/mobile_chats_tab.dart` (`_ServerContextSheet`)
Long-press on a server row opens `showModalBottomSheet` with:
- Handle bar + server name header
- **Server Settings** → pushes `MobileServerSettingsRoute`
- **Invite** → `showInviteDialog()` with `hollow://join?server=` link
- **Copy Server ID** → clipboard + toast
- **Leave/Delete Server** → confirmation dialog (`showHollowDialog`). Owner sees Delete, others see Leave. Post-action clears `selectedServerProvider`, `selectedChannelProvider`, `channelListProvider`.

---

## MobileChatRoute

**File:** `lib/src/ui/mobile/mobile_chat_route.dart`
**Class:** `MobileChatRoute extends ConsumerStatefulWidget`
**Purpose:** Shared chat view for both DM and channel conversations. Pushes onto root navigator (bottom nav disappears).

### Constructor
| Parameter | Type | Description |
|---|---|---|
| `peerId` | `String?` | Set for DM conversations |
| `serverId` | `String?` | Set for channel conversations |
| `channelId` | `String?` | Set for channel conversations |
| `channelName` | `String?` | Display name for channel header |

`isDm` getter: `peerId != null`.

### State Variables
- `_controller` / `_focusNode` — main text input
- `_scrollController` / `_positionsListener` — `ScrollablePositionedList` controllers
- `_replyToMessageId` / `_replyToText` / `_replyToSenderName` — reply state
- `_editingMessageId` — inline edit mode (message ID being edited)
- `_editController` / `_editFocusNode` — edit TextField controllers
- `_lastTypingSent` — 3s throttle for typing indicators
- `_isInAutoScrollZone` — auto-scroll on new messages
- `_stagedFilePath` / `_stagedFileName` / `_stagedFileIsImage` — staged file attachment
- `_isRecordingVoice` — swaps input bar for VoiceRecorderBar
- `_searchOpen` / `_searchController` / `_searchFocusNode` / `_searchResults` — channel search
- `_highlightIndex` — search result highlight (auto-clears after 1.5s)
- `_channelKey` — getter for `'$serverId:$channelId'` (channelChatProvider map key)

### Provider Management (Critical)
On entry: `_openDmChat` sets `selectedPeerProvider`, clears `selectedServerProvider`. `_openChannelChat` sets both `selectedServerProvider` and `selectedChannelProvider`.
On exit: `dispose()` clears these providers so the event provider doesn't treat the user as still viewing the chat.

### Widget Tree
```
Scaffold
├── SafeArea
│   └── Column
│       ├── _MobileChatHeader (back, name, status, search icon, mute bell)
│       ├── _buildSearchBar (channel only, when _searchOpen)
│       ├── Expanded → Stack
│       │   ├── ScrollablePositionedList.builder (initialScrollIndex: messages.length, initialAlignment: 1.0)
│       │   │   └── _LongPressMessage → MessageBubble / ChannelMessageBubble (isHighlighted for search)
│       │   └── Builder → unread pill (DM + channel, "N new messages")
│       ├── _TypingBar
│       ├── _ReplyPreview (if replying)
│       ├── StagedHollowLinkCard / StagedLinkPreviewCard (link preview)
│       ├── _StagedFilePreview (if file staged)
│       ├── Post permission gate (channel only — replaces input bar when canPostInChannelProvider is false)
│       └── VoiceRecorderBar (if _isRecordingVoice) OR _MobileInputBar (paperclip + text + emoji + mic + send)
```

### Message Rendering
Uses `ScrollablePositionedList.builder` with sentinel pattern (`itemCount: messages.length + 1`).

**Grouping:** 5-minute window + sender change triggers `showHeader`.

**Reply context:** For each message with `replyToMid`, looks up the original in the message list and passes `replyToSenderName` + `replyToText` to the bubble.

**Edit mode:** When `_editingMessageId` matches a message, renders `_buildEditView()` instead of the bubble — an inline `TextField` with accent border + Save/Cancel buttons.

### _LongPressMessage Widget
Wraps each message bubble. Provides:
- `HitTestBehavior.opaque` — full-width tap target (not just painted content)
- Teal highlight animation during long-press hold (`AnimatedContainer` with `hollow.accent.withValues(alpha: 0.08)`)
- Triggers `showMobileMessageActions()` on long-press complete

### File Actions
- `_saveFile(FileAttachment)` — reads bytes, passes to `FilePicker.platform.saveFile(bytes:)`. Android requires `bytes:` param (crashes without it). Converts WebP→PNG if needed via `network_api.convertImageFormat()`.
- `_requestFileFromPeer(FileAttachment, senderId)` — requests file via P2P when not on disk.
- `_handleSend()` — if `_stagedFilePath` is set, sends as file attachment via `network_api.sendFile()`, otherwise sends text.

### Action Callbacks Wired
Both DM and channel builders wire:
- `onToggleReaction` on bubbles → reaction pills are tappable
- Long-press → `_showDmActions()` / `_showChannelActions()` → bottom sheet
- `onDownload` — shows when message has file attachment. Saves locally or requests from peer. Guards duplicate downloads via `fileTransferProvider`.

### Channel Permission Gates
- **Read gate:** If `myPermissionsProvider` `readMessages` bit is 0, replaces message list with eyeOff icon + "no permission" text. DMs unaffected.
- **Post gate:** If `canPostInChannelProvider` returns false, replaces input bar with "no permission to send" notice. Checks bitmask AND channel posting mode.
- **Sync indicator:** Below header for channel chats. Uses `serverSyncStatusProvider`. Shows spinner + "Syncing..."/"Retrying..." (warning color) / "Sync failed" with tappable "Retry" link. Hidden when idle/synced/connecting.

### Emoji Picker in Input Bar
Smiley icon (`LucideIcons.smile`) between mic and send buttons. Opens `showModalBottomSheet` with 30-emoji grid (from `kReactionEmojis`). Inserts selected emoji at cursor position via `_controller.text.replaceRange()`.

---

## MobileServerSettingsRoute

**File:** `lib/src/ui/mobile/mobile_server_settings_route.dart`
**Class:** `MobileServerSettingsRoute extends ConsumerStatefulWidget`
**Purpose:** Full-screen server settings page, pushed from server long-press context sheet.

### Constructor
| Parameter | Type | Description |
|---|---|---|
| `serverId` | `String` | Server to configure |

### UI Layout (ListView)
- **Server avatar** — 80×80, tap to pick + crop (1:1, `showImageCropDialog`), long-press to clear. Permission-gated (`Permission.manageServer`).
- **Server Name** — `HollowTextField` + Save button. `crdt_api.renameServer()`. Permission-gated.
- **Description** — multi-line `HollowTextField` (maxLines:3, maxLength:256) + Save. `crdt_api.updateServerSetting(key: 'description')`. Permission-gated.
- **Server ID** — `SelectableText` (mono font) + copy button. Always visible.
- **Your Nickname** — `HollowTextField` + Save. `crdt_api.setNickname()`. Always visible.
- **Danger Zone** — `_SectionDivider(danger: true)` + `HollowButton.danger()`. Owner: Delete Server (`crdt_api.deleteServer`). Member: Leave Server (`crdt_api.leaveServer`). Both show confirmation dialog and clear server/channel providers on success.

### ASOT-Style Section Dividers
`_SectionDivider` widget: `Row` with two `Divider`s flanking centered label text. Optional `danger: true` for red color.

---

## Mobile Message Actions

**File:** `lib/src/ui/mobile/mobile_message_actions.dart`
**Function:** `showMobileMessageActions()` — `showModalBottomSheet` with contextual actions.

### Bottom Sheet Layout
```
Column (mainAxisSize: min)
├── Drag handle (32×4px)
├── _MessagePreview (sender name + truncated text + timestamp)
├── _QuickReactionsRow (top 6 emojis + "More..." button)
├── Divider
└── Action rows (HollowPressable, icon + label)
    ├── Reply (LucideIcons.reply)
    ├── Edit Message (LucideIcons.pencil) — own messages only, no file
    ├── Copy Text (LucideIcons.copy) — text messages only
    ├── Save File (LucideIcons.download) — file messages only
    ├── Message Info (LucideIcons.shieldCheck) — shows proof dialog
    └── Delete Message (LucideIcons.trash2, error color) — own messages only
```

### Three Views (AnimatedSize transitions)
1. **actions** — default view with action rows
2. **allEmojis** — full 30-emoji grid (6 columns), triggered by "More..." button. Back button returns to actions.
3. **deleteConfirm** — inline confirmation: warning icon + "Delete this message? This can't be undone." + Cancel/Delete buttons

### Parameters
All action callbacks are nullable — only shown when non-null:
- `onReply`, `onEdit`, `onDelete`, `onCopy`, `onDownload` — `VoidCallback?`
- `onReaction` — `void Function(String emoji)?`
- `onInfo` — `VoidCallback?`

Note: `onCopyImage` was removed — `super_clipboard` image operations don't work on Android. "Save File" covers the use case.

### Emoji Source
Imports `kReactionEmojis` from `lib/src/ui/chat/emoji_picker.dart` (30 curated emojis). Does NOT use the desktop's `showEmojiPicker()` overlay — embeds the grid directly in the sheet to avoid raw `OverlayEntry`.

---

## Widget Test Framework

**Files:**
- `test/helpers/test_app.dart` — `pumpHollowMobile()` + 20 mock notifiers
- `test/helpers/test_data.dart` — fake peer IDs, servers, channels, friends, unread state
- `test/helpers/mock_rust_lib.dart` — documentation only (mocking is at provider level)

### Key Pattern
All FFI-dependent providers are overridden with mock notifiers that return static test data. No native library loading needed. Tests run in ~1s.

`pumpHollowMobile(tester)` sets viewport to 400×800 and wraps `MobileShell` in `ProviderScope` with all overrides.

### Test Files
- `test/widget/mobile_shell_test.dart` — 7 tests (rendering, nav bar, tab switching)
- `test/widget/desktop_shell_test.dart` — 5 tests (responsive breakpoints, themes)
- `test/widget/mobile_nav_badge_test.dart` — 3 tests (unread badges, pending friends)
- `test/widget_test.dart` — 1 smoke test
