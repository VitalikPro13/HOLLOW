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

### Floating Pill Layering
`MobileShell` wraps its `Scaffold` in a `Stack` with `MobileActiveCallPill` and `MobileVoiceChannelPill` on top. These pills are also placed in `MobileChatRoute`'s Stack so they remain visible on pushed chat routes. Full-screen voice/call routes use `PageRouteBuilder` (slide-from-bottom) and cover the pills by being pushed on top in the navigator stack. **CRITICAL:** Pills must NOT go in `app.dart` builder — that layer is above the navigator and no route can cover it.

### MobileChatsTab — Ambient Background & Header
**File:** `lib/src/ui/mobile/tabs/mobile_chats_tab.dart`
- **Ambient blob:** Wraps tab in `AmbientBackground(color1: accent, color2: accent, opacity: 0.12)`. Both blobs teal (no purple like desktop). Uses `SharedTickers.instance.ambient` (45s figure-8 at ~15fps). Same `_AmbientPainter` radial gradients as desktop.
- **Header:** Row with teal "Hollow" text (24px, w700) + `_HeaderShimmerLine` — ping-pong shimmer using `SharedTickers.instance.ambient` at ~10s cycle. Gradient: border→accent(0.5)→border with ±0.15 glow width + subtle boxShadow.

### Channel Tree Connectors
**File:** `lib/src/ui/mobile/tabs/mobile_chats_tab.dart` (`_TreeChannelRow`)
Expanded server channel list shows tree-style connectors (├── / └──). `_TreeChannelRow` wraps `_ChannelRow` in a `Stack` with vertical + horizontal `ColoredBox` lines. Vertical line aligned under server avatar center (`HollowSpacing.lg + 22`). Last channel uses `└──` (line stops at branch), others use `├──` (line continues). Line color: `hollow.textSecondary` at 0.7 alpha.

### Channel Long-Press Context Sheet
**File:** `lib/src/ui/mobile/mobile_channel_actions.dart`
Long-press on a channel row in the expanded accordion opens `showMobileChannelActions()`:
- Channel name header with type icon (hash/volume)
- If `canManage` (Permission.manageChannels): **Rename** (pops sheet, opens `showHollowDialog`), **Visibility** (radio: Everyone/Mod+/Admin+), **Who Can Post** (same), **Delete** (inline confirmation)
- If not admin: read-only channel info only
- Uses `AnimatedSize` view switching (actions → deleteConfirm → visibility → posting)
- `onChanged` callback triggers `_loadChannels()` to refresh the accordion

### Layout-Aware Channel List
**File:** `lib/src/ui/mobile/tabs/mobile_chats_tab.dart` (`_ChannelList`)
Channel accordion now respects layout ordering + categories:
- Fetches both `ChannelListNotifier.fetchChannels()` AND `ChannelLayoutNotifier.fetchLayout()` via `Future.wait`
- Parses layout JSON into `_DisplayItem` sealed class hierarchy: `_CategoryDisplayItem`, `_ChannelDisplayItem`, `_SeparatorDisplayItem`
- Categories render as collapsible `_CategoryHeaderRow` (uppercase, chevron toggle, `AnimatedRotation`)
- Separators render as `_TreeSeparatorRow` (12px gap with vertical tree line)
- Unplaced channels appended alphabetically at end
- "+" `_CreateChannelRow` at bottom when `canManage` (calls `showCreateChannelDialog` with `onCreated: _loadChannels`)
- Listens to `serverListProvider.select((s) => s[widget.serverId])` for per-server change detection

### Server Long-Press Context Sheet
**File:** `lib/src/ui/mobile/tabs/mobile_chats_tab.dart` (`_ServerContextSheet`)
Long-press on a server row opens `showModalBottomSheet` with:
- Handle bar + server name header
- **Server Settings** → pushes `MobileServerSettingsRoute`
- **Create Channel** → `showCreateChannelDialog()` (gated by `Permission.manageChannels`)
- **Invite** → `showInviteDialog()` with `hollow://join?server=` link
- **Copy Server ID** → clipboard + toast
- **Leave/Delete Server** → confirmation dialog (`showHollowDialog`). Owner sees Delete, others see Leave. Post-action clears `selectedServerProvider`, `selectedChannelProvider`, `channelListProvider`.

