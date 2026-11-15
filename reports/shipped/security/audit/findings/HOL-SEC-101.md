# HOL-SEC-101: Reactions skipped channel visibility live and membership in backfill

```
ID:          HOL-SEC-101                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Low                         (Impact: reactions by members who cannot see a channel, or by never-members, attached to posts;
                                          Exploitability M: a member, or anyone whose signed reaction a member relays in a sync batch)
Category:    Channel / Authorization
Component:   rust/hollow_core/src/node/message_ops.rs (handle_envelope_add_reaction,
             store_synced_dm_reactions), crypto_handler.rs (backfill_filter), swarm.rs (batch arms)
Boundary:    TB-3 (server members) / TB-2 (contacts)
Traces to:   C-16; phase B re-check channel A-CH02, A-CH05
Attacker:    a member; a stranger with a relaying member
Found:       2026-10-02 (phase B re-check)
```

## Description

A live reaction over Olm was checked for membership but not for whether the reactor could see the channel. Channel sync batches filtered the sending peer and each post's author, never the reactors, and stored any reaction with a valid signature. DM sync batches stored reactions from anyone, not only the conversation's two parties.

## Fix

Live reactions take the same change ladder as edits (member, can see the channel, not muted). Both channel batch arms run `backfill_filter`, which keeps a reaction only if its reactor was a member at the reaction's own time. DM sync applies the party rule the live path already had.

## Residual risk

A backfilled reaction's time is the reactor's claim, so a former member can date one into its old membership (as AR-11 for posts). Legacy-anchored servers skip the reactor check like the author check.

## Test

Unit `authz_a_reaction_needs_a_reactor_who_can_see_the_channel`, `authz_a_synced_dm_reaction_comes_only_from_a_party`; harness `authz_backfill_drops_a_reaction_by_a_never_member` (failed before: "a never-member's reaction was backfilled"); mutation killed.
