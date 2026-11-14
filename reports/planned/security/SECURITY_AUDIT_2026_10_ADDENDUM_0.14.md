# Addendum for 0.14: HOL-SEC-187 to HOL-SEC-206

This addendum carries the 0.14 findings into `SECURITY_AUDIT_2026_10.md`. It is EMBARGOED
until 0.14 ships. On release day each part below goes where its heading says, and the PDF
is rebuilt (`PLANNED_TO_SHIPPED_0.14.md`, section 4). Written 2026-11-05 and brought up to
date on 2026-11-14 from the finding files and the commits on the local branch
`security/0.14`, up to `89d3a85d`.

---

## Goes after section 1, "Limits of this review": a new subsection

### After 0.13: the 0.14 findings

Twenty findings were filed after 0.13.0 shipped, numbered HOL-SEC-187 to HOL-SEC-206. They
came from a review of the installed macOS app, the hostile reviews of the 0.14 designs and
code, probes written while building 0.14, the STRIDE slices of section 6.2, a fuzz target,
and a review of the 0.14 dependency upgrades. Every one is fixed on the 0.14 branch. All
twenty stay private until 0.14 ships, then publish with its advisories.

| Severity | C | A | P | S | Total |
|---|---|---|---|---|---|
| High | 2 | 1 | 0 | 0 | 3 |
| Medium | 5 | 2 | 1 | 0 | 8 |
| Low | 6 | 2 | 1 | 0 | 9 |
| Total | 13 | 5 | 2 | 0 | 20 |

With them, the review's record holds 202 findings, numbered HOL-SEC-001 to HOL-SEC-206
(166 to 169 unused, section 3.10).

0.14 also narrows the fuzzing limit above. The Rust wire parsers now
run under 23 cargo-fuzz targets (sealed frames, envelopes, CRDT batches, rosters, archives
and file names among them; about 30 million executions in the first run, one finding,
HOL-SEC-202), and the relay's libFuzzer set has a tenth target for its denylist.

---

## Goes at the end of section 3.10, "Finding numbers"

The findings filed after 0.13.0 are HOL-SEC-187 to 206, in the order they were filed. The
fuzz finding was first given 196, which the setup wizard's review had taken the same day,
and was renumbered 202 before any file was written under either number. The hostile review
of the 0.14 relay code drafted numbers for findings in code that never shipped; those
drafts were void and used no number.

---

## Goes at the end of section 4, "Findings table"

From HOL-SEC-187 on, the fixes ship in 0.14; the commits are on the local branch
`security/0.14` until that release. A relay-only fix is deployed to the official relay
before the 0.14 clients.

| ID | Title | Severity | Class | Status | Fixed in |
|---------|------------------------------|--------|----|------|--------|
| HOL-SEC-187 | The macOS app could load code from directories outside its bundle | High | C | Fixed | 0.14 (d957c635, b8b64d15, 5da98071) |
| HOL-SEC-188 | A device its roster removed could still write server history with the master key | High | C | Fixed | 0.14 (5af8f7b7, 060ca581, 11d2619f, dcce6b29) |
| HOL-SEC-189 | A removed device's vouch flood could uncount a device another voucher holds | Medium | C | Fixed | 0.14 (23891904) |
| HOL-SEC-190 | A received voice's volume was looked up by the track id its sender chose | Medium | C | Fixed | 0.14 (33024bdb) |
| HOL-SEC-191 | The Windows screen share's voice redirect found voices by the track id their sender chose | Medium | C | Fixed | 0.14 (80daf1f8) |
| HOL-SEC-192 | A stranger's friend requests and join asks were kept without a bound | Medium | A | Fixed | 0.14 (d42cad43) |
| HOL-SEC-193 | A carried profile card or update keeps a roster for any identity its sender's device signed | Medium | A | Fixed | 0.14 (a58d7f38) |
| HOL-SEC-194 | A member served a public channel's deleted posts, and their files, to a non-member | Low | P | Fixed | 0.14 (c7caff62) |
| HOL-SEC-195 | A leave during the screen share picker left a live share for the next room | Low | C | Fixed | 0.14 (f0805308) |
| HOL-SEC-196 | A take over's backup could hold a link, and its rollback read through it as root | Medium | C | Fixed | 0.14 relay setup (3d62ce35) |
| HOL-SEC-197 | A take over copied the old relay's state by name while the old services ran | Low | C | Fixed | 0.14 relay setup (3d62ce35) |
| HOL-SEC-198 | Removing the relay left the take-over backup with the old relay's secrets | Low | C | Fixed | 0.14 relay setup (3d62ce35) |
| HOL-SEC-199 | The setup's certbot ran as root from packages nobody pinned | Low | C | Fixed | 0.14 relay setup (3d62ce35) |
| HOL-SEC-200 | Olm pickles left session and account secrets in freed memory on every save | Low | C | Fixed | 0.14 (a6cdf8c4) |
| HOL-SEC-201 | MLS saves left group and signing secrets in freed memory on every message | Low | C | Fixed | 0.14 (bc2c4bdc) |
| HOL-SEC-202 | A file name cut to length could come out as a Windows device name | Low | A | Fixed | 0.14 (82df7694) |
| HOL-SEC-203 | A wrong-typed keys.json ended the relay without its restart snapshot | Low | A | Fixed | Relay 0.14 (883aa238) |
| HOL-SEC-204 | A self-hosted install's background push fetch dialled the official relay | Medium | P | Fixed | 0.14 (5965e6b9) |
| HOL-SEC-205 | A received sticker pack was unpacked with no size limit as soon as its card showed | High | A | Fixed | 0.14 (89d3a85d) |
| HOL-SEC-206 | Importing a shards bundle could replace a vault file's key or store shards no manifest names | Medium | C | Fixed | 0.14 (89d3a85d) |

