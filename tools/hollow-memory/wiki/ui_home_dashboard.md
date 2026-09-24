# HomeDashboard and FriendsBar

The home screen shown in Dock layout mode when no server or DM is selected. `HomeDashboard` is the main content area; `FriendsBar` is the 44px horizontal strip across the top of the Dock layout showing friend avatars with status dots.

Source files:
- `lib/src/ui/shell/home_dashboard.dart`: layout, greeting title row, `homeShowsRail()`
- `lib/src/ui/shell/home_inbox.dart`: `HomeAttention`, `HomeSetupChecklist`, `HomeConversations`
- `lib/src/ui/shell/home_rail.dart`: `HomeRail` (News card, Relay card, Active Now)
- `lib/src/ui/shell/friends_bar.dart`: FriendsBar, `showFriendsManager()`, _FriendsManager dialog, _FriendChip

Redesigned 2026-09-23 (design language section 5; plan `HOLLOW_DESIGN_LANGUAGE_PLAN.md` session 9). The old three columns (profile, recent conversations, network) are gone. The phone's Chats tab reuses the strips and the conversation data (2026-09-24, wiki `ui_mobile` "MobileChatsTab").

**Shared with mobile:** `HomeActions` (abstract; `DesktopHomeActions` is the default, the phone passes `_MobileHomeActions`: `touch`, `installsUpdates`, `openUpdate`, `addFriend`, `addServer`, `editProfile`), `HomeGreeting`, `homeIsFirstRun` / `homeShowsSetup`, `kHomeFirstRunLine`, `HomeConversation` + `homeDmConversations` / `homeMentionConversations` / `homeConversationLeading` / `homeNewestFirst`, `HomeFilter` + `HomeFilters` (a `Wrap`, so a phone at 2x text wraps instead of overflowing), `homeNothingToShow`. With `touch` the attention and setup rows put their buttons under the text (full size, `Wrap`), type one step up.

---

## Layout

An app pane anchored to the window, never a centred max-width group (design language 5.2, `feedback_app_pane_not_web_page`):
- **Inbox** (`_HomeMain`, `Expanded`): a FIXED title row (greeting, search, New message) over ONE `CustomScrollView` that spans the pane with its padding inside, so the scrollbar sits on the panel's edge. Everything below the title scrolls together (Needs Attention, Get Set Up, Conversations), because variable-height strips above an `Expanded` list overflow under interface zoom.
- **Side panel** (`HomeRail`): 300 px (`kHomeRailWidth`), `hollow.surface` with a left hairline, full height, like the member panel. Leaves below 840 px of pane (`kHomeRailBreakpoint`, `homeShowsRail()`), never squeezes.
- Non-row content is inset by the rows' own padding (`kHomeRowInset` in the inbox, `_Inset` md in the panel) so headings, cards and row text share one left edge and only hover fills bleed past it.
- Startup reveal: fade + small slide via `StartupRevealScope.interval()` (inbox 0.30-0.55, panel 0.40-0.65).

## Title row

