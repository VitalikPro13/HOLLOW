# HOLLOW — Complete Feature Matrix

> Generated 2026-05-12, updated 2026-05-12. Covers every user-facing feature on desktop, with mobile porting status.
> Used for: mobile port punch list, integration test coverage planning, QA tracking.

## Legend

| Status | Meaning |
|--------|---------|
| **Done** | Fully implemented on mobile |
| **Partial** | Basic version exists, missing interactions or polish |
| **Not impl** | Desktop only, no mobile equivalent |
| **N/A** | Not applicable to mobile (e.g. window chrome) |

---

## 1. Chat — Core Messaging

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 1 | Send text message | `chat_pane.dart`, `channel_chat_pane.dart` | Done | Enter / tap send | Desktop: Enter sends. Mobile: tap send button |
| 2 | Edit own message | `message_action_bar.dart`, `chat_pane.dart` | Done | Long-press → Edit → inline TextField | Mobile: Save/Cancel buttons. Sync gap: offline peers don't receive edits |
| 3 | Delete message (own/mod) | `message_action_bar.dart` | Done | Long-press → Delete → confirm | Mobile: inline confirmation in bottom sheet. Sync gap: same as edit |
| 4 | Copy message text | `message_action_bar.dart` | Done | Long-press → Copy Text | Toast confirmation |
| 5 | Emoji reactions (add) | `reaction_bar.dart`, `emoji_picker.dart` | Done | Long-press → quick react or full grid | 6 quick emojis + "More..." for full 30 |
| 6 | Emoji reactions (remove) | `reaction_bar.dart` | Done | Tap reaction pill on message | Toggle off own reaction |
| 7 | Emoji reactions (view) | `reaction_bar.dart` | Done | Reaction pills below message | Count + accent highlight for own reactions |
| 8 | Reply to message | `message_action_bar.dart`, `chat_pane.dart` | Done | Long-press → Reply | Reply preview above input bar |
| 9 | Reply preview in bubble | `message_bubble.dart` | Done | Inline display | Shows quoted sender + text above message |
| 10 | Pin message (channel) | `channel_chat_pane.dart`, `message_action_bar.dart` | Not impl | Hover → pin | Permission-gated, channel only |
| 11 | Pinned messages list | `channel_chat_pane.dart` | Not impl | Click pin icon in header | Modal with pinned count |
| 12 | Message proof / info | `message_action_bar.dart`, `message_proof_dialog.dart` | Done | Long-press → Message Info | Shows sender, timestamp, signature verification |
| 13 | Message action bar (hover) / long-press sheet | `message_action_bar.dart`, `mobile_message_actions.dart` | Done | Long-press → bottom sheet | Mobile: bottom sheet with actions. Desktop: hover overlay |

## 2. Chat — File Attachments

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 14 | Send file attachment | `chat_pane.dart`, `chat_drop_zone.dart` | Done | Click paperclip / file picker | Mobile: file picker only, no drag-drop (N/A on mobile) |
| 15 | Image inline display | `file_attachment_widget.dart` | Done | Tap → fullscreen | Uses desktop widget, renders inline |
| 16 | Image fullscreen lightbox | `file_attachment_widget.dart` | Done | Tap image | Uses desktop fullscreen viewer |
| 17 | Video thumbnail display | `video_message_bubble.dart` | Done | Tap → play | Uses desktop video player widget |
| 18 | Video inline playback | `video_message_bubble.dart` | Done | Tap play | Uses desktop video player widget |
| 19 | Audio playback inline | `audio_message_bubble.dart` | Done | Tap play | Uses desktop audio player widget |
| 20 | Download file | `file_attachment_widget.dart`, `mobile_chat_route.dart` | Done | Long-press → Save File | Bottom sheet action, save dialog with WebP conversion |
| 21 | Copy image to clipboard | `chat_input_shortcuts.dart` | N/A | Hover → image copy | Desktop only (super_clipboard unreliable on Android); Save File covers mobile |
| 22 | Paste image from clipboard | `chat_input_shortcuts.dart` | N/A | Ctrl+V | Desktop only; mobile uses file picker + Android native paste |
| 23 | Drag-drop file into chat | `chat_drop_zone.dart` | N/A | Drag file over area | Desktop only |
| 24 | File progress indicator | `download_manager_popup.dart` | Done | Inline in message | Uses desktop progress widget |
| 25 | Download manager popup | `download_manager_popup.dart` | N/A | Click icon to toggle | Desktop popup, not applicable to mobile |

## 3. Chat — Link Previews

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 26 | Link preview (OG metadata) | `chat_pane.dart`, `channel_chat_pane.dart` | Done | Auto-fetch on URL type | 600ms debounce in mobile_chat_route, sender-side only |
| 27 | Link preview card | `link_preview_card.dart` | Done | Rendered below message | Uses desktop widget, ClipRRect fix for non-uniform border |
| 28 | Staged link preview | `staged_link_preview_card.dart` | Done | Above input while composing | Loading/loaded/failed states, dismiss button |
| 29 | Hollow protocol links | `hollow_link_card.dart`, `hollow_link_utils.dart` | Done | Tap card | Share/ServerInvite/RoomInvite, ClipRRect fix for non-uniform border |

## 4. Chat — Voice Messages

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 30 | Record voice message | `voice_recorder_bar.dart` | Done | Tap mic button | OGG Opus via native encoder (no ffmpeg), waveform viz, auto-send on stop |
| 31 | Voice message playback | `audio_message_bubble.dart` | Done | Tap play in bubble | Desktop widget works on mobile; duration probe skipped (no ffmpeg), player reports duration |

