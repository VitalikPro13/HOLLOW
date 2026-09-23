# Hollow design language and the grand redesign

**Status:** IN PROGRESS, sessions 1 to 8 done 2026-09-19 (decisions applied, sweeps 3c to 9 done); session 9 (2026-09-23) wrote the screen standards and mocked up Home. Direction agreed 2026-09-14, research the same day.

**Read this section first in a new session.** It is the handoff: what exists, what it changed, and the next thing to pick up. Everything below section 0 is the original plan, kept for its research digest and its screen-by-screen program; where it and this section disagree, this section is right.

---

## STATE OF PLAY (2026-09-23)

### What shipped

| Artifact | What it is |
|---|---|
| `reports/reference/HOLLOW_DESIGN_LANGUAGE.md` | **The live rule set.** Supersedes section 3 below. Principles, tokens, the two label components, the button-variant rule, states, the forbidden list, and 11 open decisions. |
| `.claude/skills/hollow-ui/` | The skill every agent loads before widget work. Repo-tracked (`.gitignore` now admits `.claude/skills/`), so it reaches the VM, the mini and any other machine. CLAUDE.md gates on it. |
| `test/design_language_guard_test.dart` | The ratchet: 13 rules, a baseline count each. Fails when a count goes UP **and** when it goes DOWN without the baseline being lowered in the same commit. `HOLLOW_DESIGN_BASELINE=print` prints current counts. |
| 7 primitives in `lib/src/ui/components/` | `HollowBadge`, `HollowChip`, `HollowSectionHeader`, `HollowEmptyState`, `HollowDivider` (+`HollowVerticalDivider`), `HollowListRow`, `HollowSkeleton`. 27 widget tests in `test/widget/design_primitives_test.dart`. |
| `integration_test/probe/design_gallery.dart` | **The design sheet.** `scripts/ui_probe.ps1 -Widget design-gallery` renders every primitive in every state, dark beside light, with no data dir, identity or relay. This replaced phase 0's toggle route. |
| `scripts/probe_scenarios/fleet/design_sweep_mobile.json` | The mobile half of a sweep: Archive sub-tabs, inner tabs, Settings. One peer, ~23 s on an iOS Simulator. |

New tokens: `HollowTypography.micro` (10/500, absorbs 155 orphaned sites) and `monoSmall` (11/400); `HollowRadius.xs` 4 exposed as `hollow.radiusXs`.

### Sweeps done

- **Sweep 1, sub-tab pills.** Five classes doing one job into `HollowChip`: `_SubTabPill` (byte-identical in `shell/archive_dashboard.dart` and `share/share_dashboard.dart`), `_TabPill` (`archive/archive_conversation_list.dart`), `_SubTabPill` + `_InnerTabPill` (`mobile/tabs/mobile_archive_tab.dart`). They had 2 radii plus a 20px pill, 3 paddings, 2 type sizes, and the mobile one used a SOLID accent fill for mere selection.
- **Sweep 2, the Shop.** `_FilterPill` into `HollowChip`; `_ShopChip` and `_KindChip` into `HollowBadge`; the header row (ghost + outline + outline + a bare `HollowPressable` at 4px gaps) to four ghost actions at 8px; and the listing card rebuilt so the art fills it (a hard `size: 96` in a ~228px cell became a `LayoutBuilder`-measured ~212px), the card keeping a background step and dropping its hairline, badges grouped at the trailing edge.

- **Sweep 3, every remaining label class (session 2).** local-label-class is now **0**, so the rule is a hard ban from here on. What each became:
  - Static facts into `HollowBadge`: `_NsfwBadge` + `_MobileNsfwBadge` (error kind), `DeviceBadge` (accent), the game card's `_TagChip` (neutral; it lost its wash of the game's colour) and `_PlatformChip` when it has no store link.
  - Choices into `HollowChip`: `_ChannelTypeChip`, `_EngineChip` (label + `hint`), `NotificationChoiceChip` + mobile `_NotifLevelPill` (their warning and error tints for Mentions and Nothing are gone, since selection is the accent everywhere), and `_PlatformChip` when it has a store link.
  - `_AccessChip`, `_SlowModeChip` and their mobile twins were Material `PopupMenuButton`s at 10px. They became ONE shared pair, `settings/channel_access_pickers.dart` (`ChannelAccessPicker`, `SlowModePicker`): a `HollowChip` with a chevron that opens `showHollowMenu` with check marks, used by desktop and mobile. The restricted warning tint is gone; the label (Mod+, Admin+, a label name) says it. Slow mode reads "Slow mode" / "Slow 30s" on both platforms now.
  - `_KeyBadge` + `_BindingBadges` (byte-identical) into a new `components/hollow_key_combo.dart`, one mono `HollowBadge` per key.
  - `_DownloadAllChip` was an action, so it became a compact ghost `HollowButton`.
  - `_LegendChip` was a chart legend key, renamed `_LegendEntry` and tokenized.
  - Not labels, kept with a `// design-ignore:` reason on the class line: the floating call and voice bars (`_VoiceControlsPill`, `MobileActiveCallPill`, `MobileVoiceChannelPill`, `MobileSourceSwitchPill` and their State classes), `UnreadJumpPill` (the sanctioned pill), `_AvatarBadge` (a mute mark on an avatar corner), the video bubble's `_Badge` (a scrim over video) and `_FriendChip` (an avatar tab in the friends bar).
  - Component additions: `HollowChip` gained `leading` (a non-IconData glyph such as a platform logo), `hint` (quiet text after the label) and `trailingIcon` (chevron for a menu, arrow for a link); `HollowBadge` gained `leading`. Tests in `design_primitives_test.dart`, variants on the design sheet.
  - Verified with before/after renders: desktop `scripts/probe_scenarios/design_sweep3_labels.json` (audio, notifications, shortcuts, devices, storage, server Channels + the open picker, server notifications); mobile `fleet/design_sweep3_mobile.json` (creates a throwaway server from New conversation, long-press, Server Settings, Channels + the open picker, Notifications), ~36 s on the mini at `.39`. On mobile, dismiss a menu with a `tap_at` outside it: `escape` does not close it in the simulator.

- **Sweep 3b, the look-alikes the class rule could not see (session 2).** `SelectorPill` is deleted (screen share options, app lock, duress scope, image quality are `HollowChip` now). The builder functions: the emoji, GIF and sticker picker tabs, GIF lists and sticker packs are `HollowChip`; the channel slow-mode countdown and the message proof status are `HollowBadge` (proof now reads Unsigned / Verified / Invalid in sentence case, Verified as success); the bulk-access modes are chips. The last three Material `PopupMenuButton`s (per-channel notification override, storage cleanup, auto-download override) open `showHollowMenu`. Not labels, kept with a `design-ignore` reason: the unread-pill and call-source overlays, the Twitch chip (brand purple). Two new guard rules at 0: `local-label-builder` and `material-popup-menu`.
  - `showHollowMenu` gained `alignEnd`: the anchor becomes the menu's top-right corner, for a trigger at the trailing edge of its panel (without it the override menu opened across the member panel).
  - The picker "+" (new GIF list, new sticker pack) sits OUTSIDE the scrolling row now, pinned at the trailing edge: at label size the lists overflow the 360px picker sooner, and the add action must never scroll out of reach.
  - Found on the old code: the storage cleanup menu's "Clear unused emotes & GIFs" row overflowed by 3.3px. Gone with the new menu.
  - Scenario `scripts/probe_scenarios/design_sweep3b_lookalikes.json`. A picker is an overlay host that Escape does not close; the scenario closes each by tapping its own button.
  - **Open for Vitalik:** chip density inside the 360px pickers. At the one chip size, a user with several GIF lists sees two or three before the scroll arrows, where the old 11px pills fit four. A denser chip variant would break "one size"; the alternative is accepting the scroll.

- **Sweep 3c, section headers and eyebrow caps (session 4).** Every tracked-caps label and private header class in the app is gone; `upper-case-label` and `letter-spacing` are both **0** and a new rule `local-section-header` (a `*Section(Label|Header|Title)` class outside components) starts at 0.
  - `SettingsCard` titles render through `HollowSectionHeader` (subheading, Title Case as written). `SettingsSectionLabel` became `SettingsFieldLabel`: the label above ONE input, `label` in `textSecondary`, sentence case. A group of settings takes a `HollowSectionHeader` (Security's six sections, Profile's Connections, owned art, server Overview).
  - `TriStateSegment` is a row of equal-width `HollowChip`s, so Dock / Classic and the other eight segmented controls select with the chip state; mobile's image and audio quality pickers too (mobile has no Dock / Classic).
  - Deleted: home `_SectionLabel`, `game_card_dialog` `_SectionLabel`, mobile chats `_SectionLabel` and settings `_SectionLabel` (centred between two dividers), mobile friends `_SectionHeader`, `_RoleDivider`, `_SectionDivider` (mobile server settings), `_SectionCaption`, `server_template._sectionHeader`, `about_section._aboutSectionLabel`, `storage_dashboard_dialog._buildSection`'s accent icon. Icons beside headings dropped on Home (Recent Conversations, Network, Your Stats), the storage dashboard, vault categories, mobile member sheet, storage route and pinned sheet.
  - Category names (channel sidebar, channels tab, mobile chats, archive groups) render as the user typed them.
  - One-offs: role capitalisation (14 copies) is `roleDisplayName()` in `core/role_hierarchy.dart`; server initials (3 copies) are `initialsFromName()` in `core/name_initials.dart`; the remaining `toUpperCase()` calls are data with a `design-ignore` reason.
  - Bug found by the probe: Settings > Security asserted on open in debug builds (`ref.invalidate` inside `initState`); the invalidate now runs past the first await.
  - Scenarios `design_sweep3c_headers.json` (desktop, 17 screens) and `fleet/design_sweep3c_mobile.json` (mini, 8 shots).
  - **Follow-ups the same session (Vitalik's review):** the shimmer is gone. `member_panel._SectionDivider` keeps a static `HollowDivider` between label and count so the count is anchored (Vitalik), with no sweep or glow (the collapsible chevron stays), and `ShimmerDividerLine` is deleted: its uses (home "Online", About's "Follow ~ Support", mobile Settings) are a plain `HollowDivider`. `HollowSectionHeader` gained `subtitle` (one quiet line, the action centres on both lines), which closed the gap under "Art You Own" and carries the Profiles description. Profile rows lost their hairline: the active row's 1 px accent border fell on a fractional pixel under UiScale and drew its right edge at half strength; the Active badge and accent icon mark it now.
  - **Decided:** section titles stay Title Case, as the rules allow (Vitalik, "follow the rules").
  - **Left for later:** home's "Online" stat row keeps its icon; `HollowSectionHeader` has no danger tone, so mobile server settings' Danger Zone header is neutral; `selection_shimmer.dart` (selected channel and peer rows) is the next gradient to go, in the gradient pass.