### Channel Layout Editor in Server Settings
**File:** `lib/src/ui/mobile/mobile_server_settings_route.dart` (`_ChannelLayoutEditor`)
New "Channels" section (gated by `Permission.manageChannels`) with:
- Centered action buttons: + Channel, + Category, + Break
- `ReorderableListView.builder` (shrinkWrap, NeverScrollableScrollPhysics) with drag handles
- Category rows (accent bg), channel rows (elevated bg), separator rows (divider)
- Rename/delete via `showHollowDialog` dialogs
- Dirty state tracking with Save Layout / Discard buttons
- Listens to `serverListProvider.select()` for auto-refresh on channel events

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
On exit: Providers are cleared in `Navigator.push().then()` in `mobile_chats_tab.dart` — AFTER the route fully pops. `MobileChatRoute.dispose()` does NOT touch selection providers. This ensures `isViewingChannel` guard works during viewing but unreads accumulate after returning to Chats tab.
Unread clearing: `_markSeen()` called after history loads in `initState` `.then()` callback (with real message IDs). Never calls `markChannelSeen`/`markDmSeen` with null.

### Widget Tree
```
Scaffold
├── SafeArea
│   └── Column
│       ├── _MobileChatHeader (back, name, status, users icon, search icon, mute bell)
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

### Management Drill-Down Rows
Below the Channels section, a "Management" section with `_NavRow` widgets (icon + label + chevron right):
- **Members** → pushes `MobileMembersRoute`
- **Roles** → pushes `MobileRolesRoute` (gated by `Permission.manageRoles`)
- **Labels** → pushes `MobileLabelsRoute`
- **Twitch Verification** → pushes `MobileTwitchSettingsRoute` (gated by `Permission.manageServer`)
- **Invite** → opens `showInviteDialog` with `hollow://join?server=` link

---

## MobileProfileSheet

**File:** `lib/src/ui/mobile/mobile_profile_sheet.dart`
**Function:** `showMobileProfileSheet(context, {peerId, role?, twitchUsername?, labels?})`
**Purpose:** Shared profile bottom sheet used from member panel, DM header tap, and friend long-press.

### Layout
- `SafeArea` → `Column(mainAxisSize: min)`
- Drag handle (32×4px)
- Banner (180px) — `AnimatedGifImage` or gradient fallback via `bannerColorFromId()`
- Avatar (72px) overlapping banner by 36px (`Transform.translate`), bordered
- Name: local nickname (bold) + profile name (secondary) if nickname set, else just profile name
- Online status: `StatusDot` + "Online"/"Offline"
- Role badge: colored pill (if not 'member')
- Labels: `Wrap` of colored chips
- Twitch badge: tappable, opens `https://twitch.tv/$username` via `url_launcher`. Falls back to `profile?.twitchUsername` when param is null
- Status text: italic accent
- About me: centered, max 4 lines
- Action buttons (non-self): Message (if friend), Set/Edit Nickname, Friend action (Add/Accept/Pending/Friends indicator)
- Peer ID footer: short ID + copy icon

### Twitch Fallback
`effectiveTwitch = twitchUsername ?? profile?.twitchUsername ?? ''` — ensures badge shows in DM context where no `MemberFfi` is available.

---

## MobileMemberPanel

**File:** `lib/src/ui/mobile/mobile_member_panel.dart`
**Function:** `showMobileMemberPanel(context, serverId)`
**Purpose:** Member list bottom sheet triggered from users icon in channel chat header.

### Layout
`DraggableScrollableSheet` (initial: 0.5, min: 0.3, max: 0.9) with:
- Drag handle + "Members" header with users icon
- `ListView.builder` with `_MemberEntry` sealed class (divider or member)

### Role Grouping
- Online members grouped by role (Owner → Admin → Moderator → Members) if mixed roles, single "Online" divider if all 'member'
- Offline members in separate section
- Role divider labels: "Owner"/"Admin"/"Moderator"/"Members" with glow colors (gold/purple/orange/teal)

### Member Tile
- Avatar (36px) + status dot (syncing=yellow, online=green, offline=gray)
- Name (local nick → server nick → profile name) + full role word badge ("Owner"/"Admin"/"Moderator")
- Twitch username row (icon + text, tappable to open Twitch page), with `effectiveTwitch` fallback to profile
- Tap → `showMobileProfileSheet` with role, labels, twitchUsername
- Offline members dimmed (50% opacity via `AnimatedOpacity`)

---

## MobileMembersRoute

**File:** `lib/src/ui/mobile/mobile_members_route.dart`
**Purpose:** Full member management (role change, kick, ban). Pushed from server settings.

### Features
- Full member list with avatar, status, role, Twitch badge (tappable)
- Tap member → profile sheet. Long-press OR tap three-dots → action bottom sheet
- Action sheet: role change (assignable roles only), kick (with confirmation), ban (with confirmation)
- Collapsible banned members section with unban buttons
- Permission-gated: `_canManageRole()` checks actor vs target role priority

### FFI Functions
`changeMemberRole`, `kickMember`, `banMember`, `unbanMember`, `getBannedMembers`

---

## MobileRolesRoute

