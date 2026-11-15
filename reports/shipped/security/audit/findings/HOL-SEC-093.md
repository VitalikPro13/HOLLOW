# HOL-SEC-093: A member's snapshot of an older server set the joiner's roles and bans

```
ID:          HOL-SEC-093                 Status: Fixed on local main (2026-10-02), retest at
                                          release
Severity:    Low                         (Impact L: on the joiner's replica only, and only
                                          until an honest member serves the owner's
                                          checkpoint, the answering member could make itself
                                          an admin, ban or mute others, grant permissions and
                                          make a channel public; Exploitability M: a member
                                          holding the door that answers the join first and
                                          withholds the checkpoint)
Category:    Missing authorization
Component:   rust/hollow_core/src/crdt/fold.rs :: ServerState::accept_join_snapshot
Boundary:    TB-4 (server members)
Traces to:   C-15; decision D2 (2026-10-02); phase B re-check crdt A-06 (PARTIAL), CRDT-S1
Attacker:    P-05 member with a modified client
Found:       2026-10-02 (phase B re-check)
```

## Description

A server founded before 0.12 has no founding op to build from, so a joiner starts from a
state snapshot one member hands it. With an invite that pins the owner, the joiner
checked only that the snapshot named that owner. Every other field was the answering
member's word, and the joiner judged later ops against it: a member could hand over a
snapshot that made itself an admin, banned or muted others, changed role permissions,
assigned access labels and grants, or marked a private channel public. The joiner kept
that state until another member served the owner's checkpoint.

## Fix

A snapshot from a member decides who belongs and what exists, never who may decide. On
adoption the joiner keeps only the owner's role, and drops role permissions, bans,
mutes, label assignments and channel grants, and marks every channel not public. Roles
and the rest come back only from the owner's own signed ops or the owner's checkpoint,
which replaces the whole state.

## Variants

- A snapshot can still name the wrong members, channels and settings, including a
  channel's access settings, until the checkpoint arrives; a joiner posting into a
  channel the snapshot opened reaches other members, never outsiders.
- Until the owner has run 0.12 once, admins' ops do not apply on such a joiner: they
  wait for the owner's checkpoint.
- Replays and reordering of genuine old ops on these servers before the checkpoint:
  AR-10.

## Test

Unit `authz_a_join_snapshot_carries_no_authority` and harness
`authz_a_members_snapshot_of_an_older_server_decides_nothing` (failed before the fix);
mutation pass in the session notes.