---

## Goes at the end of section 5, "Findings"

### HOL-SEC-187: The macOS app could load code from directories outside its bundle

**Severity:** High (Impact H, Exploitability M). **Class:** C. **Fixed in:** 0.14 (d957c635, b8b64d15, 5da98071). **Affected:** every macOS release from 0.5.0 through 0.13.0.

**Impact.** Code planted by another program running as the same user could run inside the signed app, with its keychain access, its camera, microphone and screen grants, and the identity in memory.

**Description.** The release carried library search paths that point outside the app (Homebrew's and `/usr/local` folders, an Xcode toolchain path) and was signed with library validation turned off, so the loader took user-writable libraries into the app. Every signed build could also open the identity key's keychain item without a prompt, so an old build carrying a planted library still reached the key after the load fix.

**Fix.** A release gate strips every search path that leaves the bundle, refuses any that remains, and checks after signing that no executable waives library validation; the shipped signature no longer waives it. The identity key moves into a keychain group that only builds with a validated Developer ID profile can read, after a self-check of the bundle's own signature and loaded images; the first 0.14 start moves the old item and deletes nothing it cannot read back. An App Lock entry moved to its new keychain class is copied under a staging name and read back before the old one goes, so a stop in between loses no secret.

**Residual.** Legacy virtual cameras on macOS 12 and 13 stop working (accepted). Until the old team's certificate is revoked, old builds keep the privacy grants. The retest on the notarized 0.14 build runs before release.

**Test.** `scripts/macos_load_gate_test.sh` (43 cases) with its source guard `test/macos_load_gate_guard_test.dart`; `a_legacy_key_moves_into_the_protected_keychain_then_leaves`, `a_move_cut_short_keeps_both_and_finishes_at_the_next_start`; `test/app_lock_keychain_groups_test.dart` for the App Lock move; the signed-build check `scripts/macos_keychain_check.sh` on throwaway macOS 14, 15 and 26 runners.

### HOL-SEC-188: A device its roster removed could still write server history with the master key

**Severity:** High (Impact H, Exploitability M). **Class:** C. **Fixed in:** 0.14 (5af8f7b7, 060ca581, 11d2619f, dcce6b29). **Affected:** every release from 0.12.0 through 0.13.0.

**Impact.** A stolen device its owner had already removed could still change servers in the owner's name. For an owner, that means any server state, a server delete and every moderation act.

**Description.** The roster decides which devices are a person's, but every device holds the master key, and server operations, the relay's join lock and channel posts were checked only against the master signature. A removed device could sign server operations, keep the door to a server's room, and have its posts carried into everyone's history by another member's sync.

**Fix.** One design (`DEVICE_PROOF_DESIGN.md` rev 3.5), built in three tracks. The relay's join lock takes a lock change only from a device the relay's fold of the identity's rosters counts, and moves the lock whenever a member's device is removed (5af8f7b7). The roster gives one verdict on which devices count, and a flood cannot push out the removal that keeps a device out (060ca581). Every server operation, channel post and change to a post now carries a proof from the device that wrote it; past a server's cut (its first owner checkpoint or founding operation that commits to a recovery key) only what a counted device proved takes effect, live, in sync and in backfill (11d2619f). A lost or stolen device is settled back to what it did before the person last had it, and the owner, the members and the person recovering see what happens (dcce6b29).

**Residual.** The post gate compares dates the author picks, so a removed device can still place content at an old date through a replica that has not heard of the removal. A removed device's operations from before the person last had it stay, as that person chose. A retire written by a remover that lacks part of the history sets a narrower post window (AR-41), and a recovery key a master-key holder forged and showed first is AR-15. A 0.13 member's posts without a proof are refused past the cut, which the 0.13 status notice says.

**Test.** Relay `test_join_lock.cpp` and `a_pinned_device_chain_verifies_as_the_relay_verifies_it`; `authority_ignores_first_sight_and_maturity`, `a_device_never_floods_out_a_removal_of_itself`; `after_the_cut_only_a_counted_device_writes_and_a_members_op_parks`, `a_post_after_the_cut_needs_a_counted_device_a_window_or_a_pre_cut_date`, `a_backfilled_page_keeps_only_posts_a_counted_device_proves`, and the harness tests `w3c1_a_removed_device_writes_no_server_history_after_the_cut`, `t14c_a_removed_devices_changes_are_refused_after_the_cut` and `w3c1_a_lost_laptop_settles_back_to_what_it_did_before_t`. Each fails with the master signature alone.

### HOL-SEC-189: A removed device's vouch flood could uncount a device another voucher holds

**Severity:** Medium (Impact M, Exploitability M). **Class:** C. **Fixed in:** 0.14 (23891904). **Affected:** every release from 0.12.0 through 0.13.0, and every relay since 2026-10-02.

**Impact.** An honest linked device could stop counting at every contact, in DMs and at the relay's inbox, until the person's recovery phrase put it back.

**Description.** The roster's cap on vouches ranked them by their signer and ignored removals. A removed device ranked ahead of an honest voucher could flood vouches and push that device's only valid vouch past the cap.

**Fix.** The cap judges each vouch by its signer's standing under the removal walk; only removals that every view counts can void a vouch; each standing device keeps its vouch from the nearest valid voucher, and compacting twice changes nothing. The app and the relay apply the same rules and share pinned vectors.

**Residual.** A device that still counts and floods its own roster can push out vouches ranked after it (as HOL-SEC-079 states); membership, ranks and the walk are kept.

**Test.** `compaction_is_idempotent_under_a_vouch_flood` (300 random flooded identities), `roster_vectors_are_current`, relay `test_roster`, `review189_a_master_key_pending_join_uncounts_a_linked_device`.

### HOL-SEC-190: A received voice's volume was looked up by the track id its sender chose

**Severity:** Medium (Impact M, Exploitability M). **Class:** C. **Fixed in:** 0.14 (33024bdb). **Affected:** every release with calls or voice channels through 0.13.0.

**Impact.** A participant could keep playing for a listener who had deafened or muted them, or move the listener's volume for another member.

**Description.** Deafen and the volume sliders named a voice by its track id, which the sending peer writes itself. Native code looked the id up among the listener's own tracks first and then across every connection.

**Fix.** Volume is set by the local connection and the receiver, and native code looks only among that connection's receivers. Deafen and the sliders cover every audio receiver of a connection, and a voice that arrives later takes the volume already chosen.

**Residual.** Gossip forwards, which ship turned off, take the forwarder's connection volume under deafen (AR-40).

**Test.** `test/remote_receiver_volume_test.dart`, the "receiver-keyed volume" group of `test/gossip_forward_service_test.dart`; mutation pass 18 of 18.

### HOL-SEC-191: The Windows screen share's voice redirect found voices by the track id their sender chose

**Severity:** Medium (Impact M, Exploitability M). **Class:** C. **Fixed in:** 0.14 (80daf1f8). **Affected:** every Windows release from 0.10.0 through 0.13.0.

**Impact.** During an entire-screen share with audio, a participant could have our own microphone played back to us and its voice mixed into the shared audio; with no attacker at all, deafen and the sliders did nothing during a share.

**Description.** The redirect that keeps received voices out of the shared audio chose voices by track id through the same global lookup as HOL-SEC-190, and ignored the listener's volume.

**Fix.** The redirect names each voice by connection and receiver, carries the volume it should play at, and hands each voice back at that volume when the share stops; it caps voices per connection so one peer can only silence its own.

**Residual.** For a moment between a share starting and the redirect attaching, a voice can still play in the main process; if the redirect's helper dies mid-share, voices stay silent until the share stops.

**Test.** The "1:1 call" and source-guard groups of `test/remote_receiver_volume_test.dart`, the "share voice redirect" group of `test/gossip_forward_service_test.dart`, `test/vc_leave_teardown_test.dart`; a Windows fleet run on the 0.14 test relay.

### HOL-SEC-192: A stranger's friend requests and join asks were kept without a bound

**Severity:** Medium (Impact M, Exploitability H). **Class:** A. **Fixed in:** 0.14 (d42cad43). **Affected:** every release through 0.13.0.

**Impact.** Anyone who knew a person's id, or held any invite link, could grow that person's stored rosters, cards, settings rows and request list without limit.

**Description.** A friend request stored the requester's roster, key bundle, card and a pending row before any bound; an answer that matched nothing of ours still stored its roster; a join ask stored the asker's roster and card on every member that opened it.

**Fix.** At most 64 pending incoming requests, 32 of them from people who share no server with us, checked before anything is written. An answer keeps a roster only when it meets our own request or a friendship. A join ask keeps the asker's roster and card only when the server would admit it, and only on the member that answers; the others hold them briefly in bounded memory.

**Residual.** A flood of up to 32 junk requests fills the strangers' share until they are declined or blocked; an honest stranger's request waits in the relay's mailbox meanwhile.

**Test.** `review_ab_incoming_friend_requests_from_minted_identities_stay_bounded`, `t14f_review_live_asks_a_member_steps_aside_from_keep_nothing_until_admitted`, `t14f_a_strangers_accept_or_decline_keeps_no_roster`.

### HOL-SEC-193: A carried profile card or update keeps a roster for any identity its sender's device signed

**Severity:** Medium (Impact M, Exploitability M). **Class:** A. **Fixed in:** 0.14 (a58d7f38). **Affected:** every release from 0.12.0 through 0.13.0.

**Impact.** One encrypted session (a co-member, a friend or a meeting peer) could grow our roster book and card store without limit.

**Description.** Profile cards and updates stored the roster they carried before any relationship check, and a device can consent to any identity its owner makes up.

**Fix.** A roster that rides a profile is kept only for our own identity, an identity whose roster we hold, a friend row or a member of a server we hold; a refused roster drops the whole message. A profile update inside a meeting is dropped, and a meeting keeps cards for at most 256 identities while we sit in it.

**Residual.** The roster book and the card store are never pruned, so churn through an open server still adds to them over time.

**Test.** `probe193_a_co_members_cards_fill_the_roster_book_with_minted_identities`, `rev193_a_meeting_hosts_churned_strangers_fill_a_guests_roster_book`, `the_profile_roster_arms_go_through_the_gate`.

### HOL-SEC-194: A member served a public channel's deleted posts, and their files, to a non-member

**Severity:** Low (Impact L, Exploitability M). **Class:** P. **Fixed in:** 0.14 (c7caff62). **Affected:** every release with public channels through 0.13.0.

**Impact.** Text and files their author deleted from a public channel stayed readable to a stranger who never saw them.

**Description.** Members keep a deleted post's text and file as evidence. The member channel sync responder admitted anyone for a public channel, since reading is what public means, and then served the member page with its deleted rows; HOL-SEC-014 had closed the same leak on the guest page only. The file request path served a public channel's file to a non-member without asking whether its post had been deleted.

**Fix.** The member sync responder serves only a current member who may see the channel; anyone else gets silence and reads the guest page, which leaves deleted posts out. A non-member asking for the file of a deleted post gets silence too. Members keep the evidence.

**Residual.** A member whose device the responder cannot place yet (a new device, a phrase-recovered install) gets no page from that responder until its roster arrives, and retries, as for every non-public channel before.

**Test.** `a_non_member_channel_sync_ask_gets_no_deleted_text`, `a_stranger_gets_no_file_of_a_deleted_public_post`, `a_public_channels_sync_page_goes_only_to_a_member`, `a_member_once_refused_gets_its_old_evidence_on_the_retry`.

### HOL-SEC-195: A leave during the screen share picker left a live share for the next room

**Severity:** Low (Impact M, Exploitability L). **Class:** C. **Fixed in:** 0.14 (f0805308). **Affected:** every release with voice channel screen share, from 0.9.4 through 0.13.0.

**Impact.** Our screen stayed captured with no room to stop it, and a voice room we joined later was told we share and was served the capture on a Watch, a room the person never chose to show their screen to. The share controls there did say we share, and the system's capture indicator stayed on.

**Description.** A voice channel share waited for the capture picker (the Android consent dialog, the iOS broadcast sheet, the Wayland portal) while the app stayed usable. A leave, a kick or a channel delete in that window found no capture to close, and the start then resumed on a state with no room, so the next room inherited it. A DM call share had the same window.

**Fix.** The start holds its capture and preview until its last wait and checks after each one that its session is still current and we are still in the room; a lost session closes what it opened. A stop during the picker cancels the start, a second start meanwhile is refused, and a join into another room drops any share left over. The DM call share does the same per call.

**Residual.** While the picker is up the person sees no share control, so a share they gave up on is cancelled only by leaving or by the picker returning.

**Test.** The `test/vc_leave_teardown_test.dart` group "a share that starts while the room changes (HOL-SEC-195)" and `test/dm_share_start_test.dart`.

### HOL-SEC-196: A take over's backup could hold a link, and its rollback read through it as root

**Severity:** Medium (Impact M, Exploitability M). **Class:** C. **Fixed in:** the 0.14 relay setup (3d62ce35). **Affected:** the setup wizard's take over since it shipped with relay 0.13.0 build 1.

**Impact.** Root-only files on the relay box, such as a TLS private key, could land readable by the old relay's service account.

**Description.** A take over backs up every file it may replace, so a failure can put the old relay back. It checked each path by name and then copied it in a separate step, while the old relay's service still ran and its account could write some of those folders. A file swapped for a link in between left a link in the backup, and a rollback read the link's target as root and landed those bytes at the old path, owned by the old account.

**Fix.** The backup opens each file once, checks the open file itself (a regular file with one name at the expected path) and copies from that descriptor; a file that changed in between stops the take over before anything changed. A rollback restores only the backup's own plain copy, descriptor to descriptor, and names any entry it refused.

**Residual.** Between the name check and the open, a swapped-in link can still make root open a FIFO or a device before the descriptor check refuses it; no byte is read or written through it.

**Test.** `t_adopt_backup_refuses_an_entry_that_became_a_link`, `t_adopt_rollback_never_lands_a_link_target`; the box test `adopt_box_test.sh race` on real systemd and accounts.

### HOL-SEC-197: A take over copied the old relay's state by name while the old services ran

**Severity:** Low (Impact M, Exploitability L). **Class:** C. **Fixed in:** the 0.14 relay setup (3d62ce35). **Affected:** the setup wizard's take over since relay 0.13.0 build 1.

**Impact.** A root-only file could land as the new relay's report counts or the forwarder's identity, readable by that service.

**Description.** Report counts or forwarder data kept outside the setup's own folders were checked and then copied as root by a command that follows a link, while the old services still ran.

**Fix.** The stage no longer reads the old files. It installs the copy the backup already took through the checked descriptor (HOL-SEC-196), and only a file the backup saw owned by root or by the old service's own account.

**Residual.** None known.

**Test.** `t_adopt_stage_copies_only_the_old_accounts_own_plain_file`; the box test `adopt_box_test.sh stagerace`.

### HOL-SEC-198: Removing the relay left the take-over backup with the old relay's secrets

**Severity:** Low (Impact M, Exploitability L). **Class:** C. **Fixed in:** the 0.14 relay setup (3d62ce35). **Affected:** the setup wizard's take over and removal since relay 0.13.0 build 1.

**Impact.** Copies of the TLS private key, the TURN secret, the push token, the DuckDNS token, members-only keys and the forwarder identity stayed on a box the person believed was clean.

**Description.** The removal screen said it removes every service with its accounts, settings and secrets, but neither removal path touched the take-over backup or named it.

**Fix.** When a backup exists, the removal screen names it and asks whether to delete it. Yes zeroes every file and deletes the folder; no keeps it, and the last screen says what it holds and how to delete it.

**Residual.** None known.

**Test.** `t_uninstall_names_or_removes_the_take_over_backup`; the box test `adopt_box_test.sh takeover`.

### HOL-SEC-199: The setup's certbot ran as root from packages nobody pinned

**Severity:** Low (Impact H, Exploitability L). **Class:** C. **Fixed in:** the 0.14 relay setup (3d62ce35). **Affected:** the setup wizard since relay 0.13.0 build 1, in IP address mode on a box without snap.

**Impact.** Code that runs as root twice a day on the relay box, if a dependency release or the package index were hostile at install time.

**Description.** Only certbot itself was pinned. Every dependency resolved to whatever the index served that day, unchecked, the renewal ran as root with no sandbox, and the host check did not look at it.

**Fix.** The setup ships `deploy/certbot-requirements.txt` with every package pinned to one version and its sha256 hash, installs from it alone with hashes required and no source builds, remakes an older unpinned environment, and runs the renewal in a sandbox that `check-host.sh` checks.

**Residual.** None known.

**Test.** `t_certbot_venv_installs_only_hashed_requirements`; the box test `systemd_box_test.sh` (certbot section) on Ubuntu 24.04 and Debian 12.

### HOL-SEC-200: Olm pickles left session and account secrets in freed memory on every save

**Severity:** Low (Impact M, Exploitability L). **Class:** C. **Fixed in:** 0.14 (a6cdf8c4). **Affected:** every release through 0.13.0.

**Impact.** Root and chain keys, skipped message keys and the account's identity and one-time secret keys outlived their use in freed memory, where a memory disclosure, a core dump or swap could hand them back.

**Description.** Every Olm session and account save serialized its pickle into plain strings, grown by doubling and, for the account, built from a JSON value tree; the store channel, the database bind and every read back held them the same way, and nothing wiped them. Nothing kept the heap out of crash dumps. vodozemac 0.11.2 wipes only its own copies.

**Fix.** Pickles are wiped on drop from serialization through the store channel to the bind and on every read back, and are written into a buffer sized before the first byte, so no growth leaves a copy behind. Every process entry turns core dumps off on Unix and keeps the heap out of Windows Error Reporting dumps.

**Residual.** SQLite's own copies of a bound value and its page cache are not wiped (AR-44); stack copies during serialization are not wiped; Linux keeps the process dumpable, since the desktop portals and PipeWire identify a Flatpak client through it.

**Test.** `a_saved_pickle_is_wiped_when_dropped_and_never_outgrew_its_buffer`, `a_pickle_that_would_outgrow_its_buffer_is_refused`, `pickles_read_back_from_the_store_are_wiped_on_drop`, `a_process_that_holds_secrets_writes_no_core_dump_with_its_heap`.

### HOL-SEC-201: MLS saves left group and signing secrets in freed memory on every message

**Severity:** Low (Impact M, Exploitability L). **Class:** C. **Fixed in:** 0.14 (bc2c4bdc). **Affected:** every release through 0.13.0.

**Impact.** The device's MLS signing key, each group's epoch and message secrets, HPKE private keys, resumption secrets and a staged commit's path secrets outlived their use in freed memory, where a memory disclosure, a core dump or swap could hand them back.

**Description.** OpenMLS's memory store serialized every written row into a buffer grown by doubling, copied it again and freed both the growth copies and the row it replaced unwiped, on every MLS encrypt and decrypt. Each save copied the changed rows and the signing key into plain buffers on their way to the database, every load read them back the same way, and past epochs were scrubbed through a JSON value tree and packed through growing buffers.

**Fix.** Rows that hold key material are written by Hollow's store wrapper in one pass into a buffer that wipes what it outgrows, and the row each write replaces or deletes is wiped; tests hold every such write to the memory store's own bytes. Save rows, the signer and every row read back are wiped on drop all the way to the database and back, rows read from disk move into the store without a copy, and a store let go wipes every row. Past epochs are scrubbed in place and packed at their exact size.

**Residual.** OpenMLS parses a row with serde_json whenever it reads one, which frees partial copies unwiped; rows without key material are still written by the memory store; the past-epoch compressor frees its window unwiped; SQLite's own copies are not wiped (AR-44); stack copies are not wiped.

**Test.** `mls_save_rows_are_wiped_on_drop`, `a_replaced_or_deleted_secret_row_is_wiped`, `rows_laid_over_the_store_wipe_what_they_replace`, `a_store_let_go_wipes_every_row`, `the_signer_reads_back_as_the_crate_reads_it`, `a_past_copy_is_scrubbed_in_place_as_the_value_tree_scrubbed_it`, `a_packed_copy_never_outgrew_its_buffers`.

### HOL-SEC-202: A file name cut to length could come out as a Windows device name

**Severity:** Low (Impact L, Exploitability M). **Class:** A. **Fixed in:** 0.14 (82df7694). **Affected:** every release from 0.10.0 through 0.13.0.

**Impact.** A Share download saved on Windows under a device name such as CON opened the device instead of a file, so that download failed or its bytes went nowhere; nothing left the downloads folder.

**Description.** `safe_file_name` checked a name for Windows device names before it cut the name to 200 bytes and trimmed the spaces and dots the cut exposed, so `CON` followed by about 200 spaces and one more character came out as `CON`. The device list also missed some names Windows reserves (`COM0`, `LPT0`, the superscript digits) and a stem with spaces before its extension. The `file_names` fuzz target found it.

**Fix.** The device-name check runs on the name that is kept, after every change to it, against the full reserved list.

**Residual.** None known.

**Test.** `a_device_name_is_judged_on_the_name_kept`; `fuzz_regressions_stay_fixed` replays the kept fuzz input.

### HOL-SEC-203: A wrong-typed keys.json ended the relay without its restart snapshot

**Severity:** Low (Impact M, Exploitability L). **Class:** A. **Fixed in:** relay 0.14 (883aa238). **Affected:** every relay release through 0.13.0 build 1.

**Impact.** The relay ended without its shutdown path, so every offline buffer, topic ring, parked kill signal, session and push token on the box was lost, and a start with the same file crash-looped. Only the operator's own root-owned file could trigger it.

**Description.** The license reader read the `enabled` field outside its parse's error handling. A `keys.json` whose `enabled` is not a boolean, or whose top level is not an object, threw from the reload timer into the network library, which ends the process. A second edit inside the same second was also never read.

**Fix.** One reader that never throws type-checks the file before any read and keeps the previous keys when it does not read. Both timer callbacks catch everything, and reloads compare the file's time to the nanosecond together with its size, inode and device.

**Residual.** A `keys.json` that does not read at start leaves the license gate off until the file is fixed, as invalid JSON always did.

**Test.** Relay `test_license_pool.cpp` (every wrong shape keeps the previous keys), live `deny_license_wrong_types`, and the `file_stamp.h` cases of `test_deny_list.cpp`.

### HOL-SEC-204: A self-hosted install's background push fetch dialled the official relay

**Severity:** Medium (Impact M, Exploitability M). **Class:** P. **Fixed in:** 0.14 (5965e6b9). **Affected:** Android installs on a self-hosted relay with UnifiedPush, from 0.12.0 through 0.13.0.

**Impact.** The official relay learned that a device uses Hollow, its device id and public key, its IP address, the room it asked for and when it got a push, although its person had chosen another relay to keep that metadata away from us.

**Description.** When a UnifiedPush wake finds the app killed, Android starts a background process that fetches the waiting messages itself. That process never received the relay the person picked, which only the running app knows, and fell back to the official relay. The iOS extension had the same fallback, reached only where a self-hosted relay has push credentials of its own.

**Fix.** The fetch reads the relay this install saved in its own database. A database it cannot read refuses the fetch, and only one that reads and holds no choice means the official relay.

**Residual.** None known.

**Test.** `w4_iospush_a_fetch_with_no_relay_given_dials_the_installs_own_relay`, `w4_iospush_an_unreadable_relay_choice_refuses_the_fetch`; a cold-process wake on an Android emulator against a self-hosted test relay.

### HOL-SEC-205: A received sticker pack was unpacked with no size limit as soon as its card showed

**Severity:** High (Impact M to H, Exploitability H). **Class:** A. **Fixed in:** 0.14 (89d3a85d). **Affected:** every release with sticker packs, from 0.10.0 through 0.13.0; the shards import in every release through 0.13.0.

**Impact.** Every member who viewed the conversation ran out of memory and the app ended, again on every open while the attachment stayed. Anyone who may post a file in a DM or a channel could do it, with no tap from the victim. Nothing was read or written.

**Description.** The chat card of a received `.hollow-pack` reads its manifest as soon as the file is on disk. The manifest was read whole, with no limit on what it inflated to, and the import read each sticker the same way before checking it, so a small pack could inflate about a thousand times. The `.hollow-shards` import had the same gap on a file the person picks.

**Fix.** Every entry of such a zip is read under a cap of its own and one budget for the whole file, counting the bytes it inflates to, and a refused entry still pays for what it inflated. Before the zip reader parses anything, the file's index is walked from its end and may list at most 128 entries for a pack and 65,536 for a bundle. The card reads one pack at a time, remembers a pack it refused and shows that it cannot open it.

**Residual.** None known; a pack inside its budget costs the viewer at most that budget, about 60 MiB.

**Test.** `a_pack_whose_manifest_unpacks_past_its_cap_is_refused`, `a_pack_stops_unpacking_once_its_budget_is_spent`, `a_pack_file_past_its_size_is_refused_before_it_is_read`, `review_t14_a_pack_listing_far_more_entries_than_a_pack_holds_is_refused` (with a peak memory check), `a_bundle_whose_manifest_unpacks_past_its_cap_is_refused`, `shards_together_stop_at_the_bundle_budget`; the widget tests of the pack card; a Windows fleet run with a pack whose manifest inflates to 1 GiB.

### HOL-SEC-206: Importing a shards bundle could replace a vault file's key or store shards no manifest names

**Severity:** Medium (Impact H, Exploitability L). **Class:** C. **Fixed in:** 0.14 (89d3a85d). **Affected:** every release with the evidence recovery pool through 0.13.0.

**Impact.** A held vault file's manifest (its key, name and content id) could be replaced, so the file a member recovered was someone else's bytes, and junk shards took the place of real ones. The person had to choose to import a bundle the attacker gave them.

**Description.** The import wrote every manifest a bundle carried over what was held and stored every shard for whatever server the bundle named. It used neither the live manifest gate nor the shard-write gate.

**Fix.** A bundle names no sender, so it is judged against what the device holds. For a server we hold and are a member of, a manifest only fills a gap, and only one the live gate would take; for a server we no longer hold, no manifest is added. A shard lands only under the server its held manifest names, through the shard gates, so only the bytes that manifest pins are stored.

**Residual.** An ex-member's bundle restores only the shards of manifests the device still holds.

**Test.** `a_bundle_for_a_server_we_do_not_hold_stores_nothing`, `a_bundle_never_replaces_a_held_vault_manifest`, `a_bundle_shard_that_does_not_hash_to_its_manifest_is_not_stored`, `a_bundle_manifest_is_judged_like_a_live_one`, `an_ex_members_bundle_restores_only_the_shards_of_manifests_it_holds`.

---

## Goes in section 5, HOL-SEC-161: replace its Residual line and extend its Test line

**Residual.** None known since 0.14: a PreKey's inner ratchet key of small order is refused too, a session that cannot encrypt is retired so the next send re-keys, and vodozemac 0.11.2 refuses small-order keys in its own 3DH and ratchet steps.

Add to **Test:** `a_prekey_with_a_small_order_ratchet_key_never_opens_a_session`, `the_crafted_prekey_with_an_honest_ratchet_key_opens_and_answers`, `a_session_that_cannot_encrypt_is_retired_so_the_next_send_re_keys`, `vodozemac_alone_refuses_a_v1_prekey_under_the_v2_config`, `vodozemac_alone_refuses_an_outbound_session_on_a_small_order_key`.

## Goes in Appendix A, WP2 (DMs and Olm), "Examined, no finding": replace the L-02 line

- L-02 (vodozemac non-contributory DH) holds: every non-ephemeral key input is signed and
 verified before session creation on every path (EF/olm "L-02"). Since 0.14 vodozemac
 (0.11.2) refuses non-contributory key agreements itself, and Hollow also refuses a
 PreKey's small-order inner ratchet key, which vodozemac reaches only at the first send.

---

## Goes in section 6.1, "Accepted risks": changes since 0.13

- **AR-01 (no per-message limits).** Revisited in 0.14: the circuit breaker now enforces by
  default, and the connection limits are operator settings (`SELF_HOSTING.md`, "Connection
  limits"). Still no per-message limit.
- **AR-08 (report counts).** The full-table half is fixed in 0.14 (track b14-bounds); the
  report half stays accepted.
- **AR-11 (backdated ops).** Narrowed in 0.14 for kicks and bans. A kick or ban now names
  the target's power-granting operations it had seen, and every member voids those it did
  not name inside the span the removal closed. Demotions and the cases the row lists stay
  accepted.
- **AR-12 (an op older than a checkpoint's clock is lost).** Closed in 0.14 by checkpoint
  coverage (56587ca2).
- **AR-15 (identity residuals).** Narrowed in 0.14 for server joins: on a relay that answers
  `roster_check`, a joiner's KeyPackage reaches, and its Welcome comes from, only a device
  the relay's roster fold counts. The row lists what stays open.
- **AR-17 (guest preview).** Extended by the STRIDE slice on public channels: a guest cannot
  tell a member's post from a non-member's, and its memory store has no cap of its own.
- **AR-36 (resumable sessions).** Corrected for 0.14's limits: the breaker enforces, one
  IPv4 address can drive more relay work under the new default of 512 connections, and
  holding the login window takes about 500 IPv4 addresses.
- **New in 0.14.** AR-37 (what a sender a locked room hides may reach), AR-38 (0.13 clients
  lose servers whose join lock a 0.14 device moved), AR-40 (two volume residuals of
  HOL-SEC-190), AR-41 (a retire's post window from a remover that lacks the history),
  AR-42 (profile updates signed by the master key alone), AR-43 (two residuals of the
  rejoin rule), AR-44 (SQLite's own memory), AR-45 (a sync responder can withhold ops) and
  AR-46 (the rebuild cost of a backdated flood). AR-39 was opened and closed within 0.14.

## Goes in section 6.2, "Open items": state at the 0.14 freeze

- **Circuit breaker.** Enforces by default since 0.14 (4ccb0a10): the official relay's
  shadow counters over 11 days, the G1 scale run and a probe of 300 fresh sessions behind
  one address showed no trip.
- **0.13 compatibility paths.** Gone in 0.14: the legacy MLS leaf rebind, the old stand-in
  rule for anchored servers, the dual `revoked_devices` write, the state vector for
  self-certifying servers, the old discovery answer and the ring-control switch (550d6b01).
- **Media.** SFrame on 1:1 cameras is built. Gossip audio stays off, so voice channels stay
  a full mesh up to 16 people, and SFrame on a forwarded voice is proven in tests only.
- **The signed status notice for 0.13** is a release step: it tells 0.13 users to update,
  that they stop seeing servers whose lock a 0.14 device moved, and that their posts past a
  server's cut no longer reach 0.14 members.
- **HOL-SEC-187's last proof.** The retest on the notarized 0.14 build runs before release.
- **Assurance.** The STRIDE slices for server state, public channels and history sync,
  which the 0.13 pass left out, are written (`audit/phase_ef/crdt.md`,
  `public_channels.md`, `backfill.md`); one of their gaps became HOL-SEC-194. The
  requirements list (`audit/requirements.md`) names, for each rule, where it is enforced and
  which test proves it. The Rust wire parsers are fuzzed.