- **Sweep 4, dividers (session 4).** `raw-divider` 41 to **0**, a hard ban now. Every inline `Divider(` / `VerticalDivider(` in `lib/src/ui` is `HollowDivider` / `HollowVerticalDivider`, and `about_section._aboutDivider` (a half-alpha border) is gone. Mobile Settings' two section rules were `textSecondary` at 50%, a louder line than anywhere else; they are the one hairline now. Verified pixel-identical on every desktop screen of `design_sweep4_dividers.json` except live stats and a scroll thumb.
  - **Trap:** the theme's `DividerThemeData(space: 1)` makes a bare `Divider(color: ...)` 1 px tall, NOT Material's 16. A first pass wrapped those sites in 8 px of padding and the Overview tab grew 16 px per divider; the diff against the before shots caught it.
  - Kept, not hairlines: the annotation toolbar's `_Divider` (exempt overlay), `hollow_shell._SplitDivider` (a drag handle), `UnreadDivider`, `HollowMenuDivider`.

- **Sweep 5, empty states (session 5, 2026-09-19).** `HollowEmptyState` had zero uses; now every empty list, pane and picker grid in `lib/src/ui` renders through it (desktop shell, chat panes, the three pickers, guest, help, settings, archive, share, shop, dialogs, mobile: about 80 sites in 55 files). New guard rule `local-empty-state` (a `*Empty*` class or `_xEmpty` builder outside components, `OrEmpty` excepted) at **0**, a hard ban.
  - **`dense: true`** added to the component: a list INSIDE a settings card or a section (blocked users, verified contacts, muted conversations, owned art, marks, "No matching settings"), start-aligned, no own padding, title `bodySmall`, no glyph (asserted). The default stays the centred pane. Widget test + a design-sheet row.
  - Deleted: `_buildEmptyState` (share, conferences), `_buildEmptyDmState`, `_buildEmptyChannelState`, `_buildEmptyChat`, `_buildSplitEmptyChat`, the three pickers' `_emptyHint`, owned art's `_EmptyState`, and `sidebar/empty_peer_list.dart` (no callers).
  - The 40 to 64 px half-alpha icons became the 24 px `textTertiary` glyph; heading-size empty titles (mobile chats, mobile conferences, channel start "Welcome to #name") became the body title. Copy kept, only split: a `\n` or second sentence became `description`, no terminal period or "!" on titles ("Say hello!" dropped). Mobile wording matches desktop where the state is the same.
  - New copy an agent wrote, worth Vitalik's eye: download manager "Downloaded files and shard activity show up here.", showcase search "Check the spelling or try a shorter name.", mobile vault "Join a server to see vault files.", mobile imported archives "Tap Load Archive above.", owned art title "No art yet".
  - Left alone on purpose: toasts, errors beside a trigger, menu rows, status lines (recovery phrase, audio diagnostic), the "No vault files" row status, and the screen-share "Waiting for / Connecting to screen share" placeholders on the black video surface (connection states, not empty ones).
  - Scenario `design_sweep5_empty.json` (desktop, 21 shots: conferences, share, archive, friends panel tabs, picker searches, server labels/emotes, settings search). A `semantics:Close` target matches the WINDOW's close button first and quits the app; close panels with `escape`.
  - Mobile verified on the mini with `fleet/design_sweep5_mobile.json` (fresh peer: conferences, friends, the four Archive tabs, Verified Contacts, Blocked Users, light chats), before and after. The render caught the one real bug: a one-line dense state is only as wide as its text, so a centring parent centred it (mobile Blocked Users sat mid-screen beside a start-aligned Verified Contacts). Dense now claims the width through `Align(topStart, heightFactor: 1)`, which still shrink-wraps where the width is unbounded; a widget test pins it. Settings rows below the fold need a `scroll` on `text:Appearance` before the tap.
  - Pairs as `cmp_*.png` (before | after) from a small PIL stacker, desktop `e5-*` and mobile `m5-*`.
  - **Left for later:** "Manage Labels" in server settings still has an icon beside its heading.

- **Sweep 6, one spinner and one sheet (session 5, 2026-09-19).** Three primitives, then every site. `raw-spinner` 127 to **0** and `raw-bottom-sheet` 29 to **0**, both hard bans.
  - `HollowSpinner` (`components/hollow_spinner.dart`): small 14 (a row, a button), medium 20 (a card or section), large 32 (a pane), `textSecondary` by default because a spinner is a state and never the accent, optional `value` for a determinate ring, a "Loading" semantics label. The six old sizes (14/16/18/20/24/36) and their accent/secondary/primary colours are gone.
  - `HollowButton(loading: true)`: the label stays laid out invisibly (same width, screen reader keeps the name), a spinner in the variant foreground paints over it through `Positioned.fill` + `OverflowBox` with ZERO minimums, presses are ignored and it does not fade. About 40 busy buttons that swapped their child for a spinner use it; labels that changed while busy ("Exporting...") are fixed now, since the spinner hides them.
  - `showHollowSheet()` + `HollowSheetHandle` (`components/hollow_sheet.dart`): overlay surface, `radiusXl` top corners, one handle with 8 px above and below. The surface is a `ColoredBox` read from the SHEET's own context (the route's `backgroundColor` is transparent), so a theme change while a sheet is open repaints it; before, every sheet stayed dark around light content. 26 mobile sheets and 3 shared ones converted; their hand-drawn 32 or 36 px handles are gone, the three pickers gained one, and the two `DraggableScrollableSheet`s pass `handle: false` and place the handle themselves.
  - Kept with `design-ignore`: the countdown dials with seconds inside (mobile incoming call 52 px, notification banner 30 px), the recovery pool's 120 px gauge, and spinners over video or a picking scrim (white).
  - Renders caught two bugs the first unit test missed: the spinner, a pixel taller than a label line, grew a loading button by 1 px, and `OverflowBox` inherited the label's tight minimum width and drew the spinner as a 52x14 oval. Both are pinned by tests now.
  - Scenario `fleet/design_sweep6_mobile.json` (server sheet, channel sheet, message actions sheet dark and light). The composer's send button has no semantics label in Saved messages, so the scenario taps it by position; worth an a11y look.
  - **Left for later:** sheet HEADERS still vary (the audio sheet has an icon beside a heading-size title, the server sheet a centred title); that belongs to the screen phases. Desktop's incoming-call countdown became `HollowSpinner.large(value:)` (32 in a 36 box) while mobile's dial kept its own size; align them in the call screen pass.

