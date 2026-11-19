# History sync for big servers: newest-first join and a per-device history window (0.15)

Status: planned (Vitalik, Nov 19 2026: goes to 0.15). Area: relay-and-sync. Related: `STORAGE_NODES_PLAN.md` §17 and phase 2b (referenced, not edited), wiki `security_write_gates` §55 and §65, memories `project_local_history_storage`, `project_storage_node_server_answer`, `project_issue90_dm_gap_digest`, `project_restricted_channel_backfill_gate`, finding HOL-SEC-185.

## 0. Summary

- **Confirmed, with three corrections.** A joiner pages every channel's whole history oldest-first, 200 rows a page, no cap, so the newest rows arrive last. Corrections: (a) a returning member asks only from its watermarks, so it is not oldest-first over the whole history; (b) the chat pane never shows more than the newest 200 rows held locally, so "scroll up" is new UI work even for rows already on disk; (c) the server `retention_messages` prune is a dormant bug (it compares seconds with milliseconds), and if it ever ran it would make a device claim history it no longer holds.
- **A (newest-first join):** new fields on the existing sync messages. 0.15 is already the next deliberate clean break (tmp3 "THE PLAN", Vitalik Nov 16), so the ascending join path is deleted in 0.15 itself: every 0.15 responder serves the newest page of the stretch an ask names, and no 0.14 fallback is kept. The joiner lands its newest page per channel first; older history becomes a hole (`channel_sync_holes`, already persisted) that a throttled scheduler fills top-down. A restart resumes from the database.
- **B (history window):** a per-device "Keep server messages" setting, default All. A window is not a clear: it writes a *window mark* that feeds `channel_held_from`, so a windowed device is a partial holder by the existing AR-39 rule and never vouches for rows it lacks. Rows below the window are refused at the one insert and pruned in batches. Widening turns the mark back into a hole and refetches. Scrolling up below the window fetches pages into RAM only.
- **C:** the Archive manifest, the export dialog and the viewer say where this device's history starts, and why.
- **D:** storage nodes (phase 2b) are the holder of last resort for old pages; this plan needs a "newest first, before cursor" read on the node.
- **E:** DMs are out of scope.
- **F:** every new path goes through the one responder (`sync_partner`, then `channel_held_from`), the same receive gates and bounded state. Nothing new reaches the relay.

## 1. Today, read from the code

**Joiner.**
- On the Welcome the joiner asks the member who sent it for every channel it can see, in one loop: `swarm.rs:9112-9131` (`channel_asks.start_with`, `sync_handler::channel_sync_request` `sync_handler.rs:739`).
- An empty store produces `since = 0`, no sender watermarks, no gap (`messages.rs:4472` `channel_ask_since`).
- The responder `build_channel_sync_batch` (`sync_handler.rs:976`) serves `get_channel_messages_since(.., 0, 200)` `ORDER BY timestamp ASC` (`messages.rs:4586-4612`); later pages come from `get_channel_messages_since_per_sender` (`messages.rs:4966`, also ascending).
- Each next page continues from the page's own end: `ChannelPageEnd` (`sync_handler.rs:795`), `channel_next_page_request` (`:822`). Receive arm `swarm.rs:10676-10737`, landing through `land_channel_page` (`sync_handler.rs:4318`).
- One holder per channel (`channel_asks.rs`): 20 s of silence hands the ask on, a holder keeps it at most 10 min (`MAX_TENURE`), a page counts as progress only if it ends past the last one (`hear`, `channel_asks.rs:392`).
- The chat pane loads the newest 200 rows from the database (`channel_chat_provider.dart:337-341, 490-494`; `messages.rs:4217`). While a join pages, the pane shows the newest rows *received so far*, which are the channel's oldest. Live posts after the Welcome arrive over MLS. Relay ring frames (200 frames / 1 MB per channel, `relay-uws/src/state.h:95-96`) sealed before the joiner's epoch cannot be read by it.
- Measured (HOL-SEC-185, 0.13 fix): 100k messages = about 55 MB relay traffic and about 51 s, about 1.7 KB per row on disk.

