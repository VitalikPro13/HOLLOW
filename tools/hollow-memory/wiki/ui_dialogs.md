# Dialogs -- All Modal Dialogs

Every modal dialog in the project. All files live under `lib/src/ui/dialogs/`. Most use `showHollowDialog()` from `lib/src/ui/components/hollow_dialog.dart` which provides scale 0.95->1.0 + fade entrance with full-screen glassmorphism blur barrier.

---

## WelcomeDialog -- First-launch Onboarding

**File:** `lib/src/ui/dialogs/welcome_dialog.dart` (443 lines)
**Trigger:** Called by the bootstrap flow when no identity exists on disk (first launch).
**Entry point:** `showWelcomeDialog(BuildContext context)` -- returns `Future<String?>`.
**Barrier:** Non-dismissible (`barrierDismissible: false`).

### Return values
- `'create_new'` -- user chose Create New Account
- `'restored_mnemonic'` -- identity restored from recovery phrase
- `'restored_backup'` -- identity imported from .hollow backup file
- `null` -- dialog dismissed without selection (should not happen due to non-dismissible barrier)

### Widget: `_WelcomeContent` (StatefulWidget)

**State fields:**
- `_view` -- `_WelcomeView` enum: `.menu` (default) or `.restorePhrase`
- `_phraseController` -- `TextEditingController` for the 24-word input
- `_phraseError` -- nullable error string shown below the text field
- `_restoring` -- bool, true during async restore operation

**View: menu (`_buildMenu`)**
- Shield icon in accent-tinted 56px container
- "Welcome to Hollow" heading + "Choose how to set up your account" subtitle
- Three `_OptionCard` widgets:
  1. `LucideIcons.userPlus` "Create New Account" -- pops with `'create_new'`
  2. `LucideIcons.keyRound` "Restore from Recovery Phrase" -- switches `_view` to `.restorePhrase`
  3. `LucideIcons.folderInput` "Restore from Backup" -- calls `_onRestoreFromBackup()`

**View: restorePhrase (`_buildRestorePhrase`)**
- Back arrow + "Restore from Recovery Phrase" title row
- Instruction text: "Enter your 24-word recovery phrase, separated by spaces."
- `HollowTextField` with 4 `maxLines`, hint "word1 word2 word3 ... word24"
- Error text (conditionally shown when `_phraseError != null`)
- Cancel (ghost) + Restore (filled) buttons; Restore shows spinner when `_restoring`

**Method: `_onRestoreFromPhrase()`**
- Splits text on whitespace, validates exactly 24 words
- Calls `identity_api.restoreIdentityFromMnemonic(phrase:)`
- On success: pops with `'restored_mnemonic'`
- On failure: sets `_phraseError`

**Method: `_onRestoreFromBackup()`**
- Opens `FilePicker` for `.hollow` extension
- Opens a nested `AlertDialog` for passphrase input (obscured text, autofocus)
- Calls `storage_api.importBackup(backupPath:, passphrase:)`
- On success: pops with `'restored_backup'`
- On failure: shows error toast

### Widget: `_OptionCard` (StatefulWidget)
- Tracks `_hovered` bool for hover styling
- `MouseRegion` + `GestureDetector` wrapping an `AnimatedContainer`
- Props: `icon`, `title`, `subtitle`, `hollow`, `onTap`
- Hover: surface alpha 0.4 -> 0.8, border accent alpha 0 -> 0.3
- Layout: 40px icon box | title + subtitle column | chevron-right icon

### FFI calls
- `identity_api.restoreIdentityFromMnemonic(phrase:)`
- `storage_api.importBackup(backupPath:, passphrase:)`

---

## CreateServerDialog -- Server Creation / Join

**File:** `lib/src/ui/dialogs/create_server_dialog.dart` (210 lines)
**Trigger:** Plus button in the server strip or home dashboard.
**Entry point:** `showCreateServerDialog(BuildContext context)` -- void, no return.

### Layout
- Two-panel side-by-side layout separated by a `VerticalDivider` (180px height)
- Close button (X) via `HollowPressable` in top-right
- Constraints: maxWidth 600, minWidth 400

**Left panel: Join a Server**
- `LucideIcons.logIn` + "Join a Server" heading
- "Paste an invite link or server ID." caption
- `HollowTextField` with autofocus, mono font, hint "hollow://join?server=... or ID"
- `HollowButton.filled` "Join" (expand: true)
- `onSubmitted` on the text field also triggers join

**Right panel: Create a Server**
- `LucideIcons.plus` + "Create a Server" heading
- "Start your own server. You can invite others later." caption
- `HollowTextField` with hint "My Awesome Server"
- `HollowButton.outline` "Create" (expand: true)
- `onSubmitted` on the text field also triggers create

### Top-level functions

**`_handleJoin(context, controller)`**
- Parses input as URI; extracts `server` query param if scheme is `hollow://`
- Falls back to treating raw input as server ID
- Calls `crdt_api.joinServer(serverId:)`
- Shows info toast "Joining server..."

**`_handleCreate(context, controller)`**
- Trims name, validates non-empty
- Calls `crdt_api.createServer(name:)`

### FFI calls
- `crdt_api.joinServer(serverId:)`
- `crdt_api.createServer(name:)`

---

## CreateChannelDialog -- Channel Creation

**File:** `lib/src/ui/dialogs/create_channel_dialog.dart` (150 lines)
**Trigger:** Plus button next to channel list in `ChannelSidebar`.
**Entry point:** `showCreateChannelDialog(BuildContext context, String serverId)` -- void.

