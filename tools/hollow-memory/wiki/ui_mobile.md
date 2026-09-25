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

The tab body is a `Stack` with one `Offstage` per tab: switching is instant, and every tab stays mounted so its scroll and state survive the switch.

| Index | Tab | Widget | Icon |
|-------|-----|--------|------|
| 0 | Chats | `MobileChatsTab` | `LucideIcons.messageCircle` |
| 1 | Friends | `MobileFriendsTab` | `LucideIcons.users` |
| 2 | Archive | `MobileArchiveTab` | `LucideIcons.archive` |
| 3 | Settings | `MobileSettingsTab` | `LucideIcons.settings` |

Tab state: `mobileTabProvider` (`StateProvider<int>`, default 0) in `lib/src/ui/shell/mobile_nav.dart`.

### MobileNavBar
**File:** `lib/src/ui/mobile/mobile_nav_bar.dart`
Bottom bar (56px) with 4 `_NavTab` widgets + center `_AddButton`. Uses `LayoutBuilder` + `Stack` for the active-tab bar.
- **Active-tab bar (2026-09-24, Vitalik's pick over accent-only and the old radial glow):** a 32 x 2 px accent bar on the bar's top edge above the active tab, sliding by `AnimatedPositioned` (`HollowDurations.normal`, `HollowCurves.subtle`, zero under reduce motion), so the active tab reads by POSITION as well as colour. Maps tab indices 0,1 to slots 0,1 and 2,3 to slots 3,4 (skipping the centre slot). Icons 24; the label keeps one weight whether active or not (a bold active label reflowed).
- Chats tab: total unread count (DM + channel)
- Friends tab: pending incoming friend request count
- **Center "+" button** (`_AddButton`): 40×40 accent-filled rounded container with plus icon, no shadow (the accent glow went with the tab glow). Semantics "Add a server". Opens `showCreateServerDialog` (`dialogs/create_server_dialog.dart`), the desktop "Add a server" dialog, whose two halves ("Join a server" / "Start your own") stack on a phone. Join refuses text that is not an invite link or a 32-hex server id (`isServerIdShape`), inline: "That isn't an invite link or server ID. Check what you pasted." Passed via `onAdd` callback from `MobileShell`. The phone's own `NewConversationDialog` is deleted (2026-09-25).
- Archive tab
- Settings tab

### Background Image Layer
`MobileShell` watches `backgroundProvider`. When `bg.hasBackground`:
- Scaffold `backgroundColor` → `Colors.transparent`
- Wraps scaffold in Stack: `Image.memory(bg.imageBytes!, fit: BoxFit.cover)` → darken overlay `Container(color: hollow.background.withValues(alpha: darkenAlpha))` → scaffold
- `darkenAlpha = bg.panelOpacity.clamp(0.0, 0.92)` — user-controlled via Settings > Appearance > Panel Opacity slider
- Same pattern must be applied in `MobileChatRoute` (and any other pushed full-screen route) since pushed routes fully cover the shell

### The minimised call (was the floating pills)
`MobileShell` wraps its `Scaffold` in a `Stack` with `MobileMinimisedCall()` on top: the call you are in, floating 12 px above the nav bar. `MobileChatRoute` DOCKS it under its header (`MobileMinimisedCall(floating: false)`) instead. Call routes are pushed on top and cover it. **CRITICAL:** never in the `app.dart` builder: that layer is above the navigator and no route can cover it. Only the incoming screen lives there. See wiki `ui_call_surfaces` (Phone).

### MobileChatsTab: the phone's Home (2026-09-24)
**File:** `lib/src/ui/mobile/tabs/mobile_chats_tab.dart`

The desktop Home inbox on a phone, plus the server list (a phone has no dock). Wiki `ui_home_dashboard` has the shared pieces.
- **Title row:** `HomeGreeting` (the same greeting as desktop), then two 44 px icon actions: Conferences and New message (`LucideIcons.squarePen`, only once there is a friend; `showNewMessageDialog` with the phone's `onOpen` / `onAddFriend`). New message is an icon, not a filled button, because the nav bar's centre + already carries the accent.
- **One `CustomScrollView`:** the first-run line, a search field (`Search conversations`, once there is any DM or server), `HomeAttention` and `HomeSetupChecklist` with `_MobileHomeActions` (touch layout; no update row, the stores update phones; add friend = `showMobileAddFriendSheet`, add server = `showCreateServerDialog`, profile = `openMobileProfileSettings`), the `HomeFilters` chips, then the list.
- **All:** Saved messages and parked joins pinned first, then DMs and servers ranked unread first, then newest, then by name (servers carry no time). **Unread:** the hot DMs and servers. **Mentions:** one `ConversationRow` per channel that mentioned us, which opens that channel. A server row carries its mention count (red, `@`) or else its unread count; mention rows are not repeated in All.
- **Names follow local nicknames:** the shared `home_inbox.dart` rows `ref.watch(localNicknameProvider)` (`displayNameFor` reads the nickname cache), so a rename shows at once here and on desktop Home.
- **Rows:** DMs, Saved messages and mentions are `ConversationRow(touch: true)` with 48 px leading, full-bleed, long press = the DM sheet. Servers are `_ServerRow` (`ServerAvatar(animate: expanded)`, members line, `HollowCountBadge`, chevron) expanding into the channel tree; the tree's rows use `HollowCountBadge` and a success `HollowBadge` for voice occupants. Geometry constants `_kAvatar` 48, `_kTreeIndent`, `_kTreeLeft`.
- **Active Now** (2026-09-24): above the chips, only while a voice room has people in it: a `HollowSectionHeader` + up to two `HomeVoiceRoomTile(touch: true, onOpen:)` (then "and N more rooms"), from `homeVoiceRooms(ref)`; Join goes through the tab's own `_openVoiceChannel` (leave-your-call toast, `confirmVoiceRoomSwitch` which asks only while you are in a room with others, chat + voice routes). News and Relay are NOT here: rendered at the end of the list and rejected by Vitalik ("takes so much space"); they close mobile Settings instead.
- `AmbientBackground` still wraps the tab (draws nothing unless the Ambient opt-in is on). The old teal "Hollow" wordmark and `_HeaderShimmerLine` are gone.

### Pending Join Row (pending joins rung 1, 2026-08-29)
**File:** `lib/src/ui/mobile/tabs/mobile_chats_tab.dart` (`_PendingJoinRow`), `lib/src/ui/components/pending_join_ui.dart` (`showPendingJoinSheet`, shared with desktop's menu)

A join into a server whose members were all offline PARKS instead of failing (Rust persists the request, answers it whenever a member returns, which can be days). Each entry in `pendingJoinsProvider` becomes a `_PendingJoinRow`, PINNED above the sorted conversation list: inserted at the top, deliberately outside the unread/recency sort, since a parked join has no name to sort by and no activity to rank, and burying one under a month of chats is how a user forgets they ever asked to join.

Row visual: greyed on purpose (`hollow.textTertiary` icon + text) — not a conversation, nothing to open. 48px icon box (`hollow.elevated`) with `LucideIcons.clock` (pending) or `LucideIcons.ban` (rejected), title (`pendingJoinTitle`) + subtitle (`pendingJoinSubtitle`, the reason text when rejected). No spinner — the wait is for another person to open their app.

Tap AND long-press both open `showPendingJoinSheet()`, the mobile bottom-sheet idiom, built from the SAME action helpers as desktop's `showPendingJoinMenu` (`pending_join_ui.dart`): "Request again" (rejected only), "Copy invite link", "Discard request"/"Remove". A tile that did nothing on tap would read as broken, same reasoning as the desktop tile's click-and-right-click.

### Channel Tree Connectors
**File:** `lib/src/ui/mobile/tabs/mobile_chats_tab.dart` (`_TreeChannelRow`)
Expanded server channel list shows tree-style connectors (├── / └──). `_TreeChannelRow` wraps `_ChannelRow` in a `Stack` with vertical + horizontal `ColoredBox` lines. Vertical line aligned under server avatar center (`HollowSpacing.lg + 22`). Last channel uses `└──` (line stops at branch), others use `├──` (line continues). Line color: `hollow.textSecondary` at 0.7 alpha.

### Channel Long-Press Context Sheet
**File:** `lib/src/ui/mobile/mobile_channel_actions.dart`
Long-press on a channel row in the expanded accordion opens `showMobileChannelActions()` (rows = touch `HollowListRow`s with grey icons, the desktop channel menu's labels):
- `HollowSheetTitle(channel.name)`
- Text channels: Mark as read, Mute channel / Unmute channel (a voice channel has neither)
- If `canManage` (Permission.manageChannels): Rename channel (`renameChannelFlow`, the desktop prompt), Visibility and Who can post (text channels only) as drill-in views with the current setting as a trailing hint, Temporary access (not on a public channel; `showChannelGrantsDialog`), a divider, Delete channel (`confirmDeleteChannel`, the desktop confirm; no inline confirm view any more)
- Visibility / Who can post views: a back row, then Everyone / Moderator and above / Admin and above (`accessTierLabel`) and "Require access labels" or "Edit access labels (N)" (`showAccessLabelPicker(gate:, target:)`). A plain tier on a label-gated channel asks `confirmClearLabelGate`, the same wording as desktop.
- `AnimatedSize` switching between actions, visibility and posting; `onChanged` refreshes the accordion

### Layout-Aware Channel List
**File:** `lib/src/ui/mobile/tabs/mobile_chats_tab.dart` (`_ChannelList`)
Channel accordion now respects layout ordering + categories:
- Fetches both `ChannelListNotifier.fetchChannels()` AND `ChannelLayoutNotifier.fetchLayout()` via `Future.wait`
- Builds `effectiveLayoutFrom(parseLayoutJson(layoutJson), channels)` into a `_DisplayItem` sealed class hierarchy: `_CategoryDisplayItem`, `_ChannelDisplayItem`, `_SeparatorDisplayItem`
- Categories render as collapsible `_CategoryHeaderRow` (name as the user typed it, no uppercase; chevron toggle, `AnimatedRotation`)
- Separators render as `_TreeSeparatorRow` (12px gap with vertical tree line)
- **Channels missing from the layout come out of the normalisation, NOT a second loop.** Appending them separately (as this did until issue #61) leaves them outside the pass that tracks `currentCategory`, so a channel drawn under a trailing category carries `category: null` and stays on screen when that category is collapsed. `test/sidebar_effective_layout_guard_test.dart` guards this list and the desktop sidebar together. `channels` is pre-filtered by `meCanSee`, so normalisation also drops layout entries for channels this user cannot see.
- "+" `_CreateChannelRow` at bottom when `canManage` (calls `showCreateChannelDialog` with `onCreated: _loadChannels`)
- Listens to `serverListProvider.select((s) => s[widget.serverId])` for per-server change detection
- **CRITICAL — rows are keyed by item identity** (`ValueKey('srv-${id}')` / `ValueKey('dm-${id}')` in the conversation ListView) and `_ChannelList` reloads in `didUpdateWidget` when `serverId` changes. The list mixes DMs and servers and reorders constantly; without keys Flutter re-parented row State across DIFFERENT conversations — a newly joined server displayed ANOTHER server's channel structure while every logged ID looked correct. Any row widget holding per-item loaded state needs both protections.

### Server Long-Press Context Sheet
**File:** `lib/src/ui/mobile/tabs/mobile_chats_tab.dart` (`_showServerSheet`)
Long-press on a server row opens `showHollowSheet` with the desktop strip menu's rows, minus folders (a phone has none): `HollowSheetTitle(serverName)`, Mark as read, Mute server / Unmute server, Invite people (`showInviteDialog` with `webServerInviteLink(serverId, relay:)`), Create channel (Permission.manageChannels), Server settings (pushes `MobileServerSettingsRoute`), Copy server ID, a divider, then Delete server for the owner or Leave server for everyone else, through the shared `confirmDeleteServer` / `confirmLeaveServer` (wiki `ui_server_settings`). Rows are `_sheetRow` (touch `HollowListRow`, the sheet closes first); failures toast through `_report`.

### Channel editing in Server settings
The phone's server settings are the desktop pages under `SettingsDensity(touch: true)` (wiki `ui_server_settings`); the old `_ChannelLayoutEditor` is gone.

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
- `_staged` (`List<StagedAttachment>`) — staged attachments, up to 10; two or more send as one album
- `_dmAlbums` / `_channelAlbums`: album grouping of the list last displayed (`collapseDmAlbums` / `collapseChannelAlbums`), read by the row builders
- `_isRecordingVoice` — swaps input bar for VoiceRecorderBar
- `_searchOpen` / `_searchController` / `_searchFocusNode` / `_searchResults` — channel search
- `_highlightIndex` — search result highlight (auto-clears after 1.5s)
- `_channelKey` — getter for `'$serverId:$channelId'` (channelChatProvider map key)

### Provider Management (Critical)
On entry: `_openDmChat` sets `selectedPeerProvider`, clears `selectedServerProvider`. `_openChannelChat` sets both `selectedServerProvider` and `selectedChannelProvider`.
On exit: Providers are cleared in `Navigator.push().then()` in `mobile_chats_tab.dart` — AFTER the route fully pops. `MobileChatRoute.dispose()` does NOT touch selection providers. This ensures `isViewingChannel` guard works during viewing but unreads accumulate after returning to Chats tab.
Unread clearing: `_markSeen()` called after history loads in `initState` `.then()` callback (with real message IDs). Never calls `markChannelSeen`/`markDmSeen` with null.

### Decomposed structure (2026-07-15 Sonar item-3, chat-pane shape)
`build()` is a slim skeleton; sections are private builders on the State: `_buildHeader` (→ `_MobileChatHeader`, itself decomposed into `_leadingAvatar`/`_titleBlock`/`_trailingActions`/`_pinnedButton`), `_buildSearchBar`, `_buildSyncIndicator`, `_buildNoReadPermission` / `_buildMessageArea` (→ `_buildDmMessages`/`_buildChannelMessages` → shared `_buildMessageListShell` → `_buildDmRow`/`_buildChannelRow`) + `_buildUnreadPillOverlay`, `_buildSlowModePill`, `_buildComposerOrBanner` (→ `_buildBlockedBanner` / `_buildInputArea`), `_wrapWithBackground`. `_registerBuildListeners()` (called from build) holds the `visibleChannelsProvider` eviction listener (`_onVisibleChannelsChanged`); the message-growth listeners (`_onDmMessagesChanged`/`_onChannelMessagesChanged`) stay registered inside the list builders so they don't register while the read-permission gate replaces the list. Action-sheet callbacks are nullable factories (`_replyActionFor`/`_editActionFor`/`_copyActionFor`/`_downloadActionFor`/`_pinActionFor` — gate order preserved) with proof dialogs in `_showDmProof`/`_showChannelProof`; reactions via `_toggleDmReaction`/`_toggleChannelReaction` (shared by bubble + sheet). `_sendFileMessage` is the one optimistic-insert+`fileTransferProvider.sendFile` pipeline for staged files AND voice notes. It ADOPTS `chat_pane_shared.dart` — see wiki ui_chat_pane_shared.

### Widget Tree
```
Scaffold
├── SafeArea (inside EmoteScope)
│   └── Column
│       ├── _MobileChatHeader (back, name, status, users icon, pins, search icon, mute bell)
│       ├── MobileMinimisedCall(floating: false) (the call or room you are in, docked)
│       ├── _buildSearchBar (channel only, when _searchOpen)
│       ├── _buildSyncIndicator (channel only)
│       ├── Expanded → Stack   (or _buildNoReadPermission when read gate denies)
│       │   ├── reversedChatList (shared shell, selectionArea: false)
│       │   │   └── LongPressMessage → MessageBubble / ChannelMessageBubble (isHighlighted for search)
│       │   └── _buildUnreadPillOverlay → shared UnreadJumpFade
│       ├── SystemStatusBanner (bottom anchor)
│       └── _TypingBar → typingMastersFor + shared TypingIndicatorHost, floating the label over this cluster:
│           ├── _buildMentionPanel / _buildEmotePanel (autocomplete)
│           ├── ChatReplyPreviewBar (if replying, shared)
│           ├── StagedLinkArea (shared; hollow-link or OG preview)
│           ├── StagedAttachmentStrip (if files staged, shared; reorderable for an album)
│           ├── _buildSlowModePill (channel, cooldown active)
│           ├── _buildComposerOrBanner: blocked banner (no-post/muted) OR VoiceRecorderBar OR the shared `ChatComposerRow` ([+] attach sheet (Photo or video, File) + text with the expression button inside + mic that becomes Send; no autofocus; `expressionsOpen` swaps the smiley for a keyboard icon, "Show keyboard")
│           └── MobileKeyboardPanelDock (the keyboard's inset, or the expression panel in its place)
```

### Message Rendering
Uses the shared `reversedChatList()` shell: `reverse: true`, newest at builder index 0 bottom-pinned, `findChildIndexCallback` keyed-row reuse, `_frozenLen` display freeze while scrolled up (see chat_pane scroll model). The displayed list folds every album into its earliest item; `indexById` also maps each album item to its anchor row (replies, jumps, unread marker), and the anchor's bubble gets `album: dmAlbumItems(...)` / `channelAlbumItems(...)` with a preview from `albumPreviewText`.

**Grouping:** shared `shouldGroup()` (same sender within 5 min; channel rows compare device→master collapsed sender ids). Date separators via shared `dateSeparatedChatRow`/`DateSeparator` ("Today"/"Yesterday"/"February 16, 2026" — desktop format since 2026-07-15).

**Reply context:** For each message with `replyToMid`, O(1) lookup via the per-build `indexById` map; passes `replyToSenderName` + `replyToText` (`_attachmentPreviewText`, a thin wrapper over `messagePreviewText()` from `lib/src/core/message_preview.dart`: covers file, emote AND asset tokens, not file tokens alone, and never emits an emoji glyph) to the bubble.

**Edit mode:** When `_editingMessageId` matches a message, `_editRow()` renders `_buildEditView()` instead of the bubble — an inline `TextField` with accent border + Save/Cancel buttons.

### _LongPressMessage Widget
Wraps each message bubble. Provides:
- `HitTestBehavior.opaque` — full-width tap target (not just painted content)
- Teal highlight animation during long-press hold (`AnimatedContainer` with `hollow.accent.withValues(alpha: 0.08)`)
- Triggers `showMobileMessageActions()` on long-press complete

### File Actions
- `_saveFile(FileAttachment)` — reads bytes, passes to `FilePicker.platform.saveFile(bytes:)`. Android requires `bytes:` param (crashes without it). Converts WebP→PNG if needed via `network_api.convertImageFormat()`.
- `_requestFileFromPeer(FileAttachment, senderId)` — requests file via P2P when not on disk.
- `_handleSend()` — slow-mode + media-only gates (`_blockedBySlowMode`/`_passesMediaOnlyGate`), clears composer state (`_clearComposerState`), then `_sendFiles(staged, caption: text, ...)` if files are staged (shared `sendStagedAttachments`: every optimistic insert first, then sequential `fileTransferProvider.sendFile(album:)`, caption on item 0) else the text `sendMessage`. An album row's action sheet drops the single-file actions and its delete asks `confirmDeleteAlbum` then deletes every item (`_deleteActionFor`).
- `_pickFile({bool imagesOnly = false})` — `FilePicker.platform.pickFiles(allowMultiple: true)` (media-only channels restrict extensions), STAGES the files above the input bar through `admitStagedAttachments` + `appendStaged` (media-only filter, 10-item cap, one large-file Share question for the batch; caption-friendly, desktop parity). One [+] attach button opens `_showAttachSheet` (Photo / File rows).

### Pin Messages (Channel Only)
- `pinnedProvider` loaded after channel history loads in `initState` `.then()` callback
- `_MobileChatHeader` title: DM → friend display name + Online/Offline subtitle; channel → `# channelName` + the **server name** as a subtitle (read from `serverListProvider.select((m) => m[serverId]?.name)`, ellipsis-truncated) so the user knows which server the channel belongs to
- `_MobileChatHeader` shows pin icon with count badge when `pinnedProvider[key]` is non-empty (between members icon and search icon)
- Tapping pin icon opens `_showPinnedMessagesSheet()`, which calls the shared `showPinnedMessages(touch: true)` (wiki `ui_chat_channel`, "Pinned Messages"): a sheet with `HollowSheetTitle('Pinned messages')`, rows that jump to the message, Unpin always visible for whoever may pin, and the sheet closes when the last pin goes
- `_showChannelActions()` wires `onPin` callback — permission-gated (`Permission.manageChannels`), toggles `crdt_api.pinMessage()`/`unpinMessage()`
- `isPinned` param passed to bottom sheet for the "Pin message" / "Unpin message" label

### Action Callbacks Wired
Both DM and channel builders wire:
- `onToggleReaction` on bubbles → reaction pills are tappable
- Long-press → `_showDmActions()` / `_showChannelActions()` → bottom sheet
- `onDownload` — shows when message has file attachment. Saves locally or requests from peer. Guards duplicate downloads via `fileTransferProvider`.

### Channel Permission Gates
- **Read gate:** If `myPermissionsProvider` `readMessages` bit is 0, replaces message list with eyeOff icon + "no permission" text. DMs unaffected.
- **Post gate:** If `canPostInChannelProvider` returns false, replaces input bar with "no permission to send" notice. Checks bitmask AND channel posting mode.
- **Sync indicator:** Below header for channel chats. Uses `serverSyncStatusProvider`. Shows spinner + "Syncing..."/"Retrying..." (warning color) / "Sync failed" with tappable "Retry" link. Hidden when idle/synced/connecting.

### Expression panel in the keyboard's place (2026-09-24)
The smiley inside the composer (`_toggleExpressions`) swaps the software keyboard for the shared `ExpressionPanel` (Emoji / GIFs / Stickers, from `expression_picker.dart`) at the same height, and the button becomes a keyboard icon ("Show keyboard") that swaps back. There is no sheet any more (`showExpressionSheet` is deleted).

- `_expressionsOpen` flag. Opening unfocuses the composer; closing requests focus, and the focus listener `_onComposerFocus` drops the panel once the keyboard is on its way (so a tap on the field also brings the keyboard back).
- The panel is `MobileKeyboardPanelDock(open, keyboardFocus: _focusNode, panelBuilder: _buildExpressionPanel)` (`lib/src/ui/mobile/mobile_keyboard_panel.dart`), the last child under the composer. The route's `Scaffold` sets `resizeToAvoidBottomInset: false` and its `SafeArea` `bottom: false`: the dock itself makes room for the keyboard, so the composer never moves while keyboard and panel swap.
- Dock sizing: remembers the last keyboard height seen this run (`_lastKeyboardHeight`; 40% of the screen before any keyboard). Open = max(stored, inset). When the panel's own search field raises the keyboard, the panel sits above it at most 45% of the remaining space. A panel closing while the composer has focus stays up until the rising keyboard covers it (a 700 ms timeout covers hardware keyboards that never raise one). The panel is on the composer's `surface` with a top hairline, no scrim, and pads for the home indicator.
- An emoji goes into the text and the panel stays open for the next one (`refocus: false`); a GIF or sticker sends (issue #36); sharing a pack closes the panel first. Editing, search and voice recording close it.
- Back (`PopScope(canPop: !_expressionsOpen)`) closes the panel before it leaves the chat, and a tap on the message area closes it (an always-present translucent `GestureDetector`, so opening the panel never remounts the list).
- Pinned by `test/widget/mobile_keyboard_panel_test.dart`.

---

## MobileServerSettingsRoute

**File:** `lib/src/ui/mobile/mobile_server_settings_route.dart`
**Purpose:** a server's settings on a phone: a list of pages (grey icons, values) that pushes the SAME page widgets the desktop rail shows, at touch density. Pushed from the server long-press sheet. Detail in `ui_server_settings.md` ("Phone"). The old phone-only members, roles, labels, emotes and Twitch routes were folded into the shared pages and deleted (2026-09-24).

---

## MobileSettingsTab

**File:** `lib/src/ui/mobile/tabs/mobile_settings_tab.dart`
Since the Settings rebuild (2026-09-24) the tab is a ROOT LIST whose rows push the SHARED desktop page widgets under `SettingsDensity(touch: true)` (`MobileSettingsSubPage`); the old phone-only `_ProfileTab` / `_SystemTab` / `_AppearanceTab` / `_AccessibilityTab` / `_AudioTab` / `_FilesTab` / `_DevicesTab` / `_BackupTab` / `_AboutTab` bodies and their private rows are gone. Pages, groups and rows: wiki `ui_user_settings`. The list ends with `HomeStatusCard`, `HomeNewsCard` and `HomeRelayCard(loadBars: mobileTab == 3)` (the bars and their 7 s poll run only while Settings is the visible tab).

### Security Tab (App Lock: PIN / password / biometric)
- **App lock** (the shared `SecurityAppLockSection` in `settings/security_section.dart`, phone branch): Enable → `_chooseLockType()` sheet ("Choose a lock": touch `HollowListRow`s PIN "4 to 8 digits, quick to type" / Password "Anything you like, stronger" / a third, inert row naming the biometric, "Available once a PIN or password is set": a biometric is a layer on top of a PIN/password, not its own lock type) → `askSecretDialog(ask: SecretAsk.create, isPin:)`, whose `onSubmit` runs `identity_api.enablePasswordProtection` (PIN = numeric secret through the SAME Rust Argon2id flow) + `AppLockService` bookkeeping INSIDE the dialog: the confirm loads through the seconds of Argon2id, a wrong current secret lands on its field, nothing typed is lost. Change and "Turn off the app lock" (confirm "Turn off", a filled button, not red: it deletes no data) use the same dialog with `SecretAsk.change` / `.current`.
- **Biometric row** (mobile + lock enabled + `canUseBiometrics()`): Switch (`activeThumbColor`). ON → needs the secret (`sessionSecret` or re-ask) → one live `promptBiometric()` check → `enableBiometric(secret)` stores it in flutter_secure_storage. See `lib/src/core/services/app_lock_service.dart`. (`canUseBiometrics()` requires `getAvailableBiometrics().isNotEmpty` — some Pixels report Face Unlock as class-2/weak and return empty even with enrolled biometrics; relax that check if the Switch never appears.)
- Device Protection: enable/disable OS keychain (Windows/macOS only)
- Recovery Phrase button (loads from identity or storage API)
- **Check a message proof**: the shared `VerifyProofSection` (Security, Advanced) on both platforms.
- **Backup file** (`BackupFileRow`, `settings/backup_section.dart`): "Export a backup" dialog with its options inside ("Include downloaded files", "Include files you keep for your servers"). Rust `exportBackup` writes to a path it owns, so a phone exports to a temp file under `hollowDataDir`, reads the bytes, hands them to `FilePicker.saveFile(bytes:)` (required on Android/iOS), then deletes the temp file. IMPORT is NOT here: it lives in the first-launch welcome dialog (`welcome_dialog.dart`), since `importBackup` overwrites the data dir and must run before the node starts; that picker uses `FileType.any` on mobile (`.hollow` isn't a recognized iOS/Android UTI, so `FileType.custom` hides it).
- Unlock-at-launch flow lives in `hollow_shell.dart _showPasswordUnlockDialog`: biometric prompt FIRST, then `UnlockDialog` (`shell/identity_unlock_dialogs.dart`: PIN or password, a biometric retry, "Forgot PIN?" / "Forgot password?"; a wrong secret reopens it with the error ON THE FIELD, never a toast, since the lock cover silences toasts) and `RecoveryPhraseDialog` (24 words checked by count, recovery runs inside the dialog, the phrase kept on failure).
- **Unlocking… spinner** (`_UnlockingOverlay`, flag-driven `Stack` over the shell — NOT a dialog, so nothing races it dismissed): the post-unlock Argon2id derivation (~1.5-3s) + the local DB load can't begin until unlock finishes (the SQLCipher passphrase is derived from the just-unlocked identity — local-first render can't help). `_unlocking` is set the instant a secret is in hand (both `tryBiometric` and the password-entry path) and cleared after `profileProvider`/`friendsProvider` load in `_bootstrap` (conversation list renderable). Only shows when an App Lock is active; wrong-secret + identity-error paths clear it. See `feedback_app_lock_unlock_ux` memory.

### About Tab
See "Audio, ringtone and About on the phone" below.

---

## MobileFriendsTab (Enhanced)

**File:** `lib/src/ui/mobile/tabs/mobile_friends_tab.dart`
**Purpose:** Friend list with search, favourites, and long-press actions.

### Search
`HollowTextField` with search icon at top. Filters accepted friends by name (case-insensitive substring via `_resolvedName`).

### Sections (in order)
Each section is headed by `_sectionHeaderSliver(title, count)`, a `SliverToBoxAdapter` around `HollowSectionHeader(title, count:, dense: true)`. Requests hide while searching.

1. **Received**: incoming requests, Decline + Accept (`_PendingRow`)
2. **Sent**: outgoing requests, Cancel request
3. **Favourites**: starred friends in `favouriteFriendsProvider` order
4. **All friends**: everyone else. Empty: "No friends yet" / "No friends match".

### Add friend (`showMobileAddFriendSheet`, `_AddFriendSheet`)
A sheet, not a dialog: "Add friend", "User ID or nickname" (`kAddFriendHint`, mono) with `kAddFriendNote` under it, a full-width filled "Send request" directly below, then `HowOthersAddYou` (the temporary-nickname claim). Opened from the tab's "Add friend" button and the Chats tab's add-friend action.

### Long-Press Actions (bottom sheet with `SafeArea`)
The desktop person menu's labels, as touch `HollowListRow`s under `HollowSheetTitle(name)`: Message, Start a call (online, no call up; `startMobileDmCall`), Profile (`showMobileProfileSheet`), Add to favourites / Remove favourite, Move up / Move down (favourites only, the keyboard-free reorder), Set nickname / Edit nickname (`showLocalNicknameDialog`, THE nickname dialog), a divider, Remove friend (`confirmRemoveFriend`, THE remove confirm, run inside the dialog).

---

## Bottom Sheet Motion

`showHollowSheet` passes `sheetAnimationStyle: _sheetMotion()`, read per open so Reduce motion reaches the next sheet: `AnimationStyle.noAnimation` when `HollowDurations.animationsDisabled`, else `HollowCurves.enter` both ways (a reverse curve runs backwards, so the enter curve is also the easing-in exit), `HollowDurations.normal` in and `fast` out. A drag still tracks the finger (the route rebinds to the raw controller while dragging). A sheet travels its full height: it is attached to an edge and dismissed by a gesture (design language 3.8).

## Bottom Sheet SafeArea Pattern

**CRITICAL:** All `showHollowSheet` builders must wrap content in `SafeArea(child: ...)` for Android 3-button navigation bar compatibility. The canonical pattern is `mobile_chats_tab.dart:_showServerSheet`.

**`HollowSheetTitle(title, {subtitle})`** (`components/hollow_sheet.dart`, 2026-09-25): the name at the top of every phone action sheet (the person, server, channel or message the rows act on), start-aligned `subheading`, one line, full width so it starts on the rows' leading edge even in a centring column. Rows under it are touch `HollowListRow`s with grey 20 px icons; destructive rows carry no red, the confirm they open does. Used by the DM, server, channel, friend, pinned-messages, pending-join and archive-filter sheets. For `DraggableScrollableSheet`, use `viewPadding.bottom + HollowSpacing.xl` in ListView padding instead.

---

## Mobile Message Actions

**File:** `lib/src/ui/mobile/mobile_message_actions.dart`
**Function:** `showMobileMessageActions()` — `showHollowSheet(scrollControlled: true)` with contextual actions.

### Bottom Sheet Layout
```
Column (mainAxisSize: min)
├── _MessagePreview (sender name + truncated text + timestamp)
├── _QuickReactionsRow (kQuickReactionEmojis + "More reactions")
└── Groups split by HollowDivider, the desktop message menu's order (_ActionRow = touch HollowListRow, grey icon)
    ├── Reply
    ├── Copy text, the file row (Save file / Try again / Stop waiting via fileBarAction), Pin message / Unpin message, Edit message
    ├── Message proof
    └── Delete message (own messages; runs at once, no confirm)
```

### Two Views (AnimatedSize transitions)
1. **actions**: default view with action rows
2. **allEmojis**: back row + "Add a reaction" over `EmojiPickerBody` (half the screen height). Back returns to actions.

**A single message's delete never asks** (Vitalik, 2026-09-25, as on desktop): the old inline `deleteConfirm` view is gone. An album row still asks once, in the caller (`confirmDeleteAlbum`).

### Parameters
All action callbacks are nullable — only shown when non-null:
- `onReply`, `onEdit`, `onDelete`, `onCopy`, `onDownload`, `onPin` — `VoidCallback?`
- `onReaction` — `void Function(String emoji)?`
- `onInfo` — `VoidCallback?`
- `isPinned`: `bool` (toggles "Pin message" / "Unpin message")

Note: `onCopyImage` was removed — `super_clipboard` image operations don't work on Android. "Save File" covers the use case.

### Emoji Source
The quick row reads `kQuickReactionEmojis`; "More reactions" embeds `EmojiPickerBody` (`chat/emoji_picker.dart`, with the server's emotes via `serverId`) in the sheet. It does NOT use the desktop's `showEmojiPicker()` overlay, to avoid a raw `OverlayEntry`.

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

## Phone call screens (rebuilt 2026-09-25, session 23)

`MobileCallScreen` (DM, `mobile_call_video_view.dart`), `MobileVoiceChannelRoute` (voice room and meeting), `MobileMinimisedCall`, `MobileIncomingCallOverlay`, `MobileShareFullscreen` and the shared pieces in `mobile_call_chrome.dart`. Built on the desktop adapters (`DmCallStageSource`, `VcCallStageSource`). Full description in wiki `ui_call_surfaces`, section "Phone". Deleted: `mobile_active_call_pill.dart`, `mobile_voice_channel_pill.dart`, `mobile_source_switch_pill.dart`, `mobile_voice_avatars.dart` (`MobileClusteredAvatars`, `MobileSpeakingAvatar`, `MobileControlButton`), `components/speaking_border.dart`, `MobileCallStatusStrip`, `_VoiceChannelStatusStrip`.

### Navigation pattern (unchanged)
A voice channel tap in the Chats tab pushes TWO routes: `MobileChatRoute` (the channel's text chat) underneath, `MobileVoiceChannelRoute` on top (slide up). "Open the chat" on the call screen pops back to that chat, or opens it when the call was reached from elsewhere (`openMobileCallChat`).

---

## Audio, ringtone and About on the phone

The Audio & Video and About pages are the shared `settings/audio_section.dart` and `settings/about_section.dart` at touch density (wiki `ui_user_settings`); the phone-only `_MicGainSlider`, `_VoiceEnhanceToggle`, `_InfoRow`, `_MobileBrandIcon` and friends are gone. Provider semantics (mic gain, Voice Enhancement, ringtone keys): wiki `providers_event_settings`. The ringtone row's Trim opens `showRingtoneClipEditor()`, whose waveform is REAL since 2026-09-25: `loadRingtoneWaveform` asks Rust `audio_waveform(path, buckets)` (`api/waveform.rs` over `audio_peaks.rs`, symphonia) for the decoded duration and per-bucket min/max + RMS, drawn by `RingtoneWaveformPainter`; a format symphonia lacks (Opus in Ogg) falls back to the player's duration with no waveform, so it still trims by time. Legal documents open in `_showLegalSheet` (`about_section.dart`).

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
**Purpose:** Full-screen server storage dashboard, pushed from the phone server settings list ("Storage on this phone").

### Data Loading
- `crdt_api.getStorageStats(serverId:)` → `StorageStatsFfi`
- `crdt_api.getServerSetting(serverId:, key: 'retention_files'/'retention_messages')`

### Sections
Each section box is titled `HollowSectionHeader(title, dense: true)`, no section icon.

1. **Server Storage**: vault mode label, member count. Full replication (<6): the server's data against THIS phone's free space (`freeBytesAt(hollowDataDir)`, `core/services/disk_space.dart`), "X used · Y free", and no bar at all until a free-space reading exists (the old bar sat at 0%). Erasure coding (6+) with redundancy factor.
2. **Your Storage** (6+ members): pledge amount with edit button, usage bar.
3. **Retention Policy**: messages + files retention display. Admin can tap to edit. Records `_since` timestamp for forward-only pruning.

Pledge and retention edits are the DESKTOP storage dashboard's own flows (`editStoragePledge`: a `promptForName` in MB with a validator, at least 512; `editRetentionPolicy`: `_RetentionPicker`), both writing inside their dialog; the phone only toasts "Pledge saved" / "Retention saved" and reloads. `StorageUsageBar` is shared too.
4. **Vault Health** — StatusDot + status text + shard count. Pulse animation on active transfers.
5. **Member Pledges** (6+ members) — member count + average pledge.

### Navigation
The "Storage on this phone" row of `MobileServerSettingsRoute`, visible to all members.

---

## MobileArchiveTab

**File:** `lib/src/ui/mobile/tabs/mobile_archive_tab.dart`
**Class:** `MobileArchiveTab extends ConsumerWidget`
**Purpose:** Full archive tab (bottom nav index 2). My Data + Imported Archives sub-tabs.

### Deferred Loading
Watches `mobileTabProvider` — returns `SizedBox.shrink()` when `activeTab != 2`. Prevents `archiveDmListProvider` from firing before the message store is open at startup.

### Top-Level Structure
- "Archive" heading + pill sub-tab row: "My Data" | "Imported" (uses `archiveSubTabProvider`)
- Switches between `_MobileMyDataView` and `_MobileImportedArchivesView` instantly

### _MobileMyDataView (ConsumerStatefulWidget)
- Inner pill tabs: DMs | Channels (uses `myDataInnerTabProvider`, no Vault Files — deferred to Section 25)
- Search field (uses `archiveSearchProvider`)
- **DM list:** Avatar + name + message count + eye icon (hide/unhide). Hidden section with expandable `AnimatedSize`. Tap → push `MobileArchiveViewerRoute(peerId:)`. Long-press → bottom sheet (Export, Hide/Unhide).
- **Channel list:** Grouped by server headers (`HollowSectionHeader(serverName, dense: true)`, name as written, export icon as the `action`). Each channel: # + name + count. Tap → push `MobileArchiveViewerRoute(serverId:, channelId:)`. Long-press → export bottom sheet.
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

### Header (ArchiveMobileToolbar, shared)
Back button, avatar (DM) or # icon (channel), title, subtitle "in serverName" (channel), icon buttons: filter (channels, >1 sender), calendar (jump-to-date), search toggle, export, "read-only" badge. From `lib/src/ui/archive/shared/archive_toolbar.dart`.

### Message List (shared core)
Renders `ArchiveDmMessageList` / `ArchiveChannelMessageList` from `lib/src/ui/archive/shared/archive_message_list.dart` (`desktopChrome: false`, ReduceMotionController-aware `scrollDuration`), with `LongPressMessage` action wrapper → `showMobileArchiveMessageActions()`. Loading spinner to content is an instant swap. See wiki `ui_archive` "Shared Viewer Core" for the full rendering stack.

### Search
`ArchiveListSearchBar` (shared) rendered OUTSIDE the list, above loading/empty states; drives scroll-to-match via `ArchiveMessageListController` (1.5s highlight).

### Sender Filter (Channel only)
`showArchiveFilterSheet()` (shared) — bottom sheet with searchable participant list. Sets `archiveFilterSenderProvider`.

### Jump-to-Date
`showDatePicker()` → `archiveJumpToDateProvider` → the shared core's `ref.listen` (in build) does the binary-search scroll.

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
Uses `importedArchiveDataProvider(path)`; spinner to content is an instant swap.

### Derivation + Rendering (shared)
All conversion/filtering/banner derivation happens in one `prepareImportedArchive(..., mobile: true)` call (`lib/src/ui/archive/shared/imported_archive_prep.dart`); the route renders `ArchiveVerificationBanner` (`dense: true`) → `ArchiveChannelSelector` (server archives; resets filter/search on switch, uses `importedArchiveSelectedChannelProvider`) → `ArchiveMobileToolbar` → the shared message lists, same as `MobileArchiveViewerRoute` but with exporter-relative DM proof contexts from prep.

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
None of its own: the rows render in place and the sheet's own slide (`showHollowSheet`) is the only motion.

## MobileInChatBanner (in-app notification)

**File:** `lib/src/ui/mobile/mobile_notification_banner.dart`
**Class:** `MobileInChatBanner extends ConsumerStatefulWidget`
**Purpose:** The ONLY mobile in-app notification banner. Shown WHILE the user is inside a chat, for messages arriving in OTHER conversations. (The old top-tabs `MobileNotificationBanner` was removed — outside a chat, mobile relies on OS notifications.)

### Mounting & behavior
- Mounted in `MobileChatRoute`'s return Stack with `currentPeerId`/`currentServerId`/`currentChannelId` (suppresses the conversation being read) and `topOffset = MediaQuery.paddingOf(context).top + 64` (clears the chat header).
- Watches `systemNotificationProvider`; iterates `cards.reversed` (newest first) and picks the newest FRESH card that isn't the current conversation.
- **Freshness window (10s, UX audit 2026-07-02):** only surfaces a card whose newest message is ≤10s old (`_freshnessWindow`, keyed on `messages.last.timestamp`). Cards can be created while NO banner is mounted (user on a main tab), so stale cards are PRUNED post-frame instead of replayed when a chat opens. Current-conversation cards are pruned too (not just hidden), and `dispose()` dismisses the card being shown (post-frame) so it doesn't replay in the next chat. `MobileChatRoute.initState` additionally dismisses the opened conversation's card via `dismissDm`/`dismissChannel` — POST-FRAME ONLY (synchronous provider write in initState throws "Tried to modify a provider while the widget tree was building").
- Slides down from top by its FULL height (it hangs from the edge and is swiped up, the one exception to the 8 px rule) + fade: `HollowDurations.normal` in, `fast` out, `HollowCurves.enter`, durations re-read at every run. Body wrapped in `Material(type: transparency)` (avoids the yellow debug double-underline on a Positioned-in-Stack `Text`).
- **Accumulation:** adopts the FRESH card when the same source grows (the cached `_currentCard` is an immutable snapshot — must re-point to it). Shows the last **3** messages (provider caps the stack at 5).
- **Countdown ring (`_CountdownRing`):** depleting `CircularProgressIndicator` + remaining seconds (5→1) in the banner's right space, driven by a 5s `AnimationController` that auto-dismisses on complete. Swipe-up or tap also dismiss; tap navigates to the source conversation.
- **Emote tokens:** message lines render via `Text.rich` + `emotePreviewSpans` inside an `EmoteScope(serverId, peerHint)` (see wiki `emotes` > Notification Previews) — never raw text.

### Mobile @mention autocomplete (channels)
`mobile_chat_route.dart`: `_updateMentionAutocomplete` (from `_onTextChanged`, channels only) scans back from the cursor for an `@` at word-start, builds candidates from `serverMembersProvider` + `@everyone` (`serverDisplayNameFor`/`serverNicknamesProvider`), and renders `_buildMentionPanel` ABOVE the input bar (a Column child after `_TypingBar`, NOT an OverlayEntry). `_acceptMention` replaces `@query` with `@DisplayName `. Cleared on send. Class `_MobileMentionCandidate`.

## DM Long-Press Context Menu

**File:** `lib/src/ui/mobile/tabs/mobile_chats_tab.dart` (`_showDmSheet`)
**Trigger:** `onLongPress` on a DM's `ConversationRow` in the Chats tab list.

### Actions (the desktop person menu's labels for a DM tile)
`HollowSheetTitle(name)`, then Mark as read (`markDmSeenLatest(master)`), Mute conversation / Unmute conversation (`notificationSettingsProvider.setDmEnabled`), Export conversation (`showExportArchiveDialog`, messageCount: 0), Hide from archive / Show in archive (`hiddenArchiveDmsProvider`), Copy user ID (the MASTER id). Rows are the tab's `_sheetRow` (same as the server sheet); failures toast through `_report`.

## Notification Levels (Server Settings)

The phone shows the desktop Notifications page (server level chips + `ChannelOverrideDropdown`) under `SettingsDensity(touch: true)`: wiki `ui_server_settings`. The old `_NotificationSection` is gone.

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

## Mobile Call Screens — Audio Routing, Badges, Proximity, Wakelock, Screen Share

Implemented 2026-06 across `mobile_call_video_view.dart` (1:1) and `mobile_voice_channel_route.dart` (VC).

### Control rows (session 23: one row, `MobileCallControlRow`)
Mute, Deafen, Speaker (phones), Camera, Share, [Flip while the camera is on, phones], then End (DM; Cancel while ringing out) or Leave (room). Round 56 px buttons with the word UNDER each (`caption`, `textSecondary`); a seventh shrinks the row to 48, a narrow phone shrinks it to fit. Tones: rest = `hover` fill, on = `textPrimary` fill, muted/deafened = error 18%, End/Leave = error fill. The visible word is short ("Camera"), the semantics label says the purpose ("Turn on camera", "Leave the call", "Leave the room", "Leave the meeting").

### Share-audio volume (2026-07-17)
While you watch a share, a "Share volume" scrim button sits bottom-left on the live share (`MobileLiveShare`), opening `showShareVolumeSheet`: the received-share-audio volume slider (0 to 200%, persisted `shareAudioVolumeProvider`; 100% = -6 dB calibration, 200% = source loudness) and "Quieter when people talk" (`shareAudioDuckProvider`). Values flow through the `ShareAudioLevel` bus (see providers_voice_files.md).

### Audio routing + device picker (mobile-gated)
Defaults: 1:1 voice → earpiece, 1:1 video → speaker, camera-on mid-call → auto-switch to speaker (BOTH DM `toggleVideo` and VC `toggleCamera` since 2026-07-20), VC join → speaker. Reset to earpiece in `_cleanup()` / `onLocalLeft()` so the next call never inherits a stale route. State: `CallState.isSpeakerOn` / `VoiceChannelState.isSpeakerOn` (= "hands-free", not "the phone's loudspeaker").

**IRON RULE — a connected headset ALWAYS beats the built-in loudspeaker (2026-08-15).** Every speaker decision goes through `AudioRoutes.preferLoudRoute()` (`core/services/audio_route.dart`), NEVER a bare `Helper.setSpeakerphoneOn(true)`: iOS's `overrideOutputAudioPort(.speaker)` OUTRANKS headphones and drags capture to the built-in mic with it, so the old speaker-on default left a headset user in silence (field bug). With a headset attached, "speaker on" degrades to `setSpeakerphoneOnButPreferBluetooth` (DefaultToSpeaker, no override — the loudspeaker still wins on unplug). Same guard exists natively in `AudioUtils setSpeakerphoneOn:` via `+hasExternalAudioRoute` (covers the plugin's own re-asserts) and on Android in `AudioSwitchManager.enableSpeakerphone` (audioswitch's `selectDevice` PINS the speaker, so a later hotplug never took over).

**Picker (`mobile_audio_route_sheet.dart` + `core/providers/audio_route_provider.dart`).** The speaker button is an audio-device button: plain toggle while only built-in routes exist, route sheet once a headset is attached (`hasExternalRoute`), long-press always opens the sheet; the icon shows the LIVE route (`audioRouteIcon` — `headset` for wired, so it doesn't collide with deafen's plain `headphones`). Routes are enumerated from `enumerateDevices()` — on iOS from `availableInputs` FIRST (an active override hides a headset from `currentRoute.outputs`, but its input port stays listed and carries the UID `setPreferredInput:` needs) plus a always-synthesized Speaker; on Android straight from audioswitch's device classes. Selecting on iOS clears the override THEN pins the input (output follows — iOS has no pick-an-output API); on Android it's `Helper.selectAudioOutput(kind)`. The active route is read from the platform (`hollowSelectedAudioOutput`, Hollow fork channel), never from our own last write, because the OS re-routes on its own; `onDeviceChange` drives the refresh. Tests: `test/audio_route_test.dart`.

**Route DURABILITY history:** below.

**Route DURABILITY (2026-07-20, device-confirmed):** iOS makes the route durable by baking it into libwebrtc's session template (`AudioUtils setSpeakerphoneOn:` sets `DefaultToSpeaker` + mode `videoChat`/`voiceChat` on `webRTCConfiguration` — audio-unit restarts then re-apply OUR route, not WebRTC's earpiece default) plus a native self-heal (`healSpeakerRouteIfClobbered`: any route change landing output on the RECEIVER while `_speakerOn` → re-assert; also fired from `startScreenAudioPlayer` so an incoming share can't drag audio to the earpiece). Since 2026-08-15 it heals the MIRROR case too — output pinned to the built-in speaker while a headset is attached = stale override, release it. Dart re-assert points: VC join re-asserts after `startAudio` + at +1200ms (the early set runs before the service exists); DM `toggleVideo` / VC `toggleCamera` re-assert at +1200ms after ANY camera flip. Full story: memory `feedback_mobile_call_audio_route`.

### Mute/deafen marks
Session 23: the phone uses the desktop's marks, the red mic-off beside the name (`MobileCallFace`, `CallPersonTile`). Data: VC = `peerAudioStates`; 1:1 = `CallState.isMuted/isDeafened/remoteMuted/remoteDeafened` (synced via the `audio_state` call signal, see providers_voice_files.md).

### Proximity + wakelock
**Proximity is GLOBAL (since 2026-06-21), not per-screen.** `CallProximityController` (`lib/src/ui/mobile/call_proximity_controller.dart`) — a pure side-effect `ConsumerWidget` mounted in `app.dart`'s mobile `Stack` (next to `MobileIncomingCallOverlay`, always alive) — watches BOTH `callProvider` and `voiceChannelProvider` and engages `proximity_sensor` screen-off whenever EITHER is in earpiece mode (active call/VC, no local/remote video; `_vcHasVideo` mirrors the VC route's `_hasVideo`). **Earpiece is decided by the ACTUAL route** (`audioRouteProvider.activeKind == earpiece`) since 2026-08-15, falling back to `!isSpeakerOn` only when the platform can't name it — headphones in a voice call leave that flag false while audio is nowhere near the ear, and the screen blanked at every passing object. This blanks the screen on ear-hold from ANY screen, not just the call sheet (the old per-screen `_syncProximity` only ran while that widget was built). Android needs WAKE_LOCK (present); iOS blanks natively while the events stream is subscribed. **Wakelock stays screen-scoped:** `_syncWakelock` in each call screen uses `wakelock_plus` (^1.5.2 — 1.6+ conflicts with file_picker via win32) to keep the screen on while video/screen share is displayed; disabled in dispose.

### Shares on the phone (session 23)
Opt-in (#38) on both screens: an offer is `MobileShareOffer` (a card in a room, "Sharing their screen" + Watch under the name in a DM, also over the video in a DM with a camera on, which used to hide it). Watching puts `MobileLiveShare` (`ShareTile` large: name, quality, Stop watching) on top with the people as a row of faces; tap it or Full screen for `MobileShareFullscreen` (landscape via `FullscreenMediaChrome` + `toggleForcedLandscape`, pinch zoom through `ZoomSurface`, which is `media_zoom_view.dart`'s re-anchoring viewer extracted; a tap toggles the controls, they fade after 2 s, Reduce motion keeps them). Your own share is never previewed (the phone would film itself): `MobileOwnShare` says who is watching and offers Stop sharing. The source-switch pill is gone. Starting a share on a phone opens `showMobileScreenShareSheet` (`mobile_screen_share_sheet.dart`): "Share your screen", a "Share audio" switch that starts OFF (Vitalik 2026-09-25, desktop's picker too) with the platform note under it (Android 10+ for audio; apps that block capture stay silent), Cancel + Share.

### PiP
In a DM with both cameras on, yours is a 90x120 `CallPersonTile(strip)` in a corner you drag, clamped inside the video area.

### Drag-to-minimize (2026-07)
Both call screens are wrapped in `MobileSheetDragToMinimize` (`mobile_sheet_drag.dart`): swipe down anywhere pulls the sheet with the finger (chat visible behind), release past 30% or a downward fling pops the route (the minimised call remains), otherwise it springs back. Mechanism = Cupertino back-swipe vertically: `onVerticalDrag*` drives the enclosing route's `TransitionRoute.controller` (`// ignore: invalid_use_of_protected_member` — no public API), guarded on `route.isCurrent && animation.isCompleted`, with `navigator.didStart/StopUserGesture`. Zero paint cost at rest (routes stay opaque); the labelled "Minimise the call" chevron remains the accessible path. Descendant gestures (InteractiveViewer pinch, PiP pan, buttons) win the arena where present.

### Speaking state + duration (2026-07 perf)
VAD speaking flags live in `speaking_provider.dart` (`callSpeakingProvider` record, `vcSpeakingProvider` Set) — NOT in CallState/VoiceChannelState (a flip used to rebuild both whole call Scaffolds 1-4x/sec). The avatar clusters are wrapped in scoped `Consumer`s watching those providers. Call/VC duration renders via `CallDurationText` (`ui/components/call_duration_text.dart`), a self-ticking leaf Text — the old per-second `setState` rebuilt the entire screen (and kept ticking while backgrounded). `_statusText`'s active branch returns '' (the duration widget takes over).

### Settings-tab relay stats gate (2026-07)
`relayStatsProvider` is autoDispose + lifecycle-gated; `_MobileOnlineCounter` and `_AboutTab` watch it ONLY while `mobileTabProvider == 3` (all four tabs stay mounted, so an ungated watch would poll from launch). Leaving the tab drops the last listener → poll timer disposes; re-entering re-creates it (immediate fetch).

## Mobile UX Hardening (2026-06)

One-pass fixes from the production-readiness audit:

- **Keyboard-aware dialogs (global):** `showHollowDialog` wraps every pageBuilder in `AnimatedPadding(MediaQuery.viewInsetsOf)` + `MediaQuery.removeViewInsets` (mirrors Flutter's Dialog). NEVER add viewInsets padding inside a dialog builder — double-pad. `HollowDialog` itself: full-width-minus-padding under 600px, content in `Flexible > SingleChildScrollView`, actions in `Wrap`.
- **Add friend** is a bottom sheet (`_AddFriendSheet` in mobile_friends_tab.dart): input + full-width "Send request" directly below, the temporary-nickname claim (`HowOthersAddYou`) under it. `isScrollControlled` + manual viewInsets bottom padding + SafeArea.
- **Send jump fix (mobile_chat_route.dart):** sending uses post-frame `_jumpToBottom()` (instant), never animated scrollTo — the animated path raced the chatProvider listener auto-scroll + the input bar collapsing after `clear()` (the iOS "jump for a second"). `_scrollToBottom` (incoming messages) is post-frame-safe with mounted/isAttached guards.
- **In-channel search:** results box sizes to `(visible height - keyboard) * 0.35` clamped 120–360 (was fixed 200px).
- **Inline edit:** `_startEditing` scrolls the editor to alignment 0.15 after a 300ms delay (post keyboard animation) so it's never hidden behind the keyboard.
- **Message actions sheet:** `isScrollControlled` + 85%-height cap + internal `SingleChildScrollView` (emoji grid clipped on short phones).
- **Toast position:** `HollowToast` bottom = 32 + keyboard inset + (width<600 ? 56 + viewPadding.bottom : 0) — floats above the nav bar and keyboard.
- **Minimised call:** no longer draggable (session 23): it spans the width 12 px in from each side above the nav bar, and its body opens the call.
- **Image crop:** portrait orientation lock while open (rotation reset the crop), decode capped at `targetWidth: 2048, allowUpscaling: false` (raw RGBA OOM guard).
- **Welcome dialog:** compact-aware minWidth + internal scroll.
- **iOS:** `audio` added to UIBackgroundModes (calls survive backgrounding).

### Accessibility — Reduce Motion + Larger Text (2026-06-25)

- **ALL mobile page pushes go through `hollowMobileRoute()`** (`lib/src/ui/mobile/mobile_page_route.dart`), NOT raw `MaterialPageRoute`/`PageRouteBuilder`. (Docs elsewhere in this file that still say "pushed as `PageRouteBuilder`" / `MaterialPageRoute(...)` are describing the pre-2026-06-25 code — the transition mechanism is now `hollowMobileRoute()` everywhere; the destination widgets are unchanged.) `hollowMobileRoute({builder, transition: slideRight|slideUp|fade, duration (default HollowDurations.normal), settings})` builds its own `_HollowPageRoute` and gates the transition duration on `ReduceMotionController.instance.isReduced` (`Duration.zero` when reduced). See "Pushed pages: iOS swipe back" below. **Why it matters:** a raw `MaterialPageRoute`'s transition is governed ONLY by Flutter's built-in `MediaQuery.disableAnimations` (OS reduce-motion flag) — the in-app tri-state control couldn't stop it (On) nor force it back on (Off, when OS was on). Routing through `hollowMobileRoute()` makes `ReduceMotionController` the single authority: **On = instant, Off = animates even with OS reduce-motion on, Auto = follows OS.** Default `slideRight`; voice-channel/call routes use `slideUp`.
- **Noticeable one-shot animations (300ms+)** that hardcode their own durations also gate on `isReduced`: nav-bar glow `AnimatedPositioned` (`mobile_nav_bar.dart`), storage usage-bar `TweenAnimationBuilder` (`mobile_storage_route.dart`), scroll-to-message `scrollTo` (`mobile_chat_route.dart` + both archive viewers), (the archive viewers' content swaps are instant now). `Future.delayed` LOGIC timers are NOT animations — left alone. Sub-200ms micro-fades intentionally left. Implicit `Animated*` using `HollowDurations.fast/normal/slow` already snap to zero via the controller.
- **Interface scale + chat text size (issue #20, 2026-07-26):** in-app display scaling on top of the OS setting. `UiScale` wraps the mobile Stack in `app.dart` (INSIDE `withClampedTextScaling`, so the text clamp still applies), capped at 1.5x on mobile — a 360dp phone lays out at 240dp there and the shell is verified to fit (`text_scale_overflow_test.dart` "Interface scale" group). `ChatTextScale` wraps the message list (via `reversedChatList`) and `_MobileInputBar`. Mobile has no title bar, so there is no `ZoomIndicator` escape hatch — the ceiling and the un-clippable Settings list are what keep it recoverable.
- **Larger Text (P3 stage 1):** mobile text-scale cap raised to **2.0×** (`app.dart` `withClampedTextScaling(0.8, 2.0)`). Mobile chrome bars stay fixed-height but **cap their labels** with `MediaQuery.withClampedTextScaling(maxScaleFactor: 1.3, child: Text(...))` (tab-bar norm): `mobile_nav.dart` + `mobile_nav_bar.dart` nav captions. Mobile chat header (`mobile_chat_route.dart`) uses `Container(constraints: BoxConstraints(minHeight: 52))` to GROW. **NEVER wrap a full-width bar in a bare `ConstrainedBox(minHeight:)`** — it unbounds width and collapses the layout; put `constraints:` on the Container or cap the label. CI: `test/widget/text_scale_overflow_test.dart` pumps the mobile shell at 1.0×/1.5×/2.0× asserting no RenderFlex overflow.

### Pushed pages: iOS swipe back (2026-09-24)

`hollowMobileRoute()` returns `_HollowPageRoute`, a `PageRoute` of its own (`mobile_page_route.dart`):
- `slideRight` pages slide in from the right with `HollowCurves.enter`; `slideUp` from the bottom; `fade` fades. Reduce motion = no transition (except that a swipe back still drags the page, since the finger drives it).
- **iOS only**, for `slideRight` pages: `_BackSwipeDetector` puts a 20 px strip on the leading edge (widened by a notch's padding, RTL-aware); a horizontal drag starting there drives the route's own controller (`_BackSwipe`), then pops on a fling or past halfway, or settles back (350 ms `fastEaseInToSlowEaseOut`). It respects `popGestureEnabled` (so a `PopScope` that refuses the pop, like the chat's open expression panel, blocks the swipe) and keeps `navigator.userGestureInProgress` until the settle lands. Android's system back gesture owns the edge there, so no strip.
- The page below shifts 30% of the width to the left while covered, iOS style, through `delegatedTransition` (an instance tear-off, so two stacked Hollow pages never compare equal and the lower one still gets the parallax). Linear while the finger drives it, `HollowCurves.enter` otherwise.
- Pinned by `test/widget/mobile_back_swipe_test.dart`; driven on the iOS Simulator by the fleet scenario `fleet/mobile_swipe_back.json` (wiki fleet_probe).

## MobileChatRoute reversed lists + lifecycle guards (2026-07-03)

Both mobile lists (`_buildDmMessages`, `_buildChannelMessages`) use the reversed-list model (see ui_chat_dm): reverse:true, newest = builder index 0, `chronoIndex = len-1-revIndex`, `_frozenLen` freeze-while-reading, instant `jumpTo(0,0)` maintenance. At-bottom lives in `_checkAutoScroll` (`minIndex <= 0` → `_isInAutoScrollZone` field; edge transitions release/set the freeze + mark seen). **At-bottom growth calls `_scrollToBottom()` (jump + `_markSeen`), never the bare jump** — bare jump left the seen pointer stale (ghost unread).

**`_routeDeactivated` guard:** the route sets a flag in `deactivate()`/clears in `activate()`. A popped route's `ref.listen` callbacks + positions callbacks still fire during the pop frame (banner taps pop the route mid-notification); `mounted` stays true on a deactivated element and `ref.read` there throws "deactivated widget's ancestor". The visibleChannels eviction listener, both growth listeners, and `_checkAutoScroll` all bail on the flag.

**File/image send parity (2026-07-10):** `_handleSend` (file branch) and `_stageVoiceMessage` insert an optimistic `addFileMessage` bubble (diskPath = the picker's local path) BEFORE the network send — desktop parity; previously the sender's bubble only appeared after the FileCompleted → DB-reload round-trip ("image takes seconds to show"). Both now route through `fileTransferProvider.sendFile` (NOT raw `network_api.sendFile`), gaining transfer progress state, video thumbnail pre-extraction, and >34 MB share-backed routing. Dedup by message_id absorbs the later FileCompleted reload. Chat image bubbles decode at display size (`cacheWidth` on `Image.file` in `file_attachment_widget.dart`; ResizeImage never upscales, fullscreen decodes full-res separately).

**Channel-open subscribe:** `initState` (channel branch) subscribes the channel's relay topic — route-level so EVERY entry (Chats tab, banner, push tap) gets live topic broadcasts; the Chats-tab path previously never subscribed. Since 2026-07-03 this goes through `subscribeChannelTopics()` (`lib/src/core/services/channel_topic_service.dart`): never throws, retries ~30s until the node is up (a cold-start push tap opens the route BEFORE `start_node()` completes — a bare call crashed with an uncaught "Node is not running"), and carries a per-server sequence so a stale retry can't clobber a newer subscription (Rust `SubscribeChannels` REPLACES the per-server topic set). Same helper used by MobileShell push-tap, the in-app banner, and desktop `_subscribeActiveChannel`.

**Element reuse (2026-07-03 blink fix):** both mobile lists pass `findChildIndexCallback` (local `indexById` map: messageId → chrono index → `len-1-i`) to the VENDORED `scrollable_positioned_list` so row elements move across index slots instead of remounting on every arrival — see ui_chat_dm "Element reuse".

**Banner tap (MobileInChatBanner._onTap):** pop-then-push — chat routes carry `RouteSettings(name: MobileChatRoute.routeName)` at all 10 push sites; the banner (and shell push handlers) `popUntil` past any chat route before pushing, so chats never stack. Selection writes happen BEFORE the pop, and every chat-open `.then()` cleanup is GUARDED (`only clear if selection still equals what I set`) so the popped route's cleanup can't clobber the new chat. The channel branch passes `channelName` from the fetched channel map (else the header shows "# Channel") and subscribes the topic.