**Returning member.** Per-sender watermarks minus a 30-minute lookback (`get_per_sender_timestamps`, `messages.rs:4910`) plus a per-day `GapDigest` over 30 days (`channel_gap_anchor`, `messages.rs:3213`); dispatch via `SyncCoordinator` (`types.rs:5754`) and `ask_peers_to_fill` (`sync_handler.rs:1476`); topic ring replay from the watermark (`catchup_watermark_ages` / `request_channel_catchups`, `sync_handler.rs:1216, 1257`). Only the missed span is paged, ascending, so a long absence also gets its newest rows last.

**Partial holders (AR-39).** `channel_held_from` (`messages.rs:4266`) = the oldest row at or after MAX(floor mark, hole top). The responder serves only from that row and puts `held_from` on the page. A device that held nothing opens a hole (`note_held_page`, `messages.rs:4372`), filled ascending (`raise_channel_hole`) through `Kind::Hole` asks with `until` (`channel_hole_request`, `sync_handler.rs:761`). Holes persist in `channel_sync_holes` (`messages.rs:1644`).

**Clear messages.** `clear_history_in` (`messages.rs:4056`) writes permanent floors and remembered cleared ids; `floor_refuses_sql` (`:490`) refuses those rows on every insert; asks count what the clear took (`channel_cleared_*`). UI `storage_section.dart:349-375`, FFI `api/storage.rs:1280`, empty-state copy `chat_pane_shared.dart:1286-1295`.

**Server retention.** `swarm.rs:7186-7251` computes `now_ts` in seconds against millisecond rows, so it never deletes anything. `prune_channel_messages_in_range` (`messages.rs:4721`) deletes rows with no floor, hole or mark: fixed as it stands, it would make a device answer as a full holder while missing rows.

**Gates.** Responder `sync_partner` (member, can see, not revoked; `crypto_handler.rs:1729`) at `swarm.rs:13132`. Receiver `channel_backfill_allowed_from` plus `backfill_filter` (`swarm.rs:10678-10682`). `holders_among` filters holders by `sync_partner` per channel.

**Archive.** `export_channel_archive` / `export_server_archive` (`api/archive.rs:174, 210`) export every held row. `ArchiveManifest` (`archive/types.rs:72-97`) has no coverage field; the manifest is inside the signed content hash (`archive/exporter.rs:93-142`).

**Precedent.** Guest pages are already newest-first (`PublicChannelSyncRequest`, `get_visible_channel_messages_before`, `messages.rs:4617`).

## 2. Goals and non-goals

Goals: the newest page of the channel on screen arrives one round trip after the Welcome, whatever the history length; the whole history still reaches an "All" device, as one copy, in the background; an opt-in window keeps less on this device without lying to peers or in the Archive.

Non-goals: changing the default ("All" stays: full history on every member is deliberate, for evidence and a complete Archive); DMs; node history itself (§17); changing a clear's semantics.

## 3. A. Newest-first join

### 3.1 Wire (additive; 0.14 answers by construction)

`HavenMessage::ChannelSyncRequest` (`types.rs:2137`) gains:
- `newest_first: bool` (`serde(default)`, skipped when false): serve the newest rows of the stretch `[since+1, until)`; no `until` = the channel's newest.
- `limit: Option<u16>`: clamped to 20..=200; the tail ask uses 100.
- `from_row: Option<i64>`: on catch-up asks, serve no row below this to any sender, named or not. Always a row the asker holds (its X), never the window bound or a floor. Removes the page of "unnamed sender served in full" every catch-up from a later-starting device costs today.

`MessageEnvelope::ChannelSyncBatch` (`types.rs:3810`) gains `newest_first: bool` as an echo. On an echoed page: `has_more: Some(true)` = more rows below the page's bottom within the stretch; `None` with `held_from: None` = nothing held below the bottom (the channel's start within the stretch); `held_from: Some(X)` keeps its AR-39 meaning.

**Compatibility: part of the 0.15 clean break (Vitalik, Nov 19).** 0.15 already drops compatibility (tmp3 "THE PLAN": relay drops 0.13 compat and non-pv:2 presence, kick residual, AR-41), so this plan keeps no 0.14 ascending path: delete the ascending join and the bottom-up hole fill; no per-session "who echoed" bookkeeping. Fields still carry `#[serde(default)]` where a struct is persisted. If the 0.15 break is ever narrowed so 0.14 peers stay on servers, the way back is a fallback (a 0.14 responder answers ascending, the asker continues as a catch-up chain).

