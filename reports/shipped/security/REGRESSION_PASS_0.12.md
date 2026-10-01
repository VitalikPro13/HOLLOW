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