### Layout
Uses `StatefulBuilder` inside `showHollowDialog` to manage local state.
Wraps content in `HollowDialog` (title: "Create Channel").

**State fields (closure-scoped):**
- `nameController` -- `TextEditingController`
- `isVoice` -- bool, false = text channel (default)

**Channel type selector:**
- Row of two `_TypeOption` widgets: Text (`LucideIcons.hash`) and Voice (`LucideIcons.volume2`)
- `AnimatedContainer` with `HollowDurations.fast` transition
- Selected: accent background + accent border (1.5px), bold text
- Unselected: surface background + normal border (1px)

**Name field:**
- `HollowTextField` with autofocus
- `prefixIcon`: hash icon for text, volume2 icon for voice
- Hint text: "General" for voice, "general" for text

**Actions:**
- Cancel (ghost) + Create (filled)
- `onSubmitted` on text field triggers submit

**Submit logic:**
- Calls `crdt_api.createChannel(serverId:, name:, category: null, channelType:)` where channelType is `'voice'` or `'text'`

### Widget: `_TypeOption` (StatelessWidget)
Props: `icon`, `label`, `isSelected`, `onTap`

### FFI calls
- `crdt_api.createChannel(serverId:, name:, category:, channelType:)`

---

## InviteDialog -- Invite Code Display

**File:** `lib/src/ui/dialogs/invite_dialog.dart` (94 lines)
**Trigger:** After generating an invite from server settings or channel sidebar.
**Entry point:** `showInviteDialog(BuildContext context, String link, String code)` -- void.

### Layout
Uses `HollowDialog` with title "Invite Link".

**Content:**
- Determines `isServer` by checking if link contains `'server='`
- Dynamic subtitle: "Share this link to invite someone to your server/room:"
- Dynamic code label: "Server ID" or "Room code"
- Link container: accent-bordered box with `SelectableText` in mono font (accent color)
- Copy button: `HollowPressable` with `LucideIcons.copy`, copies link to clipboard, shows success toast
- Code label text below: "Server ID: {code}" or "Room code: {code}"

**Actions:**
- "Done" filled button closes dialog

### No FFI calls -- purely display.

---

## MnemonicDialog -- Recovery Phrase Display

**File:** `lib/src/ui/dialogs/mnemonic_dialog.dart` (74 lines)
**Trigger:** After creating a new account (post-WelcomeDialog).
**Entry point:** `showMnemonicDialog(BuildContext context, String mnemonic)` -- void.
**Barrier:** Non-dismissible.

### Layout
Uses `HollowDialog` with title "Your Recovery Phrase".

**Content:**
- Warning text explaining to write down and keep safe
- Container with warning-tinted border containing `SelectableText` of the mnemonic in mono font
- Copy button: `HollowButton.ghost` with `LucideIcons.copy`, copies mnemonic, shows success toast

**Actions:**
- "I've saved it" filled button closes dialog

### No FFI calls -- mnemonic is passed in as parameter.

---

## ScreenShareDialog -- Screen/Window Source Selection

**File:** `lib/src/ui/dialogs/screen_share_dialog.dart` (463 lines)
**Trigger:** Screen share button in voice channel controls.
**Entry point:** `showScreenShareDialog(BuildContext context)` -- returns `Future<ScreenShareSelection?>`.

### Data types

**`ScreenShareResolution` enum:** p360, p480, p720, p1080, p1440, p4k -- each with `width`, `height`, `label`.
**`ScreenShareFps` enum:** fps5, fps15, fps30, fps60 -- each with `value`, `label`.

**`ScreenShareSelection` class:**
- Fields: `sourceId`, `width`, `height`, `fps`, `shareAudio`
- `qualityLabel` getter: e.g. "1080p60", "4K30"

### Widget: `_ScreenShareDialog` (StatefulWidget)

**State fields:**
- `_sources` -- `Map<String, DesktopCapturerSource>` keyed by source ID
- `_selectedSourceId` -- nullable string
- `_resolution` -- default `p1080`
- `_fps` -- default `fps60`
- `_shareAudio` -- default false
- `_loading` -- true until sources loaded
- `_showScreens` -- true = Screens tab, false = Windows tab
- `_refreshTimer` -- periodic thumbnail refresh every 3s

**initState:**
- Calls `_loadSources()`
- Subscribes to `desktopCapturer.onAdded`, `.onRemoved`, `.onThumbnailChanged` streams

**`_loadSources()`:**
- Calls `desktopCapturer.getSources(types: [SourceType.Screen, SourceType.Window])`
- Starts 3-second periodic `desktopCapturer.updateSources()` timer

**`_filteredSources`:** Filters `_sources` by current tab type (Screen vs Window).

**Layout (680x560 max):**
- Title: "Share Your Screen"
- Tabs row: "Screens" / "Windows" -- `_buildTab()` pills
- Source grid: `GridView.builder`, crossAxisCount 2 for screens / 3 for windows, 16:10 aspect ratio
- Each tile (`_buildSourceTile`): thumbnail image (or desktop icon placeholder), name label, accent border when selected
- Resolution pills row: all `ScreenShareResolution` values as `_buildPill()` chips
- FPS pills row: all `ScreenShareFps` values as `_buildPill()` chips
- Share audio toggle: `HollowToggle` + label
- Actions: Cancel (ghost) + Share (filled, disabled when no source selected)

**Share button:** Pops dialog with `ScreenShareSelection(sourceId:, width:, height:, fps:, shareAudio:)`.

### External dependencies
- `flutter_webrtc` -- `desktopCapturer`, `DesktopCapturerSource`, `SourceType`

