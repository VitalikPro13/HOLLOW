# UserSettingsDialog — Application Settings

Source: `lib/src/ui/dialogs/user_settings_dialog.dart` (5235 lines)

The largest UI file in the project. A full-screen modal dialog with five tabs: Profile, System, Security, Updates, and About. Opened via `showUserSettingsDialog()`, which acts as a toggle (re-calling while open closes the dialog). All settings use a deferred-save pattern: changes are staged in local state and only committed to providers on Save. Cancel reverts everything (including accent color).

---

## Entry Point and Toggle Behavior

`showUserSettingsDialog(BuildContext context, WidgetRef ref, {bool openSystemTab, bool openUpdatesTab})` is the public entry. A module-level `bool _settingsDialogOpen` tracks whether the dialog is currently showing. If already open, calling this function pops the existing dialog (toggle behavior). On open, it reads the current profile (display name, status, aboutMe) from `profileProvider` and creates `TextEditingController`s for each. The `initialTab` parameter allows deep-linking to System or Updates tab.

Helper: `_bannerColorFromId(String id)` generates a deterministic HSL color from a peer ID's hash code, shifted 40 degrees from the avatar hue, used as fallback banner gradient.

---

## Tab Navigation System

`enum _SettingsTab { profile, system, security, updates, about }`

The dialog uses a left-side rail (140px wide) with five `_TabItem` widgets, separated by a 1px vertical divider from the content area. Tab switching is immediate via `setState()`. The content area uses a Dart 3 `switch` expression on `_activeTab`. Profile and System tabs are built inline by `_buildProfileTab()` and `_buildSystemTab()`. Security, Updates, and About are standalone widget classes (`_SecurityTab`, `_UpdatesTab`, `_AboutTab`).

### _TabItem
Stateless widget. Props: `icon` (IconData), `label` (String), `isActive` (bool), `onTap` (VoidCallback). Renders a `HollowPressable` with `subtle: true`, icon + label in a Row. Active state: icon uses `hollow.accent`, label uses `hollow.textPrimary` with `FontWeight.w600`. Inactive: icon and label use `hollow.textSecondary`.

---

## Dialog Chrome and Layout

`_UserSettingsContent` is a `ConsumerStatefulWidget`. The dialog container: `ConstrainedBox` with maxWidth 680, maxHeight 540, minHeight 540, minWidth 400. Decorated with `hollow.elevated` at 0.92 alpha, accent-tinted border, 24px blur shadow. Structure top-to-bottom:

1. **Header** — "Settings" heading text, padded xl on sides and top.
2. **Tab rail + content** — `Row` with 140px rail column, 1px divider, expanded content area.
3. **Actions footer** — Cancel (ghost button) and Save (filled button), right-aligned.

Cancel reverts the accent hue to `_initialAccentHue` via `accentHueProvider.notifier.setHue()`. Save calls `_onSave()`.

---

## State Management and Deferred Save Pattern

`_UserSettingsContentState` maintains pending state for every toggle and slider. Each setting follows the pattern: `_pending*` (current UI value), `_initial*` (value when dialog opened), `_*Initialized` (whether the async provider has loaded). During `initState()`, synchronous providers are read immediately. Async providers are initialized lazily via `ref.listen()` in `build()` — when the first value arrives, `_*Initialized` is set true and `_pending*`/`_initial*` are synchronized.

### Pending state fields:
- `_pendingDarkMode` (bool) — from `themeModeProvider`
- `_pendingMinimizeToTray` (bool) — from `minimizeToTrayProvider` (async)
- `_pendingProxy` (bool) — from `proxyEnabledProvider` (async)
- `_pendingDockMode` (bool) — from `layoutModeProvider` (async), true = dock, false = classic
- `_pendingDisableAnimations` (bool) — from `disableAnimationsProvider` (async)
- `_pendingInvisible` (bool) — from `invisibleModeProvider` (sync)
- `_pendingAutoDownloadThreshold` (int, MB) — from `autoDownloadThresholdProvider` (async), default 169
- `_pendingCacheCap` (int, MB) — from `vaultCacheCapProvider` (async), default 1024
- `_initialAccentHue` (double) — from `accentHueProvider`
- `_pendingAvatarBytes` / `_pendingBannerBytes` (Uint8List?) — null = no change, empty = clear
- `_avatarChanged` / `_bannerChanged` (bool) — whether user modified the image
- `_liveDisplayName` / `_liveStatus` (String) — updated on every keystroke via `_onFieldChanged()` listener for live preview