## 5. Chat — Text Rendering & Formatting

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 32 | Bold `**text**` | `message_text_parser.dart` | Done | Auto-parse | Desktop widget renders on mobile unchanged |
| 33 | Italic `*text*` | `message_text_parser.dart` | Done | Auto-parse | Desktop widget renders on mobile unchanged |
| 34 | Code block `` ```code``` `` | `message_text_parser.dart` | Done | Auto-parse | Full-width container, works on mobile |
| 35 | Inline code `` `code` `` | `message_text_parser.dart` | Done | Auto-parse | Background pill, works on mobile |
| 36 | Strikethrough `~~text~~` | `message_text_parser.dart` | Done | Auto-parse | Desktop widget renders on mobile unchanged |
| 37 | Spoiler `\|\|text\|\|` | `message_text_parser.dart` | Done | Tap to reveal/hide | GestureDetector.onTap — works on mobile |
| 38 | URL auto-linking | `message_text_parser.dart` | Done | Tap accent text | GestureDetector.onTap + url_launcher, works on mobile |
| 39 | @mention autocomplete | `channel_chat_pane.dart` | Done | Type @ → overlay popup | OverlayEntry + HollowPressable.onTap, works on mobile |
| 40 | @mention highlight | `channel_message_bubble.dart`, `message_text_parser.dart` | Done | Accent pill badges | WidgetSpan + Container styling, works on mobile |
| 41 | Keyboard shortcuts (Ctrl+B/I/E) | `chat_input_shortcuts.dart` | N/A | Wrap selection | Desktop only |
| 42 | Keyboard shortcuts (Shift+Enter) | `chat_input_shortcuts.dart` | N/A | Insert newline | Desktop: Shift+Enter. Mobile: keyboard newline |

## 6. Chat — Status & Navigation

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 43 | Typing indicator (show) | `chat_pane.dart`, `channel_chat_pane.dart` | Done | Above input bar | _TypingBar with TypingDots, profiles from typingProvider |
| 44 | Typing indicator (send) | `chat_pane.dart`, `channel_chat_pane.dart` | Done | 3s throttle on input | sendTypingIndicator in _onTextChanged, DM only |
| 45 | Message grouping by sender | `chat_pane.dart` | Done | Consecutive within 5 min | Same logic as desktop in MobileChatRoute |
| 46 | Message timestamp separator | `chat_pane.dart` | Done | Date label between groups | _DateSeparator with _sameDay check |
| 47 | Scroll-to-bottom button | `chat_pane.dart`, `channel_chat_pane.dart` | Done | Floating "N new" pill | Accent pill with arrow + count, auto-hides at bottom |
| 48 | Unread message indicator | `chat_pane.dart`, `channel_chat_pane.dart` | Done | Floating "N new" pill | DM + channel, message-ID dedup, same protocol as desktop |
| 49 | In-channel search | `channel_chat_pane.dart` | Done | Search icon in header | TextField + results list, Rust FFI searchChannelMessages |
| 50 | Search results navigation | `channel_chat_pane.dart` | Done | Tap result → jump | Scroll to message with 1.5s accent highlight |
| 51 | Per-DM mute toggle | `chat_pane.dart` | Done | Bell icon in DM header | notificationSettingsProvider.setDmEnabled, toast feedback |

## 7. Chat — Layout & Panels

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 52 | DM chat (1:1) | `chat_pane.dart` | Done | Full ChatPane | MobileChatRoute with all message features |
| 53 | Channel chat (server text) | `channel_chat_pane.dart` | Done | Full ChannelChatPane | MobileChatRoute shared for DM + channel |
| 54 | Chat header bar | `chat_pane.dart`, `channel_chat_pane.dart` | Done | Back + avatar + name + status | _MobileChatHeader, profile sheet on tap. Extra icons (call, members) are separate features |
| 55 | Member panel toggle | `channel_chat_pane.dart` | N/A | Click users icon | Duplicate → see #92 (Section 12). Mobile: bottom sheet |
| 56 | DM profile panel | `chat_pane.dart` | Done | Tap header name | _ProfileSheet bottom sheet with avatar, name, peer ID, banner |
| 57 | DM call buttons (voice) | `chat_pane.dart` | N/A | Click phone icon | Duplicate → see #145 (Section 16) |
| 58 | DM call buttons (video) | `chat_pane.dart` | N/A | Click video icon | Duplicate → see #149 (Section 16) |
| 59 | Inline call panel (DM) | `chat_pane.dart` | N/A | Slides down during call | Duplicate → see #156 (Section 16) |
| 60 | Screen share overlay (DM) | `chat_pane.dart` | N/A | Click monitor icon | Duplicate → see #152 (Section 16) |
| 61 | Split view (dock mode) | `chat_pane.dart`, `hollow_shell.dart` | N/A | Ctrl+Shift+\ | Desktop dock layout only |

## 8. Chat — Input Bar

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 62 | Text input field | `chat_pane.dart`, `channel_chat_pane.dart` | Done | Max 5 lines, auto-expand | 120px max, rounded pill style |
| 63 | Attachment button | `chat_pane.dart`, `channel_chat_pane.dart` | Done | Paperclip → file picker | FilePicker.platform.pickFiles() |
| 64 | Microphone button | `chat_pane.dart` | Done | Tap mic → VoiceRecorderBar | Disabled when file staged |
| 65 | Emoji picker button | `message_action_bar.dart` | Done | Shows popup picker | Mobile: smiley icon in input bar → bottom sheet with 30-emoji grid. Inserts at cursor position |
| 66 | Send button | `chat_pane.dart`, `channel_chat_pane.dart` | Done | Tap send | Accent circle, always visible |

## 9. Chat — Permissions & Sync

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 67 | Read permission gate | `channel_chat_pane.dart` | Done | Hide messages | eyeOff icon + message when readMessages bit is 0 |
| 68 | Post permission gate | `channel_chat_pane.dart` | Done | Disable input | Replaces input bar with "no permission" notice via canPostInChannelProvider |
| 69 | Channel sync request | `channel_chat_pane.dart` | Done | Auto on open | Already works — loadHistory() calls requestChannelSync FFI |
| 70 | Sync status indicator | `channel_chat_pane.dart` | Done | Spinner + text | Syncing/retrying/failed states with retry button below header |
| 71 | Vault health indicator | `channel_chat_pane.dart` | N/A | Icon + tooltip | Deferred — needs server info sheet (6+ member servers only, low priority for mobile) |

---