---

## LicenseKeyDialog -- Alpha Access Key Input

**File:** `lib/src/ui/dialogs/license_key_dialog.dart` (194 lines)
**Trigger:** On app startup when relay reports key-required via `/relay-status`.
**Entry point:** `showLicenseKeyDialog(BuildContext context, {String? error})` -- returns `Future<String?>`.
**Barrier:** Non-dismissible.

### Widget: `_LicenseKeyContent` (StatefulWidget)

**State fields:**
- `_controller` -- `TextEditingController`
- `_error` -- nullable error string (initialized from `widget.initialError`)

**Auto-formatting (`_onChanged`):**
- Uppercases input, strips non-alphanumeric chars
- Limits to 16 chars
- Inserts dashes every 4 chars: `XXXX-XXXX-XXXX-XXXX`
- Clears error on any change

**Validation (`_onSubmit`):**
- Empty check -> "Please enter a license key"
- Splits on `-`, validates exactly 4 parts of exactly 4 chars each
- On valid: pops with the key string

**Layout (440x340 max):**
- KeyRound icon in 56px accent-tinted container
- "License Key Required" heading
- "Enter your alpha access key to continue" subtitle
- `HollowTextField` with autofocus, mono font, hint "HLLW-XXXX-XXXX-XXXX", letter-spacing 1.5
- Error text (conditional)
- "Activate" filled button (full width)

### No FFI calls -- returns key string to caller which passes it to `set_license_key()`.

---

## TwitchJoinDialog -- Twitch OAuth Device Code Verification

**File:** `lib/src/ui/dialogs/twitch_join_dialog.dart` (545 lines)
**Trigger:** When a user tries to join a Twitch-gated server (from event_provider or server join flow).
**Entry point:** `showTwitchJoinDialog(BuildContext context, {...})` -- void.

### Global callback mechanism
- `_activeTwitchJoinCallback` -- top-level `void Function(bool success, String? error)?`
- `handleTwitchJoinResult({required bool success, String? error})` -- called by event_provider when TwitchJoinRejected arrives; returns true if active dialog handled it

### Widget: `_TwitchJoinDialog` (StatefulWidget)

**Constructor fields:**
- `serverId`, `channelId`, `channelName`, `serverName`
- `minFollowDays`, `requireSub` -- Twitch gate requirements
- `failureReason` -- optional, pre-populates failed state

**State fields:**
- `_step` -- `_JoinStep` enum: `requirements`, `connect`, `verifying`, `success`, `failed`
- `_error` -- nullable error string
- `_userCode` -- device code shown to user
- `_verificationUri` -- Twitch verification URL

**Step flow:**

**`_JoinStep.requirements` (`_buildRequirements`):**
- RichText: "{serverName} requires Twitch verification to join."
- Requirement rows with icon boxes:
  - Follow requirement: "Follow {channelName} for at least {minFollowDays} days"
  - Sub requirement (conditional): "Active subscription to {channelName}"
- "You'll need to connect your Twitch account to verify."
- Actions: Cancel (ghost) + "Connect Twitch" (filled, with Twitch icon from `SimpleIcons.twitch`)

**`_JoinStep.connect` (`_buildConnect`):**
- Before code received: spinner + "Starting Twitch authorization..."
- After code received:
  - "Enter this code on Twitch:" text
  - Large styled code display (24px, letter-spacing 4) in accent-bordered container
  - Tap to copy code (toast "Code copied!")
  - Spinner + "Waiting for authorization..."
- Actions: Cancel + "Open Twitch" button (launches `_verificationUri` via `url_launcher`)

**`_JoinStep.verifying` (`_buildVerifying`):**
- Spinner + "Verifying your Twitch account..."
- "Checking follow status for {channelName}"
- No action buttons

**`_JoinStep.success` (`_buildSuccess`):**
- CheckCircle icon + "You're now in {serverName}!"
- Auto-closes after 1500ms
- No action buttons

**`_JoinStep.failed` (`_buildFailed`):**
- AlertCircle icon + "Could not join {serverName}"
- Error box with error message
- Actions: "Close" ghost button

**Progress dots:** `_buildDots()` -- row of filled/unfilled circles tracking step index.

**Flow methods:**
- `_checkAndProceed()` -- checks `twitchIsConnected()`, skips to verify if already connected
- `_startConnect()` -- calls `twitchStartDeviceFlow()`, gets `userCode` + `verificationUri` + `deviceCode`
- `_pollForToken(deviceCode, intervalSecs)` -- calls `twitchPollForToken()`, then `_verify()` on success
- `_verify()` -- calls `twitchEnsureToken()`, `twitchGenerateProof(broadcasterId:)`, then `crdt_api.joinServer(serverId:, twitchProofJson:)`. Stays on verifying step until `_onJoinResult` callback fires.

### FFI calls
- `twitch_api.twitchIsConnected()`
- `twitch_api.twitchStartDeviceFlow()`
- `twitch_api.twitchPollForToken(deviceCode:, intervalSecs:)`
- `twitch_api.twitchEnsureToken()`
- `twitch_api.twitchGenerateProof(broadcasterId:)`
- `crdt_api.joinServer(serverId:, twitchProofJson:)`

---

## ImageCropDialog -- Avatar/Image Cropping

**File:** `lib/src/ui/dialogs/image_crop_dialog.dart` (470 lines)
**Trigger:** Avatar or banner selection in user settings, server settings.
**Entry point:** `showImageCropDialog({context, imageBytes, aspectRatio, title})` -- returns `Future<Uint8List?>`.

