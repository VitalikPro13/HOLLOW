# Regression pass before 0.12

**Status:** done 2026-10-01 (sessions 23 and 24), on local `main` after `b59efbcd`,
uncommitted at the time of writing. What remains is listed under "Not covered".
**Why:** the security audit (designs D, E, A, ID-1, relay hardening H, HOL-SEC-001 to
077) changed nearly every trust boundary, while the fleet journeys had gone stale. This
pass proves, over the real relay and in the widgets, that the app still does what it
did, that the new gates let honest traffic through, and that sync converges.
**Method:** the multi-node Rust harness for protocol claims, then the fleet (real
app instances driven by the probe) on Windows and on the Mac mini's iOS Simulators, and
a scan of every app log for refusal lines during honest journeys. Every bug found got a
test that fails without its fix, checked by reverting the fix (a mutation run).

The five findings the final pass left open were fixed in session 37 (next section);
the final pass on the finished 0.12 tree (session 36) follows it, then the sessions 23
and 24 pass.

## The final pass's five findings, fixed (session 37, 2026-10-05)

**Tree:** local `main` at `7da4d17e` plus this session's fixes, committed locally. The Mac
mini was brought to `7da4d17e` by `git push mini` (its stale tree discarded on
Vitalik's word), then given the diff as LF files (`git diff --stat` identical).

| Suite | Result |
|---|---|
| Rust (`cargo nextest run --lib`) | 1502 passed, 9 skipped (4 new tests) |
| clippy on changed lines | nothing |
| Flutter (`flutter test`) | 1951 passed, 3 skipped (2 new test files) |
| `flutter analyze` | 0 errors, nothing on changed files |
| Windows fleet: `server_invite_message`, `voice_channel`, `regress_channels`, `fleet_pending_join` | pass, twice |
| `fleet_profile_wipe` | 7 of 7 |
| 0.11.1 two-device upgrade (x, y, z from the s36 seed) | twice, posts live both ways |
| iOS Simulators: `mobile_voice_kick` | pass, ends on Chats |

1. **MLS fork when two devices of one identity commit at one epoch.** Worse than the
   0.11 upgrade alone: every device of an identity hears what is sent to it, and the
   coordinator elections pick an identity, so two online devices of a server's owner
   both committed a joiner's KeyPackage whenever their batch ticks fell within one
   network delay, and two upgrading 0.11 devices both rebound their leaf in place.
   And the heal never started: a forked device whose identity sorts first elected
   nobody to probe. Fixed in both halves:
   - one device per identity commits in a group: the lowest online one holding a leaf
     there as we see it (`we_commit_for_our_identity`), for the batch commit, the
     in-place rebind and the sibling re-add; a device that deferred its rebind and is
     still unbound after the bootstrap timeout rebinds itself; every KeyPackage goes
     to every online device of the target's identity, so the committing device holds
     it whoever asked;
   - the heal: the catch-up responder is the lowest online member other than the one
     behind; each copy of a group keeps the digest of its recent epochs, so a probe
     from an epoch we passed is judged forked instead of served a catch-up that can
     never apply; of two forks the one the authority's lowest online device holds
     stays (a responder facing it asks it for a repair), so the two sides never
     repair each other back; a digest-less epoch hint has its own cooldown and no
     longer silences the probe that carries the digest.
   Tests `two_devices_of_the_owner_add_a_joiner_once` (`MockRelay::hold_broadcasts`
   reproduces the crossing commits) and `a_fork_between_the_owners_devices_heals_without_a_restart`
   (the fleet's shape: the owner's lowest device alone on one fork, everyone posting;
   the wiretap shows that device is never moved). Mutation: the commit gate, the
   responder fallback, the epoch history, the fork rule and the cooldown split each
   fail a test when reverted. Fleet: the 0.11.1 two-device identity and its friend
   upgraded at once from the s36 seed (twice): one in-place rebind, the sibling
   re-added in the same commit, every post read live by the other two, no decrypt
   failure after the replayed 0.11 frames at start-up.
2. **Friends saw "added a new device" for an upgraded identity's own device.** A
   device the upgrade's phrase admitted (`Roster::upgrade_admitted`, only while the
   upgrade's base is current), already in the friend's saved roster, is not news when
   its consent arrives; any other device still alerts. Tests
   `an_upgraded_identitys_own_devices_are_no_news_to_its_friends` (rosters arrive one
   at a time, a device linked later by a vouch still alerts) and
   `only_the_upgrades_own_base_counts_its_admissions`. Fleet: the friend `z` took the
   identity's roster with one member and then two and recorded no alert (s36 recorded
   one for `x`); the one alert it shows was already in the 0.11.1 seed, since none
   was recorded during the run.
