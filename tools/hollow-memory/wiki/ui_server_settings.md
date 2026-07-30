# ServerSettingsPanel -- Server Configuration

Replaces the chat pane when `serverSettingsOpenProvider` is `true`. Contains all server management UI organized into permission-gated tabs. Source: `lib/src/ui/settings/server_settings_panel.dart`.

## ServerSettingsPanel -- Tab Router and Permission Gating

`file:ServerSettingsPanel` is a `ConsumerStatefulWidget` that takes `ServerInfo server` and an optional `VoidCallback onClose`. It replaces the chat pane in the main shell.

**State:** `_selectedTab` (int) tracks the currently selected tab index.

**Provider dependencies:**
- `serverListProvider` -- re-reads server by ID so name updates are reflected live in the header
- `myPermissionsProvider(serverId)` -- async int bitmask of local user's permissions
- `myRoleProvider(serverId)` -- async string role name for the local user

**Loading guard:** If either `myPermissionsProvider` or `myRoleProvider` has not loaded yet, renders a skeleton header with a close button and an empty body. This prevents a flash of wrong tabs before permissions are known.

**Tab visibility logic** (`_visibleTabs(permissions, myRole)`):
- **Overview** -- always visible (all members see nickname settings, admins see server settings)
- **Channels** -- only if `permissions & Permission.manageChannels != 0`
- **Roles** -- only if `permissions & Permission.manageRoles != 0`
- **Labels** -- always visible (self-service label picker for all, management for MANAGE_ROLES)
- **Members** -- always visible (viewing is open, action buttons gated inside the tab)
- **Notifications** -- always visible
- **Danger** -- always visible (owner sees Delete, non-owners see Leave)

Each tab is a record `({IconData icon, String label, bool isDanger})`. The Danger tab has `isDanger: true` which tints it red.

**Tab bar clamping:** If permissions change (e.g., role downgrade) and `_selectedTab >= tabs.length`, it is clamped to 0.

**Layout structure:**
1. **Header bar** (48px) -- settings icon, "Server Settings -- {serverName}" title with ellipsis, close button (X icon). Close button calls `onClose` if provided, otherwise sets `serverSettingsOpenProvider` to false.
2. **Tab bar** (40px) -- `EdgeScrollRow` of `_TabButton` widgets on `hollow.surface` background with bottom border. Arrows + wheel-panning appear only while the tabs overflow (a narrow panel or a larger text setting); before 2026-07-30 the overflowing tabs were unreachable on a plain wheel mouse.
3. **Tab content** -- `AnimatedSwitcher` with `HollowDurations.normal` crossfade, `Stack` layout builder for overlap during transition.

**`_TabButton`:** `HollowPressable` with `subtle: true`. Shows icon (14px) + label text. Selected state: accent color (or error for danger), `FontWeight.w600`. Unselected: `hollow.textSecondary`, `FontWeight.w400`.

**Tab content routing** (`_buildTabContent`): Switch on `tab.label` string to instantiate the appropriate tab widget:
- `'Overview'` -> `OverviewTab(server, canManageServer: permissions & Permission.manageServer != 0)`
- `'Channels'` -> `ChannelsTab(serverId)`
- `'Roles'` -> `RolesTab(serverId)`
- `'Labels'` -> `LabelsTab(serverId)`
- `'Members'` -> `MembersTab(serverId)`
- `'Notifications'` -> `NotificationsTab(serverId)`
- `'Danger'` -> `DangerZoneTab(server)`

Each tab has a stable `ValueKey` for AnimatedSwitcher identity.

## OverviewTab -- Server Identity and Settings

Source: `lib/src/ui/settings/overview_tab.dart` (763 lines). `ConsumerStatefulWidget` taking `ServerInfo server` and `bool canManageServer`.

**Text editing controllers (6 total):**
- `_nameController` -- server name, initialized from `widget.server.name`
- `_descController` -- server description, loaded async
- `_nicknameController` -- local user's server nickname, loaded async
- `_twitchChannelController` -- Twitch channel display name
- `_twitchChannelIdController` -- numeric Twitch user ID
- `_twitchMinDaysController` -- minimum follow days, initialized to `'0'`
- `_maxMembersController` -- max member cap (digits-only via `FilteringTextInputFormatter.digitsOnly`; blank = unlimited)

**Boolean state flags:**
- `_saving` -- disables Save buttons during name/description save
- `_savingNickname` -- disables nickname Save button during save
- `_twitchEnabled` -- master toggle for Twitch verification
- `_twitchRequireSub` -- require subscription (not just follow)
- `_twitchOwnerVerify` -- owner-online verification mode
- `_savingTwitch` -- disables Twitch save button during save
- `_isPrivate` -- private (invite-only) server toggle
- `_savingAccess` -- disables the Access save button during save

