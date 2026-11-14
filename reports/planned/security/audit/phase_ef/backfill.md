# Phase E slice "backfill": catch-up sync of DMs, channels and the op log

Pre-freeze STRIDE pass for 0.14 (2026-11-05), the third slice the 0.13 review left open
(flow F-35, plus F-23 and the CRDT catch-up half of F-30; `coverage.md` WP3 "Not
examined"). Code read on `security/0.14` at `56587ca2`. Nothing was built or run; every
test named exists in that tree unless marked *planned*.

## Scope

- Elements (E-02):
  - P1 askers: `storage/messages.rs::dm_sync_anchor` and `channel_gap_anchor` (watermark
    minus the lookback, plus a `GapDigest` of what we hold behind it: per UTC day a count and
    the XOR of each message id's 64-bit FNV-1a), `node/sync_handler.rs::channel_sync_request`,
    `dm_next_page_since`, `ChannelPageEnd`, `node/channel_asks.rs` (one holder per channel at
    a time, `MAX_TENURE` 10 minutes), `crypto_handler::sync_partner` and `mls_sync_partner`
    (whom a sync may be asked of).
  - P2 responders: the `DmSyncRequest` and `DmSiblingSyncRequest` arms and the
    `ChannelSyncRequest` arm in `node/swarm.rs` (`build_channel_sync_batch`,
    `get_dm_gap_messages`, `get_channel_gap_messages` with `gap_span_ok`), the guest page
    (see `public_channels.md`), the op-log digest (`crdt/digest.rs::entries`,
    `node/crdt_resync.rs::answer_digest`), whole-log pages (`crdt_resync::page`), and the
    file serving paths (`FileRequest` channel arm, `file_handler.rs` replication and holder
    candidates, `vault_ops.rs`).
  - P3 ingest: the `DmSyncBatch`, `DmSiblingSyncBatch` and both `ChannelSyncBatch` arms
    (Olm and MLS), `channel_backfill_allowed_from`, `backfill_filter` and
    `backfill_author_allowed` (`node/crypto_handler.rs`), `check_backfill_signature`
    (`REQUIRE_SIGNED_BACKFILL`), `message_ops::change_may_touch_row`, the channel floors of
    "Clear messages" (`ChannelInsert::Cleared`, `channel_ask_reaches_floor`), message-id
    dedup.
  - DS1 the message store (`messages`, `channel_messages`, `message_deletions`).
- Flows: F-23 (DM sync), F-35 (channel sync and backfill, file serving), F-30's catch-up
  (op digest, pages).
- External interactors: X-2 relay, X-3 friends, members (holders), strangers holding a
  server id, X-4 own siblings, P-08 removed device.
- Claims: C-04, C-09, C-13, C-14, C-18; rule: live enforces, backfill tolerates (CLAUDE.md).

## Summary

- STRIDE cells walked: 45.
- Already numbered and open: the laundering half of HOL-SEC-188 (a removed device's
  master-signed posts reach everyone through a stale member's backfill) until track C's
  channel post proof (DEVICE_PROOF section 13).
- One **candidate for a HOL-SEC number** shared with `public_channels.md` (G-P1: the channel
  sync responder serves deleted rows to a non-member of a public channel). Two Info gaps
  (G-B1, G-B2).
- What holds: every serving path asks `channel_readable_by` first; every ingested row is
  signature-checked, attributed to the master, judged by `change_may_touch_row` when it
  meets an existing row, and refused when its author was never a member at its time.

## Assets

| Asset | Why it matters here |
|---|---|
| History completeness | A gap a watermark never repairs is silent data loss (#90). |
| Restricted channel history | The subgroup protects live traffic only; backfill was the bypass (`project_restricted_channel_backfill_gate`). |
| Row integrity | A responder must not rewrite, re-attribute, re-card or delete what it serves (HOL-SEC-004). |
| DM privacy | Only the conversation's two identities, and their own devices, ever get its rows. |
| Responder resources | Every ask costs the responder a query and an upload. |

## Trust boundaries

- TB-2: the responder is a member or a friend running any client; it may withhold, never
  forge. The asker is any device that reaches us.
- TB-3: siblings get the whole DM history; a removed device gets nothing.
- TB-1: sync rides Olm or MLS; the relay sees only sizes and timing.

## STRIDE

### P1: askers

| Class | Threat | Mitigation (code) | Residual | Test |
|---|---|---|---|---|
| S | A sync is asked of a stranger who answers with junk or learns what we hold. | `sync_partner` (a current member who can read the channel, not revoked); an MLS-triggered ask goes to the leaf's certified master or a sync partner (`mls_sync_partner`, HOL-SEC-089, -124). | none | `authz_a_frame_that_fails_to_decrypt_asks_only_a_member_to_sync`, `authz_mls_syncs_ask_only_a_member_device` |
| T | A bare watermark skips rows that arrived out of order. | Watermark plus `GapDigest` (#90); a next page starts at the page's own end (`dm_next_page_since`, `ChannelPageEnd`), never our newest row. | none | `the_next_channel_page_starts_every_sender_at_the_page_end`, `a_page_cut_by_its_limit_takes_no_gap_row_past_its_end` |
| D | One withholding holder keeps a channel's rows from us. | One holder at a time, a silent holder hands the ask on, tenure capped at 10 minutes, order random per process and channel. | L2 per channel (wiki section 40; no AR row, `crdt.md` G-C1) | `g13w3_a_silent_channel_holder_hands_the_ask_to_the_next` |
| D | Pages nobody asked for keep an ask alive. | Only pages we asked for count; a non-advancing page is ignored. | Verifying a page before it counts as progress (HOL-SEC-185 residual) | `g13w3_pages_nobody_asked_for_never_keep_a_channel_ask` |

### P2: responders

| Class | Threat | Mitigation | Residual | Test |
|---|---|---|---|---|
| I | A member who cannot see a restricted channel pulls its history or file keys. | `channel_readable_by` = (member OR public) AND `can_see_channel`, on the requester's master, asked FIRST on the `ChannelSyncRequest` arm, the `FileRequest` channel arm (plus `is_member` before a key-bearing header), replication and holder candidates (`file_handler.rs`), vault serving (`vault_ops.rs`). | none | `restricted_channel_history_and_files_never_reach_a_non_qualifier` |
| I | A non-member gets a public channel's deleted text through the member responder. | The guest responder serves visible rows only; the member responder does not distinguish. | **G-P1, candidate** (see `public_channels.md`) | *planned* `a_non_member_channel_sync_ask_gets_no_deleted_text` |
| I | A friend pulls another conversation, or a blocked friend pulls ours. | DM rows only for the asker's resolved master; blocked askers dropped (HOL-SEC-087); the whole-history sibling ask only from our own unrevoked device (`is_own_unrevoked_device`). | none | `authz_a_blocked_friend_pulls_no_dm_history`, `authz_synced_dm_item_touches_only_its_own_conversation_and_direction` |
| I | A removed device keeps pulling DMs. | A device its own roster removed serves nothing (`roster_book::own_removal`); contacts drop sessions with a device they hear removed (C-03), and key exchange refuses a revoked device (`key_exchange_device_unauthorized`). | The friend responder relies on the session teardown and has no `is_revoked` check of its own (G-B1, Info) | `authz_a_removed_device_loses_the_inbox_at_once` |
| I | A non-member reads the op log by digest. | Members only; a non-member gets its own removal notice and nothing else. | none | `g13_non_member_digest_gets_only_the_removal_notice` |
| D | A requester makes us hash and scan a whole history per ask. | `gap_span_ok` refuses empty, inverted or over-wide digests; gap rows capped at 200 and never paginated; op digest asks over 256 ranges or past round 6 unanswered; whole-log pages budgeted per asker and in all (`pace_answer`). | AR-06 family (re-serving costs work) | `serving_is_budgeted_per_asker_and_in_all` |
| D | A cleared holder hands old rows back, or stalls an asker. | A holder at its floor answers `Stuck` with no rows (`channel_ask_reaches_floor`), so the asker moves on. | Catch-up when every online holder cleared (tmp3 leftovers, w2-c) | (w2-c units) |

### P3: ingest

| Class | Threat | Mitigation | Residual | Test |
|---|---|---|---|---|
| S | A responder backfills rows under another author's name. | `check_backfill_signature` (v2/v3 extras, shape-checked, `REQUIRE_SIGNED_BACKFILL`, unsigned refused); rows attributed to the signing master. | none | `backfill_rejects_unsigned_item`, `authz_a_synced_item_cannot_move_text_into_another_slot` |
| S | Backfill launders a removed device's master-signed posts. | Planned: the channel post device proof (DEVICE_PROOF section 13). | **HOL-SEC-188** (open half) | *planned*, track C |
| T | A responder rewrites, re-cards, re-attributes or deletes an existing row. | `change_may_touch_row` for every remote change to an existing row; a hidden flag only with the author's deletion proof; dedup by message id, never content. | none | `authz_synced_channel_item_cannot_rewrite_another_authors_row` |
| T | A post by someone who was never a member at its time. | `backfill_author_allowed` against `member_record` (10 min slack), reactions by reactor at their own time (`backfill_filter`). | AR-10 (legacy anchors are not judged until their checkpoint) | `authz_backfill_drops_a_reaction_by_a_never_member` |
| T | Backfill from a guest or a non-member. | `channel_backfill_allowed_from`: a current member who can read the channel; source scan pins both arms. | none | `channel_ingest_gates_stay_wired` |
| T | Cleared history comes back by sync. | Every insert path obeys the channel floor (`ChannelInsert::Cleared`). | none | (w2-c units) |
| R | A deletion is denied after the fact. | The deletion proof is kept with the deleted text (evidence) and re-served to members. | none | as T |
| D | A malformed or oversized item panics the node or is stored clipped. | A body over 64 KiB (`MAX_MESSAGE_BYTES`) drops whole, never clipped; remote strings are parsed fallibly. | Fuzzing of sync batches is a pre-freeze item | `authz_a_remote_string_never_panics_the_node` |
| E | Backfill bypasses a mute or a posting rule. | By design: live enforces, backfill tolerates (a mute may postdate the history). | Stated rule, not a gap | none |

## Gaps for the lead

- **G-P1** is written up in `public_channels.md` (candidate for a HOL-SEC number).
- **G-B1 (Info, defence in depth).** The `DmSyncRequest` responder checks the block list and
  our own removal, not whether the asking device is revoked. Today the session teardown
  (C-03) and the key-exchange refusal stop a removed device first, so I found no path; one
  `resolver::is_revoked(peer_str)` line would make the responder hold on its own, the way
  the typing and signal arms do. Suggested test: `a_removed_device_pulls_no_dm_history`.
- **G-B2 (Info).** A `GapDigest` day is a count plus the XOR of unkeyed 64-bit FNV-1a hashes
  of message ids (`storage/messages.rs::mid_hash`). A member who chooses its own message
  ids and controls which device holds which row could make two different day sets compare
  equal and keep one row out of one asker's gap repair; watermarks and live delivery still
  carry it. The op-log digest is salted for this reason (`crdt/digest.rs`). Under the 0.14
  clean break the asker could send a per-ask salt and both ends hash with a keyed function.
  Low value; recorded so the choice is explicit.

## State at 89d3a85d (2026-11-14)

This slice was read at `56587ca2`. What changed since, on `security/0.14`:

- **The laundering half of HOL-SEC-188 is fixed** by track C's post and change proofs: past
  a server's cut, backfill keeps only posts and changes a counted device proves, a carried
  post window covers, or that date from before the cut (`requirements.md` R-CH-12).
- **G-P1 became HOL-SEC-194** (Low), fixed in c7caff62: the member responder refuses a
  non-member, and a deleted public post's file is served to no non-member (R-CH-09).
- **The L2 row** is AR-45.
- **A cleared holder** no longer answers `Stuck`: AR-39 (e45c0bec) replaced that answer and
  `channel_ask_reaches_floor` with the one held-from answer every partial holder gives
  (R-CH-10), so the D row on cleared holders above describes 56587ca2 only.
- **G-B1 and G-B2** stay Info, unchanged. The test G-B1 suggests (`a_removed_device_pulls_no_dm_history`) is
  not written.
