# Mobile UI — Shell, Chat Route, and Actions

Covers all mobile-specific UI: the shell layout, chat route, message actions bottom sheet, and navigation. All files under `lib/src/ui/mobile/`.

---

## MobileShell

**File:** `lib/src/ui/mobile/mobile_shell.dart`
**Class:** `MobileShell extends ConsumerStatefulWidget` (stateful since 2026-06: registers push-notification tap handlers)
**Purpose:** 4-tab mobile layout replacing desktop HollowShell below 600px breakpoint.

### Push-tap navigation registration
`initState` (mobile platforms only) registers `PushNotificationService.registerOpenChatHandler(_openChatFromPush)` and `registerOpenChannelHandler(...)`. `_openChatFromPush(peerId)`: no-op if `selectedPeerProvider` already == peerId; else set selectedPeer, null selectedServer, `markDmSeen`, push `MobileChatRoute(peerId)` via rootNavigator, clear selection in `.then()` — identical to the in-app banner pattern. Taps that arrive BEFORE the shell mounts (cold start) are buffered inside PushNotificationService and delivered on registration.

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
- **Center "+" button** (`_AddButton`): 40×40 accent-colored rounded container with plus icon. Opens `NewConversationDialog` (Join Server, Create Server — no Add Friend, that's in Friends tab). Passed via `onAdd` callback from `MobileShell`.
- Archive tab
- Settings tab

### Background Image Layer
`MobileShell` watches `backgroundProvider`. When `bg.hasBackground`:
- Scaffold `backgroundColor` → `Colors.transparent`
- Wraps scaffold in Stack: `Image.memory(bg.imageBytes!, fit: BoxFit.cover)` → darken overlay `Container(color: hollow.background.withValues(alpha: darkenAlpha))` → scaffold
- `darkenAlpha = bg.panelOpacity.clamp(0.0, 0.92)` — user-controlled via Settings > Appearance > Panel Opacity slider
- Same pattern must be applied in `MobileChatRoute` (and any other pushed full-screen route) since pushed routes fully cover the shell

### Floating Pill Layering
`MobileShell` wraps its `Scaffold` in a `Stack` with `MobileNotificationBanner`, `MobileActiveCallPill`, and `MobileVoiceChannelPill` on top. These pills are also placed in `MobileChatRoute`'s Stack so they remain visible on pushed chat routes. Full-screen voice/call routes use `PageRouteBuilder` (slide-from-bottom) and cover the pills by being pushed on top in the navigator stack. **CRITICAL:** Pills must NOT go in `app.dart` builder — that layer is above the navigator and no route can cover it.

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
- **CRITICAL — rows are keyed by item identity** (`ValueKey('srv-${id}')` / `ValueKey('dm-${id}')` in the conversation ListView) and `_ChannelList` reloads in `didUpdateWidget` when `serverId` changes. The list mixes DMs and servers and reorders constantly; without keys Flutter re-parented row State across DIFFERENT conversations — a newly joined server displayed ANOTHER server's channel structure while every logged ID looked correct. Any row widget holding per-item loaded state needs both protections.

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
- `_lastTypingSent` — 3s throttle for typing indicators. `_onTextChanged` sends `sendTypingIndicator` for BOTH DMs (`serverId:''`, `channelId:peerId`) AND server channels (`serverId`/`channelId`) — previously it early-returned on `!isDm`, so a phone never showed as "typing…" in a server channel (fixed 2026-06-19; the Rust path was already correct).
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
│       └── VoiceRecorderBar (if _isRecordingVoice) OR _MobileInputBar (paperclip + image/gallery + text + emoji + mic + send)
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
- `_pickFile({bool imagesOnly = false})` — `FilePicker.platform.pickFiles(type: imagesOnly ? FileType.image : FileType.any)` → `network_api.sendFile`. The composer has TWO attach buttons: the paperclip (`onPickFile` → any file) and an image/gallery button to its RIGHT (`onPickImage` → `_pickFile(imagesOnly: true)`).

### Pin Messages (Channel Only)
- `pinnedProvider` loaded after channel history loads in `initState` `.then()` callback
- `_MobileChatHeader` title: DM → friend display name + Online/Offline subtitle; channel → `# channelName` + the **server name** as a subtitle (read from `serverListProvider.select((m) => m[serverId]?.name)`, ellipsis-truncated) so the user knows which server the channel belongs to
- `_MobileChatHeader` shows pin icon with count badge when `pinnedProvider[key]` is non-empty (between members icon and search icon)
- Tapping pin icon opens `_showPinnedMessagesSheet()` — bottom sheet with sender name, time, text preview for each pinned message
- `_showChannelActions()` wires `onPin` callback — permission-gated (`Permission.manageChannels`), toggles `crdt_api.pinMessage()`/`unpinMessage()`
- `isPinned` param passed to bottom sheet for "Pin Message"/"Unpin Message" label toggle

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
- **Server Template** — Export/Import buttons in a `Row`. Gated by `canManage`. Calls `exportServerTemplate(context, server)` and `importServerTemplate(context, ref, server)` from `server_template.dart`. Export passes `bytes:` on Android/iOS.
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
**Purpose:** Settings ROOT LIST that pushes full-screen subpages (iOS-Settings style). The old pill-tab bar + AnimatedSwitcher design was removed (2026-06).

### Root List (`MobileSettingsTab` — `ConsumerWidget`)
- "Settings" heading + **profile card** (HollowAvatar 48px, display name via `displayNameFor`, "Name, status, avatar & banner" caption, chevron) → pushes the Profile subpage.
- Divider (`hollow.textSecondary` @ 0.35 alpha) separates the profile card from the nav tiles.
- `_SettingsNavTile` rows (accent icon box 36px + title + subtitle + chevron). **Restructured 2026-06-21** to mirror the desktop category split: **Help**, **Appearance**, **Network**, **Audio & Video**, **Files & Storage**, **Security**, **Devices**, **Backup**, **About**. (The old single "System" and "Security" tiles were split.)
- `_push()` → `Navigator.push(MaterialPageRoute(_SettingsSubPage(title, child)))`.
- **Bottom of the list:** `_MobileStatsCard` ("Your Stats" — Friends / Servers / DM messages / Devices online, mirrors the desktop Home `_SyncStatsCard` for eyeball multi-device sync comparison), followed by `_MobileOnlineCounter` (a port of the desktop Home shell's bottom "Online … N" row — users icon + `_MobileShimmerLine` divider + live `relayStats.onlineUsers`).

### _SettingsSubPage
Full-screen scaffold matching MobileServerSettingsRoute chrome: `SafeArea > Column[back-arrow header row (HollowPressable + heading), Divider, Expanded(child)]`. The bodies are: `_ProfileTab`, `_AppearanceTab`, `_NetworkTab` (formerly `_SystemTab`, trimmed to Peer ID + relay), `_AudioTab`, `_FilesTab`, `_SecurityTab` (trimmed to App Lock + Device Protection + Recovery), `_DevicesTab`, `_BackupTab`, `_AboutTab`. The new tabs (`_AppearanceTab`/`_AudioTab`/`_FilesTab`/`_DevicesTab`/`_BackupTab`) are thin compositions of the same already-modular section widgets (`_ThemeToggleRow`, `_AccentHueSection`, `_BackgroundSection`, `_AudioQualityPicker`, `_RingtonePicker`, `_ImageQualityPicker`, `_AutoDownloadSlider`, `_CacheCapSlider`, `_DevicesSectionMobile`, `_LinkDeviceButton`, `_ResetDeviceListButton`, `_BackupExportButton`). `_AutoDownloadSlider` (previously unused) is now wired into `_FilesTab`.

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

### System Tab (`_SystemTab` — `ConsumerStatefulWidget`)
Sections in order:
1. **Peer ID** — copyable (mono font, accent color, tap → clipboard)
2. **Network** — relay domain management:
   - Relay list from `savedRelayListProvider` (radio-style selection, official badge on default)
   - Add relay: inline TextField + Add/Cancel
   - Remove relay: X button on non-default relays
   - "Apply & Close App" (conditional) → `relayDomainProvider.setDomain()` → `notifyShutdown()` → `SystemNavigator.pop()`
3. **Appearance** — `_ThemeToggleRow` (dark/light switch, immediate apply via `themeModeProvider`), `_AccentHueSection` (rainbow slider 0-359° via `RainbowSliderTrackShape`, preset swatches 28x28 in Wrap, long-press to remove, + to save), `_BackgroundSection` (file picker → mobile crop 9:16 → `backgroundProvider.setImage()`, opacity slider 0.0–0.92), `_InvisibleToggleRow` (`invisibleModeProvider`). **Reduce Motion moved out of Appearance** (2026-06-24) into a new **Accessibility** nav tile → `_AccessibilityTab`: `_ReduceMotionRow` (tri-state Auto/On/Off `_MobileSegment` → `reduceMotionProvider`/`ReduceMotionController`) + `_ReduceTransparencyRow` (`reduceTransparencyProvider`)
4. **Voice & Audio** — audio quality pills, mic gain slider, audio processing info
5. **Files** — `_ImageQualityPicker` (Lossless/Balanced/Small pills via `imageQualityProvider`), `_AutoDownloadSlider` (34-2048 MB), `_CacheCapSlider` (256-10240 MB, formatted as GB when ≥1024)
6. **Ringtone** — ringtone picker + volume slider

### Security Tab (App Lock: PIN / password / biometric)
- **App Lock row**: status "PIN enabled" / "Password enabled" / "Not set". Enable → `_chooseLockType()` bottom sheet (`_LockTypeOption` rows: PIN 4-8 digits / Password / a THIRD grayed-out "Fingerprint / face unlock" entry, `onTap: null` → 0.55 opacity, no chevron, not pressable, subtitle "Available once a PIN or password is set" — biometric is a layer on top of a PIN/password, not its own lock type) → `_askSecret()` dialog (numeric keyboard + `FilteringTextInputFormatter.digitsOnly` + maxLength 8 for PIN, confirm field, min-4-digit check) → `identity_api.enablePasswordProtection` (PIN = numeric secret through the SAME Rust Argon2id flow) + `AppLockService.setLockType` + `sessionSecret` cache. Remove → ask current secret → `removePasswordProtection` + `AppLockService.clearAll()`. **Enable/Remove run Argon2id (~seconds)** → the button is swapped for an inline 18px `CircularProgressIndicator` while busy (`_appLockBusy` flag, reset in `finally`).
- **Biometric row** (mobile + lock enabled + `canUseBiometrics()`): Switch (`activeThumbColor`). ON → needs the secret (`sessionSecret` or re-ask) → one live `promptBiometric()` check → `enableBiometric(secret)` stores it in flutter_secure_storage. See `lib/src/core/services/app_lock_service.dart`. (`canUseBiometrics()` requires `getAvailableBiometrics().isNotEmpty` — some Pixels report Face Unlock as class-2/weak and return empty even with enrolled biometrics; relax that check if the Switch never appears.)
- Device Protection: enable/disable OS keychain (Windows/macOS only)
- Recovery Phrase button (loads from identity or storage API)
- **Account Backup** section (`_BackupExportButton`): exports a passphrase-encrypted `.hollow` file. Toggles for "Include downloaded files" / "Include vault shards". Since Rust `exportBackup` writes to a path it owns, mobile exports to a temp file under `hollowDataDir`, reads the bytes, hands them to `FilePicker.saveFile(bytes:)` (required on Android/iOS), then deletes the temp file. Passphrase via `_askBackupPassphrase` (HollowDialog with confirm field). IMPORT is NOT here — it lives in the first-launch welcome dialog (`welcome_dialog.dart`), since `importBackup` overwrites the data dir and must run before the node starts; that picker uses `FileType.any` on mobile (`.hollow` isn't a recognized iOS/Android UTI, so `FileType.custom` hides it).
- Unlock-at-launch flow lives in `hollow_shell.dart _showPasswordUnlockDialog`: biometric prompt FIRST, then PIN/password dialog (fingerprint retry button); all unlock/recovery dialogs use `(screenWidth - padding).clamp(0, maxW)` widths.
- **Unlocking… spinner** (`_UnlockingOverlay`, flag-driven `Stack` over the shell — NOT a dialog, so nothing races it dismissed): the post-unlock Argon2id derivation (~1.5-3s) + the local DB load can't begin until unlock finishes (the SQLCipher passphrase is derived from the just-unlocked identity — local-first render can't help). `_unlocking` is set the instant a secret is in hand (both `tryBiometric` and the password-entry path) and cleared after `profileProvider`/`friendsProvider` load in `_bootstrap` (conversation list renderable). Only shows when an App Lock is active; wrong-secret + identity-error paths clear it. See `feedback_app_lock_unlock_ux` memory.

### About Tab
- Centered `hollow_logo_rounded.png` (96x96, ClipRRect rounded) + "Hollow" display text + tagline
- Info section: version (v0.4.2), platform, license (AGPL-3.0)
- Links section: anonlisten.com, github.com/AnonListen/Hollow

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

### Add Friend Dialog (`_AddFriendDialog`)
Unified input: auto-detects peer ID (`12D3KooW` prefix) vs temporary nickname. Below the input, a "Your temporary nickname" section lets users claim/release an ephemeral relay-scoped nickname (watches `temporaryNicknameProvider`). Shows claim input (3-20 chars), claimed badge with Release button, or error state (taken/invalid).

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
    ├── Pin/Unpin Message (LucideIcons.pin) — manageChannels permission, channel only
    └── Delete Message (LucideIcons.trash2, error color) — own messages only
```

### Three Views (AnimatedSize transitions)
1. **actions** — default view with action rows
2. **allEmojis** — full 30-emoji grid (6 columns), triggered by "More..." button. Back button returns to actions.
3. **deleteConfirm** — inline confirmation: warning icon + "Delete this message? This can't be undone." + Cancel/Delete buttons

### Parameters
All action callbacks are nullable — only shown when non-null:
- `onReply`, `onEdit`, `onDelete`, `onCopy`, `onDownload`, `onPin` — `VoidCallback?`
- `onReaction` — `void Function(String emoji)?`
- `onInfo` — `VoidCallback?`
- `isPinned` — `bool` (toggles "Pin Message"/"Unpin Message" label)

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
- **Mic gain slider** (`_MicGainSlider`): 34%–200%, 83 divisions, default 100%, with a caption line. Reads/writes `micGainProvider` (clamped 0.34–2.0). Drives the native **post-APM capture makeup gain + -3 dB soft limiter** via `Helper.setCaptureGain()` (the old `setVolume` on the local track was a no-op for outgoing audio). Floor 34% (not 0) so it can't mute. Applies live mid-call
- **Audio processing info**: Echo cancellation, noise suppression, AGC shown as "Auto" (always on)

### Ringtone Section
- **Ringtone picker**: file name + Choose button + clear (X). Reads/writes `ringtonePathProvider`
- **Ringtone volume slider**: 0.0–1.0, reads/writes `ringtoneVolumeProvider`

---

## MobileImageCropRoute

**File:** `lib/src/ui/mobile/mobile_image_crop_route.dart`
**Entry point:** `showMobileImageCrop({context, imageBytes, aspectRatio, title})` → pushes route, returns `Uint8List?`

### Design: Fixed Frame + Movable Image
Standard mobile crop pattern (like iOS Photos). The crop frame is fixed in the center; the user drags and pinch-zooms the image underneath.

### Layout
- Scaffold (black background) → SafeArea → Column
- Header: back arrow + title + "Pinch to zoom" hint
- Expanded: `LayoutBuilder` → `GestureDetector(onScaleStart/Update/End)` → Stack with positioned image + IgnorePointer crop overlay
- Bottom: Cancel (ghost) + Apply (filled)

### Gesture Handling
Manual `_scale`, `_offsetX`, `_offsetY` state (no `InteractiveViewer`). On every gesture update:
- Scale: clamped 1.0–8.0, zooms around focal point
- Pan: offset applied from gesture delta
- **Clamping** (`_clampOffset`): image left edge ≤ crop left, image right ≥ crop right, same for top/bottom. Ensures crop frame NEVER shows empty space.

### Crop Rendering
1. Compute source rect: `(cropFrame - offset) / scale * (imgPixels / basePixels)`
2. `PictureRecorder → Canvas.drawImageRect → picture.toImage → toByteData(format: png)`
3. Safety clamp to image bounds

### Aspect Ratios Used
- Avatar: 1.0 (square)
- Banner: 3.0 (wide)
- Background: 9.0/16.0 on mobile (portrait), 16.0/9.0 on desktop (landscape)

### Crop Overlay Painter
`_CropOverlayPainter`: dark overlay outside crop (clipRect difference), 2px accent border, rule-of-thirds grid (0.3 alpha), corner brackets (3px stroke, 20px length).

---

## MobileStorageRoute

**File:** `lib/src/ui/mobile/mobile_storage_route.dart`
**Purpose:** Full-screen server storage dashboard, pushed from server settings Management section.

### Data Loading
- `crdt_api.getStorageStats(serverId:)` → `StorageStatsFfi`
- `crdt_api.getServerSetting(serverId:, key: 'retention_files'/'retention_messages')`

### Sections
1. **Server Storage** — colored bar (green/yellow/red by fill %), used/total, vault mode label, member count. Full replication (<6) vs erasure coding (6+) with redundancy factor.
2. **Your Storage** (6+ members) — pledge amount with edit button (HollowDialog), usage bar.
3. **Retention Policy** — messages + files retention display. Admin can tap to edit (HollowDialog with radio-style options). Records `_since` timestamp for forward-only pruning.
4. **Vault Health** — StatusDot + status text + shard count. Pulse animation on active transfers.
5. **Member Pledges** (6+ members) — member count + average pledge.

### Navigation
Added as `_NavRow(icon: LucideIcons.hardDrive, label: 'Storage')` in `MobileServerSettingsRoute` Management section, visible to all members.

---

## MobileArchiveTab

**File:** `lib/src/ui/mobile/tabs/mobile_archive_tab.dart`
**Class:** `MobileArchiveTab extends ConsumerWidget`
**Purpose:** Full archive tab (bottom nav index 2). My Data + Imported Archives sub-tabs.

### Deferred Loading
Watches `mobileTabProvider` — returns `SizedBox.shrink()` when `activeTab != 2`. Prevents `archiveDmListProvider` from firing before the message store is open at startup.

### Top-Level Structure
- "Archive" heading + pill sub-tab row: "My Data" | "Imported" (uses `archiveSubTabProvider`)
- `AnimatedSwitcher` (200ms) switches between `_MobileMyDataView` and `_MobileImportedArchivesView`

### _MobileMyDataView (ConsumerStatefulWidget)
- Inner pill tabs: DMs | Channels (uses `myDataInnerTabProvider`, no Vault Files — deferred to Section 25)
- Search field (uses `archiveSearchProvider`)
- **DM list:** Avatar + name + message count + eye icon (hide/unhide). Hidden section with expandable `AnimatedSize`. Tap → push `MobileArchiveViewerRoute(peerId:)`. Long-press → bottom sheet (Export, Hide/Unhide).
- **Channel list:** Grouped by server headers (uppercase). Each channel: # + name + count. Server headers have export icon. Tap → push `MobileArchiveViewerRoute(serverId:, channelId:)`. Long-press → export bottom sheet.
- Selection providers set before push, cleared in `.then()`.

### _MobileImportedArchivesView (ConsumerStatefulWidget)
- "Load Archive" button → `FilePicker` (no drag-drop on mobile)
- List of `_MobileArchiveEntryCard` widgets showing: type icon, name, verification shield badge, detail text, message count, date
- Tap → push `MobileImportedArchiveViewerRoute(path:)`. Long-press → remove bottom sheet.

---

## MobileArchiveViewerRoute

**File:** `lib/src/ui/mobile/mobile_archive_viewer_route.dart`
**Class:** `MobileArchiveViewerRoute extends ConsumerStatefulWidget`
**Purpose:** Full-screen read-only message viewer for My Data (DMs and channels).

### Constructor
| Parameter | Type | Description |
|---|---|---|
| `peerId` | `String?` | DM peer (mutually exclusive with serverId/channelId) |
| `serverId` | `String?` | Server ID for channel viewer |
| `channelId` | `String?` | Channel ID for channel viewer |

`isDm` getter: `peerId != null`.

### Header (_MobileArchiveHeader)
Back button, avatar (DM) or # icon (channel), title, subtitle "in serverName" (channel), icon buttons: filter (channels, >1 sender), calendar (jump-to-date), search toggle, export, "read-only" badge.

### Message List
- `ScrollablePositionedList.builder` with `ItemScrollController`
- `DateSeparator` + `shouldGroup` / `shouldShowDateSeparator` (reused from `chat_pane.dart`)
- `MessageBubble` (DM) or `ChannelMessageBubble` (channel)
- `_DeletedOverlay` for `hiddenAt != null`
- `EditHistoryIndicator` (reused from `archive_message_viewer.dart`)
- `_LongPressMessage` wrapper → `showMobileArchiveMessageActions()`
- Reply lookups from same message list (channels: from unfiltered `allMessages`)
- `AnimatedSwitcher` crossfade from loading spinner to content

### Search
Reuses `ArchiveSearchBar` from `archive_message_viewer.dart`. Match indices computed inline, prev/next cycle with `_scrollToIndex()` + 1.5s highlight.

### Sender Filter (Channel only)
`_FilterSheet` bottom sheet with searchable participant list. Sets `archiveFilterSenderProvider`.

### Jump-to-Date
`showDatePicker()` → `archiveJumpToDateProvider` → binary search scroll.

### File Save
Same pattern as `mobile_chat_route.dart:_saveFile()` — WebP→PNG conversion, `FilePicker.platform.saveFile(bytes:)`.

### Provider Cleanup
Resets `archiveFilterSenderProvider`, search/jump providers in `dispose()` via `addPostFrameCallback`.

---

## MobileImportedArchiveViewerRoute

**File:** `lib/src/ui/mobile/mobile_imported_archive_viewer_route.dart`
**Class:** `MobileImportedArchiveViewerRoute extends ConsumerStatefulWidget`
**Purpose:** Full-screen viewer for imported `.hollow-archive` files.

### Constructor
| Parameter | Type | Description |
|---|---|---|
| `path` | `String` | File path of the `.hollow-archive` |

### Data Loading
Uses `importedArchiveDataProvider(path)` with `AnimatedSwitcher` crossfade from spinner to content.

### Verification Banner
- Archive signature status: shield icon + text (signed by exporter or invalid)
- Message signature counts: valid/invalid/unsigned
- Color-coded: accent (valid), amber (warnings), error (invalid)

### Channel Selector (Server Archives)
Horizontal scrolling pill tabs for multi-channel server archives. Uses `importedArchiveSelectedChannelProvider`. Resets filter/search on channel switch.

### Message List
Same pattern as `MobileArchiveViewerRoute`: `ScrollablePositionedList`, date separators, grouping, reply lookups, edit history, deleted overlay, long-press actions, search bar.

### Message Conversion
Uses `convertArchiveDmMessages()` / `convertArchiveChannelMessages()` from `archive_provider.dart`.

---

## MobileArchiveMessageActions

**File:** `lib/src/ui/mobile/mobile_archive_message_actions.dart`
**Function:** `showMobileArchiveMessageActions(context, messageText, senderName, timestamp, {onCopy, onDownload, onInfo})`
**Purpose:** Read-only long-press bottom sheet for archive messages.

### Actions (subset of showMobileMessageActions)
- Copy Text — when message has text
- Save File — when file attachment with diskPath
- Message Info — opens message proof dialog

### Animation
Staggered entrance (400ms): message preview fades+slides in first, then each action row with 0.15 offset. Exit handled by `showModalBottomSheet`'s built-in slide-down.

## MobileInChatBanner (in-app notification)

**File:** `lib/src/ui/mobile/mobile_notification_banner.dart`
**Class:** `MobileInChatBanner extends ConsumerStatefulWidget`
**Purpose:** The ONLY mobile in-app notification banner. Shown WHILE the user is inside a chat, for messages arriving in OTHER conversations. (The old top-tabs `MobileNotificationBanner` was removed — outside a chat, mobile relies on OS notifications.)

### Mounting & behavior
- Mounted in `MobileChatRoute`'s return Stack with `currentPeerId`/`currentServerId`/`currentChannelId` (suppresses the conversation being read) and `topOffset = MediaQuery.paddingOf(context).top + 64` (clears the chat header).
- Watches `systemNotificationProvider`; picks the newest card that isn't the current conversation.
- Slides down from top (~280ms easeOutCubic) + fade. Body wrapped in `Material(type: transparency)` (avoids the yellow debug double-underline on a Positioned-in-Stack `Text`).
- **Accumulation:** adopts the FRESH card when the same source grows (the cached `_currentCard` is an immutable snapshot — must re-point to it). Shows the last **3** messages (provider caps the stack at 5).
- **Countdown ring (`_CountdownRing`):** depleting `CircularProgressIndicator` + remaining seconds (5→1) in the banner's right space, driven by a 5s `AnimationController` that auto-dismisses on complete. Swipe-up or tap also dismiss; tap navigates to the source conversation.

### Mobile @mention autocomplete (channels)
`mobile_chat_route.dart`: `_updateMentionAutocomplete` (from `_onTextChanged`, channels only) scans back from the cursor for an `@` at word-start, builds candidates from `serverMembersProvider` + `@everyone` (`serverDisplayNameFor`/`serverNicknamesProvider`), and renders `_buildMentionPanel` ABOVE the input bar (a Column child after `_TypingBar`, NOT an OverlayEntry). `_acceptMention` replaces `@query` with `@DisplayName `. Cleared on send. Class `_MobileMentionCandidate`.

## DM Long-Press Context Menu

**File:** `lib/src/ui/mobile/tabs/mobile_chats_tab.dart` (`_DmContextSheet`)
**Trigger:** `onLongPress` on `_DmRow` in the Chats tab conversation list.

### Actions
- Mute/Unmute Notifications — toggles `notificationSettingsProvider.setDmEnabled`
- Export Archive — opens `showExportArchiveDialog` (messageCount: 0, count hidden)
- Hide/Show in Archive — toggles `hiddenArchiveDmsProvider`
- Copy Peer ID — clipboard + toast

### Pattern
Reuses existing `_SheetAction` widget (same as server context sheet). Bottom sheet with drag handle + peer name header.

## Notification Levels (Server Settings)

**File:** `lib/src/ui/mobile/mobile_server_settings_route.dart` (`_NotificationSection`)
**Purpose:** Server-wide + per-channel notification level control.

### Server-Wide Level
3 pills in a Row: All Messages (bell, accent) / Mentions Only (atSign, warning) / Nothing (bellOff, error). Uses `notificationSettingsProvider.setServerLevel()`.

### Per-Channel Overrides
List of channels with current level badge. Tap → bottom sheet with 4 options: Default / All / Mentions / Nothing. Uses `notificationSettingsProvider.setChannelOverride()`.

## Vault Files Tab (Archive)

**File:** `lib/src/ui/mobile/tabs/mobile_archive_tab.dart` (`_MobileVaultFilesView`)
**Purpose:** Third inner pill tab in My Data (DMs | Channels | Vault).

### Layout
- When `recoveryPoolProvider` is active and not pending, shows the desktop `RecoveryPoolDashboard` widget directly (zero desktop-specific deps)
- Otherwise: "Join Recovery Pool" accent button (reuses `showJoinRecoveryPoolDialog`) + server list
- Server list: `_VaultServerSection` expandable per-server (auto-expands if files exist)
- Per-server: `_VaultFileRow` with file icon, name, size, shard progress bar, "X/Y" badge
- Badge colors: green (reconstructable), orange (partial), gray (no shards)
- Long-press on server header (or tap ellipsis icon): bottom sheet with Export Shards, Import Shards, Start Recovery Pool actions
- Shard export uses mobile file save pattern (temp dir → FFI → bytes → `FilePicker.saveFile(bytes:)`) on Android/iOS

## About Tab (Relay Stats + News + Links + Legal)

**File:** `lib/src/ui/mobile/tabs/mobile_settings_tab.dart` (`_AboutTab`)

### Info Section
`_InfoRow` widgets: Version (0.4.2), Platform (`Platform.operatingSystem` — dynamic), License (AGPL-3.0).

### Relay Stats Card
Container with status dot (green if `relayStats.isFresh` — a fetch succeeded in the last ~20s; was `fetchCount > 0` which stayed green forever after the first fetch), relay domain, online users count, RAM usage bar (`_StatBar`), bandwidth bar. Watches `relayStatsProvider` (7s polling).

### News Section
Latest 3 posts from `newsProvider`. Cards show title + date + a 4-line plain-text teaser (`_plainTeaser()` strips markdown markers so `**`/`#`/`[]()` don't show raw). Tap opens `showHollowDialog` with the full body rendered as real markdown via `MarkdownBody` (same `flutter_markdown_plus` + stylesheet as the desktop `home_dashboard` news, with `onTapLink` → external browser), title, date, and X close button. Previously the expanded body was plain `Text(post.body)` — markdown rendering was added to match desktop.

### Contact Section
`HollowButton.ghost` with icons: email (copies to clipboard), website (opens external browser), GitHub (opens `github.com/VitalikPro13/HOLLOW` externally). Uses `BrandIcons.github` for GitHub icon.

### Follow & Support Section
Row header: "Follow ---shimmer--- Support" using `_MobileShimmerLine` (same shimmer as desktop `_AboutShimmerLine`).
Brand icon row: YouTube, X, Twitch, Kick | shimmer divider | Patreon, Ko-Fi. `_MobileBrandIcon` widgets in bordered containers, tap opens external browser.

### Legal Section
`HollowButton.ghost` with icons: Privacy Policy, Terms of Use (open `_showLegalSheet` — `DraggableScrollableSheet` with `Markdown` widget from `flutter_markdown_plus`, styled `MarkdownStyleSheet` matching desktop), Open-Source Licenses (Flutter's built-in `showLicensePage`).

### System Tab Notes
- Auto-Download slider removed (Share system is N/A on mobile, setting has no effect)
- Ringtone picker: resets `ringtoneStart`/`ringtoneEnd` and probes duration via `AudioPlayer` when new file selected (matches desktop pattern). "Trim" button opens shared `showRingtoneClipEditor()` dialog.
- Accent swatches (`_MobileColorSwatch` + save-preset button) are 36×36 (touch-target minimum; were 28×28).

## Mobile Call Screens — Audio Routing, Badges, Proximity, Wakelock, Screen Share

Implemented 2026-06 across `mobile_call_video_view.dart` (1:1) and `mobile_voice_channel_route.dart` (VC).

### Control rows (identical order in 1:1 and VC)
mute, deafen (headphones, red when active), speaker (`LucideIcons.speaker`, accent when on), camera, [flip — VC only when camera on], hang up. VC row shrinks buttons 56→46px when ≥6 buttons (Row overflow on 360dp). The 1:1 remote-volume sheet was REMOVED from mobile (desktop volume popup remains).

### Speaker routing (`Helper.setSpeakerphoneOn`, mobile-gated)
Defaults: 1:1 voice → earpiece, 1:1 video → speaker, camera-on mid-call → auto-switch to speaker, VC join → speaker. Reset to earpiece in `_cleanup()` / `onLocalLeft()` so the next call never inherits a stale route. State: `CallState.isSpeakerOn` / `VoiceChannelState.isSpeakerOn`.

### Mute/deafen badges (convention everywhere)
Muted badge = bottom-LEFT, deafened badge = bottom-RIGHT (red box, white icon, `micOff`/`headphoneOff`). Widgets: `_AvatarBadge` in `mobile_voice_avatars.dart` (`MobileSpeakingAvatar.isMuted/isDeafened`, `MobileClusteredAvatars.mutedSet/deafenedSet`), desktop 1:1 `_badgedCallAvatar` in `chat_pane.dart`. Data: VC = `peerAudioStates`; 1:1 = `CallState.isMuted/isDeafened/remoteMuted/remoteDeafened` (synced via the `audio_state` call signal — see providers_voice_files.md).

### Proximity + wakelock
**Proximity is GLOBAL (since 2026-06-21), not per-screen.** `CallProximityController` (`lib/src/ui/mobile/call_proximity_controller.dart`) — a pure side-effect `ConsumerWidget` mounted in `app.dart`'s mobile `Stack` (next to `IncomingCallOverlay`, always alive) — watches BOTH `callProvider` and `voiceChannelProvider` and engages `proximity_sensor` screen-off whenever EITHER is in earpiece mode (active call/VC, no speaker, no local/remote video; `_vcHasVideo` mirrors the VC route's `_hasVideo`). This blanks the screen on ear-hold from ANY screen, not just the call sheet (the old per-screen `_syncProximity` only ran while that widget was built). Android needs WAKE_LOCK (present); iOS blanks natively while the events stream is subscribed. **Wakelock stays screen-scoped:** `_syncWakelock` in each call screen uses `wakelock_plus` (^1.5.2 — 1.6+ conflicts with file_picker via win32) to keep the screen on while video/screen share is displayed; disabled in dispose.

### Incoming screen share on mobile (1:1)
`_hasRealVideo` and `_buildVideoView` check `call.remoteScreenSharing && notifier.screenShareRenderer?.srcObject != null`; the share renders full-bleed inside `InteractiveViewer(maxScale: 6)` (pinch-zoom), taking priority over camera feeds, with the local camera PiP on top. The VC screen-share view got the same InteractiveViewer wrap. (Before 2026-06 the mobile 1:1 view was camera-only and silently ignored an incoming share.)

### PiP drag bounds
Both screens clamp the camera PiP to `dy: 0..(screenHeight - 260)` (was hard-coded 400 — PiP got stuck mid-screen on tall phones).

## Mobile UX Hardening (2026-06)

One-pass fixes from the production-readiness audit:

- **Keyboard-aware dialogs (global):** `showHollowDialog` wraps every pageBuilder in `AnimatedPadding(MediaQuery.viewInsetsOf)` + `MediaQuery.removeViewInsets` (mirrors Flutter's Dialog). NEVER add viewInsets padding inside a dialog builder — double-pad. `HollowDialog` itself: full-width-minus-padding under 600px, content in `Flexible > SingleChildScrollView`, actions in `Wrap`.
- **Add Friend** is a bottom sheet (`_AddFriendSheet` in mobile_friends_tab.dart): input + full-width Send Friend Request directly below, temporary-nickname claim boxed off in a separate "Want them to add you instead?" card. `isScrollControlled` + manual viewInsets bottom padding + SafeArea.
- **Send jump fix (mobile_chat_route.dart):** sending uses post-frame `_jumpToBottom()` (instant), never animated scrollTo — the animated path raced the chatProvider listener auto-scroll + the input bar collapsing after `clear()` (the iOS "jump for a second"). `_scrollToBottom` (incoming messages) is post-frame-safe with mounted/isAttached guards.
- **In-channel search:** results box sizes to `(visible height - keyboard) * 0.35` clamped 120–360 (was fixed 200px).
- **Inline edit:** `_startEditing` scrolls the editor to alignment 0.15 after a 300ms delay (post keyboard animation) so it's never hidden behind the keyboard.
- **Message actions sheet:** `isScrollControlled` + 85%-height cap + internal `SingleChildScrollView` (emoji grid clipped on short phones).
- **Toast position:** `HollowToast` bottom = 32 + keyboard inset + (width<600 ? 56 + viewPadding.bottom : 0) — floats above the nav bar and keyboard.
- **Pills:** both `MobileActiveCallPill` and `MobileVoiceChannelPill` clamp `_dragOffset` (dx ±(w/2−80), dy −(h−136−topInset)..0) — can't be dragged into the nav or off-screen.
- **Image crop:** portrait orientation lock while open (rotation reset the crop), decode capped at `targetWidth: 2048, allowUpscaling: false` (raw RGBA OOM guard).
- **Welcome dialog:** compact-aware minWidth + internal scroll.
- **iOS:** `audio` added to UIBackgroundModes (calls survive backgrounding).

### Accessibility — Reduce Motion + Larger Text (2026-06-25)

- **ALL mobile page pushes go through `hollowMobileRoute()`** (`lib/src/ui/mobile/mobile_page_route.dart`), NOT raw `MaterialPageRoute`/`PageRouteBuilder`. (Docs elsewhere in this file that still say "pushed as `PageRouteBuilder`" / `MaterialPageRoute(...)` are describing the pre-2026-06-25 code — the transition mechanism is now `hollowMobileRoute()` everywhere; the destination widgets are unchanged.) `hollowMobileRoute({builder, transition: slideRight|slideUp|fade, duration, settings})` gates the transition duration on `ReduceMotionController.instance.isReduced` (`Duration.zero` when reduced). **Why it matters:** a raw `MaterialPageRoute`'s transition is governed ONLY by Flutter's built-in `MediaQuery.disableAnimations` (OS reduce-motion flag) — the in-app tri-state control couldn't stop it (On) nor force it back on (Off, when OS was on). Routing through `hollowMobileRoute()` makes `ReduceMotionController` the single authority: **On = instant, Off = animates even with OS reduce-motion on, Auto = follows OS.** Default `slideRight`; voice-channel/call routes use `slideUp`.
- **Noticeable one-shot animations (300ms+)** that hardcode their own durations also gate on `isReduced`: nav-bar glow `AnimatedPositioned` (`mobile_nav_bar.dart`), storage usage-bar `TweenAnimationBuilder` (`mobile_storage_route.dart`), scroll-to-message `scrollTo` (`mobile_chat_route.dart` + both archive viewers), archive-viewer `AnimatedSwitcher` content swaps. `Future.delayed` LOGIC timers are NOT animations — left alone. Sub-200ms micro-fades intentionally left. Implicit `Animated*` using `HollowDurations.fast/normal/slow` already snap to zero via the controller.
- **Larger Text (P3 stage 1):** mobile text-scale cap raised to **2.0×** (`app.dart` `withClampedTextScaling(0.8, 2.0)`). Mobile chrome bars stay fixed-height but **cap their labels** with `MediaQuery.withClampedTextScaling(maxScaleFactor: 1.3, child: Text(...))` (tab-bar norm): `mobile_nav.dart` + `mobile_nav_bar.dart` nav captions. Mobile chat header (`mobile_chat_route.dart`) uses `Container(constraints: BoxConstraints(minHeight: 52))` to GROW. **NEVER wrap a full-width bar in a bare `ConstrainedBox(minHeight:)`** — it unbounds width and collapses the layout; put `constraints:` on the Container or cap the label. CI: `test/widget/text_scale_overflow_test.dart` pumps the mobile shell at 1.0×/1.5×/2.0× asserting no RenderFlex overflow.