3. **The "Recording saved" toast covered the call bar.** A `ToastKeepClear` marks the
   call bar; a toast that would overlap a marked box rises above it, and stays put
   when nothing is in the way. `fleet_profile_wipe` now taps hang-up while the toast
   is on screen: 7 runs, all gates pass (`build/fleet_out/s37/finding3_toast_before_after.png`).
   The script also points HOME at its scratch folder now: launched from Git Bash it
   had left a test recording in the real `Videos\Hollow Recordings` (removed).
4. **A phone kicked from a server stayed on its channel page.** The page leaves when
   its server leaves `serverListProvider` (not while the list is still loading, never
   for a DM). Widget test `mobile_chat_route_server_gone_test.dart`; `mobile_voice_kick`
   on the iOS Simulators now ends with the kicked phone on Chats
   (`build/fleet_out/s37/finding4_kick_before_after.png`).
5. **Joiners logged `Ignoring ServerJoinResolved from non-member`.** A resolution from
   a device we cannot place yet (right after a join, ours or a co-joiner's) is logged
   quietly; one from a placed identity that is not a member keeps the security line.
   The refusal scans of `server_invite_message`, `voice_channel`, `regress_channels`
   and `fleet_pending_join` hold no such line (3 quiet lines instead).

Remaining refusal lines in those scans are classes already explained below (Olm glare,
a fresh joiner refusing an RTC offer from a device it cannot place yet) plus a held
commit overtaken by a newer one, which is the commit judge working.

**Seen, not changed:** the s36 seed holds a second old 0.11 server where only `y` and
`z` keep a group (`x` does not count its own identity a member there) and each takes
itself for the group's authority, so both rebind their leaf in it; it behaved the
same in s36, and only that seed's 0.11 data has it.

## Final pass before release (session 36, 2026-10-05)

**Tree:** local `main` at `a2638379` plus this session's two fixes, uncommitted. The
Mac mini was brought to the same tree without git (an LF archive of the diff, checked
by the tree hash).

| Suite | Result |
|---|---|
| Rust (`cargo nextest run --lib`) | 1498 passed, 9 skipped (3 new tests) |
| clippy on changed lines | nothing |
| Windows fleet, `scripts/fleet_all.ps1` (28 items, fresh build and identities) | 28 pass (27 first time; `fleet_destroy` after its gates were brought in line with HOL-SEC-156) |
| iOS Simulators, 10 phone scenarios plus `mobile_call` and `mobile_voice_kick` | all pass |
| New checks for the s35 decisions and the s34 device lists | see below |
| 0.11.1 clients against today's relay (`fleet_device_link` built from `v0.11.1-beta`) | 22 of 22 |
| Load-timing tests from s35 | 5 of 5 alone each, and about 20 s each inside the full suite |

Evidence is under `build/fleet_out/kept/session36/` and `build/fleet_out/all/`
(gitignored). The refusal scans were read item by item: every line is one of the
classes explained in the session 24 section, plus the three below.

**The s35 decisions, proven live**
- A (recordings) and B (a wipe touches only its profile): `scripts/fleet_profile_wipe.ps1`,
  5 of 5. Two profiles in a scratch APPDATA and home; profile B records a real call
  (5 MB file) into a shared `Hollow Recordings` folder that also holds profile A's
  recording and a stranger's file; B destroys this device. Only B's recording goes,
  `profiles.json` drops B and pins A, B's root is empty, no old debug log survives,
  A is untouched.
- C (legacy phrase): a 0.11.1 two-device identity, its friend and a 0.11 server were
  made with the 0.11.1 build, then started on 0.12. Every device signed the first
  recovery from its stored phrase and claimed its seat, the phrase prompt confirmed and
  erased on one device and stayed as a reminder on the other ("Later"), DMs and the old
  server work in every direction. It found bug 2 below and findings 1 and 2.
- D (request thumbnails): `regress_request_thumb`, both pending rows show the other
  side's avatar, the still one and the first frame of the animated one.
- E (per-transfer stream ids): `regress_two_device_file`, on the fleet
  `fleet_device_link -KeepUp` leaves: a server file to both devices of one identity at
  once, a file from the linked device to its sibling and a friend, a DM file to both
  devices. All six copies are byte-identical to their sources.

**The s34 device lists**
- Voice calls with kicks: `regress_voice_kick` (Windows) and `mobile_voice_kick`
  (phones). Found bug 1.
- Joins on a busy server: `regress_busy_join`, the joiner holds all 16 messages, from
  before and during its join.
- DM and server re-add: `fleet_friend_readd` 6 of 6, kick and rejoin in `moderation`
  and both kick scenarios.
- Desktop locked toasts: `regress_locked_toast`, a DM while locked posts only the
  neutral toast (`locked toast posted`), the message is there after unlock.
- Wipe traces on Windows: `fleet_destroy` and `fleet_profile_wipe`, empty roots, no
  debug log, the OS temp names gone.
- iOS: the App Group data, push hints, push diag and `Documents/hollow` all carry the
  backup exclusion; App Lock on writes only `{"~locked":true}` into the hints and turns
  the switcher cover on; the snapshot iOS takes for the app switcher is the blank cover
  while locked and the screen while unlocked (decoded from SplashBoard); the PIN opens
  the app after a restart (the this-device keychain class round trip); turning the lock
  off clears the hints and the cover.
- Cross-platform: a friend request, DMs both ways and a voice call between Windows and
  an iPhone Simulator.

**Bugs found and fixed (each with a harness test, mutation-checked)**

1. **A member kicked from a server while in its voice channel stayed in a ghost call.**
   The kick's teardown removed the server state before the auto-leave ran, and the
   auto-leave only left when the state existed; the owner's delete never called it.
   The kicked device kept the room on screen and redialled the others every 20 to 30 s
   (they refused it, so no media flowed). Fix: the auto-leave treats a server we no
   longer hold as one we are out of, and the delete op (plaintext and MLS twin) and the
   sync-reconciled eviction call it. Tests `a_kicked_member_leaves_its_own_voice_call`,
   `a_deleted_servers_call_ends_for_every_member`. Proven on Windows and the phones.
2. **The two devices of an upgraded 0.11 identity stopped counting each other.** A
   0.11 link copied the stored phrase, so each device upgrades on its own at its first
   0.12 start with only its own consent, and nothing told the sibling: both showed "Only
   this device is linked", sibling sync stopped and one device refused the other's MLS
   rebind. Fix: a start that builds the first roster from a 0.11 list announces it once
   it connects, the way a phrase change does (own room, contacts, mailbox). Test
   `a_legacy_identity_whose_devices_both_kept_the_phrase_stays_one_identity` asserts
   the announce on the wire, since the harness's shared resolver hides the split
   itself; the fleet upgrade proved the fix (two devices on each, sibling sync running).

**Findings left open (decisions for Vitalik)**

1. Two devices of a 0.11 identity that upgrade at the same moment each rebind their
   MLS leaf in a server they share and fork the group. The forked device misses live
   posts there (each arrives seconds later through the Olm sync fallback) until it
   reconnects or restarts, which heals it. A decrypt failure at our own epoch sends no
   fork probe. Proposed: probe with the `epoch_auth` digest on such a failure.
2. Friends of an upgrading multi-device identity see "added a new device" for a device
   they already knew, because the first 0.12 roster they hold carries one consent and
   becomes the baseline. The 0.11 list cannot help: the roster replaces it in the same
   row. Proposed: a device the stored roster already admitted is not new when only its
   consent arrives.
3. The "Recording saved" toast covers the call bar's hang-up button while it shows.
4. On a phone, a member kicked while viewing a channel stays on that channel's page
   of the lost server.
5. Every joiner logs `Ignoring ServerJoinResolved from non-member` for its own join:
   the resolution arrives after its snapshot and before it can place the owner's
   device. Harmless; a quiet return for our own join would remove it.
6. A wipe deletes the legacy keychain slot `com.hollow.identity.wrapping_key` along with
   its own per-profile slot. On macOS (no DPAPI fallback) another profile that never
   started since the per-profile slots came in would lose its key.
7. A share-backed DM file's first share offer can arrive before the receiver has heard
   the sender's "have" and is dropped; the next tick connects (about 11 s).

**New refusal classes seen on honest traffic, explained**
- `Ignoring ServerJoinResolved from non-member` on a joiner (finding 5).
- `Not answering a door ask ... no device of a member` while a joiner is not admitted
  yet (D1 working).
- `Dropped RtcShareOffer ... proved no link to a share we hold` (finding 7).
- After the 0.11 upgrade: 0.11 frames the relay still held, refused as `Unsealed`.

**Not covered, and why**
- The iOS notification extension's neutral banner: `simctl push` delivered the alert
  without running the extension. Needs a real iPhone and APNs.
- macOS App Lock launch secret after the keychain class change: needs the signed
  build (the data-protection keychain wants the team's entitlement). Check it on the
  notarized release build.
- Shares through the media forwarder: the forwarder on the box predates s34 and gave
  0.12 clients no session, so the viewer fell back to the direct route (which works).
  The new forwarder deploys on release day; then run `regress_voice3` with
  `HOLLOW_FORCE_RELAY_ROUTE=1` and expect "assigned to infra forwarder" with no
  `direct_failed`.
- Android (FLAG_SECURE, recents, clipboard, neutral banners) and a real FCM push to a
  closed phone: Vitalik.

**Fleet tooling changed**
- `fleet_destroy.ps1`: the order and wipe gates judge by the exit and the empty root
  when the wipe erased the debug log (HOL-SEC-156), and say so in a note.
- New: `fleet_profile_wipe.ps1`, scenarios `regress_request_thumb`,
  `regress_two_device_file`, `regress_voice_kick`, `regress_busy_join`,
  `regress_locked_toast`, `mobile_call`, `mobile_voice_kick`.

## Results at the end of session 24

| Suite | Result |
|---|---|
| Rust (`cargo nextest run --lib`) | 1169 passed, 8 skipped |
| Flutter (`flutter test`) | 1787 passed, 3 skipped |
| `flutter analyze` | 0 errors (warnings all predate this pass) |
| clippy on changed lines | nothing |
| Windows fleet, `scripts/fleet_all.ps1` (28 items) | 28 pass (27 in the full run; `regress_media` passed on its rerun after its bug was fixed) |
| iOS Simulators (9 phone scenarios) | 9 pass (2 after selector fixes) |
| Relay box `deploy/check-host.sh` | every check ok |
| Relay unit tests on the VPS (`test/run_tests.sh`) | all pass (auth frame, fair share, join lock, kill list, ring auth, snapshot codec and the rest) |

The Windows run table, every item's log, each peer's app log per item and the refusal
scans are in `build/fleet_out/kept/session24/fleet_all_run2/` (gitignored, local). Run 2
was a fresh build and fresh identities, about 90 minutes.

## Checklist

Evidence paths are under `build/fleet_out/kept/` on the Windows machine.

**Friends and DMs**
- [x] Request by id, accept, decline, request to an offline friend, remove and re-add
  needs fresh consent: `friend_dm`, `fleet_friend_decline`, `fleet_friend_offline`,
  `fleet_friend_readd` (6/6). Phones: `mobile_friend_dm`.
- [x] DMs both ways, offline backfill, fan-out to every device: `fleet_multidevice_dm_gap`
  (8/8); phones by hand in session 23 (`session23/shots/p27*`).
- [x] Edit, react, reply, delete in a DM: session 23 on the phones (`p47`, `p48`).
- [x] Block and unblock (blocked DM never shows, the next one after unblock does),
  nickname claim and lookup, profile audience while a request is pending (the pending
  side sees the name, never the status or about text): `regress_social`.
- [x] Safety number verify: `fleet_destroy` G2.

**Servers**
- [x] Create, invite (`key=`, `relay=`), join on Windows and phone, pending join with
  the owner offline: `server_invite_message`, `fleet_pending_join` (8/8),
  `member_panel_pass`, `member_panel_mobile`.
- [x] A stranger joins while the owner is away, the owner returns and converges, and
  (new) a member closed while the owner deletes the server loses it on return:
  `fleet_owner_offline`.
- [x] Restricted channel for moderators, promotion shows it, a post reaches the
  moderator and never the member, kick, rejoin, ban, refused rejoin: `moderation`.
- [x] Channel rename and delete reach members; edit, react, reply, delete, pin and
  @mention in a channel; a public channel's post reaches everyone: `regress_channels`.
- [x] Offline channel image and file catch-up: `fleet_channel_file_catchup` (7/7).
- [x] Server settings, member panel, places: `server_settings_after`, `places_after`,
  `server_settings_after_mobile`.

**Files and media**
- [x] Images re-encoded to WebP, files on disk as HFE1 ciphertext (both phones,
  session 23), honest file card states: `fleet_file_card_states` (6/6).
- [x] Albums: `album_dm`. Stickers, GIFs and personal emotes across an offline gap:
  `fleet_asset_offline`, `fleet_device_link` G8.
- [x] Video, the auto-download gate at Off (card waits, Download completes), a 40 MB
  file over the Share lane, a voice message: `regress_media`
  (`session24/shots/regress_media/`).

**Calls and voice**
- [x] DM call, voice room, share offer: `calls_after`, `calls_after_vc`; DM call between
  two phones, about three minutes (session 23, `p61`, `p64`).
- [x] Voice channel with two, and with three where one leaves; screen share is
  opt-in (an offer and no stream until Watch, then the stream, then it stops with the
  share): `voice_channel`, `regress_voice3`.

**Multi-device and identity**
- [x] Link in every direction, removal and phrase recovery, restored backup approve:
  session 23 on the phones and Windows.
- [x] A device linked after the server exists reads it and posts into it, live in all
  four directions, and read state follows across devices: `fleet_device_link` (22/22).
- [x] Destroy everywhere with the phrase: `fleet_destroy` (10/10).
- [x] App lock (set password, Lock now, the right password lifts the cover, a wrong one
  is refused) and the duress code saving: `regress_app_lock`
  (`session24/app_lock/`). Run on this account with
  `%APPDATA%\com.anonlisten\hollow\flutter_secure_storage.dat` copied aside and restored
  byte for byte afterwards; Credential Manager held no Hollow entry before or after.

**Design surfaces**
- [x] `chat_redesign`, `avatar_frame`, `unread_line`, and on the phones `chat_mobile`,
  `redesigns_after_mobile`, `design_sweep_mobile`, `mobile_swipe_back`,
  `settings_mobile_after`, `home_mobile`.

## Bugs found and fixed

Session 23 (details in `tmp4.txt` and the wiki): a restored backup with no contacts
never heard its approval (`roster_book::own_room`); a device behind on its roster never
re-proved its inbox (`reprove_own_inbox`); co-members who are not friends never learned
each other's rosters at join time (`after_welcome_joined` ProfileRequest); "A iOS
device"; desktop-sized lock buttons on a phone; the unread mark painted under the
scrollbar thumb.

Session 24:

1. **A returning owner never placed a member who joined while it was away.** It never
   saw the join request that carries the joiner's roster, and the joiner's Welcome found
   it offline, so neither side could place the other's device and every audience gate
   stayed shut (the member row read `12D3KooW...`). Fix: the MLS batch tick introduces
   us to each device our server group certifies for a CRDT member that our own store
   cannot place (light profile with the roster, then a ProfileRequest; the request is
   answered on the strength of the certified leaf). Test
   `an_owner_back_from_a_join_it_missed_learns_the_joiners_devices` (names and avatars
   both ways). Proven in the fleet by `fleet_owner_offline`.
2. **A newly linked device could stay without its server leaf.** Its KeyPackage rides
   the Relay lane and outran its roster (Olm), so the member that received it could not
   tie it to the owner, deferred to the owner, and the owner never saw it; with no
   channel traffic nothing asked again. Friends' posts reached the new device only as
   hints. Fixes: the batch tick asks again for any server group a member does not hold
   (to the owner, or our own sibling when the owner is our identity), and the receiver
   excludes the sender by the master its KeyPackage certifies. Tests
   `a_new_device_whose_first_leaf_ask_is_lost_asks_again`,
   `the_owners_new_device_gets_its_leaf_and_every_post`. Proven by `fleet_device_link`
   G7.
3. **A device without a leaf posted past its own siblings.** The Olm fallback skipped
   our own identity. Test `a_leafless_devices_post_reaches_its_sibling`.
4. **A new sibling's first sync was rate limited.** The per-peer flood limit (100
   burst, 20 per second) applied to our own devices too; the first sync after a link
   exceeds it and the dropped frames were lost to the new device (found by the refusal
   scan in `fleet_destroy`). Own devices are now exempt. Test
   `a_siblings_burst_is_never_rate_limited` (26 to 67 of 160 lost without the fix).
5. **A DM file over 34 MB never arrived.** "Send as Share" created the Share, but the
   DM header was always built with `share_ref: None`, so the friend refused it for its
   size; a later missing-file sweep pulled all 40 MB through the relay stream instead.
   DM headers now carry the Share and no bytes ride the DM. Test
   `a_share_backed_dm_file_reaches_the_friend_as_a_share`. Proven by `regress_media`.
6. **A share-backed DM file never auto-downloaded** whatever the setting: the Dart gate
   waited for a server sync that DM sync never completes. `shareAutoDownloadScope`,
   `test/share_auto_download_scope_test.dart`.

## Refusal lines on honest traffic, explained

Every item's refusal scan was read. What remains, all explained and harmless:
- KeyBundle glare: the documented Olm glare resolution.
- Ban refusals, decline notices, a duplicate join answer dropped: the gates working.
- A joiner's first second after its Welcome: it refuses the owner's channel sync, its
  backfill and an RTC offer from a device it cannot place yet; the Welcome-time
  ProfileRequest places it within the second and the journeys converge.
- The stranger window before admission: profile fields ignored, a ProfileRequest
  ignored, from co-members not admitted yet.
- `#staff` catch-up asked of, or by, a member who cannot read it: both ends refuse.
  Wasted traffic, left as it is (narrowing every catch-up path risks the one that later
  succeeds in the join window).
- ICE candidates sent to a peer that was just closed (`fleet_friend_offline`).

## Not covered, and why

- Link previews live (needs a fetchable page on the sender's side), typing (a peer's
  typing label cannot be held long enough to shoot; a widget test covers it).
- Access labels and grants changed live, the guest web viewer, a relay switch (needs the
  self-hosted VM relay), a relay restart (restarts production), the at-rest migration
  from an older build: all opt-in or outside this pass.
- Video pixels and audio: screenshots cannot prove them; the share watch proves the
  stream appears and stops.
- iOS: `fleet_device_link.ps1` and `fleet_owner_offline.ps1` stop at their first
  step on the Simulators (stale phone selectors, Windows-only relaunch); phone linking
  was proven by hand in session 23.
- Relay spot checks beyond `check-host.sh` and the unit tests: a stranger reading a DM
  room's roster is prevented by design (DM room codes are an HMAC of the masters' X25519
  keys) and covered by the C-24 wiretap tests, not driven live.

## UX decided after session 23 (next, before ID-1R)

Phone dialog buttons stack full width when they do not fit; device names show only
"Desktop" or "Phone"; calls ring every device of a friend, first accept wins, siblings
show a locked "In a call on another device", one call per identity with voice channels
counted alike; a reply to a deleted message reads "Deleted message". The call screen
captions stay as they are.