### _onSave() — what happens on Save:
1. Applies `themeModeProvider` to dark/light based on `_pendingDarkMode`.
2. If minimize-to-tray changed, calls `minimizeToTrayProvider.notifier.setEnabled()`.
3. If proxy changed, calls `proxyEnabledProvider.notifier.setEnabled()`.
4. If layout mode changed, calls `layoutModeProvider.notifier.setMode()`.
5. If auto-download threshold changed, calls `autoDownloadThresholdProvider.notifier.setThreshold()`.
6. If cache cap changed, calls `vaultCacheCapProvider.notifier.setCap()`.
7. If disable-animations changed, calls `disableAnimationsProvider.notifier.setEnabled()`, updates `HollowDurations.animationsDisabled` and `SharedTickers.instance.disabled`. If disabling, pauses shared tickers. If enabling, starts and resumes them.
8. If invisible mode changed, calls `invisibleModeProvider.notifier.setInvisible()`.
9. Calls `profileProvider.notifier.updateMyProfile()` with display name, status, aboutMe, and optionally avatar/banner bytes.
10. Pops the dialog.
11. If proxy changed, shows `_RestartPrompt` dialog.

---

## Profile Tab

Built by `_buildProfileTab(HollowTheme hollow)`. Layout is a `SingleChildScrollView` with a two-column Row at top, then a divider, then a Connections section.

### Left Column: Profile Preview Card (200px wide)
A live-updating miniature profile card showing how the user's profile will appear.

**Banner area** (70px tall): Shows `_pendingBannerBytes` if `_bannerChanged`, else saved `profileProvider` banner. Uses `AnimatedGifImage` for GIF support. Falls back to deterministic gradient from `_bannerColorFromId()`.

**Avatar** (56px): `HollowAvatar` with 3px surface-colored border. Offset -28px to overlap the banner. Shows pending avatar if changed, else saved avatar. `animate: true` for GIF avatars.

**Display name**: `previewName` = live text if non-empty, else `displayNameFor()` fallback. Styled as 14px bold subheading.

**Status**: Shown only if non-empty. 10px italic caption, textSecondary color.

**About Me**: Shown only if non-empty. Section header "ABOUT ME" (9px bold uppercase) + 10px caption, max 3 lines.

**Peer ID footer**: Last 8 chars of peer ID in 8px mono, with tiny copy icon, at 0.35 alpha.

### Image Management Rows (below preview card)
Two `_ImageRow` widgets for Avatar and Banner. Each checks whether an image currently exists (pending or saved) to determine whether the trash/clear button is enabled.

`_ImageRow` — Stateless widget. Shows a pressable label with image icon (accent-colored), a 1px divider line, and a trash icon. Trash uses `AnimatedOpacity` at 0.25 when no image exists, 1.0 when clearable. Trash icon colored `hollow.error` when active.

### Avatar Picking Flow (`_pickAvatar()`)
1. Opens `FilePicker.platform.pickFiles(type: FileType.image)`.
2. GIF check: if `.gif`, skips crop. Max 1MB, stores raw bytes directly.
3. Non-GIF: opens `showImageCropDialog()` with 1:1 aspect ratio, "Crop Avatar" title.
4. Cropped bytes passed to `network_api.processAvatar(rawBytes:)` (Rust FFI for WebP conversion/optimization).
5. Result stored in `_pendingAvatarBytes`, `_avatarChanged = true`.

`_clearAvatar()`: Sets `_pendingAvatarBytes` to empty `Uint8List(0)`, `_avatarChanged = true`.

### Banner Picking Flow (`_pickBanner()`)
Same as avatar but: GIF max 2MB, crop aspect ratio 3.0 (3:1), processes via `network_api.processBanner()`.

### Right Column: Edit Fields
Three `HollowTextField` inputs stacked vertically:
- **DISPLAY NAME** — `_FieldLabel` + text field, hintText "Enter a display name", autofocus, maxLength 32.
- **STATUS** — hintText "What are you up to?", maxLength 48.
- **ABOUT ME** — hintText "Tell us about yourself", maxLines 3, maxLength 128. `onChanged` calls `setState()` to update the preview card.

### Connections Section
Separated by 1px divider + spacing. Header: `_FieldLabel(label: 'CONNECTIONS')`.