## 10. Server Management

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 72 | Create server | `create_server_dialog.dart` | Done | Dialog (create/join tabs) | Nav bar "+" button → NewConversationDialog → Create Server |
| 73 | Join server (invite code) | `create_server_dialog.dart` | Done | Dialog or `hollow://join` link | Nav bar "+" → Join Server. Also via hollow:// link cards in chat |
| 74 | Leave server | `danger_zone_tab.dart` | Done | Settings → Danger Zone | Long-press server → Leave, or MobileServerSettingsRoute danger zone |
| 75 | Delete server | `danger_zone_tab.dart` | Done | Settings → Danger Zone | MobileServerSettingsRoute danger zone (owner only). Confirmation dialog |
| 76 | Server name edit | `overview_tab.dart` | Done | Text input, max 32 chars | MobileServerSettingsRoute, permission-gated (manageServer) |
| 77 | Server avatar | `overview_tab.dart`, `server_avatar_provider.dart` | Done | File picker + crop | Tap avatar → pick + crop 1:1. Long-press to clear. Permission-gated |
| 78 | Server description | `overview_tab.dart` | Done | Text field, max 256 chars | MobileServerSettingsRoute, multi-line, permission-gated |
| 79 | Server ID display + copy | `overview_tab.dart` | Done | Selectable text | MobileServerSettingsRoute + long-press context sheet. Copy button |
| 80 | Server settings access | `channel_sidebar.dart`, `server_settings_panel.dart` | Done | Gear icon in header | Long-press server row → Settings → full-screen MobileServerSettingsRoute |
| 81 | Server export/import template | `overview_tab.dart`, `server_template.dart` | Not impl | Export/Import buttons | Low priority — template system rarely used |

## 11. Channel Management

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 82 | Create channel (text) | `create_channel_dialog.dart` | Done | Dialog with type selector | Reuses desktop dialog. "+" in accordion + server context sheet |
| 83 | Create channel (voice) | `create_channel_dialog.dart` | Done | Dialog with type selector | Same dialog, voice type toggle |
| 84 | Delete channel | `channels_tab.dart` | Done | Long-press → bottom sheet | Confirmation in sheet + server settings editor |
| 85 | Rename channel | `channels_tab.dart` | Done | Long-press → bottom sheet | Rename view in sheet + server settings editor |
| 86 | Reorder channels (drag-drop) | `channels_tab.dart` | Done | Drag in settings | ReorderableListView in MobileServerSettingsRoute |
| 87 | Channel categories | `channels_tab.dart`, `channel_sidebar.dart` | Done | Collapsible headers | Chevron toggle in accordion, layout-aware rendering |
| 88 | Channel visibility toggle | `channels_tab.dart` | Done | Long-press → bottom sheet | Radio-style selection (Everyone/Mod+/Admin+) + posting |
| 89 | Channel sidebar display | `channel_sidebar.dart` | Done | Accordion in Chats tab | Server row expands to show channels with AnimatedCrossFade |
| 90 | Channel switching | `channel_sidebar.dart` | Done | Tap channel → push chat | Full MobileChatRoute navigation |
| 91 | Unread per channel | `unread_provider.dart`, `channel_sidebar.dart` | Done | Red pill with count | Per-channel in server accordion, matches desktop |

## 12. Members & Roles

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 92 | Member list panel | `member_panel.dart` | Done | Right sidebar 240px | Mobile: DraggableScrollableSheet from users icon in chat header |
| 93 | Member online/offline status | `member_panel.dart` | Done | Status dot on avatar | Role-grouped, online/offline sections |
| 94 | Member profile popup | `member_panel.dart`, `profile_card_popup.dart` | Done | Click member | Tap member → MobileProfileSheet bottom sheet with role, labels, actions |
| 95 | Member sync indicator | `member_panel.dart` | Done | Spinning refresh icon | Yellow pulse dot via isPeerSyncingProvider |
| 96 | Assign roles | `members_tab.dart` | Done | Settings dropdown | Long-press member → role change sheet. Priority-based |
| 97 | Change member role | `members_tab.dart` | Done | Settings role selector | MobileMembersRoute with long-press actions |
| 98 | Kick members | `members_tab.dart` | Done | Settings button | Confirmation dialog, permission-gated |
| 99 | Ban/unban members | `members_tab.dart` | Done | Settings section | Collapsible banned section with unban |
| 100 | Create/edit roles | `roles_tab.dart` | Done | Settings tab | MobileRolesRoute: 3 role cards, 6 permission toggles each |
| 101 | Labels (cosmetic) | `labels_tab.dart` | Done | Settings tab | MobileLabelsRoute: self-assign + manage (create, delete, assign members) |
| 102 | Server nickname | `overview_tab.dart` | Done | Text input, max 32 chars | Already in MobileServerSettingsRoute |

## 13. Invitations & Twitch

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 103 | Invite generation | `channel_sidebar.dart`, `invite_dialog.dart` | Done | Header button / dialog | Server settings → Invite row. Reuses desktop showInviteDialog |
| 104 | Invite link copy | `invite_dialog.dart` | Done | Copy button | Server ID display + link in dialog |
| 105 | Twitch verification toggle | `overview_tab.dart` | Done | Settings toggle | MobileTwitchSettingsRoute: enable/disable |
| 106 | Twitch channel linking | `overview_tab.dart` | Done | Text input + fill | Channel ID + display name + Fill from account |
| 107 | Twitch min follow days | `overview_tab.dart` | Done | Number input | 0 = just follow |
| 108 | Twitch subscription req | `overview_tab.dart` | Done | Toggle | Require sub not just follow |
| 109 | Twitch owner-online | `overview_tab.dart` | Done | Toggle | Only owner accepts joins |
| 110 | Twitch join dialog | `twitch_join_dialog.dart` | Not impl | Multi-step modal | Desktop dialog works cross-platform, needs wiring from server join flow |
| 111 | Twitch badge on member | `member_panel.dart` | Done | Purple icon + username | In MemberTile and MobileProfileSheet |

---