- `greetingFor(DateTime.now())` (`core/greeting.dart`): Good night 0-6, Good morning 6-12, Good afternoon 12-18, Good evening 18-24, then `chosenNameForPeer` of our own id, else `kNamelessGreeting` = "Kind Stranger" (Vitalik's phrase). First run (no friend AND no server) says "Welcome to Hollow, <name>" plus one line of copy. A one-shot `Timer` at `nextGreetingChange()` re-renders at each boundary (never a periodic clock).
- Search field (filters the conversation list) and the one filled `New message` (`showNewMessageDialog`, a friend picker whose footer opens `showFriendsManager(addFriend: true)`) appear only once there is a friend.

## Needs Attention (`HomeAttention`)

Absent when nothing waits. One `elevated` row each, ghost secondary + compact outline primary with per-row `loading:` and a failure toast:
- Unacknowledged `securityAlertsProvider` entries grouped per master: new device(s), identity re-keyed, identity reappeared. Verify = `showVerifyContactDialog` (not awaited), Dismiss = `acknowledgeForPeer`.
- Incoming friend requests (`friendsProvider`, pending + incoming): Accept / Decline.
- An update ready (`hasUpdateProvider`): View update opens Settings on Updates. Desktop only (`installsUpdates`). The manifest is checked at launch (`newsProvider.build`) and again every 2 h by `UpdateNotifier`'s own one-shot `Timer` (desktop only, re-armed by every check, so a manual check pushes the next one out; skipped while downloading / extracting / ready). A background check shows no progress and no error. Never tie it to `GuestFetchMode.periodic30m` or the 60 s status poll.
More than 3 collapse behind "Show all N".

## Get Set Up (`HomeSetupChecklist`)

Shown while the person has no friend OR no server, `homeSetupProvider.loaded`, and not hidden. Six steps: identity (done), back up the recovery phrase (`phraseSaved`, set by the phrase dialog's "I've saved it"), add a friend, join or create a server (`showCreateServerDialog`), profile picture (own avatar bytes), link another device (`myDevicesProvider.length > 1`). The first undone step carries the ONE filled button, the rest compact outline. Hide persists (`home_setup_hidden`).

`homeSetupProvider` (`core/providers/home_setup_provider.dart`) holds `recovery_phrase_saved`, `home_setup_hidden` and `changelog_seen_version`; `load(appVersion)` runs from `hollow_shell._bootstrap` (a `build()` read races the store open and comes back empty, `feedback_load_persisted_setting_from_bootstrap_not_build`). A fresh install stamps the running version as seen, so "Updated to" means an update.

## Conversations (`HomeConversations`, a sliver)

- DMs: `sortedFriendsProvider` + `lastDmMessageProvider` + `dmUnreadCounts` (a muted DM counts 0, as in the friends bar); open with `openDmConversation`; right click = the shared user menu (`dmTile`).
- Channel mentions: every `channelMentionCounts` entry above 0 for a known server; title `#channel` + the server as detail, preview from `mentionPreviewProvider` (recorded in `event_provider` when a live channel message mentions us and we are not viewing it; in memory only, so after a restart the row says "Mentioned you" with no time and sorts first). Opens with `openServerChannel()` (`core/providers/channel_navigation.dart`, the same batch the notification path uses).
- Filter chips All / Unread (DMs with unread + mention rows) / Mentions, and the title-row search.
- Rows are `ConversationRow` (`components/conversation_row.dart`): `PresenceAvatar`, title + detail + time BESIDE the name (`conversationTimeLabel()`: 14:05 / Yesterday / weekday / Sep 17 / Sep 17, 2025, interface face at `textTertiary`), preview, `HollowCountBadge` (accent unread, error + `@` mention) at the far edge.
- Empty states: no conversations at all, nothing unread, no mentions, no search match.

## Side panel (`HomeRail`)

1. **News card:** header "News" + the running version as a mono `HollowBadge`; the latest `newsProvider` post (title, date, plain-text excerpt via `plainNewsExcerpt`); the WHOLE card opens the post (`showNewsPostDialog`; a text link was too small for a finger) and a teal "What's new in X" (`showChangelogDialog`, Older / Newer to walk versions). When `changelogSeen != currentVersion`, the card leads with "Updated to X", three changelog lines and "See everything that's new" until opened (`markChangelogSeen`). The changelog is `changelog.txt` BUNDLED as a pubspec asset and parsed by `core/changelog.dart` (`changelogProvider`); `describes()` matches `0.11` to `0.11.0`. No network, no third party. Links are `HollowTextLink`.
2. **Relay card:** "Relay", the connection dot + `overallConnectionProvider.label` via `connectionVisual()`, the relay domain in mono, then `RelayLoadBars` (`settings/relay_health_card.dart`: RAM, bandwidth, the 7 s poll sweep, an "Online" count row). Watching it runs `relayStatsProvider`'s poll, so it polls while Home or Settings > Network is open.
3. **Active Now:** voice rooms across every non-conference server from `voiceChannelProvider.participants` (devices resolved to masters, channel names via `serverChannelsProvider`), each with Join (joins, then opens the channel) or Open when we are in it; then online friends (`onlineIdentitiesProvider`) as `HollowListRow` with their status or "In voice, <server>", capped at 8. Screen shares across servers are not tracked, so they do not appear.

The pieces are public and shared with the phone (wiki `ui_mobile`): `HomeNewsCard`, `HomeRelayCard(loadBars:)` (false drops the bars and their poll for a mounted-but-hidden tab) close mobile Settings; `homeVoiceRooms(ref)` + `HomeVoiceRoomTile(onOpen:, touch:)` are the phone Chats' Active Now.

## Moved off Home

Your Stats is Settings > Devices `SyncCheckCard`; the status card and relay bars are Settings > Network `RelayHealthCard`; the peer id and own profile live in the user bar and profile.

---

## System Status Banner — Website-Driven Status Notice

`lib/src/ui/shell/system_status_banner.dart` + `lib/src/core/providers/status_provider.dart`. A global status notice (maintenance / outage / announcement) pushed from a website JSON file, with a live countdown, severity levels, and per-incident dismissal. **Independent of the relay** — it's an HTTPS GET to the website, so it loads even when the relay WS is down (exactly when "relay back at 02:00" matters most).

**Data:** `https://anonlisten.com/hollow/releases/status.json` — a single JSON object (not an array like news.json), fetched via `updater_api.fetchReleaseFeed(url: '...?t=<bust>')`, the UNSIGNED plain fetch news.json also uses (the update manifest alone goes through `fetchVersionManifest`, which demands a `.sig` sidecar; pointing a feed at it makes the card go blank). Fields (all defensively defaulted): `id` (stable per-incident key for dismissal), `level`, `title`, `message`, `until` (ISO-8601 UTC instant for the countdown), `until_label`, `link`, `link_label`, `dismissible` (default true). No local source copy is committed — the live file lives on the website. Empty `{}` or `level:operational` with no message = silent (no banner; the Home/Settings card shows green "All systems operational").

**`statusProvider` (`StatusNotifier`):**
- `StatusLevel` enum: `operational | info | maintenance | warning | critical`. `fromString` defaults unknown → operational (fail-safe — a bad feed never shows a scary banner). `showsInBanner` = `!= operational`.
- `_fetch()` runs eagerly in `build()` (network, no DB dependency) so the banner appears instantly. An **own `Timer.periodic(60s)`** re-fetches (disposed via `ref.onDispose`) — deliberately NOT piggybacking the relay-stats 7s poll (that would force `relayStatsProvider` always-on = more load; a 60s HTTP request is trivially cheap, and the file changes a few times a month).
- **Dismissal:** `dismissCurrent()` persists the current `id` under SQLCipher key `dismissed_status_id`. `loadDismissed()` reads it back — **called from `hollow_shell.dart` `_bootstrap()` AFTER the DB is open**, NOT eagerly in `build()` (the DB isn't open when the banner first watches the provider during local-first render → `loadSetting` throws → swallowed → dismissal lost every restart; bootstrap ordering is the race-free fix, same pattern as `themeModeProvider.load()`).
- `StatusState.showBanner` getter: banner-worthy level + has content + not-dismissed-for-this-id.

**`statusVisual(level, hollow)`** — single source of truth for color+icon, shared by banner and card: operational→`success`+circleCheck, info→`accentText`+info (teal — the neutral/playful "info" channel, distinct from the amber/red alarms; no blue token exists so accentText is the contrast-safe accent), maintenance→`warning`+wrench, warning→`warning`+triangleAlert, critical→`error`+octagonAlert.

**`StatusCountdown`** — self-ticking 1s `Timer.periodic` counting down to `until` (UTC). Format: `2h 14m` (>1h) / `14:23` (<1h) / `45s` (<1m). At/after zero it flips to "In progress now" and stops. Tabular figures so digits don't jitter. The `until` parser forces UTC interpretation even if the author omits the `Z`, so the countdown is identical in every timezone.

**`SystemStatusBanner`** (`ConsumerStatefulWidget`) — the dismissible strip. Renders only when `showBanner`. **Tap-to-expand:** collapsed = compact one-liner (icon + headline·message ellipsised + countdown + chevron-down hint + X); tapping the bar expands to full untruncated title + wrapped message + countdown + Details (chevron flips up). Starts collapsed (auto-appearing content announces quietly, user opts into detail); a new notice `id` resets to collapsed; the X dismisses without toggling (HitTestBehavior.opaque). `AnimatedSize` grow/shrink uses `HollowDurations.fast` (auto-zero under reduce-motion). `StatusBannerAnchor` enum (top/bottom) picks which edge carries the divider — top-strip (divider below, desktop) vs bottom-anchored (divider above, so it doesn't merge into the bar beneath, mobile).

**Mount points (responsive — desktop top, mobile bottom-anchored):**
- Desktop: under the FriendsBar in BOTH `hollow_shell.dart` `_buildDockLayout` AND `_buildClassicLayout` (`anchor: top`).
- Mobile tab screens: above the bottom nav bar (`mobile_shell.dart`, `anchor: bottom`).
- Mobile chat: above the input cluster (`mobile_chat_route.dart`, `anchor: bottom`).
- Mobile calls: top under the participant/channel name in BOTH `mobile_call_video_view.dart` (1:1) and `mobile_voice_channel_route.dart` (`anchor: top`).

**`HomeStatusCard`** (`ConsumerStatefulWidget`) — the calm card variant. Unlike the banner it renders the green "All systems operational" healthy state too (Home/Settings are deliberate pull-surfaces, so a reassuring steady-state is welcome). Used in Settings > Network's `RelayHealthCard` on desktop (Home no longer carries it; the banner covers problems) and on the mobile Settings tab before `_MobileStatsCard` ("Your Stats").

**Tap-to-expand (2026-08-04)** — mirrors the banner's pattern so the two surfaces behave identically:
- Collapsed: headline + `sub` message each clamp to `maxLines: 2` with ellipsis; chevron-down on the right of the Row.
- Expanded (`showFull`): `maxLines: null` + `TextOverflow.clip` on both, message gains `height: 1.35`, and the **Details link** appears — it is expand-ONLY (collapsed it would compete with the tap-to-expand affordance). The link has its own `HollowFocusRing` + `HitTestBehavior.opaque` `GestureDetector` so following it doesn't also collapse the card.
- `AnimatedSize` (`HollowDurations.fast` / `HollowCurves.subtle`, `alignment: topCenter`).
- `hasDetail = !operational && (message.isNotEmpty || link.isNotEmpty)`. When false the card returns a plain `Semantics` wrapper with NO chevron and NO focus ring — the healthy state has nothing to reveal, so it must not be an interactive control that expands into nothing.
- A new `status.id` resets `_expanded` to false during build (same `_lastId` guard the banner uses).
- Interactive path wraps in `Semantics(container: true, button: true, hint: 'Expand/Collapse notice')` → `HollowFocusRing` → `MouseRegion(click)` → `GestureDetector`, so it is keyboard-operable (a11y CI guards).

---

## FriendsBar — Horizontal Friend Strip

`friends_bar.dart:FriendsBar` is a `ConsumerWidget`. Renders a 44px tall horizontal bar at the top of the Dock layout. Contains an "Add Friend" button, a vertical divider, and a horizontally scrolling list of friend chips.

**Providers read:**
- `friendsProvider` — all friend entries
- `peersProvider` — online peer detection
- `invisiblePeersProvider` — exclude invisible peers from online status
- `profileProvider` — display names and avatars
- `unreadProvider` — `unreadState.dmUnreadCounts[peerId]`
- `notificationSettingsProvider.notifier` — `isDmEnabled(peerId)` check for unread filtering
- `selectedPeerProvider` — highlight currently selected friend
- `favouriteFriendsProvider` — custom friend ordering

**Container:** Height 44px, `hollow.surface` background (alpha 1.0), bottom border in `hollow.border`.

**Sorting logic for accepted friends:** Online first (not invisible), then alphabetical by display name. Online detection: `peers.containsKey(peerId) && !invisiblePeers.contains(peerId)`.

**Favourites override:** If `favouriteFriendsProvider` returns a non-empty list, only those friends are displayed (in their custom order), filtered to valid accepted friends. Otherwise, all accepted friends are shown in the default online-first alphabetical order.

**Pending request badge:** Counts friends with `status == 'pending' && direction == 'incoming'`. If > 0, a red circle (14px, `hollow.error`, 2px `hollow.surface` border) overlays the top-right of the Add Friend button, showing the count in white 8px w700 text.

**Layout (Row):**
1. `HollowSpacing.sm` left padding
2. **Add Friend button:** `HollowTooltip(message: 'Add Friend')` wrapping `HollowPressable` with `LucideIcons.userPlus` (18px, `hollow.textSecondary`). Tap calls `_showAddFriendDialog()`.
3. Vertical divider: 1px wide, 24px tall, `hollow.border` color, `HollowSpacing.sm` horizontal margin.
4. **Friends list (Expanded):** If `displayList` is empty, shows "No friends yet" caption. Otherwise, horizontal `ListView.builder` rendering `_FriendChip` widgets with `HollowSpacing.xs` horizontal padding.
5. **Right-hand group** (each `HollowTooltip` > `HollowPressable`, 18px icon, accent when active):
   - **Hollow Shop** — `LucideIcons.store`, rendered ONLY when `shopAvailableProvider` (absent, not disabled, on store builds). Active on `shopTabOpenProvider`. Tap toggles: `setShellTab(read, null)` when lit, else `openShopTab(read)`. Sits before Saved messages. (2026-09-02, wiki `hollowpack`.)
   - **Saved messages** — `LucideIcons.bookmark`. Active when `savedMessagesPeerIdProvider == selectedPeerProvider`. Tap calls `_toggleSavedMessages`.
   - **Conferences** — `LucideIcons.video`. Active on `conferenceTabOpenProvider`. Tap toggles: `setShellTab(read, null)` when lit, else `conferenceProvider.notifier.openTab()`.
   - **Help** — `LucideIcons.circleHelp`, toggles `helpPanelOpenProvider`.

**Every strip button that lights up must also un-light (2026-07-31).** The accent colour reads as an on/off control, so pressing the lit button has to take you back out. Audit by ICON STATE, not by whether the thing it opens is a centre tab — Saved messages was the last hold-out and only ever selected, so pressing it again re-selected the same peer and looked dead. The two need different machinery for the same feel: **Conferences is a centre TAB layered over the selection**, so off = one `setShellTab(read, null)` and whatever was underneath reappears; **Saved messages IS the selection**, so there is nothing underneath and off has to mean Home. Pinned by `test/widget/friends_bar_toggle_test.dart`.

**Saved-messages toggle (`_toggleSavedMessages`):** in split view with `focusedPane == 1` it forwards to `_selectFriend` (that press targets the right pane, so there is no global lit state to toggle). Otherwise, if `selectedPeerProvider == savedId` it calls `_clearToHome`, else `_selectFriend`.

**`_clearToHome`:** the exact inverse of `_selectFriend`'s non-split branch — same providers, peer cleared instead of set. Deliberately does NOT close an open split: the press that lit the button didn't open one.

**Friend selection (`_selectFriend`):** Checks `splitViewProvider` — if split mode is active and focus is on pane 1 (right), calls `navigateRightToPeer(peerId)`. Otherwise:
- Calls `setShellTab(ref.read, null)` — closes every centre tab at once (see `feedback_shell_centre_tabs_exclusive`)
- Sets `selectedPeerProvider` to peerId
- Clears `selectedServerProvider`, `channelListProvider`, `selectedChannelProvider`, `serverSettingsOpenProvider`
- Calls `unreadProvider.notifier.markDmSeen(peerId, null)`

---

## _FriendChip — Individual Friend Avatar in Bar

`friends_bar.dart:_FriendChip` is a `StatelessWidget`. Renders a single friend as a compact chip in the horizontal FriendsBar.

**Props:** `peerId`, `name`, `isOnline`, `isSelected`, `unreadCount`, `avatarBytes`, `onTap`.

**Layout:** `HollowTooltip(message: name)` wrapping `HollowPressable` with `hollow.elevated` hover color. Selected state: `hollow.accent` at 15% alpha background. Padding: `HollowSpacing.sm` horizontal, 4px vertical. Horizontal margin: 3px.

**Contents (Row):**
1. **Avatar stack:**
   - `HollowAvatar(peerId, size: 24, imageBytes: avatarBytes)`
   - `StatusDot` overlay at bottom-right (-2, -2): 7px dot inside 10px `hollow.surface` circle. Green + pulse when online, `hollow.textSecondary` when offline.
   - **Unread indicator (conditional):** If `unreadCount > 0`, a `HollowCountBadge` (accent, `ring: hollow.surface`) at top-left (-4, -4).

2. **Name text:** `ConstrainedBox(maxWidth: 72)`. Caption style, 11px. `hollow.textPrimary` if selected, `hollow.textSecondary` if not. Bold (w600) if unread, normal (w400) otherwise. Single line ellipsis.

**Right click** (issue #61 phase 4): wrapped in a `Consumer` + `ContextMenuTarget` opening the shared user menu with the `dmTile` surface. A `Consumer` rather than a `ref` constructor field, because passing a `WidgetRef` into a constructor cascades rebuilds.

---

## _FriendsManager — Full Friends Dialog

`friends_bar.dart:_FriendsManager` is a `ConsumerStatefulWidget`. A modal dialog opened by the Add Friend button in FriendsBar. Contains 5 tabs for managing all friend relationships.

**Dialog opening:** `showFriendsManager(context, {addFriend})` (public; Home's checklist and the New message dialog open it on the Add Friend tab). Historically `_showAddFriendDialog()` used `showGeneralDialog` with:
- `barrierDismissible: true`, `barrierColor: Colors.black` at 50% alpha
- Transition: `HollowDurations.normal`, fade + scale from 0.95 to 1.0, `Curves.easeOut`

**State:** `_activeTab` (`_FriendsTab` enum: `friends`, `favourites`, `incoming`, `outgoing`, `add`). Default: `_FriendsTab.friends`. `_addController` (`TextEditingController`) for the Add Friend input, disposed in `dispose()`.

**Providers read:**
- `friendsProvider` — categorized into `accepted`, `incoming`, `outgoing`
- `peersProvider` + `invisiblePeersProvider` — online sorting for accepted list

**Sorting for accepted friends:** Online first (respecting invisible peers), then alphabetical by peer ID.

**Dialog container:** 520px wide, 480px tall, `hollow.background` color, `radiusLg` corners, `hollow.border` border, drop shadow (black 30% alpha, blur 24, offset (0,8)).

**Layout (Column):**
1. **Header (48px):** `LucideIcons.users` (18px) + "Friends" title (subheading, w600) + spacer + close button (`LucideIcons.x`, 18px, calls `Navigator.pop`).

2. **Tab bar (40px):** `hollow.surface` background with bottom border. Row of 5 `_TabButton` widgets:
   - "Friends" — shows `accepted.length` count
   - "Favourites" — shows `favouriteFriendsProvider.length` count, icon `LucideIcons.star`
   - "Incoming" — shows `incoming.length` count, `showBadge: incoming.isNotEmpty` (red badge)
   - "Outgoing" — shows `outgoing.length` count
   - "Add Friend" — no count, icon `LucideIcons.userPlus`

3. **Tab content (Expanded):** `AnimatedSwitcher` with `HollowDurations.fast`. Switch expression maps `_activeTab` to:
   - `_FriendsTab.friends` -> `_FriendsListTab(accepted: accepted)`
   - `_FriendsTab.favourites` -> `_FavouritesReorderTab(accepted: accepted)`
   - `_FriendsTab.incoming` -> `_RequestsTab(requests: incoming, direction: 'incoming')`
   - `_FriendsTab.outgoing` -> `_RequestsTab(requests: outgoing, direction: 'outgoing')`
   - `_FriendsTab.add` -> `_AddFriendTab(controller: _addController)`

---

## _TabButton — Tab Bar Button

`friends_bar.dart:_TabButton` is a `StatelessWidget`. A pressable tab in the `_FriendsManager` tab bar.

**Props:** `label`, `count` (nullable int), `isActive`, `showBadge` (default false), `icon` (nullable IconData), `onTap`.

**Rendering:** `HollowPressable` with `radiusMd` corners. Row containing:
- Optional icon (13px, accent if active, textSecondary if not)
- Label text (12px caption, accent + w600 if active, textSecondary + w400 if not)
- Optional count badge: pill container with count text. Background: `hollow.error` if `showBadge` is true, otherwise 15% alpha of active color. Text color: white if `showBadge`, otherwise active color. 10px, w600.

---

## _FriendsListTab — All Friends Tab

`friends_bar.dart:_FriendsListTab` is a `ConsumerWidget`. Shows all accepted friends with favourite toggle and remove buttons.

**Props:** `accepted` (List<FriendInfo>).

**Providers read:** `profileProvider`, `peersProvider`, `invisiblePeersProvider`, `favouriteFriendsProvider` (via Builder).

**Empty state:** Centered column with `LucideIcons.users` (40px, 30% alpha), "No friends yet", "Add a friend by their peer ID".

**List:** `ListView.builder` with `HollowSpacing.md` padding. Each item is a container with `hollow.elevated` background, `radiusMd` corners.

**Item layout (Row):**
1. **Avatar stack:** `HollowAvatar(peerId, size: 32)` with `StatusDot` overlay at bottom-right (7px dot inside 10px circle, `hollow.elevated` background).
2. **Name + status (Expanded Column):** Name (13px, w500), online status text (10px, green if online, textSecondary if offline).
3. **Favourite toggle button:** `HollowTooltip` ("Add to favourites" / "Remove from favourites"). `LucideIcons.star` (16px), `hollow.warning` if favourited, `hollow.textSecondary` at 40% alpha if not. Calls `favouriteFriendsProvider.notifier.toggle(peerId)`.
4. **Remove friend button:** `HollowTooltip` "Remove friend". `LucideIcons.userMinus` (16px, `hollow.error`). On tap:
   - Calls `friendsProvider.notifier.removeFriend(peerId)`
   - Calls `favouriteFriendsProvider.notifier.remove(peerId)`
   - If `selectedPeerProvider == peerId`, clears selection to null
   - If split view right pane shows this peer, calls `splitViewProvider.notifier.closeSplit()`

---

## _FavouritesReorderTab — Drag-to-Reorder Favourites

`friends_bar.dart:_FavouritesReorderTab` is a `ConsumerWidget`. Shows starred friends in a reorderable list.

**Props:** `accepted` (List<FriendInfo>).

**Providers read:** `favouriteFriendsProvider`, `profileProvider`, `peersProvider`, `invisiblePeersProvider`.

**Filtering:** `validFavs` = favourites list filtered to IDs present in accepted friends set (removes stale entries).

**Empty state:** Centered column with `LucideIcons.star` (40px, 30% alpha), "No favourites yet", "Star a friend in the Friends tab to add them here".

**List:** `ReorderableListView.builder` with `HollowSpacing.md` padding, `buildDefaultDragHandles: false`.

**Drag proxy:** `proxyDecorator` wraps child in `Material` with 4px elevation, `Colors.black26` shadow, `radiusMd` corners, transparent background.

**Reorder callback:** `favouriteFriendsProvider.notifier.reorder(oldIndex, newIndex)`.

**Item layout (Row):**
1. **Drag handle:** `ReorderableDragStartListener(index: index)` wrapping `LucideIcons.gripVertical` (16px, textSecondary).
2. **Avatar:** `HollowAvatar(peerId, size: 28)`.
3. **Name + status (Expanded Column):** Name (13px, w500), online status (10px).
4. **Remove button:** `HollowTooltip` "Remove from favourites". `LucideIcons.x` (14px, textSecondary). Calls `favouriteFriendsProvider.notifier.remove(peerId)`.

---

## _RequestsTab — Incoming/Outgoing Requests

`friends_bar.dart:_RequestsTab` is a `ConsumerStatefulWidget`. Shows pending friend requests with search filtering and accept/reject actions.

**Props:** `requests` (List<FriendInfo>), `direction` ('incoming' or 'outgoing').

**State:** `_searchController` (TextEditingController), `_query` (String, initialized empty).

**Providers read:** `profileProvider`.

**Empty state:** Centered column with direction-specific icon (`LucideIcons.inbox` for incoming, `LucideIcons.send` for outgoing, both 40px at 30% alpha), and direction-specific text ("No incoming requests" / "No outgoing requests").

**Search:** `HollowTextField` with direction-specific placeholder ("Search incoming requests..." / "Search outgoing requests..."), `LucideIcons.search` prefix, isDense. Filters by display name or peer ID (case-insensitive contains).

**No matches:** "No matches" body text centered.

**List:** `ListView.builder`. Each item: container with `hollow.elevated` background, `radiusMd` corners.

**Item layout (Row):**
1. **Avatar:** `HollowAvatar(peerId, size: 32)`.
2. **Name + subtitle (Expanded Column):** Name (13px, w500), subtitle ("Wants to be friends" for incoming, "Request sent" for outgoing, 10px caption).
3. **Action buttons:**
   - **Incoming:** Accept button (`LucideIcons.check`, 16px, `hollow.success`) calling `friendsProvider.notifier.acceptRequest(peerId)` + Reject button (`LucideIcons.x`, 16px, `hollow.error`) calling `friendsProvider.notifier.rejectRequest(peerId)`. Both wrapped in `HollowTooltip`.
   - **Outgoing:** Cancel button (`LucideIcons.x`, 16px, `hollow.error`) calling `friendsProvider.notifier.rejectRequest(peerId)`. Tooltip: "Cancel request".

---

## _AddFriendTab — Unified Add Friend Input

`friends_bar.dart:_AddFriendTab` is a `ConsumerStatefulWidget`. Unified input form for sending a friend request by peer ID or temporary nickname, plus a nickname claim section.

**Props:** `controller` (TextEditingController, managed by parent `_FriendsManagerState`).

**Auto-detection:** `_isPeerId(input)` checks if input starts with `12D3KooW`. If yes, sends via `friendsProvider.notifier.sendRequest()`; otherwise resolves as nickname via `network_api.sendFriendRequestByNickname()`.

**Layout:** Padded with `HollowSpacing.lg`. Column containing:
1. Instruction text: "Enter a peer ID or temporary nickname" (body, textSecondary)
2. Row: `HollowTextField` (hint "Peer ID or nickname...", mono 12px, autofocus) + "Send Request" filled button
3. Divider
4. "Your temporary nickname" section — watches `temporaryNicknameProvider`:
   - **Claimed state:** Shows nickname in accent-colored chip + "Release" ghost button
   - **Off/failed state:** `HollowTextField` (hint "Choose a nickname (3-20 chars)...") + "Claim" filled button (disabled while claiming)
   - **Error display:** Shows human-readable error for "taken" / "invalid" / generic failure

---

## Provider Dependency Summary

**HomeDashboard subtree reads:**
- `friendsProvider`, `sortedFriendsProvider`, `serverListProvider`, `homeSetupProvider`, `identityProvider`, `profileProvider` - title row and checklist
- `securityAlertsProvider`, `updaterProvider`, `hasUpdateProvider` - Needs Attention
- `lastDmMessageProvider`, `onlineIdentitiesProvider`, `unreadProvider`, `mentionPreviewProvider`, `serverChannelsProvider` - Conversations
- `newsProvider`, `changelogProvider`, `overallConnectionProvider`, `relayDomainProvider`, `relayStatsProvider`, `voiceChannelProvider`, `deviceLinkProvider` - side panel

**FriendsBar subtree reads:**
- `friendsProvider`, `peersProvider`, `invisiblePeersProvider`, `profileProvider`, `unreadProvider`, `notificationSettingsProvider`, `selectedPeerProvider`, `favouriteFriendsProvider` — FriendsBar
- `friendsProvider`, `peersProvider`, `invisiblePeersProvider` — _FriendsManager
- `profileProvider`, `peersProvider`, `invisiblePeersProvider`, `favouriteFriendsProvider`, `splitViewProvider` — _FriendsListTab
- `favouriteFriendsProvider`, `profileProvider`, `peersProvider`, `invisiblePeersProvider` — _FavouritesReorderTab
- `profileProvider` — _RequestsTab
- `friendsProvider` — _AddFriendTab (via ref.read for sendRequest)

**State mutations triggered:**
- `selectedPeerProvider`, `selectedServerProvider`, `channelListProvider`, `selectedChannelProvider`, `serverSettingsOpenProvider` — conversation/friend selection
- `unreadProvider.notifier.markDmSeen()` — read receipts on selection
- `friendsProvider.notifier` — sendRequest, acceptRequest, rejectRequest, removeFriend
- `favouriteFriendsProvider.notifier` — toggle, remove, reorder
- `splitViewProvider.notifier` — navigateRightToPeer, closeSplit
- `archiveTabOpenProvider`, `shareTabOpenProvider` — closed on friend selection
- `newsProvider.notifier.refresh()`, `updaterProvider.notifier.checkForUpdates()` — manual refresh
