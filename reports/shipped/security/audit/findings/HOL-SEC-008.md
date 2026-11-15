# HOL-SEC-008: A friend could rewrite or re-caption messages it did not write, our own included, through live and push delivery

```
ID:          HOL-SEC-008                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Medium                      (Impact M: a friend rewrites, hides, cards or re-captions a message in the
                                          victim's own history, our own sent messages included, which then read as
                                          unverified in the Message Proof; Exploitability M: the push path needs only a
                                          friendship and ids the friend already received, the other rows need a message's
                                          id and signed fields)
Category:    Access control (authenticated but not authorised): the change's signature proves who wrote the CHANGE,
             never that the ROW it lands on is theirs
Component:   rust/hollow_core/src/node/swarm.rs :: Olm EditMessage, DeleteMessage, AddReaction arms
             rust/hollow_core/src/node/message_ops.rs :: handle_envelope_{edit_message,delete_message,link_preview_set,
                                                         add_reaction} (every channel transport, and the DM card)
             rust/hollow_core/src/node/fetch.rs :: handle_edit_message, handle_link_preview_set, persist_direct_message
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-17; plan section 2.2 class 1; candidates B3..B8, C6, L5 (cards and reactions); authz rows A-DM-14..A-DM-18
Attacker:    P-04 friend, P-05 server member (channel binding, reactions), a revoked sibling that still holds history (F5)
Found:       2026-09-26, phase B DM, channel and transport passes; confirmed by reading and test 2026-09-27
```

## Description

HOL-SEC-004 bound every SYNCED change to the row it lands on. The live and push
paths still decided by message id alone:

- A live DM edit, deletion or card was accepted on any row we had received,
  and the signature was checked against the SENDER, not the row's author. A
  sender that knew a message's id and signed fields could rewrite, hide or card
  a message in a different conversation, and the row kept its real author's
  name.
- On the push path (the background fetch node on mobile) the edit had no
  direction check at all, so a friend could rewrite OUR OWN messages in our
  conversation with them, using ids and fields it had received. A DM whose id
  matched an existing `[file:...]` row replaced that row's text and signature
  (the caption promotion), our own sent images included.
- A DM reaction attached to any id, channel messages included, from where it
  replicated through channel sync; a channel reaction attached to any id
  whatever channel it named.
- A channel edit, deletion, card or reaction from the row's own author was
  accepted when it named another server or channel, or none. The mute gate then
  read the server the sender picked, so a muted member could still edit (C6).
- Over MLS, any server member could send a DM-shaped card or reaction.

## Reproduction

`authz_live_dm_change_touches_only_the_senders_own_rows`,
`authz_push_dm_change_touches_only_the_senders_own_rows`,
`authz_live_channel_change_must_name_the_rows_own_channel` and
`authz_dm_reaction_lands_only_in_the_reactors_conversation`
(node/message_ops.rs and node/fetch.rs tests).

## Fix

- The HOL-SEC-004 guard, now `message_ops::change_may_touch_row`, is the one
  ownership check for every change, live or synced. `live_dm_change` takes the
  signer and context from the ROW and refuses a friend's change unless the row
  is theirs in their conversation with us, and a sibling's unless the row is
  ours.
- The live DM edit and delete left the swarm arm for
  `handle_envelope_dm_edit` / `handle_envelope_dm_delete`. The Olm channel arms
  now run the same handlers as MLS and public channels, with the sender resolved
  to its master, so the channel rules exist once (this also ends two drifts: the
  Olm mute gate read a device id, and multi-device authors' Olm edits were
  refused).
- A channel change must name its row's own server and channel. A reaction lands
  only on a row of the channel it names (`channel_reaction_target_ok`) or of the
  reactor's conversation with us (`dm_reaction_target_ok`). MLS drops DM-shaped
  cards and reactions.
- Push path: the edit and the card go through `live_dm_change`, the caption
  promotion through `change_may_touch_row`.
- Class rule (wiki `security_write_gates`, CLAUDE.md): every remote change to an
  existing message row passes `change_may_touch_row`.

## Variants

- Every storage function that changes an existing message row or reaction was
  listed (`edit_message_in`, `hide_message_in`, `set_message_hidden_in`,
  `update_link_preview*`, `promote_file_sentinel_to_caption`,
  `reconcile_dm_by_timestamp`, `repair_channel_message_sender`,
  `set_*_edited_at`, `add_reaction`, `remove_reaction`) with every caller. The
  rest write only on a fresh insert, are bound by their SQL to the sender's own
  conversation (`reconcile_dm_by_timestamp`), act only on the sender's own
  reaction (`remove_reaction`), or sit behind the sync guard (HOL-SEC-004).
- Reactions riding a channel sync batch are checked for the reactor's signature,
  not the reactor's membership: candidate E4 and class C.
- The live half of B9: the live FileHeader owner guard already takes the
  transport sender; the byte substitution around it is H1/H2.
- Edit ordering and reaction replay: B10, B11.

## Test

The four tests above fail when each path's old rule is put back (DM signer from
the sender, no channel binding, no reaction binding, the three push paths
unguarded) and pass with the fix. Full suite 904/904.