**File:** `lib/src/ui/mobile/mobile_roles_route.dart`
**Purpose:** Role permission editor. Pushed from server settings.

### Layout
3 role cards (Admin/Moderator/Member), each with:
- Colored header (purple/orange/gray) with role icon + Reset button
- 6 permission toggle rows: Manage Server, Manage Channels, Manage Roles, Kick/Ban, Send Messages, Read Messages
- `Switch` widgets with `activeTrackColor: hollow.accent`, `activeThumbColor: Colors.white`
- Changes save immediately via `crdt_api.changeRolePermissions()`

---

## MobileLabelsRoute

**File:** `lib/src/ui/mobile/mobile_labels_route.dart`
**Purpose:** Cosmetic label management. Pushed from server settings.

### Sections
1. **Self-assign** — `Wrap` of label chips. Tap to toggle assignment on yourself. Check/circle icon state.
2. **Manage** (gated by `Permission.manageRoles`) — label list with color dot, name, assign-members button, delete button. Create button in header (+).

### Create Dialog
Name field (max 24) + 9 preset color circles. `crdt_api.createLabel()`.

### Assign Dialog
`HollowDialog` with member checklist. `crdt_api.assignLabel()` / `unassignLabel()`.

---

## MobileTwitchSettingsRoute

**File:** `lib/src/ui/mobile/mobile_twitch_settings_route.dart`
**Purpose:** Twitch verification configuration for servers. Pushed from server settings.

### Fields
- Enable toggle, Channel Display Name (64 chars), Channel ID (32 chars), Min Follow Days (4 chars)
- Require Subscription toggle, Owner-Online Verification toggle
- "Fill from account" button (`twitchGetUserId` + `twitchGetUsername`)
- Save button: writes all 6 `crdt_api.updateServerSetting()` keys

---

## MobileSettingsTab (Restructured)

**File:** `lib/src/ui/mobile/tabs/mobile_settings_tab.dart`
**Purpose:** Full settings with pill tab bar. Replaces old single-section layout.

### Tab Bar
Horizontal scrollable `_PillTab` widgets: Profile, System, Security, About. Selected = accent fill + white text, unselected = surface bg + secondary text.

### Profile Tab
- **Live preview card** — bordered container (`surface` bg, `border` outline, `radiusMd`) with:
  - Banner (100px, tappable to change, long-press to clear)
  - Avatar (64px, overlapping banner, tappable/long-press)
  - Display name (bold, live-updates on keystroke)
  - Status (italic, live-updates)
  - Divider + "ABOUT ME" label + about text (live-updates)
  - Peer ID footer (faded short ID)
- Text fields below: Display Name (32), Status (48), About Me (128, 3 lines)
- Save Profile button
- Twitch connection row (disconnect works, connect deferred to desktop)
- `_populated` flag ensures fields fill from `profileProvider` on first available build (not stale `initState`)

### System Tab
- Peer ID (copyable, mono font, accent color)
- Network status (Connected/Connecting via `nodeProvider`)

### Security Tab
- Password Protection: enable (with confirm dialog) / remove
- Device Protection: enable/disable OS keychain (Windows/macOS only)
- Recovery Phrase button (loads from identity or storage API)

### About Tab
- Hollow branding + version (v0.4.2) + platform + license (AGPL-3.0) + links

---

## MobileFriendsTab (Enhanced)

**File:** `lib/src/ui/mobile/tabs/mobile_friends_tab.dart`
**Purpose:** Friend list with search, favourites, and long-press actions.

### Search
`HollowTextField` with search icon at top. Filters accepted friends by name (case-insensitive substring via `_resolvedName`).

### Sections (in order)
1. **Requests** (if any pending) — incoming + outgoing with accept/reject/cancel buttons
2. **Favourites** — starred friends pinned above online, ordered by `favouriteFriendsProvider` list order. Star icon on row.
3. **Online** — sorted alphabetically by resolved name
4. **Offline** — sorted alphabetically

### Long-Press Actions (bottom sheet with `SafeArea`)
- Message → navigate to DM
- View Profile → `showMobileProfileSheet`
- Favourite / Unfavourite → `favouriteFriendsProvider.toggle()`
- Set Nickname → dialog (32 chars, "only visible to you")
- Remove Friend → confirmation dialog → `friendsProvider.removeFriend()`

---

## Bottom Sheet SafeArea Pattern

**CRITICAL:** All `showModalBottomSheet` builders must wrap content in `SafeArea(child: ...)` for Android 3-button navigation bar compatibility. The canonical pattern is `mobile_chats_tab.dart:_showServerSheet`. For `DraggableScrollableSheet`, use `viewPadding.bottom + HollowSpacing.xl` in ListView padding instead.

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