## 14. Profile & Identity

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 112 | Profile card popup | `profile_card_popup.dart` | Done | Hover/click avatar | MobileProfileSheet: banner, avatar, name, status, about, role, labels, Twitch, actions |
| 113 | Edit display name | `user_settings_dialog.dart` | Done | Text field, max 32 chars | Settings → Profile tab |
| 114 | Edit status | `user_settings_dialog.dart` | Done | Text field, max 48 chars | Settings → Profile tab |
| 115 | Edit about me | `user_settings_dialog.dart` | Done | Text area, max 128 chars | Settings → Profile tab, 3 lines |
| 116 | Avatar upload/change | `user_settings_dialog.dart` | Done | File picker → crop (1:1) | Tap avatar in Profile tab. processAvatar FFI |
| 117 | Avatar clear | `user_settings_dialog.dart` | Done | Long-press avatar | Clears pending avatar |
| 118 | Avatar GIF support | `user_settings_dialog.dart` | Done | File picker accepts .gif | Skip crop, raw bytes, max 1MB |
| 119 | Banner upload/change | `user_settings_dialog.dart` | Done | File picker → crop (3:1) | Tap banner in Profile tab. processBanner FFI |
| 120 | Banner clear | `user_settings_dialog.dart` | Done | Long-press banner | Clears pending banner |
| 121 | Banner GIF support | `user_settings_dialog.dart` | Done | File picker accepts .gif | Skip crop, raw bytes, max 2MB |
| 122 | Twitch connect/disconnect | `user_settings_dialog.dart` | Partial | Device code auth button | Disconnect works. Connect shows info toast (device code needs desktop for now) |
| 123 | Peer ID display + copy | `profile_card_popup.dart`, `user_bar.dart` | Done | Tap to copy | Settings → System tab |
| 124 | Recovery phrase display | `mnemonic_dialog.dart` | Done | Modal dialog | Settings → Security tab → Recovery Phrase |
| 125 | Identity creation flow | `welcome_dialog.dart` | Done | First launch dialog | Create / restore mnemonic / restore backup, cross-platform |
| 126 | Restore from mnemonic | `welcome_dialog.dart` | Done | Text input (24 words) | Full validation + Rust identity_api call |
| 127 | Restore from backup | `welcome_dialog.dart` | N/A | File picker + passphrase | Excluded from mobile port |

## 15. Friends & Social

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 128 | Send friend request | `friends_provider.dart`, `profile_card_popup.dart` | Done | Button action | "Add Friend" in profile card |
| 129 | Accept friend request | `friends_provider.dart` | Done | Button action | Accept button |
| 130 | Reject friend request | `friends_provider.dart` | Done | Cross icon | Request rows |
| 131 | Remove friend | `friends_bar.dart` | Done | Remove icon | Long-press friend → Remove Friend with confirmation |
| 132 | Favourite friends | `favourite_friends_provider.dart`, `friends_bar.dart` | Done | Star toggle | Long-press → Favourite/Unfavourite. Pinned section above Online |
| 133 | Local nicknames | `local_nickname_provider.dart`, `profile_card_popup.dart` | Done | Set button in profile card | MobileProfileSheet + long-press friend → Set Nickname |
| 134 | Friends list | `friends_bar.dart`, `mobile_friends_tab.dart` | Done | Horizontal bar / tab | Favourites → Online → Offline sections |
| 135 | Friends manager dialog | `friends_bar.dart` | Done | Full-screen dialog | Friends tab with Requests/Favourites/Online/Offline sections |
| 136 | Add friend dialog | `friends_bar.dart`, `mobile_friends_tab.dart` | Done | Input dialog | Peer ID text field |
| 137 | Pending friend badge | `friends_bar.dart` | Done | Red badge | Count on Friends tab in MobileNavBar |
| 138 | Start DM conversation | `peer_card.dart`, `mobile_friends_tab.dart` | Done | Tap friend | Navigate to DM chat |
| 139 | Friend search/filter | `friends_bar.dart` | Done | Search field | HollowTextField at top, case-insensitive substring |
| 140 | DM unread count | `friends_bar.dart`, `peer_card.dart` | Done | Red badge on avatar | Respects mute |
| 141 | Last message preview | `peer_card.dart` | Done | Text + timestamp | Truncated, "You:" prefix |
| 142 | Encryption status icon | `peer_card.dart` | Done | Green lock icon | E2E cipher active |
| 143 | Online/offline status | `user_bar.dart`, `peers_provider.dart` | Done | Status dot + text | Color-coded |
| 144 | Invisible mode | `settings_provider.dart`, `user_bar.dart` | Done | Toggle | Suppresses typing + online status, provider-level (no UI needed) |

---

## 16. Voice — 1:1 DM Calls

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 145 | Initiate voice call | `call_provider.dart`, `chat_pane.dart` | Done | Phone icon in DM header | Phone icon in mobile_chat_route header, gated on online + not in call |
| 146 | Accept call | `call_provider.dart`, `incoming_call_dialog.dart` | Done | Dialog accept button | MobileIncomingCallOverlay: full-screen, avatar, name, accept/decline, 30s countdown |
| 147 | Reject/decline call | `call_provider.dart`, `incoming_call_dialog.dart` | Done | Dialog decline button | MobileIncomingCallOverlay decline button |
| 148 | Hang up / end call | `call_provider.dart`, `active_call_bar.dart` | Done | phoneOff icon | MobileActiveCallPill hangup button |
| 149 | Video call | `call_provider.dart` | Done | Camera icon in DM | Video icon in mobile_chat_route header |
| 150 | Camera toggle mid-call | `call_provider.dart`, `active_call_bar.dart` | Done | Video icon | Camera button in MobileActiveCallPill |
| 151 | Microphone mute | `call_provider.dart`, `active_call_bar.dart` | Done | Mic icon | Mute button in MobileActiveCallPill |
| 152 | Screen share (DM) | `call_provider.dart`, `active_call_bar.dart` | N/A | Monitor icon + dialog | Sending excluded on mobile per plan |
| 153 | Incoming call dialog | `incoming_call_dialog.dart` | Done | Top-center overlay | MobileIncomingCallOverlay full-screen with avatar, countdown |
| 154 | Incoming call ringtone | `incoming_call_dialog.dart` | Done | Audio playback | Ringtone in MobileIncomingCallOverlay (custom file, trim, loop) |
| 155 | Call duration display | `active_call_bar.dart` | Done | MM:SS in call bar | Duration timer in MobileActiveCallPill |
| 156 | Active call bar (floating) | `active_call_bar.dart` | Done | Draggable pill | MobileActiveCallPill: mute, camera, hangup, timer. Draggable |
| 157 | PiP video view | `call_video_view.dart` | Done | Floating draggable panel | MobileCallVideoView: remote large, local PiP corner, portrait-first |
| 158 | Remote volume control | `call_provider.dart` | Not impl | Slider 0-200% | Low priority — mobile uses system volume |
| 159 | Call stats logging | `call_provider.dart` | Done | Diagnostic | Already fires from callProvider (5s after connect) — no mobile-specific code needed |