**Initialization (`initState`):**
- `_loadDescription()` -- calls `crdt_api.getServerSetting(serverId, 'description')`, populates controller
- `_loadNickname()` -- gets `identityProvider.peerId`, calls `crdt_api.getServerMembers(serverId)`, finds local user's nickname
- `_loadTwitchSettings()` -- reads 6 server settings keys: `twitch_verification_enabled`, `twitch_channel_name`, `twitch_channel_id`, `twitch_min_follow_days`, `twitch_require_sub`, `twitch_owner_verify`
- `_loadAccessSettings()` -- reads `is_private` and `max_members` settings keys (0/empty = blank field = unlimited)

**`didUpdateWidget`:** If server name changed externally, updates `_nameController.text`.

### Server Settings Section (admin+ only, gated by `canManageServer`)

Entire section wrapped in `if (widget.canManageServer)`. Contains:

**Server Icon:**
- Displays `_stagedIcon ?? serverAvatarProvider[serverId]` as 48x48 `ClipRRect` image (gaplessPlayback), or a placeholder container with image icon; 14px spinner overlay while `_iconBusy`
- "Upload" button (`HollowButton.ghost`) -> `_pickServerAvatar()` (optimistic staging, 2026-07-16/17):
  1. `FilePicker.platform.pickFiles(type: FileType.image)` to select image
  2. Reads file bytes
  3. `showImageCropDialog(imageBytes, aspectRatio: 1.0, title: 'Crop Server Icon')` for square crop
  4. Stages cropped bytes SYNCHRONOUSLY (`_stagedIcon` + `_iconBusy`) so the icon updates instantly; `_iconPickGen` guards overlapping picks
  5. `crdt_api.setServerAvatar(serverId, rawBytes: cropped)` (Rust WebP encode + queued CRDT write)
  6. On success: `serverAvatarProvider.applyLocalWrite(serverId, cropped)` — NEVER an immediate `loadAvatar` (races the fire-and-forget persist and shows the previous icon; see memory `feedback_crdt_read_after_write_race`), then drop staging + success toast. On failure: revert staging + error toast
- "Remove" button (`HollowButton.ghost` with trash icon) -- only shown if `serverAvatarProvider` contains key for this server. `_clearServerAvatar()` bumps the pick gen, calls `crdt_api.clearServerAvatar(serverId)`, then `applyLocalWrite(serverId, null)` + toast.
- Mobile twin: `mobile_server_settings_route.dart:_pickAvatar/_clearAvatar` — identical flow.

**Server Name:**
- `HollowTextField` with `_nameController`, hint "Server name", `maxLength: 32`, `onSubmitted` triggers save
- Adjacent "Save" `HollowButton.filled`, disabled while `_saving` is true
- `_saveName()`: trims text, skips if empty or unchanged, calls `crdt_api.renameServer(serverId, newName)`, shows success/error toast

**Description:**
- `HollowTextField` with `_descController`, hint "What is this server about?", `maxLines: 3`, `maxLength: 256`
- "Save Description" `HollowButton.filled` aligned right, disabled while `_saving`
- `_saveDescription()`: calls `crdt_api.updateServerSetting(serverId, 'description', desc)`

**Access (private + member cap):**
- Section header "ACCESS".
- **Private server** toggle (`HollowToggle`, `_isPrivate`) with subtitle "New members can't join via the link." When ON, the join handler rejects all new joiners.
- **Max members** field (`HollowTextField`, `_maxMembersController`, digits-only, hint "Unlimited") + helper "Leave blank for no limit. Existing members are never removed."
- ONE section-level **"Save Access Settings"** `HollowButton.filled` placed BELOW both controls (right-aligned, like "Save Twitch Settings") — NOT an inline save next to the input (that wrongly reads as "save this field").
- `_saveAccessSettings()`: parses the field (0/empty = unlimited, stored as "0"). For a finite cap, fetches the LIVE member count via `crdt_api.getServerMembers().length` (not the possibly-stale `ServerInfo.memberCount`) and rejects with a toast if the cap is below the current count. Writes `is_private` and `max_members` via `crdt_api.updateServerSetting` (reuses `ServerSettingChanged` — no new CRDT op). Enforcement is on the Rust join handler; see `rust_sync_handler.md` / `swarm.rs ServerJoinRequest`.

**Server Template:**
- Section header "SERVER TEMPLATE" with description text
- "Export" button (`HollowButton.outline`) -> `exportServerTemplate(context, server)`
- "Import" button (`HollowButton.outline`) -> `importServerTemplate(context, ref, server)`

**Server ID:**
- Read-only display in elevated container with border
- `SelectableText` showing `serverId` in mono font
- "Copy" button -> `Clipboard.setData(ClipboardData(text: serverId))`, toast "Copied to clipboard"

### Twitch Verification Section (admin+ only, inside `canManageServer`)

Section header "TWITCH VERIFICATION" with description "Gate join requests behind Twitch follow or subscription checks."