---

## MobileVoiceChannelRoute

**File:** `lib/src/ui/mobile/mobile_voice_channel_route.dart`
**Class:** `MobileVoiceChannelRoute extends ConsumerStatefulWidget`
**Purpose:** Full-screen voice channel view (participants, video, controls). Pushed as `PageRouteBuilder` with slide-from-bottom transition.

### Constructor
| Parameter | Type | Description |
|---|---|---|
| `serverId` | `String` | Server ID |
| `channelId` | `String` | Voice channel ID |
| `channelName` | `String` | Display name |

### Layout
- Top bar: chevron-down (pops route) + `# channelName` + duration MM:SS
- Center: `MobileClusteredAvatars` (audio mode) or video grid (camera/screen share mode)
- Bottom controls: mute, deafen, camera, flip camera (mobile+camera on), leave (red)
- Auto-pops when `voiceChannelProvider` changes to different channel or leaves

### Video Modes
1. **Remote screen share**: full-bleed `RTCVideoView` with `ObjectFitContain` + local camera PiP
2. **Single local camera**: full self-view with mirror
3. **Single remote camera**: full remote + local PiP
4. **Multi-camera grid**: `Wrap` layout, tiles adapt to count

### Navigation Pattern
Voice channel tap in accordion (`mobile_chats_tab.dart`) pushes TWO routes:
1. `MobileChatRoute` (text chat) — underneath
2. `MobileVoiceChannelRoute` (voice view) — on top via `PageRouteBuilder` slide-from-bottom

Popping the voice route reveals the text chat. User can then read/send messages in the channel.

---

## MobileVoiceChannelPill

**File:** `lib/src/ui/mobile/mobile_voice_channel_pill.dart`
**Class:** `MobileVoiceChannelPill extends ConsumerStatefulWidget`
**Purpose:** Floating draggable pill shown when in a voice channel. Tap body returns to voice route.

### Layering
Lives in BOTH `MobileShell` Stack (visible on tabs) AND `MobileChatRoute` Stack (visible on chats). The voice route's `PageRouteBuilder` slide covers it when the full-screen view is active. **Never put in `app.dart` builder** — that layer is above the navigator and uncoverable.

### Visibility
- `vcState.isInVoiceChannel && callState.status == CallStatus.idle`
- Channel name from `vcState.currentChannelName` (NOT `channelListProvider`)

### Layout
`Positioned(bottom: 80)` → draggable Container (height 48, pill shape, green border, shadow) with:
- StatusDot (green, pulse) + `# channelName` + duration MM:SS + mute/deafen/leave buttons

---

## MobileVoiceAvatars (Shared Widgets)

**File:** `lib/src/ui/mobile/mobile_voice_avatars.dart`
**Purpose:** Shared avatar and control widgets extracted from `mobile_call_video_view.dart`, used by both DM calls and voice channels.

### MobileClusteredAvatars
Adaptive grid layout based on participant count (1→single, 2→row, 3→2+1, 4→2+2, 5→2+1+2, 6+→3 cols). Avatar size: 96 (≤2), 80 (≤4), 64 (>4).

### MobileSpeakingAvatar
`ConsumerStatefulWidget` with animated teal glow border (300ms easeOut). 3px border + 16px blur shadow when speaking. Muted badge (red micOff) at bottom-right.

### MobileControlButton
Circular button (configurable size/color). `AnimatedOpacity` 0.4 when disabled.

---

## Voice Channel Status Strip

**Widget:** `_VoiceChannelStatusStrip` (private, in `mobile_chat_route.dart`)
**Purpose:** Cross-server green strip shown in any chat when user is in a voice channel.

### Layout
Green bar (success color, 0.1 alpha background): dot + "In voice: #channelName" + "Tap to return" + chevronUp. Taps push `MobileVoiceChannelRoute` via `PageRouteBuilder` slide-from-bottom.

### Visibility
- `vcState.isInVoiceChannel` — shown in both DM and channel chats
- Channel name from `vcState.currentChannelName`

---

## Audio Settings (System Tab)

Added to `_SystemTab` in `mobile_settings_tab.dart`:

### Voice & Audio Section
- **Audio quality picker**: 3 pills (Voice/Music/Hi-Fi) with description label underneath. Reads/writes `audioQualityProvider`
- **Mic gain slider**: 0.0–2.0, reads/writes `micGainProvider`
- **Audio processing info**: Echo cancellation, noise suppression, AGC shown as "Auto" (always on)

### Ringtone Section
- **Ringtone picker**: file name + Choose button + clear (X). Reads/writes `ringtonePathProvider`
- **Ringtone volume slider**: 0.0–1.0, reads/writes `ringtoneVolumeProvider`