## 17. Voice — Server Voice Channels

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 160 | Join voice channel | `voice_channel_provider.dart`, `channel_sidebar.dart` | Done | Click voice channel tile | Mobile: tap voice channel in accordion → instant join + push MobileVoiceChannelRoute |
| 161 | Leave voice channel | `voice_channel_provider.dart`, `voice_channel_panel.dart` | Done | Disconnect button | Mobile: leave button in voice route controls + pill |
| 162 | Participant list | `voice_channel_provider.dart`, `member_panel.dart` | Done | Below channel in sidebar | Mobile: MobileClusteredAvatars grid with speaking indicators |
| 163 | Mute/unmute | `voice_channel_provider.dart`, `voice_channel_panel.dart` | Done | Mic icon | Voice route + pill |
| 164 | Deafen/undeafen | `voice_channel_provider.dart`, `voice_channel_panel.dart` | Done | Headphones icon | Voice route + pill |
| 165 | Camera toggle | `voice_channel_provider.dart`, `voice_channel_panel.dart` | Done | Video icon | Voice route controls + front/back flip |
| 166 | Video grid layout | `voice_channel_pane.dart` | Done | Adaptive grid | Mobile: Wrap grid, adapts to count. PiP for local when remote is main |
| 167 | Video tile fullscreen | `voice_channel_pane.dart` | Done | Tap tile | Remote screen share full-bleed + local PiP |
| 168 | Speaking indicator (VAD) | `voice_channel_pane.dart`, `voice_channel_service.dart` | Done | 2px accent border | MobileSpeakingAvatar with animated teal glow |
| 169 | Screen share (start) | `voice_channel_provider.dart`, `voice_channel_panel.dart` | N/A | Monitor icon + dialog | Desktop only |
| 170 | Screen share (stop) | `voice_channel_provider.dart`, `voice_channel_pane.dart` | N/A | Stop button | |
| 171 | Screen share full-bleed | `voice_channel_pane.dart` | N/A | UI layout | Full-screen presentation |
| 172 | Screen share quality label | `voice_channel_pane.dart` | N/A | UI display | "1080p60", "4K30" etc. |
| 173 | Screen share mixed mode | `voice_channel_pane.dart` | N/A | Source switcher tabs | Camera + screen |
| 174 | Chat overlay in voice | `voice_channel_pane.dart` | N/A | Slide-in 360px panel | Mobile: voice-only view by design, no chat overlay |
| 175 | Controls pill (floating) | `voice_channel_pane.dart` | Done | Bottom-center bar | Mobile: MobileVoiceChannelPill (mute, deafen, leave). Tap returns to voice route |
| 176 | Duration timer | `voice_channel_pane.dart` | Done | MM:SS in controls pill | In voice route top bar + pill |
| 177 | Connection status | `voice_channel_panel.dart` | Done | Green text | Mobile: green status strip cross-server + pill StatusDot |
| 178 | Voice channel panel | `voice_channel_panel.dart` | N/A | Bottom of sidebar | Desktop sidebar element. Mobile: replaced by pill + voice route |

## 18. Voice — Audio Settings

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 179 | Input device selection | `settings_provider.dart`, `user_settings_dialog.dart` | N/A | Dropdown | Mobile uses system default mic |
| 180 | Output device selection | `settings_provider.dart`, `user_settings_dialog.dart` | N/A | Dropdown | Mobile uses system audio routing (speaker/earpiece/bluetooth) |
| 181 | Camera device selection | `settings_provider.dart`, `user_settings_dialog.dart` | Done | Dropdown | Mobile: front/back flip button (switchCamera) in voice route + DM call |
| 182 | Audio quality preset | `settings_provider.dart` | Done | Dropdown | Mobile: 3 pills in Settings > System > Voice & Audio |
| 183 | Microphone gain | `settings_provider.dart` | Done | Slider 0.0-2.0 | Mobile: slider in Settings > System > Voice & Audio |
| 184 | Echo cancellation | `voice_channel_service.dart`, `voice_service.dart` | Done | Audio constraint | Mobile: shown as "Auto" in Settings (always on) |
| 185 | Noise suppression | `voice_channel_service.dart`, `voice_service.dart` | Done | Audio constraint | Mobile: shown as "Auto" in Settings (always on) |
| 186 | Auto gain control | `voice_channel_service.dart`, `voice_service.dart` | Done | Audio constraint | Mobile: shown as "Auto" in Settings (always on) |
| 187 | Ringtone file picker | `settings_provider.dart` | Done | File picker | Mobile: in Settings > System > Ringtone section |
| 188 | Ringtone trim (start/end) | `settings_provider.dart` | Not impl | Slider | Low priority — desktop sliders work cross-platform |
| 189 | Ringtone volume | `settings_provider.dart` | Done | Slider 0.0-1.0 | Mobile: slider in Settings > System > Ringtone section |