### Widget: `_ImageCropDialog` (StatefulWidget)

**Constructor fields:**
- `imageBytes` -- raw source image bytes
- `aspectRatio` -- width/height (1.0 for avatar, 3.0 for banner)
- `title` -- dialog title string

**State fields:**
- `_decodedImage` -- `ui.Image?` (decoded via codec)
- `_imageLoaded` -- bool
- `_displayW`, `_displayH` -- scaled display dimensions (max 420x380)
- `_cropRect` -- `Rect` in display coordinates
- `_dragMode` -- `_DragMode` enum: `none`, `move`, `topLeft`, `topRight`, `bottomLeft`, `bottomRight`
- `_dragStart` -- `Offset`
- `_cropAtDragStart` -- `Rect`

**Constants:**
- `_maxDisplayWidth = 420.0`, `_maxDisplayHeight = 380.0`
- `_minCropSide = 40` -- minimum crop dimension in display pixels

**`_decodeImage():`**
- Decodes bytes via `ui.instantiateImageCodec`
- Scales image to fit within max display bounds
- Computes initial crop rect as largest rect with target aspect ratio that fits the display image, centered

**Crop interaction:**
- `_onPanStart(details, mode)` -- records drag start position and current crop rect
- `_onPanUpdate(details)` -- move mode: translates rect with clamping; corner modes: resizes maintaining aspect ratio with minimum size and bounds clamping
- `_onPanEnd(details)` -- resets drag mode to none

**`_onConfirm():`**
- Converts crop rect from display coords to image coords using scale factors
- Renders cropped region via `PictureRecorder` + `Canvas.drawImageRect`
- Exports as PNG via `picture.toImage().toByteData(format: ImageByteFormat.png)`
- Pops with `Uint8List` of cropped PNG bytes

**Layout:**
- Header: title + "Drag to move, corners to resize" hint
- Image area: `Stack` with:
  - Full source image (`Image.memory`)
  - `_CropOverlayPainter` (CustomPaint) -- dark overlay outside crop, accent border, rule-of-thirds grid
  - Move handle: `GestureDetector` over crop rect area with `SystemMouseCursors.move`
  - Four corner handles (`_buildHandle`): 18px hit area, 10px visual accent square with white border
- Actions: Cancel (ghost) + Apply (filled)

### CustomPainter: `_CropOverlayPainter`
- Draws dark overlay (60% black) outside crop rect using `clipRect` with `ClipOp.difference`
- Draws accent border (2px stroke) around crop rect
- Draws rule-of-thirds grid lines (0.5px, 30% accent alpha)

### Enum: `_DragMode`
Values: `none`, `move`, `topLeft`, `topRight`, `bottomLeft`, `bottomRight`

---

## IncomingCallDialog -- Incoming Call Overlay

**File:** `lib/src/ui/dialogs/incoming_call_dialog.dart` (283 lines)
**Trigger:** Reactively rendered when `callProvider` status is `ringing` + `incoming`.
**NOT a showHollowDialog -- this is a persistent overlay widget (`IncomingCallOverlay`).

### Widget: `IncomingCallOverlay` (ConsumerStatefulWidget)

Uses `SingleTickerProviderStateMixin` for animation.

**State fields:**
- `_controller` -- `AnimationController` (duration: `HollowDurations.normal`)
- `_slideAnim` -- slide from `Offset(0, -1)` to `Offset.zero` with `HollowCurves.enter`
- `_fadeAnim` -- fade 0 -> 1 with `HollowCurves.enter`
- `_wasVisible` -- tracks previous visibility for enter/exit transitions
- `_ringtonePlayer` -- `AudioPlayer?` for custom ringtone playback
- `_countdownTimer` -- 30-second countdown `Timer.periodic`
- `_secondsLeft` -- int, starts at 30, decrements each second
- Cached display info (survives exit animation): `_cachedPeerId`, `_cachedDisplayName`, `_cachedAvatarBytes`, `_cachedIsVideoCall`

**Ringtone playback (`_startRingtone`):**
- Reads `ringtonePathProvider`, `ringtoneVolumeProvider`, `ringtoneStartProvider`, `ringtoneEndProvider`
- Plays from start offset, loops within clip range via `onPositionChanged` listener

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
  - Countdown timer: `CircularProgressIndicator` (value = secondsLeft/30) wrapping countdown text, turns red at 5s
  - Accept (`HollowButton.filled`, phone/video icon) -- calls `callProvider.notifier.acceptCall()`

### Providers read
- `callProvider` -- CallStatus, CallDirection, peerId, isVideoCall
- `profileProvider` -- display name, avatar bytes
- `ringtonePathProvider`, `ringtoneVolumeProvider`, `ringtoneStartProvider`, `ringtoneEndProvider` (all async)

---

## RecoveryPoolDialog -- Recovery Pool Join/Initiate

**File:** `lib/src/ui/dialogs/recovery_pool_dialog.dart` (371 lines)
**Trigger:** DangerZoneTab in server settings (initiate) or recovery pool invite link (join).
**Contains TWO separate dialogs.**

### Initiate Dialog

**Entry point:** `showInitiateRecoveryPoolDialog(context, {serverId, serverName})`

**Widget: `_InitiateDialog` (ConsumerStatefulWidget)**

**State fields:**
- `_starting` -- bool
- `_inviteLink` -- nullable string, set after pool created

**Two views:**

**Consent screen (when `_inviteLink == null`):**
- Server icon + name row
- Explanation text about cooperatively gathering vault shards
- "Your local data stays encrypted. Only vault shards are shared."
- Actions: Cancel (ghost) + "Start Pool" (filled, shield icon, shows spinner when starting)

