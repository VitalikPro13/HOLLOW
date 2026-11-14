# Phase E slice "public channels": plaintext signed posts, guests, public files

Pre-freeze STRIDE pass for 0.14 (2026-11-05), the second slice the 0.13 review left open
(flow F-34; `coverage.md` WP3 "Not examined"). Code read on `security/0.14` at `56587ca2`.
Nothing was built or run; every test named exists in that tree.

## Scope

- Elements (E-02 unless named):
  - P1 the send branch: `message_ops.rs` (the `PublicChannelMessage` send on
    `is_channel_public()`), `file_handler.rs` (the public file card), the relay's `SendPublic`
    (`0x0A`).
  - P2 the member receive path: `node/swarm.rs` arms `PublicChannelMessage`,
    `PublicChannelEdit`, `PublicLinkPreviewSet`, `PublicChannelDelete`,
    `PublicChannelAddReaction`, `PublicChannelRemoveReaction`, each behind
    `message_ops::public_frame_accepted`, then `handle_envelope_channel_message`
    (`channel_sig_rejected`, `live_channel_moderation_drop`) and the shared edit, card,
    delete and reaction handlers.
  - P3 the guest: `node/guest_view.rs` (`GuestView::store_for`, a store that lives only
    while the guest browses), `PublicChannelListResponse`, `PublicChannelSyncResponse`
    (`message_ops::guest_item_accepted`, `verified_guest_hidden_at`,
    `sync_reaction_accepted`, `file_handler::synced_card_claim_refused`), the live guest file
    card.
  - P4 the member responders to guests: `PublicChannelListRequest` (effectively public
    channels, banner thumbnail only), `PublicChannelSyncRequest`
    (`get_visible_channel_messages_before`, `guest_page_more` at the channel floor), the
    `FileRequest` serving gate and `PublicFileHeader` (requested-only).
  - P5 the public flag: `ChannelInfo::effective_public` and `ServerState::is_channel_public`
    (`crdt/server_state.rs`), the `ChannelPublicChanged` arm of `op_allowed`.
  - The relay (X-2): guest sockets (`auth_mode` "guest", `PerSocketData::is_guest`), the
    breaker's allowance for public frames reaching sockets outside a room's audience
    (`breaker.h`), door rooms (`door_room.h`).
- Flows: F-34 (public posts and files), the guest's preview, page and file pulls, push for a
  public post (`node/fetch.rs`).