## 19. Voice — Encryption & WebRTC

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 190 | SFrame E2EE (DM calls) | `call_provider.dart`, `frame_cryptor_service.dart` | Done | Transparent | Cross-platform — handled by providers |
| 191 | SFrame E2EE (voice channels) | `voice_channel_provider.dart`, `frame_cryptor_service.dart` | Done | Transparent | Cross-platform — handled by providers |
| 192 | SFrame E2EE (screen share) | `call_provider.dart`, `voice_channel_provider.dart` | Done | Transparent | Cross-platform — handled by providers |
| 193 | ICE candidate handling | `voice_service.dart`, `voice_channel_service.dart` | Done | Queued flush | Cross-platform — handled by services |
| 194 | TURN/STUN config | `ice_config_provider.dart` | Done | Auto-refresh 50min | Cross-platform — iceConfigProvider |

---

## 20. Settings — Appearance

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 195 | Theme (dark/light) | `user_settings_dialog.dart` | Not impl | Toggle | **Mobile per plan:** under "Appearance" ASOT section in Settings tab |
| 196 | Custom accent hue | `user_settings_dialog.dart` | Not impl | HSL slider 0-360° | **Mobile:** under "Appearance" section |
| 197 | Accent color presets | `user_settings_dialog.dart` | Not impl | Add/remove saved hues | **Mobile:** under "Appearance" section |
| 198 | Background image | `user_settings_dialog.dart` | Not impl | File picker + crop | **Mobile:** under "Appearance" section |
| 199 | Animations toggle | `user_settings_dialog.dart` | Not impl | Toggle | **Mobile:** under "Appearance" section |

## 21. Settings — Layout

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 200 | Layout mode (dock/classic) | `user_settings_dialog.dart` | N/A | Toggle | Desktop only |
| 201 | Minimize to tray | `user_settings_dialog.dart` | N/A | Toggle | Desktop only |
| 202 | Image quality selection | `settings_provider.dart` | Not impl | Radio buttons | Lossless/Balanced/Small |
| 203 | Auto-download threshold | `settings_provider.dart` | Not impl | Number input (MB) | 34-2048 MB |
| 204 | Vault cache cap | `settings_provider.dart` | Not impl | Number input (MB) | 256-10240 MB |

## 22. Settings — Network

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 205 | Relay domain selection | `user_settings_dialog.dart`, `relay_domain_provider.dart` | Not impl | Dropdown | **Mobile per plan:** under "Network" ASOT section in Settings tab |
| 206 | Custom relay domain entry | `user_settings_dialog.dart` | Not impl | Text input + Add | **Mobile:** under "Network" section |
| 207 | Remove relay from list | `user_settings_dialog.dart` | Not impl | Delete button | **Mobile:** swipe-to-delete in relay list |
| 208 | License key entry | `license_key_dialog.dart` | Not impl | Modal dialog | Shows on startup if relay requires it |

## 23. Settings — Dialogs

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 209 | User settings dialog | `user_settings_dialog.dart` | Partial | 5-tab modal | **Mobile per plan:** Settings tab replaces dialog. ASOT-style sections: Profile, Appearance, Network, Data, About. Scrollable, full-width dividers |
| 210 | Image crop dialog | `image_crop_dialog.dart` | Not impl | Modal with ratio | 1:1 (avatar) or 3:1 (banner) |
| 211 | Screen share picker dialog | `screen_share_dialog.dart` | N/A | Modal | Screens/windows, res, fps, audio |
| 212 | Storage dashboard dialog | `storage_dashboard_dialog.dart` | Not impl | Modal | Cache, vault, DB usage |
| 213 | Paste link dialog | `paste_link_dialog.dart` | Not impl | Modal | `hollow://` deep link navigation |

---

## 24. Archive & Data

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 214 | Archive dashboard | `archive_dashboard.dart` | Partial | Tab switcher | **Mobile per plan:** Archive tab (3rd bottom tab). My Data + Imported as sub-tabs or sections |
| 215 | My data view | `my_data_view.dart` | Not impl | Two-panel layout | **Mobile:** single-panel list → tap conversation → push viewer. Export per-DM/channel/server |
| 216 | Conversation list | `archive_conversation_list.dart` | Not impl | Searchable panel | DMs + channels by server |
| 217 | Message viewer | `archive_message_viewer.dart` | Not impl | Read-only display | Full history |
| 218 | DM export | `export_archive_dialog.dart` | Not impl | Right-click → Export | `.hollow-archive` file |
| 219 | Channel export | `export_archive_dialog.dart` | Not impl | Right-click → Export | Single or multi-channel |
| 220 | Server export | `export_archive_dialog.dart` | Not impl | Header → Export | All channels |
| 221 | Export mode (full/text) | `export_archive_dialog.dart` | Not impl | Radio buttons | With/without attachments |
| 222 | Hidden DM management | `archive_conversation_list.dart` | Not impl | Eye toggle | Hide/unhide in archive |
| 223 | Imported archives view | `imported_archives_view.dart` | Not impl | Right panel | Browse + search + verify |
| 224 | Archive search | `archive_conversation_list.dart` | Not impl | Search field | Case-insensitive contains |

## 25. Vault & Recovery

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 225 | Vault files view | `vault_files_view.dart` | Not impl | Right panel | Per-server shard status |
| 226 | Recovery pool join | `recovery_pool_dialog.dart` | Not impl | Join button → dialog | Phrase + shards |
| 227 | Recovery pool dashboard | `recovery_pool_dashboard.dart` | Not impl | Right panel | Status, shard distribution |
| 228 | Shard bundle dialog | `shard_bundle_dialog.dart` | Not impl | Upload modal | |

## 26. Share System

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 229 | Share card display | `share_card.dart` | N/A | In-chat card | **Mobile per plan:** Share excluded (STUN-only, dead on mobile CGNAT). HollowLinkCard shows but download won't work mobile↔mobile |
| 230 | Share dashboard | `share_dashboard.dart` | N/A | Full panel | **Mobile per plan:** Share system excluded from mobile |

---