**Enable toggle:**
- Row with Twitch icon (SimpleIcons.twitch, purple #9146FF), label "Require Twitch Verification", `HollowToggle`
- When disabled, all sub-settings are hidden

**Conditional sub-settings (shown when `_twitchEnabled`):**

**Twitch Channel ID:**
- `HollowTextField` with `_twitchChannelIdController`, hint "e.g. 123456789", `maxLength: 32`
- "Fill from account" button (`HollowButton.ghost` with userCheck icon) -> `_fillTwitchFromAccount()`:
  - Calls `twitch_api.twitchGetUserId()` and `twitch_api.twitchGetUsername()`
  - Populates both controllers if successful
  - Error toast if Twitch not connected

**Channel Display Name:**
- `HollowTextField` with `_twitchChannelController`, hint "e.g. coolStreamer123", `maxLength: 64`
- Shown to joiners in verification messages

**Minimum Follow Days:**
- `HollowTextField` 100px wide, `_twitchMinDaysController`, hint "0", `maxLength: 4`
- 0 = just following is enough

**Require Subscription toggle:**
- Row with crown icon, label "Require Subscription", description "Members must be subscribed to your channel"
- `HollowToggle` bound to `_twitchRequireSub`

**Owner-Online Verification toggle:**
- Row with shield icon, label "Owner-Online Verification"
- Description: "Only you (the owner) can accept join requests. Fully resistant to modified clients, but you must be online."
- `HollowToggle` bound to `_twitchOwnerVerify`

**Save Twitch Settings button:**
- `HollowButton.filled`, aligned right, disabled while `_savingTwitch`
- `_saveTwitchSettings()`: writes all 6 settings via `crdt_api.updateServerSetting()`. If enabled, also calls `twitch_api.twitchGetUsername()` and `crdt_api.setTwitchUsername()` to set the owner's Twitch badge.

### Your Identity Section (all members)

Always visible regardless of `canManageServer`.

**Server Nickname:**
- Section header "YOUR IDENTITY"
- Label "Server Nickname" with description "This nickname is only visible on this server. Leave empty to use your display name."
- `HollowTextField` with `_nicknameController`, hint "Nickname (optional)", `maxLength: 32`, `onSubmitted` triggers save
- "Save" `HollowButton.filled`, disabled while `_savingNickname`
- `_saveNickname()`: calls `crdt_api.setNickname(serverId, peerId, nickname)`, invalidates `serverMembersProvider(serverId)`, shows "Nickname cleared" or "Nickname updated" toast

## ChannelsTab -- Channel Layout Editor

Source: `lib/src/ui/settings/channels_tab.dart` (1034 lines). `ConsumerStatefulWidget` with `serverId`.

### Data Model

Three sealed classes represent layout items:
- `CategoryItem(String name)` -- category header
- `ChannelItem(String channelId)` -- a channel reference
- `SeparatorItem()` -- visual break that also breaks category scope

**State:**
- `_layout` -- `List<LayoutItem>`, the current working layout
- `_savedLayout` -- `List<LayoutItem>`, snapshot from DB for dirty comparison
- `_loaded` -- bool, false until initial load completes

**Dirty detection (`_dirty`):** Compares `_layout` against `_savedLayout` by length, runtime type, and field values. Returns true if any difference.

### Layout Loading

`_loadLayout()`:
1. Calls `crdt_api.getChannelLayout(serverId)` which returns JSON string
2. Parses JSON array, constructs `LayoutItem` list from `type` field (`'category'`, `'channel'`, `'separator'`)
3. Calls `_effectiveLayoutFrom(layout, channels)` to reconcile with actual channel list
4. Sets both `_layout` and `_savedLayout` to the effective layout

`_effectiveLayoutFrom(base, channels)`:
- Starts from the base layout
- Finds channel IDs referenced in layout
- Appends any channels from `channelListProvider` not yet in the layout (sorted by name)
- Removes layout entries for channels that no longer exist in provider
- Returns the reconciled list

**Auto-sync:** In `build()`, if `channels.isNotEmpty && effective.length != _layout.length` (channels created/deleted externally), schedules a post-frame callback that updates both `_layout` and `_savedLayout`, then auto-saves the layout JSON via `crdt_api.updateChannelLayout()`. The `channels.isNotEmpty` guard prevents layout corruption when `channelListProvider` is cleared during server deselection (switching to Home tab) while the settings panel is still mounted.

**Channel property controls:** Each `_ChannelRow` has `onVisibilityChanged`, `onPostingChanged`, `onPublicToggled` callbacks. These use optimistic UI updates via `channelListProvider.updateChannel()` BEFORE calling the FFI. The visibility/posting chips are `_AccessChip` dropdowns. The public toggle is a globe icon (accent when public).

### Actions

**Save (`_save`):**
- Serializes `_layout` to JSON array (category: `{type, name}`, channel: `{type, channel_id}`, separator: `{type}`)
- Calls `crdt_api.updateChannelLayout(serverId, layoutJson)` -- persisted via CRDT
- Updates `_savedLayout` to match `_layout`
- Shows "Channel layout saved" success toast

**Add Channel (`_addChannel`):**
- Opens `showHollowDialog` with `StatefulBuilder` for channel type toggle
- Channel type toggle: two `_ChannelTypeChip` widgets ("Text" with hash icon, "Voice" with volume icon)
- `HollowTextField` for channel name, `maxLength: 32`, prefix icon changes with type
- On submit: calls `crdt_api.createChannel(serverId, name, category: null, channelType)`, triggers rebuild
- CRDT operation -- channel appears in provider, auto-sync picks it up

**Add Category (`_addCategory`):**
- Opens `showHollowDialog` with name text field, `maxLength: 32`
- On submit: appends `CategoryItem(name)` to `_layout` (local only until saved)

**Add Separator:** Inline button appends `SeparatorItem()` to `_layout`

**Rename Category (`_renameCategory(index, currentName)`):**
- Dialog with pre-filled text field
- Replaces `_layout[index]` with new `CategoryItem(name)`

**Remove Category (`_removeCategory(index)`):** Removes `_layout[index]` directly, no confirmation.

**Rename Channel (`_renameChannel(channelId, currentName)`):**
- Dialog with pre-filled text field
- Calls `crdt_api.renameChannel(serverId, channelId, newName)` -- CRDT operation, immediate

**Delete Channel (`_deleteChannel(channelId, name)`):**
- Confirmation dialog: "Are you sure you want to delete #name? This cannot be undone."
- On confirm: calls `crdt_api.removeChannel(serverId, channelId)`, removes from `_layout`, shows info toast

### Build Layout

**Header row:**
- Description text "Drag to reorder channels and categories"
- Three buttons: "Break" (add separator), "Category" (add category), "Channel" (add channel)

**Drag-and-drop list:** `ReorderableListView.builder` with:
- `buildDefaultDragHandles: false` -- custom drag handles via `ReorderableDragStartListener`
- `proxyDecorator` -- Material elevation 4, shadow, rounded corners during drag
- `onReorder` -- standard remove/insert with index adjustment

**Item rendering per type:**

**`_SeparatorRow`:** Drag handle + 1.5px horizontal line + delete (X) button.

**`_CategoryRow`:** Accent-tinted container with:
- Drag handle (gripVertical icon)
- Folder icon in accent color
- Category name in uppercase, accent color, bold, letter-spacing 0.8
- Pencil icon button -> rename
- Trash icon button -> delete

**`_ChannelRow`:** Determines `isUnderCategory` by scanning backwards through `_layout` for the nearest `CategoryItem` (a `SeparatorItem` breaks scope). If under a category, shows tree connector (`_TreeConnectorPainter` -- vertical + horizontal line, `isLast` variant for the L-shaped connector).

Row contains:
- Optional indent (12px + 16px connector + 4px gap) when under a category
- Elevated container with:
  - Drag handle
  - Channel icon (hash for text, volume2 for voice)
  - Channel name
  - **Public toggle** (globe icon) -- `HollowPressable` toggle button. When `is_public` is true: accent-tinted globe icon with filled background. When false: neutral globe icon. Tap calls `crdt_api.setChannelPublic(serverId, channelId, !isPublic)` with **optimistic update** via `channelListProvider.updateChannel()` BEFORE the FFI call. Only shown for text channels. Public channels send messages as Ed25519-signed plaintext (not MLS-encrypted).
  - **Visibility `_AccessChip`** (eye icon) -- `PopupMenuButton` cycling through `'everyone'` / `'moderator'` / `'admin'`
  - **Posting `_AccessChip`** (messageSquare icon) -- same options
  - **Slow-mode `_SlowModeChip`** (timer icon, text channels only) -- `PopupMenuButton<int>` over `kSlowModeOptions` (Off/5s/10s/30s/1m/5m/15m/1h). Warning-tinted when active; labels via `slowModeDurationLabel()` from `lib/src/core/moderation_format.dart`. Optimistic update then `crdt_api.setChannelSlowMode()`. Moderator+ are exempt from the limit.
  - **Media-only toggle** (image icon, text channels only) -- `HollowPressable`, accent when on. Optimistic update then `crdt_api.setChannelMediaOnly()`. Media-only channels accept only images/GIFs/videos (captions allowed); the chat input filters the file picker to `kMediaOnlyExtensions` and blocks text-only sends + voice recordings with a toast.
  - Rename button (pencil icon)
  - Delete button (trash icon, red)

**`_AccessChip`:** Compact dropdown showing current level label:
- `'everyone'` -> "All" (neutral styling)
- `'moderator'` -> "Mod+" (warning color background)
- `'admin'` -> "Admin+" (warning color background)
- On select: applies **optimistic update** via `channelListProvider.updateChannel()` BEFORE calling `crdt_api.setChannelVisibility()` or `crdt_api.setChannelPosting()` -- CRDT operations. The optimistic update is needed because CrdtStore is fire-and-forget via mpsc, so the DB write may not be flushed when `ServerUpdated` fires (causing stale reads without the optimistic path).

**Save/Discard bar:** Only shown when `_dirty`. Two buttons:
- "Discard" (`HollowButton.ghost`) -- sets `_loaded = false`, calls `_loadLayout()` to reload from DB
- "Save Layout" (`HollowButton.filled`) -- calls `_save()`

**`_ChannelTypeChip`:** `AnimatedContainer` with accent border when selected, surface background otherwise. Used in the channel creation dialog.

## MembersTab -- Member Management

Source: `lib/src/ui/settings/members_tab.dart` (634 lines). `ConsumerWidget` with `serverId`.

### Member List Display

Watches `serverMembersProvider(serverId)` (async) and `myRoleProvider(serverId)` (async).

**Sort order:** owner (0), admin (1), moderator (2), member (3) -- numeric priority sort.

**`_MemberRow`:** `ConsumerWidget` displaying:
- `HollowAvatar` (32px) with profile avatar bytes
- Display name resolved via `serverDisplayNameFor(profiles, peerId, nickname)` -- resolution order: server nickname -> local nickname -> profile display name -> short peer ID
- "(you)" italic label next to own name
- Peer ID in caption style, ellipsized
- **Role badge:** colored container with icon + capitalized role name
  - Owner: warning color, crown icon
  - Admin: purple (#A78BFA), shield icon
  - Moderator: orange-red blend, shieldCheck icon
  - Member: textSecondary, user icon

### Role Management

**Tier-gating logic:**

`_canManageRole(actorRole, targetRole)`:
- Priority map: owner=3, admin=2, moderator=1, member=0
- Owner can manage everyone
- Moderators and members cannot manage anyone
- Admins can manage targets with lower priority

`_assignableRoles(actorRole)`:
- Owner: [admin, moderator, member]
- Admin: [moderator, member]
- Others: []

**Action menu:** `PopupMenuButton` shown only if `canManage` (not self and `_canManageRole` passes). Contains:
- Role change options: for each assignable role that differs from current, shows icon + "Make {Role}" text
- Divider (if any assignable roles exist)
- "Kick Member" (userMinus icon, red)
- "Mute Member" (volumeX icon, warning)
- "Ban Member" (ban icon, red)

**Role change (`_changeRole`):**
- Shows `_ConfirmDialog` with title "Change Role", message "Change {name}'s role to {Role}?"
- On confirm: calls `crdt_api.changeMemberRole(serverId, peerId, newRole)`, shows success toast

**Kick (`_confirmKick`):**
- `_ConfirmDialog` with `isDanger: true`, "Are you sure you want to kick {name} from the server?"
- On confirm: calls `crdt_api.kickMember(serverId, peerId)`, shows success toast

**Ban (`_confirmBan`):**
- `_ConfirmDialog` with `isDanger: true`, "Are you sure you want to ban {name}? They will be removed and unable to rejoin."
- On confirm: calls `crdt_api.banMember(serverId, peerId)`, shows success toast

**Mute (`_showMuteDialog`):**
- `_MuteDurationDialog` with duration options from `kMuteDurationOptions`: 10 minutes / 1 hour / 24 hours / 7 days / Permanent (0 = permanent, shown in error color)
- On pick: calls `crdt_api.muteMember(serverId, peerId, durationSecs)` (`<= 0` = permanent), shows success toast
- Same hierarchy gate as kick/ban (KICK_MEMBERS + outrank), enforced in Rust

### Muted Members Section

`_MutedMembersSection` -- `ConsumerStatefulWidget`, shown only when `canKick`, ABOVE the banned section.

**Data:** watches `mutedMembersProvider(serverId)` (channel_provider.dart) — NOT a one-shot load. The provider is invalidated on `ServerUpdated` via the event provider's 0/120/400/1000ms ramp (CrdtStore writes are fire-and-forget, a single immediate reload reads stale DB), so a fresh mute appears without leaving the tab.

**Display:** expandable header (chevron + volumeX + "Muted ({count})" in warning color); rows show `HollowAvatar` + display name (server nickname > displayName, resolved from `serverMembersProvider` — muted members are still members) + remaining time via `formatMuteRemaining()` ("Permanent" / "2h 10m left"); "Unmute" ghost button calls `crdt_api.unmuteMember` then invalidates the provider.

Mobile parity: `mobile_members_route.dart` mirrors all of this (mute option in the actions bottom sheet → duration bottom sheet; `_MutedRow` list watching the same provider). The muted user's own input bar shows a "You are muted on this server — {remaining} left" banner via `myMuteStatusProvider` (self-invalidates at expiry).

### Banned Members Section

`_BannedMembersSection` -- `ConsumerStatefulWidget`, shown only when `canKick` (owner or admin).

**State:** `_banned` (nullable list of peer IDs), `_expanded` (bool).

**Loading:** `crdt_api.getBannedMembers(serverId)` on init.

**Display:** Expandable section with chevron toggle:
- Header: chevron + ban icon + "Banned ({count})" in error color
- When expanded: list of banned peer IDs in elevated containers, each with "Unban" ghost button
- `_unban(peerId)`: calls `crdt_api.unbanMember(serverId, peerId)`, reloads list, shows toast

### Confirm Dialog

`_ConfirmDialog`: Reusable confirmation widget with Material wrapping for text rendering.
- 360px wide, glassmorphic surface (alpha 0.92), accent border (alpha 0.2), dark shadow
- Title (heading style, 18px), message (body, textSecondary), two buttons (Cancel ghost, Confirm filled or danger)

## RolesTab -- Permission Configuration

Source: `lib/src/ui/settings/roles_tab.dart` (261 lines). `ConsumerStatefulWidget` with `serverId`.

### Permission Bitmask

Constants from `file:Permission` class (in `server_provider.dart`):
- `manageServer` = bit 0 (1)
- `manageChannels` = bit 1 (2)
- `manageRoles` = bit 2 (4)
- bit 3 unused (MANAGE_INVITES was removed)
- `kickMembers` = bit 4 (16)
- `sendMessages` = bit 5 (32)
- `readMessages` = bit 6 (64)

**`_permissionEntries`:** 6 entries for the toggle UI, each with `label`, `desc`, and `bit`:
- Manage Server -- "Server settings, profile, and deletion"
- Manage Channels -- "Create, edit, and delete channels"
- Manage Roles -- "Change member roles and labels"
- Kick Members -- "Remove or ban members"
- Send Messages -- "Send messages in channels"
- Read Messages -- "View messages in channels"

### Default Permissions

`_defaultPerms` (must match Rust `MemberRole::default_permissions()`):
- Admin: manageChannels | manageRoles | kickMembers | sendMessages | readMessages
- Moderator: kickMembers | sendMessages | readMessages
- Member: sendMessages | readMessages

Owner always has `Permission.all` (all bits set), not editable.

### State and Loading

**State:** `_perms` (Map<String, int>), `_loading` (bool).

`_loadPermissions()`: Iterates `['admin', 'moderator', 'member']`, calls `crdt_api.getRolePermissions(serverId, role)` for each. Falls back to `_defaultPerms` on error.

### Build Structure

Watches `myRoleProvider(serverId)` to determine editing ability. Role priority: owner=3, admin=2, moderator=1, member=0.

For each of `['admin', 'moderator', 'member']`, renders `_buildRoleSection(role, hollow, canEdit)` where `canEdit = myPriority > rolePriority[role]`.

**Role section:** Elevated container with border containing:
- **Header row:** Role icon + name (colored per role), "Reset" ghost button (only if `canEdit`)
  - Role colors: admin = purple (#AB47BC, shieldCheck), moderator = orange (#FF9800, shield), member = grey (#78909C, user)
- **Permission toggles:** One `_PermissionRow` per `_permissionEntries` entry

**`_PermissionRow`:** Row with label + description on left, `HollowToggle` on right. Toggle `onChanged` is null when `canEdit` is false (visually disabled).

### Permission Toggling

`_togglePermission(role, bit, enabled)`:
- Optimistically updates local state with bitwise OR (enable) or AND-NOT (disable)
- Calls `crdt_api.changeRolePermissions(serverId, role, updatedBitmask)`
- On error: reverts local state, shows error toast

`_resetToDefault(role)`:
- Optimistically sets `_perms[role]` to `_defaultPerms[role]`
- Calls `crdt_api.changeRolePermissions(serverId, role, defaultPerm)`
- Shows "{Role} permissions reset to defaults" success toast
- On error: reverts, shows error toast

## LabelsTab -- Cosmetic Labels and Self-Service Picker

Source: `lib/src/ui/settings/labels_tab.dart` (469 lines). `ConsumerStatefulWidget` with `serverId`.

### Preset Colors

9 preset colors: red (#EF4444), orange (#F97316), yellow (#EAB308), green (#22C55E), cyan (#06B6D4), blue (#3B82F6), purple (#8B5CF6), pink (#EC4899), grey (#78909C).

`_parseColor(hex)`: Strips `#`, parses 6-char hex to `Color`. Falls back to grey (#78909C).

### State and Loading

**State:** `_labels` (nullable `List<LabelFfi>`), `_myLabelIds` (Set of label IDs the local user has).

`_loadLabels()`:
1. `crdt_api.getServerLabels(serverId)` -- gets all server labels
2. `crdt_api.getServerMembers(serverId)` -- finds local user's member entry
3. Extracts label IDs from local user's `labels` list into `_myLabelIds`

**Live refresh:** `ref.listen(serverMembersProvider(serverId), ...)` triggers `_loadLabels()` when server state updates from remote peers.

### Self-Assign Section (all members)

Shown when `labels.isNotEmpty`. Header: "Pick your labels" with description "Tap to add or remove labels from your profile".

**Label chips:** `Wrap` of `GestureDetector` containers:
- Selected: colored background (alpha 0.25), colored border, check icon
- Unselected: elevated background, neutral border, circle icon
- Tap calls `_toggleSelfLabel(labelId)`:
  - If already assigned: `crdt_api.unassignLabel(serverId, labelId, peerId)`, removes from `_myLabelIds`
  - If not assigned: `crdt_api.assignLabel(serverId, labelId, peerId)`, adds to `_myLabelIds`

### Management Section (MANAGE_ROLES permission required)

Gated by `canManage = myPermissionsProvider & Permission.manageRoles != 0`.

**Header row:** Settings icon + "Manage Labels" title + "New" filled button.

**Label list:** Each label in an elevated row with:
- Color swatch (14px circle)
- Label name in label color, bold
- Assign button (userPlus icon) -> `_showAssignDialog(label)`
- Delete button (trash icon, red) -> `_deleteLabel(labelId)`

### Create Label Dialog

`_showCreateDialog()`: `showHollowDialog` with `StatefulBuilder`.
- `HollowTextField` for label name, autofocus
- Color picker: `Wrap` of 9 preset color circles (28px), selected one has white 2px border
- Cancel/Create buttons
- On create: calls `_createLabel(name, color)` which converts color to hex, calls `crdt_api.createLabel(serverId, name, hex)`, waits 100ms, reloads labels

### Delete Label

`_deleteLabel(labelId)`: Directly calls `crdt_api.deleteLabel(serverId, labelId)`, waits 100ms, reloads labels. No confirmation dialog.

### Assign Dialog

`_AssignDialog`: `ConsumerStatefulWidget` taking `serverId`, `LabelFfi label`, `VoidCallback onDone`.

**State:** `_assignedPeerIds` (Set of peer IDs that have this label).

`_loadAssignments()`: Reads `serverMembersProvider`, scans each member's labels for matching `labelId`.

**Display:** `HollowDialog` titled "Assign '{name}'", 320x300 `ListView`:
- Each member as `ListTile` with dense layout
- Leading: 10px circle (filled with label color if assigned, transparent with border if not)
- Title: display name resolved via `serverDisplayNameFor`
- Tap toggles assignment via `crdt_api.assignLabel` / `crdt_api.unassignLabel`, invalidates `serverMembersProvider`
- "Done" button calls `onDone()` then pops

## NotificationsTab -- Notification Settings

Source: `lib/src/ui/settings/notifications_tab.dart` (336 lines). `ConsumerWidget` with `serverId`.

### Notification Levels

From `notification_provider.dart`:
- `NotificationLevel`: `all`, `mentions`, `nothing`
- `ChannelNotificationLevel`: `inherit`, `all`, `mentions`, `nothing`

Storage keys: `notif:{serverId}` for server level, `notif:{serverId}:{channelId}` for channel overrides.

### Server-Wide Setting

Section header "SERVER NOTIFICATIONS" with description "Default notification level for all channels in this server."

`_NotificationLevelSelector`: Row of three `_LevelChip` widgets:
- "All Messages" (bell icon, accent color when selected)
- "Mentions Only" (atSign icon, warning color when selected)
- "Nothing" (bellOff icon, error color when selected)

Selected chip: colored background (alpha 0.15), colored border, bold text. Unselected: surface background, neutral border.

On change: `notifNotifier.setServerLevel(serverId, level)`.

### Per-Channel Overrides

Section header "CHANNEL OVERRIDES" with description "Override notification settings for specific channels."

For each channel in `channelListProvider`:
- Row with hash icon, channel name (ellipsized), `_ChannelOverrideDropdown`

**`_ChannelOverrideDropdown`:** `PopupMenuButton<ChannelNotificationLevel>` with 4 options:
- Default (settings icon) -- uses `ChannelNotificationLevel.inherit`
- All (bell icon) -- `ChannelNotificationLevel.all`
- Mentions (atSign icon) -- `ChannelNotificationLevel.mentions`
- Nothing (bellOff icon) -- `ChannelNotificationLevel.nothing`

Display: surface container with border showing current label + chevron down. Active item highlighted in accent color.

On change: `notifNotifier.setChannelOverride(serverId, channelId, level)`.

## DangerZoneTab -- Leave and Delete Server

Source: `lib/src/ui/settings/danger_zone_tab.dart` (248 lines). `ConsumerWidget` taking `ServerInfo server`.

### Role Detection

Watches `myRoleProvider(server.serverId)`. `isOwner = roleAsync.valueOrNull == 'owner'`.

### Layout

Red-bordered container (`error` color, alpha 0.3) with:
- Header: alertTriangle icon + "Danger Zone" in error color
- Content varies by role

### Non-Owner: Leave Server

Row with:
- Left: "Leave this server" title + "You will need a new invite to rejoin." description
- Right: `HollowButton.danger` with logOut icon, "Leave Server"

`_confirmLeave()`: `showHollowDialog` -> `HollowDialog` with:
- Title: "Leave Server"
- Content: 'Are you sure you want to leave "{serverName}"?' + 'You will need a new invite to rejoin this server.'
- Cancel ghost button, "Leave Server" danger button

`_leaveServer()`:
1. `crdt_api.leaveServer(serverId)`
2. Clears state: `serverSettingsOpenProvider = false`, `selectedServerProvider = null`, `selectedChannelProvider = null`, `channelListProvider.clear()`
3. Toast: 'Left "{serverName}"'

### Owner: Delete Server

Row with:
- Left: "Delete this server" title + "Once deleted, all data is permanently removed." description
- Right: `HollowButton.danger` with trash2 icon, "Delete Server"

`_confirmDelete()`: `showHollowDialog` -> `HollowDialog` with:
- Title: "Delete Server"
- Content: 'Are you sure you want to delete "{serverName}"?' + 'This action cannot be undone. All channels and messages will be permanently deleted.'
- Cancel ghost button, "Delete Server" danger button

`_deleteServer()`:
1. `crdt_api.deleteServer(serverId)`
2. Clears state: same as leave (serverSettingsOpen, selectedServer, selectedChannel, channelList)
3. Toast: 'Server "{serverName}" deleted'

## ServerTemplate -- Export and Import System

Source: `lib/src/ui/settings/server_template.dart` (723 lines). Top-level functions and data models, not a widget.

### Data Models

**`ServerTemplate`:**
- `version` (int) -- currently 1, rejects version > 1
- `exportedAt` (String?, ISO 8601 UTC)
- `name` (String)
- `description` (String)
- `iconBase64Webp` (String?, base64-encoded WebP image)
- `channels` (List of `TemplateChannel`)
- `channelLayout` (List of `Map<String, dynamic>`)

**`TemplateChannel`:**
- `templateId` (String) -- synthetic ID like "t-0", "t-1" assigned during export
- `name` (String)
- `channelType` (String, "text" or "voice")
- `category` (String?)

**`TemplateDiff`:**
- `nameChange` (String?) -- new name or null if unchanged
- `descriptionChange` (String?) -- new description or null if unchanged
- `iconChanged` (bool)
- `channelsToAdd` (List of TemplateChannel)
- `channelsToRemove` (List of ChannelInfo)
- `layoutChanged` (bool)
- `matchedChannels` (Map template_id -> real channel_id)
- `isEmpty` getter -- true when no changes detected

### Export (`exportServerTemplate`)

1. Reads channels via `crdt_api.getServerChannels(serverId)`
2. Reads layout via `crdt_api.getChannelLayout(serverId)`, parses JSON
3. Reads description and icon from server settings
4. Assigns template IDs (`t-0`, `t-1`, ...) to each channel, builds `idToTemplate` mapping
5. Rewrites layout JSON replacing `channel_id` with `template_id` (skips stale entries)
6. Constructs `ServerTemplate` and serializes to pretty JSON
7. Opens `FilePicker.platform.saveFile()` with sanitized default name `{server-name}-template.json`
8. Writes to file, shows success toast

### Import (`importServerTemplate`)

1. Opens `FilePicker.platform.pickFiles()` for JSON files
2. Parses file, constructs `ServerTemplate` (rejects version > 1)
3. Validates: template not empty, icon not > 1MB when decoded
4. Reads current server state for diffing (channels, description, icon)
5. Computes `TemplateDiff`
6. If diff is empty, shows "No Changes Needed" dialog and returns
7. Shows confirmation dialog with change preview
8. If confirmed, applies template

### Diff Computation (`_computeDiff`)

**Channel matching:** Case-insensitive name + type match between template channels and current channels. Unmatched template channels become `channelsToAdd`. Unmatched current channels become `channelsToRemove`.

**Layout change detection:** True if channels are added/removed. Even if channels match, checks if template layout ordering (resolved to real IDs) differs from current channel order.

### Template Application (`_applyTemplate`)

Five phases:
1. **Settings** (parallel): rename server, update description, set avatar (decoded from base64)
2. **Remove channels:** sequential `crdt_api.removeChannel()` for each
3. **Create channels:** sequential `crdt_api.createChannel()`, then polls `channelListProvider` up to 5 seconds (50 attempts, 100ms interval) to discover new channel IDs by name matching against previously-existing IDs
4. **Update layout:** Builds full ID mapping (matched + newly created), resolves template layout `template_id` references to real `channel_id`, calls `crdt_api.updateChannelLayout()`
5. **Refresh UI:** `channelListProvider.loadForServer()`, `channelLayoutProvider.loadForServer()`, `serverListProvider.onServerUpdated()`

### Confirmation Dialog (`_showConfirmationDialog`)

`HollowDialog` titled "Apply Template" showing:
- "Apply '{name}' to this server?" header
- Safety note: "Removed channels will disappear from the sidebar, but their messages are never deleted -- they remain in everyone's local database."
- **SETTINGS section:** name change, description update, icon change (each with appropriate icon)
- **CHANNELS TO ADD:** listed with hash/volume icon in accent color
- **CHANNELS TO REMOVE:** listed with hash/volume icon in error color
- **Layout note:** if only ordering changed, shows "Channel ordering will be updated"
- Cancel ghost button, "Apply Template" danger button (returns bool)