- External interactors: X-2 relay, X-3 members, guests (a non-member browsing), strangers.
- Claims: C-20 ("signed by their authors and cannot be forged, even though they are not
  encrypted"), C-18 (restricted channels), C-29 (file paths).

## Summary

- STRIDE cells walked: 41.
- No finding numbered here. One **candidate for a HOL-SEC number** (G-P1, the member sync
  responder serves a public channel's deleted rows to a non-member) and two Info gaps
  (G-P2, G-P3). Details at the end; the candidate is described, not written up.
- What holds: authenticity (every public post, edit, card, delete and reaction is
  signature-checked with the v2 extras, live and on a guest's page), the restricted-never-
  public rule, the members-only write path, requested-only public file headers.

## Assets

| Asset | Why it matters here |
|---|---|
| Authorship of public posts | The signature is the only binding; there is no MLS layer (C-20). |
| Deleted public posts | Members keep a deleted post's text as signed evidence; strangers must not get it back (HOL-SEC-014). |
| Restricted channels | Must never go public, live or by history (HOL-SEC-094, C-18). |
| A guest's device | It holds no server state, so it cannot judge membership; nothing it is shown may land in its database (HOL-SEC-095). |
| Member storage | Files and history members serve to guests. |

## Trust boundaries

- TB-1: the relay reads public posts by design (they are plaintext, sealed only for the
  sender's device); it must not forge or reorder them into a different meaning.
- TB-2: members, guests and strangers are separate principals. A guest is anyone holding the
  server id with a public channel.

## STRIDE

### P1, P2: sending and the member receive path

| Class | Threat | Mitigation (code) | Residual | Test |
|---|---|---|---|---|
| S | A post, edit, card or reaction under another identity's name. | `channel_sig_rejected` requires a v2 signature over the server, channel, text and extras (mid, reply, file id, order, card digest, album) and the key binding to the sender's master; a missing signature rejects. The relay frame is device-sealed (design A). | none | `authz_synced_channel_item_cannot_rewrite_another_authors_row`, `a_text_chunk_moved_into_another_slot_never_verifies` |
| S | A conference id used as a public channel to persist meeting chat. | `handle_envelope_channel_message` drops any `conf:` sid first. | none | `conference_waiting_room_admits_denies_and_chats` |
| T | A non-member, muted member or member without post rights posts live. | `live_channel_moderation_drop` -> `live_channel_post_refusal` (member, see, post, mute, media-only, slow mode by our clock) on every live transport. | Backfill does not judge mutes (live enforces, backfill tolerates) | `channel_ingest_gates_stay_wired` |
| T | A frame for a channel this member does not hold as public. | `public_frame_accepted`: with state, only `is_channel_public` (effective); without state, only while browsing as a guest. | none | `authz_a_hidden_channel_never_shows_to_a_guest` |
| T | A removed author re-edits or re-cards an old post. | Edits and cards ask `live_channel_change_refusal` (member who can see, not muted). | Deletes and unreactions never ask (an author may always take its own post down) | `authz_a_removed_author_no_longer_edits_or_recards_live` |
| R | An author denies a post. | The v2 signature is stored with the row and re-served. | none | as S |
| I | The relay and every room socket read public posts. | By design: C-20 promises authenticity, not secrecy; public channels are plaintext in the whitepaper and the UI. | none (stated) | none |
| D | A flood of public posts. | The relay breaker in SHADOW and the per-device frame budget; members drop non-member posts before any write. | AR-01 (no per-message limits) | none |
| E | A restricted or voice channel is made or stays public. | `effective_public` = public flag AND text AND unrestricted; restricting clears the flag for good; `op_allowed` refuses `ChannelPublicChanged` on a restricted channel (HOL-SEC-094). | none | `authz_a_restricted_channel_is_never_public` |

### P3: the guest

| Class | Threat | Mitigation | Residual | Test |
|---|---|---|---|---|
| S | A member shows a guest an author name or avatar it chose. | A guest shows an author only by that author's own master-signed card, an avatar only when its bytes hash to the card's. | none | `authz_a_guest_shows_only_what_the_senders_card_signs`, `authz_a_guest_shows_an_author_only_by_its_own_card` |
| S | Server name, avatar, banner and channel list are the answering member's word. | Nothing binds them to the owner. | AR-17 | none (accepted) |
| T | A page item with a forged hidden flag, reaction or file card. | `guest_item_accepted` re-verifies every item; `verified_guest_hidden_at` needs the author's deletion proof; `sync_reaction_accepted`; a card only for the signed file id and only when `synced_card_claim_refused` passes. | none | `a_member_hands_a_guest_only_signed_cards` |
| T | A post by a non-member is shown to a guest as part of the channel. | A guest holds no member list, so it cannot judge membership (matrix row channel:A-CH10 records this as by design). An unknown author shows with no name. | No AR row (G-P2) | none |
| I | Posts a guest saw outlive the preview on its disk. | `GuestView`: posts live in a store held only while the guest browses; leaving forgets them. | none | `a_guest_store_lives_in_memory_only_while_held`, `authz_a_guest_keeps_public_posts_in_memory_only` |
| D | A guest's memory store grows while it browses a busy or spammed channel. | Only the relay breaker and member pacing bound it; leaving clears it. | G-P3 (Info) | none |
| E | A guest writes history into members' databases. | Backfill is taken only from a current member who can read the channel (`channel_backfill_allowed_from`); guest sockets are refused at the relay for ring writes, push and most sends (`ws_handler.cpp` `is_guest` arms, HOL-SEC-030). | none | `channel_ingest_gates_stay_wired` |

### P4: what members serve to guests

| Class | Threat | Mitigation | Residual | Test |
|---|---|---|---|---|
| I | A guest's page carries deleted text. | `PublicChannelSyncRequest` serves only `get_visible_channel_messages_before` (no hidden rows), stops at the channel floor. | The member sync path (G-P1, candidate) | `guest_pages_leave_deleted_messages_out` |
| I | A closed or restricted channel shows in the guest list. | `PublicChannelListRequest` lists only `effective_public` channels; the closing admin tells the room's guests. | none | `authz_a_hidden_channel_never_shows_to_a_guest` |
| I | A file of a private channel or a DM is served to a guest who learned its id. | `FileRequest` gate on the stored row's context: a channel row needs `channel_readable_by` (membership or public, and visibility); a key-bearing header only for a member who may read; guests get `PublicFileHeader`. | none | `file_request_gate_refuses_stranger_and_serves_guest_public` |
| T | An unsolicited public file header streams bytes onto a guest's disk. | `PublicFileHeader` taken only for a pull the guest made (`pending_public_file_requests`, 120 s, matching server, removed on receipt); the file id self-certifies (design A `file_commit`). | none | `authz_a_guest_takes_a_public_file_header_only_from_the_peer_it_asked`, `a_guest_pull_is_answered_only_for_its_server_while_fresh` |
| D | Guests make members re-serve pages. | A 2 s answer dedup per (server, channel, guest); member frame budget. | AR-06 family (re-serving costs work) | none |

### P5: the public flag

| Class | Threat | Mitigation | Residual | Test |
|---|---|---|---|---|
| E | A member without MANAGE_CHANNELS flips a channel public. | `op_allowed` on `ChannelPublicChanged`: the permission, a text channel, not restricted. | A stolen device's flip after the person last had it is reverted at once by an owner device (DEVICE_PROOF section 8.3 "Unpublish", track C, planned) | `authz_a_restricted_channel_is_never_public` |
| T | A backdated write reopens a channel that was restricted later. | Checkpoint coverage keeps the `is_public` clock on both visibility arms; an interleaving errs closed. | Wiki section 59: a channel can stay not public where history would reopen it | `rival_owner_checkpoints_converge_without_loss` |

## Gaps for the lead

- **G-P1 (candidate for a HOL-SEC number, Low).** The member-path responder
  `HavenMessage::ChannelSyncRequest` in `node/swarm.rs` (about line 11893) gates on
  `crypto_handler::channel_readable_by`, which lets a NON-member through for a public
  channel (that is what public means for reading). It then serves
  `sync_handler::build_channel_sync_batch`, whose rows come from
  `get_channel_messages_since` / `_per_sender` / `get_channel_gap_messages`: hidden
  (deleted) rows are included with their full text next to the deletion proof
  (`channel_sync_items`, `t: m.text`), as the member evidence rule wants. The guest
  responder `PublicChannelSyncRequest` was fixed for exactly this in HOL-SEC-014, and the
  `FileRequest` arm adds `is_member` before handing a key-bearing header; this arm has
  neither. The answer rides Olm, so the asker needs a session with the member device;
  first contact is open to an unknown device (`key_exchange_device_unauthorized` lets an
  unknown device through), and AR-16 already says members answer strangers in a server with
  a public channel. I did not run a probe (docs-only track). Suggested fix: the member
  responder serves only a current member (`is_member` on the resolved master, as
  `channel_backfill_allowed_from` does), and a non-member is told to use the guest page;
  or it serves visible rows only to a non-member. Suggested test:
  `a_non_member_channel_sync_ask_gets_no_deleted_text` (harness: a stranger with an Olm
  session asks a member for a public channel holding a deleted post; it must receive no row
  whose text the author deleted). Variant to check with it: `sender_timestamps` lets the
  same asker see per-author activity of a public channel, which the guest page also shows.
- **G-P2 (record, Info).** A guest cannot tell a member's post from a non-member's in a
  public channel; an unknown author shows without a name. `authz_matrix.md` row A-CH10
  records the choice; `accepted_risks.md` has no row and AR-17 covers only the preview.
  Proposed: extend AR-17 by one sentence.
- **G-P3 (Info).** A guest's in-memory store has no row or byte cap of its own while it
  browses; a sender in the room bounded only by the relay breaker (in SHADOW) can grow it.
  Proposed: a per-channel cap in `GuestView` (oldest first), or a sentence in AR-17.

## State at 89d3a85d (2026-11-14)

This slice was read at `56587ca2`. What changed since, on `security/0.14`:

- **G-P1 became HOL-SEC-194** (Low), fixed in c7caff62 (`requirements.md` R-CH-09, claim
  C-38).
- **G-P2 and G-P3** are recorded in AR-17.
- **New in 0.14:** an age-restricted server has no public channel; every member's own
  fold refuses guests there (R-CH-13).