**_TwitchConnectionRow** — `ConsumerStatefulWidget`. On init, calls `_checkConnection()` which queries `twitch_api.twitchIsConnected()`, `twitchGetUserId()`, `twitchGetUsername()`. Shows:
- Twitch icon (purple #9146FF) from `SimpleIcons.twitch`.
- "Twitch" label + status subtitle ("Connected as {username}" or "Connect to join Twitch-verified servers").
- Connected: ghost "Disconnect" button. Calls `twitch_api.twitchDisconnect()`.
- Not connected: outline "Connect" button. Calls `_connect()` which opens `showTwitchDeviceCodeDialog()`. On success callback, iterates all servers with `twitch_verification_enabled == 'true'` and sets the Twitch username via `crdt_api.setTwitchUsername()`.

---

## System Tab

Built by `_buildSystemTab(HollowTheme hollow)`. A `SingleChildScrollView` with sections: Appearance, Layout, System, Files, Media, Voice & Video, Keyboard Shortcuts.

### APPEARANCE Section

**Dark Mode toggle** — `_ToggleRow` with moon/sun icon (dynamic based on state). Toggles `_pendingDarkMode`.

**Accent Color picker** — `_AccentColorPicker` widget (documented below).

**Background picker** — `_BackgroundPicker` widget (documented below).

### LAYOUT Section

**Dock Mode toggle** — `_ToggleRow` with `LucideIcons.layoutDashboard`. Subtitle: "Bottom bar with friends strip". Toggles `_pendingDockMode`.

**Disable Animations toggle** — `_ToggleRow` with `LucideIcons.zap`. Subtitle: "Turn off UI transitions and effects". Toggles `_pendingDisableAnimations`.

### SYSTEM Section

**Appear Invisible toggle** — `_ToggleRow` with `LucideIcons.eyeOff`. Subtitle: "Show as offline to other users". Toggles `_pendingInvisible`.

**Minimize to Tray toggle** — Only shown on desktop (`Platform.isWindows || Platform.isLinux || Platform.isMacOS`). `_ToggleRow` with `LucideIcons.minimize2`. Toggles `_pendingMinimizeToTray`.

### FILES Section

**Auto-Download Threshold** — Icon + label ("Auto-Download Threshold") + dynamic subtitle showing current MB value. Below: a `Slider` with range 34 MB to 2048 MB (2 GB), 50 divisions. Styled with accent color track and 6px thumb. Range labels "34 MB" and "2 GB" below the slider.

**Cache Size Limit** — Icon `LucideIcons.hardDrive` + label + subtitle showing GB value and explanation ("server file downloads are evicted when cache exceeds this"). Slider range 256 MB to 10240 MB (10 GB), 40 divisions. Label dynamically shows GB when >= 1024. Range labels "256 MB" and "10 GB".

### MEDIA Section

**Image Quality** — `_ImageQualitySelector` widget (documented below).

### VOICE & VIDEO Section

**Audio/Video devices** — `_AudioDeviceSettings` widget (documented below).

### KEYBOARD SHORTCUTS Section

Two sub-sections of `_ShortcutRow` widgets:

**General shortcuts:**
| Label | Shortcut |
|---|---|
| Open Settings | Ctrl + , |
| Toggle Member Panel | Ctrl + Shift + M |
| Quick Search | Ctrl + K |
| Toggle Split View | Ctrl + Shift + \ |
| Focus Left Pane | Ctrl + 1 |
| Focus Right Pane | Ctrl + 2 |

**CHAT INPUT sub-section** (9px dimmed label):
| Label | Shortcut |
|---|---|
| Send Message | Enter |
| New Line | Shift + Enter |
| Bold | Ctrl + B |
| Italic | Ctrl + I |
| Code | Ctrl + E |
| Strikethrough | Ctrl + Shift + X |
| Spoiler | Ctrl + Shift + S |

### _ShortcutRow
Stateless. Label on left (12px body, textSecondary), `_KeyBadge` on right.

### _KeyBadge
Splits shortcut string on " + ", renders each key as a styled box (surface background, border, mono text 10px) with "+" separators between them.

---

## _AccentColorPicker

`ConsumerStatefulWidget` in the System tab's Appearance section.

**Label row**: Palette icon + "Accent Color" text + 18x18 color preview square showing `accentFromHue(currentHue)`.

**Hue slider**: Full rainbow gradient rendered by `_RainbowSliderTrackShape`. Range 0-359 (hue degrees). 14px track height, 9px white thumb, no overlay. `_RainbowSliderTrackShape` extends `SliderTrackShape`, paints a `LinearGradient` of 13 HSL colors (every 30 degrees) with rounded corners (7px radius). Changes are applied live to `accentHueProvider.notifier.setHue()` (preview updates immediately; reverted on Cancel).

**Preset swatches**: A `Wrap` of `_ColorSwatch` widgets:
- First: "Default" swatch at `defaultAccentHue`, always shown.
- Saved presets from `accentPresetsProvider` — each has right-click to remove (`onSecondaryTapUp`).
- If current hue is not already a preset and differs from default, a "+" button to save current hue as a new preset.

### _ColorSwatch
22x22 rounded square filled with `accentFromHue(hue)`. Selected state: 2px white border. Non-selected: 1px white at 0.15 alpha. Wrapped in `HollowTooltip` showing label or "Right-click to remove". Click selects, right-click removes.

---

## _BackgroundPicker

`ConsumerWidget` in the System tab's Appearance section. Watches `backgroundProvider`.

**Label row**: Image icon + "Background" text + buttons on right. If no background: "Set Image" ghost button. If background exists: "Change" + "Remove" ghost buttons.

**Set/Change flow**: Opens `FilePicker.platform.pickFiles(type: FileType.image)`, reads raw bytes, opens `showImageCropDialog()` with 16:9 aspect ratio ("Crop Background"). Cropped bytes stored via `backgroundProvider.notifier.setImage()`.

**Remove**: Calls `backgroundProvider.notifier.clearImage()`.

**Darken slider** (only shown when background exists): "Darken" label + slider range 0.4 to 1.0 (panel opacity). Accent-colored track, 7px white thumb. Current percentage shown as text. Updates `backgroundProvider.notifier.setOpacity()` live.

---

## _ImageQualitySelector

`ConsumerWidget` in the System tab's Media section. Watches `imageQualityProvider`.

Displays "Image Quality" label, a description from `current.description`, and a row of pill chips for each `ImageQuality.values` entry. Each pill is an `AnimatedContainer` (150ms) that toggles between accent-highlighted (selected) and surface (unselected) with border changes. Tapping calls `imageQualityProvider.notifier.setQuality(q)`.

Below the pills: explanatory text "Images and GIFs are converted to WebP to save bandwidth and storage. Receivers can still save them as PNG, JPG, etc."

---

## _AudioDeviceSettings

`ConsumerStatefulWidget` in the System tab's Voice & Video section. The most complex sub-widget with device enumeration, mic testing, ringtone management.

### State fields:
- `_audioInputs` — `List<win32audio.AudioDevice>` (microphones via win32audio)
- `_audioOutputs` — `List<win32audio.AudioDevice>` (speakers via win32audio)
- `_cameras` — `List<webrtc.MediaDeviceInfo>` (cameras via flutter_webrtc)
- `_loading` (bool), `_recorder` (rec.AudioRecorder?), `_ampSub` (StreamSubscription?), `_micTesting` (bool), `_micLevel` (double 0.0-1.0), `_ringtonePreview` (AudioPlayer?)

### Device Enumeration (`_loadDevices()`)
1. Enumerates audio inputs via `win32audio.Audio.enumDevices(AudioDeviceType.input)`.
2. Enumerates audio outputs via `win32audio.Audio.enumDevices(AudioDeviceType.output)`.
3. Enumerates cameras via `webrtc.navigator.mediaDevices.enumerateDevices()`, filtered to `videoinput`.
4. Auto-selects system active device (the one with `isActive == true`) if user hasn't chosen one yet for each category.

### Resolve functions
- `_resolveInputValue(String? savedId)` — validates saved ID exists in device list, falls back to active device, then first device.
- `_resolveOutputValue(String? savedId)` — same pattern for outputs.
- `_resolveCameraValue(String? savedId)` — validates against camera list, falls back to first camera.

### Device Rows (4 dropdowns)
All use `_buildDeviceRow()` — a Row with icon (14px), label (80px fixed width), and an `Expanded` dropdown. Dropdown: 32px height, styled with `hollow.elevated` background, border, chevron-down icon.

**Microphone** — `LucideIcons.mic`, items from `_audioInputs`. Value stored via `audioInputDeviceProvider.notifier.setDevice()`.

**Speaker** — `LucideIcons.volume2`, items from `_audioOutputs`. On change, also calls `webrtc.Helper.selectAudioOutput(deviceId)` to apply immediately to WebRTC.

**Camera** — `LucideIcons.camera`, only shown if cameras detected. Items from `_cameras`. Stored via `cameraDeviceProvider.notifier.setDevice()`.

**Audio Quality** — `LucideIcons.sliders`. Items from `AudioQualityPreset.values`, each showing label + bitrate + mono/stereo info. Stored via `audioQualityProvider.notifier.setPreset()`.

### Mic Test
Button row: mic/micOff icon + ghost button "Test Microphone" / "Stop Test". When testing, an expanding volume meter bar appears. The meter is a `Stack` with border background and a `FractionallySizedBox` fill colored by level: >0.5 = green (`hollow.success`), >0.02 = accent, else dim textSecondary.

`_startMicTest()`: Creates `rec.AudioRecorder`, starts a PCM16 stream at 16kHz mono with the selected input device. Listens to `onAmplitudeChanged` every 100ms. Normalizes dBFS (-60..0) to 0.0..1.0 range.

`_stopMicTest()`: Cancels amplitude subscription, stops and disposes recorder.

### Refresh Devices
`LucideIcons.refreshCw` icon + "Refresh Devices" ghost button. Sets loading and re-runs `_loadDevices()`.

### Ringtone Settings
**Ringtone selector row**: Bell icon + "Ringtone" label. Below: file name display (styled container) + "Browse" ghost button + conditional "Trim" and "X" (clear) buttons.

Browse: `FilePicker.platform.pickFiles()` with extensions `['mp3', 'wav', 'ogg', 'flac', 'm4a']`. On selection, stores path via `ringtonePathProvider.notifier.setPath()`, resets clip to 0..30s, probes duration with `AudioPlayer` and caches via `ringtoneDurationProvider`.

Trim: Opens `_RingtoneClipEditorDialog(filePath:)`.

Clear (X button): Sets ringtone path to null.

**Ringtone volume slider**: Volume icon + "Volume" label + slider (0.0-1.0) + percentage text. On `onChangeStart`, starts ringtone preview playback (loop mode). On `onChanged`, updates `ringtoneVolumeProvider` and preview player volume. On `onChangeEnd`, stops preview.

`_startRingtonePreview(double volume)`: Reads current ringtone path, creates `AudioPlayer` in loop mode at given volume, plays from disk.

`_stopRingtonePreview()`: Stops and disposes the preview player.

**Info label**: "Ringtone plays for up to 30 seconds during incoming calls."

---

## _RingtoneClipEditorDialog

`ConsumerStatefulWidget`. A `HollowDialog` with title "Trim Ringtone" for selecting a clip range within an audio file.

### State:
- `_player` (AudioPlayer?), `_totalDuration` (double, seconds, default 60), `_start` / `_end` (double, seconds), `_currentPos` (double), `_isPlaying` (bool), `_loaded` (bool), `_posSub` (StreamSubscription?)

### Initialization (`_loadDuration()`)
Reads saved `ringtoneStartProvider` and `ringtoneEndProvider` values. Uses cached duration from `ringtoneDurationProvider`. Clamps end to total duration, ensures start < end.

### UI Layout
- **File info**: File name + total duration formatted as mm:ss.
- **Range slider**: `RangeSlider` with `RangeValues(_start, _end)`, range 0 to `_totalDuration`. Enforces max 30s clip by clamping whichever thumb moved farther. Accent-colored active track, 7px round range thumb.
- **Time labels**: Start time (left), clip duration with "s clip" suffix (center, accent colored), end time (right). All use tabular figures.
- **Playback progress** (only during playback): `LinearProgressIndicator` showing position within the selected clip range.

### Playback
`_startPreview()`: Creates AudioPlayer, sets volume from `ringtoneVolumeProvider`, plays file, seeks to `_start`. Listens to `onPositionChanged` — updates `_currentPos`, loops back to start if position exceeds `_end`.

`_stopPreview()`: Cancels subscription, stops and disposes player.

### Actions
- **Preview/Stop** (ghost button): Play/square icon, starts or stops preview.
- **Cancel** (ghost button): Closes dialog without saving.
- **Save** (filled button): Writes `_start` and `_end` to `ringtoneStartProvider` and `ringtoneEndProvider`, stops preview, closes dialog.

---

## Security Tab (_SecurityTab)

`StatefulWidget` (not Consumer — uses `storage_api` directly).

### State:
- `_revealed` (bool) — whether mnemonic is shown
- `_loading` (bool) — loading mnemonic from storage
- `_includeVault` / `_includeFiles` (bool) — backup checkboxes
- `_mnemonic` (String?) — the 24-word recovery phrase
- `_error` (String?) — load error

### RECOVERY PHRASE Section

**Loading state**: 20x20 accent-colored `CircularProgressIndicator`.

**Error state**: Red error text "Failed to load mnemonic: {error}".

**No mnemonic stored**: Shows explanation text + a `HollowTextField` (300px wide) with hint "Enter 24-word recovery phrase". On submit: validates exactly 24 space-separated words, calls `storage_api.saveMnemonic()`, shows success toast.

**Mnemonic exists**:
- **Container**: Full width, padded, background colored. Border changes to warning amber when revealed.
- **Hidden state**: Center text "Hidden for security" at 0.5 alpha.
- **Revealed state**: `_buildWordGrid()` — splits mnemonic into words, renders in 4 columns x 6 rows. Each word: `RichText` with number prefix (e.g. "01. ") in dim mono + word in normal mono (11px).
- **Reveal/Hide button**: Ghost button with eye/eyeOff icon, toggles `_revealed`.
- **Copy button** (only shown when revealed): Ghost button with copy icon, copies mnemonic to clipboard, shows success toast.
- **Warning**: AlertTriangle icon (warning color) + "Anyone with these words can access your account. Never share them." (11px caption, warning color).

### ACCOUNT BACKUP Section

Description: "Exports your identity, profile, servers, friends, and messages."

**Include vault checkbox**: Custom 18x18 checkbox (accent filled when checked, check icon) + "Include vault shard data" label. `GestureDetector` toggles `_includeVault`.

**Include files checkbox**: Same pattern, toggles `_includeFiles`, label "Include downloaded files".

**Export Backup button**: Filled button with download icon. Flow (`_exportBackup()`):
1. Opens `_askPassphrase()` dialog with title "Set Backup Passphrase" and confirmation field.
2. Opens `FilePicker.platform.saveFile()` with filename "hollow-backup.hollow", extension filter `.hollow`.
3. Calls `storage_api.exportBackup(outputPath, includeVault, includeFiles, passphrase)`.
4. Shows success toast with file size in MB, or error toast on failure.

### _askPassphrase() dialog
A `showHollowDialog` with a 360px container. Shows title, passphrase `HollowTextField` (obscured, autofocused), optional confirmation field (when `confirm: true`). Cancel returns null. Encrypt button validates non-empty, matches confirmation if required, returns passphrase string.

### VERIFY A PROOF Section

`_VerifyProofSection` — `StatefulWidget`. Allows pasting or importing a proof JSON to verify Ed25519 message signatures.

**Description text**: "Paste a proof JSON or import a .json file to verify that a message was authentically signed by its sender."

**Input area**: 120px tall `TextField` (monospace 11px, expandable, no border decoration) in a bordered container. Hint shows example JSON structure.

**Buttons**: "Import File" ghost button (opens `.json` file picker) + "Verify" filled button (or "Verifying..." while processing).

**Verification flow (`_verify()`):**
1. Parses JSON, extracts `message`, `sender`, `context`, `signature` objects.
2. Validates `version == 1`, `protocol == "hollow-proof-v1"`, `algorithm == "Ed25519"`.
3. Validates required fields: peerId, publicKeyB64, signatureB64, canonicalPayload.
4. Reconstructs canonical payload from individual fields (`hollow-msg:{type}:{contextId}:{peerId}:{timestampMs}:{text}`) and compares against embedded `canonical_payload` — catches field tampering.
5. Calls `network_api.verifyMessageProof()` (Rust FFI Ed25519 verification).
6. Scrolls result into view via `Scrollable.ensureVisible()`.

**Result display (`_buildResult()`):**
- **Error**: Red container with shieldAlert icon + error message.
- **Valid/Invalid**: Accent (valid) or red (invalid) container. Shows "VERIFIED" or "INVALID SIGNATURE" badge with shield icon. Below: MESSAGE section (text, max 300 chars, 4 lines), SENDER section (selectable mono peer ID), context type + UTC ISO 8601 timestamp.

### _ProofResult
Data class: `valid` (bool), `error` (String?), `text`, `timestampMs`, `messageId`, `senderPeerId`, `contextType`, `contextId`.

---

## Updates Tab (_UpdatesTab)

`ConsumerStatefulWidget`. Auto-checks for updates on first frame (if idle or errored).

### Header
"Updates" heading + version badge chip showing `v{currentVersion}` in accent color on accent-tinted background.

### Check for Updates button
Filled button with refreshCw/loader icon. Disabled while checking. Calls `updaterProvider.notifier.checkForUpdates()`.

### Error State
Red container with alertCircle icon + error message text. Shown when `UpdateStatus.error` and `state.error != null`.

### Download Progress
Shown during `UpdateStatus.downloading` or `UpdateStatus.extracting`. Styled container with:
- Header: archive/download icon + "Extracting/Downloading v{version}..." text.
- Cancel button (X icon) — only during downloading, calls `notifier.cancelDownload()`.
- `LinearProgressIndicator`: determinate during download (`state.downloadProgress`), indeterminate during extraction.
- Bytes counter: "X MB / Y MB" using `_formatBytes()` helper (B/KB/MB formatting).

### Ready to Install
Shown when `UpdateStatus.readyToInstall`. Accent-tinted container with checkCircle icon + "Ready to install v{version}". "Install & Restart" filled button calls `notifier.installAndRestart()`. Subtitle: "Hollow will close and relaunch automatically."

### Version List
Shown when manifest is loaded. "Versions" section label + list of `_VersionCard` widgets for each version in the manifest.

### _VersionCard
Stateless. Props: `version` (VersionInfo), `isCurrent`, `isLatest`, `isDownloading`, `onInstall` (nullable).

Container styled with accent tint when current, surface otherwise. Shows:
- Version number (bold) + "Latest" badge (accent pill) if latest + "Installed" badge (gray pill) if current.
- Date text.
- Release notes (max 2 lines, ellipsis).
- "Install" outline button on right — only shown when `onInstall != null` (not current version, and updater is idle/errored).

### Empty State
When no manifest and idle: centered text "Press 'Check for Updates' to see available versions."

### Version downgrade capability
The version list shows ALL versions from the manifest, not just newer ones. Any non-current version has an "Install" button, allowing downgrade to older versions.

---

## About Tab (_AboutTab)

`StatelessWidget`. A `SingleChildScrollView` with sections separated by 0.5-alpha dividers.

### App Identity
Row: 72x72 rounded app logo (`assets/hollow_logo_rounded.png`) + Column with "Hollow" (24px heading), "Alpha Version" (accent, bold), "by AnonListen" (caption).

### Contact Section
- **Email**: Ghost button "feedback@anonlisten.com" with mail icon. Copies to clipboard on tap.
- **Website**: Ghost button "anonlisten.com" with globe icon. Opens in external browser.

### Follow & Support Section
Header: `_aboutShimmerLabel('Follow', 'Support', hollow)` — "Follow" text, shimmer line, "Support" text.

Icon row with animated shimmer divider between Follow and Support groups:

**Follow icons (left):**
- YouTube (SimpleIcons.youtube, red) -> youtube.com/@Anon_Listen
- X (SimpleIcons.x, textPrimary) -> x.com/Anon_Listen
- TikTok (SVG asset `assets/tiktok-solo-icon.svg`) -> tiktok.com/@AnonListen
- Twitch (SimpleIcons.twitch, purple) -> twitch.tv/AnonListen
- Kick (SimpleIcons.kick) -> kick.com/AnonListen

**Shimmer divider**: `_AboutShimmerLine`

**Support icons (right):**
- Patreon (SimpleIcons.patreon, textPrimary) -> patreon.com/AnonListen
- Ko-Fi (SimpleIcons.kofi) -> ko-fi.com/AnonListen

### _BrandIcon
`StatefulWidget`. Hover state: elevated background, 1.15x scale animation, icon color transitions from textSecondary to brand color. Uses `HollowTooltip` for platform name. Click opens URL externally.

### _SvgBrandIcon
Same pattern as `_BrandIcon` but renders an SVG asset. Uses `ColorFilter.mode(textSecondary, srcIn)` when not hovering, removes filter on hover to show original colors.

### _KickBotIcon
Variant with custom green color (#C0FF00). Same hover pattern. Uses `assets/kickbot-logo.svg`.

### _AboutShimmerLine
`StatelessWidget` that reads `SharedTickers.instance.shimmer` ValueListenable. Renders a 1px gradient line that animates a shimmer highlight across its width using accent color.

### Legal Section
- **Privacy Policy**: Ghost button with shield icon. Opens `_showLegalDocument()` with `legal/PRIVACY_POLICY.md`.
- **Terms of Use**: Ghost button with scroll icon. Opens `_showLegalDocument()` with `legal/TERMS_OF_USE.md`.
- **Open-Source Licenses**: Ghost button with fileText icon. Opens Flutter's built-in `showLicensePage()` with app name "Hollow", version "Alpha", and 48x48 rounded logo.

### _showLegalDocument()
Top-level function. Loads markdown from asset bundle, strips the `# Title` heading. Opens a 640x520 `showHollowDialog` with:
- Header: title text + X close button.
- 1px divider.
- Body: `Markdown` widget (selectable, custom styled). Links open externally. Custom `MarkdownStyleSheet` with Hollow typography, accent-colored links, 12px block spacing.

---

## _ToggleRow

Reusable `StatelessWidget` for System tab toggle settings. Props: `icon`, `label`, `subtitle` (optional), `value`, `onChanged`. Layout: icon (16px) + Expanded column (label + optional subtitle in 10px caption) + `HollowToggle`.

---

## _SectionLabel

`StatelessWidget`. Renders uppercase label text in 10px bold caption with 0.5 letter spacing, textSecondary color. Used throughout the System and Security tabs.

---

## _FieldLabel

`StatelessWidget`. Same style as `_SectionLabel` — uppercase, 10px, bold, letterspaced. Used in the Profile tab for field labels.

---

## _RestartPrompt

`ConsumerWidget`. Shown after proxy setting changes. 340px max-width dialog with:
- Rotate icon (32px, accent).
- "Restart Required" heading.
- "The proxy setting requires a restart to take effect." body.
- "Restart Later" ghost button (closes dialog).
- "Restart Now" filled button: calls `network_api.notifyShutdown()`, waits 200ms, spawns a new detached process of the current executable, waits 100ms, calls `exit(0)`.

---

## Twitch Device Code Dialog

`showTwitchDeviceCodeDialog(BuildContext context, {VoidCallback? onSuccess})` — top-level function opening `_TwitchDeviceCodeDialog`.

`_TwitchDeviceCodeDialog` — `StatefulWidget`. State: `_userCode`, `_verificationUri`, `_error`, `_polling`, `_done`.

### Flow:
1. `initState()` calls `_startFlow()`.
2. `_startFlow()`: Calls `twitch_api.twitchStartDeviceFlow()`, gets user code + verification URI + device code + interval.
3. Starts `_pollForToken(deviceCode, intervalSecs)`: Calls `twitch_api.twitchPollForToken()` which blocks until authorized or error.
4. On success: sets `_done = true`, calls `onSuccess` callback, auto-closes after 800ms.

### UI States:
- **Loading** (no code yet): 20x20 spinner.
- **Code displayed**: "Enter this code on Twitch:" + large user code (24px heading, letterspacing 4, tappable to copy) in accent-bordered container with copy icon. Below: polling spinner + "Waiting for authorization..." if polling.
- **Success**: Green checkCircle + "Twitch connected!" in accent.
- **Error**: Red alertCircle + error text.

### Actions:
- Error: "Close" ghost button.
- Success: Empty (auto-closes).
- Normal: "Cancel" ghost button + "Open Twitch" filled button (with Twitch icon, opens verification URI externally).

---

## Provider Dependencies Summary

Providers read/watched by this dialog:
- `identityProvider` — local peer ID
- `profileProvider` — current profile data (display name, status, aboutMe, avatar, banner)
- `themeModeProvider` — dark/light mode
- `minimizeToTrayProvider` — async, tray minimize toggle
- `proxyEnabledProvider` — async, proxy toggle
- `layoutModeProvider` — async, dock/classic layout
- `disableAnimationsProvider` — async, animation toggle
- `invisibleModeProvider` — sync, invisible status
- `autoDownloadThresholdProvider` — async, file auto-download MB threshold
- `vaultCacheCapProvider` — async, vault cache MB cap
- `accentHueProvider` — accent color hue (0-359)
- `accentPresetsProvider` — saved preset hues
- `backgroundProvider` — background image + panel opacity
- `imageQualityProvider` — async, WebP quality tier
- `audioInputDeviceProvider` — async, saved mic device ID
- `audioOutputDeviceProvider` — async, saved speaker device ID
- `cameraDeviceProvider` — async, saved camera device ID
- `audioQualityProvider` — async, audio quality preset
- `ringtonePathProvider` — async, ringtone file path
- `ringtoneVolumeProvider` — async, ringtone volume (0.0-1.0)
- `ringtoneStartProvider` / `ringtoneEndProvider` — async, clip range in seconds
- `ringtoneDurationProvider` — async, cached total duration
- `updaterProvider` — update state machine (status, manifest, progress, versions)
- `serverListProvider` — for Twitch badge propagation