- **Sweep 7, one slider and one switch (session 6, 2026-09-19).** `HollowSlider` (`components/hollow_slider.dart`) is the only slider and `HollowToggle` the only switch; two new guard rules, `raw-slider` and `raw-switch` (Material or Cupertino `Switch` / `Checkbox` / `Radio`), start at **0**.
  - About 30 sliders under eight hand-rolled themes (track 2, 3 or 4 px, thumb 5, 6 or 7, halo 10 or 12 or none, three halo alphas, a white thumb on the opacity slider, Material's default look in the call volume popup) are one geometry now: 3 px track, 6 px thumb, 12 px halo at 12 %, `accent` fill, `border` for the rest, **no tick marks** (the 50-step cache and auto-download sliders drew a comb), the drag label on the `overlay` surface. `onMedia: true` over video and the annotation bar (the old `Colors.white24` / `0x33FFFFFF`), `halo: false` for the vertical volume popover, `activeColor` only for the annotation pen colour. Audio's two private `_slimSliderTheme` helpers are deleted. The accent hue picker keeps its rainbow track with a `design-ignore`.
  - The 13 Material `Switch`es were all on mobile (settings, roles, Twitch) while other mobile rows already used `HollowToggle`, so one screen mixed a 52 x 32 Material switch with a 36 x 20 Hollow one. All are `HollowToggle` now, each with a `semanticLabel` (the row's title; `SettingsToggleRow` passes its label too). The roles row's `AnimatedOpacity` is gone because the toggle fades itself when disabled (it was 0.16).
  - **Touch targets.** On Android and iOS the toggle's hit area grows to 48 x 48 (the painted switch stays 36 x 20) and the slider sits in a 48 px tall box. Mobile rows with a toggle are therefore a few px taller than before; desktop is unchanged. **Trap:** the render slider ignores a minimum height when its height is unbounded and asserts, so the slider takes a fixed `SizedBox(height: 48)`, never a `ConstrainedBox(minHeight:)`; a widget test caught it before any render did.
  - Scenarios `design_sweep7_controls.json` + `design_sweep7_lower.json` (desktop: Accessibility, Audio & Video top to bottom, Files & Storage, light Appearance; the wheel does not scroll a settings page, dragging a content text does) and `fleet/design_sweep7_mobile.json` (Appearance, Accessibility, Network, Audio & Video, Files & Storage, Security). The desktop settings pages got denser: Material 3's slider was about 48 px tall with its padding, the Hollow one is about 24.
  - **Open for Vitalik:** the toggle is 36 x 20 on a phone too, where iOS's own switch is 51 x 31. One size keeps parity with desktop and the hit area is 48 either way; a touch variant is one constant if he wants it bigger.
  - **Found and fixed the same session:** mobile Settings > Security never left its spinner in debug builds (the simulator): `_loadStatus` ran `ref.invalidate` synchronously from `initState`, the same assert sweep 3c fixed on desktop, and it threw before the `try`, so `_loading` never cleared. The invalidate now runs past the first await. Release builds skip the assert, so users never saw it. "Appear invisible" sat under "Layout" on mobile and inside the desktop Layout card; it is its own "Presence" section on both now.

- **Sweep 8, the dialog pass (session 7, 2026-09-19).** One frame, one action rule, no blur. Rules in `HOLLOW_DESIGN_LANGUAGE.md` 4.4 and the skill.
  - Component (`components/hollow_dialog.dart`): `HollowDialogSurface` is the only frame (overlay, hairline, 12 px shadow, `radiusLg` desktop / `radiusXl` + full width on a phone, width policy `width` / `maxWidth` / `maxHeight`, `padded: false` for edge-to-edge layouts). `HollowDialog` sits on it and gained `showClose`, `leadingActions`, `width`. New: `HollowDialogCloseButton`, `HollowDialogText`, `showHollowConfirm()`. Entrance from 0.96, exit on the motion token. Six widget tests, a Dialog row on the design sheet.
  - **Backdrop blur removed (Vitalik: blur reads as AI slop).** A flat theme token `scrim` (65% black dark, 32% light) behind dialogs AND sheets; 55% was tried first and left the chat too legible behind the dialog. `reduceTransparencyFlag` is gone (Reduce Transparency still governs the wallpaper). Blur survives only where it does a job: NSFW images, the game card's cover art.
  - Five agents by folder converted ~20 hand-drawn frames, 7 raw `showDialog` / `showGeneralDialog` / `AlertDialog` / `SimpleDialog` sites and audited ~100 `HollowDialog`s: tinted borders and title icons gone, titles sentence case, primary last, danger for delete/leave/remove/kick/ban/wipe, lone Done/Close buttons became the X, ~40 hand-built yes/no pairs became `showHollowConfirm` (private `_confirm` helpers deleted). Profile and game card became ONE window split into panes (were detached cards). Mobile matches desktop wording.
  - **Casing trap:** dialog TITLES are sentence case, but `HollowSectionHeader` and card titles inside a dialog stay Title Case (Vitalik's 3c verdict); two agents lowercased those and were reverted.
  - Guard: `raw-dialog` at **0** (one `design-ignore`: the archive sender filter, an anchored popover inside a SelectionArea) and a second test, **no dialog draws its own frame** (a `showHollowDialog` builder that opens with Center / Material / Container / DecoratedBox), which catches 15 of the old frames on HEAD.
  - Scenarios `fleet/design_sweep8_fixes.json` (desktop, a throwaway peer that creates its own server and label) and `fleet/design_sweep8_mobile.json` (mini, 5 shots, three throwaway servers). The first desktop pass used `ui_probe.ps1` on a mirror of the real identity; those scenarios were deleted.
  - **Found, unverified on a device:** on the iOS Simulator a row in mobile Chats whose server sheet has opened once never fires `onLongPress` again (logged: the callback does not run; a different row still works; dismissing by barrier or by an action makes no difference). Pre-existing on HEAD. A widget test of `HollowPressable` + `showHollowSheet` with the same A, B, A, A sequence PASSES, so the primitives are fine; the cause is either in the mobile shell or the live binding's synthetic `tester.longPress`. Check on a phone before digging further.
  - **Follow-ups the same session (Vitalik's review):** Add a server was loose (a hard-coded 180 px divider taller than both columns, a second 8 px on top of the section header's own gap, field-to-button 12 instead of 8): `IntrinsicHeight` + stretch, gaps on the ramp. The channel panel's default "Text channels" sat in its own band between two hairlines: now it reads as a category header (no divider, `md` above, text on the `#` column). Label delete asks first ("Delete "X"?", danger), desktop and mobile. The welcome screen shows the Hollow logo instead of a shield in an accent box. "Add a server" kept as the title.
  - **Casualties caught before they broke anything:** `fleet.ps1` onboarding waited for "Your Recovery Phrase" (now sentence case; fixed, onboarding re-verified); `fleet_destroy.ps1` and `fleet_relay_switch.ps1` tapped a "Done" that became the X (now `dialog > semantics:Close`). Any copy change in a sweep needs a grep of `scripts/` and `integration_test/` for the old string.
  - **Probe identity (Vitalik):** the first sweep 8 shots ran `ui_probe.ps1`'s default, a mirror of his REAL data dir. Never again: verification is `fleet.ps1` on throwaway fixture peers (`feedback_probe_throwaway_identities_only`); the follow-up shots used `fleet/design_sweep8_fixes.json` and a live un-onboarded peer for the welcome screen.
  - **Left for later / open for Vitalik:** the welcome screen's option rows are still icon-in-a-tinted-box; the game card's white-on-scrim X over art (a `HollowDialogCloseButton(onMedia:)` would replace it); the imported-pack dialog can show 3+ outline wear buttons; the storage dashboard's sections are cards inside a dialog; `promptForName` could take `maxLength` (three agents asked); the archive filter wants a real anchored popover primitive; the friends manager tab strip sits on `surface` inside an overlay.

- **Sweep 9, the filled-button audit (session 8, 2026-09-19).** `.filled` 146 to **115**, each now the one commit of its screen, pane, dialog or sheet. The rule was sharpened in `HOLLOW_DESIGN_LANGUAGE.md` 4.2 and the skill, then applied:
  - **Per-item actions are compact outline, never filled** (a list of ten was ten primaries): invite cards' Join / Open, meeting rows' Start meeting (desktop + mobile), mobile waiting-room Admit (its gap to Decline 4 to 8), the voice pane's stream rows and grid tiles' Watch. The single focused-stream placeholder keeps its filled Watch.
  - **Section and field saves are outline.** Server Overview had five filled Saves on one page (name, description, access, Twitch, nickname), mobile server settings four, Network five inline Saves plus the add-relay Add; all outline now. Apply & restart, Save layout, Save profile, Link a device, Set password stay filled: each is the one commit of its page. Desktop Claim (nickname) matches mobile's outline.
  - **Two actions, no primary, both ghost:** server template Export / Import on both platforms. **Selection is a chip:** the catch-up day pickers (desktop a hand-rolled chip that changed weight on select, mobile a filled button among ghosts) are `HollowChip`s.
  - **Cautionary:** Reset device list is `outline(danger: true)` on both platforms. Notifications: Request permission (when missing) is the filled one, Send a test notification ghost. Updates: Check for updates steps down to ghost when an update is ready (Install & restart owns the filled); its hand-drawn version pill is a mono `HollowBadge`.
  - Busy buttons that still swapped their label ("Saving...", "Claiming...", "Verifying...", "Cropping...", "Checking...") use `loading:` now (9 sites). Two shared flags (server name + description) were left disabled-while-busy.
  - The invite card's "Joined" and share card's "In shares" hand-drawn pills are `HollowBadge(success)`. Labels tab headers are `HollowSectionHeader` (the settings icon beside "Manage Labels", left from sweep 5, is gone).
  - **Component bug the renders caught:** an outline was 2 px taller than a filled (the 1 px border added to the padding), so every swapped Save pushed the layout below it. The border now comes out of the padding; a widget test pins all four variants to one size, compact and not.
  - Guard: a third test, **no action row holds two filled buttons** (two `HollowButton.filled` sharing the innermost `children:` / `actions:` list; the else of a condition does not count). 0 hits on the tree; proved to fire on a planted pair.
  - Scenarios `fleet/design_sweep9_buttons.json` (desktop, 18 shots incl. a fake-id invite so Join shows, a created conference room, the Add Friend tab) and `fleet/design_sweep9_mobile.json` (mini). The settings pages scroll by `scroll` (drag) on a visible text; `wheel` does not move them. `text:Notifications` needs `index: 1` once Server Settings is open behind.
  - **Left for later / open for Vitalik:** Add a server keeps two filled (Join and Create, one per column); the End meeting danger button sits beside the filled Open call on mobile with no confirm; the invite and share cards still have an accent left strip (a "coloured edge" tell) for the screen pass; the mobile profile sheet is a stack of full-width buttons (Message filled + two outline) where desktop is one primary plus an icon strip.

Guard baselines moved: font-size 597 to 596, radius 117 to 116 (sweep 9); font-size 689 to 597, material-colors 207 to 190, color-literal 136 to 133, radius 123 to 117, edge-insets 230 to 225, sized-box-gap 176 to 171, big-shadow 28 to 15, raw-material 55 to 26, raw-dialog new at 0 (sweep 8); material-colors 223 to 207, color-literal 137 to 136, raw-slider and raw-switch new at 0 (sweep 7); raw-spinner 127 to 0, raw-bottom-sheet 29 to 0, radius 149 to 123, material-colors 234 to 223, edge-insets 233 to 230 (sweep 6); font-size 703 to 689 and sized-box-gap 178 to 176 (sweep 5), local-label-class **36 to 28 to 0**, upper-case-label 42 to 0, letter-spacing 57 to 0, raw-divider 51 to 41 to 0, font-size 744 to 703, gradient 23 to 21, font-size 824 to 809 to 791 to 785, edge-insets 266 to 257 to 248 to 236, radius 177 to 175 to 168, letter-spacing 66 to 64 to 63, sized-box-gap 202 to 192 to 182.

- **Session 9, screen standards and the Home direction (2026-09-23).** The component work was done but nothing said what makes a whole SCREEN good, which is why the screen phases felt impossible to start (Vitalik: "I just can't get my head right on the design"). Three things landed:
  - **Screen standards** in `HOLLOW_DESIGN_LANGUAGE.md` section 5 (and step 5 of the skill's "Before you write a line"): the four-line screen brief (job, focal point, primary action, what leaves), layout rules (one alignment edge, panes anchored to the window with max widths for prose only, a main region plus at most ONE side panel that drops rather than squeezes; the first draft said "a list column capped at 720, the group centres", which was wrong, see below) and 14 checks (squint test, nothing twice, status by exception, progressive disclosure, destructive actions out of reach, accent only on what acts, icons earn their place, one row per kind of thing, a designed first run, locale-aware dates, reading width, targets, keyboard, five states). Vitalik agreed with the list in conversation; Apple's HIG is his named reference ("absolute gold").
  - **Home mockup, awaiting Vitalik's verdict:** https://claude.ai/artifact/2bP8y5rkxT3BFKGQH1c4dL (Design canvas: populated desktop with working filter chips, first run, phone Chats tab). The direction and its audit are in section 6 below. Dock mode stays the default and the signature; Home becomes an actual home.
  - **Avatar initials fixed:** a peer with no avatar showed "12" everywhere (the first two characters of every libp2p id, `12D3KooW...`). `HollowAvatar` now takes initials from the display name (`peerInitials()` in `core/name_initials.dart`) and falls back to the LAST two characters of the id. `initialsFromName` trims and takes runes, so a leading emoji is not split. Tests `test/name_initials_test.dart`.
  - **Home BUILT on desktop the same day** (Vitalik approved the mockup: "YES TO ALL"; mobile waits for the Mac). `home_dashboard.dart` is the layout (the inbox takes the width, a 300 px side panel on the right edge built like the member panel, `homeShowsRail()` drops it below 840, one `CustomScrollView` so variable strips never push the list off), `home_inbox.dart` (Needs Attention: unacknowledged security alerts, incoming requests with Accept/Decline, update ready; Get Set Up: six steps, the first undone one filled, Hide persists; Conversations: DMs plus channel mentions, All / Unread / Mentions chips, search), `home_rail.dart` (What's New teaser + `showNewsPostDialog`; Active Now: voice rooms across servers with Join/Open, then online friends with their status line). New: `showNewMessageDialog` (friend picker), `showFriendsManager(addFriend:)` now public, `openServerChannel()` (`core/providers/channel_navigation.dart`, the shell's notification path uses it too), `mentionPreviewProvider` (the latest mentioning message per channel, in memory; the count stays the truth), `homeSetupProvider` (flags `recovery_phrase_saved`, set by the phrase dialog's "I've saved it", and `home_setup_hidden`, loaded in `_bootstrap`). Moved off Home: relay load + the status card to Settings > Network (`RelayHealthCard`, so the 7 s relay poll no longer runs whenever Home is open), Your Stats to Settings > Devices (`SyncCheckCard`). The five desktop unread pills are `HollowCountBadge` (the dock now shows a server's mention count too). Guard baselines: font-size 596 to 565, material-colors 190 to 183, color-literal 133 to 130, radius 116 to 108, edge-insets 225 to 216, sized-box-gap 171 to 164.
  - **Verified** with `fleet/home_redesign.json` on three throwaway peers (a starts empty; b and c send requests a answers FROM Home; DMs; b mentions a in a server a creates and sits in its voice room; New message, news post, both Settings pages). Renders caught: the checklist never showing (its flags were read in `build()`, the bootstrap race, see `feedback_load_persisted_setting_from_bootstrap_not_build`), rows' own padding putting avatars 8 to 12 px right of the headings (non-row content is now inset by `kHomeRowInset` so text shares one edge and only hover bleeds), a ghost "Read the post" off the card's edge (`HollowTextLink`), and a fixed-height friend picker. Before|after: `build/cmp_home_populated.png`.
  - **Fleet trap fixed:** every fleet script waited on `text:Connected`, which lived on the old Home's Network card. They now wait on `"provider": "connection", "equals": "connected"`; the `Wait-ForAnyTarget` helpers still list `tooltip:Online` first.
  - **Left for Home:** screen shares across servers are not tracked (Active Now shows voice rooms only); the mobile Chats tab gets the same strips and chips when the Mac is on; `HollowListRow` hovers to `elevated` even inside an overlay (the friend picker), where the rule says `hover`.
  - **Layout corrected after Vitalik's first look (same day):** the build copied the mockup's 720 px inbox + rail CENTRED as a group, which left ~120 px of dead band on each side of a 1280 window ("the weird gaps is what makes it out of touch"; the old three columns filled the width). A centred max-width group is a web-page layout: the mockup's artboard framed it, the real pane frames nothing. Now the inbox fills the pane and the rail is a full-height `surface` side panel with a hairline, like the member panel; the conversation row's time moved beside the name (the reason for the cap was the name-to-time eye travel). The rule is rewritten as design language 5.2 + 5.2.1 (mockup is not the screen) and skill step 6.
  - **Personality pass (Vitalik's second look, same day):** "as much as I love this design, we need to make it a bit personal rather than bland". The title is now a greeting by the local clock (`core/greeting.dart`: Good night 0-6, Good morning 6-12, Good afternoon 12-18, Good evening 18-24, then the chosen name or **Kind Stranger**, Vitalik's phrase from an earlier project of his; the first run keeps "Welcome to Hollow, <name>"), re-evaluated by one `Timer` at the next boundary. The side panel is three blocks: **News** (the latest post plus a teal "What's new in X" that opens `showChangelogDialog`; the first launch after an update leads with "Updated to X" and three changelog lines until opened, `changelog_seen_version` in `homeSetupProvider`, stamped with the running version on a fresh install so "Updated" means an update), **Relay** (name in the console voice, the connection dot via `connectionVisual`, `RelayLoadBars` shared with Settings > Network, people online), and **Active Now**. The changelog is `changelog.txt` BUNDLED as an asset (`core/changelog.dart` parses it, `describes()` matches `0.11` to `0.11.0`): no request to GitHub or anyone, works offline, always the running build's notes; the release skill now waits for the changelog before the builds and syncs it to the VM and Mac. The title row is fixed above the scroll and the scroll spans the pane (padding inside), so the scrollbar sits on the panel's edge instead of floating 24 px in. Row times and the news date left the console voice (a written date in mono read as a typewriter).
  - **Found for later screen passes:** the DM profile panel shows Block and Report as red outline buttons at rest (check 5; the desktop profile card's primary plus icon strip is the model); your own name renders in the accent in chat (check 6); Settings is a modal over the app, cramped for 11 categories (decide full-window settings BEFORE the Settings pass); Settings rows carry an icon each (check 7); Home formats older dates as `M/D` (check 10); Home, sidebar DM tiles, mobile Chats and Archive draw conversation rows separately (check 8).

### Four bugs the work surfaced, all fixed

1. **Ghost and outline buttons failed contrast.** They drew their label in raw `hollow.accent`, which is 2.33:1 on the light theme. 244 ghost uses. Now `accentText`.
2. **`accentText` was validated against the wrong surface.** Computed against `background` (the best case), it was 4.45:1 on `elevated`, where ghost buttons actually sit. Now computed against `elevated` on every factory, and `contrast_test.dart` loops all three surfaces. See `feedback_contrast_token_worst_case_surface`.
3. **`HollowButton` did not colour an icon passed as its `child`**, only the `icon:` slot, so every icon-only ghost button rendered in the ambient colour. Found because the Shop's refresh icon sat grey beside three teal siblings.
4. **`HollowChip` labels could overflow.** Three equal-width chips on a narrow mobile column overflowed by 2px at 1.0x text scale and 54px at 1.5x. Labels are now `Flexible` + ellipsis. Caught by `text_scale_overflow_test`.

### Verification standard used, and worth keeping

Every sweep: probe screenshots **before**, change, probe screenshots **after**, stack the pair, read them, fix what looks wrong, then report. Desktop through `scripts/ui_probe.ps1`, mobile through `scripts/fleet.ps1 -Scenario design_sweep_mobile -Peers a` on the Mac mini. Three of the four bugs above were invisible in the source and only showed up in a render.

**The mini needs a machine-local build fix** before it can build the simulator app at all (Xcode 27 + webcrypto's BoringSSL hook): see `feedback_webcrypto_boringssl_native_assets`. It lives in the gitignored `ios/Flutter/LocalSigning.xcconfig` and is already applied.

### Where to pick up next

**Sweeps 3 to 9 are done** (sessions 4 to 8). **Session 9 wrote the screen standards, the Home mockup (approved) and built Home on desktop. Next: mobile Chats parity when the Mac is on, then the chat screen.**

1. ~~Sweep 3c~~ done, see above.
2. ~~Sweep 4, dividers~~ done, see above.
3. ~~Sweep 5, empty states~~ done, see above.
4. ~~Sweep 6, sheet + spinner~~ done, see above. ~~Sweep 7, Switch / Slider~~ done. ~~Sweep 8, dialogs~~ done. ~~Sweep 9, filled buttons~~ done.
5. **START HERE: the screen work**, phases 2 onward below, with the Shop's per-kind card shapes (verdict 9) and the compact message mode (verdict 8) inside it. Method per screen (session 9): brief (design language 5.1), then a clickable mockup on a Design canvas for anything STRUCTURAL (what goes where), Vitalik's verdict, then the Flutter pass with before/after renders against the 5.3 checks. Polish-only screens skip the mockup. Order: Home (the pilot: it sets the shared conversation row), then chat (where people spend their time; the compact message mode rides it), then the rest of phase 2's list.

**The ratchet tail rides the screen work (decided 2026-09-19).** The component sweeps are done, but nine guard rules still sit above zero: font-size 596, edge-insets 225, material-colors 190, sized-box-gap 171, color-literal 133, radius 116, raw-material 26, gradient 21, big-shadow 15. They are NOT cleared by more blind sweeps: hundreds of literal swaps across files nobody is looking at are where regressions hide. Each screen pass clears the literals in the files it touches, since it is re-rendering and judging that screen anyway, and lowers the baselines in the same commit. A short mechanical sweep at the end mops up whatever no screen owned (theme-adjacent helpers, rarely seen dialogs).

**What completes the epic:** (1) phases 2 and 3 done for every screen, desktop and mobile together, per screen; (2) the nine ratchet rules at or near zero; (3) phase 4, every surface with its empty, loading, error, offline and locked state; (4) phase 5, the navigation map regenerated and one screenshot matrix across Windows, Linux, the iOS Simulator and Android; (5) the "left for later" items above closed. Rough size: 12 to 15 sessions, one screen each. Home goes first (its audit sheet is section 6).

### Session 3 (2026-09-18): decisions rendered, picked and applied

**Picked by Vitalik from the rendered decision sheet:** dark ladder A (`dark-lifted`), light ladder L1 (`light-crisp`), ghost grey at rest (`textSecondary`), Onest confirmed over IBM Plex Sans, cards fill only in both themes. The candidates are deleted; the values are plain tokens.

Applied (uncommitted at the time of writing; 1041 tests green, analyze clean):

- **Five surface levels** (`lib/src/theme/surface_ladder.dart`): `surface` chrome `0B0C10`, `background` canvas `111318`, `elevated` raised `181A20`, new `overlay` `1E2127`, new `hover` `262930` (light: `F1F2F4` / `FFFFFF` / `F5F6F8` / `FFFFFF` / `EBEDF0`). Every foreground token validated against all five (`Contrast.ensureContrastOnAll`).
- **Surface role sweep, every site in `lib/src/ui`** (three partition agents, ~240 token changes, ~45 hairlines removed): chrome = persistent frame only (title bar and dock moved from `background`), cards and inputs `elevated`, everything floating `overlay` and opaque (the 0.92 to 0.97 dialog glass alphas are gone), rows inside an overlay hover to `hover`. Settings now has a chrome rail, a canvas content pane and raised cards. `noticeSurface()` blends onto `elevated`. Composer and chat header strips were judged chrome.
- **Onest + Geist Mono** bundled as static instances (400/500/600, 400/500) cut with `fontTools.varLib.instancer`; `display` 600; mono lost its tracking.
- **Ghost grey**, **danger label `textOnError`**, **`HollowCard` fill only**, dialog accent border gone.
- **Ambient** is an Appearance opt-in (`ambientBackgroundProvider`, desktop + mobile, `AmbientBackgroundToggle` in settings_shared), off by default and under reduce motion.
- **No 8 or 9 px text**: 41 sites onto `micro` / `monoSmall`; the friends-bar request badge became a 14 px pill that grows.
- **The 6 px radius is deleted**: 407 sites moved (controls to 8, chips/badges/progress to 4), `radiusSm` and `HollowRadius.sm` removed. Nested radius takes the smaller stop.
- **Message text** was already `body` 14: nothing to do.
- Rule set, skill and guard updated (baselines: font-size 744, letter-spacing 57, radius-literal 153, material-colors 234).
- Probe: `{"op":"theme","value":"light"}` flips the theme in place; `scripts/probe_scenarios/design_surfaces.json` shoots home, channel, menu, Shop, three Settings pages in both themes. Mobile verified on the mini with `fleet/design_sweep_mobile`.

Findings worth keeping:

1. **Skia on Windows draws light-on-dark text ~1.4 px heavier than dark-on-light** (measured stems at 600: 3.7 px against 2.3 px). Weights are correct; light reads a step thinner. If Vitalik wants it heavier, the light roles go one weight up, never a size.
2. Seen for later sweeps: Appearance's Dock / Classic segmented control selects with a SOLID accent fill; the selected channel row in light shows a right-edge gradient; the mobile Settings rows are icon-in-a-tinted-box (a tell); `game_card_dialog` has a gradient from `Colors.transparent`; `edge_scroll_row` edge fades are hard-wired to `surface`.

- **Verdict 14 applied:** the GIF favourites lists and the sticker packs are ONE `PickerListDropdown` chip each (the current list's name plus a chevron). It opens `showGifMenu` (never `showHollowMenu`: the pickers are raw overlay hosts, #76) with every list, the current one checked, and "New list" / "New pack" last; right-click or long-press on the chip opens the old rename/delete/share menu for the list it shows. `GifMenuItem` gained `checked`, and its rows hover to `hollow.hover`. Scenario `design_picker_lists.json`.
- **Verdict 3 applied** where it exists today: owned art's Wear and Redeem were already compact outline; blocked users' Unblock moved to it. Device rows (three icon actions) and verified contacts (two actions) stay ghost by the rule.

**Next session:** sweep 3c (section headers and the ~40 tracked-caps eyebrow labels, mostly Settings), then dividers, empty states, `showHollowSheet()` + one spinner, Material Switch/Slider, the dialog pass (28 files), the filled-button audit. The Dock / Classic segmented control's solid accent selection belongs to the 3c pass over Settings.

### Vitalik's verdicts on the open decisions (2026-09-18, end of session 2)

Taken in conversation from recommendations, before any render. **Next session starts here:** build a decision sheet (side by side on REAL screens, extending `integration_test/probe/design_gallery.dart` or a probe scenario) that shows each verdict applied, Vitalik confirms by eye, then the theme files change and the sweeps run against the final look. Decisions first, sweeps second.

| # | Question | Verdict |
|---|---|---|
| 1 | Ghost buttons are accent-coloured (240 of them) | **Grey.** Ghost = `textSecondary`, `textPrimary` on hover. The accent is kept for the one filled primary, selected chips, links and focus. Vitalik: "absolutely grey, this is actually a bad issue". |
| 2 | Typeface | **Onest** (UI sans, variable, Cyrillic) + **Geist Mono** (the console voice, shared with the website). IBM Plex Sans rendered beside it as the comparison. Bundle the variable TTFs, rewrite `hollow_typography.dart`. |
| 3 | The action inside a list row | A row that exists FOR one action (Wear frame, Unlink, a member card's action) gets a **compact outline** button; secondary row actions stay ghost icons. |
| 4 | Surface ladder | **Five levels**, chrome (dock, sidebars, title bar) one step DARKER than the canvas so content is the brightest thing. Vitalik singles this out as what most needs upgrading for polish. |
| 5 | Ambient animated background | **Flat by default**, the animation an opt-in in Appearance, dimmer and slower. |
| 6 | `HollowCard` fill + hairline | **Fill only** (background step). Check the light theme on the sheet: a hairline may be needed there where the fill is too faint. |
| 7 | Type density | **Keep the UI at today's sizes** (it reads well at the small default window). **Message text 14 by default** (still scaled by `ChatTextScale`). **Remove every 8 and 9 px site**; nothing under `micro` 10. |
| 8 | Compact message display | **Yes, opt-in** (Discord's Default vs Compact, no avatars), in Appearance or Accessibility. After the chat screen work, not before. |
| 9 | Shop card for non-square art | **Each kind at its own shape**: banners a full-width row at 2.5:1, avatars / frames / stickers square tiles. |
| 10 | Light theme | **Same pass as dark, at the same time.** |
| 11 | `display` at 700 | **600.** Three weights: 400 / 500 / 600. |
| 12 | `HollowButton.danger` label in `Colors.white` | **A token** (`textOnAccent` or an on-error token). |
| 13 | The 6 px radius stop | **Drop it.** Buttons and inputs stay at 8; what used 6 moves to 8 (controls) or 4 (chips, badges). |
| 14 | 360 px picker density (from sweep 3b) | Fixed tabs stay chips. **User-created GIF lists and sticker packs become ONE dropdown chip** ("All lists", chevron) opening `showHollowMenu` with the lists checked and "New list" / "New pack" at the bottom. Scales to any count, no scroll arrows. Vitalik: "actually better". |

Remaining sweeps after the decisions land (about seven, then the screen phases): 3c section headers + the 32 tracked-caps eyebrow labels; dividers (105); empty states (~60); two new primitives, `showHollowSheet()` (27 hand-styled mobile sheets) and one Hollow spinner (126 raw `CircularProgressIndicator`); remaining Material `Switch` / `Slider`; the dialog pass (28 files); the filled-button audit (151 against ~one per screen).

### Decisions already taken, do not relitigate

- **Consolidate and guard first, decide the look second.** Phase 0's toggle route was a workaround for a codebase that does not read tokens. Once it does, editing `lib/src/theme/` and re-shooting the design sheet gives the same grid on every screen for no new code.
- **Type roles are pinned to the sizes the app already renders**, so adopting them is a visual no-op. Section 3.2's scale (body 14, floor 11) was not a tokenization but a global density change: the app is built at 10/11/12/13 (556 of ~800 sites) and only 23 sites use 14. The bump stays available later as one flip of the role table.
- **Motion and radius are pinned to today's values too.** The rule set documents what the code does (`HollowDurations` 150/250/400, buttons at `radiusMd` 8) and lists the retunes as open decisions, rather than quietly changing app-wide behaviour.
- The measured counts in section 1 hold, except `Divider(` is 111 (not 50) and the `copyWith(fontSize:)` split was wrong: almost every site is a raw `TextStyle` constructor, not a token contradicted in place. The guard's baselines are the authority.
- This plan no longer waits on the media viewer plan: A+B+C shipped and the rest does not touch these files.

---

**Owner:** Vitalik (taste, final say on every visual decision, judged by eye from renders).
**Companion memory:** `project_hollow_design_language_direction` (the locked direction), `reference_website_design_system` (the website's system this must cohere with), `feedback_hover_state_patterns`, `feedback_ui_logic_checklist`, `reference_ux_named_laws`, `feedback_web_design_iteration_method` (renders decide, not prose), `feedback_verify_ui_by_driving`, `feedback_mobile_parity_always`, `project_accessibility_plan`.
**Plan checklist:** HOLLOW_PLAN.md (add the bullets when phase 0 starts).

---

## 0. TL;DR

Hollow's layout is its own and stays: Dock mode with the server strip at the bottom and pinned friends in the header. What makes the app read as generated is everything inside that layout: the system font, one radius for everything, an icon on every heading, tracked all-caps eyebrow labels, cards inside columns inside panels, and 68 competing chip implementations, because nothing ever told the agents which one to use. This is not a taste failure. It is a missing specification.

The fix is the pattern this repo already uses for hover states, focus rings and context menus: a written rule, a skill loaded before the work, a CI guard behind it. Applied to the whole UI:

1. **A design language** (section 3), written from the research digest in section 2 and the website system already in force: tokens, type, surfaces, components and their usage rules, motion, states, voice, and a hard list of the tells that are forbidden.
2. **Enforcement** (section 4): the language lives in `reports/reference/HOLLOW_DESIGN_LANGUAGE.md`, a `hollow-ui` skill every agent loads before touching a widget, and source-scan CI guards for the mechanical rules.
3. **A program** (section 5): decisions by eye first (typeface, surface ladder, background), then tokens and shared components with a mechanical migration, then every screen on desktop, then every screen on mobile, then a states pass, then a screenshot matrix that finally covers the whole app instead of eight screens.

Decisions locked with Vitalik:

- The Dock layout and the four-panel Classic layout are not redesigned. Fillings, tokens, components, hierarchy and states are.
- Dense and intentional, not minimalist. Character over chrome.
- Apple's Human Interface Guidelines, Material 3 and Fluent 2 are principle sources and checklists, never the look.
- No mascot placeholder. Holly arrives when the art exists; the empty-state component leaves room for her and ships without her.
- Every debatable visual choice is decided by a render Vitalik can flip, never by a paragraph.
- Production grade means desktop and mobile both, in the same phase, with screenshots as the proof.

---

## 1. Where the app is today

Numbers from a full inventory of `lib/src/ui` (253 files) on 2026-09-14.

| Area | State |
|---|---|
| Typeface | System default (`hollow_typography.dart` `fontFamily: null`), mono is `Consolas` with a generic fallback. No shipped face, so the app has no typographic voice and renders differently on every OS. |
| Type roles | 9 roles defined, but 803 `fontSize:` literals; 681 of them are `copyWith(fontSize:)` on a token, so the token is imported and contradicted in the same line. 23 distinct sizes in use including half steps (8.5, 9.5, 10.5, 11.5, 12.5, 13.5). The three most used sizes (11, 12, 10) include one with no role at all. |
| Radius | 5 tokens exist; 204 numeric literals across 20 distinct values. Radii are exposed two ways (`HollowRadius.*` and `hollow.radiusMd`). |
| Surfaces | 3 dark levels (background `0xFF0D0F14`, surface, elevated) and one border token. Not enough steps for canvas, sidebar, raised, overlay and hover to differ. |
| Colour | 308 `Colors.*` uses in 93 files and 122 `Color(0x` literals in 28 files outside the theme; `Colors.amber` used where `hollow.warning` exists; the background hex re-declared in `annotation_overlay.dart`. |
| Eyebrow caps | 38 `toUpperCase()` label sites in 29 files, 66 `letterSpacing` literals across 11 values for the same visual role. |
| Chips, pills, tags, badges | 45 classes plus 23 `_xChip` builder functions, 68 implementations; only 7 live in `components/`. `_SubTabPill` is defined three times. The Shop alone ships three chip classes at three radii and two untokenised sizes. |
| Section headers | 4 incompatible private helpers; icon beside heading built by hand at every site with icon sizes 13 and 18 on one screen. |
| Empty states | No shared widget. 65 "No ..." strings in 39 files, 3 mutually incompatible local helpers, the rest inline. |
| Dividers and Material | 50 `Divider(height: 1, color: hollow.border)` repeats (a missing `HollowDivider`), 54 raw `Material(` outside components. No `Card`, `ListTile`, `InkWell`, `TextButton` remain, so the primitives migration already worked once. |
| Buttons | The healthy part: `HollowButton` with four variants, 505 uses, one raw constructor. What is missing is the rule for which variant goes where (the Shop header row mixes ghost, outline twice, a filter pill and a bare pressable). |
| Icons | Lucide 1,339 uses vs Material 9. Converged. |
| Screenshot coverage | `UI_NAVIGATION_MAP.md` covers 8 desktop screens and 0 mobile screens against 28 dialogs, 37 settings files, 36 mobile files. |

The home shell and the Shop screenshots reviewed in the session show the result: calm and not garish, with none of the loud tells (no gradients, no glass, no neon borders), but anonymous. A competent default dark dashboard.

---

## 2. Research digest: what good looks like

Distilled from Apple HIG (2026 text), Material 3 and M3 Expressive, Fluent 2, Refactoring UI, Rauno Freiberg's interface rules, Emil Kowalski's motion standards, Linear, Vercel Geist, Raycast, Discord's 2025 refresh, Telegram Desktop, NN/g on empty, loading and error states, and the 2025 to 2026 "generated UI" discourse. URLs in section 8.

### 2.1 Principles that survive all sources

1. Content first, chrome recedes. Messages get the brightest surface; dock, sidebar and title bar sit on the dimmest.
2. Hierarchy by lightness and weight, not by size, borders or shadows. Two to three text colours, two weights.
3. One colour, one meaning. The accent means interactive or primary, nothing else. Never colour alone.
4. Separation by tone and spacing before lines. A border only where a boundary is ambiguous.
5. Simplicity is not minimalism (Apple's own words). Keep the important close, disclose the rest progressively. Deprioritise instead of deleting: smaller and lower contrast, still visible.
6. Familiarity over novelty. Do not rebrand known patterns; M3's research shows dropping labels and moving controls measurably hurts.
7. One visual winner per screen. Decide the most important thing and make everything else step back.
8. Every action visibly succeeds, fails or shows busy. Every list has its empty, loading and error state designed.
9. Delight through craft, not decoration. Motion on rare moments, none on things seen a hundred times a day.
10. Same tokens, different density per platform. Pointer and hover and shortcuts on desktop, thumb zone and 44 to 48 targets on mobile.
11. Opinionated defaults over settings. The same person could have made every screen.
12. Legibility floors: body 13 to 14 on desktop, minimum 11, no weights under 400, text 4.5:1 with 7:1 as the target on dark, icons and controls 3:1.

### 2.2 The tells, and the counter-move for each

| Tell | Counter-move |
|---|---|
| Unchosen typeface (system, Inter, Geist by default) | Choose a face on purpose, ship it, test at 12 to 14 px on Windows ClearType |
| Gradients as decoration, gradient text on numbers | One accent, semantic; no decorative gradient anywhere |
| Glass, blur, glow, animated ambient backgrounds | Solid surfaces; depth by luminance steps |
| Uniform rounded cards with a hairline on everything, nested cards | Background step or spacing; one radius per component class; a card only for a repeatable self-contained unit |
| Coloured strip on a card edge | Status as a dot or text |
| Icon in a tinted box beside every list item | Icons only when they carry meaning; no tinted containers |
| All-caps tracked eyebrow labels | Sentence case; hierarchy by weight and colour |
| Three identical feature cards, bento by reflex | One layout primitive, varied content, one thing wins |
| Emoji as bullets or icons | The icon set |
| Everything equal weight | One focal point per screen |
| Perfectly even spacing | Tight inside groups, generous between groups |
| Bounce on every hover | Motion tokens; frequent actions unanimated |
| Mid-grey body text failing contrast | Validated tiers; dark mode as a designed theme |
| Big shadows and glows | None on dark; hairline or a lightness step |
| Missing unhappy paths, generic microcopy | Empty, loading and error designed, copy in the product's voice |

### 2.3 Numbers worth copying

- **Dark surfaces.** Near black, never pure black as the default (pure black kills elevation and smears on OLED). Four to five colour-only levels suffice: canvas, sidebar or surface, raised (cards, inputs), overlay (menus, popovers), hover or active. Lighter is closer. Raycast's ladder is four steps within 11 units of luminance plus a hairline on every card and zero drop shadows. Linear uses semi-transparent white hairlines throughout instead of shadows.
- **Text tiers.** High about 87 percent white, medium about 60 percent, disabled about 38 percent, never `#FFFFFF` body text (halation). Off-white `#E4E4E7` to `#F5F5F5`.
- **Accents on dark.** Desaturate fills; accent text needs its own lighter tone (Hollow already has `accentText`, keep it the only accent text colour).
- **Type scale.** Radix's nine steps: 12/16, 14/20, 16/24, 18/26, 20/28, 24/30, 28/36, 35/40, 60/60 with tracking from +0.0025em at 12 to -0.025em at 60; line heights rounded to 4. Three weights with strict roles: 400 body, 500 UI, 600 headings. Fluent: sentence case everywhere, no bold, no italic, 50 to 60 characters per line.
- **Spacing.** 4-unit grid, 8 multiples for layout, 4 for controls; Atlassian's ramp 0, 2, 4, 6, 8, 12, 16, 20, 24, 32, 40, 48, 64; inner padding 0 to 8, container padding 12 to 24, sections 32 and up. No two adjacent stops within 25 percent.
- **Radius.** Three to six stops from one factor. Geist never uses pill radius on primary buttons; Fluent caps controls at 4 and dialogs at 8; Radix keeps a checkbox square-ish even at "full" so it never reads as a radio.
- **Motion.** Press 100 to 160 ms, tooltip 125 to 200, dropdown 150 to 250, modal 200 to 500, ceiling 300. Ease-out for enter and exit, ease-in-out for on-screen moves, never ease-in. Transform and opacity only; enter from scale 0.95 to 0.97 plus opacity, never from zero; popovers scale from the trigger, modals from centre. Things done 100 times a day get no animation. Reduce motion means fewer and gentler, keep fades.
- **Density.** Discord separates message display (cozy with avatars, compact without) from UI density (compact, default, spacious) from chat text size. Telegram offers a compact single column and a message width toggle. Hollow already has `UiScale` and `ChatTextScale`; a message display mode is the missing third axis.
- **States.** Nothing for under one second; skeleton for two to ten seconds keeping the final geometry; progress bar over ten; uploads get progress, never skeletons. Empty states say what is true now, teach what fills the space, offer one action. Errors sit next to the trigger, name the cause, suggest a fix that exists, keep the user's input, no blame words, no jokes.
- **Buttons.** One primary per region, rarely more than one per view; ghost for everything inside compound surfaces and for Cancel; danger only on the final destructive confirmation; loading state over disabled; icon-only buttons carry a tooltip and a label.
- **Badges versus chips.** Two components only. A badge is static (status, count, kind). A chip is interactive (filter, select, removable). Pill and tag are shapes and words, not components.

### 2.4 Typeface candidates

Hollow has users writing Cyrillic, so coverage is a hard filter, which rules out Figtree, DM Sans, Instrument Sans, Space Grotesk and Commit Mono. All candidates are OFL and bundle freely. From Flutter 3.41 `FontWeight` drives the variable `wght` axis, so one variable TTF per family is enough.

| Family | Coverage | Character | Verdict |
|---|---|---|---|
| Onest | Cyrillic and extended, 100 to 900 | Distinct, designed by a Cyrillic-native team | Lead candidate for UI sans |
| IBM Plex Sans | Cyrillic, Greek, width axis | The most character, crisp at small sizes | The "opinionated" alternative |
| Manrope | Cyrillic, Greek | Friendly semi-geometric | The warm alternative |
| Inter, Geist Sans | Yes (Geist since 1.7.0) | The default tell; the website already uses Geist | Only if cohesion with the website wins by eye |
| JetBrains Mono | Cyrillic, Greek, tuned for 12 px | Wide coverage | Lead candidate for the console voice |
| Geist Mono | Cyrillic | Pairs with the website's mono | Alternative |

The website system chose Geist Sans and Geist Mono. Cohesion matters, but the research is blunt that unchosen Geist is a tell. The recommendation is one deliberate sans for the app with the mono shared with the website, decided by rendering the same three screens in each candidate (section 5, phase 0). The website can follow the app later.

---

## 3. The Hollow design language, version 1

This section becomes `reports/reference/HOLLOW_DESIGN_LANGUAGE.md` when phase 0 closes the open choices in section 7. Rules are written to be checkable.

### 3.1 Identity

Hollow is encrypted, distributed and hosted by its members. Its visual identity says the same thing: honest surfaces, no decoration, verifiable details rendered like a fingerprint. The three signature elements:

1. **The Dock.** The bottom server strip and the pinned-friends header. Untouched by this plan, polished by it.
2. **The console voice.** A mono face for identities, hashes, safety numbers, relay names, versions, timestamps and counters (tabular numerals). Used on purpose, never for body copy. This is the one place the app looks like the protocol it runs.
3. **One accent, sparingly.** Teal (`0xFF00BFA6`, hue variants stay) on interactive and primary elements only. Never tinting cards, never glows, never on headings.

Holly, when she exists, appears in moments (empty states, onboarding, errors, the shop) and never in chrome. Until then, no placeholder.

### 3.2 Tokens

- **Surfaces, dark.** Five colour-only levels, one hairline: `canvas` (the chat and content, keep `0xFF0D0F14`), `chrome` (dock, sidebars, title bar; one step darker than canvas so content is the brightest thing), `raised` (inputs, cards that earn a card, message hover), `overlay` (menus, popovers, dialogs), `hover` (state layer, alpha over the level below). `border` stays one hairline at 8 to 14 percent white. Shadows only on `overlay`, small. Light theme mirrors all five with the same names. Exact values are chosen in phase 0 from three rendered ladders.
- **Text.** Exactly three tiers, `textPrimary` (off-white, never pure white), `textSecondary`, `textTertiary` (already 4.5:1 guarded), plus `accentText` and `textOnAccent`. No fourth tier, no ad hoc alpha on text.
- **Semantic colours.** `accent`, `success`, `warning`, `error`, each with a text-safe variant. `Colors.amber` and friends are forbidden outside the theme.
- **Type roles.** One shipped variable sans and one mono. Roles, desktop sizes, with line heights rounded to 4: `title` 20/28 600, `heading` 16/24 600, `body` 14/20 400, `bodyStrong` 14/20 500, `label` 13/20 500, `caption` 12/16 400, `micro` 11/16 500, `mono` 13/20 400, `monoSmall` 11/16 400. `display` 28/36 600 exists for the few places that need it (welcome, empty states). Nothing under 11. No half steps. Weights 400, 500, 600 only. Mobile takes the same roles one step up for body and label. `copyWith(fontSize:)` is forbidden; a new size is a new role, argued in a review.
- **Case.** Sentence case for everything except card and section titles, permission names, proper nouns. No `toUpperCase()` on labels. No tracked caps. The one exception is the mono console voice, which may be upper case for short tags.
- **Spacing.** Keep `HollowSpacing` (2, 4, 8, 12, 16, 24, 32, 48). Rule: inner padding and icon gaps 4 to 8, container padding 12 to 16, between sections 24 to 32. Numeric `EdgeInsets` literals are forbidden outside the theme.
- **Radius.** Four stops plus full: `xs` 4 (chips, badges, small controls), `sm` 8 (buttons, inputs, menus), `md` 12 (cards, dialogs on desktop), `lg` 16 (sheets, mobile dialogs), `full` for avatars and status dots only. Primary buttons are never pills. One exposure path (`hollow.radius.*`); `HollowRadius` becomes an alias and then goes away. Numeric `BorderRadius.circular` is forbidden outside the theme.
- **Icons.** Lucide, stroke 1.75 at 20 px and 2 at 16 px, sizes 14, 16, 20, 24 only. Never beside a heading as decoration. Icon-only controls carry a purpose label and a tooltip (both already CI-guarded). Brand icons match stroke and optical size.
- **Motion.** Durations `fast` 120 ms (press, hover colour), `base` 180 ms (tooltip, dropdown, chip), `slow` 260 ms (dialog, sheet, route). Curves `enter` ease-out, `move` ease-in-out, never ease-in. Transform and opacity only; enter from 0.96 plus fade. Hover never moves layout, never changes weight. Frequent actions (send, switch channel, open menu) animate nothing beyond the 120 ms colour. Reduce motion keeps fades, drops everything else.
- **State layers.** Hover, pressed, selected and focus are alphas over the surface, luminance-aware (`_hoverLift` already does this). Selection is a chip state, never a filled button.

### 3.3 Components and the rules for using them

New or consolidated primitives, all in `lib/src/ui/components/`:

| Component | Replaces | Rule |
|---|---|---|
| `HollowBadge` | ~40 static chip and tag classes (`_ShopChip`, `_KindChip`, kind and count tags) | Static only. Kinds: neutral, accent, success, warning, error, mono. Radius xs. Never clickable. |
| `HollowChip` | ~28 interactive pill classes (`_FilterPill`, `_SubTabPill` x3, access and slow-mode chips, `SelectorPill`) | Interactive only: filter, select, removable, sub-tab. Selected = accent-muted fill and accent text. Radius xs. |
| `HollowSectionHeader` | 4 private helpers | Title in `heading` or `label`, optional trailing action, optional count in mono. No leading icon. |
| `HollowEmptyState` | 3 helpers and 60 inline columns | One honest line about what is true now, one optional second line, one action at most. Optional glyph at 24. A slot for Holly, empty for now. |
| `HollowDivider` | 50 inline `Divider(height: 1, ...)` | The hairline. Nothing else. |
| `HollowSkeleton` | none | Keeps the final geometry; used only for 2 to 10 second loads. |
| `HollowListRow` | ad hoc rows | Dense row with leading, title, subtitle, trailing, hover on the whole row, no dead zones between rows. |
| `HollowCard` | itself | Only for a repeatable, self-contained unit (a listing, a device, a news item). Sections and settings groups are not cards. A card has a background step or a hairline, never both plus a shadow. |

Usage rules:

- **Buttons.** `filled` is the one primary action of a region, at most one per visible region and rarely more than one per screen. `outline` is a secondary alternative standing next to that primary, at most two. `ghost` is everything else: toolbars, icon buttons, Cancel, links in rows. `danger` is the final destructive confirmation only. A row of actions with no primary is all ghost. Loading state, not disabled, while a request runs.
- **Dialogs.** Ghost Cancel, filled confirm, danger only destructive (already law). Title in `title`, body in `body`, one primary.
- **Feedback.** Inline next to the trigger for field and row errors; toast for deferrable status; dialog only when the flow must stop.
- **Lists over cards.** Anything repeated more than three times is a list of `HollowListRow`, not a grid of cards, unless the item is the art (shop, gallery).
- **Headings.** No icon. Count or status in mono at the trailing edge if useful.
- **Numbers.** Tabular numerals everywhere a number can change: timestamps, counts, sizes, stats.
- **Copy.** Sentence case, no em dashes, honest labels (`feedback_ui_logic_checklist`), the sepia gate for anything longer than a label.

### 3.4 Screens and density

- Desktop body text 14, rows 32 to 36 in lists, message rows grouped by sender with the timestamp in mono at low contrast. Mobile body 16, rows 48 and up, controls in the thumb zone.
- A message display setting, cozy (avatars, current) versus compact (no avatars, tighter), separate from `UiScale` and `ChatTextScale`. Discord's three axes, and the one Hollow is missing.
- The chat surface is the brightest thing on screen. Dock, sidebar and header sit on `chrome`.
- The home screen is about people: conversations get the width, stats leave for System Status and the profile, relay figures go under System Status.

### 3.5 The forbidden list (CI-guarded where mechanical)

1. `fontSize:` outside `lib/src/theme/`.
2. `BorderRadius.circular(<number>)` outside the theme.
3. `Colors.<anything>` except `Colors.transparent` outside the theme; `Color(0x` outside the theme.
4. `toUpperCase()` for a label; `letterSpacing:` outside the theme.
5. `Divider(` outside components; raw `Material(` outside components except the documented overlay hosts.
6. A `Chip`, `Pill`, `Tag` or `Badge` class outside components.
7. An `Icon` as the first child of a heading row (source scan on the section-header pattern).
8. Gradients (`LinearGradient`, `RadialGradient`) outside the theme's ambient background and the annotation overlay.
9. `BoxShadow` with `blurRadius > 12` anywhere; any `BoxShadow` on a surface below `overlay`.
10. `EdgeInsets.all(<number>)` and `symmetric(` with numeric literals outside the theme.
11. `Colors.transparent` passed as an animated colour (already law).
12. Two `HollowButton.filled` in one `Row` or `Column` (source scan, heuristic).

Existing guards that stay: purpose labels, `HollowFocusRing`, `showHollowMenu`, `setShellTab`, the hover rules, the contrast checks.

---

## 4. Enforcement

- **The document.** `reports/reference/HOLLOW_DESIGN_LANGUAGE.md`, living, regenerated when a decision changes. Section 3 of this plan is its draft.
- **The skill.** `hollow-ui` in `.claude/skills/` (repo, so every agent on every machine gets it): the rules of 3.2 to 3.5 as a checklist, the component table, the brief template of section 5.5, and the instruction to screenshot through `scripts/ui_probe.ps1` before reporting done. CLAUDE.md gets one line: load `hollow-ui` before any widget work, the way `sepia` gates copy.
- **The guards.** A `test/design_language_guard_test.dart` source scan (the shape the repo already uses for `mint_key_package`, hover and labels) for every mechanical rule in 3.5, with an allowlist file that must shrink and never grow. `custom_lint` can come later if the scan proves too coarse.
- **The brief template.** Every Opus subagent redesigning a screen receives the same numbered brief (5.5). One agent, one screen, one file set, screenshots in the result.
- **The proof.** `UI_NAVIGATION_MAP.md` regenerated to enumerate every screen, dialog and mobile route (today 8 of roughly 100), so the screenshot matrix has a target list. `FEATURE_MATRIX.md` gains a "designed states" column.

---

## 5. The program

### Phase 0: decide by eye  (SUPERSEDED, see the status note)

The hidden-route version below is not what was built. The design sheet is
`integration_test/probe/design_gallery.dart`, pumped in place of `HollowApp` by
`ui_probe.ps1 -Widget design-gallery`: no toggles, no route, no data directory.
Candidates are compared by editing `lib/src/theme/` and re-shooting, which
costs a rebuild and covers every screen in the app rather than three. The
original text is kept below for the list of choices it enumerates.

### Phase 0, as originally planned

A hidden route `hollow://design-sheet` (debug and profile builds only) that renders the same three real screens (home, DM chat, settings) under toggles: typeface (three sans, two mono), surface ladder (three candidate ladders), radius factor, message display cozy or compact, ambient background on or off and at three intensities. Driven by `ui_probe.ps1` into a screenshot grid Vitalik flips through. The web method (`feedback_web_design_iteration_method`) adapted to Flutter: toggles default off, the recommended combination is one preset, adopted toggles become the token and their switch is removed. Verdicts recorded in the memory and in this document the same day.

Outputs: the typeface, the surface values, the radius scale, the ambient decision. Then `HOLLOW_DESIGN_LANGUAGE.md` is written from section 3 with the numbers filled in.

### Phase 1: tokens and primitives, mechanical

- Fonts bundled (variable TTF, weights 400 to 600 subset if static), `hollow_typography.dart` rewritten to the roles, `hollow_colors.dart` to the five surfaces, radius unified to one path, motion tokens added.
- New components from 3.3 built in isolation with a widget test each.
- Migration sweeps, one per rule, by Opus agents with a hard scope: replace literals with tokens, replace the 68 chips with the two components, replace the 4 headers, the 50 dividers, the 60 empty states. No visual redesign in this phase; screens look the same or slightly better. The guard test lands with each sweep and its allowlist goes to zero per rule.
- Desktop and mobile in the same sweep, since both use the same files.

### Phase 2: screens, desktop

In this order, each one an audit sheet, a brief, one agent, screenshots, Vitalik's verdict:

1. Home (the dashboard; stats move out, conversations widen, headers lose icons, the profile column shortens).
2. DM chat and channel chat (message rows, grouping, hover bar, composer, staged strip, reply bar; the media viewer arrives from the other plan).
3. Dock and header (polish only: sizes, badges, hover, the accent ring on the active tab).
4. Settings (11 categories: the cards become sections, the rail gets the type roles, every toggle row is a `HollowListRow`).
5. Server settings panel and its tabs.
6. Shop (the art is the card: full-bleed image, title and price under it, one badge for kind, one for owned, bigger avatars, the header row reduced to one primary).
7. Archive, Share, Conferences, Voice channel pane, Call surfaces, Members, Friends bar.
8. All 28 dialogs against the dialog rule.

### Phase 3: screens, mobile

The same order on `MobileShell` and the 36 mobile files. Parity is checked per screen, not at the end.

### Phase 4: states

Every list and every surface gets its empty, loading and error state through the shared components. A checklist per screen: what shows in the first second, at three seconds, on failure, when empty, when offline, when locked.

### Phase 5: proof

The navigation map regenerated for all screens, the screenshot matrix run on Windows, the Linux laptop, the Mac mini iOS Simulator and an Android device, the contrast guard extended to every new token, the design language document marked shipped.

### 5.5 The brief template for a screen

0. The screen brief from `HOLLOW_DESIGN_LANGUAGE.md` 5.1: job in one sentence, focal point, the one primary action, what leaves the screen. Agreed with Vitalik before the agent starts.
1. Screen and files (exact list).
2. What is wrong today (from the audit sheet: which tells, which rule numbers).
3. What must not change (layout, providers, behaviour, CI-guarded patterns).
4. The components to use (from 3.3) and the button hierarchy for this screen (which action is the one `filled`).
5. Mobile counterpart and its file.
6. Screenshots required (which routes, which states) via `ui_probe.ps1`; the agent reads its own PNGs and fixes what looks wrong before reporting.
7. Done means: guard test green, screenshots attached, no new allowlist entries, every check in design language 5.3 holds on the renders.

---

## 6. Audit sheet seeds

Two screens already audited from screenshots in the session, as the format for the rest.

**Home, re-audited 2026-09-23 against design language 5.3 (the proposal, pending Vitalik's verdict on the mockup).**

- Brief. **Job:** see what needs me and get back into my conversations. **Focal point:** the conversation list (in Dock mode it is the only place every DM is listed). **Primary action:** New message. **Leaves:** the profile column (your identity is the user bar), Your Stats and relay RAM/bandwidth (System Status), the peer id (profile), the permanent Network card (a connection row appears only when not connected).
- What the render showed: three columns of equal weight (squint test fails); own name twice and friends three times (the header strip, the list, the Network column's "Offline 15"); "Connected, 0 friends reachable" next to "Offline 15" reads broken when nothing is; centred profile block over left-aligned cards; list rows ~650 px wide with the time at the far end; `M/D` dates; no first-run state.
- Proposed layout (as mocked; the widths were corrected in the build, see session 9): a main column (title row with search and New message; a **Needs Attention** strip only when something is pending: friend requests, join requests, a friend's new unverified device, recovery phrase not backed up; each one row with ghost + compact outline; then Conversations with All / Unread / Mentions chips, DMs plus channel mentions) and one side panel (What's New card, **Active Now**: voice rooms and screen shares you can join, then online friends with their status line). The rail drops below ~960 px.
- **Active Now only if the data exists:** it needs who is in which voice channel across our servers and who is sharing. If only presence dots are available the top strip already shows them, and the rail is What's New alone until the data does.
- Unread count badge proposed as the accent, with red reserved for a mention (`@`), so red keeps meaning "someone needs you". Today every unread is red.
- **First run:** the same layout with a Get Set Up checklist in place of Needs Attention: identity (done), back up the recovery phrase (the screen's one filled), add a friend, join or create a server (outline), avatar, link a device (ghost).
- Mobile: the Chats tab takes the same Needs Attention strip and the same chips above its list (parity; mobile has no Home).

**Home (`home_dashboard.dart`), the 2026-09-14 audit.** Icons on four headings (tell 6, rule 3.3 headings). Eyebrow caps FRIENDS, RELAY SERVER, NEWS, YOUR STATS (tell 7). Two cards and two dividers in the profile column with a large empty gap under them (tell 4, rule lists over cards). Stats and relay RAM and bandwidth on the home (rule 3.4). Conversation previews leak raw tokens `[e:...]`, `[file:...]`, `[a:g:...]`, `[a:s:...]` (bug, tracked in the media plan section 11). Same weight on every heading. Keep: the layout, the accent H tab, the mono peer id (make it deliberate).

**Shop (`shop_dashboard.dart`).** Header row mixes a filter pill class, a ghost button, two outline buttons and a bare pressable (button rule: one filled, the rest ghost; the filter is a `HollowChip` group). Three chip classes at three radii and two untokenised sizes across the dashboard and the owned panel (`HollowBadge`). The listing card floats a small image inside a large bordered box: the art should be the card. Avatars too small (Vitalik). The empty space under four items has no state (rule 3.3 empty state).

---

## 7. Open choices, decided in phase 0 by render

- The typeface pair (section 2.4).
- The surface ladder values and whether `chrome` is darker than `canvas` (recommended) or lighter.
- The ambient animated background: keep as an opt-in "Ambient" background at a dimmer, slower setting with a flat default (recommended, and consistent with the website's removal of glowing blobs), or keep as the default.
- Whether the light theme gets the same pass in phase 2 or a shorter one in phase 5 (recommended: same pass; the tokens make it nearly free).
- The message display compact mode: phase 2 with the chat screen, or later.

---

## 8. Sources

Principles and platforms: Apple HIG design principles, dark mode, typography, colour, materials, designing for macOS and iOS (developer.apple.com/design/human-interface-guidelines/...). Material 3 tokens, colour roles, type scale, shape scale, motion, and the M3 Expressive research (m3.material.io, design.google/library/expressive-material-design-google-research). Fluent 2 layout, typography, shapes, elevation and the Windows signature experiences (fluent2.microsoft.design, learn.microsoft.com/windows/apps/design/signature-experiences).

Craft: Refactoring UI summary (sglavoie.com/posts/2023/09/09/book-summary-refactoring-ui), Rauno Freiberg's interfaces (github.com/raunofreiberg/interfaces), Emil Kowalski's animation standards (github.com/emilkowalski/skills), Karri Saarinen's rules (figma.com/blog/karri-saarinens-10-rules...), Linear's UI refresh notes (linear.app/now/how-we-redesigned-the-linear-ui, linear.app/changelog/2026-03-12-ui-refresh), Vercel Geist (vercel.com/geist/introduction), Raycast design notes (github.com/VoltAgent/awesome-design-md), Radix Themes typography and radius (radix-ui.com/themes/docs/theme), Atlassian spacing and button (atlassian.design), Primer button (primer.style), Carbon dialog and notification patterns (carbondesignsystem.com), Smart Interface Design Patterns on badges and chips, USWDS and EightShapes on cards, Lucide icon design guide (lucide.dev/contribute/icon-design-guide), Nathan Curtis on token naming, the DTCG token format 2025.10 (designtokens.org).

Density: Matt Ström-Awn on UI density (mattstromawn.com/writing/ui-density), Discord display settings and the 2025 refresh (discord.com/blog), Slack message display help, Telegram Desktop compact.

States: NN/g empty state design, skeleton screens, error message guidelines (nngroup.com/articles).

The tells: mania.design "Spot the slop", 925studios "AI slop design tells", developersdigest "AI design slop and how to spot it", saasui.design, dev.to "The purple gradient problem", smoothui.dev, the Hacker News thread 46677824.

Typefaces: fontsource API metadata per family, vercel/geist-font releases, jetbrains.com/lp/mono, Flutter font weight variation notes (docs.flutter.dev/release/breaking-changes/font-weight-variation).
