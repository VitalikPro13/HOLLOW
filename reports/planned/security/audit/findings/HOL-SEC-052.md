# HOL-SEC-052: Moderation edges skipped rank, and ownership could be minted or dropped

```
ID:          HOL-SEC-052                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Low                         (Impact M: a moderator lifted an admin's ban or its own mute, an
                                          admin rewrote the owner's nickname or granted permissions it did
                                          not hold, and an owner could leave its server ownerless, after
                                          which anyone could found it; Exploitability L: needs a moderator,
                                          admin or owner with a modified client)
Category:    Missing authorization
Component:   rust/hollow_core/src/crdt/server_state.rs :: op_allowed, role_change_allowed,
             kick_allowed, lifts_register
             rust/hollow_core/src/crdt/fold.rs :: author_checked
             rust/hollow_core/src/node/sync_handler.rs :: author_op
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-15, C-16; candidates E11, E12 (evidence crdt:S12, crdt:S13)
Attacker:    P-05 privileged member with a modified client
Found:       2026-09-26, phase B CRDT pass; confirmed by reading 2026-09-27
```

## Description

Unban and unmute checked no rank. Owner and Admin could rewrite anyone's
nickname, Twitch name and pledge, the owner's included. `RolePermissionsChanged`
took any role string and any bits. The owner could create co-owners, demote
itself or remove itself at ingest, and an ownerless state accepted a founding
op from anyone. Authoring and ingest used different rules for some of these, so
an honest client could author an op every peer refused.

## Reproduction

`authz_moderation_edges_respect_rank` and `authz_the_owner_is_fixed`
(crdt/server_state.rs tests).

## Fix

- Lifting a ban or mute needs at least the rank that set it (the register keeps
  it); unmute also needs to outrank the target.
- Nickname, Twitch name and pledge of someone else need Owner or Admin and
  outranking a current member.
- Role permissions take only admin, moderator or member, below the author's
  rank, and grant only bits the author holds.
- The owner is fixed (decision 1): nobody becomes Owner, and nothing demotes,
  removes, bans, mutes or edits the Owner; a founding op lands only on an
  ownerless state and only for the anchor.
- Our own authoring goes through `op_allowed` (`author_checked`), so an op our
  rules refuse is never applied or sent.

## Test

Each test fails with its old rule put back and passes with the fix. Full suite
green.
