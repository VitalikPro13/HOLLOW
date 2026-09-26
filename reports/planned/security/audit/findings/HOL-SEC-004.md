# HOL-SEC-004: A sync responder could rewrite, re-attribute, card or delete any message it knew the id of

```
ID:          HOL-SEC-004                 Status: Fixed on local main (2026-09-26), retest at release
Severity:    High                        (Impact H: any channel or DM message rewritten under its real author's name,
                                          moved to the attacker's name, given a phishing card or hidden, and the result
                                          re-served onward by the victim's own sync; Exploitability M: needs a message id
                                          and a sync path to the victim, which any friend or server member has)
Category:    Access control (authenticated but not authorised): the item's signature proves who wrote the ITEM,
             never that the ROW it lands on is theirs
Component:   rust/hollow_core/src/node/swarm.rs :: ChannelSyncBatch (Olm), DmSyncBatch, DmSiblingSyncBatch arms
             rust/hollow_core/src/node/sync_handler.rs :: handle_envelope_channel_sync_batch (MLS twin)
             rust/hollow_core/src/node/file_handler.rs :: file_meta_write_allowed call sites
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-17; plan section 2.2 class 1; candidates B1, B2, B9 (sync half), channel S14; authz rows A-CH02, A-DM-20
Attacker:    P-04 friend, P-05 server member, P-01 through any session it holds
Found:       2026-09-26, phase B channel and DM enumeration passes, confirmed by reading and test
```

## Description

Every catch-up sync item carries its author's signature, and since 0.8.5 an item
whose signature does not verify is dropped. What the check proved was only that
the item's own `s` wrote the item. The item was then applied to whatever row its
`mid` named, anywhere in the database:

- an existing channel row was re-attributed to the item's signer (the multi-device
  sender repair), after which a deletion proof signed by the same attacker
  verified against the row;
- an item with `edited_at` overwrote the row's text while the row kept its real
  author's name;
- a card with its signature was grafted onto any row whose text the item matched;
- a DM item edited a row in a different conversation, or in the other direction;
- the file card riding an item was judged by the blob's own `sender` field, and
  its `fid` was never compared with the `file_id` the item signed, so any item
  could relabel any known file.

The victim then served the rewritten rows, with the attacker's proofs, to the
rest of the channel through its own sync responses.

## Reproduction

`authz_synced_channel_item_cannot_rewrite_another_authors_row` and
`authz_synced_dm_item_touches_only_its_own_conversation_and_direction`
(node/message_ops.rs tests). Before the fix, a validly signed item from another
member re-attributed and hid a channel message, and the DM guard did not exist.

## Fix

- One guard, `message_ops::synced_item_may_touch_row`, runs before any write for
  every sync item: an existing row changes only when it sits in the channel or
  conversation the item names and its author is the item's signer. A channel
  row's author is its sender collapsed to the master, or the key its stored
  signature names, so the legitimate wedged-row repair still converges
  (`synced_channel_item_still_repairs_a_row_wedged_under_a_device_id`). A DM
  row's author follows from its conversation and direction.
- Both channel transports now run one function,
  `sync_handler::ingest_synced_channel_item` (verify, guard, upsert, extras), in
  place of two copies that had drifted apart. The DM friend and sibling arms call
  the same guard.
- File cards go through `file_handler::synced_file_meta`: the blob must describe
  the `file_id` the item signed, ownership is judged against the item's verified
  author, and the stored sender and message id come from the item, not the blob.

## Variants

- Same root cause on LIVE paths, still open: candidate B3 (DM edit signer never
  compared to the row's author), B4 (push-path DM edit rewrites our own rows),
  B5 (live DM delete takes its signer from the sender), B6 (DM reaction on any
  id), B7 (DM `LinkPreviewSet` on any row), B8 (push path promotes any file row),
  B9 live half. Each should call the same guard.
- Ordering and replay of edits and reactions (B10, B11) are a separate class.
- Who may SEND a channel batch at all (candidate C3) is fixed alongside: a batch
  is accepted only from a current member who can see that channel
  (`authz_channel_backfill_only_from_a_member_who_can_read_it`). Refusing items
  whose author was never a member needs a provable membership record the state
  does not keep yet: candidate E4, built with E1.

## Test

`authz_synced_channel_item_cannot_rewrite_another_authors_row`,
`authz_synced_dm_item_touches_only_its_own_conversation_and_direction`: both fail
with the guard disabled and pass with it. The existing sync deletion, card,
reaction and wedged-row tests pass.
