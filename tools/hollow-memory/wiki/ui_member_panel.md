# MemberPanel — Right-Side Member List

Sources: `lib/src/ui/shell/member_panel.dart` (the frame), `lib/src/ui/shell/member_list.dart`
(the list, shared with the phone), `lib/src/ui/components/person_row.dart` (the row).
Rebuilt 2026-09-26 (design language pass; tmp3 item 1).

## The frame

`MemberPanel` is only rendered with a server selected (the shell's `_MemberPanelSlot` gates on
`selectedServerId != null && memberPanelOpen && !voiceRoomSelected`); the old DM/Home "peers online"
mode was dead code and is gone. `surface`, width from `memberPanelWidthProvider` (the
`PanelResizeHandle` seam on its LEFT edge paints the divider, so the shell passes
`edgeBorder: false`). Top: a `ChatHeaderBar` (users icon, "Members"), level with the chat's header
and outside `PanelScale`; below it `PanelScale > MemberList`, keyed per server so switching swaps
instantly.

## MemberList (desktop panel AND the phone's member sheet)

`memberListProvider(serverId)` (autoDispose family, `AsyncValue<List<MemberListItem>>`) is the ONE
grouping: online members by role in `owner, admin, moderator` order, then plain members (and any
role this build does not know) under **"Online"**, then **"Offline"**; each group sorted by
nickname-or-name, case-insensitive. Online = `onlineIdentitiesProvider` (device->master folded,
invisible applied); yourself follows `invisibleModeProvider`. Items: `MemberGroupItem(label, count,
folded)` / `MemberPersonItem(member, online)`.

- **Groups fold** (issue #54): `collapsedMemberGroupsProvider`, keyed `serverId:label`, persisted;
  a folded group keeps its header and full count. The header is `HollowSectionHeader(dense, count)`
  inside a `HollowPressable` with a trailing chevron (semantics "Collapse/Expand <label>, N
  members"); groups after the first sit `lg` below the previous rows.
- **The role shows ONCE**, as its group's header. Rows carry no role line and no role colours (the
  old hardcoded purple admin / warning-orange moderator / gold owner are gone: status colours are
  not rank).
- **States:** loading shows nothing for 1 s, then skeleton rows at the final geometry (`Timer`, no
  ticker); error = `HollowEmptyState` "Couldn't load the member list" + ghost "Try again"
  (invalidates `serverMembersProvider`); empty = "No members yet"; our relay link offline /
  reconnecting / error = a quiet line on top, "You're offline, so who's online may be out of date."
- `touch: true` (phone sheet): 40 px avatars, full-bleed rows, a tap opens
  `showMobileProfileSheet`. Desktop: a tap opens `showProfileCardPopup` anchored by
  `memberCardAnchor` (left of the panel, re-read on resize), a right click `showUserContextMenu`.

## PersonRow

`PersonRow(peerId, name, online, onTap, nameTrailing, subtitle, touch)`: `PresenceAvatar` (32 desktop
/ 40 touch, dot ring cut from `surface` / `overlay`), name in `body` (`bodyTouch` on a phone) w500,
glyphs after the name, optional second line. Desktop rows are 36 tall (two-line ~50). Offline
DIMS THE AVATAR (AnimatedOpacity 0.5) and drops the NAME to `textTertiary` (faded text fails
contrast). The member list passes `SupportNameGlyph` + `TwitchNameGlyph` (a grey Twitch mark with
the handle in its tooltip; the handle itself lives on the profile card) and, while online, the
person's `profile.status` as the subtitle. The per-row sync spinner is gone (it was an operator
signal and a ticker per row).

## The User Context Menu (issue #61 phase 3)

Both tiles are wrapped in a `ContextMenuTarget` that opens `showUserContextMenu`
(`lib/src/ui/shell/user_context_menu.dart`). **Left click still opens the profile card** — the card is an
identity surface (banner, showcase, roles) and a list of text rows cannot replace it, so the menu carries
`Profile` as its first row instead of trying to be one.

This is ONE menu shared by every surface that shows a person: these two tiles, a sender name or avatar in chat
(`ProfileTapTarget`), the voice participant row in the channel sidebar, the DM tile (`PeerCard`), the friends
bar chip, and the home dashboard's recent conversations. A `UserMenuSurface` (`generic` / `dmTile` / `voice`)
adds the surface-specific rows.

### Rows, in order
Profile, Mention, Message, Start a call, Set nickname, Verify contact, Manage member, Mute member, Kick member,
Ban member, Block, Report, Copy user ID. Yourself gets Profile and Copy user ID only.

- **Mention** appears only while a TEXT channel is on screen, and posts a scoped `composerInsertProvider`
  request (`serverId:channelId`) that the matching channel pane applies. The scope is what keeps it out of the
  other pane in split view.
- **Start a call** appears only when the identity is online and no call is already up.
- **The `dmTile` surface** adds Mark as read, Mute conversation, the favourite toggle and Remove friend.
- **The `voice` surface** puts the per-peer volume slider in as the menu's FIRST row (a `HollowMenuCustom`).
  Right-clicking a participant used to open that slider and nothing else; folding it in keeps the control and
  gains the row every other user action. The slider stays keyed by the ROUTABLE DEVICE id (`routablePeerId`)
  because volume is a property of an audio stream; everything else collapses to the master via the resolver.

### Gating: hide, never disable
Moderation rows need `canManageRole(myRole, targetRole)` AND `Permission.kickMembers`, and the target must
actually appear in `serverMembersProvider` — an owner right-clicking a non-member gets nothing. A greyed row
still advertises an action the user cannot perform, and a shown-but-unusable one produces a confusing Rust
rejection later. Rust re-checks `op_allowed` on every op regardless.

The confirms themselves live in `lib/src/ui/settings/moderation_dialogs.dart`, shared with the Server settings
Members page (desktop and phone) and Manage member (see `ui_profile_card.md`, "Moderation confirms"): each runs
its op INSIDE the confirm and toasts itself. Set nickname opens `showLocalNicknameDialog`, Remove friend
`confirmRemoveFriend` (`dialogs/confirm_remove_friend.dart`), both the same dialogs every other surface uses.

## VoiceChannelPanel Integration

The `VoiceChannelPanel` (`lib/src/ui/shell/voice_channel_panel.dart`) is a separate widget that sits at the bottom of the channel sidebar (not inside MemberPanel). It appears when `vcState.isInVoiceChannel` is true and shows:

1. **Header row:** green connection dot + "Voice Connected" label + channel name from `channelListProvider`
2. **Controls row:** Mute toggle (`LucideIcons.mic`/`micOff`), Deafen toggle (`LucideIcons.headphones`), Camera toggle (`LucideIcons.video`/`videoOff`), Screen Share (desktop only, `LucideIcons.monitor`), Disconnect (`LucideIcons.phoneOff`, error color)

### Screen Share Handling
`_handleScreenShareToggle()`: If already sharing, calls `stopScreenShare()`. Otherwise opens `showScreenShareDialog(context)` to get source selection, then calls `startScreenShare()` with sourceId, dimensions, fps, and shareAudio.

### Providers Read by VoiceChannelPanel
- `voiceChannelProvider` — `VoiceChannelState` with all voice state
- `channelListProvider` — to resolve channel name from `currentChannelId`

### Platform Gate
Screen share button only shows on `Platform.isWindows || Platform.isMacOS || Platform.isLinux`.