## 27. Notifications

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 231 | System tray notifications | `system_notification_provider.dart` | Not impl | Native OS toast | **Mobile per plan (post-launch):** needs FCM (Android) / APNs (iOS). `local_notifier` is desktop-only |
| 232 | In-app notification overlay | `notification_overlay.dart` | Not impl | Card popup in chat | **Mobile:** toast-style notification when in different chat |
| 233 | In-app toast (success) | `hollow_toast.dart` | Done | Green slide-up | Auto-dismiss 3s, all three types used on mobile |
| 234 | In-app toast (error) | `hollow_toast.dart` | Done | Red slide-up | Auto-dismiss 3s |
| 235 | In-app toast (info) | `hollow_toast.dart` | Done | Blue slide-up | Auto-dismiss 3s |
| 236 | Unread badge (per DM) | `unread_provider.dart` | Done | Red pill with count | In conversation list |
| 237 | Unread badge (per channel) | `unread_provider.dart` | Done | Red pill with count | In server accordion channel row |
| 238 | Unread badge (per server) | `unread_provider.dart` | Done | Red pill with count | On server row in conversation list |
| 239 | Unread badge (home button) | `server_strip.dart` | Not impl | Pill on home icon | Total DM unread |
| 240 | Notification level (server) | `notification_provider.dart` | Not impl | Dropdown | All/Mentions/Muted |
| 241 | Notification level (channel) | `notification_provider.dart` | Not impl | Dropdown | Inherit/All/Mentions/Muted |
| 242 | Mute DM notifications | `notification_provider.dart` | Done | Toggle | Per-DM. Bell icon in DM header (implemented in Section 6 #51) |

---

## 28. Shell & Navigation

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 243 | Server strip (classic) | `server_strip.dart` | N/A | Vertical icon bar 72px | Mobile: replaced by unified conversation list with server accordion in Chats tab |
| 244 | Server strip reordering | `server_strip.dart` | N/A | Long-press drag | Desktop only — mobile uses conversation list ordering |
| 245 | Server folders | `server_strip.dart`, `server_folder_popup.dart` | N/A | Drag server onto another | Desktop only |
| 246 | Friends bar (dock) | `friends_bar.dart` | N/A | Horizontal 44px | Desktop dock only — mobile has Friends tab |
| 247 | Bottom bar (dock) | `bottom_bar.dart` | N/A | Horizontal 56px | Desktop dock only — mobile has 4-tab MobileNavBar |
| 248 | Channel sidebar | `channel_sidebar.dart` | N/A | Left panel 240px | Desktop panel. Mobile equivalent is server accordion in Chats tab (Done, see #89) |
| 249 | Member panel | `member_panel.dart` | N/A | Right panel 240px | Duplicate → see #92 (Section 12). Mobile: bottom sheet |
| 250 | User bar (classic) | `user_bar.dart` | N/A | Bottom of sidebar | Desktop only. Mobile: peer ID + settings in Settings tab |
| 251 | Home dashboard (dock) | `home_dashboard.dart` | Not impl | 3-column layout | **Mobile per plan:** demoted to section in Settings tab under Network/About, not a dedicated tab |
| 252 | Voice channel panel | `voice_channel_panel.dart` | N/A | Bottom of sidebar | Duplicate → see #178 (Section 17). Desktop sidebar element |
| 253 | Mobile shell (4-tab) | `mobile_shell.dart` | Done | Bottom nav | Chats/Friends/Archive/Settings |
| 254 | Mobile chat route | `mobile_chat_route.dart` | Done | Push onto navigator | Back button, input bar |

## 29. Window & Desktop Chrome

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 255 | Custom title bar | `window_title_bar.dart` | N/A | 32px chrome | Hollow branding, drag-to-move |
| 256 | Minimize button | `window_title_bar.dart` | N/A | Click | Minimize / tray |
| 257 | Maximize button | `window_title_bar.dart` | N/A | Click | Toggle maximize |
| 258 | Close button | `window_title_bar.dart` | N/A | Click | Close / tray based on setting |
| 259 | Resize handles | `hollow_shell.dart` | N/A | Edge drag | DragToResizeArea |

## 30. Animations & Visual Effects

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 260 | Startup reveal | `startup_reveal.dart` | Not impl | Auto-play | 2.5s staggered fade+slide |
| 261 | Ambient background blobs | `ambient_background.dart` | Not impl | Auto-play ~15fps | Teal+purple, 45s figure-8 |
| 262 | Panel slide animations | `hollow_shell.dart` | Not impl | On open/close | Slide+fade+clip |
| 263 | Crossfade view switching | `hollow_shell.dart` | Not impl | AnimatedSwitcher | Pane transitions |
| 264 | Tooltip fade+slide | `hollow_tooltip.dart` | Not impl | 400ms hover | 100ms fade + 4px slide |
| 265 | Toast slide+fade | `hollow_toast.dart` | Done | Auto-dismiss | Slide up + fade out, works on mobile |
| 266 | Selection shimmer | `selection_shimmer.dart` | Not impl | Text selection | Shimmer during multi-message select |

## 31. Components (Reusable)

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 267 | HollowAvatar | `hollow_avatar.dart` | Done | Circular image | Lazy-load, initials fallback, GIF |
| 268 | HollowButton | `hollow_button.dart` | Done | Click | filled/ghost/outline/danger variants |
| 269 | HollowTextField | `hollow_text_field.dart` | Done | Text input | Border animation, error state |
| 270 | HollowPressable | `hollow_pressable.dart` | Done | Press | Opacity+scale spring, hover is no-op on touch |
| 271 | HollowDialog | `hollow_dialog.dart` | Done | Modal | Scale+fade, glassmorphism blur, cross-platform |
| 272 | HollowToggle | `hollow_toggle.dart` | Not impl | Click | Spring thumb, color crossfade |
| 273 | HollowTooltip | `hollow_tooltip.dart` | N/A | 400ms hover | Desktop hover only |
| 274 | HollowToast | `hollow_toast.dart` | Done | Auto-dismiss | Success/error/info, all used on mobile |
| 275 | HollowCard | `hollow_card.dart` | Not impl | Container | Elevated, bordered, rounded |
| 276 | StatusDot | `status_dot.dart` | Done | Visual indicator | Optional pulse glow |
| 277 | ConnectionProgress | `connection_progress.dart` | Not impl | Display | Widget is cross-platform but not wired into mobile chat |

## 32. Context Menus

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 278 | Message context menu | `message_action_bar.dart`, `mobile_message_actions.dart` | Done | Long-press → bottom sheet | Edit/delete/react/reply/copy (pin/info pending) |
| 279 | Channel context menu | `channel_sidebar.dart` | Not impl | Right-click channel | **Mobile:** long-press channel in accordion → bottom sheet (mute/notify/export/delete) |
| 280 | DM context menu | `chat_pane.dart` | Not impl | Right-click DM | **Mobile:** long-press DM in Chats list → bottom sheet (mute/notify/export/block/delete) |
| 281 | Server context menu | `server_strip.dart` | Not impl | Right-click server | **Mobile per plan:** long-press server row → bottom sheet (Settings/Invite/Members/Leave) |
| 282 | Server folder context menu | `server_folder_popup.dart` | N/A | Right-click folder | Desktop only — no server folders on mobile |
| 283 | Bottom bar server context menu | `bottom_bar.dart` | N/A | Right-click server | Desktop dock only |

## 33. Miscellaneous

| # | Feature | Desktop File(s) | Mobile | Interaction | Notes |
|---|---------|-----------------|--------|-------------|-------|
| 284 | Update checker | `updater_provider.dart` | N/A | Background | **Mobile:** app store handles updates |
| 285 | News/blog display | `news_provider.dart` | Not impl | Home dashboard | **Mobile per plan:** in Settings tab under About section |
| 286 | Relay stats display | `relay_stats_provider.dart` | Not impl | Home network column | **Mobile per plan:** in Settings tab under Network section |
| 287 | Animated GIF display | `animated_gif_image.dart` | Done | Auto-play | Frame decode via instantiateImageCodec, used in mobile profile |
| 288 | Responsive layout | `hollow_shell.dart` | Done | LayoutBuilder | <600 mobile, 600-1024 tablet, 1024+ desktop |

---

## Summary

| Category | Total | Done | Partial | Not Impl | N/A |
|----------|-------|------|---------|----------|-----|
| All features | 288 | 182 | 3 | 56 | 47 |

**Actionable (excl. N/A): 241 total, 182 Done (75%), 3 Partial, 56 Not impl.**

*Updated 2026-05-29. Sections 12-19 complete.*

### Session 2026-05-29 Progress
- **Sections 17-19 complete.** Voice channels: join/leave/mute/deafen/camera/video/speaking indicators, floating pill, cross-server status strip. Audio settings in System tab. E2EE/WebRTC transparent cross-platform.
- **New files:** mobile_voice_channel_route.dart, mobile_voice_channel_pill.dart, mobile_voice_avatars.dart (shared widgets extracted from DM call).
- **Modified:** mobile_chats_tab.dart (voice channel tap → join), mobile_shell.dart (VC pill), mobile_chat_route.dart (VC status strip), mobile_settings_tab.dart (audio settings), mobile_call_video_view.dart (refactored to shared widgets), voice_channel_service.dart (switchCamera), voice_channel_provider.dart (switchCamera).
- **Exclusions:** Screen share sending (#169-171, 173 → N/A), Chat overlay (#174 → N/A, voice-only view), Voice channel panel (#178 → N/A, replaced by pill), Ringtone trim (#188 → low priority).

### Session 2026-05-28 Progress (continued)
- **Section 16 complete.** 1:1 DM calls: phone/video icons in header, full-screen incoming call overlay, floating active call pill, PiP video view.
- **New files:** mobile_incoming_call.dart, mobile_active_call_pill.dart, mobile_call_video_view.dart.
- **Modified:** mobile_chat_route.dart (call buttons in DM header), mobile_shell.dart (call overlays in Stack).
- **Exclusions:** Screen share sending (#152 → N/A), Remote volume (#158 → low priority).

### Session 2026-05-28 Progress
- **Sections 12-15 complete.** Members & Roles, Invitations & Twitch, Profile & Identity, Friends & Social.
- **Member panel:** DraggableScrollableSheet from users icon in channel chat header. Role-grouped (Owner/Admin/Moderator/Members → Online/Offline). Tap member → MobileProfileSheet with role badge, labels, Twitch badge, actions (Message, Set Nickname, Add Friend).
- **Server settings expanded:** Drill-down rows for Members, Roles, Labels, Twitch, Invite. MobileMembersRoute (long-press role change/kick/ban, banned section). MobileRolesRoute (3 role cards, 6 permission toggles). MobileLabelsRoute (self-assign + manage/create/delete/assign members).
- **Settings tab restructured:** Pill tab bar (Profile, System, Security, About). Profile tab: avatar/banner upload+crop+GIF, display name, status, about me, Twitch connect. System tab: Peer ID, network status. Security tab: password protection, device protection, recovery phrase. About tab: version, license, links.
- **Friends tab enhanced:** Search field, Favourites section (star icon, pinned above Online), long-press actions (Message, View Profile, Favourite, Set Nickname, Remove Friend).
- **New files:** mobile_profile_sheet.dart, mobile_member_panel.dart, mobile_members_route.dart, mobile_roles_route.dart, mobile_labels_route.dart, mobile_twitch_settings_route.dart.
- **Exclusions confirmed:** Identity export (#127 → N/A), Server template (#81 → low priority).

### Session 2026-05-14 Progress
- **Sections 1-8 complete or audited.** Section 6 fully done. Voice messages, search, mute, unread badges, notification dedup rework.
- **Desktop fix:** Channel notification dedup reworked from timer-based to message-ID-based (Rust + Dart). Channel sidebar upgraded to red numbered badges.
- **Mobile:** Full unread system (DM + channel + server), voice recording, in-channel search, per-DM mute, scroll-to-bottom pill, channel key fix, initial scroll fix, provider management fix.
- **Dedup cleanup:** Removed 8 duplicate entries from Sections 7 and 28 (call buttons/panel → Sec 16, member panel → Sec 12, voice panel → Sec 17, channel sidebar/user bar → N/A desktop-only). #242 per-DM mute corrected to Done.
