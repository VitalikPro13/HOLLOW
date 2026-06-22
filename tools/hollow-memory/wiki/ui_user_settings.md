# UserSettingsDialog — Application Settings

Source: `lib/src/ui/dialogs/user_settings_dialog.dart` (~5600 lines)

The largest UI file in the project. **Redesigned 2026-06-21** from a fixed 680×540 dialog with 5 lopsided tabs into a responsive (~920×680, 90% of window) dialog with a **searchable side rail of 10 focused categories** and **card-based content**. Opened via `showUserSettingsDialog()`, which acts as a toggle (re-calling while open closes the dialog).

**Auto-save model (the key behavioral change):** the old global Save/Cancel footer is GONE. Every setting now applies immediately on change (most already did — accent, background, image quality, audio devices, and all of Security were always immediate; the redesign converted the remaining 8 deferred toggles to match). **Profile is the one exception** — it keeps its own explicit "Save Profile" button (text fields + cropped images benefit from a single commit); the button is disabled and reads "Saved" until an edit dirties it. There is no accent-revert-on-cancel anymore (accent persists live, consistent with everything else).

---

## Entry Point and Toggle Behavior

`showUserSettingsDialog(BuildContext context, WidgetRef ref, {bool openSystemTab, bool openUpdatesTab})` is the public entry. A module-level `bool _settingsDialogOpen` tracks whether the dialog is currently showing. If already open, calling this function pops the existing dialog (toggle behavior). On open, it reads the current profile (display name, status, aboutMe) from `profileProvider` and creates `TextEditingController`s for each. The `initialTab` parameter deep-links: `openUpdatesTab`→Updates, `openSystemTab`→Appearance (the old "System" tab's first split-off), else Profile.

Helper: `_bannerColorFromId(String id)` generates a deterministic HSL color from a peer ID's hash code, shifted 40 degrees from the avatar hue, used as fallback banner gradient.

---

## Category Navigation System

`enum _SettingsCategory { profile, appearance, network, storage, audio, shortcuts, security, devices, backup, updates, about }` with a `_SettingsCategoryMeta` extension providing each category's `icon`, `label`, and `searchTerms` (keywords so the rail search matches settings *inside* a category, e.g. "theme"→Appearance, "relay"→Network, "recovery"→Security).

The old monolithic "System" tab (8 sections) split into **Appearance / Network / Files & Storage / Audio & Video / Shortcuts**; the old "Security" tab (7 sections) split into **Security / Devices / Backup**.

### Files & Storage category (Storage Manager, 2026-06-22)

The former separate `files` + `storage` categories are merged into one `storage` category labelled **"Files & Storage"** (`_storageCards`). Cards: **Usage** (the storage dashboard), **Cache Limits** (auto-download threshold + downloaded-files cap + vault-cache cap sliders), **Media** (image quality), **Data Location**. Mobile twin: a single `_StorageTab` (the old `_FilesTab` was removed) reached from one "Files & Storage" nav tile.

The dashboard widgets live in `lib/src/ui/settings/storage_section.dart` (shared desktop+mobile): `StorageBreakdownView` renders a modern summary header — big "Storage used" total + a segmented proportional usage bar (Downloads = accent, Vault cache = warning, Held shards = success) + a legend, a "⋯" `_CleanupMenu` (PopupMenuButton: "Clear all downloads" / "Clear vault cache"; held shards intentionally absent — read-only, deleting them hurts group availability), then a per-conversation/server list of `_ContextRow`s (avatar/channel icon, name, "size · N files", hover-reveal red trash for scoped clear). Backed by `storage_provider.dart` (`storageBreakdownProvider` + `storageActionsProvider`) and `filesCacheCapProvider` in `settings_provider.dart`. FFI: `get_storage_breakdown`, `clear_all_file_bytes`, `clear_file_bytes_for_context`, `clear_vault_cache`, `evict_files_cache`, `enforce_storage_caps` (api/storage.rs). Caps are ENFORCED after each download via `enforce_storage_caps` in `event_provider`'s `FileCompleted` handler (both sliders were no-op before). Clearing bytes keeps the signed FileHeader rows so messages render as re-downloadable cards.

The 188px-wide left rail has: "Settings" heading, a `HollowTextField` **search filter** (updates `_searchQuery`, filters via `_filteredCategories`), then a scrolling `ListView` of `_TabItem`s for the matching categories. If the active category gets filtered out mid-type, `activeForContent` falls back to the first match so the content area never goes blank. The content area is a `Stack`: `_buildCategoryContent()` + a floating top-right X close button (`Positioned`, no tooltip).

`_buildCategoryContent()` dispatches via a Dart 3 `switch`: Profile → `_buildProfileTab()`; Appearance/Network/Files/Audio/Shortcuts → `_cardList(_xxxCards())` (lists of `_SettingsCard`); Security/Devices/Backup/Updates/About → standalone widgets (`_SecurityTab`, `_DevicesCategory`, `_BackupCategory`, `_UpdatesTab`, `_AboutTab`). Content padding is `fromLTRB(xl, 44, xl, xl)` — the 44px top clears the floating X.

### _SettingsCard
The visual unit of the redesign. `StatelessWidget` with `title` + `children`. Renders an uppercase caption title + a bordered, `surface`-tinted rounded container. Categories are short stacks of these instead of one undifferentiated scroll.

### _TabItem
Stateless widget. Props: `icon` (IconData), `label` (String), `isActive` (bool), `onTap` (VoidCallback). Renders a `HollowPressable` with `subtle: true`, icon + label in a Row. Active state: icon uses `hollow.accent`, label uses `hollow.textPrimary` with `FontWeight.w600`. Inactive: icon and label use `hollow.textSecondary`.

---

## Dialog Chrome and Layout

`_UserSettingsContent` is a `ConsumerStatefulWidget`. The dialog container: `ConstrainedBox` sized responsively — `maxWidth = min(screenW*0.9, 920)`, `maxHeight = min(screenH*0.86, 680)`, minHeight 420, minWidth 360. Decorated with `hollow.elevated` at 0.96 alpha, accent-tinted border, 24px blur shadow, `clipBehavior: antiAlias`. Structure is a single `Row`: 188px rail column (header + search + category list) | 1px divider | expanded content `Stack` (cards + floating X). No footer — there is no global Save/Cancel.

---

## State Management (Auto-Save)

`_UserSettingsContentState` no longer holds `_pending*`/`_initial*`/`_*Initialized` fields for the toggles — those were removed when the deferred-save model was dropped. Toggle/slider cards read provider values directly (`ref.watch(...).valueOrNull`) and write via the notifier in `onChanged` (e.g. dark mode, dock mode, animations, invisible, minimize-to-tray, auto-download threshold, cache cap). The state class now only tracks: `_activeTab` (`_SettingsCategory`), `_searchController`/`_searchQuery`, relay selection (`_initialRelayDomain`/`_selectedRelay`/`_showAddRelay`/`_newRelayController`), `_profileDirty` (+ the avatar/banner/live-name fields for the Profile preview). `_saveProfile()` commits the profile and clears `_profileDirty`; it does NOT close the dialog.

Disable-animations applies immediately via `_setDisableAnimations()` (sets `HollowDurations.animationsDisabled` + `SharedTickers.instance` pause/resume). Relay change uses an explicit "Apply & Restart" button (`_applyRelayAndRestart()`) since it requires a process restart.

### Legacy (pre-2026-06-21) deferred-save fields — REMOVED:

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

## Categories split from the old "System" tab

The old `_buildSystemTab()` is gone. Its sections now live in per-category card builders, all returning `List<Widget>` of `_SettingsCard`s:

- **Appearance** (`_appearanceCards`): Theme card (dark mode + `_AccentColorPicker`), Background card (`_BackgroundPicker`), Layout card (dock mode, disable-animations, appear-invisible, + minimize-to-tray on desktop). All apply immediately.
- **Network** (`_networkCards`): Relay card — relay list (`_buildRelayRow`), add-relay field (`_buildAddRelayField`), and "Apply & Restart" when the selection differs from the active relay.
- **Files & Storage** (`_filesCards`): Downloads card (`_buildAutoDownloadSlider`), Cache card (`_buildCacheCapSlider`), Data Location card (`_buildDataLocation` + open-folder), Media card (`_ImageQualitySelector`). Sliders read/write providers directly.
- **Audio & Video** (`_audioCards`): Devices card wrapping `_AudioDeviceSettings`.
- **Shortcuts** (`_shortcutCards`): General + Chat Input cards of `_ShortcutRow`s.

The sub-widgets (`_AccentColorPicker`, `_BackgroundPicker`, `_AudioDeviceSettings`, `_ImageQualitySelector`, `_ShortcutRow`, `_ToggleRow`) are unchanged and documented below.

### (Legacy) System Tab sections — for reference

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

**Mic Gain** — Slider (34%–200%, 83 divisions) indented below the Microphone row, with a caption line ("Boosts your outgoing voice… limiter at -3 dB prevents clipping."). Default 100%. Reads/writes `micGainProvider` (clamped to `kMicGainMin`=0.34 / `kMicGainMax`=2.0 in `settings_provider.dart`). Drives the native **post-APM capture makeup gain + soft limiter** via `Helper.setCaptureGain()` (NOT `setVolume`, which only scales remote tracks — see `services_media_storage.md` / the voice services). Floor is 0.34 not 0 because the gain feeds a real native stage; 0 would mute the user. Applies live mid-call.

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

## RingtoneClipEditorDialog (Shared)

**File:** `lib/src/ui/dialogs/ringtone_clip_editor_dialog.dart` (extracted from `user_settings_dialog.dart`)
**Entry point:** `showRingtoneClipEditor(BuildContext context, String filePath)` — opens via `showHollowDialog`.

`ConsumerStatefulWidget`. A `HollowDialog` with title "Trim Ringtone" for selecting a clip range within an audio file. Used by both desktop (System tab) and mobile (Settings > System > Ringtone > Trim button).

**Redesigned (2026-06)** to fix two issues: action buttons clipped off-screen on small iPhones, and imprecise trimming on long tracks (a single full-track RangeSlider gave ~0.75s/pixel on a 5-min file). The clipping fix is partly in `HollowDialog` itself (it now caps `maxHeight` to the screen so the Flexible scroll region clamps and the sticky action bar stays visible — benefits every dialog).

### State:
- `_player` (AudioPlayer?), `_totalDuration` (double, seconds, default 60), `_start` / `_end` (double, seconds), `_currentPos` (double), `_isPlaying` (bool), `_loaded` (bool), `_posSub` (StreamSubscription?), `_bars` (List<double> — deterministic pseudo-waveform seeded from the file path hash; no PCM decode, just visual context for the selection window).

### Initialization (`_loadDuration()`)
Reads saved `ringtoneStartProvider` and `ringtoneEndProvider` values. Uses cached duration from `ringtoneDurationProvider`. Clamps end to total duration, ensures start < end, enforces the 30s max clip (`_kMaxClip`).

### UI Layout
- **File info**: File name + total duration formatted as mm:ss.x.
- **`_WaveformSelector`**: a scrubbable waveform strip (64 bars via `_WaveformPainter`) with two draggable handles for start/end and a draggable middle to pan the whole window. Bars inside the selection are accent-colored, outside are border-colored; a playhead line shows during preview. Replaces the old single full-track `RangeSlider`.
- **Numeric start/end with ±nudge** (`_NudgeField`): start (left) and end (right) shown as mm:ss.x with − / + buttons (0.5s steps) flanking each — frame-accurate adjustment, reliable on tiny screens. Clip duration shown center (accent).
- **Move-window row** (`_StepButton`): ±1s / ±5s chevrons to shift the whole selection window, preserving its length (handy on long tracks).
- **Playback progress** (only during playback): `LinearProgressIndicator` showing position within the selected clip range.
- Helpers `_setStart`/`_setEnd`/`_nudgeWindow` keep `start < end` and clip ≤ `_kMaxClip` (30s).

### Playback
`_startPreview()`: Creates AudioPlayer, sets volume from `ringtoneVolumeProvider`, plays file, seeks to `_start`. Listens to `onPositionChanged` — updates `_currentPos`, loops back to start if position exceeds `_end`.

`_stopPreview()`: Cancels subscription, stops and disposes player.

### Actions
Laid out as a single full-width `Row` (so Preview sits on the LEFT, Cancel/Save on the right — a bare `HollowDialog` actions Wrap right-aligns everything):
- **Preview/Stop** (ghost button, left): Play/square icon, starts or stops preview.
- **Cancel** (ghost button, right): Closes dialog without saving.
- **Save** (filled button, right): Writes `_start` and `_end` to `ringtoneStartProvider` and `ringtoneEndProvider`, stops preview, closes dialog.

---

## Security / Devices / Backup categories (split from the old Security tab)

The old `_SecurityTab` (which held App Lock, Device Protection, Recovery Phrase, Account Backup, Your Devices, Multi-Device, Verify a Proof) split into three categories:

- **`_SecurityTab`** (Security category) — now just **App Lock + Device Protection + Recovery Phrase + Verify a Proof** (the proof verifier moved here, at the bottom, per 2026-06-21 feedback). Still a `StatefulWidget`.
- **`_DevicesCategory`** (`ConsumerStatefulWidget`) — Your Devices card (`_DevicesSection`), Link a Device card (`showDeviceLinkDialog`), Maintenance card (`_resetDeviceLists` → `network_api.resetDeviceLists()`). Each in a `_SettingsCard`.
- **`_BackupCategory`** (`StatefulWidget`) — Account Backup card only (`_includeVault`/`_includeFiles` checkboxes + `_exportBackup`).

The passphrase prompt is now a **top-level** `askPassphraseDialog(context, title, {confirm, buttonLabel})` shared by App Lock and Account Backup (was a private method on `_SecurityTabState`).

### Security category (`_SecurityTab`)

`StatefulWidget` (not Consumer — uses `storage_api` directly).

### State:
- `_revealed` (bool) — whether mnemonic is shown
- `_loading` (bool) — loading mnemonic from storage
- `_includeVault` / `_includeFiles` (bool) — backup checkboxes
- `_mnemonic` (String?) — the 24-word recovery phrase
- `_error` (String?) — load error

### APP LOCK Section

**Protection status state**: `_hasPassword`, `_hasOsKeychain`, `_osKeychainAvailable`, `_protectionLoading` — loaded via `identity_api.getIdentityProtectionStatus()` in `initState`.

**No password set**: Description text about setting password to encrypt identity. "Set Password" filled button calls `_enablePassword()` which opens `_askPassphrase()` dialog then calls `identity_api.enablePasswordProtection(password, requireOnLaunch: true)`.

**Password active** (flags=0x01 or 0x03):
- Green shieldCheck icon + "Password protection active" status text.
- **"Ask for password on launch" toggle** (only shown when `_osKeychainAvailable`): `HollowToggle` with value `!_hasOsKeychain`. When ON (default, flags=0x01) — password prompt on every launch. When OFF (flags=0x03) — password-derived key cached in OS keychain via `identity_api.setRequirePasswordOnLaunch()`, app opens silently but identity file is still encrypted.
- Change Password / Remove Password ghost buttons.

**Methods**: `_enablePassword()`, `_changePassword()`, `_removePassword()`, `_toggleRequireOnLaunch(bool)`.

### DEVICE PROTECTION Section

Only shown when `!_hasPassword && _osKeychainAvailable`. Standalone device-level encryption (flags=0x02) using Windows Credential Manager + DPAPI fallback (or macOS Keychain).

- **Active state**: Green monitor icon + "Device protection active" + "Remove Device Protection" ghost button.
- **Inactive state**: Description text + "Enable Device Protection" outline button.
- **Warning**: Orange alertTriangle icon — "Windows may lose device credentials after OS reinstalls or admin password resets. Always keep your 24-word recovery phrase backed up."

**Methods**: `_enableOsKeychain()`, `_disableOsKeychain()`.

**Recovery tip**: Info icon + "Forgot your password? You can recover with your 24-word recovery phrase."

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

### YOUR DEVICES Section (`_DevicesSection` / `_DeviceRow`)

`_DevicesSection` (a `ConsumerStatefulWidget`) lists every device linked to this account, sourced from `myDevicesProvider` (which derives from `deviceLinkProvider` — the Dart mirror of the Rust resolver — inverted against this device's master). `<= 1` device → a "Only this device is linked…" hint. Otherwise active devices render first, with offline/ghost devices behind a "Show all (N offline)" toggle (`_showAll`).

**`initState` refresh (critical):** posts a frame callback that calls `deviceLinkProvider.refresh()` + `deviceLabelProvider.refresh()` + `ref.invalidate(localDevicePeerIdProvider)`. Without this, the list rendered empty/stale after an app restart — `deviceLinkProvider` is only warmed once at event-stream start (races node readiness) and on `DeviceListUpdated` network events, with no live listener while Settings is closed. The data was always persisted in the DB; only the Dart mirror was stale. The mobile twin (`mobile_settings_tab.dart:_DevicesSectionMobile`) does the same.

**`_DeviceRow`** (per device): smartphone icon + label (or shortened peer id) + "This device" badge for the running device + `online`/`offline` subtitle. Action buttons (other devices only, hidden for "This device"):
- **Sync from this device** (`LucideIcons.refreshCw`, teal when online) → `_syncFrom()`. Confirm dialog ("Pull servers and friends FROM this device onto THIS device… only adds what's missing, nothing removed, messages unaffected; must be online") → FFI `network_api.requestStateSync(sourceDeviceId: device.peerId)`. The tapped device is the SOURCE, this device is the DESTINATION. The source responds (`SiblingStateSyncRequest` handler in swarm.rs) by re-announcing all its servers (drives the destination's join flow → `ServerJoined` → list refresh) + re-sharing its friends. Servers + friends only, not messages. The deterministic escape hatch for when automatic sibling sync didn't converge.
- **Rename** (`pencil`) → `_rename()` → `deviceLabelProvider.setLabel()` (local label, `device_labels` table).
- **Remove** (`trash2`, error color) → `_remove()` → confirm → `network_api.revokeDevice()` (Step 7 revocation).

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

## TwitchDeviceCodeDialog (Shared)

**File:** `lib/src/ui/dialogs/twitch_device_code_dialog.dart` (extracted from `user_settings_dialog.dart`)
**Entry point:** `showTwitchDeviceCodeDialog(BuildContext context, {VoidCallback? onSuccess})` — opens via `showHollowDialog`.

`TwitchDeviceCodeDialog` — `StatefulWidget`. State: `_userCode`, `_verificationUri`, `_error`, `_polling`, `_done`. Used by both desktop (Settings > Profile > Twitch > Connect) and mobile (Settings > Profile > Twitch > Connect).

### Flow:
1. `initState()` calls `_startFlow()`.
2. `_startFlow()`: Calls `twitch_api.twitchStartDeviceFlow()`, gets user code + verification URI + device code + interval.
3. Starts `_pollForToken(deviceCode, intervalSecs)`: Calls `twitch_api.twitchPollForToken()` which blocks until authorized or error.
4. On success: sets `_done = true`, calls `onSuccess` callback, auto-closes after 1200ms via `Navigator.of(context, rootNavigator: true).pop()`.
5. "Open Twitch" button uses `LaunchMode.externalApplication` to open system browser (not in-app webview).

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
