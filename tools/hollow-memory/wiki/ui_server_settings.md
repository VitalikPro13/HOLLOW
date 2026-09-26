# Server settings -- a place, desktop and phone

Rebuilt 2026-09-24 (design language session 18) onto the Settings shell. The old `ServerSettingsPanel` with its tab strip, the eight `*_tab.dart` files and the five phone sub-routes are gone.

## The place model

- **Switch:** `serverSettingsOpenProvider` (`server_provider.dart`) stays the ONE open flag; ~25 navigation sites set it false.
- **Open:** `openServerSettings(read, serverId, {page})` (`core/providers/server_settings_provider.dart`) closes every centre tab (`setShellTab(null)`), stores the server id ALWAYS (a split's right pane reads its own overridden `selectedServerProvider`, so "the selected one" is ambiguous there), resets the page to its default and opens. `closeServerSettings(read)` clears the flag.
- **Target:** `serverSettingsTargetProvider` = the stored id, else the selected server.
- **Shell mounts** (`hollow_shell.dart` `_serverSettingsPlace`): Classic replaces the channel sidebar AND the chat pane (the server strip stays); Dock replaces the whole centre row; split view is covered too (the old 800x600 dialog is gone). The member panel hides. A target that is not the selected server renders inside `ForeignServerSettingsScope`, which overrides `selectedServerProvider`, `channelListProvider` and `channelLayoutProvider` with fresh notifiers loaded for that server, so the pages never edit the left pane's channels.
- **Openers:** channel sidebar gear (toggles), channel sidebar right-click, server strip / dock server menu (select the server first, then open), the right pane's sidebar gear, phone long-press sheet ("Server settings" -> `MobileServerSettingsRoute`).
- **Close:** the X ("Close server settings (Esc)"), Escape, or the gear again; it returns to the channel it covered. A server deleted or left elsewhere while open closes the place on the next frame.

## The shared frame

`ui/settings/settings_place_frame.dart`: `SettingsPlaceFrame` (rail + page column; on a wide window the PAIR centres and the rail's surface bleeds to the left edge; X top right; one floating bottom bar), `SettingsRail`, `SettingsRailItem`, `SettingsRailGroupLabel`, `SettingsUnsavedBar`. Settings (`settings_place.dart`) and `ServerSettingsPlace` (`ui/server_settings/server_settings_place.dart`) both use it. In the CLASSIC layout the frame keeps the channel sidebar's `UserBar` (you, status, Downloads, the gear) at the rail's foot, its surface running left to the server strip; Dock and the phone have no bar (the dock holds you). A page that sets `sliverPage` (Members) scrolls through `SettingsScrollView` as a `CustomScrollView` with the same padding and 720 max width.

## Pages and gates

`ui/server_settings/server_settings_catalog.dart`: `ServerSettingsPage` enum (rail order), label, grey icon, `requires` bit, `serverSettingsPagesFor(perms)`, `defaultServerSettingsPage(perms)` (Overview with MANAGE_SERVER, else Profile), `serverSettingsPageFor(page, id)`, plus `confirmDeleteServer` / `confirmLeaveServer`: THE delete and leave confirms for the whole app (Overview and Profile danger zones, the strip / dock server menu, the phone long-press sheet). The FFI runs inside the confirm (`showHollowConfirm(onConfirm:)`, a failure stays in the dialog), and they read the provider CONTAINER, not the caller's ref, because the menu or sheet that opened them may be gone by then. Afterwards `_afterServerGone` closes server settings only if they showed that server, deselects it only if it was selected, and pops a phone back to its shell.

| Group | Page | Gate | File |
|---|---|---|---|
| Server | Overview | manageServer | `pages/overview_page.dart` |
| Server | Access | manageServer | `pages/access_page.dart` |
| Server | Channels | manageChannels | `pages/channels_page.dart` |
| Server | Roles | manageRoles | `pages/roles_page.dart` |
| Server | Labels | manageRoles | `pages/labels_page.dart` |
| Server | Emotes & stickers | everyone (add/remove: manageEmotes) | `pages/emotes_page.dart` |
| Server | Members | everyone (actions gated) | `pages/members_page.dart` |
| Server | Files & storage | everyone (retention: owner/admin) | `pages/files_storage_page.dart` |
| You | Profile | everyone | `pages/profile_page.dart` |
| You | Notifications | everyone | `pages/notifications_page.dart` |

Nothing renders until `serverSettingsAccessProvider(id)` (permissions AND role loaded) is non-null: rendering earlier flashes the wrong pages.

## Save model

- **Text fields** ride `serverSettingsDraftProvider(serverId)` (`ServerSettingsDraftNotifier`): name (32), description (256), member limit, your nickname (32). One bar, "You have unsaved server changes" (Reset / Save), on every page. Save writes only what changed (`renameServer`, `description`, `max_members`, `setNickname`); an empty name or a limit below the LIVE member count throws `ServerDraftError`, shown as a toast with the edits kept. Reset re-reads the saved values.
- **Channel list** rides `channelLayoutDraftProvider(serverId)`: order, categories and dividers are staged; the bar on the Channels page reads "You changed the channel list" (Discard / Save layout). Save goes through the caller's `ChannelLayoutNotifier.mutate` (the right pane's scoped one when foreign). Channels created elsewhere appear through `effectiveLayoutFrom`, so no auto-save is needed.
- **Everything else writes at once**, over an optimistic update that reverts with a toast on failure: switches, chips, menus, per-channel properties, role bits, labels.
- The phone shows the draft's Reset / Save and the layout's Discard / Save layout in each page's title bar instead of a floating bar.

## Page notes

- **Overview:** Icon (48, "Square. A GIF or animated WebP moves.") and Banner ("Wide, 3 to 1") apply at once (crop 1:1 / 3:1, animated picks skip the cropper, 2 MB cap, `applyLocalWrite` seeding); Name + Description; "How an invite shows it" preview (232 wide, beside the fields from 560 px, above them and left-aligned at the same 232 on a phone); Advanced fold: Server ID (mono, Copy) and Template (Export / Import -> `server_template.dart`); Danger zone for the owner only: outline danger "Delete server" -> confirm "Delete <name>?".
- **Access:** Joining (Private server: Rust rejects EVERY new join, `server_state.is_private()`; Adult content; Member limit via the draft), Twitch verification (switch with the purple brand icon; turning it on with no channel opens the channel dialog first; Channel row + Change dialog; "Followed for at least" menu over `kFollowDaySteps`; Subscribers only; Only I accept requests), While members are away (Offline catch-up; absent = on at 3 days; Keep them for 1 / 3 / 7 days). Every key is a per-key `updateServerSetting`.
- **Twitch channel dialog:** typing a channel name looks up its numeric id after 600 ms through `twitch_lookup_channel` (Helix `/users?login=`). Helix needs a Bearer token on every call, and the app has no client secret, so the lookup uses the CONNECTED account's user token; without one it says to connect Twitch in Settings, Profile. Enter on the name saves once the id is known, else looks it up at once. The id field shows only when the lookup found nothing or failed, or after "Enter the ID yourself"; otherwise the found id reads as a mono "ID 123" line. "Use my own channel" fills your own account (errors show inside the dialog). `TwitchChannelDialog` is `@visibleForTesting` (`test/widget/twitch_channel_dialog_test.dart`).
- **Channels:** toolbar (New channel, New category, Divider; all ghost). Category rows: small secondary label, hover-revealed "Set access for all" (`runCategoryBulkAccess`) + More (Rename, Delete category with a confirm). Channel rows (40, 52 on touch): grip, # or speaker, name then `channelSummary()` (only what differs: "<gate> can see", "<gate> can post", "Slow 30s", "Media only", "Public", "N members with temporary access"), chevron. Click opens an inline panel: Who can see it, Who can post, Slow mode, Media only, Public (the last four text only), Temporary access (hidden when public; `showChannelGrantsDialog`), Rename, outline danger Delete channel. Drag starts at once under a pointer, after a hold on touch. Rename = `promptForName(onSubmit:)` (stays open while it runs, keeps the typed name on failure); Delete = `confirmDeleteChannel` (`server_settings/delete_channel_confirm.dart`, shared with the sidebar menu and the phone sheet: "Delete #x?", `kDeleteChannelMessage` "It disappears for everyone. Its messages stay on the devices that already have them. This can't be undone.", runs inside the dialog). Who can see / post with labels opens `showAccessLabelPicker(gate:, target: '#x')`.
- **Access label picker** (`settings/access_label_picker.dart`): `showAccessLabelPicker(gate: AccessLabelGate.see | .post, target:)`; the title comes from `accessLabelPickerTitle` ("Who can see #x" / "Who can post in #x", "...the channels in <category>" from the bulk dialog), so every surface asks the same question (the old `title:` param is `@Deprecated`). `LabelChip`s over the ACCESS labels, Cancel + Apply; clearing every label says roles decide again. Empty: "No access labels yet".
- **Temporary access dialog** (`settings/channel_grants_dialog.dart`, `showChannelGrantsDialog`): "Temporary access to #x", "Has access now" rows (avatar, name, `grantRemainingLabel`, remove X; an id suffix only where two names clash) and "Give access" (`MemberSearchPicker`, "Everyone else already has access" when empty); picking a member switches the SAME dialog to a `HollowDurationPicker` view (Back + Give access), run inside it. Own writes live in `_written` (a refetch right after a queued write still returns the old grants). Its time labels are shared with Manage member (wiki `ui_profile_card`).
- **Category bulk access** (`settings/category_bulk_access_dialog.dart`): `runCategoryBulkAccess` (Channels page + the sidebar's category menu) opens "Set access for <category>": two `SettingsSwitchRow`s (Change who can see them / Change who can post), each revealing chips Everyone / Mod+ / Admin+ / Labels… (the access label picker); "Apply to N" runs `applyCategoryBulkAccess` INSIDE the dialog, channel by channel, optimistic with a per-channel rollback, and throws a `FriendlyException` naming the channels that did not change. Toast "Access changed on N channels".
- **Roles:** one table, a column per role (96 px, 64 on touch), 7 permission rows. A column is editable only when your priority beats the role's (owner 3 > admin 2 > moderator 1 > member 0), matching Rust. `rolePermissionsProvider(id)` reads Rust's `defaultRolePermissions`, never a Dart copy. "Reset to defaults" resets every column you may edit.
- **Labels:** "Labels <count>" with ghost New label; rows: colour dot, name, "Access · opens #x · 3 members" / "Cosmetic · N members", ghost "Give to members" (`showLabelAssignDialog`) + More (Edit, Delete). `showLabelEditDialog` / `showLabelAssignDialog` live here. The list draws `labelWritesProvider` (`LabelWrites`: edits and deletes by id, creations under a `pending:` id until the store shows a label with the same name, colour and kind) over the stored labels, because the FFI only queues the op; a pending row reads "Saving…" with no actions. Edit dialog: Name (hint "VIP, Artist, Night owl"), named colour swatches, kind chips Cosmetic / Access, Save disabled while the name is empty and run inside the dialog. Delete: "Delete <label>?" run inside the confirm. The assign dialog (480) toggles members optimistically and names the member in its failure toast.
- **Emotes & stickers:** counts in the section header ("8 of 50"); tiles are the art; a manager's tap opens Remove (confirm "Remove :name:?", run inside the dialog). Adds and removes show at once through `AssetWritesNotifier` (`serverEmoteWritesProvider` keyed by name, `serverStickerWritesProvider` keyed by hash, drawn over the stored list by `overAssetWrites`): a write returns an undo for failure, and 2 s later (`settleAfter`) one refetch decides it, since the node can still refuse after the FFI returned. Replaces the old 150 ms sleep + invalidate.
- **Members:** Moderation first when you hold kickMembers (Muted with "For another 23 hours" + Unmute; Banned with Unban; `bannedMembersProvider`). Then "Everyone <count>": search + chips All / Admins / Moderators / Members with counts; one flat list sorted owner, admin, moderator, member, then name; every member, built lazily (the page opts into `SettingsSliverPage`: the top sections are box slivers and the rows a `SliverList.builder` keyed by member id, hosted by `SettingsScrollView`), no cap. Row: avatar, name + "You" badge, "Role · labels" or "Muted". More (only when `canManageRole(myRole, role)` and not you): Make <role> (`showChangeRoleDialog` with `currentRole`), Labels and temporary access (`showManageMemberDialog`), Copy user ID, Mute (Unmute when already muted, `unmuteMember`), Kick, Ban (`moderation_dialogs.dart`, wiki `ui_profile_card`). On a phone a tap opens the profile sheet (with `serverId`, so Manage member shows there) and More / long-press opens an action sheet of touch `HollowListRow`s with grey icons (Kick and Ban carry no red there: the confirm they open does).
- **Files & storage** (2026-09-26, replaces the storage dashboard dialog and the phone storage route; rail labels that join two words use "&" in sentence case on both rails): one column of sections. "On this computer" ("On this phone"): the big figure ("Nothing yet" at zero) "of <server> on this computer", a 4 px categorical bar + legend (Downloads, Kept for the server; NO emotes and stickers segment, because that cache is shared by every server and has no honest per-server figure), free space on the data root's drive (`freeBytesAt(hollowDataDir)`); the pledge as a slider "Keep for this server up to" over fixed stops from `kMinPledgeMb` (512) capped by free space plus what the server already uses here, saving ONCE on release through `setStoragePledge` (a failure puts the thumb back and toasts `friendlyError`); "Download automatically" for this server (the per-conversation override Settings > Files & storage uses: Default / Always on / Off); "Downloaded files" + a compact outline Clear in error text behind `showHollowConfirm`, then "Freed X". "The whole server": used of given (`serverStorageStatsProvider`), one plain line on how files are kept (under 6 members every member keeps a full copy; from 6 files are split so a few members online can rebuild them), members and the average given; health ONLY when something needs you (failed files as an error line, files still spreading out beside a small spinner; NO Retry, since the vault has no retry call). "How long things are kept": Messages / Files as chip menus (Forever, 30, 90, 180, 365 days), "Applies to new messages and files."; members see plain values and "Only admins can change this." Loading = `_UsageSkeleton` in the final geometry, never "0 B". Phone: the same page at touch density, every choice opens ONE picker sheet with a check on the current option. The channel sidebar's storage button opens this page (`openServerSettings(read, id, page:)`). Tests `test/widget/storage_fixes_test.dart`; renders `test/screenshots/redesign_after_storage_screenshot_test.dart`.
- **Profile:** nickname via the draft with a live message line; "Your labels" chips (access labels locked, a tap says staff hand them out); Danger zone "Leave <server>" for non-owners.
- **Notifications:** server level chips (All messages / Mentions only / Nothing, with a line describing the choice) and per-channel `ChannelOverrideDropdown` (`ui/settings/channel_override_dropdown.dart`, shared with Settings > Notifications) for channels you can see.

## Phone

`MobileServerSettingsRoute` is the list: server header (icon 48, name, "N online · M members"), groups Server / You, 56 px `MobileSettingsNavRow` rows with grey icons and values (Members count, notification level); Files & storage is one of the pages. Each row pushes `MobileSettingsSubPage` (shared with `mobile_settings_tab.dart`) with the SAME page under `SettingsDensity(touch: true)`, wrapped in `ForeignServerSettingsScope` when the server is not the selected one. Invite lives on the long-press sheet, not here.

## Tests and probes

`test/widget/server_settings_test.dart` (rail gates, default page, Escape, the unsaved bar, `channelSummary`, the roles table's locked column, members moderation + filter, the phone list). Fleet: `server_settings_after.json`, `server_settings_classic.json`, `server_settings_after_mobile.json`, `redesigns_after.json` and `redesigns_after_mobile.json` (Files & storage as owner and member, the retention menu and sheet); the probe op `reveal` scrolls Overview's Delete server into view for every cleanup.

---

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
6. If diff is empty, shows the "No changes needed" dialog and returns
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

### Confirmation Dialog (`showTemplateConfirmDialog`, `@visibleForTesting`)

`HollowDialog` "Apply template" (480) showing:
- `Apply "{name}" to this server?` (`HollowDialogText`)
- **Settings** (dense `HollowSectionHeader`): "The name becomes X", "A new description", "A new server icon"
- **Channels to add** / **Channels to remove** (dense headers): plain rows with a hash or volume icon, no accent or red tint; under the removals, "Removed channels disappear for everyone. Their messages stay on the devices that already have them."
- **Layout note:** if only ordering changed, "The channel order changes"
- Cancel ghost + "Apply template" filled, or DANGER "Apply and remove N channels" when the template removes any (returns bool)

An empty diff shows "No changes needed". The progress dialog is closed by its own route (`removeRoute`), never a bare `pop` of whatever is on top. Failures toast through `friendlyError`.