### 3.2 Responder (one place: `build_channel_sync_batch`, `sync_handler.rs:976`, called only from `swarm.rs:13151`)

- Branch after the `sync_partner` gate and after `channel_held_from`: `WHERE server_id, channel_id AND timestamp >= max(since+1, X) AND timestamp < until ORDER BY timestamp DESC LIMIT limit+1` on `idx_channel_msgs` (`messages.rs:1266`).
- Close ties at the bottom: include every row stamped at the bottom timestamp, capped at 1,000; past the cap the page goes out as `Stuck` (HOL-SEC-185 residual, unchanged). Without it a hole top cut mid-millisecond loses rows.
- Rows ascending inside the page; hidden rows included (evidence, HOL-SEC-194).
- Preview budget: `channel_sync_items` (`sync_handler.rs:643`) cuts at the newest end; a descending page must cut at the oldest end so it stays a contiguous top slice.
- De-dup key: `channel_sync_ask_key` (`sync_handler.rs:857`) must hash `newest_first`, `limit`, `from_row`, else a descending and an ascending ask with the same watermarks de-dup against each other (`swarm.rs:13139-13144`).
- `from_row` on ascending asks: `get_channel_messages_since_per_sender` serves unnamed senders from `from_row`.

### 3.3 Asker

- **Tail first.** At the Welcome (`swarm.rs:9121`), on channel open (`handle_request_channel_sync`, `sync_handler.rs:4239`) and at start for every channel with no row, no floor and no hole: first ask `newest_first, limit 100, since 0`. Order: the channel on screen first, then visible channels in CRDT order, at most 4 tail asks in flight per server.
- **Hole from a tail page.** `land_channel_page` calls a new `MessageStore::note_top_page` in the same transaction: a device that held no rows opens a hole with `below` = the oldest landed row and `all_from` = 0 (or the window bound, §4) unless the page reached the start; a page answering the hole's descending ask (`until == hole.below`) lowers `below` to its oldest landed row, to X when the page said `held_from: X`, and closes the hole when it reached the start. Only landed rows move the hole (AR-39 forged-row rule).
- **`ChannelAsks`** (`channel_asks.rs`): new `Kind::Tail`; descending chains progress downward (`hear` `:392` takes `bottom < last` for them); a `PageBottom` twin of `ChannelPageEnd` gives the next cursor; "every ask catches up first" stays.
- **A start claim needs a second identity.** One holder saying "the channel starts here" would close a hole for good (B1 L2 residual), so a start claim is confirmed by one empty descending page from a second identity when one is online (mirrors the CRDT resync rule "a non-partial responder or two identities"). With nobody else online the hole closes and the residual is noted.
- **Scheduler, new `node/history_fill.rs`** (pure state, unit-tested like `channel_asks`). Priorities: (1) the open channel's tail, (2) its scroll-up page, (3) other channels' tails, (4) catch-ups (existing, never throttled), (5) background hole fill, top-down, round-robin. Background fill: one page in flight per server, at most 2 servers at once, a minimum gap between pages (desktop/mobile constants from T0), paused while backgrounded on mobile, resumable (state lives in `channel_sync_holes`); `MAX_TENURE` expiring mid-fill moves the ask on.
- **Dart.** `MessageSyncProgress` totals stop meaning "remaining"; during a fill the progress line reads "Loading older messages". `channelHistoryBeginsLaterProvider` already refreshes on completion (`event_provider.dart:931`).

### 3.4 A2: returning member after a long absence (optional, after T0 data)

If the first catch-up page's `total` (already counted, `sync_handler.rs:1056-1067`) exceeds a threshold (proposed 2,000), switch to a tail ask; the gap between the watermark and the tail's bottom becomes a hole with `all_from` at the oldest watermark. Cost: while that hole is open, `channel_held_from` vouches only from its top, so this device stops serving older history to others (a bounded, asker-chosen exception to AR-39 "no contagion"). Vitalik decides.

## 4. B. Per-device history window

**Setting.** Settings > Files & storage gets a "Message history" card: "Keep server messages on this device": Last week / Last month / Last 3 months / Last year / All (default). Stored in `app_settings` through a typed FFI `set_history_window(days)` that runs the bookkeeping below in one transaction (never a bare `saveSetting`); notifier follows `settings_provider.dart:786`. One setting per device for all servers, never synced to siblings; `scrub_device_secrets` (`messages.rs:5256`) drops it, so a copy starts at All.

