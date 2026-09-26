# Settings — the place (desktop) and the Settings tab (phone)

Rebuilt 2026-09-24 (design language session 16). The old `UserSettingsDialog`
(`dialogs/user_settings_dialog.dart`, a 920x680 modal) is **deleted**. Settings is now a
centre PLACE on desktop and the same page widgets pushed as sub-routes on the phone.

## Opening and closing (desktop)

- `ShellTab.settings` in `core/providers/shell_tab.dart`, flag `settingsTabOpenProvider`
  (`core/providers/settings_place_provider.dart`), written ONLY by `setShellTab()`.
- Open with `openSettings(read, {SettingsCategory? category})`; toggle with
  `toggleSettings(read)`. Callers: the dock gear (`bottom_bar.dart`, which carries the
  `NavSelectionMark` while open; `_Places` excludes settings from the Places mark/fold),
  Classic's `UserBar` gear (`selected` while open), Ctrl+, (`hollow_shell.dart`, toggles),
  the tray (`tray_service.dart`, opens, never toggles), Home's `editProfile` /
  `openUpdate` (profile / about), the profile card's edit (`profile_card_body.dart`).
- Unlike the other places it does NOT clear the selection, so closing (gear, Ctrl+,,
  Escape, the X) returns to the conversation underneath. Every navigation site that calls
  `setShellTab(null)` (servers, Home, DMs, notification taps) closes it too.
- `settingsCategoryProvider` remembers the page across closes.
- `hollow_shell.dart` renders `SettingsPlace` in place of the whole centre row: Dock mode
  swaps the ClipRect row (sidebar + chat + member panel), Classic keeps the `ServerStrip`
  and swaps the rest. Split view state survives underneath.

## The place (`settings/settings_place.dart`)

- Rail 240 (`kSettingsRailWidth`) on `surface`: "Settings" title on the rail's box edge
  (12, where the search box and item fills start), the search field, then the groups from
  `settings_catalog.dart` (Account: Profile, Security, Devices / App: Appearance,
  Accessibility, Notifications, Audio & video, Shortcuts / Connection and data: Network,
  Files & storage), a divider, About. Labels that join two words use "&" in sentence
  case, on this rail and Server settings' alike (since 2026-09-26). `SettingsRailItem`: grey 16 icon, `label` text, 32
  tall so all eleven fit a 768 px laptop; the active one is an `elevated` fill + textPrimary.
- Page column: `kSettingsPageMaxWidth` 720, padding 32 left / 48 right, one
  `SingleChildScrollView` owned by the host. The X (`Close settings (Esc)`) sits top right.
- **Centred pair (layout C):** a `LayoutBuilder` computes `bleed` so the block from the rail's
  box edge to the page column's end is centred; the bleed is painted `surface` (the rail
  colour runs to the window's left edge) and the page's scroll area still reaches the right
  edge. Below the pair's width bleed is 0 (the pair hugs the left edge). Design language 5.2.
- Search: `kSettingsSearchIndex` (label, category, keywords) plus category names; results
  replace the page; tapping one opens its page. Escape clears a search first, then closes.
- `_UnsavedProfileBar`: floats at the column's foot on every page while
  `profileDraftProvider.dirty`, ghost Reset + filled Save (loading, toasts).

## The kit (`settings/settings_kit.dart`)

One row for every page, desktop and phone:
- `SettingsPage(title, intro, children)`: each child is ONE big section; a `HollowDivider`
  with xl above and below separates each two (Vitalik 2026-09-24: spacing alone read as
  clutter). Top-level sections drop their own top gap (`_SettingsTopLevel` marker); nested
  ones keep xl.
- `SettingsSection(title, subtitle, action, children)`, `SettingsRow(title, subtitle |
  subtitleWidget, leading, trailing, wideTrailing, enabled, titleTrailing, monoTitle)`,
  `SettingsSwitchRow`, `SettingsChoiceRow<T>` (chips; its subtitle describes the SELECTED
  option), `SettingsSliderRow` (slider 200 + mono readout), `SettingsExpandRow` (reveals a
  list), `SettingsAdvanced` (the one fold per page, open when something inside is
  non-default), `SettingsNote`.
- `SettingsDensity(touch: true)`: rows 56, wide controls stack under the title, the page
  title hides (the phone's route bar names the page).
- No cards and no row icons. `leading` only for the thing the row IS (avatar, server,
  device tile). `SettingsCard` survives for Server settings until its own pass.

## Pages (`settings/pages/*_page.dart`, via `settingsPageFor(category)`)

- **Profile** (`pages/profile_page.dart`): Avatar / Banner / Frame rows (48 slot, banner
  2.5:1), Display name (hint "Enter a display name"), Status, About me, and a 220 live
  preview card (`ProfilePreviewCard`, above the rows on touch); Presence (Appear invisible);
  Connections (Twitch); Your art (`OwnedArtPanel`: Wear / Worn, More > Remove from Your art
  with a confirm, Rust `remove_owned_art` local only); Support marks
  (`SupportMarksSection`: two toggles, marks, codes waiting; the verified Twitch account is
  NOT listed there, Connections' Disconnect is its one control). The last two are absent on
  store builds. All edits live in `profileDraftProvider` (text controllers, staged
  images with pick generations, frame), which survives leaving the page.
- **Security**: App lock (desktop password or phone PIN/biometric), Recovery (phrase, backup
  file export with its options inside the export dialog), Privacy, People (verified,
  blocked as expand rows), Advanced (check a message proof, a dialog), Danger zone.
- **Devices**: device rows (`titleTrailing` "This device" badge; others in a More menu),
  Link another device (the page's filled), Advanced (sync check, reset the device list).
- **Appearance**, **Accessibility**, **Notifications**, **Audio & video** (call quality
  spells out the bitrate), **Shortcuts** (desktop only), **Network** (relay row with Change,
  Relay health expand, offline delivery, GIFs and previews, Advanced keys/proxies),
  **Files & storage** (usage, downloads, image quality, data folder + profiles, Advanced
  caches), **About** (header, Updates incl. What's new and Earlier versions, contact with
  hollow.anonlisten.com, legal).

## Phone (`mobile/tabs/mobile_settings_tab.dart`)

The tab lists the identity row, the same groups (Shortcuts omitted), About, then Help and
the Shop, then the status/news/relay cards. Each row pushes `_SettingsSubPage` hosting
`SettingsDensity(touch: true, settingsPageFor(c))`. Profile's route bar carries Reset +
Save for the draft. Phone-only flows live in the shared pages behind platform checks.