**Link screen (when `_inviteLink != null`):**
- Title: "Recovery Pool Started"
- Share instructions text
- Link container with `SelectableText` in mono accent font + copy button
- Actions: "Done" filled button

**`_initiate()`:** Calls `crdt_api.initiateRecoveryPool(serverId:)`, returns invite link string.

### Join Dialog

**Entry point:** `showJoinRecoveryPoolDialog(context, {prefillLink})`

**Widget: `_JoinDialog` (ConsumerStatefulWidget)**

**State fields:**
- `_controller` -- `TextEditingController` (prefilled if `prefillLink` provided)
- `_joining` -- bool

**Layout:**
- Explanation text about contributing vault shards
- `HollowTextField` with mono font, hint "hollow://recovery?server=...&token=..."
- Actions: Cancel (ghost) + "Join Pool" (filled, login icon, shows spinner when joining)

**`_join()`:**
- Validates link contains `server=` and `token=`
- Calls `crdt_api.joinRecoveryPool(inviteLink:)`
- Polls `recoveryPoolProvider` every 500ms for up to 10 seconds waiting for welcome
- On welcome: calls `recoveryPoolProvider.notifier.confirmJoin()`, pops, shows success toast
- On timeout: calls `crdt_api.stopRecoveryPool()`, clears provider, shows error toast

### FFI calls
- `crdt_api.initiateRecoveryPool(serverId:)`
- `crdt_api.joinRecoveryPool(inviteLink:)`
- `crdt_api.stopRecoveryPool(serverId:)`

### Providers read
- `recoveryPoolProvider`

---

## ExportArchiveDialog -- Archive Export Options

**File:** `lib/src/ui/dialogs/export_archive_dialog.dart` (366 lines)
**Trigger:** Export button in chat pane context menu, server settings.
**Entry point:** `showExportArchiveDialog(context, {isDm, isServer, peerId, serverId, channelId, channelName, serverName, channels, name, messageCount})`

### Widget: `_ExportArchiveDialogContent` (StatefulWidget)

**State fields:**
- `_fileMode` -- string: `'full'` (default), `'images_only'`, or `'placeholder'`
- `_exporting` -- bool

**Layout (HollowDialog, title "Export Archive"):**

**Conversation info row:**
- Type icon: `LucideIcons.server` / `.messageSquare` / `.hash`
- Name (bold) + message count

**File mode selector -- three `_FileModeOption` widgets:**
1. `LucideIcons.hardDrive` "Full" -- Include all files (largest)
2. `LucideIcons.image` "Images only" -- Include images, skip videos/large files
3. `LucideIcons.fileText` "Placeholder" -- No files, just metadata (smallest)

**Signed note:** ShieldCheck icon + "Archive will be signed with your Ed25519 key for cryptographic verification."

**Actions:** Cancel (ghost) + "Export & Sign" (filled, fileOutput icon, shows spinner when exporting)

**`_export()`:**
- Opens `FilePicker.platform.saveFile()` with `.hollow-archive` extension
- Calls appropriate FFI based on type:
  - `archive_api.exportServerArchive(serverId:, serverName:, channelsJson:, outputPath:, fileMode:)` for server
  - `archive_api.exportDmArchive(peerId:, outputPath:, fileMode:)` for DM
  - `archive_api.exportChannelArchive(serverId:, channelId:, channelName:, outputPath:, fileMode:)` for channel
- Shows success toast with file size

### Widget: `_FileModeOption` (StatelessWidget)
Uses `HollowPressable` wrapper. Shows check icon when selected.

### FFI calls
- `archive_api.exportServerArchive(...)`, `archive_api.exportDmArchive(...)`, `archive_api.exportChannelArchive(...)`

---

## StorageDashboardDialog -- Storage Usage Visualization

**File:** `lib/src/ui/dialogs/storage_dashboard_dialog.dart` (749 lines)
**Trigger:** Storage button in server settings or channel sidebar.
**Entry point:** `showStorageDashboardDialog(BuildContext context, String serverId)`

### Widget: `_StorageDashboardContent` (ConsumerStatefulWidget)

**Static caches (survive dialog open/close for instant reopen):**
- `_statsCache` -- `Map<String, crdt_api.StorageStatsFfi>`
- `_retentionFilesCache` -- `Map<String, String>`
- `_diskFreeBytesCache` -- int

**State fields:**
- `_stats` -- `crdt_api.StorageStatsFfi?`
- `_retentionFiles` -- string (default `'365d'`)
- `_diskFreeBytes` -- int

**`_loadData()`:** Parallel `Future.wait` of:
- `crdt_api.getStorageStats(serverId:)`
- `crdt_api.getServerSetting(serverId:, key: 'retention_files')`
- `_getDiskFreeBytes()` -- runs PowerShell `(Get-PSDrive C).Free` on Windows

**Layout (HollowDialog, 540px width):**

**Header:** HardDrive icon + "Storage Dashboard" + close button

**Adaptive sections based on member count:**

**< 6 members (Full Replication):**
- Single "Server Storage" section (full width)
  - Mode label: "Full Replication"
  - Storage bar: server data / total disk capacity
  - Bytes used + disk free (with warning icon if < 1GB)
  - Member count

**6+ members (Erasure Coding):**
- Side-by-side: "Server Storage" | "Your Storage" (IntrinsicHeight for equal height)
- Server Storage: mode label (e.g. "Erasure Coding (k=5/m=3)"), storage bar = used / effective capacity (total pledged / redundancy factor), overhead display
- Your Storage: pledge amount (clickable to edit), storage bar = used / pledge, disk free