**Not kept below the window bound W = now - window:** channel posts, their edits, deletions, reactions, file headers and downloaded bytes. CRDT server state, pins as state, MLS and DMs are untouched.

**The window mark (honesty invariant).** New table `channel_window_marks(server_id, channel_id, kept_from)`: below `kept_from` this device keeps nothing by its own choice and may fetch it again. `channel_held_from` (`messages.rs:4270`) gains a third UNION arm: MAX(floor mark, hole top, window mark), so a windowed device serves from X (its oldest row at or after `kept_from`) and says so; peers treat it like a late joiner or a cleared device. A young channel never gets a mark. `channel_gap_anchor` (`messages.rs:3227-3233`) already clips the digest at X for a holder that does not count cleared rows; `channel_ask_spans` (`:4452`) already names only senders held from X; `from_row = X` stops 0.15 responders serving pruned senders in full; a 0.14 responder wastes at most one page per channel per catch-up.

**Writers of the mark.**
- **Prune.** `MessageStore::prune_below_window(now)` deletes in batches (the clear's loop shape, `finish_cleared_history`, `messages.rs:4103`): rows and what hangs off them, file unlinks through the pending-unlink queue, FTS optimize, `release_free_pages`. Writes NO floors, cleared ids or cleared counts; raises `kept_from` to the newest pruned row + 1. Runs from the hourly maintenance tick (next to `swarm.rs:7231`) and right after the setting narrows; holds the iOS storage background task like the clear.
- **Insert gate.** `insert_channel_message[_judged]` (`messages.rs:3807, 3832`) refuses `timestamp < W` beside `floor_refuses_sql`, on every path (live, sync, push, public lane); a refusal raises `kept_from` the same way.
- **Window and holes.** Raising the window lifts a hole's `all_from`; if it meets `below`, the hole is absorbed: in one transaction `kept_from = hole.below` and the hole row is deleted. Never through `drop_filled_hole` (`messages.rs:4424`), which would erase the mark and claim full history.

**Narrow** (All to a month): a confirm dialog, then the prune. **Widen** (a month to All): every mark becomes a hole (`below` = X, `all_from` = new W or 0), the mark is deleted, the hole fills top-down. A window never reaches below a clear's floor: floors stay permanent, cleared history never returns.

**Scroll-up.** New local paging FFI `load_channel_messages_before(sid, cid, before_ts, before_mid, limit)` (keyset on the `messages.rs:4229` ORDER BY). The pane keeps at most about 1,000 rows in memory, trimming the far end. At the top of local rows:
- **All device with a hole open:** ask the hole's descending page now (priority 2); rows stored, hole lowered.
- **Windowed device below its mark: a peek.** Same descending ask on the wire (the responder cannot tell it from a fill), recorded locally in a bounded asked-set (1 per open channel, 4 in all; unasked pages hard-dropped, as in `file_asks`). Rows pass `channel_backfill_allowed_from`, `backfill_filter`, `verify_sync_item_sig` (`sync_handler.rs:4897`) and `floor_refuses`, are NOT inserted, and go to Dart in a new `NetworkEvent::ChannelOlderPage`. Dart keeps them in a RAM cache (2,000 rows per channel, 5,000 in all, dropped on pane close), deduped by `message_id`; link-card thumbs through `image_gate::shown`; v1 offers no file downloads from peeked rows.

**Server retention.** T4 fixes the units at `swarm.rs:7186` and routes `retention_messages` through `prune_below_window` with the same marks, or deletes the arm. Never `prune_channel_messages_in_range` as it stands.

## 5. C. Archive and evidence honesty

- **Manifest.** `ArchiveManifest` and `ArchiveChannelInfo` (`archive/types.rs:35-39, 72-97`) gain `#[serde(default)] history_from: Option<i64>` (this device's X) and `history_reason: Option<String>` ("window" | "cleared" | "joined_later"; absent = whole), inside the signed hash. Old loaders ignore them.
- **Export dialog** (`ui/dialogs/export_archive_dialog.dart`): a notice before export when any exported channel has `history_from`.
- **Viewers.** The imported viewer and the in-app Archive (`archive_provider.dart:291`) show a banner; the in-app Archive reads a new FFI `channel_history_coverage(sid, cid)` built on `channel_held_from` and the existing `channel_history_cleared` / `channel_history_begins_later` (`api/storage.rs:315, 326`).
- **Empty state** (`chat_pane_shared.dart:1290-1295`) gains a window branch; peeked rows sit under a divider saying they are not saved here.
- The statement covers only where history BEGINS on this device; gaps in the middle are not knowable and not claimed.

## 6. D. Storage nodes

Ladder for an old page: (1) local rows; (2) online members (one holder at a time, partial holders hand on via `held_from`); (3) the server's node pool (§17, phase 2b; decision 23 already puts the node first for catch-up).

Needed from 2b (for Vitalik to fold into §17): a "newest first, before cursor, limit" batch read beside §17.5's "after cursor X"; the node reporting where its own index starts (a seeded node, decision 31) so its answers carry `held_from` with the same meaning; node items judged as sync items (§17.5). Node pages may fill holes on an All device or serve peeks on a windowed one. Restricted channels: only per-channel history-key holders can open items (§17.3); members skip items tagged with channels they cannot see. Until 2b ships: when no online member vouches below X, the hole stays open and the UI says older messages are with members who are offline. Windowed phones plus a node is the intended pairing; "All" stays the default either way.

## 7. E. DMs: out of scope

DMs are 1:1 and usually small; a linked device gets the database whole at link time; sibling backfill (`DmSiblingSyncRequest`, `sync_handler.rs:918`) and `dm_sync_anchor` (`messages.rs:3197`) are unchanged; the window never applies to DMs (matching "Direct messages stay" in the clear). If T0 shows sibling backfill hurting, newest-first for DMs gets its own plan.

## 8. F. Security

1. **One serving path.** Descending pages and peeks are `ChannelSyncRequest` variants answered only in `build_channel_sync_batch` behind `sync_partner` (members only, `can_see_channel`, not revoked, HOL-SEC-194). Guests keep `PublicChannelSyncRequest` (no hidden rows). `holders_among` picks only entitled holders; restricted-channel asks never go to a non-qualifier, and a non-qualifier's ask is refused before any DB read.
2. **One receive path.** `channel_backfill_allowed_from`, `backfill_filter`, signature verification, then the window gate and `floor_refuses` at the one insert (peeks: the same checks, no insert). Cleared history never returns, RAM included.
3. **Bounded state.** Asked-sets, peeks and the RAM cache capped; `history_fill` state derived from the database (at most one hole and one mark per held channel); tie-close capped at 1,000; responder de-dup map already pruned (`swarm.rs:6939`); pacing stays `frame_budget`; nothing a stranger sends creates a row (holes and marks move only from our own asks' landed rows or our own setting).
4. **No new relay metadata.** Same Carried Olm frames, same room; the window value never leaves the device; asks name only held rows (X). An asked member can infer roughly where our history starts: the existing AR-39 residual, more frequent with windows (document in §65).
5. **Residuals.** A holder omitting rows while answering whole (B1 L2), reduced for start claims by the two-identity check; more than 1,000 rows in one millisecond still get `Stuck`.

## 9. G. Measurements, tests, tracks

**Measure first (T0, on today's main; again after T2/T4).** Harness benchmark, `#[ignore]` behind `HOLLOW_MEASURE=1`: seed 1k / 10k / 100k signed rows (`plant_signed_channel_row`, as `test_harness.rs:56651`) from 100 authors, 17% link cards, 1% deleted, in 1 and in 10 channels. Record: join command to Welcome; TTFM (Welcome until the newest 50 rows of the opened channel are in the DB); total time; relay bytes (`MockRelay` meter); page count; joiner DB size; responder ms per page at depth. Fleet on the staging relay (two desktops, Android emulator, iOS simulator) for 10k and 100k: TTFM and total from `[HOLLOW-SYNC]` stamps plus relay counters. Also: the prune of 100k rows to one week on a phone (wall time, file shrink), and how often a return's first catch-up `total` exceeds 2,000 (for A2). Acceptance set after T0: TTFM flat across 1k/10k/100k; total bytes within a few percent of baseline (one copy).

**Harness tests:** `hs_a_joiner_lands_the_newest_page_first`, `hs_background_fill_takes_one_copy_and_closes_the_hole`, `hs_fill_resumes_after_a_restart_without_refetching`, `hs_a_start_claim_waits_for_a_second_identity`, `hs_a_windowed_member_vouches_only_from_its_window`, `hs_a_windowed_member_never_stores_rows_below_its_window` (sync, live, push, unnamed senders), `hs_widening_the_window_fetches_the_rest`, `hs_a_window_absorbing_a_hole_keeps_its_mark`, `hs_peeked_rows_reach_dart_and_never_the_db`, `hs_an_unasked_peek_page_is_dropped`, `hs_a_cleared_floor_beats_the_window_and_the_peek`, `hs_restricted_pages_never_reach_a_non_qualifier` (extend `restricted_channel_history_and_files_never_reach_a_non_qualifier` with descending asks, peeks and a stranger socket).

**Unit tests:** `desc_page_closes_ties_at_its_bottom`, `desc_page_costs_the_same_at_any_depth`, `ask_key_tells_desc_from_asc`, `preview_budget_cuts_a_desc_page_at_its_bottom`, `window_mark_feeds_channel_held_from`, `young_channel_gets_no_window_mark`, `from_row_bounds_unnamed_senders`, `history_fill` priority and pacing, archive `manifest_states_where_history_begins`; widget tests for the export notice, empty state and settings card.

**Tracks (dependencies only):**

| Track | Scope | Agent | Depends on |
|---|---|---|---|
| T0 | Baseline measurements | runner | none |
| T1 | Wire fields, descending responder, tie-close, `from_row`, ask key; delete the ascending join path (0.15 clean break) | builder-secure | none (T0 for numbers) |
| T2 | Tail-first asker, `note_top_page`, `ChannelAsks` descending chains, start-claim check, `history_fill` | builder-secure | T1 |
| T3 | Local scroll-up paging (FFI + pane) | builder | none; remote half needs T2 |
| T4 | Window: setting FFI, marks, insert gate, prune, absorb and widen, retention fix | builder-secure | T1; widen fill needs T2 |
| T5 | Peek: asked-set, verify-only landing, event, Dart RAM cache | builder-secure | T1, T3, T4 |
| T6 | Archive honesty: manifest, dialog, viewers, empty state | builder | none for cleared/joined-later; window reason after T4 |
| T7 | Node read ladder | builder-secure | STORAGE_NODES phase 2b |
| T8 | Re-measure and fleet; wiki §65 and `rust_sync_handler` update | runner + lead | T2, T4, T5 |

## 10. Decisions for Vitalik

All decided by Vitalik, Nov 19-20 2026:

1. **One window per device**, chosen by the user on each device (a week on desktop, a day on the phone); default **All** on every device. The window is what a device KEEPS, never what it pulls first: pulling is always newest-first, and an All device fills the rest in the background.
2. **Pinned posts below the window: on demand.** Pins are CRDT state, so the pins panel knows the ids; opening it peeks a small descending page at each pinned post's timestamp from any member holding it (same ask, gates and RAM cache as scroll-up, §4). No exempt rows, no new wire.
3. **Peeked rows: shown from RAM, no file downloads in v1.**
4. **A2 tail-first for returning members: yes**, threshold set from the T0 data.
5. **Fix server `retention_messages` through window marks** (T4), never delete the arm.
6. The ascending join path is deleted in 0.15, as part of its clean break.

## 11. Proposed copy (goes through Sepia before shipping; no em dashes)

**Settings card.** Title "Message history". Row "Keep server messages on this device". Options: Last week, Last month, Last 3 months, Last year, All. Help: "Every member keeps the full history of their servers, so your Archive is complete and you can show what was said. Keeping less saves space on this device. Other members still have the older messages, and you can scroll back to read them while one of them is online."

**Narrow confirm.** Title "Keep only the last month?" Body: "Server messages older than a month will be removed from this device, with their downloaded files. Other members keep theirs. Archives you export from this device will start a month back, so export any you want complete first." Button "Keep last month".

**Empty states and dividers.** Window empty state: "This device keeps the last month. Scroll up to load older messages from other members." Peek divider: "Older messages below are not saved on this device." Nobody online: "Older messages are on other members' devices, and none of them is online right now."

**Archive.** Export notice: "This device keeps server messages from 19 October 2026 on, so this archive starts there." Variants: "is still downloading older messages" and "older messages were cleared from this device". Viewer banner: "Exported from a device holding messages from 19 October 2026 on. Earlier messages are not in this archive."
