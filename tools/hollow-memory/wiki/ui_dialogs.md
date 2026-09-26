# Dialogs -- All Modal Dialogs

Every modal dialog in the project. Most live under `lib/src/ui/dialogs/`; the shared layer (confirm, name prompt, duration, copy field, one-wording helpers) is the next section. Every modal opens with `showHollowDialog()` from `lib/src/ui/components/hollow_dialog.dart`: a scale 0.96->1.0 + fade entrance over the flat `HollowTheme.scrim` (65% black dark, 32% light; NO backdrop blur since design sweep 8, 2026-09-19). The frame is always `HollowDialogSurface` (overlay, hairline, 12 px shadow, radiusLg desktop / radiusXl + full width on a phone); a standard dialog is `HollowDialog` (title in `heading`, sentence case; `showClose`, `leadingActions`, `width`, `busy`, `error`, `scrollable`); a yes-or-no question is `showHollowConfirm()`, a one-field name `promptForName()`, and an action runs INSIDE the dialog. Raw `showDialog`/`showGeneralDialog` and hand-drawn frames are CI-guarded (`design_language_guard_test.dart`). Rules: `reports/reference/HOLLOW_DESIGN_LANGUAGE.md` 4.4.

**Dialogs never enter the Dock header (2026-09-26).** `showHollowDialog` builds every dialog inside `DialogChromeSlot` (`hollow_dialog.dart`): while the Dock owns the window chrome (`windowChromeTop(ref)` = `kDockHeaderHeight`, 44 px, 0 in fullscreen, annotation and Classic) the dialog is padded down by the header and `MediaQuery.size` is shrunk to the slot below it, so a dialog that centres, sizes or scrolls from "the screen" can never reach the pinned friends or the window controls. The scrim still covers the whole window. Two traps it guards: the builder runs INSIDE the slot (`Builder(builder: builder)`; called with the route's outer context it measured the whole window), and the slot sits INNERMOST, below `MediaQuery.removeViewInsets` (which rebuilds MediaQuery from the outer context and would restore the full size). Pinned by `test/widget/dialog_chrome_slot_test.dart`; the media viewer pads itself by the same `windowChromeTop()`.

---

## The shared dialog layer (2026-09-25)

Built by design language session 24 (the dialogs pass); rules in `HOLLOW_DESIGN_LANGUAGE.md` 4.1, 4.2, 4.4. The one law: **a dialog that acts runs the action INSIDE itself** (confirm loading, Cancel disabled, scrim/Escape/X blocked, close on success, the reason shown in the dialog on a throw so the person can retry). Never pop first and await after.

### Primitives (`lib/src/ui/components/`)
- **`showHollowConfirm(..., onConfirm:)`** (`hollow_dialog.dart`): the one yes-or-no. Ghost Cancel + ONE filled confirm, `danger` only when `destructive`. With `onConfirm` it runs the action in the dialog (above) and resolves true only once it finished; the error line is `friendlyError(e)`.
- **`promptForName(title:, confirmLabel:, hintText, initial, description, maxLength, validator, allowEmpty, onSubmit)`** (`hollow_dialog.dart`): the one "type a name" dialog, width 420, owns its controller, autofocus, Enter submits, confirm disabled while empty (unless `allowEmpty`). `validator` returns the field's error, checked on submit; `onSubmit` runs inside, and a throw lands on the FIELD with the typed text kept. Resolves to the trimmed name or null.
- **`HollowDialogAction`** mixin (`hollow_dialog.dart`): `runDialogAction(action, fallback:)` → true on success; sets `actionRunning` / `actionError` (a `friendlyError` sentence). Running stays on after success so the confirm keeps its spinner through the exit; a dialog that moves to a second step resets it itself. Pair with **`HollowDialog(busy:, error:)`**: `busy` wraps the dialog in `PopScope(canPop: false)`; `error` is one live-region line above the actions (a failure that belongs to one field goes on that field's `errorText` instead). **`HollowDialog(scrollable: false)`** for content that scrolls itself (a nested scroll view in the default one never scrolls).
- **`HollowButtonTouchScope`** (`hollow_button.dart`): an InheritedWidget that turns on `HollowButton.touch` below it. `HollowDialog` wraps its action row in it on a compact screen, and `HollowDialogCloseButton` goes 44, so phone dialogs get touch-size actions without a call site passing `touch:`. Custom-layout dialogs (screen share, image crop) wrap their own action row the same way.
- **Disabled buttons are neutral at full opacity**: label `textTertiary`, a faint `textPrimary` 8% fill for filled/danger, a `textTertiary` 40% hairline for outline, never a faded accent (a 40% fade of a 40% outline vanished on light). Loading is not disabled: same colours, a spinner.
- **`friendlyError(e, {fallback})` + `FriendlyException`** (`lib/src/core/friendly_error.dart`): the sentence a person sees. First-match rules map locked identity, node not running, disk full, rate limit, timeout, relay/network, access denied, permission, not found, already exists, too large, invalid to one plain line with a next step; a Rust (`String`/`AnyhowException`) message that already reads as a sentence passes through; else `fallback` or `kGenericErrorSentence` ("Something went wrong. Try again."). The raw text goes to `hollow_debug.log` via `logFromDart`. Throw `FriendlyException('...')` for a specific sentence (it is shown verbatim). **Guard:** `design_language_guard_test.dart` "toasts do not show a raw exception" counts `$e`-style interpolations in toasts, ratcheted by `_rawExceptionToastBaseline` (3 since 2026-09-26).
- **`HollowCopyField`** (`hollow_copy_field.dart`): a value to copy (link, code, id): the value in `textPrimary` on `elevated`, mono unless `mono: false`, a labelled copy button ("Copy <label/name>") that toasts "Copied"; `label` puts a `SettingsFieldLabel` above; `wrap: false` keeps one line with an ellipsis (links); `copyValue` when the clipboard differs from the display. The one legitimate well: never a card, never accent text.
- **`HollowChipTabs<T>`** (`hollow_chip_tabs.dart`, `HollowChipTab(value, label, hint, count, icon)`): EVERY tab row (dialog, page, place header) is a `HollowChip` row, 8 apart, one selected; `hint` a quiet total, `count` a `HollowCountBadge` for something waiting on the person (`HollowChip` gained `count:` and `focusNode:`); Left/Right/Home/End move and select; `expand: true` equal widths on a phone, else it wraps. No underline tabs, no local `_Tab`. Users: Friends Manager, screen share, Share, Archive, `place_header.dart`.
- **`HollowDurationPicker`** + **`showHollowDurationDialog(title, message, confirmLabel, onConfirm(Duration?))`** (`hollow_duration_picker.dart`): the ONE "for how long" choice, a chip row of `kHollowDurationPresets` (10 min, 15 min, 1 h, 24 h, 7 days, null). Null = "Until I remove it", a choice like any other, never a red "Permanent". `hollowDurationLabel` words it for toasts ("until I remove it"). The dialog runs `onConfirm` inside. Users: mute (`moderation_dialogs.dart`), `channel_grants_dialog.dart`, `manage_member_dialog.dart`.
- **`LabelChip` / `LabelBadge` / `LabelSwatch`** (`label_visuals.dart`): a label that toggles is `LabelChip` (a `HollowChip` led by the label's colour; `locked` dims it and swaps the swatch for a lock but still fires `onTap` so the caller can say why); a label someone wears is `LabelBadge` (a `HollowBadge`, never clickable). `LabelTypeChip` = the Cosmetic/Access selector. No private label chips.
- **`HollowListRow` flush + `HollowBleed`** (`hollow_list_row.dart`): `flush` (null follows the nearest `HollowFlushRows`, which a PADDED `HollowDialogSurface` provides) puts the row's content on the surrounding text edge and bleeds its hover fill out by `insetOf(touch:)` (12, 16 touch). `HollowBleed(horizontal:)` is the negative margin Flutter lacks: `HollowDialog` widens its scroll view with it so the hover is not clipped at the text edge; a custom list in a dialog (New message, message proof's `MessageRow`, the Friends Manager drag lift) does the same.
- **`HollowIconButton(onMedia: true)`** (`hollow_icon_button.dart`): an icon button over art (a banner, key art, a wide artwork): a round dark scrim that lifts on hover within its own circle, a 16 px white glyph. Only over a real picture; over a flat surface use the plain button (`MediaScrimIconButton` in `profile_identity_column.dart` picks).
- **`HollowSheetTitle(title, subtitle:)`** (`hollow_sheet.dart`): the name at the top of a phone action sheet (the person, server, channel or message the rows act on): start-aligned `subheading`, one line, full width so a centred sheet column still starts it on the rows' edge.

### One-wording helpers (every surface, desktop and phone, calls the same one)
- **`confirmDeleteChannel(context, serverId:, channelId:, channelName:)`** (`server_settings/delete_channel_confirm.dart`): "Delete #name?", `kDeleteChannelMessage`, danger "Delete channel", `removeChannel` inside; then `onChannelRemoved` + toast. Reads the ProviderContainer, not a ref (the menu that opened it may be gone).
- **`confirmLeaveServer` / `confirmDeleteServer(context, ref, serverId)`** (`server_settings/server_settings_catalog.dart`): "Leave <name>?" ("You'll need a new invite to come back.", danger "Leave server") / "Delete <name>?" (danger "Delete server"); the FFI runs inside; then a toast and `_afterServerGone` (closes its Server settings, deselects it, pops the phone back to its shell).
- **`confirmRemoveFriend(context, ref, peerId:, name:)`** (`dialogs/confirm_remove_friend.dart`): see Friends Manager below.
- **`showLocalNicknameDialog(context, ref, peerId, currentNickname:)`** (`components/profile_card_body.dart`): `promptForName` "Set nickname", "Only you see it.", max 32, empty clears, `setNickname` inside; toast "Nickname set" / "Nickname cleared".
- **`confirmVoiceRoomSwitch(context, ref, serverId:, channelId:, channelName:)`** + **`voiceSwitchLeavesPeople(vc, ...)`** (`shell/voice_room_switch.dart`): a voice-room join asks "Switch voice room?" ("You'll leave #a and join #b.", filled "Switch") ONLY when it would leave someone else behind (current room has a participant other than our master or device id; the sets are DEVICE-keyed). An empty room, or the same room, never asks. Called by the sidebar, Home rail, voice pane and phone Chats.
- **`confirmClearLabelGate(context, channelName:, tier:, forVisibility:)`** (`shell/channel_context_menus.dart`): "Drop the access labels?" before a plain tier replaces a channel's access labels (it lets more people in); confirm "Open to everyone" / "Open to Moderator and above" (`accessTierLabel`). Desktop menu + phone sheet.
- **`showAccessLabelPicker(context, serverId:, initial:, gate:, target:)`** (`settings/access_label_picker.dart`): `AccessLabelGate { see, post }`; the title comes from `accessLabelPickerTitle` ("Who can see #general" / "Who can post in the channels in General"), never the caller (`title:` is deprecated). Returns the label-id set (empty = back to tier mode) or null.
- **`showChangeRoleDialog(context, ref, serverId:, peerId:, displayName:, newRole:, currentRole:)`** (`settings/moderation_dialogs.dart`): THE role confirm (Members page, member menu, Manage member): "Make Mira an admin?", "They go from Member to Admin, which changes what they can do here.", filled "Make admin", `changeMemberRole` inside, toast "<name> is now Admin". Kick/ban/mute in the same file share its `_confirmAndRun` shape.
- **`renameChannelFlow(context, ref, serverId, channel, onRenamed:)`** (`shell/channel_context_menus.dart`): `promptForName` "Rename channel", max 32, `renameChannel` inside (the prompt keeps the typed name on failure); a no-op when unchanged; toast "Channel renamed". Desktop menu + phone sheet.
- **`showPinnedMessages(context, serverId:, channelId:, pinnedIds:, messages:, preview:, onJump:, touch:)`** (`chat/pinned_messages.dart`): a dialog on desktop, a sheet (with `HollowSheetTitle`) on the phone; newest first, "N more pinned messages are further back in this channel." for unloaded pins; a row jumps; whoever may pin gets a grey **Unpin** per row (hover/focus on desktop, always on touch; optimistic, back if it fails); unpinning the LAST pin closes the list.
- **`askSecretDialog(context, title:, ask:, confirmLabel:, onSubmit(current, next), message:, isPin:)`** (`settings/security_section.dart`): the app password / PIN prompt. `SecretAsk { current, create, change }`; `onSubmit` runs inside; a wrong current secret lands on its field; nothing typed is lost; secret fields in dialogs are one height.
- **`shell/identity_unlock_dialogs.dart`**: `UnlockDialog` (launch + app lock) and `RecoveryPhraseDialog`, see "Keyboard-Aware & Phone-Adaptive Dialogs" below.

### Removed
- `dialogs/browse_public_dialog.dart` (`showBrowsePublicDialog`, dead: guest browsing is the Browse Public Channels tab, `ShellTab.guest`).
- The phone Chats tab's "New" dialog (`NewConversationDialog` / `showNewConversationDialog` in `mobile_chats_tab.dart`); its add-server entry now opens `showCreateServerDialog`.
- Per-site confirm/rename/nickname/pledge/retention dialogs that the helpers above replaced.
- `dialogs/storage_dashboard_dialog.dart` and `mobile/mobile_storage_route.dart` (2026-09-26): the storage dashboard became Server settings > Files & storage, a page (wiki `ui_server_settings`). The pledge is a slider and retention a chip menu there, so `editStoragePledge` / `editRetentionPolicy` went with them.

---

## WelcomeDialog -- First-launch Onboarding

**File:** `lib/src/ui/dialogs/welcome_dialog.dart`
**Rebuilt 2026-09-26** to the approved mockup (canvas "Hollow profile, game card and the dialog redesigns").
**Trigger:** Called by the bootstrap flow when no identity exists on disk. That is first launch AND the state you land on after erasing the running profile (see `project_profile_switcher_issue47`).
**Entry point:** `showWelcomeDialog(BuildContext context)` -- returns `Future<WelcomeResult?>`, a record `({String action, String relayDomain})`.
**Barrier:** Non-dismissible (`barrierDismissible: false`).

### Return values
- `'create_new'` -- "Create an identity"
- `'link_device'` -- Link a device (creates a THROWAWAY identity just to connect; hollow_shell handles the rest)
- `'restored_backup'` -- identity imported from a .hollow backup file
- `null` -- dismissed without selection (should not happen)

`relayDomain` rides alongside every action: the relay field lets a self-hoster set the relay before the identity exists, and hollow_shell applies it via `relayDomainProvider` + `savedRelayListProvider` when it differs from `kDefaultRelayDomain`.

**Restore from Recovery Phrase stays OFF Welcome** (Step 9C/C6, confirmed again 2026-09-26). A 24-word phrase alone regenerates the master keypair but carries NO synced data, and a stale messages.db on disk caused a "Loading… forever" mismatch. Use Link a device or Restore from a backup. The mnemonic-restore FFI still serves the in-app recovery dialogs.

### The frame: `WelcomeFrame` (`dialogs/welcome_frame.dart`)
The ONE surface Welcome and the first-run link steps share, so moving between them reads as one flow: a fixed-width (~440) `HollowDialogSurface` on desktop, the whole screen on a phone with the actions (`bottom`) in the thumb zone. An optional header (back arrow + title) for every step after the first. `WelcomeActions` lays the buttons out trailing and 8 apart on desktop, full width and stacked on a phone, primary last. `WelcomeFrame.isPhone(context)`.

### Steps, all IN PLACE in one frame (never a stacked dialog)
- **First run:** logo mark, "Welcome to Hollow" (`display`), two short paragraphs ("Your identity is made on this device and stays with you. There is no account and nobody to sign in to." / "Next, Hollow shows your recovery phrase. Write it down and keep it somewhere safe."), ONE filled full-width "Create an identity", then "Already use Hollow?" and two grey `HollowListRow`s: "Link a device" ("Enter a 6-character code from your other device") and "Restore from a backup" ("Open a .hollow file you saved earlier"). Footer ghost controls (32 px, 44 on a phone): "Other profiles (N)" (desktop only, when N > 0) and the relay domain button (semantics "Change the relay").
- **Relay:** the relay button opens the field in place ("Relay address", a help line); an invalid address is an error line at the field, never a toast.
- **Restore:** `FilePicker` filtered to `.hollow` (`FileType.any` on iOS/Android, where the custom extension would HIDE the file), then a file row (name, size, saved date), "Choose another file", a labelled passphrase field with show/hide, and filled "Restore". The passphrase is NEVER trimmed (Enter and the button pass the same raw string). While `importBackup` runs: Restore loading, the field disabled, one line ("This can take a minute"); a wrong passphrase is `friendlyError` at the field. Pops `'restored_backup'` on success.

### Profile switcher (issue #47 follow-up, 2026-08-21)

Desktop-only, for the same reason the Settings card is (sandboxed mobile roots; the iOS NSE opens one fixed App Group DB path).

- `_allProfiles` = `listProfileRows(readProfileRegistrySync())` -- the SAME shared list Settings renders.
- `_otherProfiles` = rows that are not `runningProfileRoot()` and where `profileHasIdentity(path)` is true. The profile line and the switcher are gated on this being non-empty, so a genuine first-ever launch sees none of it.
- **Profile line:** which profile is being set up; `_currentProfileName` matches the running root against the row list and falls back to the last path segment (an env override or a folder added on another machine is not in the list, and must not claim to be "Default"). This line is also the answer to "where did my restored backup go": `import_backup` writes to the ACTIVE `identity::data_dir()`.
- **"Other profiles (N)"** opens the list in place: each other profile with name, mono path and a compact outline **Switch**. Switch = pin in `profiles.json` (explicitly, even for Default: the pin has to beat portable auto-detection) then `relaunchApp()`. "Switching restarts Hollow. This folder stays as it is." When `dataDirEnvOverrideActive` the footer warns that `HOLLOW_DATA_DIR` overrides the selection.

### FFI calls
- `storage_api.importBackup(backupPath:, passphrase:)`

### The receiving side of Link a device (`dialogs/device_link_dialog.dart`)
After Welcome pops `'link_device'` the node starts (the "Connecting" placeholder, `_ConnectingContent`), then `DeviceLinkMode.enterCode` runs. Every phase draws in `WelcomeFrame` so it reads as the same card; the mechanism is unchanged (the dialog pops `true` to go back to Welcome, the import runs pre-node-start after a restart, `relaunchApp()` does the restart, never an in-place import). Code entry = `LinkCodeField`: six mono slots over one invisible `TextField` (paste works, letters and digits only, case-insensitive, Enter submits, the `hint:ABC123` probe target still resolves); Link is neutral-disabled until 6. Offline: a spinner line "Connecting to the relay. You can type the code meanwhile." and Link goes loading when pressed, submitting once the relay connects. Then waiting (spinner, approve on the other device), receiving (`HollowProgressBar` + a tabular "41 of 66 MB" line), importing (spinner), failed (the reason, ghost Back + filled Try again), Linked (counts down from 3, then restarts; filled Restart now). The SENDING side keeps its own dialogs (session 24 polish). Tests: `test/widget/device_link_dialog_test.dart`, `test/widget/welcome_link_code_copy_test.dart`; renders `test/screenshots/redesign_after_welcome_screenshot_test.dart`.

---

## CreateServerDialog -- Add a server (join or create)

**File:** `lib/src/ui/dialogs/create_server_dialog.dart`
**Trigger:** plus in the server strip, the dock (`bottom_bar.dart`), Home, the phone nav's centre button ("Add a server") and Chats tab.
**Entry point:** `showCreateServerDialog(BuildContext context)` -- void. The phone opens the same dialog, stacked.

### Layout (`_AddServerDialog`, ConsumerStatefulWidget)
`HollowDialog(title: 'Add a server', showClose: true, width: 600, busy: _busy)`. Two halves, each a `HollowSectionHeader` with its own form and its own action. A person picks one, never both, so neither outranks the other: **both buttons are `outline`** (no filled).
- **Join a server** ("Paste an invite link or server ID."): mono `HollowTextField` "Invite link or server ID" (autofocus off on compact) + outline "Join".
- **Start your own** ("A new server of yours. Invite people once it is made."): field "My Awesome Server" + outline "Create".
- Desktop: side by side with a `HollowVerticalDivider`; headers and forms are two separate `IntrinsicHeight` rows so a wrapping description never pushes one side's field below the other's. Compact: stacked, `HollowDivider` between.
- Each button is disabled while its field is empty or the other half runs; `onSubmitted` on each field acts too.

### The work runs inside the dialog
- `_join()`: `inviteFromInput(input, HollowLinkType.serverInvite)` (`hollow_link_utils.dart`; accepts `hollow://join?server=`, web `https://hollow.anonlisten.com/join#server=` fragment or query, or a raw id), then **`isServerIdShape(id)` (32 hex) or the field says "That isn't an invite link or server ID. Check what you pasted."** (a typo used to park a join nobody could answer; a well-formed id of a server that never existed still parks, the relay keeps no server list). Then `ensureRelayForInviteId` (below; false = the switch dialog restarted or was declined, the dialog stays) and `crdt_api.joinServer(serverId: id.toLowerCase(), nsfwConfirmed: false)`. Join loads on its button; a throw lands on the join field via `friendlyError` (fallback "Couldn't join that server. Check the link and try again."). Success pops, then toasts "Joining server..." on the navigator overlay (`_closeWith`; only queued, the server appears once a member admits us).
- `_create()`: `crdt_api.createServer(name:)`, loading on Create, error on the name field (fallback "Couldn't create the server. Try again."), success pops + "Server created".
- `busy` blocks scrim, Escape and the X while either runs.

**Relay hint:** every invite builder (`webServerInviteLink`, `webConferenceInviteLink`, `roomInviteLink`) takes `required relay:` and stamps the SENDER's relay; a hint that differs from `relayDomainProvider` opens the ONE dialog in `relay_switch_dialog.dart` ("This server lives on another relay", ghost Cancel, filled "Switch and restart"), NEVER an auto-switch. On confirm the canonical link is parked under the setting `pending_invite_after_switch`, the relay is switched, the app exits, and `_bootstrap` replays it once through `DeepLinkService.handleUrl` after the node starts. The in-chat Join card shows `On <host>` for a differing relay. The guest sidebar's join bar applies the same 32-hex check. Memory `project_self_hosting_overhaul_2026_09`.

### FFI calls
- `crdt_api.joinServer(serverId:, nsfwConfirmed:)`
- `crdt_api.createServer(name:)`

---

## CreateChannelDialog -- Channel Creation

**File:** `lib/src/ui/dialogs/create_channel_dialog.dart`
**Trigger:** the channel sidebar and category menus (`channel_context_menus.dart`), the shell shortcut, the Channels page of Server settings, the phone Chats tab.
**Entry point:** `showCreateChannelDialog(context, serverId, {onCreated})` -- void; `onCreated` receives the NEW channel id so a caller can place it in the layout instead of letting it land unsorted.

`_CreateChannelDialog` (`HollowDialogAction`): `HollowDialog(title: 'Create channel', width: 420, busy:)`.
- "Choose a type and name for your new channel."
- Type = two equal `HollowChip(expand: true)` (Text `hash` / Voice `volume2`), a selection, never buttons.
- `HollowTextField` (autofocus, prefix icon follows the type, hint "general" / "General"); the failure sits on the field's `errorText` with the name kept, cleared on edit.
- Ghost Cancel (disabled while running) + filled "Create" (disabled while empty, `loading:`).
- Submit runs `crdt_api.createChannel(serverId:, name:, category: null, channelType: 'voice'|'text')` inside `runDialogAction` (fallback "Couldn't create the channel. Try again."), pops on success, then `onCreated(channelId)`.

---

## InviteDialog -- Invite Link

**File:** `lib/src/ui/dialogs/invite_dialog.dart`
**Trigger:** Invite in the channel sidebar header / server strip menu (`server_context_menus.dart`) / the phone's Chats tab.
**Entry point:** `showInviteDialog(BuildContext context, String link, String serverId)` -- void. Server invites only (rooms no longer come here).

`HollowDialog(title: 'Invite link', showClose: true, width: 420)`, no Done button (nothing to confirm):
- "Anyone with this link can join <server name>." (`serverListProvider`; "your server" when unnamed).
- `HollowCopyField(value: link, name: 'invite link', wrap: false)`: the link on ONE line with an ellipsis, a labelled copy button that toasts "Copied". The id is not shown separately (the link carries it).

### No FFI calls -- purely display.

---

## MnemonicDialog -- Recovery Phrase Display

**File:** `lib/src/ui/dialogs/mnemonic_dialog.dart`
**Trigger:** After creating a new account (`hollow_shell.dart`), Home's setup card "save your phrase" (`home_inbox.dart`), the user bar.
**Entry point:** `showMnemonicDialog(BuildContext context, String mnemonic)` -- void.
**Barrier:** Non-dismissible.

`HollowDialog(title: 'Your recovery phrase')`, an acknowledgement, so ONE filled button and no X:
- "These 24 words bring back your identity if you lose this device. Write them down in order and keep them somewhere safe."
- **`RecoveryPhraseGrid`** (public, reusable): the words numbered in `monoSmall` `textTertiary` (tabular figures) + the word in `mono` `textPrimary`, read left to right, 3 columns on desktop / 2 on a phone, inside a `SelectionArea`. No tinted warning box.
- `leadingActions`: ghost "Copy" (copies the phrase, toasts "Copied").
- Filled "I've saved it": pops, then `homeSetupProvider.markPhraseSaved()`; a failed write only toasts (`friendlyError`, "Hollow couldn't note that you saved it, so it may remind you again."), never keeps the dialog up.

### No FFI calls -- mnemonic is passed in as parameter.

---

## ScreenShareDialog -- Screen/Window Source Selection

**File:** `lib/src/ui/dialogs/screen_share_dialog.dart`
**Trigger:** Share in the call controls (desktop). The phone has its own `mobile_screen_share_sheet.dart`.
**Entry point:** `showScreenShareDialog(BuildContext context)` -- returns `Future<ScreenShareSelection?>` (null on Cancel).

### Data types

**`ScreenShareResolution` enum:** p360, p480, p720, p1080, p1440, p4k -- each with `width`, `height`, `label`.
**`ScreenShareFps` enum:** fps5, fps15, fps30, fps60 -- each with `value`, `label`.

**`ScreenShareSelection` class:**
- Fields: `sourceId`, `width`, `height`, `fps`, `shareAudio`, `pid`, `windowHwnd`, `profile` (`ScreenContentProfile`, drives the encoder tuning; default motion)
- `windowHwnd`: for a WINDOW share on Windows, the window's HWND (the desktop source `id` IS the decimal HWND); 0 for screens. The screen-audio exe resolves HWND→owning pid→the app's audio-rendering pids itself (per-app INCLUDE+mix). This is the RELIABLE per-app target — `pid` arrives as 0 for windows, so it isn't trusted
- `pid`: process ID from `DesktopCapturerSource.pid` (Windows only, often 0 for windows — see `windowHwnd`). Legacy per-process target
- `qualityLabel` getter: e.g. "1080p60", "4K30"

**`ScreenShareSources`**: the injectable source of `capturer` + `requestPermission()` (macOS Screen Recording), so a widget test stands in for the native capturer. `ScreenShareDialog` is public with `sources:`.

### Widget: `_ScreenShareDialogState`

**State fields:** `_sources` (by id), `_selectedSourceId`, `_resolution` (p1080, clamped to `_availableResolutions`: only tiers a connected display can produce), `_fps` (fps60), `_profile` (motion), `_shareAudio` (**false**: "Share audio" starts OFF, desktop and phone), `_load` (`_SourceLoad { loading, ready, denied, failed }`), `_showScreens`, `_refreshTimer` (3 s `updateSources`), `_portalMode` / `_portalFresh`.

**initState:** Wayland (`DesktopCaptureSupport.usePortalPicker`) skips enumeration entirely (no `_loadSources()`, no listeners, no timer; each pops an xdg-desktop-portal dialog). Otherwise `_loadSources()` + `onAdded` / `onRemoved` (clears a removed pick) / `onThumbnailChanged`.

**`_loadSources()`:** on macOS asks `requestPermission()` FIRST (nothing enumerates until Screen Recording is granted); `getSources(types: DesktopCaptureSupport.sourceTypes)` (issue #30); the first screen starts picked. macOS with no permission or no screens = `denied`; a throw = `failed`.

**Visible-tab selection:** `_visibleSelectionId` is the pick only when it is on the tab in view, so a screen picked on Screens never shares from the Windows tab where nothing looks chosen. Share enables on it.

**Layout (`HollowDialogSurface`, width 680, maxHeight 560):**
- Title "Share your screen".
- `HollowChipTabs<bool>` "Screens" / "Windows" (the tab row is chips), then the source area by `_load`: `loading` = a skeleton grid in the final geometry; `denied` = `HollowEmptyState` "Hollow isn't allowed to see your screen" + outline "Open System Settings" (the Screen Recording pane); `failed` = "Hollow couldn't list your screens and windows" + outline "Try again"; `ready` = the grid (2 columns screens / 3 windows, 16:10), or "No screens found" / "No open windows found". A tile is `elevated` with a border that thickens to 2 px accent when picked (no tint), `HollowFocusRing`, Semantics selected.
- Wayland portal mode replaces tabs + grid with `_buildPortalSection()`: "Press Share and your desktop opens its own dialog. Pick a whole screen or a single window there.", plus (once `portalGrantLikely`) chips "Same as last time" / "Pick something new" with a line under them; the fresh pick bumps the restore generation on Share.
- Options table (`SettingsFieldLabel` + wrapping chip rows): "Optimize for" (Smooth motion / Sharp text, which also snaps fps 60 / 15), "Resolution", "Frame rate".
- `HollowToggle` "Share audio" (locked off with a note on macOS below 13; a Wayland note that audio is system-wide minus Hollow).
- Action row under `HollowButtonTouchScope`: a leading hint while nothing can be shared ("Finding your screens…", "Pick a screen to share.", "Pick a window to share."), ghost Cancel, filled Share.

**Share:** pops `ScreenShareSelection(...)` with `windowHwnd = int.tryParse(id)` for a window, 0 for a screen (portal mode pops `DesktopCaptureSupport.portalSourceId`). Logs `[SCREEN-AUDIO] Share confirmed: type/pid/hwnd/audio/id` via `network_api.logFromDart`.

### External dependencies
- `flutter_webrtc` -- `desktopCapturer`, `DesktopCapturerSource`, `SourceType`, `Helper.requestCapturePermission`

---

## LicenseKeyDialog -- Relay Access Key Input

**File:** `lib/src/ui/dialogs/license_key_dialog.dart`
**Trigger:** Only a SELF-HOSTED relay whose owner switched access keys on (`/relay-status` says key-required); the official relay's `keys.json` has `"enabled": false`, so it never asks. Also after the relay rejects a stored key (`hollow_shell.dart` `_handleLicenseError`, reasons mapped to "access key" sentences).
**Entry point:** `showLicenseKeyDialog(BuildContext context, {String? error})` -- returns `Future<String?>` (the typed key; the default-relay switch ends the process instead of returning).
**Barrier:** Non-dismissible. One term in the UI: "access key" (never "license key" or "beta").

### Widget: `_LicenseKeyContent` (ConsumerStatefulWidget, `HollowDialogAction`)

**Auto-formatting (`_onChanged`):** uppercases, strips non-alphanumerics, 16 chars max, dashes every 4 (`XXXX-XXXX-XXXX-XXXX`), clears the error.

**Validation (`_onSubmit`):** empty -> "Enter the access key you were given."; wrong shape -> "An access key is 16 letters and numbers, like XXXX-XXXX-XXXX-XXXX." Both on the field's `errorText`. Valid pops with the key.

**Layout (HollowDialog, width 420):**
- Title "This relay needs an access key"
- Body names the relay (mono span from `relayDomainProvider`): "<relay> only lets people in with an access key, set by whoever runs it. Ask them for one and enter it here."
- `HollowTextField` (mono, hint `XXXX-XXXX-XXXX-XXXX`, `errorText`)
- Leading ghost "Use the default relay" (phone: "... and close"), shown only off `kDefaultRelayDomain`: `setDomain(default)` + `exitForRelaySwitch()` inside the dialog with loading and an inline error.
- Filled "Connect".

### No key FFI here -- the caller passes the key to `set_license_key()`.

---

## TwitchJoinDialog -- Twitch-gated server join

**File:** `lib/src/ui/dialogs/twitch_join_dialog.dart`
**Trigger:** A join to a Twitch-gated server (event_provider, the join flows).
**Entry points:** `showTwitchJoinDialog(context, {serverId, channelId, channelName, serverName, minFollowDays, requireSub, failureReason})` -- void. Same file: `showJoinRejectedDialog(context, {title, message})` (info only, `showClose`, the specific reason: a vague failure reads as a network problem) and `showNsfwConfirmDialog(context, {serverName, onProceed})` (a `showHollowConfirm` "Sensitive content warning", filled "I am 18 or older, join" because joining destroys nothing; `onProceed` sends the retry INSIDE the dialog).

### Global callback mechanism
- `_activeTwitchJoinCallback` + `handleTwitchJoinResult({success, error})`: event_provider routes a `TwitchJoinRejected` / result to the open dialog (returns true when handled, so no second dialog opens).

### Calls behind a seam
`TwitchJoinCalls` (`twitchJoinCallsProvider`, a test replaces it): `isConnected`, `startDeviceFlow`, `pollForToken`, `ensureToken`, `verifyFollow(broadcasterId)`, `joinServer(serverId, proof)` (`crdt_api.joinServer(twitchProofJson:, nsfwConfirmed: false)`).

### `_TwitchJoinDialogState` (`HollowDialogAction`)
`_JoinStep { checking, requirements, connect, verifying, success, failed }`. Starts at **checking** ("Checking your Twitch connection…") so a connected account goes straight to verifying instead of flashing the requirements; `failureReason` opens on failed. One `HollowDialog(width: 420, busy:)`; title by step: "Twitch verification", "Joined <server>", "Couldn't join <server>". No progress dots.
- **requirements:** "<server> asks new members to verify with Twitch.", rows (grey 16 px icon + text): "Follow <channel> for at least N days" (or "Follow <channel>" when 0) and, with `requireSub`, "Subscribe to <channel>"; "Connect your Twitch account so Hollow can check." Ghost Cancel + filled "Connect Twitch" (`BrandIcons.twitch`, loading while `startDeviceFlow` runs; a failure shows inside, "Hollow couldn't reach Twitch. Try again in a moment.").
- **connect:** "Open Twitch and enter this code to connect your account.", `HollowCopyField(value: userCode, name: 'Code', wrap: false)`, spinner "Waiting for Twitch…". Ghost Cancel + filled "Open Twitch" (`launchUrl`). Polling runs `pollForToken`, then verify.
- **verifying:** spinner "Verifying your Twitch account…" + "Checking that you follow <channel>"; no actions. `_verify()` = `ensureToken` then `verifyFollow(channelId)`: a blind-signed FOLLOW credential (the shop signs what Twitch said onto our master; the owner verifies offline against the pinned root; names channel, age bucket and tier, nothing identifying the account, so it may ride the join ring), then `joinServer`. Stays here until the event callback.
- **success:** check icon + "Your Twitch account meets this server's requirements."; closes itself after 1500 ms.
- **failed:** the reason (`friendlyError`, or "Your Twitch account doesn't meet this server's requirements."), `showClose`, filled "Try again" (only when a `channelId` is known) re-runs from checking.

---

## ImageCropDialog -- Avatar/Image Cropping

**File:** `lib/src/ui/dialogs/image_crop_dialog.dart` (desktop; the phone uses `mobile/mobile_image_crop_route.dart`)
**Trigger:** Avatar, banner, server icon or chat background selection in Settings and Server settings.
**Entry point:** `showImageCropDialog({context, imageBytes, aspectRatio, title})` -- returns `Future<Uint8List?>` (PNG bytes, null on Cancel). `aspectRatio` = width/height: 1.0 avatar or server icon, **2.5 USER banner** (the ratio every banner surface and Rust's storage share), 3.0 SERVER banner, 16/9 chat background.

### Widget: `_ImageCropDialogState` (`HollowDialogAction`)

**State:** `_decodedImage` (`ui.Image?`, disposed with the state), `_imageLoaded`, `_displayW`/`_displayH` (fit within `_maxDisplayWidth` 420 x `_maxDisplayHeight` 380), `_cropRect` (display coords), `_dragMode` (`_DragMode { none, move, topLeft, topRight, bottomLeft, bottomRight }`), `_dragStart`, `_cropAtDragStart`. Constants: `_minCropSide` 40, `_handleHit` 28 (the desktop target minimum) around a 10 px painted `_handleMark`, `_placeholder` 300x200 while decoding, `_nudge` 4 / `_bigNudge` 16.

- `_decodeImage()`: `ui.instantiateImageCodec`, scale to fit, initial crop = the largest rect of the target ratio, centred.
- Pan: move translates with clamping; a corner resizes keeping the ratio, min size and bounds.
- **Keyboard:** the surface autofocuses a `Focus`; arrow keys move the crop (Shift = the big step), Enter / numpad Enter applies.
- `_onConfirm()`: inside `runDialogAction` (fallback "Couldn't crop that image. Try again."): display rect to image rect, `PictureRecorder` + `drawImageRect` (high filter quality), `toImage` → PNG `toByteData`; pops the bytes on success. The error shows in the dialog above the actions; Cancel is disabled and `PopScope` blocks dismissal while it runs.

**Layout:** `HollowDialogSurface` (not `HollowDialog`: its scrolling body would contend with the crop drags), width = display width + padding. Title in `heading`, caption "Drag to move, corners to resize. Arrow keys move it too.", the image `Stack` (image, `_CropOverlayPainter` in a `RepaintBoundary` with `HollowColors.mediaScrim` outside the crop, accent 2 px border and rule-of-thirds lines at 30% accent; a transparent move region with the move cursor; four corner handles with resize cursors, accent square with an `onMedia` edge), a large spinner in the placeholder while decoding. Actions under `HollowButtonTouchScope`: ghost Cancel + filled Apply.

---

## IncomingCallDialog -- Incoming Call Overlay

**File:** `lib/src/ui/dialogs/incoming_call_dialog.dart` (283 lines)
**Trigger:** Reactively rendered when `callProvider` status is `ringing` + `incoming`.
**NOT a showHollowDialog -- this is a persistent overlay widget (`IncomingCallOverlay`).

### Widget: `IncomingCallOverlay` (ConsumerStatefulWidget)

Uses `SingleTickerProviderStateMixin` for animation.

**State fields:**
- `_controller` -- `AnimationController` (duration: `HollowDurations.normal`; the exit sets `reverseDuration = HollowDurations.fast`)
- `_fadeAnim` -- one `CurvedAnimation` (`HollowCurves.enter`, reverse `HollowCurves.exit`) that drives the fade AND an 8 px drop from above (`Transform.translate` of `-HollowMotion.rise * (1 - t)`), not the card's full height
- `_wasVisible` -- tracks previous visibility for enter/exit transitions
- `_ringtone` -- a `CallRingtone` (`ui/call/call_ringtone.dart`, session 23), shared with the phone's `MobileIncomingCallOverlay`
- `_countdownTimer` -- 30-second countdown `Timer.periodic`
- `_secondsLeft` -- int, starts at 30, decrements each second
- Cached display info (survives exit animation): `_cachedPeerId`, `_cachedDisplayName`, `_cachedAvatarBytes`, `_cachedIsVideoCall`

**Ringtone playback (`CallRingtone.start`):**
- Reads `ringtonePathProvider`, `ringtoneVolumeProvider`, `ringtoneStartProvider`, `ringtoneEndProvider`; after the awaits, bails if the call already ended (`stillRinging: () => mounted && _wasVisible`; a quick decline during the SQLCipher loads must not leave a ringtone playing forever)
- Custom path set AND file on disk AND trim range valid → plays from start offset, loops within clip range via `onPositionChanged` listener
- Otherwise (never set, cleared, file deleted, degenerate trim) → bundled default `AssetSource('sounds/default_ringtone.wav')` with `ReleaseMode.loop`, full clip (issue #39; an unset ringtone is never silent anymore)

**Visibility logic (in `build`):**
- When `isVisible` becomes true: forward animation, start ringtone, start countdown
- When `isVisible` becomes false: reverse animation, stop ringtone, stop countdown
- Caches peer info from `profileProvider` when visible (so card doesn't go blank during exit)

**Layout:**
- `Positioned` at top: `HollowSpacing.xl + 32` (below title bar)
- 320px wide card with `SlideTransition` + `FadeTransition`
- `HollowAvatar` (56px)
- Display name (bold)
- Call type label: "Incoming video call..." or "Incoming voice call..."
- Button row:
  - Decline (`HollowButton.danger`, `LucideIcons.phoneOff`) -- calls `callProvider.notifier.rejectCall()`
  - Countdown timer: `HollowSpinner.large(value: secondsLeft/30)` wrapping countdown text, turns red at 5s
  - Accept (`HollowButton.filled`, phone/video icon) -- calls `callProvider.notifier.acceptCall()`

### Providers read
- `callProvider` -- CallStatus, CallDirection, peerId, isVideoCall
- `profileProvider` -- display name, avatar bytes
- `ringtonePathProvider`, `ringtoneVolumeProvider`, `ringtoneStartProvider`, `ringtoneEndProvider` (all async)

---

## RecoveryPoolDialog -- Recovery Pool Join/Initiate

**File:** `lib/src/ui/dialogs/recovery_pool_dialog.dart`
**Trigger:** "Start a recovery pool" in Archive's vault files view (`archive/vault_files_view.dart`); a recovery link (deep link, the in-chat link card) opens Join.
**Contains TWO dialogs**, both `HollowDialog(width: 420)` with `HollowDialogAction`: the work runs inside, the confirm loads, a failure shows above the actions.

### Initiate: `showInitiateRecoveryPoolDialog(context, {serverId, serverName})`
- **Consent** ("Start a recovery pool"): "Ask the others who were in <server> to help rebuild its large files, like videos and attachments. Each of you shares the file pieces you still hold, and only those pieces leave this device." Ghost Cancel + filled "Start pool". `_initiate()` = `crdt_api.initiateRecoveryPool(serverId:)` (fallback "Couldn't start the recovery pool. Try again."), then the same dialog turns into the link step.
- **Link** ("Recovery pool started", `showClose`, no Done): "Send this link to the others who were in <server>. ..." + `HollowCopyField(value: link, name: 'recovery pool link', wrap: false)`.

### Join: `showJoinRecoveryPoolDialog(context, {prefillLink})`
- "Join a recovery pool": prose, mono `HollowTextField` hint `hollow://recovery?server=...&token=...` (autofocus). Ghost Cancel + filled "Join pool".
- A link without `server=` and `token=` = field error "That isn't a recovery pool link. Paste the whole link, starting with hollow://recovery."
- `crdt_api.joinRecoveryPool(inviteLink:)`, then `_waitForWelcome()` polls `recoveryPoolProvider` every 500 ms for 10 s for a member; none = `stopRecoveryPool` + clear (the notifier read BEFORE the await), and the dialog shows `kRecoveryPoolNoAnswer` ("Nobody in that pool answered. Ask whoever shared the link to keep Hollow open, then try again."). Success: `confirmJoin()`, pop, toast "Joined the recovery pool".

### FFI calls
- `crdt_api.initiateRecoveryPool(serverId:)`, `crdt_api.joinRecoveryPool(inviteLink:)`, `crdt_api.stopRecoveryPool(serverId:)`

---

## ExportArchiveDialog -- Archive Export Options

**File:** `lib/src/ui/dialogs/export_archive_dialog.dart` (+ `export_to_file.dart`)
**Trigger:** Export in Archive (`archive_conversation_list.dart`, `archive_message_viewer.dart`, the phone `mobile_archive_viewer_route.dart`).
**Entry point:** `showExportArchiveDialog(context, {isDm, isServer, peerId, serverId, channelId, channelName, serverName, channels, name, messageCount})`

### `_ExportArchiveDialogContentState` (`HollowDialogAction`)
`HollowDialog(title: 'Export <name>', width: 420, busy:, error:)`:
- "Saves 1,204 messages to one file. The archive is signed, so anyone can check it came from you." (grouped count; "this conversation" when 0).
- `SettingsFieldLabel` "Files", then three equal `HollowChip(expand: true)`: "Full" / "Images only" / "Messages only" (`_fileMode` `full` / `images_only` / `placeholder`), a selection; the chosen mode's one line under the row ("Includes every file. The largest archive.", "Includes images, and leaves out videos and large files.", "Keeps each file's name, not the file. The smallest archive."). Chips lock while exporting.
- Ghost Cancel + filled "Export and sign" (loading).

`_export()` runs `exportToFile(fileName: '<exportFileStem(name)>.hollow-archive', extension: 'hollow-archive', pickerTitle: 'Save archive', write: _write)` inside `runDialogAction` (fallback "Couldn't export the archive. Try again."). A cancelled picker (null) ends quietly with the dialog still open; success pops + toast "Archive exported (<size>)". `_write` picks `archive_api.exportServerArchive` / `exportDmArchive` / `exportChannelArchive(..., fileMode:)`.

### `export_to_file.dart` (shared with the shard export)
- `exportFileStem(name)`: letters, digits, spaces and dashes, spaces to underscores, lower case; `hollow` when empty.
- `exportToFile({fileName, extension, pickerTitle, write, onWriting})` → bytes written or null on cancel. Desktop asks where first (`FilePicker.saveFile`) and Rust writes there; a phone has no writable path to offer, so Rust writes a temp file whose bytes go to the system save sheet, then the temp is deleted. `onWriting` fires when the slow part starts, so loading shows only after the picker closes.

---

## StorageDashboardDialog -- RETIRED (2026-09-26)

Replaced by the Server settings page Files & storage (`server_settings/pages/files_storage_page.dart`, wiki `ui_server_settings`), which every member can open. `freeBytesAt(hollowDataDir)` (`core/services/disk_space.dart`: the volume holding the DATA ROOT, never a fixed `C:` or `/`; Windows `GetDiskFreeSpaceExW`, Linux/macOS/Android `df -Pk` via `parseDfAvailableBytes`, null on iOS) moved there with it.

---

## MessageProofDialog -- Cryptographic Message Proof Verification

**File:** `lib/src/ui/dialogs/message_proof_dialog.dart`
**Trigger:** the message More / right-click menu -> "Message proof" (DM, channel, guest view), and the Archive viewers' info action (live and imported archives).
**Entry point:** `showMessageProofDialog(BuildContext context, MessageProofData proof)`

### Data class: `MessageProofData`
- `senderPeerId`, `senderDisplayName`, `text`, `timestampMs`, `signature?`, `publicKey?`, `messageId?`, `context` (recipient peer_id for DM, "server_id:channel_id" for channel), `msgType` (`"dm"` / `"ch"`), `fileAttachment?`, `preverified?`.
- (0.8.5) NO Dart payload reconstruction: live rows verify via `network_api.verifyMessageProofV2(msgType:, context:, senderPeerId:, messageId:)` (Rust loads the row and builds the v2 payload, or v3 when it has an `album_id`); imported-archive rows carry the Rust loader's verdict as `preverified`.
- `publicKeyFingerprint`: base64 key → hex → first 32 hex chars in groups of 4, upper case.

### Status: `ProofStatus { checking, verified, invalid, unsigned, notHere, failed }`
One `HollowBadge` + one explaining line (`_statusWords()`):
- **Checking** (neutral) while the FFI runs.
- **Verified** (success): "Signed with the sender's key, and unchanged since it was sent."
- **Invalid** (error): "The signature doesn't match this message. It was changed after it was signed, or signed by an older version of Hollow."
- **Unsigned** (neutral): no signature or public key, or Rust found none.
- **Not on this device** (neutral): no `messageId`, or the FFI said "not found". NOT a verdict on the message (the row this device would check against is missing), so it must never read as Invalid: "...Check it on a device that has the conversation, or ask the sender for an exported proof."
- **Not checked** (neutral): any other throw, with the `friendlyError` line.

### Layout: `HollowDialog(title: 'Message proof', showClose: true, maxWidth: 520)`
- The badge, its line, then the message as the ONE `MessageRow` (read-only: no reactions, no reply), wrapped in `HollowBleed(horizontal: MessageRow.horizontalInset)` so the avatar sits on the dialog's text edge.
- `HollowSectionHeader('Details', dense: true)`, then `HollowCopyField`s, each with its own copy button:
  - **Sender** (not mono): the sender's OWN profile name (MASTER via `identityOf`), plus ", you call them <nickname>" when a local nickname differs; copies the name. A proof names who SIGNED, never the nickname alone.
  - **Sender's user ID**, **Time (UTC)** (`toUtc().toIso8601String()`, copies it with the raw ms), **Message ID**, **Key fingerprint**, **Signature** (shown as first 24 + "..." + last 24, copies the whole).
- `leadingActions`, only when `_canExport` (Rust produced the canonical payload): ghost "Copy proof" (JSON to clipboard, "Proof copied") and ghost "Export proof" (`FilePicker.saveFile` `hollow-proof-<id>.json`, "Proof exported"; a failure toasts `friendlyError`).
- `_proofJsonString()`: always the v2 envelope (`protocol: hollow-proof-v2`; `payload_version` 3 and `album` for album rows; message fields incl. `edited_at`, `reply_to`, `file_id`, `order_us`, `link_preview_digest`; verification instructions for msg2 and msg3 grammars).

No entrance animation of its own; the dialog route's scale-and-fade is the only motion.

---

## ShardBundleDialog -- File pieces export/import

**File:** `lib/src/ui/dialogs/shard_bundle_dialog.dart`
**Trigger:** Archive's vault files view (`archive/vault_files_view.dart`). The UI says "file pieces"; "shards" stays in code and the `.hollow-shards` extension.
**Contains TWO dialogs**, both `HollowDialog(width: 420)` with `HollowDialogAction` (work inside, loading confirm, error above the actions).

### Export: `showExportShardsDialog(context, {serverId, serverName, shardCount})`
- "Export file pieces": "Save the N file pieces you hold for <server> to one file. Send it to the others who were there, and they can rebuild files without you being online." Ghost Cancel + filled "Export".
- `exportToFile(fileName: '<exportFileStem(serverName)>.hollow-shards', extension: 'hollow-shards', pickerTitle: 'Save file pieces', write: archive_api.exportServerShards)` (the shared helper in `export_to_file.dart`, so the phone gets the system save sheet); a cancelled picker ends quietly; success pops + "Saved <size> of file pieces".

### Import: `showImportShardsDialog(context, {onImported})`
- "Import file pieces": "Choose a .hollow-shards file from someone who was in the server. Pieces you are missing are added, so more files can be rebuilt." Ghost Cancel + filled "Choose file" (picker "Choose a file of pieces").
- `archive_api.importServerShards(archivePath:)` (fallback "Couldn't read that file. Check it's a .hollow-shards file and try again."), then `onImported()`, and the same dialog turns into `_ImportResult`.
- `_ImportResult` ("Pieces imported", `showClose`): "Added to <server>. N more files can be rebuilt now." (or "No new files can be rebuilt yet."), then `_ResultRow`s "New pieces" / "Already had" (tabular figures). No success box, no Done.

---

## Settings is no longer a dialog (2026-09-24)

`UserSettingsDialog` / `showUserSettingsDialog` are DELETED. Settings is a centre place opened
with `openSettings()` / `toggleSettings()`; see `ui_user_settings.md`.

## Friends Manager -- `dialogs/friends_manager_dialog.dart` (2026-09-24, dialogs pass 2026-09-25)

`showFriendsManager(context, {addFriend, tab})`, re-exported from `shell/friends_bar.dart`;
`FriendsManagerTab { friends, requests, add }`. The header's add-friend button opens Requests
while requests wait, else Add friend. The class stays `_FriendsManager` (fleet scenarios target
`type:_FriendsManager`). `HollowDialogSurface` 520 x 552, `padded: false`, on `overlay`.
**The chip tab row IS the header**: `HollowChipTabs` "Friends" (count as `hint`), "Requests"
(`count:` badge while requests wait), "Add friend", then the close X, a hairline under it. No
"Friends" title (it said the word twice); the route still announces "Friends" via `Semantics`.
Tab content sits under `HollowFlushRows`, so rows are on the tab row's and search field's text edge.

- **Friends:** "Search friends", then "Favourites" (reorderable in place: a pointer-only drag
  handle; visible positions are mapped to the stored list before `reorder`) and "All friends"
  (an empty handle column when favourites exist, so the actions line up). Rows are
  `HollowListRow`: `PresenceAvatar` (ring cut from the row's hover fill), name, status line or
  Online/Offline. Actions (`HollowIconButton`s, 44 on touch) fade in on hover, keyboard focus,
  while the row's menu is open, and always on touch, hidden never removed so Tab reaches them:
  Message, the favourite star, More. More (also right-click via `ContextMenuTarget`): Voice call
  (online, not in a call; `startDmCallFlow`, the DM header's TURN check and leave-the-room
  confirm), View profile, Set a nickname / Edit nickname (`showLocalNicknameDialog`), **Move up /
  Move down** on a favourite (the keyboard's path to the drag), then Remove friend
  (`confirmRemoveFriend`). Clicking a row opens the DM. Empty: "No friends yet" / "No friends
  match".
- **Favourites are MASTER ids** (`favourite_friends_provider.dart`): the store keys masters and
  ids that are no longer friends stay stored but hidden (a device id in the store crashed the
  manager).
- **Requests:** "Received" (ghost "Decline", outline "Accept"; semantic labels "Decline/Accept
  friend request"; "No requests waiting" when empty) and "Sent" (ghost "Cancel request"). The
  pressed button loads per row; a failure toasts. Display resolves device→master for name and
  avatar only; answers still target `req.peerId`.
- **Add friend:** `SettingsFieldLabel` "User ID or nickname", mono field (`kAddFriendHint` "Paste
  an ID, or type a nickname") + filled "Send request", baseline-aligned so an error under the field
  never pulls the button out of line; `kAddFriendNote` "They see your request the next time
  they're online." The typed id survives a look at another tab (controller held by the dialog).
  `sendFriendRequestTo(ref, input)` (shared with the phone) is AWAITED: a peer id sends; a
  nickname registers a lookup in `_nicknameLookups`, calls `sendFriendRequestByNickname`, and
  completes only when a new outgoing request appears (15 s timeout: "Hollow didn't hear back about
  that nickname. Try again."). `handleNicknameLookupFailed` (from event_provider) fails the waiting
  send with "No one has the nickname X right now. Nicknames reset when their owner goes offline."
  So the button stays busy through the lookup, the error lands on the field via `friendlyError`
  with the input kept, and "Friend request sent" is true when it shows.
- **`HowOthersAddYou`** (shared with the phone's add sheet): `HollowSectionHeader` "How others add
  you", "Your user ID" + ghost "Copy" ("ID copied"), "Temporary nickname" (field + outline "Claim",
  loading while claiming; the typed name stays until the relay answers and clears once claimed; a
  claim that never reached the relay calls `onClaimFailed('send')`), or the claimed name + ghost
  "Release". Claim errors: taken / invalid (3 to 20 lowercase letters, numbers or underscores).
- Shared helpers for the phone's Friends tab: `receivedRequestLabel`, `sentRequestLabel`,
  `isPeerIdInput`, `sendFriendRequestTo`, `kAddFriendHint`, `kAddFriendNote`.

### `confirmRemoveFriend` (`dialogs/confirm_remove_friend.dart`)
THE remove-friend question, every surface: `showHollowConfirm` "Remove <name>?", "You'll both drop
off each other's friend list. Your conversation stays on this device.", danger "Remove friend",
`onConfirm` = `removeFriendAndTidy(ref, peerId)` (remove, drop the favourite, close the open DM
and the split pane showing them; reads everything BEFORE the await). The toast "Friend removed"
goes to the root overlay captured up front (the removal usually unmounts the asking row).

---

## Keyboard-Aware & Phone-Adaptive Dialogs (2026-06)

- **Global keyboard avoidance**: `showHollowDialog` (hollow_dialog.dart) wraps EVERY dialog's pageBuilder in `AnimatedPadding(padding: MediaQuery.viewInsetsOf(context), 100ms decelerate)` + `MediaQuery.removeViewInsets(removeBottom: true, ...)` — the same pattern as Flutter's `Dialog`. Every dialog (including custom Center-based builders) shifts above the keyboard for free. RULE: never add viewInsets padding inside a dialog builder — it double-pads.
- **HollowDialog widget**: under 600px (`HollowDialogSurface.isCompact`) the frame spans the screen minus 24 a side with `radiusXl`; content scrolls in a `Flexible` (`scrollable: false` for content that scrolls itself), actions in a right-aligned `Wrap` under `HollowButtonTouchScope`, so the actions and the close X grow to 44 on their own (a call site never passes `touch:`).
- **CreateServerDialog**: compact stacks Join above Create with a `HollowDivider` (desktop keeps two columns); autofocus is off on compact so the keyboard doesn't immediately cover the stacked layout.
- **MessageProofDialog**: a standard `HollowDialog`; its Copy/Export are `leadingActions` and touch-size on a phone like any other.
- **WelcomeDialog**: compact-aware minWidth (was forced 360) + internal scroll.
- **Unlock/recovery dialogs**: `shell/identity_unlock_dialogs.dart`, opened by hollow_shell. `UnlockDialog` ("Unlock Hollow", width 420, PIN-aware numeric keyboard, "Wrong PIN/password. Try again." on the field, never a toast because the lock cover silences toasts; leading ghost "Forgot PIN?" / "Forgot password?" pops `kUnlockRecover`, a biometric icon button pops `kUnlockBiometric`, filled "Unlock"). `RecoveryPhraseDialog` (`HollowDialogAction`: the 24 words checked for count on the field, `onRecover` runs inside the dialog, a failure lands on the field with the phrase kept; `cancellable: false` at launch). See ui_mobile.md "Security Tab (App Lock)".

---

## VerifyContactDialog -- Safety Number Comparison (Issue 1-D, 2026-07)

**File:** `lib/src/ui/dialogs/verify_contact_dialog.dart`
**Entry point:** `showVerifyContactDialog(context, peerId:)` (device or master id; it resolves to the MASTER, verification is of a person) -- desktop opens `HollowDialog(title: 'Verify contact', showClose: true)`, mobile pushes `MobileVerifyContactRoute` (a `MobileSettingsSubPage`) via `hollowMobileRoute()`. Both wrap the same `VerifyContactBody`, so the flow can never drift between platforms.
**Reached from:** the More menu of `ProfileIdentityColumn` (popup and profile dialog) and its More sheet on the phone, the DM left-hand profile panel (`_DmProfilePanel._buildDmActions` in chat_pane.dart), the "Verify" button on `SecurityAlertBanner`, and the "View" action in Settings > Security > Verified Contacts.

**Every floating host dismisses itself first.** The profile column's verify action captures the ROOT navigator context, then closes the host (`dismissHost`), then pushes -- the same pattern as nickname/block/report. Capturing first is load-bearing: dismissing disposes the host's own context. The DM panel is persistent, not floating, so it opens the screen directly.

The entry label doubles as the state readout ("Verify contact" vs "View safety number" in the profile's More menu and sheet, "Safety number" in the user menu), so every surface shows verification status without a separate badge.

### What the user is doing

Both people open this screen and see the **same** 60-digit number, because it is derived symmetrically from their two master Ed25519 keys (`crypto/safety_number.rs`). If the numbers match, nothing is sitting in the middle. It must be compared over a channel an attacker on the relay does not control -- in person, on a video call, or through an app they already trust.

There is deliberately no "yours / theirs" split: a single shared number removes the ordering mistake users would otherwise make.

### Layout

- Explainer naming the contact ("Compare this number with <name> over a channel you already trust: ...").
- `_numberField` -- a `HollowCopyField` labelled "Safety number": 12 groups of 5, four to a line (so a person reading aloud keeps their place), copying the one-line grouped form. Grouping comes from the Rust `formatSafetyNumber()` so desktop and mobile cannot render the same number two different ways. No hand-drawn number card.
- **Paste-compare** -- `SettingsFieldLabel` "Their number" + a `HollowTextField` ("Paste the number they sent you") whose `onChanged` runs the sync FFI `safetyNumbersMatch()`. 60 digits is too many to check reliably by eye; the machine does it. Both sides are normalized to digits first, so display spacing or a pasted newline never produces a false mismatch (a false alarm on a security screen teaches users to ignore it). Result renders in a `Semantics(liveRegion: true)` row with an ICON as well as colour.
- Outstanding `security_alerts` for this contact, surfaced here too -- this is the moment the user decides whether to trust the person.
- `_VerifiedRow` -- a plain row (no card): shield icon + "You verified <name>." / "Not verified yet." and ONE compact outline, "Mark verified" or "Remove verification" (`danger: true`, cautionary), with `loading` and a success/error toast (the mutating provider rethrows).

### Failure handling

`safetyNumberWith()` returning `Err` renders `_ErrorLine` (alert icon + a `friendlyError` sentence, fallback "Hollow couldn't work out a safety number for this contact. Try again later.", live region) INSTEAD of a number. The screen never shows a plausible-looking value it did not actually compute -- per the spec's own warning, a badge or number that fails to reflect reality is worse than none, because it asserts a safety that is not there.

### No camera scanning

`mobile_scanner` has no Windows or Linux support, so a scan flow could never be the primary path on the platform Hollow is developed and tested on. Paste-compare works identically on all six platforms. Revisit only if the mobile story demands it.

---

## The profile, game card and showcase editor dialogs

Rebuilt 2026-09-26 (design language session 25). The full profile (`dialogs/profile_dialog.dart`) and its compact popup and phone sheet: wiki `ui_profile_card`. The game card (`dialogs/game_card_dialog.dart`, a sheet on phones) and the showcase editor (`dialogs/showcase_editor*.dart`, the profile dialog in edit mode, a pushed page on phones): wiki `profile_showcase_board`.