**Bottom row (always):**
- Side-by-side: "Retention Policy" | "Vault Health"
- Retention Policy: file retention display, editable by owner/admin via `_editRetention()` -> `SimpleDialog` with options (permanent, 30d, 90d, 180d, 365d)
- Vault Health:
  - < 6 members: green StatusDot + "Full replication" + explainer
  - 6+ members: colored StatusDot (green/yellow/red) + status text based on active transfers and failures + shard count

**Member Pledges (6+ only):** Full-width section showing count + average pledge.

**Helper methods:**
- `_vaultModeLabel(memberCount)` -- returns human-readable label based on k/m tiers
- `_vaultParams(memberCount)` -- returns `(k, m)` tuple for erasure coding tiers
- `_formatBytes(BigInt)`, `_formatBytesInt(int)` -- human-readable byte formatting
- `_formatRetention(policy)` -- "365 days", "Permanent", etc.
- `_storageBar(fraction, color, hollow)` -- `TweenAnimationBuilder` animated bar, color shifts to warning at 70%, error at 90%
- `_editPledge(hollow)` -- `AlertDialog` with MB input (min 512), calls `crdt_api.setStoragePledge()`
- `_editRetention(hollow, key, currentValue)` -- `SimpleDialog` with retention options, calls `crdt_api.updateServerSetting()`

### Providers read
- `serverMembersProvider(serverId)` -- member count
- `vaultStatusProvider.select((s) => s[serverId])` -- `VaultServerStatus?`
- `myRoleProvider(serverId)` -- determines if retention is editable

### FFI calls
- `crdt_api.getStorageStats(serverId:)`
- `crdt_api.getServerSetting(serverId:, key:)`
- `crdt_api.setStoragePledge(serverId:, pledgeBytes:)`
- `crdt_api.updateServerSetting(serverId:, key:, value:)`

---

## MessageProofDialog -- Cryptographic Message Proof Verification

**File:** `lib/src/ui/dialogs/message_proof_dialog.dart` (582 lines)
**Trigger:** Right-click context menu on a message -> "Message Proof".
**Entry point:** `showMessageProofDialog(BuildContext context, MessageProofData proof)`

### Data class: `MessageProofData`

**Fields:**
- `senderPeerId`, `senderDisplayName`, `senderAvatar` (nullable `Uint8List`)
- `text`, `timestampMs`, `signature` (nullable), `publicKey` (nullable)
- `messageId` (nullable), `context` (recipient peer_id for DM, "server_id:channel_id" for channel)
- `msgType` -- `"dm"` or `"ch"`
- `fileAttachment` -- nullable `FileAttachment`

**Computed properties:**
- `canonicalPayload` -- `'hollow-msg:$msgType:$context:$senderPeerId:$timestampMs:$text'`
- `publicKeyFingerprint` -- base64-decoded key -> hex -> groups of 4 uppercase chars (first 32 hex chars = 16 bytes)
- `toProofJson()` -- structured JSON with version, protocol, message, sender, context, signature, verification instructions

### Widget: `_MessageProofDialogContent` (StatefulWidget)

**State fields:**
- `_verified` -- `bool?` (null = pending, true = valid, false = invalid)

**`_verifySignature()` (called in initState):**
- Calls `network_api.verifyMessageProof(senderPeerId:, signatureB64:, publicKeyB64:, canonicalPayload:)`
- Sets `_verified` accordingly

**Layout (520px max):**

**Header row:**
- Dynamic shield icon: `shieldCheck` (verified), `shieldAlert` (invalid), `shield` (pending), `shieldOff` (unsigned)
- "Message Proof" heading
- Badge: `_buildBadge()` -- "UNSIGNED", "VERIFYING...", "VERIFIED", or "INVALID" with appropriate color

**Message preview (`_MessagePreview`):**
- Chat-bubble style: `HollowAvatar` + sender name + timestamp + optional media thumbnail + text
- Media: if image/video, shows 48px thumbnail from `file.diskPath`; if other file, shows paperclip + filename
- Text truncated to 200 chars / 3 lines

**Info rows (`_InfoRow` widgets):**
- Sender Peer ID (mono, copyable)
- Timestamp (ISO 8601 + raw ms)
- Message ID (conditional, mono, copyable)
- Public Key Fingerprint (conditional, mono, copyable)
- Ed25519 Signature (conditional, mono, copyable, truncated: first 24 + "..." + last 24 chars)

**Actions:**
- "Copy Proof" ghost button -- copies full proof JSON to clipboard
- "Export Proof" ghost button -- opens `FilePicker.platform.saveFile()`, writes JSON to file
- "Close" filled button

### Widget: `_MessagePreview` (StatelessWidget)
Renders chat-style message with avatar, name, time, optional media, text.

### Widget: `_InfoRow` (StatelessWidget)
Props: `label`, `value`, `mono`, `copyable`, `truncate`. Shows label above value with optional copy icon.

### FFI calls
- `network_api.verifyMessageProof(senderPeerId:, signatureB64:, publicKeyB64:, canonicalPayload:)`

---

## ShardBundleDialog -- Shard Import/Export

**File:** `lib/src/ui/dialogs/shard_bundle_dialog.dart` (372 lines)
**Contains TWO separate dialogs.**

### Export Shards Dialog

**Entry point:** `showExportShardsDialog(context, {serverId, serverName, shardCount})`

**Widget: `_ExportShardsDialog` (StatefulWidget)**

**State fields:**
- `_exporting` -- bool

**Layout (HollowDialog, title "Export Shards"):**
- Server icon + name row
- "Export {shardCount} vault shards as a .hollow-shards bundle." description
- Actions: Cancel (ghost) + "Export" (filled, download icon, shows spinner)

**`_export()`:**
- Sanitizes server name for filename: `{safe_name}.hollow-shards`
- Opens `FilePicker.platform.saveFile()` with `.hollow-shards` extension
- Calls `archive_api.exportServerShards(serverId:, outputPath:)`
- Shows success toast with file size

### Import Shards Dialog

**Entry point:** `showImportShardsDialog(context, {onImported})`

**Widget: `_ImportShardsDialog` (StatefulWidget)**

**State fields:**
- `_importing` -- bool
- `_result` -- nullable `archive_api.ShardImportResultFfi`

**Two views:**

**Initial view (when `_result == null`):**
- "Select a .hollow-shards bundle from another ex-member." description
- Actions: Cancel (ghost) + "Select File" (filled, upload icon, shows spinner)

**Result view (`_buildResult`, when `_result != null`):**
- Title: "Import Complete"
- Result rows (`_ResultRow`): Server ID, Manifests imported, Shards imported, Shards skipped
- Green success box: "{newReconstructable} files now reconstructable"
- Actions: "Done" filled button

**`_pickAndImport()`:**
- Opens `FilePicker` for `.hollow-shards` files
- Calls `archive_api.importServerShards(archivePath:)`
- Calls `widget.onImported?.call()` on success

### Widget: `_ResultRow` (StatelessWidget)
Simple label-value row with spaceBetween alignment.

### FFI calls
- `archive_api.exportServerShards(serverId:, outputPath:)`
- `archive_api.importServerShards(archivePath:)`

---

## UserSettingsDialog -- Full User Settings Panel

**File:** `lib/src/ui/dialogs/user_settings_dialog.dart` (5234 lines)
**Trigger:** Settings gear in user bar, Ctrl+, keyboard shortcut.
**Entry point:** `showUserSettingsDialog(BuildContext context, WidgetRef ref, {openSystemTab, openUpdatesTab})`

### Toggle behavior
- `_settingsDialogOpen` top-level bool prevents double-open; calling when open pops the dialog (toggle pattern)
- Dialog completion resets the flag via `.then((_) => _settingsDialogOpen = false)`

### Tab enum: `_SettingsTab`
Values: `profile`, `system`, `security`, `updates`, `about`

### Widget: `_UserSettingsContent` (ConsumerStatefulWidget)

**Constructor fields:**
- `localPeerId`, `displayNameController`, `statusController`, `aboutMeController`
- `initialTab` -- defaults to profile, overridden by `openSystemTab`/`openUpdatesTab` params

**State fields (pending changes applied only on Save):**
- `_liveDisplayName`, `_liveStatus` -- live preview values
- `_pendingAvatarBytes`, `_pendingBannerBytes`, `_avatarChanged`, `_bannerChanged`
- `_activeTab` -- current tab
- `_pendingDarkMode`, `_pendingMinimizeToTray`, `_pendingProxy`, `_pendingDockMode`
- `_pendingDisableAnimations`, `_pendingInvisible`
- `_pendingAutoDownloadThreshold` (default 169 MB), `_pendingCacheCap` (default 1024 MB)
- `_initialAccentHue` -- for cancel revert
- Various `_*Initialized` bools to track async provider hydration

**Layout (680x540, fixed height):**
- "Settings" heading
- Two-column: 140px tab rail (left) | vertical divider | content area (right)
- Actions row: Cancel (ghost, reverts accent hue) + Save (filled)

### Profile Tab (`_buildProfileTab`)

**Left column (200px): Profile preview card + image controls**
- Banner: `AnimatedGifImage` or gradient fallback (deterministic color from peer ID hash)
- Avatar: `HollowAvatar` (56px) with 3px surface border, overlapping banner via `Transform.translate(offset: Offset(0, -28))`
- Display name + status preview (live from controllers)
- "ABOUT ME" section (conditional)
- Peer ID footer (last 8 chars, mono, tiny)
- Below card: Avatar row (Change/Clear) + Banner row (Change/Clear) using `_ImageRow` widget

**Right column: Edit fields**
- DISPLAY NAME: `HollowTextField` (autofocus, maxLength 32)
- STATUS: `HollowTextField` (maxLength 48)
- ABOUT ME: `HollowTextField` (maxLines 3, maxLength 128)

**Connections section:**
- `_TwitchConnectionRow` -- shows Twitch connection status, connect/disconnect buttons

**Avatar/Banner picking:**
- `_pickAvatar()` -- `FilePicker` for image, GIFs skip crop (max 1MB), others go through `showImageCropDialog(aspectRatio: 1.0)`, then `network_api.processAvatar()`
- `_pickBanner()` -- same pattern, GIFs max 2MB, crop aspect 3.0, then `network_api.processBanner()`

### System Tab (`_buildSystemTab`)

**Sections:**
- APPEARANCE: Dark Mode toggle, `_AccentColorPicker` (rainbow hue slider + preset swatches), `_BackgroundPicker` (image selection with 16:9 crop + darken opacity slider)
- LAYOUT: Dock Mode toggle (with subtitle), Disable Animations toggle
- SYSTEM: Appear Invisible toggle, Minimize to Tray toggle (desktop only)
- FILES: Auto-Download Threshold slider (34 MB - 2 GB, 50 divisions), Cache Size Limit slider (256 MB - 10 GB, 40 divisions)
- MEDIA: `_ImageQualitySelector` -- three pill chips for image quality tiers
- VOICE & VIDEO: `_AudioDeviceSettings` -- microphone/speaker/camera dropdowns + mic test + audio quality preset + ringtone picker
- KEYBOARD SHORTCUTS: display-only rows for all shortcuts (Ctrl+,, Ctrl+Shift+M, Ctrl+K, Ctrl+Shift+\, Ctrl+1, Ctrl+2, Enter, Shift+Enter, Ctrl+B, Ctrl+I, Ctrl+E, Ctrl+Shift+X, Ctrl+Shift+S)

### Security Tab (`_SecurityTab`)

**Sections:**
- RECOVERY PHRASE: loads mnemonic via `storage_api.getMnemonic()`, shows word grid (4 columns x 6 rows) when revealed, or "Hidden for security" when hidden. Reveal/Hide toggle + Copy button. Warning text. If no mnemonic stored, shows text field to enter 24 words.
- ACCOUNT BACKUP: description, "Include vault shard data" checkbox, "Include downloaded files" checkbox, "Export Backup" button -> passphrase dialog (with confirm) -> `storage_api.exportBackup()`
- VERIFY A PROOF (`_VerifyProofSection`): paste JSON or import .json file, verify button calls `network_api.verifyMessageProof()` with full payload reconstruction and tamper detection. Shows VERIFIED/INVALID result with message text, sender, context, timestamp.

### Updates Tab (`_UpdatesTab`)

**Auto-checks on tab open** via `updaterProvider.notifier.checkForUpdates()`.

**Sections:**
- Header with current version badge
- "Check for Updates" button
- Error state display (conditional)
- Download progress: linear progress bar + bytes counter, cancel button
- Extracting state: indeterminate progress
- Ready to install: "Install & Restart" button
- Version list: `_VersionCard` widgets for each version in manifest, with current/latest badges, install button

### About Tab (`_AboutTab`)

**Layout:**
- App logo (72px rounded) + "Hollow" / "Alpha Version" / "by AnonListen"
- Contact: feedback@anonlisten.com (copy) + anonlisten.com (launch)
- Follow & Support: brand icons row (YouTube, X, TikTok, Twitch, Kick | shimmer divider | Patreon, Ko-Fi) -- each uses `_BrandIcon` or `_SvgBrandIcon` with hover scale animation + `HollowTooltip`
- Legal: Privacy Policy, Terms of Use (both render markdown from `legal/` assets in a sub-dialog), Open-Source Licenses (Flutter's `showLicensePage`)

### Key sub-widgets

**`_AccentColorPicker`:** Rainbow hue slider (0-359) using custom `_RainbowSliderTrackShape`, preset swatches (Default teal + saved presets from `accentPresetsProvider`), add/remove preset via long-press.

**`_BackgroundPicker`:** Set/Change/Remove buttons, opens image picker -> 16:9 crop dialog, darken opacity slider (0.4 - 1.0) when background is set.

**`_AudioDeviceSettings`:** Enumerates devices via `win32audio.Audio.enumDevices()` (input/output) and `flutter_webrtc.navigator.mediaDevices.enumerateDevices()` (cameras). Dropdown rows for mic, speaker, camera, audio quality preset. Mic test button using `record` package with amplitude visualization. Ringtone picker: file selection + volume slider + trim button opening `_RingtoneClipEditorDialog`.

**`_RingtoneClipEditorDialog`:** RangeSlider for start/end clip (max 30s), preview playback with progress bar, save persists to `ringtoneStartProvider`/`ringtoneEndProvider`.

**`_TwitchConnectionRow`:** Shows connected Twitch username or "Connect Twitch Account" button, which opens `_TwitchDeviceCodeDialog` (device code flow identical to TwitchJoinDialog pattern). Disconnect button calls `twitch_api.twitchDisconnect()`.

**`_RestartPrompt`:** Simple dialog shown after proxy setting change, with "Restart Now" button that calls `network_api.restartNode()`.

**`_onSave()`:** Applies ALL pending changes atomically: theme mode, minimize to tray, proxy, layout mode, auto-download threshold, cache cap, animation toggle (including `SharedTickers` management), invisible mode, profile (display name, status, aboutMe, avatar, banner).

### Providers read/written
- `identityProvider`, `profileProvider`, `themeModeProvider`, `minimizeToTrayProvider`
- `proxyEnabledProvider`, `layoutModeProvider`, `disableAnimationsProvider`
- `invisibleModeProvider`, `autoDownloadThresholdProvider`, `vaultCacheCapProvider`
- `accentHueProvider`, `accentPresetsProvider`, `backgroundProvider`
- `audioInputDeviceProvider`, `audioOutputDeviceProvider`, `cameraDeviceProvider`
- `audioQualityProvider`, `imageQualityProvider`
- `ringtonePathProvider`, `ringtoneVolumeProvider`, `ringtoneStartProvider`, `ringtoneEndProvider`, `ringtoneDurationProvider`
- `updaterProvider`

### FFI calls
- `network_api.processAvatar(rawBytes:)`, `network_api.processBanner(rawBytes:)`
- `storage_api.getMnemonic()`, `storage_api.saveMnemonic(mnemonic:)`, `storage_api.exportBackup(...)`
- `network_api.verifyMessageProof(...)`, `network_api.restartNode()`
- `twitch_api.twitchIsConnected()`, `twitch_api.twitchStartDeviceFlow()`, `twitch_api.twitchPollForToken(...)`, `twitch_api.twitchDisconnect()`
